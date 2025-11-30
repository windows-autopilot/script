<# :
@echo off
setlocal

:: ============================================================================
:: AutoPilot Online - Script tout-en-un (Hybride Batch/PowerShell)
:: ============================================================================

title Windows AutoPilot - Enregistrement en ligne

echo.
echo ============================================================
echo   Windows AutoPilot - Enregistrement automatique en ligne
echo ============================================================
echo.

:: Verification des droits administrateur
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERREUR] Ce script doit etre execute en tant qu'Administrateur !
    echo.
    echo Faites un clic droit sur ce fichier et selectionnez
    echo "Executer en tant qu'administrateur"
    echo.
    pause
    exit /b 1
)

echo [OK] Droits administrateur confirmes
echo.
echo Lancement du script PowerShell...
echo ============================================================
echo.

:: Execution de la partie PowerShell de ce meme fichier
powershell -ExecutionPolicy Bypass -NoProfile -Command "iex ((Get-Content '%~f0' -Raw) -split ':POWERSHELL_SCRIPT\r?\n', 2)[1]"

set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo ============================================================
if %EXIT_CODE% equ 0 (
    echo [SUCCES] Enregistrement AutoPilot termine avec succes !
) else if %EXIT_CODE% equ 2 (
    echo [ANNULE] L'utilisateur a annule l'authentification.
) else (
    echo [ERREUR] Le script s'est termine avec le code : %EXIT_CODE%
)
echo.
pause
exit /b %EXIT_CODE%

:POWERSHELL_SCRIPT
#>

# ============================================================================
# CONFIGURATION - Modifiez ces valeurs selon vos besoins
# ============================================================================

$Config = @{
    GroupTag             = ""           # Tag de groupe (ex: "Kiosk", "Standard")
    AddToGroup           = ""           # Nom du groupe Azure AD
    AssignedUser         = ""           # UPN de l'utilisateur (ex: "user@contoso.com")
    AssignedComputerName = ""           # Nom d'ordinateur a assigner
    WaitForAssign        = $false       # Attendre l'assignation du profil
    AutoReboot           = $false       # Redemarrer apres assignation
}

# ============================================================================
# FIN DE LA CONFIGURATION
# ============================================================================

$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "Windows AutoPilot - Enregistrement"

function Write-Status {
    param([string]$Message, [string]$Type = "INFO")
    switch ($Type) {
        "OK"      { Write-Host "[OK] $Message" -ForegroundColor Green }
        "ERROR"   { Write-Host "[ERREUR] $Message" -ForegroundColor Red }
        "WARN"    { Write-Host "[ATTENTION] $Message" -ForegroundColor Yellow }
        "CANCEL"  { Write-Host "[ANNULE] $Message" -ForegroundColor Yellow }
        default   { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
    }
}

try {
    Write-Host ""
    Write-Status "Verification et installation des modules requis..."
    Write-Host ""

    # Installation NuGet
    $provider = Get-PackageProvider NuGet -ErrorAction SilentlyContinue
    if (-not $provider) {
        Write-Host "  Installation du provider NuGet..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    Write-Host "  [OK] NuGet" -ForegroundColor Green

    # Installation WindowsAutopilotIntune
    if (-not (Get-Module -ListAvailable -Name WindowsAutopilotIntune)) {
        Write-Host "  Installation du module WindowsAutopilotIntune..."
        Install-Module WindowsAutopilotIntune -Force -Scope CurrentUser
    }
    Import-Module WindowsAutopilotIntune -Force
    Write-Host "  [OK] WindowsAutopilotIntune" -ForegroundColor Green

    # Installation Microsoft.Graph.Authentication
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Host "  Installation du module Microsoft.Graph.Authentication..."
        Install-Module Microsoft.Graph.Authentication -Force -Scope CurrentUser
    }
    Import-Module Microsoft.Graph.Authentication -Force
    Write-Host "  [OK] Microsoft.Graph.Authentication" -ForegroundColor Green

    # Modules supplementaires si AddToGroup est configure
    if ($Config.AddToGroup) {
        if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Groups)) {
            Write-Host "  Installation du module Microsoft.Graph.Groups..."
            Install-Module Microsoft.Graph.Groups -Force -Scope CurrentUser
        }
        Import-Module Microsoft.Graph.Groups -Force
        Write-Host "  [OK] Microsoft.Graph.Groups" -ForegroundColor Green

        if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
            Write-Host "  Installation du module Microsoft.Graph.Identity.DirectoryManagement..."
            Install-Module Microsoft.Graph.Identity.DirectoryManagement -Force -Scope CurrentUser
        }
        Import-Module Microsoft.Graph.Identity.DirectoryManagement -Force
        Write-Host "  [OK] Microsoft.Graph.Identity.DirectoryManagement" -ForegroundColor Green
    }

    Write-Host ""
    Write-Status "Connexion a Microsoft Graph..."
    Write-Host ""
    Write-Host "  Une fenetre de connexion va s'ouvrir." -ForegroundColor Yellow
    Write-Host "  Si vous fermez cette fenetre, l'operation sera annulee." -ForegroundColor Yellow
    Write-Host ""

    # Tentative de connexion avec gestion de l'annulation
    try {
        Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All", "Device.ReadWrite.All", "Group.ReadWrite.All" -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Message -match "canceled|cancelled|annul") {
            Write-Host ""
            Write-Status "L'utilisateur a annule l'authentification." "CANCEL"
            exit 2
        }
        throw
    }

    # Verification de la connexion
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Echec de la connexion a Microsoft Graph." "ERROR"
        exit 1
    }

    Write-Status "Connecte au tenant : $($context.TenantId)" "OK"
    Write-Host ""

    # Recuperation des informations hardware
    Write-Status "Recuperation des informations hardware..."
    
    $session = New-CimSession
    $serial = (Get-CimInstance -CimSession $session -Class Win32_BIOS).SerialNumber
    $devDetail = Get-CimInstance -CimSession $session -Namespace root/cimv2/mdm/dmmap -Class MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" -ErrorAction SilentlyContinue

    if ($devDetail) {
        $hash = $devDetail.DeviceHardwareData
        Write-Status "Hardware hash recupere avec succes" "OK"
    }
    else {
        Write-Status "Impossible de recuperer le hardware hash. L'appareil doit etre en mode OOBE ou avoir MDM active." "ERROR"
        Remove-CimSession $session
        exit 1
    }

    Remove-CimSession $session

    Write-Host ""
    Write-Host "  Numero de serie : $serial" -ForegroundColor White
    if ($Config.GroupTag) { Write-Host "  Group Tag       : $($Config.GroupTag)" -ForegroundColor White }
    if ($Config.AssignedUser) { Write-Host "  Utilisateur     : $($Config.AssignedUser)" -ForegroundColor White }
    Write-Host ""

    # Enregistrement dans Autopilot
    Write-Status "Enregistrement de l'appareil dans Autopilot..."

    $importParams = @{
        serialNumber       = $serial
        hardwareIdentifier = $hash
    }
    if ($Config.GroupTag) { $importParams.groupTag = $Config.GroupTag }
    if ($Config.AssignedUser) { $importParams.assignedUserPrincipalName = $Config.AssignedUser }

    $imported = Add-AutopilotImportedDevice @importParams

    if (-not $imported) {
        Write-Status "Echec de l'ajout de l'appareil." "ERROR"
        exit 1
    }

    Write-Status "Appareil soumis pour import (ID: $($imported.id))" "OK"
    Write-Host ""

    # Attente de l'import
    Write-Status "Attente de la fin de l'import..."
    $maxWait = 300 # 5 minutes max
    $waited = 0
    $importComplete = $false

    while (-not $importComplete -and $waited -lt $maxWait) {
        Start-Sleep -Seconds 10
        $waited += 10
        
        $device = Get-AutopilotImportedDevice -id $imported.id
        $status = $device.state.deviceImportStatus

        Write-Host "  Status: $status (attente: $waited sec)" -ForegroundColor Gray

        if ($status -eq "complete") {
            $importComplete = $true
            Write-Status "Import termine avec succes !" "OK"
        }
        elseif ($status -eq "error") {
            Write-Status "Erreur lors de l'import: $($device.state.deviceErrorCode) - $($device.state.deviceErrorName)" "ERROR"
            exit 1
        }
    }

    if (-not $importComplete) {
        Write-Status "Timeout - L'import prend plus de temps que prevu. Verifiez le portail Intune." "WARN"
    }

    Write-Host ""

    # Attente de la synchronisation
    Write-Status "Attente de la synchronisation avec Intune..."
    $maxWait = 120
    $waited = 0
    $synced = $false

    while (-not $synced -and $waited -lt $maxWait) {
        Start-Sleep -Seconds 10
        $waited += 10

        $autopilotDevice = Get-AutopilotDevice -id $device.state.deviceRegistrationId -ErrorAction SilentlyContinue
        
        if ($autopilotDevice) {
            $synced = $true
            Write-Status "Appareil synchronise dans Intune" "OK"
        }
        else {
            Write-Host "  Synchronisation en cours... (attente: $waited sec)" -ForegroundColor Gray
        }
    }

    # Ajout au groupe Azure AD si configure
    if ($Config.AddToGroup -and $synced) {
        Write-Host ""
        Write-Status "Ajout au groupe Azure AD: $($Config.AddToGroup)..."
        
        $aadGroup = Get-MgGroup -Filter "DisplayName eq '$($Config.AddToGroup)'" -ErrorAction SilentlyContinue
        if ($aadGroup) {
            $aadDevice = Get-MgDevice -Search "deviceId:$($autopilotDevice.azureActiveDirectoryDeviceId)" -ConsistencyLevel eventual -ErrorAction SilentlyContinue
            if ($aadDevice) {
                try {
                    New-MgGroupMember -GroupId $aadGroup.Id -DirectoryObjectId $aadDevice.Id -ErrorAction Stop
                    Write-Status "Appareil ajoute au groupe" "OK"
                }
                catch {
                    if ($_.Exception.Message -match "already exist") {
                        Write-Status "L'appareil est deja membre du groupe" "WARN"
                    }
                    else {
                        Write-Status "Erreur lors de l'ajout au groupe: $_" "ERROR"
                    }
                }
            }
        }
        else {
            Write-Status "Groupe '$($Config.AddToGroup)' non trouve" "WARN"
        }
    }

    # Assignation du nom d'ordinateur si configure
    if ($Config.AssignedComputerName -and $synced) {
        Write-Host ""
        Write-Status "Attribution du nom d'ordinateur: $($Config.AssignedComputerName)..."
        Set-AutopilotDevice -id $autopilotDevice.id -displayName $Config.AssignedComputerName
        Write-Status "Nom d'ordinateur attribue" "OK"
    }

    # Attente de l'assignation du profil si configure
    if ($Config.WaitForAssign -and $synced) {
        Write-Host ""
        Write-Status "Attente de l'assignation du profil Autopilot..."
        $maxWait = 600  # 10 minutes
        $waited = 0
        $assigned = $false

        while (-not $assigned -and $waited -lt $maxWait) {
            Start-Sleep -Seconds 30
            $waited += 30

            $deviceStatus = Get-AutopilotDevice -id $autopilotDevice.id -Expand
            if ($deviceStatus.deploymentProfileAssignmentStatus -match "^assigned") {
                $assigned = $true
                Write-Status "Profil Autopilot assigne !" "OK"
            }
            else {
                Write-Host "  Status: $($deviceStatus.deploymentProfileAssignmentStatus) (attente: $waited sec)" -ForegroundColor Gray
            }
        }

        if ($assigned -and $Config.AutoReboot) {
            Write-Host ""
            Write-Status "Redemarrage dans 10 secondes..." "WARN"
            Start-Sleep -Seconds 10
            Restart-Computer -Force
        }
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Status "Enregistrement Autopilot termine avec succes !" "OK"
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Numero de serie : $serial"
    Write-Host "  Tenant ID       : $($context.TenantId)"
    Write-Host ""

    exit 0
}
catch {
    Write-Host ""
    Write-Status "Une erreur s'est produite:" "ERROR"
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}
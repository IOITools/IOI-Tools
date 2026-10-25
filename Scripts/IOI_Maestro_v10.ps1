<#
.SYNOPSIS
    IOI Maestro v10 - Motor de optimización (sin temperatura, sin backups, sin web search)
.DESCRIPTION
    Optimizaciones para Windows 11 26H2.
    - Sin medición de temperatura (eliminada).
    - Sin respaldos (eliminados).
    - Sin Bing ni búsqueda web.
    - Transparencias y efectos visuales INTACTOS.
    - Defender, Edge y SmartScreen vivos pero reducidos.
.NOTES
    Autor: Cristian Viera (IOI)
    Versión: 10.0
#>

#region AUTO-ELEVACIÓN
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $PwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $PwshPath) { $PwshPath = "powershell.exe" }
    Start-Process $PwshPath -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
Set-ExecutionPolicy Bypass -Scope Process -Force | Out-Null
#endregion

#region CARGA DE CONFIGURACIÓN
# Detectar la ruta de IOI_Config.ps1 desde la ubicación del script
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$IOI_Config = Join-Path (Split-Path $ScriptDir -Parent) "Config\IOI_Config.ps1"

if (-not (Test-Path $IOI_Config)) {
    $IOI_Config = Join-Path $ScriptDir "Config\IOI_Config.ps1"
}
. $IOI_Config
#endregion

Clear-Host
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   IOI MAESTRO v10 - EDICIÓN LIMPIA (sin temp / sin backup)      " -ForegroundColor Magenta
Write-Host "   Por Cristian Viera                                            " -ForegroundColor Gray
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "Equipo: $env:COMPUTERNAME | $((Get-CimInstance Win32_OperatingSystem).Caption)" -ForegroundColor Gray
Write-Host ""

# =========================================================================================
# FASE 1: PUNTO DE RESTAURACIÓN (única protección permitida)
# =========================================================================================
Write-Host "--- FASE 1: PUNTO DE RESTAURACIÓN ---" -ForegroundColor Cyan
try {
    Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
    $SR = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore"
    if (-not (Test-Path $SR)) { New-Item -Path $SR -Force | Out-Null }
    Set-ItemProperty -Path $SR -Name "SystemRestorePointCreationFrequency" -Value 0 -Type DWord -Force
    Checkpoint-Computer -Description "IOI_PreOptimizacion_$(Get-Date -Format 'yyyyMMdd_HHmm')" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
    Write-Host "[✓] Punto de restauración creado." -ForegroundColor Green
} catch {
    Write-Host "[!] No se pudo crear punto de restauración: $($_.Exception.Message)" -ForegroundColor Yellow
}

# =========================================================================================
# FASE 2: BLINDAJE DE DRIVERS (sin actualizaciones de WU)
# =========================================================================================
Write-Host "`n--- FASE 2: BLINDAJE DE DRIVERS ---" -ForegroundColor Cyan
$WUPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
if (-not (Test-Path $WUPath)) { New-Item -Path $WUPath -Force | Out-Null }
Set-ItemProperty -Path $WUPath -Name "ExcludeWUDriversInQualityUpdate" -Value 1 -Type DWord -Force

$DevicePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"
if (Test-Path $DevicePath) {
    Set-ItemProperty -Path $DevicePath -Name "SearchOrderConfig" -Value 0 -Type DWord -Force
}

$MetadataPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata"
if (-not (Test-Path $MetadataPath)) { New-Item -Path $MetadataPath -Force | Out-Null }
Set-ItemProperty -Path $MetadataPath -Name "PreventDeviceMetadataFromNetwork" -Value 1 -Type DWord -Force
Write-Host "[✓] Drivers blindados contra actualizaciones de WU." -ForegroundColor Green

# =========================================================================================
# FASE 3: ENERGÍA, TÉRMICA Y PAGE FILE
# =========================================================================================
Write-Host "`n--- FASE 3: ENERGÍA Y TÉRMICA ---" -ForegroundColor Cyan

# Plan de Alto Rendimiento
powercfg /setactive SCHEME_MIN | Out-Null

# CPU: mínimo 5%, máximo 100%
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5 | Out-Null
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null

# Desbloquear directiva oculta de boost
$CpuBoostPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\be337238-0d82-4146-a960-4f3749d470c7"
if (Test-Path $CpuBoostPath) {
    Set-ItemProperty -Path $CpuBoostPath -Name "Attributes" -Value 2 -Type DWord -Force
}

# Sin apagado de pantalla / standby / hibernación
powercfg /change monitor-timeout-ac 0 | Out-Null
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null
powercfg /change monitor-timeout-dc 0 | Out-Null
powercfg /change standby-timeout-dc 0 | Out-Null
powercfg /change hibernate-timeout-dc 0 | Out-Null

# Desactivar apagado de discos duros (clave para evitar recuperación de ahorro)
powercfg /setacvalueindex SCHEME_CURRENT SUB_DISK DISKIDLE 0 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT SUB_DISK DISKIDLE 0 | Out-Null

# Desactivar suspensión selectiva de USB y ahorro de energía
powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null

# Concentradores de raíz USB: sin suspensión selectiva
$USBKeys = Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{36fc9e60-c465-11cf-8056-444553540000}" -ErrorAction SilentlyContinue
foreach ($Key in $USBKeys) {
    Set-ItemProperty -Path $Key.PsPath -Name "HcDisableSelectiveSuspend" -Value 1 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $Key.PsPath -Name "EnhancedPowerManagementEnabled" -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $Key.PsPath -Name "AllowIdleIrpInD3" -Value 0 -ErrorAction SilentlyContinue
}

# HAGS
$GraphicsPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
Set-ItemProperty -Path $GraphicsPath -Name "HwSchMode" -Value 2 -Type DWord -Force

# Pagefile: 16 GB / 24 GB
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile -eq $true) {
        Set-CimInstance -InputObject $cs -Property @{AutomaticManagedPagefile = $false} -ErrorAction Stop
    }
    $pf = Get-CimInstance -ClassName Win32_PageFileSetting -Filter "Name='C:\\pagefile.sys'" -ErrorAction SilentlyContinue
    if ($pf) {
        Set-CimInstance -InputObject $pf -Property @{InitialSize = 16384; MaximumSize = 24576} -ErrorAction Stop
    } else {
        New-CimInstance -ClassName Win32_PageFileSetting -Property @{Name = "C:\pagefile.sys"; InitialSize = 16384; MaximumSize = 24576} -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Host "[✓] Pagefile: 16 GB / 24 GB." -ForegroundColor Green
} catch {
    Write-Host "[!] No se pudo ajustar pagefile." -ForegroundColor Yellow
}

powercfg /setactive SCHEME_CURRENT | Out-Null
Write-Host "[✓] Energía, USB, discos y pagefile configurados." -ForegroundColor Green

# =========================================================================================
# FASE 4: AUDIO MMCSS
# =========================================================================================
Write-Host "`n--- FASE 4: AUDIO MMCSS ---" -ForegroundColor Cyan
$AudioTaskPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Audio"
if (-not (Test-Path $AudioTaskPath)) { New-Item -Path $AudioTaskPath -Force | Out-Null }
Set-ItemProperty -Path $AudioTaskPath -Name "Scheduling Category" -Value "High" -Type String -Force
Set-ItemProperty -Path $AudioTaskPath -Name "SFIO Priority" -Value "High" -Type String -Force
Set-ItemProperty -Path $AudioTaskPath -Name "Priority" -Value 6 -Type DWord -Force

$AudioEnginePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Audio"
if (-not (Test-Path $AudioEnginePath)) { New-Item -Path $AudioEnginePath -Force | Out-Null }
Set-ItemProperty -Path $AudioEnginePath -Name "DisableProtectedAudioDG" -Value 1 -Type DWord -Force
Write-Host "[✓] Audio priorizado." -ForegroundColor Green

# =========================================================================================
# FASE 5: PUBLICIDAD, IA Y BING
# =========================================================================================
Write-Host "`n--- FASE 5: PUBLICIDAD, IA Y BING ---" -ForegroundColor Cyan
$ContentPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
if (Test-Path $ContentPath) {
    $props = @{
        "ContentDeliveryAllowed" = 0
        "SubscribedContent-338388Enabled" = 0
        "SubscribedContent-338393Enabled" = 0
        "SubscribedContent-353696Enabled" = 0
        "SystemPaneSuggestionsEnabled" = 0
        "SilentInstalledAppsEnabled" = 0
        "OemPreInstalledAppsEnabled" = 0
        "PreInstalledAppsEnabled" = 0
    }
    foreach ($p in $props.GetEnumerator()) {
        Set-ItemProperty -Path $ContentPath -Name $p.Key -Value $p.Value -Type DWord -Force -ErrorAction SilentlyContinue
    }
}

# IA / Copilot / Recall / Widgets
$CopilotPaths = @(
    "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
)
foreach ($path in $CopilotPaths) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
}

$AIPaths = @(
    "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"
)
foreach ($path in $AIPaths) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name "TurnOffAIDataAnalysis" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $path -Name "AllowRecallEnablement" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
}

Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarDa" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

# CORTANA + BÚSQUEDA WEB (BING) ELIMINADOS
$SearchPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
if (-not (Test-Path $SearchPolicy)) { New-Item -Path $SearchPolicy -Force | Out-Null }
Set-ItemProperty -Path $SearchPolicy -Name "AllowCortana" -Value 0 -Type DWord -Force
Set-ItemProperty -Path $SearchPolicy -Name "AllowSearchToUseLocation" -Value 0 -Type DWord -Force
Set-ItemProperty -Path $SearchPolicy -Name "DisableWebSearch" -Value 1 -Type DWord -Force
Set-ItemProperty -Path $SearchPolicy -Name "ConnectedSearchUseWeb" -Value 0 -Type DWord -Force
Set-ItemProperty -Path $SearchPolicy -Name "ConnectedSearchUseWebOverMetered" -Value 0 -Type DWord -Force
Set-ItemProperty -Path $SearchPolicy -Name "BingSearchEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

Write-Host "[✓] IA, Copilot, Bing y búsqueda web deshabilitados." -ForegroundColor Green

# =========================================================================================
# FASE 6: PURGA DE BLOATWARE
# =========================================================================================
Write-Host "`n--- FASE 6: PURGA DE BLOATWARE ---" -ForegroundColor Cyan
$BloatwareList = @(
    "*WindowsFeedbackHub*", "*MicrosoftFeedbackHub*", "*BingNews*",
    "*MicrosoftSolitaireCollection*", "*MicrosoftStickyNotes*", "*Teams*",
    "*Todos*", "*PowerAutomateDesktop*", "*Outlook*", "*BingWeather*",
    "*WindowsCamera*", "*RemoteAssistance*", "*ZuneVideo*", "*ZuneMusic*",
    "*SoundRecorder*", "*Xbox*", "*GamingServices*", "*OneDrive*",
    "*MicrosoftOfficeHub*", "*Clipchamp*", "*3DBuilder*", "*Getstarted*",
    "*3DViewer*", "*HolographicFirstRun*", "*OneNote*", "*People*",
    "*Print3D*", "*Skype*", "*WindowsAlarms*", "*WindowsMaps*", "*GetHelp*",
    "*Microsoft365Copilot*", "*Widgets*", "*MSPaint*"
)
foreach ($App in $BloatwareList) {
    Get-AppxPackage -AllUsers -Name $App -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object {$_.DisplayName -like $App} | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
}
$OneDriveSetup = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
if (-not (Test-Path $OneDriveSetup)) { $OneDriveSetup = "$env:SystemRoot\System32\OneDriveSetup.exe" }
if (Test-Path $OneDriveSetup) { Start-Process $OneDriveSetup -ArgumentList "/uninstall" -NoNewWindow -Wait -ErrorAction SilentlyContinue }
Write-Host "[✓] Bloatware eliminado (Notas, Recortes, Fotos, Terminal conservados)." -ForegroundColor Green

# =========================================================================================
# FASE 7: DEFENDER REDUCIDO + EDGE MÍNIMO
# =========================================================================================
Write-Host "`n--- FASE 7: DEFENDER REDUCIDO + EDGE MÍNIMO ---" -ForegroundColor Cyan

# Defender: CPU 10%, sin escaneo de archivos, sin scripts, sin catchup
try {
    Set-MpPreference -ScanAvgCPULoadFactor 10 -ErrorAction SilentlyContinue
    Set-MpPreference -DisableArchiveScanning $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableScriptScanning $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableCatchupFullScan $true -ErrorAction SilentlyContinue
    Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction SilentlyContinue

    # Excluir rutas de IOI
    Add-MpPreference -ExclusionPath "D:\Cristian Viera\Setups\III\Tweaks & Txt's\IOI" -ErrorAction SilentlyContinue

    Get-ScheduledTask -TaskPath "\Microsoft\Windows\Windows Defender\" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $s = $_.Settings
            $s.IdleSettings.StopOnIdleEnd = $true
            Set-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Settings $s -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }
    Write-Host "[✓] Defender reducido (protección intacta)." -ForegroundColor Green
} catch { Write-Host "[!] Defender: $($_.Exception.Message)" -ForegroundColor Yellow }

# Edge: mínimo, sin StartupBoost, sin BackgroundMode
$EdgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
if (-not (Test-Path $EdgePolicyPath)) { New-Item -Path $EdgePolicyPath -Force | Out-Null }
$EdgeSettings = @{
    "StartupBoostEnabled" = 0
    "BackgroundModeEnabled" = 0
    "HideFirstRunExperience" = 1
    "PersonalizationReportingEnabled" = 0
    "ShowRecommendationsEnabled" = 0
    "SmartScreenEnabled" = 0
    "SmartScreenPuaEnabled" = 0
}
foreach ($Name in $EdgeSettings.Keys) {
    Set-ItemProperty -Path $EdgePolicyPath -Name $Name -Value $EdgeSettings[$Name] -Type DWord -Force -ErrorAction SilentlyContinue
}

# SmartScreen desactivado en Edge
$EdgeSmart = "HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\PhishingFilter"
if (-not (Test-Path $EdgeSmart)) { New-Item -Path $EdgeSmart -Force | Out-Null }
Set-ItemProperty -Path $EdgeSmart -Name "EnabledV9" -Value 0 -Type DWord -Force
Set-ItemProperty -Path $EdgeSmart -Name "PreventOverride" -Value 1 -Type DWord -Force

# Evitar autoarranque de Edge
$EdgeAutoPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
Remove-ItemProperty -Path $EdgeAutoPath -Name "MicrosoftEdgeAutoLaunch*" -ErrorAction SilentlyContinue

Write-Host "[✓] Edge reducido y SmartScreen desactivado solo en Edge." -ForegroundColor Green

# =========================================================================================
# FASE 8: TELEMETRÍA Y XBOX
# =========================================================================================
Write-Host "`n--- FASE 8: TELEMETRÍA Y XBOX ---" -ForegroundColor Cyan
$ServicesList = @("DiagTrack", "dmwappushservice", "WerSvc", "XblAuthManager", "XblGameSave", "XboxGipSvc", "XboxNetApiSvc")
foreach ($Svc in $ServicesList) {
    if (Get-Service -Name $Svc -ErrorAction SilentlyContinue) {
        Stop-Service -Name $Svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $Svc -StartupType Disabled -ErrorAction SilentlyContinue
    }
}
$DC = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
if (-not (Test-Path $DC)) { New-Item -Path $DC -Force | Out-Null }
Set-ItemProperty -Path $DC -Name "AllowTelemetry" -Value 0 -Type DWord -Force

# Tareas programadas de telemetría
$Tasks = @(
    "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
    "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
    "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "\Microsoft\Windows\Application Experience\StartupAppTask",
    "\Microsoft\Windows\Autochk\Proxy",
    "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
    "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
)
foreach ($Task in $Tasks) {
    $TP = Split-Path $Task -Parent
    $TN = Split-Path $Task -Leaf
    $exists = Get-ScheduledTask -TaskPath "$TP\" -TaskName $TN -ErrorAction SilentlyContinue
    if ($exists) {
        try { Disable-ScheduledTask -TaskPath "$TP\" -TaskName $TN -ErrorAction Stop | Out-Null } catch {
            schtasks /change /tn $Task /disable 2>$null | Out-Null
        }
    }
}
Write-Host "[✓] Telemetría y Xbox deshabilitados." -ForegroundColor Green

# =========================================================================================
# FASE 9: RED TCP/IP + DNS
# =========================================================================================
Write-Host "`n--- FASE 9: RED ---" -ForegroundColor Cyan
ipconfig /flushdns | Out-Null
netsh int ip reset | Out-Null
netsh winsock reset | Out-Null
Set-NetTCPSetting -AutoTuningLevelLocal Normal -ErrorAction SilentlyContinue
netsh int tcp set global heuristics=disabled | Out-Null
netsh int tcp set global timestamps=disabled | Out-Null
netsh int tcp set global autotuninglevel=normal | Out-Null

$DNS4 = @("1.1.1.1", "8.8.8.8")
$DNS6 = @("2606:4700:4700::1111", "2001:4860:4860::8888")
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
    Set-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -ServerAddresses $DNS4 -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -ServerAddresses $DNS6 -ErrorAction SilentlyContinue
}

$Ifaces = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
if (Test-Path $Ifaces) {
    Get-ChildItem -Path $Ifaces -Name | ForEach-Object {
        Set-ItemProperty -Path "$Ifaces\$_" -Name "TcpAckFrequency" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "$Ifaces\$_" -Name "TCPNoDelay" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "$Ifaces\$_" -Name "TcpDelAckTicks" -Value 0 -Type DWord -ErrorAction SilentlyContinue
    }
}

$QoSPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"
if (-not (Test-Path $QoSPath)) { New-Item -Path $QoSPath -Force | Out-Null }
Set-ItemProperty -Path $QoSPath -Name "NonBestEffortLimit" -Value 0 -Type DWord -Force

$Adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
foreach ($Adapter in $Adapters) {
    Set-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName "Green Ethernet" -DisplayValue "Disabled" -ErrorAction SilentlyContinue
    Set-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName "Energy Efficient Ethernet" -DisplayValue "Disabled" -ErrorAction SilentlyContinue
    Set-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName "Flow Control" -DisplayValue "Rx & Tx Enabled" -ErrorAction SilentlyContinue
    Set-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName "IPv4 Checksum Offload" -DisplayValue "Rx & Tx Enabled" -ErrorAction SilentlyContinue
    # NOTA: Se eliminó Set-NetAdapterPowerManagement (falla en algunos adaptadores)
}
Write-Host "[✓] Red configurada." -ForegroundColor Green

# =========================================================================================
# FASE 10: UI — SOLO LO SEGURO (sin tocar transparencias ni efectos visuales)
# =========================================================================================
Write-Host "`n--- FASE 10: UI (respetando transparencias y efectos) ---" -ForegroundColor Cyan

# Menús instantáneos (sin retraso)
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Type String -Force

# Hover del mouse/teclado: sin tiempo de espera
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MouseHoverTime" -Value "0" -Type String -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseHoverTime" -Value "0" -Type String -Force -ErrorAction SilentlyContinue

# Teclado: latencia mínima
Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name "AutoRepeatDelay" -Value "200" -Type String -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name "AutoRepeatRate" -Value "15" -Type String -Force

# Ratón: sin aceleración
Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "0" -Type String -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "0" -Type String -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "0" -Type String -Force

# TIC dinámico: desactivar
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "DragFullWindows" -Value "0" -Type String -Force

# Apagado rápido (tiempos de espera reducidos)
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "AutoEndTasks" -Value "1" -Type String -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WaitToKillAppTimeout" -Value "2000" -Type String -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "HungAppTimeout" -Value "2000" -Type String -Force
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "WaitToKillServiceTimeout" -Value "2000" -Type String -Force

# Resolución de enlaces (DNS/hosts prioritarios)
$ServiceProvPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\ServiceProvider"
if (Test-Path $ServiceProvPath) {
    Set-ItemProperty -Path $ServiceProvPath -Name "LocalPriority" -Value 499 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $ServiceProvPath -Name "HostsPriority" -Value 500 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $ServiceProvPath -Name "DnsPriority" -Value 2000 -Type DWord -ErrorAction SilentlyContinue
}

# Menú contextual clásico (opcional, pero útil)
$ClassicMenu = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
if (-not (Test-Path $ClassicMenu)) { New-Item -Path $ClassicMenu -Force | Out-Null }
Set-ItemProperty -Path $ClassicMenu -Name "(Default)" -Value "" -Type String -Force

# Explorador: sin Inicio ni OneDrive (solo Galería)
$HomeNS = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\DelegateFolders\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"
if (Test-Path $HomeNS) { Remove-Item -Path $HomeNS -Force -ErrorAction SilentlyContinue }

# Flechitas de accesos directos
$ShellIcons = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons"
if (-not (Test-Path $ShellIcons)) { New-Item -Path $ShellIcons -Force | Out-Null }
Set-ItemProperty -Path $ShellIcons -Name "29" -Value "%windir%\System32\shell32.dll,-50" -Type String -Force

# ⚠️ NO SE TOCAN: transparencias, efectos visuales, menuShowDelay en Accesibilidad
Write-Host "[✓] UI configurada (transparencias y efectos visuales INTACTOS)." -ForegroundColor Green

# =========================================================================================
# FASE 11: ACCESIBILIDAD (deshabilitar lo innecesario)
# =========================================================================================
Write-Host "`n--- FASE 11: ACCESIBILIDAD ---" -ForegroundColor Cyan
$Voice = "HKCU:\Software\Microsoft\Speech_OneCore\Preferences"
if (-not (Test-Path $Voice)) { New-Item -Path $Voice -Force | Out-Null }
Set-ItemProperty -Path $Voice -Name "VoiceActivationDefaultOn" -Value 0 -Type DWord -Force

Set-ItemProperty -Path "HKCU:\Software\Microsoft\Input\Settings" -Name "TouchUI" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

$Gaze = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GazeInput"
if (-not (Test-Path $Gaze)) { New-Item -Path $Gaze -Force | Out-Null }
Set-ItemProperty -Path $Gaze -Name "Enabled" -Value 0 -Type DWord -Force

$Braille = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Accessibility\ATs\Braille"
if (Test-Path $Braille) {
    Set-ItemProperty -Path $Braille -Name "StartAT" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
}

$Narrator = "HKCU:\Software\Microsoft\Narrator\NoRoam"
if (-not (Test-Path $Narrator)) { New-Item -Path $Narrator -Force | Out-Null }
Set-ItemProperty -Path $Narrator -Name "RunningState" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

Write-Host "[✓] Accesibilidad deshabilitada." -ForegroundColor Green

# =========================================================================================
# FASE 12: CALIBRACIÓN VISUAL (fondo de pantalla máxima resolución)
# =========================================================================================
Write-Host "`n--- FASE 12: CALIBRACIÓN VISUAL ---" -ForegroundColor Cyan
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "FontSmoothingGamma" -Value 1500 -Type DWord -Force -ErrorAction SilentlyContinue

# Fondo de pantalla: máxima calidad
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallpaperStyle" -Value "10" -Type String -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "TileWallpaper" -Value "0" -Type String -Force -ErrorAction SilentlyContinue

# JPEG 100%
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "JPEGQuality" -Value 100 -Type DWord -Force

# NTFS optimizado
fsutil behavior set disable8dot3 1 | Out-Null
fsutil behavior set disablelastaccess 1 | Out-Null
fsutil behavior set memoryusage 2 | Out-Null

# Prioridad de apps en primer plano
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name "Win32PrioritySeparation" -Value 38 -Type DWord -Force
$SP = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
Set-ItemProperty -Path $SP -Name "SystemResponsiveness" -Value 0 -Type DWord -Force

Write-Host "[✓] Calibración visual aplicada." -ForegroundColor Green
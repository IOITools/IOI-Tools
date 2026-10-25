<#
.SYNOPSIS
    Configuración central de IOI Tools (Edición Pública/Portable)
.DESCRIPTION
    Detecta dinámicamente la ruta raíz para funcionar en cualquier PC.
#>

# =========================================================================================
# DETECCIÓN DINÁMICA DE LA RUTA RAÍZ
# =========================================================================================
$scriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($scriptPath)) { $scriptPath = $PSCommandPath }

$global:IOI_ConfigDir = Split-Path $scriptPath -Parent
$global:IOI_Root      = Split-Path $global:IOI_ConfigDir -Parent

# =========================================================================================
# RUTAS PRINCIPALES
# =========================================================================================
$global:IOI_Scripts      = Join-Path $IOI_Root "Scripts"
$global:IOI_Recursos     = Join-Path $IOI_Root "Recursos"
$global:IOI_Docs         = Join-Path $IOI_Root "Documentacion"

# =========================================================================================
# RECURSOS (Logos relativos)
# =========================================================================================
$global:IOI_LogoHeader   = Join-Path $IOI_Recursos "Iconos\IOI_Header.png"
$global:IOI_LogoNeon     = Join-Path $IOI_Recursos "Iconos\IOI_Neon_Profile.png"
$global:IOI_LogoApp      = Join-Path $IOI_Recursos "Iconos\IOI_Black.ico"
$global:IOI_LogoIconPng  = Join-Path $IOI_Recursos "Iconos\IOI_Tools.png"

# =========================================================================================
# RUTAS DE EJECUCIÓN (Temporales del usuario, NO tocan la raíz)
# =========================================================================================
$global:IOI_ProgramData  = Join-Path $env:TEMP "IOI_Tools"
$global:IOI_RAMWorker    = Join-Path $IOI_ProgramData "IOI_RAM_Worker.ps1"
$global:IOI_RAMCounter   = Join-Path $IOI_ProgramData "ram_counter.txt"
$global:IOI_RAMLog       = Join-Path $IOI_ProgramData "ram_log.txt"

# =========================================================================================
# PREFERENCIAS
# =========================================================================================
$global:IOI_TemaColor      = "Green"
$global:IOI_Idioma         = "es-MX"
$global:IOI_Notificaciones = $true

# =========================================================================================
# VERIFICACIÓN DE ESTRUCTURA
# =========================================================================================
function Test-IOIEstructura {
    $rutasCriticas = @($IOI_Root, $IOI_Scripts, $IOI_ConfigDir, $IOI_Recursos)
    $faltantes = @()
    foreach ($ruta in $rutasCriticas) {
        if (-not (Test-Path $ruta)) { $faltantes += $ruta }
    }
    if ($faltantes.Count -gt 0) {
        Write-Host "⚠ Faltan carpetas del ecosistema IOI:" -ForegroundColor Yellow
        $faltantes | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
        return $false
    }
    return $true
}
<#
.SYNOPSIS
    IOI QuitarFlechitas v2 - Elimina el overlay de accesos directos.
.DESCRIPTION
    Modifica el registro para apuntar el overlay 29 (acceso directo) a un ícono
    transparente (shell32.dll,-50). Reinicia Explorer para aplicar el cambio.
    Carga la configuración central de IOI.
.NOTES
    Autor: IOI
    Versión: 2.0
#>

#region AUTO-ELEVACIÓN
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "⏫ Solicitando permisos de Administrador..." -ForegroundColor Yellow
    $PwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $PwshPath) { $PwshPath = "powershell.exe" }
    Start-Process $PwshPath -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
Set-ExecutionPolicy Bypass -Scope Process -Force | Out-Null
#endregion

#region CARGA DE CONFIGURACIÓN CENTRAL
$IOI_Config = "D:\Cristian Viera\Setups\III\Tweaks & Txt's\IOI\Config\IOI_Config.ps1"
if (-not (Test-Path $IOI_Config)) {
    Write-Host "❌ No se encontró IOI_Config.ps1 en la ruta esperada." -ForegroundColor Red
    Write-Host "   Ruta: $IOI_Config" -ForegroundColor Gray
    Read-Host "Presiona Enter para salir"
    exit 1
}
. $IOI_Config
if (-not (Test-IOIEstructura)) {
    Write-Host "❌ Estructura IOI incompleta." -ForegroundColor Red
    Read-Host "Presiona Enter para salir"
    exit 1
}
#endregion

Clear-Host
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   IOI QUITARFLECHITAS v2 - SIN FLECHITAS EN ACCESOS DIRECTOS   " -ForegroundColor Magenta
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "Root IOI: $IOI_Root" -ForegroundColor Gray
Write-Host ""

# =========================================================================================
# APLICAR EL CAMBIO
# =========================================================================================
Write-Host "--- APLICANDO CAMBIO ---" -ForegroundColor Cyan
try {
    $ShellIcons = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons"
    if (-not (Test-Path $ShellIcons)) {
        New-Item -Path $ShellIcons -Force | Out-Null
        Write-Host "[+] Clave 'Shell Icons' creada." -ForegroundColor Green
    }
    Set-ItemProperty -Path $ShellIcons -Name "29" -Value "%windir%\System32\shell32.dll,-50" -Type String -Force
    Write-Host "[✓] Overlay 29 apuntado a ícono transparente." -ForegroundColor Green
} catch {
    Write-Host "[!] Error: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Presiona Enter para salir"
    exit 1
}

# =========================================================================================
# REINICIAR EXPLORER
# =========================================================================================
Write-Host "`n--- REINICIANDO EXPLORER ---" -ForegroundColor Yellow
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Host "[✓] Explorer reiniciado." -ForegroundColor Green

# =========================================================================================
# VERIFICACIÓN
# =========================================================================================
Write-Host "`n--- VERIFICACIÓN ---" -ForegroundColor Cyan
$check = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons" -Name "29" -ErrorAction SilentlyContinue
if ($check."29" -eq "%windir%\System32\shell32.dll,-50") {
    Write-Host "[✓] Overlay 29 confirmado en el registro." -ForegroundColor Green
} else {
    Write-Host "[✗] No se pudo confirmar el cambio." -ForegroundColor Red
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host " ✅ FLECHITAS ELIMINADAS                                        " -ForegroundColor Green
Write-Host "    Si algún ícono sigue mostrando flechita, reinicia el PC.   " -ForegroundColor Yellow
Write-Host "=================================================================" -ForegroundColor Green
Write-Host ""
Read-Host "Presiona Enter para cerrar"
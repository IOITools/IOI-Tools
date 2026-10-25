<#
.SYNOPSIS
    IOI BORN v2 - Creación del perfil IOI y bypass OOBE
.DESCRIPTION
    Fase 1 del despliegue IOI en Windows limpio:
    - Verifica que esté corriendo como Administrador.
    - Carga la configuración central del ecosistema IOI.
    - Registra el bypass de OOBE (para futuras instalaciones).
    - Crea la cuenta local IOI con privilegios de Administrador.
    - Verifica y reporta el estado final.
.NOTES
    Autor: IOI
    Versión: 2.0
    Requiere: Administrador
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
    Write-Host "❌ Estructura IOI incompleta. Revisa las carpetas faltantes arriba." -ForegroundColor Red
    Read-Host "Presiona Enter para salir"
    exit 1
}
#endregion

Clear-Host
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "        🧬 IOI BORN v2 - DESPLIEGUE DE PERFIL PRINCIPAL        " -ForegroundColor Magenta
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "Equipo: $env:COMPUTERNAME | $((Get-CimInstance Win32_OperatingSystem).Caption)" -ForegroundColor Gray
Write-Host "Root IOI: $IOI_Root" -ForegroundColor Gray
Write-Host ""

# =========================================================================================
# PASO 1: BYPASS OOBE (WINDOWS 11 24H2+)
# =========================================================================================
Write-Host "--- PASO 1: REGISTRANDO BYPASS OOBE ---" -ForegroundColor Cyan
$OOBEKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"
if (-not (Test-Path $OOBEKey)) { New-Item -Path $OOBEKey -Force | Out-Null }
Set-ItemProperty -Path $OOBEKey -Name "BypassNRO" -Value 1 -Type DWord -Force
Write-Host "[✓] BypassNRO registrado (para futuras instalaciones limpias)." -ForegroundColor Green

# =========================================================================================
# PASO 2: CREAR USUARIO IOI
# =========================================================================================
Write-Host "`n--- PASO 2: CREANDO USUARIO IOI ---" -ForegroundColor Cyan
if (-not (Get-LocalUser -Name "IOI" -ErrorAction SilentlyContinue)) {
    Write-Host "[+] Creando cuenta local IOI..." -ForegroundColor Gray
    $Password = ConvertTo-SecureString "IOI_Temp_2026" -AsPlainText -Force
    New-LocalUser -Name "IOI" -Password $Password -Description "Cuenta Administrador Principal IOI" -PasswordNeverExpires $true | Out-Null
    Write-Host "   [✓] Usuario 'IOI' creado." -ForegroundColor Green
    Write-Host "   [i] Contraseña temporal: IOI_Temp_2026" -ForegroundColor Yellow
    Write-Host "       Cámbiala desde Configuración > Cuentas tras el primer login." -ForegroundColor DarkGray
} else {
    Write-Host "[i] El usuario IOI ya existe. Saltando creación." -ForegroundColor DarkGray
}

# =========================================================================================
# PASO 3: AÑADIR A ADMINISTRADORES (MULTI-IDIOMA)
# =========================================================================================
Write-Host "`n--- PASO 3: PRIVILEGIOS DE ADMINISTRADOR ---" -ForegroundColor Cyan
$adminGroup = if (Get-LocalGroup -Name "Administradores" -ErrorAction SilentlyContinue) { "Administradores" }
              elseif (Get-LocalGroup -Name "Administrators" -ErrorAction SilentlyContinue) { "Administrators" }
              else { $null }

if ($adminGroup) {
    $yaEsAdmin = Get-LocalGroupMember -Group $adminGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\IOI" }
    if (-not $yaEsAdmin) {
        Add-LocalGroupMember -Group $adminGroup -Member "IOI" -ErrorAction SilentlyContinue
        Write-Host "[✓] IOI añadido al grupo '$adminGroup'." -ForegroundColor Green
    } else {
        Write-Host "[i] IOI ya es miembro de '$adminGroup'." -ForegroundColor DarkGray
    }
} else {
    Write-Host "[!] No se encontró el grupo de Administradores." -ForegroundColor Yellow
}

# =========================================================================================
# PASO 4: VERIFICACIÓN FINAL
# =========================================================================================
Write-Host "`n--- PASO 4: VERIFICACIÓN FINAL ---" -ForegroundColor Cyan
$usuario = Get-LocalUser -Name "IOI" -ErrorAction SilentlyContinue
if ($usuario) {
    Write-Host "[✓] Usuario: $($usuario.Name)" -ForegroundColor Green
    Write-Host "    Habilitado: $($usuario.Enabled)" -ForegroundColor Gray
    Write-Host "    Creado: $($usuario.PasswordLastSet)" -ForegroundColor Gray
} else {
    Write-Host "[✗] El usuario IOI NO existe." -ForegroundColor Red
}

if ($adminGroup) {
    $esAdmin = Get-LocalGroupMember -Group $adminGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\IOI" }
    if ($esAdmin) {
        Write-Host "[✓] Pertenece a: $adminGroup" -ForegroundColor Green
    } else {
        Write-Host "[✗] NO pertenece al grupo de Administradores." -ForegroundColor Red
    }
}

# =========================================================================================
# FINAL
# =========================================================================================
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host " ✅ IOI BORN v2 COMPLETADO                                     " -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "📋 SIGUIENTE PASO:" -ForegroundColor Cyan
Write-Host "  1. Cierra sesión del usuario actual." -ForegroundColor Gray
Write-Host "  2. Inicia sesión con el usuario 'IOI' (contraseña: IOI_Temp_2026)." -ForegroundColor Gray
Write-Host "  3. Cambia la contraseña desde Configuración > Cuentas." -ForegroundColor Gray
Write-Host "  4. Elimina el perfil genérico anterior con 'netplwiz' si aún existe." -ForegroundColor Gray
Write-Host "  5. Continúa con la instalación de drivers." -ForegroundColor Gray
Write-Host ""
Read-Host "Presiona Enter para finalizar"
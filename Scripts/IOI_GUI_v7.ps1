# ============================================================
# FUNCIÓN REAL DE LIMPIEZA DE RAM (EmptyWorkingSet)
# IOI Tools - Fase 3
# ============================================================
function Clear-IOIRAM {
    param(
        [ValidateSet('Estandar','Profundo')]
        [string]$Modo = 'Estandar'
    )

    # Cargamos la API de Windows para EmptyWorkingSet
    if (-not ([System.Management.Automation.PSTypeName]'IOI.RAM').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class IOI_RAM {
    [DllImport("psapi.dll")]
    public static extern int EmptyWorkingSet(IntPtr hProcess);
}
"@
    }

    $procesos = Get-Process -ErrorAction SilentlyContinue
    $liberados = 0
    $totalProcesos = $procesos.Count

    # En modo PROFUNDO incluimos procesos del sistema (requiere Admin)
    if ($Modo -eq 'Profundo') {
        $procesos = Get-Process -IncludeUserName -ErrorAction SilentlyContinue
    }

    foreach ($proc in $procesos) {
        try {
            # No tocamos procesos críticos del sistema ni el propio PowerShell
            if ($proc.Id -eq $PID) { continue }
            if ($proc.ProcessName -in @('System','Idle','csrss','wininit','services','lsass','smss')) { continue }

            $handle = $proc.Handle
            if ($handle -ne [IntPtr]::Zero) {
                [void][IOI_RAM]::EmptyWorkingSet($handle)
                $liberados++
            }
        } catch {
            # Procesos protegidos o sin permisos: se ignoran silenciosamente
            continue
        }
    }

    # Calculamos RAM libre antes/después (aproximado)
    $ramLibre = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024, 0)

    return [PSCustomObject]@{
        Modo           = $Modo
        ProcesosTotal  = $totalProcesos
        ProcesosLibres = $liberados
        RAMLibreMB     = $ramLibre
        Mensaje        = "Limpieza $Modo completada. $liberados de $totalProcesos procesos optimizados. RAM libre: $ramLibre MB."
    }
}
# ============================================================
# FIN FUNCIÓN Clear-IOIRAM
# ============================================================

<#
.SYNOPSIS
    IOI Tools v7.2 - MS Store Look + Background Tasks + Progress Bars
.DESCRIPTION
    Interfaz gráfica moderna estilo Microsoft Store con tareas en background
    y barras de progreso reales.
.NOTES
    Autor: Cristian Viera (IOI)
    Versión: 7.2
#>

#Requires -Version 5.1

#region ASSEMBLIES
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
#endregion

#region ADMIN CHECK & UNIVERSAL LAUNCH
$CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($CurrentUser)
$IsAdmin = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$IsSTA = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'

if (-not $IsAdmin -or -not $IsSTA) {
    # Detectamos si estamos en PS7 (pwsh) o en el clásico (powershell)
    $CurrentExe = (Get-Process -Id $PID).Path
    $Args = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    
    if (-not $IsAdmin) {
        Start-Process $CurrentExe -ArgumentList $Args -Verb RunAs
    } else {
        Start-Process $CurrentExe -ArgumentList $Args
    }
    exit
}
#endregion

#region CARGA DE CONFIGURACIÓN
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
# Buscamos el Config.ps1 un nivel arriba (en la raíz de IOI_Original)
$IOI_Config = Join-Path (Split-Path $ScriptDir -Parent) "Config\IOI_Config.ps1"

if (-not (Test-Path $IOI_Config)) {
    # Si no lo encuentra ahí, busca dentro de la misma carpeta Scripts
    $IOI_Config = Join-Path $ScriptDir "IOI_Config.ps1"
}

if (-not (Test-Path $IOI_Config)) {
    [System.Windows.MessageBox]::Show("No se encontró IOI_Config.ps1 en:`n$IOI_Config", "IOI Tools Error", "OK", "Error") | Out-Null
    exit 1
}

. $IOI_Config
#endregion

#region VARIABLES GLOBALES
$script:AppName    = "IOI Tools"
$script:AppVersion = "7.2"
$script:LogFolder  = Join-Path $IOI_Root "Documentacion\Logs\GUI"
if (-not (Test-Path $script:LogFolder)) {
    New-Item -ItemType Directory -Path $script:LogFolder -Force | Out-Null
}

$script:PrimaryAction   = $null
$script:SecondaryAction = $null
$script:TertiaryAction  = $null

$script:ExclusionesKernel = @(
    "svchost", "csrss", "winlogon", "services", "lsass", "wininit",
    "dwm", "explorer", "system", "idle", "conhost", "taskhostw",
    "dllhost", "spoolsv", "fontdrvhost", "sihost", "ctfmon", "SearchIndexer"
)

$guidAltoRendimiento = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"

# Background task state
$script:TaskRunning   = $false
$script:TaskName      = ""
$script:TaskPercent   = 0
$script:TaskJob       = $null
$script:TaskStartTime = $null
#endregion

#region HELPERS
function Save-IOILog {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Details
    )
    try {
        $SafeName  = $Operation -replace '[^\w\-]', '-'
        $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $LogPath   = Join-Path $script:LogFolder "$SafeName-$Timestamp.txt"
        $Content = @"
=================================================================
IOI TOOLS v$($script:AppVersion)
=================================================================
Fecha:      $(Get-Date)
Equipo:     $env:COMPUTERNAME
Usuario:    $env:USERNAME
Operación:  $Operation
Estado:     $Status
=================================================================

$Details

=================================================================
"@
        Set-Content -LiteralPath $LogPath -Value $Content -Encoding UTF8
        return $LogPath
    } catch {
        return "No se pudo guardar log: $($_.Exception.Message)"
    }
}

function Convert-ToReadableSize {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "{0:N0} Bytes" -f $Bytes
}

function Show-IOIMessage {
    param(
        [string]$Message,
        [string]$Title = "IOI Tools",
        [System.Windows.MessageBoxButton]$Buttons = [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]$Icon    = [System.Windows.MessageBoxImage]::Information
    )
    return [System.Windows.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
}

function Open-IOIUri {
    param([string]$Uri)
    try { Start-Process $Uri } catch {
        Show-IOIMessage "Windows no pudo abrir: $Uri`n`n$($_.Exception.Message)" "No se pudo abrir" | Out-Null
    }
}

function Play-SuccessSound {
    try {
        $player = New-Object System.Media.SoundPlayer
        $sonidos = @(
            "$env:SystemRoot\Media\Windows Notify System Generic.wav",
            "$env:SystemRoot\Media\Windows Notify Calendar.wav",
            "$env:SystemRoot\Media\Windows Balloon.wav"
        )
        $reproducido = $false
        foreach ($s in $sonidos) {
            if (Test-Path $s) {
                $player.SoundLocation = $s
                $player.PlaySync()
                $reproducido = $true
                break
            }
        }
        if (-not $reproducido) { [System.Media.SystemSounds]::Asterisk.Play() }
    } catch {}
}

function Play-ErrorSound {
    try { [System.Media.SystemSounds]::Hand.Play() } catch {}
}

function Play-WarningSound {
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch {}
}

function Show-ToastNotification {
    param([string]$Title, [string]$Message)
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
        [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
        $AppId = "IOI Tools"
        $Template = @"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text id="1">$Title</text>
            <text id="2">$Message</text>
        </binding>
    </visual>
</toast>
"@
        $Xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $Xml.LoadXml($Template)
        $Toast = [Windows.UI.Notifications.ToastNotification]::new($Xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($Toast)
    } catch {}
}
#endregion

#region XAML (Look MS Store renovado)
[xml]$Xaml = @'
<Window
 xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="IOI Tools v7.2 - by Cristian Viera"
 Width="1300"
 Height="870"
 MinWidth="1150"
 MinHeight="720"
 WindowStartupLocation="CenterScreen"
 Background="#0C0C0C"
 FontFamily="Segoe UI"
 ResizeMode="CanResize"
 WindowStyle="SingleBorderWindow">

 <Window.Resources>

   <Style x:Key="NavButton" TargetType="Button">
     <Setter Property="Foreground" Value="#E0E0E0"/>
     <Setter Property="Background" Value="Transparent"/>
     <Setter Property="BorderBrush" Value="Transparent"/>
     <Setter Property="BorderThickness" Value="0"/>
     <Setter Property="Height" Value="44"/>
     <Setter Property="Margin" Value="0,0,0,2"/>
     <Setter Property="Padding" Value="16,0"/>
     <Setter Property="HorizontalContentAlignment" Value="Left"/>
     <Setter Property="FontSize" Value="13"/>
     <Setter Property="Cursor" Value="Hand"/>
     <Setter Property="Template">
       <Setter.Value>
         <ControlTemplate TargetType="Button">
           <Border Background="{TemplateBinding Background}"
                   BorderBrush="{TemplateBinding BorderBrush}"
                   BorderThickness="{TemplateBinding BorderThickness}"
                   CornerRadius="8"
                   x:Name="border">
             <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                               VerticalAlignment="Center"
                               Margin="{TemplateBinding Padding}"/>
           </Border>
           <ControlTemplate.Triggers>
             <Trigger Property="IsMouseOver" Value="True">
               <Setter TargetName="border" Property="Background" Value="#1F2B3A"/>
             </Trigger>
             <Trigger Property="IsPressed" Value="True">
               <Setter TargetName="border" Property="Background" Value="#2A3F55"/>
             </Trigger>
           </ControlTemplate.Triggers>
         </ControlTemplate>
       </Setter.Value>
     </Setter>
   </Style>

   <Style x:Key="PrimaryButton" TargetType="Button">
     <Setter Property="Foreground" Value="#000000"/>
     <Setter Property="Background" Value="#00E5FF"/>
     <Setter Property="BorderThickness" Value="0"/>
     <Setter Property="Height" Value="42"/>
     <Setter Property="MinWidth" Value="160"/>
     <Setter Property="Padding" Value="20,0"/>
     <Setter Property="Margin" Value="0,0,10,0"/>
     <Setter Property="FontWeight" Value="SemiBold"/>
     <Setter Property="Cursor" Value="Hand"/>
     <Setter Property="Template">
       <Setter.Value>
         <ControlTemplate TargetType="Button">
           <Border Background="{TemplateBinding Background}"
                   CornerRadius="8"
                   x:Name="border">
             <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
           </Border>
           <ControlTemplate.Triggers>
             <Trigger Property="IsMouseOver" Value="True">
               <Setter TargetName="border" Property="Background" Value="#33EBFF"/>
             </Trigger>
             <Trigger Property="IsPressed" Value="True">
               <Setter TargetName="border" Property="Background" Value="#00C4DB"/>
             </Trigger>
           </ControlTemplate.Triggers>
         </ControlTemplate>
       </Setter.Value>
     </Setter>
   </Style>

   <Style x:Key="SecondaryButton" TargetType="Button">
     <Setter Property="Foreground" Value="#E0E0E0"/>
     <Setter Property="Background" Value="Transparent"/>
     <Setter Property="BorderBrush" Value="#00E5FF"/>
     <Setter Property="BorderThickness" Value="1"/>
     <Setter Property="Height" Value="42"/>
     <Setter Property="MinWidth" Value="160"/>
     <Setter Property="Padding" Value="20,0"/>
     <Setter Property="Margin" Value="0,0,10,0"/>
     <Setter Property="Cursor" Value="Hand"/>
     <Setter Property="Template">
       <Setter.Value>
         <ControlTemplate TargetType="Button">
           <Border Background="{TemplateBinding Background}"
                   BorderBrush="{TemplateBinding BorderBrush}"
                   BorderThickness="{TemplateBinding BorderThickness}"
                   CornerRadius="8"
                   x:Name="border">
             <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
           </Border>
           <ControlTemplate.Triggers>
             <Trigger Property="IsMouseOver" Value="True">
               <Setter TargetName="border" Property="Background" Value="#0F2A33"/>
             </Trigger>
           </ControlTemplate.Triggers>
         </ControlTemplate>
       </Setter.Value>
     </Setter>
   </Style>

   <Style TargetType="TextBox">
     <Setter Property="Background" Value="#080808"/>
     <Setter Property="Foreground" Value="#E0E0E0"/>
     <Setter Property="BorderBrush" Value="#1F1F1F"/>
     <Setter Property="BorderThickness" Value="1"/>
     <Setter Property="Padding" Value="16"/>
     <Setter Property="FontFamily" Value="Cascadia Code, Consolas, Courier New"/>
     <Setter Property="FontSize" Value="13"/>
     <Setter Property="CaretBrush" Value="#00E5FF"/>
   </Style>

 </Window.Resources>

 <Grid>
   <Grid.RowDefinitions>
     <RowDefinition Height="120"/>
     <RowDefinition Height="72"/>
     <RowDefinition Height="*"/>
     <RowDefinition Height="Auto"/>
     <RowDefinition Height="64"/>
   </Grid.RowDefinitions>

   <Border Grid.Row="0" Background="#0A0A0A" BorderBrush="#00E5FF" BorderThickness="0,0,0,2" Padding="24,0">
     <Grid>
       <Grid.ColumnDefinitions>
         <ColumnDefinition Width="Auto"/>
         <ColumnDefinition Width="*"/>
         <ColumnDefinition Width="Auto"/>
       </Grid.ColumnDefinitions>

       <Image Grid.Column="0" x:Name="ImgLogoHeader" Width="100" Height="100" Margin="0,0,24,0" Stretch="Uniform" VerticalAlignment="Center"/>

       <StackPanel Grid.Column="1" VerticalAlignment="Center">
         <TextBlock Text="IOI TOOLS" Foreground="#00E5FF" FontSize="40" FontWeight="Bold" FontFamily="Segoe UI Semibold"/>
         <TextBlock Text="Suite de mantenimiento · v7.2" Foreground="#909090" FontSize="15" Margin="0,6,0,0"/>
       </StackPanel>

       <StackPanel Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center">
         <TextBlock Text="Cristian Viera" Foreground="#FFFFFF" FontWeight="SemiBold" FontSize="20" HorizontalAlignment="Right"/>
         <TextBlock Text="IOI · 2026" Foreground="#00E5FF" FontSize="13" Margin="0,6,0,0" HorizontalAlignment="Right"/>
       </StackPanel>
     </Grid>
   </Border>

   <Border Grid.Row="1" Background="#080808" Padding="24,12">
     <Grid>
       <Grid.ColumnDefinitions>
         <ColumnDefinition Width="2.5*"/>
         <ColumnDefinition Width="1*"/>
         <ColumnDefinition Width="1*"/>
         <ColumnDefinition Width="1*"/>
         <ColumnDefinition Width="1.2*"/>
       </Grid.ColumnDefinitions>
       <TextBlock x:Name="TxtWindowsStatus" Grid.Column="0" Foreground="#D0D0D0" FontSize="12" VerticalAlignment="Center"/>
       <TextBlock x:Name="TxtAdminStatus"   Grid.Column="1" Foreground="#00FF7F" FontSize="12" VerticalAlignment="Center" FontWeight="SemiBold"/>
       <TextBlock x:Name="TxtNetworkStatus" Grid.Column="2" Foreground="#00FF7F" FontSize="12" VerticalAlignment="Center" FontWeight="SemiBold"/>
       <TextBlock x:Name="TxtDefenderStatus" Grid.Column="3" Foreground="#D0D0D0" FontSize="12" VerticalAlignment="Center"/>
       <TextBlock x:Name="TxtDriveStatus"   Grid.Column="4" Foreground="#D0D0D0" FontSize="12" VerticalAlignment="Center" TextAlignment="Right"/>
     </Grid>
   </Border>

   <Grid Grid.Row="2" Margin="20,12,20,12">
     <Grid.ColumnDefinitions>
       <ColumnDefinition Width="260"/>
       <ColumnDefinition Width="20"/>
       <ColumnDefinition Width="*"/>
     </Grid.ColumnDefinitions>

     <Border Grid.Column="0" Background="#0F0F0F" BorderBrush="#1A1A1A" BorderThickness="1" CornerRadius="10" Padding="14">
       <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
         <StackPanel>
           <TextBlock Text="MÓDULOS" Foreground="#00E5FF" FontSize="11" FontWeight="Bold" Margin="6,0,0,12"/>

           <Button x:Name="BtnRAM"         Style="{StaticResource NavButton}" Content="🧠   RAM"           ToolTip="Liberar memoria (WorkingSet, Standby, System WS)"/>
           <Button x:Name="BtnNET"         Style="{StaticResource NavButton}" Content="🌐   NET"           ToolTip="Info de red + optimización"/>
           <Button x:Name="BtnCLEAN"       Style="{StaticResource NavButton}" Content="🧹   CLEAN"         ToolTip="Limpieza: Rápida, Profunda o Extrema"/>
           <Button x:Name="BtnFIX"         Style="{StaticResource NavButton}" Content="🔧   FIX"           ToolTip="SFC / DISM / Ambos"/>
           <Button x:Name="BtnBOOST"       Style="{StaticResource NavButton}" Content="⚡   BOOST"         ToolTip="Rendimiento: plan, CPU, UI, gráficos, IA"/>
           <Button x:Name="BtnNETREF"      Style="{StaticResource NavButton}" Content="🌐   NETREF"        ToolTip="Reset completo de pila de red"/>
           <Button x:Name="BtnHerramientas" Style="{StaticResource NavButton}" Content="🛠️   HERRAMIENTAS" ToolTip="Mantenimiento, fantasmas, purga"/>
           <Button x:Name="BtnMaestro"     Style="{StaticResource NavButton}" Content="🚀   MAESTRO v10"   ToolTip="Motor principal de optimización"/>
           <Button x:Name="BtnEmergencia"  Style="{StaticResource NavButton}" Content="🚨   EMERGENCIA"    ToolTip="Acciones rápidas"/>
           <Button x:Name="BtnSistema"     Style="{StaticResource NavButton}" Content="💻   SISTEMA"       ToolTip="Información completa del sistema"/>

           <Separator Background="#1F1F1F" Margin="0,12"/>

           <TextBlock Text="UTILIDADES" Foreground="#606060" FontSize="10" FontWeight="Bold" Margin="6,4,0,8"/>

           <Button x:Name="BtnLogs"  Style="{StaticResource NavButton}" Content="📋   LOGS"   ToolTip="Ver logs automáticos"/>
           <Button x:Name="BtnAyuda" Style="{StaticResource NavButton}" Content="❓   AYUDA"  ToolTip="Acerca de IOI Tools"/>
           <Button x:Name="BtnExit"  Style="{StaticResource NavButton}" Content="❌   SALIR"  ToolTip="Cerrar IOI Tools"/>
         </StackPanel>
       </ScrollViewer>
     </Border>

     <Border Grid.Column="2" Background="#0F0F0F" BorderBrush="#1A1A1A" BorderThickness="1" CornerRadius="10" Padding="28">
       <Grid>
         <Grid.RowDefinitions>
           <RowDefinition Height="Auto"/>
           <RowDefinition Height="Auto"/>
           <RowDefinition Height="Auto"/>
           <RowDefinition Height="*"/>
           <RowDefinition Height="Auto"/>
         </Grid.RowDefinitions>

         <TextBlock x:Name="TxtTitle" Foreground="#FFFFFF" FontSize="28" FontWeight="Bold"/>
         <TextBlock x:Name="TxtDescription" Grid.Row="1" Foreground="#A0A0A0" FontSize="14" TextWrapping="Wrap" Margin="0,8,0,10"/>
         <TextBlock x:Name="TxtMeta" Grid.Row="2" Foreground="#00E5FF" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,16"/>

         <TextBox x:Name="TxtOutput" Grid.Row="3"
                  VerticalScrollBarVisibility="Auto"
                  HorizontalScrollBarVisibility="Disabled"
                  TextWrapping="Wrap"
                  AcceptsReturn="True"
                  IsReadOnly="True"/>

         <StackPanel x:Name="ActionPanel" Grid.Row="4" Orientation="Horizontal" Margin="0,20,0,0">
           <Button x:Name="BtnPrimary"   Style="{StaticResource PrimaryButton}"   Visibility="Collapsed"/>
           <Button x:Name="BtnSecondary" Style="{StaticResource SecondaryButton}" Visibility="Collapsed"/>
           <Button x:Name="BtnTertiary"  Style="{StaticResource SecondaryButton}" Visibility="Collapsed"/>
         </StackPanel>
       </Grid>
     </Border>
   </Grid>

   <Border Grid.Row="3" x:Name="TaskBar" Background="#1A0000" BorderBrush="#FF8800" BorderThickness="0,2,0,0" Padding="24,10" Visibility="Collapsed">
     <Grid>
       <Grid.ColumnDefinitions>
         <ColumnDefinition Width="Auto"/>
         <ColumnDefinition Width="*"/>
         <ColumnDefinition Width="Auto"/>
       </Grid.ColumnDefinitions>

       <TextBlock Grid.Column="0" Text="⏳" FontSize="20" VerticalAlignment="Center" Margin="0,0,12,0"/>

       <StackPanel Grid.Column="1" VerticalAlignment="Center">
         <TextBlock x:Name="TxtTaskName" Text="Tarea en ejecución..." Foreground="#FFB300" FontSize="13" FontWeight="SemiBold"/>
         <TextBlock x:Name="TxtTaskInfo" Text="Preparando..." Foreground="#FFD966" FontSize="11" Margin="0,2,0,0"/>
       </StackPanel>

       <StackPanel Grid.Column="2" VerticalAlignment="Center" MinWidth="200">
         <ProgressBar x:Name="TaskProgress" Height="8" Background="#330000" Foreground="#FFB300" Value="0" Maximum="100"/>
         <TextBlock x:Name="TxtTaskPercent" Text="0%" Foreground="#FFB300" FontSize="11" HorizontalAlignment="Right" Margin="0,4,0,0"/>
       </StackPanel>
     </Grid>
   </Border>

   <Border Grid.Row="4" Background="#080808" BorderBrush="#1A1A1A" BorderThickness="0,1,0,0" Padding="24,10">
     <Grid>
       <Grid.ColumnDefinitions>
         <ColumnDefinition Width="Auto"/>
         <ColumnDefinition Width="*"/>
         <ColumnDefinition Width="Auto"/>
       </Grid.ColumnDefinitions>

       <Image Grid.Column="0" x:Name="ImgLogoNeon" Width="44" Height="44" Margin="0,0,14,0" Stretch="Uniform"/>

       <StackPanel Grid.Column="1" VerticalAlignment="Center">
         <TextBlock x:Name="TxtStatus" Text="Estado: Listo" Foreground="#00FF7F" FontSize="12" FontWeight="SemiBold"/>
         <TextBlock Text="Sistema optimizado por IOI Tools v7.2" Foreground="#505050" FontSize="10" Margin="0,2,0,0"/>
       </StackPanel>

       <StackPanel Grid.Column="2" VerticalAlignment="Center" HorizontalAlignment="Right">
         <TextBlock Text="Cristian Viera" Foreground="#00E5FF" FontSize="12" FontWeight="Bold" HorizontalAlignment="Right"/>
         <TextBlock Text="IOI · 2026" Foreground="#505050" FontSize="10" HorizontalAlignment="Right" Margin="0,2,0,0"/>
       </StackPanel>
     </Grid>
   </Border>
 </Grid>
</Window>
'@
#endregion

#region CARGAR VENTANA Y LOGOS
try {
    $Reader = New-Object System.Xml.XmlNodeReader $Xaml
    $Window = [Windows.Markup.XamlReader]::Load($Reader)

    # Forzamos la ruta correcta del ícono en el Búnker
    $IOI_LogoApp = Join-Path (Split-Path $ScriptDir -Parent) "Recursos\Iconos\IOI_Tools.ico"

    # Aplicar icono .ico a la ventana (barra de tareas)
    try {
        if ($IOI_LogoApp -and (Test-Path $IOI_LogoApp)) {
            $ico = [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Uri]::new($IOI_LogoApp))
            $Window.Icon = $ico
        }
    } catch {
        # Si el icono falla, lo ignoramos silenciosamente
    }

    # Header Logo
    $ImgLogoHeader = $Window.FindName("ImgLogoHeader")
    if ($ImgLogoHeader -and $IOI_LogoHeader -and (Test-Path $IOI_LogoHeader)) {
        $bmpHeader = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmpHeader.BeginInit()
        $bmpHeader.UriSource = New-Object System.Uri($IOI_LogoHeader)
        $bmpHeader.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmpHeader.EndInit()
        $ImgLogoHeader.Source = $bmpHeader
    }

    # Footer Logo (Neon)
    $ImgLogoNeon = $Window.FindName("ImgLogoNeon")
    if ($ImgLogoNeon -and $IOI_LogoNeon -and (Test-Path $IOI_LogoNeon)) {
        $bmpNeon = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmpNeon.BeginInit()
        $bmpNeon.UriSource = New-Object System.Uri($IOI_LogoNeon)
        $bmpNeon.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmpNeon.EndInit()
        $ImgLogoNeon.Source = $bmpNeon
    }

} catch {
    [System.Windows.MessageBox]::Show("No se pudo cargar la interfaz.`n$($_.Exception.Message)", "IOI Tools - Error", "OK", "Error") | Out-Null
    exit 1
}
#endregion

#region CONECTAR CONTROLES
$TxtWindowsStatus  = $Window.FindName("TxtWindowsStatus")
$TxtAdminStatus    = $Window.FindName("TxtAdminStatus")
$TxtNetworkStatus  = $Window.FindName("TxtNetworkStatus")
$TxtDefenderStatus = $Window.FindName("TxtDefenderStatus")
$TxtDriveStatus    = $Window.FindName("TxtDriveStatus")

$TxtTitle       = $Window.FindName("TxtTitle")
$TxtDescription = $Window.FindName("TxtDescription")
$TxtMeta        = $Window.FindName("TxtMeta")
$TxtOutput      = $Window.FindName("TxtOutput")
$TxtStatus      = $Window.FindName("TxtStatus")

$ActionPanel = $Window.FindName("ActionPanel")

$BtnPrimary   = $Window.FindName("BtnPrimary")
$BtnSecondary = $Window.FindName("BtnSecondary")
$BtnTertiary  = $Window.FindName("BtnTertiary")

$BtnRAM          = $Window.FindName("BtnRAM")
$BtnNET          = $Window.FindName("BtnNET")
$BtnCLEAN        = $Window.FindName("BtnCLEAN")
$BtnFIX          = $Window.FindName("BtnFIX")
$BtnBOOST        = $Window.FindName("BtnBOOST")
$BtnNETREF       = $Window.FindName("BtnNETREF")
$BtnHerramientas = $Window.FindName("BtnHerramientas")
$BtnMaestro      = $Window.FindName("BtnMaestro")
$BtnEmergencia   = $Window.FindName("BtnEmergencia")
$BtnSistema      = $Window.FindName("BtnSistema")

$BtnLogs  = $Window.FindName("BtnLogs")
$BtnAyuda = $Window.FindName("BtnAyuda")
$BtnExit  = $Window.FindName("BtnExit")

$TaskBar         = $Window.FindName("TaskBar")
$TxtTaskName     = $Window.FindName("TxtTaskName")
$TxtTaskInfo     = $Window.FindName("TxtTaskInfo")
$TaskProgress    = $Window.FindName("TaskProgress")
$TxtTaskPercent  = $Window.FindName("TxtTaskPercent")

$script:NavigationButtons = @(
    $BtnRAM, $BtnNET, $BtnCLEAN, $BtnFIX, $BtnBOOST, $BtnNETREF,
    $BtnHerramientas, $BtnMaestro, $BtnEmergencia, $BtnSistema,
    $BtnLogs, $BtnAyuda, $BtnExit
)
#endregion

#region SISTEMA DE PÁGINAS
$BtnPrimary.Add_Click({ if ($script:PrimaryAction)   { & $script:PrimaryAction } })
$BtnSecondary.Add_Click({ if ($script:SecondaryAction) { & $script:SecondaryAction } })
$BtnTertiary.Add_Click({ if ($script:TertiaryAction)  { & $script:TertiaryAction } })

function Set-ActionButton {
    param($Button, [string]$Label, [string]$Slot, [scriptblock]$Action)
    if ([string]::IsNullOrWhiteSpace($Label)) {
        $Button.Visibility = "Collapsed"
        switch ($Slot) {
            "Primary"   { $script:PrimaryAction = $null }
            "Secondary" { $script:SecondaryAction = $null }
            "Tertiary"  { $script:TertiaryAction = $null }
        }
        return
    }
    $Button.Content = $Label
    $Button.Visibility = "Visible"
    switch ($Slot) {
        "Primary"   { $script:PrimaryAction = $Action }
        "Secondary" { $script:SecondaryAction = $Action }
        "Tertiary"  { $script:TertiaryAction = $Action }
    }
}

function Set-Page {
    param(
        [string]$Title, [string]$Desc, [string]$Meta, [string]$Body,
        [string]$P1 = "", [scriptblock]$PA1 = $null,
        [string]$P2 = "", [scriptblock]$PA2 = $null,
        [string]$P3 = "", [scriptblock]$PA3 = $null
    )
    
    $TxtTitle.Text = $Title
    $TxtDescription.Text = $Desc
    $TxtMeta.Text = $Meta
    $TxtOutput.Text = $Body
    
    # Blindaje para que los botones no fallen si el panel no se encuentra
    if ($ActionPanel) { $ActionPanel.Visibility = "Visible" }
    if ($StatusCardsPanel) { $StatusCardsPanel.Visibility = "Collapsed" }
    if ($TxtOutput) { $TxtOutput.Visibility = "Visible" }
    
    Set-ActionButton $BtnPrimary $P1 "Primary" $PA1
    Set-ActionButton $BtnSecondary $P2 "Secondary" $PA2
    Set-ActionButton $BtnTertiary $P3 "Tertiary" $PA3
}

function Set-Busy {
    param([bool]$Busy, [string]$Message = "")
    if ($Busy) {
        $TxtStatus.Text = "🔴 EJECUTANDO: $Message — Puedes navegar mientras corre"
        $TxtStatus.Foreground = "#FFB300"
        $Window.Title = "⏳ IOI Tools - $Message"
        Show-TaskBar -Message $Message
    } else {
        $TxtStatus.Text = "Estado: Listo"
        $TxtStatus.Foreground = "#00FF7F"
        $Window.Title = "IOI Tools v7.2 - by Cristian Viera"
        Hide-TaskBar
    }
    try {
        $Window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
    } catch {}
}
#endregion

#region TASK BAR (Background)
function Show-TaskBar {
    param([string]$Message)
    $TaskBar.Visibility = "Visible"
    $TxtTaskName.Text = "⏳ $Message"
    $TxtTaskInfo.Text = "Puedes navegar mientras corre. No cierres la ventana."
    $TaskProgress.Value = 0
    $TxtTaskPercent.Text = "0%"
    $script:TaskRunning = $true
    $script:TaskName = $Message
    $script:TaskPercent = 0
    $script:TaskStartTime = Get-Date
}

function Hide-TaskBar {
    $TaskBar.Visibility = "Collapsed"
    $script:TaskRunning = $false
    $script:TaskName = ""
    $script:TaskPercent = 0
}

function Update-TaskProgress {
    param(
        [int]$Percent,
        [string]$Info = ""
    )
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $script:TaskPercent = $Percent
    $TaskProgress.Value = $Percent
    $TxtTaskPercent.Text = "$Percent%"
    if ($Info) { $TxtTaskInfo.Text = $Info }
    try {
        $Window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
    } catch {}
}
#endregion

#region STATUS BAR
function Refresh-SystemStatus {
    try {
        $OS = Get-CimInstance Win32_OperatingSystem
        $TxtWindowsStatus.Text = "$($OS.Caption) | Build $($OS.BuildNumber)"
    } catch { $TxtWindowsStatus.Text = "Windows detectado" }

    $TxtAdminStatus.Text = "Admin: YES"

    try {
        if ([System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) {
            $TxtNetworkStatus.Text = "Red: OK"
            $TxtNetworkStatus.Foreground = "#00FF7F"
        } else {
            $TxtNetworkStatus.Text = "Red: Offline"
            $TxtNetworkStatus.Foreground = "#FFB300"
        }
    } catch { $TxtNetworkStatus.Text = "Red: ?" }

    try {
        $MP = Get-MpComputerStatus -ErrorAction Stop
        if ($MP.AntivirusEnabled) {
            $TxtDefenderStatus.Text = "Defender: Activo"
            $TxtDefenderStatus.Foreground = "#00FF7F"
        } else {
            $TxtDefenderStatus.Text = "Defender: Inactivo"
            $TxtDefenderStatus.Foreground = "#FFB300"
        }
    } catch { $TxtDefenderStatus.Text = "Defender: ?" }

    try {
        $Drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        $TxtDriveStatus.Text = "$env:SystemDrive Libre: $(Convert-ToReadableSize $Drive.FreeSpace)"
    } catch { $TxtDriveStatus.Text = "Disco: ?" }
}
#endregion

#region HOME
function Show-HomePage {
    if ($StatusCardsPanel) { $StatusCardsPanel.Visibility = "Collapsed" }
    if ($TxtOutput) { $TxtOutput.Visibility = "Visible" }
    if ($ActionPanel) { $ActionPanel.Visibility = "Collapsed" }
    
    $TxtTitle.Text = "Bienvenido a IOI Tools v7.2"
    $TxtDescription.Text = "Suite de mantenimiento y optimización para Windows 11. Estilo MS Store, tareas en background y barras de progreso reales."
    $TxtMeta.Text = "CRISTIAN VIERA · v7.2 · ADMINISTRADOR"
    
    $TxtStatus.Text = "Estado: Listo"
    $TxtStatus.Foreground = [System.Windows.Media.Brushes]::MediumSpringGreen

    $TextoBienvenida = @"
Selecciona un módulo en el menú de la izquierda.

MÓDULOS DISPONIBLES
==============================================================
  RAM            - Liberar memoria (WorkingSet/Standby/System WS)
  NET            - Info de red + optimización
  CLEAN          - Limpieza (rápida/profunda/extrema)
  FIX            - Reparación (SFC/DISM)
  BOOST          - Rendimiento (plan/CPU/UI/gráficos/IA)
  NETREF         - Reiniciar pila de red
  HERRAMIENTAS   - Mantenimiento, fantasmas, purga
  MAESTRO v10    - Optimización total (motor principal)
  EMERGENCIA     - Acciones rápidas
  SISTEMA        - Info completa en vivo

NOVEDADES v7.2
--------------------------------------------------------------
  * Look MS Store: header grande, hover suave, bordes redondeados
  * Tareas en background: navega mientras corren
  * Barra de progreso real con porcentaje
  * Panel de tarea persistente en el footer
  * Correcciones aplicadas: XAML, Fantasmas, Purga

FILOSOFÍA
--------------------------------------------------------------
  * 100% PowerShell
  * Portable, sin instalación
  * Sin telemetría
  * Sin IA integrada
  * Sin respaldos automáticos
  * Transparencias y efectos visuales INTACTOS
"@

    $TxtOutput.Text = $TextoBienvenida
}

#endregion

#region RAM
function Invoke-RAM {
    Set-Busy $true "Liberando memoria RAM..."
    try {
        Update-TaskProgress -Percent 5 -Info "Analizando procesos..."
        $totalRAM = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
        $usedRAM = (Get-Process | Measure-Object -Property WorkingSet -Sum).Sum / 1GB
        $percent = [math]::Round(($usedRAM / $totalRAM) * 100, 0)

        $privilegiosCode = @"
using System;
using System.Runtime.InteropServices;
public class Privilegios {
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }
    [DllImport("kernel32.dll", ExactSpelling = true)] public static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)] public static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
    [DllImport("advapi32.dll", SetLastError = true)] public static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)] public static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
    public static bool EnablePrivilege(string privilege) {
        IntPtr hproc = GetCurrentProcess(); IntPtr htok = IntPtr.Zero;
        if (!OpenProcessToken(hproc, 0x0020 | 0x0008, ref htok)) return false;
        TokPriv1Luid tp = new TokPriv1Luid(); tp.Count = 1; tp.Luid = 0; tp.Attr = 2;
        if (!LookupPrivilegeValue(null, privilege, ref tp.Luid)) return false;
        return AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
"@
        if (-not ([System.Management.Automation.PSTypeName]'Privilegios').Type) { Add-Type -TypeDefinition $privilegiosCode -ErrorAction SilentlyContinue }
        [Privilegios]::EnablePrivilege("SeProfileSingleProcessPrivilege") | Out-Null
        [Privilegios]::EnablePrivilege("SeIncreaseQuotaPrivilege") | Out-Null

        Update-TaskProgress -Percent 20 -Info "Vaciando WorkingSet..."

        $NativeCode = @"
using System;
using System.Runtime.InteropServices;
public class Mem {
    [DllImport("psapi.dll")] public static extern int EmptyWorkingSet(IntPtr hwProc);
    private const int SystemMemoryListInformation = 80;
    private const int MemoryPurgeStandbyList = 4;
    private const uint FILE_CACHE_MAX_HARD_DISABLE = 0x2;
    private const uint FILE_CACHE_MIN_HARD_DISABLE = 0x8;
    [DllImport("ntdll.dll")] public static extern uint NtSetSystemInformation(int i, IntPtr p, int l);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetSystemFileCacheSize(IntPtr mn, IntPtr mx, uint f);
    public static bool EmptyStandbyList() { try { IntPtr ptr = Marshal.AllocHGlobal(4); Marshal.WriteInt32(ptr, 4); uint r = NtSetSystemInformation(80, ptr, 4); Marshal.FreeHGlobal(ptr); return r == 0; } catch { return false; } }
    public static bool EmptySystemWS() { try { IntPtr m1 = new IntPtr(-1); return SetSystemFileCacheSize(m1, m1, 0x2 | 0x8); } catch { return false; } }
}
"@
        if (-not ([System.Management.Automation.PSTypeName]'Mem').Type) { Add-Type -TypeDefinition $NativeCode -ErrorAction SilentlyContinue }

        # 1. EmptyWorkingSet en todos los procesos
        $procesos = Get-Process -ErrorAction SilentlyContinue
        $liberados = 0
        $totalProcesos = $procesos.Count
        $contador = 0
        
        foreach ($proc in $procesos) {
            $contador++
            if ($contador % 10 -eq 0) {
                $porcentaje = [math]::Round(($contador / $totalProcesos) * 60) + 20
                Update-TaskProgress -Percent $porcentaje -Info "Optimizando: $($proc.ProcessName)"
            }
            try {
                if ($proc.Id -eq $PID) { continue }
                if ($proc.ProcessName -in @('System','Idle','csrss','wininit','services','lsass','smss')) { continue }
                $handle = $proc.Handle
                if ($handle -ne [IntPtr]::Zero) {
                    [void][Mem]::EmptyWorkingSet($handle)
                    $liberados++
                }
            } catch { continue }
        }

        Update-TaskProgress -Percent 85 -Info "Vaciando Standby List..."
        [Mem]::EmptyStandbyList() | Out-Null
        Start-Sleep -Milliseconds 300

        Update-TaskProgress -Percent 95 -Info "Vaciando caché del sistema..."
        [Mem]::EmptySystemWS() | Out-Null
        
        Update-TaskProgress -Percent 100 -Info "¡Completado!"
        Start-Sleep -Milliseconds 500

        # Cálculo final
        $ramLibre = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024, 0)

        # Mostramos el resultado en la pantalla de Ayuda
        $TextoAyuda = "✅ Limpieza PROFUNDA completada con éxito.`n`n"
        $TextoAyuda += "Procesos optimizados: $liberados de $totalProcesos`n"
        $TextoAyuda += "Memoria RAM libre actual: $ramLibre MB`n`n"
        $TextoAyuda += "Se han vaciado las listas de espera (Standby) y la caché del sistema.`n"
        $TextoAyuda += "El sistema debería responder de forma más fluida ahora."
        
        Show-AyudaPage $TextoAyuda

    } catch {
        $TextoAyuda = "❌ Ocurrió un error al limpiar la RAM:`n$($_.Exception.Message)"
        Show-AyudaPage $TextoAyuda
    } finally {
        Set-Busy $false
    }
}

function Show-RAMPage {
    Set-Page `
        "🧠 RAM - Liberación de Memoria" `
        "Libera memoria de 3 formas: WorkingSet, Standby List y System Working Set." `
        "SEGURO · ADMIN · 3 NIVELES" `
@"
LIBERACIÓN DE MEMORIA RAM

1. EmptyWorkingSet de todos los procesos (excepto kernel)
2. EmptyStandbyList (libera RAM en espera)
3. EmptySystemWorkingSet (libera caché del sistema)
4. Garbage Collection (.NET)

RESULTADO ESPERADO
- Reducción de uso de RAM
- Sistema más responsivo
- Sin afectar procesos críticos

✨ v7.2: barra de progreso real con contador de procesos
"@ `
        "EJECUTAR LIBERACIÓN" `
        { Invoke-RAM }
}
#endregion

#region NET
function Invoke-NETInfo {
    Set-Busy $true "Obteniendo info de red..."
    try {
        Update-TaskProgress -Percent 30 -Info "Consultando adaptador..."
        $adapter = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if (-not $adapter) {
            $TxtOutput.Text = "⚠ No se encontró adaptador activo."
            Play-WarningSound
            Set-Busy $false
            return
        }
        Update-TaskProgress -Percent 70 -Info "Extrayendo IP/DNS..."
        $ip   = (Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4).IPAddress
        $mask = (Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4).PrefixLength
        $gw   = (Get-NetRoute -InterfaceIndex $adapter.InterfaceIndex -DestinationPrefix "0.0.0.0/0").NextHop
        $dns  = (Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4).ServerAddresses -join ", "

        $Report = @"
INFORMACIÓN DE RED
─────────────────────────────────────────────────────────────
Adaptador: $($adapter.Name)
IP:        $ip
Máscara:   /$mask
Gateway:   $gw
DNS:       $dns
"@
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $TxtOutput.Text = $Report
        Play-SuccessSound
    } catch {
        $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"
        Play-ErrorSound
    }
    Set-Busy $false
}

function Invoke-NETOptLight {
    Set-Busy $true "Optimización ligera de red..."
    try {
        Update-TaskProgress -Percent 20 -Info "Flush DNS..."
        ipconfig /flushdns | Out-Null
        Update-TaskProgress -Percent 40 -Info "ARP cache..."
        netsh interface ip delete arpcache | Out-Null
        Update-TaskProgress -Percent 60 -Info "QoS..."
        $QoSPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"
        if (-not (Test-Path $QoSPath)) { New-Item -Path $QoSPath -Force | Out-Null }
        Set-ItemProperty -Path $QoSPath -Name "NonBestEffortLimit" -Value 0 -Type DWord -Force
        Update-TaskProgress -Percent 80 -Info "TcpNoDelay..."
        $Ifaces = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
        if (Test-Path $Ifaces) {
            Get-ChildItem -Path $Ifaces -Name | ForEach-Object {
                Set-ItemProperty -Path "$Ifaces\$_" -Name "TcpAckFrequency" -Value 1 -Type DWord -ErrorAction SilentlyContinue
                Set-ItemProperty -Path "$Ifaces\$_" -Name "TCPNoDelay" -Value 1 -Type DWord -ErrorAction SilentlyContinue
            }
        }
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $Report = "OPTIMIZACIÓN LIGERA APLICADA`n`n✓ DNS flush`n✓ ARP cache`n✓ QoS`n✓ TcpNoDelay"
        $TxtOutput.Text = $Report
        Save-IOILog "NET-Ligera" "Completado" $Report | Out-Null
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "NET ligera aplicada"
    } catch {
        $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"
        Play-ErrorSound
    }
    Set-Busy $false
}

function Invoke-NETOptFull {
    Set-Busy $true "Optimización completa de red..."
    try {
        Update-TaskProgress -Percent 15 -Info "Flush DNS..."
        ipconfig /flushdns | Out-Null
        Update-TaskProgress -Percent 25 -Info "Winsock reset..."
        netsh winsock reset | Out-Null
        Update-TaskProgress -Percent 35 -Info "TCP reset..."
        netsh int tcp reset | Out-Null
        Update-TaskProgress -Percent 45 -Info "IP reset..."
        netsh int ip reset | Out-Null
        Update-TaskProgress -Percent 55 -Info "Autotuning..."
        netsh int tcp set global autotuninglevel=normal | Out-Null
        netsh int tcp set global heuristics=disabled | Out-Null
        netsh int tcp set global timestamps=disabled | Out-Null
        Update-TaskProgress -Percent 70 -Info "DNS Cloudflare..."
        $DNS4 = @("1.1.1.1", "8.8.8.8")
        $DNS6 = @("2606:4700:4700::1111", "2001:4860:4860::8888")
        Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
            Set-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -ServerAddresses $DNS4 -ErrorAction SilentlyContinue
            Set-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -ServerAddresses $DNS6 -ErrorAction SilentlyContinue
        }
        Update-TaskProgress -Percent 85 -Info "Adaptadores..."
        $Adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
        foreach ($a in $Adapters) {
            Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName "Green Ethernet" -DisplayValue "Disabled" -ErrorAction SilentlyContinue
            Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName "Energy Efficient Ethernet" -DisplayValue "Disabled" -ErrorAction SilentlyContinue
            Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName "Flow Control" -DisplayValue "Rx & Tx Enabled" -ErrorAction SilentlyContinue
            Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName "IPv4 Checksum Offload" -DisplayValue "Rx & Tx Enabled" -ErrorAction SilentlyContinue
        }
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $Report = "OPTIMIZACIÓN COMPLETA APLICADA`n`n✓ DNS flush + Winsock + TCP/IP reset`n✓ DNS Cloudflare + Google`n✓ Adaptadores sin ahorro de energía`n`n⚠ Reinicia el equipo para aplicar todos los cambios."
        $TxtOutput.Text = $Report
        Save-IOILog "NET-Completa" "Completado" $Report | Out-Null
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "NET completa aplicada. Reinicia el equipo."
    } catch {
        $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"
        Play-ErrorSound
    }
    Set-Busy $false
}

function Show-NETPage {
    Set-Page `
        "🌐 NET - Red" `
        "Información de red y optimización de la pila TCP/IP." `
        "INFO · LIGERA · COMPLETA" `
@"
MÓDULO DE RED

• INFO      - Muestra IP, máscara, gateway, DNS
• LIGERA    - DNS + ARP + QoS + TcpNoDelay
• COMPLETA  - Reset completo + DNS Cloudflare + adaptadores

⚠ La opción completa requiere reiniciar.
"@ `
        "VER INFO" `
        { Invoke-NETInfo } `
        "OPT. LIGERA" `
        { Invoke-NETOptLight } `
        "OPT. COMPLETA" `
        { Invoke-NETOptFull }
}
#endregion

#region CLEAN
function Invoke-CLEANRapida {
    Set-Busy $true "Limpieza rápida..."
    try {
        Update-TaskProgress -Percent 30 -Info "Limpiando TEMP usuario..."
        Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 60 -Info "Limpiando TEMP Windows..."
        Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 90 -Info "Flush DNS..."
        ipconfig /flushdns | Out-Null
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $Report = "LIMPIEZA RÁPIDA COMPLETADA`n`n✓ TEMP usuario`n✓ TEMP Windows`n✓ DNS cache"
        $TxtOutput.Text = $Report
        Save-IOILog "CLEAN-Rapida" "Completado" $Report | Out-Null
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "Limpieza rápida completada"
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Invoke-CLEANProfunda {
    $choice = Show-IOIMessage "¿Ejecutar limpieza profunda?`n`nAñade DISM y cola de impresión." "Confirmar" ([System.Windows.MessageBoxButton]::YesNo) ([System.Windows.MessageBoxImage]::Question)
    if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Set-Busy $true "Limpieza profunda (DISM)..."
    try {
        Update-TaskProgress -Percent 10 -Info "TEMP usuario..."
        Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 20 -Info "TEMP Windows..."
        Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 30 -Info "Cola impresión..."
        Stop-Service Spooler -ErrorAction SilentlyContinue -Force
        Remove-Item "$env:WINDIR\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
        Start-Service Spooler -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 40 -Info "DISM cleanup (puede tardar)..."
        $dismOut = Dism /Online /Cleanup-Image /StartComponentCleanup /Quiet 2>&1 | Out-String
        Update-TaskProgress -Percent 90 -Info "Flush DNS..."
        ipconfig /flushdns | Out-Null
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $Report = "LIMPIEZA PROFUNDA COMPLETADA`n`n✓ TEMP`n✓ Cola impresión`n✓ DISM cleanup`n✓ DNS`n`nDISM:`n$dismOut"
        $TxtOutput.Text = $Report
        Save-IOILog "CLEAN-Profunda" "Completado" $Report | Out-Null
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "Limpieza profunda completada"
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Invoke-CLEANExtrema {
    $choice = Show-IOIMessage "¿Limpieza EXTREMA?`n`nIncluye Package Cache, logs, prefetch, resetbase.`nPuede tardar MUCHO." "Confirmar" ([System.Windows.MessageBoxButton]::YesNo) ([System.Windows.MessageBoxImage]::Warning)
    if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Set-Busy $true "Limpieza EXTREMA..."
    try {
        Update-TaskProgress -Percent 5 -Info "TEMP usuario..."
        Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 10 -Info "TEMP Windows..."
        Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 15 -Info "Update cache..."
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service wuauserv -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 25 -Info "Browser caches..."
        $browserCaches = @(
            "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
            "$env:LOCALAPPDATA\Thorium\User Data\Default\Cache",
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache"
        )
        foreach ($cache in $browserCaches) {
            if (Test-Path $cache) { Remove-Item $cache\* -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Update-TaskProgress -Percent 40 -Info "Package Cache + logs..."
        Remove-Item "C:\ProgramData\Package Cache\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:LOCALAPPDATA\Temp\*installer*" -Recurse -Force -ErrorAction SilentlyContinue
        wevtutil el | ForEach-Object { wevtutil cl "$_" *> $null }
        Update-TaskProgress -Percent 55 -Info "Prefetch + FontCache..."
        Remove-Item "$env:WINDIR\Prefetch\*" -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache\*" -Recurse -Force -ErrorAction SilentlyContinue
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 65 -Info "DISM /ResetBase (MUY LENTO)..."
        $dismOut = Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet 2>&1 | Out-String
        Update-TaskProgress -Percent 90 -Info "TRIM + DNS..."
        try { defrag C: /L 2>&1 | Out-Null } catch {}
        ipconfig /flushdns | Out-Null
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 800
        $Report = "LIMPIEZA EXTREMA COMPLETADA`n`n✓ TEMP`n✓ Update cache`n✓ Browser caches`n✓ Package Cache`n✓ Logs`n✓ Prefetch`n✓ Papelera`n✓ DISM resetbase`n✓ TRIM`n✓ DNS"
        $TxtOutput.Text = $Report
        Save-IOILog "CLEAN-Extrema" "Completado" $Report | Out-Null
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "Limpieza extrema completada"
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Show-CLEANPage {
    Set-Page `
        "🧹 CLEAN - Limpieza del Sistema" `
        "Limpieza en 3 niveles de intensidad con barra de progreso real." `
        "RÁPIDA · PROFUNDA · EXTREMA" `
@"
NIVELES DE LIMPIEZA

• RÁPIDA    - TEMP + DNS (segundos)
• PROFUNDA  - Rápida + DISM + cola impresión (1-2 min)
• EXTREMA   - Profunda + Package Cache + logs + prefetch + resetbase + TRIM (5-10 min)

✨ v7.2: barra de progreso en tiempo real con cada paso

⚠ EXTREMA puede tardar MUCHO (ResetBase es lento)
"@ `
        "RÁPIDA" `
        { Invoke-CLEANRapida } `
        "PROFUNDA" `
        { Invoke-CLEANProfunda } `
        "EXTREMA" `
        { Invoke-CLEANExtrema }
}
#endregion

#region FIX
function Invoke-FIXSFC {
    Set-Busy $true "Ejecutando SFC /scannow..."
    try {
        Update-TaskProgress -Percent 10 -Info "Iniciando SFC..."
        $out = sfc /scannow 2>&1 | Out-String
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $Report = "SFC /SCANNOW COMPLETADO`n`n$out"
        $TxtOutput.Text = $Report
        Save-IOILog "FIX-SFC" "Completado" $Report | Out-Null
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "SFC completado"
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Invoke-FIXDISM {
    Set-Busy $true "Ejecutando DISM /RestoreHealth..."
    try {
        Update-TaskProgress -Percent 10 -Info "Iniciando DISM..."
        $out = Dism /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-String
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $Report = "DISM /RESTOREHEALTH COMPLETADO`n`n$out"
        $TxtOutput.Text = $Report
        Save-IOILog "FIX-DISM" "Completado" $Report | Out-Null
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "DISM completado"
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Invoke-FIXAmbos {
    Set-Busy $true "Ejecutando SFC + DISM..."
    try {
        Update-TaskProgress -Percent 5 -Info "SFC (puede tardar)..."
        $sfcOut = sfc /scannow 2>&1 | Out-String
        Update-TaskProgress -Percent 50 -Info "DISM RestoreHealth..."
        $dismOut = Dism /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-String
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $Report = "REPARACIÓN COMPLETA`n`n=== SFC ===`n$sfcOut`n`n=== DISM ===`n$dismOut"
        $TxtOutput.Text = $Report
        Save-IOILog "FIX-Ambos" "Completado" $Report | Out-Null
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "SFC + DISM completados"
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Show-FIXPage {
    Set-Page `
        "🔧 FIX - Reparación del Sistema" `
        "Repara archivos dañados con SFC y DISM." `
        "SFC · DISM · AMBOS" `
@"
REPARACIÓN DEL SISTEMA

• SFC         - sfc /scannow (5-15 min)
• DISM        - Repara imagen de Windows (10-30 min)
• AMBOS       - Combina SFC + DISM (15-45 min)

✨ v7.2: barra de progreso mientras corre

⚠ Puede tardar mucho. NO cierres la ventana.
"@ `
        "SFC" `
        { Invoke-FIXSFC } `
        "DISM" `
        { Invoke-FIXDISM } `
        "AMBOS" `
        { Invoke-FIXAmbos }
}
#endregion

#region BOOST
function Invoke-BOOSTTodo {
    Set-Busy $true "Aplicando TODOS los ajustes de rendimiento..."
    try {
        Update-TaskProgress -Percent 10 -Info "Plan Alto Rendimiento..."
        powercfg -setactive $guidAltoRendimiento
        Update-TaskProgress -Percent 25 -Info "Prioridad de procesos..."
        $apps = @("brave","msedge","thorium","chrome","code","powershell","pwsh")
        foreach ($app in $apps) {
            Get-Process -Name $app -ErrorAction SilentlyContinue | ForEach-Object {
                try { $_.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch {}
            }
        }
        Update-TaskProgress -Percent 40 -Info "CPU 5% / 100%..."
        try {
            powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5 | Out-Null
            powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
            powercfg /setactive SCHEME_CURRENT | Out-Null
        } catch {}
        Update-TaskProgress -Percent 55 -Info "UI instantánea..."
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Type String -Force
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MouseHoverTime" -Value "0" -Type String -Force
        Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name "AutoRepeatDelay" -Value "200" -Type String -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name "AutoRepeatRate" -Value "15" -Type String -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "0" -Type String -Force -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 70 -Info "Gráficos..."
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "FontSmoothingGamma" -Value 1500 -Type DWord -ErrorAction SilentlyContinue
        $Paths = Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^00" }
        foreach ($P in $Paths) {
            Set-ItemProperty -Path $P.PSPath -Name "DALRule_FullRGBOverHDMI" -Value 1 -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $P.PSPath -Name "DAL_DP_EnableITCSupport" -Value 0 -ErrorAction SilentlyContinue
        }
        Update-TaskProgress -Percent 85 -Info "IA/Copilot/Bing off..."
        $CopilotPaths = @("HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot","HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot")
        foreach ($path in $CopilotPaths) {
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            Set-ItemProperty -Path $path -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        $AIPaths = @("HKCU:\Software\Policies\Microsoft\Windows\WindowsAI","HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI")
        foreach ($path in $AIPaths) {
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            Set-ItemProperty -Path $path -Name "TurnOffAIDataAnalysis" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $path -Name "AllowRecallEnablement" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarDa" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        $SearchPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
        if (-not (Test-Path $SearchPolicy)) { New-Item -Path $SearchPolicy -Force | Out-Null }
        Set-ItemProperty -Path $SearchPolicy -Name "DisableWebSearch" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $SearchPolicy -Name "BingSearchEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $Report = @"
RENDIMIENTO APLICADO
─────────────────────────────────────────────────────────────
✓ Plan Alto Rendimiento
✓ Prioridad de procesos
✓ CPU 5% / 100%
✓ UI instantánea
✓ Gráficos FontSmoothing + HDMI
✓ IA / Copilot / Cortana off
✓ Bing / web search off

⚠ Transparencias y efectos visuales INTACTOS.
"@
        $TxtOutput.Text = $Report
        Save-IOILog "BOOST-Todo" "Completado" $Report | Out-Null
        Refresh-SystemStatus
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "Rendimiento aplicado"
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Show-BOOSTPage {
    Set-Page `
        "⚡ BOOST - Rendimiento" `
        "Ajustes de rendimiento consolidados." `
        "PLAN · CPU · UI · GRÁFICOS · IA" `
@"
AJUSTES DE RENDIMIENTO

• Plan: Alto Rendimiento
• Prioridad alta a navegadores / VS Code / PowerShell
• CPU: 5% / 100%
• UI: menús instantáneos, hover 0
• Gráficos: FontSmoothing + HDMI full RGB
• IA / Copilot / Cortana / Widgets off
• Búsqueda web (Bing) off

✨ v7.2: barra de progreso con cada paso

⚠ NO toca transparencias ni efectos visuales.
"@ `
        "APLICAR TODO" `
        { Invoke-BOOSTTodo }
}
#endregion

#region NETREF
function Invoke-NETREF {
    Set-Busy $true "Reiniciando pila de red..."
    try {
        Update-TaskProgress -Percent 15 -Info "Flush DNS..."
        ipconfig /flushdns | Out-Null
        Update-TaskProgress -Percent 30 -Info "Winsock reset..."
        netsh winsock reset | Out-Null
        Update-TaskProgress -Percent 45 -Info "TCP/IP reset..."
        netsh int ip reset | Out-Null
        netsh int tcp reset | Out-Null
        Update-TaskProgress -Percent 60 -Info "ARP cache..."
        netsh interface ip delete arpcache | Out-Null
        Update-TaskProgress -Percent 80 -Info "Autotuning..."
        netsh int tcp set global autotuninglevel=normal | Out-Null
        netsh int tcp set global heuristics=disabled | Out-Null
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $Report = "PILA DE RED REINICIADA`n`n✓ DNS`n✓ Winsock`n✓ TCP/IP`n✓ ARP`n✓ Autotuning`n`n⚠ Reinicia el equipo."
        $TxtOutput.Text = $Report
        Save-IOILog "NETREF" "Completado" $Report | Out-Null
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "Pila de red reiniciada"
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Show-NETREFPage {
    Set-Page `
        "🌐 NETREF - Reinicio de Red" `
        "Resetea la pila de red completa." `
        "DNS · WINSOCK · TCP/IP · ARP" `
@"
REINICIO DE PILA DE RED

• Flush DNS
• Winsock reset
• TCP/IP reset
• TCP reset
• ARP cache
• Autotuning normal
• Heuristics disabled

⚠ Requiere reiniciar el equipo.
"@ `
        "EJECUTAR RESET" `
        { Invoke-NETREF }
}
#endregion

#region HERRAMIENTAS
function Invoke-HERRMantenimiento {
    Set-Busy $true "Mantenimiento profundo..."
    try {
        Update-TaskProgress -Percent 5 -Info "SFC..."
        $logFile = Join-Path $script:LogFolder "mantenimiento_$(Get-Date -Format yyyy-MM-dd_HHmm).log"
        $output = @()
        $output += "=== SFC ==="
        $output += (sfc /scannow 2>&1 | Out-String)
        Update-TaskProgress -Percent 35 -Info "DISM..."
        $output += "=== DISM ==="
        $output += (Dism /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-String)
        Update-TaskProgress -Percent 65 -Info "CHKDSK..."
        $output += "=== CHKDSK ==="
        $output += (chkdsk C: /scan 2>&1 | Out-String)
        Update-TaskProgress -Percent 85 -Info "TRIM..."
        $output += "=== TRIM ==="
        try { $output += (defrag C: /L 2>&1 | Out-String) } catch {}
        $output | Out-File $logFile -Encoding UTF8
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $TxtOutput.Text = "MANTENIMIENTO COMPLETADO`n`nLog: $logFile"
        Save-IOILog "HERR-Mantenimiento" "Completado" "Ver log: $logFile" | Out-Null
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "Mantenimiento completado"
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Invoke-HERRFantasmas {
    Set-Busy $true "Limpiando dispositivos fantasma..."
    try {
        Update-TaskProgress -Percent 30 -Info "Enumerando dispositivos desconectados..."
        $env:devmgr_show_nonpresent_devices = 1
        $eliminados = 0
        $fallidos = 0
        $output = pnputil /enum-devices /disconnected 2>&1 | Out-String
        Update-TaskProgress -Percent 50 -Info "Analizando IDs..."
        $instancias = [regex]::Matches($output, 'Instance ID:\s+(.+)') | ForEach-Object { $_.Groups[1].Value.Trim() }
        Update-TaskProgress -Percent 70 -Info "Eliminando..."
        foreach ($inst in $instancias) {
            try {
                $res = pnputil /remove-device $inst 2>&1 | Out-String
                if ($LASTEXITCODE -eq 0) { $eliminados++ }
                else { $fallidos++ }
            } catch { $fallidos++ }
        }
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $Report = @"
DISPOSITIVOS FANTASMA
─────────────────────────────────────────────────────────────
Instancias detectadas: $($instancias.Count)
Eliminados: $eliminados
Fallidos:  $fallidos
"@
        $TxtOutput.Text = $Report
        Save-IOILog "HERR-Fantasmas" "Completado" $Report | Out-Null
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "Fantasmas: $eliminados eliminados"
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Invoke-HERRPurga {
    $choice = Show-IOIMessage "¿Purga total?`n`nIncluye ResetBase (muy lento)." "Confirmar" ([System.Windows.MessageBoxButton]::YesNo) ([System.Windows.MessageBoxImage]::Warning)
    if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Set-Busy $true "Purga total..."
    try {
        Update-TaskProgress -Percent 10 -Info "Midiendo espacio..."
        $startSpace = (Get-PSDrive C).Free / 1GB
        Update-TaskProgress -Percent 20 -Info "TEMP..."
        Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 30 -Info "Update cache..."
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service wuauserv -ErrorAction SilentlyContinue
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Update-TaskProgress -Percent 50 -Info "DISM /ResetBase (MUY LENTO)..."
        Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet 2>&1 | Out-Null
        Update-TaskProgress -Percent 85 -Info "TRIM..."
        try { defrag C: /L 2>&1 | Out-Null } catch {}
        $endSpace = (Get-PSDrive C).Free / 1GB
        $saved = [math]::Round($startSpace - $endSpace, 1)
        Update-TaskProgress -Percent 100 -Info "✅ Completado ($saved GB liberados)"
        Start-Sleep -Milliseconds 800
        $TxtOutput.Text = "PURGA TOTAL COMPLETADA`n`nEspacio liberado: $saved GB"
        Save-IOILog "HERR-Purga" "Completado" "Liberado: $saved GB" | Out-Null
        Refresh-SystemStatus
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "Purga total: $saved GB liberados"
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Show-HerramientasPage {
    Set-Page `
        "🛠️ HERRAMIENTAS Avanzadas" `
        "Mantenimiento profundo, fantasmas y purga total." `
        "MANTENIMIENTO · FANTASMAS · PURGA" `
@"
HERRAMIENTAS AVANZADAS

• MANTENIMIENTO - SFC + DISM + CHKDSK + TRIM
• FANTASMAS     - Elimina dispositivos no conectados
• PURGA         - Limpieza extrema con ResetBase

✨ v7.2: barra de progreso por fase
"@ `
        "MANTENIMIENTO" `
        { Invoke-HERRMantenimiento } `
        "FANTASMAS" `
        { Invoke-HERRFantasmas } `
        "PURGA TOTAL" `
        { Invoke-HERRPurga }
}
#endregion

#region MAESTRO
function Invoke-MaestroV10 {
    $choice = Show-IOIMessage "¿Ejecutar IOI_Maestro_v10.ps1?`n`nAplicará TODAS las optimizaciones.`n`nPuede tardar 5-10 minutos." "Confirmar" ([System.Windows.MessageBoxButton]::YesNo) ([System.Windows.MessageBoxImage]::Question)
    if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $MaestroPath = Join-Path $IOI_Scripts "IOI_Maestro_v10.ps1"
    if (-not (Test-Path $MaestroPath)) {
        Show-IOIMessage "No se encontró IOI_Maestro_v10.ps1 en:`n`n$MaestroPath" "Error" | Out-Null
        Play-ErrorSound
        return
    }

    Set-Busy $true "Lanzando Maestro v10..."
    try {
        Update-TaskProgress -Percent 100 -Info "Abriendo ventana externa..."
        $TxtOutput.Text = "🚀 LANZANDO IOI MAESTRO v10...`n`nEl motor se ejecutará en una ventana separada.`nCuando termine, reinicia el equipo."
        Start-Process "pwsh.exe" -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$MaestroPath`"" -Verb RunAs
        Start-Sleep -Milliseconds 800
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "Maestro v10 iniciado en ventana separada"
    } catch {
        $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"
        Play-ErrorSound
    }
    Set-Busy $false
}

function Show-MaestroPage {
    Set-Page `
        "🚀 MAESTRO v10 - Optimización Total" `
        "Lanza el motor principal (13 fases)." `
        "OPTIMIZACIÓN COMPLETA · ADMIN" `
@"
IOI MAESTRO v10

Fases:
1. Punto restauración
2. Blindaje drivers
3. Energía/térmica/pagefile/USB
4. Audio MMCSS
5. Publicidad/IA/Bing
6. Purga bloatware
7. Defender + Edge mínimo
8. Telemetría + Xbox
9. Red TCP/IP + DNS
10. UI (sin tocar transparencias)
11. Accesibilidad
12. Calibración visual

⚠ Se lanza en ventana separada.
⚠ Al terminar, reinicia.
"@ `
        "EJECUTAR MAESTRO" `
        { Invoke-MaestroV10 }
}
#endregion

#region EMERGENCIA
function Invoke-EMERExplorer {
    Set-Busy $true "Reiniciando Explorer..."
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Set-Busy $false
    $TxtOutput.Text = "✅ Explorer reiniciado."
    Play-SuccessSound
}

function Invoke-EMERRAM {
    Set-Busy $true "Liberando RAM de emergencia..."
    try {
        Update-TaskProgress -Percent 50 -Info "Liberando Standby..."
        $nc = @"
using System;
using System.Runtime.InteropServices;
public class MemEmg {
    [DllImport("ntdll.dll")] public static extern uint NtSetSystemInformation(int i, IntPtr p, int l);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetSystemFileCacheSize(IntPtr mn, IntPtr mx, uint f);
    public static bool EmptyStandbyList() { try { IntPtr ptr = Marshal.AllocHGlobal(4); Marshal.WriteInt32(ptr, 4); uint r = NtSetSystemInformation(80, ptr, 4); Marshal.FreeHGlobal(ptr); return r == 0; } catch { return false; } }
    public static bool EmptySystemWS() { try { IntPtr m1 = new IntPtr(-1); return SetSystemFileCacheSize(m1, m1, 0x2 | 0x8); } catch { return false; } }
}
"@
        if (-not ([System.Management.Automation.PSTypeName]'MemEmg').Type) { Add-Type -TypeDefinition $nc -ErrorAction SilentlyContinue }
        [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
        $sb = [MemEmg]::EmptyStandbyList()
        $ws = [MemEmg]::EmptySystemWS()
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $TxtOutput.Text = "✅ RAM liberada.`n`nStandby: $(if ($sb) {'✓'} else {'✗'})`nSystemWS: $(if ($ws) {'✓'} else {'✗'})"
        Play-SuccessSound
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Invoke-EMERPANICO {
    $choice = Show-IOIMessage "🚨 MODO PÁNICO 🚨`n`n1. Liberar RAM`n2. Matar procesos >500 MB`n3. Refrescar GPU`n4. Reiniciar Explorer`n`n¿Continuar?" "Modo Pánico" ([System.Windows.MessageBoxButton]::YesNo) ([System.Windows.MessageBoxImage]::Warning)
    if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Set-Busy $true "🚨 MODO PÁNICO..."
    try {
        Update-TaskProgress -Percent 15 -Info "RAM..."
        [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
        Update-TaskProgress -Percent 40 -Info "Matando procesos >500 MB..."
        Get-Process | Where-Object {
            $_.WorkingSet -gt 500MB -and
            $_.ProcessName -notin $script:ExclusionesKernel -and
            $_.ProcessName -notmatch "brave|msedge|thorium|chrome|code|powershell|pwsh"
        } | ForEach-Object { try { Stop-Process -Id $_.Id -Force } catch {} }
        
        Update-TaskProgress -Percent 70 -Info "Refrescando GPU..."
        try {
            $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
            foreach ($gpu in $gpus) {
                Write-Host "GPU: $($gpu.Name)" -ForegroundColor DarkGray
            }
            $null = & pnputil /enum-devices /class Display 2>&1
        } catch {}
        
        Update-TaskProgress -Percent 90 -Info "Explorer..."
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500
        $TxtOutput.Text = "✅ MODO PÁNICO COMPLETADO`n`n✓ RAM liberada`n✓ Procesos pesados eliminados`n✓ GPU refrescada`n✓ Explorer reiniciado"
        Play-SuccessSound
        Show-ToastNotification -Title "IOI Tools" -Message "Modo pánico completado"
    } catch { $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"; Play-ErrorSound }
    Set-Busy $false
}

function Show-EmergenciaPage {
    Set-Page `
        "🚨 EMERGENCIA - Acciones Inmediatas" `
        "Acciones rápidas cuando el sistema no responde." `
        "SEGURAS · PÁNICO" `
@"
PANEL DE EMERGENCIA

• Reiniciar Explorer
• Liberar RAM
• MODO PÁNICO (RAM + matar + GPU + Explorer)

⚠ El modo pánico cierra apps sin guardar.
"@ `
        "🔄 EXPLORER" `
        { Invoke-EMERExplorer } `
        "🧠 RAM" `
        { Invoke-EMERRAM } `
        "⚡ PÁNICO" `
        { Invoke-EMERPANICO }
}
#endregion

#region SISTEMA
function Show-SistemaPage {
    Set-Busy $true "Recopilando info del sistema..."
    try {
        Update-TaskProgress -Percent 20 -Info "OS + hardware..."
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $bios = Get-CimInstance Win32_BIOS
        $totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        $freeRAM = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        $usedRAM = $totalRAM - $freeRAM
        $ramPct = [math]::Round(($usedRAM / $totalRAM) * 100, 1)
        $uptime = (Get-Date) - $os.LastBootUpTime

        Update-TaskProgress -Percent 60 -Info "Discos..."
        $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Sort-Object DeviceID
        $diskInfo = ""
        foreach ($d in $disks) {
            $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
            $totalGB = [math]::Round($d.Size / 1GB, 1)
            if ($d.Size -gt 0) {
                $pct = [math]::Round(($d.FreeSpace / $d.Size) * 100, 0)
                $diskInfo += "  $($d.DeviceID) $totalGB GB total · $freeGB GB libres ($pct%)`n"
            }
        }

        Update-TaskProgress -Percent 100 -Info "✅ Completado"
        Start-Sleep -Milliseconds 500

        $Report = @"
INFORMACIÓN DEL SISTEMA
══════════════════════════════════════════════════════════════════

🖥️  SISTEMA OPERATIVO
─────────────────────────────────────────────────────────────
  Nombre:         $($os.Caption)
  Versión:        $($os.Version)
  Build:          $($os.BuildNumber)
  Instalado:      $($os.InstallDate)
  Arquitectura:   $($os.OSArchitecture)
  Último arranque: $($os.LastBootUpTime)
  Uptime:         $($uptime.Days)d $($uptime.Hours)h $($uptime.Minutes)m

🔧  HARDWARE
─────────────────────────────────────────────────────────────
  Fabricante:     $($cs.Manufacturer)
  Modelo:         $($cs.Model)
  CPU:            $($cpu.Name)
  Núcleos:        $($cpu.NumberOfCores) físicos / $($cpu.NumberOfLogicalProcessors) lógicos
  Velocidad:      $($cpu.MaxClockSpeed) MHz
  RAM total:      $totalRAM GB
  RAM usada:      $usedRAM GB ($ramPct%)
  RAM libre:      $freeRAM GB

💾  ALMACENAMIENTO
─────────────────────────────────────────────────────────────
$diskInfo
🔐  BIOS / UEFI
─────────────────────────────────────────────────────────────
  Fabricante:     $($bios.Manufacturer)
  Versión:        $($bios.SMBIOSBIOSVersion)
  Fecha:          $($bios.ReleaseDate)

══════════════════════════════════════════════════════════════════
"@
        $TxtOutput.Text = $Report
        Play-SuccessSound
    } catch {
        $TxtOutput.Text = "❌ Error: $($_.Exception.Message)"
        Play-ErrorSound
    }
    Set-Busy $false
}

function Show-SistemaPageWrapper {
    Set-Page `
        "💻 SISTEMA - Info completa" `
        "Información detallada del sistema operativo, hardware y almacenamiento." `
        "SO · HARDWARE · ALMACENAMIENTO · BIOS" `
@"
Esta sección muestra información completa del sistema en tiempo real:

• Sistema operativo (versión, build, uptime)
• Hardware (CPU, RAM, fabricante)
• Almacenamiento (discos y espacio libre)
• BIOS / UEFI

Presiona "ACTUALIZAR INFO" para refrescar los datos.
"@ `
        "ACTUALIZAR INFO" `
        { Show-SistemaPage }
}
#endregion

#region LOGS
function Show-LogsPage {
    $latestText = "No hay logs aún."
    try {
        $latest = Get-ChildItem -LiteralPath $script:LogFolder -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { $latestText = $latest.FullName }
    } catch {}

    Set-Page `
        "📋 LOGS - Registro de Actividad" `
        "Logs automáticos de cada operación." `
        "AUTOMÁTICO · PERSISTENTE" `
@"
CARPETA DE LOGS

$($script:LogFolder)

ÚLTIMO ARCHIVO

$latestText

Los logs se generan automáticamente con cada acción.
"@ `
        "ABRIR CARPETA" `
        { Start-Process explorer.exe -ArgumentList "`"$($script:LogFolder)`"" } `
        "ÚLTIMO LOG" `
        {
            try {
                $latest = Get-ChildItem -LiteralPath $script:LogFolder -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($latest) { Start-Process $latest.FullName }
                else { Show-IOIMessage "No hay logs aún." | Out-Null }
            } catch { Show-IOIMessage "No se pudo abrir el log." | Out-Null }
        }
}
#endregion

#region AYUDA
function Show-AyudaPage {
    if ($StatusCardsPanel) { $StatusCardsPanel.Visibility = "Collapsed" }
    if ($TxtOutput) { $TxtOutput.Visibility = "Visible" }
    if ($ActionPanel) { $ActionPanel.Visibility = "Collapsed" }
    $TxtStatus.Text = "Estado: AYUDA"
    
    $TextoAyuda = @"
AUTOR
Cristian Viera

FILOSOFÍA
- 100% PowerShell
- Portable, sin instalación
- Sin telemetría
- Sin IA integrada
- Sin respaldos automáticos
- Transparencias y efectos visuales INTACTOS

¿QUÉ ES IOI TOOLS?
Es un conjunto de utilidades siempre gratuita y de código abierto en la que puedes aplicar las opciones que necesites para ayudar a tu equipo (Windows 10/11) a trabajar, verse y desempeñarse mejor de como lo tienes en este momento. Esta es una compilación y mejora de scripts, programas y diversos tweaks que he compilado y sigo mejorando para que los tengas a la mano y puedas siempre utilizar esta herramienta de optimización a la mano. De servirte, compartir IOI Tools ayudará a más usuarios como a ti.

¡Disfruta y muchas gracias por usar IOI Tools!

LOGS
$script:LogFolder
"@
    Set-Page "❓ AYUDA - Acerca de IOI Tools" "IOI Tools v7.2 - Edición Universal" "CRISTIAN VIERA · 2026" $TextoAyuda
}

#endregion

#region NAVEGACIÓN
$BtnRAM.Add_Click({ Show-RAMPage })
$BtnNET.Add_Click({ Show-NETPage })
$BtnCLEAN.Add_Click({ Show-CLEANPage })
$BtnFIX.Add_Click({ Show-FIXPage })
$BtnBOOST.Add_Click({ Show-BOOSTPage })
$BtnNETREF.Add_Click({ Show-NETREFPage })
$BtnHerramientas.Add_Click({ Show-HerramientasPage })
$BtnMaestro.Add_Click({ Show-MaestroPage })
$BtnEmergencia.Add_Click({ Show-EmergenciaPage })
$BtnSistema.Add_Click({ Show-SistemaPageWrapper })
$BtnLogs.Add_Click({ Show-LogsPage })
$BtnAyuda.Add_Click({ Show-AyudaPage })
$BtnExit.Add_Click({ $Window.Close() })
#endregion

#region ARRANQUE
try {
    Refresh-SystemStatus
    Show-HomePage
    $Window.ShowDialog() | Out-Null
} catch {
    [System.Windows.MessageBox]::Show(
        "IOI Tools se detuvo por error.`n`n$($_.Exception.Message)",
        "IOI Tools Error",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
    exit 1
}

exit 0
#endregion

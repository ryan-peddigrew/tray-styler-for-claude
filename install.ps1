# Windows 11 System Tray Styler for Claude - installer. Created by Ryan Peddigrew.
# Per-user install, no admin rights, no registry or Windhawk changes:
#   usage service  -> %LOCALAPPDATA%\TrayStylerForClaude
#   Rainmeter skin -> <Rainmeter skins folder>\TrayStylerForClaude (TrayGlass.exe compiled from source here)
#   shortcuts      -> Start menu, and Startup unless -NoStartup
# Undo everything with uninstall.ps1.
param(
    [switch]$NoStartup,     # don't start the usage service at sign-in
    [switch]$NoLaunch,      # don't start the service or load the skin now
    [string]$SkinRoot,      # override the Rainmeter skins folder (testing)
    [string]$AppRoot,       # override the service folder (testing)
    [string]$ShortcutRoot   # override where shortcuts go (testing)
)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Name = 'TrayStylerForClaude'

function Get-SkinRoot {
    $ini = Join-Path $env:APPDATA 'Rainmeter\Rainmeter.ini'
    if (Test-Path $ini) {
        $m = Select-String -Path $ini -Pattern '^\s*SkinPath\s*=\s*(.+?)\s*$' | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value.TrimEnd('\') }
    }
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Rainmeter\Skins'
}

function Get-Rainmeter {
    foreach ($p in "$env:ProgramFiles\Rainmeter\Rainmeter.exe", "${env:ProgramFiles(x86)}\Rainmeter\Rainmeter.exe") {
        if ($p -and (Test-Path $p)) { return $p }
    }
    $null
}

function New-Shortcut($path, $target, $arguments, $workDir) {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($path)
    $lnk.TargetPath = $target; $lnk.Arguments = $arguments; $lnk.WorkingDirectory = $workDir
    $lnk.Description = 'Windows 11 System Tray Styler for Claude (Claude usage service)'
    $lnk.Save()
}

$rainmeter = Get-Rainmeter
if (-not $rainmeter -and -not $SkinRoot) { throw 'Rainmeter is not installed. Install it from https://www.rainmeter.net, then run install.ps1 again.' }
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "C# compiler not found at $csc (.NET Framework 4.x is part of Windows 11)." }

if (-not $SkinRoot) { $SkinRoot = Get-SkinRoot }
if (-not $AppRoot) { $AppRoot = Join-Path $env:LOCALAPPDATA $Name }
$skinDir = Join-Path $SkinRoot $Name
$res = Join-Path $skinDir '@Resources'

# Stop our own running helper so its exe can be replaced (only the copy in this skin folder).
Get-Process TrayGlass -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($skinDir, 'OrdinalIgnoreCase') } | Stop-Process -Force

# 1. Usage service
New-Item -ItemType Directory -Force $AppRoot | Out-Null
Copy-Item (Join-Path $Here 'src\app\*') $AppRoot -Force
Write-Output "Service : $AppRoot"

# 2. Skin (keeps a backup of an existing .ini so local variable tweaks are not lost)
New-Item -ItemType Directory -Force $res | Out-Null
$ini = Join-Path $skinDir "$Name.ini"
if (Test-Path $ini) { Copy-Item $ini "$ini.bak" -Force; Write-Output "Backup  : $ini.bak" }
Copy-Item (Join-Path $Here "src\skin\$Name\*") $skinDir -Recurse -Force
& $csc -nologo -target:winexe "-out:$(Join-Path $res 'TrayGlass.exe')" (Join-Path $res 'TrayGlass.cs') | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'TrayGlass.exe failed to compile.' }
Write-Output "Skin    : $skinDir"

# 3. Shortcuts
$vbs = Join-Path $AppRoot 'StartTrayStyler.vbs'
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$menuDir = if ($ShortcutRoot) { $ShortcutRoot } else { [Environment]::GetFolderPath('Programs') }
$startDir = if ($ShortcutRoot) { $ShortcutRoot } else { [Environment]::GetFolderPath('Startup') }
New-Item -ItemType Directory -Force $menuDir | Out-Null
New-Shortcut (Join-Path $menuDir 'Tray Styler for Claude.lnk') $wscript "`"$vbs`"" $AppRoot
if (-not $NoStartup) {
    New-Item -ItemType Directory -Force $startDir | Out-Null
    New-Shortcut (Join-Path $startDir 'Tray Styler for Claude.lnk') $wscript "`"$vbs`"" $AppRoot
    Write-Output 'Startup : usage service starts at sign-in'
}

# 4. Fonts are optional (Windows substitutes a default), but the design uses Inter / Inter Display.
#    Read both font registries: per-user fonts are not listed by InstalledFontCollection.
$fonts = foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts') {
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    if ($p) { $p.PSObject.Properties.Name }
}
foreach ($f in 'Inter', 'Inter Display') { if (-not ($fonts -match "^$f (Regular|SemiBold|Medium)")) { Write-Warning "Font '$f' not installed; the bubble falls back to a default font. Get Inter from https://rsms.me/inter/" } }

# 5. Start now
if (-not $NoLaunch) {
    $busy = $null
    try { $busy = Get-NetTCPConnection -LocalPort 47823 -State Listen -ErrorAction Stop } catch {}
    if ($busy) { Write-Output 'Service : a usage service is already listening on 127.0.0.1:47823; the skin will use it.' }
    else { Start-Process $wscript "`"$vbs`"" }
    if ($rainmeter) {
        & $rainmeter '!RefreshApp'
        Start-Sleep -Seconds 2
        & $rainmeter '!ActivateConfig' $Name "$Name.ini"
        Write-Output 'Skin    : loaded in Rainmeter'
    }
}
Write-Output 'Done. Undo with uninstall.ps1.'

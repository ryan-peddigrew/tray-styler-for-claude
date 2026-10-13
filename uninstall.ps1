# Windows 11 System Tray Styler for Claude - uninstaller. Created by Ryan Peddigrew.
# Removes only what install.ps1 added. Never touches your Claude sign-in (~\.claude) or Windhawk.
param([string]$SkinRoot, [string]$AppRoot, [string]$ShortcutRoot)
$ErrorActionPreference = 'Stop'
$Name = 'TrayStylerForClaude'

if (-not $SkinRoot) {
    $SkinRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Rainmeter\Skins'
    $rini = Join-Path $env:APPDATA 'Rainmeter\Rainmeter.ini'
    if (Test-Path $rini) {
        $m = Select-String -Path $rini -Pattern '^\s*SkinPath\s*=\s*(.+?)\s*$' | Select-Object -First 1
        if ($m) { $SkinRoot = $m.Matches[0].Groups[1].Value.TrimEnd('\') }
    }
}
if (-not $AppRoot) { $AppRoot = Join-Path $env:LOCALAPPDATA $Name }
$skinDir = Join-Path $SkinRoot $Name

$rainmeter = @("$env:ProgramFiles\Rainmeter\Rainmeter.exe", "${env:ProgramFiles(x86)}\Rainmeter\Rainmeter.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($rainmeter -and -not $PSBoundParameters.ContainsKey('SkinRoot')) { & $rainmeter '!DeactivateConfig' $Name; Start-Sleep -Seconds 1 }

# Stop only our processes: the TrayGlass.exe in this skin folder and the service started from $AppRoot.
Get-Process TrayGlass -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($skinDir, 'OrdinalIgnoreCase') } | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf((Join-Path $AppRoot 'ClaudeUsageTray.ps1'), [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

$menuDir = if ($ShortcutRoot) { $ShortcutRoot } else { [Environment]::GetFolderPath('Programs') }
$startDir = if ($ShortcutRoot) { $ShortcutRoot } else { [Environment]::GetFolderPath('Startup') }
foreach ($p in (Join-Path $menuDir 'Tray Styler for Claude.lnk'), (Join-Path $startDir 'Tray Styler for Claude.lnk'), $skinDir, $AppRoot) {
    if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Output "Removed $p" }
}
Write-Output 'Tray Styler for Claude is uninstalled.'

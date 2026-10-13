# Windows 11 System Tray Styler for Claude - runs the offline checks, then packages dist\TrayStylerForClaude-<version>.zip.
# Ships source only: install.ps1 compiles TrayGlass.exe on the user's PC.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ver = ([regex]::Match((Get-Content -Raw "$Root\src\skin\TrayStylerForClaude\TrayStylerForClaude.ini"), '(?m)^Version=(\S+)')).Groups[1].Value

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Root\tests\Test-Project.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Checks failed; not packaging.' }

$stage = Join-Path $Root "dist\TrayStylerForClaude-$ver"
Remove-Item $stage, "$stage.zip" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item "$Root\README.md", "$Root\CHANGELOG.md", "$Root\install.ps1", "$Root\uninstall.ps1" $stage
Copy-Item "$Root\src" $stage -Recurse
Get-ChildItem $stage -Recurse -Include *.exe, *.log, *.bak | Remove-Item -Force
Compress-Archive -Path "$stage\*" -DestinationPath "$stage.zip"
Remove-Item $stage -Recurse -Force
Write-Output "Packaged $stage.zip"

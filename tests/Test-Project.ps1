# Windows 11 System Tray Styler for Claude - checks that run without changing the desktop.
#   -Live also runs the usage service once on a spare port (-Check mode: reads your Claude sign-in,
#   prints only percentages, reset countdowns and status; never the token).
param([switch]$Live)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:Fail = 0
function Assert($ok, $what) {
    if ($ok) { Write-Output "PASS  $what" } else { Write-Output "FAIL  $what"; $script:Fail++ }
}

# 1. PowerShell syntax
foreach ($f in Get-ChildItem $Root -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\dist\\' }) {
    $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
    Assert ($e.Count -eq 0) "parses: $($f.Name)"
}

# 2. TrayGlass.cs compiles (to a temp folder)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("tsfc-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$out = & $csc -nologo -warn:4 -target:winexe "-out:$tmp\TrayGlass.exe" "$Root\src\skin\TrayStylerForClaude\@Resources\TrayGlass.cs" 2>&1
Assert ($LASTEXITCODE -eq 0 -and (Test-Path "$tmp\TrayGlass.exe")) "TrayGlass.cs compiles $(if ($out) { "($out)" })"

# 3. Skin .ini structure
$ini = Get-Content "$Root\src\skin\TrayStylerForClaude\TrayStylerForClaude.ini"
$bad = $ini | Where-Object { $_ -match '^\[[^\]]+\]\S' }
Assert (-not $bad) 'skin: every [section] header is on its own line'
$sections = @{}; $cur = $null
foreach ($l in $ini) {
    if ($l -match '^\[([^\]]+)\]\s*$') { $cur = $Matches[1]; $sections[$cur] = @() }
    elseif ($cur -and $l -match '^([A-Za-z0-9]+)=') { $sections[$cur] += $Matches[1] }
}
foreach ($s in $sections.Keys) {
    if ($s -like 'Meter*') { Assert ($sections[$s] -contains 'Meter') "skin: [$s] has Meter=" }
    elseif ($s -cmatch '^m[A-Z]') { Assert ($sections[$s] -contains 'Measure') "skin: [$s] has Measure=" }
}
Assert (-not ($ini -match 'Ryan Peddigrew\\|C:\\Users')) 'skin: no hard-coded user paths'
Assert (-not ((Get-Content -Raw "$Root\src\skin\TrayStylerForClaude\@Resources\TrayGlass.cs") -match 'C:\\Users')) 'TrayGlass.cs: no hard-coded user paths'

# 4. Feed countdown formatting (the C# class embedded in the service)
$svc = Get-Content -Raw "$Root\src\app\ClaudeUsageTray.ps1"
Assert (-not ($svc -match 'C:\\Users')) 'service: no hard-coded user paths'
$cs = [regex]::Match($svc, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?public static class UsageFeed.*?)\r?\n'@").Groups[1].Value
Add-Type -TypeDefinition ($cs -replace 'class UsageFeed', 'class UsageFeedTest')
$now = [DateTime]::UtcNow.Ticks
Assert ([UsageFeedTest]::Short(0) -eq '') 'countdown: unknown -> empty'
Assert ([UsageFeedTest]::Short($now + [TimeSpan]::FromSeconds(30).Ticks) -eq 'now') 'countdown: <1 min -> now'
Assert ([UsageFeedTest]::Short($now + [TimeSpan]::FromMinutes(149.5).Ticks) -eq '2h 29m') 'countdown: 2h 29m'
Assert ([UsageFeedTest]::Short($now + [TimeSpan]::FromHours(100.5).Ticks) -eq '4d 4h') 'countdown: 4d 4h'

# 5. Skin regex vs a sample feed body (PCRE (?siU) approximated with .NET lazy groups)
$rx = ([regex]::Match(($ini -join "`n"), '(?m)^RegExp=\(\?siU\)(.+)$').Groups[1].Value) -replace '\(\.\*\)', '(.*?)' -replace '\.\*<', '.*?<'
$sample = "<s>x</s>`n<w>x</w>`n<hs>Current ?</hs>`n<hw>Weekly ?</hw>`n<sp>-1</sp>`n<wp>80</wp>`n<scd></scd>`n<wcd>6d 4h</wcd>`n<st>Sign-in expired</st>"
$m = [regex]::Match($sample, "(?si)$rx")
Assert ($m.Success -and $m.Groups[1].Value -eq '-1' -and $m.Groups[2].Value -eq '80' -and $m.Groups[4].Value -eq '6d 4h' -and $m.Groups[5].Value -eq 'Sign-in expired') 'skin regex parses a feed with missing data'

# 6. Live service check on a spare port
if ($Live) {
    $o = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "$Root\src\app\ClaudeUsageTray.ps1" -Check -Port 47899
    $code = $LASTEXITCODE
    $o | ForEach-Object { "      $_" }
    $txt = $o -join "`n"
    Assert ($txt -notmatch 'sk-ant-|Bearer') 'live: output has no token'
    $lm = [regex]::Match($txt, "(?si)$rx")
    Assert ($lm.Success) 'live: feed body matches the skin regex'
    Assert ($code -eq 0) 'live: usage data available (exit 0; 1 = no data, see status line)'
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
if ($script:Fail) { Write-Output "$($script:Fail) check(s) failed"; exit 1 } else { Write-Output 'All checks passed' }

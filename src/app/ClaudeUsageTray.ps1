# Windows 11 System Tray Styler for Claude - usage service. Created by Ryan Peddigrew.
# Claude plan usage in the Windows tray: two icons (5h session, 7d week), plus a tiny loopback feed
# read by the TrayStylerForClaude Rainmeter skin (<sp>/<wp>/<scd>/<wcd>/<st> tags) and, optionally,
# Windhawk Taskbar Clock Customization (%web1%/%web2% colour dots, %web3%/%web4% hover lines).
# Source: GET https://api.anthropic.com/api/oauth/usage with the Claude Code sign-in
# (~/.claude/.credentials.json), read-only. The token is never logged, shown or written.
# Fallback: the Claude desktop app's cached sample (plan-usage-history.json) if recent.
# Load: one fetch every 5 min (plus on hover/click if over a minute old); no polling loops.
# The feed server is a blocking background thread.
# -Check: fetch once, print the feed body (never the token) via a self-request on -Port, then exit.

param([switch]$Check, [int]$Port = 47823)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Same name as the original ClaudeUsageTray, so the two never run side by side (they share the port).
$mutex = New-Object Threading.Mutex($false, 'Local\ClaudeUsageTray')
if (-not $Check -and -not $mutex.WaitOne(0)) { exit }

Add-Type -Namespace CUT -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
'@
[void][CUT.Native]::SetProcessDPIAware()
$script:IconPx = [Math]::Max(16, [CUT.Native]::GetSystemMetrics(49))  # SM_CXSMICON

# Loopback-only HTTP feed for the Windhawk clock. Blocks in Accept() on its own thread (no polling);
# "{CD}", "{SCD}" and "{WCD}" in the body are replaced at request time with live countdowns.
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public static class UsageFeed {
    static volatile string body = "<s>?</s>\n<w>?</w>";
    static long resetTicks;   // session reset, UTC ticks; 0 = unknown
    static long weekTicks;    // weekly reset, UTC ticks; 0 = unknown
    static TcpListener listener;

    public static void Set(string newBody, long newResetTicks, long newWeekTicks) {
        body = newBody;
        Interlocked.Exchange(ref resetTicks, newResetTicks);
        Interlocked.Exchange(ref weekTicks, newWeekTicks);
    }

    // "2h 29m", "6d 4h" (a day or more), "now", or "" if unknown.
    public static string Short(long t) {
        if (t == 0) return "";
        TimeSpan span = new TimeSpan(t - DateTime.UtcNow.Ticks);
        if (span.TotalMinutes < 1) return "now";
        if (span.TotalDays >= 1) return string.Format("{0}d {1}h", (int)Math.Floor(span.TotalDays), span.Hours);
        return string.Format("{0}h {1}m", (int)Math.Floor(span.TotalHours), span.Minutes);
    }

    public static string Countdown() {
        string s = Short(Interlocked.Read(ref resetTicks));
        if (s == "") return "";
        return s == "now" ? "resets now" : "resets in " + s;
    }

    public static string Render() {
        return body.Replace("{CD}", Countdown())
                   .Replace("{SCD}", Short(Interlocked.Read(ref resetTicks)))
                   .Replace("{WCD}", Short(Interlocked.Read(ref weekTicks)));
    }

    public static bool Start(int port) {
        try {
            listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            Thread th = new Thread(Serve);
            th.IsBackground = true;
            th.Start();
            return true;
        } catch { return false; }
    }

    static void Serve() {
        byte[] buf = new byte[4096];
        while (true) {
            TcpClient c = null;
            try {
                c = listener.AcceptTcpClient();
                c.ReceiveTimeout = 1000;
                NetworkStream s = c.GetStream();
                s.Read(buf, 0, buf.Length);   // request line + headers; same content for any path
                byte[] b = Encoding.UTF8.GetBytes(Render());
                byte[] h = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-cache\r\nContent-Length: " + b.Length + "\r\nConnection: close\r\n\r\n");
                s.Write(h, 0, h.Length);
                s.Write(b, 0, b.Length);
            } catch { }
            finally { if (c != null) c.Close(); }
        }
    }
}
'@

$Dir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile   = Join-Path $Dir 'tray.log'
$CredFile  = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$CacheFile = Join-Path $env:APPDATA 'Claude\plan-usage-history.json'
$UsageUrl  = 'https://api.anthropic.com/api/oauth/usage'
$LocalTz   = [TimeZoneInfo]::Local   # times shown in the PC's own time zone
$ReSignIn  = 'Sign-in expired: run claude once to re-sign-in'
$RefreshMinutes = 5

# Errors only; capped at 200 KB.
function Write-Log($msg) {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 200KB) { Remove-Item $LogFile -Force }
        Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding utf8
    } catch {}
}

function Get-LocalNow { [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $LocalTz).DateTime }

function Format-Reset($iso) {
    if (-not $iso) { return '' }
    $dto = [DateTimeOffset]::Parse([string]$iso, [Globalization.CultureInfo]::InvariantCulture)
    $t = [TimeZoneInfo]::ConvertTime($dto, $LocalTz).DateTime
    $f = if ($t.Date -eq (Get-LocalNow).Date) { 'h:mmtt' } else { 'ddd h:mmtt' }
    $t.ToString($f).Replace('AM', 'am').Replace('PM', 'pm')
}

# ---------- data ----------

# Returns @{ session; sessionReset; week; weekReset; extras[]; note }
function Get-Usage {
    $o = $null
    try { if (Test-Path $CredFile) { $o = (Get-Content $CredFile -Raw | ConvertFrom-Json).claudeAiOauth } }
    catch { Write-Log "credentials unreadable: $($_.Exception.Message)" }
    if (-not $o -or -not $o.accessToken) { return Get-CachedUsage 'Not signed in: right-click > Sign in' }
    if ($o.expiresAt -and [int64]$o.expiresAt -lt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { return Get-CachedUsage $ReSignIn }

    $h = @{ Authorization = "Bearer $($o.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20'; 'User-Agent' = 'tray-styler-for-claude/0.1' }
    try { $u = Invoke-RestMethod -Uri $UsageUrl -Headers $h -TimeoutSec 15 }
    catch {
        $code = $null; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        Write-Log "usage call failed ($code): $($_.Exception.Message)"
        if ($code -eq 401 -or $code -eq 403) { return Get-CachedUsage $ReSignIn }
        return Get-CachedUsage "Fetch failed ($code), retrying in $RefreshMinutes min"
    }

    $res = @{ extras = @(); note = '' }
    if ($u.five_hour) { $res.session = [double]$u.five_hour.utilization; $res.sessionReset = $u.five_hour.resets_at }
    if ($u.seven_day) { $res.week = [double]$u.seven_day.utilization; $res.weekReset = $u.seven_day.resets_at }
    # Per-model weekly windows (Opus, Sonnet, ...) and anything else shaped like a limit.
    foreach ($p in $u.PSObject.Properties) {
        if ($p.Name -in 'five_hour', 'seven_day', 'extra_usage') { continue }
        $v = $p.Value
        if ($v -is [psobject] -and $v.PSObject.Properties['utilization'] -and $null -ne $v.utilization) {
            $name = (Get-Culture).TextInfo.ToTitleCase(($p.Name -replace '^seven_day_', '' -replace '_', ' '))
            $res.extras += ('{0} {1:0}%' -f $name, [double]$v.utilization)
        }
    }
    $x = $u.extra_usage
    if ($x -and $x.is_enabled) {
        if ($null -ne $x.utilization) { $res.extras += ('Extra {0:0}%' -f [double]$x.utilization) }
        else { $res.extras += 'Extra on' }
    }
    $res
}

function Get-CachedUsage($why) {
    $res = @{ extras = @(); note = $why }
    try {
        $s = (Get-Content $CacheFile -Raw | ConvertFrom-Json).samples | Sort-Object t | Select-Object -Last 1
        $at = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$s.t)
        if (([DateTimeOffset]::UtcNow - $at).TotalHours -le 2) {
            $res.session = [double]$s.u.fh; $res.week = [double]$s.u.sd
            $res.note = "$why. App cache $([TimeZoneInfo]::ConvertTime($at, $LocalTz).ToString('h:mmtt').ToLower())"
        }
    } catch {}
    $res
}

# ---------- drawing ----------

# Four tiers, used everywhere: 0 = under 30, 1 = 30-59, 2 = 60-84, 3 = 85+.
function Get-Tier($pct) {
    if ($pct -ge 85) { 3 } elseif ($pct -ge 60) { 2 } elseif ($pct -ge 30) { 1 } else { 0 }
}

function Get-Colour($pct) {
    if ($null -eq $pct) { return [Drawing.Color]::FromArgb(170, 170, 170) }
    switch (Get-Tier $pct) {
        3 { [Drawing.Color]::FromArgb(255, 85, 75) }     # red
        2 { [Drawing.Color]::FromArgb(255, 150, 40) }    # orange
        1 { [Drawing.Color]::FromArgb(255, 210, 50) }    # yellow
        0 { [Drawing.Color]::FromArgb(197, 224, 122) }   # lime
    }
}

# Draws a small label ("5h"/"7d"), then e.g. "42%" in its tier colour, then a tiny progress bar
# (purple track, coloured fill).
function New-UsageIcon($pct, [string]$label) {
    $n = $script:IconPx
    $bmp = New-Object Drawing.Bitmap($n, $n)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)
    $digits = if ($null -eq $pct) { '?' } else { [string][Math]::Min(999, [int][Math]::Round($pct)) }

    $fam = New-Object Drawing.FontFamily('Arial')
    $origin = New-Object Drawing.PointF(0, 0)
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddString($digits, $fam, [int][Drawing.FontStyle]::Bold, 100, $origin, [Drawing.StringFormat]::GenericTypographic)
    $db = $path.GetBounds()
    $pp = New-Object Drawing.Drawing2D.GraphicsPath
    if ($null -ne $pct) {
        $pp.AddString('%', $fam, [int][Drawing.FontStyle]::Bold, 62, $origin, [Drawing.StringFormat]::GenericTypographic)
        $pb = $pp.GetBounds()
        $m = New-Object Drawing.Drawing2D.Matrix
        $m.Translate(($db.Right + 6 - $pb.X), ($db.Y - $pb.Y))   # smaller %, top-aligned after the digits
        $pp.Transform($m)
        $path.AddPath($pp, $false)
    }

    $b = $path.GetBounds()
    $barH = [Math]::Max(3, [int][Math]::Round($n / 7))
    $labelH = [Math]::Max(5, [int][Math]::Round($n * 0.3))
    $top = $labelH + 1
    $availH = $n - $barH - 1 - $top
    $sx = $n / $b.Width
    $sy = [Math]::Min($availH / $b.Height, $sx * 1.9)   # allow tall, narrow glyphs
    $m = New-Object Drawing.Drawing2D.Matrix
    $m.Translate(0, $top + ($availH - $b.Height * $sy) / 2)
    $m.Scale($sx, $sy)
    $m.Translate(-$b.X, -$b.Y)
    $path.Transform($m)

    # Small window label on top ("5h" / "7d"), centred.
    $lp = New-Object Drawing.Drawing2D.GraphicsPath
    $lp.AddString($label, $fam, [int][Drawing.FontStyle]::Bold, 100, $origin, [Drawing.StringFormat]::GenericTypographic)
    $lb = $lp.GetBounds()
    $ls = [Math]::Min($labelH / $lb.Height, ($n * 0.8) / $lb.Width)
    $m = New-Object Drawing.Drawing2D.Matrix
    $m.Translate(($n - $lb.Width * $ls) / 2, 0)
    $m.Scale($ls, $ls)
    $m.Translate(-$lb.X, -$lb.Y)
    $lp.Transform($m)
    $lbrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(205, 200, 215))
    $g.FillPath($lbrush, $lp)
    $lbrush.Dispose(); $lp.Dispose()

    $text = New-Object Drawing.SolidBrush((Get-Colour $pct))
    $g.FillPath($text, $path)
    $track = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(74, 63, 92))
    $fill  = New-Object Drawing.SolidBrush((Get-Colour $pct))
    $g.SmoothingMode = 'None'
    $g.FillRectangle($track, 0, $n - $barH, $n, $barH)
    if ($null -ne $pct -and $pct -gt 0) {
        $w = [Math]::Max(1, [int][Math]::Round($n * [Math]::Min(100, $pct) / 100))
        $g.FillRectangle($fill, 0, $n - $barH, $w, $barH)
    }
    $g.Dispose(); $text.Dispose(); $track.Dispose(); $fill.Dispose(); $path.Dispose(); $pp.Dispose()
    $hIcon = $bmp.GetHicon()
    $bmp.Dispose()
    [Drawing.Icon]::FromHandle($hIcon)
}

function Set-TrayIcon($ni, $icon) {
    $old = $ni.Icon
    $ni.Icon = $icon
    if ($old) { [void][CUT.Native]::DestroyIcon($old.Handle); $old.Dispose() }
}

# NotifyIcon.Text is capped at 63 chars; set the private field to get the shell's 127.
function Set-TrayText($ni, [string]$text) {
    if ($text.Length -gt 127) { $text = $text.Substring(0, 127) }
    $flags = [Reflection.BindingFlags]'NonPublic,Instance'
    $t = [Windows.Forms.NotifyIcon]
    $t.GetField('text', $flags).SetValue($ni, $text)
    if ($t.GetField('added', $flags).GetValue($ni)) { [void]$t.GetMethod('UpdateIcon', $flags).Invoke($ni, @($true)) }
}

# ---------- UI ----------

$niSession = New-Object Windows.Forms.NotifyIcon
$niWeek    = New-Object Windows.Forms.NotifyIcon
$script:Last  = @{ extras = @(); note = '' }
$script:TipAt = [DateTime]::MinValue
$script:FetchedAt = [DateTime]::MinValue

function Format-Pct($pct) { if ($null -eq $pct) { '?' } else { '{0:0}%' -f $pct } }

# Colour dot for the clock line, matching the icon tiers: green, yellow, orange, red.
function Get-Dot($pct) {
    if ($null -eq $pct) { return [char]::ConvertFromUtf32(0x26AA) }
    [char]::ConvertFromUtf32((0x1F7E2, 0x1F7E1, 0x1F7E0, 0x1F534)[(Get-Tier $pct)])
}

# "Current 72% · resets in 2h 26m" (countdown is "{CD}" for the feed, filled in per request).
function Format-Current($pct, [string]$countdown) {
    if ($null -eq $pct) { return 'Current ?' }
    $s = 'Current {0:0}%' -f $pct
    if ($countdown) { $s += " $([char]0x00B7) $countdown" }
    $s
}

# "Weekly 33% · resets Sun 3:00am"
function Format-Weekly($pct, $reset) {
    if ($null -eq $pct) { return 'Weekly ?' }
    $s = 'Weekly {0:0}%' -f $pct
    if ($reset) { $s += " $([char]0x00B7) resets $(Format-Reset $reset)" }
    $s
}

# Tray hover text; rebuilt from stored data (no network) so the countdown is current when hovered.
function Update-Tips {
    $d = $script:Last
    $cur = Format-Current $d.session ([UsageFeed]::Countdown())
    $wk  = Format-Weekly $d.week $d.weekReset
    $tail = @((Get-LocalNow).ToString('ddd MMM d'))
    if ($d.extras.Count) { $tail += ($d.extras -join ' | ') }
    if ($d.note) { $tail += $d.note }
    Set-TrayText $niSession ((@($cur, $wk) + $tail) -join "`n")
    Set-TrayText $niWeek    ((@($wk, $cur) + $tail) -join "`n")
    $script:TipAt = Get-Date
}

function Update-Tray {
    try { $d = Get-Usage } catch { Write-Log "update failed: $($_.Exception.Message)"; $d = @{ extras = @(); note = 'Error: see tray.log' } }
    $script:Last = $d
    $script:FetchedAt = Get-Date
    Set-TrayIcon $niSession (New-UsageIcon $d.session '5h')
    Set-TrayIcon $niWeek    (New-UsageIcon $d.week '7d')

    Set-Feed $d
    Update-Tips
    [GC]::Collect()
}

function Get-UtcTicks($iso) {
    if (-not $iso) { return [int64]0 }
    try { [DateTimeOffset]::Parse([string]$iso, [Globalization.CultureInfo]::InvariantCulture).UtcTicks } catch { [int64]0 }
}

# Whole percent for the skin, or -1 when unknown (the skin shows a dash and a grey ring).
function Format-Num($pct) { if ($null -eq $pct) { '-1' } else { '{0:0}' -f [Math]::Min(100, [Math]::Max(0, [double]$pct)) } }

function Set-Feed($d) {
    $resetTicks = Get-UtcTicks $d.sessionReset
    $countdown = if ($resetTicks) { '{CD}' } else { '' }
    $status = if ($d.note) { $d.note } else { 'OK' }
    [UsageFeed]::Set((@(
        # Windhawk clock colour dots: session after the date, week after the time.
        "<s>$(Get-Dot $d.session)</s>",
        "<w>$(Get-Dot $d.week)</w>",
        # Windhawk clock hover lines.
        "<hs>$(Format-Current $d.session $countdown)</hs>",
        "<hw>$(Format-Weekly $d.week $d.weekReset)</hw>",
        # Skin fields: percents, short live countdowns, and a status line (OK or why data is missing/stale).
        "<sp>$(Format-Num $d.session)</sp>",
        "<wp>$(Format-Num $d.week)</wp>",
        "<scd>{SCD}</scd>",
        "<wcd>{WCD}</wcd>",
        "<st>$([Security.SecurityElement]::Escape([string]$status))</st>"
    ) -join "`n"), $resetTicks, (Get-UtcTicks $d.weekReset))
}

function Start-SignIn {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    $exe = Get-ChildItem (Join-Path $env:APPDATA 'Claude\claude-code') -Recurse -Filter claude.exe -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $target = if ($cmd) { $cmd.Source } elseif ($exe) { $exe.FullName } else { $null }
    if (-not $target) { [void][Windows.Forms.MessageBox]::Show('Claude Code not found. Install it, then run "claude" once to sign in.', 'Claude usage'); return }
    Start-Process -FilePath $target -WorkingDirectory $env:USERPROFILE
}

if ($Check) {
    if (-not [UsageFeed]::Start($Port)) { Write-Output "Port $Port is in use (tray already running? use -Port 47899)"; exit 2 }
    $d = Get-Usage
    Set-Feed $d
    (Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/" -TimeoutSec 5).Content
    if ($d.extras.Count) { 'Extras: ' + ($d.extras -join ' | ') }
    exit $(if ($null -ne $d.session) { 0 } else { 1 })
}

if (-not [UsageFeed]::Start($Port)) { Write-Log "feed listener failed to start (port $Port in use?)" }

$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Refresh', $null, { Update-Tray })
[void]$menu.Items.Add('Open claude.ai/settings/usage', $null, { Start-Process 'https://claude.ai/settings/usage' })
[void]$menu.Items.Add('Sign in to Claude Code...', $null, { Start-SignIn })
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Exit', $null, { $niSession.Visible = $false; $niWeek.Visible = $false; [Windows.Forms.Application]::Exit() })

foreach ($ni in $niWeek, $niSession) {
    $ni.ContextMenuStrip = $menu
    $ni.Text = 'Claude usage'
    $ni.Icon = New-UsageIcon $null $(if ($ni -eq $niWeek) { '7d' } else { '5h' })
    $ni.Visible = $true
    $ni.add_MouseClick({ param($s, $e) if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Update-Tray } })
    # Hover: fresh numbers if the last fetch is over a minute old; otherwise just refresh the countdown.
    $ni.add_MouseMove({
        if (((Get-Date) - $script:FetchedAt).TotalSeconds -ge 60) { Update-Tray }
        elseif (((Get-Date) - $script:TipAt).TotalSeconds -ge 20) { Update-Tips }
    })
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = $RefreshMinutes * 60 * 1000
$timer.add_Tick({ Update-Tray })
$timer.Start()

Update-Tray
[Windows.Forms.Application]::Run()
$timer.Stop(); $niSession.Dispose(); $niWeek.Dispose(); $mutex.ReleaseMutex()

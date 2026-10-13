# Windows 11 System Tray Styler for Claude

Created by **Ryan Peddigrew**.

A glass bubble for the Windows 11 notification area that shows your Claude plan usage (5-hour session and 7-day week) as two rings with live reset countdowns, next to a clean clock and a small battery line. It matches a dark, blurred taskbar and slides with an auto-hide taskbar.

Version 0.1.0 (pre-release).

## What it is made of

| Part | What it does |
|---|---|
| `src/app/ClaudeUsageTray.ps1` | Usage service. Reads your usage once every 5 minutes, shows two small tray icons (5h / 7d) with hover details, and serves a tiny feed on `http://127.0.0.1:47823/` (this PC only). |
| `src/app/StartTrayStyler.vbs` | Starts the service hidden (used by the Start menu and Startup shortcuts). |
| `src/skin/TrayStylerForClaude/` | Rainmeter skin: the glass bubble with rings, countdowns, clock, date and battery. |
| `@Resources/TrayGlass.cs` | Small helper compiled at install time. Adds blur and rounded corners, keeps the bubble aligned to the taskbar's right edge, and follows the auto-hide slide (event-driven, no polling). Clicking the clock opens the Windows calendar flyout. |

This is not a Windhawk mod. See [Release path](#release-path-and-windhawk).

## Requirements

- Windows 11
- [Rainmeter](https://www.rainmeter.net) 4.5 or later
- Claude Code installed and signed in once (`claude`), which stores the sign-in the service reads
- Optional: the [Inter](https://rsms.me/inter/) and Inter Display fonts (the design uses them; Windows substitutes a default font without them)

## Install

1. Download and unzip the release.
2. Right-click the folder background, choose **Open in Terminal**, and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

The installer is per-user and needs no admin rights. It copies the service to `%LOCALAPPDATA%\TrayStylerForClaude`, copies the skin to your Rainmeter skins folder, compiles `TrayGlass.exe` from the included source with the C# compiler built into Windows, adds a Start menu shortcut and a Startup shortcut, starts the service and loads the skin. It does not change the registry, Windhawk, or any Windows setting.

Options: `-NoStartup` (don't start at sign-in), `-NoLaunch` (install only).

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

This unloads the skin, stops only the Tray Styler processes, and removes the files and shortcuts the installer added. Your Claude sign-in is never touched.

## Configure

Edit `TrayStylerForClaude.ini` in your Rainmeter skins folder (right-click the bubble > Edit skin), then refresh the skin.

| Variable | Default | Meaning |
|---|---|---|
| `RightGap` | `6` | Physical px between the bubble's right edge and the taskbar's right edge. |
| `TopOffset` | `4` | Physical px from the taskbar top to the bubble top. `4` suits a floating dock made with Windhawk Taskbar Styler; use `0` for the stock taskbar. |
| `Font`, `ClockFont` | `Inter`, `Inter Display` | Fonts. |
| `Green`, `Yellow`, `Orange`, `Red` | | Ring colours for under 30%, 30-59%, 60-84%, 85%+. |
| `Tint` | `16,16,16,164` | Glass tint (RGBA). |
| `UsageUrl` | `http://127.0.0.1:47823/` | Where the skin reads the feed. |

After changing `RightGap` or `TopOffset`, restart Rainmeter so the running helper picks them up.

The bubble sits on top of the notification area's clock. To avoid seeing the native clock behind it, you can hide it with Windhawk's *Taskbar Clock Customization* mod. That is optional and is not done by the installer.

## How usage is read

- Source: `GET https://api.anthropic.com/api/oauth/usage` (an undocumented endpoint), called read-only with the Claude Code sign-in from `%USERPROFILE%\.claude\.credentials.json`.
- The token is only sent to `api.anthropic.com`. It is never logged, displayed, written anywhere, or sent to the local feed.
- If the sign-in has expired or the call fails, the service falls back to the Claude desktop app's cached sample (`%APPDATA%\Claude\plan-usage-history.json`) when it is under 2 hours old, and says so in the status line. Otherwise it shows `-` with grey rings. It never invents numbers.
- Hover over the rings for the status line ("OK", or why data is missing). Click the rings to open claude.ai/settings/usage.

## Limitations

- The usage endpoint is not a documented public API. It can change or stop working without notice; the bubble then shows `-` and a status message.
- The service does not refresh an expired sign-in itself. Running `claude` once refreshes it (right-click a tray icon > **Sign in to Claude Code...**).
- Reset countdowns need the live API; the desktop app cache provides percentages only.
- Primary monitor only. Placement is tuned for a bottom taskbar.
- Only one usage service runs at a time on port 47823 (a second copy exits).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Rings show `-`, hover says "Usage service not running" | Start **Tray Styler for Claude** from the Start menu. |
| Hover says "Sign-in expired" | Run `claude` once in a terminal, then left-click a tray icon to refresh. |
| Check the data directly | `powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\TrayStylerForClaude\ClaudeUsageTray.ps1" -Check -Port 47899` prints the feed (never the token). Exit code 0 = data available. |
| Errors | `%LOCALAPPDATA%\TrayStylerForClaude\tray.log` (errors only, capped at 200 KB). |
| Bubble in the wrong place | Adjust `RightGap` / `TopOffset`, then restart Rainmeter. |
| No blur | Make sure `TrayGlass.exe` exists in the skin's `@Resources` folder (run `install.ps1` again). |

## Development

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Test-Project.ps1        # offline checks
powershell -ExecutionPolicy Bypass -File .\tests\Test-Project.ps1 -Live  # also reads live usage once on port 47899
powershell -ExecutionPolicy Bypass -File .\build.ps1                     # tests + dist\TrayStylerForClaude-<version>.zip
```

## Release path and Windhawk

Windhawk mods are single C++ files that Windhawk injects into Windows processes, submitted as pull requests to the `ramensoftware/windhawk-mods` repository. This project is a Rainmeter skin plus a PowerShell service and a small C# helper, so it cannot be submitted to Windhawk as-is. Publishing there would mean rewriting the bubble as a native C++ explorer mod, which is a separate project.

The fitting release path is a GitHub release with the zip from `build.ps1`, installed with `install.ps1`.

## License

No license has been chosen yet. Until one is added, all rights are reserved by Ryan Peddigrew.

Claude is a trademark of Anthropic. This project is not made or endorsed by Anthropic.

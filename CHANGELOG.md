# Changelog

## 0.1.0 - 2026-10-13 (pre-release)

First packaged version of Ryan Peddigrew's personal tray setup (Rainmeter skin "TrayExtras", ClaudeUsageTray service, TrayGlass helper).

### Added
- `install.ps1` / `uninstall.ps1`: per-user install and clean removal; TrayGlass.exe is compiled from source at install.
- Usage service `-Check` mode: one fetch, prints the feed (never the token), exit code shows whether data is available.
- Feed fields for the skin: `<sp>`, `<wp>` (percent or -1), `<scd>`, `<wcd>` (live countdowns), `<st>` (status).
- Hover status on the rings ("OK", sign-in expired, service not running); click opens claude.ai/settings/usage.
- Grey rings and `-` when no data is available instead of stale or zero values.
- `RightGap` / `TopOffset` skin variables; the bubble now aligns itself to the taskbar's right edge.
- `tests/Test-Project.ps1` and `build.ps1`.

### Fixed
- `[MeterClockHit]` section header and `Meter=` were on one line, so the clock click target was not a valid meter.
- Weekly countdown was blank on the day of the weekly reset (the reset text dropped the weekday); the service now computes both countdowns.
- Skin made three separate feed requests a minute; now one.
- Hard-coded `C:\Users\...` paths in the skin, launcher and helper.
- Hard-coded Eastern time zone; times now use the PC's time zone.
- Window lookup in TrayGlass now handles non-ASCII skin paths.

### Removed
- `Reset.lua` (weekly countdown now comes from the service).

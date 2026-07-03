# Changelog

All notable changes to this project will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/)

## [Unreleased]

## [0.2.15] - 2026-07-03

### Added
- Show the release commit SHA and release date in the About window
- Show the current release commit SHA and release date in update-check results

### Fixed
- Show Activity chart hover hours as explicit one-hour ranges

## [0.2.14] - 2026-06-23

### Added
- Show exact hourly token values when hovering inside the Activity hourly chart
- Include the hourly request count in the Activity chart hover tooltip

### Fixed
- Show Activity hourly chart x-axis labels every 3 hours from 0h through 21h
- Keep Activity hover tooltips inside the heatmap width so right-edge text is not clipped

## [0.2.13] - 2026-06-21

### Changed
- Limit General sync interval choices to 10s, 30s, 60s, and Never
- Refresh project documentation for the current settings UI, Activity drill-down, Codex sync behavior, and release workflow

## [0.2.12] - 2026-06-21

### Fixed
- Normalize Codex input tokens by excluding cached input before calculating Input Tokens and Cache Hit

## [0.2.11] - 2026-06-21

### Fixed
- Persist Codex cumulative token totals in sync state to prevent cross-batch heartbeat rows from shifting request counts

## [0.2.10] - 2026-06-21

### Added
- Activity heatmap mode toggle: "Default" (trailing 365 days) and per-year view
- Trailing mode shows a GitHub-style rolling window ending today with cross-year month labels
- Tap Activity header to dismiss the hourly token chart

## [0.2.9] - 2026-06-21

### Changed
- Activity token charts now use a fixed-height drawer below the heatmap
- Clicking an Activity day now filters the whole panel to that day while opening the token chart
- Switching the app filter no longer dismisses the Activity token chart
- Shared window frame tracking between Activity and filter controls
- Kept Activity chart click-exclusion frame state local to the popover UI

## [0.2.8] - 2026-06-21

### Fixed
- Old app instance now force-exits after update restart to prevent duplicate menu bar icons

## [0.2.7] - 2026-06-20

### Added
- Activity days now expand to an hourly Input Tokens, Output Tokens, and Cache Read line chart
- Clicking outside the Activity area now hides the selected-day detail
- Activity no longer shows the token chart when the selected day has no token usage
- Activity days with no data are no longer selectable or highlighted

## [0.2.6] - 2026-06-20

### Fixed
- Restart after update now uses a detached launcher so the new app starts after the old process exits

## [0.2.5] - 2026-06-20

### Added
- Date range dropdown with one-row presets and calendar-based single-day or range selection

### Changed
- Enlarged calendar day hit targets in the date range dropdown
- Removed the border from the date range button
- Aligned the date range dropdown arrow closer to the end date
- Removed the selected date summary from the bottom of the date range dropdown
- Reduced the date range dropdown width and realigned its arrow to the start of the end date
- Shifted the date range dropdown lower and reduced its compact calendar size

### Fixed
- Prevented the date range dropdown from jittering when selecting preset ranges
- Show a single date in the filter bar when a custom range starts and ends on the same day
- Clear calendar selection highlights when choosing preset ranges
- Show `Today` in the filter bar after selecting the Today preset

## [0.2.4] - 2026-06-20

### Fixed
- Restart after update now waits for the old process to exit before launching the new app bundle

## [0.2.3] - 2026-06-20

### Added
- Save confirmation dialog for General, Config, and Prompt settings pages
- Green top saved toast after confirmed settings saves

## [0.2.2] - 2026-06-20

### Fixed
- Dual menu bar instances after update when Keep in Background is enabled
- Config and Prompt editor text hidden in installed release app
- Nested scrollbars in Config and Prompt editor pages
- Prevent debug executable runs from registering MonitorAgent as a login item
- Read About and update-check versions from the installed app bundle

## [0.2.1] - 2026-06-19

### Fixed
- Update and Restart buttons hidden by overlapping secondary button position

## [0.2.0] - 2026-06-19

### Added
- Settings sidebar navigation with three categories: General, Config, Prompt
- Config tab: view and edit Claude Code settings.json and Codex config.toml
- Prompt tab: view and edit Claude Code CLAUDE.md and Codex AGENTS.md system prompts
- Right-click menu direct links to General, Config, and Prompt
- Save shows "Saved" toast instead of closing the settings window

### Fixed
- Route Cmd+, Settings to the same settings window as the menu bar context menu

## [0.1.6] - 2026-06-19

### Changed
- Update dialog uses titled window with blue primary button (white text)
- Settings window closes on save as confirmation

### Fixed
- Single button misaligned in update dialog when only Cancel is shown

## [0.1.5] - 2026-06-19

### Added
- Reopen panel when clicking app icon while already running (applicationShouldHandleReopen)
- Keep in Background: Cmd+Q hides instead of quitting (default on, right-click Quit always exits)
- Launch at Login: auto-start via SMAppService (requires .app bundle)
- Set activation policy to .accessory (hide from Dock and Cmd+Tab)
- Settings window resizable with larger default size

## [0.1.4] - 2026-06-18

### Fixed
- App not restarting after update (use detached shell process instead of NSWorkspace)

## [0.1.3] - 2026-06-18

### Fixed
- About window crash caused by Bundle.module missing in release builds
- App not restarting after update install (now uses NSWorkspace.openApplication)

## [0.1.2] - 2026-06-18

### Added
- About MonitorAgent window with app icon, version, and GitHub link
- Settings window with theme picker (System / Light / Dark)
- Dark theme support across all views
- Configurable sync interval (10/20/30/40/50/60s or Never) in Settings
- On-demand sync when opening panel (always triggers regardless of interval)
- Settings Cancel/Save flow — changes only apply after explicit Save

### Fixed
- Settings and Check for Updates windows now follow theme changes in real time
- Settings Save no longer closes the window

## [0.1.1] - 2026-06-17

### Fixed
- Merge duplicate model names in distribution chart (e.g. two "Opus 4.6" entries)

## [0.1.0] - 2026-06-17

### Added
- macOS menu bar app with NSStatusItem + floating panel
- Filter bar: All / Claude Code / Codex + time range picker (Today / 7D / 30D / All)
- Stat cards: Requests, Sessions, Input Tokens, Output Tokens, Cache Read, Cache Hit
- GitHub-style yearly activity heatmap with year switcher and hover tooltips
- Model distribution stacked bar with legend
- Self-owned JSONL sync engine (Claude Code + Codex), no third-party dependency
- Right-click context menu with Settings and Quit
- Check for Updates with auto-download and install
- Built-in auto-update check on launch (24h throttle)

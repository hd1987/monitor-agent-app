# Changelog

All notable changes to this project will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/)

## [Unreleased]

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

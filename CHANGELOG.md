# Changelog

All notable changes to this project will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/)

## [Unreleased]

## [0.10.2] - 2026-08-04

### Added
- Add a configurable Toggle Activity Chart panel shortcut that defaults to `C`

### Fixed
- Keep an open Activity chart presented when day rollover resets the active range to the new Today
- Make a main-panel click dismiss an open date popover without activating the clicked control

## [0.10.1] - 2026-08-03

### Changed
- Replace Activity outside-click dismissal and protected click regions with a compact top-right collapse button that shares the top-panel line-chart icon and hover treatment
- Render single-day and multi-day Activity data through one normalized chart component
- Add a stateful top-panel chart button using the supplied template SVG that shows or collapses Activity detail for the current date range, turns only its icon blue while open, and shares the top tools' circular hover treatment
- Consolidate Activity presentation, payload, and loading fields into one state and load a newly opened chart without reloading unrelated dashboard data

### Fixed
- Keep the Activity chart's 190pt height budget stable by overlaying its collapse button, close the detail when all Agents are disabled, and cache the template chart icon

## [0.10.0] - 2026-08-02

### Added
- Let an already-open Activity detail follow multi-day filters, aggregating one to three days by hour, up to 90 days by day, up to 540 days by week, and longer history by month while closed details stay closed

### Changed
- Widen the multi-day Activity tooltip so its date range stays on one line
- Show nine evenly distributed X-axis labels for non-hourly Activity ranges with at least nine aggregate points
- Avoid repeating the date before the end time in multi-day hourly Activity tooltips
- Show only evenly distributed hour labels on multi-day hourly Activity X-axes
- Use six-hour ticks for two-day Activity ranges and eight-hour ticks for three-day ranges, including the final midnight boundary only after the range completes
- Place the Activity chart type immediately after its top-left date title
- Remove the redundant aggregation-type subtitle from Activity tooltips

### Fixed
- Reuse one time boundary for Activity range filtering and aggregation
- Avoid duplicate Activity detail queries after date-filter changes
- Clamp partial weekly Activity tooltip dates to the selected range

## [0.9.0] - 2026-08-01

### Added
- Add a Monitored Agents setting for enabling or disabling Claude Code, Codex, and Cursor across routine refreshes, panel filters, aggregates, and subscription quota requests while preserving cached data

### Fixed
- Place the Activity hourly chart's `Now` label beside its dashed current-hour guide

## [0.8.4] - 2026-08-01

### Changed
- Refine the Activity hourly chart with translucent area fills, a dashed current-time guide, intersection markers, and a structured hourly breakdown tooltip

## [0.8.3] - 2026-08-01

### Fixed
- Route the update window's native close action through cancellation while blocking closure during installation
- Prevent overlapping update operations and fail visibly when unique archive staging fails
- Prevent stale hourly Activity loads from overwriting results after the app filter changes
- Ignore Codex token events without per-turn usage instead of recording cumulative totals
- Build release artifacts and metadata from the exact release tag
- Correct Cursor, refresh lifecycle, shortcut, and database-path documentation

## [0.8.2] - 2026-07-31

### Fixed
- Load packaged icon resources from the installed app bundle instead of the development build path

## [0.8.1] - 2026-07-31

### Fixed
- Reject app updates missing the required SwiftPM resource bundle, preventing a launch crash after installation

## [0.8.0] - 2026-07-31

### Changed
- Show the supplied Agent and Cursor icons plus the existing Claude Code and Codex icons in the main-panel filter, expanding only the selected filter to include its label
- Use the supplied Agent icon for All; All, Claude Code, and Codex use the shared template color, while Cursor keeps its original color
- Centralize reusable app SVGs in the packaged Icons resource bundle with shared SwiftUI and AppKit loading APIs
- Use the shared Agent SVG for the menu bar icon and include the resource bundle in release builds
- Use the complete Agent artwork in the 18-point menu bar with a vertically centered viewport
- Use the Agent graphic in the shared Dock and About application icon
- Reuse the menu bar Agent SVG for the All filter icon

## [0.7.0] - 2026-07-30

### Added
- Add a Cursor main-panel filter backed by the signed-in user's exact usage events, including requests, sessions, tokens, cache hit, activity, and model distribution
- Add a main-panel refresh button and configurable Refresh Data shortcut, defaulting to `R`, that restart the automatic refresh interval, share a 10-second request cooldown, and animate during manually triggered refreshes
- Add Cursor MCP Servers plus separate User and Built-in Skills to the MCP & Skill settings inventory
- Add a Global MCP & Skill tab for Skills in `~/.agents/skills`

### Security
- Read Cursor's local access token only for bounded, non-redirecting requests to `https://api2.cursor.sh`, without persisting or logging the credential

### Changed
- Rename the Extensions settings category to MCP & Skill and show MCP Servers before Skills
- Replace separate Sync Interval and subscription quota timers with one panel-visible Refresh Interval, defaulting to 1 minute, and a non-overlapping refresh cycle for Claude Code, Codex, Cursor, and subscription quota; panel-open refreshes honor the selected interval, while `Never` uses the same 1-minute default for that check
- Reload Claude Code and Codex results before waiting for the Cursor network refresh
- Remove the per-provider refresh action from unavailable subscription quota cards in favor of the unified panel refresh

### Fixed
- Allow a manual refresh to queue after its cooldown while an existing refresh cycle is still running
- Replace Cursor usage atomically after an account change so records from different accounts cannot mix
- Advance Cursor's incremental watermark after every successful query and keep overlap counts from accumulating
- Preserve existing Cursor usage when a rebuild unexpectedly returns no Cursor events

## [0.6.10] - 2026-07-28

### Fixed
- Keep the expanded Activity hourly chart open while interacting with the FilterBar, including app tabs, panel tools, drag regions, and the date control
- Refresh an open Activity hourly chart in place when selecting a single day or Today, while closing it for multi-day ranges and other presets

## [0.6.9] - 2026-07-27

### Fixed
- Prevent the main-panel header controls from moving upward when they dismiss the expanded Activity hourly chart

## [0.6.8] - 2026-07-25

### Added
- Add a Shortcuts settings category holding the global panel shortcut plus customizable in-panel shortcuts for Toggle Pin (default `P`), Cycle App Filter (`Tab`, Shift reverses), Reset Panel Position (`Return`), and Hide Panel (`Esc`), with per-shortcut clear and a Restore Defaults action
- Add a Shortcuts entry to the menu bar right-click menu
- Show a refresh button on a subscription quota card when a subscribed provider's request fails so it can be retried without waiting for the next interval

### Changed
- Remove the Subscription Quota on/off toggles and derive each provider's visibility from whether its expiration date is set, moving the date control to the right
- Move the global panel shortcut out of General into the new Shortcuts category
- Keep the shortcut recorder row from shifting by fixing the button width and reserving the clear button's space
- Fix the Settings sidebar at a constant width and block its divider drag so it cannot be resized or collapsed

## [0.6.7] - 2026-07-21

### Changed
- Adjust subscription quota Remaining colors so values at or below 10% are red and values above 10% through 40% are orange

## [0.6.6] - 2026-07-21

### Changed
- Revert broad development runtime isolation and restore the previous shared runtime behavior
- Isolate bare development executables from the installed app's active and temporary usage databases

## [0.6.5] - 2026-07-20

### Fixed
- Disable the Global Shortcut recorder in development mode to match its system registration policy

### Changed
- Share source headers across Extensions, Config, and Prompt settings, with names on the left and paths plus Finder actions on the right
- Rebuild local usage data from bounded streaming snapshots while Claude Code and Codex remain active, with pre-copy event filtering, accelerated line scanning, durable per-file transactions, a catch-up pass, byte-level phase progress, cancellation, strict source validation, and an immediate final sync

## [0.6.4] - 2026-07-19

### Fixed
- Show the full subscription expiration date in General settings

## [0.6.3] - 2026-07-19

### Changed
- Use a darker background for subscription expiration date controls in Dark mode

## [0.6.2] - 2026-07-19

### Added
- Add a folder button beside the Extensions Skills source path to open its directory

### Changed
- Adapt shared Settings surfaces to Dark mode while preserving their existing Light colors
- Reuse shared token, tooltip, status, and selected-control color definitions across the app
- Remove unused legacy card colors

## [0.6.1] - 2026-07-19

### Changed
- Lighten Extensions item cards to RGB 236

## [0.6.0] - 2026-07-19

### Added
- Add a combined read-only Extensions settings page for Claude Code and Codex, with source-labeled Skills and MCP Servers sections
- Add Extensions to the menu bar icon's right-click settings shortcuts

### Changed
- Present Extensions as System Settings-inspired grouped panels with counts, top-right selectable sources, adaptive wrapping cards, and accessible MCP status dots
- Restrict the Claude MCP inventory source to `~/.claude.json` and stop reading `~/.claude/settings.json`
- Apply RGB 247 to shared utility grouped surfaces, source tabs, and Config/Prompt editors, with RGB 229 Extensions item cards

### Fixed
- Keep Skills and MCP Servers navigation responsive by loading local inventories in the background

## [0.5.9] - 2026-07-18

### Changed
- Match the About and update-check window colors to General across the full transparent title-bar area
- Show quota remaining percentages in orange below 40% and red below 10%, using the same green, orange, and red palette across quota cards and tips
- Show the selected main-panel app filter with a restrained Activity-blue tint and primary text while preserving the active Pin color
- Restyle General subscription-expiration inputs with compact calendar fields and clearer set/unset states, and share one locale-aware six-row calendar with larger navigation targets, explicit Today access, continuous range highlighting, and accessible date states
- Expand the Config and Prompt source tabs into equal-width segments aligned with the full editor content width
- Reduce the visual weight of the main-panel header tools and increase spacing between them while preserving the active Pin accent

### Fixed
- Keep the Settings sidebar visible and remove its redundant title-bar toggle button

## [0.5.8] - 2026-07-17

### Changed
- Build formal releases with Xcode 26.6 and the macOS 26.5 SDK so native SwiftUI styling matches local development

## [0.5.7] - 2026-07-17

### Changed
- Remove the footer separator from the General, Config, and Prompt settings pages
- Rebuild Settings with a fixed full-height native macOS sidebar beneath the traffic-light controls, title-free content visually aligned to the first sidebar item including the grouped General form, compact window geometry, standard segmented controls, and quiet inline save feedback; unify About, update-check, and usage-data rebuild surfaces with restrained hierarchy
- Redesign the main panel with General-aligned opaque window and darker grouped backgrounds including Activity detail, readable inactive-state text, compact aligned header controls with ungrouped date and quieter tool icons, immediate press feedback, and reduced-motion adaptations

## [0.5.6] - 2026-07-16

### Changed
- Improve Activity readability with compact chart axes, more spacious toggleable token legends, a current-time marker, future-hour shading, relative heatmap intensity levels, and clearer request labels

### Fixed
- Clear previous hourly Activity data while a newly selected day is loading

## [0.5.5] - 2026-07-16

### Changed
- Match the Subscription Quota item spacing with the other General settings items
- Stop keeping Settings, About, and update-check windows above other apps

## [0.5.4] - 2026-07-16

### Changed
- Rename the subscription tip heading and show calendar-day countdowns in reset-credit tips

## [0.5.3] - 2026-07-16

### Added
- Add optional Claude Code and Codex subscription expiration dates with urgency dots and compact remaining-day hover details

### Changed
- Remove the Keep in Background setting so Cmd+Q always quits the app
- Color quota plans by subscription expiration urgency, refine the card hover regions, restore pointer-anchored reset tips, and reuse the main-panel calendar style for expiration dates
- Reorder General settings by interface, interaction, startup, refresh, quota, and maintenance concerns

## [0.5.2] - 2026-07-15

### Changed
- Refine reset-credit tip sizing and colors, and increase Tokens and reset-credit tip item spacing

## [0.5.1] - 2026-07-15

### Added
- Add Tab and Shift-Tab app-filter cycling and Enter panel-position reset shortcuts

### Changed
- Color each reset-credit tip dot by its expiration urgency and simplify the expiration heading

## [0.5.0] - 2026-07-14

### Added
- Add a configurable global shortcut in General settings for toggling the main panel

### Changed
- Replace the main-panel reset-position icon with a scope symbol
- Hide the main panel when Escape is pressed, including while pinned
- Show the pinned icon in blue only while the main panel has focus

## [0.4.1] - 2026-07-14

### Changed
- Give the main panel the same native window shadow as the General settings window and remove its edge border

## [0.4.0] - 2026-07-14

### Added
- Add a draggable main-panel header region and a reset-position button after the pin control

### Changed
- Shorten the reset-credit detail label to `Full reset`
- Keep a pinned main panel visible beneath the status-item context menu
- Preserve the dragged main-panel position while the app remains running
- Expand main-panel dragging to every non-interactive FilterBar margin and padding region
- Keep every main-panel app-filter label on one line
- Reduce the main-panel date range control width from 150pt to 120pt

## [0.3.7] - 2026-07-14

### Added
- Add a persistent borderless pin button with compact left-angled inactive styling beside General settings on the right
- Add a faint borderless General settings gear button on the right that opens settings without hiding the main panel

### Changed
- Replace the subscription quota card placeholders with the supplied Claude Code and ChatGPT SVG icons
- Allow zero-activity days to open the Activity hourly chart with zero values

## [0.3.6] - 2026-07-13

### Changed
- Apply Codex reset-credit expiration urgency colors to the count while keeping the date subdued

## [0.3.5] - 2026-07-13

### Changed
- Show the nearest Codex reset-credit expiration in the quota card and highlight expirations under 7 or 3 days
- Remove separators and tighten spacing between items in the Codex reset-credit tip

## [0.3.4] - 2026-07-13

### Fixed
- Label Codex quota windows from the server-provided duration when temporary limit changes alter the primary window

## [0.3.3] - 2026-07-12

### Changed
- Run periodic usage-data sync only while the main panel is open

## [0.3.2] - 2026-07-12

### Changed
- Show the full `gpt-5.6-sol` model identifier in the model distribution

## [0.3.1] - 2026-07-12

### Changed
- Remove the progress bars from subscription quota metrics and lay each window out on a single line
- Tighten each quota metric's label-to-value spacing and separate metrics with wider gaps instead of vertical dividers
- Add a middle-dot separator between each quota label and its value, matching the provider plan style
- Restyle the Codex reset-credits count to match the quota metrics instead of a green badge and place it right after the metrics
- Show the Codex reset-credits tip when hovering anywhere on the card and anchor it to the initial pointer position
- Soften the jarring purple in the model distribution palette to a violet closer in tone to the other colors
- Map current-generation model names to stable colors and short names
- Raise the model distribution legend limit from six to thirty models
- Drop the main panel drop shadow and give the light-mode edge a subtle gray border for definition

## [0.3.0] - 2026-07-11

### Added
- Show filter-aware Claude Code and Codex subscription quota cards at the bottom of the main panel
- Add independent Claude Code and Codex quota toggles in General settings

### Changed
- Move the subscription quota description above the grouped provider toggle rows
- Group the Claude Code and Codex quota toggles in a full-width macOS-style Subscription Quota section
- Redesign subscription quota cards with horizontal metrics, progress bars below each metric, and optional details placed last
- Raise the quota low-remaining red threshold from 10% to 20%
- Show Codex reset credits as an availability badge with a detailed hover tip instead of an action-style icon

### Fixed
- Use available wording for the reset-credit count inside the hover tip
- Label reset-credit counts as resets and soften the badge background
- Keep quota provider titles left-aligned while loading and place reset times after percentages
- Detect Codex bundled inside the ChatGPT or Codex macOS app when the GUI environment PATH omits it
- Give newly discovered models distinct, deterministic colors in the model distribution

## [0.2.22] - 2026-07-11

### Fixed
- Keep Activity month labels stationary and fully visible when opening or closing the hourly chart

## [0.2.21] - 2026-07-10

### Fixed
- Stage and validate updates before replacement, restoring the installed app if replacement fails
- Keep the app recoverable when the local usage database cannot be opened
- Commit synced records and file offsets atomically, restart truncated files from the beginning, and serialize rebuild with active sync work
- Keep existing usage data when a rebuild cannot read any source session files
- Clear unavailable Activity years after data changes
- Promote rounded token abbreviations to the next unit at display boundaries

## [0.2.20] - 2026-07-09

### Changed
- Show request and session counts as exact grouped numbers and use two decimal places for abbreviated token counts

## [0.2.19] - 2026-07-09

### Changed
- Removed the Cache Hit progress bar and aligned Requests, Sessions, and Cache Hit stat card widths

## [0.2.18] - 2026-07-09

### Changed
- Treat calendar and Activity selections for the current day as the dynamic Today range and reset any selected date to Today after day rollover

### Fixed
- Stop the Activity hourly chart for today at the current hour so future zero-value buckets do not pull lines down

## [0.2.17] - 2026-07-08

### Changed
- Combine token stat cards into a composite Tokens card with token breakdown details and show Cache Hit with a progress bar
- Include Cache Creation in the Activity hourly token chart

## [0.2.16] - 2026-07-05

### Added
- Rebuild local usage data from Claude Code and Codex source logs via Settings > General > Data, with progress and final results shown in the rebuild dialog

### Changed
- Redesigned the Check for Updates dialog with structured SwiftUI states, scrollable release notes, and clearer download progress

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

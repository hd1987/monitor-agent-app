# MonitorAgent

> **Keep this file in sync with every change.** When modifying architecture, schema, UI layout, data sources, or project structure, update the relevant section here first.

macOS menu bar app that displays usage statistics for Claude Code and Codex.

## Stack

- Swift 5.10 / SwiftUI + AppKit / macOS 14+
- SQLite via GRDB (Swift Package Manager)
- Build: `swift build`
- Test: `swift test`
- Release build: `swift build -c release`
- Run locally: `swift run MonitorAgent &`
- Stop locally: `pkill -f MonitorAgent`

## Data Source

Self-owned JSONL parsing, no third-party dependency.

| Source | Path | Parser |
|--------|------|--------|
| Claude Code | `~/.claude/projects/**/*.jsonl` | `ClaudeLogParser` — extracts `message.usage` from `type == "assistant"` lines |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl` + `~/.codex/archived_sessions/rollout-*.jsonl` | `CodexLogParser` — stateful, extracts `token_count` events with heartbeat dedup and stores uncached input tokens |

Database: `~/.monitor-agent/monitor.db`

The database is a derived local cache, not the source of truth. Database open failures keep the app available so the rebuild action remains accessible. `Settings > General > Data` can rebuild the cache by syncing all Claude Code and Codex JSONL logs into `~/.monitor-agent/monitor-rebuild.tmp.db`, validating that temporary database, then replacing `monitor.db` only after the rebuild succeeds. If the active database contains data but no source files can be read, the rebuild aborts without replacing it. The rebuild runs in a sheet that shows file-level progress and the final requests/sessions/files summary. Original Claude/Codex logs and settings are never modified. Any leftover temporary rebuild database is cleaned up on app startup.

Incremental sync resets a file's parser state when the source file is truncated or replaced with a smaller file. Parsed records and the matching `sync_state` offset are committed in one database transaction so an offset never advances past records that failed to persist. Rebuild waits for the sync queue to become idle, and database reads, writes, close, reopen, and replacement share one lifecycle lock so the active database cannot be replaced during an in-flight operation.

### Schema

```sql
request_logs (
    request_id TEXT PK,          -- "session:{msg_id}" or "codex:{sid}:{turn}"
    app_type TEXT,               -- "claude" | "codex"
    model TEXT,
    input_tokens INTEGER,        -- uncached input tokens; Codex raw input includes cache and is normalized
    output_tokens INTEGER,
    cache_read_tokens INTEGER,
    cache_creation_tokens INTEGER,
    session_id TEXT,
    created_at INTEGER           -- Unix seconds
)

sync_state (
    file_path TEXT PK,
    byte_offset INTEGER,         -- incremental read position
    record_count INTEGER,
    session_id TEXT,              -- Codex: carried across lines
    model TEXT,                   -- Codex: carried across lines
    last_total_input_tokens INTEGER,  -- Codex: heartbeat dedup across sync batches
    last_total_output_tokens INTEGER, -- Codex: heartbeat dedup across sync batches
    last_modified INTEGER,
    last_synced_at INTEGER
)
```

## Project Structure

```
Sources/MonitorAgent/
├── App.swift                      # NSStatusItem + FloatingPanel (borderless NSPanel)
├── AppInstaller.swift             # Staged update extraction, bundle validation, and installed-app replacement
├── AppStore.swift                 # ObservableObject, Combine filter → reload, selected activity detail, manages sync/rebuild lifecycle
├── ActivityTokenChartLayout.swift # Fixed layout constants for the Activity selected-day drawer
├── DatabaseManager.swift          # GRDB r/w, schema setup, path-based databases, all queries + insert/sync methods
├── Models.swift                   # AppFilter, TimeRange, UsageStats, DayActivity, HourlyTokenUsage, ParsedRecord, SyncState, rebuild summaries
├── SyncSettings.swift             # SyncInterval enum + UserDefaults persistence (default 30s)
├── GlobalShortcut.swift           # Configurable global shortcut persistence, recording model, and Carbon registration
├── UpdateCheckView.swift          # SwiftUI update-check dialog state and view
├── UpdateChecker.swift            # GitHub release check, staged app validation, atomic install, and restart
├── UsageDataRebuilder.swift       # Temporary database rebuild, validation, and successful replacement
├── Quota/                         # Subscription quota models, settings, environment detection, and provider clients
├── Sync/
│   ├── SessionSyncManager.swift   # Configurable DispatchSourceTimer, injectable file roots/database, incremental/full read
│   ├── ClaudeLogParser.swift      # Stateless: line Data → ParsedRecord?
│   └── CodexLogParser.swift       # Stateful: line Data + CodexParseContext → ParsedRecord?
└── Views/
    ├── AboutView.swift            # About window (app icon, bundle version/SHA/date, GitHub link)
    ├── PopoverView.swift          # Panel container (620px, white 98%, rounded 12pt, light mode, native window shadow)
    ├── FilterBar.swift            # App toggle (All/Claude Code/Codex) + date range dropdown
    ├── SettingsView.swift         # Sidebar settings: General / Config / Prompt categories
    ├── StatCardsView.swift        # 4 stat cards in HStack
    ├── SubscriptionQuotaView.swift # Bottom single-line Claude/Codex subscription quota cards
    ├── ActivityTokenChartView.swift # Fixed-height selected-day hourly token chart
    ├── HeatmapView.swift          # Year heatmap grid + hover tooltip + selected-day token chart
    ├── WindowFrameReader.swift    # Shared AppKit frame reporter for outside-click exclusions
    └── ModelDistributionView.swift # Stacked proportion bar + 3-col legend
```

## UI Layout

**Menu Bar**: Robot icon (template image from bundled SVG). Left-click opens the panel and triggers an immediate sync. While the panel remains visible, Sync Interval controls periodic usage-data refreshes; hiding the panel stops the timer, and `Never` performs only the immediate open sync. A user-configured global shortcut can toggle the panel from any app; it is unassigned by default, requires at least one modifier, can be cleared, and is registered immediately after General settings are saved. Shortcut conflicts prevent the General save and keep the previous shortcut active. Right-click opens About / General / Config / Prompt / Check for Updates / Quit. Update-check dialogs use a SwiftUI-hosted panel with structured states for checking, up-to-date, new version, downloading, installing, completion, and failure. New-version dialogs show current build metadata and scrollable release notes; downloads show determinate MB progress. Updates are extracted into a staging directory, validated as a MonitorAgent app bundle, and only then replace the installed app. Activation policy is `.accessory` (no Dock icon). Re-clicking the app icon shows the panel via `applicationShouldHandleReopen`.

**Panel** (top → bottom): The borderless main panel uses the same native macOS window shadow as the General settings window, without a separate edge border. Pressing `Esc` hides the panel even when it is pinned. Pressing `Tab` cycles the app filter forward, `Shift+Tab` cycles it backward, and `Enter` resets the panel below the menu-bar icon.

The reset-credit tip uses a compact width, labels its date column `Expires`, and applies expiration urgency colors only to each row's dot.

1. **FilterBar** — left-aligned `[All | Claude Code | Codex]` segmented control plus right-aligned panel pin, position reset, General settings gear, and a compact 120pt date range control. App-filter labels always stay on one line, with the central drag gap shrinking before the filter compresses. All non-interactive FilterBar whitespace acts as the borderless panel's drag region: the full-width upper and lower padding strips, the left and right side margins, and the gap between the app filter and right-side controls. Interactive controls and the spacing between adjacent controls remain click-only. Dragging keeps the panel inside the current screen's visible frame, and closing then reopening retains the dragged position for the current app session. The reset button returns the panel below the menu-bar icon; restarting the app also restores that default placement. The pin, reset, and General icons have compact spacing and provide hover help. An enabled pin stays filled but uses the blue accent only while the main panel has focus, returning to the subdued icon color when focus moves elsewhere. The General button opens settings without hiding the main panel. Pinning keeps the panel open when focus moves away, the user clicks outside, or the status-item context menu opens; that menu appears above the retained panel. Left-clicking the status item explicitly closes the panel, while closing and reopening preserves the pin until the user turns it off. Presets are `Today | 7 Days | 30 Days | All Time`; the calendar supports single-day and start/end range selection. Selecting the current day from the calendar uses the dynamic `Today` range instead of a fixed custom date, and any active date selection resets to `Today` after day rollover.
2. **Subscription Quota** — full-width provider cards directly below the FilterBar, above the stat cards, filtered by the top All / Claude Code / Codex selector. Provider titles use embedded Claude Code and ChatGPT SVG marks and remain left-aligned in loading, error, and populated states so asynchronous updates never shift them. Provider, plan, and quota items are arranged horizontally on a single line with no progress bars. Each quota item shows a compact label, a middle-dot separator, the color-coded remaining percentage, and reset time; metrics are separated by wide gaps. Codex window labels come from each response window's duration instead of assuming primary/secondary always mean `5h`/`1w`; Claude keeps its known `5h`, `1w`, and optional Opus labels. Codex reset credits (`resets · N`) follow the metrics and show the nearest future expiration after the count. The expiration keeps the same subdued style as quota reset times, while the count is green by default, orange when less than 7 days remain, and red when less than 3 days remain. Hovering anywhere on a card with reset credits opens a Tokens-style custom tip below the card, anchored to the initial pointer x position and clamped inside the card, with one `Full reset` row and expiration date per credit. Disabled providers are completely hidden. Quota data comes from the providers' account usage endpoints rather than local token estimates. Opening the panel immediately attempts to refresh every enabled provider and starts a panel-visible-only quota timer; closing the panel stops it. Quota refresh interval choices are `1 min`, `2 min`, `5 min`, and `Never`, defaulting to `2 min`; timed choices also define the minimum interval between request attempts. `Never` disables the timer but still attempts one refresh when the panel opens, using a fixed 2-minute minimum request interval. The top app filter only changes which quota cards are displayed and never triggers a quota request.
3. **StatCards** — `Requests | Sessions | Tokens | Cache Hit`. Requests, Sessions, and Cache Hit share a metric-card width; Tokens is wider. Requests and Sessions show exact grouped counts with single-line scaling. Tokens is a composite card whose total is Input Tokens + Output Tokens + Cache Read + Cache Creation; abbreviated token values use two decimal places, and hover/click detail shows each token category. Cache Hit shows the percentage.
4. **Activity** — GitHub-style heatmap with `Default` trailing-365-day mode and per-year mode. Month labels use a fixed single-line overlay aligned to the heatmap grid, with the final label clamped inside the trailing edge so opening the hourly chart cannot shift or truncate the labels. Hover shows the daily request count with the tooltip kept inside the heatmap width. Every displayed day is selectable, including days with zero activity. Clicking a day filters the whole panel to that date and opens a fixed-height hourly token chart for Input Tokens, Output Tokens, Cache Read, Cache Creation, and request count; zero-activity days show zero values across the chart, and clicking the current day uses the dynamic `Today` range. The chart x-axis shows 3-hour labels from `0h` through `21h`; today's chart stops drawing at the current hour so future zero-value buckets do not pull lines down. Hovering inside the chart shows the nearest start-inclusive one-hour range plus its exact request count and token values. Clicking outside Activity hides the chart without restoring the previous date range; switching All / Claude Code / Codex keeps the chart open.
5. **ModelDistribution** — stacked proportion bar plus a three-column legend listing up to 30 models. Known model aliases retain their established colors; new model names receive deterministic, collision-aware colors from an extensible palette instead of sharing a generic fallback color.

**About** — App icon (`AppIcon.icns`), name, tagline, bundle version plus release commit SHA from `AppVersion.versionWithCommit`, optional release date from `AppVersion.releaseDate`, GitHub button.

**Settings** — The window uses a `960 × 680` default and minimum content size, with a left sidebar (General / Config / Prompt) plus right content area. Cancel closes the window. Save asks for confirmation before applying the current category, then keeps the window open and shows a top green success toast. Save only applies to the current category. Switching categories reloads from disk. Config/Prompt use a Claude Code / Codex tab bar. Subscription Quota settings use per-row descriptions and a subdued grouped background rather than a shared section description or bright card surface.

- **General** — Theme (System/Light/Dark), Sync Interval (10s/30s/60s/Never), configurable global shortcut for toggling the main panel, Launch at Login toggle, a full-width rounded Subscription Quota group with one shared description above simple Claude Code and Codex toggle rows, Data rebuild action with progress/result sheet
- **Config** — TextEditor for `~/.claude/settings.json` (JSON validated on save) and `~/.codex/config.toml`; shows "File not found" if missing
- **Prompt** — TextEditor for `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`; shows "File not found" if missing

## Branches

- `develop` — active development, all work here
- `main` — release only, merged from develop at release time

## Release

See [RELEASE.md](RELEASE.md) for full workflow. Summary:
1. Agent: verify → move `[Unreleased]` entries → commit → tag on `develop`
2. You: push `develop` + tags, create PR, merge `develop` into `main`
3. GitHub Actions: release only after `main` receives a reachable unreleased tag

## Conventions

- Git commit: one short English sentence
- Code comments: English only
- Update CHANGELOG.md `[Unreleased]` section with every code change
- Update this file when architecture, schema, UI layout, or project structure changes
- Do not call a release published until the tagged commit is on `main` and the GitHub Release workflow completes

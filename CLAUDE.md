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
├── AppStore.swift                 # ObservableObject, Combine filter → reload, selected activity detail, manages sync lifecycle
├── ActivityTokenChartLayout.swift # Fixed layout constants for the Activity selected-day drawer
├── DatabaseManager.swift          # GRDB r/w, schema setup, all queries + insert/sync methods
├── Models.swift                   # AppFilter, TimeRange, UsageStats, DayActivity, HourlyTokenUsage, ParsedRecord, SyncState
├── SyncSettings.swift             # SyncInterval enum + UserDefaults persistence (default 30s)
├── Sync/
│   ├── SessionSyncManager.swift   # Configurable DispatchSourceTimer, file discovery, incremental read
│   ├── ClaudeLogParser.swift      # Stateless: line Data → ParsedRecord?
│   └── CodexLogParser.swift       # Stateful: line Data + CodexParseContext → ParsedRecord?
└── Views/
    ├── AboutView.swift            # About window (app icon, bundle version/SHA/date, GitHub link)
    ├── PopoverView.swift          # Panel container (620px, white 98%, rounded 12pt, light mode)
    ├── FilterBar.swift            # App toggle (All/Claude Code/Codex) + date range dropdown
    ├── SettingsView.swift         # Sidebar settings: General / Config / Prompt categories
    ├── StatCardsView.swift        # 6 stat cards in HStack
    ├── ActivityTokenChartView.swift # Fixed-height selected-day hourly token chart
    ├── HeatmapView.swift          # Year heatmap grid + hover tooltip + selected-day token chart
    ├── WindowFrameReader.swift    # Shared AppKit frame reporter for outside-click exclusions
    └── ModelDistributionView.swift # Stacked proportion bar + 3-col legend
```

## UI Layout

**Menu Bar**: Robot icon (template image from bundled SVG). Left-click opens the panel and triggers an on-demand sync. Right-click opens About / General / Config / Prompt / Check for Updates / Quit. Update-check result dialogs include the current bundle version, release commit SHA when available, and release date when available. Activation policy is `.accessory` (no Dock icon). Re-clicking the app icon shows the panel via `applicationShouldHandleReopen`.

**Panel** (top → bottom):

1. **FilterBar** — `[All | Claude Code | Codex]` segmented control plus right-aligned date range dropdown. Presets are `Today | 7 Days | 30 Days | All Time`; the calendar supports single-day and start/end range selection.
2. **StatCards** — `Requests | Sessions | Input Tokens | Output Tokens | Cache Read | Cache Hit`.
3. **Activity** — GitHub-style heatmap with `Default` trailing-365-day mode and per-year mode. Hover shows the daily request count with the tooltip kept inside the heatmap width. Days with no activity are not selectable. Clicking an active day filters the whole panel to that date and opens a fixed-height hourly token chart for Input Tokens, Output Tokens, Cache Read, and request count when token data exists. The chart x-axis shows 3-hour labels from `0h` through `21h`; hovering inside the chart shows the nearest start-inclusive one-hour range plus its exact request count and token values. Clicking outside Activity hides the chart without restoring the previous date range; switching All / Claude Code / Codex keeps the chart open when data remains available.
4. **ModelDistribution** — stacked proportion bar plus three-column legend for top models.

**About** — App icon (`AppIcon.icns`), name, tagline, bundle version plus release commit SHA from `AppVersion.versionWithCommit`, optional release date from `AppVersion.releaseDate`, GitHub button.

**Settings** — Left sidebar (General / Config / Prompt) plus right content area. Cancel closes the window. Save asks for confirmation before applying the current category, then keeps the window open and shows a top green success toast. Save only applies to the current category. Switching categories reloads from disk. Config/Prompt use a Claude Code / Codex tab bar.

- **General** — Theme (System/Light/Dark), Sync Interval (10s/30s/60s/Never), Keep in Background toggle, Launch at Login toggle
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

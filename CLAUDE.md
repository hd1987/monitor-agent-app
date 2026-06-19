# MonitorAgent

> **Keep this file in sync with every change.** When modifying architecture, schema, UI layout, data sources, or project structure, update the relevant section here first.

macOS menu bar app that displays usage statistics for Claude Code and Codex.

## Stack

- Swift 5.10 / SwiftUI + AppKit / macOS 14+
- SQLite via GRDB (Swift Package Manager)
- Build: `swift build` / Run: `swift run MonitorAgent &` / Stop: `pkill -f MonitorAgent`

## Data Source

Self-owned JSONL parsing, no third-party dependency.

| Source | Path | Parser |
|--------|------|--------|
| Claude Code | `~/.claude/projects/**/*.jsonl` | `ClaudeLogParser` — extracts `message.usage` from `type == "assistant"` lines |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl` + `~/.codex/archived_sessions/rollout-*.jsonl` | `CodexLogParser` — stateful, extracts `token_count` events with heartbeat dedup |

Database: `~/.monitor-agent/monitor.db`

### Schema

```sql
request_logs (
    request_id TEXT PK,          -- "session:{msg_id}" or "codex:{sid}:{turn}"
    app_type TEXT,               -- "claude" | "codex"
    model TEXT,
    input_tokens INTEGER,
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
    last_modified INTEGER,
    last_synced_at INTEGER
)
```

## Project Structure

```
Sources/MonitorAgent/
├── App.swift                      # NSStatusItem + FloatingPanel (borderless NSPanel)
├── AppStore.swift                 # ObservableObject, Combine filter → reload, manages sync lifecycle
├── DatabaseManager.swift          # GRDB r/w, schema setup, all queries + insert/sync methods
├── Models.swift                   # AppFilter, TimeRange, UsageStats, ParsedRecord, SyncState
├── SyncSettings.swift             # SyncInterval enum + UserDefaults persistence (default 30s)
├── Sync/
│   ├── SessionSyncManager.swift   # Configurable DispatchSourceTimer, file discovery, incremental read
│   ├── ClaudeLogParser.swift      # Stateless: line Data → ParsedRecord?
│   └── CodexLogParser.swift       # Stateful: line Data + CodexParseContext → ParsedRecord?
└── Views/
    ├── AboutView.swift            # About window (app icon, version, GitHub link) + AppVersion constant
    ├── PopoverView.swift          # Panel container (620px, white 98%, rounded 12pt, light mode)
    ├── FilterBar.swift            # App toggle (All/Claude Code/Codex) + time range picker
    ├── SettingsView.swift         # Sidebar settings: General / Config / Prompt categories
    ├── StatCardsView.swift        # 6 stat cards in HStack
    ├── HeatmapView.swift          # Year heatmap grid + hover tooltip overlay
    └── ModelDistributionView.swift # Stacked proportion bar + 3-col legend
```

## UI Layout

**Menu Bar**: Robot icon (SVG template image). Left-click → panel (triggers sync). Right-click → About / General / Config / Prompt / Check for Updates / Quit. Activation policy `.accessory` (no Dock icon). Re-clicking app icon shows panel via `applicationShouldHandleReopen`.

**Panel** (top → bottom):

1. **FilterBar** — `[All | Claude Code | Codex]` segmented + `[Today ▾]` time picker

**About** — App icon (AppIcon.icns), name, tagline, version (`AppVersion.current`), GitHub button

**Settings** — Left sidebar (General / Config / Prompt) + right content area. Cancel closes window; Save shows "Saved" toast (no close). Save only applies to current category. Switching categories reloads from disk. Config/Prompt use Claude Code / Codex tab bar.

- **General** — Theme (System/Light/Dark), Sync Interval (10–60s/Never), Keep in Background toggle, Launch at Login toggle
- **Config** — TextEditor for `~/.claude/settings.json` (JSON validated on save) and `~/.codex/config.toml`; shows "File not found" if missing
- **Prompt** — TextEditor for `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`; shows "File not found" if missing
2. **StatCards** — `Requests | Sessions | Input Tokens | Output Tokens | Cache Read | Cache Hit`
3. **Heatmap** — GitHub-style year grid, auto-sized cells, year switcher, hover tooltip ("6 contributions on May 21st")
4. **ModelDistribution** — stacked color bar + legend (top 6 models, 3 columns)

## Branches

- `develop` — active development, all work here
- `main` — release only, merged from develop at release time

## Release

See [RELEASE.md](RELEASE.md) for full workflow. Summary:
1. Agent: update CHANGELOG → commit → tag
2. You: push develop + tags → create PR → merge
3. GitHub Actions: build → sign → package .app → create Release

## Conventions

- Git commit: one short English sentence
- Code comments: English only
- Update CHANGELOG.md `[Unreleased]` section with every code change
- Update this file when architecture, schema, UI layout, or project structure changes

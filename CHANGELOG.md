# Changelog

All notable changes to this project will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/)

## [Unreleased]

### Added
- About MonitorAgent window with app icon, version, and GitHub link
- Settings window with theme picker (System / Light / Dark)
- Dark theme support across all views

### Fixed
- Settings and Check for Updates windows now follow theme changes in real time
- Settings Save no longer closes the window
- Configurable sync interval (10/20/30/40/50/60s or Never) in Settings
- On-demand sync when opening panel (always triggers regardless of interval)
- Settings Cancel/Save flow — changes only apply after explicit Save

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

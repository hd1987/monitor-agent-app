# Changelog

All notable changes to this project will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/)

## [Unreleased]

### Added
- Self-owned JSONL sync engine (Claude Code + Codex), no CC Switch dependency
- Right-click context menu with Settings and Quit
- Hover tooltip on heatmap cells ("6 contributions on May 21st")

### Changed
- Window background: white 98% opacity, 1px border at 1% gray
- Robot icon for menu bar

## [0.1.0] - 2026-06-17

### Added
- macOS menu bar app with NSStatusItem + floating panel
- Filter bar: All / Claude Code / Codex + time range picker (Today / 7D / 30D / All)
- Stat cards: Requests, Sessions, Input Tokens, Output Tokens, Cache Read, Cache Hit
- GitHub-style yearly activity heatmap with year switcher
- Model distribution stacked bar with legend
- Read from `~/.cc-switch/cc-switch.db` (initial version)

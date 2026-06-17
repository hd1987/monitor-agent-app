# Release Guide

## Branch Strategy

- `develop` — active development branch, all work happens here
- `main` — release branch, only receives merges from develop at release time

## Release Flow

### 1. Agent prepares the release (on develop)

When you say "release vX.Y.Z", the agent will:

1. Move `[Unreleased]` entries in `CHANGELOG.md` to `[X.Y.Z] - YYYY-MM-DD`
2. Add a new empty `[Unreleased]` section at top
3. Commit: `Release vX.Y.Z`
4. Tag: `vX.Y.Z`
5. Merge develop → main (fast-forward)

### 2. You push (manual)

```bash
git push origin main --tags
```

### 3. GitHub Actions builds and publishes

Triggered by push to `main`. The workflow (`.github/workflows/release.yml`):

1. Checks if HEAD has a tag that hasn't been released yet — skips otherwise
2. `swift build -c release` on macOS 14 runner
3. Packages `MonitorAgent.app` bundle with `Info.plist` (version from tag, `LSUIElement=true`)
4. Compresses to `MonitorAgent.zip` via `ditto`
5. Extracts release notes from `CHANGELOG.md`
6. Creates GitHub Release with zip attached

### Result

Users download `MonitorAgent.zip` from the GitHub Releases page → unzip → drag to Applications → double-click to run.

## Changelog Convention

Maintain `CHANGELOG.md` using [Keep a Changelog](https://keepachangelog.com/) format:

- **Added** — new features
- **Changed** — modifications to existing features
- **Fixed** — bug fixes
- **Removed** — removed features

Update `[Unreleased]` with every code change. The agent handles this during development.

## Version Numbering

Semantic versioning: `MAJOR.MINOR.PATCH`

- PATCH: bug fixes, minor UI tweaks
- MINOR: new features, new data dimensions
- MAJOR: breaking changes, architecture overhaul

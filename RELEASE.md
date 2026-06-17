# Release Guide

## Branch Strategy

- `develop` — active development branch, all work happens here
- `main` — protected release branch, only accepts pull requests from develop

## Release Flow

### 1. Agent prepares the release (on develop)

When you say "release vX.Y.Z", the agent will:

1. Move `[Unreleased]` entries in `CHANGELOG.md` to `[X.Y.Z] - YYYY-MM-DD`
2. Add a new empty `[Unreleased]` section at top
3. Commit: `Release vX.Y.Z`
4. Tag: `vX.Y.Z`

### 2. You push and create PR (manual)

1. `git push origin develop --tags`
2. Create a PR from develop → main on GitHub
3. Merge the PR

### 3. GitHub Actions builds and publishes

Triggered by push to `main`. The workflow (`.github/workflows/release.yml`):

1. Checks if HEAD has a tag that hasn't been released yet — skips otherwise
2. `swift build -c release` on macOS 15 runner (Xcode 16 / Swift 6)
3. Packages `MonitorAgent.app` bundle with `Info.plist` (version from tag, `LSUIElement=true`)
4. Ad-hoc code signs the app (`codesign -s -`)
5. Compresses to `MonitorAgent.zip` via `ditto`
6. Extracts release notes from `CHANGELOG.md`
7. Creates GitHub Release with zip attached

### Result

Users download `MonitorAgent.zip` from the GitHub Releases page → unzip → drag to Applications → open.

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

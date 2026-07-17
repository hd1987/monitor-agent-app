# Release Guide

## Branch Strategy

- `develop` — active development branch, all work happens here
- `main` — protected release branch, only accepts pull requests from develop

## Release Flow

### 1. Agent prepares the release (on develop)

When you say "release vX.Y.Z", the agent will:

1. Confirm the worktree state and keep unrelated user changes untouched
2. Move `[Unreleased]` entries in `CHANGELOG.md` to `[X.Y.Z] - YYYY-MM-DD`
3. Add a new empty `[Unreleased]` section at top
4. Run release verification (`swift test`, `swift build`, `swift build -c release`, `git diff --check`)
5. Commit with exactly `Release vX.Y.Z`
6. Tag the same commit as `vX.Y.Z`

### 2. You publish the prepared branch and create PR (manual)

1. `git push origin develop --tags`
2. Create a PR from develop → main on GitHub
3. Merge the PR

Pushing tags alone does not publish a release. The tagged commit must become reachable from `main`.

### 3. GitHub Actions builds and publishes

Triggered by push to `main`. The workflow (`.github/workflows/release.yml`):

1. Finds the latest tag reachable from `main`
2. Skips if no tag is reachable or the GitHub Release already exists
3. Selects Xcode 26.6 on the macOS 26 runner
4. Verifies the selected macOS SDK is 26.5, matching local development builds
5. Runs `swift build -c release`
6. Packages `MonitorAgent.app` with `Info.plist` values derived from the tag and changelog (`CFBundleShortVersionString`, `CFBundleVersion`, `MonitorAgentGitCommit`, `MonitorAgentReleaseDate`, `LSUIElement=true`)
7. Copies `AppIcon.icns` into the app bundle
8. Ad-hoc code signs the app (`codesign -s -`)
9. Compresses to `MonitorAgent.zip` via `ditto`
10. Extracts release notes from `CHANGELOG.md`
11. Creates a GitHub Release with `MonitorAgent.zip` attached

### Result

Users download `MonitorAgent.zip` from the GitHub Releases page, unzip it, drag `MonitorAgent.app` to Applications, and open it.

Do not call the release published until the `main` workflow finishes and the GitHub Release exists.

## Changelog Convention

Maintain `CHANGELOG.md` using [Keep a Changelog](https://keepachangelog.com/) format:

- **Added** — new features
- **Changed** — modifications to existing features
- **Fixed** — bug fixes
- **Removed** — removed features

Update `[Unreleased]` with every code change. The agent handles this during development.

For release notes, keep user-visible changes concise and grouped under:

- **Added** — new features
- **Changed** — modifications to existing features
- **Fixed** — bug fixes
- **Removed** — removed features

## Version Numbering

Semantic versioning: `MAJOR.MINOR.PATCH`

- PATCH: bug fixes, minor UI tweaks
- MINOR: new features, new data dimensions
- MAJOR: breaking changes, architecture overhaul

## Verification Commands

Use these before release prep and after documentation/process changes:

```bash
swift test
swift build
swift build -c release
git diff --check
```

The release workflow additionally asserts Xcode 26.6 and macOS SDK 26.5 so native SwiftUI controls use the same linked SDK behavior as local development.

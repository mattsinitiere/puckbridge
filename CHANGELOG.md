# Changelog

All notable changes to Puck Bridge are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org/).
The release tag (`vX.Y.Z`) is the version; move "Unreleased" items under a new heading when tagging.

## [Unreleased]

## [0.4.0] - 2026-10-13
### Added
- **Puck tabs.** Hold on the puck's face to pick a tab: **Chats** (Claude Desktop recents), **Claude Code** (recent sessions), and one tab per Claude Code project folder. Uses the stock firmware's tab screen (`swarms` / `swarm.select`); up to 24 tabs of 16 rows. Code sessions are read from `~/.claude/projects` (folder + title only). Opening a Code session or speaking into one isn't supported yet; the puck says so. Menu: **Puck tabs: show Claude Code sessions**.
- App icon ("Minimal ◎"): `Resources/AppIcon.svg` → `AppIcon.png`; `build.sh` turns it into `AppIcon.icns`.
- Release notes now come from this file's section for the version.
- Actions → Release → **Run workflow** can create a new version tag (on the chosen branch), so a release needs no git command.
- `AGENTS.md` (agent/developer guide) and `CLAUDE.md` pointer for Claude Code.
- `.github/workflows/build.yml` (compile check on every push), same file as on `matthew/keen-babbage-ipemc5`.
### Fixed
- Release build failed with "Permission denied": `scripts/*.sh` are now executable in git, and the workflow runs `bash scripts/build.sh` so older tags build too.
- Release workflow: also builds when a release is published in the GitHub UI; a manual run (Actions → Release → Run workflow) builds the chosen tag instead of `main`; the self-signed certificate is trusted on the runner so CI signing actually takes effect (previously it would quietly fall back to ad-hoc); the signature is checked; uploads with `gh` instead of a third-party action.

## [0.3.0] - 2026-10-13
First release from this repository.
### Added
- GitHub Actions release workflow: tag `v*` → universal (arm64 + x86_64) build → `PuckBridge.zip` attached to the release.
- In-app updates from GitHub Releases: daily check plus ◎ → **Check for updates…**; installs in place and relaunches.
- `scripts/install.sh` one-line installer/updater for any Mac; `scripts/dev-install.sh` for local builds.
- Optional stable code signing in CI (`SIGNING_CERT_P12` / `SIGNING_CERT_PASSWORD` secrets) so macOS keeps permissions across updates.
- Version shown in the ◎ menu.
- MIT license with attribution for the OpenHarness-derived puck protocol.

## [0.2.0] - 2026-10-13 (local build, not released)
### Added
- Menu-bar app (◎) with puck and Claude status, settings, log, and Start at login.
- Voice: puck audio → on-device Apple Speech → pasted into the selected chat and sent (or paste-only).
- Small puck button stops Claude while it's writing (`turn.started` marks the tile busy; `turn.stop` presses Claude's Stop).
- Automatically stops OpenHarness's `harnessd` service when it holds the puck; "Restore OpenHarness service" menu item.

## [0.1.0] - 2026-10-13 (prototype scripts)
### Added
- `puck_test.py`: proved the puck can be driven without OpenHarness (framing verified against upstream vectors, 27/27).
- `claude_ax_dump.swift` / `claude_watch.swift`: mapped what Claude Desktop exposes to Accessibility.
- `puck_bridge.swift`: recent chats on the puck, open on select/tap, finish alerts with reply preview, flicker protection.
### Findings
- Claude Desktop doesn't expose background chat completion; finish alerts cover the open chat only.
- Puck needs `CLOCAL` on the serial port; OpenHarness's launchd agent (KeepAlive) must be booted out to free the port.

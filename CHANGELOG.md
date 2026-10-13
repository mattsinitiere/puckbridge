# Changelog

All notable changes to Puck Bridge are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org/).
The release tag (`vX.Y.Z`) is the version; move "Unreleased" items under a new heading when tagging.

## [Unreleased]
### Added
- **Settings window** (◎ → Settings…, ⌘,) with General, Character, Puck, Claude & Voice and Advanced tabs. It shows live status and a permissions checklist, and opens by itself on first launch if Accessibility isn't allowed yet.
- **Pick the puck's character:** Clawd (default), Codex Bot, Jolly or Fo, from Settings or the ◎ → Character menu.
- **Your own character:** import a petdex-style sprite sheet (8 × 9 frames, PNG or WebP). Puck Bridge converts it to the puck's pack format and uploads it over the cable, and sends it again after the puck restarts.
- **Puck settings from the Mac:** brightness, finish beep (the puck ships muted), calm mode, reverse scrolling and voice language. They're read from and saved on the puck itself.
- **Settings tiles on the puck:** Character, Beep, Brightness and Calm mode appear after your chats. Tap the face twice to change one, or tap, say a value, and tap. They can be turned off in Settings → Character.
- Menu: Open Chat submenu, Character submenu, beep toggle, warning icon when Accessibility is missing, Open Claude when it isn't running.
- Settings: Bring Claude to the front when a chat opens (on by default); hide the start of replies on the puck (privacy); Reconnect puck, Send test alert, Copy diagnostics.
- `Build` workflow: compiles on every push and pull request, and checks generated character packs with the puck firmware's own parser (`tests/check_pet_pack.c`, `tests/make_test_sheet.py`).
- `AGENTS.md` (agent/developer guide) and `CLAUDE.md` pointer for Claude Code.
### Changed
- Settings moved out of the ◎ menu into the Settings window. "Restore OpenHarness service" is now Settings → Advanced → **Lend the Puck to OpenHarness…**, with **Take It Back**.
- The puck connects and shows its settings tiles even before Accessibility is allowed.
- Transcripts are no longer written to the log (only their word count).
### Fixed
- Restoring OpenHarness didn't hand the puck over: Puck Bridge reopened the port within a fraction of a second.
- On replies longer than 25 seconds the puck stopped showing Claude as busy, so the character stopped working and the small button could no longer stop Claude. `turn.started` is now refreshed every 10 s.
- The puck could hang waiting after a recording whose audio was lost (e.g. a reconnect mid-recording); it now always gets an answer.
- Voice could paste into another app if Claude didn't come to the front in time. Pasting no longer wipes images or files from the clipboard.
- A stale "writing" spinner stayed on the puck if Claude quit mid-reply.
- "You're up to date" was shown when the update check had actually failed.
- Alerts could open behind other windows.
- An update that failed halfway could delete the app; the old copy is now kept until the new one is in place.
- Puck I/O from voice and menu actions now runs on the bridge thread (fixes data races).
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

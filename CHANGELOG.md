# Changelog

All notable changes to Puck Bridge are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org/).
The release tag (`vX.Y.Z`) is the version; move "Unreleased" items under a new heading when tagging.

## [Unreleased]
### Added
- **Puck Bridge firmware** for the round puck: the official firmware plus `firmware/patches` (built in CI from a pinned OpenHarness commit with ESP-IDF 5.5, bundled in the app). Settings → Puck → Firmware installs it over the USB cable; **Restore…** downloads Autonomous's official firmware, checks it, and puts it back. The puck keeps its previous firmware as a fallback.
- **Clock + weather face** (needs Puck Bridge firmware): shows after 5 minutes idle (Settings → Puck → Clock face: Never/2/5/10/15/30 min, 24-hour clock, weather on/off). Weather comes from Open-Meteo using this Mac's location (Location Services; only a rounded location is sent).
- **Small button = home** (needs Puck Bridge firmware): tap → clock face; hold while Claude writes → stop; hold otherwise → screen off/on.
- Location row in Settings → General → Permissions.
- **Character library:** Settings → Character → **Import Characters…** takes petdex sprite sheets, folders with a pet.json, and .zip files of them (zips inside zips too), so a whole bundle imports at once. They stay on this Mac (never in the app or the repo); pick one and the puck gets it over the cable. Remove with the trash button. The old single "your own" character moves into the library.
- **On-device Settings menu** (Puck Bridge firmware): the clock face's Settings button opens Character, Sound, Volume, Brightness, Calm mode, Clock after, 24-hour clock and Weather; tap a row to change it. The Mac app does the changing, so both stay in sync.
- **Finish sounds** (Puck Bridge firmware): Chime, Soft, Bell or Digital, plus volume, in Settings → Puck → Sound (with Test) and in the puck's menu.
- Settings → Advanced → **Copy Claude Layout**: Claude's window structure (no message text), for fixing chat detection.
### Fixed
- Chats and Claude Code sessions got mixed: on Claude's Code tab the sidebar lists Code sessions, which were read as chats. Puck Bridge now recognises them (by their titles in `~/.claude/projects`) and keeps the chat list.
- **Fo showed nothing:** the official firmware (0.0.88) has no Fo. Fo is now offered only on Puck Bridge firmware, which has it.
### Changed
- With Puck Bridge firmware the puck's own Settings menu replaces the Settings tab of tiles.

## [0.6.0] - 2026-10-13
### Added
- **Settings window** (◎ → Settings…, ⌘,) with General, Character, Puck, Claude & Voice and Advanced tabs. It shows live status and a permissions checklist, and opens by itself on first launch if Accessibility isn't allowed yet.
- **Pick the puck's character:** Clawd (default), Codex Bot, Jolly or Fo, from Settings or the ◎ → Character menu.
- **Your own character:** import a petdex-style sprite sheet (8 × 9 frames, PNG or WebP). Puck Bridge converts it to the puck's pack format and uploads it over the cable, and sends it again after the puck restarts.
- **Puck settings from the Mac:** brightness, finish beep (the puck ships muted), calm mode, reverse scrolling and voice language. They're read from and saved on the puck itself.
- **Settings tab on the puck:** hold the face → TABS → **Settings** for Character, Beep, Brightness and Calm mode. Tap the face twice to change one, or tap, say a value, and tap. Can be turned off in Settings → Character.
- Menu: Open Chat submenu, Character submenu, beep toggle, warning icon when Accessibility is missing, Open Claude when it isn't running.
- Settings: Bring Claude to the front when a chat opens (on by default); hide the start of replies on the puck (privacy); Reconnect puck, Send test alert, Copy diagnostics.
- **Beta Access** (Settings → General): lists a preview build of every branch on GitHub, each with an Install button, plus **Back to the Release**. While you run a preview, Check for Updates also follows newer builds of that branch. A newer release always wins.
- Every push publishes that branch's build as a pre-release `preview-<branch>` (replaced on each push, deleted with the branch), versioned `<latest release>.<build number>` and signed like releases. Pre-releases never count as the latest release, so the normal updater and `install.sh` ignore them.
- `scripts/make-signing-cert.sh`: one paste in Terminal makes the signing certificate and walks you through adding it to GitHub as repository secrets (they cover every branch: releases, `main` and previews), so macOS stops re-asking for permissions after every update. Settings → General shows whether the running app is signed.
- `Build` workflow: compiles on every push and pull request (or Actions → Build → **Run workflow**), and checks generated character packs with the puck firmware's own parser (`tests/check_pet_pack.c`, `tests/make_test_sheet.py`).
### Changed
- Settings moved out of the ◎ menu into the Settings window. "Restore OpenHarness service" is now Settings → Advanced → **Lend the Puck to OpenHarness…**, with **Take It Back**.
- The puck connects (and shows its Settings tab) even before Accessibility is allowed. Before, it sat on the "Harness" screen until permission was granted.
- "Puck tabs: show Claude Code sessions" moved to Settings → Claude & Voice.
- Test builds from the Build workflow are signed too: with your certificate once it's set up, otherwise with a throwaway one that tests the signing path. Both workflows share `scripts/ci-import-cert.sh`.
- Transcripts are no longer written to the log (only their word count).
### Fixed
- The puck's "working for Xs" timer restarted at 0 every time you switched chats and came back. A chat Claude is writing in now stays busy on the puck while you look at another one. When you return, the timer has kept counting; if it finished meanwhile, its tile gets the reply without a beep. (The puck can't be told an earlier start time, so a task already running before Puck Bridge saw it counts from when it was first seen.)
- Clicking between chats could show "writing" on the puck when nothing was sent. The busy chat was guessed from the last one opened on the puck; it's now the chat on screen (found by its title in the conversation header), and the Stop button must be seen on two reads in a row. The log names the chat and button that triggered it.
- The small button's Stop now stops the chat it was pressed for, opening it first if needed, instead of whatever chat is on screen.
- The Release workflow could fail to parse (a one-line `run:` containing ": "), which would have blocked every release; all workflow files are now checked with a YAML parser.
- The Build workflow's signature check always failed, and the Release workflow's signature warning always fired, because `codesign -dv` doesn't print Authority lines (`-dvv` does).
- Restoring OpenHarness didn't hand the puck over: Puck Bridge reopened the port within a fraction of a second.
- On replies longer than 25 seconds the puck stopped showing Claude as busy, so the character stopped working and the small button could no longer stop Claude. `turn.started` is now refreshed every 10 s.
- The puck could hang waiting after a recording whose audio was lost (e.g. a reconnect mid-recording); it now always gets an answer.
- Voice could paste into another app if Claude didn't come to the front in time. Pasting no longer wipes images or files from the clipboard.
- A stale "writing" spinner stayed on the puck if Claude quit mid-reply.
- "You're up to date" was shown when the update check had actually failed.
- Alerts could open behind other windows.
- An update that failed halfway could delete the app; the old copy is now kept until the new one is in place.
- Puck I/O from voice and menu actions now runs on the bridge thread (fixes data races).

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

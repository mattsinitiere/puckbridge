# Changelog

All notable changes to Puck Bridge are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org/).
The release tag (`vX.Y.Z`) is the version; move "Unreleased" items under a new heading when tagging.

## [Unreleased]

## [0.8.4] - 2026-10-14
A full UX review of the puck and the Mac app (four reviews: puck visuals, puck flows, the Mac app, day-to-day use) and the fixes. Puck Bridge firmware **0.0.88-pb.9**.
### Fixed
- **Timers and alarms ring even when the finish chime is off.** A fresh puck ships with it off, so alarms rang silently.
- **No more false "finished":** Claude Code sessions are followed in their transcripts, so a long build or test run no longer looks done after 45 s of quiet; a chat given up on after 20 minutes in the background now says "Lost track of this chat" instead of looking finished.
- **Voice tells the truth:** if the words don't reach Claude the puck says so (it used to show them as sent); if something is already typed in Claude's box, your words are added and **not** sent.
- **Alarms and a running timer survive an unplug or a puck restart:** the Mac re-sends them when the puck comes back, and tells you on the Mac if one came due while it was away.
- The Mac app no longer stalls on a busy Claude (1.5 s limit per Accessibility call), which could make the puck say "No answer from the Mac".
- OpenHarness is kept from starting at login while Puck Bridge has the puck (it could put the stock firmware back after a reboot); if the stock firmware does come back, Puck Bridge says so and offers to reinstall.
- Out-of-date help text ("Hold the puck's face to see its tabs").
- Settings → Puck → Clock face pointed to the firmware section "above"; it is below.
- Puck screen overlaps found by the full screen gallery: a Claude Code session's project name ran across the pet over a reply card (now hidden there), the next-alarm line touched the pet, and the connecting screen's hint was cut off (firmware pb.9).
### Added
- **The clock keeps time without the Mac** (asleep or unplugged): it stays up, dimmed, with "Waiting for your Mac".
- **A finished chat is a line on the clock** ("Grocery list is ready", tap it to open) instead of taking the clock away.
- **Active** leads the Claude Code groups on the puck: everything working or with a reply waiting, across all projects.
- **Health on the puck and in Settings:** "Allow Accessibility on your Mac", "Claude isn't open", "Open Claude's window" show on the puck's clock and in Settings → General → Health, each with a fix button.
- **Alarms:** tap to **snooze** 9 minutes (Stop is its own button), a missed alarm stays on the clock and in Notifications, and the next alarm shows under the clock.
- **Timer:** a running timer shows as a draining ring with **+1 min** and Stop; the dial has 5/10/15/25/45-minute presets and a "<" back.
- **Hold to talk** fills a ring until a release sends ("Keep holding", then "Release to send"); **slide away to cancel**. The voice screen shows whom you're talking to and "Tap to send".
- **Stop:** a working chat's face says "Hold the small button to stop" (the first few times), "Stopping" after, and "Claude already finished" if it's too late; a held small button on the clock stops the chat that started last.
- **Say "stop Claude"** (or "cancel that") to stop it. Chat and project names are given to speech recognition so they're heard right.
- Swipe hints on the clock (Notifications, Settings, Code) the first few times; a stopwatch beside the line that opens the timer.
- **Reset and Allow Again** (Settings → General) for when macOS forgets Accessibility after an update; the Setup window says so after an update.
- Asks once whether to turn on the finish chime when a new puck connects; a Test button next to Sound.
- A Mac notification when Claude finishes (or an alarm is due) and the puck isn't plugged in (Settings → Claude & Voice).
- A **Timers** tab in Settings (timer and alarms).
- **Pictures of every screen:** `firmware/sim/tools/gallery.py` renders all 37 puck screens in dark and light (`demo/gallery_*.sim`, contact sheets with `--sheets`); `PuckBridge --screenshots <dir>` draws every Mac window (each Settings pane, at window size and full length, the Setup pages, the helper card) with sample data, and each preview build attaches them as `MacScreenshots.zip`.
- `firmware/sim/demo/pb8.sim`; the simulator fails a test whose screen overflows (a screen holds 40 shapes and the rest silently went undrawn).
### Changed
- **Easier to read:** hints and secondary text are brighter (about 6:1 instead of 2.4-3.9:1); the **Cards** list shows three items instead of about one and a half; a thin scroll bar on the right edge replaces "2 of 5".
- **Orange always means working**, also on the face (it was neon green there); green only marks what's chosen, and is softer.
- **Light mode** has real contrast (hint text about 7:1, darker greens and oranges).
- The timer and alarm screens say what rang once, large, instead of "TIMER / Time's up / Timer / 0:00"; the connecting screen moves and says which wait it is.
- A right swipe on the clock does nothing (it opened a chat); "Listening" no longer fades to almost nothing.
- Settings: a Health section, plain wording ("Puck connected", "Autonomous's firmware"), honest firmware install text with a progress bar, Restore disabled when it's already on Autonomous's firmware, OpenHarness settings only when it's installed, "Take the Puck Back" in the menu, the Setup window remembers skipped steps and only says "You're all set" when you are.

## [0.8.3] - 2026-10-14
### Added
- **Custom timers on the puck** (Puck Bridge firmware 0.0.88-pb.7): tap the line under the clock for a **timer dial** (hours, minutes, seconds; tap + / − or drag a column), then Start. Tap the timer's line while it runs to see the time left and **Stop** it early. Also from the Mac (Settings → Puck → Timer: any hours, minutes and seconds) and the puck's Settings → Timer → **Custom…**.
- **Alarms** (firmware pb.7): up to four, set in Settings → Puck → Alarms or by voice. They ring on the puck (ALARM, the label, the time) and live in its memory, so **unplugging the puck clears them**.
- **Voice commands for the puck:** say "timer 2 hours 15 minutes", "set a timer for 90 seconds", "stop the timer", "alarm 7:30 am", "wake me up at 6", "alarm in 20 minutes for tea" or "cancel my alarms". Only an utterance that is just one of these goes to the puck; everything else still goes to Claude. Settings → Claude → Voice turns it off.
- **Hold to talk** (firmware pb.7, with the Cards, Dial or Compact list style): hold the face and speak; letting go sends. Tap-to-talk, tap-to-send still works. This replaces holding for the tabs (the clock's swipes reach them).
- **Folded Claude Code projects show their sessions:** Puck Bridge reads Claude Code's own session files on the Mac (`~/.claude/projects`) for projects folded in Claude's sidebar, including which one is working (and a finish alert when it's done). Cloud sessions aren't there, and a title can differ a little from Claude's. Settings → Claude → Claude Code turns it off.
- `firmware/sim/demo/{timer_dial,alarms,hold_talk,elapsed}.sim`.
- **New puck navigation** (Puck Bridge firmware 0.0.88-pb.6, with the Cards, Dial or Compact list style): the clock is home; swipe down for notifications, up for settings, left for your **Claude Code groups**, left again for your chats; right goes back. Tap a group to see its sessions; tap a session to open it on the puck.
- **Session status on the puck:** Claude Code rows show their pull request as Claude's sidebar does (**PR #9 merged** purple, **PR #12 open** green, **closed** red), or orange **Working · 1:23**, or **Reply ready**.
- **Light mode** for the whole puck: Settings → Puck → **Appearance** (Dark, Light, Match Mac), or Settings → Appearance on the puck.
- **Redesigned puck Settings:** rounded cards with the value on the right and real on/off switches; swipe down to close.
- README: screenshots of every puck screen in dark and light (`docs/screenshots/`, made by `firmware/sim/tools/readme_shots.py`).
- `firmware/sim/demo/nav.sim` and `nav_light.sim`: the whole navigation, in both themes.
- **List styles for the puck's chat and tab lists** (Puck Bridge firmware 0.0.88-pb.5 and later): **Cards**, **Dial**, **Compact list** or **Classic** (the original green pages and side pages). Choose in Settings → Puck → "Chat and tab lists", or on the puck: Settings → Lists. Every row shows what it's doing (orange "Working · 1:23", "Reply ready", "Idle"; tabs: "3 sessions · 1 working"). In the new styles, swiping only browses; tap a row to open it, or a tab to switch to it.
- `firmware/sim/demo/lists_{cards,dial,compact}.sim`: each style on the chat list and five tabs (browsing sends nothing, a tap opens or switches).
- `firmware/sim/demo/project_tabs.sim`: five tabs (Chats + four projects) on Puck Bridge firmware use the carousel, a browsed project is selected with the tab handshake and ✓ lands on its session.
### Changed
- In the new navigation a **tap on the clock** opens the face of the chat you were on, or the chats list when the current group has none (it showed an empty "No chats here" face).
- `firmware/sim/demo/lists_{cards,dial,compact}.sim` reach the groups by swiping, since holding the face now talks.
- **Claude stays in the background:** opening a chat from the puck no longer brings Claude to the front (Settings → Claude → "Bring Claude to the front…" turns it back on). Voice is typed into Claude in the background; only if that doesn't take does Claude come forward for a moment, and then the app you were using comes back.
- The puck's boot screen says **Puck Bridge** instead of "Harness".
- **One puck tab per Claude Code project again** (owner's choice): hold the face → Chats, then each project as Claude's sidebar groups them, with its 16 newest sessions. The single Claude Code tab showed only the 16 newest sessions of all projects, so quieter projects never appeared.
### Fixed
- **"Working" counts from when the turn started**, not from 0:00 when you open a chat on the puck (firmware pb.7 takes `elapsed` in `turn.started`; for a Claude Code session already working when it's opened, Puck Bridge reads the start from its session file).
- **Folded projects** in Claude's Code sidebar now get a tab too, and keep the sessions Puck Bridge last saw (a folded project shows no sessions to read). Picking a folded project on the puck unfolds it in Claude; opening or speaking to one of its sessions unfolds it first. A project never unfolded since Puck Bridge started shows an empty tab until it's picked or unfolded once.

## [0.8.2] - 2026-10-14
### Added
- **Puck Bridge firmware 0.0.88-pb.4** (all of the puck changes below; install it from Settings → Puck → Firmware).
- `scripts/test-firmware.sh` also compiles the firmware with GCC 14 and ESP-IDF's warnings-as-errors flags when GCC 14 is installed, so compile errors only the firmware build saw show up in seconds.
- **Timers** (Puck Bridge firmware pb.4): Settings → Timer on the puck (1 min to 1 hour, or cancel), or the Timer buttons in Settings → Puck on the Mac. The puck counts down by itself, shows it on the clock, and rings at the end until you touch it.
- **Hear the sounds before choosing them:** on the puck's Sound and Volume pickers, each choice plays when you stop on it.
### Changed
- **Tabs are a switch between your chats and Claude Code:** holding the puck's face now offers exactly two tabs, Chats and Claude Code (every Code session, all projects). Choosing one also switches Claude's sidebar to that view, and switching Claude's view on the Mac moves the puck to the matching tab.
- Code sessions carry their project name to the puck (shown small on Puck Bridge firmware).
- The startup chat choice no longer takes the puck off its clock (`focus` with `keepClock`).
- **Puck polish (from a screen-by-screen test of every flow in the firmware simulator):**
  - The tab screen is a clear switch: one card per tab (Chats / Claude Code) with how many chats or sessions it has and how many are working; tap one to switch, tap the current card or swipe to go back. It used to switch tabs while you were only swiping through.
  - The face's tips now match the new swipes ("Tap to talk", "Hold for tabs", "Swipe up for all chats", "Swipe right for the clock"), and "Choose a pane" / "Tap the name to switch panes" are gone. An empty tab says "No chats here".
  - The connecting screen says "Puck Bridge" and "Open Puck Bridge on your Mac" or "Loading your chats…" instead of just "Harness".
  - Messages from the Mac and voice errors are centred, say "Tap to close", close with a tap anywhere and go back to the clock if they came up over it. "Check Harness on your computer" became "No answer from the Mac. Try again."
  - The "stop this turn?" screen has proper Cancel / Stop buttons and the chat's name.
  - The chats list is headed with the tab's name (CHATS / CLAUDE CODE), and Code sessions show their project.
  - An empty or failed Settings page says how to get back ("Swipe left for the clock").
  - A picker no longer marks the first choice as current when nothing is.
### Fixed
- **Startup on the clock in every case:** the puck stays on its clock however the first messages arrive (chat list before or after the clock, a chat choice, a reconnect). Before, a list arriving after the clock sent it to the chat face.
- **Startup on the clock, also when Claude is read late:** Puck Bridge reads Claude before it sends the puck its first chat list, and once the puck's clock is up it no longer sends the startup chat choice to firmware that would leave the clock for it. The puck's first tab matches the view Claude is showing.
- Switching tabs on the puck while Claude is writing no longer flips Claude's view (that hid the reply, so its finish was never seen and the chat stayed "working" for 20 minutes).
- The puck's small-button Stop only presses Stop when the chat on screen is the one you asked to stop.
- Opening a chat or Code session from the Mac's menu moves the puck to the matching tab.
- Timer state can't go stale ("0:00 left" after a missed end); the puck's menu updates when a timer starts, ends or is cancelled.
- The puck's character picker always includes the current character (it holds 16), and a choice is matched by name if the list changed meanwhile.
- Two Code sessions with the same title in one project get separate ids; opening by title also checks the project.
- Code sessions are no longer marked working from their sidebar status until the words Claude uses are confirmed (only logged); a misread status could have kept a spinner going forever.
- A character removed on another Mac is moved to "Removed Characters" in Puck Bridge's support folder instead of being deleted (a different iCloud account looks the same).
- **The wrong chat showing as working:** when Claude starts writing, Puck Bridge now matches the conversation's own title more carefully (the row text may be cut short or carry a status like "#5 · Merged"), and when it can't tell which chat it is, it marks none instead of guessing the top row. When the conversation has a title, nothing else (text on screen that happens to equal another chat's name) decides. A row that just appeared counts as the new chat only at the top of its list. The log says why it picked the chat it did.

## [0.8.1] - 2026-10-14
### Added
- **Characters in iCloud Drive:** your imported characters are kept in iCloud Drive too (Puck Bridge → Characters), so importing them once puts them on every Mac signed in to your iCloud. Removing one removes it everywhere. Settings → Character → "Keep them in iCloud Drive" turns it off. They stay private: never in this app's repo or releases.
### Changed
- **Puck Bridge firmware 0.0.88-pb.3:** when Claude starts working while the clock is up, the clock stays and that chat's segment in the ring turns orange (it used to jump to the chat). The finished reply still beeps and shows its card. The idle clock now also comes up while Claude works, and holding the small button on the clock stops the chat that's working.
- **No more "Choose a pane" at startup:** the puck now starts on the clock with your first chat chosen (firmware pb.3), and Puck Bridge tells the puck which chat to show after it connects or switches tabs (the one you last opened, else the one open in Claude, else the first). Official firmware gets a real chat on its face as well.

## [0.8.0] - 2026-10-14
### Added
- **Puck Bridge firmware 0.0.88-pb.2** (`firmware/patches/0001-puck-bridge-firmware.patch`, replacing the pb.1 patch):
  - **Side pages:** Settings ← Clock → your chats. Swipe right from the first chat to reach the clock, right again for Settings; swipe up on a chat for the list of all chats. Dots show where you are.
  - **New clock:** big time, the date in spaced capitals, the weather, your character, and a ring with one segment per chat (orange = Claude working, white = finished and unread).
  - **Settings with pickers:** Character, Sound, Volume, Brightness and Clock after open a page of choices. Characters are drawn as themselves, animated, and you swipe through them and tap Choose.
  - Fixes for Settings on the puck: rows now take a normal press (the strict tap rule missed many real presses), a quick second tap is no longer lost when the Mac re-sends the menu, and the clock decides when you lift your finger instead of on first contact.
- `firmware/sim`: a host simulator of the puck's firmware (its real UI and cable code) with scripted tests and screenshots; `scripts/test-firmware.sh` runs it in CI on every push.
- **Claude Code sessions, as Claude's sidebar shows them:** Puck Bridge now reads Claude's Code view (the Mode switch at the top of its sidebar) and lists each project's sessions on the puck, one tab per project (Chats first). Both lists are remembered while Claude shows the other one, and Code sessions also across restarts (titles only).
- **Open and talk to Code sessions from the puck:** pausing on a session, tapping it or speaking to it switches Claude to its Code list, opens the session and types there. Same for a chat while Claude shows Code sessions. The menu-bar menu gets **Open Code Session**.
- **Setup window:** on first launch (or a new Mac), one permission at a time: Accessibility, Speech Recognition, Location. Each step moves on by itself when macOS reports the grant. For Accessibility a small card floats beside System Settings with an icon you can drag into the list. Menu → Finish Setting Up… and Settings → General → Walk Me Through It… bring it back.
- The puck's own log lines (its 0x04 frames) now go into PuckBridge.log as `puck: …` (at most 20 a second), so firmware problems can be read from the Mac.
- Puck menu rows carry their choices for firmware pb 2 (Character with each pet, Sound, Volume, Brightness, Clock after); a choice made on the puck's picker page arrives as `pb.menu.set`.
- Code sessions whose sidebar status says they are working show as busy on the puck and beep when they finish, even in the background (unverified: which status words Claude uses; every new one is logged once).
### Changed
- Code sessions no longer come from `~/.claude/projects` (that missed Cloud sessions and mixed Code sessions into the chat list when Claude showed its Code view). The "Claude Code" all-sessions tab is gone; each project has its own tab.
- The open conversation is now found from its own title (Claude's web view is titled "<title> - Claude Code"), before the older text heuristics.
- Speech and Location are no longer asked for the moment the app starts; the Setup window asks for them in turn.

## [0.7.0] - 2026-10-13
### Added
- `firmware/patches/0001-puck-bridge-clock-and-home.patch` (firmware `0.0.88-pb.1`) and `firmware/README.md` (what it changes, the `ambient` / `pb.menu` / `pb.sound` protocol, how to restore). Passes all 33 upstream firmware host contracts.
- **Puck Bridge firmware** for the round puck: the official firmware plus `firmware/patches` (built in CI from a pinned OpenHarness commit with ESP-IDF 5.5, bundled in the app). Settings → Puck → Firmware installs it over the USB cable; **Restore…** downloads Autonomous's official firmware, checks it, and puts it back. The puck keeps its previous firmware as a fallback.
- **Clock + weather face** (needs Puck Bridge firmware): shows after 5 minutes idle (Settings → Puck → Clock face: Never/2/5/10/15/30 min, 24-hour clock, weather on/off). Weather comes from Open-Meteo using this Mac's location (Location Services; only a rounded location is sent).
- **Small button = home** (needs Puck Bridge firmware): tap → clock face; hold while Claude writes → stop; hold otherwise → screen off/on.
- Location row in Settings → General → Permissions.
- **Installer:** releases now include `PuckBridge.dmg`. Open it and drag Puck Bridge onto the Applications folder (the window shows the app, an arrow and Applications). `PuckBridge.zip` stays for the in-app updater.
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

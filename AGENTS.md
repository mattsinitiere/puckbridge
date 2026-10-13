# AGENTS.md — Puck Bridge

Guide for AI coding agents (Claude Code etc.) working in this repo. Read this before changing anything.

## What this is

**Puck Bridge** is a macOS menu-bar app that connects the **Autonomous Harness puck**, a round ESP32-S3 USB desk display, to **Claude Desktop**, replacing Autonomous's OpenHarness app/daemon.

What it does today:
- Shows the user's **recent Claude Desktop chats** on the puck. Pausing on one makes Claude open it.
- Detects when **Claude finishes a reply in the open chat**, then makes the puck beep and show a card with the start of the reply.
- **Voice:** puck audio is transcribed on-device (Apple Speech), typed into the selected chat, and sent (optionally paste-only).
- **Small puck button while Claude is writing** asks to stop, then the app presses Claude's Stop button.
- Auto-connects, survives unplug/replug and Claude restarts, starts at login, and self-updates from GitHub Releases.

Owner: Matthew Sinitiere (`mattsinitiere`). Daily machines: Mac Studio + MacBook Pro M1, latest macOS. **He doesn't usually work in the terminal.** Keep any steps he has to run short and copy-pasteable, and prefer GUI/menu solutions.

## Repo map

```
Sources/main.swift            Entire app (single file, no dependencies). Sections are marked `// MARK:`.
Resources/Info.plist          Bundle metadata. Version + PBUpdateRepo are filled in by build.sh.
scripts/build.sh [vX.Y.Z]     Universal build (arm64 + x86_64) → build/Puck Bridge.app + dist/PuckBridge.zip
scripts/dev-install.sh        Build this checkout and install it to /Applications (local testing)
scripts/install.sh            End-user install/update from the latest GitHub release (curl | bash)
.github/workflows/release.yml Tag v* (or publishing a release) → build on macOS runner → attach PuckBridge.zip
CHANGELOG.md                  Keep a Changelog format. Update "Unreleased" with every change.
LICENSE                       MIT (ours) + attribution for the OpenHarness-derived protocol code.
```

`main.swift` sections, in order: Settings + log → Puck framing → Serial port → Claude Desktop via Accessibility → Voice (Transcriber) → Bridge (state machine + main loop) → Updates from GitHub Releases → Menu-bar app.

## Build, run, release

- **Requirements:** macOS 14+, Xcode command-line tools (`swiftc`). No SwiftPM, no Xcode project. Keep it that way unless there's a strong reason.
- **Local test:** `scripts/dev-install.sh`, then `tail -f ~/Library/Logs/PuckBridge.log`.
- **Release:** update `CHANGELOG.md`, commit, then create a GitHub release with a new tag `vX.Y.Z` (or `git tag vX.Y.Z && git push --tags`). CI builds and attaches `PuckBridge.zip`. The in-app updater looks for an asset named **exactly** `PuckBridge.zip` containing `Puck Bridge.app`.
- **Versioning:** the tag is the source of truth (`v0.3.1` → `CFBundleShortVersionString 0.3.1`). Semver: patch = fixes, minor = features, major = breaking changes to puck firmware compatibility.
- **Signing:** CI signs with the self-signed identity **"Puck Bridge Signing"** if repo secrets `SIGNING_CERT_P12` / `SIGNING_CERT_PASSWORD` exist, otherwise ad-hoc. Ad-hoc builds change identity every release, so **macOS forgets the Accessibility/Speech permissions after each update.** Keep the bundle id `dev.sinitiere.puckbridge` stable. Never commit `.p12` files.
- **Updates:** `Updater` calls `https://api.github.com/repos/<PBUpdateRepo>/releases/latest` unauthenticated, which requires the repo to stay **public**. Install = download, `ditto -x`, then a detached `/bin/sh` swaps the bundle in place and relaunches.

## The puck: hardware + protocol

Source of truth: **github.com/autonomous-ai/openharness** (MIT). Host side: `cli/src/cable/cableFrame.ts`, `cableSession.ts`, `serial.ts`. Device side: `devices/harness-device/firmware/main/cable_client.c`, `ptt.c`, `ui/habitat/ui_habitat.c`. Check there before guessing.

**Link.** USB CDC serial `/dev/cu.usbmodem*`. Open with `O_RDWR|O_NOCTTY|O_NONBLOCK|O_EXLOCK`, then raw mode + **`CLOCAL`** (without it macOS reports EOF immediately) and clear `HUPCL`. Only one process can own the port.

**Frame.** `A5 48 | ver=1 | type | len u16 LE | payload | crc16 LE`. CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) over `ver..payload`. Max payload 8192. Types: `0x01` JSON (has `"t"`), `0x02` PCM (16-bit mono LE, puck → host, during voice), `0x03` firmware, `0x04` log line, `0x05` pet pack. The puck's ROM/boot text shares the wire, so the decoder must skip noise and resync on the magic.

**Session.**
- Puck sends `hello {product:"harness", fw, proto, …}` roughly every 15 s. **Answer every one** with `welcome {proto:3, app, machine:{id,name}, selected, voiceLang, features:[…]}`. Push the chat list only on the first greeting of a session.
- The host must send `ping` every ~10 s; the puck answers `pong`.

**Host → puck messages we use**

| Message | Fields | Purpose |
|---|---|---|
| `agents.begin` | | Start of chat list |
| `agent` | `id, name, engine, model, effort, machineId, machine` | One per chat |
| `agents.end` | `total, tab` | End of chat list |
| `machines.begin` / `machine` / `machines.end` | `machine`: `{id, name, state:"ready", local:true}`; `end`: `{selected, source:"local"}` | Reply to `machines.list` |
| `machine.selected` | `machineId` | Reply to `machine.select` |
| `turn.started` | `agentId, text` | Shows a spinner on the tile and makes it "busy" (this is what lets the small button stop it) |
| `turn.done` | `agentId` | Stops the spinner, no beep |
| `summary` | `agentId, name, engine, machine, recap≤190, text` | Beep + notification card. Add `restore:true` for history with no beep. |
| `notif.replace` | `items:[]` | Reset the drawer on attach |
| `voice.transcript` | `routeId:"", text, agentId, agentName, needsConfirm:false, uploadId` | Voice result |
| `voice.error` | `message, uploadId` | Voice failure (always answer `voice.end`, or the puck hangs) |
| `toast` | `text` | Brief message on the puck |
| `swarms` | `selected, items:[{id≤47B, name≤39B, agents, panes}], tiles:[]` | Tab list (max 24). Send only when ids/names/selection change: a new list cancels the user's swipe on the TABS screen. |

Other types the firmware understands but we don't use yet: `focus`, `turn.activity`, `question`, `question.close`, `settings.set`, `companion.*`, `models`, `fw.offer`, `pet.*`, `selection.state`, `carry.state`, `form.state`, `visit.state`.

**Puck → host messages we handle:** `hello`, `pong`, `machines.list`, `machine.select`, `agents.list`, `agents.refresh`, `focus {agentId}` (carousel selection; we open the chat after ~0.8 s settle, ignored in the first 3 s of a session), `agent.open {agentId}` (tap on a card), `turn.stop {agentId}`, `swarm.select {swarmId}` (sent continuously while the user swipes the TABS carousel), `swarms.list`, `voice.begin {agentId?, sr, lang, uploadId, …}`, PCM frames, `voice.end`, `voice.abort`, `notif.read`.

**Buttons (official firmware ≥0.0.88)**
- **Large/top** (PWR key on the AXP2101 PMIC): tap toggles the screen. Long press is a **hardware restart in the PMIC and can't be changed**.
- **Small/bottom** (GPIO0 = **BOOT**): tap cancels voice, or opens the STOP confirm when the focused tile is busy (confirming sends `turn.stop`), or goes home. Hold ≥800 ms toggles the screen. Holding BOOT while plugging in forces ROM download mode, which is the **recovery path for bad firmware**.
- Button presses are handled entirely on-device. The host never sees them, except via `turn.stop`.

**Tabs (`Bridge.buildTabs`).** Hold the face ≥650 ms → TABS carousel. Tab ids: `chats`, `code`, `p-<fnv64 of folder>`. Switch handshake (firmware `workspace.c`): device sends `swarm.select` → host replies `swarms` with `selected` = that id → device sends `agents.refresh` → host streams `agents.begin`/`agent`×≤16/`agents.end {tab: <that id>}`. The device only lands when `agents.end.tab` matches; otherwise it shows "The tab did not open" after 8 s. Always answer `agents.refresh` with a full list, even if unchanged. Agent ids for Code sessions are `cc-<session uuid>`.

## Claude Desktop: the Accessibility contract

Bundle id `com.anthropic.claudefordesktop` (Electron). Set `AXManualAccessibility = true` on the app element so the tree populates. These selectors were verified against the user's install in Oct 2026, **and will break when Claude's UI changes**, so re-verify with Accessibility Inspector or a tree dump first when something stops working.

- **Sidebar chat row:** an `AXButton` whose title is `"<status> <chat title>"`. Its subtree holds an `AXImage` (description = status, e.g. `Idle`/`Done`) and an `AXStaticText` (value = title). **Chat id = that AXImage's `AXDOMIdentifier`** (e.g. `_r_6oa_`). It's stable across renames within a session but **not across Claude restarts**. Pressing the row button opens the chat.
- **Writing indicator:** a button with description `Stop` exists only while Claude streams in the open chat. `Send` appears only when the composer has text. **"Stop disappeared" means finished OR the user switched chats.**
- **Composer:** `AXTextArea`, description `"Write your prompt to Claude"`. It's rich text. Setting `AXValue` is unreliable, so focus it and paste with ⌘V via CGEvent, then restore the clipboard.
- **Message action buttons:** `"Show message actions for You said: …"` / `"… Claude responded: …"`. These may only exist on hover, so treat them as a weak signal.
- **Conversation text:** `AXStaticText` elements positioned right of the sidebar's right edge.

**Known limits, all confirmed by testing**
- Sidebar status icons do **not** change while a normal chat generates. Idle/Done applies to tasks (Cowork/Dispatch/scheduled).
- **Background finishes are invisible.** If the user switches away mid-reply, nothing in the UI changes when it completes, and Claude sent no macOS notification while in-app (untested with Claude unfocused, which is worth testing).
- **Claude Code sessions** live under the Code tab and aren't in the Chat sidebar. We don't switch Claude's tabs behind the user; instead `CodeSessions` reads `~/.claude/projects/<folder>/<session>.jsonl` (first 64 KB: `cwd`, `summary`, first prompt). Unverified: whether Claude Desktop's Code tab stores its sessions there. Opening a Code session in Claude from the puck isn't implemented (needs the Code tab's AX tree).
- **Project chats** are collapsed under project toggles, so only Recents show.

**Finish detection (`Bridge.checkClaude`)**
- When `writing` goes false → true: snapshot the chat order, conversation texts, message labels, and composer text (the prompt). Send `turn.started` to the best-guess chat (opened-from-puck, else the top row).
- When `writing` goes true → false: decide "same chat" if ≥50% of the pre-writing texts or message labels remain, **or** a chat row first appeared within 5 s of writing starting (a new chat from the home screen). If so, `notify(activeChat, replyText)`. The reply is the new texts minus the prompt. Otherwise log a switch and stay silent.
- **Active chat:** a newly appeared row, else the row that jumped furthest up the list, else the one opened from the puck, else the first row.
- An empty sidebar read is ignored unless it happens 3 times in a row, to prevent puck flicker.

**Do not** use claude.ai's private web API or session cookies. That's unofficial, against the terms, and could get the account flagged. Stick to Accessibility.

## OpenHarness coexistence

OpenHarness runs a launchd agent `ai.autonomous.harness.harnessd` (KeepAlive) that grabs the port with `O_EXLOCK`. The app stops it via `launchctl bootout gui/$UID/ai.autonomous.harness.harnessd` when the port is busy and `Take the puck from OpenHarness automatically` is on (default). The menu item **Restore OpenHarness service** re-bootstraps it from `~/Library/LaunchAgents/…plist` and turns auto-take off. **When OpenHarness connects, it auto-updates the puck's official firmware.** That matters once we ship custom firmware.

## Conventions

- Single-file Swift, AppKit, no third-party dependencies, macOS 14+. Keep `// MARK:` sections.
- Log with `say()` (stdout + `~/Library/Logs/PuckBridge.log`). Log user-visible events and decisions, never chat contents beyond titles, and never transcripts unless debugging.
- The bridge loop runs on a background thread. UI updates go through `DispatchQueue.main`. Puck writes go through `Bridge.send` (locked).
- New user preferences go in `enum Pref` (UserDefaults) with a checkmark menu item.
- Don't break compatibility with **official** puck firmware. Custom-firmware-only features must be gated on a capability the puck advertises in `hello` (see roadmap).
- Every change gets a line under `## [Unreleased]` in `CHANGELOG.md`.

## Testing (no automated tests yet; hardware in the loop)

Before tagging a release, on a Mac with the puck and Claude Desktop:
1. ◎ shows `Puck: connected (fw …)` and `Claude: N chats`. The puck's PANES lists the chats.
2. Pause on a chat on the puck: Claude opens it.
3. Ask Claude something and stay on the chat: beep, plus a card showing the start of the reply.
4. Ask, then switch chats mid-reply: no alert, and the log says "Switched chats…".
5. New chat from Claude's home screen: alert on finish.
6. Voice: pause on a chat, then tap-and-speak. The text lands in that chat and sends (or is only pasted, per the menu setting).
7. Small button while Claude writes, then confirm: Claude stops.
8. Unplug/replug the puck, and quit/relaunch Claude: everything recovers without restarting the app.
9. ◎ → Check for updates… on an older build finds and installs the release.

Good next step: add unit tests for the framing/CRC against the shared vectors in openharness `cli/src/cable/vectors/cable_frame.txt` (all 27 currently pass in a Python port).

## Roadmap

1. **Signing certificate in CI** so permissions survive updates (README has steps). This is the user's to-do.
2. **Background-finish alerts:** test whether Claude posts macOS notifications when its window is unfocused. If it does, read Notification Center banners via AX and forward them.
3. **Custom firmware ("Step 6"):** fork `devices/harness-device/firmware` (ESP-IDF 5.5+, ESP32-S3, 466×466 round AMOLED). Goals:
   - Report button gestures to the host instead of hard-coding them: e.g. `{"t":"button","id":"top|bottom","gesture":"tap|double|hold"}`, advertised via a `hello` capability like `buttons:"events-v1"`. Puck Bridge then maps gestures to actions from the menu (screen on/off, stop Claude, start voice, next/prev chat, open Claude). The top long-press stays a hardware restart.
   - An **idle clock + weather face**: the host sends e.g. `{"t":"ambient","time":<epoch>,"tz":"…","tempF":…,"cond":"…"}` every minute. Weather comes from Open-Meteo (free, no key) using a ZIP or coordinates set in the menu.
   - Release firmware through this repo's pipeline. Back up the full 16 MB flash (`esptool read_flash`) before the first flash. Keep OpenHarness's service off, or it will overwrite the firmware. First check secure boot is off (`esptool get_security_info`; the repo docs say Secure Boot v2 isn't enabled yet).
4. **Voice polish:** a review-before-send flow using the puck's draft UI (`voice.end {review:true}` → `voice.draft`). Optional slash-commands.
5. Open Claude Code sessions (and send voice to them) from the puck. Needs a dump of Claude's Code tab AX tree from the user's Mac.

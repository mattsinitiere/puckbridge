# AGENTS.md — Puck Bridge

Guide for AI coding agents (Claude Code etc.) working in this repo. Read this before changing anything.

## What this is

**Puck Bridge** is a macOS menu-bar app that connects the **Autonomous Harness puck**, a round ESP32-S3 USB desk display, to **Claude Desktop**, replacing Autonomous's OpenHarness app/daemon.

What it does today:
- Shows the user's **recent Claude Desktop chats** on the puck. Pausing on one makes Claude open it.
- Detects when **Claude finishes a reply in the open chat**, then makes the puck beep and show a card with the start of the reply.
- **Voice:** puck audio is transcribed on-device (Apple Speech), typed into the selected chat, and sent (optionally paste-only).
- **Small puck button while Claude is writing** asks to stop, then the app presses Claude's Stop button.
- **Character:** the user picks the pet the puck animates (Clawd, Codex Bot, Jolly, Fo), or imports a petdex sprite sheet that is converted and uploaded to the puck.
- **Puck settings** (brightness, beep, calm mode, scrolling, voice language) from a SwiftUI **Settings window**, and from **settings tiles** in the puck's own carousel.
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
.github/workflows/build.yml   Every push/PR: build, check character packs with the firmware's parser, publish the branch's preview
.github/workflows/previews-cleanup.yml  A deleted branch deletes its preview pre-release
scripts/publish-preview.sh    CI: (re)publish pre-release preview-<branch> with key: value notes the app parses
scripts/preview-tag.sh        Branch name → preview tag
scripts/make-signing-cert.sh  Owner, once: signing certificate → repo secrets (scripts/ci-import-cert.sh uses them in CI)
firmware/UPSTREAM             OpenHarness commit the puck firmware is built from
firmware/patches/*.patch      Puck Bridge firmware (side pages, clock face, home button, settings + pickers, sounds); see firmware/README.md
firmware/sim/                 Host simulator: real firmware UI + cable code, stubbed RTOS; demo/*.sim scripts with `expect` checks, `shot` PNGs
scripts/test-firmware.sh      CI (Linux): clean upstream + patches → firmware/sim/test.sh (ASan/UBSan). Run it after any patch change
scripts/build-firmware.sh     CI (Linux + Docker espressif/idf:v5.5): upstream + patches → firmware/out/PuckFirmware.{bin,json}, bundled in the app
scripts/make-dmg.sh           Drag-to-Applications installer dist/PuckBridge.dmg (dmgbuild; window art in Resources/dmg/)
tests/check_pet_pack.c        Runs an HPET pack through upstream pet_store.c (compiled from a pinned OpenHarness commit)
tests/make_test_sheet.py      Draws synthetic petdex sheets for that test (stdlib only)
CHANGELOG.md                  Keep a Changelog format. Update "Unreleased" with every change.
LICENSE                       MIT (ours) + attribution for the OpenHarness-derived protocol code.
```

`main.swift` sections, in order: Settings + log → Puck framing → Serial port → Claude Desktop via Accessibility → Voice (Transcriber) → Characters (built-ins + `PetPack` sprite-sheet → HPET encoder + `CustomCharacter`) → Bridge (state machine + main loop) → Updates from GitHub Releases → Settings window (SwiftUI: `AppModel` + panes) → Menu-bar app → Command line (`--make-pet`, used by CI).

There is no Swift toolchain on Linux cloud sessions (download.swift.org is blocked), so **the Build workflow is the compile check**: push and read its result before claiming Swift changes work.

## Build, run, release

- **Requirements:** macOS 14+, Xcode command-line tools (`swiftc`). No SwiftPM, no Xcode project. Keep it that way unless there's a strong reason.
- **Local test:** `scripts/dev-install.sh`, then `tail -f ~/Library/Logs/PuckBridge.log`.
- **Release:** update `CHANGELOG.md`, commit, then create a GitHub release with a new tag `vX.Y.Z` (or `git tag vX.Y.Z && git push --tags`). CI builds and attaches `PuckBridge.zip`. Or Actions → Release → Run workflow (branch `main`, tag `vX.Y.Z`), which creates the tag itself; use this from Claude Code cloud sessions, whose git proxy can't push tags. The in-app updater looks for an asset named **exactly** `PuckBridge.zip` containing `Puck Bridge.app`.
- **Versioning:** the tag is the source of truth (`v0.3.1` → `CFBundleShortVersionString 0.3.1`). Semver: patch = fixes, minor = features, major = breaking changes to puck firmware compatibility.
- **Signing:** CI (Release *and* Build) signs with the self-signed identity **"Puck Bridge Signing"** if repo secrets `SIGNING_CERT_P12` / `SIGNING_CERT_PASSWORD` exist (`scripts/ci-import-cert.sh`); the owner makes them once with `scripts/make-signing-cert.sh`. Without them, Build signs with a throwaway certificate (to test the path) and Release signs ad-hoc. Settings → General shows which signature the running app has. Ad-hoc builds change identity every release, so **macOS forgets the Accessibility/Speech permissions after each update.** Keep the bundle id `dev.sinitiere.puckbridge` stable. Never commit `.p12` files.
- **Updates:** `Updater` calls `https://api.github.com/repos/<PBUpdateRepo>/releases/latest` unauthenticated, which requires the repo to stay **public**.
- **Previews / Beta Access:** the Build workflow publishes each pushed branch as pre-release `preview-<branch>` (notes carry `branch:`, `commit:`, `version:`, `signed:`, `summary:` lines; version = `<latest release>.<run number>`). Builds carry `PBChannel` (branch, empty for releases) and `PBCommit` in Info.plist. With Pref `betaAccess`, a preview build's update check also offers newer builds of its own branch; a newer release always wins. Actions artifacts can't be used for this: downloading them needs a GitHub login. Install = download, `ditto -x`, then a detached `/bin/sh` swaps the bundle in place and relaunches.

## The puck: hardware + protocol

Source of truth: **github.com/autonomous-ai/openharness** (MIT). Host side: `cli/src/cable/cableFrame.ts`, `cableSession.ts`, `serial.ts`. Device side: `devices/harness-device/firmware/main/cable_client.c`, `ptt.c`, `ui/habitat/ui_habitat.c`. Check there before guessing.

**Link.** USB CDC serial `/dev/cu.usbmodem*`. Open with `O_RDWR|O_NOCTTY|O_NONBLOCK|O_EXLOCK`, then raw mode + **`CLOCAL`** (without it macOS reports EOF immediately) and clear `HUPCL`. Only one process can own the port.

**Frame.** `A5 48 | ver=1 | type | len u16 LE | payload | crc16 LE`. CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) over `ver..payload`. Max payload 8192. Types: `0x01` JSON (has `"t"`), `0x02` PCM (16-bit mono LE, puck → host, during voice), `0x03` firmware, `0x04` log line, `0x05` pet pack. The puck's ROM/boot text shares the wire, so the decoder must skip noise and resync on the magic.

**Hello.** `hello` carries `fw`, `hw`, `mac`, `proto`, **`settings`** (the full settings object, see below), **`pets`** (newest pet-pack version the firmware reads; absent = no custom pets) and **`petIds`** (packs it holds).

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
| `toast` | `text` | Message screen on the puck (full screen, not a brief overlay) |
| `focus` | `agentId` | Moves the puck's carousel to that tile |
| `settings.set` | any of `brightness 0-100, muted, quiet, scrollReversed, voiceLang (≤7)` (also `focusFace, straightTitle, followCompanion, character`) | Partial update; one bad field rejects the frame. Replies `settings.state {ok, error?, settings}` twice (immediately, then after the NVS write). Empty `settings.set` = read. |
| `pet.map` | `all: id\|null, engines: {engine: id}` | Which custom pack draws for which engine. RAM only, no reply. |
| `pet.offer` / `pet.drop` | `id (16 hex), size, crc` / `id` | Start/abandon a custom-pet upload (see Characters) |
| `swarms` | `selected, items:[{id≤47B, name≤39B, agents, panes}], tiles:[]` | Tab list (max 24). Only new ids/names (or selection) cancel the user's swipe on the TABS screen; from pb 4 items carry `working` and are re-sent when the counts change. |

Other types the firmware understands but we don't use yet: `turn.activity`, `question`, `question.close`, `companion.*`, `models`, `fw.offer`, `selection.state`, `carry.state`, `form.state`, `visit.state`.

**Puck → host messages we handle:** `hello`, `pong`, `machines.list`, `machine.select`, `agents.list`, `agents.refresh`, `focus {agentId}` (carousel selection; we open the chat after ~0.8 s settle, ignored in the first 3 s of a session), `agent.open {agentId}` (tap on a card), `turn.stop {agentId}`, `swarm.select {swarmId}` (sent continuously while the user swipes the TABS carousel), `swarms.list`, `voice.begin {agentId?, sr, lang, uploadId, …}`, PCM frames, `voice.end`, `voice.abort`, `notif.read`, `settings.state`, `pet.accept` / `pet.progress {written}` / `pet.done` / `pet.error {reason}`.

**Busy expires.** The puck drops a tile's busy state 25 s after the last `turn.started` (`ui_prune_stale_busy`), which stops the working animation and the STOP option. The bridge re-sends `turn.started` every 10 s while Claude writes. `turn.activity` does not refresh it.

## Characters and puck settings (official firmware, verified in source Oct 2026)

- **The pet is chosen by each tile's `engine`** (`focus.c pet_for`): a custom pack mapped to that engine, else the built-in pet of that name. Built-ins: `claude` (Clawd), `codex` (robot), `muse` (Jolly), `fo` (ghost). Other engines also change the tile's badge colour. Puck Bridge tags every chat with the chosen engine; a custom character is a pack mapped to `claude`.
- `settings.set {character}`, `companion.set` and `followCompanion` do **nothing** on official builds (`HABITAT_FOCUS_ONLY`). Don't build on them.
- **Custom packs (HPET, frame type 0x05):** `pet.offer` → `pet.accept` → raw pack bytes in ≤ 8 KB frames, **never more than 16 KB ahead of the last `pet.progress`** (the USB link drops bytes silently past that) → `pet.done` or `pet.error {crc|version|shape|busy|memory}`. 1 MB max, 4 packs max, held in PSRAM, so they're **lost when the puck restarts**: resend when `hello.petIds` lacks ours. Encoder: `PetPack` in main.swift, a port of OpenHarness `cli/src/cable/pets/{sheet,convert,pack}.ts`; parser: firmware `pet_store.c`.
- **Character library** (`CharacterLibrary`): `~/Library/Application Support/Puck Bridge/Characters/<slug>/{character.json, spritesheet.*}`, mirrored folder-by-folder to iCloud Drive `Puck Bridge/Characters` (`sync()`, Pref `syncCharacters`, UserDefaults `cloudCharacters` = folders seen in iCloud, so a folder gone from there was removed on another Mac; an empty iCloud folder never deletes). **Never commit or bundle the owner's imported characters:** several are third-party IP (Kirby, Pikachu, Patrick Star) and this repo and its releases are public.
- **There is no settings screen on the puck.** OpenHarness removed it; its "controls" list is fixed actions. The puck never changes a setting on its own, so `hello.settings` / `settings.state` are the truth and the Mac only sends changes. The finish beep is **muted by default** on a fresh puck.
- **The Settings tab** is how settings change from the puck without custom firmware: a puck tab (`settings`, last in the TABS carousel) whose rows are tiles (`puckbridge-settings-*`), with how-to text sent as `summary {restore:true}`. On the Focus face a touch starts voice for the tile on screen, so a quick touch-touch (< 1.2 s of audio, or nothing heard) cycles the value, and a spoken value sets it. `focus` on a tile is ignored; `agent.open` on a tile counts as a tap. **Not yet tested on hardware.**
- No message sets the puck's clock on official firmware; the clock face is Puck Bridge firmware.

## Puck Bridge firmware (`firmware/`)

- Official firmware + `firmware/patches/*.patch`, built by the `firmware` CI job (Ubuntu, Docker `espressif/idf:v5.5`, cached by patch hash), bundled as `Contents/Resources/PuckFirmware.{bin,json}`. Version `0.0.88-pb.N` (`version.txt` in the patch; **bump N for every firmware change**, or pucks on the previous build are never offered it). `hello` carries `"pb"`: the protocol level (pb.1 → 1, pb.2 and pb.3 → 2, pb.4 → 3: timers, previews, keepClock, project; pb.5 → 4: `pb.ui {lists}` list styles, `swarms` items' `working`; pb.6 → 5: clock-home navigation and the Claude Code groups page with the new styles, agents' `status`/`tone` (`Bridge.puckStatus`), `pb.ui {theme}` (Pref `puckTheme`: dark, light, auto = the Mac's appearance), settings cards, 12 menu rows (Lists, Appearance), "Puck Bridge" boot wordmark).
- **To change it:** apply the patch to an upstream checkout (`firmware/UPSTREAM`), edit, commit there, and regenerate the single patch with `git diff --binary <upstream> > firmware/patches/0001-puck-bridge-firmware.patch` (it vendors two small fonts, `fonts/Inter-Pb*.ttf`, and the generated `main/ui/habitat/pb_faces.c`; `scripts/gen_pb_faces.py` remakes them). Then `scripts/test-firmware.sh`, and add a `firmware/sim/demo/*.sim` for new behaviour.
- **Install path = the official OTA over the cable:** `fw.offer {version, size, sha256}` → (slot erase, seconds) `fw.accept` → type-0x03 frames ≤ 8 KB, ≤ 16 KB ahead of `fw.progress {written}` → `fw.done` → reboot → `hello` with the new `fw`. `fw.error {message}`; silence = declined (e.g. during voice). The firmware checks SHA-256 and that `esp_app_desc.version` equals the offered version; no signature (no secure boot in the shipped sdkconfig). Rollback is enabled, but the image is marked valid as soon as it boots and opens the cable (app_main.c `fw_mark_valid`), so rollback only covers images that crash before that.
- **Restore:** Settings → Puck → Firmware → Restore downloads Autonomous's published manifest (`storage.googleapis.com/s3-autonomous-upgrade-3/harness/esp32/ota/metadata.json`, key `commander`), verifies size + SHA-256, and sends it the same way. OpenHarness also reinstalls official firmware whenever it connects.
- **Extensions (only when `hello.pb >= 1`):** `ambient` (pre-formatted clock + weather strings, every minute), `pb.menu` / `pb.menu.open` / `pb.menu.tap` (the device Settings menu: the firmware draws rows, `Bridge.menuTap` changes values), from pb 2 rows with `choices` + `index` shown on a picker page and answered with `pb.menu.set {id, index, value}` (`Bridge.menuSet`; the whole `pb.menu` must stay ≤ 512 JSON tokens), `pb.sound {style: chime|soft|bell|digital, volume, test}` (sent after every welcome), from pb 4 `pb.ui {lists: cards|dial|compact|classic}` (`Bridge.sendLists`, after every welcome; Pref `listStyle`, Settings → Puck and the puck's Settings → Lists, its tenth and last menu row). Full spec: `firmware/README.md`.
- **Navigation (pb.6, with a new list style):** the clock is home: down = INBOX, up = PBMENU, left = GROUPS (`render_groups`: the `code*` tabs; a tap = `A_GROUP` → tab handshake with `pb.land_list`, landing on AGENTS), left again = the chats (`A_PB_CHATS`); right goes back (face → AGENTS → GROUPS → CLOCK). `firmware/sim/demo/nav.sim` / `nav_light.sim` walk it. Opening a chat from the puck never brings Claude forward unless Pref `bringForward` (default off); voice pastes into a background Claude via `CGEvent.postToPid` and only flashes it forward (then re-activates the previous app) when the paste didn't land.
- **Side pages (pb 2, Classic style):** `Settings ← Clock → panes`; they switch on when the host sends `ambient`/`pb.menu`/`pb.sound`, and then the face reports no desktop scroll (vertical swipes are navigation). An official daemon gets the official behaviour.
- No ESP-IDF in Linux cloud sessions (Espressif's servers are blocked): CI is the compile check, and `firmware/sim` is the behaviour check. The firmware's own host tests (`test/test_*.py`) do run locally with a sparse esp-idf clone (components/json, components/esp_rom at v5.5) as IDF_PATH.

**Buttons (official firmware ≥0.0.88)**
- **Large/top** (PWR key on the AXP2101 PMIC): tap toggles the screen. Long press is a **hardware restart in the PMIC and can't be changed**.
- **Small/bottom** (GPIO0 = **BOOT**): tap cancels voice, or opens the STOP confirm when the focused tile is busy (confirming sends `turn.stop`), or goes home. Hold ≥800 ms toggles the screen. Holding BOOT while plugging in forces ROM download mode, which is the **recovery path for bad firmware**.
- Button presses are handled entirely on-device. The host never sees them, except via `turn.stop`.

**Tabs (`Bridge.buildTabs`).** Hold the face ≥650 ms → TABS carousel. Tab ids: `chats`, then `code-<fnv64 of project>` per Claude Code project in sidebar order (its newest 16 sessions; each `agent` carries `project`; at most 23 projects), `settings` (last, official firmware only). Projects come from `ClaudeView.projects` (every project group, **folded ones too**: a folded group shows its name and "New session in …" but no rows) and are kept in `codeProjects`; `mergeCodeRows` keeps a folded project's remembered sessions. Choosing a tab switches Claude's sidebar to Chat or Code (`pendingMode`, ~1 s after the last `swarm.select`, never while Claude writes) and unfolds a folded project (`pendingUnfold` → `Claude.unfold`, which presses the project's name button, at most once per 4 s per project because a second press folds it). Opening or speaking to a session in a folded project unfolds it first. **Unverified on hardware:** that pressing the project's name unfolds it. Switching Claude's view on the Mac moves the puck (`followClaudeMode`: to the open session's project, else the first). With 1–3 tabs Puck Bridge firmware shows cards (its card counts say "sessions" only for the id `code`); with more it uses the stock carousel. Switch handshake (firmware `workspace.c`): device sends `swarm.select` → host replies `swarms` with `selected` = that id → device sends `agents.refresh` → host streams `agents.begin`/`agent`×≤16/`agents.end {tab: <that id>}`. The device only lands when `agents.end.tab` matches; otherwise it shows "The tab did not open" after 8 s. Always answer `agents.refresh` with a full list, even if unchanged. Agent ids for Code sessions are `cc-<fnv64 of project + "\n" + title>` (they survive Claude re-drawing the list; a rename is carried over by `carryIds`).

## Claude Desktop: the Accessibility contract

Bundle id `com.anthropic.claudefordesktop` (Electron). Set `AXManualAccessibility = true` on the app element so the tree populates. These selectors were verified against the user's install in Oct 2026, **and will break when Claude's UI changes**, so re-verify with Accessibility Inspector or a tree dump first when something stops working.

- **Mode switch** (top of the sidebar): `AXRadioGroup` desc `Mode` with `AXRadioButton`s desc `"Chat and Cowork…"` and `"Code"`; the selected one has `AXValue` 1. The sidebar shows **one** mode's list. `Claude.show(mode)` presses it (only for an explicit open/voice from the puck or menu).
- **Code view sidebar** (dump Oct 2026): per project an `AXGroup` holding `AXButton title=<project>`, `AXButton desc="New session in <project>"`, then a group of session rows built exactly like chat rows (`AXButton title="<status> <title>"`, `AXImage desc=<status>` e.g. `#5 · Merged`, `#9 · Open`, `Idle`, `AXStaticText`). The open conversation's `AXWebArea` is titled `"<title> - Claude Code"` (`ClaudeView.openTitle`). Unverified: the status words while a session works (logged as "Code session status seen"); until confirmed, `Bridge.trustCodeStatus` is false and status never marks a row busy.
- **Sidebar chat row:** an `AXButton` whose title is `"<status> <chat title>"`. Its subtree holds an `AXImage` (description = status, e.g. `Idle`/`Done`) and an `AXStaticText` (value = title). **Chat id = that AXImage's `AXDOMIdentifier`** (e.g. `_r_6oa_`). It's stable across renames within a session but **not across Claude restarts**. Pressing the row button opens the chat.
- **Writing indicator:** a button with description `Stop` exists only while Claude streams in the open chat. `Send` appears only when the composer has text. **"Stop disappeared" means finished OR the user switched chats.**
- **Composer:** `AXTextArea`, description `"Write your prompt to Claude"` (Chat) or `"Prompt"` (Code); matched on "prompt". It's rich text. Setting `AXValue` is unreliable, so focus it and paste with ⌘V via CGEvent, then restore the clipboard.
- **Message action buttons:** `"Show message actions for You said: …"` / `"… Claude responded: …"`. These may only exist on hover, so treat them as a weak signal.
- **Conversation text:** `AXStaticText` elements positioned right of the sidebar's right edge.

**Known limits, all confirmed by testing**
- Sidebar status icons do **not** change while a normal chat generates. Idle/Done applies to tasks (Cowork/Dispatch/scheduled).
- **Background finishes are invisible.** If the user switches away mid-reply, nothing in the UI changes when it completes, and Claude sent no macOS notification while in-app (untested with Claude unfocused, which is worth testing). The bridge only learns the outcome when the user returns to that chat.
- **The puck's busy timer can't be set:** `turn.started` has no start-time field; the puck counts from when a tile goes idle → busy. Never send `turn.done` for a chat that may still be running, or the timer restarts at 0.
- **Claude Code sessions** are read from the Code view's sidebar (above). The bridge keeps `chatRows` and `codeRows` from whenever each list was last on screen (`codeRows` also in UserDefaults `codeRows`, titles only), so the puck has both. Opening or speaking to a row of the other mode switches the mode, waits, finds the row again (by id, else title) and presses it (`pendingOpen` / `deliver`). The old `~/.claude/projects` reader is gone: it missed Cloud sessions.
- **Project chats** are collapsed under project toggles, so only Recents show.

**Finish detection (`Bridge.checkClaude`)**
- `writing` (Stop present) only changes after two reads in a row agree; while it's settling nothing is decided (a switch can briefly show half the old chat).
- **Open chat** = the row whose (unique) title is the web area's title (`openTitle`), else the sidebar chat whose title appears in the conversation area, i.e. its header (`openChatId`). Unverified against every Claude layout; when it's nil the old heuristics apply.
- Writing starts → the writing chat is: the open chat, else a row that appeared within 5 s (new chat from the home screen), else the last chat opened from the puck/menu (≤ 10 min ago), else the top row. It goes into `busy` with a snapshot of the conversation texts, message labels and composer text (the prompt); `turn.started` is re-sent every 10 s for every busy chat.
- Writing stops → if the open chat is still the writing one (or, when unknown, ≥ 50% of the snapshot texts/labels remain, or the row is new) it finished: `turn.done` + `notify` with the new texts minus the prompt. Otherwise the user switched away: the chat **stays busy** (`awaySince`), so the puck's timer keeps counting.
- Coming back to a busy chat: still writing → it just continues; not writing → it finished meanwhile → `turn.done` + a `summary {silent:true}` (no beep, they're looking at it). Background chats are given up after 20 min.
- An empty sidebar read is ignored unless it happens 3 times in a row, to prevent puck flicker.

**Do not** use claude.ai's private web API or session cookies. That's unofficial, against the terms, and could get the account flagged. Stick to Accessibility.

## OpenHarness coexistence

OpenHarness runs a launchd agent `ai.autonomous.harness.harnessd` (KeepAlive) that grabs the port with `O_EXLOCK`. The app stops it via `launchctl bootout gui/$UID/ai.autonomous.harness.harnessd` when the port is busy and `Take the puck from OpenHarness automatically` is on (default). Settings → Advanced → **Lend the Puck to OpenHarness…** releases the port, re-bootstraps it from `~/Library/LaunchAgents/…plist` and turns auto-take off; **Take It Back** reverses that. **When OpenHarness connects, it auto-updates the puck's official firmware.** That matters once we ship custom firmware.

## Conventions

- Single-file Swift, AppKit, no third-party dependencies, macOS 14+. Keep `// MARK:` sections.
- Log with `say()` (stdout + `~/Library/Logs/PuckBridge.log`). Log user-visible events and decisions, never chat contents beyond titles, and never transcripts unless debugging.
- The bridge loop runs on a background thread and owns all bridge state and puck I/O. Other threads (UI, Speech callbacks, `deliverQueue`) hand work to it with `bridge.perform { b in … }`. The bridge reports to the UI with `publish()` → `Snapshot` on the main thread (`AppModel`).
- New user preferences go in `enum Pref` (UserDefaults) and get a control in the Settings window (`@AppStorage` with the same key). Settings that live on the puck are not stored on the Mac.
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
10. Settings → Puck: moving brightness and toggling the beep change the puck, and the values survive unplug/replug.
11. Settings → Character: each built-in shows on the puck; importing a petdex sheet uploads it (log: "Custom character stored"), and it comes back after the puck restarts.
13. Puck Bridge firmware: Settings → Puck → Firmware → Install. The puck restarts on `0.0.88-pb.4`; small-button tap → clock (big time, ring segments per chat); idle 5 min → clock; swipe right on the clock → Settings, left → chats, right from the first chat → clock, swipe up on a chat → chat list; Settings rows change values (and the Mac's Settings follow), Character opens a picker with each pet; the Mac log shows `puck: …` lines; sounds play with Test; hold the small button while Claude writes → stop. Then Restore → official 0.0.88 comes back.
12. Settings tab on the puck (hold the face → TABS → Settings): stop on "Puck character", tap the face twice → next character; tap, say "Jolly", tap → Jolly. Same for beep/brightness/calm.

Good next step: add unit tests for the framing/CRC against the shared vectors in openharness `cli/src/cable/vectors/cable_frame.txt` (all 27 currently pass in a Python port).

## Roadmap

1. **Signing certificate in CI** so permissions survive updates: the owner runs `scripts/make-signing-cert.sh` once (README). This is the user's to-do.
2. **Background-finish alerts:** test whether Claude posts macOS notifications when its window is unfocused. If it does, read Notification Center banners via AX and forward them.
3. **Custom firmware ("Step 6") — started:** clock face, home button, device menu and sounds ship as Puck Bridge firmware (see above). Still open: fork `devices/harness-device/firmware` (ESP-IDF 5.5+, ESP32-S3, 466×466 round AMOLED). Goals:
   - Report button gestures to the host instead of hard-coding them: e.g. `{"t":"button","id":"top|bottom","gesture":"tap|double|hold"}`, advertised via a `hello` capability like `buttons:"events-v1"`. Puck Bridge then maps gestures to actions from the menu (screen on/off, stop Claude, start voice, next/prev chat, open Claude). The top long-press stays a hardware restart.
   - An **idle clock + weather face**: the host sends e.g. `{"t":"ambient","time":<epoch>,"tz":"…","tempF":…,"cond":"…"}` every minute. Weather comes from Open-Meteo (free, no key) using a ZIP or coordinates set in the menu.
   - Release firmware through this repo's pipeline. Back up the full 16 MB flash (`esptool read_flash`) before the first flash. Keep OpenHarness's service off, or it will overwrite the firmware. First check secure boot is off (`esptool get_security_info`; the repo docs say Secure Boot v2 isn't enabled yet).
4. **Settings tab, hardware check:** confirm the touch-touch and spoken flows on a real puck, and what the puck shows after `voice.transcript` for a tile. If the flow is awkward, the custom-firmware button events above are the cleaner fix.
5. **Voice polish:** a review-before-send flow using the puck's draft UI (`voice.end {review:true}` → `voice.draft`). Optional slash-commands.
6. Confirm the Code view's status words while a session works (and the Stop button's label there), from a layout dump taken mid-run.

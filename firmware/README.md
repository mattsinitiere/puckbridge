# Puck Bridge firmware patch

`patches/0001-puck-bridge-firmware.patch` is a patch to the official Autonomous Harness puck firmware
(github.com/autonomous-ai/openharness, `devices/harness-device/firmware`, commit
`ce68e2fac27b8523c145f79d9d22f2ad7e589aad`). Apply it from the openharness repo root with
`git apply firmware/patches/0001-puck-bridge-firmware.patch`, then build with ESP-IDF 5.5 (`idf.py build`).

**Test it without the puck:** `scripts/test-firmware.sh` applies the patch to a clean upstream checkout and runs
`firmware/sim`, a host simulator that compiles the real `ui_habitat.c`, `cable_client.c` and `app_main.c` (FreeRTOS
and ESP-IDF stubbed, single-threaded) and plays scripted touches, buttons and cable messages (`firmware/sim/demo/*.sim`;
commands are listed at the top of `firmware/sim/src/sim.c`). `shot` writes a PNG of the real frame. CI runs it on
every push.

## What it changes

- **Version** `0.0.88-pb.6` (version.txt, which becomes `esp_app_desc.version`). `hello` carries `"pb": 5`
  (pb.1 sent 1, pb.2 and pb.3 sent 2, pb.4 sent 3, pb.5 sent 4).
- **pb.6:** with any of the new list styles, **clock-home navigation**: from the clock, down = the notifications (up
  goes back), up = the settings (down at the top goes back), left = the **Claude Code groups** (a page of the host's
  `code*` tabs; browsing switches nothing), left again = the chats; a tapped group (or the chats) is switched to with
  the tab handshake and opens on its **list** (not the face); a tapped row opens its face; right goes back everywhere
  (face → list → groups → clock). Every list scrolls up and down (the dial too). Agents may carry `status` (≤ 23
  bytes, e.g. "PR #9 merged") and `tone` (`merged` purple, `open` green, `closed` red, `draft`/`idle` grey), shown on
  rows that aren't working or unread. **Settings as cards** (name left, value right with "›", On/Off rows as
  switches; "Swipe down to close"). **Light theme** (`pb.ui {theme:"light"}`): every colour goes through `ht_rgb`,
  which flips greys and darkens colours for a white ground (the pets keep theirs). Up to **12** settings rows. The
  boot wordmark says "Puck Bridge". Classic keeps pb.4's side pages and pages.
- **pb.5:** list styles for the panes list and the tabs (`pb.ui`, below): **cards** (a column of cards, scrolled up
  and down, the middle one large with a green rim), **dial** (the clock's ring with a segment per row, the chosen one
  long, its name large in the middle; turned sideways), **compact** (five rows under a fixed green band, scrolled up
  and down) or **classic** (the official pages). Every row says what it's doing (orange "Working · 1:23", white "Reply
  ready", "Idle"; a tab: "3 sessions · 1 working"). In the new styles browsing switches nothing: a tap on a row opens
  it, a tap on a tab switches to it (the two-tab cards are classic-only). Tabs may carry `working`.
- **pb.4:** timers (below), sound previews in pickers, a tab switch screen of cards (one per tab: name, how many
  chats or sessions, "· N working"; tap to switch, tap the current card or swipe sideways to go back), Code panes show
  their project small under the name, tips that match side pages ("Tap to talk", "Hold for tabs", "Swipe up for all
  chats", "Swipe right for the clock"; never "Choose a pane"), a "Puck Bridge" connecting screen, message and
  stop screens with pills and the release rule (a tap anywhere closes a message), and the panes list headed with the
  tab's name.
- **Side pages** (once a Puck Bridge host has sent `ambient`, `pb.menu` or `pb.sound` on this connection; off again on
  disconnect): `Settings ← Clock → pane 1 → pane 2 → …`. On the face, swiping right from the first pane goes to the
  clock, and nothing wraps. On the clock, swipe left → the pane on the face (or the first), swipe right → Settings,
  tap → back to the face. On Settings, swipe left → clock. Page dots on the clock and Settings (settings, clock, up to
  5 panes, "+" for more). Swipe up on the face → the list of panes. While a Puck Bridge host is connected the face
  reports no desktop scroll (`ui_scroll_reportable()` is false), which frees vertical swipes; an official daemon keeps
  scroll, wrap-around and everything else as before.
- **Clock face (CLOCK view):** the time in 112 px Inter SemiBold with tabular digits (`pb_time`, 13 glyphs), am/pm
  beside it, the date above in spaced capitals (`pb_caps`), the weather below, the pane's pet standing still, and a
  ring at the edge with one segment per pane of the current tab (up to 12): orange = working, white = finished with
  an unread notice, dim = idle; no panes = one dim ring. Every string comes from the host. Before any `ambient` the
  time is a dim `--:--`. Letters the fonts lack are dropped. Text, dots and ring move a couple of pixels (and the ring
  ±2°) each minute against AMOLED burn-in. The clock decides on release: a tap goes back to the face, a sideways swipe
  pages.
- **Small (BOOT) button.** A **tap** cancels live voice, then: picker → its list, anywhere else → the clock. A
  **hold** (800 ms or more) opens the "stop this turn?" screen when the pane on the face is busy (on the clock: that
  pane, or the only pane working), and otherwise turns
  the screen on or off as before. A press still wakes a dark screen. Factory reset (BOOT held at power-on) is unchanged.
- **A fresh connection starts on the clock** (pb.3, made robust in pb.4): the first `ambient` chooses the first pane
  when none is chosen and shows the clock unless the face is in use; a list that lands later keeps the clock up, and a
  `focus` with `"keepClock": true` chooses the pane without leaving the clock. Every ordering of welcome, list,
  focus, `pb.sound` and `ambient` ends on the clock (`firmware/sim/demo/startup_orders.sim`).
- **Idle becomes the clock.** After `idleMin` minutes (default 5) with nothing going on, the agent face becomes the
  clock. "Nothing going on" means no touch, no voice, connected, and the face showing (not a list, question, draft,
  form, message, stop or update screen); a pane that is working doesn't hold it off (pb.3), since the ring shows it.
  A turn that starts leaves the clock up and turns its ring segment orange (pb.3; pb.2 went back to the face). A
  finished turn that rings, or a host `focus`, leaves the clock.
- **Screen sleep.** The firmware normally turns the panel off after 5 minutes without a touch. While the clock is up
  it stays on. If the idle timer had already turned the panel off when the clock takes over, the panel comes back on.
  The PWR tap and the BOOT hold still turn it off.
- **Settings (PBMENU view):** the rows the Mac sends, four at a time, label over value; rows with choices show " ›".
  A row press counts when the finger lifts inside the row it pressed within 1.8 s, having moved less than 48 px
  sideways and 40 px down, and the list didn't scroll (the strict tap classifier missed many real presses on this
  glass). A new `pb.menu` only cancels a held press when a different row is now under the finger.
- **Picker (PICKER view):** a row with `choices` opens a page of them: the label as header, `<` back, the candidate
  large in the middle (its pet animated in its idle loop, or its value as text), the neighbours small at the sides,
  dots, and a **Choose** pill; the host's current value is green. Swipe or tap a neighbour to move. `builtin:true`
  draws the firmware's own pet even when a custom pack is mapped to that engine.
- **Notification sounds.** `chime` (the original sound, unchanged sample for sample), `soft`, `bell`, `digital`, with
  a volume setting. Style and volume are kept in RAM only.
- **Logging:** `ESP_LOGI` lines for every clock, menu, picker and face swipe decision (with touch coordinates), which
  Puck Bridge writes to its log as `puck: …`.
- Cost (estimated, x86 object sizes): ~33.5 KB flash for the two fonts, ~8 KB code, ~8.5 KB PSRAM for the choice
  tables, ~70 B internal RAM.

## Protocol (only send these when `hello.pb >= 1`)

Host → puck:

```
{"t":"ambient","time":"3:44","ampm":"PM","date":"Tuesday, Oct 13","temp":"68°","cond":"Partly cloudy","hilo":"H 75°  L 58°","idleMin":5}
```
All strings are pre-formatted, and any of them may be `""` or absent. `ampm` is `""` in 24-hour mode. `idleMin` is
0 to 720, where 0 means never switch automatically and absent keeps the last value. Send it right after `welcome`
and then every minute. Limits: time 15 bytes, ampm 7, date 47, temp 15, cond 47, hilo 31 (longer values are cut at a
whole letter).

```
{"t":"pb.menu","title":"Settings","items":[{"id":"character","label":"Character","value":"Clawd"}, ...]}
```
Up to 10 items. id, label and value are each at most 23 bytes, and longer values are cut at a whole letter. Rows
without an id are dropped. This replaces the whole list. If it arrives while the menu is open, the menu redraws.

From pb 2 a row can also carry its choices, shown on a picker page:
```
{"id":"character","label":"Character","value":"Clawd","index":0,
 "choices":[{"value":"Clawd","pet":"claude","builtin":true},{"value":"Codex Bot","pet":"codex","builtin":true},{"value":"Mochi"}]}
```
Up to 16 choices per row (extras ignored); `value` ≤ 23 bytes (choices without one are dropped), `pet` ≤ 15 bytes (an
engine name; unknown or absent → the value as text), `index` absent or out of range → the first. The whole frame must
stay within the cable's JSON guard: **≤ 512 tokens** (and 8192 bytes), counted as 7 + per row 7 (+2 with `index`,
+2 + 3 per choice, +2 per `pet`, +2 per `builtin`). Over that the frame is dropped and the old list stays, so leave out
`builtin` when false and `pet` when there is none. Puck Bridge's menu is about 250 tokens.

```
{"t":"pb.sound","style":"chime","volume":70,"test":false}
```
`style` is one of `chime`, `soft`, `bell` or `digital`. An unknown style means `chime`, and an absent one keeps the
current style. `volume` is 0 to 100 and scales the samples on a square law (70 is about -6 dB, 0 is silent). Absent
keeps the current volume. `test:true` plays the sound once now, even when `muted` is on, but never while the
microphone is open. Send it after every `welcome`. The official `muted` setting works as before.

Puck → host:

- `{"t":"pb.menu.open"}` when the Settings page opens.
- `{"t":"pb.timer.state","seconds":S}` (pb 3) on every timer start, replace or cancel (0), once a minute while
  running, and 0 at the end; `{"t":"pb.timer.done","reason":"stopped"|"timeout"}` when the ringing stops (a touch,
  the small button, a hold; or 60 s of ringing).

From pb 3, host → puck also:
```
{"t":"pb.timer","seconds":300,"label":"5 min timer"}
```
0–86400 s, 0 cancels, `label` ≤ 23 bytes. A new one replaces a running timer (and silences a ringing one without
`pb.timer.done`). The puck counts down on its own clock (a sleeping Mac or a disconnect doesn't stop it). The clock
shows "Timer 4:59" in orange in place of the weather; at zero the TIMER screen ("Time's up", the label, 0:00, the
ring blinking, a Stop pill) wakes the panel and plays the current sound every 2 s (silent when `muted`, never while
the microphone is open) for up to 60 s.

From pb 4 (firmware pb.5), host → puck also:
```
{"t":"pb.ui","lists":"cards"}
```
`lists` is `cards`, `dial`, `compact` or `classic` (anything else is classic, and so is a puck that never got one).
From pb 5 (firmware pb.6) `pb.ui` may also carry `"theme":"dark"|"light"` (absent: unchanged; the puck starts dark).
In RAM: send it after every `welcome`. `swarms` items may carry `"working":N` (the tab's working chats); a tab that
isn't on the face shows it. New counts with the same ids and names don't disturb a swipe, so the host re-sends
`swarms` when they change.

`focus` may carry `"keepClock": true`; `agent` may carry `"project"` (≤ 39 bytes, shown small on Code panes).
Picker choices may carry `"sound":"chime|soft|bell|digital"` and/or `"volume":0-100`: when the picker rests on one
for ~300 ms it plays that sound once (even when muted; never while the microphone is open). Each such key costs 2
tokens in the 512-token budget. A row whose choices are actions (the Timer row) sends no `index`.
Host-initiated tab switch: `swarms` with the new `selected`, then that tab's `agents.begin` / `agent`… /
`agents.end {tab}`, then `focus {agentId, keepClock:true}`. Answer it with `pb.menu`. The puck shows
  "Loading…" and gives up after 5 s ("No answer from the Mac.").
- `{"t":"pb.menu.tap","id":"<id>"}` when a row without choices is tapped. Answer with an updated `pb.menu`.
- `{"t":"pb.menu.set","id":"<id>","index":N,"value":"<choice value>"}` (pb 2) when a choice is made on a picker page.
  The puck goes back to the list; answer with an updated `pb.menu`.
- `pb.menu.open` is sent when the Settings page opens (a swipe right from the clock).

## How it degrades

- **Official daemon (OpenHarness):** it ignores `hello.pb` and never sends the new messages, so the clock shows
  `--:--`, there is no idle clock, and the menu says "No answer from the Mac." A BOOT tap shows the clock, and a touch
  goes back to the face.
- **Older Puck Bridge talking to this firmware:** same as above.
- **This Puck Bridge talking to official firmware:** the firmware does not send `pb`, so the host must not send
  these messages. If it does, the official firmware counts them as unknown and ignores them.
- **Unplugging:** the clock text is cleared and the clock and menu go back to the face. The next connection refills
  them.

## Restoring official firmware

- Let OpenHarness connect (Puck Bridge → Settings → Advanced → Lend the Puck to OpenHarness…). Its daemon updates the
  puck to the official firmware, because `0.0.88-pb.4` is not the published version.
- Or flash the official image with the repo's `flash-circle.sh --version <x.y.z>`, or write back a full-flash backup
  with `esptool write_flash 0 backup.bin`.
- If the firmware will not boot, hold BOOT while plugging in to enter ROM download mode, then flash.

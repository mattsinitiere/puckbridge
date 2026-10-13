# Puck Bridge firmware patch

`patches/0001-puck-bridge-clock-and-home.patch` is a small patch to the official Autonomous Harness puck firmware
(github.com/autonomous-ai/openharness, `devices/harness-device/firmware`, commit
`ce68e2fac27b8523c145f79d9d22f2ad7e589aad`). Apply it from the openharness repo root with
`git apply firmware/patches/0001-puck-bridge-clock-and-home.patch`, then build with ESP-IDF 5.5 (`idf.py build`).

## What it changes

- **Version** `0.0.88-pb.1` (version.txt, which becomes `esp_app_desc.version`). `hello` carries `"pb": 1`.
- **Clock face (new CLOCK view).** The time in Inter 44, am/pm beside it, the date, the weather and high/low,
  the current pane's pet standing still, and a `[ settings ]` control. Every string comes from the host. Before
  any `ambient` it shows a dim `--:--`. Letters the font lacks (emoji, for example) are dropped. `°` is drawn.
  The text moves a couple of pixels each minute to protect the AMOLED from burn-in.
- **Small (BOOT) button.** A **tap** (released before 800 ms) cancels live voice, then shows the clock. A **hold**
  (800 ms or more) opens the existing "stop this turn?" screen when the pane on the face is busy, and otherwise turns
  the screen on or off as before. A press still wakes a dark screen. Factory reset (BOOT held at power-on) is unchanged.
- **Idle becomes the clock.** After `idleMin` minutes (default 5) with nothing going on, the agent face becomes the
  clock. "Nothing going on" means no touch, no busy pane, no voice, connected, and the face showing (not a list,
  question, draft, form, message, stop or update screen). Any touch on the clock goes back to the agent face, and that
  touch does nothing else. A turn starting, a finished turn that rings, or a host `focus` also leave the clock.
- **Screen sleep.** The firmware normally turns the panel off after 5 minutes without a touch. While the clock is up
  it stays on. If the idle timer had already turned the panel off when the clock takes over, the panel comes back on.
  The PWR tap and the BOOT hold still turn it off.
- **Settings menu (new PBMENU view).** The Mac sends the rows and the puck shows them. Small button goes back to the clock.
- **Notification sounds.** `chime` (the original sound, unchanged sample for sample), `soft`, `bell`, `digital`, with
  a volume setting. Style and volume are kept in RAM only.

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

```
{"t":"pb.sound","style":"chime","volume":70,"test":false}
```
`style` is one of `chime`, `soft`, `bell` or `digital`. An unknown style means `chime`, and an absent one keeps the
current style. `volume` is 0 to 100 and scales the samples on a square law (70 is about -6 dB, 0 is silent). Absent
keeps the current volume. `test:true` plays the sound once now, even when `muted` is on, but never while the
microphone is open. Send it after every `welcome`. The official `muted` setting works as before.

Puck → host:

- `{"t":"pb.menu.open"}` when the clock's `[ settings ]` control is tapped. Answer it with `pb.menu`. The puck shows
  "Loading…" and gives up after 5 s ("No answer from the Mac.").
- `{"t":"pb.menu.tap","id":"<id>"}` when a row is tapped. Answer with an updated `pb.menu`.

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
  puck to the official firmware, because `0.0.88-pb.1` is not the published version.
- Or flash the official image with the repo's `flash-circle.sh --version <x.y.z>`, or write back a full-flash backup
  with `esptool write_flash 0 backup.bin`.
- If the firmware will not boot, hold BOOT while plugging in to enter ROM download mode, then flash.

# Puck Bridge

Menu-bar app that connects the **Autonomous Harness puck** to **Claude Desktop** — no OpenHarness needed.

- Your recent Claude chats appear on the puck. Pause on one → Claude opens it.
- Claude finishes a reply → the puck beeps and shows the start of the reply.
- Tap-and-speak on the puck → transcribed on your Mac → typed into the chat and sent.
- Small (bottom) button while Claude is writing → stop Claude.
- Pick the little character on the puck (Clawd, Codex Bot, Jolly, Fo), or import your own petdex sprite sheet.
- Change the puck's brightness, beep and more from ◎ → **Settings…**, or from the puck's **Settings** tab (hold the puck's face to switch tabs).
- Updates itself from this repo's Releases.

## Install on a Mac
```bash
curl -fsSL https://raw.githubusercontent.com/mattsinitiere/puckbridge/main/scripts/install.sh | bash
```
Then approve **Accessibility** and **Speech Recognition** for *Puck Bridge* (◎ → **Settings…** → General shows what's missing), and turn on **Start Puck Bridge when you log in** there.

## Update
◎ menu → **Check for updates…** (it also checks daily). Or re-run the install line.

## Make a release
1. Bump `CHANGELOG.md`.
2. GitHub → **Releases → Draft a new release** → new tag like `v0.3.1` → **Publish**.
3. The *Release* workflow builds the app and attaches `PuckBridge.zip` (~3 min).

## Keep macOS permissions across updates (recommended, one-time)
Without this, every update is signed differently and macOS asks for Accessibility and Speech Recognition again.
1. Open **Terminal** and paste:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/mattsinitiere/puckbridge/main/scripts/make-signing-cert.sh | bash
   ```
2. It makes a private signing certificate and opens GitHub twice. Each time, paste the name it shows and press ⌘V for the secret, then **Add secret**.
3. Install the next build (a new release, or ◎ → Check for Updates…). macOS asks for permissions **one last time**, then keeps them for every later update.

◎ → Settings… → General → **Signature** shows *Signed as Puck Bridge Signing* once this is working.

## Buttons (current official firmware)
| Button | Tap | Hold |
|---|---|---|
| Large (top) | screen on/off | hardware restart |
| Small (bottom) | back · stop Claude when writing · cancel voice | screen on/off |

The small button is the chip's BOOT button: hold it while plugging in to force flashing mode (recovery).

## Develop
```bash
scripts/dev-install.sh          # build this checkout and install it locally
tail -f ~/Library/Logs/PuckBridge.log
```

## Troubleshooting
- **"held by OpenHarness"** — the app stops OpenHarness's service automatically; to give the puck back use ◎ → Settings… → Advanced → *Lend the Puck to OpenHarness…* (and *Take It Back* later).
- **No beep when Claude finishes** — new pucks ship with the beep off: ◎ → *Beep When Claude Finishes*.
- **Chats stopped appearing after an update** — System Settings → Privacy & Security → Accessibility → toggle Puck Bridge off/on (or set up the signing certificate above).

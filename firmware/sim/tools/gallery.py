"""Write demo/gallery_dark.sim and demo/gallery_light.sim: one walk through every puck screen (Puck Bridge firmware,
Cards style), a `shot` of each into out/gallery/<theme>_NN_<screen>.png. Then:

    python3 firmware/sim/tools/gallery.py && scripts/test-firmware.sh      # or run the two .sim files directly
    python3 firmware/sim/tools/gallery.py --sheets                          # contact sheets: out/gallery/sheet_*.png
"""
import sys
from pathlib import Path

sim = Path(__file__).resolve().parents[1]
TOUR = r'''
log 1
autoping 1
echo === before the Mac: the waiting screen
time +300
SHOT waiting_for_mac
include demo/lib/welcome.sim
SHOT loading_chats
include demo/lib/lists_data.sim
in {"t":"swarms","selected":"chats","items":[{"id":"chats","name":"Chats","agents":5,"panes":5,"working":1},{"id":"now","name":"Active","agents":2,"panes":2,"working":1},{"id":"code-a1","name":"puckbridge","agents":3,"panes":3,"working":1},{"id":"code-b2","name":"openharness","agents":1,"panes":1,"working":0},{"id":"code-c3","name":"website","agents":2,"panes":2,"working":0}],"tiles":[]}
include demo/lib/pbhost.sim
in {"t":"pb.ui","lists":"cards"THEME}
in {"t":"turn.started","agentId":"c2","text":"Writing…","elapsed":95}
time +300
echo === the clock (home), with its swipe hints the first times
boot tap
time +600
SHOT clock_hints
time +4500
SHOT clock
echo === the clock's line: a finished chat, the Mac's warning, a timer, the next alarm
in {"t":"summary","agentId":"c3","name":"Grocery list","engine":"claude","machine":"Mac Studio","recap":"Added oat milk and eggs to the list.","text":"Added oat milk and eggs to the list."}
time +300
SHOT clock_chat_ready
time +13000
in {"t":"pb.status","text":"Allow Accessibility on your Mac"}
time +200
SHOT clock_mac_warning
in {"t":"pb.status","text":""}
in {"t":"pb.timer","seconds":1500,"label":"Focus"}
time +1200
SHOT clock_timer
in {"t":"pb.timer","seconds":0}
in {"t":"pb.alarm","id":"a1","in":3600,"label":"Stand-up"}
time +200
SHOT clock_next_alarm
in {"t":"pb.alarm","id":"a1","in":0}
echo === down: notifications
in {"t":"summary","agentId":"c4","name":"Kitchen remodel budget and contractor questions","engine":"claude","machine":"Mac Studio","recap":"The three quotes come to $18,400 on average; the tile work is the biggest difference.","text":"The three quotes come to $18,400 on average; the tile work is the biggest difference."}
time +300
boot tap
time +300
swipe 233 140 233 330 250
time +300
SHOT notifications
swipe 233 330 233 140 250
time +300
echo === up: settings, a picker
swipe 233 330 233 140 250
time +200
include demo/lib/menu_pb5.sim
time +300
SHOT settings
swipe 233 330 233 150 400
time +300
SHOT settings_more
swipe 233 150 233 330 400
time +300
tap 233 208 120
time +300
SHOT picker_character
boot tap
time +200
tap 233 272 120
time +300
SHOT picker_sound
boot tap
time +200
boot tap
time +300
echo === left: the Claude Code groups (Active first), a group's sessions, the chats
swipe 330 233 120 233 250
time +300
SHOT groups
in {"t":"pb.ui","lists":"dial"}
time +100
SHOT groups_dial_style
in {"t":"pb.ui","lists":"compact"}
time +100
SHOT groups_compact_style
in {"t":"pb.ui","lists":"cards"}
time +100
swipe 233 280 233 196 400
time +700
tap 233 184 120
time +200
in {"t":"swarms","selected":"code-a1","items":[{"id":"chats","name":"Chats","agents":5,"panes":5,"working":1},{"id":"now","name":"Active","agents":2,"panes":2,"working":1},{"id":"code-a1","name":"puckbridge","agents":3,"panes":3,"working":1},{"id":"code-b2","name":"openharness","agents":1,"panes":1,"working":0},{"id":"code-c3","name":"website","agents":2,"panes":2,"working":0}],"tiles":[]}
time +100
in {"t":"agents.begin"}
in {"t":"agent","id":"cc-1","name":"Puck tabs per project","project":"puckbridge","status":"PR #12 open","tone":"open","engine":"claude","model":"","effort":"","machineId":"mac-1","machine":"Mac Studio"}
in {"t":"agent","id":"cc-2","name":"Fix the release build","project":"puckbridge","status":"PR #9 merged","tone":"merged","engine":"claude","model":"","effort":"","machineId":"mac-1","machine":"Mac Studio"}
in {"t":"agent","id":"cc-3","name":"App icon","project":"puckbridge","status":"PR #7 closed","tone":"closed","engine":"claude","model":"","effort":"","machineId":"mac-1","machine":"Mac Studio"}
in {"t":"agents.end","total":3,"tab":"code-a1"}
in {"t":"turn.started","agentId":"cc-1","text":"Running a command…","elapsed":312}
in {"t":"focus","agentId":"cc-1","keepClock":true}
time +400
SHOT group_sessions
in {"t":"pb.ui","lists":"compact"}
time +100
SHOT group_sessions_compact_style
in {"t":"pb.ui","lists":"dial"}
time +100
SHOT group_sessions_dial_style
in {"t":"pb.ui","lists":"cards"}
time +100
echo === a session's face: working, then finished
tap 233 184 120
time +500
SHOT face_working
in {"t":"turn.done","agentId":"cc-1"}
in {"t":"summary","agentId":"cc-1","name":"Puck tabs per project","engine":"claude","machine":"Mac Studio","recap":"Done: one tab per project, folded ones included. Tests pass.","text":"Done: one tab per project, folded ones included. Tests pass."}
time +600
SHOT face_finished
in {"t":"notif.replace","items":[]}
time +6000
SHOT face_resting
echo === voice: hold to talk (the ring fills), release; tap to talk; sending; the answer
touch down 233 233
time +650
SHOT voice_hold
time +600
SHOT voice_release_to_send
touch move 233 330
touch move 233 400
touch up 233 400
time +1500
tap 233 233 80
time +700
SHOT voice_tap_to_send
tap 233 233 80
time +300
SHOT voice_sending
time +70000
SHOT voice_no_answer
tap 233 233 80
time +300
echo === stop: the confirmation, then too late
in {"t":"turn.started","agentId":"cc-1","text":"Writing…"}
time +200
SHOT face_stop_tip
boot hold
time +200
SHOT stop_confirm
in {"t":"turn.done","agentId":"cc-1"}
tap 316 334 100
time +200
SHOT stop_already_finished
tap 233 233 80
time +200
echo === a message from the Mac
in {"t":"toast","text":"Added to your draft in Claude. Not sent."}
time +200
SHOT message
tap 233 233 80
time +200
echo === timers: the dial, a running timer, time's up
boot tap
time +300
tap 233 262 120
time +200
SHOT timer_dial
tap 233 108 100
time +300
tap 233 262 120
time +1200
SHOT timer_running
tap 316 346 120
time +200
in {"t":"pb.timer","seconds":2,"label":"Tea"}
time +3000
SHOT timer_done
tap 233 233 80
time +200
echo === alarms: ringing, missed
in {"t":"pb.alarm","id":"a2","in":2,"label":"Stand-up"}
time +3000
SHOT alarm_ringing
time +62000
boot tap
time +300
SHOT clock_missed_alarm
tap 233 233 80
time +200
boot tap
time +300
echo === the Mac goes away: the clock keeps time
include demo/lib/drop.sim
time +60000
SHOT clock_without_mac
'''
NAMES = []
def write(theme):
    n = 0
    out = []
    for line in TOUR.strip("\n").split("\n"):
        if line.startswith("SHOT "):
            n += 1
            name = line[5:].strip()
            if theme == "dark": NAMES.append(name)
            out.append(f"shot out/gallery/{theme}_{n:02d}_{name}.png")
        else:
            out.append(line.replace("THEME", ',"theme":"light"' if theme == "light" else ""))
    head = (f"# GENERATED by firmware/sim/tools/gallery.py ({theme}): every puck screen, one shot each, into out/gallery.\n"
            "# Edit the tour there, not here.\n")
    (sim / f"demo/gallery_{theme}.sim").write_text(head + "\n".join(out) + "\n")

def sheets():
    from PIL import Image, ImageDraw, ImageFont
    g = sim / "out/gallery"
    font = ImageFont.load_default()
    try: font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 16)
    except OSError: pass
    for theme in ("dark", "light"):
        files = sorted(g.glob(f"{theme}_[0-9][0-9]_*.png"))
        cols, S, pad, lab = 4, 280, 14, 26
        per = 12
        for k in range(0, len(files), per):
            chunk = files[k:k + per]
            rows = (len(chunk) + cols - 1) // cols
            im = Image.new("RGB", (cols * (S + pad) + pad, rows * (S + lab + pad) + pad), (40, 40, 46))
            d = ImageDraw.Draw(im)
            for i, f in enumerate(chunk):
                x, y = pad + (i % cols) * (S + pad), pad + (i // cols) * (S + lab + pad)
                im.paste(Image.open(f).convert("RGB").resize((S, S)), (x, y))
                d.text((x, y + S + 4), f.stem.split("_", 2)[1] + "  " + f.stem.split("_", 2)[2].replace("_", " "),
                       fill=(200, 200, 200), font=font)
            im.save(g / f"sheet_{theme}_{k // per + 1}.png")

if "--sheets" in sys.argv: sheets()
else:
    write("dark"); write("light")
    print(f"wrote demo/gallery_dark.sim, demo/gallery_light.sim ({len(NAMES)} screens each)")

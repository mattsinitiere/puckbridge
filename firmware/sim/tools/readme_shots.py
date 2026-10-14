"""Round PNGs of the puck's screens for README.md, cut from the simulator's renders.

    scripts/test-firmware.sh          # writes firmware/sim/out/renders/*.png (demo/nav.sim, nav_light.sim, ...)
    python3 firmware/sim/tools/readme_shots.py

Writes docs/screenshots/<theme>-<screen>.png (transparent outside the glass, 300 px). Needs Pillow.
"""
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[3]
renders = root / 'firmware/sim/out/renders'
out = root / 'docs/screenshots'
SHOTS = {   # README name: the render it comes from (nav.sim; nav_light.sim adds "light_")
    'clock': 'nav_01_clock', 'notifications': 'nav_02_notifications', 'settings': 'nav_03_settings',
    'groups': 'nav_04_groups', 'sessions': 'nav_07_group_sessions', 'face': 'nav_08_session_face',
    'chats': 'nav_09_chats', 'dial': 'nav_10_groups_dial', 'compact': 'nav_11_groups_compact', 'boot': 'nav_00_boot',   # dark only: the theme arrives after the Mac's welcome
}
SIZE = 300

def cut(src: Path, dst: Path):
    im = Image.open(src).convert('RGBA')
    w = im.width
    big = w * 4
    mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, big - 1, big - 1), fill=255)
    im.putalpha(mask.resize((w, w), Image.LANCZOS))
    im.resize((SIZE, SIZE), Image.LANCZOS).save(dst, optimize=True)

out.mkdir(parents=True, exist_ok=True)
for theme, prefix in (('dark', ''), ('light', 'light_')):
    for name, render in SHOTS.items():
        src = renders / f'{prefix}{render}.png'
        if src.exists():
            cut(src, out / f'{theme}-{name}.png')
        else:
            print(f'missing {src.name}')
print(f'wrote {out}')

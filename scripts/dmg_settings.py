# dmgbuild settings for the Puck Bridge installer window: the app on the left, an arrow, Applications on the right.
# Used by scripts/make-dmg.sh (dmgbuild -s scripts/dmg_settings.py -D app=... -D background=... -D icon=...).
import os.path

app = defines["app"]            # noqa: F821  (dmgbuild provides `defines`)
appname = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")      # noqa: F821  the volume's icon in Finder
background = defines["background"]  # noqa: F821  600x400 points, 1x + 2x in one TIFF

window_rect = ((200, 140), (600, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
# Centres in window points; the background's arrow sits between them at y = 190.
icon_locations = {appname: (150, 190), "Applications": (450, 190)}
hide_extension = [appname]

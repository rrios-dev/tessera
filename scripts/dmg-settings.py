# dmgbuild settings for Tessera's installer window: the app on the left, a link to
# /Applications on the right, the branded background behind. Paths arrive as -D defines.
# usage: dmgbuild -s scripts/dmg-settings.py -D app=… -D background=… -D icon=… Tessera out.dmg
import os.path

app = defines["app"]  # noqa: F821 — injected by dmgbuild
app_name = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821 — the volume's icon
background = defines["background"]  # noqa: F821 — multi-resolution TIFF, 660 × 420 pt

format = "UDZO"
filesystem = "APFS"  # HFS+ images hit a mounting bug on macOS 26

# Centres must match the arrow and the label chips in assets/dmg/background.svg.
icon_locations = {app_name: (170, 214), "Applications": (490, 214)}
icon_size = 112
text_size = 13
label_pos = "bottom"

# The window adds its title bar (~28 pt) to the 660 × 420 picture.
window_rect = ((200, 140), (660, 448))
default_view = "icon-view"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None

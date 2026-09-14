# dmgbuild settings for the Claude Switcher disk image (drag-to-Applications window).
# Invoked by `make dmg`:  dmgbuild -s scripts/dmg-settings.py -D stage=dist/dmg -D background=... -D icon=... "Claude Switcher" out.dmg
# Geometry must match scripts/make-dmg-bg.swift.
import os

stage = defines["stage"]
files = [os.path.join(stage, f) for f in sorted(os.listdir(stage))]
symlinks = {"Applications": "/Applications"}

background = defines["background"]
icon = defines.get("icon")

format = "UDZO"
window_rect = ((200, 120), (640, 460))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

icon_size = 112
text_size = 12
arrange_by = None
icon_locations = {
    "ClaudeSwitcher.app": (160, 170),
    "Applications": (480, 170),
    "DOC TRUOC KHI MO - README.txt": (160, 372),
    "Uninstall.command": (480, 372),
}

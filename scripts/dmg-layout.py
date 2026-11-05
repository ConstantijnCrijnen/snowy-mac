"""Write and inspect the Finder presentation on an owned disk image."""
import sys
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias

WINDOW = "{{140, 130}, {660, 440}}"
POSITIONS = {"Snowy.app": (185, 240), "Applications": (475, 240)}


def write_layout(volume, background):
    alias = Alias.for_file(str(background))
    # Preserve volume identity and file IDs, without recording the build path.
    alias.volume.posix_path = "/Volumes/Snowy"
    with DSStore.open(str(volume / ".DS_Store"), "w+") as layout:
        layout["."]["vSrn"] = ("long", 1)
        layout["."]["icvl"] = ("type", b"icnv")
        layout["."]["bwsp"] = {
            "WindowBounds": WINDOW,
            "ShowStatusBar": False,
            "ShowToolbar": False,
            "ShowSidebar": False,
            "ShowPathbar": False,
            "ShowTabView": False,
            "ContainerShowSidebar": False,
            "PreviewPaneVisibility": False,
        }
        layout["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "backgroundType": 2,
            "backgroundImageAlias": alias.to_bytes(),
            "arrangeBy": "none",
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "gridSpacing": 100.0,
            "scrollPositionX": 0.0,
            "scrollPositionY": 0.0,
            "iconSize": 112.0,
            "textSize": 14.0,
            "labelOnBottom": True,
            "showIconPreview": False,
            "showItemInfo": False,
        }
        for name, position in POSITIONS.items():
            layout[name]["Iloc"] = position


def verify_layout(volume, background):
    with DSStore.open(str(volume / ".DS_Store"), "r") as layout:
        assert layout["."]["icvl"] == (b"type", b"icnv")
        assert layout["."]["bwsp"]["WindowBounds"] == WINDOW
        options = layout["."]["icvp"]
        assert options["backgroundType"] == 2
        assert options["arrangeBy"] == "none"
        alias = Alias.from_bytes(options["backgroundImageAlias"])
        actual = Alias.for_file(str(background))
        assert alias.target.cnid == actual.target.cnid
        assert alias.volume.name == "Snowy"
        assert alias.volume.posix_path == "/Volumes/Snowy"
        assert alias.target.posix_path == "/.background/Snowy.tiff"
        for name, position in POSITIONS.items():
            assert tuple(layout[name]["Iloc"]) == position
    print("Verified Finder window, background alias and icon positions.")


mode, mount = sys.argv[1:]
volume = Path(mount).resolve(strict=True)
if volume.name != "mount" or not volume.parent.name.startswith(".Snowy-package.") or not volume.is_mount():
    raise SystemExit("Use the mounted image owned by package-release.sh.")
background = volume / ".background" / "Snowy.tiff"
if not background.is_file():
    raise SystemExit("Missing Finder background.")
if mode == "write":
    write_layout(volume, background)
elif mode == "verify":
    verify_layout(volume, background)
else:
    raise SystemExit("Expected write or verify.")

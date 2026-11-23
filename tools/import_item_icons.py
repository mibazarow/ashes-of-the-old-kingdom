#!/usr/bin/env python3
"""Slice the 16x16 item icons the inventory draws, from the local CC0 pack.

Source: assets/assets4/ninja_adventure_asset_pack.zip (Pixel-Boy / Sparklin Labs,
CC0 1.0). The archive is read straight out of the ZIP — nothing is downloaded,
nothing is extracted into the repository, and the pack itself is never copied.
One output per item id in data/items.json: assets/sprites/icon_<item_id>.png,
always exactly 16x16 RGBA.

Every source cell and the reason it was chosen is in SOURCES below, and the same
table is mirrored in docs/ASSET_CREDITS.md. The pack has no fang, no tusk and no
horn anywhere in it (measured: zero PNG names under Items/ or Ui/ contain fang,
tusk, tooth, horn, skull or ivory), so three of the fourteen icons are the
closest shape the pack does have and are flagged `approx` in the report; nothing
was drawn by hand to paper over the gap.

Fitting is one rule for every icon, so the set stays consistent:

  1. crop the source to its alpha bounding box (the pack's items are drawn small
     inside larger canvases — LifePot is 9x11, the sword 6x17, the skill icons
     24x24 with a rounded frame);
  2. if the box already fits in 16x16 it is pasted at native size, centred with
     floor offsets — no resampling at all, so a 9x11 flask keeps every pixel;
  3. otherwise the box is nearest-neighbour rescaled so its longest side becomes
     16, aspect preserved, and centred. Nearest-neighbour only: no blur, no
     anti-aliasing, integer arithmetic.

The script is deterministic and idempotent: the same pack bytes always produce
the same PNG bytes, and re-running overwrites each output with identical bytes.
The PNG codec is the one already used by tools/import_ninja_sprites.py, so both
importers agree on what a pixel is and neither needs Pillow (it is used when
installed, exactly like the sibling script).

Run from the project root:

    python3 tools/import_item_icons.py            # write the icons
    python3 tools/import_item_icons.py --check    # verify, write nothing
"""
import argparse
import os
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import import_ninja_sprites as ninja  # noqa: E402  (same directory, same codec)

DEFAULT_PACK = "assets/assets4/ninja_adventure_asset_pack.zip"
DEFAULT_OUT = "assets/sprites"
PACK_ROOT = "Ninja Adventure - Asset Pack/"
ICON_SIZE = 16

## item_id -> (member inside the pack, exact or approximation, why).
##
## `exact` means the pack file is literally the thing the item is: a potion for a
## potion, a sword for a sword, a key for a key. `approx` means the pack has no
## such object at all and this is the nearest shape in it — recorded here and in
## the credits doc so nobody has to guess later which icons are honest and which
## are stand-ins.
SOURCES = [
    ("health_potion", "Items/Potion/LifePot.png", "exact",
     "the same flask assets/sprites/potion.png is cut from"),
    ("mana_potion", "Items/Potion/WaterPot.png", "exact",
     "the pack's water flask; the pack has no mana flask, this is its other potion"),
    ("iron_sword", "Items/Weapons/Sword/Sprite.png", "exact",
     "the pack's sword"),
    ("iron_spear", "Items/Weapons/Lance/Sprite.png", "exact",
     "the pack's spear is named Lance"),
    ("leather_armor", "Ui/Skill Icon/Items & Weapon/Armor.png", "exact",
     "the only armour shape in the pack is the equipment skill icon"),
    ("wooden_shield", "Ui/Skill Icon/Items & Weapon/Guard.png", "exact",
     "the pack's shield icon is named Guard"),
    ("leather_boots", "Ui/Skill Icon/Items & Weapon/Boot.png", "exact",
     "the pack's boot icon"),
    ("swift_ring", "Ui/Skill Icon/Items & Weapon/Ring.png", "exact",
     "the pack's ring icon"),
    ("echo_amulet", "Ui/Skill Icon/Items & Weapon/Amulet.png", "exact",
     "the pack's amulet icon"),
    ("wolf_fang", "Items/Weapons/Bone/SpriteInHand.png", "approx",
     "no fang in the pack; this is its bone, held variant (knob end down)"),
    ("boar_tusk", "Items/Tool/Sickle.png", "approx",
     "no tusk or horn in the pack; the sickle's curved blade is the nearest "
     "curved point it draws"),
    ("bone_shard", "Items/Weapons/Bone/Sprite.png", "exact",
     "the pack's bone, unheld variant (knob end up)"),
    ("ruin_key", "Items/Treasure/SilverKey.png", "approx",
     "the pack has two keys, gold and silver; silver is the nearer read for a "
     "rusty iron key — the metal is bright grey, not rust-brown"),
    ("rusted_seal", "Items/Other/Stamp.png", "exact",
     "a seal stamp, which is what a broken royal seal reads as"),
]


def load_member(pack, member):
    """Decode one PNG member of the pack without leaving anything on disk.

    The reusable codec in import_ninja_sprites.py reads a path, so the member is
    written to a temp file outside the repository and removed again; the pack is
    never unpacked into the project.
    """
    with zipfile.ZipFile(pack) as archive:
        raw = archive.read(PACK_ROOT + member)
    handle, tmp = tempfile.mkstemp(suffix=".png")
    try:
        with os.fdopen(handle, "wb") as fh:
            fh.write(raw)
        _w, _h, grid = ninja.load_rgba(tmp)
    finally:
        os.unlink(tmp)
    return grid


def alpha_bbox(grid):
    """Tightest (x, y, w, h) around the non-transparent pixels, or None."""
    height, width = len(grid), len(grid[0])
    x0, y0, x1, y1 = width, height, -1, -1
    for y in range(height):
        for x in range(width):
            if grid[y][x][3] > 0:
                x0, y0 = min(x0, x), min(y0, y)
                x1, y1 = max(x1, x), max(y1, y)
    if x1 < 0:
        return None
    return x0, y0, x1 - x0 + 1, y1 - y0 + 1


def crop(grid, x, y, w, h):
    return [[grid[y + dy][x + dx] for dx in range(w)] for dy in range(h)]


def fit_into_cell(grid, size=ICON_SIZE):
    """Fit one sprite into a transparent size x size cell. Returns (cell, note)."""
    box = alpha_bbox(grid)
    if box is None:
        raise ValueError("source is fully transparent")
    x, y, w, h = box
    art = crop(grid, x, y, w, h)
    if w <= size and h <= size:
        cell = ninja.blank(size, size)
        ninja.center_paste(cell, size, size, art)
        return cell, "native %dx%d centred" % (w, h)
    longest = max(w, h)
    dw = max(1, int(round(w * size / longest)))
    dh = max(1, int(round(h * size / longest)))
    cell = ninja.blank(size, size)
    ninja.center_paste(cell, size, size, ninja.nn_scale(art, dw, dh))
    return cell, "nearest-neighbour %dx%d -> %dx%d" % (w, h, dw, dh)


def build(pack, out_dir, write):
    rows = []
    for item_id, member, kind, why in SOURCES:
        cell, note = fit_into_cell(load_member(pack, member))
        target = os.path.join(out_dir, "icon_%s.png" % item_id)
        if write:
            ninja.save_rgba(target, ICON_SIZE, ICON_SIZE, cell)
        rows.append((item_id, member, kind, note, target, os.path.exists(target)))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--pack", default=DEFAULT_PACK, help="path to the Ninja Adventure zip")
    ap.add_argument("--out", default=DEFAULT_OUT, help="directory for icon_<item_id>.png")
    ap.add_argument("--check", action="store_true",
                    help="report what would be written and whether each output exists")
    args = ap.parse_args()

    if not os.path.exists(args.pack):
        sys.stderr.write("pack not found: %s\n" % args.pack)
        return 2
    if not args.check:
        os.makedirs(args.out, exist_ok=True)

    rows = build(args.pack, args.out, write=not args.check)
    width = max(len(r[0]) for r in rows)
    print("%-*s  %-9s  %-46s  %s" % (width, "item", "match", "fit", "source"))
    for item_id, member, kind, note, _target, exists in rows:
        print("%-*s  %-9s  %-46s  %s%s" % (
            width, item_id, kind, note, member, "" if exists or not args.check else "  [MISSING]"))
    approx = [r[0] for r in rows if r[2] == "approx"]
    print("\n%d icons, %d exact, %d approximation(s): %s"
          % (len(rows), len(rows) - len(approx), len(approx), ", ".join(approx) or "none"))
    if args.check:
        missing = [r[4] for r in rows if not r[5]]
        if missing:
            sys.stderr.write("missing: %s\n" % ", ".join(missing))
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

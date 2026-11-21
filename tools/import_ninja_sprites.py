#!/usr/bin/env python3
"""Import real 16x16 pixel art from the local Ninja Adventure pack (CC0) into
the project's sprite contract, keeping every file's exact dimensions so no game
code changes.

Source: assets/assets4/ninja_adventure_asset_pack.zip (already extracted to a
source dir; this script never downloads anything).

The eight outputs and the EXACT source cells they are sliced from are listed in
SOURCES below and recorded in docs/ASSET_CREDITS.md. The character sheets are
64x112 = 4 columns x 7 rows of 16x16. The pack's README documents the column
order as down/right/left/up, but measuring the pixels shows the real order is
DOWN(col0) / UP(col1) / LEFT(col2) / RIGHT(col3): col0 has the two front eyes,
col1 is a featureless back-of-head, col2/col3 are mirrored side views. Row0 is
the idle pose (row2 is its exact duplicate, the "pad" row). The slicing below
uses the measured order, not the documented one.

Tile transparency: the tree cell TilesetNature px(192,144) is a bush drawn on an
empty background — measured 118 of its 256 pixels are alpha 0, including both
edge columns. Sliced straight into the atlas it renders as a black square around
the bush in a TileMapLayer, so every tile is passed through ensure_opaque(),
which gives anything with alpha a solid opaque base underneath. Grass, dirt and
stone are already fully opaque and stay byte-identical.

Tree readability: the bush composited over grass measured only lum 149.2 against
grass lum 174.9 — a 25.7-unit gap — so in game trees read as slightly darker
grass, not as dense impassable foliage. Three opaque variants are therefore
built in one run and measured (see tree_variants): A = bush over solid
RGB(38,66,38); B = bush over solid RGB(26,48,30) with every non-transparent
pixel then darkened 25% by integer multiply; C = the bush composited twice over
RGB(38,66,38), once as-is and once mirrored vertically at +2 px, thickening the
silhouette into a clump. --tree-variant picks which one lands in tiles.png
(default b, the measured darkest). All three are 100% opaque, single 16x16
cells, integer math, nearest-neighbour only, no blur. --sheet writes an 8x
labelled comparison PNG of grass, bush-over-grass, A, B and C.

Uses PIL when it is installed; otherwise falls back to a pure-Python PNG
codec (zlib + struct). Deterministic, idempotent, no randomness.
"""
import argparse
import os
import struct
import sys
import zlib

# --- PNG backend: prefer PIL, else pure-Python -------------------------------
try:
    from PIL import Image  # type: ignore
    HAVE_PIL = True
except Exception:  # pragma: no cover - environment dependent
    Image = None
    HAVE_PIL = False


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _decode_pure(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG: %s" % path)
    pos, palette, trns, idat = 8, None, None, bytearray()
    width = height = bitdepth = colortype = interlace = None
    while pos < len(raw):
        (length,) = struct.unpack(">I", raw[pos:pos + 4])
        ctype = raw[pos + 4:pos + 8]
        cdata = raw[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, bitdepth, colortype, _c, _f, interlace = \
                struct.unpack(">IIBBBBB", cdata)
        elif ctype == b"PLTE":
            palette = cdata
        elif ctype == b"tRNS":
            trns = cdata
        elif ctype == b"IDAT":
            idat += cdata
        elif ctype == b"IEND":
            break
    data = zlib.decompress(bytes(idat))
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colortype]
    bpp_bytes = max(1, (channels * bitdepth + 7) // 8)

    def stride(w):
        return (w * channels * bitdepth + 7) // 8

    def unfilter(w, h, src):
        out, p, prev = [], 0, bytearray(stride(w))
        for _ in range(h):
            ft = src[p]
            p += 1
            line = bytearray(src[p:p + stride(w)])
            p += stride(w)
            n = stride(w)
            for i in range(n):
                if ft == 1:
                    if i >= bpp_bytes:
                        line[i] = (line[i] + line[i - bpp_bytes]) & 0xFF
                elif ft == 2:
                    line[i] = (line[i] + prev[i]) & 0xFF
                elif ft == 3:
                    a = line[i - bpp_bytes] if i >= bpp_bytes else 0
                    line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
                elif ft == 4:
                    a = line[i - bpp_bytes] if i >= bpp_bytes else 0
                    c = prev[i - bpp_bytes] if i >= bpp_bytes else 0
                    line[i] = (line[i] + _paeth(a, prev[i], c)) & 0xFF
                elif ft != 0:
                    raise ValueError("bad filter %d" % ft)
            out.append(line)
            prev = line
        return out

    maxv = (1 << bitdepth) - 1
    scale = 255 // maxv if maxv != 255 else 1

    def to_rgba(sample):
        if colortype == 0:
            return (sample[0], sample[0], sample[0], 255)
        if colortype == 4:
            return (sample[0], sample[0], sample[0], sample[1])
        if colortype == 2:
            return (sample[0], sample[1], sample[2], 255)
        if colortype == 6:
            return (sample[0], sample[1], sample[2], sample[3])
        if colortype == 3:
            idx = sample[0]
            a = trns[idx] if (trns and idx < len(trns)) else 255
            return (palette[idx * 3], palette[idx * 3 + 1], palette[idx * 3 + 2], a)
        raise ValueError("unsupported colortype %d" % colortype)

    def expand(rows, w):
        out = []
        for row in rows:
            pxs = []
            for x in range(w):
                if bitdepth == 8:
                    base = x * channels
                    pxs.append(list(row[base:base + channels]))
                elif bitdepth == 16:
                    base = x * channels * 2
                    pxs.append([row[base + i * 2] for i in range(channels)])
                else:
                    chans, bitpos = [], x * channels * bitdepth
                    for c in range(channels):
                        b = bitpos + c * bitdepth
                        byte = row[b // 8]
                        shift = 8 - bitdepth - (b % 8)
                        chans.append(((byte >> shift) & maxv) * scale)
                    pxs.append(chans)
            out.append(pxs)
        return out

    grid = [[(0, 0, 0, 0) for _ in range(width)] for _ in range(height)]
    if interlace == 0:
        pxs = expand(unfilter(width, height, data), width)
        for y in range(height):
            for x in range(width):
                grid[y][x] = to_rgba(pxs[y][x])
    else:
        passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 2, 4, 8), (2, 0, 4, 4),
                  (0, 1, 2, 4), (1, 0, 2, 2), (0, 0, 1, 2)]
        p = 0
        for (xoff, yoff, xstep, ystep) in passes:
            pw = (width - xoff + xstep - 1) // xstep
            ph = (height - yoff + ystep - 1) // ystep
            if pw <= 0 or ph <= 0:
                continue
            sub = stride(pw) * ph
            pxs = expand(unfilter(pw, ph, data[p:p + sub]), pw)
            p += sub
            for y in range(ph):
                for x in range(pw):
                    grid[yoff + y * ystep][xoff + x * xstep] = to_rgba(pxs[y][x])
    return width, height, grid


def _encode_pure(path, width, height, grid):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw += bytes(grid[y][x])
    comp = zlib.compress(bytes(raw), 9)

    def chunk(tag, d):
        c = tag + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
                 + chunk(b"IDAT", comp) + chunk(b"IEND", b""))


def load_rgba(path):
    if HAVE_PIL:
        im = Image.open(path).convert("RGBA")
        px = im.load()
        w, h = im.size
        return w, h, [[px[x, y] for x in range(w)] for y in range(h)]
    return _decode_pure(path)


def save_rgba(path, width, height, grid):
    if HAVE_PIL:
        im = Image.new("RGBA", (width, height))
        im.putdata([grid[y][x] for y in range(height) for x in range(width)])
        im.save(path)
    else:
        _encode_pure(path, width, height, grid)


# --- pixel helpers -----------------------------------------------------------
def blank(w, h):
    return [[(0, 0, 0, 0) for _ in range(w)] for _ in range(h)]


def blit_cell(dst, dx, dy, src, sx, sy, w, h):
    """Copy an w x h region from src at (sx,sy) into dst at (dx,dy), clipped."""
    sh = len(src)
    sw = len(src[0])
    dh = len(dst)
    dw = len(dst[0])
    for y in range(h):
        for x in range(w):
            syv, sxv = sy + y, sx + x
            dyv, dxv = dy + y, dx + x
            if 0 <= sxv < sw and 0 <= syv < sh and 0 <= dxv < dw and 0 <= dyv < dh:
                dst[dyv][dxv] = src[syv][sxv]


def center_paste(dst, dw, dh, src):
    """Paste src centred in a dw x dh transparent cell (floor offset)."""
    sw, sh = len(src[0]), len(src)
    ox, oy = (dw - sw) // 2, (dh - sh) // 2
    blit_cell(dst, ox, oy, src, 0, 0, sw, sh)


def nn_scale(src, dw, dh):
    """Nearest-neighbour resize, no blur."""
    sw, sh = len(src[0]), len(src)
    out = blank(dw, dh)
    for y in range(dh):
        sy = min(sh - 1, y * sh // dh)
        for x in range(dw):
            sx = min(sw - 1, x * sw // dw)
            out[y][x] = src[sy][sx]
    return out


def opaque_fraction(grid):
    """Fraction of pixels with alpha exactly 255."""
    total = len(grid) * len(grid[0])
    return sum(1 for row in grid for q in row if q[3] == 255) / float(total)


def composite_over(base, top):
    """Source-over alpha composite of `top` onto `base`, in place, same size.

    Integer math only: no float rounding drift, no blur, no resampling, so the
    result is byte-identical on every run and on every machine. Fully
    transparent source pixels leave the background untouched, fully opaque ones
    replace it exactly, so a hard-edged pixel-art sprite keeps its edges.
    """
    for y in range(len(top)):
        for x in range(len(top[0])):
            sr, sg, sb, sa = top[y][x]
            if sa == 0:
                continue
            br, bg, bb, ba = base[y][x]
            na = sa + ba * (255 - sa) // 255
            if na == 0:
                base[y][x] = (0, 0, 0, 0)
                continue
            inv = 255 - sa
            base[y][x] = (
                (sr * sa + br * ba * inv // 255) // na,
                (sg * sa + bg * ba * inv // 255) // na,
                (sb * sa + bb * ba * inv // 255) // na,
                na,
            )
    return base


def ensure_opaque(cell, bg, name=""):
    """Return (grid, was_composited): the cell laid source-over opaque `bg`.

    A tile with any alpha below 255 draws as a dark box inside a TileMapLayer,
    because the layer has nothing behind it. Already-opaque tiles are returned
    untouched (same bytes), so this only changes the tiles that need it.
    """
    if opaque_fraction(cell) >= 1.0:
        return cell, False
    return composite_over([row[:] for row in bg], cell), True


def solid(w, h, rgb):
    """Fully opaque w x h grid of one colour."""
    r, g, b = rgb
    return [[(r, g, b, 255) for _ in range(w)] for _ in range(h)]


def mirror_v(src):
    """Vertical mirror (top<->bottom) of an w x h grid, same size, no resampling."""
    return [row[:] for row in reversed(src)]


def darken(grid, num, den):
    """Multiply every non-transparent pixel's RGB by num//den (integer, exact).

    Alpha is left untouched, so opacity is never changed by darkening. Integer
    math keeps the result byte-identical on every run and machine.
    """
    out = []
    for row in grid:
        newrow = []
        for (r, g, b, a) in row:
            if a == 0:
                newrow.append((r, g, b, a))
            else:
                newrow.append((r * num // den, g * num // den, b * num // den, a))
        out.append(newrow)
    return out


def mean_luminance(grid):
    """Mean Rec.601 luma (0.299R+0.587G+0.114B) over all pixels, integer math."""
    total = 0
    for row in grid:
        for (r, g, b, _a) in row:
            total += (299 * r + 587 * g + 114 * b) // 1000
    return total / float(len(grid) * len(grid[0]))


# --- tree variants -----------------------------------------------------------
# The bush cell TilesetNature px(192,144) is drawn on an empty background, so
# composited over grass it reads as a slightly darker patch of grass: the bush
# greens sit close to the grass luminance and the tile does not read as a dense
# impassable obstacle. Three variants are built in one run and measured; the
# flag picks which one is written into tiles.png.
TREE_BASE_MID = (38, 66, 38)
TREE_BASE_DARK = (26, 48, 30)


def tree_variants(bush):
    """Return {'a':grid,'b':grid,'c':grid}, each 16x16 and 100% opaque."""
    # A: bush over a solid mid dark-green base.
    a = composite_over(solid(16, 16, TREE_BASE_MID), bush)
    # B: bush over a darker solid base, then every non-transparent pixel
    #    darkened by 25% (x75/100, integer).
    b = composite_over(solid(16, 16, TREE_BASE_DARK), bush)
    b = darken(b, 75, 100)
    # C: the bush twice over the mid base — once as-is, once mirrored
    #    vertically and shifted +2 px down, which thickens the silhouette into
    #    a clump. Single cell only; no 2x2 arrangement.
    c = solid(16, 16, TREE_BASE_MID)
    composite_over(c, bush)
    composite_over(c, shift_down(mirror_v(bush), 2))
    return {"a": a, "b": b, "c": c}


def shift_down(src, dy):
    """Copy an w x h grid dy px down, dropping what leaves the cell."""
    out = blank(len(src[0]), len(src))
    blit_cell(out, 0, dy, src, 0, 0, len(src[0]), len(src))
    return out


# --- comparison sheet --------------------------------------------------------
# Minimal 3x5 bitmap font, only the glyphs the sheet labels need. Drawn at the
# sheet's own scale so labels stay hard-edged pixel art like the tiles.
FONT3x5 = {
    "A": ("010", "101", "111", "101", "101"),
    "B": ("110", "101", "110", "101", "110"),
    "C": ("011", "100", "100", "100", "011"),
    "D": ("110", "101", "101", "101", "110"),
    "E": ("111", "100", "110", "100", "111"),
    "G": ("011", "100", "101", "101", "011"),
    "I": ("111", "010", "010", "010", "111"),
    "L": ("100", "100", "100", "100", "111"),
    "N": ("101", "111", "111", "111", "101"),
    "O": ("010", "101", "101", "101", "010"),
    "P": ("110", "101", "110", "100", "100"),
    "R": ("110", "101", "110", "101", "101"),
    "S": ("011", "010", "010", "001", "110"),
    "T": ("111", "010", "010", "010", "010"),
    "U": ("101", "101", "101", "101", "111"),
    "V": ("101", "101", "101", "101", "010"),
    "W": ("101", "101", "111", "111", "101"),
    "+": ("000", "010", "111", "010", "000"),
    "0": ("111", "101", "101", "101", "111"),
    "1": ("010", "110", "010", "010", "111"),
    "2": ("111", "001", "111", "100", "111"),
    "3": ("111", "001", "111", "001", "111"),
    "4": ("101", "101", "111", "001", "001"),
    "5": ("111", "100", "111", "001", "111"),
    "6": ("111", "100", "111", "101", "111"),
    "7": ("111", "001", "010", "010", "010"),
    "8": ("111", "101", "111", "101", "111"),
    "9": ("111", "101", "111", "001", "111"),
    " ": ("000", "000", "000", "000", "000"),
}


def draw_text(dst, ox, oy, text, rgb, scale=1):
    """Blit a label in the 3x5 font onto dst at (ox,oy); unknown chars skipped."""
    r, g, b = rgb
    cx = ox
    for ch in text.upper():
        glyph = FONT3x5.get(ch)
        if glyph:
            for gy in range(5):
                for gx in range(3):
                    if glyph[gy][gx] == "1":
                        for sy in range(scale):
                            for sx in range(scale):
                                x, y = cx + gx * scale + sx, oy + gy * scale + sy
                                if 0 <= x < len(dst[0]) and 0 <= y < len(dst):
                                    dst[y][x] = (r, g, b, 255)
        cx += 4 * scale


def comparison_sheet(items, path, scale=8, gap=8, label_h=32):
    """Write a labelled 8x nearest-neighbour sheet of 16x16 tiles.

    `items` is a list of (label, grid). Returns (width, height).
    """
    tw = 16 * scale
    th = 16 * scale
    w = len(items) * tw + (len(items) - 1) * gap
    h = label_h + th
    sheet = solid(w, h, (12, 12, 16))
    for i, (label, grid) in enumerate(items):
        ox = i * (tw + gap)
        big = nn_scale(grid, tw, th)
        blit_cell(sheet, ox, label_h, big, 0, 0, tw, th)
        draw_text(sheet, ox + 2, (label_h - 10) // 2, label, (236, 236, 236),
                  scale=2)
    save_rgba(path, w, h, sheet)
    return w, h


# --- source resolution -------------------------------------------------------
PACK_PREFIX = "Ninja Adventure - Asset Pack"

# rel path inside the pack -> human label
SOURCES = {
    "ninja": "Actor/Character/NinjaRed/SpriteSheet.png",
    "villager": "Actor/Character/Villager/SpriteSheet.png",
    "hunter": "Actor/Character/Hunter/SpriteSheet.png",
    "skeleton": "Actor/Character/Skeleton/SpriteSheet.png",
    "dog": "Actor/Animal/Dog/SpriteSheet.png",
    "chest": "Items/Treasure/LittleTreasureChest.png",
    "potion": "Items/Potion/LifePot.png",
    "coin": "Items/Treasure/GoldCoin.png",
    "field": "Backgrounds/Tilesets/TilesetField.png",
    "nature": "Backgrounds/Tilesets/TilesetNature.png",
}


def resolve(srcdir, rel):
    cands = [os.path.join(srcdir, PACK_PREFIX, rel), os.path.join(srcdir, rel)]
    for c in cands:
        if os.path.isfile(c):
            return c
    base = os.path.basename(rel)
    for root, _dirs, files in os.walk(srcdir):
        if base in files:
            return os.path.join(root, base)
    raise SystemExit("ERROR: source not found under %s: %s" % (srcdir, rel))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.normpath(os.path.join(here, "..", "assets", "sprites"))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", default="/tmp/ninja",
                    help="dir holding the extracted Ninja Adventure pack")
    ap.add_argument("--out", default=default_out, help="assets/sprites output dir")
    ap.add_argument("--tree-variant", choices=("a", "b", "c"), default="b",
                    help="which tree tile to write into tiles.png: "
                         "a = bush over solid RGB(38,66,38); "
                         "b = bush over solid RGB(26,48,30) then all pixels "
                         "darkened 25%% (integer); c = bush plus its vertical "
                         "mirror at +2px over RGB(38,66,38). Default b: the "
                         "measured darkest, i.e. furthest from grass.")
    ap.add_argument("--sheet", default="",
                    help="also write an 8x labelled comparison sheet "
                         "(grass, bush-over-grass, A, B, C) to this PNG path")
    args = ap.parse_args()

    if not os.path.isdir(args.src):
        raise SystemExit("ERROR: source dir does not exist: %s" % args.src)
    os.makedirs(args.out, exist_ok=True)

    paths = {k: resolve(args.src, rel) for k, rel in SOURCES.items()}
    img = {k: load_rgba(p) for k, p in paths.items()}

    def cell(key, sx, sy, w=16, h=16):
        _w, _h, g = img[key]
        out = blank(w, h)
        blit_cell(out, 0, 0, g, sx, sy, w, h)
        return out

    # --- player.png 64x16: down / up / right / down(reserve) ----------------
    # NinjaRed row0 idle. Measured columns: 0=down, 1=up, 2=left, 3=right.
    player = blank(64, 16)
    blit_cell(player, 0, 0, img["ninja"][2], 0, 0, 16, 16)    # frame0 DOWN
    blit_cell(player, 16, 0, img["ninja"][2], 16, 0, 16, 16)  # frame1 UP
    blit_cell(player, 32, 0, img["ninja"][2], 48, 0, 16, 16)  # frame2 SIDE=RIGHT
    blit_cell(player, 48, 0, img["ninja"][2], 0, 0, 16, 16)   # frame3 reserve=DOWN

    # --- single 16x16 actors (down-facing idle = col0 row0) -----------------
    wolf = cell("dog", 0, 0)      # Dog sheet is side-view only; frame0 used
    archer = cell("hunter", 0, 0)
    npc = cell("villager", 0, 0)
    chest = cell("chest", 0, 0)   # frame0 = closed

    # --- potion: LifePot 9x11 centred in 16x16 ------------------------------
    potion = blank(16, 16)
    center_paste(potion, 16, 16, img["potion"][2])

    # --- coin: GoldCoin 7x7 nearest-neighbour scaled to 8x8 -----------------
    coin = nn_scale(img["coin"][2], 8, 8)

    # --- tiles.png 64x16: grass, dirt, stone, tree --------------------------
    # grass = TilesetField (16,64)  [col1,row4 solid green fill]
    # dirt  = TilesetField (16,16)  [col1,row1 solid tan fill]
    # stone = TilesetNature (288,240)[col18,row15 mossy grey rock, most seamless;
    #   the old (144,96) measured lum 241 = near-white snow, not rock]
    # tree  = TilesetNature (192,144)[col12,row9 whole rounded bush with a small
    #   trunk and empty left/right margins; the old (0,16) was one quadrant of a
    #   2x2 tree -> striped columns when tiled]
    # Grass, dirt and stone are already 1.000 opaque and pass through
    # ensure_opaque() byte-identical. The tree cell is 0.539 opaque (118
    # transparent px, both edge columns empty), and the old bush-over-grass
    # composite measured only lum 149.2 vs grass 174.9, so trees read as darker
    # grass. tree_variants() builds three opaque alternatives (A/B/C) and
    # --tree-variant writes one of them into the atlas; see the module docstring.
    grass = cell("field", 16, 64)
    dirt_raw = cell("field", 16, 16)
    stone_raw = cell("nature", 288, 240)
    tree_raw = cell("nature", 192, 144)
    dirt, dirt_bg = ensure_opaque(dirt_raw, grass, "dirt")
    stone, stone_bg = ensure_opaque(stone_raw, grass, "stone")
    # Legacy behaviour, kept only so the sheet can show what is being replaced:
    # the bush composited over grass, which reads as slightly darker grass.
    tree_over_grass, _tog = ensure_opaque(tree_raw, grass, "tree")
    variants = tree_variants(tree_raw)
    chosen_lum = {k: mean_luminance(v) for k, v in variants.items()}
    grass_lum = mean_luminance(grass)
    tree = variants[args.tree_variant]
    tree_bg = True

    tiles = blank(64, 16)
    blit_cell(tiles, 0, 0, grass, 0, 0, 16, 16)
    blit_cell(tiles, 16, 0, dirt, 0, 0, 16, 16)
    blit_cell(tiles, 32, 0, stone, 0, 0, 16, 16)
    blit_cell(tiles, 48, 0, tree, 0, 0, 16, 16)

    for name, frac, did in (("grass", opaque_fraction(grass), False),
                            ("dirt", opaque_fraction(dirt), dirt_bg),
                            ("stone", opaque_fraction(stone), stone_bg),
                            ("tree", opaque_fraction(tree), tree_bg)):
        print("  tile %-5s opaque_frac %.3f%s"
              % (name, frac, "  (composited over a solid base)" if did else ""))
        assert frac >= 1.0, "tile %s is not fully opaque" % name

    # --- tree variant measurements + verification ----------------------------
    print("tree variant candidates (mean luminance, grass = %.1f):" % grass_lum)
    for key in ("a", "b", "c"):
        print("  %s: lum %.1f  dark_vs_grass %.1f  opaque_frac %.3f"
              % (key, chosen_lum[key], grass_lum - chosen_lum[key],
                 opaque_fraction(variants[key])))
    print("chosen: %s" % args.tree_variant)
    gap_lum = grass_lum - chosen_lum[args.tree_variant]
    assert gap_lum >= 35.0, \
        "tree tile is only %.1f lum units darker than grass, need >= 35" % gap_lum
    four = {"grass": grass, "dirt": dirt, "stone": stone,
            "tree": variants[args.tree_variant]}
    names = sorted(four)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            x, y = names[i], names[j]
            assert four[x] != four[y], "tiles %s and %s are identical" % (x, y)
    print("  tree vs grass luminance gap: %.1f (>= 35 required)" % gap_lum)
    print("  four tiles pairwise distinct: ok")

    if args.sheet:
        items = [("GRASS", grass),
                 ("BUSH+GRASS", tree_over_grass),
                 ("CAND A", variants["a"]),
                 ("CAND B", variants["b"]),
                 ("CAND C", variants["c"])]
        sw, sh = comparison_sheet(items, args.sheet)
        print("  wrote sheet  %s  %dx%d" % (args.sheet, sw, sh))

    outputs = [
        ("player.png", 64, 16, player),
        ("wolf.png", 16, 16, wolf),
        ("archer.png", 16, 16, archer),
        ("npc.png", 16, 16, npc),
        ("chest.png", 16, 16, chest),
        ("potion.png", 16, 16, potion),
        ("coin.png", 8, 8, coin),
        ("tiles.png", 64, 16, tiles),
    ]
    print("backend: %s" % ("PIL" if HAVE_PIL else "pure-Python"))
    print("source : %s" % args.src)
    print("output : %s" % args.out)
    for name, w, h, grid in outputs:
        # sanity: every output keeps its exact contract size
        assert len(grid) == h and all(len(r) == w for r in grid), name
        save_rgba(os.path.join(args.out, name), w, h, grid)
        cov = sum(1 for r in grid for p in r if p[3] > 8) / float(w * h)
        print("  wrote %-11s %2dx%-2d  alpha coverage %.1f%%  opaque_frac %.3f"
              % (name, w, h, cov * 100, opaque_fraction(grid)))


if __name__ == "__main__":
    main()

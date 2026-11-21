#!/usr/bin/env python3
"""Generate placeholder 16x16 pixel-art PNGs (no external deps).

These are TEMPORARY assets: see docs/TODO_TEMP_ASSETS.md.
Every sprite is drawn from simple primitives so the shapes stay readable at
16x16 with nearest-neighbour filtering.
"""
import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "sprites")


def png(path, width, height, pixels):
    """pixels: list of rows, each row a list of (r,g,b,a)."""
    raw = b"".join(
        b"\x00" + b"".join(struct.pack("BBBB", *px) for px in row) for row in pixels
    )

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    blob = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(blob)
    print("wrote", path, f"{width}x{height}")


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [[(0, 0, 0, 0) for _ in range(w)] for _ in range(h)]

    def put(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y][x] = c

    def rect(self, x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.put(x, y, c)

    def ellipse(self, cx, cy, rx, ry, c):
        for y in range(self.h):
            for x in range(self.w):
                if rx and ry and ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0:
                    self.put(x, y, c)

    def outline(self, c):
        """Add a 1px outline around every opaque cluster."""
        src = [row[:] for row in self.px]
        for y in range(self.h):
            for x in range(self.w):
                if src[y][x][3] != 0:
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < self.w and 0 <= ny < self.h and src[ny][nx][3] != 0:
                        self.put(x, y, c)
                        break

    def blit(self, other, ox, oy):
        for y in range(other.h):
            for x in range(other.w):
                px = other.px[y][x]
                if px[3] != 0:
                    self.put(ox + x, oy + y, px)

    def composite(self, other, ox, oy):
        """Alpha-composite `other` over this canvas at (ox,oy), per-pixel
        source-over. Unlike blit(), transparent source pixels keep the existing
        background instead of leaving a hole, so a sprite with empty margins can
        be dropped over an opaque tile without exposing a transparent gap."""
        for y in range(other.h):
            for x in range(other.w):
                sr, sg, sb, sa = other.px[y][x]
                if sa == 0:
                    continue
                dx, dy = ox + x, oy + y
                if not (0 <= dx < self.w and 0 <= dy < self.h):
                    continue
                dr, dg, db, da = self.px[dy][dx]
                na = sa + da * (255 - sa) // 255
                if na == 0:
                    self.px[dy][dx] = (0, 0, 0, 0)
                    continue
                inv = 255 - sa
                r = (sr * sa + dr * da * inv // 255) // na
                g = (sg * sa + dg * da * inv // 255) // na
                b = (sb * sa + db * da * inv // 255) // na
                self.px[dy][dx] = (r, g, b, na)


CLEAR = (0, 0, 0, 0)
BLACK = (16, 14, 20, 255)
SKIN = (232, 190, 152, 255)
STEEL = (176, 184, 196, 255)
STEEL_D = (108, 116, 132, 255)
CLOAK = (52, 96, 132, 255)
CLOAK_L = (78, 132, 176, 255)
BOOT = (72, 56, 44, 255)


def humanoid(cloak, cloak_l, hair=(58, 42, 32, 255), eye=(24, 20, 28, 255)):
    """A readable 16x16 top-down-ish figure."""
    c = Canvas(16, 16)
    # legs
    c.rect(5, 12, 6, 15, BOOT)
    c.rect(9, 12, 10, 15, BOOT)
    # torso / cloak
    c.rect(4, 7, 11, 13, cloak)
    c.rect(4, 7, 11, 8, cloak_l)
    # shoulders
    c.put(3, 8, cloak)
    c.put(12, 8, cloak)
    # head
    c.ellipse(7.5, 4.5, 3.6, 3.4, SKIN)
    # hair
    c.rect(4, 1, 11, 2, hair)
    c.put(4, 3, hair)
    c.put(11, 3, hair)
    # eyes
    c.put(6, 5, eye)
    c.put(9, 5, eye)
    c.outline(BLACK)
    return c


def make_player():
    strip = Canvas(64, 16)
    down = humanoid(CLOAK, CLOAK_L)
    up = humanoid(CLOAK, CLOAK_L, hair=(58, 42, 32, 255))
    # "up" hides the face
    up.rect(5, 3, 10, 6, (58, 42, 32, 255))
    up.put(6, 5, (58, 42, 32, 255))
    up.put(9, 5, (58, 42, 32, 255))
    up.outline(BLACK)
    side = humanoid(CLOAK_L, CLOAK)
    side.put(9, 5, (24, 20, 28, 255))
    side.put(6, 5, CLEAR)
    strip.blit(down, 0, 0)
    strip.blit(up, 16, 0)
    strip.blit(side, 32, 0)
    strip.blit(down, 48, 0)
    return strip


def make_wolf():
    """Ash wolf: low, four-legged silhouette."""
    c = Canvas(16, 16)
    body = (108, 104, 116, 255)
    body_l = (140, 136, 148, 255)
    c.rect(3, 8, 12, 11, body)
    c.rect(3, 8, 12, 8, body_l)
    # legs
    c.rect(3, 12, 4, 14, body)
    c.rect(7, 12, 8, 14, body)
    c.rect(11, 12, 12, 14, body)
    # head + snout
    c.rect(11, 5, 14, 9, body_l)
    c.put(15, 7, body)
    # ears
    c.put(11, 4, body)
    c.put(14, 4, body)
    # eye
    c.put(13, 6, (226, 120, 64, 255))
    # tail
    c.rect(1, 7, 3, 8, body)
    c.outline(BLACK)
    return c


def make_archer():
    """Ranged cultist: hooded, holding a bow."""
    c = humanoid((92, 72, 108, 255), (122, 100, 140, 255), hair=(70, 52, 84, 255))
    # hood
    c.rect(3, 1, 12, 3, (92, 72, 108, 255))
    c.put(3, 4, (92, 72, 108, 255))
    c.put(12, 4, (92, 72, 108, 255))
    # bow
    c.rect(13, 5, 13, 12, (150, 110, 62, 255))
    c.put(14, 6, (150, 110, 62, 255))
    c.put(14, 11, (150, 110, 62, 255))
    c.outline(BLACK)
    return c


def make_npc():
    c = humanoid((96, 84, 60, 255), (124, 110, 82, 255), hair=(178, 168, 150, 255))
    # staff
    c.rect(12, 3, 12, 13, (122, 96, 58, 255))
    c.put(12, 2, (120, 190, 210, 255))
    c.outline(BLACK)
    return c


def make_chest():
    c = Canvas(16, 16)
    wood = (138, 96, 56, 255)
    wood_l = (168, 122, 74, 255)
    iron = (168, 172, 180, 255)
    c.rect(3, 6, 12, 14, wood)
    c.rect(3, 6, 12, 8, wood_l)
    c.rect(3, 9, 12, 10, iron)
    c.rect(7, 9, 8, 12, (232, 196, 96, 255))
    c.outline(BLACK)
    return c


def make_coin():
    c = Canvas(8, 8)
    c.ellipse(3.5, 3.5, 3.2, 3.2, (240, 200, 72, 255))
    c.put(3, 2, (255, 240, 160, 255))
    c.outline((120, 88, 20, 255))
    return c


def make_potion():
    c = Canvas(16, 16)
    c.rect(6, 2, 9, 4, (196, 200, 208, 255))
    c.rect(5, 4, 10, 6, (120, 200, 236, 255))
    c.ellipse(7.5, 10.0, 4.6, 4.6, (196, 84, 96, 255))
    c.outline(BLACK)
    return c


def make_tiles():
    """4 tiles of 16x16: grass, dirt, stone wall, tree."""
    atlas = Canvas(64, 16)

    grass = Canvas(16, 16)
    grass.rect(0, 0, 15, 15, (74, 108, 62, 255))
    for x, y in ((2, 3), (7, 1), (12, 6), (4, 9), (10, 12), (1, 13), (14, 2)):
        grass.put(x, y, (92, 128, 74, 255))
        grass.put(x, y + 1, (62, 92, 54, 255))
    atlas.blit(grass, 0, 0)

    dirt = Canvas(16, 16)
    dirt.rect(0, 0, 15, 15, (112, 92, 66, 255))
    for x, y in ((3, 4), (9, 2), (12, 9), (5, 12), (1, 8), (14, 14)):
        dirt.put(x, y, (96, 78, 56, 255))
        dirt.put(x + 1, y, (128, 106, 78, 255))
    atlas.blit(dirt, 16, 0)

    stone = Canvas(16, 16)
    stone.rect(0, 0, 15, 15, (96, 96, 104, 255))
    stone.rect(0, 0, 15, 2, (120, 120, 130, 255))
    stone.rect(0, 7, 15, 8, (78, 78, 86, 255))
    stone.rect(0, 14, 15, 15, (78, 78, 86, 255))
    stone.rect(5, 0, 6, 7, (78, 78, 86, 255))
    stone.rect(11, 8, 12, 15, (78, 78, 86, 255))
    atlas.blit(stone, 32, 0)

    tree = Canvas(16, 16)
    tree.rect(7, 11, 8, 15, (86, 62, 40, 255))
    tree.ellipse(7.5, 6.0, 7.0, 5.6, (48, 82, 50, 255))
    tree.ellipse(7.5, 5.0, 5.0, 4.0, (62, 104, 62, 255))
    tree.put(5, 3, (86, 132, 78, 255))
    tree.put(9, 6, (86, 132, 78, 255))
    tree.outline((28, 44, 30, 255))
    # The tree is a bush with transparent corners; blitting it straight onto the
    # transparent atlas left those corners alpha=0, so the TileMapLayer drew a
    # black square around every tree. Lay the opaque grass tile down first and
    # composite the bush source-over it, so the margins read as grass (a bush
    # growing on grass) and the tile is 100% opaque with grass-coloured edges.
    tree_bg = Canvas(16, 16)
    tree_bg.rect(0, 0, 15, 15, (74, 108, 62, 255))
    for x, y in ((2, 3), (7, 1), (12, 6), (4, 9), (10, 12), (1, 13), (14, 2)):
        tree_bg.put(x, y, (92, 128, 74, 255))
        tree_bg.put(x, y + 1, (62, 92, 54, 255))
    atlas.blit(tree_bg, 48, 0)
    atlas.composite(tree, 48, 0)
    return atlas


def main():
    os.makedirs(OUT, exist_ok=True)
    png(os.path.join(OUT, "player.png"), 64, 16, make_player().px)
    png(os.path.join(OUT, "wolf.png"), 16, 16, make_wolf().px)
    png(os.path.join(OUT, "archer.png"), 16, 16, make_archer().px)
    png(os.path.join(OUT, "npc.png"), 16, 16, make_npc().px)
    png(os.path.join(OUT, "chest.png"), 16, 16, make_chest().px)
    png(os.path.join(OUT, "coin.png"), 8, 8, make_coin().px)
    png(os.path.join(OUT, "potion.png"), 16, 16, make_potion().px)
    png(os.path.join(OUT, "tiles.png"), 64, 16, make_tiles().px)


if __name__ == "__main__":
    main()

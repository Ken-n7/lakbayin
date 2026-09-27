#!/usr/bin/env python3
"""Tiny Swords' own rocks with maths carved into them, for the menus' scene
(client, 2026-09-27: math "etched on some assets" -- "natural rocks with
carves in them" -- and, after two tries at drawing rocks of our own, "the
generated one is out of place").

So nothing here is drawn: the rocks are the pack's Rock2 and Rock4, pixel for
pixel, shown at the same scale as the pack's other rocks, and the maths is
cut into their flat faces on their own pixel grid -- a 5x7 cut in the pack's
ink, the colour of its cracks, with a pale lip under each stroke where the
light catches the cut.

Each island carries its station's signs: Blue the four operations, Yellow the
order they are done in -- ( ) first, then x and / -- Red powers, on a
different set of the pack's four rocks each (`PIECES`), and on every rock one
character is set in gold rather than cut -- a different one each time.

Idempotent. Run from game/ with Pillow installed:

    python3 tools/make_carvings.py
"""
import os

from PIL import Image, ImageOps

SRC = "assets/terrain/decorations/"
OUT = "assets/terrain/decorations/math"

INK = (0x16, 0x1C, 0x2E, 255)       # the pack's outline and cracks
LIP = (0xB6, 0xE2, 0xE0, 255)       # a touch lighter than its lightest stone
# Gold inlay, one character a rock (client: "one gold character on one rock,
# and they vary every rock"): the gold, in a cut dark on its shaded sides,
# and a glint low down where the light reaches in.
GOLD = (0xF2, 0xC1, 0x4E, 255)
GLINT = (0xFF, 0xF4, 0xC2, 255)

# 5x7 cuts, and 3x5 raised ones for powers (a leading "^").
G = {
    "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
    "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    "x": [".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "....."],
    "/": ["..#..", ".....", ".....", "#####", ".....", ".....", "..#.."],
    "=": [".....", ".....", "#####", ".....", "#####", ".....", "....."],
    "(": ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],
    ")": [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],
    "v": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],   # the letter x
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "3": ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "6": [".###.", "#....", "#....", "####.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "....#", ".###."],
    "^2": ["###", "..#", "###", "#..", "###"],
    "^3": ["###", "..#", "###", "..#", "###"],
    " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    # A size down, for the smallest rock's face (a leading "_").
    "_9": [".##.", "#..#", "#..#", ".###", "...#", ".##."],
}


def tokens(text):
    out, i = [], 0
    while i < len(text):
        n = 2 if text[i] in "^_" else 1
        out.append(text[i:i + n])
        i += n
    return out


def width(text):
    return sum(len(G[t][0]) + 1 for t in tokens(text)) - 1


def carve(im, text, cx, y0, gold=-1):
    """Cut `text` centred on column `cx`, its top at row `y0`; the character
    at index `gold` (of its tokens) set in gold instead of cut."""
    x = cx - width(text) // 2
    cut, inlay = set(), set()
    for i, t in enumerate(tokens(text)):
        rows = G[t]
        dy = -1 if t.startswith("^") else 0      # powers sit high
        for r, row in enumerate(rows):
            for c, ch in enumerate(row):
                if ch == "#":
                    (inlay if i == gold else cut).add((x + c, y0 + dy + r))
        x += len(rows[0]) + 1
    stone = lambda q: im.getpixel(q)[3] == 255 and im.getpixel(q) != INK and q not in cut and q not in inlay
    for p in cut:
        im.putpixel(p, INK)
    # The gold is set down in a cut, not laid on the rock: light comes from
    # the top left, so the cut's walls on those sides are in shadow -- dark
    # over and left of each stroke -- and the gold itself stays bright. (The
    # first try shaded under the gold instead, which read as a drop shadow:
    # raised; shading the gold's own top turned its thin strokes brown.)
    for (px, py) in inlay:
        im.putpixel((px, py), GOLD)
        for q in ((px, py - 1), (px - 1, py)):
            if stone(q):
                im.putpixel(q, INK)
    # Under each stroke, cut or gold: the pale lip where the light catches.
    for (px, py) in cut | inlay:
        q = (px, py + 1)
        if stone(q):
            im.putpixel(q, LIP)
    # A glint low on the gold, where the light reaches into the cut.
    if inlay:
        im.putpixel(max(inlay, key=lambda p: (p[1], -p[0])), GLINT)


def rock(name, flip, cuts):
    """The pack's rock `name`, mirrored if `flip`, with each (text, centre
    column, top row, gold index) of `cuts` carved in."""
    im = Image.open(os.path.join(SRC, name + ".png")).convert("RGBA")
    if flip:
        im = ImageOps.mirror(im)
    for text, cx, y, gold in cuts:
        carve(im, text, cx, y, gold)
    return im


# Where each rock's faces are, on its own 64px grid (mirrored: 63 - x):
#   Rock4  top 13-35 x 20-31, front 20-43 x 36-48     (big)
#   Rock3  lit face 24-45 x 26-42                        (broad)
#   Rock2  top 16-47 x 26-33                             (wide, low)
#   Rock1  top 24-38 x 25-34                             (small)
# Each island its station's signs, a different set of rocks on each, and one
# character in gold on every rock -- a different one each time.
PIECES = {
    # Blue, Station 1: the four operations.
    "blue_a": ("Rock4", False, [("+ -", 24, 21, -1), ("x /", 32, 38, 0)]),
    "blue_b": ("Rock2", False, [("3+4=7", 32, 28, 3)]),
    "blue_c": ("Rock1", True, [("+", 32, 29, 0)]),
    # Yellow, Station 2: the order -- brackets first, then x and /.
    "yellow_a": ("Rock3", False, [("(x)", 33, 29, 1)]),
    "yellow_b": ("Rock2", True, [("2+3x4", 32, 28, 1)]),
    # Red, Station 3: powers.
    "red_a": ("Rock4", True, [("v^2", 39, 22, 1), ("2^3", 33, 38, -1)]),
    "red_b": ("Rock2", False, [("2^3=8", 32, 26, 3)]),
    "red_c": ("Rock3", False, [("4^2", 35, 27, -1), ("16", 31, 35, 1)]),
    "red_d": ("Rock1", False, [("_9", 31, 30, 0)]),
    # More of them (client: "add more rocks ... one on each of the first
    # island's three plateaus, and the rest everywhere, the base camp too").
    # Station 1 -- the plateaus, then the ground.
    "blue_p1": ("Rock1", False, [("-", 32, 29, 0)]),
    "blue_p2": ("Rock1", True, [("x", 32, 29, 0)]),
    "blue_p3": ("Rock3", False, [("7+1", 33, 29, 1)]),
    "blue_d": ("Rock3", False, [("8-3", 32, 29, 1)]),
    "blue_e": ("Rock2", True, [("9-4=5", 32, 28, 4)]),
    # Station 2.
    "yellow_c": ("Rock4", False, [("( )", 24, 21, -1), ("2x3", 32, 38, 1)]),
    "yellow_d": ("Rock1", True, [("=", 32, 29, 0)]),
    "yellow_e": ("Rock2", False, [("(1+2)", 33, 28, 0)]),
    # Station 3.
    "red_e": ("Rock2", True, [("3^2=9", 32, 27, 1)]),
    "red_f": ("Rock1", True, [("2^2", 32, 29, 1)]),
    "red_g": ("Rock3", False, [("6^2", 35, 27, -1), ("36", 31, 35, 0)]),
    # Base Camp: a little of every station, the first rocks anyone sees.
    "camp_a": ("Rock3", False, [("v^2", 33, 29, 1)]),
    "camp_b": ("Rock2", True, [("1+1=2", 32, 27, 4)]),
}


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".png") and f[:-4] not in PIECES:
            os.remove(os.path.join(OUT, f))
            if os.path.exists(os.path.join(OUT, f + ".import")):
                os.remove(os.path.join(OUT, f + ".import"))
    for name, (src, flip, cuts) in PIECES.items():
        im = rock(src, flip, cuts)
        im.save(os.path.join(OUT, name + ".png"))
        print("wrote", os.path.join(OUT, name + ".png"))


if __name__ == "__main__":
    main()

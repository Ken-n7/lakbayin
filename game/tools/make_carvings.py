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
# and they vary every rock"): the gold, its shade where the cut falls away,
# and a glint.
GOLD = (0xF2, 0xC1, 0x4E, 255)
GOLD_DEEP = (0x9C, 0x6A, 0x1A, 255)
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
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "6": [".###.", "#....", "#....", "####.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "....#", ".###."],
    "^2": ["###", "..#", "###", "#..", "###"],
    "^3": ["###", "..#", "###", "..#", "###"],
    " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
}


def tokens(text):
    out, i = [], 0
    while i < len(text):
        n = 2 if text[i] == "^" else 1
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
    for p in cut:
        im.putpixel(p, INK)
    for p in inlay:
        im.putpixel(p, GOLD)
    # Under each stroke: the pale lip of a cut, or the gold's own shade.
    for (px, py) in cut | inlay:
        q = (px, py + 1)
        if q in cut or q in inlay or im.getpixel(q)[3] != 255 or im.getpixel(q) == INK:
            continue
        im.putpixel(q, GOLD_DEEP if (px, py) in inlay else LIP)
    # A glint on the gold's first stroke, top left.
    if inlay:
        im.putpixel(min(inlay, key=lambda p: (p[1], p[0])), GLINT)


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
    "blue_c": ("Rock1", True, [("+", 32, 26, 0)]),
    # Yellow, Station 2: the order -- brackets first, then x and /.
    "yellow_a": ("Rock3", False, [("(x)", 33, 29, 1)]),
    "yellow_b": ("Rock2", True, [("2+3x4", 32, 28, 1)]),
    # Red, Station 3: powers.
    "red_a": ("Rock4", True, [("v^2", 39, 22, 1), ("2^3", 33, 38, -1)]),
    "red_b": ("Rock2", False, [("2^3=8", 32, 29, 3)]),
    "red_c": ("Rock3", False, [("4^2", 35, 27, -1), ("16", 31, 35, 1)]),
    "red_d": ("Rock1", False, [("9", 31, 26, 0)]),
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

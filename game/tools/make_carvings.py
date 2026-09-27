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
order they are done in -- ( ) first, then x and / -- Red powers. One big rock
(Rock4, its top and its front face) and one small (Rock2, its top) each.

Idempotent. Run from game/ with Pillow installed:

    python3 tools/make_carvings.py
"""
import os

from PIL import Image, ImageOps

SRC = "assets/terrain/decorations/"
OUT = "assets/terrain/decorations/math"

INK = (0x16, 0x1C, 0x2E, 255)       # the pack's outline and cracks
LIP = (0xB6, 0xE2, 0xE0, 255)       # a touch lighter than its lightest stone

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


def carve(im, text, cx, y0):
    """Cut `text` centred on column `cx`, its top at row `y0`."""
    x = cx - width(text) // 2
    cut = set()
    for t in tokens(text):
        rows = G[t]
        dy = -1 if t.startswith("^") else 0      # powers sit high
        for r, row in enumerate(rows):
            for c, ch in enumerate(row):
                if ch == "#":
                    cut.add((x + c, y0 + dy + r))
        x += len(rows[0]) + 1
    for p in cut:
        im.putpixel(p, INK)
    # The lip: under each stroke, where the stone is still stone.
    for px, py in cut:
        q = (px, py + 1)
        if q not in cut and im.getpixel(q)[3] == 255 and im.getpixel(q) != INK:
            im.putpixel(q, LIP)


def rock(name, flip, cuts):
    im = Image.open(os.path.join(SRC, name + ".png")).convert("RGBA")
    if flip:
        im = ImageOps.mirror(im)
    for text, cx, y in cuts:
        carve(im, text, cx, y)
    return im


def main():
    os.makedirs(OUT, exist_ok=True)
    # Rock4's faces: its light top (columns 13-35, rows 20-31; 28-50 when
    # mirrored) and its front (columns 20-43, rows 36-48; 20-43 mirrored).
    # Rock2's light top: columns 16-47, rows 26-33.
    pieces = {
        "rock_blue.png": rock("Rock4", False, [("+ -", 24, 21), ("x /", 32, 38)]),
        "rock_yellow.png": rock("Rock4", True, [("( )", 39, 21), ("x /", 30, 38)]),
        "rock_red.png": rock("Rock4", False, [("v^2", 24, 22), ("2^3", 32, 39)]),
        "stone_blue.png": rock("Rock2", False, [("3+4=7", 32, 28)]),
        "stone_yellow.png": rock("Rock2", True, [("2+3x4", 32, 28)]),
        "stone_red.png": rock("Rock2", False, [("2^3=8", 32, 29)]),
    }
    for name, im in pieces.items():
        im.save(os.path.join(OUT, name))
        print("wrote", os.path.join(OUT, name), im.size)


if __name__ == "__main__":
    main()

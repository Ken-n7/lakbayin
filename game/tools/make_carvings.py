#!/usr/bin/env python3
"""Rocks with maths carved into them -- standing rocks and flat ones in the grass, for the menus'
scene (client, 2026-09-27: math "etched on some assets").

Drawn pixel by pixel in the Tiny Swords rocks' own four stone colours and
their way of drawing -- jagged outlines, lit facets, dark cracks where the
facets meet -- so they sit in the pack as natural rock, not dressed stone. Each island carries its station's
signs: Blue the four operations, Yellow the order they are done in -- ( ),
then x and /, then + and - -- Red the powers. The carving is a groove in the
darkest stone with a light lip under it, where the light catches the cut.

Idempotent. Run from game/ with Pillow installed:

    python3 tools/make_carvings.py
"""
import os

from PIL import Image

OUT = "assets/terrain/decorations/math"

# The stone of Rock1-4, lightest to the outline.
LIGHT = (0x8C, 0xC3, 0xC4, 255)
MID = (0x66, 0x9D, 0x9D, 255)
DARK = (0x50, 0x6A, 0x69, 255)
LINE = (0x16, 0x1C, 0x2E, 255)
GROOVE = (0x1C, 0x28, 0x30, 255)
LIP = (0xD8, 0xF4, 0xF0, 255)
SHADOW = (0x10, 0x18, 0x20, 70)
# The stations' liveries, for the inlay on each stone's head.
INLAY = {"blue": (0x4A, 0x7C, 0xC9, 255), "yellow": (0xE6, 0xB4, 0x3C, 255),
         "red": (0xC8, 0x48, 0x3C, 255)}

# 5x7 glyphs, and 3x5 raised ones for powers (a leading "^").
G = {
    "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
    "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    "x": [".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "....."],
    "/": ["..#..", ".....", ".....", "#####", ".....", ".....", "..#.."],
    "=": [".....", ".....", "#####", ".....", "#####", ".....", "....."],
    "(": ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],
    ")": [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],
    "v": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],   # the letter x
    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
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
        if text[i] == "^":
            out.append(text[i:i + 2])
            i += 2
        else:
            out.append(text[i])
            i += 1
    return out


def width(text):
    return sum(len(G[t][0]) + 1 for t in tokens(text)) - 1


def carve(im, text, x0, y0):
    """Cut `text` into the stone at (x0, y0), the top of a 7-row line."""
    x = x0
    for t in tokens(text):
        rows = G[t]
        dy = -1 if t.startswith("^") else 0      # powers sit high
        for r, row in enumerate(rows):
            for c, ch in enumerate(row):
                if ch == "#":
                    im.putpixel((x + c, y0 + dy + r), GROOVE)
        # The lip: light on the stone just under each cut.
        for r, row in enumerate(rows):
            for c, ch in enumerate(row):
                below = rows[r + 1][c] if r + 1 < len(rows) else "."
                if ch == "#" and below != "#":
                    p = (x + c, y0 + dy + r + 1)
                    if im.getpixel(p) not in (GROOVE, LINE, (0, 0, 0, 0)):
                        im.putpixel(p, LIP)
        x += len(rows[0]) + 1


def _jag(seed, n, lo, hi):
    """`n` small whole-pixel offsets in [lo, hi], the same every run."""
    out, v = [], seed
    for _ in range(n):
        v = (v * 1103515245 + 12345) & 0x7FFFFFFF
        out.append(lo + v % (hi - lo + 1))
    return out


def _shade(im, mask, face):
    """Fill `mask` pixels with `face(x, y)`, outlined in the pack's ink."""
    w, h = im.size
    inside = lambda x, y: 0 <= x < w and 0 <= y < h and mask[y][x]
    for y in range(h):
        for x in range(w):
            if not mask[y][x]:
                continue
            edge = not (inside(x - 1, y) and inside(x + 1, y) and inside(x, y - 1) and inside(x, y + 1))
            im.putpixel((x, y), LINE if edge else face(x, y))


def _poly_mask(w, h, pts):
    from PIL import ImageDraw
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).polygon(pts, fill=1)
    return [[m.getpixel((x, y)) == 1 for x in range(w)] for y in range(h)]


def _shadow(im, cx, cy, rx, ry):
    w, h = im.size
    for y in range(h):
        for x in range(w):
            if im.getpixel((x, y))[3] == 0 and ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1:
                im.putpixel((x, y), SHADOW)


def _rock(w, h, facets, cracks, notches, seed):
    """A rock the way the pack draws one: facets of lit, mid and shaded stone,
    an ink outline that thickens on the shaded (bottom and right) side, and
    ink cracks with dark wedges where the facets meet. Points move by up to a
    pixel per `seed`, so no two rocks share an outline."""
    from PIL import ImageDraw
    # One offset per corner, shared by every facet meeting there -- moved
    # separately, neighbouring facets part and the grass shows through.
    j = _jag(seed, 400, -1, 1)
    moves = {}
    for pts, _ in facets:
        for p in pts:
            if p not in moves:
                n = len(moves)
                moves[p] = (j[2 * n], j[2 * n + 1])
    wob = lambda pts: [(x + moves[(x, y)][0], y + moves[(x, y)][1]) for x, y in pts]
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    moved = [(wob(pts), col) for pts, col in facets]
    for pts, col in moved:
        d.polygon(pts, fill=col)
    solid = lambda x, y: 0 <= x < w and 0 <= y < h and im.getpixel((x, y))[3] == 255
    edge = [(x, y) for y in range(h) for x in range(w) if solid(x, y) and not (
        solid(x - 1, y) and solid(x + 1, y) and solid(x, y - 1) and solid(x, y + 1))]
    for p in edge:
        im.putpixel(p, LINE)
    # The shaded side's heavier line: one more pixel in from the bottom/right.
    for x, y in edge:
        if not solid(x, y + 1) or not solid(x + 1, y):
            for q in ((x, y - 1), (x - 1, y)):
                if solid(*q) and im.getpixel(q) == DARK:
                    im.putpixel(q, LINE)
    for line in cracks:
        d.line(line, fill=LINE, width=1)
    for tri in notches:
        d.polygon(tri, fill=LINE)
    return im


def stele(lines, inlay, seed):
    """A standing rock, leaning a little: a lit crown and left shoulder, the
    broad front face the maths is cut into, the right side and foot in shade."""
    w, h = 42, 56
    crown = [(9, 9), (12, 6), (16, 2), (22, 3), (27, 1), (31, 6), (33, 12), (27, 14), (18, 12), (11, 14)]
    left = [(9, 9), (11, 14), (10, 24), (9, 36), (8, 46), (6, 49), (3, 42), (5, 32), (3, 22), (6, 13)]
    front = [(11, 14), (18, 12), (27, 14), (31, 20), (30, 32), (31, 44), (22, 47), (9, 46), (9, 36), (10, 24)]
    right = [(27, 14), (33, 12), (36, 20), (35, 30), (38, 40), (36, 48), (32, 51), (31, 44), (30, 32), (31, 20)]
    foot = [(8, 46), (9, 46), (22, 47), (31, 44), (32, 51), (22, 52), (12, 51), (6, 49)]
    im = _rock(w, h,
               [(crown, LIGHT), (left, LIGHT), (front, MID), (right, DARK), (foot, DARK)],
               [[(11, 14), (18, 12), (27, 14)], [(27, 14), (31, 20), (30, 32), (31, 44)],
                [(9, 46), (22, 47), (31, 44)], [(10, 24), (9, 30)], [(31, 6), (29, 9)]],
               [[(17, 12), (19, 12), (18, 15)], [(30, 31), (32, 33), (30, 34)], [(21, 47), (23, 47), (22, 50)]],
               seed)
    _shadow(im, w / 2, 52, w / 2 - 1, 3)
    # The station's colour, a chip of stone set in the crown.
    cx, cy = 21, 7
    for dy in range(-2, 3):
        for dx in range(-2 + abs(dy), 3 - abs(dy)):
            im.putpixel((cx + dx, cy + dy), inlay if abs(dx) + abs(dy) < 2 else GROOVE)
    # The maths, cut into the front face (x 12-28, clear of its seams).
    y = 17 if len(lines) == 3 else 20
    for line in lines:
        carve(im, line, 12 + (17 - width(line)) // 2, y)
        y += 9
    return im


def slab(text, seed):
    """A low rock in the grass, the maths cut into its top: the top lit, its
    front in shade, a crack or two."""
    tw = width(text)
    w, h = tw + 14, 23
    W = w
    top = [(3, 7), (8, 2), (int(W * .4), 3), (int(W * .6), 1), (W - 6, 3), (W - 2, 8), (W - 4, 14),
           (int(W * .5), 15), (6, 14), (1, 11)]
    lit = [(3, 7), (8, 2), (int(W * .4), 3), (int(W * .35), 4), (8, 4), (4, 9)]
    front = [(1, 11), (6, 14), (int(W * .5), 15), (W - 4, 14), (W - 2, 8), (W - 1, 14), (W - 4, 19),
             (int(W * .6), 20), (int(W * .3), 19), (4, 18), (0, 14)]
    im = _rock(w, h, [(top, MID), (lit, LIGHT), (front, DARK)],
               [[(6, 14), (int(W * .5), 15), (W - 4, 14)], [(W - 4, 14), (W - 2, 8)]],
               [[(int(W * .5) - 1, 15), (int(W * .5) + 1, 15), (int(W * .5), 18)]], seed)
    _shadow(im, w / 2, 20, w / 2, 2)
    carve(im, text, (w - tw) // 2, 5)
    return im


def main():
    os.makedirs(OUT, exist_ok=True)
    pieces = {
        "stele_blue.png": stele(["+ -", "x /"], INLAY["blue"], 11),
        "stele_yellow.png": stele(["( )", "x /", "+ -"], INLAY["yellow"], 23),
        "stele_red.png": stele(["v^2", "2^3", "4^2"], INLAY["red"], 37),
        "slab_blue.png": slab("3+4=7", 5),
        "slab_yellow.png": slab("2+3x4", 17),
        "slab_red.png": slab("2^3=8", 29),
    }
    for name, im in pieces.items():
        im.save(os.path.join(OUT, name))
        print("wrote", os.path.join(OUT, name), im.size)


if __name__ == "__main__":
    main()

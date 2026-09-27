#!/usr/bin/env python3
"""Standing stones and paving slabs with maths carved into them, for the menus'
scene (client, 2026-09-27: math "etched on some assets").

Drawn pixel by pixel in the Tiny Swords rocks' own four stone colours, so they
sit in the pack as if they came with it. Each island carries its station's
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
GROOVE = (0x2E, 0x40, 0x45, 255)
LIP = (0xB6, 0xE2, 0xE0, 255)
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


def stele(lines, inlay):
    """A standing stone, rounded head, light on the left, shade on the right,
    `lines` carved one under another, and the station's colour set in its head."""
    w, h = 27, 44
    body_h = h - 3
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    r = 7
    inside = lambda x, y: (y >= r or (x - r) ** 2 + (y - r) ** 2 <= r * r
                           or (x - (w - 1 - r)) ** 2 + (y - r) ** 2 <= r * r
                           or (r <= x <= w - 1 - r)) and 0 <= x < w and 0 <= y < body_h
    for y in range(body_h):
        for x in range(w):
            if not inside(x, y):
                continue
            edge = not (inside(x - 1, y) and inside(x + 1, y) and inside(x, y - 1) and inside(x, y + 1))
            if edge:
                col = LINE
            elif x <= 3 or y <= 2:
                col = LIGHT
            elif x >= w - 5:
                col = DARK
            else:
                col = MID
            im.putpixel((x, y), col)
    # The foot: a darker band where it stands in the grass, and its shadow.
    for x in range(1, w - 1):
        for y in range(body_h - 4, body_h - 1):
            if im.getpixel((x, y)) not in (LINE, (0, 0, 0, 0)):
                im.putpixel((x, y), DARK)
    for x in range(-2, w + 2):
        for y in range(body_h, h):
            if 0 <= x < w and (x - w / 2) ** 2 / (w / 2 + 2) ** 2 + (y - body_h) ** 2 / 9 <= 1:
                im.putpixel((x, y), SHADOW)
    # The inlay: a small diamond in the station's colour.
    cx, cy = w // 2, 5
    for dy in range(-2, 3):
        for dx in range(-2 + abs(dy), 3 - abs(dy)):
            im.putpixel((cx + dx, cy + dy), inlay if abs(dx) + abs(dy) < 2 else GROOVE)
    # The carving, centred, lines 9 rows apart from under the inlay.
    y = 11
    for line in lines:
        carve(im, line, (w - width(line)) // 2, y)
        y += 9
    return im


def slab(text):
    """A flat paving stone seen from above and a little in front: a top face
    carrying `text`, and its thickness below."""
    w = width(text) + 8
    h = 16
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    top, depth = 11, 3
    for y in range(h):
        for x in range(w):
            if y < top + depth:
                corner = (x in (0, w - 1) and y in (0, top + depth - 1))
                if corner:
                    continue
                edge = x in (0, w - 1) or y in (0, top + depth - 1)
                col = LINE if edge else (LIGHT if y <= 1 else MID if y < top else DARK)
                im.putpixel((x, y), col)
            elif y < top + depth + 2 and 1 <= x < w - 1:
                im.putpixel((x, y), SHADOW)
    carve(im, text, 4, 2)
    return im


def main():
    os.makedirs(OUT, exist_ok=True)
    pieces = {
        "stele_blue.png": stele(["+ -", "x /"], INLAY["blue"]),
        "stele_yellow.png": stele(["( )", "x /", "+ -"], INLAY["yellow"]),
        "stele_red.png": stele(["v^2", "2^3", "4^2"], INLAY["red"]),
        "slab_blue.png": slab("3+4=7"),
        "slab_yellow.png": slab("2+3x4"),
        "slab_red.png": slab("2^3=8"),
    }
    for name, im in pieces.items():
        im.save(os.path.join(OUT, name))
        print("wrote", os.path.join(OUT, name), im.size)


if __name__ == "__main__":
    main()

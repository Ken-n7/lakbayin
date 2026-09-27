#!/usr/bin/env python3
"""Rocks with maths carved into them -- standing rocks and flat ones in the
grass -- for the menus' scene (client, 2026-09-27: math "etched on some
assets", then "natural rocks with carves in them", then "the same resolution
as the Tiny Swords ones").

Drawn at the pack's own pixel size: the backdrop shows Tiny Swords' buildings,
ground and trees at 0.5, so these are drawn F = 2.6 times finer than their
first cut and shown at 0.5 too (`Backdrop.CARVING_SCALE`). The shapes are the
pack's way of drawing rock -- jagged outline, lit crown and left face, shaded
right and foot, an ink line heavier on the shaded side, cracks with dark
wedges -- in its rocks' four colours. The maths is cut in MedievalSharp, the
game's display face: a dark groove with a light lip under it.

Each island carries its station's signs: Blue the four operations, Yellow
the order they are done in -- ( ), then x and /, then + and - -- Red powers.

Idempotent. Run from game/ with Pillow installed:

    python3 tools/make_carvings.py
"""
import os

from PIL import Image, ImageDraw, ImageFont

OUT = "assets/terrain/decorations/math"
FONT = "assets/fonts/MedievalSharp.ttf"
F = 2.6            # detail over the first cut; shown at 0.5 in the backdrop

# The stone of Rock1-4, lightest to the outline.
LIGHT = (0x8C, 0xC3, 0xC4, 255)
MID = (0x66, 0x9D, 0x9D, 255)
DARK = (0x50, 0x6A, 0x69, 255)
LINE = (0x16, 0x1C, 0x2E, 255)
GROOVE = (0x1C, 0x28, 0x30, 255)
LIP = (0xD8, 0xF4, 0xF0, 255)
SHADOW = (0x10, 0x18, 0x20, 70)
INLAY = {"blue": (0x4A, 0x7C, 0xC9, 255), "yellow": (0xE6, 0xB4, 0x3C, 255),
         "red": (0xC8, 0x48, 0x3C, 255)}


def _jag(seed, n, lo, hi):
    """`n` small whole-pixel offsets in [lo, hi], the same every run."""
    out, v = [], seed
    for _ in range(n):
        v = (v * 1103515245 + 12345) & 0x7FFFFFFF
        out.append(lo + v % (hi - lo + 1))
    return out


def _s(pts):
    """First-cut coordinates to this resolution."""
    return [(round(x * F), round(y * F)) for x, y in pts]


def _shadow(im, cx, cy, rx, ry):
    w, h = im.size
    for y in range(h):
        for x in range(w):
            if im.getpixel((x, y))[3] == 0 and ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1:
                im.putpixel((x, y), SHADOW)


def _rock(w, h, facets, cracks, notches, seed):
    """A rock the way the pack draws one. Coordinates are the first cut's;
    corners move a little per `seed`, shared by every facet meeting there, so
    no two rocks share an outline and no facets part."""
    j = _jag(seed, 400, -1, 1)
    moves = {}
    for pts, _ in facets:
        for p in pts:
            if p not in moves:
                n = len(moves)
                moves[p] = (j[2 * n], j[2 * n + 1])
    wob = lambda pts: [(round((x + moves[(x, y)][0] * .6) * F), round((y + moves[(x, y)][1] * .6) * F))
                       for x, y in pts]
    W, H = round(w * F), round(h * F)
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for pts, col in facets:
        d.polygon(wob(pts), fill=col)
    solid = lambda x, y: 0 <= x < W and 0 <= y < H and im.getpixel((x, y))[3] == 255
    # The ink line: two pixels, the pack's weight at this size; three on the
    # shaded bottom and right.
    ring = set()
    for y in range(H):
        for x in range(W):
            if solid(x, y) and not all(solid(x + dx, y + dy) for dx, dy in
                                       ((-1, 0), (1, 0), (0, -1), (0, 1))):
                ring.add((x, y))
    inner = set()
    for x, y in ring:
        for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            q = (x + dx, y + dy)
            if solid(*q) and q not in ring:
                inner.add(q)
    heavy = set()
    for x, y in inner:
        if not solid(x, y + 2) or not solid(x + 2, y):
            for q in ((x, y - 1), (x - 1, y)):
                if solid(*q) and q not in ring and q not in inner:
                    heavy.add(q)
    for p in ring | inner | heavy:
        im.putpixel(p, LINE)
    for line in cracks:
        d.line(_s(line), fill=LINE, width=2)
    for tri in notches:
        d.polygon(_s(tri), fill=LINE)
    return im


def _glyphs(text, size):
    """`text` in the display face, hard-edged (no anti-aliasing: pixel art),
    thickened a pixel so the cut reads."""
    font = ImageFont.truetype(FONT, size)
    l, t, r, b = font.getbbox(text)
    m = Image.new("1", (r - l + 4, b - t + 4), 0)
    d = ImageDraw.Draw(m)
    d.fontmode = "1"
    d.text((2 - l, 2 - t), text, font=font, fill=1)
    w, h = m.size
    on = {(x, y) for y in range(h) for x in range(w) if m.getpixel((x, y))}
    on |= {(x + 1, y) for x, y in on}
    return on, w + 1, h


def carve(im, text, cx, top, size, fit_w=None):
    """Cut `text` centred on `cx`, its top at `top`; shrunk to `fit_w` if wide."""
    on, w, h = _glyphs(text, size)
    while fit_w and w > fit_w and size > 8:
        size -= 1
        on, w, h = _glyphs(text, size)
    x0 = round(cx - w / 2)
    inside = lambda p: 0 <= p[0] < im.width and 0 <= p[1] < im.height
    for x, y in on:
        p = (x0 + x, top + y)
        if inside(p) and im.getpixel(p)[3] == 255:
            im.putpixel(p, GROOVE)
    # The lip: light on the stone just under each cut.
    for x, y in on:
        if (x, y + 1) not in on:
            p = (x0 + x, top + y + 1)
            if inside(p) and im.getpixel(p)[3] == 255 and im.getpixel(p) not in (LINE, GROOVE):
                im.putpixel(p, LIP)
    return h


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
                [(9, 46), (22, 47), (31, 44)], [(11, 14), (10, 24), (9, 36), (8, 46), (7, 49)], [(31, 6), (29, 9)]],
               [[(17, 12), (19, 12), (18, 15)], [(30, 31), (32, 33), (30, 34)], [(21, 47), (23, 47), (22, 50)]],
               seed)
    _shadow(im, w * F / 2, 52 * F, w * F / 2 - F, 3 * F)
    # The station's colour, a chip of stone set in the crown.
    cx, cy, r = round(21 * F), round(7 * F), round(2.2 * F)
    d = ImageDraw.Draw(im)
    d.polygon([(cx, cy - r - 2), (cx + r + 2, cy), (cx, cy + r + 2), (cx - r - 2, cy)], fill=GROOVE)
    d.polygon([(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)], fill=inlay)
    im.putpixel((cx - 1, cy - r + 2), LIP)
    # The maths, cut into the front face (x 12-28 of the first cut).
    face_cx, face_w = 20.5 * F, 16 * F
    y = round((16 if len(lines) == 3 else 19) * F)
    for line in lines:
        # Signs alone are drawn small in the face; cut them larger than
        # numbers so the line reads at the same weight.
        signs = not any(c.isalnum() for c in line)
        carve(im, line, face_cx, y - (round(1.5 * F) if signs else 0), round((12 if signs else 8.5) * F), face_w)
        y += round(9 * F)
    return im


def slab(text, seed):
    """A low rock in the grass, the maths cut into its top: the top lit, its
    front in shade, a crack or two."""
    size = round(8 * F)
    _, tw, _ = _glyphs(text, size)
    W = round(tw / F) + 12
    w, h = W, 23
    top = [(3, 7), (8, 2), (int(W * .4), 3), (int(W * .6), 1), (W - 6, 3), (W - 2, 8), (W - 4, 14),
           (int(W * .5), 15), (6, 14), (1, 11)]
    lit = [(3, 7), (8, 2), (int(W * .4), 3), (int(W * .35), 4), (8, 4), (4, 9)]
    front = [(1, 11), (6, 14), (int(W * .5), 15), (W - 4, 14), (W - 2, 8), (W - 1, 14), (W - 4, 19),
             (int(W * .6), 20), (int(W * .3), 19), (4, 18), (0, 14)]
    im = _rock(w, h, [(top, MID), (lit, LIGHT), (front, DARK)],
               [[(6, 14), (int(W * .5), 15), (W - 4, 14)], [(W - 4, 14), (W - 2, 8)]],
               [[(int(W * .5) - 1, 15), (int(W * .5) + 1, 15), (int(W * .5), 18)]], seed)
    _shadow(im, w * F / 2, 20 * F, w * F / 2, 2 * F)
    carve(im, text, w * F / 2, round(3.6 * F), size, (W - 10) * F)
    return im


def main():
    os.makedirs(OUT, exist_ok=True)
    pieces = {
        "stele_blue.png": stele(["+  −", "×  ÷"], INLAY["blue"], 11),
        "stele_yellow.png": stele(["(  )", "×  ÷", "+  −"], INLAY["yellow"], 23),
        "stele_red.png": stele(["x²", "2³", "4²"], INLAY["red"], 37),
        "slab_blue.png": slab("3+4=7", 5),
        "slab_yellow.png": slab("2+3×4", 17),
        "slab_red.png": slab("2³=8", 29),
    }
    for name, im in pieces.items():
        im.save(os.path.join(OUT, name))
        print("wrote", os.path.join(OUT, name), im.size)


if __name__ == "__main__":
    main()

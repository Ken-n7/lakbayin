#!/usr/bin/env python3
"""Redraw the glyphs of PixelifySans.ttf that cannot be told apart on their own.

The client: digits were hard to read. Letters looked fine -- but mostly because
the letters around them give them away. A join code, an answer or a single
digit on a circle has no neighbours to lean on, so every character has to
read alone. Stock Pixelify Sans draws O and 0 identically, Z as a 2 with a
flat top, B with a rounded back like 8, a hooked 6 like its G, a curled T that
reads as an arrow beside a curled 7, a 1 with no base, and a 3 that on a
phone filled in to an 8. Each is replaced
with the classic pixel form, on the face's own 5x7 grid and at its own width,
so no line of text in the game changes length.

Maths needs the same of its signs: the stock parentheses step in and out like
{ } -- "8 + (-3)" read as "8 + <-3>" -- and the superscript digits are the
stock shapes at half size, where the 2 of an exponent is a smudge. The
parentheses are redrawn as curves with a straight middle, and the
superscripts as a 3x5 digit set -- fewer, bigger pixels than the stock 5x7 at
half size, whose cells came out under a pixel at body size.

And no ligatures: the face joins fi, fl, ff, ffi and ffl into single glyphs,
and its "fi" is drawn so that "Enter Station 1 first" read "... Arst". Every
word is letters one at a time.

The five was the first (flat top, unlike S); the rest followed.

Idempotent: re-running redraws the same shapes. Run from game/ with
fonttools installed:

    python3 tools/fix_glyphs.py
"""
import bisect
import pathlib

from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.ttGlyphPen import TTGlyphPen

FONT = "assets/fonts/PixelifySans.ttf"

# The face is a 5x7 pixel grid; these are the cell boundaries in font units,
# read off the untouched glyphs (x left->right, y bottom->top).
X = [60, 151, 241, 332, 423, 525]
Y = [-12, 78, 169, 260, 350, 440, 530, 631]
# The superscripts' 3x5 grid, top-aligned with the capitals, and the
# parentheses' 3x10 one (which runs from below the baseline to above the
# capitals); the right parenthesis sits 30 units further left, as the stock
# one does.
SUP_X = [60, 130, 200, 270]
SUP_Y = [281, 351, 421, 491, 561, 631]
PAREN_Y = [-160, -68, 24, 115, 207, 299, 390, 482, 574, 665, 757]
GRIDS = {
    "main": (X, Y),
    "sup": (SUP_X, SUP_Y),
    "paren_l": ([60, 154, 249, 343], PAREN_Y),
    "paren_r": ([30, 124, 219, 313], PAREN_Y),
}
BLEED = 6  # cells overlap slightly so the rasteriser leaves no hairline seams

# Written top-down. A glyph narrower than five columns (the one) keeps its
# own advance width -- only its outline is redrawn.
GLYPHS = {
    "five": [
        "#####",
        "#....",
        "#....",
        "####.",
        "....#",
        "#...#",
        ".###.",
    ],
    # Slashed: the one change that makes a zero never an O.
    "zero": [
        ".###.",
        "#...#",
        "#..##",
        "#.#.#",
        "##..#",
        "#...#",
        ".###.",
    ],
    # A flag and a base, so it is neither I (bars) nor l (a bare stem).
    "one": [
        ".#.",
        "##.",
        ".#.",
        ".#.",
        ".#.",
        ".#.",
        "###",
    ],
    # Round top, flat base -- the Z is the other way about.
    "two": [
        ".###.",
        "#...#",
        "....#",
        "...#.",
        "..#..",
        ".#...",
        "#####",
    ],
    # Open all down the left, where 8 and B are solid: the stock 3 kept
    # pixels at the ends of both curves, and on a phone it read as an 8.
    "three": [
        "####.",
        "....#",
        "....#",
        ".###.",
        "....#",
        "....#",
        "####.",
    ],
    # Open at the top right, where the G is closed.
    "six": [
        ".###.",
        "#....",
        "#....",
        "####.",
        "#...#",
        "#...#",
        ".###.",
    ],
    "seven": [
        "#####",
        "....#",
        "...#.",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
    ],
    # The six turned over.
    "nine": [
        ".###.",
        "#...#",
        "#...#",
        ".####",
        "....#",
        "....#",
        ".###.",
    ],
    # A flat back: the stock B was rounded on the left, an eight with a notch.
    "B": [
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#...#",
        "#...#",
        "####.",
    ],
    # The bar coming in from the right is what a six never has.
    "G": [
        ".###.",
        "#...#",
        "#....",
        "#.###",
        "#...#",
        "#...#",
        ".###.",
    ],
    # A flat bar across the top; the stock curl read as an arrow.
    "T": [
        "#####",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
    ],
    # Flat top, flat base, a diagonal between: nothing like the two.
    "Z": [
        "#####",
        "....#",
        "...#.",
        "..#..",
        ".#...",
        "#....",
        "#####",
    ],
    # A curve with a long straight middle: never < > or { }.
    "parenleft": [
        "..#",
        ".#.",
        ".#.",
        "#..",
        "#..",
        "#..",
        "#..",
        ".#.",
        ".#.",
        "..#",
    ],
}
GLYPHS["parenright"] = [row[::-1] for row in GLYPHS["parenleft"]]

# Exponents: the classic 3x5 digits, each still telling 0/8, 2/Z-like and
# 6/9 apart at a size where a 5x7 digit is mush.
SUPERS = {
    "uni2070": ["###", "#.#", "#.#", "#.#", "###"],
    "uni00B9": [".#.", "##.", ".#.", ".#.", "###"],
    "uni00B2": ["##.", "..#", ".#.", "#..", "###"],
    "uni00B3": ["##.", "..#", ".#.", "..#", "##."],
    "uni2074": ["#.#", "#.#", "###", "..#", "..#"],
    "uni2075": ["###", "#..", "##.", "..#", "##."],
    "uni2076": [".##", "#..", "###", "#.#", "###"],
    "uni2077": ["###", "..#", ".#.", ".#.", ".#."],
    "uni2078": ["###", "#.#", "###", "#.#", "###"],
    "uni2079": ["###", "#.#", "###", "..#", "##."],
}
GLYPHS.update(SUPERS)


def grid_of(name: str) -> tuple:
    if name in SUPERS:
        return GRIDS["sup"]
    if name == "parenleft":
        return GRIDS["paren_l"]
    if name == "parenright":
        return GRIDS["paren_r"]
    return GRIDS["main"]


def main() -> None:
    font = TTFont(FONT)
    for name, rows in GLYPHS.items():
        gx, gy = grid_of(name)
        pen = TTGlyphPen(None)
        for row, bits in enumerate(rows):
            top = len(rows) - 1 - row  # written top-down, Y is bottom-up
            for col, bit in enumerate(bits):
                if bit != "#":
                    continue
                x0 = max(gx[col] - BLEED, gx[0])
                x1 = min(gx[col + 1] + BLEED, gx[len(bits)])
                y0 = max(gy[top] - BLEED, gy[0])
                y1 = min(gy[top + 1] + BLEED, gy[-1])
                pen.moveTo((x0, y0))
                pen.lineTo((x1, y0))
                pen.lineTo((x1, y1))
                pen.lineTo((x0, y1))
                pen.closePath()
        font["glyf"][name] = pen.glyph()
        # gvar deltas are indexed by point, and the point count just changed.
        # The game never asks for a weight other than the 400 default, so drop
        # them rather than redrawing bold forms nobody renders.
        font["gvar"].variations.pop(name, None)

    _drop_ligatures(font)
    font.save(FONT)
    for name in GLYPHS:
        _verify(name)
    assert not _ligatures(TTFont(FONT)), "ligatures still in the font"

    # The game loads .godot/imported/*.fontdata, never the .ttf, so a patched
    # font with a warm cache still draws the old glyphs. Drop the cache entry
    # and Godot rebuilds it on next launch.
    stale = list(pathlib.Path(".godot/imported").glob("PixelifySans.ttf-*"))
    for path in stale:
        path.unlink()
    print(f"patched {len(GLYPHS)} glyphs in {FONT}; dropped {len(stale)} cached import file(s)")


def _ligatures(font: TTFont) -> list:
    """The `liga` feature's ligature subtables -- the ones a shaper applies
    unasked. (Fractions and `dlig` only happen on request, so they stay.)"""
    gsub = font["GSUB"].table
    out = []
    for rec in gsub.FeatureList.FeatureRecord:
        if rec.FeatureTag != "liga":
            continue
        for i in rec.Feature.LookupListIndex:
            lookup = gsub.LookupList.Lookup[i]
            for st in lookup.SubTable:
                t = st.ExtSubTable if lookup.LookupType == 7 else st
                if getattr(t, "ligatures", None):
                    out.append(t)
    return out


def _drop_ligatures(font: TTFont) -> None:
    for t in _ligatures(font):
        t.ligatures = {}


def _verify(name: str) -> None:
    """Re-read the saved file and rebuild the grid from the contours --
    catches a bad bleed, a wrong grid constant, or a stock font dropped back in
    on top (whose curves land nowhere near a cell corner)."""
    rows = GLYPHS[name]
    width = len(rows[0])
    gx, gy = grid_of(name)
    pen = RecordingPen()
    TTFont(FONT).getGlyphSet()[name].draw(pen)
    cells, cur = set(), []
    for op, args in pen.value:
        if op == "moveTo":
            cur = [args[0]]
        elif op == "lineTo":
            cur.append(args[0])
        elif op == "closePath":
            xs = sorted({p[0] for p in cur})
            ys = sorted({p[1] for p in cur})
            assert len(cur) == 4 and len(xs) == 2 and len(ys) == 2, f"{name}: not a rect: {cur}"
            # Undo the bleed to land back on the cell this box was drawn for.
            col = bisect.bisect_right(gx, xs[0] + BLEED) - 1
            row = bisect.bisect_right(gy, ys[0] + BLEED) - 1
            assert (xs[1], ys[1]) == (min(gx[col + 1] + BLEED, gx[width]),
                                      min(gy[row + 1] + BLEED, gy[-1])), f"{name}: bad box: {cur}"
            cells.add((len(rows) - 1 - row, col))
    got = ["".join("#" if (r, c) in cells else "." for c in range(width))
           for r in range(len(rows))]
    assert got == rows, name + "\n" + "\n".join(got)


if __name__ == "__main__":
    main()

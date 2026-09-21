#!/usr/bin/env python3
"""Redraw the `5` in PixelifySans.ttf so it stops reading as an `S`.

Stock Pixelify Sans draws five as `.###. / #...# / #...# / .#... / ..##. /
#...# / .###.` -- rounded top *and* bottom, same as S, three and eight. In a
maths game where digits carry the meaning that is unacceptable, so the glyph
is replaced with the classic flat-top pixel five. The flat top bar is unique
in this face, which is exactly what makes it legible at 14px.

Idempotent-ish: re-running on an already patched font just redraws the same
shape. Run from the repo with fonttools installed:

    python3 tools/fix_five_glyph.py
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
BLEED = 6  # cells overlap slightly so the rasteriser leaves no hairline seams

FIVE = [
    "#####",
    "#....",
    "#....",
    "####.",
    "....#",
    "#...#",
    ".###.",
]


def main() -> None:
    font = TTFont(FONT)
    pen = TTGlyphPen(None)
    for row, bits in enumerate(FIVE):
        top = 6 - row  # FIVE is written top-down, Y is bottom-up
        for col, bit in enumerate(bits):
            if bit != "#":
                continue
            x0 = max(X[col] - BLEED, X[0])
            x1 = min(X[col + 1] + BLEED, X[-1])
            y0 = max(Y[top] - BLEED, Y[0])
            y1 = min(Y[top + 1] + BLEED, Y[-1])
            pen.moveTo((x0, y0))
            pen.lineTo((x1, y0))
            pen.lineTo((x1, y1))
            pen.lineTo((x0, y1))
            pen.closePath()
    font["glyf"]["five"] = pen.glyph()

    # gvar deltas are indexed by point, and the point count just changed. The
    # game never asks for a weight other than the 400 default, so drop them
    # rather than redrawing a bold five nobody renders.
    font["gvar"].variations.pop("five", None)

    font.save(FONT)
    _verify()

    # The game loads .godot/imported/*.fontdata, never the .ttf, so a patched
    # font with a warm cache still draws the old five. Drop the cache entry and
    # Godot rebuilds it on next launch.
    stale = list(pathlib.Path(".godot/imported").glob("PixelifySans.ttf-*"))
    for path in stale:
        path.unlink()
    print(f"patched five in {FONT}; dropped {len(stale)} cached import file(s)")


def _verify() -> None:
    """Re-read the saved file and rebuild the 5x7 grid from the contours --
    catches a bad bleed, a wrong grid constant, or a stock font dropped back in
    on top (whose curves land nowhere near a cell corner)."""
    pen = RecordingPen()
    TTFont(FONT).getGlyphSet()["five"].draw(pen)
    cells, cur = set(), []
    for op, args in pen.value:
        if op == "moveTo":
            cur = [args[0]]
        elif op == "lineTo":
            cur.append(args[0])
        elif op == "closePath":
            xs = sorted({p[0] for p in cur})
            ys = sorted({p[1] for p in cur})
            assert len(cur) == 4 and len(xs) == 2 and len(ys) == 2, f"not a rect: {cur}"
            # Undo the bleed to land back on the cell this box was drawn for.
            col = bisect.bisect_right(X, xs[0] + BLEED) - 1
            row = bisect.bisect_right(Y, ys[0] + BLEED) - 1
            assert (xs[1], ys[1]) == (min(X[col + 1] + BLEED, X[-1]),
                                      min(Y[row + 1] + BLEED, Y[-1])), f"bad box: {cur}"
            cells.add((6 - row, col))  # FIVE is written top-down, Y is bottom-up
    got = ["".join("#" if (r, c) in cells else "." for c in range(5)) for r in range(7)]
    assert got == FIVE, "\n".join(got)


if __name__ == "__main__":
    main()

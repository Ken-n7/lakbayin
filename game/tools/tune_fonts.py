#!/usr/bin/env python3
"""Trims Patrick Hand's line box to the height the game was laid out for.

Patrick Hand (the text face, `Art.TEXT_FONT`) reserves 1042 units above the
baseline in a 1000-unit em, but nothing the game shows reaches past 877 --
ASCII, Latin-1 (so ñ and é), superscripts and maths signs; the rest is empty
space over every line. The few taller glyphs (stacked-accent capitals like
Vietnamese Ắ) are still drawn in full: a label paints a glyph past its line
box rather than clipping it, so they only sit closer to the line above. Its line height came to 1.35 em
against the 1.20 the old pixel face had, which pushed the two fullest screens
(Game Controls, Feedback) 5-8px off the canvas. Ascent 900 makes it 1.21 and
still clears every glyph -- the script checks that before it saves.

The SIL OFL permits modified versions; Patrick Hand has no Reserved Font
Name, so the name stays. Idempotent. Run from the repo root:

    python3 game/tools/tune_fonts.py
"""
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.ttLib import TTFont

FONT = Path(__file__).resolve().parent.parent / "assets/fonts/PatrickHand-Regular.ttf"
ASCENT = 900

font = TTFont(FONT)
glyphs = font.getGlyphSet()
top = 0.0
for name in font.getGlyphOrder():
    pen = BoundsPen(glyphs)
    glyphs[name].draw(pen)
    if pen.bounds:
        top = max(top, pen.bounds[3])
cmap = font.getBestCmap()
SHOWN = [range(0x20, 0x7F), range(0xA0, 0x100), range(0x2070, 0x20A0), range(0x2200, 0x2300)]
shown = 0.0
for code, name in cmap.items():
    if any(code in r for r in SHOWN):
        pen = BoundsPen(glyphs)
        glyphs[name].draw(pen)
        if pen.bounds:
            shown = max(shown, pen.bounds[3])
assert shown <= ASCENT, f"a glyph reaches {shown}, over the {ASCENT} ascent"
font["hhea"].ascent = ASCENT
font["OS/2"].sTypoAscender = ASCENT
font["OS/2"].usWinAscent = ASCENT
font.save(FONT)
print(f"{FONT.name}: ascent {ASCENT} (tallest glyph shown {shown:.0f}, any glyph {top:.0f})")

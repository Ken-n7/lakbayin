class_name Pal
extends RefCounted

## The look, in one file: every colour, every font size, the canvas it is all
## laid out against. Nothing here draws anything -- see `Art.gd` for that and
## `Ui.gd` for the widgets.
##
## Before this existed the screens carried 95 raw `Color(...)` literals between
## them, which is how `5a4632` and `5a4630` -- the same intended brown -- came
## to sit in two different files. Change a colour here and it changes
## everywhere it means the same thing.

# --- Canvas -----------------------------------------------------------------
## The design resolution every screen is laid out against (project.godot
## `display/window/size/viewport_*`). The window override is 2x this for
## desktop runs; the stretch mode scales, so these are the only numbers any
## layout should use.
const CANVAS := Vector2(640.0, 360.0)
const MID := Vector2(320.0, 180.0)

# --- Parchment and ink ------------------------------------------------------
## Cream. Text that sits on the dark board or on a wooden button -- map signage,
## HUD labels, the focus ring. The most-used colour on the project.
const CREAM := Color("ffe9a8")
## The darkest brown. Body text on a paper panel.
const INK := Color("2a201a")
## One step lighter. Panel titles and the text caret.
const TITLE := Color("3a2c22")
## Muted brown for secondary rows and captions. (Was `5a4632` in one file and
## `5a4630` in another; they were meant to be the same colour.)
const INK_MUTED := Color("5a4632")
## The paper a text field is printed on.
const PAPER := Color("f7ecd2")
## The parchment a panel is printed on.
const PARCHMENT := Color("f1e2bd")
## Panel and field borders, and the lowest gem tier.
const WOOD := Color("8a6a3a")

# --- Accents ----------------------------------------------------------------
## Gems, the gold rule, a focused field's border.
const AMBER := Color("e09a1f")
const GOLD := Color("f4b93e")
## The middle gem tier on the leaderboard.
const GOLD_DIM := Color("b9831a")
## A heading printed on parchment, where CREAM would vanish.
const BRONZE := Color("7a5216")
## Right answer / wrong answer. Also the two result overlays.
const CORRECT := Color("3f7a1e")
const WRONG := Color("b03a1e")
## The same warning on dark wood, where WRONG is too dark to read: the HUD
## clock's last minute.
const WRONG_BRIGHT := Color("ff6b5a")
const CORRECT_BRIGHT := Color("7ee35a")
## The leaderboard podium's three steps.
const PODIUM := [Color("f4b93e"), Color("b9c2cc"), Color("c98a4b")]
## Station blue, for topic lines and the Learn tabs.
const INFO := Color("3a5a8c")
const INFO_DEEP := Color("1c5b8c")

# --- Surfaces ---------------------------------------------------------------
## The app background, behind every screen (also project.godot's boot splash
## and default clear colour).
const BG := Color(0.10, 0.08, 0.13)
## The scrim a panel is laid over. One value: the five screens that each dim
## the board had four different alphas between them, none of them deliberate.
const DIM := Color(0.10, 0.07, 0.12, 0.90)

# --- Text on dark -----------------------------------------------------------
const WHITE := Color(1, 1, 1)
const WHITE_STRONG := Color(1, 1, 1, 0.96)
const WHITE_SOFT := Color(1, 1, 1, 0.85)
const WHITE_DIM := Color(1, 1, 1, 0.75)
const WHITE_FAINT := Color(1, 1, 1, 0.45)
## Drop shadow behind text that has to read over artwork.
const SHADOW := Color(0, 0, 0, 0.6)

# --- Font sizes -------------------------------------------------------------
## A scale, not a free choice. Note `Art.MIN_FONT` (14) is a hard floor applied
## in `Art.label()`, `Ui.button()` and `Ui.line_edit()`, so SMALL and TINY both
## render at 14 today -- they still say which is which, and raising the floor
## after a real-device read is the one knob that moves them.
const LOGO := 44
const H1 := 26
const H2 := 18
const BODY := 15
const LABEL := 14
const SMALL := 13
const TINY := 11

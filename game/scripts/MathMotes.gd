class_name MathMotes
extends Node2D

## Math drifting over the menus' scene (client, 2026-09-27: "math stuff in the
## background"). Signs and numbers rise slowly out of the sea like lantern
## light, sway a little, and fade out before they reach the top -- then start
## again from below. The first step of maths in the art; the map may follow.
##
## Deliberately quiet: a few at a time, in the display face, pale gold, under
## the backdrop's dark wash like everything else in it. The parchment panels in
## front have to read first; these are atmosphere.
##
## A fixed composition (a seeded generator, so every launch is the same), like
## the rest of the backdrop. Drawn in one `_draw`: a handful of strings a frame.

const GLYPHS := ["+", "−", "×", "÷", "=", "π", "√", "x²", "½", "∞", "%", "≠",
		"3", "7", "2³", "(−2)", "9", "4²", "a+b", "0"]
const COUNT := 28
const RISE := [7.0, 13.0]          # world px per second
const SIZES := [18, 32]            # font sizes, small to large
const ALPHA := 1.0                # at their brightest, before the wash
const COLOR := Color("ffe9a8")     # pale gold, the colour of lamplight
const SEED := 20260927

var area: Vector2                  # the world they drift over, in px
var _font: Font
var _motes: Array = []             # {text, x, y0, speed, phase, size}
var _t := 0.0


func _init(world_size: Vector2) -> void:
	area = world_size


func _ready() -> void:
	_font = load(Art.TITLE_FONT)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in COUNT:
		_motes.append({
			"text": GLYPHS[i % GLYPHS.size()],
			# Spread evenly across the width, jittered, so no stretch of the
			# pan is ever empty or crowded.
			"x": (i + rng.randf_range(0.15, 0.85)) * area.x / COUNT,
			"phase": rng.randf(),                  # how far up it starts
			"speed": rng.randf_range(RISE[0], RISE[1]),
			"size": rng.randi_range(SIZES[0], SIZES[1]),
			"sway": rng.randf_range(0.0, TAU),
		})


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


## Where mote `m` is at time `t`: its height as 0 (bottom) to 1 (top) of its
## climb, and its position. Pure, so a test can ask.
func place(m: Dictionary, t: float) -> Array:
	var climb := area.y + 40.0
	var p := fposmod(m.phase + t * m.speed / climb, 1.0)
	var pos := Vector2(m.x + sin(t * 0.5 + m.sway) * 6.0, area.y + 20.0 - p * climb)
	return [p, pos]


## In from nothing at the bottom, out to nothing near the top: never popping.
static func fade(p: float) -> float:
	return clampf(minf(p / 0.12, (1.0 - p) / 0.22), 0.0, 1.0)


func _draw() -> void:
	for m: Dictionary in _motes:
		var at: Array = place(m, _t)
		var a := fade(at[0]) * ALPHA
		if a <= 0.01:
			continue
		var size: int = m.size
		var w := _font.get_string_size(m.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var pos: Vector2 = at[1] - Vector2(w * 0.5, 0)
		# A soft dark edge, then the glyph: legible on sea and grass alike.
		draw_string_outline(_font, pos, m.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4,
				Color(0.1, 0.07, 0.05, a * 0.8))
		draw_string(_font, pos, m.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(COLOR, a))

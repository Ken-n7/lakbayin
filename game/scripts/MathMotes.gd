class_name MathMotes
extends Node2D

## Math drifting over the menus' scene (client, 2026-09-27: "math stuff in the
## background"). Signs and numbers drift slowly like lantern light, each its
## own way -- up, across, aslant, a few sinking -- on a gentle curve, leaning
## as they go; each fades in, drifts a while and fades out, then begins again
## somewhere new. The first step of maths in the art; the map may follow.
##
## Deliberately quiet: sixteen over the whole pan (client: "lessen it a bit"), in the display face, pale gold, under
## the backdrop's dark wash like everything else in it. The parchment panels in
## front have to read first; these are atmosphere.
##
## A fixed composition (a seeded generator, so every launch is the same), like
## the rest of the backdrop. Drawn in one `_draw`: a handful of strings a frame.

const GLYPHS := ["+", "−", "×", "÷", "=", "π", "√", "x²", "½", "∞", "%", "≠",
		"3", "7", "2³", "(−2)", "9", "4²", "a+b", "0"]
const COUNT := 16
const SPEED := [7.0, 13.0]         # world px per second
const TRAVEL := [120.0, 220.0]     # how far one drifts before it fades, px
const SIZES := [18, 32]            # font sizes, small to large
const ALPHA := 1.0                 # at their brightest, before the wash
const COLOR := Color("ffe9a8")     # pale gold, the colour of lamplight
const SEED := 20260927
const TILT := 0.18                 # how far one leans as it goes, radians

var area: Vector2                  # the world they drift over, in px
var _font: Font
var _motes: Array = []             # {text, lane, dir, bend, speed, travel, phase, size, spin}
var _t := 0.0


func _init(world_size: Vector2) -> void:
	area = world_size


func _ready() -> void:
	_font = load(Art.TITLE_FONT)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in COUNT:
		# Every way, not only up (client: "add more direction"): an even
		# spread of headings round the circle, jittered, a few more rising
		# than sinking so the scene still feels like it lifts.
		var heading := TAU * (i + rng.randf_range(0.2, 0.8)) / COUNT - PI * 0.5
		heading = lerp_angle(heading, -PI * 0.5, 0.25)
		_motes.append({
			"text": GLYPHS[i % GLYPHS.size()],
			# Its stretch of the pan, so none is ever empty or crowded.
			"lane": (i + 0.5) / COUNT,
			"dir": Vector2.from_angle(heading),
			"bend": rng.randf_range(-0.35, 0.35),      # a gentle curve
			"speed": rng.randf_range(SPEED[0], SPEED[1]),
			"travel": rng.randf_range(TRAVEL[0], TRAVEL[1]),
			"phase": rng.randf(),
			"size": rng.randi_range(SIZES[0], SIZES[1]),
			"spin": rng.randf_range(0.0, TAU),
		})


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


## Where mote `m` is at time `t`: how far along this drift it is, 0 to 1, its
## position, and its lean. Each drift starts somewhere new near its lane, so
## the same path never plays twice in a row. Pure, so a test can ask.
func place(m: Dictionary, t: float) -> Array:
	var run: float = m.phase + t * m.speed / m.travel
	var p := fposmod(run, 1.0)
	var n := floori(run)
	# Where this drift begins: in its lane, somewhere new each time, kept far
	# enough in that the whole drift stays over the scene.
	var reach: float = m.travel * 0.5 + 24.0
	var jx := _hash(n * 2 + int(m.spin * 1000.0)) - 0.5
	var jy := _hash(n * 2 + 1 + int(m.spin * 1000.0))
	var centre := Vector2(
		clampf(m.lane * area.x + jx * area.x / COUNT, reach, area.x - reach),
		lerpf(reach, area.y - reach, jy))
	var d: Vector2 = m.dir
	var side := Vector2(-d.y, d.x)
	var along: float = (p - 0.5) * m.travel
	var pos: Vector2 = centre + d * along + side * (m.bend * along * along / m.travel)
	var lean: float = sin(t * 0.6 + m.spin) * TILT
	return [p, pos, lean]


## A repeatable 0-1 from an integer: where each drift starts.
static func _hash(n: int) -> float:
	var v := (n * 1103515245 + 12345) & 0x7FFFFFFF
	v = (v ^ (v >> 13)) * 1274126177 & 0x7FFFFFFF
	return float(v % 10007) / 10006.0


## In from nothing, out to nothing: never popping.
static func fade(p: float) -> float:
	return clampf(minf(p / 0.2, (1.0 - p) / 0.25), 0.0, 1.0)


func _draw() -> void:
	for m: Dictionary in _motes:
		var at: Array = place(m, _t)
		var a := fade(at[0]) * ALPHA
		if a <= 0.01:
			continue
		var size: int = m.size
		var w := _font.get_string_size(m.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		draw_set_transform(at[1], at[2])
		var pos := Vector2(-w * 0.5, size * 0.35)
		# A soft dark edge, then the glyph: legible on sea and grass alike.
		draw_string_outline(_font, pos, m.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4,
				Color(0.1, 0.07, 0.05, a * 0.8))
		draw_string(_font, pos, m.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(COLOR, a))
	draw_set_transform(Vector2.ZERO)

class_name TowerSymbols
extends Node2D

## Maths circling a tower (client, 2026-09-27): a few of its station's signs,
## round its middle on a flat ellipse, the far side dimmer. When its question
## is answered they whirl faster and faster, then shoot off, each its own way,
## and are gone -- `burst()`.
##
## Half the size of the tower's number (PathCircle.NUMBER_SIZE), in the display
## face, pale gold with a dark edge like the signs drifting over the menus.
## Drawn in one `_draw`: a handful of strings a frame.

const SIZE := 16                     # half the number over the tower (32)
const COUNT := 4
const RADIUS := Vector2(30, 10)      # the ellipse: wide, flattened for the view
const SPIN := 0.9                    # radians a second, at rest
const WHIRL := 11.0                  # ... and at the top of the whirl
const WHIRL_S := 0.55                # the whirl, then the dash
const DASH_S := 0.6
const DASH_PX := 230.0               # how far one flies before it is gone
const COLOR := Color("ffe9a8")
## Each station's signs: the four operations, the order, powers.
const SIGNS := [["+", "−", "×", "÷"], ["(", ")", "×", "+"], ["x²", "2³", "4²", "√"]]

var station := 0
var _font: Font
var _t := 0.0
var _angle := 0.0
var _burst_t := -1.0                 # time since burst(); -1 at rest
var _dirs: Array[Vector2] = []       # each sign's way out, fixed at the dash


func _ready() -> void:
	_font = load(Art.TITLE_FONT)
	# Towers along the way do not all turn in step.
	_angle = float(get_instance_id() % 628) / 100.0


func bursting() -> bool:
	return _burst_t >= 0.0


## The question is answered: whirl, then scatter.
func burst() -> void:
	if bursting():
		return
	_burst_t = 0.0


func _process(delta: float) -> void:
	_t += delta
	var spin := SPIN
	if bursting():
		_burst_t += delta
		# Up to speed across the whirl, eased in so it winds up.
		spin = lerpf(SPIN, WHIRL, clampf(_burst_t / WHIRL_S, 0.0, 1.0) ** 2)
		if _burst_t >= WHIRL_S and _dirs.is_empty():
			_fix_dirs()
		if _burst_t >= WHIRL_S + DASH_S:
			queue_free()
			return
	_angle += spin * delta
	queue_redraw()


## Straight out from where each one is at the moment it leaves, turned a
## little so no two go quite the way their neighbours do.
func _fix_dirs() -> void:
	for i in COUNT:
		var a := _angle + TAU * i / COUNT + (0.35 if i % 2 == 0 else -0.35)
		_dirs.append(Vector2(cos(a), sin(a) * 0.7).normalized())


## Where sign `i` is now, and how bright: [position, alpha, scale].
func place(i: int) -> Array:
	var a := _angle + TAU * i / COUNT
	var r := RADIUS
	if bursting() and _burst_t < WHIRL_S:
		r *= lerpf(1.0, 0.8, _burst_t / WHIRL_S)       # drawn in as it winds up
	var pos := Vector2(cos(a) * r.x, sin(a) * r.y + sin(_t * 2.0 + i) * 1.5)
	# The far side of the ellipse (sin < 0, above the middle) is behind the
	# tower: dimmer and a touch smaller.
	var front := (sin(a) + 1.0) * 0.5
	var alpha := lerpf(0.3, 1.0, front)
	var scale := lerpf(0.85, 1.0, front)
	if not _dirs.is_empty():
		var k := clampf((_burst_t - WHIRL_S) / DASH_S, 0.0, 1.0)
		pos += _dirs[i] * DASH_PX * (1.0 - (1.0 - k) ** 3)   # fast out, easing off
		alpha = 1.0 - k * k * k                              # bright most of the way
		scale = 1.0 + 0.3 * k                               # and growing as it comes
	return [pos, alpha, scale]


func _draw() -> void:
	var signs: Array = SIGNS[clampi(station, 0, SIGNS.size() - 1)]
	for i in COUNT:
		var at: Array = place(i)
		var a: float = at[1]
		if a <= 0.01:
			continue
		var text: String = signs[i % signs.size()]
		var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, SIZE).x
		var base: Vector2 = at[0] - Vector2(w * 0.5, -SIZE * 0.35)
		# A streak behind a sign on its dash.
		if not _dirs.is_empty():
			for s in [0.10, 0.05]:
				var back: Vector2 = base - _dirs[i] * DASH_PX * s
				draw_string_outline(_font, back, text, HORIZONTAL_ALIGNMENT_LEFT, -1, SIZE, 4,
						Color(0.1, 0.07, 0.05, a * (0.25 if s > 0.07 else 0.4)))
				draw_string(_font, back, text, HORIZONTAL_ALIGNMENT_LEFT, -1, SIZE, Color(COLOR, a * (0.35 if s > 0.07 else 0.55)))
		draw_set_transform(base, 0.0, Vector2.ONE * float(at[2]))
		draw_string_outline(_font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, SIZE,
				6 if not _dirs.is_empty() else 4, Color(0.1, 0.07, 0.05, a * 0.9))
		draw_string(_font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, SIZE, Color(COLOR, a))
		draw_set_transform(Vector2.ZERO)

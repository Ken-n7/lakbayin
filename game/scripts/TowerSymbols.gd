class_name TowerSymbols
extends Node2D

## Maths circling a tower (client, 2026-09-27): its station's signs round the
## tower's round top, the far side dimmer. Not in lockstep (client: "plain, no
## random movement"): each keeps its own speed, so they drift apart and bunch
## up; each breathes in and out from the ring, bobs, and rocks, all at its own
## rate. When its question is answered they whirl faster and faster, then
## shoot off, each its own way, and are gone -- `burst()`.
##
## Half the size of the tower's number (PathCircle.NUMBER_SIZE), in the display
## face, pale gold with a dark edge like the signs drifting over the menus.
## Drawn in one `_draw`: a handful of strings a frame.

const SIZE := 16                     # half the number over the tower (32)
const SIZES := [14, 17]              # each its own, all well under the number
const COUNT := 6
## Round the tower's top -- a ring seen from above, so nearly round -- just
## outside its crenellations. (It first went round the middle of the tower,
## on a flat ellipse, which read as circling the top's south edge.)
const RADIUS := Vector2(38, 30)
## The top's centre above a tower's base, as a share of the tower's drawn
## height. The four tower sprites share their shape: drawn from art row 46 to
## 230 of 256, the ring's centre at row 92 -- 0.75 of the way up.
const TOP := 0.75
const SPIN := 0.9                    # radians a second, at rest
const WHIRL := 11.0                  # ... and at the top of the whirl
const WHIRL_S := 0.55                # the whirl, then the dash
const DASH_S := 0.6
const DASH_PX := 230.0               # how far one flies before it is gone
const COLOR := Color("ffe9a8")
## Each station's signs: the four operations, the order, powers.
const SIGNS := [["+", "−", "×", "÷"], ["(", ")", "×", "+"], ["x²", "2³", "4²", "√"]]

var station := 0
## Its own signs instead of a station's (Home's tower: a little of each).
var signs: Array = []
var _font: Font
var _t := 0.0
var _angle := 0.0
var _burst_t := -1.0                 # time since burst(); -1 at rest
var _dirs: Array[Vector2] = []       # each sign's way out, fixed at the dash
var _each: Array = []                # each sign's own ways, see `_ready`


## Where the signs circle for a tower drawn `height` world px tall (its art
## as `Art.cell` trims it), from its base.
static func top_of(height: float) -> Vector2:
	return Vector2(0, -height * TOP)


func _ready() -> void:
	_font = load(Art.TITLE_FONT)
	var rng := RandomNumberGenerator.new()
	rng.seed = get_instance_id()       # towers along the way do not move alike
	_angle = rng.randf() * TAU
	for i in COUNT:
		_each.append({
			"gap": TAU * i / COUNT + rng.randf_range(-0.4, 0.4),   # not evenly spaced
			"speed": rng.randf_range(0.75, 1.3),                    # drifts against the rest
			"reach": rng.randf_range(0.85, 1.12),                   # its own ring...
			"breathe": rng.randf_range(0.06, 0.14),                 # ...that swells and shrinks
			"breathe_f": rng.randf_range(0.5, 1.3),
			"bob": rng.randf_range(2.0, 5.0),
			"bob_f": rng.randf_range(1.1, 2.6),
			"rock": rng.randf_range(0.1, 0.3),
			"rock_f": rng.randf_range(0.6, 1.6),
			"size": rng.randi_range(SIZES[0], SIZES[1]),
			"phase": rng.randf() * TAU,
		})


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
		var a := _angle_of(i) + (0.35 if i % 2 == 0 else -0.35)
		_dirs.append(Vector2(cos(a), sin(a) * 0.8).normalized())


func _angle_of(i: int) -> float:
	var e: Dictionary = _each[i]
	return e.gap + _angle * e.speed


## Where sign `i` is now, how bright, how big, and its lean:
## [position, alpha, scale, rotation].
func place(i: int) -> Array:
	var e: Dictionary = _each[i]
	var a := _angle_of(i)
	var r: Vector2 = RADIUS * (e.reach + e.breathe * sin(_t * e.breathe_f + e.phase))
	if bursting() and _burst_t < WHIRL_S:
		r *= lerpf(1.0, 0.8, _burst_t / WHIRL_S)       # drawn in as it winds up
	var pos := Vector2(cos(a) * r.x, sin(a) * r.y + sin(_t * e.bob_f + e.phase) * e.bob)
	# The far side (sin < 0, above the centre) is behind the tower's top:
	# dimmer and a touch smaller.
	var front := (sin(a) + 1.0) * 0.5
	var alpha := lerpf(0.35, 1.0, front)
	var scale := lerpf(0.85, 1.0, front)
	var lean: float = sin(_t * e.rock_f + e.phase * 1.7) * e.rock
	if not _dirs.is_empty():
		var k := clampf((_burst_t - WHIRL_S) / DASH_S, 0.0, 1.0)
		pos += _dirs[i] * DASH_PX * (1.0 - (1.0 - k) ** 3)   # fast out, easing off
		alpha = 1.0 - k * k * k                              # bright most of the way
		scale = 1.0 + 0.3 * k                               # and growing as it comes
	return [pos, alpha, scale, lean]


func _draw() -> void:
	var set: Array = signs if not signs.is_empty() else SIGNS[clampi(station, 0, SIGNS.size() - 1)]
	for i in COUNT:
		var at: Array = place(i)
		var a: float = at[1]
		if a <= 0.01:
			continue
		var text: String = set[i % set.size()]
		var size: int = _each[i].size
		var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var off := Vector2(-w * 0.5, size * 0.35)
		# A streak behind a sign on its dash.
		if not _dirs.is_empty():
			for s in [0.10, 0.05]:
				var back: Vector2 = at[0] + off - _dirs[i] * DASH_PX * s
				draw_string_outline(_font, back, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4,
						Color(0.1, 0.07, 0.05, a * (0.25 if s > 0.07 else 0.4)))
				draw_string(_font, back, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(COLOR, a * (0.35 if s > 0.07 else 0.55)))
		draw_set_transform(at[0], float(at[3]), Vector2.ONE * float(at[2]))
		draw_string_outline(_font, off, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
				6 if not _dirs.is_empty() else 4, Color(0.1, 0.07, 0.05, a * 0.9))
		draw_string(_font, off, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(COLOR, a))
		draw_set_transform(Vector2.ZERO)

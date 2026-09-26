class_name SkyClouds
extends CanvasLayer

## The sky the start swoop dives through (client: "the camera coming from the
## sky, like in the movies"). Screen space, over the board and under the HUD.
##
## While the board waits for Start, big clouds frame the aerial view's edges
## and drift -- looking down past them. The swoop drives `progress()` with its
## own eased 0..1: the frame clouds swell and fly out past the screen's edges
## as the camera drops, a second bank looms up from the middle and bursts past,
## and a thin white haze peaks as it goes through. Gone when the dive ends.

const PATHS := Clouds.PATHS
const FRAME := 8               # clouds round the edges
## Where round the edges, in degrees (0 right, 90 the bottom) -- a gap at the
## bottom middle, where the start hint sits.
const FRAME_AT := [0, 22, 158, 180, 212, 250, 290, 328]
const BANK := 4                # clouds the camera dives through
const FRAME_ALPHA := 0.9
const HAZE_PEAK := 0.28        # the white-out's strongest, mid-dive
const GROW := 4.0              # how much bigger a cloud gets by the dive's end
const DRIFT := 6.0             # px a second while waiting

var _frame: Array[Sprite2D] = []
var _bank: Array[Sprite2D] = []
var _home := {}                # cloud -> [offset from centre, scale, alpha]
var _haze: ColorRect
var _t := 0.0
var _clock := 0.0


func _ready() -> void:
	var view := get_viewport().get_visible_rect().size
	var mid := view * 0.5
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	# The frame: round an ellipse just inside the screen's edges, so each
	# cloud is half on screen and the board shows through the middle.
	for i in FRAME:
		# Round the edges, but none at the bottom middle: the start hint is there.
		var a := deg_to_rad(float(FRAME_AT[i]) + rng.randf_range(-8.0, 8.0))
		var off := Vector2(cos(a) * view.x * 0.52, sin(a) * view.y * 0.56)
		_frame.append(_cloud(i, off, rng.randf_range(0.9, 1.25), FRAME_ALPHA, mid))
	# The bank: near the middle, small and unseen until the dive brings it up.
	for i in BANK:
		var a := TAU * (float(i) + 0.5) / BANK + rng.randf_range(-0.4, 0.4)
		var off := Vector2(cos(a), sin(a)) * view.y * rng.randf_range(0.08, 0.2)
		_bank.append(_cloud(i + 1, off, rng.randf_range(0.35, 0.5), 0.0, mid))
	_haze = ColorRect.new()
	_haze.color = Color(1, 1, 1, 0)
	_haze.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_haze.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_haze)


func _cloud(i: int, off: Vector2, s: float, alpha: float, mid: Vector2) -> Sprite2D:
	var c := Sprite2D.new()
	c.texture = Art.tex(PATHS[i % PATHS.size()])
	c.flip_h = i % 2 == 1
	c.position = mid + off
	c.scale = Vector2(s, s)
	c.modulate = Color(1, 1, 1, alpha)
	add_child(c)
	_home[c] = [off, s, alpha]
	return c


## Before the dive: the frame drifts, a slow sway round its place.
func _process(delta: float) -> void:
	if _t > 0.0:
		return
	_clock += delta
	var mid := get_viewport().get_visible_rect().size * 0.5
	for c in _frame:
		var h: Array = _home[c]
		var phase := float(_frame.find(c))
		c.position = mid + (h[0] as Vector2) + Vector2(sin(_clock * 0.3 + phase), cos(_clock * 0.23 + phase)) * DRIFT


## The dive, `t` 0..1 (the swoop's own easing).
func progress(t: float) -> void:
	_t = maxf(t, 0.0001)
	var mid := get_viewport().get_visible_rect().size * 0.5
	# The frame: out past the edges and bigger, gone by the end.
	var f := 1.0 + GROW * t * t
	for c in _frame:
		var h: Array = _home[c]
		c.position = mid + (h[0] as Vector2) * f
		c.scale = Vector2.ONE * float(h[1]) * f
		c.modulate.a = float(h[2]) * (1.0 - smoothstep(0.45, 0.85, t))
	# The bank: up from the middle, filling the view, and past.
	var b := 1.0 + (GROW * 2.5) * t * t
	for c in _bank:
		var h: Array = _home[c]
		c.position = mid + (h[0] as Vector2) * b * 1.8
		c.scale = Vector2.ONE * float(h[1]) * b
		c.modulate.a = smoothstep(0.05, 0.3, t) * (1.0 - smoothstep(0.45, 0.75, t)) * 0.95
	# Through the cloud: a white haze, strongest in the middle of it.
	_haze.color.a = HAZE_PEAK * smoothstep(0.2, 0.45, t) * (1.0 - smoothstep(0.45, 0.7, t))

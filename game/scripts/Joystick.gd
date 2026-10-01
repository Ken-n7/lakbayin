extends Node2D
## Floating analog thumbstick: the base spawns wherever a touch lands inside
## `zone` and vanishes on release, rather than sitting at a fixed spot. Once
## claimed, the knob's distance from that spawn point sets real move speed,
## not just an on/off direction -- fed to the same move_* actions the
## keyboard does (via Input's per-action strength), so `_process`'s
## `Input.get_axis` reads it with no changes of its own.

const RADIUS := 46.0

## Left half of the game's 640x360 design canvas -- GO keeps the right
## half to themselves. A touch here always spawns the stick, so it also means
## a bare tap on the left no longer falls through to the circle-inspect tap
## (`AdventureScreen._tap_at`); that gesture still works on the right half.
var zone := Rect2(Vector2.ZERO, Vector2(320, 360))
## Touches the stick leaves alone even inside `zone`: the HUD's arrow back to
## the hero can sit on the left edge, and a tap on it must reach it.
var ignore := func(_at: Vector2) -> bool: return false

var _touch_index := -1
var _knob := Vector2.ZERO


func _input(event: InputEvent) -> void:
	# `_set_pad(false)` only hides the parent `_touch_pad` -- `visible` alone
	# stays true, so a left-half touch during the frozen intro, a quiz or the
	# pause menu would otherwise still be swallowed here instead of reaching
	# whatever it was actually meant for.
	if not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			if _touch_index == -1 and zone.has_point(t.position) and not ignore.call(t.position):
				_touch_index = t.index
				position = t.position
				_knob = Vector2.ZERO
				queue_redraw()
				get_viewport().set_input_as_handled()
		elif t.index == _touch_index:
			release()
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and (event as InputEventScreenDrag).index == _touch_index:
		_drag_to((event as InputEventScreenDrag).position)
		get_viewport().set_input_as_handled()


func _drag_to(at: Vector2) -> void:
	_knob = (at - position).limit_length(RADIUS)
	var n := _knob / RADIUS
	Input.action_press("move_right", maxf(n.x, 0.0))
	Input.action_press("move_left", maxf(-n.x, 0.0))
	Input.action_press("move_down", maxf(n.y, 0.0))
	Input.action_press("move_up", maxf(-n.y, 0.0))
	queue_redraw()


## Public: also called by `_set_pad(false)` so a held drag never survives
## into a quiz or the pause menu -- a hidden node still gets `_input`.
func release() -> void:
	_touch_index = -1
	_knob = Vector2.ZERO
	for a in ["move_left", "move_right", "move_up", "move_down"]:
		Input.action_release(a)
	queue_redraw()


func _draw() -> void:
	if _touch_index == -1:
		return   # only visible while a finger actually holds it
	draw_circle(Vector2.ZERO, RADIUS, Color(1, 1, 1, 0.18))
	draw_arc(Vector2.ZERO, RADIUS, 0.0, TAU, 32, Color(1, 1, 1, 0.4), 2.0)
	draw_circle(_knob, RADIUS * 0.5, Color(0.2, 0.45, 0.85, 0.85))

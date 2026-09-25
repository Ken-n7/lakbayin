class_name DragScroll
extends Node

## Drag anywhere in a list to scroll it -- on a card, on a label, on a button.
##
## A ScrollContainer only drags when the press lands on itself, and every row
## in this game is a card or a button that takes the press first: a finger on
## the list moved it by nothing, and the only way down was the thin scrollbar
## (client: "you have to press somewhere specific"). This watches the input
## before the GUI does. Past DEADZONE it is a drag: the list follows the
## finger, and the release is moved off-screen so the button the drag started
## on is not pressed. A flick carries on and slows down, as a phone list does.
##
## `Ui.drag_scroll(scroll)` attaches one; it replaces the container's own
## touch drag, which is switched off so the two never both move it.

const DEADZONE := 10.0         # canvas px before a press becomes a drag
const WHEEL_STEP := 40.0       # px a wheel notch moves
const FRICTION := 5.0          # how fast a flick dies away, per second
const MIN_FLING := 40.0        # px/s below which a flick just stops

var _sc: ScrollContainer
var _down := false
var _dragging := false
var _from := Vector2.ZERO
var _start_scroll := 0
var _last := Vector2.ZERO
var _vel := 0.0
var _replaying := false


static func attach(sc: ScrollContainer) -> void:
	var d := DragScroll.new()
	d._sc = sc
	sc.scroll_deadzone = 1 << 20          # its own drag is off; this is the drag
	sc.add_child(d)


func _input(event: InputEvent) -> void:
	if _replaying or not _sc.is_visible_in_tree():
		return
	# The container's own wheel moves an eighth of a page -- 13px on a short
	# list, seventy notches to the end of the bank.
	if event is InputEventMouseButton and event.pressed and (event.button_index == MOUSE_BUTTON_WHEEL_UP
			or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		if _sc.get_global_rect().has_point(event.position) and not _covered(event.position):
			var dir := 1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1
			_sc.scroll_vertical += int(dir * WHEEL_STEP * maxf(event.factor, 1.0))
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var at: Vector2 = event.position
		if event.pressed:
			_down = _sc.get_global_rect().has_point(at) and not _covered(at)
			_dragging = false
			_vel = 0.0
			_from = at
			_last = at
			_start_scroll = _sc.scroll_vertical
		elif _down:
			_down = false
			if _dragging:
				_dragging = false
				# The press went to whatever was under the finger; let its
				# release land far away, so a button releases without firing.
				get_viewport().set_input_as_handled()
				_push_away(event)
	elif event is InputEventMouseMotion and _down:
		var at: Vector2 = event.position
		if not _dragging and at.distance_to(_from) > DEADZONE:
			_dragging = true
			# The button under the finger still thinks the finger is on it --
			# it decides on release from the last motion it saw, and from here
			# on this swallows them. Show it the finger leaving.
			_push_away(event)
		if _dragging:
			var dt := maxf(get_process_delta_time(), 0.001)
			_vel = lerpf(_vel, (_last.y - at.y) / dt, 0.5)
			_last = at
			_sc.scroll_vertical = _start_scroll + int(_from.y - at.y)
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _down or absf(_vel) < MIN_FLING:
		_vel = 0.0
		return
	_sc.scroll_vertical += int(_vel * delta)
	_vel *= maxf(0.0, 1.0 - FRICTION * delta)


## `event` again, somewhere no control is: a release there presses nothing,
## a motion there tells a held button the finger has left it.
func _push_away(event: InputEvent) -> void:
	var off := event.duplicate()
	off.position = Vector2(-10000, -10000)
	off.global_position = off.position
	_replaying = true
	get_viewport().push_input(off)
	_replaying = false


## A dialog open over the list (a delete confirmation, the players menu) owns
## the press, not the list under it.
func _covered(at: Vector2) -> bool:
	var hit := get_viewport().gui_get_hovered_control()
	return hit != null and hit != _sc and not _sc.is_ancestor_of(hit)

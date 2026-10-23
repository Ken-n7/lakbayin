class_name DevMapTools
extends RefCounted

## The dev panel's Map tab (DevPanel): the cheats for the match screen it was
## made for -- getting round the world without walking it, answering without
## typing, looking at it from above while the clock runs. Debug builds only.
##
## Everything here reaches into that screen. That is the point: it is a test
## rig, not a feature, and it can be deleted whole without touching the game.

const FAST_WALK := 3.0

## Heading, then one row per button: label, and the method it calls. A toggle
## shows " · on" while it is on. Adding a tool is a line here plus the method.
const GROUPS := [
	["Move", [["Teleport", "_teleport"], ["Aerial", "_aerial"], ["Fast Walk", "_fast_walk"]]],
	["Match", [["Answer Monk", "_answer_monk"], ["+1:00", "_add_minute"],
		["Freeze", "_freeze"], ["End Match", "_end_match"]]],
	["Look", [["Show Walls", "_show_walls"]]],
]
## Which tools are switches, and how to read whether each is on.
const TOGGLES := ["_aerial", "_fast_walk", "_freeze", "_show_walls"]

var _adv: Control
var buttons := {}           # method name -> Button (the panel's tests press them)
var _walls: Node2D = null   # the wall overlay, while it is up
var _hero_box: Node2D = null   # and the hero's Foot box with it


func _init(adv: Control) -> void:
	_adv = adv


func is_for(screen: Control) -> bool:
	return screen == _adv


## The tab's contents, built fresh each time it is shown; toggles read their
## state back from the screen, so nothing is out of step.
func build() -> Control:
	buttons = {}
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	for group: Array in GROUPS:
		col.add_child(DevUi.heading(String(group[0])))
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 2)
		grid.add_theme_constant_override("v_separation", 2)
		col.add_child(grid)
		for spec: Array in group[1]:
			var b := DevUi.button(String(spec[0]))
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.pressed.connect(_press.bind(String(spec[1])))
			grid.add_child(b)
			buttons[String(spec[1])] = b
	for fn: String in TOGGLES:
		_mark(fn, _is_on(fn))
	return col


func _is_on(fn: String) -> bool:
	match fn:
		"_aerial":
			return bool(_adv._dev_aerial)
		"_fast_walk":
			return float(_adv._speed_mult) > 1.0
		"_freeze":
			return Game.clock_paused
		"_show_walls":
			return _walls != null and is_instance_valid(_walls)
	return false


func _press(fn: String) -> void:
	if not is_instance_valid(_adv) or _adv.world == null:
		return
	call(fn)
	if _walls != null and is_instance_valid(_walls):
		_walls.queue_redraw()


func _mark(fn: String, on: bool) -> void:
	if buttons.has(fn) and is_instance_valid(buttons[fn]):
		DevUi.mark(buttons[fn], on)


# --- The tools --------------------------------------------------------------
## The next monk your team has not answered, nearest first; with words
## carried and none left to answer, the Monastery.
func _next_monk() -> int:
	var best := -1
	var best_d := INF
	for i in _adv.world.monks.size():
		if _adv.play.ours(i):
			continue
		var d: float = _adv.world.monks[i].position.distance_to(_adv.player.position)
		if d < best_d:
			best_d = d
			best = i
	return best


func _teleport() -> void:
	var i := _next_monk()
	var to: Vector2 = _adv.world.monks[i].position + Vector2(0, 24) if i >= 0 else _adv.world.door()
	_adv.player.position = to
	_adv._cam.position = to
	_adv._update_interaction()


## The nearest unanswered monk's word, written right, wherever the hero is.
func _answer_monk() -> void:
	var i := _next_monk()
	if i < 0:
		_adv.hud.flash("Every monk is answered — deposit at the Monastery.")
		return
	await _adv.play.answer(i, str(_adv.play.words[i].modern))
	_adv.hud.flash("Monk %d answered." % (i + 1))


func _aerial() -> void:
	var cam: Camera2D = _adv._cam
	_adv._dev_aerial = not _adv._dev_aerial
	if _adv._dev_aerial:
		cam.position_smoothing_enabled = false
		_adv._clamp_cam(false)
		var z: float = _adv._aerial_zoom()
		cam.zoom = Vector2(z, z)
		cam.position = Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE * 0.5
	else:
		cam.zoom = Vector2(MapCfg.PLAY_ZOOM, MapCfg.PLAY_ZOOM)
		_adv._clamp_cam(true)
		cam.position = _adv.player.position
		cam.position_smoothing_enabled = true
	_mark("_aerial", _adv._dev_aerial)


func _fast_walk() -> void:
	_adv._speed_mult = 1.0 if _adv._speed_mult > 1.0 else FAST_WALK
	_mark("_fast_walk", _adv._speed_mult > 1.0)


func _freeze() -> void:
	Game.clock_paused = not Game.clock_paused
	_mark("_freeze", Game.clock_paused)


func _add_minute() -> void:
	Game.time_left += 60.0
	Game.time_changed.emit(int(ceilf(Game.time_left)))


## Straight to the results, for testing the end without playing a match.
func _end_match() -> void:
	_adv.finish("time")


## Every wall in the world, drawn, and the hero's own Foot box riding along.
func _show_walls() -> void:
	if _walls != null and is_instance_valid(_walls):
		_walls.queue_free()
		_walls = null
		if is_instance_valid(_hero_box):
			_hero_box.queue_free()
		_mark("_show_walls", false)
		return
	var n := Node2D.new()
	n.z_index = 5
	n.draw.connect(func() -> void:
		for r: Rect2 in _adv.grid.solid:
			n.draw_rect(r, Color(1.0, 0.25, 0.25, 0.25))
			n.draw_rect(r, Color(1.0, 0.4, 0.4, 0.85), false, 1.0))
	_adv.world.add_child(n)
	_walls = n
	_hero_box = Node2D.new()
	_hero_box.z_index = 6
	_hero_box.draw.connect(func() -> void:
		_hero_box.draw_rect(_adv.hero_box, Color(0.3, 0.9, 1.0, 0.35))
		_hero_box.draw_rect(_adv.hero_box, Color(0.3, 0.9, 1.0, 0.95), false, 1.0))
	_adv.player.add_child(_hero_box)
	_mark("_show_walls", true)

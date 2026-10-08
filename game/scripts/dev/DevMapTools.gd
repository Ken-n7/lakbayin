class_name DevMapTools
extends RefCounted

## The dev panel's Map tab (DevPanel): the cheats for the adventure screen
## it was made for -- reaching the later islands without answering every
## question, looking at the board while the game runs. Debug builds only.
##
## Everything here reaches into that screen. That is the point: it is a test
## rig, not a feature, and it can be deleted whole without touching the game.

const FAST_WALK := 3.0

## Heading, then one row per button: label, and the method it calls. A toggle
## shows " · on" while it is on. Adding a tool is a line here plus the method.
const GROUPS := [
	["Move", [["Teleport", "_teleport"], ["Aerial", "_aerial"],
		["Fast Walk", "_fast_walk"], ["Open Gates", "_open_gates"]]],
	["Progress", [["Skip Station", "_skip_station"], ["+1:00", "_add_minute"],
		["Freeze", "_freeze"], ["End Run", "_end_run"]]],
	["Look", [["Show Walls", "_show_walls"], ["Hero -", "_hero_smaller"],
		["Hero +", "_hero_bigger"]]],
]
## Which tools are switches, and how to read whether each is on.
const TOGGLES := ["_aerial", "_fast_walk", "_freeze", "_show_walls"]

var _adv: Control
var buttons := {}           # method name -> Button (the panel's tests press them)
var _walls: Node2D = null   # the `_solid` overlay, while it is up
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
	col.add_child(DevUi.note("Keys on the map: [ and ] size the hero."))
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


## Every tool goes through here so the wall overlay is repainted after one that
## moves a wall, and the HUD after one that moves the run on.
func _press(fn: String) -> void:
	if not is_instance_valid(_adv):
		return
	call(fn)
	if _walls != null and is_instance_valid(_walls):
		_walls.queue_redraw()


func _mark(fn: String, on: bool) -> void:
	if buttons.has(fn) and is_instance_valid(buttons[fn]):
		DevUi.mark(buttons[fn], on)


# --- The tools --------------------------------------------------------------
## Resolve every circle the current station has left, brief its tower, and bank
## it -- the same four refreshes `close_overlay()` ends with are what then opens
## whatever that station's progress unlocks.
func _skip_station() -> void:
	if Game.items_done >= Game.TOTAL_ITEMS:
		_adv.hud.flash("Board already cleared.")
		return
	var st := Game.station_of_item(Game.items_done)
	Game.towers_entered[st] = true
	while Game.items_done < Game.TOTAL_ITEMS and Game.station_of_item(Game.items_done) == st:
		Game.mark_correct()
	Game.finish_station(st)
	_adv.hud.refresh()
	_adv._refresh_circles()
	_adv.barricades.refresh()
	_adv.hud.flash("Station %d skipped." % (st + 1))


## The next stop on the walk: an unbriefed station's own doorstep, else the
## circle that is up next, else the Victory Gate. Every one of those is an anchor,
## and `_clear_of_anchors()` guarantees an anchor is never inside a wall.
func _teleport() -> void:
	var to: Vector2
	if Game.items_done >= Game.TOTAL_ITEMS:
		to = (_adv.stations.gate as Node2D).position
	else:
		var st := Game.station_of_item(Game.items_done)
		to = ((_adv.stations.nodes[st] as Node2D).position if not Game.towers_entered[st]
				else (_adv._circles[Game.items_done] as Node2D).position)
	_adv.player.position = to
	_adv._cam.position = to


## The whole-board POV, the same one the intro holds on. `_dev_aerial` is what
## stops `_process()` dragging the camera back to the hero every frame.
func _aerial() -> void:
	var cam: Camera2D = _adv._cam
	_adv._dev_aerial = not _adv._dev_aerial
	if _adv._dev_aerial:
		cam.position_smoothing_enabled = false
		_adv._clamp_cam(false)
		var z: float = _adv._aerial_zoom()
		cam.zoom = Vector2(z, z)
		cam.position = Vector2(MapCfg.WORLD_W * MapCfg.TILE, MapCfg.WORLD_H * MapCfg.TILE) * 0.5
	else:
		cam.zoom = Vector2(MapCfg.PLAY_ZOOM, MapCfg.PLAY_ZOOM)
		_adv._clamp_cam(true)
		cam.position = _adv.player.position
		cam.position_smoothing_enabled = true
	_mark("_aerial", _adv._dev_aerial)


## Stand every guard down, without touching question progress -- for walking the
## board rather than for testing the gating.
func _open_gates() -> void:
	for g: Dictionary in _adv.barricades.list:
		_adv.barricades.open(g)
	_adv.hud.flash("All crossings open.")


func _fast_walk() -> void:
	_adv._speed_mult = 1.0 if _adv._speed_mult > 1.0 else FAST_WALK
	_mark("_fast_walk", _adv._speed_mult > 1.0)


func _freeze() -> void:
	Game.clock_paused = not Game.clock_paused
	_mark("_freeze", Game.clock_paused)


func _add_minute() -> void:
	Game.time_left += 60.0
	Game.time_changed.emit(int(ceilf(Game.time_left)))


## Every wall on the board, drawn. A bare Node2D with its `draw` signal wired to
## a lambda -- no script file for eight lines. It repaints from `_press()`, since
## the set it draws changes whenever a gate opens.
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
	# The hero's own Foot box, riding along with them (scenes/Hero.tscn).
	_hero_box = Node2D.new()
	_hero_box.z_index = 6
	_hero_box.draw.connect(func() -> void:
		_hero_box.draw_rect(_adv.hero_box, Color(0.3, 0.9, 1.0, 0.35))
		_hero_box.draw_rect(_adv.hero_box, Color(0.3, 0.9, 1.0, 0.95), false, 1.0))
	_adv.player.add_child(_hero_box)
	_mark("_show_walls", true)


## The [ and ] sizing knob as buttons, for tuning on a phone with no keyboard.
## The toast prints the number to bake into MapCfg.UNIT_SCALE.
func _hero_smaller() -> void:
	_adv._nudge_hero_scale(-_adv.HERO_SCALE_STEP)


func _hero_bigger() -> void:
	_adv._nudge_hero_scale(_adv.HERO_SCALE_STEP)


## Straight to the summary, for testing the end of a run without playing one.
func _end_run() -> void:
	Game.end_adventure()

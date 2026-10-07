extends Control

## The dev drawer: a tab on the left edge of the Adventure map that pops out a
## box of cheats. Plain widgets, no pack art and no slide -- it is a test rig,
## and dressing it as parchment only makes it look like part of the game. It exists so the later islands can be reached without
## answering every question in front of them, and so the board can be looked at
## while the game is running rather than only in a screenshot.
##
## Debug builds only -- `AdventureScreen` does not even create the node otherwise
## (`OS.is_debug_build()`), so the `--export-debug` APK keeps it and a release
## export drops it with nothing to strip by hand.
##
## Everything here reaches into the screen it was handed. That is the point: it
## is a test rig, not a feature, and it can be deleted whole without touching a
## line of the game.

const PANEL_W := 124.0
## Top edge only -- the box is a container, so it takes whatever height its
## buttons need, and eleven of them nearly fill the 360px canvas.
const PANEL_Y := 4.0
const TAB := Vector2(18.0, 40.0)
const TAB_Y := 150.0
const FAST_WALK := 3.0

## One row per button: label, and the method it calls. Adding a tool is a line
## here plus the method. A toggle rewrites its own label with a trailing dot.
const TOOLS := [
	["Skip Station", "_skip_station"],
	["Teleport", "_teleport"],
	["Aerial", "_aerial"],
	["Open Gates", "_open_gates"],
	["Fast Walk", "_fast_walk"],
	["Freeze", "_freeze"],
	["+1:00", "_add_minute"],
	["Show Walls", "_show_walls"],
	["Hero -", "_hero_smaller"],
	["Hero +", "_hero_bigger"],
	["End Run", "_end_run"],
]

var _adv: Control
var _panel: PanelContainer
var _handle: Button
var _buttons := {}          # method name -> Button, for the toggles' labels
var _walls: Node2D = null   # the `_solid` overlay, while it is up
var _hero_box: Node2D = null   # and the hero's Foot box with it
var _open := false


func setup(adv: Control) -> void:
	_adv = adv
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The drawer is a bare frame; only its handle and its buttons take clicks, so
	# the rest of the screen still gets taps, drags and the circle-inspect.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_panel = DevUi.box(PANEL_W)
	_panel.position = Vector2(TAB.x, PANEL_Y)
	_panel.visible = false
	add_child(_panel)
	var box := DevUi.column(_panel)
	for spec: Array in TOOLS:
		var b := DevUi.button(String(spec[0]))
		b.pressed.connect(_press.bind(String(spec[1])))
		box.add_child(b)
		_buttons[String(spec[1])] = b

	_handle = DevUi.button("D", TAB.y)
	_handle.custom_minimum_size = TAB
	_handle.position = Vector2(0.0, TAB_Y)
	_handle.pressed.connect(toggle)
	add_child(_handle)
	_claim_touch()


## Show or hide. No tween: waiting 0.18s to reach a cheat is 0.18s of nothing.
func toggle() -> void:
	_open = not _open
	_panel.visible = _open
	_claim_touch()


func close() -> void:
	if _open:
		toggle()


## The floating joystick claims the left half of the canvas and marks those
## touches handled, so on a device it would swallow every tap meant for the
## drawer. Hand back exactly the strip the drawer is using. Desktop runs have no
## joystick at all, so this is a no-op there.
func _claim_touch() -> void:
	var stick: Node2D = _adv.hud.joystick
	if stick == null or not is_instance_valid(stick):
		return
	var taken := (TAB.x + PANEL_W if _open else TAB.x) + 4.0
	stick.zone = Rect2(Vector2(taken, 0.0), Vector2(320.0 - taken, 360.0))


## Every tool goes through here so the wall overlay is repainted after one that
## moves a wall, and the HUD after one that moves the run on.
func _press(fn: String) -> void:
	call(fn)
	if _walls != null and is_instance_valid(_walls):
		_walls.queue_redraw()


## A toggle's label carries its own state -- one dot, no second stylebox to skin.
func _mark(fn: String, on: bool) -> void:
	var b: Button = _buttons[fn]
	var base: String = b.text.trim_suffix(" •")
	b.text = base + (" •" if on else "")


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

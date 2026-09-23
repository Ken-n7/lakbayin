extends Control

## The Adventure Map: the client's board laid over a Tiny Swords island --
## base camp, Station 1, its circles, Station 2, its circles, Station 3, its circles,
## Victory Gate, all on one authored path. One circle is one question item, and
## they resolve strictly in order. WASD/arrows move the hero; E (or Space/Enter)
## enters the tower you stand at, answers the circle you stand on, or walks
## through the gate once all of Game.TOTAL_ITEMS are cleared.
const DevTools := preload("res://scripts/DevTools.gd")

var main: Control

var world: Node2D
var player: Node2D

## Every cell and every box on the board. See `map/MapGrid.gd`.
var grid := MapGrid.new()
## The four that build it, in the order `setup()` runs them. Each owns one
## concern and writes into `grid`; this screen owns the walk and the play.
var builder: MapBuilder
var stations: Stations
var barricades: Barricades
var decor: Decor

var _circles: Array = []        # Game.TOTAL_ITEMS PathCircle nodes, path order
var _cam: Camera2D
var _prompt: Label
var _bang: Label = null         # the "!" over the hero when something is in reach
var _hud_gems: Label
var _hud_time: Label
var _hud_station: Label
var _hud_pips: Label
var _gem_bar: ProgressBar
var _hud_layer: CanvasLayer
var _ui_layer: CanvasLayer

var _touch_pad: Node2D = null
var _joystick: Node2D = null
var _overlay: Control = null
var _paused := false
var _flash_active := false
var _frozen := false            # the aerial POV before the adventure starts
var _intro_tw: Tween = null
var _start_hint: Label = null   # "Tap anywhere to start" -- freed once it does
var _card: Control = null       # the tapped circle's info card
var _hint_bar: Label = null     # the controls crib, hidden while the board is frozen
var _dev: Control = null        # the cheat drawer, on debug builds only
## Dev knobs the drawer drives: a walk-speed multiplier, and the flag that stops
## `_process()` dragging the camera back to the hero while the board is framed.
var _speed_mult := 1.0
var _dev_aerial := false
var _hero_scale := MapCfg.UNIT_SCALE   # live-tunable via [ / ], DevTools.key_step()


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# A bare Control defaults to MOUSE_FILTER_STOP, which swallows every click or
	# tap right here as "handled" before _unhandled_input ever sees it -- taps on
	# the board (start, circle cards) would silently do nothing. The HUD buttons
	# and panels are their own Controls with their own filters, unaffected by this.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_hud()
	if not Game.adventure_active:
		Game.begin_adventure()
	world = Node2D.new()
	add_child(world)
	world.y_sort_enabled = true
	builder = MapBuilder.new(world, grid)
	stations = Stations.new(world, grid)
	barricades = Barricades.new(world, grid)
	decor = Decor.new(world, grid)
	grid.anchors = builder.path_anchors()
	builder.build_terrain()
	grid.grass = builder.grass
	world.set_meta("grass", builder.grass)
	world.set_meta("tile", MapCfg.TILE)
	builder.build_island()
	_build_path()
	decor.build()
	_spawn_player()
	Game.time_changed.connect(_on_time)
	Game.gems_changed.connect(_on_gems)
	Game.adventure_ended.connect(_on_adventure_end)
	_refresh_hud()
	_refresh_circles()
	# A restart mid-run keeps whatever it had already opened.
	barricades.refresh()
	_start_intro()


func _exit_tree() -> void:
	# Only if THIS screen was the one holding the freeze. `Main.open()` frees the
	# old screen with `queue_free()` (deferred), so on a Restart this runs after
	# the new screen's `setup()` already set clock_paused = true for its own
	# fresh intro -- an unconditional clear here would clobber that.
	if _frozen:
		Game.clock_paused = false
	Game.time_changed.disconnect(_on_time)
	Game.gems_changed.disconnect(_on_gems)
	Game.adventure_ended.disconnect(_on_adventure_end)


func _build_path() -> void:
	var PathCircle := preload("res://scripts/PathCircle.gd")
	var k := 1                       # anchor 0 is the base camp
	for st in Game.ITEMS_PER_STATION.size():
		var meta := QuestionGen.station_meta(st)
		stations.build_keep(st, grid.anchors[k], meta.accent, builder.tower_lift(k))
		k += 1
		# Every circle is a tower in its station's livery -- native colors, no
		# tint -- so size the decor keep-out box off it too.
		var building: String = MapCfg.CIRCLE_BUILDINGS[st]
		var ctex := Art.cell(building, 0, 0)
		var chw := ctex.region.size.x * 0.5 * PathCircle.TOWER_SCALE
		var cbh := ctex.region.size.y * PathCircle.TOWER_SCALE
		for _i in Game.ITEMS_PER_STATION[st]:
			var c: Node2D = PathCircle.new()
			c.position = grid.anchors[k]
			world.add_child(c)
			var lift := builder.circle_lift(k)
			c.setup(_circles.size(), building, lift, world)
			# The middle of the drawn building, for anything aiming at what the
			# player can see rather than at the anchor it steps off of. Same
			# `set_meta` channel `Stations.build_keep()` uses for its wall.
			c.set_meta("tower_mid", grid.anchors[k] + lift - Vector2(0, cbh * 0.5))
			_circles.append(c)
			# The wall PathCircle computed is local to the anchor; place it in
			# world space and keep decor off the lifted tower's real footprint.
			var w: Rect2 = c.wall
			w.position += grid.anchors[k]
			grid.block(w)
			grid.keep_out(Rect2(
					grid.anchors[k] + lift - Vector2(chw + MapCfg.TILE * 0.5, cbh),
					Vector2(chw * 2.0 + MapCfg.TILE, cbh + MapCfg.TILE * 0.5)))
			k += 1
	stations.build_camp(grid.anchors[0])
	stations.build_gate(grid.anchors[k])
	barricades.build(builder.tower_anchors())


# --- Stations ---------------------------------------------------------------
## The signage boxes on their own as well. Decor treats them like any other
## keep-out, but a guard looking for somewhere to stand has to clear them with his
## whole body or he ends up printed across the station's name.


func _spawn_player() -> void:
	player = Node2D.new()
	player.position = grid.anchors[0]
	var shade := Sprite2D.new()
	shade.texture = Art.tex(MapCfg.SHADOW_SHEET)
	shade.scale = Vector2(MapCfg.HERO_SHADOW_SCALE, MapCfg.HERO_SHADOW_SCALE)
	shade.modulate.a = MapCfg.HERO_SHADOW_ALPHA
	shade.position = MapCfg.HERO_SHADOW_OFFSET
	player.add_child(shade)
	var spr := AnimatedSprite2D.new()
	spr.name = "Spr"
	spr.scale = Vector2(_hero_scale, _hero_scale)
	spr.offset = MapCfg.HERO_FOOT_OFFSET
	spr.sprite_frames = Art.walk_frames(Game.hero_sheet(Game.hero_id))
	spr.play("down")
	spr.pause()
	player.add_child(spr)
	# "There is something here you can actually do." Clears the hero's head: the
	# 20px frame sits at `offset` -10 and scales by `_hero_scale`. Bobs so it
	# catches the eye without a marker on the ground under it.
	_bang = Art.label("!", 16, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	_bang.position = Vector2(-MapCfg.BANG_BOX.x * 0.5,
			-MapCfg.HERO_FRAME_H * _hero_scale - MapCfg.BANG_CLEARANCE)
	_bang.size = MapCfg.BANG_BOX
	_bang.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_bang.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bang.visible = false
	Art.shadow(_bang)
	player.add_child(_bang)
	var bob := _bang.create_tween().set_loops()
	bob.tween_property(_bang, "position:y", _bang.position.y - MapCfg.BANG_BOB,
			MapCfg.BANG_BOB_TIME).set_trans(Tween.TRANS_SINE)
	bob.tween_property(_bang, "position:y", _bang.position.y,
			MapCfg.BANG_BOB_TIME).set_trans(Tween.TRANS_SINE)
	world.add_child(player)
	# On the world, not the hero: the aerial POV has to frame the whole board
	# before it swoops down to him.
	_cam = Camera2D.new()
	_cam.position_smoothing_enabled = true
	_cam.position_smoothing_speed = MapCfg.CAM_SMOOTH
	_cam.position = player.position
	world.add_child(_cam)
	_clamp_cam(true)


## Camera limits, on for play and off for the aerial POV. A visible rect wider
## than the limits does not get letterboxed -- it gets shoved off-centre, so the
## whole-board view has to run unclamped.
func _clamp_cam(on: bool) -> void:
	_cam.limit_left = 0 if on else -MapCfg.CAM_UNCLAMPED
	_cam.limit_top = 0 if on else -MapCfg.CAM_UNCLAMPED
	_cam.limit_right = MapCfg.WORLD_W * MapCfg.TILE if on else MapCfg.CAM_UNCLAMPED
	_cam.limit_bottom = MapCfg.WORLD_H * MapCfg.TILE if on else MapCfg.CAM_UNCLAMPED


## Frames the whole board. Computed, not a constant: the old 0.46 framed a
## 1408x960 world and would show a corner of this one.
static func _aerial_zoom() -> float:
	return minf(Pal.CANVAS.x / float(MapCfg.WORLD_W * MapCfg.TILE),
			Pal.CANVAS.y / float(MapCfg.WORLD_H * MapCfg.TILE))


# --- Pre-start aerial POV ---------------------------------------------------
## The client's flow shows the board from far away and frozen, then the camera
## swoops to the hero when the adventure starts. The board holds here until
## something starts it: offline that is any tap / click / interact press, and in
## Phase 3 the admin's Start Game calls `_swoop()` over `Net.gd` instead -- no
## button to delete, just route that signal in wherever `_swoop()` is called from
## `_unhandled_input()` now. `Game.clock_paused` is why the wait is free: no time
## is spent while the board is still frozen, however long the player looks. No
## joystick either, which the client asked for twice.
func _start_intro() -> void:
	_frozen = true
	Game.clock_paused = true
	_set_pad(false)
	_cam.position_smoothing_enabled = false
	_clamp_cam(false)
	var z := _aerial_zoom()
	_cam.zoom = Vector2(z, z)
	_cam.position = Vector2(MapCfg.WORLD_W * MapCfg.TILE * 0.5, MapCfg.WORLD_H * MapCfg.TILE * 0.5)
	_prompt.text = "Scouting the board..."
	# The controls crib goes with the joystick -- there is nothing to drive yet.
	if _hint_bar != null:
		_hint_bar.visible = false
	# Right under the prompt, lower centre -- nothing sits on the board itself.
	_start_hint = Art.label("Tap anywhere to start", 13, Color(1, 1, 1, 0.85), HORIZONTAL_ALIGNMENT_CENTER)
	_start_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_start_hint.offset_top = -74.0
	_start_hint.offset_bottom = -50.0
	_start_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_layer.add_child(_start_hint)


## The transition: the POV comes down onto the board and the hero.
func _swoop() -> void:
	if not _frozen:
		return
	_drop_start_hint()
	_prompt.text = ""
	_intro_tw = create_tween()
	_intro_tw.set_parallel(true)
	_intro_tw.tween_property(_cam, "zoom", Vector2(MapCfg.PLAY_ZOOM, MapCfg.PLAY_ZOOM), MapCfg.SWOOP_TIME).set_ease(Tween.EASE_IN_OUT)
	_intro_tw.tween_property(_cam, "position", player.position, MapCfg.SWOOP_TIME).set_ease(Tween.EASE_IN_OUT)
	_intro_tw.chain().tween_callback(skip_intro)


func _drop_start_hint() -> void:
	if _start_hint != null and is_instance_valid(_start_hint):
		_start_hint.queue_free()
	_start_hint = null


## Collapse the intro at once -- the tail of the tween, and what the tests call so
## nothing waits on wall-clock time.
func skip_intro() -> void:
	if not _frozen:
		return
	if _intro_tw != null and _intro_tw.is_valid():
		_intro_tw.kill()
	_intro_tw = null
	_drop_start_hint()
	if _hint_bar != null:
		_hint_bar.visible = true
	_frozen = false
	Game.clock_paused = false
	_cam.zoom = Vector2(MapCfg.PLAY_ZOOM, MapCfg.PLAY_ZOOM)
	_clamp_cam(true)
	_cam.position = player.position
	_cam.position_smoothing_enabled = true
	_set_pad(true)
	_prompt.text = ""
	_update_interaction()


## Which way the sprite faces. Vertical wins ties so a diagonal walk still
## shows the back or front, which reads better than a side-on shuffle.
static func _facing(dir: Vector2) -> String:
	if absf(dir.y) >= absf(dir.x):
		return "down" if dir.y > 0.0 else "up"
	return "right" if dir.x > 0.0 else "left"


func _process(delta: float) -> void:
	if _overlay != null and is_instance_valid(_overlay) and Game.adventure_active:
		return
	if _paused or _frozen or not Game.adventure_active:
		return
	if not _dev_aerial:
		_cam.position = player.position
	var dir := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down"))
	if dir.length_squared() > 1.0:
		dir = dir.normalized()
	var spr: AnimatedSprite2D = player.get_node("Spr")
	if dir.length_squared() > 0.001:
		# One axis at a time, so a diagonal into a wall slides along it rather
		# than stopping dead. Buildings only became real walls once the
		# footprint stopped being rounded to tile centres.
		var step := dir * MapCfg.PLAYER_SPEED * _speed_mult * delta
		player.position.x += step.x
		if not grid.is_walkable(player.position):
			player.position.x -= step.x
		player.position.y += step.y
		if not grid.is_walkable(player.position):
			player.position.y -= step.y
		var face := _facing(dir)
		if spr.animation != face or not spr.is_playing():
			spr.play(face)
	elif spr.is_playing():
		# The middle column is the standing pose, so idle is the walk paused.
		spr.pause()
		spr.frame = 1
	_update_interaction()


# --- Gating -----------------------------------------------------------------
## One item per circle, strictly in order: the tower briefing unlocks its own
## circles, circle n unlocks only when n-1 is resolved, and the gate only once
## every circle is behind you.
func _can_enter_tower(i: int) -> bool:
	return (Game.items_done < Game.TOTAL_ITEMS
			and Game.station_of_item(Game.items_done) == i
			and not Game.towers_entered[i])


func _can_answer(n: int) -> bool:
	return n == Game.items_done and Game.towers_entered[Game.station_of_item(n)]


func _can_enter_gate() -> bool:
	return Game.items_done >= Game.TOTAL_ITEMS


## Index of the nearest node in `nodes` within reach, or -1.
func _nearest_of(nodes: Array) -> int:
	var best := -1
	var best_d := MapCfg.INTERACT_RADIUS
	for i in nodes.size():
		var n: Node2D = nodes[i]
		if n == null:
			continue
		var d := n.position.distance_to(player.position)
		if d < best_d:
			best_d = d
			best = i
	return best


## What the hero is standing at: {kind: "tower"|"circle"|"gate", index}, or {}.
## Anchors are ~200px apart against a 42px reach, so this is never ambiguous.
## Measured against the anchor, not the tower beside it: the anchor sits on the
## trail the hero walks, which gives a wide window of availability, where a disc
## centred on a sideways-lifted tower would only catch ~25px of that walk.
func _nearest_target() -> Dictionary:
	var best := {}
	var best_d := MapCfg.INTERACT_RADIUS
	for pair in [["tower", stations.nodes], ["circle", _circles], ["gate", [stations.gate]]]:
		var nodes: Array = pair[1]
		for i in nodes.size():
			var n: Node2D = nodes[i]
			if n == null:
				continue
			var d := n.position.distance_to(player.position)
			if d < best_d:
				best_d = d
				best = {"kind": pair[0], "index": i}
	return best


## Would pressing E / GO right now actually do something? The "!" over the
## player's head is exactly this, and `_prompt_for` opens on the same question,
## so the rule lives here rather than in both.
func _can_act_on(target: Dictionary) -> bool:
	match target.get("kind", ""):
		"tower": return _can_enter_tower(target.index)
		"circle": return _can_answer(target.index)
		"gate": return _can_enter_gate()
	return false


func _prompt_for(target: Dictionary) -> String:
	var go := "Tap GO" if Game.touch else "Press E / Space / Enter"
	var ready := _can_act_on(target)
	match target.get("kind", ""):
		"tower":
			var i: int = target.index
			if ready:
				return "%s — enter Station %d" % [go, i + 1]
			if Game.items_done >= Game.TOTAL_ITEMS:
				return "Every circle cleared — head for the Victory Gate"
			if Game.towers_entered[i]:
				return "Station %d briefing done — follow the circles" % (i + 1)
			return "Complete Station %d first" % (Game.station_of_item(Game.items_done) + 1)
		"circle":
			var n: int = target.index
			if ready:
				return "%s — Answer Quest!" % go
			if n < Game.items_done:
				return "Circle %d cleared" % (n + 1)
			if not Game.towers_entered[Game.station_of_item(n)]:
				return "Enter Station %d first" % (Game.station_of_item(n) + 1)
			return "Answer circle %d first" % (Game.items_done + 1)
		"gate":
			if ready:
				return "%s — enter the Victory Gate" % go
			return "Conquer all %d circles first" % Game.TOTAL_ITEMS
	return ""


func _update_interaction() -> void:
	var target := _nearest_target()
	_bang.visible = _can_act_on(target)
	# A toast owns the prompt line for a moment, but it has no business freezing
	# the "!" -- that is a separate channel and has to keep tracking what is in
	# reach while the tip is up.
	if _flash_active:
		return
	_prompt.text = _prompt_for(target)


func _unhandled_input(event: InputEvent) -> void:
	if _overlay != null or _paused:
		return
	var tap := ((event is InputEventMouseButton
					and (event as InputEventMouseButton).pressed
					and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT)
			or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed))
	if _frozen:
		# Any tap, click or interact press starts the adventure -- nothing to
		# inspect yet, the whole board is the thing being looked at.
		if tap or event.is_action_pressed("interact"):
			_swoop()
		return
	if tap:
		_tap_at((event as InputEventWithModifiers).position if event is InputEventMouseButton
				else (event as InputEventScreenTouch).position)
		return
	var scale_step := DevTools.key_step(event, KEY_BRACKETLEFT, KEY_BRACKETRIGHT, 0.1)
	if scale_step != 0.0:
		_nudge_hero_scale(scale_step)
		return
	if event.is_action_pressed("interact"):
		_interact()
	elif event.is_action_pressed("pause"):
		_toggle_pause()


## Dev-only sizing knob: [ shrinks, ] grows, the readout is the number to bake
## back into UNIT_SCALE once something looks right. Rescales in place, so it is
## visible mid-walk without a restart.
func _nudge_hero_scale(delta: float) -> void:
	_hero_scale = clampf(_hero_scale + delta, 0.5, 3.0)
	var spr: AnimatedSprite2D = player.get_node("Spr")
	spr.scale = Vector2(_hero_scale, _hero_scale)
	_flash_tip("Hero scale: %.1f  (was MapCfg.UNIT_SCALE = %.1f)" % [_hero_scale, MapCfg.UNIT_SCALE])


## Tap-to-inspect. `self` is a canvas item under the camera, so the viewport's
## canvas transform is what undoes the zoom and the scroll. Aimed at the tower
## the player can see, not at the anchor below it -- nothing is drawn there any
## more, so hit-testing the anchor meant tapping bare grass. TOWER_TAP_REACH
## covers the building; the screen-px slack on top keeps it tappable once the
## aerial zoom has shrunk it.
func _tap_at(screen_pos: Vector2) -> void:
	var at: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * screen_pos
	var best := -1
	var best_d := MapCfg.TOWER_TAP_REACH + 14.0 / maxf(_cam.zoom.x, 0.01)
	for n in _circles.size():
		var c := _circles[n] as Node2D
		var d: float = (c.get_meta("tower_mid", c.position) as Vector2).distance_to(at)
		if d < best_d:
			best_d = d
			best = n
	if best < 0:
		_close_card()
		return
	_show_circle_card(best)


func _close_card() -> void:
	if _card != null and is_instance_valid(_card):
		_card.queue_free()
	_card = null


## What a circle is, on tap: which item, which station, and whether it is yours.
## The client's flow puts an "Answer Quest!" button on the circle you are standing
## on, so the card carries it -- but only within reach, which is what keeps "walk
## to the circle" true. E / GO still goes straight to the question, the fast path
## for forty items.
func _show_circle_card(n: int) -> void:
	_close_card()
	var st := Game.station_of_item(n)
	var meta: Dictionary = QuestionGen.station_meta(st)
	var card := Ui.panel(Vector2(300, 0), "Circle %d of %d" % [n + 1, Game.TOTAL_ITEMS])
	card.position = Vector2(170, 92)
	_ui_layer.add_child(card)
	_card = card
	var box: VBoxContainer = card.get_child(0) as VBoxContainer
	box.add_child(Art.label(meta.title, 14, Color("3a2c22"), HORIZONTAL_ALIGNMENT_CENTER))
	var state := ("Cleared" if n < Game.items_done
			else ("Your turn" if _can_answer(n) else "Locked"))
	box.add_child(Art.label("Item %d of Station %d   -   %s"
			% [Game.item_in_station(n) + 1, st + 1, state],
			14, Color("5a4632"), HORIZONTAL_ALIGNMENT_CENTER))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	if _can_answer(n) and (_circles[n] as Node2D).position.distance_to(player.position) < MapCfg.INTERACT_RADIUS:
		var go := Ui.button("Answer Quest!", 170, 44, Ui.RED)
		go.pressed.connect(func() -> void:
			_close_card()
			_try_answer_circle())
		row.add_child(go)
	var x := Ui.button("X", 44, 44, Ui.SMALL_RED)
	x.pressed.connect(_close_card)
	row.add_child(x)


func _interact() -> void:
	match _nearest_target().get("kind", ""):
		"tower": _try_enter_station()
		"circle": _try_answer_circle()
		"gate": _try_enter_gate()


## The tower briefing: the station intro card, and nothing else. Its circles are
## what ask the questions.
func _try_enter_station() -> void:
	var i := _nearest_of(stations.nodes)
	if i < 0:
		return
	if not _can_enter_tower(i):
		if Game.items_done >= Game.TOTAL_ITEMS:
			_flash_tip("Every circle is cleared — head for the Victory Gate!")
		elif Game.towers_entered[i]:
			_flash_tip("Station %d is briefed — answer its circles!" % (i + 1))
		else:
			_flash_tip("Complete Station %d first!" % (Game.station_of_item(Game.items_done) + 1))
		return
	Game.current_station = i
	var quiz: Control = preload("res://scripts/QuizOverlay.gd").new()
	quiz.adventure = self
	quiz.station_index = i
	quiz.intro_only = true
	_show_overlay(quiz)


func _try_answer_circle() -> void:
	var n := _nearest_of(_circles)
	if n < 0:
		return
	if not _can_answer(n):
		if n < Game.items_done:
			_flash_tip("Circle %d is already cleared!" % (n + 1))
		elif not Game.towers_entered[Game.station_of_item(n)]:
			_flash_tip("Enter Station %d first!" % (Game.station_of_item(n) + 1))
		else:
			_flash_tip("Answer circle %d first!" % (Game.items_done + 1))
		return
	Game.current_station = Game.station_of_item(n)
	var quiz: Control = preload("res://scripts/QuizOverlay.gd").new()
	quiz.adventure = self
	quiz.station_index = Game.current_station
	_show_overlay(quiz)


func _try_enter_gate() -> void:
	if stations.gate == null or stations.gate.position.distance_to(player.position) >= MapCfg.INTERACT_RADIUS:
		return
	if not _can_enter_gate():
		_flash_tip("Conquer all %d circles first!" % Game.TOTAL_ITEMS)
		return
	Game.end_adventure()


# --- HUD --------------------------------------------------------------------
func _build_hud() -> void:
	# The player's Camera2D transforms every canvas item in layer 0, UI included,
	# so screen-space elements have to live in their own CanvasLayers or they
	# get dragged around the world with the camera.
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 1
	add_child(_hud_layer)
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 2
	add_child(_ui_layer)
	var top := PanelContainer.new()
	top.position = Vector2(4, 4)
	top.custom_minimum_size = Vector2(632, 44)
	top.add_theme_stylebox_override("panel", Art.panel("res://assets/ui/BigBar_Base.png", Vector2(10, 2), 0.5))
	_hud_layer.add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	top.add_child(row)

	var av := Art.texrect("res://assets/ui/Avatar_01.png", 32, 32)
	row.add_child(av)
	var name_col := VBoxContainer.new()
	var nm := Art.label(Game.player_name, 13, Color("ffe9a8"))
	name_col.add_child(nm)
	var cls := Art.label("Adventurer #%d" % Game.hero_id, 11, Color(1, 1, 1, 0.8))
	name_col.add_child(cls)
	row.add_child(name_col)

	var stats := VBoxContainer.new()
	stats.alignment = BoxContainer.ALIGNMENT_CENTER
	stats.custom_minimum_size = Vector2(150, 0)
	_hud_station = Art.label("Station 1", 13, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	stats.add_child(_hud_station)
	_hud_pips = Art.label("— — —", 13, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	stats.add_child(_hud_pips)
	row.add_child(stats)

	row.add_child(Control.new()) # spacer
	var gems_icon := Art.texrect("res://assets/ui/Icon_03.png", 26, 26)
	row.add_child(gems_icon)
	var gems_col := VBoxContainer.new()
	_hud_gems = Art.label("50", 15, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	gems_col.add_child(_hud_gems)
	_hud_time = Art.label("10:00", 13, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	gems_col.add_child(_hud_time)
	row.add_child(gems_col)

	# Full-width, not centre-anchored: PRESET_CENTER_BOTTOM puts the box's left
	# edge at mid-screen, so a 640-wide label started in the middle and ran off
	# the right edge -- centred text ended up hanging off the screen.
	_prompt = Art.label("", 15, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_prompt.offset_top = -104.0
	_prompt.offset_bottom = -74.0
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(_prompt)

	var keys := ("joystick — move   ·   GO — enter   ·   MENU / back — pause" if Game.touch
			else "WASD / arrows — move   ·   E — interact   ·   Esc — menu")
	var hint_bar: Label = Art.label(keys, 12,
			Color(1, 1, 1, 0.75), HORIZONTAL_ALIGNMENT_CENTER)
	if Game.touch:
		hint_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		hint_bar.offset_top = 52.0
		hint_bar.offset_bottom = 76.0
	else:
		hint_bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		hint_bar.offset_top = -40.0
		hint_bar.offset_bottom = -16.0
	hint_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(hint_bar)
	_hint_bar = hint_bar

	# Both float over open terrain, so they need a shadow to stay readable.
	for l in [_prompt, hint_bar]:
		Art.shadow(l)

	var gemrow := HBoxContainer.new()
	gemrow.position = Vector2(4, 50)
	gemrow.add_theme_constant_override("separation", 4)
	_hud_layer.add_child(gemrow)
	# SmallBar_Fill is a 3px sliver and SmallBar_Base a 3x1 patch; they never
	# lined up as a TextureProgressBar. A flat gauge in the pack's palette is
	# both correct at any size and legible at a glance.
	_gem_bar = ProgressBar.new()
	_gem_bar.custom_minimum_size = Vector2(140, 10)
	_gem_bar.show_percentage = false
	_gem_bar.max_value = 100.0
	_gem_bar.value = 0.0
	var trough := StyleBoxFlat.new()
	trough.bg_color = Color(0.08, 0.06, 0.10, 0.75)
	trough.set_corner_radius_all(4)
	trough.set_border_width_all(1)
	trough.border_color = Color(0, 0, 0, 0.6)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Pal.GOLD
	fill.set_corner_radius_all(4)
	_gem_bar.add_theme_stylebox_override("background", trough)
	_gem_bar.add_theme_stylebox_override("fill", fill)
	gemrow.add_child(_gem_bar)
	_build_touch_pad()
	# The cheat drawer, and only where cheating is free: a release export never
	# builds the node, so there is nothing in it to reach.
	if OS.is_debug_build():
		_dev = preload("res://scripts/DevDrawer.gd").new()
		_ui_layer.add_child(_dev)
		_dev.setup(self)


# --- Touch controls ---------------------------------------------------------
## The stick is a raw-touch Node2D (its own finger index, like TouchScreenButton
## tracks), and GO/MENU stay TouchScreenButtons -- both read real touch rather
## than mouse-emulated, so steering and pressing GO work on separate fingers at
## once. Each feeds a real InputMap action (the stick with analog strength), so
## `_process` and `_unhandled_input` stay untouched.
func _build_touch_pad() -> void:
	if not Game.touch:
		return
	_touch_pad = Node2D.new()
	_hud_layer.add_child(_touch_pad)
	# Kept a thumb's width off the bottom edge: that strip is Android's
	# swipe-up-home gesture zone, immersive mode or not.
	_joystick = preload("res://scripts/Joystick.gd").new()
	_touch_pad.add_child(_joystick)
	_touch_btn("interact", "GO", Vector2(574, 290), 0.52, 20, false)
	_touch_btn("pause", "MENU", Vector2(606, 74), 0.34, 11, true)


func _touch_btn(action: String, text: String, center: Vector2, s: float, font: int, red: bool) -> void:
	var skin := "res://assets/ui/Small%sRoundButton_%s.png"
	var col := "Red" if red else "Blue"
	var b := TouchScreenButton.new()
	b.texture_normal = Art.tex(skin % [col, "Regular"])
	b.texture_pressed = Art.tex(skin % [col, "Pressed"])
	b.action = action
	b.passby_press = true   # a thumb sliding onto GO/MENU still presses it
	# The art is 128px drawn from the node's origin, so the hit circle is its
	# own centre at full size and rides `scale` down with the sprite.
	var circle := CircleShape2D.new()
	circle.radius = 64.0
	b.shape = circle
	b.shape_centered = true
	b.scale = Vector2(s, s)
	b.position = center - Vector2(64.0, 64.0) * s
	b.modulate.a = 0.8
	_touch_pad.add_child(b)
	var l := Art.label(text, font, Color(1, 1, 1, 0.95), HORIZONTAL_ALIGNMENT_CENTER)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size = Vector2(80, 24)
	l.position = center - Vector2(40, 12)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Art.shadow(l)
	_touch_pad.add_child(l)


## The drawer stays out of the way of anything that wants the whole screen.
func _close_dev() -> void:
	if _dev != null and is_instance_valid(_dev):
		_dev.close()


## Hiding a TouchScreenButton releases its action on its own; the stick is a
## plain Node2D, so a held drag needs the same release told explicitly, or it
## would survive into a quiz or the pause menu.
func _set_pad(on: bool) -> void:
	if _touch_pad != null:
		_touch_pad.visible = on
	if not on and _joystick != null:
		_joystick.release()


func _flash_tip(text: String) -> void:
	if not is_instance_valid(_prompt):
		return
	_flash_active = true
	Art.toast(_prompt, text, 1.2, "", func() -> void: _flash_active = false)


func _on_gems(g: int) -> void:
	if is_instance_valid(_hud_gems):
		_hud_gems.text = str(g)
	var ratio := clampf(float(g) / float(Game.START_GEMS + 60), 0.0, 1.0)
	if is_instance_valid(_gem_bar):
		_gem_bar.value = 100.0 * ratio


func _on_time(sec: int) -> void:
	if is_instance_valid(_hud_time):
		_hud_time.text = Ui.mmss(sec)


func _refresh_hud() -> void:
	_on_gems(Game.gems)
	_on_time(int(ceilf(Game.time_left)))
	var next := Game.completed_stations.find(false)
	if Game.items_done >= Game.TOTAL_ITEMS:
		_hud_station.text = "Victory Gate!"
	else:
		var st := Game.station_of_item(Game.items_done)
		_hud_station.text = "Station %d · %d/%d" % [st + 1,
				Game.item_in_station(Game.items_done), Game.ITEMS_PER_STATION[st]]
	var marks := ""
	for i in Game.ITEMS_PER_STATION.size():
		marks += ["✓", "★", "—"][ 0 if Game.completed_stations[i] else (1 if Game.perfect_stations[i] else 2) ] + " "
	_hud_pips.text = marks.strip_edges()
	# Label the boards on the map itself, otherwise all three look identical.
	for i in stations.locks.size():
		var mark := "—"
		if Game.completed_stations[i]:
			mark = "★" if Game.perfect_stations[i] else "✓"
		elif i == next:
			mark = "▶"
		stations.locks[i].text = "Station %d  %s" % [i + 1, mark]


## Locked / current / done for all forty, after every resolved item.
func _refresh_circles() -> void:
	for n in _circles.size():
		var state := "locked"
		if n < Game.items_done:
			state = "done"
		elif _can_answer(n):
			state = "current"
		(_circles[n] as Node2D).set_state(state)


## Android's back button, routed here by Main: leaving a station mid-question
## is not on offer, so back opens the pause menu instead.
func go_back() -> void:
	if _overlay == null and not _paused and not _frozen:
		_toggle_pause()


func _toggle_pause() -> void:
	if _paused:
		return
	_paused = true
	_close_card()
	_close_dev()
	_set_pad(false)
	var menu := Ui.panel(Vector2(300, 250), "Paused")
	menu.position = Vector2(170, 46)
	_ui_layer.add_child(menu)
	var box: VBoxContainer = menu.get_child(0) as VBoxContainer
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	# label, kind, height, screen to open ("" = stay on the map), what to do with
	# the run in progress.
	for spec in [["Resume", Ui.BLUE, 44, "", ""], ["Home", Ui.SMALL, 38, "title", "end"],
			["Restart", Ui.SMALL, 38, "adventure", "restart"],
			["Leaderboard", Ui.SMALL_RED, 38, "board", ""],
			["New Game", Ui.SMALL_RED, 38, "hero", "abandon"]]:
		var b := Ui.button(spec[0], 170, spec[2], spec[1])
		b.pressed.connect(_leave_pause.bind(menu, spec[3], spec[4]))
		box.add_child(b)


## Every pause exit closes the menu. `drop` decides the fate of the run in
## progress -- "end" scores it, "restart" and "abandon" discard it unscored --
## and `screen` where to go next. Restart rebuilds the island, because `open()`
## remakes the screen, and the gems go back to the starting purse.
func _leave_pause(menu: Control, screen: String, drop: String) -> void:
	_paused = false
	_set_pad(true)
	menu.queue_free()
	match drop:
		"end": Game.end_adventure()
		"restart": Game.restart_adventure()
		"abandon": Game.abandon_adventure()
	if screen != "":
		main.open(screen)


# --- Quiz overlay -----------------------------------------------------------
func _show_overlay(overlay: Control) -> void:
	_overlay = overlay
	_close_card()
	_close_dev()
	_set_pad(false)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.focus_mode = Control.FOCUS_ALL
	_ui_layer.add_child(overlay)
	overlay.setup({})
	overlay.grab_focus()


func close_overlay() -> void:
	if _overlay != null:
		# A briefing overlay unlocks its station's circles on the way out.
		if bool(_overlay.get("intro_only")):
			Game.towers_entered[int(_overlay.get("station_index"))] = true
		_overlay.queue_free()
		_overlay = null
		_set_pad(true)
		_refresh_hud()
		_refresh_circles()
		barricades.refresh()
	# Clearing the board no longer ends the run on its own -- the Victory Gate
	# does, and walking to it is the last step of the player flow.


func _on_adventure_end(result: Dictionary) -> void:
	if _overlay != null:
		close_overlay()
	_paused = false
	main.open("summary", result)
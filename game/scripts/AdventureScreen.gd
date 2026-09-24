extends Control

## The Adventure Map: the client's board laid over a Tiny Swords island --
## base camp, Station 1, its circles, Station 2, its circles, Station 3, its circles,
## Victory Gate, all on one authored path. One circle is one question item, and
## they resolve strictly in order. WASD/arrows move the hero; E (or Space/Enter)
## enters the tower you stand at, answers the circle you stand on, or walks
## through the gate once all of Game.TOTAL_ITEMS are cleared.
##
## This screen owns the walk and the play -- gating, targeting, input, the
## camera, the quiz handoff. It builds nothing itself: `map/MapBuilder.gd`
## lays the ground and works out where every stop is, `map/Stations.gd` puts
## the buildings up, `map/Barricades.gd` the fences and their guards,
## `map/Decor.gd` everything growing, and they all write into one
## `map/MapGrid.gd`. `AdventureHud.gd` owns everything drawn over the top.
## Every knob any of them reads is in `config/MapCfg.gd`.
##
## **What the dev drawer, the tools and the headless suites reach for.** This
## is a deliberate surface, not an accident -- it used to be thirty private
## members, which is what made the file unsafe to touch:
##
##   grid, builder, stations, barricades, decor, hud   the six above
##   world, player, main                               the scene
##   setup(), go_back(), skip_intro(), close_overlay() the screen's own API
##   _circles                                          the PathCircle nodes
##   _can_enter_tower/_can_answer/_can_enter_gate      the gating predicates
##   _try_enter_station/_try_answer_circle/            pressing E at a stop,
##       _try_enter_gate                               without a real keypress
##   _refresh_circles()                                after progress is made
##
## `tools/board_dump.gd` reads most of it, which is what proves a refactor here
## moved nothing: take a dump before and after and diff them.

var main: Control

var world: Node2D
var player: Node2D

## Everything drawn over the board. See `AdventureHud.gd`.
var hud: AdventureHud

## Every cell and every box on the board. See `map/MapGrid.gd`.
var grid := MapGrid.new()
## The four that build it, in the order `setup()` runs them. Each owns one
## concern and writes into `grid`; this screen owns the walk and the play.
var builder: MapBuilder
var stations: Stations
var barricades: Barricades
var decor: Decor

var _circles: Array = []        # Game.TOTAL_ITEMS PathCircle nodes, path order
## Everyone else in the session, drawn where their `items_done` puts them.
var _peers: Peers = null
## The session has ended and we are on our way out; arriving twice must not
## score the run twice.
var _ending := false
var _cam: Camera2D
var _bang: Label = null         # the "!" over the hero when something is in reach

var _overlay: Control = null
var _frozen := false                    # the aerial POV before the adventure starts
## Online, only the admin's Start Game releases the board.
var _wait_for_admin := false
var _intro_tw: Tween = null
var _start_hint: Label = null   # "Tap anywhere to start" -- freed once it does
var _card: Control = null       # the tapped circle's info card
## Dev knobs the drawer drives: a walk-speed multiplier, and the flag that stops
## `_process()` dragging the camera back to the hero while the board is framed.
var _speed_mult := 1.0
var _dev_aerial := false
var _hero_scale := MapCfg.UNIT_SCALE   # live-tunable with [ and ], see _nudge_hero_scale()
## How much one press of [ or ] moves the hero's scale, and the range it may
## roam over while you pick a number by eye.
const HERO_SCALE_STEP := 0.1
const HERO_SCALE_RANGE := Vector2(0.5, 3.0)


## The admin owns the clock. Online, the board waits for their Start Game
## rather than for a tap, their pause reaches every phone at once, and the
## countdown is read off the session row instead of a local timer -- SPECS §3,
## "durungan an ira pag-answer dapat".
##
## With no backend none of this happens and the tap-to-start stand-in remains,
## which is what an offline dev run and the headless suites use.
func _sync_session() -> void:
	if not (Net.configured() and Net.signed_in()):
		return
	var live: Dictionary = await Teams.live_session()
	if live.error != "" or not is_instance_valid(self):
		return
	_wait_for_admin = true
	Game.apply_session(live.session)
	_apply_session_state()

	# The server owns the arithmetic; the local sum was only ever so the result
	# overlay does not wait on a round trip.
	Game.scored.connect(_on_scored)

	var sid: String = str(live.session.get("id", ""))
	var rt: Realtime = Net.realtime()
	rt.changed.connect(_on_session_row)
	rt.watch("sessions", "id=eq." + sid)
	# Everyone else in this session, on this board. Scoped to the session, so
	# the fan-out is the session's size -- see `Teams.everyone()` for the
	# number that decides whether this stays affordable.
	rt.watch("members", "session_id=eq." + sid)


## Forward a scoring event to the function that owns it, then take the
## server's number back. Usually identical; when it is not, this is where a
## phone that got out of step comes back into line.
func _on_scored(kind: String, flag: bool) -> void:
	if Game.session_id == "":
		return
	var reply: Dictionary
	match kind:
		"answer": reply = await Scores.apply_answer(Game.session_id, flag)
		"hint": reply = await Scores.spend_hint(Game.session_id)
		"skip": reply = await Scores.skip_item(Game.session_id)
		"station": reply = await Scores.finish_station(Game.session_id, flag)
	if reply.error != "" or (reply.row as Dictionary).is_empty():
		return
	var server_gems: int = int((reply.row as Dictionary).get("gems", Game.gems))
	if server_gems != Game.gems:
		Game.gems = server_gems
		Game.gems_changed.emit(Game.gems)


func _on_session_row(table: String, _type: String, record: Dictionary) -> void:
	if not is_instance_valid(self):
		return
	if table == "members":
		_refresh_peers()
		return
	if table == "sessions" and record.is_empty():
		# The row was deleted out from under everyone -- the teacher tearing
		# the session down counts as ending it.
		_leave_ended()
		return
	if table != "sessions":
		return
	Game.apply_session(record)
	_apply_session_state()


## Where everybody else has got to. `items_done` is the position and it is
## already being written by `apply_answer`, so this adds no writes -- it only
## listens to what the scoring was sending anyway.
func _refresh_peers() -> void:
	if Game.session_id == "":
		return
	var rows: Array = await Teams.everyone(Game.session_id)
	if not is_instance_valid(self) or _circles.is_empty():
		return
	if _peers == null or not is_instance_valid(_peers):
		_peers = Peers.new()
		world.add_child(_peers)
	var anchors: Array = []
	for c in _circles:
		anchors.append((c as Node2D).position)
	var gate_at: Vector2 = stations.gate.position if stations.gate != null else anchors[-1]
	_peers.refresh(rows, anchors, gate_at, Net.user_id)


## The run is over and it was not this player's doing, so say so and score
## what they have. Guarded, because the state can arrive twice -- once from
## the fetch and once from the socket -- and ending twice would score twice.
func _leave_ended() -> void:
	if _ending:
		return
	_ending = true
	hud.flash("The adventure has ended")
	await get_tree().create_timer(1.6).timeout
	if not is_instance_valid(self):
		return
	if Game.adventure_active:
		Game.end_adventure()      # opens the summary through `_on_adventure_end`
	else:
		main.open("home")


## One place deciding what the session's state means on the board.
func _apply_session_state() -> void:
	match Game.session_state:
		"running":
			hud.paused = false
			if _frozen:
				_swoop()
			else:
				hud.set_prompt("")
		"paused":
			# `hud.paused` is what stops the hero walking; the clock is already
			# stopped by `apply_session`.
			hud.paused = true
			hud.set_prompt("Paused by your teacher")
		"ended":
			hud.paused = true
			hud.set_prompt("Your teacher ended the adventure")
			_leave_ended()
		_:
			hud.paused = true
			if is_instance_valid(_start_hint):
				_start_hint.text = "Waiting for your teacher to start"


## The admin's questions for this run. A failure is reported, not swallowed:
## a silent fall back to the generator is exactly the substitution SPECS §10
## Phase 3 forbids, and the teacher would never know it happened.
func _load_bank() -> void:
	var err: String = await QuestionStore.load_bank()
	if err != "" and is_instance_valid(hud):
		hud.flash("Could not load the question bank — " + err)


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# A bare Control defaults to MOUSE_FILTER_STOP, which swallows every click or
	# tap right here as "handled" before _unhandled_input ever sees it -- taps on
	# the board (start, circle cards) would silently do nothing. The HUD buttons
	# and panels are their own Controls with their own filters, unaffected by this.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud = AdventureHud.new(self)
	hud.build()
	# Fetched once, while the board builds and the aerial view holds -- long
	# before the hero can reach a circle, so the wait costs nobody anything.
	_load_bank()
	_sync_session()
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
	Game.time_changed.connect(hud.on_time)
	Game.gems_changed.connect(hud.on_gems)
	Game.adventure_ended.connect(_on_adventure_end)
	hud.refresh()
	_refresh_circles()
	# After the circles exist: `_sync_session()` starts before the board is
	# built, and an early call found no anchors and drew nobody.
	_refresh_peers()
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
	Game.time_changed.disconnect(hud.on_time)
	Game.gems_changed.disconnect(hud.on_gems)
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
## Framed against the viewport, not `Pal.CANVAS`: with `keep_height` the canvas
## is 640 wide at 16:9 and ~800 at 20:9, and a constant would have cropped the
## board on one phone and floated it on another.
func _aerial_zoom() -> float:
	var view := get_viewport_rect().size
	return minf(view.x / float(MapCfg.WORLD_W * MapCfg.TILE),
			view.y / float(MapCfg.WORLD_H * MapCfg.TILE))


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
	hud.set_pad(false)
	_cam.position_smoothing_enabled = false
	_clamp_cam(false)
	var z := _aerial_zoom()
	_cam.zoom = Vector2(z, z)
	_cam.position = Vector2(MapCfg.WORLD_W * MapCfg.TILE * 0.5, MapCfg.WORLD_H * MapCfg.TILE * 0.5)
	hud.set_prompt("Scouting the board...")
	# The controls crib goes with the joystick -- there is nothing to drive yet.
	hud.set_crib(false)
	# Right under the prompt, lower centre -- nothing sits on the board itself.
	_start_hint = Art.label("Waiting for your teacher to start" if _wait_for_admin
			else "Tap anywhere to start", 13, Color(1, 1, 1, 0.85), HORIZONTAL_ALIGNMENT_CENTER)
	_start_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_start_hint.offset_top = -74.0
	_start_hint.offset_bottom = -50.0
	_start_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.ui_layer.add_child(_start_hint)


## The transition: the POV comes down onto the board and the hero.
func _swoop() -> void:
	if not _frozen:
		return
	_drop_start_hint()
	hud.set_prompt("")
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
	hud.set_crib(true)
	_frozen = false
	Game.clock_paused = false
	_cam.zoom = Vector2(MapCfg.PLAY_ZOOM, MapCfg.PLAY_ZOOM)
	_clamp_cam(true)
	_cam.position = player.position
	_cam.position_smoothing_enabled = true
	hud.set_pad(true)
	hud.set_prompt("")
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
	if hud.paused or _frozen or not Game.adventure_active:
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


## Why pressing E / GO on `target` would not work right now. Empty means it
## would. The one place that decides: the line under your feet and the toast you
## get for pressing anyway both come from here, so they cannot drift apart --
## they used to be the same three-case ladder written twice, in two wordings.
func _gate_reason(target: Dictionary) -> String:
	if _can_act_on(target):
		return ""
	match target.get("kind", ""):
		"tower":
			var i: int = target.index
			if Game.items_done >= Game.TOTAL_ITEMS:
				return "Every circle is cleared — head for the Victory Gate"
			if Game.towers_entered[i]:
				return "Station %d is briefed — answer its circles" % (i + 1)
			return "Complete Station %d first" % (Game.station_of_item(Game.items_done) + 1)
		"circle":
			var n: int = target.index
			if n < Game.items_done:
				return "Circle %d is already cleared" % (n + 1)
			if not Game.towers_entered[Game.station_of_item(n)]:
				return "Enter Station %d first" % (Game.station_of_item(n) + 1)
			return "Answer circle %d first" % (Game.items_done + 1)
		"gate":
			return "Conquer all %d circles first" % Game.TOTAL_ITEMS
	return ""


func _prompt_for(target: Dictionary) -> String:
	var kind := str(target.get("kind", ""))
	if kind == "":
		return ""
	if not _can_act_on(target):
		return _gate_reason(target)
	var go := "Tap GO" if Game.touch else "Press E / Space / Enter"
	match kind:
		"tower": return "%s — enter Station %d" % [go, int(target.index) + 1]
		"circle": return "%s — Answer Quest!" % go
		"gate": return "%s — enter the Victory Gate" % go
	return ""


func _update_interaction() -> void:
	var target := _nearest_target()
	_bang.visible = _can_act_on(target)
	# The "!" is a separate channel from the prompt line: a toast owning the line
	# has no business freezing it, so it keeps tracking what is in reach.
	hud.set_prompt(_prompt_for(target))


func _unhandled_input(event: InputEvent) -> void:
	if _overlay != null or hud.paused:
		return
	var tap := ((event is InputEventMouseButton
					and (event as InputEventMouseButton).pressed
					and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT)
			or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed))
	if _frozen:
		# Any tap, click or interact press starts the adventure -- nothing to
		# inspect yet, the whole board is the thing being looked at. Online
		# it is the admin's Start Game that does this, and a student tapping
		# their way in early would be the one thing the shared clock forbids.
		if not _wait_for_admin and (tap or event.is_action_pressed("interact")):
			_swoop()
		return
	if tap:
		_tap_at((event as InputEventWithModifiers).position if event is InputEventMouseButton
				else (event as InputEventScreenTouch).position)
		return
	# Dev sizing knob: [ shrinks the hero, ] grows him, and the toast prints the
	# number to bake into MapCfg.UNIT_SCALE.
	if event is InputEventKey and (event as InputEventKey).pressed:
		match (event as InputEventKey).keycode:
			KEY_BRACKETLEFT:
				_nudge_hero_scale(-HERO_SCALE_STEP)
				return
			KEY_BRACKETRIGHT:
				_nudge_hero_scale(HERO_SCALE_STEP)
				return
	if event.is_action_pressed("interact"):
		_interact()
	elif event.is_action_pressed("pause"):
		hud.open_menu()


## Dev-only sizing knob: [ shrinks, ] grows, the readout is the number to bake
## back into UNIT_SCALE once something looks right. Rescales in place, so it is
## visible mid-walk without a restart.
func _nudge_hero_scale(delta: float) -> void:
	_hero_scale = clampf(_hero_scale + delta, HERO_SCALE_RANGE.x, HERO_SCALE_RANGE.y)
	var spr: AnimatedSprite2D = player.get_node("Spr")
	spr.scale = Vector2(_hero_scale, _hero_scale)
	hud.flash("Hero scale: %.1f  (MapCfg.UNIT_SCALE is %.1f)" % [_hero_scale, MapCfg.UNIT_SCALE])


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
	hud.ui_layer.add_child(card)
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
	_act_on(_nearest_target())


## Do the thing, or say why not. Every way of asking -- E, GO, the tap card's
## Answer Quest! -- lands here, so a blocked press always gets the same sentence
## the prompt line was already showing.
func _act_on(target: Dictionary) -> void:
	var kind := str(target.get("kind", ""))
	if kind == "" or int(target.get("index", -1)) < 0:
		return
	var why := _gate_reason(target)
	if why != "":
		hud.flash(why + "!")
		return
	match kind:
		"tower":
			Game.current_station = int(target.index)
			_open_quiz(Game.current_station, true)
		"circle":
			Game.current_station = Game.station_of_item(int(target.index))
			_open_quiz(Game.current_station, false)
		"gate":
			Game.end_adventure()


## The briefing card (`intro_only`) or one question. Same overlay either way.
func _open_quiz(station: int, intro_only: bool) -> void:
	var quiz: Control = preload("res://scripts/QuizOverlay.gd").new()
	quiz.adventure = self
	quiz.station_index = station
	quiz.intro_only = intro_only
	_show_overlay(quiz)


# The three below are how everything other than `_interact()` reaches `_act_on`:
# the tap card, and the headless suites, which teleport the hero onto a stop and
# then press. Each names the kind it means rather than asking what is nearest.
## The tower briefing: the station intro card, and nothing else. Its circles are
## what ask the questions.
func _try_enter_station() -> void:
	_act_on({"kind": "tower", "index": _nearest_of(stations.nodes)})


func _try_answer_circle() -> void:
	_act_on({"kind": "circle", "index": _nearest_of(_circles)})


func _try_enter_gate() -> void:
	if stations.gate == null \
			or stations.gate.position.distance_to(player.position) >= MapCfg.INTERACT_RADIUS:
		return
	_act_on({"kind": "gate", "index": 0})


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
	if _overlay == null and not hud.paused and not _frozen:
		hud.open_menu()


# --- Quiz overlay -----------------------------------------------------------
func _show_overlay(overlay: Control) -> void:
	_overlay = overlay
	_close_card()
	hud.close_dev()
	hud.set_pad(false)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.focus_mode = Control.FOCUS_ALL
	hud.ui_layer.add_child(overlay)
	overlay.setup({})
	overlay.grab_focus()


func close_overlay() -> void:
	if _overlay != null:
		# A briefing overlay unlocks its station's circles on the way out.
		if bool(_overlay.get("intro_only")):
			Game.towers_entered[int(_overlay.get("station_index"))] = true
		_overlay.queue_free()
		_overlay = null
		hud.set_pad(true)
		hud.refresh()
		_refresh_circles()
		barricades.refresh()
	# Clearing the board no longer ends the run on its own -- the Victory Gate
	# does, and walking to it is the last step of the player flow.


func _on_adventure_end(result: Dictionary) -> void:
	if _overlay != null:
		close_overlay()
	hud.paused = false
	main.open("summary", result)
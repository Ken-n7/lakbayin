extends Control

## The match (Lakbayin, DESIGN.md 3): a world built from the match's seed, ten
## monks each holding a Filipino word, and the Monastery on the centre line.
## Walk to any monk, in any order, and write its word in Baybayin; carry what
## you answered to the Monastery and deposit it -- only deposited words count.
## The team that deposits every word first wins and ends the match; otherwise
## the clock ends it and the most words win.
##
## Practice is the same match alone and offline (`Match.practice`). Online the
## server decides every answer and deposit; this screen walks, looks, shows,
## and tells it what the player did.
##
## It builds nothing itself: `map/MapWorld.gd` lays the world out, `Match`
## holds the score, `AdventureHud.gd` draws everything over the top, and
## `MonkOverlay` is a monk's word and the keypad.
##
## **What the dev panel, the tools and the headless suites reach for:**
##   world, grid, player, hud, play, main      the scene and its state
##   setup(), go_back(), skip_intro()           the screen's own API
##   _try_monk(i), _try_deposit()               pressing E at a stop
##   finish(reason)                             ending the match

var main: Control
var world: MapWorld
var grid: MapGrid
var player: Node2D
var hud: AdventureHud
## The match: its words, who has answered what, the deposits.
var play := Match.new()

## Practice: 10 monks for 6 minutes, as a match would be.
const PRACTICE_MONKS := 10
const PRACTICE_S := 360
## How near a monk (or the Monastery) you -- or a teammate -- must come for the
## team's minimap to show it: about a screen's width.
const SEE_R := 260.0
## The aerial view at the start and the end, seconds.
const INTRO_HOLD_S := 1.6
const END_HOLD_S := 3.0

var _peers: Peers = null
var _cam: Camera2D
var _bang: Label = null         # the "!" over the hero when something is in reach
var _overlay: Control = null
var _frozen := false            # the aerial view: before the start, and at the end
var _ending := false
var _intro_tw: Tween = null
var _sky: SkyClouds = null
var _start_hint: Label = null
## Dev knobs the dev panel's Map tab drives.
var _speed_mult := 1.0
var _dev_aerial := false
## The hero's Foot box, relative to their feet (scenes/Hero.tscn).
var hero_box := Rect2()
var _hero_scale := MapCfg.UNIT_SCALE
## Team vision (DESIGN.md 3.2): monks someone on the team has come near.
var _seen := {}
var _monastery_seen := false
var _see_clock := 0.0
var _my_team_id := ""
var _session_row := {}
var _loading: Label = null
var _typing_monk := -1
var _typing_clock := 0.0
var _busy_clock := 0.0
var _typing_peers: Array[String] = []

# --- Looking around the map, as a MOBA does ---------------------------------
## A finger dragged across the board moves the camera, at the play zoom, to see
## what is really there -- the other team, the monks, the Monastery -- and the
## camera stays where it is left. Moving, GO, or the arrow on the screen's
## edge bring it home to the hero. A press only becomes a look once it has
## moved PAN_SLOP px; one that lifts before that is a tap (`_tap_at`).
const PAN_SLOP := 10.0
var _looking := false
var _look_at := Vector2.ZERO
var _press := {}


# --- Setting up ---------------------------------------------------------------
func setup(data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Taps on the board reach `_unhandled_input`; the HUD's own controls stop
	# their own.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var online := not bool(data.get("practice", false)) and Net.configured() \
		and Net.signed_in() and Game.joined_session != ""
	if online:
		_loading = Art.label("Joining the match…", Pal.H2, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
		_loading.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		_loading.grow_horizontal = Control.GROW_DIRECTION_BOTH
		Art.shadow(_loading)
		add_child(_loading)
		var why := await _join_online()
		if not is_instance_valid(self):
			return
		if why != "":
			_loading.text = why
			await get_tree().create_timer(1.8).timeout
			if is_instance_valid(self):
				main.open("room" if Game.joined_code != "" else "team")
			return
		_loading.queue_free()
	else:
		Game.begin_adventure(PRACTICE_S)
		play.start_practice(randi() % 1000000 + 1, PRACTICE_MONKS)
	_build()
	if online:
		_go_live()
	_start_intro()


## The match this phone joined: its row, its words and teams, every answer so
## far. "" or why not.
func _join_online() -> String:
	var session: Dictionary = await Teams.session(Game.joined_session)
	if session.is_empty() or Teams.expired(session):
		Game.joined_session = ""
		Game.save_profile()
		return "That match is over."
	var err: String = await play.start_online(str(session.id))
	if err != "":
		return err
	Game.begin_adventure(int(session.get("duration_s", PRACTICE_S)))
	_session_row = session.duplicate()
	Game.apply_session(session)
	_my_team_id = play.team_ids[play.team] if play.team < play.team_ids.size() else ""
	return ""


func _build() -> void:
	_sky = SkyClouds.new()
	_sky.layer = 1
	add_child(_sky)
	world = MapWorld.new()
	world.seed = play.seed
	world.monk_count = play.monk_count()
	add_child(world)
	world.build()
	grid = world.grid
	hud = AdventureHud.new(self)
	hud.build()
	hud.minimap.set_land(world.gen.land)
	hud.minimap.source = _minimap_points
	_spawn_player()
	for band in world.cloud_bands:
		band.keep_clear = [player]
	Game.time_changed.connect(hud.on_time)
	Game.time_changed.connect(_time_warning)
	Game.adventure_ended.connect(_on_time_up)
	play.changed.connect(_on_play_changed)
	_on_play_changed()


func _exit_tree() -> void:
	if _frozen:
		Game.clock_paused = false
	if not play.practice:
		var rt := Net.realtime()
		if rt.presence_changed.is_connected(_refresh_busy):
			rt.presence_changed.disconnect(_refresh_busy)
		# A newer screen may already have announced itself in this frame.
		if str(rt.get("_tracked").get("sid", "")) == play.session_id \
				and str(rt.get("_tracked").get("where", "")) == "map":
			rt.untrack()
	if hud != null:
		Game.time_changed.disconnect(hud.on_time)
		Game.time_changed.disconnect(_time_warning)
		Game.adventure_ended.disconnect(_on_time_up)


func _spawn_player() -> void:
	# scenes/Hero.tscn: the shadow, the sprite, and the Foot box that is what
	# bumps into walls.
	player = load(MapCfg.HERO_SCENE).instantiate()
	player.position = world.spawn_of(play.team)
	var foot := player.get_node_or_null("Foot")
	if foot != null:
		var box := foot.get_node("Box") as CollisionShape2D
		var size := (box.shape as RectangleShape2D).size
		hero_box = Rect2((foot as Node2D).position + box.position - size * 0.5, size)
		foot.free()
	var spr: AnimatedSprite2D = player.get_node("Spr")
	spr.scale = Vector2(_hero_scale, _hero_scale)
	spr.sprite_frames = Art.walk_frames(Game.hero_sheet(Game.hero_id))
	spr.play("down")
	spr.pause()
	# "There is something here you can do." Bobs so it catches the eye.
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
	# The team's arrow over the player's own hero, in the colour the others see.
	if not play.practice:
		var arrow := Peers.team_arrow(Peers.TEAM_COLOURS[play.team])
		arrow.name = "Arrow"
		arrow.position.y = Peers.ARROW_Y
		player.add_child(arrow)
	world.add_child(player)
	_cam = Camera2D.new()
	_cam.position_smoothing_enabled = true
	_cam.position_smoothing_speed = MapCfg.CAM_SMOOTH
	_cam.position = player.position
	world.add_child(_cam)
	_clamp_cam(true)


## Camera limits, on for play and off for the aerial view: a visible rect wider
## than the limits is shoved off-centre rather than letterboxed.
func _clamp_cam(on: bool) -> void:
	_cam.limit_left = 0 if on else -MapCfg.CAM_UNCLAMPED
	_cam.limit_top = 0 if on else -MapCfg.CAM_UNCLAMPED
	_cam.limit_right = MapCfg.WORLD_W * MapCfg.TILE if on else MapCfg.CAM_UNCLAMPED
	_cam.limit_bottom = MapCfg.WORLD_H * MapCfg.TILE if on else MapCfg.CAM_UNCLAMPED


## Frames the whole world, against the viewport (the canvas is 640 wide at
## 16:9 and ~800 at 20:9).
func _aerial_zoom() -> float:
	var view := get_viewport_rect().size if is_inside_tree() else Vector2(Pal.CANVAS)
	return minf(view.x / float(MapCfg.WORLD_W * MapCfg.TILE),
			view.y / float(MapCfg.WORLD_H * MapCfg.TILE))


# --- Online -------------------------------------------------------------------
## The socket: the session (the end), the members (who is here), the answers
## (a teammate's greys a monk out); positions on the snapshot channel, and the
## movement relay when one runs.
func _go_live() -> void:
	var sid := play.session_id
	var rt: Realtime = Net.realtime()
	if not rt.changed.is_connected(_on_row):
		rt.changed.connect(_on_row)
	if not rt.subscribed.is_connected(_resync):
		rt.subscribed.connect(_resync)
	if not rt.position.is_connected(_on_position):
		rt.position.connect(_on_position)
	rt.watch("sessions", "id=eq." + sid)
	rt.watch("members", "session_id=eq." + sid)
	rt.watch("monk_answers", "session_id=eq." + sid)
	if not rt.presence_changed.is_connected(_refresh_busy):
		rt.presence_changed.connect(_refresh_busy)
	_publish_activity(-1)
	rt.watch_positions([Realtime.snap_topic(sid)])
	var relay := Net.relay()
	if not relay.snap.is_connected(_on_relay_snap):
		relay.snap.connect(_on_relay_snap)
	relay.join(sid, "player", Game.hero_id)
	_refresh_peers()


func _on_row(table: String, type: String, record: Dictionary) -> void:
	if not is_instance_valid(self) or play.practice:
		return
	match table:
		"monk_answers":
			if str(record.get("session_id", "")) == play.session_id:
				var was := play.deposited(1 - play.team)
				play.take_row(type, record)
				var now := play.deposited(1 - play.team)
				if now > was:
					hud.announce("%s deposited — %d of %d" % [Match.TEAMS[1 - play.team], now, play.monk_count()])
		"members":
			if str(record.get("session_id", "")) == play.session_id:
				_refresh_peers()
		"sessions":
			if str(record.get("id", "")) != play.session_id:
				return
			_session_row = record.duplicate()
			if str(record.get("state", "")) == "ended":
				var won := play.team_ids.find(str(record.get("winner_team", "")))
				play.winner = won
				finish("finished" if won >= 0 else "ended")
			else:
				Game.apply_session(record)


## Back from a drop: whatever happened meanwhile, read again.
func _resync() -> void:
	if play.practice or _ending:
		return
	await play.reload()
	var session: Dictionary = await Teams.session(play.session_id)
	if is_instance_valid(self) and not session.is_empty():
		_on_row("sessions", "UPDATE", session)


var _peers_loading := false


func _refresh_peers() -> void:
	if play.practice or _peers_loading:
		return
	_peers_loading = true
	var rows: Array = await Teams.everyone(play.session_id)
	if not is_instance_valid(self):
		return
	_peers_loading = false
	if _peers == null or not is_instance_valid(_peers):
		_peers = Peers.new()
		_peers.set_team_order(play.team_ids)
		world.add_child(_peers)
	_peers.refresh(rows, [world.door()], world.door(), Net.user_id)
	_typing_peers.clear()
	for row: Dictionary in rows:
		var id := str(row.get("profile_id", ""))
		if id != "" and id != Net.user_id and str(row.get("team_id", "")) == _my_team_id:
			_typing_peers.append(id)
	_refresh_busy()


func _publish_activity(monk: int) -> void:
	_typing_monk = monk
	_typing_clock = 0.0
	if play.practice or _ending or not is_inside_tree():
		return
	var meta := {"sid": play.session_id, "where": "map", "name": Net.username}
	if monk >= 0:
		meta["typing_monk"] = monk
		meta["typing_until"] = Game.now() + MonkActivity.TTL
	Net.realtime().track(meta)


func _tick_activity(delta: float) -> void:
	if play.practice or _ending:
		return
	_typing_clock += delta
	_busy_clock += delta
	if _typing_monk >= 0 and _typing_clock >= MonkActivity.REFRESH_S:
		_publish_activity(_typing_monk)
	if _busy_clock >= 1.0:
		_busy_clock = 0.0
		_refresh_busy()


func _refresh_busy() -> void:
	if play.practice or world == null or _ending:
		return
	var active := MonkActivity.active(Net.realtime().online, _typing_peers,
		play.session_id, play.monk_count(), Game.now())
	for i in world.monks.size():
		world.monks[i].set_busy(active.has(i) and not play.ours(i))


## Where this hero is, for everybody else's board: the path walked, sampled
## every SAMPLE_S, sent as one bundle every BUNDLE_S on the match's snapshot
## channel (a snapshot of one: there is no teacher to gather them) -- or to the
## movement relay, sample by sample, when one is up. Peers plays it back.
const SAMPLE_S := 0.1
## ponytail: players x players deliveries -- a second apart keeps 3 v 3 near
## 30 a second on Supabase's free tier; run the relay for anything bigger.
const BUNDLE_S := 1.0
const BUNDLE_OVERLAP_S := 0.3
const STILL_EVERY_S := 3.0
var _path: Array = []
var _sample_clock := 0.0
var _bundle_clock := 0.0
var _moved_since_send := false
var _conn := "good"
var _conn_clock := 0.0


func _share_position(delta: float) -> void:
	if play.practice or player == null:
		return
	var relay := Net.relay()
	var now := Time.get_ticks_msec() / 1000.0
	_sample_clock -= delta
	if _sample_clock <= 0.0:
		_sample_clock = maxf(_sample_clock + SAMPLE_S, 0.0)
		var x := roundi(player.position.x)
		var y := roundi(player.position.y)
		if not _path.is_empty() and (int(_path[-1][1]) != x or int(_path[-1][2]) != y):
			_moved_since_send = true
		_path.append([now, x, y])
	var every := BUNDLE_S * (2.0 if _conn == "weak" else 1.0)
	while _path.size() > 1 and now - float(_path[0][0]) > every + BUNDLE_OVERLAP_S:
		_path.pop_front()
	if relay.up:
		_share_relay(delta, now, relay)
		# Event viewers receive snapshots without joining the movement relay.
		if not WatchFeed.has_viewers(Net.realtime().online, play.session_id):
			_bundle_clock = 0.0
			_moved_since_send = false
			return
	_bundle_clock += delta
	if not ((_moved_since_send and _bundle_clock >= every) or _bundle_clock >= STILL_EVERY_S):
		return
	if _path.is_empty():
		return
	_bundle_clock = 0.0
	_moved_since_send = false
	var xs: Array = []
	var ys: Array = []
	for q: Array in _path:
		xs.append(q[1])
		ys.append(q[2])
	Net.realtime().send_position(Realtime.snap_topic(play.session_id), {
		"sid": play.session_id,
		"p": [{"id": Net.user_id, "hero": Game.hero_id,
			"p": {"t": snappedf(float(_path[0][0]), 0.01), "dt": SAMPLE_S, "x": xs, "y": ys}}],
	}, "snap")


var _relay_clock := 0.0
var _relay_since := 0.0
var _relay_last := Vector2i(-32768, -32768)
var _relay_moving := false


## The relay's rate: a sample whenever the hero is somewhere new, one more
## where they stop, and every STILL_EVERY_S standing.
func _share_relay(delta: float, now: float, relay: RelayLink) -> void:
	var step := 1.0 / float(maxi(relay.hz, 1))
	_relay_clock -= delta
	_relay_since += delta
	if _relay_clock > 0.0:
		return
	_relay_clock = maxf(_relay_clock + step, 0.0)
	var at := Vector2i(roundi(player.position.x), roundi(player.position.y))
	var moved := at != _relay_last
	if moved or _relay_moving or _relay_since >= STILL_EVERY_S:
		relay.send_sample(now, at.x, at.y)
		_relay_moving = moved
		_relay_last = at
		_relay_since = 0.0


func _on_relay_snap(entries: Array) -> void:
	if _peers == null or not is_instance_valid(_peers):
		return
	for e: Dictionary in entries:
		_peers.move(str(e.get("id", "")), e)


func _on_position(event: String, data: Dictionary) -> void:
	if event != "snap" or str(data.get("sid", "")) != play.session_id or not is_instance_valid(self):
		return
	if _peers == null or not is_instance_valid(_peers):
		_refresh_peers()
		return
	for p: Variant in data.get("p", []):
		if p is Dictionary:
			_peers.move(str((p as Dictionary).get("id", "")), p)


func _watch_connection(delta: float) -> void:
	_conn_clock -= delta
	if _conn_clock > 0.0:
		return
	_conn_clock = 0.5
	var was := _conn
	_conn = "good" if play.practice else Net.connection()
	if _conn != was:
		hud.set_connection(_conn)


# --- The aerial view ----------------------------------------------------------
## The whole world from above, held a moment -- where the monks are, where the
## Monastery stands -- then down onto the hero. A tap goes straight down.
func _start_intro() -> void:
	_frozen = true
	Game.clock_paused = play.practice      # online the server's clock runs on
	hud.paused = true
	hud.set_pad(false)
	hud.set_crib(false)
	_cam.position_smoothing_enabled = false
	_clamp_cam(false)
	var z := _aerial_zoom()
	_cam.zoom = Vector2(z, z)
	_cam.position = Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE * 0.5
	hud.set_prompt("Find the monks!  Deposit their words at the Monastery.")
	_start_hint = Art.label("Tap to start", 13, Color(1, 1, 1, 0.85), HORIZONTAL_ALIGNMENT_CENTER)
	_start_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_start_hint.offset_top = -74.0
	_start_hint.offset_bottom = -50.0
	_start_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.ui_layer.add_child(_start_hint)
	_intro_tw = create_tween()
	_intro_tw.tween_interval(INTRO_HOLD_S)
	_intro_tw.tween_callback(_swoop)


## Down onto the hero: one eased curve for zoom and position, zoom by ratio so
## the dive is one movement, landing where the play camera will be.
func _swoop() -> void:
	if not _frozen or _ending:
		return
	if _intro_tw != null and _intro_tw.is_valid():
		_intro_tw.kill()
	_drop_start_hint()
	hud.set_prompt("")
	if main != null:
		main.music.play("journey")
	var z0 := _cam.zoom.x
	var p0 := _cam.position
	var to := _settled_cam(player.position, MapCfg.PLAY_ZOOM)
	_intro_tw = create_tween()
	_intro_tw.tween_method(func(t: float) -> void:
		var zz := z0 * pow(MapCfg.PLAY_ZOOM / z0, t)
		_cam.zoom = Vector2(zz, zz)
		var span := 1.0 / z0 - 1.0 / MapCfg.PLAY_ZOOM
		var w := (1.0 / zz - 1.0 / MapCfg.PLAY_ZOOM) / span if absf(span) > 0.0001 else 0.0
		_cam.position = to + (p0 - to) * w
		if is_instance_valid(_sky):
			_sky.progress(t),
		0.0, 1.0, MapCfg.SWOOP_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_intro_tw.tween_callback(skip_intro)


func _settled_cam(at: Vector2, zoom: float) -> Vector2:
	var half := get_viewport_rect().size / (2.0 * zoom)
	var size := Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE
	return Vector2(clampf(at.x, half.x, maxf(half.x, size.x - half.x)),
			clampf(at.y, half.y, maxf(half.y, size.y - half.y)))


func _drop_start_hint() -> void:
	if _start_hint != null and is_instance_valid(_start_hint):
		_start_hint.queue_free()
	_start_hint = null


## Collapse the intro at once -- the tail of the swoop, and what the tests
## call so nothing waits on wall-clock time.
func skip_intro() -> void:
	if not _frozen or _ending:
		return
	if _intro_tw != null and _intro_tw.is_valid():
		_intro_tw.kill()
	_intro_tw = null
	_drop_start_hint()
	if is_instance_valid(_sky):
		_sky.queue_free()
	_sky = null
	_frozen = false
	hud.paused = false
	Game.clock_paused = false
	_cam.zoom = Vector2(MapCfg.PLAY_ZOOM, MapCfg.PLAY_ZOOM)
	_clamp_cam(true)
	_cam.position = player.position
	_cam.position_smoothing_enabled = true
	hud.set_pad(true)
	hud.set_crib(true)
	hud.set_prompt("")
	_update_interaction()


# --- Walking ------------------------------------------------------------------
static func _facing(dir: Vector2) -> String:
	if absf(dir.y) >= absf(dir.x):
		return "down" if dir.y > 0.0 else "up"
	return "right" if dir.x > 0.0 else "left"


func _process(delta: float) -> void:
	if hud == null:
		return
	_watch_connection(delta)
	_share_position(delta)
	_look_for_monks(delta)
	_tick_activity(delta)
	if _overlay != null and is_instance_valid(_overlay):
		return
	if hud.paused or _frozen or _ending:
		return
	var dir := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down"))
	if _looking and dir.length_squared() > 0.001 and not bool(_press.get("panning", false)):
		end_look()
	if not _dev_aerial:
		_cam.position = _look_at if _looking else player.position
	_aim_hero_pointer()
	if dir.length_squared() > 1.0:
		dir = dir.normalized()
	var spr: AnimatedSprite2D = player.get_node("Spr")
	if dir.length_squared() > 0.001:
		# One axis at a time, so a diagonal into a wall slides along it; in
		# steps of at most 2px, so a hitched frame cannot jump a thin wall.
		var step := dir * MapCfg.PLAYER_SPEED * _speed_mult * delta
		var n := ceili(step.length() / 2.0)
		step /= n
		for _i in n:
			player.position.x += step.x
			if not grid.box_walkable(player.position, hero_box):
				player.position.x -= step.x
			player.position.y += step.y
			if not grid.box_walkable(player.position, hero_box):
				player.position.y -= step.y
		var face := _facing(dir)
		if spr.animation != face or not spr.is_playing():
			spr.play(face)
	elif spr.is_playing():
		spr.pause()
		spr.frame = 1
	_update_interaction()


## Team vision: a monk -- or the Monastery -- comes onto the team's minimap once
## anyone on the team has been within SEE_R of it. Five times a second.
func _look_for_monks(delta: float) -> void:
	_see_clock -= delta
	if _see_clock > 0.0 or player == null:
		return
	_see_clock = 0.2
	var eyes: Array[Vector2] = [player.position]
	if _peers != null and is_instance_valid(_peers) and _my_team_id != "":
		eyes.append_array(_peers.positions_of(_my_team_id))
	for i in world.monks.size():
		if _seen.has(i):
			continue
		for e in eyes:
			if e.distance_to(world.monks[i].position) < SEE_R:
				_seen[i] = true
				break
	if not _monastery_seen:
		for e in eyes:
			if e.distance_to(world.door()) < SEE_R:
				_monastery_seen = true


func _minimap_points() -> Dictionary:
	var monks: Array = []
	for i in world.monks.size():
		if play.ours(i):
			monks.append([world.monks[i].position, "ours"])
		elif _seen.has(i):
			monks.append([world.monks[i].position, "seen"])
	var mates: Array[Vector2] = []
	if _peers != null and is_instance_valid(_peers) and _my_team_id != "":
		mates = _peers.positions_of(_my_team_id)
	return {"me": player.position, "mates": mates, "monks": monks,
		"mate_colour": Peers.TEAM_COLOURS[play.team],
		"monastery": world.door() if _monastery_seen else null}


# --- Interacting --------------------------------------------------------------
## What the hero stands at: {kind: "monk", index} or {kind: "door"}, or {}.
func _nearest_target() -> Dictionary:
	var best := {}
	var best_d := MapCfg.INTERACT_RADIUS
	for i in world.monks.size():
		var d := world.monks[i].position.distance_to(player.position)
		if d < best_d:
			best_d = d
			best = {"kind": "monk", "index": i}
	if world.door().distance_to(player.position) < best_d:
		best = {"kind": "door"}
	return best


## Why pressing E / GO on `target` would not work right now; "" if it would.
func _block(target: Dictionary) -> String:
	match str(target.get("kind", "")):
		"monk":
			if play.ours(int(target.index)):
				return "Your team has this monk's word"
		"door":
			if play.carried().is_empty():
				return "Nothing to deposit — answer a monk first"
	return ""


func _prompt_for(target: Dictionary) -> String:
	var kind := str(target.get("kind", ""))
	if kind == "":
		return ""
	var why := _block(target)
	if why != "":
		return why
	var go := "Tap GO" if Game.touch else "Press E"
	if kind == "monk":
		return "%s — write this monk's word" % go
	var n := play.carried().size()
	return "%s — deposit %d word%s" % [go, n, "" if n == 1 else "s"]


func _update_interaction() -> void:
	var target := _nearest_target()
	_bang.visible = not target.is_empty() and _block(target) == ""
	hud.set_prompt(_prompt_for(target))


func _unhandled_input(event: InputEvent) -> void:
	if hud == null or _overlay != null or _ending:
		return
	var tap := ((event is InputEventMouseButton
					and (event as InputEventMouseButton).pressed
					and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT)
			or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed))
	if _frozen:
		if tap or event.is_action_pressed("interact"):
			_swoop()
		return
	var p := _pointer(event)
	if not p.is_empty():
		_on_pointer(p)
		return
	if event.is_action_pressed("interact"):
		end_look()
		_act_on(_nearest_target())


func _act_on(target: Dictionary) -> void:
	var kind := str(target.get("kind", ""))
	if kind == "":
		return
	var why := _block(target)
	if why != "":
		Sfx.play("blocked")
		hud.flash(why)
		return
	if not play.practice and _conn == "offline":
		Sfx.play("blocked")
		hud.flash("Reconnecting — wait a moment")
		return
	if kind == "monk":
		_open_monk(int(target.index))
	else:
		_deposit()


## The tests and the dev panel: press E at monk `i`, or at the door, wherever
## the hero is.
func _try_monk(i: int) -> void:
	_act_on({"kind": "monk", "index": i})


func _try_deposit() -> void:
	_act_on({"kind": "door"})


func _open_monk(i: int) -> void:
	var overlay: Control = preload("res://scripts/MonkOverlay.gd").new()
	var check := func(typed: String) -> String: return await play.answer(i, typed)
	overlay.setup({"word": play.words[i], "monk": i, "labels": play.practice, "check": check})
	overlay.activity_changed.connect(func(active: bool) -> void:
		var monk := i if active else -1
		if monk != _typing_monk:
			_publish_activity(monk))
	overlay.answered.connect(func(result: String) -> void:
		if result == "correct":
			world.monks[i].take(Match.TEAMS[play.team]))
	_overlay = overlay
	end_look()
	_press = {}
	hud.close_dev()
	hud.set_pad(false)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.tree_exited.connect(_on_overlay_gone)
	hud.ui_layer.add_child(overlay)
	_publish_activity(i)


func _on_overlay_gone() -> void:
	_overlay = null
	_publish_activity(-1)
	if not _ending and hud != null:
		hud.set_pad(true)
		_update_interaction()


func _deposit() -> void:
	var elapsed := Game.duration_seconds - Game.time_left
	var got: Dictionary = await play.deposit(elapsed)
	if not is_instance_valid(self):
		return
	if got.error != "":
		Sfx.play("error")
		hud.flash("Not deposited: " + str(got.error))
		return
	var n := int(got.deposited)
	Sfx.play("station_complete")
	hud.flash("Deposited %d word%s — %d of %d" % [n, "" if n == 1 else "s", play.deposited(), play.monk_count()])
	if play.deposited() >= play.monk_count():
		play.winner = play.team
		finish("finished")


func _on_play_changed() -> void:
	if world == null:
		return
	for i in world.monks.size():
		if play.ours(i):
			world.monks[i].take(Match.TEAMS[play.team])
	hud.refresh()
	if player != null:
		_update_interaction()


# --- Looking around ------------------------------------------------------------
## One pointer event, as {kind: down|move|up, id, pos, rel}, or {} for anything
## else. A touch's own index is its id; a real mouse is -100. The mouse a phone
## makes from a touch (DEVICE_ID_EMULATION) is dropped: the touch itself is here.
static func _pointer(event: InputEvent) -> Dictionary:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		return {"kind": "down" if t.pressed else "up", "id": t.index, "pos": t.position,
				"rel": Vector2.ZERO}
	if event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		return {"kind": "move", "id": d.index, "pos": d.position, "rel": d.relative}
	if event.device == InputEvent.DEVICE_ID_EMULATION:
		return {}
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var b := event as InputEventMouseButton
		return {"kind": "down" if b.pressed else "up", "id": -100, "pos": b.position,
				"rel": Vector2.ZERO}
	if event is InputEventMouseMotion and ((event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT):
		var m := event as InputEventMouseMotion
		return {"kind": "move", "id": -100, "pos": m.position, "rel": m.relative}
	return {}


func _on_pointer(p: Dictionary) -> void:
	match p.kind:
		"down":
			if hud.pointer_hit(p.pos):
				end_look()
				return
			if (_press.is_empty() or _press.id == p.id) and not hud.owns_touch(p.pos):
				_press = {"id": p.id, "at": p.pos, "panning": false}
		"move":
			if _press.is_empty() or p.id != _press.id:
				return
			if not _press.panning:
				if (p.pos as Vector2).distance_to(_press.at) < PAN_SLOP:
					return
				_press.panning = true
				_begin_look()
				_look_by(p.pos - _press.at)
				return
			_look_by(p.rel)
		"up":
			if _press.is_empty() or p.id != _press.id:
				return
			var was_pan: bool = _press.panning
			var at: Vector2 = _press.at
			_press = {}
			hud.set_panning(false)
			if not was_pan:
				_tap_at(at)


func _begin_look() -> void:
	hud.set_panning(true)
	if _looking:
		return
	_looking = true
	_look_at = _cam.get_screen_center_position()
	_cam.position_smoothing_enabled = false
	_cam.position = _look_at


func _look_by(screen_delta: Vector2) -> void:
	var z := _cam.zoom.x
	_look_at = _settled_cam(_look_at - screen_delta / z, z)


## Home to the hero, gliding. Safe to call when not looking.
func end_look() -> void:
	if not _looking:
		return
	_looking = false
	if _press.get("panning", false):
		_press = {}
		hud.set_panning(false)
	_cam.position_smoothing_enabled = true
	hud.point_to_hero(false)


## While looking away, the arrow on the screen's edge points at the hero.
func _aim_hero_pointer() -> void:
	if not _looking:
		return
	var view := get_viewport_rect().size
	var hero: Vector2 = get_viewport().get_canvas_transform() * player.position
	var inset := Rect2(Vector2(28, 70), view - Vector2(28 + 150, 70 + 64))
	if Rect2(Vector2.ZERO, view).grow(-16.0).has_point(hero):
		hud.point_to_hero(false)
		return
	var c := inset.get_center()
	var dir := (hero - c).normalized()
	var tx := INF if is_zero_approx(dir.x) else ((inset.end.x if dir.x > 0.0 else inset.position.x) - c.x) / dir.x
	var ty := INF if is_zero_approx(dir.y) else ((inset.end.y if dir.y > 0.0 else inset.position.y) - c.y) / dir.y
	hud.point_to_hero(true, c + dir * minf(tx, ty), dir)


## A tap on a monk or the Monastery within reach acts on it, as GO would; one
## out of reach says to walk there.
func _tap_at(screen_pos: Vector2) -> void:
	var at: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * screen_pos
	var slack := 30.0 / maxf(_cam.zoom.x, 0.01)
	for i in world.monks.size():
		if (world.monks[i].position + Vector2(0, -16)).distance_to(at) < slack:
			if world.monks[i].position.distance_to(player.position) < MapCfg.INTERACT_RADIUS:
				_act_on({"kind": "monk", "index": i})
			else:
				hud.flash("Walk up to the monk to write his word")
			return


# --- The end ------------------------------------------------------------------
## A team finished (`finished`), the clock ran out (`time`), or the session
## ended some other way: the world from above a moment, then the results.
func finish(reason: String) -> void:
	if _ending:
		return
	_ending = true
	Game.abandon_adventure()           # the clock stops here
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	hud.paused = true
	hud.set_pad(false)
	hud.set_crib(false)
	end_look()
	var won := play.winner
	var head := "Time!"
	if reason == "finished" and won >= 0:
		head = "You finished!" if play.practice else "%s wins!" % Match.TEAMS[won]
	Sfx.play("victory_gate" if won == play.team else ("time_up" if reason == "time" else "ended"))
	hud.set_prompt(head)
	if not play.practice:
		Net.relay().leave()
		Net.realtime().watch_positions([])
		Net.realtime().untrack()
		Game.joined_session = ""
		Game.save_profile()
	_frozen = true
	_cam.position_smoothing_enabled = false
	_clamp_cam(false)
	var z0 := _cam.zoom.x
	var p0 := _cam.position
	var z1 := _aerial_zoom()
	var p1 := Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE * 0.5
	var tw := create_tween()
	tw.tween_method(func(t: float) -> void:
		var zz := z0 * pow(z1 / z0, t)
		_cam.zoom = Vector2(zz, zz)
		_cam.position = p0.lerp(p1, t),
		0.0, 1.0, 1.2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_interval(END_HOLD_S)
	tw.tween_callback(func() -> void:
		if main != null:
			var got := play.result(reason == "time")
			got["custom"] = bool(_session_row.get("custom", false))
			main.open("results", got))


## The clock ran out (Game ends the adventure at 0).
func _on_time_up(_result: Dictionary) -> void:
	finish("time")


## One minute left, then each of the last ten seconds.
## Running low: a silent pop-up, not a sound.
func _time_warning(sec: int) -> void:
	if _frozen or hud == null:
		return
	if sec == 60:
		hud.announce("1 minute left!")
	elif sec == 10:
		hud.announce("10 seconds left!")


## Android's back button. Practice: back to Home. A match: there is no way out
## but playing it.
func go_back() -> void:
	if play.practice and main != null:
		Game.abandon_adventure()
		main.open("home")
	elif hud != null:
		hud.flash("The match ends when a team finishes or the clock runs out")

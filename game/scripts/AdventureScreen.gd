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
var grid: MapGrid
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
var _sky: SkyClouds = null        # the clouds the start swoop dives through
## "" while playing; "finished" or "eliminated" once this player is done but
## the session is not -- they watch, flying the map, until everyone is done.
var _spectate := ""
var _banner: Label = null
var _start_hint: Label = null   # "Tap anywhere to start" -- freed once it does
var _card: Control = null       # the tapped circle's info card
## Dev knobs the drawer drives: a walk-speed multiplier, and the flag that stops
## `_process()` dragging the camera back to the hero while the board is framed.
var _speed_mult := 1.0
## The hero's Foot box, relative to their feet, from scenes/Hero.tscn -- the
## part of them that walls stop. A point at the feet if the scene has none.
var hero_box := Rect2()
## The level the hero walks at: 0 the ground, 1 a terrace, 2 the summit
## (map/Terrain.gd). A ramp is where it changes.
var hero_level := 0
var _current_circle := -1            # the circle to answer now, -1 none
var _last_state := ""                # the session state last applied, for its sounds
var _last_gems := -1
var _dev_aerial := false

# --- Looking around the map, as a MOBA does ---------------------------------
## A finger dragged across the board moves the camera, at the play zoom, to see
## what is really there -- other teams walking, the knights, the stations -- and
## the camera stays where it is left. Moving, GO, or the arrow on the screen's
## edge bring it home to the hero.
##
## A press only becomes a look once it has moved PAN_SLOP px; one that lifts
## before that is a tap (`_tap_at`). Touches are read as raw ScreenTouch /
## ScreenDrag, so the right thumb can look while the left one steers -- the
## mouse a phone makes from a touch only ever follows the first finger, and is
## ignored here so a touch is never read twice.
const PAN_SLOP := 10.0
var _looking := false
var _look_at := Vector2.ZERO       # where the camera is looking, world px
var _press := {}                   # the pointer down on the board: {id, at, panning}
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
	if _explore or not (Net.configured() and Net.signed_in()):
		return
	# Signed in means online: whatever happens next, the board waits for the
	# teacher. Falling back to tap-to-start here let a student play a whole
	# run that no server ever scored.
	_wait_for_admin = true
	# The session this phone joined by its code -- never "the newest one
	# anywhere", which is how a leftover test session once caught a class.
	var session: Dictionary = await Teams.session(Game.joined_session)
	if not is_instance_valid(self):
		return
	if session.is_empty() or Teams.expired(session):
		_hold_offline("That adventure has ended.")
		await get_tree().create_timer(1.6).timeout
		if is_instance_valid(self):
			main.open("team")
		return
	var sid: String = str(session.get("id", ""))

	# In this session? Then pick up where the server says, which is a fresh
	# 50 gems on circle 1 for a first join and the real progress for a rejoin.
	var mine: Dictionary = await Teams.membership(sid)
	if not is_instance_valid(self):
		return
	if mine.has("error"):
		_hold_offline(str(mine.error))
		return
	if mine.is_empty() or mine.get("team_id") == null:
		_hold_offline("Pick your team first.")
		await get_tree().create_timer(1.6).timeout
		if is_instance_valid(self):
			main.open("team")
		return
	Game.restore_from(mine)
	_my_team = str(mine.get("team_id", ""))
	Game.apply_session(session)
	_apply_session_state()
	# Back after a restart already done: straight to watching.
	if bool(mine.get("finished", false)):
		_begin_spectating("finished", int(mine.get("finish_s", -1)) if mine.get("finish_s") != null else -1)
	elif bool(mine.get("eliminated", false)):
		_begin_spectating("eliminated")
	if not _circles.is_empty():
		hud.refresh()
		_refresh_circles()
		barricades.refresh()

	# The server owns the arithmetic; the local sum was only ever so the result
	# overlay does not wait on a round trip.
	if not Game.scored.is_connected(_on_scored):
		Game.scored.connect(_on_scored)

	var rt: Realtime = Net.realtime()
	if not rt.changed.is_connected(_on_session_row):
		rt.changed.connect(_on_session_row)
	# A socket that dropped and came back missed whatever happened meanwhile
	# -- a pause, a resume, the end. Read the row again rather than trust it.
	if not rt.subscribed.is_connected(_resync):
		rt.subscribed.connect(_resync)
	if not rt.broadcast.is_connected(_on_broadcast):
		rt.broadcast.connect(_on_broadcast)
	rt.watch("sessions", "id=eq." + sid)
	# Everyone else in this session, on this board. Scoped to the session, so
	# the fan-out is the session's size -- see `Teams.everyone()` for the
	# number that decides whether this stays affordable.
	rt.watch("members", "session_id=eq." + sid)
	# On the teacher's list as here, on the board -- which is what "ready" is.
	rt.track({"sid": sid, "where": "map", "name": Net.username})
	_watch_positions()
	if not rt.presence_changed.is_connected(_show_waiting):
		rt.presence_changed.connect(_show_waiting)
	_refresh_peers()


## Where this hero is, for everybody else's board. Sent a few times a second
## while walking and every few seconds standing still, so someone who opens
## the map late still sees who is standing where.
##
## Through the teacher (PosHub): each position goes on this player's own
## channel (`Realtime.in_topic`), which only the teacher joins, and comes back
## to everyone inside the teacher's snapshots (`snap_topic`). Sent to the whole
## class directly, every position reached every phone, and a class of 30 was
## cut off by Supabase's free tier. Measured (tools/sim/classroom.py --move
## --channel hub): 30 students at 0.5s, snapshots at 0.25s, 99-100% delivered,
## nothing cut. If the teacher's screen is gone, no snapshots come and heroes
## fall back to their towers (Peers.STALE_S).
## Walking: twice a second; Peers draws heroes DELAY_S behind, between two
## positions already in, so that reads as smooth. A turn or a stop goes out
## sooner, since that is exactly where a guess from the last velocity goes
## wrong -- but no faster than POS_TURN_S, or a weaving thumb is a flood.
## Standing: a keepalive.
const POS_EVERY_S := 0.5
const POS_TURN_S := 0.3
const POS_IDLE_S := 3.0
var _my_team := ""
var _pos_clock := 0.0
var _pos_idle := 0.0
var _pos_prev := Vector2.INF     # last frame's position, for the velocity
var _vel_sent := Vector2.ZERO


func _share_position(delta: float) -> void:
	if Game.session_id == "" or player == null:
		return
	_pos_clock += delta
	_pos_idle += delta
	var vel := Vector2.ZERO
	if _pos_prev != Vector2.INF and delta > 0.0:
		vel = (player.position - _pos_prev) / delta
	_pos_prev = player.position
	var turned := vel.distance_to(_vel_sent) > 20.0
	var due := (turned and _pos_clock >= POS_TURN_S) \
		or (vel != Vector2.ZERO and _pos_clock >= POS_EVERY_S) \
		or _pos_idle >= POS_IDLE_S
	if not due:
		return
	_pos_clock = 0.0
	_pos_idle = 0.0
	_vel_sent = vel
	var spr: AnimatedSprite2D = player.get_node("Spr")
	Net.realtime().send_position(Realtime.in_topic(Game.session_id, Net.user_id), {
		"sid": Game.session_id,
		"id": Net.user_id,
		"name": Net.username,
		"team": _my_team,
		"hero": Game.hero_id,
		"x": player.position.x,
		"y": player.position.y,
		# The sender's own clock, so the other boards can space positions by
		# when they happened rather than by when the network delivered them.
		"ts": Time.get_ticks_msec() / 1000.0,
		"vx": vel.x,
		"vy": vel.y,
		"face": str(spr.animation),
		"moving": vel.length() > 1.0,
	})


## This player's own channel, where its positions go, and the snapshots of
## everyone that come back from the teacher.
func _watch_positions() -> void:
	if Game.session_id == "":
		return
	Net.realtime().watch_positions([Realtime.in_topic(Game.session_id, Net.user_id),
		Realtime.snap_topic(Game.session_id)])


func _on_broadcast(event: String, data: Dictionary) -> void:
	if event == "rescue":
		_on_rescue_news(data)
		return
	if event != "snap" or str(data.get("sid", "")) != Game.session_id \
			or not is_instance_valid(self):
		return
	if _peers == null or not is_instance_valid(_peers):
		_refresh_peers()
		return
	# Everyone who moved since the teacher's last snapshot; this player too,
	# which Peers ignores.
	for p: Variant in data.get("p", []):
		if p is Dictionary:
			_peers.move(str((p as Dictionary).get("id", "")), p)


## A teammate gave this player gems (`RescueOverlay`, on their phone). The
## message only says who and how many: the gems themselves come from the
## server's copy of this player's row, the one thing that decides them, so a
## message that arrives alone -- or is not from a teammate at all -- moves no
## gems, and a lost one costs only the banner.
func _on_rescue_news(data: Dictionary) -> void:
	if not is_instance_valid(self) or str(data.get("sid", "")) != Game.session_id \
			or str(data.get("to", "")) != Net.user_id:
		return
	var amount := int(data.get("amount", 0))
	var who := str(data.get("from", "")).strip_edges()
	Sfx.play("rescue")
	hud.announce("%s rescued you!  +%d gem%s" % [who if who != "" else "A teammate",
			amount, "" if amount == 1 else "s"])


## Rescue from the map: the top bar's button. The question screen opens its own.
func open_rescue() -> void:
	var why := rescue_block()
	if _overlay != null or why != "":
		if why != "":
			hud.flash(why)
		return
	var r: Control = preload("res://scripts/RescueOverlay.gd").new()
	r.finished.connect(func(summary: String) -> void:
		if _overlay == r:
			close_overlay()
		if summary != "":
			hud.flash(summary))
	_show_overlay(r)


## Why Rescue is not on offer right now, or "". The game's own rules, plus the
## board's: the old menu that held Rescue could not open while paused, before
## the start or while watching, and the top-bar button must not either -- a
## finished player giving gems away after their finish is recorded.
func rescue_block() -> String:
	if _spectate != "":
		return "You are done — Rescue is for players still on the board"
	if _frozen:
		return "Rescue opens once the adventure starts"
	if hud != null and hud.paused:
		return "The adventure is paused"
	return Game.rescue_block()


## Online with nothing to join: say why and keep the board shut. The old
## fallback was the offline tap-to-start, i.e. an unscored run.
func _hold_offline(why: String) -> void:
	hud.paused = true
	if is_instance_valid(_start_hint):
		_start_hint.text = why
	else:
		hud.set_prompt(why)


func _resync() -> void:
	if Game.session_id == "" or not is_instance_valid(self):
		return
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		Teams.SESSIONS + "?select=*&id=eq." + Game.session_id)
	if not is_instance_valid(self) or got.error != "":
		return
	var rows: Array = got.data if got.data is Array else []
	if rows.is_empty():
		_leave_ended()
		return
	Game.apply_session(rows[0])
	_apply_session_state()
	_refresh_peers()


## Forward a scoring event to the function that owns it, then take the
## server's number back. Usually identical; when it is not, this is where a
## phone that got out of step comes back into line.
func _on_scored(kind: String, flag: bool) -> void:
	if Game.session_id != "":
		Scores.submit(kind, flag, Game.session_id, _on_score_reply)


func _on_score_reply(reply: Dictionary) -> void:
	if reply.error != "":
		Sfx.play("error")
		hud.flash("Not scored: " + reply.error)
	else:
		_take_server_row(reply.row)
		# The Gate's reply carries the time the server stamped.
		if _spectate == "finished" and reply.row.get("finish_s") != null:
			_show_banner(int(reply.row.finish_s))


## The server's copy of this player's row -- from a scoring reply or from the
## socket. Gems follow it.
func _take_server_row(row: Dictionary) -> void:
	# Only with nothing still on its way: an older reply taken over a newer
	# local sum would briefly undo it.
	if row.is_empty() or Scores.pending() > 0:
		return
	var server_gems: int = int(row.get("gems", Game.gems))
	if server_gems == Game.gems:
		return
	Game.gems = server_gems
	Game.eliminated = bool(row.get("eliminated", Game.eliminated))
	Game.gems_changed.emit(Game.gems)
	if Game.eliminated and _overlay == null:
		_begin_spectating("eliminated")


## Everything the socket says. Filters narrow what the server sends, but not
## deletes -- Realtime delivers every DELETE on a watched table whatever the
## filter -- so each row is checked against this session before it counts.
func _on_session_row(table: String, type: String, record: Dictionary) -> void:
	if not is_instance_valid(self) or Game.session_id == "":
		return
	if table == "members":
		# Deletes arrive from every session (see `Realtime._join`), so this
		# check matters for them most of all. The key carries session_id.
		if str(record.get("session_id", "")) != Game.session_id:
			return
		var pid: String = str(record.get("profile_id", ""))
		var me: bool = pid == Net.user_id
		if type == "DELETE":
			if me:
				_leave_removed()
			elif _peer_rows.erase(pid):
				_draw_peers()
			return
		if me:
			_take_team(record)
			_take_server_row(record)
		elif _peer_rows.has(pid):
			# Applied from the message -- an answer moves a marker with no
			# fetch. Only a newcomer, whose name it lacks, costs a read.
			var row: Dictionary = _peer_rows[pid]
			row.team_id = "" if record.get("team_id") == null else str(record.get("team_id"))
			for k in ["items_done", "gems", "eliminated"]:
				if record.has(k):
					row[k] = record[k]
			_draw_peers()
		else:
			_refresh_peers()
		return
	if table != "sessions" or str(record.get("id", "")) != Game.session_id:
		return
	if type == "DELETE":
		# The teacher tearing the session down counts as ending it.
		_leave_ended()
		return
	Game.apply_session(record)
	_apply_session_state()


## The teacher moved this player (before Start) or removed their team. Moved:
## say so, and positions go out under the new colour. Removed: back to the
## lobby to pick another -- still in the session, gems and all.
func _take_team(row: Dictionary) -> void:
	var team: String = "" if row.get("team_id") == null else str(row.get("team_id"))
	if team == _my_team:
		return
	_my_team = team
	_show_my_arrow()
	Sfx.play("team_changed")
	if team != "":
		hud.flash("Your Quest Keeper moved you to another team")
		return
	if _ending:
		return
	_ending = true
	hud.flash("Your team was removed — pick another")
	await get_tree().create_timer(1.6).timeout
	if is_instance_valid(self):
		main.open("team")


## This player's membership is gone -- only a deleted session takes it now,
## since removing a team leaves its players in with no team. Not scored:
## there is nothing left on the server to score against.
func _leave_removed() -> void:
	if _ending:
		return
	_ending = true
	Game.abandon_adventure()
	hud.flash("You are no longer in this adventure")
	await get_tree().create_timer(1.6).timeout
	if is_instance_valid(self):
		main.open("team")


## Where everybody else has got to. `items_done` is the position and it is
## already being written by `apply_answer`, so this adds no writes -- it only
## listens to what the scoring was sending anyway.
## profile_id -> the row `Peers` draws from, kept current off the socket.
var _peer_rows := {}
## A read in flight. Positions arrive ~7 times a second per player, and before
## the first read lands each one used to ask for another.
var _peers_loading := false


func _refresh_peers() -> void:
	if Game.session_id == "" or _peers_loading:
		return
	_peers_loading = true
	var rows: Array = await Teams.everyone(Game.session_id)
	if not is_instance_valid(self):
		return
	_peers_loading = false
	_peer_rows = {}
	for r: Dictionary in rows:
		_peer_rows[str(r.profile_id)] = r
	if _peers == null or not is_instance_valid(_peers):
		_peers = Peers.new()
		world.add_child(_peers)
		var teams: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
			"/rest/v1/teams?select=id&session_id=eq." + Game.session_id + "&order=name")
		if not is_instance_valid(_peers):
			return
		_peers.set_team_order((teams.data if teams.data is Array else []).map(
			func(t: Dictionary) -> String: return str(t.get("id", ""))))
		_show_my_arrow()
	_draw_peers()


## The team arrow over the player's own hero, in the colour their team-mates'
## phones show it (Peers' order). None without a team: solo and Explore.
func _show_my_arrow() -> void:
	if player == null:
		return
	var arrow: Node2D = player.get_node_or_null("Arrow")
	if _my_team == "" or _peers == null or not is_instance_valid(_peers):
		if arrow != null:
			arrow.visible = false
		return
	if arrow == null:
		arrow = Peers.team_arrow(Color.WHITE)
		arrow.position.y = Peers.ARROW_Y
		player.add_child(arrow)
	Peers.tint_arrow(arrow, _peers.colour_of(_my_team))
	arrow.visible = true


func _draw_peers() -> void:
	if _peers == null or not is_instance_valid(_peers) or _circles.is_empty():
		return
	var board := world as MapWorld
	_peers.refresh(_peer_rows.values(), board.peer_anchors(), board.gate_at(), Net.user_id)
	_show_waiting()      # the roster is the other half of "N of M ready"


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


## Before Start: who else has made it onto the board. The teacher's Start
## waits for all of them, so this is the line everybody is waiting on.
func _show_waiting() -> void:
	if not is_instance_valid(self) or not is_instance_valid(_start_hint) \
			or Game.session_state != "lobby":
		return
	# `_peer_rows` is everyone in the session, this player included.
	var total := maxi(_peer_rows.size(), 1)
	var ready := 0
	for pid: String in _peer_rows:
		if Net.realtime().where_is(pid, Game.session_id) == "map":
			ready += 1
	_start_hint.text = "Waiting for your Quest Keeper to start  ·  %d of %d ready" % [ready, total]


## One place deciding what the session's state means on the board.
func _apply_session_state() -> void:
	# A sound for a change of state, not for learning it on arrival.
	var was := _last_state
	_last_state = Game.session_state
	if was != "" and was != Game.session_state:
		match Game.session_state:
			"paused": Sfx.play("paused")
			"running": Sfx.play("resumed" if was == "paused" else "")
			"ended": Sfx.play("ended")
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
			hud.set_prompt("Paused by your Quest Keeper")
		"ended":
			hud.paused = true
			hud.set_prompt("Your Quest Keeper ended the adventure")
			_leave_ended()
		_:
			hud.paused = true
			_show_waiting()


## The admin's questions for this run. A failure is reported, not swallowed:
## a silent fall back to the generator is exactly the substitution SPECS §10
## Phase 3 forbids, and the teacher would never know it happened.
func _load_bank() -> void:
	var err: String = await QuestionStore.load_bank()
	if err != "" and is_instance_valid(hud):
		hud.flash("Could not load the question bank — " + err)


## Dev only: walk the board with no session -- nothing online, nothing
## scored, no teacher to wait for. Opened from the D navigator's "explore map"
## or `godot --path game -- --explore`; a release build never sets it.
var _explore := false


func setup(data: Dictionary) -> void:
	_explore = bool(data.get("explore", false)) and OS.is_debug_build()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# A bare Control defaults to MOUSE_FILTER_STOP, which swallows every click or
	# tap right here as "handled" before _unhandled_input ever sees it -- taps on
	# the board (start, circle cards) would silently do nothing. The HUD buttons
	# and panels are their own Controls with their own filters, unaffected by this.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Before the HUD, on its layer: over the board, under the HUD.
	_sky = SkyClouds.new()
	_sky.layer = 1
	add_child(_sky)
	hud = AdventureHud.new(self)
	hud.build()
	# Fetched once, while the board builds and the aerial view holds -- long
	# before the hero can reach a circle, so the wait costs nobody anything.
	_load_bank()
	_sync_session()
	if not Game.adventure_active:
		Game.begin_adventure()
	# The board itself is `MapWorld`, shared with the teacher's map view.
	var board := MapWorld.new()
	board.tower_seed = Game.board_seed()
	world = board
	add_child(world)
	board.build()
	grid = board.grid
	builder = board.builder
	stations = board.stations
	barricades = board.barricades
	decor = board.decor
	_circles = board.circles
	_spawn_player()
	var clear: Array = [player]
	for g: Dictionary in barricades.list:
		clear.append(g.guard)
	for band in board.cloud_bands:
		band.keep_clear = clear
	Game.time_changed.connect(hud.on_time)
	Game.gems_changed.connect(hud.on_gems)
	Game.time_changed.connect(_time_sounds)
	Game.gems_changed.connect(_gem_sound)
	Game.eliminated_changed.connect(func() -> void:
		if Game.eliminated:
			Sfx.play("eliminated"))
	_last_gems = Game.gems
	Game.adventure_ended.connect(_on_adventure_end)
	hud.refresh()
	_refresh_circles()
	# After the circles exist: `_sync_session()` starts before the board is
	# built, and an early call found no anchors and drew nobody.
	_refresh_peers()
	# A restart mid-run keeps whatever it had already opened.
	barricades.refresh()
	_start_intro()
	if _explore:
		skip_intro()
		hud.flash("Explore mode — nothing is scored")


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


# --- Stations ---------------------------------------------------------------
## The signage boxes on their own as well. Decor treats them like any other
## keep-out, but a guard looking for somewhere to stand has to clear them with his
## whole body or he ends up printed across the station's name.


func _spawn_player() -> void:
	# scenes/Hero.tscn: the shadow, the sprite, and the Foot box that is what
	# bumps into walls -- open it in the editor to change the box.
	player = load(MapCfg.HERO_SCENE).instantiate()
	player.position = grid.anchors[0]
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
	# Built off-screen (the headless suites do) there is no viewport to frame:
	# the canvas size stands in, rather than a zero that the camera rejects.
	var view := get_viewport_rect().size if is_inside_tree() else Vector2(Pal.CANVAS)
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
	hud._refresh_rescue()
	_cam.position_smoothing_enabled = false
	_clamp_cam(false)
	var z := _aerial_zoom()
	_cam.zoom = Vector2(z, z)
	_cam.position = Vector2(MapCfg.WORLD_W * MapCfg.TILE * 0.5, MapCfg.WORLD_H * MapCfg.TILE * 0.5)
	hud.set_prompt("Scouting the board...")
	# The controls crib goes with the joystick -- there is nothing to drive yet.
	hud.set_crib(false)
	# Right under the prompt, lower centre -- nothing sits on the board itself.
	_start_hint = Art.label("Waiting for your Quest Keeper to start" if _wait_for_admin
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
	_start_music()
	_drop_start_hint()
	hud.set_prompt("")
	# One eased curve drives both zoom and position, so the dive is one
	# movement. Zoom goes by ratio, not by amount (a linear zoom rushes one end),
	# and the view shrinks toward where the camera will settle, so the hero
	# holds still on screen as the world closes in -- landing exactly where
	# the clamped play camera will be, so there is no jump at the end.
	var z0 := _cam.zoom.x
	var p0 := _cam.position
	var to := _settled_cam(player.position, MapCfg.PLAY_ZOOM)
	_intro_tw = create_tween()
	_intro_tw.tween_interval(MapCfg.SWOOP_HOLD)
	_intro_tw.tween_method(func(t: float) -> void:
		var z := z0 * pow(MapCfg.PLAY_ZOOM / z0, t)
		_cam.zoom = Vector2(z, z)
		var span := 1.0 / z0 - 1.0 / MapCfg.PLAY_ZOOM
		var w := (1.0 / z - 1.0 / MapCfg.PLAY_ZOOM) / span if absf(span) > 0.0001 else 0.0
		_cam.position = to + (p0 - to) * w
		if is_instance_valid(_sky):
			_sky.progress(t),
		0.0, 1.0, MapCfg.SWOOP_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_intro_tw.tween_callback(skip_intro)


## Where the play camera ends up looking at `at`, `zoom` in: `at`, pulled in
## from the board's edges by half the view, as the camera limits will.
func _settled_cam(at: Vector2, zoom: float) -> Vector2:
	var half := get_viewport_rect().size / (2.0 * zoom)
	var world := Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE
	return Vector2(clampf(at.x, half.x, maxf(half.x, world.x - half.x)),
			clampf(at.y, half.y, maxf(half.y, world.y - half.y)))


func _drop_start_hint() -> void:
	if _start_hint != null and is_instance_valid(_start_hint):
		_start_hint.queue_free()
	_start_hint = null


## The adventure is on: the waiting's battle songs give way to The Journey
## (client). Without `Main` (the map_shot tool) there is no music to change.
func _start_music() -> void:
	if main != null:
		main.music.play("journey")


## Collapse the intro at once -- the tail of the tween, and what the tests call so
## nothing waits on wall-clock time.
func skip_intro() -> void:
	if not _frozen:
		return
	if _intro_tw != null and _intro_tw.is_valid():
		_intro_tw.kill()
	_intro_tw = null
	_drop_start_hint()
	if is_instance_valid(_sky):
		_sky.queue_free()
	_sky = null
	_start_music()
	hud.set_crib(true)
	_frozen = false
	hud._refresh_rescue()
	Game.clock_paused = false
	_cam.zoom = Vector2(MapCfg.PLAY_ZOOM, MapCfg.PLAY_ZOOM)
	_clamp_cam(true)
	_cam.position = player.position
	_cam.position_smoothing_enabled = true
	hud.set_pad(true)
	hud.set_prompt("")
	_update_interaction()


## On a ramp, up and down follow the slope: a step up or down the ramp's edge
## stops is steered toward the middle of its grass instead. At the top, up
## steps off onto the high ground; beside a ramp's top, down steps onto it --
## so straight up or down takes the whole stair.
func _slip(dy: float, stair_low: int) -> void:
	var here := player.position
	var at := MapGrid.cell_at(here)
	var c := Vector2i(-1, -1)
	# Where the feet are, where they step, and the box's leading edge: walking
	# straight at a foot, the box meets the ramp's rock before the feet do.
	var edge := hero_box.position.y if dy < 0.0 else hero_box.end.y
	for k in [at, MapGrid.cell_at(here + Vector2(0, dy)), MapGrid.cell_at(here + Vector2(0, dy + edge))]:
		if grid.stairs.has(k):
			c = k
			break
	# ...or on the high ground at a ramp's top: that ramp, not a neighbour's foot.
	var beside := false
	for k in [at + Vector2i(-1, 0), at + Vector2i(1, 0)]:
		if c.x < 0 and grid.stairs.has(k) and bool(grid.stairs[k].top) \
				and k - Vector2i(int(grid.stairs[k].side), 0) == at:
			c = k
			beside = true
	if c.x < 0:
		return
	var d := absf(dy)
	var high := -float(grid.stairs[c].side)          # which way the high ground is
	# Just off the top, the box still part over the ramp's back: on, onto the
	# high ground -- and no further than clear of the ramp. Steering to the
	# ramp's middle here pulled the hero back onto its back and he stuck.
	if beside and dy < 0.0:
		var feet := Rect2(hero_box.position + here, hero_box.size)
		if feet.intersects(Rect2(Vector2(c) * MapCfg.TILE, Vector2.ONE * MapCfg.TILE)) \
				and grid.box_walkable(here + Vector2(high * d, 0.0), hero_box, hero_level, stair_low):
			player.position = here + Vector2(high * d, 0.0)
		return
	var mid := clampf(grid.ramp_mid_x(c, here.y + dy) - here.x, -d, d)
	var tries: Array[Vector2] = []
	if absf(mid) > 0.01:
		tries.append(Vector2(mid, dy))
	# Off at the ends: up from its top onto the high ground, down from its
	# foot out of its open side.
	if grid.stairs.has(at) and bool(grid.stairs[at].top) == (dy < 0.0):
		tries.append(Vector2((high if dy < 0.0 else -high) * d, 0.0))
	if absf(mid) > 0.01:
		tries.append(Vector2(mid, 0.0))
	for n in tries:
		if grid.box_walkable(here + n, hero_box, hero_level, stair_low):
			player.position = here + n
			return


## Which way the sprite faces. Vertical wins ties so a diagonal walk still
## shows the back or front, which reads better than a side-on shuffle.
static func _facing(dir: Vector2) -> String:
	if absf(dir.y) >= absf(dir.x):
		return "down" if dir.y > 0.0 else "up"
	return "right" if dir.x > 0.0 else "left"


func _process(delta: float) -> void:
	_share_position(delta)
	if _overlay != null and is_instance_valid(_overlay) and Game.adventure_active:
		return
	if hud.paused or _frozen or not Game.adventure_active or _spectate != "":
		return
	var dir := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down"))
	# Walking brings the camera home -- unless a finger is still dragging the
	# view, which is the look the player is in the middle of.
	if _looking and dir.length_squared() > 0.001 and not bool(_press.get("panning", false)):
		end_look()
	if not _dev_aerial:
		_cam.position = _look_at if _looking else player.position
	_aim_hero_pointer()
	if dir.length_squared() > 1.0:
		dir = dir.normalized()
	var spr: AnimatedSprite2D = player.get_node("Spr")
	if dir.length_squared() > 0.001:
		# One axis at a time, so a diagonal into a wall slides along it rather
		# than stopping dead. Buildings only became real walls once the
		# footprint stopped being rounded to tile centres.
		# In steps of at most 2px: a hitched frame's long step would jump a
		# stair's thin rail.
		var step := dir * MapCfg.PLAYER_SPEED * _speed_mult * delta
		var n := ceili(step.length() / 2.0)
		step /= n
		for _i in n:
			var stair_low := grid.stair_low_at(player.position)
			player.position.x += step.x
			if not grid.box_walkable(player.position, hero_box, hero_level, stair_low):
				player.position.x -= step.x
			player.position.y += step.y
			if not grid.box_walkable(player.position, hero_box, hero_level, stair_low):
				player.position.y -= step.y
				_slip(step.y, stair_low)
			hero_level = grid.level_at(player.position, hero_level)
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
	if _overlay != null or hud.paused or _spectate != "":
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
	var p := _pointer(event)
	if not p.is_empty():
		_on_pointer(p)
		return
	# Dev sizing knob: [ shrinks the hero, ] grows him, and the toast prints the
	# number to bake into MapCfg.UNIT_SCALE.
	if OS.is_debug_build() and event is InputEventKey and (event as InputEventKey).pressed:
		match (event as InputEventKey).keycode:
			KEY_BRACKETLEFT:
				_nudge_hero_scale(-HERO_SCALE_STEP)
				return
			KEY_BRACKETRIGHT:
				_nudge_hero_scale(HERO_SCALE_STEP)
				return
	if event.is_action_pressed("interact"):
		end_look()
		_interact()


## Dev-only sizing knob: [ shrinks, ] grows, the readout is the number to bake
## back into UNIT_SCALE once something looks right. Rescales in place, so it is
## visible mid-walk without a restart.
func _nudge_hero_scale(delta: float) -> void:
	_hero_scale = clampf(_hero_scale + delta, HERO_SCALE_RANGE.x, HERO_SCALE_RANGE.y)
	var spr: AnimatedSprite2D = player.get_node("Spr")
	spr.scale = Vector2(_hero_scale, _hero_scale)
	hud.flash("Hero scale: %.1f  (MapCfg.UNIT_SCALE is %.1f)" % [_hero_scale, MapCfg.UNIT_SCALE])


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


## The board's one pointer: a tap, or a look once it has moved PAN_SLOP px.
## Touches that land on the HUD (GO, the plates, Rescue, the hero pointer) are
## the HUD's, never the board's.
func _on_pointer(p: Dictionary) -> void:
	match p.kind:
		"down":
			if hud.pointer_hit(p.pos):
				end_look()
				return
			# The same finger index down again means its last lift never reached
			# the board (a quiz or the rescue screen took it): that press is over.
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


## The camera leaves the hero: it holds still where it is, and follows the
## finger 1:1 from here -- no smoothing lag behind a drag.
func _begin_look() -> void:
	hud.set_panning(true)
	_close_card()
	if _looking:
		return
	_looking = true
	_look_at = _cam.get_screen_center_position()
	_cam.position_smoothing_enabled = false
	_cam.position = _look_at


## The view dragged by `screen_delta` px: the world moves with the finger.
func _look_by(screen_delta: Vector2) -> void:
	var z := _cam.zoom.x
	_look_at = _settled_cam(_look_at - screen_delta / z, z)


## Home to the hero, gliding: smoothing back on, the target back on the hero.
## Safe to call when not looking.
func end_look() -> void:
	if not _looking:
		return
	_looking = false
	if _press.get("panning", false):
		_press = {}
		hud.set_panning(false)
	_cam.position_smoothing_enabled = true
	hud.point_to_hero(false)


## While looking away, the arrow on the screen's edge points at the hero; it
## hides whenever the hero is on screen anyway.
func _aim_hero_pointer() -> void:
	if not _looking:
		return
	var view := get_viewport_rect().size
	var hero: Vector2 = get_viewport().get_canvas_transform() * player.position
	var inset := Rect2(Vector2(28, 70), view - Vector2(28 + 120, 70 + 64))
	if Rect2(Vector2.ZERO, view).grow(-16.0).has_point(hero):
		hud.point_to_hero(false)
		return
	var c := inset.get_center()
	var dir := (hero - c).normalized()
	# Where the ray from the middle toward the hero leaves the inset box.
	var tx := INF if is_zero_approx(dir.x) else ((inset.end.x if dir.x > 0.0 else inset.position.x) - c.x) / dir.x
	var ty := INF if is_zero_approx(dir.y) else ((inset.end.y if dir.y > 0.0 else inset.position.y) - c.y) / dir.y
	hud.point_to_hero(true, c + dir * minf(tx, ty), dir)


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
		Sfx.play("panel_close")
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
	Sfx.play("panel_open")
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
		Sfx.play("blocked")
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
			Sfx.play("gate")
			# In a session: through the Gate is done, not over -- the results
			# wait for everyone (client). Alone there is nobody to wait for.
			if Game.session_id != "":
				Game.mark_finished()
				_begin_spectating("finished")
			else:
				Game.end_adventure()


## The briefing card (`intro_only`) or one question. Same overlay either way.
func _open_quiz(station: int, intro_only: bool) -> void:
	if intro_only:
		Sfx.play("enter_tower")
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


## True if a circle has just become the one to answer.
func _refresh_circles() -> bool:
	var was := _current_circle
	_current_circle = -1
	for n in _circles.size():
		var state := "locked"
		if n < Game.items_done:
			state = "done"
		elif _can_answer(n):
			state = "current"
			_current_circle = n
		(_circles[n] as Node2D).set_state(state)
	# The answered tower's firefly flies on to the next one -- or up and away
	# when there is no next one yet -- leading the player there.
	# Only on to the very next tower: a rejoin jumping several ahead must not
	# send one flying across the map.
	if was >= 0 and (_circles[was] as Node2D).state == "done" \
			and (_current_circle == was + 1 or (_current_circle < 0 and Game.items_done == was + 1)):
		var to: Vector2 = (_circles[_current_circle].number_mid() if _current_circle >= 0
				else Vector2.INF)
		var secs: float = _circles[was].send_firefly(to)
		if _current_circle >= 0:
			_circles[_current_circle].firefly_arrives_in(secs)
	return _current_circle >= 0 and _current_circle != was


## Android's back button, routed here by Main. Swallowed: there is no way
## out of a run but playing it (client, 2026-10-01). Defined so Main does not
## fall back to opening Home.
func go_back() -> void:
	# Done but not over: no way out until everyone is (client).
	if _spectate != "":
		hud.flash("The results open when everyone is done")


# --- Spectating ---------------------------------------------------------------
## Done -- through the Gate, or out of gems -- while others still play
## (client). The results wait for everyone, so until then this player flies
## the map the way the Quest Keeper does (`MapWatch`: the whole class, drag,
## pinch, zoom), with a banner saying where they stand, and no way to leave.
## The session ending -- everyone done (`end_when_all_done`), the clock, or
## the Quest Keeper -- ends it here as ever, into the results.
func _begin_spectating(why: String, finish_s := -1) -> void:
	if _spectate != "" or Game.session_id == "" or not Game.adventure_active:
		return
	_spectate = why
	hud._refresh_rescue()
	end_look()
	_press = {}
	_close_card()
	hud.set_pad(false)
	hud.set_crib(false)
	hud.set_prompt("")
	# Over the board and under the HUD: a layer of the HUD's own number, put
	# ahead of it, draws beneath it (SkyClouds does the same).
	var layer := CanvasLayer.new()
	layer.layer = 1
	add_child(layer)
	move_child(layer, 0)
	var watch := MapWatch.new()
	watch.include_me = true
	watch.tower_seed = (world as MapWorld).tower_seed   # this run's towers
	layer.add_child(watch)
	watch.watch(Game.session_id)
	world.visible = false          # MapWatch draws its own board
	_show_banner(finish_s)


## "You finished! 12:34 · 180 gems" or "Eliminated", and that the results
## wait for everyone -- on a plank under the top bar, over grass or sea.
func _show_banner(finish_s := -1) -> void:
	if _banner == null or not is_instance_valid(_banner):
		_banner = Art.label("", Pal.LABEL, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
		var plank := Ui.plank(_banner, 12.0)
		plank.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		plank.grow_horizontal = Control.GROW_DIRECTION_BOTH
		plank.offset_top = 56.0
		plank.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud.hud_layer.add_child(plank)
	var head := "Eliminated" if _spectate == "eliminated" else "You finished!"
	if _spectate == "finished":
		if finish_s >= 0:
			head += "  %s" % Ui.mmss(finish_s)
		head += "  ·  %d gems" % Game.gems
	_banner.text = head + "\nWaiting for everyone to finish…"


# --- Quiz overlay -----------------------------------------------------------
func _show_overlay(overlay: Control) -> void:
	_overlay = overlay
	end_look()
	_press = {}
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
		# `== true`, not bool(): the rescue screen has no `intro_only`, and
		# bool(null) is an error in Godot 4 -- it left that overlay stuck open.
		if _overlay.get("intro_only") == true:
			Game.towers_entered[int(_overlay.get("station_index"))] = true
		_overlay.queue_free()
		_overlay = null
		hud.set_pad(true)
		hud.refresh()
		# One sound for what opened: the knight's "a way opens" when a
		# briefing sends him aside -- that also lights the station's first
		# circle -- or the circle's chime on its own.
		var lit := _refresh_circles()
		if barricades.refresh():
			Sfx.play("knight")
		elif lit:
			Sfx.play("circle_unlock")
		# Out of gems: that result was the last thing they played (client).
		if Game.eliminated:
			_begin_spectating("eliminated")
	# Clearing the board no longer ends the run on its own -- the Victory Gate
	# does, and walking to it is the last step of the player flow.


## One minute left, then each of the last ten seconds (client).
func _time_sounds(sec: int) -> void:
	if not _frozen and (sec == 60 or (sec >= 1 and sec <= 10)):
		Sfx.play("time_warning")


## The gem counter going up: a blip just after the reward's own sound, the way
## a rupee counts in. Down is silent -- the wrong answer, hint or skip said it.
func _gem_sound(g: int) -> void:
	if _last_gems >= 0 and g > _last_gems:
		Sfx.play("gem", 0.35)
	_last_gems = g


func _on_adventure_end(result: Dictionary) -> void:
	if bool(result.get("time_up", false)):
		Sfx.play("time_up")
	if _overlay != null:
		close_overlay()
	hud.paused = false
	main.open("summary", result)

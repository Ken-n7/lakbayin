class_name Peers
extends Node2D

## Everybody else, on your board -- every team, walking where they really are.
##
## Each other player is their own hero, with their name over it in their
## team's colour. Where they stand comes from `move()`: every phone broadcasts
## its hero's position over the realtime socket (a Broadcast message, so no
## database writes). Somebody whose position has not arrived yet, or has gone
## quiet, stands at the circle their `items_done` puts them on instead.

## One colour per team, in the order Game Controls lists the teams: six, for
## the client's 6 teams of 5 (GameControlsScreen.MAX_TEAMS).
const TEAM_COLOURS := [
	Color("4aa3df"),   # blue
	Color("e8663c"),   # red
	Color("52b262"),   # green
	Color("d9a125"),   # amber
	Color("c39cf0"),   # purple, light: the summit is dark
	Color("e86fae"),   # pink
]

## Side-by-side spacing for markers sharing a circle, and the half-step down
## every other one takes so neighbouring names do not touch.
const FAN_STEP := 26.0
const FAN_STAGGER := 12.0
## A position older than this is a phone that has gone away; fall back to the
## circle rather than leave a hero frozen mid-road.
const STALE_S := 12.0
## Playback, the way a video call plays sound: each player's walk arrives as
## a bundle of their path every AdventureScreen.BUNDLE_S and is played
## back `lag` seconds behind -- every turn as it was walked, nothing guessed.
## Guessing between single positions jumped whenever a real thumb weaved.
##
## `lag` is per player and counts from the fastest a bundle of theirs has come
## (`offset`): it starts at LAG_START and grows by LAG_GROW whenever playback
## reaches the end of what has arrived (that phone's line is slower than
## allowed for), then shrinks by LAG_SHRINK for every LAG_SETTLE_S without.
## Playback never jumps: behind where it should be it runs CATCH_UP times
## faster, ahead of it EASE times; out of path it carries on along the last
## step for CARRY_S, then waits for more.
## Sized for a bundle every 0.33s (AdventureScreen.BUNDLE_S) and the trip
## through the teacher: ~0.9s behind real time to start. Grows gently and
## comes back quickly -- at +0.25 / -0.05 per 15s a few hiccups left it near
## the top for minutes (client: "the delay is too long", 2026-10-08).
const LAG_START := 0.75
const LAG_MIN := 0.5
const LAG_MAX := 1.3
const LAG_GROW := 0.15
const LAG_SHRINK := 0.05
const LAG_SETTLE_S := 5.0
## Through the movement relay (RelayLink: data marked `fast`, a sample every
## 1/10-1/20s with nothing between it and here but the network) the buffer
## only has to cover the network's jitter, not a third of a second of
## waiting. A player's data counts as fast for FAST_HOLD_S after the last
## fast sample, so a phone that drops back to the hub path changes over once,
## not on every snapshot. Tuned against the relay load tests (SPECS).
const FAST_LAG_START := 0.25
const FAST_LAG_MIN := 0.15
const FAST_LAG_MAX := 0.8
const FAST_LAG_GROW := 0.1
const FAST_HOLD_S := 2.0
const CATCH_UP := 1.15
const EASE := 0.88
const CARRY_S := 0.3
const KEEP_S := 8.0          # seconds of path held per player
## Slower than this between two points is standing, not walking.
const STILL_PX_S := 15.0
## Further off than this is a teleport or a rejoin: snap, do not glide.
const SNAP_DIST := 240.0
const HERO_SCALE := 1.6           # MapCfg.UNIT_SCALE; not named, see _make()
const HERO_FOOT := Vector2(0, -10)
## The team arrow's tip, just over a hero's head (20px frame x HERO_SCALE = 32),
## and the name above the arrow.
const ARROW_Y := -34.0
const TAG_Y := -58.0

var _markers := {}          # profile_id -> Node2D
var _team_order: Array = []
## profile_id -> {pts: [[sender time, Vector2]], offset, lag, play, dry, settled,
## face, hero, t (when a bundle last came)}
var _live := {}
var _roster := {}           # profile_id -> the last row refresh() saw
var _anchors: Array = []
var _gate := Vector2.ZERO
var _me := ""


## The session's teams in the order Game Controls lists them (by name), so a
## team is the same colour on every phone in the room. Teams that appear later
## still get a colour, just after these.
func set_team_order(team_ids: Array) -> void:
	_team_order = team_ids.duplicate()


func _init() -> void:
	# Y-sorted with everything else, so a hero behind a tower is behind it.
	y_sort_enabled = true


## Who is in the session, from the members rows. Heroes already on the board
## are updated where they stand -- rebuilding them all on every answer anyone
## gave reset every walk cycle mid-step, a hitch across the whole board.
func refresh(rows: Array, anchors: Array, gate: Vector2, me: String) -> void:
	_anchors = anchors
	_gate = gate
	_me = me
	_roster.clear()
	for row: Dictionary in rows:
		var id: String = str(row.get("profile_id", ""))
		if id != me and id != "":
			_roster[id] = row

	# Gone from the session: gone from the board. Somebody known only from
	# their positions (joined since the last read) stays until the roster
	# has them, or until they fall silent.
	for id: String in _markers.keys():
		if not _roster.has(id) and not _is_live(id):
			var old: Node2D = _markers[id]
			_markers.erase(id)
			remove_child(old)
			old.queue_free()

	# Team-mates move in step, so several often stand on one circle. Fanned
	# out side by side, or the names print over each other and read as one.
	var at_stop := {}
	for id: String in _roster:
		var done := _done(_roster[id])
		at_stop[done] = int(at_stop.get(done, 0)) + 1
	var placed := {}
	for id: String in _roster:
		var row: Dictionary = _roster[id]
		var done := _done(row)
		var k: int = placed.get(done, 0)
		placed[done] = k + 1
		var spread := (k - (int(at_stop[done]) - 1) / 2.0) * FAN_STEP
		var team: String = str(row.get("team_id", ""))
		var marker: Node2D = _markers.get(id)
		if marker == null:
			marker = _make(id, str(row.get("username", "?")), team)
			_markers[id] = marker
			add_child(marker)
			marker.set_meta("fallback", _stop(done) + Vector2(spread, (k % 2) * FAN_STAGGER))
			marker.position = _live_pos(id) if _is_live(id) else marker.get_meta("fallback")
		else:
			marker.set_meta("fallback", _stop(done) + Vector2(spread, (k % 2) * FAN_STAGGER))
			var tag: Label = marker.get_node("Tag")
			tag.text = str(row.get("username", tag.text))
			tag.add_theme_color_override("font_color", colour_of(team))
			tint_arrow(marker.get_node("Arrow"), colour_of(team))
		# Out of the adventure: still shown, because a teacher and a team-mate
		# both want to know where somebody stopped.
		marker.modulate.a = 0.45 if bool(row.get("eliminated", false)) else 1.0


## A bundle off the socket: a stretch of the player's path. Somebody who
## joined since the last refresh is drawn from it until the roster catches up.
##
## Times are the sender's own clock; its offset from ours is the smallest gap
## seen between a bundle's last point and its arrival -- the fastest trip,
## steady while network delay jumps about. A single position (an older sender)
## is a one-point bundle.
func move(id: String, data: Dictionary) -> void:
	if id == _me or id == "":
		return
	var now := Time.get_ticks_msec() / 1000.0
	var incoming := _points(data, now)
	if incoming.is_empty():
		return
	var got: Dictionary = _live.get(id, {})
	var pts: Array = got.get("pts", [])
	# A restarted sender's clock starts again from zero: start over with it.
	if not pts.is_empty() and float(incoming[-1][0]) < float(pts[-1][0]) - 30.0:
		pts = []
		got.erase("offset")
		got.erase("play")
	for q: Array in incoming:
		# Bundles overlap the one before: only what is new.
		if pts.is_empty() or float(q[0]) > float(pts[-1][0]) + 0.001:
			pts.append(q)
	while pts.size() > 2 and float(pts[-1][0]) - float(pts[0][0]) > KEEP_S:
		pts.pop_front()
	got["pts"] = pts
	if bool(data.get("fast", false)):
		got["fast_at"] = now
	var fast := now - float(got.get("fast_at", -INF)) < FAST_HOLD_S
	if got.has("lag") and bool(got.get("fast", false)) != fast:
		# On or off the relay: its own buffer, and the trip learnt afresh --
		# the other path's fastest is no guide to this one's.
		got["lag"] = FAST_LAG_START if fast else LAG_START
		got.erase("offset")
	got["fast"] = fast
	got["offset"] = minf(float(got.get("offset", INF)), now - float(incoming[-1][0]))
	if not got.has("lag"):
		got["lag"] = FAST_LAG_START if fast else LAG_START
		got["settled"] = now
		got["dry"] = false
		got["face"] = "down"
	got["hero"] = int(data.get("hero", got.get("hero", 1)))
	got["t"] = now
	_live[id] = got

	var marker: Node2D = _markers.get(id)
	if marker == null:
		marker = _make(id, str(data.get("name", "?")), str(data.get("team", "")))
		marker.set_meta("fallback", pts[-1][1])
		marker.position = pts[0][1]
		_markers[id] = marker
		add_child(marker)
	_dress(marker, got.hero)


## [[sender time, Vector2]] from a message: a bundle {t, dt, x: [], y: []}, a
## list of [t, x, y], or one position {ts, x, y}.
static func _points(data: Dictionary, now: float) -> Array:
	var out: Array = []
	var p: Variant = data.get("p")
	if p is Dictionary:
		var t0 := float(p.get("t", now))
		var dt := float(p.get("dt", 0.1))
		var xs: Array = p.get("x", [])
		var ys: Array = p.get("y", [])
		for i in mini(xs.size(), ys.size()):
			out.append([t0 + i * dt, Vector2(float(xs[i]), float(ys[i]))])
	elif p is Array:
		for q: Variant in p:
			if q is Array and (q as Array).size() >= 3:
				out.append([float(q[0]), Vector2(float(q[1]), float(q[2]))])
	elif data.has("x"):
		out.append([float(data.get("ts", now)), Vector2(float(data.x), float(data.get("y", 0.0)))])
	return out


func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	# Known only from positions, and those have stopped: gone.
	for id: String in _markers.keys():
		if not _roster.has(id) and not _is_live(id):
			var old: Node2D = _markers[id]
			_markers.erase(id)
			remove_child(old)
			old.queue_free()
	for id: String in _markers:
		var marker: Node2D = _markers[id]
		var spr: AnimatedSprite2D = marker.get_node("Spr")
		var goal: Vector2 = marker.get_meta("fallback")
		var at := {"face": "down", "moving": false}
		if _is_live(id):
			at = _play(_live[id], now, delta)
			goal = at.pos
		if marker.position.distance_to(goal) > SNAP_DIST or _is_live(id):
			marker.position = goal
		else:
			# Back to a circle after going quiet: walk there, do not blink.
			marker.position = marker.position.move_toward(goal, 200.0 * delta)
		if at.moving:
			if spr.animation != at.face or not spr.is_playing():
				spr.play(at.face)
		elif spr.is_playing():
			spr.pause()
			spr.frame = 1


## One frame of a player's playback: move their clock on, steered towards
## `lag` behind, and where that puts them on their path.
static func _play(got: Dictionary, now: float, delta: float) -> Dictionary:
	var pts: Array = got.pts
	var fast := bool(got.get("fast", false))
	var newest := float(pts[-1][0])
	var target: float = now - float(got.offset) - float(got.lag)
	# First sight, or back after a long gap: start where it should be.
	if not got.has("play") or absf(target - float(got.play)) > 3.0:
		got["play"] = target
	var off: float = target - float(got.play)
	var rate := CATCH_UP if off > 0.1 else (EASE if off < -0.1 else 1.0)
	var next: float = float(got.play) + delta * rate
	var walking := _speed_at(pts, newest) > STILL_PX_S
	# Out of path while walking: carry on CARRY_S, then wait for more. Standing,
	# the clock keeps running -- they are not moving, so nothing is guessed --
	# or a relay hero, sent only every few seconds while still, would start
	# their next walk seconds in the past and take ages to catch up.
	if walking and next > newest + CARRY_S:
		next = newest + CARRY_S
	# Out of path while they were walking: their line is slower than allowed
	# for. A little more buffer from now on -- once per running dry.
	if next > newest and walking:
		if not bool(got.dry):
			got["dry"] = true
			got["lag"] = minf(float(got.lag) + (FAST_LAG_GROW if fast else LAG_GROW),
				FAST_LAG_MAX if fast else LAG_MAX)
			got["settled"] = now
	elif next <= newest:
		got["dry"] = false
	var least := FAST_LAG_MIN if fast else LAG_MIN
	if now - float(got.settled) > LAG_SETTLE_S and float(got.lag) > least:
		got["lag"] = maxf(float(got.lag) - LAG_SHRINK, least)
		got["settled"] = now
	got["play"] = next
	var at := _path_at(pts, next)
	if at.moving:
		got["face"] = at.face
	else:
		at.face = got.face
	return at


## Where a path puts a player at sender time `t`: between the two points
## either side, or on along the last step for at most CARRY_S.
static func _path_at(pts: Array, t: float) -> Dictionary:
	if pts.size() == 1 or t <= float(pts[0][0]):
		return {"pos": pts[0][1] if t <= float(pts[0][0]) else pts[-1][1], "face": "down", "moving": false}
	var n := pts.size()
	if t >= float(pts[-1][0]):
		var a: Array = pts[n - 2]
		var b: Array = pts[n - 1]
		var vel := _vel(a, b)
		var ahead := minf(t - float(b[0]), CARRY_S)
		return {"pos": (b[1] as Vector2) + vel * ahead, "face": _face(vel),
			"moving": vel.length() > STILL_PX_S and ahead < CARRY_S}
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if float(pts[mid][0]) <= t:
			lo = mid
		else:
			hi = mid
	var p: Array = pts[lo]
	var q: Array = pts[hi]
	var w := clampf((t - float(p[0])) / maxf(float(q[0]) - float(p[0]), 0.001), 0.0, 1.0)
	var v := _vel(p, q)
	return {"pos": (p[1] as Vector2).lerp(q[1], w), "face": _face(v), "moving": v.length() > STILL_PX_S}


static func _vel(a: Array, b: Array) -> Vector2:
	return ((b[1] as Vector2) - (a[1] as Vector2)) / maxf(float(b[0]) - float(a[0]), 0.001)


static func _speed_at(pts: Array, t: float) -> float:
	if pts.size() < 2:
		return 0.0
	return _vel(pts[-2], pts[-1]).length()


static func _face(v: Vector2) -> String:
	if absf(v.x) >= absf(v.y):
		return "right" if v.x > 0.0 else "left"
	return "down" if v.y > 0.0 else "up"


func _is_live(id: String) -> bool:
	return _live.has(id) and Time.get_ticks_msec() / 1000.0 - float(_live[id].t) < STALE_S


func _live_pos(id: String) -> Vector2:
	return _live[id].pts[-1][1]


func _done(row: Dictionary) -> int:
	return clampi(int(row.get("items_done", 0)), 0, _anchors.size())


func _stop(done: int) -> Vector2:
	if _anchors.is_empty():
		return _gate
	return _gate if done >= _anchors.size() else _anchors[done]


## Teams take colours in `set_team_order`'s order; one missing from it takes
## the next free colour and keeps it for as long as the board is open. Public:
## the player's own hero asks it too, so their arrow matches everyone's.
func colour_of(team_id: String) -> Color:
	if team_id == "":
		return Color.WHITE
	var at := _team_order.find(team_id)
	if at == -1:
		_team_order.append(team_id)
		at = _team_order.size() - 1
	return TEAM_COLOURS[at % TEAM_COLOURS.size()]


## A hero like the player's, with the name over it in the team's colour.
## MapCfg is not named here: `test_rules.gd` loads this file under `--script`,
## where only plain class_name scripts resolve, so the two numbers are copied.
func _make(id: String, username: String, team_id: String) -> Node2D:
	var node := Node2D.new()
	node.name = "Peer_" + id.left(8)

	var shade := Polygon2D.new()
	var pts := PackedVector2Array()
	for i in 12:
		var a := TAU * i / 12.0
		pts.append(Vector2(cos(a) * 8.0, sin(a) * 3.0))
	shade.polygon = pts
	shade.color = Color(0, 0, 0, 0.3)
	node.add_child(shade)

	var spr := AnimatedSprite2D.new()
	spr.name = "Spr"
	spr.scale = Vector2(HERO_SCALE, HERO_SCALE)
	spr.offset = HERO_FOOT
	node.add_child(spr)
	node.set_meta("hero", 0)
	_dress(node, int(_live.get(id, {}).get("hero", 1)))

	var tag := Label.new()
	tag.name = "Tag"
	tag.text = username
	tag.add_theme_font_size_override("font_size", 11)
	tag.add_theme_color_override("font_color", colour_of(team_id))
	tag.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	tag.add_theme_constant_override("outline_size", 4)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.position = Vector2(-40, TAG_Y)
	tag.custom_minimum_size = Vector2(80, 0)
	tag.size = Vector2(80, 14)
	node.add_child(tag)
	var arrow := team_arrow(colour_of(team_id))
	arrow.position.y = ARROW_Y
	node.add_child(arrow)
	return node


## A small down arrow in a team's colour, its tip at the origin, to stand over
## a hero's head: the team at a glance, which the coloured name alone was not
## (client). A dark rim under the fill so it reads on any grass.
static func team_arrow(col: Color) -> Node2D:
	var arrow := Node2D.new()
	arrow.name = "Arrow"
	var rim := Polygon2D.new()
	rim.polygon = PackedVector2Array([Vector2(-6.5, -9.5), Vector2(6.5, -9.5), Vector2(0, 1)])
	rim.color = Color(0.1, 0.07, 0.05)
	arrow.add_child(rim)
	var fill := Polygon2D.new()
	fill.name = "Fill"
	fill.polygon = PackedVector2Array([Vector2(-4.5, -8), Vector2(4.5, -8), Vector2(0, -1.5)])
	fill.color = col
	arrow.add_child(fill)
	return arrow


static func tint_arrow(arrow: Node2D, col: Color) -> void:
	(arrow.get_node("Fill") as Polygon2D).color = col


## The hero sheet a player picked, which only arrives with their first
## position -- until then everybody is hero 1.
func _dress(node: Node2D, hero: int) -> void:
	hero = clampi(hero, 1, 32)
	if int(node.get_meta("hero", 0)) == hero:
		return
	node.set_meta("hero", hero)
	var spr: AnimatedSprite2D = node.get_node("Spr")
	spr.sprite_frames = Art.walk_frames("res://assets/characters/character_%d.png" % hero)
	spr.play("down")
	spr.pause()
	spr.frame = 1

class_name Peers
extends Node2D

## Everybody else, on your board -- every team, walking where they really are.
##
## Each other player is their own hero, with their name over it in their
## team's colour. Where they stand comes from `move()`: every phone broadcasts
## its hero's position over the realtime socket (a Broadcast message, so no
## database writes). Somebody whose position has not arrived yet, or has gone
## quiet, stands at the circle their `items_done` puts them on instead.

## Four teams, four colours, in the order Game Controls lists the teams.
const TEAM_COLOURS := [
	Color("4aa3df"),   # blue
	Color("e8663c"),   # red
	Color("52b262"),   # green
	Color("d9a125"),   # amber
]

## Side-by-side spacing for markers sharing a circle, and the half-step down
## every other one takes so neighbouring names do not touch.
const FAN_STEP := 26.0
const FAN_STAGGER := 12.0
## A position older than this is a phone that has gone away; fall back to the
## circle rather than leave a hero frozen mid-road.
const STALE_S := 12.0
## Heroes are drawn DELAY_S in the past, between two positions that have both
## already arrived -- so a message landing late or two landing together, which
## is how classroom WiFi delivers them, changes nothing on screen. Chasing the
## newest position instead stuttered: catch up, stand, jump. Past the newest
## one it walks on at the last velocity for at most PREDICT_S, so a lost
## "stopped" cannot send a hero off across the sea.
const DELAY_S := 0.25
const PREDICT_S := 0.3
const KEEP := 12            # positions held per player; ~2s of walking
## Further off than this is a teleport or a rejoin: snap, do not glide.
const SNAP_DIST := 240.0
const HERO_SCALE := 1.6           # MapCfg.UNIT_SCALE; not named, see _make()
const HERO_FOOT := Vector2(0, -10)

var _markers := {}          # profile_id -> Node2D
var _team_order: Array = []
## profile_id -> {pos, face, moving, hero, name, team, t}
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
			tag.add_theme_color_override("font_color", _colour(team))
		# Out of the adventure: still shown, because a teacher and a team-mate
		# both want to know where somebody stopped.
		marker.modulate.a = 0.45 if bool(row.get("eliminated", false)) else 1.0


## A position off the socket. Somebody who joined since the last refresh is
## drawn from the message itself until the roster catches up.
##
## `ts` is the sender's own clock. Its offset from ours is taken as the
## smallest gap seen (the fastest a message has ever come), which is steady
## while network delay jumps about -- that steadiness is the smoothness.
func move(id: String, data: Dictionary) -> void:
	if id == _me or id == "":
		return
	var now := Time.get_ticks_msec() / 1000.0
	var ts := float(data.get("ts", now))
	var got: Dictionary = _live.get(id, {})
	var samples: Array = got.get("samples", [])
	# A restarted sender's clock starts again from zero: start over with it.
	if not samples.is_empty() and ts < float(samples[-1].ts):
		samples = []
		got.erase("offset")
	samples.append({
		"ts": ts,
		"pos": Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0))),
		"vel": Vector2(float(data.get("vx", 0.0)), float(data.get("vy", 0.0))),
		"face": str(data.get("face", "down")),
		"moving": bool(data.get("moving", false)),
	})
	if samples.size() > KEEP:
		samples.pop_front()
	got["samples"] = samples
	got["offset"] = minf(float(got.get("offset", INF)), now - ts)
	got["hero"] = int(data.get("hero", 1))
	got["t"] = now
	_live[id] = got

	var marker: Node2D = _markers.get(id)
	if marker == null:
		marker = _make(id, str(data.get("name", "?")), str(data.get("team", "")))
		marker.set_meta("fallback", samples[-1].pos)
		marker.position = samples[-1].pos
		_markers[id] = marker
		add_child(marker)
	_dress(marker, got.hero)


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
			at = _sample_at(_live[id], now - float(_live[id].offset) - DELAY_S)
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


## Where a player was at sender time `rt`: between the two positions either
## side of it, or walked on from the newest for at most PREDICT_S.
static func _sample_at(live: Dictionary, rt: float) -> Dictionary:
	var samples: Array = live.samples
	var last: Dictionary = samples[-1]
	if rt >= float(last.ts):
		var ahead := minf(rt - float(last.ts), PREDICT_S)
		return {"pos": last.pos + last.vel * ahead, "face": last.face,
			"moving": last.moving and ahead < PREDICT_S}
	for i in range(samples.size() - 1, 0, -1):
		var a: Dictionary = samples[i - 1]
		var b: Dictionary = samples[i]
		if rt >= float(a.ts):
			var span := maxf(float(b.ts) - float(a.ts), 0.001)
			var w := clampf((rt - float(a.ts)) / span, 0.0, 1.0)
			return {"pos": (a.pos as Vector2).lerp(b.pos, w), "face": b.face,
				"moving": a.moving or b.moving}
	return {"pos": samples[0].pos, "face": samples[0].face, "moving": false}


func _is_live(id: String) -> bool:
	return _live.has(id) and Time.get_ticks_msec() / 1000.0 - float(_live[id].t) < STALE_S


func _live_pos(id: String) -> Vector2:
	return _live[id].samples[-1].pos


func _done(row: Dictionary) -> int:
	return clampi(int(row.get("items_done", 0)), 0, _anchors.size())


func _stop(done: int) -> Vector2:
	if _anchors.is_empty():
		return _gate
	return _gate if done >= _anchors.size() else _anchors[done]


## Teams take colours in `set_team_order`'s order; one missing from it takes
## the next free colour and keeps it for as long as the board is open.
func _colour(team_id: String) -> Color:
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
	tag.add_theme_color_override("font_color", _colour(team_id))
	tag.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	tag.add_theme_constant_override("outline_size", 4)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.position = Vector2(-40, -48)
	tag.custom_minimum_size = Vector2(80, 0)
	tag.size = Vector2(80, 14)
	node.add_child(tag)
	return node


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

extends TestCase
## Realtime regressions that do not need a match on screen; all
## services stay local/offline.

class Student extends "res://scripts/TeamNameScreen.gd":
	var reloads := 0
	func _reload_lobby() -> void:
		reloads += 1

class Socket extends RefCounted:
	var messages: Array = []
	var samples := 0
	func send_text(raw: String) -> Error:
		messages.append(JSON.parse_string(raw))
		return OK
	func send(_data: PackedByteArray, _mode: int) -> Error:
		samples += 1
		return OK
	func close(_code := 1000) -> void:
		pass

class MovementAdventure extends "res://scripts/AdventureScreen.gd":
	func _refresh_peers() -> void:
		pass


class RecordsPreview extends "res://scripts/RecordsScreen.gd":
	func _load() -> void:
		pass


class RoomPreview extends "res://scripts/RoomScreen.gd":
	func _process(_delta: float) -> void:
		pass


func _ready() -> void:
	backup_save()
	var was_url := Net.url
	Net.url = "http://127.0.0.1:1"
	Net.access_token = "test"
	Net.user_id = "alice"
	_private_movement()
	_channel_recovery()
	_lobby_reconnect()
	await _direct_movement()
	await _monk_activity()
	await _room_controls()
	await _watch_view()
	await _records_view()
	_account_change()
	_movement_edges()
	_board_edges()
	_lobby_rows()
	_session_helpers()
	Net.realtime().close_socket()
	Net.url = was_url
	Net.access_token = ""
	Net.user_id = ""
	Game.abandon_adventure()
	Game.session_id = ""
	Game.session_state = ""
	completed = true
	finish("MULTIPLAYER")


func _private_movement() -> void:
	var rt := Realtime.new()
	var socket := Socket.new()
	rt.set("_ws", socket)
	rt.set("_state", WebSocketPeer.STATE_OPEN)
	var topic := Realtime.snap_topic("s1")
	rt.set("_pos_topics", {topic: ""})
	rt._join_pos(topic)
	check("movement joins request private authorization", bool(socket.messages[0].payload.config.get("private", false)))
	var received: Array = []
	rt.position.connect(func(event: String, data: Dictionary) -> void: received.append([event, data]))
	var snap := {"sid": "s1", "p": [{"id": "alice", "p": [[1.0, 10, 20]]}]}
	var msg := {"event": "broadcast", "topic": Realtime.TOPIC,
		"payload": {"event": "snap", "payload": snap}}
	rt._handle(msg)
	check("public snapshot broadcasts are ignored", received.is_empty())
	msg.topic = topic
	rt._handle(msg)
	check("a channel must be authorized before accepting movement", received.is_empty())
	var ref := str((rt.get("_pos_topics") as Dictionary)[topic])
	rt._handle({"event": "phx_reply", "topic": topic, "ref": ref, "payload": {"status": "ok"}})
	rt._handle(msg)
	check("an authorized snapshot reaches the map", received.size() == 1)
	msg.payload.payload = {"sid": "other", "p": snap.p}
	rt._handle(msg)
	check("a snapshot cannot claim another session", received.size() == 1)
	msg.payload.payload = {"sid": "s1", "p": "not an array"}
	rt._handle(msg)
	check("malformed snapshots are rejected before reaching map code", received.size() == 1)
	check("only path lists pass as movement", not Realtime.valid_position(
		topic, "snap", {"sid": "s1", "p": [{"id": "alice", "x": 1, "y": 2}]}))
	rt.close_socket()
	rt.free()


## A healthy WebSocket can lose just one Phoenix channel. Its unsolicited
## error carries join_ref, not the ref of a client request.


## A healthy WebSocket can lose just one Phoenix channel. Its unsolicited
## error carries join_ref, not the ref of a client request.
func _channel_recovery() -> void:
	var rt := Realtime.new()
	var socket := Socket.new()
	rt.set("_ws", socket)
	rt.set("_state", WebSocketPeer.STATE_OPEN)
	(rt.get("_wanted") as Array).append({"table": "members", "filter": ""})
	rt._join()
	var main_ref := str(rt.get("_join_ref"))
	check("Phoenix joins identify their channel incarnation", socket.messages[0].get("join_ref") == main_ref)
	var topic := Realtime.snap_topic("s1")
	rt.set("_pos_topics", {topic: ""})
	rt._join_pos(topic)
	var ref := str((rt.get("_pos_topics") as Dictionary)[topic])
	rt._handle({"event": "phx_reply", "topic": topic, "ref": ref, "payload": {"status": "ok"}})
	rt._handle({"event": "phx_close", "topic": topic, "join_ref": "old-join", "ref": ref})
	check("an obsolete channel close cannot close its replacement", (rt.get("_pos_live") as Dictionary).has(topic))
	# An independent current join, so an incorrectly accepted old close above
	# cannot make this check pass by having already marked the channel down.
	rt._join_pos(topic)
	ref = str((rt.get("_pos_topics") as Dictionary)[topic])
	rt._handle({"event": "phx_reply", "topic": topic, "ref": ref, "payload": {"status": "ok"}})
	rt._handle({"event": "phx_close", "topic": topic, "join_ref": ref, "ref": null})
	check("a closed movement channel is marked down and scheduled to rejoin",
		not (rt.get("_pos_live") as Dictionary).has(topic)
		and str((rt.get("_pos_topics") as Dictionary)[topic]) == "")
	rt._handle({"event": "phx_error", "topic": Realtime.TOPIC, "join_ref": main_ref, "ref": null})
	check("a failed progress channel rejoins even while its socket stays open",
		not bool(rt.get("_joined")) and float(rt.get("_rejoin_in")) > 0.0)
	rt._join()
	rt.set("_rejoin_in", -1.0)
	rt._handle({"event": "phx_reply", "topic": Realtime.TOPIC,
		"ref": rt.get("_join_ref"), "payload": {"status": "error", "response": {"reason": "test refusal"}}})
	check("a refused progress subscription is retried instead of remaining silently dead",
		not bool(rt.get("_joined")) and float(rt.get("_rejoin_in")) > 0.0)
	rt.close_socket()
	rt.free()


func _lobby_reconnect() -> void:
	var student := Student.new()
	student.set("_session", {"id": "s1", "state": "lobby"})
	student._watch()
	Net.realtime().subscribed.emit()
	check("a match's lobby reloads when the stream comes back", student.reloads == 1)
	student.free()


func _account_change() -> void:
	Net.username = "alice"
	Net.sign_out()
	check("logout forgets the previous player", Net.access_token == "" and Net.user_id == ""
		and Net.username == "" and not FileAccess.file_exists(Net.SESSION_PATH))


## What a movement packet must be before map code sees it -- every way of
## not being one -- and what is taken out of one.
func _movement_edges() -> void:
	var topic := Realtime.snap_topic("s1")
	var ok := func(paths: Variant, event := "snap", at := topic, sid := "s1") -> bool:
		return Realtime.valid_position(at, event, {"sid": sid, "p": paths})
	var hero := func(pts: Variant, extra := {}) -> Array:
		var p := {"id": "a", "p": pts}
		p.merge(extra, true)
		return [p]
	check("a path list is movement", ok.call(hero.call([[1.0, 2, 3]])))
	check("so is a packet of no heroes", ok.call([]))
	check("only on its own match's channel", not ok.call(hero.call([[1, 2, 3]]), "snap", Realtime.snap_topic("s2")))
	check("not without a session", not ok.call(hero.call([[1, 2, 3]]), "snap", Realtime.snap_topic(""), ""))
	check("not as any other event", not ok.call(hero.call([[1, 2, 3]]), "pos"))
	check("heroes come as a list", not ok.call({"id": "a", "p": [[1, 2, 3]]}))
	check("each hero an object with an id", not ok.call(["a"]) and not ok.call(hero.call([[1, 2, 3]], {"id": ""})))
	var many: Array = []
	for i in 255:
		many.append({"id": str(i), "p": [[1, 2, 3]]})
	check("up to 255 heroes", ok.call(many))
	many.append({"id": "x", "p": [[1, 2, 3]]})
	check("...not 256", not ok.call(many))
	check("a hero number is a number", ok.call(hero.call([[1, 2, 3]], {"hero": 3}))
		and not ok.call(hero.call([[1, 2, 3]], {"hero": "3"})))
	check("a path has points", not ok.call(hero.call([])) and not ok.call(hero.call(null)))
	var long: Array = []
	for i in 128:
		long.append([i, 1, 1])
	check("up to 128 points", ok.call(hero.call(long)))
	long.append([200, 1, 1])
	check("...not 129", not ok.call(hero.call(long)))
	for bad: Variant in [[1, 2], [1, "2", 3], [INF, 2, 3], [1, NAN, 3], "1,2,3", null]:
		check("a point is three finite numbers, not %s" % str(bad), not ok.call(hero.call([[1, 2, 3], bad])))
	check("a point may carry more after the three", ok.call(hero.call([[1, 2, 3, "x"]])))

	check("points: [time, place], ints taken as floats",
		Peers._points({"p": [[1, 2, 3]]}) == [[1.0, Vector2(2, 3)]])
	check("points: what is not a point is skipped", Peers._points({"p": [[1, 2], "x", [2, 4, 5]]}) == [[2.0, Vector2(4, 5)]])
	check("points: none in what is not a list", Peers._points({"p": {"x": 1}}).is_empty() and Peers._points({}).is_empty())
	for bad: Variant in [-1, 0, "0.1", NAN, null]:
		check("a cadence of %s is no cadence" % str(bad), Peers.direct_buffer({"cadence": bad}) == Peers.LAG_START)
	check("a tiny cadence still gets the least buffer", is_equal_approx(Peers.direct_buffer({"cadence": 0.001}), 0.1))


## Everyone on the board: fanned out at the door until heard from, then
## where they are; what team vision sees; colours.
func _board_edges() -> void:
	var p := Peers.new()
	var door := Vector2(400, 300)
	p.refresh([{"profile_id": "a", "team_id": "blue", "username": "A"}], door, "me")
	check("one player waits on the door itself", (p.get("_markers")["a"] as Node2D).position == door)
	var rows: Array = [{"profile_id": "me", "team_id": "blue"}, {"profile_id": "", "team_id": "blue"}]
	for i in 5:
		rows.append({"profile_id": "p%d" % i, "team_id": "blue" if i % 2 else "red", "username": "P%d" % i})
	p.refresh(rows, door, "me")
	var markers: Dictionary = p.get("_markers")
	check("not yourself, not a row with no id; gone from the roster, gone", not markers.has("me") and not markers.has("")
		and not markers.has("a") and markers.size() == 5, str(markers.keys()))
	var xs: Array = []
	var spots := {}
	for i in 5:
		var at: Vector2 = (markers["p%d" % i] as Node2D).get_meta("fallback")
		xs.append(at.x - door.x)
		spots[at] = true
	check("five side by side, none on another", spots.size() == 5)
	check("centred on the door", is_equal_approx(xs.reduce(func(a: float, b: float) -> float: return a + b, 0.0), 0.0), str(xs))
	check("a newcomer is placed where they wait", (markers["p0"] as Node2D).position == (markers["p0"] as Node2D).get_meta("fallback"))
	check("nobody heard from: team vision sees nobody", p.positions_of("blue").is_empty() and p.heroes_of("blue").is_empty())
	p.move("p1", {"p": [[0.0, 50, 60]]})
	p.move("p0", {"p": [[0.0, 70, 80]]})
	p.move("stranger", {"p": [[0.0, 1, 1]], "team": "blue"})
	check("team vision: your side's heroes heard from",
		p.positions_of("blue").size() == 1 and p.heroes_of("blue").size() == 1
		and p.positions_of("red").size() == 1, str(p.positions_of("blue")))
	check("someone not on the roster is no one's team-mate", not p.positions_of("blue").has(Vector2(1, 1)))
	check("no team is white", p.colour_of("") == Color.WHITE)
	var blue := p.colour_of("blue")
	var red := p.colour_of("red")
	check("two sides, two colours, kept", blue != red and p.colour_of("blue") == blue)
	check("a third side still gets a colour", p.colour_of("green") in [blue, red])
	p.free()


## Lobby: every row the change feed can bring, and the doorbell.
func _lobby_rows() -> void:
	var l := Lobby.new()
	l.session = {"id": "s"}
	check("another session's change is not ours", l.apply("sessions", "UPDATE", {"id": "x", "state": "ended"}) == ""
		and not l.session.has("state"))
	check("our session's change is merged", l.apply("sessions", "UPDATE", {"id": "s", "state": "running"}) == "changed"
		and l.session.state == "running")
	check("a team comes", l.apply("teams", "INSERT", {"id": "t2", "session_id": "s", "name": "pula"}) == "changed")
	check("another session's team does not", l.apply("teams", "INSERT", {"id": "t9", "session_id": "x", "name": "a"}) == ""
		and l.teams.size() == 1)
	l.apply("teams", "INSERT", {"id": "t1", "session_id": "s", "name": "Bughaw"})
	check("teams in name order, whatever the capitals", l.teams.map(func(t: Dictionary) -> String: return t.id) == ["t1", "t2"])
	check("a team renamed in place", l.apply("teams", "UPDATE", {"id": "t2", "session_id": "s", "name": "Aaa"}) == "changed"
		and l.teams.size() == 2 and l.teams[0].id == "t2")
	check("a newcomer without a name costs a read", l.apply("members", "INSERT", {"session_id": "s", "profile_id": "u"}) == "reload")
	check("a newcomer with one is placed, on no side", l.apply("members", "INSERT",
		{"session_id": "s", "profile_id": "u", "username": "Una", "team_id": null}) == "changed" and l.team_of("u") == "")
	l.apply("members", "UPDATE", {"session_id": "s", "profile_id": "u", "team_id": "t1"})
	l.apply("members", "INSERT", {"session_id": "s", "profile_id": "v", "username": "Ana", "team_id": "t1"})
	check("on a side; a side's members by name", l.team_of("u") == "t1"
		and l.members_of("t1").map(func(m: Dictionary) -> String: return m.username) == ["Ana", "Una"])
	check("another session's member is not ours", l.apply("members", "UPDATE", {"session_id": "x", "profile_id": "u", "team_id": "t2"}) == ""
		and l.team_of("u") == "t1")
	check("a team going takes its players off it", l.apply("teams", "DELETE", {"id": "t1"}) == "changed"
		and l.team_of("u") == "" and l.team_of("v") == "")
	check("a team we never had going is nothing", l.apply("teams", "DELETE", {"id": "nope"}) == "")
	check("a member we never had leaving is nothing", l.apply("members", "DELETE", {"profile_id": "w"}) == "")
	check("nor one from another session", l.apply("members", "DELETE", {"profile_id": "u", "session_id": "x"}) == ""
		and l.players.has("u"))
	check("a member leaving", l.apply("members", "DELETE", {"profile_id": "u"}) == "changed" and not l.players.has("u"))
	check("RELOAD asks for a read", l.apply("members", "RELOAD", {}) == "reload")
	check("a table the lobby does not keep", l.apply("monk_answers", "INSERT", {"session_id": "s"}) == "")
	check("names: spectators, a side, nothing", l.name_of(Lobby.SPECTATE) == "Spectators" and l.name_of("t2") == "Aaa"
		and l.name_of("nope") == "" and l.team_of("nobody") == "")
	check("the session going empties it", l.apply("sessions", "DELETE", {"id": "s"}) == "changed" and l.session == {})
	l.session = {"id": "s"}
	check("the doorbell: another event, another session -- nothing", l.hear("score", {"sid": "s"}) == ""
		and l.hear(Lobby.EVENT, {"sid": "x"}) == "")
	check("the doorbell rings a read", l.hear(Lobby.EVENT, {"sid": "s"}) == "reload")
	check("...at most once a second", l.hear(Lobby.EVENT, {"sid": "s"}) == "")
	l.set("_rang_at", -INF)
	check("...and again after", l.hear(Lobby.EVENT, {"sid": "s"}) == "reload")


## Teams' and WatchFeed's helpers on what the server sends.
func _session_helpers() -> void:
	check("roster: the name embedded, or on the row, or ?", Teams.roster([
		{"profile_id": "a", "team_id": null, "profiles": {"username": "Al"}},
		{"profile_id": "b", "team_id": "t", "username": "Bo"}, {}]) == [
		{"profile_id": "a", "team_id": "", "username": "Al"},
		{"profile_id": "b", "team_id": "t", "username": "Bo"},
		{"profile_id": "", "team_id": "", "username": "?"}])
	check("one bad character named", Teams.bad_note("O") == "Codes never use O — check that character.")
	check("a code with nothing wrong", Teams.clean_code("a c-d e") == "ACDE" and Teams.bad_chars("ACDE") == "")
	check("look-alikes are what codes use", Teams.clean_code("zsbvg") == "258U6" and Teams.bad_chars("258U6") == "")
	check("no time is 0, not 1970", Teams._stamp(null) == 0 and Teams._stamp("") == 0)
	var now := Game.now()
	var at := func(t: float) -> String: return Time.get_datetime_string_from_unix_time(int(t))
	check("ended is over", Teams.expired({"state": "ended"}))
	check("a fresh lobby is not", not Teams.expired({"state": "lobby", "created_at": at.call(now - 60)}))
	check("a lobby from yesterday is", Teams.expired({"state": "lobby", "created_at": at.call(now - Teams.MAX_AGE_S - 1)}))
	check("a running match before its deadline is not", not Teams.expired({"state": "running", "created_at": at.call(now - 60),
		"ends_at": at.call(now + 300)}))
	check("...after it is", Teams.expired({"state": "running", "created_at": at.call(now - 600), "ends_at": at.call(now - 1)}))
	check("...and with no deadline yet is not", not Teams.expired({"state": "running", "ends_at": null}))
	check("a lobby's past deadline means nothing", not Teams.expired({"state": "lobby", "ends_at": at.call(now - 1)}))

	check("time left: no deadline yet is the whole clock", WatchFeed.time_left({"duration_s": 600}, now) == 600
		and WatchFeed.time_left({"duration_s": 600, "ends_at": null}, now) == 600)
	check("time left: to the deadline, rounded up", WatchFeed.time_left({"duration_s": 900, "ends_at": at.call(floorf(now) + 100)}, floorf(now) + 0.5) == 100)
	check("time left: none after it", WatchFeed.time_left({"duration_s": 900, "ends_at": at.call(now - 5)}, now) == 0)
	check("time left: never more than the clock", WatchFeed.time_left({"duration_s": 60, "ends_at": at.call(now + 600)}, now) == 60)
	var teams := [{"id": "b", "name": "Bughaw", "deposited": 3, "reached_at": "2026-10-23T00:01:00+00:00"},
		{"id": "r", "name": "Pula", "deposited": 3, "reached_at": "2026-10-23T00:02:00+00:00"}]
	check("the server's winner", WatchFeed.outcome({"session": {"winner_team": "r"}, "teams": teams}) == "Pula wins!")
	check("more words", WatchFeed.outcome({"session": {}, "teams": [teams[0], {"id": "r", "name": "Pula", "deposited": 4}]}) == "Pula wins!")
	check("the same words: sooner", WatchFeed.outcome({"session": {}, "teams": teams}) == "Bughaw wins!")
	teams[1].reached_at = null
	check("the same words, one time unknown: a draw", WatchFeed.outcome({"session": {}, "teams": teams}) == "Draw")
	check("not two sides", WatchFeed.outcome({"session": {}, "teams": [teams[0]]}) == "Match ended")
	check("stamps: none", WatchFeed.stamp("") == 0.0 and WatchFeed.stamp("<null>") == 0.0)
	var whole := WatchFeed.stamp("2026-10-23T00:00:00Z")
	check("stamps: a space for the T, fractions, an offset", whole > 0
		and is_equal_approx(WatchFeed.stamp("2026-10-23 00:00:00.25+00:00"), whole + 0.25))


func _monk_activity() -> void:
	var peers: Array[String] = ["mate"]
	var online := {"mate": [{"sid": "s1", "where": "map", "typing_monk": 2.0, "typing_until": 1010.0}],
		"enemy": [{"sid": "s1", "where": "map", "typing_monk": 3, "typing_until": 1010.0}]}
	check("only roster-confirmed teammates mark monks", MonkActivity.active(online, peers, "s1", 10, 1000) == {2: true})
	check("typing hints are scoped to their match", MonkActivity.active(online, peers, "s2", 10, 1000).is_empty())
	check("a dropped typist's hint expires", MonkActivity.active(online, peers, "s1", 10, 1011).is_empty())
	for value: Variant in [-1, 10, 1.5, "2", null, INF]:
		online.mate[0]["typing_monk"] = value
		check("invalid typing index is ignored: %s" % str(value), MonkActivity.active(online, peers, "s1", 10, 1000).is_empty())
	online.mate = [{"sid": "s1", "where": "map", "typing_monk": 2, "typing_until": 5000}]
	check("a hint cannot claim an unbounded lifetime", MonkActivity.active(online, peers, "s1", 10, 1000).is_empty())
	online.mate = [{"sid": "s1", "where": "lobby", "typing_monk": 1, "typing_until": 1010},
		{"sid": "s1", "where": "map", "typing_monk": 2, "typing_until": 1010}]
	check("all devices count, but lobby metadata cannot mark a monk", MonkActivity.active(online, peers, "s1", 10, 1000) == {2: true})

	var adv := MovementAdventure.new()
	add_child(adv)
	adv.setup({"practice": true})
	adv.skip_intro()
	adv.play.practice = false
	adv.play.session_id = "s1"
	adv._typing_peers.assign(peers)
	var rt := Net.realtime()
	rt.online = {"mate": [{"sid": "s1", "where": "map", "typing_monk": 2,
		"typing_until": Game.now() + 10}]}
	adv._refresh_busy()
	var monk: Monk = adv.world.monks[2]
	check("a teammate's typing is visible on the actual monk", monk.busy and monk.get_node("Typing").visible)
	rt.online.clear()
	adv._refresh_busy()
	check("departed typists clear the actual marker", not monk.busy)
	monk.set_busy(true)
	monk.take("Blue")
	check("answered monks cannot remain busy", not monk.busy)
	adv._open_monk(0)
	check("opening the keypad announces its monk", rt.get("_tracked").get("typing_monk", -1) == 0)
	check("typing presence never contains the answer", not rt.get("_tracked").has("typed") and not rt.get("_tracked").has("word"))
	var overlay: Control = adv._overlay
	var activity: Array = []
	overlay.activity_changed.connect(func(active: bool) -> void: activity.append(active))
	overlay.check = func(_typed: String) -> String: return "wrong"
	overlay._keypad.press("ᜀ")
	await overlay._on_submit()
	check("a wrong answer clears typing during lockout", not activity.is_empty() and activity[-1] == false and not rt.get("_tracked").has("typing_monk"))
	overlay._locked_until = Time.get_ticks_msec() / 1000.0 - 0.1
	overlay._process(0.0)
	check("an open keypad resumes typing when lockout ends", activity[-1] == true and rt.get("_tracked").get("typing_monk", -1) == 0)
	overlay.close()
	await get_tree().process_frame
	check("closing the keypad clears typing presence", not rt.get("_tracked").has("typing_monk"))
	var previous_socket: Variant = rt.get("_ws")
	var previous_state: int = rt.get("_state")
	var direct := Socket.new()
	rt.set("_ws", direct)
	rt.set("_state", WebSocketPeer.STATE_OPEN)
	rt.set("_pos_live", {Realtime.snap_topic("s1"): true})
	rt.online.clear()
	adv._share_position(3.0)
	check("positions go out on the match's own channel", direct.messages.size() == 1
		and direct.messages[0].event == "broadcast")
	rt.set("_ws", previous_socket)
	rt.set("_state", previous_state)
	rt.close_socket()
	adv.queue_free()
	await get_tree().process_frame
	rt.close_socket()


func _room_controls() -> void:
	var form := RoomPreview.new()
	add_child(form)
	form._build_code()
	form._code.text = "K7Q"
	form._enter()
	check("a room code short of 4 characters is refused before asking the server",
		form._msg.text == "Room codes are 4 characters." and not form._joining, form._msg.text)
	form.queue_free()
	var room := RoomPreview.new()
	add_child(room)
	room.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	room._lobby.session = {"id": "room-preview", "state": "lobby", "custom": true,
		"admin_id": Net.user_id, "code": "AB3K"}
	room._lobby.teams = [{"id": "blue", "name": "Blue"}, {"id": "red", "name": "Red"}]
	room._lobby.players = {Net.user_id: {"username": "Host", "team_id": "blue"},
		"mate": {"username": "Mate", "team_id": "red"}}
	room._build_lobby()
	await get_tree().process_frame
	check("room hosts see Move and Shuffle", room._move.visible and room._shuffle.visible)
	check("room hosts see letter hints, off to begin with", room._hints.visible and room._hints.text == "Hints: Off")
	room._lobby.session.hints = true
	room._draw_lobby()
	check("hints on reads On on the host's button", room._hints.text == "Hints: On")
	room._lobby.session.admin_id = "mate"
	room._draw_lobby()
	check("the rest of the room is told hints are on, and cannot change them",
		not room._hints.visible and room._status.text.ends_with("Letter hints are on."), room._status.text)
	room._lobby.session.admin_id = Net.user_id
	room._lobby.session.hints = false
	room._draw_lobby()
	room._move_dialog()
	await get_tree().process_frame
	check("Move opens a player and destination picker", room._move_panel.find_children("*", "OptionButton", true, false).size() == 2)
	room.go_back()
	await get_tree().process_frame
	check("Back closes Move without leaving the room", not is_instance_valid(room._move_panel) and not room._lobby.session.is_empty())
	room._lobby.session.admin_id = "mate"
	room._draw_lobby()
	check("room members cannot see host controls", not room._move.visible and not room._shuffle.visible
		and not room._go.visible and not room._hints.visible)
	room._lobby.session.admin_id = Net.user_id
	room._lobby.session.state = "running"
	room._entering = true
	room._draw_lobby()
	check("host controls disappear at Start", not room._move.visible and not room._shuffle.visible)
	room.queue_free()
	await get_tree().process_frame


func _watch_view() -> void:
	var snapshot := {"session": {"id": "s1", "state": "running", "duration_s": 600}, "monks": 3,
		"teams": [{"id": "blue", "name": "Blue", "deposited": 1, "carried": 1, "reached_at": "2026-10-23T00:01:00.1+00:00"},
			{"id": "red", "name": "Red", "deposited": 1, "carried": 0, "reached_at": "2026-10-23T00:01:00.9+00:00"}],
		"players": [{"profile_id": "mate", "team_id": "blue", "username": "Mate", "hero": 1, "carried": 1, "deposited": 1}],
		"answers": [{"team_id": "blue", "monk": 0, "deposited": false}, {"team_id": "red", "monk": 0, "deposited": true}]}
	check("watch timeout tie-break keeps fractional deposit times", WatchFeed.outcome(snapshot) == "Blue wins!")
	snapshot.teams[1].reached_at = snapshot.teams[0].reached_at
	check("watch true ties are draws", WatchFeed.outcome(snapshot) == "Draw")
	snapshot.session.winner_team = "red"
	check("watch trusts the server's completed-team winner", WatchFeed.outcome(snapshot) == "Red wins!")
	var screen := preload("res://scripts/WatchScreen.gd").new()
	add_child(screen)
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen._build_ui()
	screen._apply(snapshot)
	for _frame in 4:
		await get_tree().process_frame
	check("watch renders the same match seed without creating a controllable player", screen.world.seed == Game.seed_of("s1")
		and screen.find_children("*", "TouchScreenButton", true, false).is_empty()
		and screen.find_children("*", "MonkOverlay", true, false).is_empty())
	check("a watched monk takes the colour of the first team to answer him",
		screen.world.monks[0].colour == "Blue" and screen.world.monks[1].colour == "Black")
	check("the watched island is drawn on the screen itself, not a stretched view",
		screen.find_children("*", "SubViewport", true, false).is_empty() and screen.get("_camera").is_current())
	screen._look(screen.get("_center"), screen.get("_fit") * 3.0)
	var was: Vector2 = screen.get("_center")
	var drag := InputEventScreenDrag.new()
	drag.relative = Vector2(-40, 0)
	(screen.get("_pad") as Control).gui_input.emit(drag)
	check("dragging the watched island pans the view", (screen.get("_center") as Vector2).x > was.x
		and screen.get("_camera").position == screen.get("_center"))
	snapshot.session.state = "ended"
	screen._apply(snapshot)
	check("a finished spectator view stops showing an active countdown", screen.get("_time").text == "Final")
	# The Stats table: a heading row, then Player / Carry / Deposited per player.
	var table: GridContainer = screen.get("_lists")[0]
	check("watch keeps individual carry and deposit counts visible", table.get_child_count() == 6
		and table.get_child(3).text == "Mate" and table.get_child(4).text == "1" and table.get_child(5).text == "1")
	screen._on_position("snap", {"sid": "other", "p": [{"id": "mate", "x": 10, "y": 20}]})
	screen._on_position("snap", {"sid": "", "p": [{"id": "stranger", "x": 10, "y": 20}]})
	check("watch ignores foreign-session and non-roster movement", (screen.peers.get("_live") as Dictionary).is_empty())
	screen.queue_free()
	for _frame in 2:
		await get_tree().process_frame


func _records_view() -> void:
	var records := RecordsPreview.new()
	add_child(records)
	records.setup({})
	var rows: Array = []
	for i in 21:
		rows.append({"session_id":str(i),"code":"TEST","custom":true,"completed_at":"2026-10-23T10:11:12+00:00",
			"result":"win","deposited":3,"place":2})
	records._show(rows)
	check("records show twenty rows and know more are coming", records.get("_list").get_child_count() == 20
		and records.get("_more"))
	var labels: Array = records.find_children("*","Label",true,false).map(func(l: Label) -> String: return l.text)
	check("history labels Custom games and the player's rank", labels.any(func(t: String) -> bool: return t.contains("Custom"))
		and labels.any(func(t: String) -> bool: return t.contains("rank 2")))
	var more: Array = rows.slice(0, 5)
	records._show(more)                      # the next batch, scrolled into
	check("scrolling on adds the next batch under the first", records.get("_list").get_child_count() == 25
		and not records.get("_more") and records.get("_offset") == 25)
	records.set("_offset", 0)
	records._show([])
	await get_tree().process_frame
	check("empty history expects no more and explains the empty list", not records.get("_more")
		and records.get("_list").get_child_count() == 1)
	records.set("_tab","player_board")
	records.set("_offset", 0)
	records._show([{"profile_id":Net.user_id,"username":"Me","place":1,"wins":2,"deposited":7,"played":3}])
	labels = records.find_children("*","Label",true,false).map(func(l: Label) -> String: return l.text)
	check("global board shows wins and deposited answers", labels.any(func(t: String) -> bool: return t.contains("2 wins") and t.contains("7 deposited")))
	var results := preload("res://scripts/ResultsScreen.gd")
	check("results preserve sub-second deposit tie-breaks", is_equal_approx(results._seconds_in("2026-10-23T00:00:00.125+00:00",float(Time.get_unix_time_from_datetime_string("2026-10-23T00:00:00"))),0.125))
	records.queue_free()
	await get_tree().process_frame


func _direct_movement() -> void:
	check("fast direct updates get a shorter playback buffer", is_equal_approx(Peers.direct_buffer({"cadence":0.1}),0.15))
	check("old senders keep a compatible playback buffer", Peers.direct_buffer({}) == Peers.LAG_START)
	check("malformed cadence cannot set unbounded delay", Peers.direct_buffer({"cadence":INF}) == Peers.LAG_START
		and Peers.direct_buffer({"cadence":1000}) == Peers.LAG_MAX)
	var points := Peers._points({"p":[[1.0,10,20],[1.07,12,20],[1.23,14,20]]})
	check("frame hitches retain the real sample timestamps", points[1][0]==1.07 and points[2][0]==1.23)
	var peer := Peers.new()
	peer.move("remote",{"cadence":0.1,"p":[[1.0,10,20],[1.05,12,20]]})
	check("actual peer playback uses the advertised cadence", is_equal_approx(float(peer.get("_live").remote.lag),0.15))
	peer.free()

	var adv := MovementAdventure.new()
	add_child(adv)
	adv.setup({"practice":true})
	adv.skip_intro()
	adv.set_process(false)
	adv.play.practice=false
	adv.play.session_id="pace-test"
	adv._peers=Peers.new()
	adv.world.add_child(adv._peers)
	adv._peers.refresh([{"profile_id":"remote","team_id":"red","username":"Remote"}],Vector2.ZERO,Net.user_id)
	var rt := Net.realtime()
	var previous_socket: Variant=rt.get("_ws")
	var previous_state: int=rt.get("_state")
	var socket := Socket.new()
	rt.set("_ws",socket)
	rt.set("_state",WebSocketPeer.STATE_OPEN)
	rt.set("_pos_live",{Realtime.snap_topic("pace-test"):true})
	rt.online.clear()
	adv._share_position(0.1)
	check("the initial position is sent without an idle wait", socket.messages.size()==1)
	socket.messages.clear()
	adv.player.position.x+=5
	adv._share_position(0.1)
	socket.messages.clear()
	adv._share_position(0.1)
	check("a movement stop is sent before the idle heartbeat", socket.messages.size()==1)
	var packet: Dictionary=socket.messages[0].payload.payload.p[0]
	check("direct packets carry timestamped paths and cadence", packet.p is Array and is_equal_approx(float(packet.cadence),Net.movement_interval())
		and packet.p[-1][1]==packet.p[-2][1])
	socket.messages.clear()
	adv._share_position(0.1)
	check("standing still does not stream redundant movement", socket.messages.is_empty())
	rt.set("_pos_live",{})
	adv.player.position.x+=5
	adv._share_position(0.1)
	adv._share_position(0.1)
	rt.set("_pos_live",{Realtime.snap_topic("pace-test"):true})
	adv._share_position(0.05)
	check("a joining channel retains pending movement for an immediate retry", socket.messages.size()==1)
	rt.set("_ws",previous_socket)
	rt.set("_state",previous_state)
	rt.close_socket()
	adv.queue_free()
	await get_tree().process_frame

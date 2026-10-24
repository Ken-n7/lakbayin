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
	var snap := {"sid": "s1", "r": [{"profile_id": "alice", "gems": 60, "items_done": 1, "eliminated": false}]}
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
	msg.payload.payload = {"sid": "other", "r": snap.r}
	rt._handle(msg)
	check("a snapshot cannot claim another session", received.size() == 1)
	msg.payload.payload = {"sid": "s1", "p": "not an array"}
	rt._handle(msg)
	check("malformed snapshots are rejected before reaching map code", received.size() == 1)
	check("a player input must match its own topic", not Realtime.valid_position(
		Realtime.in_topic("s1", "bob"), "pos", {"sid": "s1", "id": "alice", "x": 1, "y": 2}))
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
	check("only matching event viewers request spectator snapshots", WatchFeed.has_viewers(
		{"viewer": [{"sid": "s1", "where": "watch"}]}, "s1") and not WatchFeed.has_viewers(
		{"viewer": [{"sid": "other", "where": "watch"}]}, "s1"))
	var snapshot := {"session": {"id": "s1", "state": "running", "duration_s": 600}, "monks": 3,
		"teams": [{"id": "blue", "name": "Blue", "deposited": 1, "carried": 1, "reached_at": "2026-10-23T00:01:00.1+00:00"},
			{"id": "red", "name": "Red", "deposited": 1, "carried": 0, "reached_at": "2026-10-23T00:01:00.9+00:00"}],
		"players": [{"profile_id": "mate", "team_id": "blue", "username": "Mate", "hero": 1, "carried": 1, "deposited": 1}],
		"answers": [{"team_id": "blue", "monk": 0, "deposited": false}, {"team_id": "red", "monk": 0, "deposited": true}]}
	check("watch monk state is independent for each team", WatchFeed.monk_state(snapshot, "blue", 0) == 1
		and WatchFeed.monk_state(snapshot, "red", 0) == 2 and WatchFeed.monk_state(snapshot, "blue", 1) == 0)
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
	check("results and history share ranks for exact player ties", results._place([
		{"deposited":2,"reached_s":3.0},{"deposited":2,"reached_s":3.0},{"deposited":0}],1) == 1
		and results._place([{"deposited":2},{"deposited":2},{"deposited":0}],2) == 3)
	check("results preserve sub-second deposit tie-breaks", is_equal_approx(results._seconds_in("2026-10-23T00:00:00.125+00:00",float(Time.get_unix_time_from_datetime_string("2026-10-23T00:00:00"))),0.125))
	records.queue_free()
	await get_tree().process_frame


func _direct_movement() -> void:
	check("fast direct updates get a shorter playback buffer", is_equal_approx(Peers.direct_buffer({"cadence":0.1}),0.15))
	check("old senders keep a compatible playback buffer", Peers.direct_buffer({}) == Peers.LAG_START)
	check("malformed cadence cannot set unbounded delay", Peers.direct_buffer({"cadence":INF}) == Peers.LAG_START
		and Peers.direct_buffer({"cadence":1000}) == Peers.LAG_MAX)
	var points := Peers._points({"p":[[1.0,10,20],[1.07,12,20],[1.23,14,20]]},0.0)
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
	adv._peers.refresh([{"profile_id":"remote","team_id":"red","username":"Remote"}],[],Vector2.ZERO,Net.user_id)
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

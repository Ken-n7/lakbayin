extends TestCase
## Realtime and relay regressions that do not need a match on screen; all
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
	var was_key := Net.anon_key
	Net.url = "http://127.0.0.1:1"
	Net.anon_key = "test"
	Net.access_token = "test"
	Net.user_id = "alice"
	_private_movement()
	_channel_recovery()
	_lobby_reconnect()
	await _monk_activity()
	await _room_controls()
	await _watch_view()
	await _records_view()
	_account_change()
	Net.realtime().close_socket()
	Net.relay().leave()
	Net.url = was_url
	Net.anon_key = was_key
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
	var link := Net.relay()
	link.join("s1", "player")
	link.set("_ticket", "alice-ticket")
	link.set("_ticket_of", "s1|player")
	link.set("_ticket_user", "alice")
	link.set("_ticket_at", Time.get_ticks_msec() / 1000.0)
	Net.sign_out()
	Net.user_id = "bob"
	Net.access_token = "bob-token"
	link.join("s1", "player")
	check("logout discards the previous player's relay ticket", link.get("_ticket") == "" and link.get("_ticket_user") == "")


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
	var relay := Net.relay()
	var fast := Socket.new()
	relay.set("_ws", fast)
	relay.set("_role", "player")
	relay.up = true
	rt.online.clear()
	adv._share_position(3.0)
	check("relay players avoid duplicate direct broadcasts without viewers", direct.messages.is_empty() and fast.samples > 0)
	rt.online = {"viewer": [{"sid": "s1", "where": "watch"}]}
	adv._share_position(3.0)
	check("relay players also deliver positions to event viewers", direct.messages.size() == 1
		and direct.messages[0].event == "broadcast")
	relay.set("_ws", null)
	relay.up = false
	rt.set("_ws", previous_socket)
	rt.set("_state", previous_state)
	rt.close_socket()
	adv.queue_free()
	await get_tree().process_frame
	rt.close_socket()


func _room_controls() -> void:
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
	room._move_dialog()
	await get_tree().process_frame
	check("Move opens a player and destination picker", room._move_panel.find_children("*", "OptionButton", true, false).size() == 2)
	room.go_back()
	await get_tree().process_frame
	check("Back closes Move without leaving the room", not is_instance_valid(room._move_panel) and not room._lobby.session.is_empty())
	room._lobby.session.admin_id = "mate"
	room._draw_lobby()
	check("room members cannot see host controls", not room._move.visible and not room._shuffle.visible and not room._go.visible)
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
	check("watch keeps individual carry and deposit counts visible", screen.get("_lists")[0].get_child_count() == 1
		and str(screen.get("_lists")[0].get_child(0).text).contains("carry 1"))
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
	check("records show twenty rows and enable the next page", records.get("_list").get_child_count() == 20
		and not records.get("_next").disabled)
	var labels: Array = records.find_children("*","Label",true,false).map(func(l: Label) -> String: return l.text)
	check("history labels Custom games and the player's rank", labels.any(func(t: String) -> bool: return t.contains("Custom"))
		and labels.any(func(t: String) -> bool: return t.contains("rank 2")))
	records._show([])
	check("empty history disables Next and explains the empty list", records.get("_next").disabled
		and records.get("_list").get_child_count() == 1)
	records.set("_tab","player_board")
	records._show([{"profile_id":Net.user_id,"username":"Me","place":1,"wins":2,"deposited":7,"played":3}])
	labels = records.find_children("*","Label",true,false).map(func(l: Label) -> String: return l.text)
	check("global board shows wins and deposited answers", labels.any(func(t: String) -> bool: return t.contains("2 wins") and t.contains("7 deposited")))
	var results := preload("res://scripts/ResultsScreen.gd")
	check("results preserve sub-second deposit tie-breaks", is_equal_approx(results._seconds_in("2026-10-23T00:00:00.125+00:00",float(Time.get_unix_time_from_datetime_string("2026-10-23T00:00:00"))),0.125))
	records.queue_free()
	await get_tree().process_frame

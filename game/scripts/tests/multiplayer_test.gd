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

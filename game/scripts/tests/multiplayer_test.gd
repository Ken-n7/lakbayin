extends TestCase
## Cross-layer multiplayer regressions; all services stay local/offline.

class RecoveryAdventure extends "res://scripts/AdventureScreen.gd":
	var reloads := 0
	func _resync() -> void:
		reloads += 1

class Teacher extends "res://scripts/GameControlsScreen.gd":
	var reloads := 0
	func _load_teams() -> void:
		reloads += 1

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
	_rejected_progress()
	_station_rejoin()
	_expired_resync()
	_authored_questions()
	_player_removal_controls()
	_private_movement()
	_channel_recovery()
	_mixed_movement()
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
	QuestionStore.bank = {}
	QuestionStore.authored_only = false
	completed = true
	finish("MULTIPLAYER")


func _member(items := 0, gems := 50) -> Dictionary:
	return {"session_id": "s1", "profile_id": "alice", "items_done": items,
		"gems": gems, "correct": items, "wrong": 0, "skipped": 0, "hints_used": 0,
		"stations_done": 0, "eliminated": false, "finished": false,
		"station_flawed": false, "station_used_hint": false, "item_used_hint": false,
		"perfect_stations": [false, false, false]}


func _rejected_progress() -> void:
	Scores.reset()
	Game.begin_adventure()
	Game.clock_paused = true
	Game.session_id = "s1"
	Game.session_state = "running"
	var adv := RecoveryAdventure.new()
	adv.hud = AdventureHud.new(adv)
	Game.mark_correct()
	adv._on_score_reply({"error": "the adventure is not running", "row": _member(),
		"kind": "answer", "session_id": "s1"})
	check("a rejected answer restores its circle, gems and correct count",
		Game.items_done == 0 and Game.gems == 50 and Game.correct == 0)
	check("...and refreshes the teacher's state", adv.reloads == 1)
	Game.gems = 0
	Game.eliminated = true
	adv.set("_spectate", "eliminated")
	adv._take_server_row(_member())
	check("a refused optimistic elimination returns to play", not Game.eliminated and adv.get("_spectate") == "")
	var row := _member(1, 50)
	row.eliminated = true
	# An active quiz defers spectating, but must still take the flag when gems match.
	var overlay := Control.new()
	adv.set("_overlay", overlay)
	adv._take_server_row(row)
	check("equal gem totals still reconcile elimination and progress", Game.eliminated and Game.items_done == 1)
	row.eliminated = false
	row.revision = 2
	adv._take_server_row(row)
	var older := _member()
	older.revision = 1
	adv._take_server_row(older)
	check("out-of-order change events cannot roll back a newer answer", Game.items_done == 1)
	var newer := _member(1, 65)
	newer.revision = 3
	Scores.know(newer)
	adv._take_server_row(row)
	check("a change received during a score is retained for its reply", Game.gems == 65)
	Game.give_rescue(15, {"gems": 50, "eliminated": false})
	Game.give_rescue(15, {"gems": 50, "eliminated": false})
	check("a rescue already applied by the change feed is not charged twice", Game.gems == 50)
	overlay.free()
	adv.set("_overlay", null)
	adv.free()


func _station_rejoin() -> void:
	Game.begin_adventure()
	Game.clock_paused = true
	Game.session_id = "s1"
	var row := _member(8, 140)
	row.stations_done = 1
	row.perfect_stations = [true, false, false]
	Game.restore_from(row)
	check("a boundary restart restores the committed station", Game.completed_stations == [true, false, false])
	check("Continue after an early server reply cannot award the bonus twice",
		Game.finish_station(0) == 10 and Game.gems == 140)
	row = _member(9, 145)
	row.stations_done = 1
	row.station_flawed = true
	row.station_used_hint = true
	row.item_used_hint = true
	row.wrong = 1
	row.skipped = 2
	row.hints_used = 3
	Game.restore_from(row)
	check("a rejoin retains current station and hint state",
		Game.station_flawed and Game.station_used_hint and Game.item_used_hint)
	check("a rejoin retains wrong, skip and hint totals", Game.wrong == 1 and Game.skipped == 2 and Game.hints_used == 3)


func _expired_resync() -> void:
	Game.begin_adventure()
	Game.apply_session({"id": "s1", "state": "running", "duration_s": 600,
		"ends_at": "2020-01-01T00:00:00Z"})
	check("an already expired session cannot score", not Game.can_score())
	Game._process(0.01)
	check("an already-zero clock ends on the next tick", not Game.adventure_active)


func _authored_questions() -> void:
	QuestionStore.authored_only = true
	QuestionStore.bank = {}
	check("a missing online question never becomes a generated question", QuestionStore.item_for(0, 0).is_empty())
	var rows: Array = []
	for station in Game.ITEMS_PER_STATION.size():
		for i in Game.ITEMS_PER_STATION[station]:
			rows.append({"station": station + 1, "prompt": "Teacher %d/%d" % [station, i],
				"answer": "2", "hint": "hint", "active": true})
	check("a complete session snapshot is ready", QuestionStore.use_session({"question_bank": rows}) == "")
	check("the snapshot supplies the teacher's actual question", QuestionStore.item_for(0, 0).prompt == "Teacher 0/0")
	check("an incomplete snapshot stays blocked", QuestionStore.use_session({"question_bank": rows.slice(0, 8)}) != "")
	check("...without topping up the missing station", QuestionStore.item_for(1, 0).is_empty())
	QuestionStore.authored_only = false
	QuestionStore.bank = {}
	check("offline practice still generates questions", not QuestionStore.item_for(0, 0).is_empty())


func _player_removal_controls() -> void:
	var teacher := Teacher.new()
	add_child(teacher)
	var teams: Array = [{"id": "red", "name": "Red"}, {"id": "blue", "name": "Blue"}]
	teacher.set("_session", {"id": "s1", "state": "lobby"})
	var chip := teacher._player_chip({"profile_id": "alice", "username": "Alice"}, "red", teams)
	var menu := (chip as MenuButton).get_popup()
	var labels: Array = []
	for i in menu.item_count:
		labels.append(menu.get_item_text(i))
	check("a lobby player's menu offers removal with the team moves", "Remove player…" in labels
		and "Move to Blue" in labels)
	chip.free()
	teacher._confirm_remove_player("alice", "Alice")
	check("removing a player always asks for confirmation", _has_button(teacher, "Remove")
		and _has_button(teacher, "Keep player"))
	teacher.get_child(teacher.get_child_count() - 1).free()
	teacher.set("_session", {"id": "s1", "state": "running"})
	chip = teacher._player_chip({"profile_id": "alice", "username": "Alice"}, "red", teams)
	check("a player's menu is locked and empty after Start", (chip as MenuButton).disabled
		and (chip as MenuButton).get_popup().item_count == 0)
	chip.free()
	teacher.free()
	var student := Student.new()
	add_child(student)
	student.set("_session", {"id": "s1", "state": "lobby"})
	Game.joined_session = "s1"
	Game.joined_code = "ABCD"
	student._on_row("members", "DELETE", {"session_id": "s1", "profile_id": "alice"})
	check("a removed player returns to code entry with an explanation",
		Game.joined_session == "" and Game.joined_code == ""
		and is_instance_valid(student.get("_code"))
		and str((student.get("_msg") as Label).text) == "You were removed from that session.")
	student.free()


func _has_button(root: Node, text: String) -> bool:
	if root is Button and (root as Button).text == text:
		return true
	for child in root.get_children():
		if _has_button(child, text):
			return true
	return false


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


## Twelve phones: eleven on the relay, one on the hub. The teacher can reach
## Supabase but is reconnecting to the relay, as in the recorded classroom.
## Use the real send/validation/hub/receive/playback code with local sockets.
func _mixed_movement() -> void:
	var rt := Net.realtime()
	var link := Net.relay()
	var old_ws: Variant = rt.get("_ws")
	var old_state: int = rt.get("_state")
	var old_topics: Dictionary = rt.get("_pos_topics")
	var old_live: Dictionary = rt.get("_pos_live")
	var old_link_ws: Variant = link.get("_ws")
	var old_up := link.up
	var old_role: String = link.get("_role")
	var old_user := Net.user_id
	var socket := Socket.new()
	rt.set("_ws", socket)
	rt.set("_state", WebSocketPeer.STATE_OPEN)
	link.set("_ws", socket)
	link.set("_role", "player")
	Game.session_id = "s1"
	var topics := {}
	var live := {}
	var rows: Array = []
	var anchors: Array = [Vector2.ZERO]
	var senders: Array = []
	for i in 12:
		var id := "student%d" % i
		topics[Realtime.in_topic("s1", id)] = "joined"
		live[Realtime.in_topic("s1", id)] = true
		rows.append({"profile_id": id, "username": id, "items_done": 0})
		var sender := MovementAdventure.new()
		sender.player = Node2D.new()
		sender.add_child(sender.player)
		sender.player.position = Vector2(600 + i * 30, 400)
		senders.append(sender)
	rt.set("_pos_topics", topics)
	rt.set("_pos_live", live)
	var hub := PosHub.new()
	hub.set("_sid", "s1")
	rt.position.connect(hub._on_broadcast)
	# The hub phone announces itself, even standing still at a question.
	link.up = false
	hub._on_broadcast("pos", {"sid": "s1", "id": "student0", "x": 600, "y": 400})
	var request := hub.take_snapshot()
	check("a teacher without the relay requests a bridge for fallback listeners", bool(request.get("bridge", false)))
	link.up = true
	Net.user_id = "student1"
	(senders[1] as MovementAdventure)._share_position(3.1)
	check("a healthy relay alone adds no Supabase movement traffic", socket.messages.is_empty() and socket.samples > 0)
	for sender: MovementAdventure in senders:
		sender._on_position("snap", request)
	for i in 12:
		Net.user_id = "student%d" % i
		link.up = i != 0
		(senders[i] as MovementAdventure)._share_position(3.1)
	for msg: Dictionary in socket.messages:
		rt._handle(msg)
	link.up = false                  # the teacher's relay is still unavailable
	var snap := hub.take_snapshot()
	check("a mixed class delivers all twelve paths while the teacher reconnects",
		(snap.get("p", []) as Array).size() == 12, str((snap.get("p", []) as Array).size()))
	var observer := MovementAdventure.new()
	observer._spectate = "finished"
	observer._peers = Peers.new()
	observer.add_child(observer._peers)
	observer._peers.refresh(rows, anchors, Vector2(9999, 9999), "")
	observer._on_position("snap", snap)
	observer._peers._process(1.0)
	var moving := 0
	for i in 12:
		var marker: Node2D = observer._peers._markers["student%d" % i]
		if marker.position.distance_to((senders[i] as MovementAdventure).player.position) < 1.0:
			moving += 1
	check("a finished spectator sees all twelve actual positions instead of station piles", moving == 12, str(moving))
	# The teacher reconnects: mirroring stops on its next snapshot.
	link.up = true
	socket.messages.clear()
	(senders[1] as MovementAdventure)._on_position("snap", {"sid": "s1", "bridge": false})
	Net.user_id = "student1"
	(senders[1] as MovementAdventure)._share_position(3.1)
	check("the teacher's recovery stops redundant movement traffic", socket.messages.is_empty())
	# Mirrored relay traffic must never keep its own bridge request alive.
	hub.set("_hub_path_at", -INF)
	hub._on_broadcast("pos", {"sid": "s1", "id": "student1", "relay": true, "x": 630, "y": 400})
	check("relay mirrors do not sustain the fallback bridge themselves", not hub.bridging())
	# A slow answer can last longer than Peers.STALE_S and PosHub.BRIDGE_S.
	socket.messages.clear()
	link.up = false
	Net.user_id = "student0"
	var quiz := Control.new()
	(senders[0] as MovementAdventure)._overlay = quiz
	(senders[0] as MovementAdventure)._share_position(3.1)
	check("an open question retains the idle movement and bridge heartbeat", socket.messages.size() == 1)
	(senders[0] as MovementAdventure)._overlay = null
	socket.messages.clear()
	(senders[0] as MovementAdventure)._conn = "offline"
	(senders[0] as MovementAdventure)._share_position(3.1)
	check("a REST outage does not suppress movement on a live position channel", socket.messages.size() == 1)
	quiz.free()
	observer.free()
	for sender: MovementAdventure in senders:
		sender.free()
	hub.free()
	rt.set("_ws", old_ws)
	rt.set("_state", old_state)
	rt.set("_pos_topics", old_topics)
	rt.set("_pos_live", old_live)
	link.set("_ws", old_link_ws)
	link.set("_role", old_role)
	link.up = old_up
	Net.user_id = old_user
	Game.session_id = ""


func _lobby_reconnect() -> void:
	var teacher := Teacher.new()
	teacher.set("_session", {"id": "s1", "state": "lobby"})
	teacher._watch_roster()
	var student := Student.new()
	student.set("_session", {"id": "s1", "state": "lobby"})
	student._watch()
	Net.realtime().subscribed.emit()
	check("teacher roster reloads when the stream comes back", teacher.reloads == 1)
	check("student lobby reloads when the stream comes back", student.reloads == 1)
	teacher.free()
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
	check("logout discards score recovery state", Scores.pending() == 0)

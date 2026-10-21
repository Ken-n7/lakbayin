extends TestCase
## Removal during map readiness and delayed lobby reads, with local HTTP only.

class JoinProbe extends "res://scripts/TeamNameScreen.gd":
	var auto_entries := 0
	func _enter(_quiet := false) -> void:
		auto_entries += 1

class Router extends Control:
	var joined: JoinProbe
	func open(_screen: String, data: Dictionary = {}) -> void:
		joined = JoinProbe.new()
		add_child(joined)
		joined.setup(data)

class MapProbe extends "res://scripts/AdventureScreen.gd":
	func _process(_delta: float) -> void:
		pass
	func _exit_tree() -> void:
		pass

const SID := "11111111-1111-1111-1111-111111111111"
const PORT := 47397
var _server := TCPServer.new()
var _peers: Array[StreamPeerTCP] = []
var _bufs := {}
var _roster_requested := false
var _release_roster := false
var _roster_done := false
var _include_member := true
var _deletes := 0


func _ready() -> void:
	backup_save()
	var was_url := Net.url
	var was_key := Net.anon_key
	Net.url = "http://127.0.0.1:%d" % PORT
	Net.anon_key = "test"
	Net.access_token = "test"
	Net.user_id = "alice"
	# Row events are injected directly; this stub only serves REST requests.
	var rt := Net.realtime()
	rt.set_process(false)
	var listening := _server.listen(PORT, "127.0.0.1") == OK
	check("local removal test server starts", listening)
	if not listening:
		completed = true
		finish("REMOVAL")
		return
	await _old_confirmation()
	await _ready_player()
	await _delayed_reads()
	rt.close_socket()
	rt.set_process(true)
	Net.relay().leave()
	_server.stop()
	_peers.clear()
	_bufs.clear()
	Net.url = was_url
	Net.anon_key = was_key
	Net.access_token = ""
	Net.user_id = ""
	Game.abandon_adventure()
	Game.session_id = ""
	Game.session_state = ""
	for player in Sfx._pool:
		player.stop()
		player.stream = null
	# Let the audio mixer release the error sound before the headless engine exits.
	await get_tree().create_timer(0.1).timeout
	completed = true
	finish("REMOVAL")


func _old_confirmation() -> void:
	var teacher := load("res://scripts/GameControlsScreen.gd").new() as Control
	add_child(teacher)
	var message := Label.new()
	teacher.add_child(message)
	teacher.set("_msg", message)
	teacher.set("_session", {"id": SID, "state": "lobby"})
	teacher._confirm_remove_player("alice", "Alice")
	var remove := _button(teacher, "Remove")
	check("lobby removal asks for confirmation", remove != null)
	teacher.set("_session", {"id": SID, "state": "running"})
	if remove != null:
		remove.pressed.emit()
	await get_tree().process_frame
	check("confirming an old dialog after Start sends no DELETE",
		_deletes == 0 and message.text.contains("can no longer be removed"))
	for state in ["paused", "ended"]:
		teacher.set("_session", {"id": SID, "state": state})
		await teacher._remove_player("alice", "Alice")
	check("paused and ended games also refuse removal", _deletes == 0)
	teacher.free()


func _ready_player() -> void:
	var router := Router.new()
	add_child(router)
	var map := MapProbe.new()
	map.main = router
	map.hud = AdventureHud.new(map)
	add_child(map)
	Game.joined_session = SID
	Game.joined_code = "ACDE"
	Game.session_id = SID
	map._on_session_row("members", "DELETE", {"session_id": SID, "profile_id": "alice"})
	check("a removed ready player immediately forgets the saved session",
		Game.joined_code == "" and Game.joined_session == "")
	await get_tree().create_timer(1.8).timeout
	check("returning from the map does not automatically rejoin",
		is_instance_valid(router.joined) and router.joined.auto_entries == 0)
	check("a removed ready player sees the removal explanation",
		is_instance_valid(router.joined)
		and (router.joined.get("_msg") as Label).text == "You were removed from that session.")
	map.hud = null
	map.main = null
	map.free()
	router.free()
	var transitioning := MapProbe.new()
	add_child(transitioning)
	transitioning.set("_ending", true)
	Game.joined_session = SID
	Game.joined_code = "ACDE"
	transitioning._leave_removed()
	check("removal also clears rejoining during an existing team transition",
		Game.joined_session == "" and Game.joined_code == "")
	transitioning.free()


func _delayed_reads() -> void:
	var student := load("res://scripts/TeamNameScreen.gd").new() as Control
	add_child(student)
	student.setup({})
	_reset_response(true)
	(student.get("_code") as LineEdit).text = "ACDE"
	student._enter()
	check("the first roster read can be held in flight",
		await _until(func() -> bool: return _roster_requested))
	student._on_row("members", "DELETE", {"session_id": SID, "profile_id": "alice"})
	_release_roster = true
	await _until(func() -> bool: return _roster_done)
	await get_tree().create_timer(0.15).timeout
	check("an old roster containing the removed player cannot restore the lobby", _removed(student))
	# Removing somebody is not a ban: a new, deliberate join must still work.
	_reset_response(true)
	_release_roster = true
	(student.get("_code") as LineEdit).text = "ACDE"
	student._enter()
	await _until(func() -> bool: return _roster_done)
	await get_tree().create_timer(0.15).timeout
	check("a removed player can deliberately rejoin the open lobby",
		Game.joined_session == SID and Game.joined_code == "ACDE"
		and (student.get("_lobby") as Lobby).players.has("alice"))
	_reset_response(true)
	student._reload_lobby()
	check("a reconnect roster read can be held in flight",
		await _until(func() -> bool: return _roster_requested))
	student._on_row("members", "DELETE", {"session_id": SID, "profile_id": "alice"})
	_release_roster = true
	await _until(func() -> bool: return _roster_done)
	await get_tree().create_timer(0.15).timeout
	check("a reconnect response cannot undo removal", _removed(student))
	# The delete event might have happened before the subscription was ready.
	_reset_response(false)
	_release_roster = true
	(student.get("_code") as LineEdit).text = "ACDE"
	student._enter()
	await _until(func() -> bool: return _roster_done)
	await get_tree().create_timer(0.15).timeout
	check("a missing membership in the initial read returns to code entry", _removed(student))
	student.free()


func _removed(student: Control) -> bool:
	return Game.joined_code == "" and Game.joined_session == "" \
		and (student.get("_session") as Dictionary).is_empty() \
		and (student.get("_lobby") as Lobby).session.is_empty() \
		and (student.get("_msg") as Label).text == "You were removed from that session."


func _reset_response(include_member: bool) -> void:
	_include_member = include_member
	_roster_requested = false
	_release_roster = false
	_roster_done = false


func _until(condition: Callable) -> bool:
	for i in 120:
		if condition.call():
			return true
		await get_tree().create_timer(0.025).timeout
	return false


func _process(_delta: float) -> void:
	while _server.is_listening() and _server.is_connection_available():
		var peer := _server.take_connection()
		_peers.append(peer)
		_bufs[peer] = ""
	for peer in _peers.duplicate():
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_peers.erase(peer)
			continue
		var n: int = peer.get_available_bytes()
		if n > 0:
			_bufs[peer] += peer.get_utf8_string(n)
		var raw: String = _bufs[peer]
		if not raw.contains("\r\n\r\n"):
			continue
		var path := raw.get_slice(" ", 1)
		if raw.begins_with("DELETE "):
			_deletes += 1
		if path.contains("select=*,teams"):
			_roster_requested = true
			if not _release_roster:
				continue
			var members: Array = [{"profile_id": "alice", "team_id": "red",
				"profiles": {"username": "Alice"}}] if _include_member else []
			_reply(peer, [{"id": SID, "code": "ACDE", "state": "lobby",
				"teams": [{"id": "red", "name": "Red"}], "members": members}])
			_roster_done = true
		elif path.begins_with("/rest/v1/sessions"):
			_reply(peer, [{"id": SID, "code": "ACDE", "state": "lobby"}])
		elif path.begins_with("/rest/v1/members"):
			_reply(peer, [{"session_id": SID, "profile_id": "alice"}])
		else:
			_reply(peer, [])


func _reply(peer: StreamPeerTCP, body: Variant) -> void:
	var payload := JSON.stringify(body)
	var reply := ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
		+ "Content-Length: %d\r\nConnection: close\r\n\r\n%s") % [payload.to_utf8_buffer().size(), payload]
	peer.put_data(reply.to_utf8_buffer())
	peer.disconnect_from_host()
	_peers.erase(peer)
	_bufs.erase(peer)


func _button(node: Node, label: String) -> Button:
	if node is Button and (node as Button).text == label:
		return node as Button
	for child in node.get_children():
		var found := _button(child, label)
		if found != null:
			return found
	return null

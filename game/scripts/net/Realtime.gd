class_name Realtime
extends Node

## Supabase Realtime over `WebSocketPeer`. There is no Godot SDK, so this
## speaks the Phoenix channel protocol directly: connect, join a topic with a
## `postgres_changes` config, heartbeat, and decode what comes back.
##
## This is the one connection the session needs -- the admin's pause and the
## live leaderboard both ride on it.
##
## Not an autoload: `Net.realtime()` makes it on first use and keeps it as a
## child, so a signed-out client holds no socket open.

## `table` is "sessions"/"members"/..., `type` is INSERT/UPDATE/DELETE, and
## `record` is the new row (the old one for a delete).
signal changed(table: String, type: String, record: Dictionary)
signal opened
## The join being accepted is NOT the same as the stream being live: Phoenix
## replies `phx_join` ok, then sends a separate "Subscribed to PostgreSQL"
## system message, and a row changed in between is never delivered. Wait for
## this, never for a timer.
signal subscribed
signal closed(code: int)

## Phoenix drops a socket it has not heard from; ask sooner than its own 30s.
const HEARTBEAT_S := 25.0

var _ws := WebSocketPeer.new()
var _state := WebSocketPeer.STATE_CLOSED
var _ref := 0
var _since_beat := 0.0
## Tables asked for before the socket opened, re-sent once it does.
var _wanted: Array[Dictionary] = []
var _joined := false
## True once the server confirms the stream, not merely the join.
var live := false


func open_socket() -> void:
	# The peer's own state, not the cached one: `_state` only catches up in
	# `_process`, so two `watch()` calls in the same frame -- members and
	# teams, say -- both saw CLOSED and the second connect returned
	# ERR_ALREADY_IN_USE.
	var live := _ws.get_ready_state()
	if live == WebSocketPeer.STATE_OPEN or live == WebSocketPeer.STATE_CONNECTING:
		return
	var url := Net.url.replace("https://", "wss://") \
		+ "/realtime/v1/websocket?apikey=" + Net.anon_key + "&vsn=1.0.0"
	var err := _ws.connect_to_url(url)
	if err != OK:
		push_warning("Realtime: connect failed (%d)" % err)


## Watch a table, optionally filtered the way PostgREST filters reads --
## `"session_id=eq.<uuid>"`. Safe to call before the socket is open.
func watch(table: String, filter := "") -> void:
	_wanted.append({"table": table, "filter": filter})
	open_socket()
	if _joined:
		_join()   # re-join with the widened config


func close_socket() -> void:
	_wanted.clear()
	_joined = false
	live = false
	if _state != WebSocketPeer.STATE_CLOSED:
		_ws.close()


func is_open() -> bool:
	return _state == WebSocketPeer.STATE_OPEN


func _process(delta: float) -> void:
	_ws.poll()
	var now := _ws.get_ready_state()
	if now != _state:
		_state = now
		if now == WebSocketPeer.STATE_OPEN:
			_joined = false
			_join()
			opened.emit()
		elif now == WebSocketPeer.STATE_CLOSED:
			closed.emit(_ws.get_close_code())
	if _state != WebSocketPeer.STATE_OPEN:
		return

	_since_beat += delta
	if _since_beat >= HEARTBEAT_S:
		_since_beat = 0.0
		_send("phoenix", "heartbeat", {})

	while _ws.get_available_packet_count() > 0:
		var text := _ws.get_packet().get_string_from_utf8()
		if OS.get_environment("RT_DEBUG") != "":
			print("RT<< ", text.substr(0, 400))
		var msg: Variant = JSON.parse_string(text)
		if msg is Dictionary:
			_handle(msg)


## One topic carrying every table we care about. Phoenix allows several, but a
## second topic is a second join, a second heartbeat and a second thing to get
## wrong, for no gain at this size.
func _join() -> void:
	var changes: Array = []
	for w: Dictionary in _wanted:
		var c := {"event": "*", "schema": "public", "table": w.table}
		if w.filter != "":
			c["filter"] = w.filter
		changes.append(c)
	_send("realtime:numxventure", "phx_join", {
		"config": {"postgres_changes": changes},
		# RLS applies to the stream too, so the socket has to say who it is.
		# Without this a watcher sees nothing and no error explains why.
		"access_token": Net.access_token,
	})
	_joined = true
	live = false


func _handle(msg: Dictionary) -> void:
	match str(msg.get("event", "")):
		"postgres_changes":
			var payload: Variant = msg.get("payload")
			if not (payload is Dictionary):
				return
			var data: Variant = (payload as Dictionary).get("data")
			if not (data is Dictionary):
				return
			var d: Dictionary = data
			var kind := str(d.get("type", ""))
			var row: Variant = d.get("record") if kind != "DELETE" else d.get("old_record")
			changed.emit(str(d.get("table", "")), kind, row if row is Dictionary else {})
		"system":
			var sys: Variant = msg.get("payload")
			if sys is Dictionary and str((sys as Dictionary).get("status", "")) == "ok" \
					and str((sys as Dictionary).get("extension", "")) == "postgres_changes":
				live = true
				subscribed.emit()
		"phx_reply":
			var reply: Variant = msg.get("payload")
			if reply is Dictionary and str((reply as Dictionary).get("status", "")) == "error":
				push_warning("Realtime: join refused -- %s" % str(reply))


func _send(topic: String, event: String, payload: Dictionary) -> void:
	_ref += 1
	if OS.get_environment("RT_DEBUG") != "":
		print("RT>> ", event, " ", JSON.stringify(payload).substr(0, 300))
	_ws.send_text(JSON.stringify({
		"topic": topic,
		"event": event,
		"payload": payload,
		"ref": str(_ref),
	}))

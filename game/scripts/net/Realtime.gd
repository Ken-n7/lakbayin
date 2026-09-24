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
## A Broadcast message from another client on the topic -- not a database
## change. `event` is the sender's name for it ("pos"), `payload` its data.
signal broadcast(event: String, payload: Dictionary)
## Somebody arrived on or left the topic. `online` has the current picture.
signal presence_changed
## The join being accepted is NOT the same as the stream being live: Phoenix
## replies `phx_join` ok, then sends a separate "Subscribed to PostgreSQL"
## system message, and a row changed in between is never delivered. Wait for
## this, never for a timer.
signal subscribed
signal closed(code: int)

## Phoenix drops a socket it has not heard from; ask sooner than its own 30s.
const HEARTBEAT_S := 25.0
## A dropped socket on classroom WiFi comes back on its own after this long.
## Without it, one blip and the teacher's pause never reaches that phone again.
const RECONNECT_S := 2.0
const TOPIC := "realtime:numxventure"

var _ws := WebSocketPeer.new()
var _state := WebSocketPeer.STATE_CLOSED
var _ref := 0
var _since_beat := 0.0
var _retry_in := -1.0
var _rejoin_in := -1.0
## The ref our live `phx_join` went out under. A channel's `phx_close` carries
## its own join ref, so a close for a join we already replaced is ignored --
## re-joining the topic closes the old channel, and reacting to that would loop.
var _join_ref := ""
## The token the channel was joined with. When the REST side renews it, the
## channel is told on the next heartbeat -- Realtime closes a channel whose JWT
## has expired, and an adventure can outlast the hour a token lives.
var _joined_token := ""
## Tables asked for before the socket opened, re-sent once it does.
var _wanted: Array[Dictionary] = []
var _joined := false
## True once the server confirms the stream, not merely the join.
var live := false
## Who is connected right now: user id -> what they last announced with
## `track()` (session, where they are, name). Supabase keeps this list and
## drops a phone from it by itself when its connection goes, which is the
## point -- nothing here has to notice a phone dying.
var online := {}
## key -> {phx_ref: meta}. One user can hold two connections (two windows);
## they only count as gone when the last one leaves.
var _presence := {}
## What this phone announces, re-sent after every (re)join.
var _tracked := {}


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
##
## One watch per table: a device follows one session at a time, so a new
## filter replaces the old rather than piling up beside it. Appending made
## every screen open add a duplicate, and kept last session's filters live.
func watch(table: String, filter := "") -> void:
	for w: Dictionary in _wanted:
		if w.table == table and w.filter == filter:
			open_socket()
			return
	_wanted.assign(_wanted.filter(func(o: Dictionary) -> bool: return o.table != table))
	_wanted.append({"table": table, "filter": filter})
	open_socket()
	if _joined:
		_join()   # re-join with the widened config


## Tell everyone else on the topic something, without touching the database.
## Dropped silently while the channel is not up -- positions are sent again a
## moment later, so a lost one costs nothing.
func send_broadcast(event: String, payload: Dictionary) -> void:
	if _state != WebSocketPeer.STATE_OPEN or not _joined:
		return
	_send(TOPIC, "broadcast", {"type": "broadcast", "event": event, "payload": payload})


## Announce this phone on the presence list -- `{sid, where, name}` -- or
## update what it says. Kept, and announced again after any reconnect.
func track(meta: Dictionary) -> void:
	_tracked = meta
	_send_track()


func untrack() -> void:
	_tracked = {}
	if _state == WebSocketPeer.STATE_OPEN and _joined:
		_send(TOPIC, "presence", {"type": "presence", "event": "untrack"})


func _send_track() -> void:
	if _tracked.is_empty() or _state != WebSocketPeer.STATE_OPEN or not _joined:
		return
	_send(TOPIC, "presence", {"type": "presence", "event": "track", "payload": _tracked})


func close_socket() -> void:
	_wanted.clear()
	_tracked = {}
	_presence = {}
	online = {}
	_retry_in = -1.0
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
			_joined = false
			live = false
			if not _wanted.is_empty():
				_retry_in = RECONNECT_S
			# Nobody can be seen from a dead socket; the rejoin sends the
			# whole list again.
			_presence = {}
			online = {}
			presence_changed.emit()
			closed.emit(_ws.get_close_code())
	if _retry_in > 0.0:
		_retry_in -= delta
		if _retry_in <= 0.0:
			_retry_in = -1.0
			open_socket()
	if _state != WebSocketPeer.STATE_OPEN:
		return
	if _rejoin_in > 0.0:
		_rejoin_in -= delta
		if _rejoin_in <= 0.0:
			_rejoin_in = -1.0
			_join()

	_since_beat += delta
	if _since_beat >= HEARTBEAT_S:
		_since_beat = 0.0
		_send("phoenix", "heartbeat", {})
		if _joined and Net.access_token != _joined_token:
			_joined_token = Net.access_token
			_send(TOPIC, "access_token", {"access_token": _joined_token})

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
			# Realtime never delivers a DELETE to a filtered subscription --
			# measured: a removed team never reached the lobbies. So deletes
			# come unfiltered, carrying only the row's key, and the receiver
			# decides whether the row was one of its own.
			changes.append({"event": "DELETE", "schema": "public", "table": w.table})
		changes.append(c)
	_joined_token = Net.access_token
	_join_ref = str(_ref + 1)
	_send(TOPIC, "phx_join", {
		# `self: false`: a phone does not need its own position echoed back.
		"config": {"postgres_changes": changes, "broadcast": {"self": false},
			# Keyed by user, so a teacher's list is one line per student.
			"presence": {"key": Net.user_id, "enabled": true}},
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
		"broadcast":
			var b: Variant = msg.get("payload")
			if b is Dictionary and (b as Dictionary).get("payload") is Dictionary:
				broadcast.emit(str((b as Dictionary).get("event", "")),
					(b as Dictionary).get("payload"))
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
			elif str(msg.get("ref", "")) == _join_ref:
				# Joined (or rejoined): presence starts empty on a new
				# channel, so say who we are again.
				_send_track()
		"presence_state":
			var st: Variant = msg.get("payload")
			_presence = {}
			if st is Dictionary:
				_presence_add(st)
			_presence_publish()
		"presence_diff":
			var diff: Variant = msg.get("payload")
			if diff is Dictionary:
				_presence_add((diff as Dictionary).get("joins", {}))
				var leaves: Variant = (diff as Dictionary).get("leaves", {})
				if leaves is Dictionary:
					for key: String in leaves:
						for m: Variant in (leaves[key] as Dictionary).get("metas", []):
							if _presence.has(key) and m is Dictionary:
								(_presence[key] as Dictionary).erase(str(m.get("phx_ref", "")))
						if _presence.has(key) and (_presence[key] as Dictionary).is_empty():
							_presence.erase(key)
			_presence_publish()
		"phx_error", "phx_close":
			# The server dropped the channel (an expired token, a restart)
			# while the socket stayed up. Join again rather than go quiet.
			if str(msg.get("topic", "")) == TOPIC and str(msg.get("ref", "")) == _join_ref \
					and not _wanted.is_empty():
				_joined = false
				live = false
				_rejoin_in = RECONNECT_S


func _presence_add(joins: Variant) -> void:
	if not (joins is Dictionary):
		return
	for key: String in joins:
		if not _presence.has(key):
			_presence[key] = {}
		for m: Variant in (joins[key] as Dictionary).get("metas", []):
			if m is Dictionary:
				_presence[key][str(m.get("phx_ref", ""))] = m


func _presence_publish() -> void:
	online = {}
	for key: String in _presence:
		for ref: String in _presence[key]:
			online[key] = _presence[key][ref]      # any connection will do
	presence_changed.emit()


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

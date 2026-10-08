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
## Often enough to notice a dead line too: a WiFi that died leaves the socket
## looking open for minutes, and the reply to each heartbeat is what says the
## line still works (`silent_for()`, Net.connection()).
const HEARTBEAT_S := 5.0
## Heard nothing at all this long on an "open" socket: it is dead. Close it,
## and the reconnect takes over.
const STALL_S := 15.0
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
## The line's health: when anything last came in, the heartbeat's round trip,
## and when the socket went down (-1 while up).
var _last_heard := 0.0
var _beat_ref := ""
var _beat_sent := 0.0
var rtt := 0.0
var _down_at := -1.0
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
## Who is connected right now: user id -> every connection's announcement
## from `track()` ({sid, where, name}), one per device. Supabase keeps this
## list and drops a phone from it by itself when its connection goes, which is
## the point -- nothing here has to notice a phone dying. Ask `where_is()`.
var online := {}
## key -> {phx_ref: meta}. One user can hold two connections (two windows);
## they only count as gone when the last one leaves.
var _presence := {}
## Leaves held back for PRESENCE_GRACE_S: key -> {phx_ref: [meta, left_at]}.
## A phone re-joining the channel -- a WiFi blip, or a screen widening what
## it watches -- is reported as a leave and a join a moment apart; shown as
## it came, a student flickered "not connected", and a Start pressed in that
## moment was refused over it. Measured in a three-phone run against the
## live project.
var _leaving := {}
## Longer than a reconnect (RECONNECT_S, then the join) so our own dropped
## connection coming back does not flicker anyone out either.
const PRESENCE_GRACE_S := 5.0
## What this phone announces, re-sent after every (re)join.
var _tracked := {}
## Position channels, beside the main topic: topic -> the ref of its join.
## Heroes' positions are most of the traffic, and Supabase's free tier counts
## every message delivered: on the one shared topic a class of 30 walking was
## cut off ("Too many messages per second", MERGE_CHECKLIST "Server load").
## So positions go through the teacher, battle-royale style (PosHub): each
## phone sends on a channel of its own that only the teacher joins, and the
## teacher sends everyone one snapshot of all of them. Broadcast only -- no
## presence, no table changes.
var _pos_topics := {}


## Where one player's positions go: only they and the teacher are on it.
## Ids only: Realtime topics take no spaces.
static func in_topic(session_id: String, profile_id: String) -> String:
	return "%s:in:%s:%s" % [TOPIC, session_id, profile_id]


## Where the teacher's snapshots of everyone come out; every phone is on it.
static func snap_topic(session_id: String) -> String:
	return "%s:snap:%s" % [TOPIC, session_id]


## The position channels this device is on: its own and the snapshots on a
## phone; every player's and the snapshots on the teacher's. Replaces the last
## set.
func watch_positions(topics: Array) -> void:
	for t: String in _pos_topics.keys():
		if not topics.has(t):
			if _state == WebSocketPeer.STATE_OPEN:
				_send(t, "phx_leave", {})
			_pos_topics.erase(t)
	for t: String in topics:
		if not _pos_topics.has(t):
			_pos_topics[t] = ""
			_join_pos(t)


func _join_pos(topic: String) -> void:
	if _state != WebSocketPeer.STATE_OPEN:
		return               # joined when the socket opens (_process)
	_pos_topics[topic] = str(_ref + 1)
	_send(topic, "phx_join", {
		"config": {"broadcast": {"self": false}, "presence": {"enabled": false},
			"postgres_changes": []},
		"access_token": Net.access_token,
	})


## A position ("pos"), or the teacher's snapshot ("snap"), to one of those
## channels. Dropped while it is not up, like any broadcast: the next one is a
## moment away.
func send_position(topic: String, payload: Dictionary, event := "pos") -> void:
	if _state != WebSocketPeer.STATE_OPEN or str(_pos_topics.get(topic, "")) == "":
		return
	_send(topic, "broadcast", {"type": "broadcast", "event": event, "payload": payload})


func open_socket() -> void:
	# The peer's own state, not the cached one: `_state` only catches up in
	# `_process`, so two `watch()` calls in the same frame -- members and
	# teams, say -- both saw CLOSED and the second connect returned
	# ERR_ALREADY_IN_USE.
	var live := _ws.get_ready_state()
	if live == WebSocketPeer.STATE_OPEN or live == WebSocketPeer.STATE_CONNECTING:
		return
	# Down from the first try, not only after an open line drops: a phone that
	# never got through was otherwise "silent for 0s", which read as good.
	if _down_at < 0.0:
		_down_at = Time.get_ticks_msec() / 1000.0
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
	_pos_topics = {}
	_tracked = {}
	_presence = {}
	_leaving = {}
	online = {}
	_retry_in = -1.0
	_joined = false
	live = false
	if _state != WebSocketPeer.STATE_CLOSED:
		_ws.close()


func is_open() -> bool:
	return _state == WebSocketPeer.STATE_OPEN


## The socket's own state, not the cached one (tests).
func get_ws_state() -> int:
	return _ws.get_ready_state()


## Anything to keep up: tables watched or position channels joined.
func active() -> bool:
	return not _wanted.is_empty() or not _pos_topics.is_empty()


## Seconds without word from the server: since the socket went down, or since
## the last message on an open one. 0 when nothing is being kept up.
func silent_for() -> float:
	if not active():
		return 0.0
	var now := Time.get_ticks_msec() / 1000.0
	if _state != WebSocketPeer.STATE_OPEN:
		return now - _down_at if _down_at >= 0.0 else 0.0
	return now - _last_heard


func _process(delta: float) -> void:
	_ws.poll()
	var now := _ws.get_ready_state()
	if now != _state:
		_state = now
		if OS.get_environment("RT_DEBUG") != "":
			print("RT socket state -> ", now, " close code ", _ws.get_close_code(), " ", _ws.get_close_reason())
		if now == WebSocketPeer.STATE_OPEN:
			_down_at = -1.0
			_last_heard = Time.get_ticks_msec() / 1000.0
			_joined = false
			_join()
			for t: String in _pos_topics:
				_join_pos(t)
			opened.emit()
		elif now == WebSocketPeer.STATE_CLOSED:
			if _down_at < 0.0:
				_down_at = Time.get_ticks_msec() / 1000.0
			_joined = false
			live = false
			if active():
				_retry_in = RECONNECT_S
			# Our own connection dropped. Everyone goes into the same grace a
			# single leave gets: a reconnect inside it (the usual case, 2s)
			# sends the whole list again and nobody is seen to flicker out;
			# a longer outage lets them go.
			var at := Time.get_ticks_msec() / 1000.0
			for key: String in _presence:
				for ref: String in _presence[key]:
					if not _leaving.has(key):
						_leaving[key] = {}
					_leaving[key][ref] = [_presence[key][ref], at]
			_presence = {}
			_presence_publish()
			closed.emit(_ws.get_close_code())
	_expire_leaves()
	# Still down with something to keep up, and no retry coming: a connect
	# that failed at once (no network yet -- WiFi coming back) never leaves
	# CLOSED, so the transition above never fires and nothing tried again.
	# Seen on a phone: offline, back, and the live channel stayed dead.
	if _state == WebSocketPeer.STATE_CLOSED and active() and _retry_in < 0.0:
		_retry_in = RECONNECT_S
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

	if silent_for() > STALL_S:
		_ws.close(-1)        # a dead line: dropped at once, the reconnect takes over
		return
	_since_beat += delta
	if _since_beat >= HEARTBEAT_S:
		_since_beat = 0.0
		_beat_ref = str(_ref + 1)
		_beat_sent = Time.get_ticks_msec() / 1000.0
		_send("phoenix", "heartbeat", {})
		if _joined and Net.access_token != _joined_token:
			_joined_token = Net.access_token
			_send(TOPIC, "access_token", {"access_token": _joined_token})
			for t: String in _pos_topics:
				_send(t, "access_token", {"access_token": _joined_token})

	while _ws.get_available_packet_count() > 0:
		_last_heard = Time.get_ticks_msec() / 1000.0
		var text := _ws.get_packet().get_string_from_utf8()
		if OS.get_environment("RT_DEBUG") != "":
			print("RT<< ", text.substr(0, 400))
		var msg: Variant = JSON.parse_string(text)
		if msg is Dictionary:
			if debug:
				_tally(received, _kind(str(msg.get("event", "")), msg.get("payload")),
					str(msg.get("topic", "")), msg.get("payload"), "<<")
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
			if _beat_ref != "" and str(msg.get("ref", "")) == _beat_ref:
				rtt = Time.get_ticks_msec() / 1000.0 - _beat_sent
			var reply: Variant = msg.get("payload")
			if reply is Dictionary and str((reply as Dictionary).get("status", "")) == "error":
				push_warning("Realtime: join refused -- %s" % str(reply))
			elif str(msg.get("ref", "")) == _join_ref:
				# Joined (or rejoined): presence starts empty on a new
				# channel, so say who we are again.
				_send_track()
		"presence_state":
			var st: Variant = msg.get("payload")
			# A full list after our own (re)join: anyone missing from it who
			# was here a moment ago is held in grace like any other leave.
			var now := Time.get_ticks_msec() / 1000.0
			for key: String in _presence:
				for ref: String in _presence[key]:
					if not _leaving.has(key):
						_leaving[key] = {}
					_leaving[key][ref] = [_presence[key][ref], now]
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
					var now := Time.get_ticks_msec() / 1000.0
					for key: String in leaves:
						for m: Variant in (leaves[key] as Dictionary).get("metas", []):
							if _presence.has(key) and m is Dictionary:
								var ref := str(m.get("phx_ref", ""))
								if not _leaving.has(key):
									_leaving[key] = {}
								_leaving[key][ref] = [m, now]
								(_presence[key] as Dictionary).erase(ref)
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
			# A position channel dropped the same way: join it again.
			var pt := str(msg.get("topic", ""))
			if _pos_topics.has(pt) and str(msg.get("ref", "")) == str(_pos_topics[pt]):
				_pos_topics[pt] = ""
				get_tree().create_timer(RECONNECT_S).timeout.connect(func() -> void:
					if _pos_topics.has(pt) and str(_pos_topics[pt]) == "":
						_join_pos(pt))


## --- Debug counters (HubDebug) ---------------------------------------------
## Off unless a debug panel turns them on: what came in and went out, by
## kind, and the last messages for the panel's log. Nothing is kept otherwise.
var debug := false
var received := {}          # kind -> count since the panel last looked
var sent := {}
var log_lines: Array[String] = []
const LOG_KEEP := 14


## "pos", "snap", "postgres_changes", "presence_diff", "heartbeat"...
static func _kind(event: String, payload: Variant) -> String:
	if event == "broadcast" and payload is Dictionary:
		return str((payload as Dictionary).get("event", "broadcast"))
	return event


func _tally(into: Dictionary, kind: String, topic: String, payload: Variant, dir: String) -> void:
	into[kind] = int(into.get(kind, 0)) + 1
	if kind == "heartbeat" or kind == "phx_reply":
		return
	var what := ""
	var inner: Variant = (payload as Dictionary).get("payload") if payload is Dictionary else null
	match kind:
		"pos":
			if inner is Dictionary and inner.get("p") is Dictionary:
				var xs: Array = inner.p.get("x", [])
				var ys: Array = inner.p.get("y", [])
				what = "%s %d pts -> (%d,%d)" % [str(inner.get("id", "")).left(6), xs.size(),
					int(xs[-1]) if not xs.is_empty() else 0, int(ys[-1]) if not ys.is_empty() else 0]
			elif inner is Dictionary:
				what = "%s (%d,%d)" % [str(inner.get("id", "")).left(6),
					int(inner.get("x", 0)), int(inner.get("y", 0))]
		"snap":
			if inner is Dictionary:
				what = "%d heroes, %d rows" % [(inner.get("p", []) as Array).size(),
					(inner.get("r", []) as Array).size()]
		"postgres_changes":
			var d: Variant = (payload as Dictionary).get("data") if payload is Dictionary else null
			if d is Dictionary:
				what = "%s %s" % [d.get("type", ""), d.get("table", "")]
	var short := topic.trim_prefix(TOPIC).get_slice(":", 1)
	log_lines.append("%s %s %-6s %-5s %s" % [Time.get_time_string_from_system(), dir,
		kind.left(6), short.left(5), what])
	if log_lines.size() > LOG_KEEP:
		log_lines.pop_front()


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
		online[key] = (_presence[key] as Dictionary).values()
	# Just left: still listed for the grace period. Always, even when another
	# connection of theirs is here -- that one may be another session (the
	# same account open in last lesson's window), which says nothing about
	# this one.
	for key: String in _leaving:
		for ref: String in _leaving[key]:
			if not online.has(key):
				online[key] = []
			online[key].append(_leaving[key][ref][0])
	presence_changed.emit()


## Drops leaves whose grace has run out; republishes if that changed anything.
func _expire_leaves() -> void:
	if _leaving.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var dropped := false
	for key: String in _leaving.keys():
		for ref: String in (_leaving[key] as Dictionary).keys():
			if now - float(_leaving[key][ref][1]) >= PRESENCE_GRACE_S:
				(_leaving[key] as Dictionary).erase(ref)
				dropped = true
		if (_leaving[key] as Dictionary).is_empty():
			_leaving.erase(key)
	if dropped:
		_presence_publish()


## Where a user is in one session: "map", "lobby", or "" for not connected to
## it. All their connections count -- the same account open on two devices,
## or still open in last session's window, is common, and taking whichever
## connection came first read a student on the map as not here at all.
func where_is(user_id: String, session_id: String) -> String:
	var found := ""
	for meta: Variant in online.get(user_id, []):
		if meta is Dictionary and str(meta.get("sid", "")) == session_id:
			if str(meta.get("where", "")) == "map":
				return "map"
			found = "lobby"
	return found


func _send(topic: String, event: String, payload: Dictionary) -> void:
	_ref += 1
	if OS.get_environment("RT_DEBUG") != "":
		print("RT>> ", event, " ", JSON.stringify(payload).substr(0, 300))
	if debug:
		_tally(sent, _kind(event, payload), topic, payload, ">>")
	_ws.send_text(JSON.stringify({
		"topic": topic,
		"event": event,
		"payload": payload,
		"ref": str(_ref),
	}))

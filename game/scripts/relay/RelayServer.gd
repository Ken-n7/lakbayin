class_name RelayServer
extends Node

## The movement relay: every student's hero position in, one snapshot of
## everyone out to the whole session, SNAP_HZ times a second. Runs headless
## on the home laptop behind a Cloudflare tunnel (tools/relay.gd,
## tools/relay/run.sh); answers, gems and the session never come here.
##
## Why: through Supabase every message is counted and capped, so phones sent
## a bundle every 0.33s and played others ~0.9s behind. Here messages cost
## nothing -- the LAN spike carried 40 phones at 10 snapshots a second on
## 8.5% of a core -- and others can be shown ~0.3-0.5s behind.
##
## Speaks RelayCodec. A connection says hello with a ticket from Supabase
## (`relay_ticket`), never its sign-in token; it is let in only as a member of
## that session (player) or its teacher (observer, sends nothing), as Supabase
## says when the relay redeems the ticket (`who`). Listens on 127.0.0.1 only:
## cloudflared connects locally.

const PORT := 47317
const MAX_UP_PER_S := 40
const MAX_TEXT := 4096
const MAX_PENDING := 8           # points kept per hero between two ticks
const WHO_KEEP_S := 600.0        # a token's answer, reused on reconnects
## A connection that cannot keep up asks for fewer snapshots (RelayLink's
## `rate`): one every `every` ticks, up to MAX_EVERY, carrying each hero's
## newest point -- a quarter of the bytes at the least, never an older place.
const MAX_EVERY := 4
## The roster goes out whole after joins and leaves, at most this often per
## session: a class joining at once (or coming back after a restart) is one or
## two of them, not one per join to every phone -- ~50 KB each, seconds of
## backlog on a weak line.
const ROSTER_PER_S := 2

var hz := 10
var silent_s := 15.0            # nothing heard this long: dropped
var hello_s := 10.0             # to say who you are, after connecting
## Who a hello's token belongs to, if they may join: (token, session, role)
## -> profile id or "". Supabase by default; tests put a stub here.
var check: Object = self

var _server := TCPServer.new()
var _clock := 0.0
var _ticks := 0
var _next_key := 0
## key -> {ws, room, idx, id, role, hero, heard, since, frames, frames_at, authing, every}
var _peers := {}
## session -> {members: {idx: key}, watchers: {key: true}, pending: {idx: [[t, x, y]]},
##              held: {every: {idx: [newest point]}}}
var _rooms := {}
var _who_cache := {}             # "token|session|role" -> [profile id, at]
var _uuid := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

## For the runner's report and the load tests.
var msgs_in := 0
var msgs_out := 0
var bytes_out := 0
var denied := 0


func _ready() -> void:
	set_process(false)


func start(port := PORT, bind := "127.0.0.1") -> String:
	var err := _server.listen(port, bind)
	if err != OK:
		return "Could not open port %d (error %d) -- is another relay running?" % [port, err]
	set_process(true)
	return ""


func stop() -> void:
	for k in _peers:
		(_peers[k].ws as WebSocketPeer).close()
	_peers.clear()
	_rooms.clear()
	_server.stop()
	set_process(false)


func peer_count() -> int:
	return _peers.size()


func room_count() -> int:
	return _rooms.size()


func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	while _server.is_connection_available():
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = 1 << 16
		ws.outbound_buffer_size = 1 << 20
		if ws.accept_stream(_server.take_connection()) == OK:
			_next_key += 1
			_peers[_next_key] = {"ws": ws, "room": "", "idx": 0, "id": "", "role": "",
				"hero": 1, "heard": now, "since": now, "frames": 0, "frames_at": now, "authing": false,
				"every": 1}
	var gone: Array = []
	for k: int in _peers:
		var peer: Dictionary = _peers[k]
		var ws: WebSocketPeer = peer.ws
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			gone.append(k)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		while ws.get_available_packet_count() > 0:
			var data := ws.get_packet()
			peer.heard = now
			msgs_in += 1
			if ws.was_string_packet():
				if data.size() <= MAX_TEXT:
					_take_text(k, data.get_string_from_utf8())
			else:
				_take_up(peer, data, now)
		if now - float(peer.heard) > silent_s:
			ws.close(4000, "silent")
		elif peer.room == "" and not peer.authing and now - float(peer.since) > hello_s:
			ws.close(4002, "no hello")
	for k in gone:
		_leave(k)
	# Stepped, not reset: resetting lost the remainder of every frame and
	# ticked 18 times a second for 20.
	_clock -= delta
	if _clock <= 0.0:
		_clock = maxf(_clock + 1.0 / float(hz), 0.0)
		_tick()


func _take_up(peer: Dictionary, data: PackedByteArray, now: float) -> void:
	if peer.room == "" or peer.role != "player":
		return
	if now - float(peer.frames_at) >= 1.0:
		peer.frames_at = now
		peer.frames = 0
	peer.frames = int(peer.frames) + 1
	if int(peer.frames) > MAX_UP_PER_S:
		return                          # more than any phone sends: dropped
	var q := RelayCodec.read_up(data)
	if q.is_empty():
		return
	var room: Dictionary = _rooms.get(peer.room, {})
	if room.is_empty():
		return
	var pts: Array = room.pending.get(peer.idx, [])
	if pts.size() < MAX_PENDING:
		pts.append(q)
	room.pending[peer.idx] = pts


func _take_text(key: int, raw: String) -> void:
	var m := RelayCodec.read_text(raw)
	match m[0]:
		"hello":
			_hello(key, m[1])
		"ping":
			_send_text(key, "pong", m[1])
		"rate":
			_pace(_peers[key], m[1].get("hz", hz))


func _hello(key: int, p: Dictionary) -> void:
	var peer: Dictionary = _peers[key]
	if peer.room != "" or peer.authing:
		return
	if int(p.get("v", 0)) != RelayCodec.VERSION:
		_deny(key, "update the app")
		return
	var session := str(p.get("session", ""))
	var role := str(p.get("role", ""))
	# A ticket (relay_ticket, schema 7c); an app from before tickets sends its
	# sign-in token instead, still let in until every phone has been updated.
	var token := str(p.get("ticket", p.get("token", "")))
	if not _uuid.search(session) or not role in ["player", "teacher"] \
			or token == "" or token.length() > 4096 or " " in token:
		_deny(key, "bad hello")
		return
	peer.authing = true
	var cache_key := "%s|%s|%s" % [token, session, role]
	var who := ""
	var cached: Array = _who_cache.get(cache_key, [])
	if not cached.is_empty() and Time.get_ticks_msec() / 1000.0 - float(cached[1]) < WHO_KEEP_S:
		who = cached[0]
	else:
		who = await check.who(token, session, role)
		if who != "":
			_who_cache[cache_key] = [who, Time.get_ticks_msec() / 1000.0]
	if not _peers.has(key):
		return                          # gone while we asked
	peer.authing = false
	if who == "":
		_deny(key, "not in this session")
		return
	var room: Dictionary = _rooms.get(session, {})
	if room.is_empty():
		room = {"members": {}, "watchers": {}, "pending": {}, "held": {}}
		_rooms[session] = room
	peer.room = session
	peer.id = who
	peer.role = role
	peer.hero = int(p.get("hero", 1))
	_pace(peer, p.get("rate", hz))      # a phone starting over on a weak line
	if role == "teacher":
		room.watchers[key] = true
	else:
		# The same student again (a reconnect): their old line goes, the
		# index stays, so nobody sees them leave and come back.
		var idx := 0
		for i: int in room.members:
			var other: int = room.members[i]
			if _peers.has(other) and _peers[other].id == who:
				idx = i
				_peers[other].room = ""
				(_peers[other].ws as WebSocketPeer).close(4001, "replaced")
				break
		if idx == 0:
			for i in range(1, 256):
				if not room.members.has(i):
					idx = i
					break
		if idx == 0:
			_deny(key, "session full")
			return
		room.members[idx] = key
		peer.idx = idx
	_send_text(key, "welcome", {"idx": peer.idx, "hz": hz})
	room.roster_due = true


## Who `token` is, if they may join `session` as `role`; "" if not. A ticket
## is redeemed with this relay's own login (an admin: relayserver, or the
## teacher's Game Controls); an old app's sign-in token is checked as itself.
func who(token: String, session: String, role: String) -> String:
	# Looked up, not named: tools and tests load this before the autoloads.
	var net: Node = get_node("/root/Net")
	if _uuid.search(token):
		var got: Dictionary = await net.rest(HTTPClient.METHOD_POST, "/rest/v1/rpc/relay_redeem",
			{"p_ticket": token, "p_session": session, "p_role": role})
		var id := str(got.data) if got.error == "" and got.data != null else ""
		return id if _uuid.search(id) else ""
	var me: Dictionary = await net.rest_as(token, HTTPClient.METHOD_GET, "/auth/v1/user")
	if me.error != "" or not (me.data is Dictionary):
		return ""
	var uid := str((me.data as Dictionary).get("id", ""))
	if not _uuid.search(uid):
		return ""
	var rows: Dictionary
	if role == "player":
		rows = await net.rest_as(token, HTTPClient.METHOD_GET,
			"/rest/v1/members?select=profile_id&session_id=eq.%s&profile_id=eq.%s" % [session, uid])
	else:
		rows = await net.rest_as(token, HTTPClient.METHOD_GET,
			"/rest/v1/sessions?select=id&id=eq.%s&admin_id=eq.%s" % [session, uid])
	return uid if rows.error == "" and rows.data is Array and not (rows.data as Array).is_empty() else ""


## Refused: said in the close itself (code 4003, the reason as its text) --
## a message sent just before a close is dropped with it.
func _deny(key: int, why: String) -> void:
	denied += 1
	(_peers[key].ws as WebSocketPeer).close(RelayCodec.DENIED, why)


func _leave(key: int) -> void:
	var peer: Dictionary = _peers[key]
	_peers.erase(key)
	var room: Dictionary = _rooms.get(peer.room, {})
	if room.is_empty():
		return
	room.watchers.erase(key)
	if room.members.get(peer.idx) == key:
		room.members.erase(peer.idx)
		room.pending.erase(peer.idx)
	if room.members.is_empty() and room.watchers.is_empty():
		_rooms.erase(peer.room)
	else:
		room.roster_due = true


## Everyone in the session, by index (ROSTER_PER_S).
func _roster(session: String) -> void:
	var room: Dictionary = _rooms[session]
	var who := {}
	for idx: int in room.members:
		var p: Dictionary = _peers[room.members[idx]]
		who[str(idx)] = {"id": p.id, "hero": p.hero}
	var text := RelayCodec.text("roster", who)
	for k in _keys(room):
		var ws: WebSocketPeer = _peers[k].ws
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(text)
			msgs_out += 1


## Snapshots a second asked for -> every how many ticks this one gets one.
func _pace(peer: Dictionary, want: Variant) -> void:
	peer.every = clampi(ceili(float(hz) / maxi(int(want), 1)), 1, MAX_EVERY)


## One snapshot per session that has news, encoded once for all of it -- and
## once more for each slower pace asked for (MAX_EVERY), on its tick.
func _tick() -> void:
	_ticks += 1
	for session: String in _rooms:
		var room: Dictionary = _rooms[session]
		if room.get("roster_due", false) and _ticks >= int(room.get("roster_at", 0)):
			room.roster_due = false
			room.roster_at = _ticks + maxi(hz / ROSTER_PER_S, 1)
			_roster(session)
		var keys := _keys(room)
		var paces := {}
		for k in keys:
			paces[int(_peers[k].every)] = true
		var frames := {}
		if not room.pending.is_empty():
			frames[1] = RelayCodec.snap(room.pending)
		for every: int in room.held.keys():
			if not paces.has(every):
				room.held.erase(every)
		for every: int in paces:
			if every == 1:
				continue
			var held: Dictionary = room.held.get(every, {})
			for i: int in room.pending:
				held[i] = [(room.pending[i] as Array)[-1]]
			room.held[every] = held
			if _ticks % every == 0 and not held.is_empty():
				frames[every] = RelayCodec.snap(held)
				room.held[every] = {}
		room.pending = {}
		for k in keys:
			var frame: Variant = frames.get(int(_peers[k].every))
			var ws: WebSocketPeer = _peers[k].ws
			if frame != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
				ws.send(frame, WebSocketPeer.WRITE_MODE_BINARY)
				msgs_out += 1
				bytes_out += (frame as PackedByteArray).size()


func _keys(room: Dictionary) -> Array:
	return room.members.values() + room.watchers.keys()


func _send_text(key: int, event: String, payload: Dictionary) -> void:
	var ws: WebSocketPeer = _peers[key].ws
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(RelayCodec.text(event, payload))
		msgs_out += 1

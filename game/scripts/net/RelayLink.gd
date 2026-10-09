class_name RelayLink
extends Node

## The movement relay (RelayServer), from a phone or the teacher's screen.
## Made by Net.relay(); one session at a time.
##
## Finds the relay through Supabase's `relay` row (the home laptop publishes
## its tunnel's address there), says hello with this device's token, then:
## a phone sends its hero's samples (send_sample) and both hear everyone's
## in snapshots (`snap`). While it is not `up` -- no relay published, the
## address stale, the line refused or dropped -- the game uses the teacher's
## hub over Supabase, as it did before the relay; this keeps trying in the
## background (full jitter, so a room of phones does not retry in step).

signal snap(entries: Array)      # [{id, hero, p: [[t s, x, y], ...], fast: true}]
signal up_changed(up: bool)

const STALE_S := 180.0           # published longer ago than this: the relay is gone
const PING_S := 1.0
const DROP_S := 12.0             # nothing heard this long (pongs come every PING_S)
## A weak line cannot carry a full class's 20 snapshots a second; they queue
## on the way and what this phone shows falls further and further behind. A
## pong waits behind every snapshot sent before it, so its round trip over the
## best seen on this connection (at most RTT_CAP: a line queued from its very
## first pong has no clean one to learn from) is that queue. RATE_DOWN_S of it
## twice running asks the relay for half the snapshots (down to a quarter,
## MAX_EVERY), then RATE_HOLD_S lets what was queued drain before judging
## again; RATE_CALM_S under RATE_UP_S asks for twice as many -- and each such
## try the line could not carry (down again within RATE_TRY_S) doubles the calm
## needed before the next, up to RATE_CALM_MAX_S.
const RATE_DOWN_S := 0.5
const RATE_UP_S := 0.15
const RATE_CALM_S := 10.0
const RATE_CALM_MAX_S := 160.0
const RATE_HOLD_S := 3.0
const RATE_TRY_S := 30.0
const RTT_CAP := 0.5
## FLUSH_S behind, what is queued is old news, and asking for fewer leaves it
## to drain for minutes on a slow line: a new connection drops it at once,
## asking for the least rate from its hello, and steps up again once calm.
const FLUSH_S := 2.0
const RETRY_MIN_S := 1.0
const RETRY_MAX_S := 15.0
const OUTDATED_RETRY_S := 300.0  # "update the app": no point asking every second
## No relay running: look again now and then, not every few seconds from
## every phone in the room.
const UNPUBLISHED_RETRY_S := 60.0
## A relay ticket is kept this long, well inside the hour the server honours
## it, so quick reconnects do not each ask for one.
const TICKET_KEEP_S := 1800.0

## Debug builds: the hub path only, as if the relay could not be reached --
## for trying the bridge on real phones (the dev panel's Network tab).
static var off := false
## Debug builds: this phone's own walk as it comes back from the relay, drawn
## as one more hero ("Your echo", the dev panel's Network tab) -- the gap between you and it is
## about what a classmate on a line like this one sees.
static var echo := false
const ECHO_KEEP := 200
## Seconds each of this phone's own samples took to come back (up to the
## relay and down again), newest last -- for NetReport.
var echo_trips: Array[float] = []

var up := false
var rtt := 0.0
var hz := 0
var rate := 0                    # snapshots a second asked for: hz, or fewer on a weak line
var idx := 0
var host := ""                   # for NetReport / HubDebug
var last_close := ""             # why the line last went down
var snaps_in := 0

var _session := ""
var _role := ""
var _hero := 1
var _ws: Variant = null
var _roster := {}                # idx -> {id, hero}
var _dialing := false
var _ticket := ""                # relay_ticket's answer, for `_ticket_of`
var _ticket_of := ""             # "session|role" it was given for
var _ticket_at := -INF
var _retry_in := -1.0
var _attempt := 0
var _heard := 0.0
var _ping_clock := 0.0
var _best_rtt := INF
var _over := 0
var _calm_since := 0.0
var _hold_until := 0.0
var _raised_at := -INF
var _calm_need := RATE_CALM_S
var _start_rate := 0             # the rate the next hello asks for (0: the relay's own)


## Debug: the hub path only (`off`), or back to the relay.
func set_off(on: bool) -> void:
	off = on
	if on:
		_close()
		last_close = "relay off (debug)"
	if _session != "":
		_retry_in = RETRY_MAX_S if on else 0.01


## Follow `session_id` as a "player" (sends its samples) or "teacher"
## (watches). Again with the same arguments: nothing changes.
func join(session_id: String, role: String, hero := 1) -> void:
	if session_id == _session and role == _role and hero == _hero:
		return
	leave()
	_session = session_id
	_role = role
	_hero = hero
	_attempt = 0
	_start_rate = 0
	_retry_in = 0.01


func leave() -> void:
	_session = ""
	_retry_in = -1.0
	_close()


## This hero was at (x, y) at `t` (this device's own clock, seconds).
func send_sample(t: float, x: int, y: int) -> void:
	if up and _role == "player":
		_ws.send(RelayCodec.up(int(t * 1000.0), x, y), WebSocketPeer.WRITE_MODE_BINARY)


func _process(delta: float) -> void:
	if _retry_in > 0.0:
		_retry_in -= delta
		if _retry_in <= 0.0:
			_retry_in = -1.0
			_dial()
	if _ws == null:
		return
	_ws.poll()
	var state: int = _ws.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		_down(_ws.get_close_code(), _ws.get_close_reason())
		return
	if state != WebSocketPeer.STATE_OPEN:
		return
	var now := Time.get_ticks_msec() / 1000.0
	while _ws != null and _ws.get_available_packet_count() > 0:
		var data: PackedByteArray = _ws.get_packet()
		_heard = now
		if _ws.was_string_packet():
			_take_text(RelayCodec.read_text(data.get_string_from_utf8()))
		else:
			_take_snap(RelayCodec.read_snap(data))
	if _ws == null:
		return
	if now - _heard > DROP_S:
		_ws.close(-1)                   # a dead line: down at once, the retry takes over
		return
	_ping_clock -= delta
	if _ping_clock <= 0.0:
		_ping_clock = PING_S
		_ws.send_text(RelayCodec.text("ping", {"t": now}))


func _dial() -> void:
	if _session == "" or _dialing or _ws != null:
		return
	if off:
		_retry(RETRY_MAX_S)
		return
	_dialing = true
	var session := _session
	var url := await published()
	if url == "" or session != _session:
		_dialing = false
		if session == _session:
			last_close = "no relay published"
			_retry(UNPUBLISHED_RETRY_S)
		return
	var ticket := await _ticket_for(session)
	if session != _session:
		_dialing = false
		return
	if ticket == "":
		_dialing = false
		_retry(-1.0)
		return
	host = Dial.host_of(url)
	var at := await Dial.address(host)
	_dialing = false
	if session != _session:
		return
	if at == "":
		_ws = WebSocketPeer.new()
		_ws.connect_to_url(url)
	else:
		_ws = PinnedSocket.new()
		_ws.connect_to_url(url, at)
	_heard = Time.get_ticks_msec() / 1000.0
	_ping_clock = 0.0
	# The hello goes as soon as the line opens (_take_text waits for welcome).
	while _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		await get_tree().process_frame
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var hello := {"v": RelayCodec.VERSION, "ticket": ticket,
		"session": _session, "role": _role, "hero": _hero}
	if _start_rate > 0:
		hello["rate"] = _start_rate
	_ws.send_text(RelayCodec.text("hello", hello))


## A ticket to join `session` on the relay (schema 7c), "" if Supabase will
## not give one. The hello carries this instead of the sign-in token, so the
## relay -- whoever runs it -- never holds anything that opens Supabase.
func _ticket_for(session: String) -> String:
	var now := Time.get_ticks_msec() / 1000.0
	if _ticket != "" and _ticket_of == session + "|" + _role and now - _ticket_at < TICKET_KEEP_S:
		return _ticket
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/rpc/relay_ticket",
		{"p_session": session, "p_role": _role})
	_ticket = str(got.data) if got.error == "" and got.data is String else ""
	_ticket_of = session + "|" + _role
	_ticket_at = now
	if _ticket == "":
		last_close = "no relay ticket: " + (got.error if got.error != "" else "no answer")
	return _ticket


## The relay's address from Supabase, "" if none is published or it has not
## been refreshed lately (the laptop went off without clearing it). Also
## RelayHost's cue: "" is when the teacher's laptop steps in.
func published() -> String:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET, "/rest/v1/relay?select=url,updated_at")
	if got.error != "" or not (got.data is Array) or (got.data as Array).is_empty():
		return ""
	var row: Dictionary = got.data[0]
	var url := str(row.get("url", "")) if row.get("url") != null else ""
	# The hello carries this phone's sign-in token: never over plain ws://.
	if not url.begins_with("wss://"):
		return ""
	if Game.now() - Teams._stamp(row.get("updated_at")) > STALE_S:
		return ""
	return url


func _take_text(m: Array) -> void:
	match m[0]:
		"welcome":
			idx = int(m[1].get("idx", 0))
			hz = int(m[1].get("hz", 0))
			rate = mini(_start_rate, hz) if _start_rate > 0 else hz
			_start_rate = 0
			_best_rtt = INF
			_over = 0
			_calm_since = Time.get_ticks_msec() / 1000.0
			_hold_until = 0.0
			_raised_at = -INF
			if _start_rate <= 0:
				_calm_need = RATE_CALM_S
			_attempt = 0
			last_close = ""
			if not up:
				up = true
				up_changed.emit(true)
		"roster":
			_roster = {}
			for k: String in m[1]:
				var who: Variant = m[1][k]
				if who is Dictionary:
					_roster[int(k)] = who
		"pong":
			rtt = Time.get_ticks_msec() / 1000.0 - float(m[1].get("t", 0.0))
			_judge_rate(rtt)


## Fewer snapshots while they queue up on the way here, more once it clears.
func _judge_rate(trip: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	_best_rtt = minf(_best_rtt, trip)
	var queued := trip - minf(_best_rtt, RTT_CAP)
	if queued > RATE_UP_S:
		_calm_since = now
	if queued > FLUSH_S and _ws != null:
		_slower(now)
		_start_rate = least_rate(hz)
		_close()
		last_close = "line too slow: started over at %d/s" % _start_rate
		_retry(0.2)
		return
	if now < _hold_until:
		return
	_over = _over + 1 if queued > RATE_DOWN_S else 0
	var want := next_rate(rate, hz, _over, now - _calm_since, _calm_need)
	if want != rate and _ws != null:
		if want < rate:
			_slower(now)
			_hold_until = now + RATE_HOLD_S
		else:
			_raised_at = now
		rate = want
		_over = 0
		_calm_since = now
		_ws.send_text(RelayCodec.text("rate", {"hz": rate}))


## Going down again soon after going up: the line could not carry it, so the
## next try waits twice as long.
func _slower(now: float) -> void:
	if now - _raised_at < RATE_TRY_S:
		_calm_need = minf(_calm_need * 2.0, RATE_CALM_MAX_S)
	_raised_at = -INF


static func least_rate(hz: int) -> int:
	return maxi(ceili(float(hz) / RelayServer.MAX_EVERY), 1)


## The snapshots a second to ask for: half after `over` queued pongs in a
## row (2), down to a quarter of `hz`; twice as many after `calm_need` calm.
static func next_rate(rate: int, hz: int, over: int, calm_s: float, calm_need := RATE_CALM_S) -> int:
	var least := least_rate(hz)
	if over >= 2 and rate > least:
		return maxi(rate / 2, least)
	if calm_s >= calm_need and rate < hz:
		return mini(rate * 2, hz)
	return rate


func _take_snap(heroes: Dictionary) -> void:
	if heroes.is_empty():
		return
	snaps_in += 1
	var out: Array = []
	var now := Time.get_ticks_msec() / 1000.0
	for i: int in heroes:
		if i == idx and _role == "player":
			# This hero is drawn from this phone; its echo only timed (and,
			# debugging, drawn as a ghost).
			for q: Array in heroes[i]:
				echo_trips.append(now - int(q[0]) / 1000.0)
			if echo_trips.size() > ECHO_KEEP:
				echo_trips = echo_trips.slice(echo_trips.size() - ECHO_KEEP)
			if echo:
				out.append({"id": "echo", "name": "Your echo", "hero": _hero, "fast": true,
					"p": (heroes[i] as Array).map(func(q: Array) -> Array: return [int(q[0]) / 1000.0, q[1], q[2]])})
			continue
		var who: Dictionary = _roster.get(i, {})
		if who.is_empty():
			continue                    # the roster is on its way
		var pts: Array = []
		for q: Array in heroes[i]:
			pts.append([int(q[0]) / 1000.0, q[1], q[2]])
		out.append({"id": str(who.get("id", "")), "hero": int(who.get("hero", 1)), "p": pts, "fast": true})
	if not out.is_empty():
		snap.emit(out)


## [fastest, median, p95] echo trip in ms, or [] before any.
func echo_ms() -> Array:
	if echo_trips.is_empty():
		return []
	var s := echo_trips.duplicate()
	s.sort()
	return [int(s[0] * 1000.0), int(s[s.size() / 2] * 1000.0), int(s[int(s.size() * 0.95)] * 1000.0)]


func _down(code: int, reason: String) -> void:
	_close()
	if code == RelayCodec.DENIED:
		_ticket = ""                    # the next try asks for a fresh one
	last_close = reason if reason != "" else "closed (%d)" % code
	if _session == "":
		return
	_retry(OUTDATED_RETRY_S if reason == "update the app" else -1.0)


func _close() -> void:
	if _ws != null and _ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_ws.close(-1)
	_ws = null
	_roster = {}
	idx = 0
	if up:
		up = false
		up_changed.emit(false)


## Full jitter: a random wait up to a doubling cap (AWS's backoff advice), so
## a classroom of phones that lost the relay together comes back apart.
func _retry(after: float) -> void:
	if after < 0.0:
		_attempt += 1
		after = randf_range(RETRY_MIN_S, minf(RETRY_MAX_S, RETRY_MIN_S * pow(2.0, _attempt)))
	_retry_in = after

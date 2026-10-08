extends SceneTree

## RelayCodec and RelayServer, offline: the wire format, then a relay on
## 127.0.0.1 with a stub in place of Supabase and Godot's own WebSocket
## clients as phones.
##   godot --headless --path game --script res://test_relay.gd

const PORT := 47392
const S1 := "11111111-1111-4111-8111-111111111111"
const S2 := "22222222-2222-4222-8222-222222222222"

var relay: RelayServer


class Stub:
	## "ok:<id>" is <id>; a teacher token "teach:<id>" only as a teacher.
	func who(token: String, _session: String, role: String) -> String:
		if token.begins_with("ok:") and role == "player":
			return token.trim_prefix("ok:")
		if token.begins_with("teach:") and role == "teacher":
			return token.trim_prefix("teach:")
		return ""


class Phone:
	var ws := WebSocketPeer.new()
	var texts: Array = []        # [event, payload]
	var snaps: Array = []        # idx -> points, one per snapshot

	func pump() -> void:
		ws.poll()
		while ws.get_available_packet_count() > 0:
			var data := ws.get_packet()
			if ws.was_string_packet():
				texts.append(RelayCodec.read_text(data.get_string_from_utf8()))
			else:
				snaps.append(RelayCodec.read_snap(data))

	## Why the relay refused this phone, or "".
	func why() -> String:
		return ws.get_close_reason() if ws.get_close_code() == RelayCodec.DENIED else ""

	func last(event: String) -> Dictionary:
		for i in range(texts.size() - 1, -1, -1):
			if texts[i][0] == event:
				return texts[i][1]
		return {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_codec()
	_host()
	relay = RelayServer.new()
	relay.check = Stub.new()
	relay.hz = 20
	root.add_child(relay)
	assert(relay.start(PORT) == "")
	await _server()
	relay.stop()
	print("test_relay: all assertions passed")
	quit()


## The backup relay (RelayHost): its tunnel's address read out of a real
## cloudflared log (JSON lines, beside Cloudflare's own links), and cloudflared
## found where this machine has it.
func _host() -> void:
	var log := ('{"level":"info","message":"Requesting new quick Tunnel on trycloudflare.com..."}\n'
		+ '{"level":"info","message":"+----------------------------+"}\n'
		+ '{"level":"info","message":"|  https://literary-journalists-slim-deputy.trycloudflare.com  |"}\n'
		+ '{"level":"info","message":"See https://www.cloudflare.com/website-terms/"}\n')
	assert(RelayHost.address_in(log) == "wss://literary-journalists-slim-deputy.trycloudflare.com")
	assert(RelayHost.address_in('{"message":"Requesting new quick Tunnel on trycloudflare.com..."}') == "",
		"no address before the tunnel has one")
	var cf := RelayHost.cloudflared()
	assert(cf == "" or FileAccess.file_exists(cf), "cloudflared found: " + cf)
	assert(not RelayHost.enabled, "never hosts headless (tests, tools)")


func _codec() -> void:
	var u := RelayCodec.up(123456, -40, 1700)
	assert(u.size() == RelayCodec.UP_SIZE)
	assert(RelayCodec.read_up(u) == [123456, -40, 1700])
	assert(RelayCodec.read_up(RelayCodec.up(0x1_0000_0005, 99999, -99999)) == [5, 32767, -32768],
		"the clock wraps, positions clamp")
	assert(RelayCodec.read_up(u.slice(0, 8)).is_empty(), "short frame refused")
	var heroes := {1: [[10, 1, 2]], 7: [[20, 3, 4], [30, -5, 6], [40, 7, 8]]}
	var s := RelayCodec.snap(heroes)
	assert(s.size() == 2 + (2 + 8) + (2 + 3 * 8))
	assert(RelayCodec.read_snap(s) == heroes, "snapshot round trip")
	assert(RelayCodec.read_snap(s.slice(0, s.size() - 1)).is_empty(), "cut snapshot refused")
	assert(RelayCodec.read_snap(RelayCodec.snap({})) == {}, "empty snapshot")
	assert(RelayCodec.read_text("not json") == ["", {}])
	assert(RelayCodec.read_text(RelayCodec.text("ping", {"t": "x"})) == ["ping", {"t": "x"}])
	print("codec: up, snapshot, text")


func _server() -> void:
	# In: a welcome with an index, and the roster to everyone.
	var a := await _join("ok:alice", S1, "player")
	assert(a.last("welcome").get("idx") == 1, "first index: %s" % a.last("welcome"))
	var b := await _join("ok:bob", S1, "player")
	assert(b.last("welcome").get("idx") == 2)
	assert(await _until(func() -> bool: return a.last("roster").size() == 2, [a, b]))
	assert(a.last("roster")["2"].id == "bob")
	print("server: welcome and roster")

	# Out: bad tokens, wrong version, wrong role, no hello at all.
	var bad := await _join("nope", S1, "player")
	assert(bad.why() == "not in this session")
	var old := _connect()
	assert(await _until(func() -> bool: return old.ws.get_ready_state() == WebSocketPeer.STATE_OPEN, [old]))
	old.ws.send_text(RelayCodec.text("hello", {"v": 0, "token": "ok:x", "session": S1, "role": "player"}))
	assert(await _until(func() -> bool: return old.why() != "", [old]))
	assert(old.why() == "update the app")
	var sneaky := await _join("ok:carol", "../../etc", "player")
	assert(sneaky.why() == "bad hello", "a session must be a uuid")
	var pretend := await _join("ok:dave", S1, "teacher")
	assert(pretend.why() != "", "a player token is not a teacher")
	relay.hello_s = 0.3
	var mute := _connect()
	assert(await _until(func() -> bool: return mute.ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, [mute]),
		"no hello: dropped")
	relay.hello_s = 10.0
	print("server: denials")

	# The teacher watches: gets everything, sends nothing that counts.
	var t := await _join("teach:tess", S1, "teacher")
	assert(t.last("welcome").get("idx") == 0)
	# Another session's phone hears nothing of this one.
	var c := await _join("ok:carol", S2, "player")

	a.ws.send(RelayCodec.up(1000, 100, 200), WebSocketPeer.WRITE_MODE_BINARY)
	a.ws.send(RelayCodec.up(1050, 110, 205), WebSocketPeer.WRITE_MODE_BINARY)
	t.ws.send(RelayCodec.up(1, 9, 9), WebSocketPeer.WRITE_MODE_BINARY)
	var got_b := func() -> Array: return _points(b, 1)
	assert(await _until(func() -> bool: return got_b.call().size() == 2, [a, b, t, c]))
	assert(got_b.call() == [[1000, 100, 200], [1050, 110, 205]], "both samples, in order")
	assert(_points(t, 1) == got_b.call(), "the teacher sees it too")
	assert(_points(a, 1) == got_b.call(), "and the sender (who skips itself)")
	assert(_points(b, 0).is_empty(), "the teacher's frames are ignored")
	assert(c.snaps.is_empty(), "nothing leaks to another session")
	print("server: snapshots")

	# A flood is cut to MAX_PENDING a tick; a wrong-sized frame is ignored.
	b.snaps.clear()
	for i in 30:
		a.ws.send(RelayCodec.up(2000 + i, i, i), WebSocketPeer.WRITE_MODE_BINARY)
	a.ws.send(PackedByteArray([1, 2, 3]), WebSocketPeer.WRITE_MODE_BINARY)
	await _until(func() -> bool: return _points(b, 1).size() >= RelayServer.MAX_PENDING, [a, b])
	await _settle([a, b, t, c])
	var most := 0
	for snap: Dictionary in b.snaps:
		most = maxi(most, (snap.get(1, []) as Array).size())
	assert(most == RelayServer.MAX_PENDING, "capped per tick: %d" % most)
	assert(_points(b, 1).size() < 30, "the rest dropped, not queued")
	print("server: flood capped")

	# The same student again (a reconnect): same index, the old line goes.
	var a2 := await _join("ok:alice", S1, "player")
	assert(a2.last("welcome").get("idx") == 1, "keeps index 1")
	assert(await _until(func() -> bool: return a.ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, [a, a2, b]))
	assert(a.ws.get_close_code() == 4001)
	await _settle([a2, b, t])
	assert(b.last("roster").size() == 2, "nobody left the roster: %s" % b.last("roster"))
	print("server: reconnect keeps the index")

	# Leaving: the roster shrinks; silence: dropped.
	b.ws.close()
	assert(await _until(func() -> bool: return a2.last("roster").size() == 1, [a2, b, t]))
	relay.silent_s = 0.3
	assert(await _until(func() -> bool: return a2.ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, [a2, t, c]),
		"silent: dropped")
	relay.silent_s = 15.0
	await _settle([t, c])
	print("server: leave and silence")


## Every point of hero `idx` across all the snapshots `p` has heard.
func _points(p: Phone, idx: int) -> Array:
	var out: Array = []
	for s: Dictionary in p.snaps:
		out.append_array(s.get(idx, []))
	return out


func _connect() -> Phone:
	var p := Phone.new()
	p.ws.connect_to_url("ws://127.0.0.1:%d" % PORT)
	return p


func _join(token: String, session: String, role: String) -> Phone:
	var p := _connect()
	assert(await _until(func() -> bool: return p.ws.get_ready_state() == WebSocketPeer.STATE_OPEN, [p]))
	p.ws.send_text(RelayCodec.text("hello", {"v": RelayCodec.VERSION, "token": token,
		"session": session, "role": role, "hero": 3}))
	await _until(func() -> bool: return not p.last("welcome").is_empty() or p.why() != "", [p])
	return p


## Pumps the phones (the relay runs itself) until `ok` holds, up to 5 seconds.
func _until(ok: Callable, phones: Array) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000:
		for p: Phone in phones:
			p.pump()
		if ok.call():
			return true
		await process_frame
	return false


func _settle(phones: Array) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 300:
		for p: Phone in phones:
			p.pump()
		await process_frame

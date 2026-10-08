extends SceneTree

## Dial and PinnedSocket, offline: the address choice, the race, and the
## WebSocket client against Godot's own WebSocket server on 127.0.0.1.
##   godot --headless --path game --script res://test_dial.gd

const PORT := 47391

var _server := TCPServer.new()
var _peer: WebSocketPeer
var _got: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_choice()
	await _race()
	await _socket()
	print("test_dial: all assertions passed")
	quit()


func _choice() -> void:
	assert(Dial.host_of("https://abc.supabase.co") == "abc.supabase.co")
	assert(Dial.host_of("wss://abc.supabase.co:8443/realtime/v1?x=1") == "abc.supabase.co")
	assert(Dial.host_of("http://127.0.0.1:4000") == "127.0.0.1")
	var all := ["64:ff9b::6812:260a", "64:ff9b::ac40:95f6", "104.18.38.10", "172.64.149.246"]
	assert(Dial.choose(all, "64:ff9b::6812:260a") == "", "the first answers: connect by name")
	assert(Dial.choose(all, "172.64.149.246") == "172.64.149.246", "a later IPv4 answers: use it")
	assert(Dial.choose(all, "64:ff9b::ac40:95f6") == "104.18.38.10", "a later IPv6 answers: the first IPv4")
	assert(Dial.choose(all, "") == "", "nothing answers: leave it to Godot")
	assert(Dial.choose(["2606:4700::1"], "") == "")
	print("dial: choose and host_of")


## A dead first address (nothing listens on that port) loses to a live one.
func _race() -> void:
	assert(_server.listen(PORT, "127.0.0.1") == OK)
	var t0 := Time.get_ticks_msec()
	var won: String = await Dial.race(["127.0.0.2", "127.0.0.1"], PORT, 3.0)
	var ms := Time.get_ticks_msec() - t0
	assert(won == "127.0.0.1", "the address that answers wins: %s" % won)
	assert(ms < 1500, "and quickly: %d ms" % ms)
	assert(await Dial.race(["127.0.0.2"], PORT, 0.5) == "", "none answers: no winner")
	# The phone's case: the first address never answers at all (here, an
	# address nothing routes to) -- the race does not wait on it.
	t0 = Time.get_ticks_msec()
	won = await Dial.race(["10.255.255.1", "127.0.0.1"], PORT, 3.0)
	assert(won == "127.0.0.1" and Time.get_ticks_msec() - t0 < 1500, "a silent first address: %s" % won)
	# Both answer (two healthy addresses): the first is kept even when the
	# other is a hair quicker -- a working network keeps Godot's own path.
	var other := TCPServer.new()
	assert(other.listen(PORT, "127.0.0.3") == OK)
	for i in 5:
		assert(await Dial.race(["127.0.0.3", "127.0.0.1"], PORT, 3.0) == "127.0.0.3", "the first, when it answers")
	other.stop()
	while _server.is_connection_available():
		_server.take_connection().disconnect_from_host()
	print("dial: race (%d ms)" % ms)


func _socket() -> void:
	var ws := PinnedSocket.new()
	# The name in the URL is only what the server is told; the address is where
	# it goes -- the name here does not even resolve.
	assert(ws.connect_to_url("ws://pinned.invalid:%d/realtime/v1/websocket?vsn=1.0.0" % PORT, "127.0.0.1") == OK)
	assert(await _until(func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_OPEN, ws))
	print("socket: open")

	# Every length encoding both ways: 7-bit, 16-bit, 64-bit.
	for n in [5, 300, 70000]:
		var text := "x".repeat(n - 1) + "!"
		assert(ws.send_text(text) == OK)
		assert(await _until(func() -> bool: return _got.size() > 0, ws), "server heard %d bytes" % n)
		assert(_got.pop_front() == text, "server got the %d bytes intact" % n)
		_peer.send_text(text.to_upper())
		assert(await _until(func() -> bool: return ws.get_available_packet_count() > 0, ws))
		assert(ws.get_packet().get_string_from_utf8() == text.to_upper(), "client got %d bytes intact" % n)
	print("socket: 5 / 300 / 70000 bytes each way")

	# Several frames landing in one read come out as several packets.
	for i in 3:
		_peer.send_text("burst %d" % i)
	assert(await _until(func() -> bool: return ws.get_available_packet_count() >= 3, ws))
	for i in 3:
		assert(ws.get_packet().get_string_from_utf8() == "burst %d" % i)
	print("socket: bursts")

	# The server closes: the client sees its code and reason.
	_peer.close(4001, "bye")
	assert(await _until(func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, ws))
	assert(ws.get_close_code() == 4001, "close code %d" % ws.get_close_code())
	assert(ws.get_close_reason() == "bye")
	print("socket: server close 4001")

	# Again, and this time the client says goodbye.
	_peer = null
	assert(ws.connect_to_url("ws://pinned.invalid:%d/" % PORT, "127.0.0.1") == OK)
	assert(await _until(func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_OPEN, ws))
	ws.close(1000, "done")
	assert(await _until(func() -> bool: return _peer.get_ready_state() == WebSocketPeer.STATE_CLOSED, ws))
	assert(_peer.get_close_code() == 1000, "server saw %d" % _peer.get_close_code())
	assert(await _until(func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, ws))
	print("socket: client close 1000")

	# A drop (close(-1), as Realtime does on a stalled line) is immediate.
	_peer = null
	assert(ws.connect_to_url("ws://pinned.invalid:%d/" % PORT, "127.0.0.1") == OK)
	assert(await _until(func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_OPEN, ws))
	ws.close(-1)
	assert(ws.get_ready_state() == WebSocketPeer.STATE_CLOSED)
	assert(await _until(func() -> bool: return _peer.get_ready_state() == WebSocketPeer.STATE_CLOSED, ws))
	print("socket: drop")

	# Nothing listening: CONNECTING ends in CLOSED, not forever.
	_server.stop()
	assert(ws.connect_to_url("ws://pinned.invalid:%d/" % PORT, "127.0.0.1") == OK)
	assert(await _until(func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, ws))
	print("socket: refused")


## Pumps the server and the client until `ok` holds, up to 5 seconds.
func _until(ok: Callable, ws: PinnedSocket) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000:
		_pump()
		ws.poll()
		if ok.call():
			return true
		await process_frame
	return false


func _pump() -> void:
	if _server.is_listening() and _server.is_connection_available():
		_peer = WebSocketPeer.new()
		_peer.inbound_buffer_size = 1 << 20
		_peer.outbound_buffer_size = 1 << 20
		_peer.accept_stream(_server.take_connection())
	if _peer == null:
		return
	_peer.poll()
	while _peer.get_available_packet_count() > 0:
		_got.append(_peer.get_packet().get_string_from_utf8())

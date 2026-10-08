class_name PinnedSocket
extends RefCounted

## A WebSocket client (RFC 6455) that connects to one chosen address while
## naming the server by its host name -- for a network where Godot's own
## WebSocketPeer would wait a minute on dead addresses first (see Dial).
## WebSocketPeer cannot do this itself: given an address it sends that as
## the Host, and Supabase's front door (Cloudflare) turns it away.
##
## Only what Realtime uses of a WebSocketPeer, with the same names and the
## same WebSocketPeer.STATE_* values, so Realtime takes either.

const CONNECT_S := 10.0
const CLOSE_WAIT_S := 2.0
const GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

var _tcp := StreamPeerTCP.new()
var _io: StreamPeer
var _tls: StreamPeerTLS
var _use_tls := false
var _host := ""
var _host_header := ""
var _path := "/"
var _key := ""
var _state := WebSocketPeer.STATE_CLOSED
var _shaking := false         # TCP/TLS up, waiting for the 101 reply
var _since := 0
var _buf := PackedByteArray()
var _frag := PackedByteArray()
var _packets: Array[PackedByteArray] = []
var _close_code := -1
var _close_reason := ""
var _rng := RandomNumberGenerator.new()


## `url` as for WebSocketPeer ("wss://name/path"); `address` is where to
## actually connect.
func connect_to_url(url: String, address: String) -> Error:
	if _state != WebSocketPeer.STATE_CLOSED:
		return ERR_ALREADY_IN_USE
	_use_tls = url.begins_with("wss://")
	var rest := url.get_slice("://", 1)
	var hostport := rest.get_slice("/", 0)
	_path = rest.substr(hostport.length())
	if _path == "":
		_path = "/"
	_host = Dial.host_of(url)
	var port := 443 if _use_tls else 80
	if hostport.length() > _host.length():
		port = int(hostport.get_slice(":", 1))
	_host_header = hostport
	_tcp = StreamPeerTCP.new()
	_tls = null
	_io = null
	_buf.clear()
	_frag.clear()
	_packets.clear()
	_close_code = -1
	_close_reason = ""
	var err := _tcp.connect_to_host(address, port)
	if err != OK:
		return err
	_state = WebSocketPeer.STATE_CONNECTING
	_shaking = false
	_since = Time.get_ticks_msec()
	return OK


func poll() -> void:
	match _state:
		WebSocketPeer.STATE_CONNECTING:
			_poll_connecting()
		WebSocketPeer.STATE_OPEN, WebSocketPeer.STATE_CLOSING:
			_read()
			_frames()
			if _state == WebSocketPeer.STATE_CLOSING \
					and Time.get_ticks_msec() - _since > CLOSE_WAIT_S * 1000.0:
				_drop(_close_code, _close_reason)


func get_ready_state() -> int:
	return _state


func send_text(text: String) -> Error:
	if _state != WebSocketPeer.STATE_OPEN:
		return ERR_UNCONFIGURED
	return _send(0x1, text.to_utf8_buffer())


func get_available_packet_count() -> int:
	return _packets.size()


func get_packet() -> PackedByteArray:
	return _packets.pop_front() if not _packets.is_empty() else PackedByteArray()


## As WebSocketPeer: a negative code drops the line at once, anything else
## says goodbye and waits (briefly) for the server's.
func close(code := 1000, reason := "") -> void:
	if _state == WebSocketPeer.STATE_CLOSED:
		return
	if code < 0 or _state != WebSocketPeer.STATE_OPEN:
		_drop(-1, "")
		return
	var body := PackedByteArray([(code >> 8) & 0xFF, code & 0xFF])
	body.append_array(reason.to_utf8_buffer())
	_send(0x8, body)
	_close_code = code
	_close_reason = reason
	_state = WebSocketPeer.STATE_CLOSING
	_since = Time.get_ticks_msec()


func get_close_code() -> int:
	return _close_code


func get_close_reason() -> String:
	return _close_reason


func _poll_connecting() -> void:
	if Time.get_ticks_msec() - _since > CONNECT_S * 1000.0:
		_drop(-1, "")
		return
	_tcp.poll()
	var s := _tcp.get_status()
	if s == StreamPeerTCP.STATUS_CONNECTING:
		return
	if s != StreamPeerTCP.STATUS_CONNECTED:
		_drop(-1, "")
		return
	if _io == null:
		if _use_tls:
			_tls = StreamPeerTLS.new()
			# The name, not the address: it is what the certificate is checked
			# against, and what tells Cloudflare which site is wanted (SNI).
			if _tls.connect_to_stream(_tcp, _host) != OK:
				_drop(-1, "")
				return
			_io = _tls
		else:
			_io = _tcp
	if _tls != null:
		_tls.poll()
		var t := _tls.get_status()
		if t == StreamPeerTLS.STATUS_HANDSHAKING:
			return
		if t != StreamPeerTLS.STATUS_CONNECTED:
			_drop(-1, "")
			return
	if not _shaking:
		var raw := PackedByteArray()
		for i in 16:
			raw.append(_rng.randi() & 0xFF)
		_key = Marshalls.raw_to_base64(raw)
		var req := "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" % [_path, _host_header] \
			+ "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % _key
		if _io.put_data(req.to_utf8_buffer()) != OK:
			_drop(-1, "")
			return
		_shaking = true
	_read()
	var end := _find_header_end()
	if end < 0:
		return
	var head := _buf.slice(0, end).get_string_from_utf8()
	_buf = _buf.slice(end + 4)
	var lines := head.split("\r\n")
	var accept := ""
	for l: String in lines:
		if l.to_lower().begins_with("sec-websocket-accept:"):
			accept = l.get_slice(":", 1).strip_edges()
	if not (" 101" in lines[0]) or accept != _accept_for(_key):
		_drop(-1, lines[0])
		return
	_state = WebSocketPeer.STATE_OPEN
	_frames()                    # anything the server sent right behind its reply


func _read() -> void:
	if _io == null:
		return
	if _tls != null:
		_tls.poll()
		if _tls.get_status() != StreamPeerTLS.STATUS_CONNECTED:
			_drop(_close_code if _state == WebSocketPeer.STATE_CLOSING else -1, _close_reason)
			return
	else:
		_tcp.poll()
		if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_drop(_close_code if _state == WebSocketPeer.STATE_CLOSING else -1, _close_reason)
			return
	var n := _io.get_available_bytes()
	if n > 0:
		var got: Array = _io.get_partial_data(n)
		if got[0] == OK:
			_buf.append_array(got[1])


## Whole frames off the front of `_buf`: data kept, pings answered, a close
## answered and the line ended. A frame still arriving stays for next time.
func _frames() -> void:
	while _state != WebSocketPeer.STATE_CLOSED and _buf.size() >= 2:
		var b0 := _buf[0]
		var b1 := _buf[1]
		var n := b1 & 0x7F
		var at := 2
		if n == 126:
			if _buf.size() < 4:
				return
			n = (_buf[2] << 8) | _buf[3]
			at = 4
		elif n == 127:
			if _buf.size() < 10:
				return
			n = 0
			for i in 8:
				n = (n << 8) | _buf[2 + i]
			at = 10
		var mask := PackedByteArray()
		if b1 & 0x80:
			if _buf.size() < at + 4:
				return
			mask = _buf.slice(at, at + 4)
			at += 4
		if _buf.size() < at + n:
			return
		var data := _buf.slice(at, at + n)
		_buf = _buf.slice(at + n)
		if not mask.is_empty():
			for i in n:
				data[i] = data[i] ^ mask[i & 3]
		match b0 & 0x0F:
			0x0, 0x1, 0x2:
				_frag.append_array(data)
				if b0 & 0x80:
					_packets.append(_frag)
					_frag = PackedByteArray()
			0x8:
				var code := (data[0] << 8) | data[1] if data.size() >= 2 else 1005
				var why := data.slice(2).get_string_from_utf8() if data.size() > 2 else ""
				if _state == WebSocketPeer.STATE_OPEN:
					_send(0x8, data.slice(0, 2))
				_drop(code, why)
			0x9:
				_send(0xA, data)


## Client frames are masked (RFC 6455 5.3).
func _send(op: int, data: PackedByteArray) -> Error:
	var n := data.size()
	var f := PackedByteArray([0x80 | op])
	if n < 126:
		f.append(0x80 | n)
	elif n < 65536:
		f.append_array(PackedByteArray([0x80 | 126, (n >> 8) & 0xFF, n & 0xFF]))
	else:
		f.append(0x80 | 127)
		for i in range(7, -1, -1):
			f.append((n >> (8 * i)) & 0xFF)
	var mask := PackedByteArray([_rng.randi() & 0xFF, _rng.randi() & 0xFF, _rng.randi() & 0xFF, _rng.randi() & 0xFF])
	f.append_array(mask)
	var body := data.duplicate()
	for i in n:
		body[i] = body[i] ^ mask[i & 3]
	f.append_array(body)
	var err := _io.put_data(f)
	if err != OK:
		_drop(-1, "")
	return err


func _drop(code: int, reason: String) -> void:
	if _tls != null:
		_tls.disconnect_from_stream()
	_tcp.disconnect_from_host()
	_io = null
	_tls = null
	_close_code = code
	_close_reason = reason
	_state = WebSocketPeer.STATE_CLOSED


func _find_header_end() -> int:
	for i in range(0, _buf.size() - 3):
		if _buf[i] == 13 and _buf[i + 1] == 10 and _buf[i + 2] == 13 and _buf[i + 3] == 10:
			return i
	return -1


static func _accept_for(key: String) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA1)
	h.update((key + GUID).to_utf8_buffer())
	return Marshalls.raw_to_base64(h.finish())

class_name HttpPool
extends RefCounted

## HTTP calls over connections that are kept, not made anew for each.
##
## `HTTPRequest` closes its connection after every call, so each one paid for
## a new one first: the TCP handshake and the TLS one, three round trips
## before the request's own. On a line with a 300 ms round trip that made an
## answer at a monk 1.2 s; over a kept connection it is 0.3 s.
##
## A connection goes back in the pool after a call and is used again within
## IDLE_S. Calls in flight at the same time each have their own. One the far
## end has let go of meanwhile fails at once, or says nothing: it is given
## `reused_timeout_s`, then the call is made once more on a new connection.
## (What may have been sent twice is safe to: Backend._call.)

## Under a minute: mobile networks forget a quiet connection about then.
const IDLE_S := 45.0
var reused_timeout_s := 5.0

## origin -> [[HTTPClient, when last used (s)]]
var _idle := {}
## For the dev tools and the tests: connections made, and calls that went
## over a kept one.
var opened := 0
var reused := 0


## One call. `origin` is "https://name-or-address[:port]"; `tls` only to
## check the certificate against another name (a pinned address). Answers as
## HTTPRequest's `request_completed` does: [result, code, headers, body].
func send(origin: String, tls: TLSOptions, method: int, path: String, headers: PackedStringArray,
		payload: String, timeout_s: float) -> Array:
	var kept := _take(origin)
	if kept != null:
		var again := await _exchange(kept, method, path, headers, payload, minf(timeout_s, reused_timeout_s))
		if int(again[0]) == HTTPRequest.RESULT_SUCCESS:
			reused += 1
			_keep(origin, kept)
			return again
		kept.close()
	var t0 := Time.get_ticks_msec()
	var c := HTTPClient.new()
	var scheme := origin.get_slice("://", 0)
	var rest := origin.get_slice("://", 1)
	var port := int(rest.get_slice(":", 1)) if rest.contains(":") else -1
	if c.connect_to_host(scheme + "://" + rest.get_slice(":", 0), port, tls) != OK:
		return _failed(HTTPRequest.RESULT_CANT_CONNECT)
	while c.get_status() in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING]:
		c.poll()
		if Time.get_ticks_msec() - t0 > timeout_s * 1000.0:
			c.close()
			return _failed(HTTPRequest.RESULT_TIMEOUT)
		await (Engine.get_main_loop() as SceneTree).process_frame
	match c.get_status():
		HTTPClient.STATUS_CONNECTED:
			pass
		HTTPClient.STATUS_CANT_RESOLVE:
			return _failed(HTTPRequest.RESULT_CANT_RESOLVE)
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			return _failed(HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR)
		_:
			return _failed(HTTPRequest.RESULT_CANT_CONNECT)
	opened += 1
	var got := await _exchange(c, method, path, headers, payload, timeout_s - (Time.get_ticks_msec() - t0) / 1000.0)
	if int(got[0]) == HTTPRequest.RESULT_SUCCESS:
		_keep(origin, c)
	else:
		c.close()
	return got


## Every kept connection closed (signing out, the server's address changing).
func clear() -> void:
	for origin: String in _idle:
		for e: Array in _idle[origin]:
			(e[0] as HTTPClient).close()
	_idle.clear()


static func _failed(result: int) -> Array:
	return [result, 0, PackedStringArray(), PackedByteArray()]


## The request and its whole answer on a connected client.
func _exchange(c: HTTPClient, method: int, path: String, headers: PackedStringArray,
		payload: String, timeout_s: float) -> Array:
	var tree := Engine.get_main_loop() as SceneTree
	var t0 := Time.get_ticks_msec()
	if c.request(method, path, headers, payload) != OK:
		return _failed(HTTPRequest.RESULT_CONNECTION_ERROR)
	while c.get_status() == HTTPClient.STATUS_REQUESTING:
		c.poll()
		if Time.get_ticks_msec() - t0 > timeout_s * 1000.0:
			return _failed(HTTPRequest.RESULT_TIMEOUT)
		await tree.process_frame
	if not c.get_status() in [HTTPClient.STATUS_BODY, HTTPClient.STATUS_CONNECTED]:
		return _failed(HTTPRequest.RESULT_CONNECTION_ERROR)
	if not c.has_response():
		return _failed(HTTPRequest.RESULT_NO_RESPONSE)
	var code := c.get_response_code()
	var said := c.get_response_headers()
	var body := PackedByteArray()
	while c.get_status() == HTTPClient.STATUS_BODY:
		c.poll()
		var chunk := c.read_response_body_chunk()
		if not chunk.is_empty():
			body.append_array(chunk)
			continue
		if Time.get_ticks_msec() - t0 > timeout_s * 1000.0:
			return _failed(HTTPRequest.RESULT_TIMEOUT)
		await tree.process_frame
	return [HTTPRequest.RESULT_SUCCESS, code, said, body]


## A kept connection to `origin` that still looks alive, or null.
func _take(origin: String) -> HTTPClient:
	var now := Time.get_ticks_msec() / 1000.0
	var list: Array = _idle.get(origin, [])
	while not list.is_empty():
		var e: Array = list.pop_back()
		var c: HTTPClient = e[0]
		c.poll()            # a connection the far end closed says so here
		if now - float(e[1]) <= IDLE_S and c.get_status() == HTTPClient.STATUS_CONNECTED:
			return c
		c.close()
	return null


func _keep(origin: String, c: HTTPClient) -> void:
	if c.get_status() != HTTPClient.STATUS_CONNECTED:
		c.close()            # the server asked for it closed
		return
	if not _idle.has(origin):
		_idle[origin] = []
	(_idle[origin] as Array).append([c, Time.get_ticks_msec() / 1000.0])

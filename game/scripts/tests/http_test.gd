extends TestCase
## The kept connections every server call goes over (HttpPool, Backend._call),
## against a small HTTP server of this suite's own that counts connections.
##   godot --headless res://scripts/tests/http_test.tscn

var _srv := TCPServer.new()
## [StreamPeerTCP, what has come in, mute]: a mute connection reads and never
## answers -- one a network has silently forgotten.
var _conns: Array = []
var accepted := 0
var served := 0
var mute_all := false


func _process(_delta: float) -> void:
	while _srv.is_connection_available():
		_conns.append([_srv.take_connection(), PackedByteArray(), false])
		accepted += 1
	for c: Array in _conns.duplicate():
		var tcp: StreamPeerTCP = c[0]
		tcp.poll()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_conns.erase(c)
			continue
		var n := tcp.get_available_bytes()
		if n > 0:
			var buf: PackedByteArray = c[1]      # a copy: packed arrays in an Array are values
			buf.append_array(tcp.get_data(n)[1])
			c[1] = buf
		var text := (c[1] as PackedByteArray).get_string_from_utf8()
		var end := text.find("\r\n\r\n")
		if end < 0:
			continue
		var length := 0
		for line in text.left(end).split("\r\n"):
			if line.to_lower().begins_with("content-length:"):
				length = int(line.get_slice(":", 1))
		if text.to_utf8_buffer().size() < end + 4 + length:
			continue
		c[1] = PackedByteArray()
		if mute_all or c[2]:
			c[2] = true
			continue
		_answer(tcp, text.get_slice(" ", 1), c)


func _answer(tcp: StreamPeerTCP, path: String, c: Array) -> void:
	served += 1
	var code := "200 OK"
	var body := JSON.stringify({"n": served, "path": path})
	var extra := ""
	match path:
		"/hang":
			c[2] = true
			return
		"/boom":
			code = "500 Internal Server Error"
			body = JSON.stringify({"message": "boom"})
		"/big":
			body = JSON.stringify({"blob": "x".repeat(300000)})
		"/close":
			extra = "Connection: close\r\n"
		"/empty":
			body = ""
	tcp.put_data(("HTTP/1.1 %s\r\nContent-Type: application/json\r\nDate: Thu, 12 Nov 2026 10:00:00 GMT\r\n%sContent-Length: %d\r\n\r\n%s"
		% [code, extra, body.to_utf8_buffer().size(), body]).to_utf8_buffer())
	if path == "/close":
		tcp.disconnect_from_host()


func _hang_up() -> void:
	for c: Array in _conns:
		(c[0] as StreamPeerTCP).disconnect_from_host()
	_conns.clear()


func _ready() -> void:
	backup_save()
	var port := 0
	for p in range(18431, 18460):
		if _srv.listen(p, "127.0.0.1") == OK:
			port = p
			break
	var was_url := Net.url
	Net.url = "http://127.0.0.1:%d" % port
	var pool: HttpPool = Net.pool
	pool.clear()
	pool.opened = 0
	pool.reused = 0

	var a: Dictionary = await Net.rest(HTTPClient.METHOD_GET, "/ok")
	check("a call gets its answer", a.error == "" and a.data is Dictionary and str(a.data.path) == "/ok", str(a))
	for i in 5:
		await Net.rest(HTTPClient.METHOD_POST, "/ok", {"i": i})
	check("six calls in a row go over one connection", accepted == 1 and pool.opened == 1 and pool.reused == 5,
		"accepted %d opened %d reused %d" % [accepted, pool.opened, pool.reused])
	check("each was answered once", served == 6, str(served))

	# Two at once: the map opens with two calls in flight.
	var both := [false, false]
	var first := func() -> void:
		both[0] = (await Net.rest(HTTPClient.METHOD_GET, "/ok")).error == ""
	var second := func() -> void:
		both[1] = (await Net.rest(HTTPClient.METHOD_GET, "/ok")).error == ""
	first.call()
	second.call()
	for i in 200:
		if both[0] and both[1]:
			break
		await get_tree().process_frame
	check("two calls at once both get through, on a connection each", both[0] and both[1] and accepted == 2,
		"%s accepted %d" % [str(both), accepted])

	var boom: Dictionary = await Net.rest(HTTPClient.METHOD_GET, "/boom")
	check("the server saying no is its message, not a dead line",
		str(boom.error) == "boom" and not bool(boom.get("network", false)), str(boom))
	var big: Dictionary = await Net.rest(HTTPClient.METHOD_GET, "/big")
	check("a long answer arrives whole", big.error == "" and str(big.data.blob).length() == 300000)
	var empty: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/empty", {})
	check("an answer with no body is no error", empty.error == "" and empty.data == null, str(empty))

	# The far end closes after answering: said so, and not kept.
	var before := accepted
	await Net.rest(HTTPClient.METHOD_GET, "/close")
	await Net.rest(HTTPClient.METHOD_GET, "/close")
	var after_close: Dictionary = await Net.rest(HTTPClient.METHOD_GET, "/ok")
	# Both kept connections were used for those and closed: the next is new.
	check("a connection the server closes is not used again", after_close.error == "" and accepted == before + 1,
		"accepted %d -> %d" % [before, accepted])

	# The far end hangs up on every kept connection without a word.
	await Net.rest(HTTPClient.METHOD_GET, "/ok")
	_hang_up()
	for i in 10:
		await get_tree().process_frame
	before = accepted
	var served_before := served
	var back: Dictionary = await Net.rest(HTTPClient.METHOD_GET, "/ok")
	check("after the server hangs up, the next call makes a new connection",
		back.error == "" and accepted == before + 1 and served == served_before + 1, str(back))

	# A kept connection that has gone silent: the call gives it a moment,
	# then goes again on a new one.
	pool.reused_timeout_s = 0.4
	await Net.rest(HTTPClient.METHOD_GET, "/ok")
	for c: Array in _conns:
		c[2] = true
	before = accepted
	var t0 := Time.get_ticks_msec()
	var woke: Dictionary = await Net.rest(HTTPClient.METHOD_GET, "/ok")
	var took := Time.get_ticks_msec() - t0
	check("a kept connection gone silent is given up on and the call made again",
		woke.error == "" and accepted == before + 1 and took >= 350 and took < 3000, "%s in %d ms" % [str(woke), took])
	pool.reused_timeout_s = 5.0

	# Nothing ever answers: the call's own timeout, said as no connection.
	var hung: Array = await pool.send(Net.url, null, HTTPClient.METHOD_GET, "/hang", PackedStringArray(), "", 0.5)
	check("a call nothing answers times out", int(hung[0]) == HTTPRequest.RESULT_TIMEOUT, str(hung[0]))
	_srv.stop()
	_hang_up()
	pool.clear()
	var dead: Dictionary = await Net.rest(HTTPClient.METHOD_GET, "/ok")
	check("no server at all is no connection, and nothing was sent",
		str(dead.error) == Net.NO_CONNECTION and bool(dead.get("network", false)) and not bool(dead.get("maybe_sent", true)), str(dead))

	Net.url = was_url
	completed = true
	finish("HTTP")

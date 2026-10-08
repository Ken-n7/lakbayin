extends TestCase
## A bad connection, as the classroom's WiFi gives one. A scoring call that
## cannot reach the server waits and is tried again -- never lost, never sent
## twice -- while Net.connection() says "offline"; once the server answers,
## it goes through exactly once and the line reads "good". A refusal from the
## server is an answer, not a dropped line, and is not retried.
##   godot --headless res://scripts/tests/net_retry_test.tscn
##
## The "server" is a few lines of TCPServer on this machine: nothing listening
## is a dead line, listening is the line back.

const PORT := 47391

var _server := TCPServer.new()
var _peers: Array[StreamPeerTCP] = []
var _bufs := {}
var hits := 0
## What the stub answers: 200 with a member row, or 400 as a refusal.
var refuse := false
## Stateful: a real row, which apply_answer moves on and GET members reads.
var stateful := false
var items_done := 0
var gems := 50
var applied := 0
var answer_posts := 0
## Apply the next answer, then hang up without replying.
var drop_next_reply := false
## Signing back in (_restore): a token for the refresh, a profile for the
## read -- or the profile's reply lost, or the token refused.
var auth := false
var profile_down := false
var token_refused := false


func _ready() -> void:
	backup_save()
	var was_url: String = Net.url
	var was_key: String = Net.anon_key
	var was_token: String = Net.access_token
	Net.url = "http://127.0.0.1:%d" % PORT
	Net.anon_key = "test"
	Net.access_token = ""

	# --- Nobody listening: the line is down ------------------------------------
	var got: Array = []
	Scores.submit("answer", true, "sid-test", func(r: Dictionary) -> void: got.append(r))
	await _wait(4.0)
	check("no server: the answer waits, it is not dropped", Scores.pending() == 1 and got.is_empty(),
		"pending %d, callbacks %d" % [Scores.pending(), got.size()])
	check("...and the line reads offline", Net.connection(Scores.waiting_s()) == "offline",
		Net.connection(Scores.waiting_s()))
	check("...waiting is counted", Scores.waiting_s() >= 3.0, str(Scores.waiting_s()))

	# --- The server is back ----------------------------------------------------
	_server.listen(PORT, "127.0.0.1")
	for i in 40:
		await _wait(0.5)
		if Scores.pending() == 0:
			break
	check("back: the answer goes through", Scores.pending() == 0 and got.size() == 1,
		"pending %d, callbacks %d" % [Scores.pending(), got.size()])
	check("...exactly once", hits == 1, "server saw %d" % hits)
	check("...with the server's row", got.size() == 1 and str(got[0].get("error", "?")) == ""
		and int((got[0].get("row", {}) as Dictionary).get("gems", 0)) == 60, str(got))
	check("...and the line reads good again", Net.connection() == "good", Net.connection())

	# --- A refusal is an answer --------------------------------------------------
	refuse = true
	var said: Array = []
	Scores.submit("hint", false, "sid-test", func(r: Dictionary) -> void: said.append(r))
	for i in 20:
		await _wait(0.25)
		if Scores.pending() == 0:
			break
	check("a refusal comes back at once, not retried", said.size() == 1 and hits == 2
		and str(said[0].get("error", "")) != "", "callbacks %d, hits %d" % [said.size(), hits])

	# --- Done there, the reply lost: never asked twice -----------------------
	# The server takes the answer and the line drops before its reply comes
	# back. Asking again would count it twice (+10 again, the next question
	# marked done): the row is read instead, and it is already there.
	refuse = false
	stateful = true
	items_done = 1
	gems = 60
	applied = 0
	drop_next_reply = true
	Scores.know({"items_done": 1, "gems": 60, "stations_done": 0})
	var lost: Array = []
	Scores.submit("answer", true, "sid-test", func(r: Dictionary) -> void: lost.append(r))
	for i in 40:
		await _wait(0.5)
		if Scores.pending() == 0:
			break
	check("reply lost: the answer is counted once", applied == 1 and items_done == 2,
		"applied %d times, items_done %d" % [applied, items_done])
	check("...it is not sent again", answer_posts == 1, "%d answer requests" % answer_posts)
	check("...and the board gets the server's row", lost.size() == 1
		and int((lost[0].get("row", {}) as Dictionary).get("items_done", 0)) == 2, str(lost))
	stateful = false

	# --- The live connection keeps trying ----------------------------------------
	# A port nobody listens on refuses at once, as a phone's connect does while
	# its WiFi is still coming back: CONNECTING and CLOSED again between two
	# polls, so no change is ever seen -- and retrying hung off that change.
	# Stuck: closed, nothing to retry, and it stays that way.
	Net.url = "https://127.0.0.1:1"
	var rt: Realtime = Net.realtime()
	rt.watch("sessions", "id=eq.none")
	await _wait(1.0)
	var stuck := 0
	for i in 12:
		await _wait(0.5)
		if rt.get_ws_state() == WebSocketPeer.STATE_CLOSED and float(rt.get("_retry_in")) < 0.0:
			stuck += 1
	check("a connect that fails at once is tried again", stuck <= 1,
		"closed with no retry coming in %d of 12 looks" % stuck)
	await _wait(5.0)       # past the 11s (two heartbeats) Net.connection() waits before "offline"
	check("...and the line reads offline meanwhile", Net.connection() == "offline", Net.connection())
	rt.close_socket()

	_bridge()
	_line_measures()
	await _restore()

	_server.stop()
	Net.url = was_url
	Net.anon_key = was_key
	Net.access_token = was_token
	completed = true
	finish("NETRETRY")


## Signing back in at launch. No line is not a sign-out: the saved login is
## kept and tried again (the splash shows "No connection" and waits). A line
## that dies between the token and the profile is not done either -- a
## teacher was left with no role and sent to the students' home. A refusal
## is still a refusal.
func _restore() -> void:
	Net.url = "http://127.0.0.1:%d" % PORT
	Net.access_token = ""
	Net.role = ""
	Net.username = ""
	Net.refresh_token = "rt1"
	Net._save_session()
	_server.stop()
	var e: String = await Net.restore_session()
	check("no line at launch: 'no connection', not signed out", e == Net.NO_CONNECTION and not Net.signed_in(), e)
	_server.listen(PORT, "127.0.0.1")
	auth = true
	profile_down = true
	e = await Net.restore_session()
	check("...the token came but not the profile: not done yet", e == Net.NO_CONNECTION and Net.role == "", e)
	profile_down = false
	e = await Net.restore_session()
	check("...and the next try finishes it, role and all", e == "" and Net.role == "admin" and Net.username == "stu",
		"%s / %s / %s" % [e, Net.role, Net.username])
	Net.access_token = ""
	Net.role = ""
	token_refused = true
	e = await Net.restore_session()
	check("a refused login is a refusal, not a lost line", e != "" and e != Net.NO_CONNECTION, e)
	auth = false
	token_refused = false
	Net.access_token = ""
	Net.refresh_token = ""
	Net.role = ""
	Net.username = ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Net.SESSION_PATH))


## One slow call is not a weak line: the typical one is what counts.
func _line_measures() -> void:
	var was: Array[float] = Net.get("_rest_rtts").duplicate()
	for s: float in [0.4, 0.5, 3.6, 0.45, 0.5]:
		Net._note_rtt(s)
	check("one 3.6s call among quick ones: the line's time stays quick", float(Net.get("_rest_rtt")) < 1.0,
		str(Net.get("_rest_rtt")))
	for s: float in [2.0, 2.2, 1.9]:
		Net._note_rtt(s)
	check("...but a run of slow ones shows", float(Net.get("_rest_rtt")) > 1.5, str(Net.get("_rest_rtt")))
	Net.set("_rest_rtts", was)
	Net.set("_rest_rtt", 0.0)


## The teacher's bridge (PosHub): relay students go into its snapshots only
## while some phone is on the hub path -- otherwise not one extra message.
func _bridge() -> void:
	var hub := PosHub.new()
	add_child(hub)
	hub.set("_sid", "s1")
	var walker := {"id": "r1", "hero": 2, "p": [[1.0, 1, 1], [1.05, 2, 2], [1.1, 3, 3], [1.2, 4, 4]], "fast": true}
	hub._on_relay_snap([walker])
	check("everyone on the relay: nothing bridged", hub.take_snapshot().is_empty())
	hub._on_broadcast("pos", {"sid": "s1", "id": "h1", "hero": 1, "p": {"t": 5.0, "dt": 0.1, "x": [9], "y": [9]}})
	check("a phone on the hub path turns the bridge on", hub.bridging())
	hub._on_relay_snap([walker])
	var snap: Dictionary = hub.take_snapshot()
	var heroes: Array = snap.get("p", [])
	var ids: Array = heroes.map(func(e: Dictionary) -> String: return str(e.id))
	check("...both paths in one snapshot", ids.has("h1") and ids.has("r1"), str(ids))
	var r1: Array = heroes.filter(func(e: Dictionary) -> bool: return e.id == "r1")
	check("...the relay's walk at the hub's own pace", not r1.is_empty()
		and r1[0].p == [[1.0, 1, 1], [1.1, 3, 3], [1.2, 4, 4]], str(r1))
	check("...and sent once", hub.take_snapshot().is_empty())
	hub.set("_hub_path_at", -INF)
	hub._on_relay_snap([walker])
	check("the hub-path phone gone: the bridge stops", hub.take_snapshot().is_empty())
	hub.queue_free()


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


## The stub: read a request, answer it, close.
func _process(_delta: float) -> void:
	while _server.is_listening() and _server.is_connection_available():
		var p := _server.take_connection()
		_peers.append(p)
		_bufs[p] = ""
	for p in _peers.duplicate():
		p.poll()
		if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_peers.erase(p)
			continue
		var n: int = p.get_available_bytes()
		if n > 0:
			_bufs[p] += p.get_utf8_string(n)
		var text: String = _bufs[p]
		var head_end := text.find("\r\n\r\n")
		if head_end < 0:
			continue
		var length := 0
		for line in text.substr(0, head_end).split("\r\n"):
			if line.to_lower().begins_with("content-length:"):
				length = int(line.split(":")[1].strip_edges())
		if text.length() < head_end + 4 + length:
			continue
		hits += 1
		var body := '{"message":"the adventure is not running"}' if refuse \
			else '[{"gems":60,"items_done":1}]'
		var status := "400 Bad Request" if refuse else "200 OK"
		if auth:
			var line: String = text.substr(0, text.find("\r\n"))
			if line.contains("/auth/v1/token"):
				status = "400 Bad Request" if token_refused else "200 OK"
				body = '{"error":"invalid_grant","error_description":"Invalid Refresh Token"}' if token_refused \
					else '{"access_token":"at1","refresh_token":"rt2","user":{"id":"u1"}}'
			elif line.contains("/rest/v1/profiles"):
				if profile_down:
					p.disconnect_from_host()      # the line died: no reply
					_peers.erase(p)
					continue
				body = '[{"username":"stu","role":"admin"}]'
		if stateful:
			var first_line: String = text.substr(0, text.find("\r\n"))
			if first_line.begins_with("POST") and first_line.contains("apply_answer"):
				answer_posts += 1
				applied += 1
				items_done += 1
				gems += 10
				if drop_next_reply:
					drop_next_reply = false
					p.disconnect_from_host()      # done here, the reply never sent
					_peers.erase(p)
					continue
			body = JSON.stringify([{"items_done": items_done, "gems": gems, "stations_done": 0}])
			status = "200 OK"
		var reply: String = ("HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n"
			+ "Connection: close\r\n\r\n%s") % [status, body.to_utf8_buffer().size(), body]
		p.put_data(reply.to_utf8_buffer())
		p.disconnect_from_host()
		_peers.erase(p)

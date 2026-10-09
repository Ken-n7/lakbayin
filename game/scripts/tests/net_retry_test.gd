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
## The question bank: every request line is kept, and two questions answer.
var bank := false
var asked: Array[String] = []


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
	_weak_line()
	await _restore()
	await _bank()
	_lobby_bell()
	_relay_pick()

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


## A class plays its own teacher's questions: a player may read every
## teacher's active ones, so the phone has to ask for its session's teacher's.
func _bank() -> void:
	Net.url = "http://127.0.0.1:%d" % PORT
	Net.access_token = "at"
	bank = true
	asked.clear()
	var err: String = await QuestionStore.load_bank("teacher-a")
	var ask: String = asked[0] if not asked.is_empty() else ""
	check("the bank asked for is the session teacher's", err == "" and ask.contains("/rest/v1/questions")
		and ask.contains("owner=eq.teacher-a"), "%s / %s" % [err, ask])
	check("...and its questions are the class's", (QuestionStore.bank.get(0, []) as Array).size() == 2,
		str(QuestionStore.bank))
	bank = false
	QuestionStore.bank = {}
	Net.access_token = ""


## A lobby's broadcasts are only a doorbell. Anyone signed in can broadcast on
## the shared channel, from any class: a fake "ended" or a fake team must
## change nothing, only ask for a reload.
func _lobby_bell() -> void:
	var lobby := Lobby.new()
	lobby.session = {"id": "s1", "state": "lobby"}
	lobby.teams = [{"id": "t1", "name": "Red"}]
	var fake := {"sid": "s1", "table": "sessions", "type": "UPDATE", "record": {"id": "s1", "state": "ended"}}
	check("a lobby broadcast asks for a reload", lobby.hear(Lobby.EVENT, fake) == "reload")
	check("...and its record is not taken", lobby.session.state == "lobby", str(lobby.session))
	var spy := {"sid": "s1", "table": "teams", "type": "INSERT",
		"record": {"id": "t9", "session_id": "s1", "name": "Spy"}}
	check("...one more within the second rings nothing",
		lobby.hear(Lobby.EVENT, spy) == "" and lobby.teams.size() == 1, str(lobby.teams))
	check("...another session's is not ours", lobby.hear(Lobby.EVENT, {"sid": "other"}) == "")
	check("the database's change feed is still applied",
		lobby.apply("sessions", "UPDATE", {"id": "s1", "state": "running"}) == "changed"
		and lobby.session.state == "running", str(lobby.session))


## Which relay a class uses (RelayLink.published): an address counts only if it
## is wss:// and fresh -- a class relay refreshed within 90s.
func _relay_pick() -> void:
	var at := func(ago: float) -> String:
		return Time.get_datetime_string_from_unix_time(int(Game.now() - ago)) + "Z"
	var reply := func(url: String, ago: float) -> Dictionary:
		return {"error": "", "data": [{"url": url, "updated_at": at.call(ago)}]}
	var stale := RelayLink.CLASS_STALE_S
	check("a class relay refreshed 20s ago is used",
		RelayLink.fresh_url(reply.call("wss://class", 20.0), stale) == "wss://class")
	check("...not one 2 minutes old: its laptop is gone",
		RelayLink.fresh_url(reply.call("wss://class", 120.0), stale) == "")
	check("...nor plain ws://, nor none, nor a failed read",
		RelayLink.fresh_url(reply.call("ws://class", 1.0), stale) == ""
		and RelayLink.fresh_url({"error": "", "data": []}, stale) == ""
		and RelayLink.fresh_url({"error": "offline", "data": null}, stale) == "")


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


## A weak line (RelayLink): pongs queued behind snapshots twice running ask
## the relay for half of them, then a quarter, never fewer; it waits for what
## was already queued to drain; calm brings them back.
func _weak_line() -> void:
	var link := RelayLink.new()
	var asked: Array = []
	link.set("_ws", Asks.new(asked))
	link.hz = 20
	link.rate = 20
	var fresh := func() -> void: link.set("_hold_until", 0.0)
	fresh.call()
	link._judge_rate(0.1)
	link._judge_rate(0.9)
	check("one queued pong: still all 20", link.rate == 20, str(link.rate))
	link._judge_rate(1.0)
	check("queued twice running: half", link.rate == 10 and asked.size() == 1 and '"hz":10' in str(asked[0]),
		"%d %s" % [link.rate, asked])
	link._judge_rate(2.0)
	link._judge_rate(2.0)
	check("...then waits for the queue to drain", link.rate == 10, str(link.rate))
	fresh.call()
	link._judge_rate(1.5)
	link._judge_rate(1.5)
	check("still queued: a quarter", link.rate == 5, str(link.rate))
	fresh.call()
	link._judge_rate(2.0)
	link._judge_rate(2.0)
	check("...and never fewer", link.rate == 5 and asked.size() == 2, "%d %s" % [link.rate, asked])
	fresh.call()
	link.set("_calm_since", Time.get_ticks_msec() / 1000.0 - RelayLink.RATE_CALM_S - 1.0)
	link._judge_rate(0.12)
	check("calm for RATE_CALM_S: twice as many", link.rate == 10 and '"hz":10' in str(asked[-1]), str(asked))
	link._judge_rate(1.0)
	link._judge_rate(1.0)
	check("a try the line cannot carry: back down, and twice the calm before the next",
		link.rate == 5 and is_equal_approx(float(link.get("_calm_need")), RelayLink.RATE_CALM_S * 2.0),
		"%d %.0f" % [link.rate, float(link.get("_calm_need"))])
	link.up = true
	link._judge_rate(0.1 + RelayLink.FLUSH_S + 0.5)
	check("far behind: dropped and started over at the least", not link.up
		and int(link.get("_start_rate")) == 5 and "started over" in link.last_close, link.last_close)
	link.free()
	var late := RelayLink.new()                    # behind from its very first pong
	late.set("_ws", Asks.new([]))
	late.hz = 20
	late.rate = 20
	late.up = true
	late._judge_rate(10.0)
	check("a first pong already 10s late: started over at once", not late.up, late.last_close)
	late.free()


class Asks:
	var out: Array
	func _init(to: Array) -> void:
		out = to
	func send_text(t: String) -> void:
		out.append(t)
	func get_ready_state() -> int:
		return WebSocketPeer.STATE_OPEN
	func close(_code := 1000, _why := "") -> void:
		pass


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
		if bank:
			asked.append(text.substr(0, text.find("\r\n")))
			body = JSON.stringify([{"station": 1, "prompt": "1+1", "answer": "2", "active": true},
				{"station": 1, "prompt": "2+2", "answer": "4", "active": true}])
			status = "200 OK"
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

class_name Backend
extends Node

## The game's line to its server (server/app.py), as the `Net` autoload:
## accounts, rows over HTTP, and the realtime socket (Realtime).
##
## Plain HTTP with a bearer token. Rows are read and written at
## `/rest/v1/<table>?<filter>`, server functions called at `/rest/v1/rpc/<name>`,
## and the socket speaks the Phoenix channel protocol at
## `/realtime/v1/websocket` -- the shapes the game was first written against,
## which the server keeps so this side did not have to change.
##
## The server's address comes from the environment first (dev machines, the
## suites), then from project settings (a shipped build).

## Where the session token lives between launches. Per `--profile=NAME`, like
## `Game.SAVE_PATH`. The name is older than this file: renaming it would sign
## every player out.
var SESSION_PATH := "user://selfhost-session%s.cfg" % Game.profile_suffix()

var url: String
## Kept so a launch signs straight back in instead of asking for the password
## again. Valid for 30 days, until sign-out.
var refresh_token := ""
var access_token := ""
var user_id := ""
## Filled from the profile on every successful sign-in.
var username := ""

var _realtime: Realtime


func _init() -> void:
	url = _conf("LAKBAYIN_SERVER_URL", "lakbayin/server/url").rstrip("/")


## One `HTTPRequest` per call, not one for the client.
##
## A single shared node refuses a second request while the first is in flight
## -- "HTTPRequest is processing a request" -- and the map issues two at once
## every time it opens. It failed only on the phone, because that is the
## first place two requests raced in earnest.
func _new_http() -> HTTPRequest:
	var req := HTTPRequest.new()
	# Godot's default is no timeout at all: on a dying connection a request
	# hung for good, and every call queued behind it with it.
	req.timeout = REQUEST_TIMEOUT_S
	add_child(req)
	return req


const REQUEST_TIMEOUT_S := 12.0
## The error of a call that never reached the server (or whose reply never
## came back) -- told apart from the server saying no.
const NO_CONNECTION := "No connection"
## The line, from the requests: when one last failed to get through (-1 since
## one got through), and how long they typically take -- the median of the
## last RTT_KEEP, so one slow call (a phone setting up a fresh secure
## connection took 1.5-3.6s now and then) does not read as a weak line.
var _rest_failed_at := -1.0
var _rest_rtt := 0.0
var _rest_rtts: Array[float] = []
const RTT_KEEP := 5
## For the dev panel's Network tab: calls that got an answer, calls that
## never did, and why the last of those failed (HTTPRequest.RESULT_*).
var http_ok := 0
var http_failed := 0
var http_last_failure := -1


## "good", "weak" or "offline" -- what a game's signal bars say. Offline: the
## live connection silent past 8s, or a request failing to get through in the
## last 10s. Weak: slow replies, or an answer waiting more than 3s to be saved
## (`waiting_s`, passed in by the caller).
## The board shows it and holds back what would pile up (AdventureScreen).
func connection(waiting_s := 0.0) -> String:
	var now := Time.get_ticks_msec() / 1000.0
	var silent := _realtime.silent_for() if _realtime != null else 0.0
	# The socket is only heard every HEARTBEAT_S when nothing else is said.
	# Weak once a heartbeat is overdue, offline once two are.
	if silent > Realtime.HEARTBEAT_S * 2.0 + 1.0 or (_rest_failed_at >= 0.0 and now - _rest_failed_at < 10.0):
		return "offline"
	if silent > Realtime.HEARTBEAT_S + 2.0 or (_realtime != null and _realtime.rtt > 1.0) \
			or _rest_rtt > 1.5 or waiting_s > 3.0:
		return "weak"
	return "good"


func _note_rtt(seconds: float) -> void:
	_rest_rtts.append(seconds)
	if _rest_rtts.size() > RTT_KEEP:
		_rest_rtts.pop_front()
	var sorted := _rest_rtts.duplicate()
	sorted.sort()
	_rest_rtt = sorted[sorted.size() / 2]


func configured() -> bool:
	return not url.is_empty()


## How often a hero's path goes out (AdventureScreen._share_position). The
## server takes every bundle and checks it (server/app.py, moved_ok).
func movement_interval() -> float:
	return 0.05


## Register; signs the new account in. Returns the error message, or "".
func sign_up(name: String, password: String) -> String:
	return await _finish(await _call(HTTPClient.METHOD_POST, "/auth/register",
		{"username": name.strip_edges(), "password": password}))


func sign_in(who: String, password: String) -> String:
	return await _finish(await _call(HTTPClient.METHOD_POST, "/auth/login",
		{"username": who.strip_edges(), "password": password}))


## The realtime socket, made on first use and kept as a child of this node.
## Nothing opens one until something asks to watch a table.
func realtime() -> Realtime:
	if _realtime == null or not is_instance_valid(_realtime):
		_realtime = Realtime.new()
		_realtime.name = "Realtime"
		add_child(_realtime)
	return _realtime


func signed_in() -> bool:
	return access_token != ""


## Signing back in after a restart, with no password. Returns "" on success,
## or why not -- "no saved session" being the ordinary answer on a fresh
## install, not an error worth showing anybody, and NO_CONNECTION when the
## server could not be reached: the login is still good, try again (the
## splash does).
##
## Signed in is not enough: a line that died between the token and the
## profile left no username. Then only the profile is fetched again.
func restore_session() -> String:
	if signed_in() and username != "":
		return ""
	if signed_in():
		return await _load_profile()
	var cfg := ConfigFile.new()
	if cfg.load(SESSION_PATH) != OK:
		return "no saved session"
	var saved := str(cfg.get_value("auth", "refresh_token", ""))
	if saved == "":
		return "no saved session"
	return await _finish(await _call(HTTPClient.METHOD_POST, "/auth/restore",
		{"refresh_token": saved}))


func sign_out() -> void:
	# Revoke the token first, then forget it here: the request owns its HTTP
	# node and can finish while the next screen is already up.
	if access_token != "":
		_call(HTTPClient.METHOD_POST, "/auth/logout", {}, access_token)
	if is_instance_valid(_realtime):
		_realtime.close_socket()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SESSION_PATH))
	refresh_token = ""
	access_token = ""
	user_id = ""
	username = ""


## One call to a table or a server function. `path` is a table and its
## query, e.g. `/rest/v1/sessions?id=eq.<id>`, or `/rest/v1/rpc/<name>`.
## The reply is in `.data`; `.error` is "" when it worked.
func rest(method: int, path: String, body: Variant = null) -> Dictionary:
	return await _call(method, path, body)


## A token is only half a session -- the display name lives in the profile,
## so every way in loads it before it reports success.
func _finish(reply: Dictionary) -> String:
	if bool(reply.get("network", false)):
		return NO_CONNECTION
	var err := _remember(reply)
	if err != "":
		return err
	return await _load_profile()


func _load_profile() -> String:
	var got := await rest(HTTPClient.METHOD_GET, "/rest/v1/profiles?select=username&id=eq." + user_id)
	if bool(got.get("network", false)):
		return NO_CONNECTION
	if got.error != "":
		return got.error
	var rows: Variant = got.data
	if rows is Array and not (rows as Array).is_empty():
		username = (rows[0] as Dictionary).get("username", "")
		# Desktop windows run side by side under `--profile`; the title says
		# which account each one is, since the screens all look alike.
		if Game.profile_suffix() != "":
			get_window().title = "Lakbayin — %s" % username
	return ""


## How far this device's clock is from the server's, off the reply's `Date`
## header -- every session clock is read against it (`Game.now()`). Kept from
## the quickest round trip seen, where the network adds the least doubt.
##
## ponytail: `Date` is whole seconds, so boards agree to within about a
## second; an RPC returning now() in ms would tighten that if it matters.
var _best_rtt := INF


func _learn_clock(headers: PackedStringArray, sent: float) -> void:
	var got := Time.get_unix_time_from_system()
	var rtt := got - sent
	if rtt > _best_rtt:
		return
	for h in headers:
		if h.to_lower().begins_with("date:"):
			var server := Game.http_date(h.substr(5).strip_edges())
			if server > 0:
				_best_rtt = rtt
				# `Date` truncates to the second: the middle of that second,
				# against the middle of the round trip.
				Game.clock_offset = server + 0.5 - (sent + rtt * 0.5)
			return


## `as_token`: made with that token instead of this device's session (sign
## out revokes the token it is letting go of).
func _call(method: int, path: String, body: Variant, as_token := "") -> Dictionary:
	if not configured():
		return {"error": "No server configured (LAKBAYIN_SERVER_URL)", "data": null}
	if not is_inside_tree():
		return {"error": "The server client is not in the scene tree yet", "data": null}
	var headers := ["Content-Type: application/json"]
	var token := as_token if as_token != "" else access_token
	if token != "":
		headers.append("Authorization: Bearer " + token)
	# The server's address that answers on this network (Dial): by name as
	# usual, or straight to the address with the name kept for the
	# certificate and the Host header.
	var host := Dial.host_of(url)
	var at := await Dial.address(host)
	var http := _new_http()
	var target := url
	if at != "":
		target = url.replace("://" + host, "://" + at)
		http.set_tls_options(TLSOptions.client(null, host))
		headers.append("Host: " + host)
	var payload := "" if body == null else JSON.stringify(body)
	var sent := Time.get_unix_time_from_system()
	var err := http.request(target + path, headers, method, payload)
	if err != OK:
		http.queue_free()
		return {"error": NO_CONNECTION, "data": null, "network": true, "maybe_sent": false}
	var res: Array = await http.request_completed
	http.queue_free()
	# Never reached the server -- no connection, or the timeout above. Said
	# apart from a refusal, so a scoring call is retried rather than dropped.
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		_rest_failed_at = Time.get_ticks_msec() / 1000.0
		Dial.forget(host)           # a changed network, maybe: dial again next time
		http_failed += 1
		http_last_failure = int(res[0])
		# No line, no address, no secure handshake: nothing was sent. Anything
		# later -- a timeout, the line dropping mid-call -- may have reached
		# the server and been done there, the reply lost on the way back.
		var unsent := int(res[0]) in [HTTPRequest.RESULT_CANT_CONNECT,
			HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR]
		return {"error": NO_CONNECTION, "data": null, "network": true, "maybe_sent": not unsent}
	_rest_failed_at = -1.0
	_note_rtt(Time.get_unix_time_from_system() - sent)
	http_ok += 1
	_learn_clock(res[2], sent)
	var code: int = res[1]
	var text := (res[3] as PackedByteArray).get_string_from_utf8()
	# A function returning nothing (Shuffle) answers 204 with no body at all.
	var parsed: Variant = JSON.parse_string(text) if text.strip_edges() != "" else null
	if code < 200 or code >= 300:
		var msg := "HTTP %d" % code
		if parsed is Dictionary:
			msg = parsed.get("message", msg)
		return {"error": msg, "data": parsed}
	return {"error": "", "data": parsed}


## Every auth call answers with the same envelope, so they all stash the token.
func _remember(reply: Dictionary) -> String:
	if reply.error != "":
		return reply.error
	var d: Variant = reply.data
	if d is Dictionary:
		access_token = d.get("access_token", "")
		refresh_token = d.get("refresh_token", refresh_token)
		var user: Variant = d.get("user")
		if user is Dictionary:
			user_id = user.get("id", "")
	if access_token.is_empty():
		return "The server did not sign you in."
	_save_session()
	return ""


func _save_session() -> void:
	# Saved for the tools too -- into their own profile's file, never the real
	# login's -- because staying signed in is itself one of the things the
	# live checks test. The splash is what declines to restore it for a tool.
	if refresh_token == "":
		return
	var cfg := ConfigFile.new()
	cfg.set_value("auth", "refresh_token", refresh_token)
	cfg.save(SESSION_PATH)


func _conf(env: String, setting: String) -> String:
	var v := OS.get_environment(env)
	return v if not v.is_empty() else str(ProjectSettings.get_setting(setting, ""))

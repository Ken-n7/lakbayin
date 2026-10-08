class_name Supabase
extends Node

## The whole Supabase client: GoTrue for sign-up/sign-in/recovery, PostgREST
## for rows. There is no Godot SDK and there does not need to be -- both are
## plain HTTP against the same host with the same two headers.
##
## Sign-in is by **email**; the username is still the unique display name the
## mockups show, carried in the sign-up metadata into `public.profiles`.
##
## Password recovery is a **6-digit code**, not a link. A link needs a web page
## or an Android deep link to land on, and this app has neither -- so the
## recovery template sends `{{ .Token }}`, the player types it, and
## `confirm_reset()` trades it for a session and sets the new password.
##
## Credentials come from the environment first (dev machines, CI), then from
## project settings (a shipped build). The anon key is meant to be public; the
## row level security in `supabase/schema.sql` is what actually guards the data.
## The *service role* key is not, and never belongs in this file or the repo.

## Where the refresh token lives between launches.
## Per `--profile=NAME`, like `Game.SAVE_PATH`.
var SESSION_PATH := "user://session%s.cfg" % Game.profile_suffix()

var url: String
var anon_key: String
## Kept so a launch can trade it for a new access token instead of asking a
## classroom of students to type their passwords again. Access tokens expire
## after about an hour; this one does not, until sign-out.
var refresh_token := ""
var access_token := ""
var user_id := ""
## Filled from `public.profiles` on every successful sign-in, so a screen never
## has to know that the display name and the login identity live apart.
var username := ""
var role := ""

var _realtime: Realtime
var _relay: RelayLink


func _init() -> void:
	url = _conf("SUPABASE_URL", "numxventure/supabase/url").rstrip("/")
	anon_key = _conf("SUPABASE_ANON_KEY", "numxventure/supabase/anon_key")


func _ready() -> void:
	# Debug builds on a phone tell the laptop how their network is treating
	# them (NetReport, tools/sim/netreport_listen.py).
	if OS.is_debug_build() and OS.has_feature("mobile"):
		add_child(NetReport.new())


## Broadcast to a channel over HTTP, without joining it (Supabase's REST
## broadcast). For NetReport, which must get through when the socket cannot.
func broadcast_rest(topic: String, event: String, payload: Dictionary) -> Dictionary:
	return await _call(HTTPClient.METHOD_POST, "/realtime/v1/api/broadcast",
		{"messages": [{"topic": topic, "event": event, "payload": payload}]})


## One `HTTPRequest` per call, not one for the client.
##
## A single shared node refuses a second request while the first is in flight
## -- "HTTPRequest is processing a request" -- and the map issues two at once
## every time it opens: the question bank and the session. It failed only on
## the phone, because that is the first place two requests raced in earnest.
##
## Node churn at a handful of requests a minute costs nothing; a dropped
## request costs a student their adventure.
func _new_http() -> HTTPRequest:
	var req := HTTPRequest.new()
	# Godot's default is no timeout at all: on a dying connection a request
	# hung for good, and every answer queued behind it (Scores) with it.
	req.timeout = REQUEST_TIMEOUT_S
	add_child(req)
	return req


const REQUEST_TIMEOUT_S := 12.0
## The line, from the requests: when one last failed to get through (-1 since
## one got through), and how long the last that did took.
var _rest_failed_at := -1.0
var _rest_rtt := 0.0
## For NetReport: calls that got an answer, calls that never did, and why
## the last of those failed (HTTPRequest.RESULT_*).
var http_ok := 0
var http_failed := 0
var http_last_failure := -1


## "good", "weak" or "offline" -- what a game's signal bars say. Offline: the
## live connection silent past 8s, or a request failing to get through in the
## last 10s. Weak: slow replies, or an answer waiting more than 3s to be saved
## (`waiting_s`, Scores.waiting_s() -- passed in: this file naming Scores,
## which names Net, broke every `--script` run that loads it).
## The board shows it and holds back what would pile up (AdventureScreen).
func connection(waiting_s := 0.0) -> String:
	var now := Time.get_ticks_msec() / 1000.0
	var silent := _realtime.silent_for() if _realtime != null else 0.0
	if silent > 8.0 or (_rest_failed_at >= 0.0 and now - _rest_failed_at < 10.0):
		return "offline"
	if silent > 4.0 or (_realtime != null and _realtime.rtt > 1.0) \
			or _rest_rtt > 1.5 or waiting_s > 3.0:
		return "weak"
	return "good"


func configured() -> bool:
	return not url.is_empty() and not anon_key.is_empty()


## Register. `role` is "player" or "admin"; the trigger turns the metadata into
## a profiles row. Returns the error message, or "" on success.
##
## With email confirmation on, this returns a user and **no session** -- the
## player confirms first. `_remember()` says so rather than failing silently.
func sign_up(email: String, username: String, password: String, role: String) -> String:
	var body := {
		"email": email.strip_edges().to_lower(),
		"password": password,
		"data": {"username": username.strip_edges(), "role": role},
	}
	return await _finish(await _call(HTTPClient.METHOD_POST, "/auth/v1/signup", body))


## `who` is an email or a username -- the mockups sign in by username, the
## client asked for both. GoTrue only knows emails, so a username is resolved
## through the `email_for_username` function first.
func sign_in(who: String, password: String) -> String:
	var email := who.strip_edges()
	if not email.contains("@"):
		var found := await _email_for(email)
		if found == "":
			# Same words GoTrue uses for a wrong password, on purpose: the form
			# must not become a way to test which usernames exist.
			return "Invalid login credentials"
		email = found
	var body := {"email": email.to_lower(), "password": password}
	return await _finish(await _call(
		HTTPClient.METHOD_POST, "/auth/v1/token?grant_type=password", body))


func _email_for(username: String) -> String:
	var reply := await _call(HTTPClient.METHOD_POST, "/rest/v1/rpc/email_for_username",
		{"uname": username})
	if reply.error != "" or not (reply.data is String):
		return ""
	return reply.data


## Confirm a new account with the code from the sign-up email. Signs them in.
func confirm_sign_up(email: String, code: String) -> String:
	return await _verify(email, code, "signup")


## "Forgot password", step 1: mail a 6-digit code. Always reports success --
## GoTrue will not say whether an address is registered, and neither should the
## form, or it becomes a way to test who has an account.
func send_reset_code(email: String) -> String:
	var reply := await _call(HTTPClient.METHOD_POST, "/auth/v1/recover",
		{"email": email.strip_edges().to_lower()})
	return "" if reply.error == "" or reply.error.begins_with("HTTP 4") else reply.error


## "Forgot password", step 2: the code buys a session, the session sets the
## password. Both halves have to land, or the account is left as it was.
func confirm_reset(email: String, code: String, new_password: String) -> String:
	var err := await _verify(email, code, "recovery")
	if err != "":
		return err
	return await change_password(new_password)


## Needs a live session -- straight after `confirm_reset()`, or while signed in.
func change_password(new_password: String) -> String:
	if access_token.is_empty():
		return "Not signed in."
	var reply := await _call(HTTPClient.METHOD_PUT, "/auth/v1/user",
		{"password": new_password})
	return reply.error


## The movement relay (RelayLink), made on first use like the socket below.
func relay() -> RelayLink:
	if _relay == null or not is_instance_valid(_relay):
		_relay = RelayLink.new()
		_relay.name = "RelayLink"
		add_child(_relay)
	return _relay


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
## install, not an error worth showing anybody.
func restore_session() -> String:
	if signed_in():
		return ""
	var cfg := ConfigFile.new()
	if cfg.load(SESSION_PATH) != OK:
		return "no saved session"
	var saved := str(cfg.get_value("auth", "refresh_token", ""))
	if saved == "":
		return "no saved session"
	return await _finish(await _call(HTTPClient.METHOD_POST,
		"/auth/v1/token?grant_type=refresh_token", {"refresh_token": saved}))


func sign_out() -> void:
	if is_instance_valid(_realtime):
		_realtime.close_socket()
	if is_instance_valid(_relay):
		_relay.leave()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SESSION_PATH))
	refresh_token = ""
	access_token = ""
	user_id = ""
	username = ""
	role = ""


## One PostgREST call. `path` is a table and its query, e.g.
##   await sb.rest(HTTPClient.METHOD_GET, "/rest/v1/team_scores?order=gems.desc")
## The reply is in `.data`; `.error` is "" when it worked.
##
## `prefer` is added to PostgREST's Prefer header -- "resolution=ignore-duplicates"
## turns a POST into insert-if-missing, one round trip instead of look-then-add.
func rest(method: int, path: String, body: Variant = null, prefer := "") -> Dictionary:
	return await _call(method, path, body, true, prefer)


## A PostgREST or auth call made as someone else -- the movement relay
## (RelayServer) checking a student's own token: whatever their row-level
## security lets them see, and nothing of this device's own session.
func rest_as(token: String, method: int, path: String) -> Dictionary:
	return await _call(method, path, null, false, "", token)


func _verify(email: String, code: String, type: String) -> String:
	return await _finish(await _call(HTTPClient.METHOD_POST, "/auth/v1/verify", {
		"type": type,
		"email": email.strip_edges().to_lower(),
		"token": code.strip_edges(),
	}))


## A token is only half a session -- the display name and the role live in
## `profiles`, so every way in loads them before it reports success.
func _finish(reply: Dictionary) -> String:
	var err := _remember(reply)
	if err != "":
		return err
	var got := await rest(HTTPClient.METHOD_GET,
		"/rest/v1/profiles?select=username,role&id=eq." + user_id)
	if got.error != "":
		return got.error
	var rows: Variant = got.data
	if rows is Array and not (rows as Array).is_empty():
		var row: Dictionary = rows[0]
		username = row.get("username", "")
		role = row.get("role", "")
		# Desktop windows run side by side under `--profile`; the title says
		# which account each one is, since the screens all look alike.
		if Game.profile_suffix() != "":
			get_window().title = "NumXventure — %s (%s)" % [username, role]
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


func _call(method: int, path: String, body: Variant, retry := true, prefer := "", as_token := "") -> Dictionary:
	if not configured():
		return {"error": "Supabase is not configured -- see supabase/README.md", "data": null}
	if not is_inside_tree():
		return {"error": "Supabase client is not in the scene tree yet", "data": null}
	var headers := [
		"apikey: " + anon_key,
		"Authorization: Bearer " + (as_token if as_token != "" else access_token if access_token else anon_key),
		"Content-Type: application/json",
		"Prefer: return=representation" + ("," + prefer if prefer != "" else ""),
	]
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
		return {"error": "request failed to start (%d)" % err, "data": null}
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
		return {"error": "No connection", "data": null, "network": true, "maybe_sent": not unsent}
	_rest_failed_at = -1.0
	_rest_rtt = Time.get_unix_time_from_system() - sent
	http_ok += 1
	_learn_clock(res[2], sent)
	var code: int = res[1]
	var text := (res[3] as PackedByteArray).get_string_from_utf8()
	# A function returning nothing (Shuffle) answers 204 with no body at all.
	var parsed: Variant = JSON.parse_string(text) if text.strip_edges() != "" else null
	# An hour into a session the access token expires. Renew once and repeat
	# the call rather than showing a student an error for the clock ticking.
	if code == 401 and retry and refresh_token != "" and not path.begins_with("/auth/v1/token"):
		var renewed: Dictionary = await _call(HTTPClient.METHOD_POST,
			"/auth/v1/token?grant_type=refresh_token", {"refresh_token": refresh_token}, false)
		if renewed.error == "" and renewed.data is Dictionary:
			access_token = (renewed.data as Dictionary).get("access_token", access_token)
			refresh_token = (renewed.data as Dictionary).get("refresh_token", refresh_token)
			_save_session()
			return await _call(method, path, body, false, prefer)

	if code < 200 or code >= 300:
		# GoTrue says `msg`, PostgREST says `message`. Neither is always there.
		var msg := "HTTP %d" % code
		if parsed is Dictionary:
			msg = parsed.get("msg", parsed.get("message", msg))
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
		return "Check your email for the code."
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

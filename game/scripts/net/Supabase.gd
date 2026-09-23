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

var url: String
var anon_key: String
var access_token := ""
var user_id := ""

var _http: HTTPRequest


func _init() -> void:
	url = _conf("SUPABASE_URL", "numxventure/supabase/url").rstrip("/")
	anon_key = _conf("SUPABASE_ANON_KEY", "numxventure/supabase/anon_key")


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)


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
	return _remember(await _call(HTTPClient.METHOD_POST, "/auth/v1/signup", body))


func sign_in(email: String, password: String) -> String:
	var body := {"email": email.strip_edges().to_lower(), "password": password}
	return _remember(await _call(
		HTTPClient.METHOD_POST, "/auth/v1/token?grant_type=password", body))


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


## One PostgREST call. `path` is a table and its query, e.g.
##   await sb.rest(HTTPClient.METHOD_GET, "/rest/v1/team_scores?order=gems.desc")
## The reply is in `.data`; `.error` is "" when it worked.
func rest(method: int, path: String, body: Variant = null) -> Dictionary:
	return await _call(method, path, body)


func _verify(email: String, code: String, type: String) -> String:
	return _remember(await _call(HTTPClient.METHOD_POST, "/auth/v1/verify", {
		"type": type,
		"email": email.strip_edges().to_lower(),
		"token": code.strip_edges(),
	}))


func _call(method: int, path: String, body: Variant) -> Dictionary:
	if not configured():
		return {"error": "Supabase is not configured -- see supabase/README.md", "data": null}
	var headers := [
		"apikey: " + anon_key,
		"Authorization: Bearer " + (access_token if access_token else anon_key),
		"Content-Type: application/json",
		"Prefer: return=representation",
	]
	var payload := "" if body == null else JSON.stringify(body)
	var err := _http.request(url + path, headers, method, payload)
	if err != OK:
		return {"error": "request failed to start (%d)" % err, "data": null}
	var res: Array = await _http.request_completed
	var code: int = res[1]
	var text := (res[3] as PackedByteArray).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
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
		var user: Variant = d.get("user")
		if user is Dictionary:
			user_id = user.get("id", "")
	if access_token.is_empty():
		return "Check your email for the code."
	return ""


func _conf(env: String, setting: String) -> String:
	var v := OS.get_environment(env)
	return v if not v.is_empty() else str(ProjectSettings.get_setting(setting, ""))

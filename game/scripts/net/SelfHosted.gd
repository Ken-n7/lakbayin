extends Supabase

## Local authoritative server. The inherited HTTP/clock helpers use the same
## row envelope; all requests go to this server, with no Supabase dependency.
func _init() -> void:
	url = _conf("LAKBAYIN_SERVER_URL", "lakbayin/server/url").rstrip("/")
	anon_key = "self-hosted"
	SESSION_PATH = "user://selfhost-session%s.cfg" % Game.profile_suffix()


func _ready() -> void:
	pass


func sign_up(_email: String, name: String, password: String, _role: String) -> String:
	return await _finish(await _call(HTTPClient.METHOD_POST, "/auth/register",
		{"username": name.strip_edges(), "password": password}))


func sign_in(who: String, password: String) -> String:
	return await _finish(await _call(HTTPClient.METHOD_POST, "/auth/login",
		{"username": who.strip_edges(), "password": password}))


func restore_session() -> String:
	if signed_in():
		return await _load_profile()
	var cfg := ConfigFile.new()
	if cfg.load(SESSION_PATH) != OK:
		return "no saved session"
	var saved := str(cfg.get_value("auth", "refresh_token", ""))
	if saved == "":
		return "no saved session"
	return await _finish(await _call(HTTPClient.METHOD_POST, "/auth/restore",
		{"refresh_token": saved}, false))


func sign_out() -> void:
	# Capture the token before the synchronous local clear; the request owns
	# its HTTP node and can finish while the next screen is already visible.
	if access_token != "":
		_revoke(access_token)
	super.sign_out()


func _revoke(token: String) -> void:
	await _call(HTTPClient.METHOD_POST, "/auth/logout", {}, false, "", token)


func _call(method: int, path: String, body: Variant, _retry := true, prefer := "", as_token := "", counts := true) -> Dictionary:
	# Opaque sessions expire after 30 days. Never fall through to the old
	# hosted provider's token refresh endpoint on a 401.
	return await super._call(method, path, body, false, prefer, as_token, counts)


func movement_interval() -> float:
	return 0.05

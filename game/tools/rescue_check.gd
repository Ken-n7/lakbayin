extends Node

## Rescue and elimination, against a real project. Two players on one team, a
## third on another, so the refusals can be checked and not just the happy path.
##
##   SUPABASE_URL=... SUPABASE_ANON_KEY=... \
##     godot --headless --path game res://tools/rescue.tscn

var _failures := 0
var _admin := ""
var _session := ""
var _code := ""


func _ready() -> void:
	await get_tree().process_frame
	if not Net.configured():
		print("SKIP  SUPABASE_URL / SUPABASE_ANON_KEY not set")
		get_tree().quit(0)
		return

	var st := str(int(Time.get_unix_time_from_system()))
	_admin = "rs-admin-" + st + "@numxventure-test.dev"
	_check("admin", await Net.sign_up(_admin, "rsa" + st, "letmein123", "admin"))
	var made: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/sessions",
		{"admin_id": Net.user_id, "duration_s": 600})
	_session = str(made.data[0].get("id", "")) if made.data is Array \
		and not (made.data as Array).is_empty() else ""
	_code = str(made.data[0].get("code", "")) if made.data is Array \
		and not (made.data as Array).is_empty() else ""
	_check("session", made.error)
	for t in ["Reds", "Blues"]:
		_check("team " + t, (await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/teams",
			{"session_id": _session, "name": t})).error)

	# Two on Reds, one on Blues.
	var a := await _player("a" + st, "Reds")
	var b := await _player("b" + st, "Reds")
	var c := await _player("c" + st, "Blues")

	# Everyone is in; the teacher starts it. Nobody new may join after this.
	await Net.sign_in(_admin, "letmein123")
	_check("start", (await Net.rest(HTTPClient.METHOD_PATCH, "/rest/v1/sessions?id=eq." + _session,
		{"state": "running", "ends_at": Time.get_datetime_string_from_unix_time(
			int(Time.get_unix_time_from_system()) + 600) + "Z"})).error)
	var late_email := "rs-late" + st + "@numxventure-test.dev"
	await Net.sign_up(late_email, "rslate" + st, "letmein123", "player")
	_check("nobody new joins once it has started",
		"" if (await Teams.enter(_code)).error != "" else "the late join went through")
	var sneak: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/members",
		{"session_id": _session, "profile_id": Net.user_id})
	_check("and the server refuses it too, not just the app",
		"" if sneak.error != "" else "the insert went through")
	await _as(a)
	_check("someone already in gets back in", (await Teams.enter(_code)).error)

	# A sees only their own team, and not themselves.
	await _as(a)
	var mates: Array = await Teams.teammates(_session)
	_check("the list is just your team", "" if mates.size() == 1
		else "offered %d people" % mates.size())
	_check("and not yourself",
		"" if mates.is_empty() or str(mates[0].profile_id) != Net.user_id else "listed you")

	_check("someone on another team is refused",
		"" if (await Scores.rescue(_session, c, 5)).error != "" else "the transfer went through")
	_check("rescuing yourself is refused",
		"" if (await Scores.rescue(_session, a, 5)).error != "" else "the transfer went through")
	_check("giving every gem is refused (you keep 1)",
		"" if (await Scores.rescue(_session, b, 50)).error != "" else "the transfer went through")
	_check("giving 0 is refused",
		"" if (await Scores.rescue(_session, b, 0)).error != "" else "the transfer went through")

	# The rescuer picks the amount (client, 2026-09-27): 15 here.
	var sent: Dictionary = await Scores.rescue(_session, b, 15)
	_check("a team-mate can be rescued with a chosen amount", sent.error)
	_check("the reply is the rescuer's row, 15 lighter",
		"" if int((sent.row as Dictionary).get("gems", 0)) == 35
		else "got %s" % (sent.row as Dictionary).get("gems"))
	var theirs: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/members?select=gems&session_id=eq." + _session + "&profile_id=eq." + b)
	var brow: Dictionary = theirs.data[0] if theirs.data is Array \
		and not (theirs.data as Array).is_empty() else {}
	_check("the teammate gains 15",
		"" if int(brow.get("gems", 0)) == 65 else "got %s" % brow.get("gems"))
	_check("one rescue per player",
		"" if (await Scores.rescue(_session, b, 1)).error != "" else "a second was allowed")

	# Elimination: ten wrong answers from 50 reaches exactly zero.
	await _as(c)
	for i in 10:
		await Scores.apply_answer(_session, false)
	var after: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/members?select=gems,eliminated&session_id=eq." + _session
		+ "&profile_id=eq." + c)
	var crow: Dictionary = after.data[0] if after.data is Array \
		and not (after.data as Array).is_empty() else {}
	_check("gems reach zero", "" if int(crow.get("gems", -1)) == 0
		else "got %s" % crow.get("gems"))
	_check("and that eliminates", "" if bool(crow.get("eliminated", false))
		else "not marked out")

	# Past zero: gems go negative, and the flag does not re-fire.
	await Scores.apply_answer(_session, false)
	var below: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/members?select=gems&session_id=eq." + _session + "&profile_id=eq." + c)
	_check("gems no longer clamp at zero",
		"" if int((below.data[0] as Dictionary).get("gems", 0)) == -5
		else "got %s" % (below.data[0] as Dictionary).get("gems"))

	await _as(a)
	_check("an eliminated player cannot be rescued",
		"" if (await Scores.rescue(_session, c, 1)).error != "" else "the transfer went through")

	await Net.sign_in(_admin, "letmein123")
	await Net.rest(HTTPClient.METHOD_DELETE, "/rest/v1/sessions?id=eq." + _session)
	print("---- RESCUE %s ----" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


## Register a player, join `team`, and hand back their profile id.
func _player(tag: String, team: String) -> String:
	_check("register " + tag, await Net.sign_up(
		"rs-" + tag + "@numxventure-test.dev", "rs" + tag, "letmein123", "player"))
	_check("join " + team, await Teams.join(_code, team))
	return Net.user_id


func _as(profile: String) -> void:
	for tag in ["a", "b", "c"]:
		pass
	# Signing in by profile id is not a thing; the caller passes an id it got
	# from _player, and we look the email back up from the username instead.
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/profiles?select=username&id=eq." + profile)
	var name: String = str((got.data[0] as Dictionary).get("username", "")) \
		if got.data is Array and not (got.data as Array).is_empty() else ""
	await Net.sign_in(name, "letmein123")


func _check(name: String, err: String) -> void:
	if err == "":
		print("  ok    ", name)
	else:
		_failures += 1
		print("  FAIL  ", name, "  ", err)

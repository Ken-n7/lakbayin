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
		{"admin_id": Net.user_id, "duration_s": 600, "state": "running",
		 "ends_at": Time.get_datetime_string_from_unix_time(
			int(Time.get_unix_time_from_system()) + 600) + "Z"})
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

	# A sees only their own team, and not themselves.
	await _as(a)
	var mates: Array = await Teams.teammates(_session)
	_check("the list is just your team", "" if mates.size() == 1
		else "offered %d people" % mates.size())
	_check("and not yourself",
		"" if mates.is_empty() or str(mates[0].profile_id) != Net.user_id else "listed you")

	_check("someone on another team is refused",
		"" if (await Scores.rescue(_session, c)).error != "" else "the transfer went through")
	_check("rescuing yourself is refused",
		"" if (await Scores.rescue(_session, a)).error != "" else "the transfer went through")

	var sent: Dictionary = await Scores.rescue(_session, b)
	_check("a team-mate can be rescued", sent.error)
	_check("the receiver gains 10",
		"" if int((sent.row as Dictionary).get("gems", 0)) == 60
		else "got %s" % (sent.row as Dictionary).get("gems"))
	var mine: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/members?select=gems,rescued_at&session_id=eq." + _session
		+ "&profile_id=eq." + a)
	var row: Dictionary = mine.data[0] if mine.data is Array \
		and not (mine.data as Array).is_empty() else {}
	_check("the sender pays 10",
		"" if int(row.get("gems", 0)) == 40 else "got %s" % row.get("gems"))
	_check("one assist per sender",
		"" if (await Scores.rescue(_session, b)).error != "" else "a second was allowed")

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
		"" if (await Scores.rescue(_session, c)).error != "" else "the transfer went through")

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

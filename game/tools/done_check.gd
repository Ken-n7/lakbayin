extends Node

## Players who are done, and the session ending by itself, against a real
## project. Bot players go through the same server calls the game makes:
##   fast  answers all 14 right, clears the stations, walks into the Gate
##   weak  answers wrong until their gems hit 0 -- eliminated
##   gone  joins and never plays -- a phone that left
## Two sessions: fast + weak (it must end itself once both are done), and
## fast + weak + gone (it must not; gone is DNF when the Quest Keeper ends it).
##
##   godot --headless --path game res://tools/done.tscn

var _failures := 0
var _admin := ""
var _code := ""
var _stamp := ""


func _ready() -> void:
	await get_tree().process_frame
	if not Net.configured():
		print("SKIP  SUPABASE_URL / SUPABASE_ANON_KEY not set")
		get_tree().quit(0)
		return
	_stamp = str(int(Time.get_unix_time_from_system()))
	_admin = "dn-admin-" + _stamp + "@numxventure-test.dev"
	_check("register the Quest Keeper", await Net.sign_up(_admin, "dna" + _stamp, "letmein123", "admin"))

	print("== everyone done: it ends itself ==")
	var s1 := await _session(["fast1", "weak1"])
	await _play_fast("fast1", s1)
	_check("one player done is not everyone", _state_is(await _state(s1), "running"))
	await _play_weak("weak1", s1)
	var row1 := await _state(s1)
	_check("the last one out ends the session", _state_is(row1, "ended"))
	_check("the server stamped when", "" if row1.get("ended_at") != null else "no ended_at")
	var members1 := await _members(s1)
	var History = load("res://scripts/HistoryScreen.gd")
	_check("History calls it Completed",
		"" if History._how_it_ended(row1, members1)[0] == "Completed"
		else "got %s" % History._how_it_ended(row1, members1)[0])

	print("== one who left: it waits, and they are DNF ==")
	var s2 := await _session(["fast2", "weak2", "gone2"])
	await _play_fast("fast2", s2)
	await _play_weak("weak2", s2)
	_check("somebody neither finished nor out keeps it running", _state_is(await _state(s2), "running"))
	await Net.sign_in(_admin, "letmein123")
	_check("the Quest Keeper ends it", (await Net.rest(HTTPClient.METHOD_PATCH,
		"/rest/v1/sessions?id=eq." + s2, {"state": "ended"})).error)
	var Board_ := load("res://scripts/LeaderboardScreen.gd")
	var times := {}
	for r: Dictionary in await Board.players(s2):
		times[str(r.username).trim_prefix("dn")] = Board_._time_of(r)
	print("  times: ", times)
	_check("the finisher has a time",
		"" if str(times.get("fast2" + _stamp, "")).contains(":") else "got %s" % times.get("fast2" + _stamp))
	_check("the eliminated one is Out", "" if times.get("weak2" + _stamp) == "Out" else "got %s" % times.get("weak2" + _stamp))
	_check("the one who left is DNF", "" if times.get("gone2" + _stamp) == "DNF" else "got %s" % times.get("gone2" + _stamp))

	for sid in [s1, s2]:
		await Net.rest(HTTPClient.METHOD_DELETE, "/rest/v1/sessions?id=eq." + sid)
	print("---- DONE %s ----" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(1 if _failures else 0)


## A running session with these players on one team.
func _session(tags: Array) -> String:
	await Net.sign_in(_admin, "letmein123")
	var made: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/sessions",
		{"admin_id": Net.user_id, "duration_s": 600})
	var sid := str(made.data[0].id)
	_code = str(made.data[0].code)
	await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/teams", {"session_id": sid, "name": "Bots"})
	for t: String in tags:
		_check("bot %s joins" % t, await Net.sign_up("dn-%s%s@numxventure-test.dev" % [t, _stamp],
			"dn" + t + _stamp, "letmein123", "player"))
		_check("bot %s picks the team" % t, await Teams.join(_code, "Bots"))
	await Net.sign_in(_admin, "letmein123")
	_check("start", (await Net.rest(HTTPClient.METHOD_PATCH, "/rest/v1/sessions?id=eq." + sid,
		{"state": "running", "ends_at": Time.get_datetime_string_from_unix_time(
			int(Time.get_unix_time_from_system()) + 600) + "Z"})).error)
	return sid


## All right, a station bonus at 8, 11 and 14, then the Gate.
func _play_fast(tag: String, sid: String) -> void:
	await _as(tag)
	for i in Game.TOTAL_ITEMS:
		await Scores.apply_answer(sid, true)
		if i + 1 in [8, 11, 14]:
			await Scores.finish_station(sid, true)
	var done: Dictionary = await Scores.finish_run(sid)
	_check("%s walks into the Gate" % tag, done.error)
	_check("%s gets a time" % tag, "" if done.row.get("finish_s") != null else "no finish_s")


## Wrong until the gems are gone: 50 at 5 a time.
func _play_weak(tag: String, sid: String) -> void:
	await _as(tag)
	var row := {}
	for i in 10:
		row = (await Scores.apply_answer(sid, false)).row
	_check("%s is eliminated at 0" % tag,
		"" if bool(row.get("eliminated", false)) else "row %s" % row)


func _as(tag: String) -> void:
	await Net.sign_in("dn-%s%s@numxventure-test.dev" % [tag, _stamp], "letmein123")


func _state(sid: String) -> Dictionary:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET, "/rest/v1/sessions?select=*&id=eq." + sid)
	return got.data[0] if got.data is Array and not (got.data as Array).is_empty() else {}


func _members(sid: String) -> Array:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/members?select=finished,eliminated&session_id=eq." + sid)
	return got.data if got.data is Array else []


static func _state_is(row: Dictionary, want: String) -> String:
	return "" if str(row.get("state", "")) == want else "state is %s" % row.get("state")


func _check(name: String, err: String) -> void:
	if err == "":
		print("  ok    ", name)
	else:
		_failures += 1
		print("  FAIL  ", name, "  ", err)

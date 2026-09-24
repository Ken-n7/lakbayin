extends Node

## Server-side scoring, against a real project. The two checks that matter are
## the ones that must be REFUSED: a client writing its own gems, and a client
## scoring while the adventure is paused.
##
##   SUPABASE_URL=... SUPABASE_ANON_KEY=... \
##     godot --headless --path game res://tools/scores.tscn

var _failures := 0
var _session := ""
var _admin_email := ""


func _ready() -> void:
	await get_tree().process_frame
	if not Net.configured():
		print("SKIP  SUPABASE_URL / SUPABASE_ANON_KEY not set")
		get_tree().quit(0)
		return

	var stamp := str(int(Time.get_unix_time_from_system()))
	_admin_email = "sc-admin-" + stamp + "@numxventure-test.dev"
	_check("register an admin", await Net.sign_up(_admin_email, "sca" + stamp, "letmein123", "admin"))

	var made: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/sessions",
		{"admin_id": Net.user_id, "duration_s": 600})
	_check("create a session", made.error)
	_session = str(made.data[0].get("id", "")) if made.data is Array \
		and not (made.data as Array).is_empty() else ""
	var code: String = str(made.data[0].get("code", "")) if made.data is Array \
		and not (made.data as Array).is_empty() else ""
	var team: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/teams",
		{"session_id": _session, "name": "Score Test"})
	_check("create a team", team.error)

	var ends := Time.get_datetime_string_from_unix_time(
		int(Time.get_unix_time_from_system()) + 600) + "Z"
	_check("start the game", (await Net.rest(HTTPClient.METHOD_PATCH,
		"/rest/v1/sessions?id=eq." + _session,
		{"state": "running", "ends_at": ends})).error)

	# Now be a student in that session.
	_check("register a player", await Net.sign_up(
		"sc-player-" + stamp + "@numxventure-test.dev", "scp" + stamp, "letmein123", "player"))
	# After Start, which is fine for someone with no team yet.
	_check("join by code and pick the team", await Teams.join(code, "Score Test"))

	# 50 to start, per SPECS §4.
	_check("a correct answer pays +10", _gems(await Scores.apply_answer(_session, true), 60))
	_check("a wrong answer costs -5", _gems(await Scores.apply_answer(_session, false), 55))
	_check("a hint costs -5", _gems(await Scores.spend_hint(_session), 50))
	_check("a skip costs -15", _gems(await Scores.skip_item(_session), 35))
	# The bonus is paid once per station, and only after its last item -- a
	# client asking early, or twice, used to get +10 each time.
	_check("a station bonus before its last item is refused",
		"" if (await Scores.finish_station(_session, true)).error != "" else "it was paid")
	for i in 5:     # items 4..8 finish station 1 (8 items)
		await Scores.apply_answer(_session, true)
	_check("a perfect station pays +10", _gems(await Scores.finish_station(_session, true), 95))
	_check("the same station cannot pay twice",
		"" if (await Scores.finish_station(_session, true)).error != "" else "it paid again")

	var counted: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/members?select=correct,items_done&session_id=eq." + _session)
	var row: Dictionary = counted.data[0] if counted.data is Array \
		and not (counted.data as Array).is_empty() else {}
	_check("correct answers are counted",
		"" if int(row.get("correct", -1)) == 6 else "got %s" % row.get("correct"))
	_check("items done counts answers and skips, not hints",
		"" if int(row.get("items_done", -1)) == 8 else "got %s" % row.get("items_done"))

	# The point of the whole slice.
	var cheat: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
		"/rest/v1/members?session_id=eq." + _session, {"gems": 9999})
	_check("a client cannot write its own gems",
		"" if cheat.error != "" else "the write was ALLOWED")
	var after: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/members?select=gems&session_id=eq." + _session)
	var still: Dictionary = after.data[0] if after.data is Array \
		and not (after.data as Array).is_empty() else {}
	_check("and the score is untouched",
		"" if int(still.get("gems", -1)) == 95 else "gems became %s" % still.get("gems"))

	# Scoring while the teacher has everyone paused.
	await Net.sign_in(_admin_email, "letmein123")
	_check("admin pauses", (await Net.rest(HTTPClient.METHOD_PATCH,
		"/rest/v1/sessions?id=eq." + _session,
		{"state": "paused", "remaining_s": 60})).error)
	await Net.sign_in("sc-player-" + stamp + "@numxventure-test.dev", "letmein123")
	var while_paused: Dictionary = await Scores.apply_answer(_session, true)
	_check("no scoring while paused",
		"" if while_paused.error != "" else "the answer was accepted")

	# --- The board a teacher reads ----------------------------------------
	await Net.sign_in(_admin_email, "letmein123")
	var teams: Array = await Board.teams(_session)
	_check("the team board has the team",
		"" if teams.size() == 1 and str(teams[0].get("name", "")) == "Score Test"
		else "got %s" % str(teams))
	_check("team gems are the sum of its members",
		"" if int(teams[0].get("gems", -1)) == 95 else "got %s" % teams[0].get("gems"))

	var players: Array = await Board.players(_session)
	_check("the player board has the player", "" if players.size() == 1
		else "got %d rows" % players.size())
	_check("it carries correct responses",
		"" if int(players[0].correct) == 6 else "got %s" % players[0].correct)
	# The number a spectating teacher actually reads.
	_check("it knows how long they have been idle",
		"" if int(players[0].idle_s) >= 0 and int(players[0].idle_s) < 600
		else "idle_s was %s" % players[0].idle_s)

	# The team penalties live in `team_scores`: once the run is over, a member
	# short of all 14 items costs the team 25.
	await Net.rest(HTTPClient.METHOD_PATCH, "/rest/v1/sessions?id=eq." + _session,
		{"state": "ended"})
	var ended: Array = await Board.teams(_session)
	_check("an unfinished member costs the team 25 once it ends",
		"" if not ended.is_empty() and int(ended[0].get("gems", -1)) == 70
		else "got %s" % str(ended))

	await Net.rest(HTTPClient.METHOD_DELETE, "/rest/v1/sessions?id=eq." + _session)
	print("---- SCORES %s ----" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


func _gems(reply: Dictionary, want: int) -> String:
	if reply.error != "":
		return reply.error
	var got: int = int((reply.row as Dictionary).get("gems", -1))
	return "" if got == want else "expected %d gems, got %d" % [want, got]


func _check(name: String, err: String) -> void:
	if err == "":
		print("  ok    ", name)
	else:
		_failures += 1
		print("  FAIL  ", name, "  ", err)

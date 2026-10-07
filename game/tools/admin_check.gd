extends Node

## The admin half, against a real project: the question bank's CRUD, what Set
## does, the shortfall rule that Start Game leans on, and the seed button.
##
##   SUPABASE_URL=... SUPABASE_ANON_KEY=... \
##     godot --headless --path game res://tools/admin.tscn
##
## Registers a throwaway admin and cleans up every row it writes -- a bank left
## full of test questions would be worse than useless to the teacher.

var _failures := 0
var _made: Array[String] = []
var _sessions: Array[String] = []
var _admin_email := ""


func _ready() -> void:
	await get_tree().process_frame
	if not Net.configured():
		print("SKIP  SUPABASE_URL / SUPABASE_ANON_KEY not set")
		get_tree().quit(0)
		return

	var stamp := str(int(Time.get_unix_time_from_system()))
	_admin_email = "admin-" + stamp + "@numxventure-test.dev"
	# Anyone may register as an admin, no approval -- SPECS §2, client's rule.
	_check("register an admin", await Net.sign_up(
		_admin_email, "ad" + stamp, "letmein123", "admin"))
	_check("role really is admin", "" if Net.role == "admin" else "got '%s'" % Net.role)

	# A question the teacher authored.
	var added: Dictionary = await QuestionStore.add(2, "7 + (-9)", "-2", "Different signs: subtract.")
	_check("add a question", added.error)
	var id: String = str(added.rows[0].get("id", "")) if not added.rows.is_empty() else ""
	_made.append(id)
	_check("new questions start inactive",
		"" if added.rows[0].get("active") == true else "active was %s" % added.rows[0].get("active"))

	_check("Set marks it active", (await QuestionStore.set_active(id, true)).error)
	var back: Dictionary = await QuestionStore.fetch(2)
	_check("fetch sees the question", back.error)
	_check("edit changes the prompt",
		(await QuestionStore.edit(id, {"prompt": "7 + (-9) ="})).error)

	# Feedback lives on the row, which is what makes delete clear it too.
	_check("feedback saves", (await QuestionStore.edit(id, {"feedback": "Keep the bigger sign."})).error)
	var with_fb: Dictionary = await QuestionStore.fetch(2)
	var found := {}
	for row: Dictionary in with_fb.rows:
		if str(row.get("id", "")) == id:
			found = row
	_check("feedback round-trips",
		"" if found.get("feedback", "") == "Keep the bigger sign." else "got '%s'" % found.get("feedback", ""))
	_check("edit kept the prompt",
		"" if found.get("prompt", "") == "7 + (-9) =" else "got '%s'" % found.get("prompt", ""))

	# The rule Start Game leans on. Checked against what the bank actually
	# holds rather than against an assumption that it is empty -- this runs on
	# a teacher's real project, which may be fully stocked.
	var counts: Dictionary = await QuestionStore.active_counts()
	var short: String = await QuestionStore.shortfall()
	var lacking: Array[String] = []
	for st in [1, 2, 3]:
		if int(counts.get(st, 0)) < Game.ITEMS_PER_STATION[st - 1]:
			lacking.append("Station %d" % st)
	if lacking.is_empty():
		_check("a full bank reports no shortfall",
			"" if short == "" else "said '%s' with %s active" % [short, str(counts)])
	else:
		_check("a short bank is reported", "" if short != "" else "shortfall said nothing")
		_check("it names the station that is short",
			"" if short.contains(lacking[0]) else "got '%s', expected %s" % [short, lacking[0]])

	# Over the 300-character limit the column refuses, which is what the
	# feedback screen's live trim exists to avoid.
	var too_long: Dictionary = await QuestionStore.edit(id, {"feedback": "x".repeat(301)})
	_check("301 characters of feedback is refused",
		"" if too_long.error != "" else "the database took it")

	_check("delete removes it", (await QuestionStore.remove(id)).error)
	_made.erase(id)
	var after: Dictionary = await QuestionStore.fetch(2)
	var still := false
	for row: Dictionary in after.rows:
		if str(row.get("id", "")) == id:
			still = true
	_check("deleted question is gone", "" if not still else "still in the bank")

	# The loop that matters: what the teacher authored is what a player is
	# asked. Station 2 takes three items, so three questions is a full station.
	var authored: Array[String] = []
	for i in 3:
		var q: Dictionary = await QuestionStore.add(2, "auth-%d + 1" % i, str(i + 1),
			"hint %d" % i)
		_check("author item %d" % i, q.error)
		if not q.rows.is_empty():
			var qid: String = str(q.rows[0].get("id", ""))
			authored.append(qid)
			_made.append(qid)
	_check("feedback on the first one",
		(await QuestionStore.edit(authored[0], {"feedback": "Remember the rule."})).error)

	_check("bank loads", await QuestionStore.load_bank())
	# Found by id, not by position: the station already holds the teacher's own
	# questions, and ordering by authoring time puts those first. Asserting on
	# index 0 was asserting on somebody else's row.
	var mine := -1
	for i in (QuestionStore.bank.get(1, []) as Array).size():
		if str((QuestionStore.bank[1][i] as Dictionary).get("id", "")) == authored[0]:
			mine = i
	_check("the authored question is in the pool",
		"" if mine >= 0 else "not found among %d" % (QuestionStore.bank.get(1, []) as Array).size())
	var first: Dictionary = QuestionStore.item_for(1, maxi(mine, 0))
	_check("player is asked the authored question",
		"" if first.get("prompt", "") == "auth-0 + 1" else "got '%s'" % first.get("prompt", ""))
	_check("authored answer comes with it",
		"" if str(first.get("answer", "")) == "1" else "got '%s'" % first.get("answer", ""))
	_check("authored hint comes with it",
		"" if first.get("hint", "") == "hint 0" else "got '%s'" % first.get("hint", ""))
	# The Feedback screen exists to write the wrong-answer rule reminder.
	_check("admin feedback becomes the rule reminder",
		"" if first.get("rule", "") == "Remember the rule." else "got '%s'" % first.get("rule", ""))
	# No feedback authored on the second, so it falls back to the hint rather
	# than showing the player an empty box.
	var second_at := -1
	for j in (QuestionStore.bank.get(1, []) as Array).size():
		if str((QuestionStore.bank[1][j] as Dictionary).get("id", "")) == authored[1]:
			second_at = j
	var second: Dictionary = QuestionStore.item_for(1, maxi(second_at, 0))
	_check("no feedback falls back to the hint",
		"" if second.get("rule", "") == "hint 1" else "got '%s'" % second.get("rule", ""))

	# An unset question is not in the pool, however many are authored.
	_check("unset it", (await QuestionStore.set_active(authored[2], false)).error)
	_check("reload", await QuestionStore.load_bank())
	var still_in := 0
	for q: Dictionary in QuestionStore.bank.get(1, []):
		if authored.has(str(q.get("id", ""))):
			still_in += 1
	_check("an unset question leaves the pool",
		"" if still_in == 2 else "%d of this run's 3 still in the pool" % still_in)

	# --- Joining by code, then picking a team -------------------------------
	# Still signed in as the admin: a session (it gets its code from the
	# database) and two teams.
	var made: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/sessions",
		{"admin_id": Net.user_id, "duration_s": 600})
	_check("admin creates a session", made.error)
	var row: Dictionary = made.data[0] if made.data is Array \
		and not (made.data as Array).is_empty() else {}
	var sid: String = str(row.get("id", ""))
	var code: String = str(row.get("code", ""))
	_sessions.append(sid)
	_check("the session has a four-character code",
		"" if code.length() == 4 else "got '%s'" % code)
	# Only what the game's font keeps apart -- a stale session_code() in the
	# database (schema.sql not re-run) is caught here.
	_check("it is made only of characters the font keeps apart",
		"" if Teams.bad_chars(code) == "" and Teams.clean_code(code) == code
		else "got '%s' -- re-run supabase/schema.sql" % code)

	var team_ids := {}
	for tname in ["Math Mavericks", "Number Ninjas"]:
		var t: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/teams",
			{"session_id": sid, "name": tname})
		_check("admin adds team %s" % tname, t.error)
		if t.data is Array and not (t.data as Array).is_empty():
			team_ids[tname] = str(t.data[0].get("id", ""))

	# Now be a student.
	var pstamp := stamp + "p"
	var player_email := "player-" + pstamp + "@numxventure-test.dev"
	_check("register a player", await Net.sign_up(
		player_email, "pl" + pstamp, "letmein123", "player"))

	# "0" is never in a code, so this one can never be real.
	_check("a code nobody was given is refused",
		"" if (await Teams.enter("Z0ZZ")).error != "" else "the join was allowed")
	_check("the code gets you in", (await Teams.enter(code)).error)
	var roster: Dictionary = await Teams.roster(sid)
	_check("in the session with no team yet",
		"" if (roster.get("", []) as Array).size() == 1 else "got %s" % str(roster))
	# Typed as the student would, not as the teacher read it out.
	_check("the code is not case-sensitive", (await Teams.enter(code.to_lower())).error)
	_check("pick a team", await Teams.pick(sid, team_ids.get("Math Mavericks", "")))
	_check("switch before Start", await Teams.pick(sid, team_ids.get("Number Ninjas", "")))
	var after_switch: Dictionary = await Teams.roster(sid)
	var total := 0
	for team_id: String in after_switch:
		total += (after_switch[team_id] as Array).size()
	_check("still one membership after switching",
		"" if total == 1 else "roster held %d" % total)
	_check("the roster names the player", "" if str(after_switch.get(
		team_ids.get("Number Ninjas", ""), [{}])[0].get("username", "")).begins_with("pl")
		else "got %s" % str(after_switch))

	# The teacher's tools, then Start, which locks the teams.
	await Net.sign_in(_admin_email, "letmein123")
	var shuffled: Dictionary = await Net.rest(HTTPClient.METHOD_POST,
		"/rest/v1/rpc/shuffle_teams", {"p_session": sid})
	_check("the teacher can shuffle before Start", shuffled.error)
	_check("the teacher can move a player before Start", (await Net.rest(
		HTTPClient.METHOD_PATCH, "/rest/v1/members?session_id=eq." + sid
		+ "&profile_id=neq." + Net.user_id, {"team_id": team_ids.get("Math Mavericks", "")})).error)
	_check("start the game", (await Net.rest(HTTPClient.METHOD_PATCH,
		"/rest/v1/sessions?id=eq." + sid, {"state": "running", "ends_at":
		Time.get_datetime_string_from_unix_time(int(Time.get_unix_time_from_system()) + 600)
		+ "Z"})).error)
	var late: Dictionary = await Net.rest(HTTPClient.METHOD_POST,
		"/rest/v1/rpc/shuffle_teams", {"p_session": sid})
	_check("no shuffle once it has started",
		"" if late.error != "" else "the shuffle went through")

	await Net.sign_in(player_email, "letmein123")
	_check("no switching once it has started",
		"" if (await Teams.pick(sid, team_ids.get("Number Ninjas", ""))) != ""
		else "the switch went through")

	# Removing a team leaves its players in the session, teamless.
	await Net.sign_in(_admin_email, "letmein123")
	await Net.rest(HTTPClient.METHOD_DELETE,
		"/rest/v1/teams?id=eq." + str(team_ids.get("Math Mavericks", "")))
	var orphans: Dictionary = await Teams.roster(sid)
	_check("a removed team's player stays in, with no team",
		"" if (orphans.get("", []) as Array).size() == 1 else "got %s" % str(orphans))
	await Net.sign_in(player_email, "letmein123")
	_check("and may pick again, even after Start",
		await Teams.pick(sid, team_ids.get("Number Ninjas", "")))
	await Net.sign_in(_admin_email, "letmein123")

	# --- A dead session's code opens nothing ---------------------------------
	var dead: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/sessions",
		{"admin_id": Net.user_id, "duration_s": 600, "state": "ended"})
	_check("an ended session exists", dead.error)
	var dead_row: Dictionary = dead.data[0] if dead.data is Array \
		and not (dead.data as Array).is_empty() else {}
	_sessions.append(str(dead_row.get("id", "")))
	_check("an ended session's code is refused",
		"" if (await Teams.find(str(dead_row.get("code", "")))).error != ""
		else "the dead session was handed out")

	# And one whose deadline has passed is over whatever its state says.
	var stale: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/sessions",
		{"admin_id": Net.user_id, "duration_s": 600, "state": "running",
		 "ends_at": Time.get_datetime_string_from_unix_time(
			int(Time.get_unix_time_from_system()) - 60) + "Z"})
	_check("a stale running session exists", stale.error)
	var stale_row: Dictionary = stale.data[0] if stale.data is Array \
		and not (stale.data as Array).is_empty() else {}
	_sessions.append(str(stale_row.get("id", "")))
	_check("a passed deadline's code is refused",
		"" if (await Teams.find(str(stale_row.get("code", "")))).error != ""
		else "the expired run was handed out")
	_check("Teams.expired() spots it",
		"" if Teams.expired(stale_row) else "a passed deadline read as live")

	# --- Codes as students really type them --------------------------------
	var spaced := " " + code.left(2).to_lower() + "-" + code.substr(2) + " "
	_check("spaces, dashes and small letters still find it",
		"" if str((await Teams.find(spaced)).session.get("id", "")) == sid else "not found: '%s'" % spaced)
	var looks: String = (await Teams.find("O0I1")).error
	_check("look-alike characters are named, not searched for",
		"" if looks.contains("never use") and looks.contains("O") else looks)
	var gone: String = (await Teams.find(str(dead_row.get("code", "")))).error
	_check("an ended code says it has ended", "" if gone.contains("has ended") else gone)
	var nobody: String = (await Teams.find("ZZZ9")).error
	_check("an unknown code says so", "" if nobody.contains("No adventure with the code") else nobody)

	# --- Start Session twice keeps the code; a code killed elsewhere is said -
	await Net.sign_in(_admin_email, "letmein123")
	await Net.rest(HTTPClient.METHOD_PATCH, "/rest/v1/sessions?admin_id=eq." + Net.user_id
		+ "&state=neq.ended", {"state": "ended"})
	var screen_a := await _controls()
	var screen_b := await _controls()
	var code_a := str(screen_a._session.get("code", ""))
	_sessions.append(str(screen_a._session.get("id", "")))
	_sessions.append(str(screen_b._session.get("id", "")))
	_check("Start Session makes a session", "" if code_a.length() == 4 else "no code")
	_check("Start Session again (a second window) keeps the same code",
		"" if str(screen_b._session.get("code", "")) == code_a
		else "%s then %s -- the first code died" % [code_a, screen_b._session.get("code", "")])
	# Ended behind both screens' backs: both must say the code is dead. Not
	# before their stream is live -- a change made between the join and
	# "subscribed" is never delivered (see realtime_check.gd), so ending it the
	# moment the screens had a code failed every run.
	for _i in 60:
		if Net.realtime().live:
			break
		await get_tree().create_timer(0.25).timeout
	await Net.rest(HTTPClient.METHOD_PATCH, "/rest/v1/sessions?id=eq." + str(screen_a._session.get("id", "")),
		{"state": "ended"})
	var shown := false
	for _i in 40:
		await get_tree().create_timer(0.25).timeout
		shown = _says(screen_a, "This code no longer works") and _says(screen_b, "This code no longer works")
		if shown:
			break
	_check("a code ended elsewhere is announced on every screen showing it",
		"" if shown else "the screens still show a dead code")
	# A screen ending its own session is not told it was ended elsewhere.
	var screen_own := await _controls()
	_sessions.append(str(screen_own._session.get("id", "")))
	await screen_own._set_state("ended", false)
	await get_tree().create_timer(3.0).timeout
	_check("ending your own session is not reported as lost",
		"" if not _says(screen_own, "This code no longer works") else "false alarm")
	for gc in [screen_a, screen_b, screen_own]:
		gc.queue_free()

	await _cleanup()
	print("---- ADMIN %s ----" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


## Signs back in as the admin first. The last half of this check runs as a
## student, and a student may not delete questions or sessions -- RLS refused
## every delete silently and the test rows stayed in the teacher's bank.
func _cleanup() -> void:
	if _admin_email != "":
		await Net.sign_in(_admin_email, "letmein123")
	for id in _made:
		await QuestionStore.remove(id)
	# Deleting the session cascades its teams and members away with it.
	for sid in _sessions:
		await Net.rest(HTTPClient.METHOD_DELETE, "/rest/v1/sessions?id=eq." + sid)


## Game Controls as the dashboard's Start Session opens it, once it has a code.
func _controls() -> Control:
	var gc: Control = load("res://scripts/GameControlsScreen.gd").new()
	add_child(gc)
	gc.setup({"new": true})
	for _i in 60:
		await get_tree().create_timer(0.1).timeout
		if str(gc.get("_session").get("code", "")) != "" and not gc.get("_making"):
			break
	return gc


func _says(root: Node, text: String) -> bool:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text.contains(text):
			return true
	return false


func _check(name: String, err: String) -> void:
	if err == "":
		print("  ok    ", name)
	else:
		_failures += 1
		print("  FAIL  ", name, "  ", err)

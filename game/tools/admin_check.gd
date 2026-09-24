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

	# --- Joining a team, the way a student does ---------------------------
	# Still signed in as the admin: make a session and two teams.
	var made: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/sessions",
		{"admin_id": Net.user_id, "duration_s": 600})
	_check("admin creates a session", made.error)
	var sid: String = str(made.data[0].get("id", "")) if made.data is Array \
		and not (made.data as Array).is_empty() else ""
	_sessions.append(sid)

	for tname in ["Math Mavericks", "Number Ninjas"]:
		var t: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/teams",
			{"session_id": sid, "name": tname})
		_check("admin adds team %s" % tname, t.error)

	# Now be a student.
	var pstamp := stamp + "p"
	_check("register a player", await Net.sign_up(
		"player-" + pstamp + "@numxventure-test.dev", "pl" + pstamp, "letmein123", "player"))

	_check("a name nobody was given is refused",
		"" if (await Teams.join("Not A Team")) != "" else "the join was allowed")
	_check("the team name joins", await Teams.join("Math Mavericks"))
	# Typed as the student would, not as the teacher wrote it.
	_check("joining is not case-sensitive", await Teams.join("math mavericks"))

	var roster: Dictionary = await Teams.roster(sid)
	var total := 0
	for team_id: String in roster:
		total += (roster[team_id] as Array).size()
	_check("roster shows one member, not two",
		"" if total == 1 else "roster held %d" % total)
	_check("roster names the player",
		"" if str(roster.values()[0][0]).begins_with("pl") else "got %s" % str(roster.values()))

	# Switching teams moves the membership rather than adding a second.
	_check("switch team", await Teams.join("Number Ninjas"))
	var after_switch: Dictionary = await Teams.roster(sid)
	var total2 := 0
	for team_id2: String in after_switch:
		total2 += (after_switch[team_id2] as Array).size()
	_check("still one membership after switching",
		"" if total2 == 1 else "roster held %d" % total2)

	# --- A dead session is not the one to work in ---------------------------
	# The teacher's screen used to adopt the newest session whatever its
	# state, so after a run ended it showed that run's teams and added to it.
	await Net.sign_in(_admin_email, "letmein123")
	var dead: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/sessions",
		{"admin_id": Net.user_id, "duration_s": 600, "state": "ended"})
	_check("an ended session exists", dead.error)
	if dead.data is Array and not (dead.data as Array).is_empty():
		_sessions.append(str(dead.data[0].get("id", "")))
	# There IS a live session from the join tests above, so the question is
	# not whether one comes back -- it is whether the dead one does.
	var dead_id: String = str(dead.data[0].get("id", "")) if dead.data is Array \
		and not (dead.data as Array).is_empty() else ""
	var offered: Dictionary = await Teams.live_session()
	_check("an ended session is not offered to a joiner",
		"" if str(offered.session.get("id", "")) != dead_id
		else "the dead session was handed out")

	# And one whose deadline has passed is over whatever its state says.
	var stale: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/sessions",
		{"admin_id": Net.user_id, "duration_s": 600, "state": "running",
		 "ends_at": Time.get_datetime_string_from_unix_time(
			int(Time.get_unix_time_from_system()) - 60) + "Z"})
	_check("a stale running session exists", stale.error)
	if stale.data is Array and not (stale.data as Array).is_empty():
		_sessions.append(str(stale.data[0].get("id", "")))
	var stale_id: String = str(stale.data[0].get("id", "")) if stale.data is Array \
		and not (stale.data as Array).is_empty() else ""
	var offered2: Dictionary = await Teams.live_session()
	_check("a passed deadline counts as over",
		"" if str(offered2.session.get("id", "")) != stale_id
		else "the expired run was handed out")
	_check("Teams.expired() spots it",
		"" if Teams.expired(stale.data[0]) else "an hour-old deadline read as live")

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


func _check(name: String, err: String) -> void:
	if err == "":
		print("  ok    ", name)
	else:
		_failures += 1
		print("  FAIL  ", name, "  ", err)

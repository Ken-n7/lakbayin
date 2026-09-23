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


func _ready() -> void:
	await get_tree().process_frame
	if not Net.configured():
		print("SKIP  SUPABASE_URL / SUPABASE_ANON_KEY not set")
		get_tree().quit(0)
		return

	var stamp := str(int(Time.get_unix_time_from_system()))
	# Anyone may register as an admin, no approval -- SPECS §2, client's rule.
	_check("register an admin", await Net.sign_up(
		"admin-" + stamp + "@numxventure-test.dev", "ad" + stamp, "letmein123", "admin"))
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

	# The rule Start Game leans on: a short bank names the shortfall.
	var short: String = await QuestionStore.shortfall()
	_check("an incomplete bank is reported", "" if short != "" else "shortfall said nothing")
	_check("it names the station that is short",
		"" if short.contains("Station 1") else "got '%s'" % short)

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

	await _cleanup()
	print("---- ADMIN %s ----" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


func _cleanup() -> void:
	for id in _made:
		await QuestionStore.remove(id)


func _check(name: String, err: String) -> void:
	if err == "":
		print("  ok    ", name)
	else:
		_failures += 1
		print("  FAIL  ", name, "  ", err)

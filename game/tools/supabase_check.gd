extends SceneTree

## Does `Supabase.gd` actually talk to a real project? Needs the network and
## the two env vars, so it is not in `run_tests.sh` -- an offline machine would
## fail a suite for no reason. Run it by hand when the backend changes:
##
##   SUPABASE_URL=... SUPABASE_ANON_KEY=... \
##     godot --headless --path game --script res://tools/supabase_check.gd
##
## It registers a throwaway account each run. Delete them in the dashboard
## under Authentication -> Users.

var _failures := 0


func _initialize() -> void:
	var sb: Node = load("res://scripts/net/Supabase.gd").new()
	root.add_child(sb)
	await process_frame  # `root` itself is not in the tree until the first frame

	if not sb.configured():
		print("SKIP  SUPABASE_URL / SUPABASE_ANON_KEY not set")
		quit(0)
		return

	# A fresh name each run: the trigger suffixes a duplicate rather than
	# failing, so a fixed name would fail the round-trip check on run two.
	var stamp := str(int(Time.get_unix_time_from_system()))
	var uname := "cc" + stamp
	var email := "client-" + stamp + "@numxventure-test.dev"
	_check("sign_up", await sb.sign_up(email, uname, "letmein123", "player"))
	_check("token kept", "" if sb.access_token != "" else "no access_token")
	_check("user id kept", "" if sb.user_id != "" else "no user id")

	# The profile the trigger made, read back through the same client.
	var reply: Dictionary = await sb.rest(
		HTTPClient.METHOD_GET, "/rest/v1/profiles?select=username,role&id=eq." + sb.user_id)
	_check("profile readable", reply.error)
	var rows: Variant = reply.data
	var row: Dictionary = rows[0] if rows is Array and not (rows as Array).is_empty() else {}
	_check("username round-trips", "" if row.get("username") == uname
		else "got %s" % row.get("username", "<nothing>"))
	_check("role defaults to player", "" if row.get("role") == "player"
		else "got %s" % row.get("role", "<nothing>"))

	# A fresh client, signing in with the password just registered.
	var sb2: Node = load("res://scripts/net/Supabase.gd").new()
	root.add_child(sb2)
	await process_frame
	_check("sign_in", await sb2.sign_in(email, "letmein123"))

	# RLS from the client's side: a player may not write the question bank.
	var denied: Dictionary = await sb2.rest(HTTPClient.METHOD_POST, "/rest/v1/questions",
		{"station": 1, "prompt": "nope", "answer": "1"})
	_check("player cannot write questions", "" if denied.error != "" else "the insert was ALLOWED")

	print("---- SUPABASE %s ----" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures > 0 else 0)


func _check(name: String, err: String) -> void:
	if err == "":
		print("  ok    ", name)
	else:
		_failures += 1
		print("  FAIL  ", name, "  ", err)

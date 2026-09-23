extends Node

## Does the realtime socket actually deliver? Signs in, watches `sessions`,
## changes one over REST, and waits for the change to come back the other way.
##
##   SUPABASE_URL=... SUPABASE_ANON_KEY=... \
##     godot --headless --path game res://tools/realtime.tscn
##
## Network only, so not in run_tests.sh. Cleans up the session it makes.

const WAIT_S := 12.0

var _failures := 0
var _got: Array[Dictionary] = []


func _ready() -> void:
	await get_tree().process_frame
	if not Net.configured():
		print("SKIP  SUPABASE_URL / SUPABASE_ANON_KEY not set")
		get_tree().quit(0)
		return

	var stamp := str(int(Time.get_unix_time_from_system()))
	_check("sign in as an admin", await Net.sign_up(
		"rt-" + stamp + "@numxventure-test.dev", "rt" + stamp, "letmein123", "admin"))

	var made: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/sessions",
		{"admin_id": Net.user_id, "duration_s": 600})
	_check("create a session", made.error)
	var sid: String = str(made.data[0].get("id", "")) if made.data is Array \
		and not (made.data as Array).is_empty() else ""

	var rt: Realtime = Net.realtime()
	rt.changed.connect(func(table: String, type: String, record: Dictionary) -> void:
		_got.append({"table": table, "type": type, "record": record}))
	rt.watch("sessions", "id=eq." + sid)

	_check("socket opens", "" if await _until(func() -> bool: return rt.is_open())
		else "never reached STATE_OPEN in %ds" % int(WAIT_S))

	# Not a sleep: the join being accepted is not the stream being live, and a
	# change made in between is never delivered. A 2s sleep here passed and
	# failed at random until this waited for the right thing.
	_check("the stream goes live", "" if await _until(func() -> bool: return rt.live)
		else "never subscribed to postgres_changes in %ds" % int(WAIT_S))

	var patched: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
		"/rest/v1/sessions?id=eq." + sid, {"state": "running"})
	_check("change the row over REST", patched.error)

	_check("the change arrives over the socket",
		"" if await _until(func() -> bool: return not _got.is_empty())
		else "nothing delivered in %ds" % int(WAIT_S))

	if not _got.is_empty():
		var first: Dictionary = _got[0]
		_check("it names the table",
			"" if first.table == "sessions" else "got '%s'" % first.table)
		_check("it is an UPDATE",
			"" if first.type == "UPDATE" else "got '%s'" % first.type)
		_check("it carries the new state",
			"" if str((first.record as Dictionary).get("state", "")) == "running"
			else "got '%s'" % str((first.record as Dictionary).get("state", "")))

	rt.close_socket()
	await Net.rest(HTTPClient.METHOD_DELETE, "/rest/v1/sessions?id=eq." + sid)
	print("---- REALTIME %s ----" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


## Polls `cond` until it holds or WAIT_S passes. Returns whether it held.
func _until(cond: Callable) -> bool:
	var waited := 0.0
	while waited < WAIT_S:
		if cond.call():
			return true
		await get_tree().process_frame
		waited += get_process_delta_time()
	return cond.call()


func _check(name: String, err: String) -> void:
	if err == "":
		print("  ok    ", name)
	else:
		_failures += 1
		print("  FAIL  ", name, "  ", err)

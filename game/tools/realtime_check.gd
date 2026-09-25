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

	# --- The clock a player would read -------------------------------------
	# Start / pause / resume, applied through Game the way a phone does it.
	var ends := Time.get_datetime_string_from_unix_time(
		int(Time.get_unix_time_from_system()) + 300) + "Z"
	var started: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
		"/rest/v1/sessions?id=eq." + sid,
		{"state": "running", "ends_at": ends, "remaining_s": null})
	_check("admin starts the game", started.error)
	Game.apply_session(started.data[0] if started.data is Array \
		and not (started.data as Array).is_empty() else {})
	_check("the clock is running", "" if not Game.clock_paused else "still paused")
	_check("it reads the deadline, not the duration",
		"" if absf(Game.time_left - 300.0) < 5.0 else "%f left" % Game.time_left)

	var paused: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
		"/rest/v1/sessions?id=eq." + sid, {"state": "paused", "remaining_s": 111})
	_check("admin pauses", paused.error)
	Game.apply_session(paused.data[0] if paused.data is Array \
		and not (paused.data as Array).is_empty() else {})
	_check("pause stops the clock", "" if Game.clock_paused else "still running")
	_check("pause hands back what it banked",
		"" if is_equal_approx(Game.time_left, 111.0) else "%f left" % Game.time_left)

	# --- Positions: one phone's hero, on another phone's board --------------
	# A second socket stands in for the second phone. Broadcast is not the
	# database: nothing is written, the message goes socket to socket.
	var other := Realtime.new()
	add_child(other)
	var heard: Array = []
	# Only this run's: every session shares the one topic, so a real game
	# open at the same time is heard too -- the map filters by `sid` as well.
	other.broadcast.connect(func(event: String, data: Dictionary) -> void:
		if str(data.get("sid", "")) == sid:
			heard.append({"event": event, "data": data}))
	other.watch("sessions", "id=eq." + sid)
	_check("a second socket goes live", "" if await _until(func() -> bool: return other.live)
		else "never subscribed in %ds" % int(WAIT_S))
	rt.send_broadcast("pos", {"sid": sid, "id": "hero-a", "x": 120.5, "y": 64.0})
	_check("a position reaches the other socket",
		"" if await _until(func() -> bool: return not heard.is_empty())
		else "nothing heard in %ds" % int(WAIT_S))
	if not heard.is_empty():
		_check("it carries where the hero is",
			"" if heard[0].event == "pos" and is_equal_approx(float(heard[0].data.get("x", 0)), 120.5)
			else "got %s" % str(heard[0]))

	# --- Presence: who is here ----------------------------------------------
	# The second socket announces itself; the first sees it, then sees it go
	# when that socket closes -- nobody has to notice a phone leave.
	other.track({"sid": sid, "where": "lobby", "name": "rt-check"})
	_check("a tracked phone shows as here",
		"" if await _until(func() -> bool: return rt.where_is(Net.user_id, sid) == "lobby")
		else "never appeared in %ds: %s" % [int(WAIT_S), str(rt.online)])
	# A re-join is reported as a leave and a join a moment apart -- in which
	# order is the server's business, so this feeds the order seen in a
	# three-phone run against the live project (leave first) straight in,
	# rather than hoping the network repeats it.
	var probe := Realtime.new()
	var key := "probe-user"
	var meta := {"sid": sid, "where": "lobby", "name": "probe"}
	probe._handle({"event": "presence_state", "payload": {key: {"metas": [meta.merged({"phx_ref": "a"})]}}})
	probe._handle({"event": "presence_diff", "payload": {"joins": {},
		"leaves": {key: {"metas": [meta.merged({"phx_ref": "a"})]}}}})
	_check("a leave is held for the grace period",
		"" if probe.where_is(key, sid) == "lobby" else "dropped at once")
	probe._handle({"event": "presence_diff", "payload": {"leaves": {},
		"joins": {key: {"metas": [meta.merged({"phx_ref": "b", "where": "map"}, true)]}}}})
	_check("and the join that follows lands", "" if probe.where_is(key, sid) == "map" else "not seen")
	probe._handle({"event": "presence_diff", "payload": {"joins": {},
		"leaves": {key: {"metas": [meta.merged({"phx_ref": "b"})]}}}})
	for k: String in probe._leaving:           # age the held leaves past the grace
		for r: String in probe._leaving[k]:
			probe._leaving[k][r][1] -= Realtime.PRESENCE_GRACE_S + 1.0
	probe._expire_leaves()
	_check("a leave with no return is gone after the grace",
		"" if probe.where_is(key, sid) == "" else "still listed")
	probe.free()

	other.close_socket()
	_check("and is gone when it disconnects",
		"" if await _until(func() -> bool: return rt.where_is(Net.user_id, sid) == "")
		else "still listed after %ds" % int(WAIT_S))

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

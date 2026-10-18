class_name Scores
extends RefCounted

## Every gem change, sent to the functions that own the arithmetic.
##
## The client still does the same sum locally, because a phone on a classroom
## connection must not wait on a round trip to show "+10". The server's answer
## is the one that counts, so what comes back replaces what was guessed -- and
## if they ever disagree, the server wins and the player sees it correct itself.

const RPC := "/rest/v1/rpc/"

## Scoring calls waiting their turn, oldest first. Static so the queue outlives
## the map screen: time running out frees the board mid-flight, and a call
## still waiting there would never have been sent.
static var _queue: Array = []
## When the call at the head of the queue was first sent (0: nothing waiting).
static var _head_since := 0.0
## Backoff between tries of a call that did not get through.
const RETRY_S := [1.0, 2.0, 4.0, 8.0]
## Last authoritative row; useful for direct callers that omit the item index.
static var _known := {}
static var _draining := false
static var _recovering := false
static var _generation := 0


static func know(row: Dictionary) -> void:
	if row.has("items_done"):
		if _same_member(row, _known) and int(row.get("revision", -1)) < int(_known.get("revision", -1)):
			return
		_known = row.duplicate()


static func _same_member(a: Dictionary, b: Dictionary) -> bool:
	return a.has("session_id") and a.has("profile_id") \
		and a.get("session_id") == b.get("session_id") and a.get("profile_id") == b.get("profile_id")


## Keep a rescue/change event that arrived while a score reply was pending.
static func latest(row: Dictionary) -> Dictionary:
	if _same_member(row, _known) and int(_known.get("revision", -1)) > int(row.get("revision", -1)):
		return _known.duplicate()
	return row


## Logout invalidates pending work, including a retry currently awaiting HTTP.
static func reset() -> void:
	_generation += 1
	_queue.clear()
	_known = {}
	_recovering = false
	_head_since = 0.0


## Each queued operation keeps its request ID on EVERY retry. The server
## deduplicates it under the session lock; a read-before-retry cannot do that.
static func submit(kind: String, flag: bool, session_id: String, done: Callable,
		item := -1, station := -1) -> void:
	var job := {"kind": kind, "flag": flag, "sid": session_id, "done": done,
		"event": Teams.uuid(), "user": Net.user_id, "generation": _generation,
		"item": item if item >= 0 else int(_known.get("items_done", 0)),
		"station": station if station >= 0 else int(_known.get("stations_done", 0))}
	_queue.append(job)
	if _draining:
		return
	_draining = true
	while not _queue.is_empty():
		job = _queue[0]
		_head_since = Time.get_ticks_msec() / 1000.0
		var tries := 0
		var reply := {}
		while _current(job):
			reply = await _call("score_event", {"p_session": job.sid, "p_event": job.event,
				"p_kind": job.kind, "p_flag": job.flag, "p_item": job.item, "p_station": job.station})
			if not _current(job) or not bool(reply.get("network", false)):
				break
			var tree := Engine.get_main_loop() as SceneTree
			await tree.create_timer(RETRY_S[mini(tries, RETRY_S.size() - 1)]).timeout
			tries += 1
		if not _current(job):
			_queue.erase(job)
			continue
		if str(reply.get("error", "")) != "":
			_recovering = true
			# Later optimistic answers depend on this one. Discard them before
			# restoring progress; never score them against a different circle.
			_queue = _queue.filter(func(j: Dictionary) -> bool:
				return j.sid != job.sid or j.user != job.user)
			reply["row"] = await _read_row(job)
			_recovering = false
			if not _current(job):
				continue
		else:
			_queue.erase(job)
		know(reply.get("row", {}))
		reply["row"] = latest(reply.get("row", {}))
		_head_since = 0.0
		reply["kind"] = job.kind
		reply["session_id"] = job.sid
		var cb: Callable = job.done
		if cb.is_valid():
			cb.call(reply)
	_head_since = 0.0
	_draining = false


static func _current(job: Dictionary) -> bool:
	return int(job.generation) == _generation and str(job.user) == Net.user_id


## A rejected score is settled only once its authoritative progress is known.
static func _read_row(job: Dictionary) -> Dictionary:
	var tries := 0
	while _current(job):
		var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
			"/rest/v1/members?select=*&session_id=eq." + str(job.sid)
			+ "&profile_id=eq." + str(job.user))
		if not bool(got.get("network", false)):
			var rows: Variant = got.data
			return (rows as Array)[0] if rows is Array and not (rows as Array).is_empty() else {}
		var tree := Engine.get_main_loop() as SceneTree
		await tree.create_timer(RETRY_S[mini(tries, RETRY_S.size() - 1)]).timeout
		tries += 1
	return {}


## Calls not yet answered, this one included.
static func pending() -> int:
	return _queue.size() + (1 if _recovering else 0)


## How long the oldest unsaved call has been waiting; 0 if none.
static func waiting_s() -> float:
	if _queue.is_empty() or _head_since <= 0.0:
		return 0.0
	return Time.get_ticks_msec() / 1000.0 - _head_since


static func apply_answer(session_id: String, correct: bool) -> Dictionary:
	return await _call("apply_answer", {"p_session": session_id, "p_correct": correct})


static func spend_hint(session_id: String) -> Dictionary:
	return await _call("spend_hint", {"p_session": session_id})


static func skip_item(session_id: String) -> Dictionary:
	return await _call("skip_item", {"p_session": session_id})


static func finish_station(session_id: String, perfect: bool) -> Dictionary:
	return await _call("finish_station", {"p_session": session_id, "p_perfect": perfect})


## Through the Victory Gate: the server stamps this player's time (Players tab).
static func finish_run(session_id: String) -> Dictionary:
	return await _call("finish_run", {"p_session": session_id})


## Give `amount` gems to a team-mate. One per sender per adventure, at least 1
## and never the last one, which the server enforces -- the rescue screen only
## decides what is easy, never what is allowed. `row` is the GIVER's.
static func rescue(session_id: String, to_profile: String, amount: int) -> Dictionary:
	return await _call("rescue", {"p_session": session_id, "p_to": to_profile, "p_amount": amount})


## `{"error": String, "row": Dictionary}` -- the member row as the server left it.
static func _call(fn: String, args: Dictionary) -> Dictionary:
	var reply: Dictionary = await Net.rest(HTTPClient.METHOD_POST, RPC + fn, args)
	if reply.error != "":
		return {"error": reply.error, "row": {}, "network": reply.get("network", false),
			"maybe_sent": reply.get("maybe_sent", false)}
	var d: Variant = reply.data
	# PostgREST returns the row itself for a function returning one row.
	if d is Array and not (d as Array).is_empty():
		d = (d as Array)[0]
	return {"error": "", "row": d if d is Dictionary else {}}

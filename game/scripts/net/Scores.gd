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


## Send one gem change, strictly after every one before it. In parallel they
## raced: a reply landed out of order and undid a newer +10 on screen, and a
## station's bonus could reach the server ahead of the answer that finished
## the station. `done` gets `{error, row}`, if its owner is still around.
static func submit(kind: String, flag: bool, session_id: String, done: Callable) -> void:
	_queue.append([kind, flag, session_id, done])
	if _queue.size() > 1:
		return      # the call draining the queue will send this one too
	while not _queue.is_empty():
		var job: Array = _queue[0]
		var reply: Dictionary
		match str(job[0]):
			"answer": reply = await apply_answer(job[2], job[1])
			"hint": reply = await spend_hint(job[2])
			"skip": reply = await skip_item(job[2])
			"station": reply = await finish_station(job[2], job[1])
			"finish": reply = await finish_run(job[2])
			_: reply = {"error": "unknown score " + str(job[0]), "row": {}}
		_queue.pop_front()
		var cb: Callable = job[3]
		if cb.is_valid():
			cb.call(reply)


## Calls not yet answered, this one included.
static func pending() -> int:
	return _queue.size()


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
		return {"error": reply.error, "row": {}}
	var d: Variant = reply.data
	# PostgREST returns the row itself for a function returning one row.
	if d is Array and not (d as Array).is_empty():
		d = (d as Array)[0]
	return {"error": "", "row": d if d is Dictionary else {}}

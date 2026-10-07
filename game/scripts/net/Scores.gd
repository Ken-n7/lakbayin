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
## This player's member row as the server last gave it: every scoring reply,
## the row the map opened with, and changes to it off the socket (know()).
## What a call that may have landed is checked against before it is sent
## again -- the server adds +10 every time it is asked, so asking twice for
## one answer would count it twice and skip the next question.
static var _known := {}


## The server's word on this player's row, from wherever it came.
static func know(row: Dictionary) -> void:
	if row.has("items_done"):
		_known = row.duplicate()


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
		_head_since = Time.get_ticks_msec() / 1000.0
		var tries := 0
		# The row before this call, kept apart: a change off the socket
		# while the reply is lost would otherwise move the yardstick.
		var before := _known.duplicate()
		while true:
			match str(job[0]):
				"answer": reply = await apply_answer(job[2], job[1])
				"hint": reply = await spend_hint(job[2])
				"skip": reply = await skip_item(job[2])
				"station": reply = await finish_station(job[2], job[1])
				"finish": reply = await finish_run(job[2])
				_: reply = {"error": "unknown score " + str(job[0]), "row": {}}
			# Did not get through: keep it and try again, as games do -- an
			# answer is never lost to a dropped connection, and nothing queued
			# behind it overtakes it. A refusal from the server is an answer.
			if not bool(reply.get("network", false)):
				break
			# Went out but no reply came back: it may have landed. Read the
			# row and see before sending it a second time.
			if bool(reply.get("maybe_sent", false)) and not before.is_empty():
				var now_row := await _read_row(str(job[2]))
				if _landed(str(job[0]), before, now_row):
					reply = {"error": "", "row": now_row}
					break
			var tree := Engine.get_main_loop() as SceneTree
			await tree.create_timer(RETRY_S[mini(tries, RETRY_S.size() - 1)]).timeout
			tries += 1
		if str(reply.get("error", "")) == "":
			know(reply.get("row", {}))
		_queue.pop_front()
		_head_since = 0.0
		var cb: Callable = job[3]
		if cb.is_valid():
			cb.call(reply)


## Whether `kind` is already in `now_row`, measured from `before`. What each
## call changes (supabase/schema.sql): an answer or a skip moves items_done on,
## a station stations_done, a finish sets finished; a hint only takes 5 gems,
## so that one is told by the gems (a teammate's rescue landing in the same
## moment would hide it -- and the hint would be asked for again).
static func _landed(kind: String, before: Dictionary, now_row: Dictionary) -> bool:
	if now_row.is_empty():
		return false
	match kind:
		"answer", "skip":
			return int(now_row.get("items_done", 0)) > int(before.get("items_done", 0))
		"station":
			return int(now_row.get("stations_done", 0)) > int(before.get("stations_done", 0))
		"finish":
			return bool(now_row.get("finished", false))
		"hint":
			return int(now_row.get("gems", 0)) == int(before.get("gems", 0)) - 5
	return false


## This player's row, read until it can be: on a line that just failed the
## read may fail too, and nothing may be resent until it is known.
static func _read_row(session_id: String) -> Dictionary:
	var tries := 0
	while true:
		var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
			"/rest/v1/members?select=*&session_id=eq." + session_id
			+ "&profile_id=eq." + Net.user_id)
		if not bool(got.get("network", false)):
			var rows: Variant = got.data
			return (rows as Array)[0] if rows is Array and not (rows as Array).is_empty() else {}
		var tree := Engine.get_main_loop() as SceneTree
		await tree.create_timer(RETRY_S[mini(tries, RETRY_S.size() - 1)]).timeout
		tries += 1
	return {}


## Calls not yet answered, this one included.
static func pending() -> int:
	return _queue.size()


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

class_name Scores
extends RefCounted

## Every gem change, sent to the functions that own the arithmetic.
##
## The client still does the same sum locally, because a phone on a classroom
## connection must not wait on a round trip to show "+10". The server's answer
## is the one that counts, so what comes back replaces what was guessed -- and
## if they ever disagree, the server wins and the player sees it correct itself.

const RPC := "/rest/v1/rpc/"


static func apply_answer(session_id: String, correct: bool) -> Dictionary:
	return await _call("apply_answer", {"p_session": session_id, "p_correct": correct})


static func spend_hint(session_id: String) -> Dictionary:
	return await _call("spend_hint", {"p_session": session_id})


static func skip_item(session_id: String) -> Dictionary:
	return await _call("skip_item", {"p_session": session_id})


static func finish_station(session_id: String, perfect: bool) -> Dictionary:
	return await _call("finish_station", {"p_session": session_id, "p_perfect": perfect})


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

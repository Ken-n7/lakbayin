class_name Monks
extends RefCounted

## A match's monks on the server (schema 4e): answering one, depositing at the
## Monastery, and the words the match drew. The server decides every outcome.


## Writes `typed` at monk `monk`: "correct" (carried now), "wrong" (locked out
## 10s), "locked", "taken" (your team has it), or "error: <why>".
## `at`: where the hero stands -- the server checks it is within reach of
## the monk, and where their walk could have brought them.
static func answer(session_id: String, monk: int, typed: String, at := Vector2.INF) -> String:
	var body := {"p_session": session_id, "p_monk": monk, "p_typed": typed}
	if at.is_finite():
		body.p_at = [at.x, at.y]
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/rpc/answer_monk", body)
	if got.error != "":
		return "error: " + str(got.error)
	return str(got.data)


## Deposits everything this player carries. {error, deposited}.
static func deposit(session_id: String, at := Vector2.INF) -> Dictionary:
	var body := {"p_session": session_id}
	if at.is_finite():
		body.p_at = [at.x, at.y]
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/rpc/deposit", body)
	return {"error": got.error, "deposited": int(got.data) if got.error == "" and got.data != null else 0}


## A match in one answer (server/app.py `match_state`): {session, teams,
## members, words, and for its players or once it is over: answers,
## standings, players}. {error, network, data} -- `network` when the server
## was not reached, which is not the match being gone.
static func state(session_id: String) -> Dictionary:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/rpc/match_state",
		{"p_session": session_id})
	return {"error": got.error, "network": bool(got.get("network", false)),
		"data": got.data if got.error == "" and got.data is Dictionary else {}}


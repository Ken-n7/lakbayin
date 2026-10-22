class_name Monks
extends RefCounted

## A match's monks on the server (schema 4e): answering one, depositing at the
## Monastery, and the words the match drew. The server decides every outcome.


## Writes `typed` at monk `monk`: "correct" (carried now), "wrong" (locked out
## 10s), "locked", "taken" (your team has it), or "error: <why>".
static func answer(session_id: String, monk: int, typed: String) -> String:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/rpc/answer_monk",
		{"p_session": session_id, "p_monk": monk, "p_typed": typed})
	if got.error != "":
		return "error: " + str(got.error)
	return str(got.data)


## Deposits everything this player carries. {error, deposited}.
static func deposit(session_id: String) -> Dictionary:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/rpc/deposit",
		{"p_session": session_id})
	return {"error": got.error, "deposited": int(got.data) if got.error == "" and got.data != null else 0}


## The match's words, monk by monk: [{monk, word, meaning, modern, traditional}].
static func words_of(session_id: String) -> Array:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/session_words?select=monk,words(word,meaning,syllables,modern,traditional)"
		+ "&session_id=eq." + session_id + "&order=monk")
	var out: Array = []
	for row: Dictionary in (got.data if got.error == "" and got.data is Array else []):
		var w: Dictionary = row.get("words", {}) if row.get("words") is Dictionary else {}
		w["monk"] = int(row.get("monk", 0))
		out.append(w)
	return out

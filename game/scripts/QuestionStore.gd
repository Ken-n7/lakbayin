class_name QuestionStore
extends RefCounted

## The admin's question bank, in `public.questions`. Every call answers
## `{"error": String, "rows": Array}` -- "" means it worked.
##
## The client authors these; there is no ready-made set in the shipped app
## (SPECS §10 Phase 3). `QuestionGen` is still here, but only behind the
## "Use sample questions" button -- never as a silent top-up, because a bank
## that fills its own gaps hides an unfinished station from the teacher until
## a scored run is already under way.

const PATH := "/rest/v1/questions"


## `station` 1-3, or 0 for the whole bank. Inactive rows come back too: the
## admin has to see what is switched off in order to switch it on.
static func fetch(station := 0) -> Dictionary:
	var q := PATH + "?select=*&order=station,id"
	if station > 0:
		q = PATH + "?select=*&station=eq.%d&order=id" % station
	var r: Dictionary = await Net.rest(HTTPClient.METHOD_GET, q)
	return {"error": r.error, "rows": r.data if r.data is Array else []}


static func add(station: int, prompt: String, answer: String, hint := "") -> Dictionary:
	var body := {
		"station": station,
		"prompt": prompt.strip_edges(),
		"answer": answer.strip_edges(),
		"hint": hint.strip_edges(),
	}
	if body.prompt == "" or body.answer == "":
		return {"error": "A question needs a prompt and an answer.", "rows": []}
	var r: Dictionary = await Net.rest(HTTPClient.METHOD_POST, PATH, body)
	return {"error": r.error, "rows": r.data if r.data is Array else []}


## Partial update: pass only what changed.
static func edit(id: String, fields: Dictionary) -> Dictionary:
	var r: Dictionary = await Net.rest(
		HTTPClient.METHOD_PATCH, PATH + "?id=eq." + id, fields)
	return {"error": r.error, "rows": r.data if r.data is Array else []}


## Deleting a question takes its feedback with it -- they live in the same row,
## which is why the spec's "deleting a question clears its feedback" is free.
static func remove(id: String) -> Dictionary:
	var r: Dictionary = await Net.rest(HTTPClient.METHOD_DELETE, PATH + "?id=eq." + id)
	return {"error": r.error, "rows": []}


## What "Set" does, per SPECS §11 Q5: mark this question as one of the items
## the next adventure draws from.
##
## `active` defaults to true in the schema, so an authored question is already
## in the pool and Set is mostly used to take one *out*. When a station holds
## more active questions than its item count, the adventure takes the first
## `ITEMS_PER_STATION[n]` in id order -- deterministic, so every team sees the
## same items, which is the point of a fixed bank.
static func set_active(id: String, on: bool) -> Dictionary:
	return await edit(id, {"active": on})


## Counts the active items per station, which is what Start Game checks.
## Returns station -> count for stations 1..3, zero-filled.
static func active_counts() -> Dictionary:
	var out := {1: 0, 2: 0, 3: 0}
	var got: Dictionary = await fetch()
	if got.error != "":
		return out
	for row: Dictionary in got.rows:
		if row.get("active", false):
			var st: int = int(row.get("station", 0))
			if out.has(st):
				out[st] += 1
	return out


## Why Start Game refuses, or "" when it may proceed. Names the shortfall
## rather than quietly generating the difference.
static func shortfall() -> String:
	var counts: Dictionary = await active_counts()
	var short: Array[String] = []
	for i in Game.ITEMS_PER_STATION.size():
		var want: int = Game.ITEMS_PER_STATION[i]
		var have: int = counts.get(i + 1, 0)
		if have < want:
			short.append("Station %d needs %d more" % [i + 1, want - have])
	return "" if short.is_empty() else "  ·  ".join(short)


## The "Use sample questions" button: tops a station up to its item count from
## the generator. An explicit act by the teacher, recorded as authored rows.
static func seed(station: int) -> Dictionary:
	var counts: Dictionary = await active_counts()
	var want: int = Game.ITEMS_PER_STATION[station - 1] - int(counts.get(station, 0))
	for i in maxi(want, 0):
		var item: Dictionary = QuestionGen.item_for_station(station - 1, i)
		var added: Dictionary = await add(station, item.get("prompt", ""),
			str(item.get("answer", "")), item.get("hint", ""))
		if added.error != "":
			return added
	return {"error": "", "rows": []}

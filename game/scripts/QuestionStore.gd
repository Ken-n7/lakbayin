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
##
## Exponents typed with a caret come back raised (`TEXT_FIELDS`), so a row
## saved as `2^3` -- before the form raised them, or straight into the table --
## reads 2³ everywhere the bank is shown: the list, Feedback, and the quiz.
static func fetch(station := 0) -> Dictionary:
	var q := PATH + "?select=*&order=station,created_at,id"
	if station > 0:
		q = PATH + "?select=*&station=eq.%d&order=created_at,id" % station
	var r: Dictionary = await Net.rest(HTTPClient.METHOD_GET, q)
	var rows: Array = r.data if r.data is Array else []
	for row in rows:
		if row is Dictionary:
			_raise(row)
	return {"error": r.error, "rows": rows}


## The text a teacher writes, where `2^3` means 2³. Not the answer: that is a
## number, compared as typed on the keypad.
const TEXT_FIELDS := ["prompt", "hint", "feedback"]


## Raises the exponents in `row`'s text fields, in place; returns it.
static func _raise(row: Dictionary) -> Dictionary:
	for k: String in TEXT_FIELDS:
		if row.get(k) is String:
			row[k] = MathText.superscripts(row[k])
	return row


static func add(station: int, prompt: String, answer: String, hint := "") -> Dictionary:
	var body := _raise({
		"station": station,
		"prompt": prompt.strip_edges(),
		"answer": answer.strip_edges(),
		"hint": hint.strip_edges(),
	})
	if body.prompt == "" or body.answer == "":
		return {"error": "A question needs a prompt and an answer.", "rows": []}
	var r: Dictionary = await Net.rest(HTTPClient.METHOD_POST, PATH, body)
	return {"error": r.error, "rows": r.data if r.data is Array else []}


## Partial update: pass only what changed.
static func edit(id: String, fields: Dictionary) -> Dictionary:
	var r: Dictionary = await Net.rest(
		HTTPClient.METHOD_PATCH, PATH + "?id=eq." + id, _raise(fields.duplicate()))
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


# --- The bank in hand -------------------------------------------------------
## Lives here and not on `Game`, because `Game` is loaded directly by
## `test_rules.gd` with `--script`, which registers no autoloads -- naming
## `Net` there compiles fine in the game and hangs the suite.
## The admin's authored questions for this run, station index -> rows. Empty
## when there is no backend, which is how an offline dev run and the headless
## suites still get questions at all.
static var bank := {}


## Pull the bank once per adventure rather than per item: forty round trips on
## a classroom connection is forty chances to stall mid-question.
static func load_bank() -> String:
	bank = {}
	if not Net.configured() or not Net.signed_in():
		return ""
	var got: Dictionary = await fetch()
	if got.error != "":
		return got.error
	for row: Dictionary in got.rows:
		if not row.get("active", false):
			continue
		var idx: int = int(row.get("station", 0)) - 1
		if idx < 0 or idx >= Game.ITEMS_PER_STATION.size():
			continue
		if not bank.has(idx):
			bank[idx] = []
		bank[idx].append(row)
	return ""


## The item a circle asks. An authored question when the bank has one, the
## generator when it does not -- which offline is every time, and online is
## never, because Start Game refuses to begin on a short station.
##
## Over-supply takes the first N in authoring order, so the teacher's first
## question is the first circle and every team answers the same items.
static func item_for(station_index: int, item_index: int) -> Dictionary:
	var rows: Array = bank.get(station_index, [])
	if item_index < rows.size():
		var q: Dictionary = rows[item_index]
		return {
			# Raised again here, where the students see it: whatever filled the
			# bank, `2^3` is never what reaches the quiz.
			"prompt": MathText.superscripts(str(q.get("prompt", ""))),
			"answer": str(q.get("answer", "")),
			"hint": MathText.superscripts(str(q.get("hint", ""))),
			# The admin's feedback is the rule reminder on a wrong answer; that
			# is what the Feedback screen writes it for. Falls back to the hint
			# so a question with no feedback still says something useful.
			"rule": MathText.superscripts(str(q.get("feedback", ""))
				if str(q.get("feedback", "")) != "" else str(q.get("hint", ""))),
		}
	var gen: Dictionary = QuestionGen.item_for_station(station_index, item_index)
	gen["answer"] = str(gen.get("answer", ""))
	return gen

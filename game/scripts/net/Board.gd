class_name Board
extends RefCounted

## The live leaderboard: teams from the `team_scores` view, players from
## `members` joined to their profile.
##
## **Players read this; only the admin watches it.** Every answered item writes
## a `members` row, so a board subscribed on forty phones turns ~200 realtime
## messages an adventure into ~22,000. The teacher's dashboard is the one place
## that needs it live; a student opening the board gets a fetch.

const SCORES := "/rest/v1/team_scores"
const MEMBERS := "/rest/v1/members"


## [{name, gems, members}], best first.
static func teams(session_id: String) -> Array:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		SCORES + "?select=name,gems,members&session_id=eq." + session_id
		+ "&order=gems.desc")
	return got.data if got.error == "" and got.data is Array else []


## [{username, gems, correct, items_done, finish_s}], best first. `finish_s` is
## the player's own time for the adventure -- the game clock when they walked
## into the Victory Gate, pauses not counted -- or -1 while they are still out.
static func players(session_id: String) -> Array:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		MEMBERS + "?select=gems,correct,items_done,finish_s,profiles(username)"
		+ "&session_id=eq." + session_id + "&order=gems.desc")
	if got.error != "" or not (got.data is Array):
		return []
	var out: Array = []
	for row: Dictionary in got.data:
		var who: Variant = row.get("profiles")
		var t: Variant = row.get("finish_s")
		out.append({
			"username": str((who as Dictionary).get("username", "?")) if who is Dictionary else "?",
			"gems": int(row.get("gems", 0)),
			"correct": int(row.get("correct", 0)),
			"items_done": int(row.get("items_done", 0)),
			"finish_s": int(t) if t != null else -1,
		})
	return out

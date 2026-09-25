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


## [{username, gems, correct, items_done, idle_s}], best first. `idle_s` is how
## long since that player last answered anything -- the number a teacher
## actually reads, since "on circle 3" and "stuck on circle 3" look identical
## without it.
static func players(session_id: String) -> Array:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		MEMBERS + "?select=gems,correct,items_done,updated_at,profiles(username)"
		+ "&session_id=eq." + session_id + "&order=gems.desc")
	if got.error != "" or not (got.data is Array):
		return []
	var now := Game.now()
	var out: Array = []
	for row: Dictionary in got.data:
		var who: Variant = row.get("profiles")
		var touched := Time.get_unix_time_from_datetime_string(str(row.get("updated_at", "")))
		out.append({
			"username": str((who as Dictionary).get("username", "?")) if who is Dictionary else "?",
			"gems": int(row.get("gems", 0)),
			"correct": int(row.get("correct", 0)),
			"items_done": int(row.get("items_done", 0)),
			"idle_s": maxi(int(now - float(touched)), 0),
		})
	return out

class_name Teams
extends RefCounted

## Joining a team, and the roster that comes back out of it.
##
## The team name IS the join code (SPECS §3): the admin creates the names in
## Game Controls and hands them out, and a name that is not one of them is
## refused. That is the whole membership mechanism -- there is no invite, no
## password, and the winner is a team, never a player.

const SESSIONS := "/rest/v1/sessions"
const TEAMS := "/rest/v1/teams"
const MEMBERS := "/rest/v1/members"


## The adventure a player would be joining: the newest session that has not
## ended. One admin runs one session, so "newest" is the whole rule -- see
## SPECS §11 Q12 if two teachers ever need to run at once.
static func live_session() -> Dictionary:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		SESSIONS + "?select=*&state=neq.ended&order=created_at.desc&limit=5")
	if got.error != "":
		return {"error": got.error, "session": {}}
	for row: Dictionary in (got.data if got.data is Array else []):
		if not expired(row):
			return {"error": "", "session": row}
	return {"error": "No adventure has been set up yet.", "session": {}}


## A run whose deadline has passed is over whether or not anybody set its state
## to `ended`. Without this a student joining tomorrow lands in yesterday's
## adventure, with a clock that reads 00:00 and a board that will not start.
static func expired(session: Dictionary) -> bool:
	if str(session.get("state", "")) != "running":
		return false
	var ends: String = str(session.get("ends_at", ""))
	if ends == "":
		return false
	return Time.get_unix_time_from_datetime_string(ends) <= Time.get_unix_time_from_system()


## Join by name. Returns "" on success, or what to show under the field.
static func join(team_name: String) -> String:
	if not Net.signed_in():
		return "Sign in first."
	var live: Dictionary = await live_session()
	if live.error != "":
		return live.error
	var session: Dictionary = live.session

	var wanted := team_name.strip_edges()
	# `ilike` so a student typing "math mavericks" is not turned away over a
	# capital letter they were never given.
	var found: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		TEAMS + "?select=id,name&session_id=eq." + str(session.get("id", ""))
		+ "&name=ilike." + wanted.uri_encode())
	if found.error != "":
		return found.error
	var rows: Array = found.data if found.data is Array else []
	if rows.is_empty():
		return "No team by that name. Check with your teacher."
	var team: Dictionary = rows[0]

	# Already in this session? Then this is a rejoin or a change of team, not
	# a second membership -- the unique (session_id, profile_id) would refuse
	# the insert and the student would see a constraint error for it.
	var mine: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		MEMBERS + "?select=team_id&session_id=eq." + str(session.get("id", ""))
		+ "&profile_id=eq." + Net.user_id)
	var existing: Array = mine.data if mine.data is Array else []
	if not existing.is_empty():
		if str(existing[0].get("team_id", "")) == str(team.get("id", "")):
			return ""
		var moved: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
			MEMBERS + "?session_id=eq." + str(session.get("id", ""))
			+ "&profile_id=eq." + Net.user_id, {"team_id": team.get("id", "")})
		return moved.error

	var made: Dictionary = await Net.rest(HTTPClient.METHOD_POST, MEMBERS, {
		"session_id": session.get("id", ""),
		"team_id": team.get("id", ""),
		"profile_id": Net.user_id,
	})
	return made.error


## The caller's team-mates in this session, minus the caller. Who Rescue can
## send to, and the only list it is allowed to offer -- the server checks the
## same thing, since a dropdown is not a permission.
static func teammates(session_id: String) -> Array:
	var mine: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		MEMBERS + "?select=team_id&session_id=eq." + session_id
		+ "&profile_id=eq." + Net.user_id)
	var rows: Array = mine.data if mine.data is Array else []
	if rows.is_empty():
		return []
	var team: String = str(rows[0].get("team_id", ""))
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		MEMBERS + "?select=profile_id,gems,eliminated,profiles(username)"
		+ "&session_id=eq." + session_id + "&team_id=eq." + team + "&order=gems")
	var out: Array = []
	for row: Dictionary in (got.data if got.data is Array else []):
		if str(row.get("profile_id", "")) == Net.user_id:
			continue
		var who: Variant = row.get("profiles")
		out.append({
			"profile_id": str(row.get("profile_id", "")),
			"username": str((who as Dictionary).get("username", "?")) if who is Dictionary else "?",
			"gems": int(row.get("gems", 0)),
			"eliminated": bool(row.get("eliminated", false)),
		})
	return out


## Everyone in the session, whatever team: who they are, where they have got
## to, and which team's colour to draw them in. This is what puts the whole
## class on one board.
##
## Scoped to a session, so the fan-out is the session's size -- eight players
## is ~900 realtime messages an adventure. A class of forty would be ~22,000,
## which is the number to remember before widening this.
static func everyone(session_id: String) -> Array:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		MEMBERS + "?select=profile_id,team_id,items_done,gems,eliminated,"
		+ "profiles(username)&session_id=eq." + session_id)
	var out: Array = []
	for row: Dictionary in (got.data if got.data is Array else []):
		var who: Variant = row.get("profiles")
		out.append({
			"profile_id": str(row.get("profile_id", "")),
			"team_id": str(row.get("team_id", "")),
			"username": str((who as Dictionary).get("username", "?")) if who is Dictionary else "?",
			"items_done": int(row.get("items_done", 0)),
			"gems": int(row.get("gems", 0)),
			"eliminated": bool(row.get("eliminated", false)),
		})
	return out


## team id -> [username]. What Game Controls prints under "Joined Members:".
static func roster(session_id: String) -> Dictionary:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		MEMBERS + "?select=team_id,profiles(username)&session_id=eq." + session_id)
	var out := {}
	if got.error != "" or not (got.data is Array):
		return out
	for row: Dictionary in got.data:
		var team: String = str(row.get("team_id", ""))
		if not out.has(team):
			out[team] = []
		var who: Variant = row.get("profiles")
		if who is Dictionary:
			out[team].append(str((who as Dictionary).get("username", "")))
	return out

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
		SESSIONS + "?select=*&state=neq.ended&order=created_at.desc&limit=1")
	if got.error != "":
		return {"error": got.error, "session": {}}
	if got.data is Array and not (got.data as Array).is_empty():
		return {"error": "", "session": got.data[0]}
	return {"error": "No adventure has been set up yet.", "session": {}}


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

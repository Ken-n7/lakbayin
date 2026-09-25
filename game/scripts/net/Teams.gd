class_name Teams
extends RefCounted

## Getting into an adventure, picking a side, and the roster that comes out.
##
## The way in is the session's CODE: the teacher presses New Session, reads
## out the four characters, and everybody types them. Then each student picks
## their own team in the lobby, and may switch until the teacher presses Start
## -- after that teams are locked (the server enforces it; see `team_rules` in
## `supabase/schema.sql`). The winner is still a team, never a player.

const SESSIONS := "/rest/v1/sessions"
const TEAMS := "/rest/v1/teams"
const MEMBERS := "/rest/v1/members"


## The open session with this code. Codes are only unique among sessions still
## in play, so it is the newest one, and one that has run out does not count.
static func find(code: String) -> Dictionary:
	var want := code.strip_edges().to_upper()
	if want.length() != 4:
		return {"error": "The code is 4 letters and numbers.", "session": {}}
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		SESSIONS + "?select=*&code=eq." + want.uri_encode()
		+ "&state=neq.ended&order=created_at.desc&limit=1")
	if got.error != "":
		return {"error": got.error, "session": {}}
	var rows: Array = got.data if got.data is Array else []
	if rows.is_empty() or expired(rows[0]):
		return {"error": "No adventure with that code. Check with your teacher.", "session": {}}
	return {"error": "", "session": rows[0]}


## A random (v4) uuid, made here so a new row can be announced before the
## server has answered with its id.
static func uuid() -> String:
	var b := Crypto.new().generate_random_bytes(16)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4),
		h.substr(16, 4), h.substr(20, 12)]


## One session by id, `{}` if it is gone. What a phone that already joined
## goes back to, rather than asking for the code again.
static func session(session_id: String) -> Dictionary:
	if session_id == "":
		return {}
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		SESSIONS + "?select=*&id=eq." + session_id)
	var rows: Array = got.data if got.data is Array else []
	return rows[0] if got.error == "" and not rows.is_empty() else {}


## A run whose deadline has passed is over whether or not anybody set its state
## to `ended`. Without this a student joining tomorrow lands in yesterday's
## adventure, with a clock that reads 00:00 and a board that will not start.
##
## Nor does a session outlive its day because nobody pressed End: a teacher
## who closes the app leaves a lobby or a pause that no deadline will ever
## pass. Anything older than MAX_AGE_S -- longer than the longest adventure
## the schema allows (7200s) plus a lesson's slack -- is over too.
const MAX_AGE_S := 3 * 3600


static func expired(session: Dictionary) -> bool:
	if str(session.get("state", "")) == "ended":
		return true
	var now := Game.now()
	var made := _stamp(session.get("created_at"))
	if made > 0 and made + MAX_AGE_S <= now:
		return true
	if str(session.get("state", "")) != "running":
		return false
	var ends := _stamp(session.get("ends_at"))
	return ends > 0 and ends <= now


## A timestamp column as unix seconds, 0 for none. A JSON null reached
## `str()` as "<null>", which parses as 1970 -- so a running session whose
## deadline had not arrived yet read as long over, and the lobby sent its
## students back to the code screen the moment the teacher pressed Start.
static func _stamp(v: Variant) -> int:
	if v == null or str(v) == "":
		return 0
	return Time.get_unix_time_from_datetime_string(str(v))


## Into the session by its code, with no team yet. Coming back in -- a rejoin,
## Join Quest -- finds the membership already there and keeps it, team,
## gems and all. `{error, session}`.
static func enter(code: String) -> Dictionary:
	if not Net.signed_in():
		return {"error": "Sign in first.", "session": {}}
	var found: Dictionary = await find(code)
	if found.error != "":
		return found
	var sid: String = str(found.session.get("id", ""))
	# Once it has started nobody new comes in -- the way a match that has
	# begun takes no one from the queue. Somebody already in it (a dead
	# phone, the app reopened) still gets back in. The server holds the same
	# line; this only words it.
	if str(found.session.get("state", "")) != "lobby":
		var mine: Dictionary = await membership(sid)
		if mine.has("error"):
			return {"error": str(mine.error), "session": {}}
		if mine.is_empty():
			return {"error": "That adventure has already started. Ask your teacher.", "session": {}}
		return found
	# Insert if missing, keep if there: one request, not look-then-add.
	var made: Dictionary = await Net.rest(HTTPClient.METHOD_POST,
		MEMBERS + "?on_conflict=session_id,profile_id",
		{"session_id": sid, "profile_id": Net.user_id},
		"resolution=ignore-duplicates")
	if made.error != "":
		return {"error": made.error, "session": {}}
	# Only a row that was actually inserted comes back, so an empty answer
	# means "already in" -- a rejoin, which must not be announced as a
	# newcomer with no team.
	if made.data is Array and not (made.data as Array).is_empty():
		Lobby.tell(sid, "members", "INSERT", {"session_id": sid,
			"profile_id": Net.user_id, "team_id": null, "username": Net.username})
	return found


## Onto a team, or across to another before Start. "" or what went wrong --
## after Start the server refuses a switch, and says so.
static func pick(session_id: String, team_id: String) -> String:
	var done: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
		MEMBERS + "?session_id=eq." + session_id + "&profile_id=eq." + Net.user_id,
		{"team_id": team_id})
	return done.error


## The session's teams, [{id, name}], in the order Game Controls shows them.
static func teams_of(session_id: String) -> Array:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		TEAMS + "?select=id,name&session_id=eq." + session_id + "&order=name")
	return got.data if got.error == "" and got.data is Array else []


## Code and team name in one go -- what the live checks do, and what a player
## does in two taps. "" or the error.
static func join(code: String, team_name: String) -> String:
	var got: Dictionary = await enter(code)
	if got.error != "":
		return got.error
	var sid: String = str(got.session.get("id", ""))
	for t: Dictionary in await teams_of(sid):
		if str(t.get("name", "")).to_lower() == team_name.strip_edges().to_lower():
			return await pick(sid, str(t.get("id", "")))
	return "No team by that name."


## The caller's own row in a session: gems, progress, whether they are out.
## `{}` when they never joined it; `{"error": ...}` when the question could
## not be asked, which is not the same thing and must not send them to rejoin.
static func membership(session_id: String) -> Dictionary:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		MEMBERS + "?select=*&session_id=eq." + session_id + "&profile_id=eq." + Net.user_id)
	if got.error != "":
		return {"error": got.error}
	var rows: Array = got.data if got.data is Array else []
	return rows[0] if not rows.is_empty() else {}


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
	var team: Variant = rows[0].get("team_id")
	if team == null:
		return []
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		MEMBERS + "?select=profile_id,gems,eliminated,profiles(username)"
		+ "&session_id=eq." + session_id + "&team_id=eq." + str(team) + "&order=gems")
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
			"team_id": "" if row.get("team_id") == null else str(row.get("team_id")),
			"username": str((who as Dictionary).get("username", "?")) if who is Dictionary else "?",
			"items_done": int(row.get("items_done", 0)),
			"gems": int(row.get("gems", 0)),
			"eliminated": bool(row.get("eliminated", false)),
		})
	return out


## team id -> [{profile_id, username}], with "" for everybody who has not
## picked a team yet. What Game Controls lists on each card, and under "No
## team", for the teacher to Move.
static func roster(session_id: String) -> Dictionary:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		MEMBERS + "?select=profile_id,team_id,profiles(username)&session_id=eq." + session_id
		+ "&order=profile_id")
	var out := {}
	if got.error != "" or not (got.data is Array):
		return out
	for row: Dictionary in got.data:
		var team: String = "" if row.get("team_id") == null else str(row.get("team_id"))
		if not out.has(team):
			out[team] = []
		var who: Variant = row.get("profiles")
		out[team].append({
			"profile_id": str(row.get("profile_id", "")),
			"username": str((who as Dictionary).get("username", "?")) if who is Dictionary else "?",
		})
	return out

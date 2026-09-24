class_name Lobby
extends RefCounted

## One session's teams and who is on them, kept in step off the realtime
## socket rather than re-fetched on every change.
##
## Both the student's team picker and the teacher's Teams tab show this. Each
## used to answer every event with two or three requests in a row -- ~250ms
## apiece -- so a team added on one screen took well over a second to appear
## on another. Now a change is applied from the message itself, and the only
## fetch is `load()`: once on open, and again for the rare row it cannot
## place (a newcomer whose username the message does not carry).
##
## Two roads bring the same change, and `apply()` takes both, in either order:
##   - a **Broadcast** (`tell()`) from whoever made it, sent the moment they
##     act -- ~0.1-0.2s, the fast road;
##   - the database's own change feed -- 0.4-1s, but it cannot be missed by a
##     phone that was connected, so it is the backstop.
## Broadcasts are unauthenticated, so they only ever change what a lobby SHOWS;
## every rule is the server's, and the map never acts on one.

const EVENT := "row"

var session := {}
## [{id, name}], sorted by name -- the order Game Controls lists them in.
var teams: Array = []
## profile_id -> {username, team_id}; team_id "" means not on a team yet.
var players := {}


## Everything in one request: the session, its teams, its members and their
## names, embedded. Returns "" or the error.
func load(session_id: String) -> String:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/sessions?select=*,teams(id,name),members(profile_id,team_id,"
		+ "profiles(username))&id=eq." + session_id)
	if got.error != "":
		return got.error
	var rows: Array = got.data if got.data is Array else []
	if rows.is_empty():
		session = {}
		teams = []
		players = {}
		return ""
	var row: Dictionary = rows[0]
	teams = []
	for t: Dictionary in row.get("teams", []):
		teams.append({"id": str(t.get("id", "")), "name": str(t.get("name", ""))})
	_sort()
	players = {}
	for m: Dictionary in row.get("members", []):
		var who: Variant = m.get("profiles")
		players[str(m.get("profile_id", ""))] = {
			"username": str((who as Dictionary).get("username", "?")) if who is Dictionary else "?",
			"team_id": _team_of(m),
		}
	row.erase("teams")
	row.erase("members")
	session = row
	return ""


## Fold one realtime change in. Returns "changed", "reload" (a row it cannot
## place -- call `load()`), or "" (not this session's, or nothing to do).
##
## Deletes arrive unfiltered and carry only the row's key, so they are matched
## by key against what this lobby holds rather than by session.
func apply(table: String, type: String, record: Dictionary) -> String:
	var sid: String = str(session.get("id", ""))
	match table:
		"sessions":
			if str(record.get("id", "")) != sid:
				return ""
			if type == "DELETE":
				session = {}
				return "changed"
			session.merge(record, true)
			return "changed"
		"teams":
			var id: String = str(record.get("id", ""))
			if type == "DELETE":
				var at := _team_index(id)
				if at == -1:
					return ""
				teams.remove_at(at)
				# Its players' rows go teamless too; those updates arrive on
				# their own, but the card should not wait for them.
				for p: String in players:
					if players[p].team_id == id:
						players[p].team_id = ""
				return "changed"
			if str(record.get("session_id", "")) != sid:
				return ""
			var at := _team_index(id)
			if at == -1:
				teams.append({"id": id, "name": str(record.get("name", ""))})
			else:
				teams[at].name = str(record.get("name", ""))
			_sort()
			return "changed"
		"members":
			var pid: String = str(record.get("profile_id", ""))
			if type == "RELOAD":
				return "reload"
			if type == "DELETE":
				if not players.has(pid) or str(record.get("session_id", sid)) != sid:
					return ""
				players.erase(pid)
				return "changed"
			if str(record.get("session_id", "")) != sid:
				return ""
			if not players.has(pid):
				# A newcomer. A broadcast carries their name; the change feed
				# does not, and costs a read.
				if not record.has("username"):
					return "reload"
				players[pid] = {"username": str(record.username), "team_id": ""}
			players[pid].team_id = _team_of(record)
			return "changed"
	return ""


## Send a change to every lobby on this session straight away, alongside the
## database write that makes it true. `type` RELOAD (table "members") asks
## them to read everything again -- for a change too big to describe, or a
## write the server refused after it was announced.
static func tell(session_id: String, table: String, type: String, record: Dictionary) -> void:
	Net.realtime().send_broadcast(EVENT,
		{"sid": session_id, "table": table, "type": type, "record": record})


## A lobby-row broadcast for this session, as `apply()` takes it; "" if not.
func hear(event: String, data: Dictionary) -> String:
	if event != EVENT or str(data.get("sid", "")) != str(session.get("id", "")):
		return ""
	var record: Variant = data.get("record")
	return apply(str(data.get("table", "")), str(data.get("type", "")),
		record if record is Dictionary else {})


## Who is on a team, [{profile_id, username}]; "" for those on none.
func members_of(team_id: String) -> Array:
	var out: Array = []
	for pid: String in players:
		if players[pid].team_id == team_id:
			out.append({"profile_id": pid, "username": players[pid].username})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.username < b.username)
	return out


func team_of(profile_id: String) -> String:
	return players[profile_id].team_id if players.has(profile_id) else ""


func name_of(team_id: String) -> String:
	var at := _team_index(team_id)
	return teams[at].name if at != -1 else ""


func _team_index(id: String) -> int:
	for i in teams.size():
		if teams[i].id == id:
			return i
	return -1


func _sort() -> void:
	teams.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.name.naturalnocasecmp_to(b.name) < 0)


static func _team_of(row: Dictionary) -> String:
	return "" if row.get("team_id") == null else str(row.get("team_id"))

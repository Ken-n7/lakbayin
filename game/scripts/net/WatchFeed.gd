class_name WatchFeed
extends RefCounted

## Spectators have a renewable server lease, never a place on either team.
static func enter(code: String) -> Dictionary:
	return await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/rpc/watch_match",
		{"p_code": Teams.clean_code(code)})


static func snapshot(session: String) -> Dictionary:
	return await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/rpc/watch_snapshot", {"p_session": session})


static func leave(session: String) -> void:
	await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/rpc/leave_watch", {"p_session": session})


## Presence is a delivery hint only; permission to read is checked by RLS.
static func has_viewers(online: Dictionary, session: String) -> bool:
	for states: Array in online.values():
		for meta: Variant in states:
			if meta is Dictionary and meta.get("sid") == session and meta.get("where") == "watch":
				return true
	return false


## 0 = unanswered, 1 = carried, 2 = deposited, separately for each team.
static func monk_state(data: Dictionary, team: String, monk: int) -> int:
	for a: Dictionary in data.get("answers", []):
		if str(a.get("team_id", "")) == team and int(a.get("monk", -1)) == monk:
			return 2 if bool(a.get("deposited", false)) else 1
	return 0


static func time_left(session: Dictionary, now: float) -> int:
	var end: Variant = session.get("ends_at")
	if end == null:
		return int(session.get("duration_s", 0))
	return maxi(0, int(ceilf(stamp(str(end)) - now)))


## Timeout ties use the same deposits / reached-total rule as the results.
static func outcome(data: Dictionary) -> String:
	var session: Dictionary = data.get("session", {})
	var teams: Array = data.get("teams", [])
	for t: Dictionary in teams:
		if str(t.get("id", "")) == str(session.get("winner_team", "")):
			return str(t.get("name", "Team")) + " wins!"
	if teams.size() != 2:
		return "Match ended"
	var a: Dictionary = teams[0]
	var b: Dictionary = teams[1]
	if int(a.deposited) != int(b.deposited):
		return str((a if int(a.deposited) > int(b.deposited) else b).name) + " wins!"
	var ta := stamp(str(a.get("reached_at", "")))
	var tb := stamp(str(b.get("reached_at", "")))
	if ta > 0 and tb > 0 and ta != tb:
		return str((a if ta < tb else b).name) + " wins!"
	return "Draw"


static func stamp(value: String) -> float:
	if value == "" or value == "<null>":
		return 0.0
	var text := value.replace(" ", "T")
	var seconds := float(Time.get_unix_time_from_datetime_string(text.left(19)))
	if text.length() > 19 and text[19] == ".":
		seconds += float("0" + text.substr(19).split("+")[0].trim_suffix("Z"))
	return seconds

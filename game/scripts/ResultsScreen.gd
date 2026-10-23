extends Control

## After a match (DESIGN.md 3.5, 3.6): who won and why, the teams' totals, the
## players ranked, and every word of the match with its Baybayin -- the one
## place a spelling is shown, so a wrong answer still teaches.
##
## Ranking is by words first, then time: more deposited words ranks higher,
## and of two with the same, whoever reached that total sooner. A team that
## deposited every word beats any that did not.
##
## Online the standings are read from the server (`team_standings`,
## `player_standings`); Practice has only the result `Match.result()` handed it.

var main: Control
var result: Dictionary = {}

const STATE_MARK := {"deposited": "✓", "lost": "✗", "missed": "·"}


func setup(data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	result = data
	_build()


func _build() -> void:
	var teams: Array = []
	var players: Array = []
	if not bool(result.get("practice", true)) and str(result.get("session_id", "")) != "":
		var got := await _standings(str(result.session_id))
		if not is_instance_valid(self):
			return
		teams = got.teams
		players = got.players
	var box := Ui.screen_panel(self, Vector2(600, 330), "")
	box.add_theme_constant_override("separation", 6)
	var head := CenterContainer.new()
	var title := _title(teams)
	head.add_child(Ui.ribbon(title[1], title[0], 30, Pal.H2))
	box.add_child(head)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(row)

	# Left: the totals and the ranking.
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(250, 0)
	left.add_theme_constant_override("separation", 3)
	row.add_child(left)
	var monks := int(result.get("monks", 0))
	if teams.is_empty():
		var at := float(result.get("reached_s", -1))
		Ui.section(left, "You")
		left.add_child(Art.label("%d of %d words deposited" % [int(result.get("my_deposits", 0)), monks],
				Pal.BODY, Pal.INK))
		if at >= 0.0:
			left.add_child(Art.label("Last deposit at %s" % Ui.mmss(int(at)), Pal.SMALL, Pal.INK_MUTED))
	else:
		Ui.section(left, "Teams")
		for t: Dictionary in teams:
			var l := Art.label("%s   %d / %d%s" % [t.name, t.deposited, monks,
				("   ·  %s" % Ui.mmss(int(t.reached_s))) if float(t.reached_s) >= 0.0 else ""],
				Pal.BODY, Peers.TEAM_COLOURS[clampi(int(t.index), 0, 1)].darkened(0.2))
			left.add_child(l)
		Ui.section(left, "Players")
		var scroll := Ui.scroll(left, 110)
		var list := VBoxContainer.new()
		list.add_theme_constant_override("separation", 1)
		scroll.add_child(list)
		for i in players.size():
			var p: Dictionary = players[i]
			var me := str(p.profile_id) == Net.user_id
			list.add_child(Art.label("%d.  %s%s   %d%s" % [i + 1, "★ " if me else "", p.username,
				p.deposited, ("   ·  %s" % Ui.mmss(int(p.reached_s))) if float(p.reached_s) >= 0.0 else ""],
				Pal.SMALL, Pal.WRONG if me else Peers.TEAM_COLOURS[clampi(int(p.team), 0, 1)].darkened(0.3)))

	# Right: every word, its Baybayin, and how your team did with it.
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 2)
	row.add_child(right)
	Ui.section(right, "The words  (✓ deposited  ✗ carried, lost  · missed)")
	var scroll := Ui.scroll(right, 190)
	var words := VBoxContainer.new()
	words.add_theme_constant_override("separation", 0)
	scroll.add_child(words)
	for w: Dictionary in result.get("words", []):
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 6)
		var mark := Art.label(STATE_MARK.get(str(w.state), "·"), Pal.LABEL,
			Pal.CORRECT if w.state == "deposited" else (Pal.WRONG if w.state == "lost" else Pal.INK_MUTED))
		mark.custom_minimum_size = Vector2(16, 0)
		line.add_child(mark)
		var name := Art.label(str(w.word), Pal.LABEL, Pal.INK)
		name.custom_minimum_size = Vector2(80, 0)
		line.add_child(name)
		var glyphs := Art.label(str(w.modern), 20, Pal.TITLE)
		glyphs.add_theme_font_override("font", Art.baybayin())
		glyphs.custom_minimum_size = Vector2(96, 0)
		line.add_child(glyphs)
		var meaning := Art.label(str(w.meaning), Pal.SMALL, Pal.INK_MUTED)
		meaning.clip_text = true
		meaning.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		meaning.custom_minimum_size = Vector2(70, 0)
		meaning.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(meaning)
		words.add_child(line)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	var home := Ui.button("Home", Ui.W_MED, Ui.H, Ui.SMALL)
	home.pressed.connect(func() -> void: main.open("home"))
	buttons.add_child(home)
	var practice := bool(result.get("practice", true))
	var custom := bool(result.get("custom", false))
	var again := Ui.button("Practice again" if practice else "New room" if custom else "Find another match",
		200, Ui.H, Ui.RED)
	again.name = "Again"
	again.pressed.connect(func() -> void:
		main.open("adventure", {"practice": true}) if practice else main.open("room" if custom else "team"))
	buttons.add_child(again)
	if not practice:
		var records := Ui.button("My Matches", 120, Ui.H, Ui.SMALL)
		records.pressed.connect(func() -> void: main.open("records"))
		buttons.add_child(records)
	box.add_child(buttons)


## [banner text, ribbon row]: who won, or that time ran out.
func _title(teams: Array) -> Array:
	if bool(result.get("practice", true)):
		var all := int(result.get("my_deposits", 0)) >= int(result.get("monks", 0))
		return ["Every word deposited!" if all else "Time's up!", Ui.RIBBON_YELLOW if all else Ui.RIBBON_RED]
	if teams.is_empty():
		return ["Match over", Ui.RIBBON_GREY]
	var best: Dictionary = teams[0]
	var tie := teams.size() > 1 and _rank_key(teams[1]) == _rank_key(best)
	if tie:
		return ["A draw!", Ui.RIBBON_GREY]
	var mine := int(best.index) == int(result.get("team", 0))
	return ["%s wins!%s" % [best.name, "  You won!" if mine else ""],
		Ui.RIBBON_BLUE if int(best.index) == 0 else Ui.RIBBON_RED]


## A team's or player's place, as something that sorts: finished first, then
## words, then the sooner that total was reached (never reached sorts last).
static func _rank_key(r: Dictionary) -> Array:
	var at := float(r.get("reached_s", -1))
	return [0 if r.get("finished") == true else 1, -int(r.get("deposited", 0)),
		at if at >= 0.0 else INF]


static func ranked(rows: Array) -> Array:
	var out := rows.duplicate()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ka := _rank_key(a)
		var kb := _rank_key(b)
		for i in ka.size():
			if ka[i] != kb[i]:
				return ka[i] < kb[i]
		return false)
	return out


## Seconds into the match from a server timestamp, given when it started.
static func _seconds_in(stamp: Variant, start: float) -> float:
	if stamp == null:
		return -1.0
	return maxf(0.0, WatchFeed.stamp(str(stamp)) - start)


static func _team_standing(row: Dictionary, index: int, start: float) -> Dictionary:
	return {"name": str(row.name), "index": index, "deposited": int(row.deposited),
		# SQL returns null for finished when the match has no winner_team.
		"finished": row.get("finished") == true, "reached_s": _seconds_in(row.reached_at, start)}


## {teams, players}, ranked, from the server's standings.
func _standings(sid: String) -> Dictionary:
	var session: Dictionary = await Teams.session(sid)
	var ends := Time.get_unix_time_from_datetime_string(str(session.get("ends_at", "")).left(19))
	var start := float(ends) - float(session.get("duration_s", 0))
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/team_standings?select=team_id,name,deposited,reached_at,finished&session_id=eq."
		+ sid + "&order=name")
	var teams: Array = []
	var team_index := {}
	for t: Dictionary in (got.data if got.data is Array else []):
		team_index[str(t.team_id)] = teams.size()
		teams.append(_team_standing(t, teams.size(), start))
	var ps: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/player_standings?select=profile_id,team_id,deposited,reached_at&session_id=eq." + sid)
	var names := {}
	for m: Dictionary in await Teams.everyone(sid):
		names[str(m.profile_id)] = str(m.username)
	var players: Array = []
	for p: Dictionary in (ps.data if ps.data is Array else []):
		players.append({"profile_id": str(p.profile_id), "username": names.get(str(p.profile_id), "?"),
			"team": int(team_index.get(str(p.team_id), 0)), "deposited": int(p.deposited),
			"reached_s": _seconds_in(p.reached_at, start)})
	return {"teams": ranked(teams), "players": ranked(players)}


func go_back() -> void:
	main.open("home")

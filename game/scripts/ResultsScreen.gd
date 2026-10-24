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
		# Spellings are revealed only once the server ends the match. Reload
		# answers too: the end event may precede the last deposit row.
		var final_words := await Monks.words_of(str(result.session_id))
		var final_answers := await Net.rest(HTTPClient.METHOD_GET,
			"/rest/v1/monk_answers?session_id=eq." + str(result.session_id))
		var my_membership := await Teams.membership(str(result.session_id))
		if not is_inside_tree():
			return
		var learned: Array = []
		for w: Dictionary in final_words:
			var state := "missed"
			for a: Dictionary in (final_answers.data if final_answers.data is Array else []):
				if a.get("team_id") == my_membership.get("team_id") and int(a.get("monk", -1)) == int(w.monk):
					state = "deposited" if a.get("deposited_at") != null else "lost"
			learned.append({"word": w.get("word", ""), "modern": w.get("modern", ""), "state": state})
		if not learned.is_empty():
			result["words"] = learned

	_layout(teams, players)


## A MOBA end screen in the paper kit: Victory / Defeat over the score, then
## two tabs -- the Scoreboard (both sides' tables) and the Words (every word
## of the match and its Baybayin) -- and the way on.
func _layout(teams: Array, players: Array) -> void:
	var box := Ui.screen_panel(self, Vector2(600, 330), "")
	box.add_theme_constant_override("separation", 4)
	var title := _title(teams)
	var banner := Art.title(Art.label(title[0], 30, title[1], HORIZONTAL_ALIGNMENT_CENTER))
	Art.shadow(banner, Color(0, 0, 0, 0.35), 2, 0)
	box.add_child(banner)
	box.add_child(Art.label(_subtitle(teams), Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))

	var board := Ui.button("Scoreboard", 150, Ui.H, Ui.SMALL)
	var words_tab := Ui.button("Words", 150, Ui.H, Ui.SMALL)
	Ui.centre_row(box, board).add_child(words_tab)
	Ui.tabs([board, words_tab])
	var area := Control.new()
	area.custom_minimum_size = Vector2(560, 186)
	box.add_child(area)
	var board_page := _scoreboard(teams, players)
	var words_page := _words()
	for page: Control in [board_page, words_page]:
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		area.add_child(page)
	var show := func(words: bool) -> void:
		board_page.visible = not words
		words_page.visible = words
		board.set_pressed_no_signal(not words)
		words_tab.set_pressed_no_signal(words)
	board.pressed.connect(show.bind(false))
	words_tab.pressed.connect(show.bind(true))
	show.call(false)

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


## The score under the banner: "Bughaw 10 – 4 Pula", or Practice's count.
func _subtitle(teams: Array) -> String:
	var monks := int(result.get("monks", 0))
	if teams.is_empty():
		var at := float(result.get("reached_s", -1))
		return "%d of %d words deposited%s" % [int(result.get("my_deposits", 0)), monks,
			("  ·  last at %s" % Ui.mmss(int(at))) if at >= 0.0 else ""]
	var by_side := teams.duplicate()
	by_side.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.index) < int(b.index))
	if by_side.size() < 2:
		return "%s %d" % [by_side[0].name, by_side[0].deposited]
	return "%s  %d  –  %d  %s" % [by_side[0].name, by_side[0].deposited, by_side[1].deposited, by_side[1].name]


## Both sides as tables, Bughaw left and Pula right: hero, name, words
## deposited, when the last went in. The match's best player wears a star.
func _scoreboard(teams: Array, players: Array) -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 20)
	if teams.is_empty():
		# Practice: one side, yours.
		players = [{"profile_id": Net.user_id, "username": _me(), "team": 0,
			"deposited": int(result.get("my_deposits", 0)), "reached_s": float(result.get("reached_s", -1))}]
		teams = [{"name": "You", "index": 0, "deposited": int(result.get("my_deposits", 0)),
			"reached_s": float(result.get("reached_s", -1)), "finished": false}]
	var mvp := ""
	if not players.is_empty() and int(players[0].get("deposited", 0)) > 0 and teams.size() > 1:
		mvp = str(players[0].profile_id)
	var winner := -1
	if teams.size() > 1 and _rank_key(teams[0]) != _rank_key(teams[1]):
		winner = int(teams[0].index)
	var by_side := teams.duplicate()
	by_side.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.index) < int(b.index))
	for t: Dictionary in by_side:
		row.add_child(_side_table(t, players.filter(func(p: Dictionary) -> bool:
			return int(p.team) == int(t.index)), mvp, int(t.index) == winner))
	return row


func _side_table(t: Dictionary, players: Array, mvp: String, won: bool) -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size.x = 260
	col.add_theme_constant_override("separation", 4)
	var index := clampi(int(t.index), 0, 1)
	var head := HBoxContainer.new()
	head.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_theme_constant_override("separation", 6)
	var ribbon_row := Ui.RIBBON_YELLOW if str(t.name) == "You" else (Ui.RIBBON_BLUE if index == 0 else Ui.RIBBON_RED)
	head.add_child(Ui.ribbon(ribbon_row, "%s  %d" % [t.name, int(t.deposited)], 24.0, Pal.LABEL))
	if won:
		head.add_child(Art.label("WINNER", Pal.SMALL, Pal.BRONZE))
	col.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 3)
	for h: String in ["", "Player", "Words", "Last"]:
		grid.add_child(_cell(h, Pal.INK_MUTED, h == "Player"))
	for p: Dictionary in players:
		var me := str(p.profile_id) == Net.user_id
		grid.add_child(_portrait(int(_heroes().get(str(p.profile_id), 0))))
		var star := "★ " if mvp != "" and str(p.profile_id) == mvp else ""
		grid.add_child(_cell(star + str(p.username), Pal.BRONZE if me else Pal.INK, true))
		grid.add_child(_cell(str(int(p.deposited)), Pal.BRONZE if me else Pal.INK, false))
		var at := float(p.get("reached_s", -1))
		grid.add_child(_cell(Ui.mmss(int(at)) if at >= 0.0 else "—", Pal.INK_MUTED, false))
	var scroll := Ui.scroll(col, 132)
	scroll.add_child(grid)
	return col


func _cell(text: String, colour: Color, name: bool) -> Label:
	var l := Art.label(text, Pal.SMALL, colour,
		HORIZONTAL_ALIGNMENT_LEFT if name else HORIZONTAL_ALIGNMENT_CENTER)
	l.custom_minimum_size = Vector2(110 if name else 46, 24)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


## A hero standing, facing out; a shadow of one when it is not known.
func _portrait(hero: int) -> TextureRect:
	var t := TextureRect.new()
	t.texture = Art.grid(Game.hero_sheet(clampi(hero, 1, Game.HERO_COUNT)), 3, 4)[1]
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = Vector2(18, 22)
	if hero < 1 or hero > Game.HERO_COUNT:
		t.modulate = Color(0, 0, 0, 0.3)
	return t


## profile id -> hero, as the match saw them (AdventureScreen passes it).
func _heroes() -> Dictionary:
	var h: Dictionary = result.get("heroes", {})
	if not h.has(Net.user_id):
		h[Net.user_id] = Game.hero_id
	return h


func _me() -> String:
	return Net.username if Net.signed_in() else (Game.player_name if Game.player_name != "" else "You")


## Every word, its Baybayin, and how your team did with it, two columns.
func _words() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.add_child(Art.label("✓ deposited   ✗ carried, lost   · missed", Pal.SMALL, Pal.INK_MUTED,
			HORIZONTAL_ALIGNMENT_CENTER))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 0)
	var centre := CenterContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.add_child(grid)
	Ui.scroll(col, 158).add_child(centre)
	for w: Dictionary in result.get("words", []):
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 6)
		var mark := Art.label(STATE_MARK.get(str(w.state), "·"), Pal.LABEL,
			Pal.CORRECT if w.state == "deposited" else (Pal.WRONG if w.state == "lost" else Pal.INK_MUTED))
		mark.custom_minimum_size = Vector2(16, 0)
		line.add_child(mark)
		var name := Art.label(str(w.word), Pal.LABEL, Pal.INK)
		name.custom_minimum_size = Vector2(90, 0)
		line.add_child(name)
		var glyphs := Art.label(str(w.modern), 20, Pal.TITLE)
		glyphs.add_theme_font_override("font", Art.baybayin())
		glyphs.custom_minimum_size = Vector2(110, 0)
		line.add_child(glyphs)
		grid.add_child(line)
	return col


## [banner text, colour]: Victory, Defeat or Draw -- or Practice's ending.
func _title(teams: Array) -> Array:
	if bool(result.get("practice", true)):
		var monks := int(result.get("monks", 0))
		var all := monks > 0 and int(result.get("my_deposits", 0)) >= monks
		return ["Every word deposited!" if all else "Time's up!", Pal.CORRECT if all else Pal.BRONZE]
	if teams.is_empty():
		return ["Match over", Pal.TITLE]
	var best: Dictionary = teams[0]
	if teams.size() > 1 and _rank_key(teams[1]) == _rank_key(best):
		return ["Draw", Pal.TITLE]
	if int(best.index) == int(result.get("team", 0)):
		return ["Victory!", Pal.CORRECT]
	return ["Defeat", Pal.WRONG]


## A team's or player's place, as something that sorts: finished first, then
## words, then the sooner that total was reached (never reached sorts last).
static func _rank_key(r: Dictionary) -> Array:
	var at := float(r.get("reached_s", -1))
	return [0 if r.get("finished") == true else 1, -int(r.get("deposited", 0)),
		at if at >= 0.0 else INF]


## The same contribution and timestamp share a place, as My Matches does.
static func _place(rows: Array, index: int) -> int:
	var first := index
	while first > 0 and _rank_key(rows[first - 1]) == _rank_key(rows[index]):
		first -= 1
	return first + 1


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

extends Control

## Leaderboards -- the players' board (client, 2026-09-27). Every team of every
## finished game in one list, best first, growing as each game ends:
##
##     Game 1 ends:  Team 1 25 · Team 2 20 · Team 3 15 · Team 4 10
##     Game 2 ends:  Team 5 26 · Team 1 25 · Team 6 24 · Team 2 20 · …
##
## Each row says which game it came from, so two games' "Kidlat" stay apart,
## and how many played for it. Tapping a team shows who played for it and how
## its score adds up. The player's own teams are starred; the top 50 are shown,
## and below them wherever the player's own teams stand.
##
## The teacher keeps the per-game board (`LeaderboardScreen`). Offline, not
## signed in, this shows the phone's own runs, as the old board did.

const TOP := 50
const PANEL := Vector2(600, 330)
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var main: Control
## () -> {error, rows}; see `Board.all_time`.
var fetch_board: Callable = func() -> Dictionary:
	return await Board.all_time()
## (team_id) -> {error, rows}; see `Board.team_players`.
var fetch_team: Callable = func(team_id: String) -> Dictionary:
	return await Board.team_players(team_id)
## Who is looking: their teams get the star.
var me := ""
var offline := false

var _list: VBoxContainer
var _status: Label
var _team: Control = null


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if me == "":
		me = Net.user_id
	offline = not (Net.configured() and Net.signed_in()) if me == Net.user_id else offline
	var box := Ui.back_panel(self, PANEL, "Leaderboards", go_back)
	box.add_theme_constant_override("separation", 5)
	var about := Art.label("Every team from every finished game, best first. Tap a team to see who played.",
			Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	about.custom_minimum_size = Vector2(PANEL.x - 40, 0)
	box.add_child(about)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	DragScroll.attach(scroll)
	box.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)
	_status = Art.label("", Pal.BODY, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(PANEL.x - 60, 0)
	_list.add_child(_status)
	_load()


func _load() -> void:
	for c in _list.get_children():
		if c != _status:
			c.queue_free()
	_status.visible = true
	_status.text = "Loading…"
	if offline:
		_fill_offline()
		return
	var got: Dictionary = await fetch_board.call()
	if not is_instance_valid(_list):
		return
	if str(got.get("error", "")) != "":
		_status.text = "Couldn't load the leaderboard. Check your connection and try again."
		var retry := Ui.button("Try again", 140, Ui.H, Ui.SMALL)
		retry.name = "Retry"
		retry.pressed.connect(_load)
		Ui.centre_row(_list, retry)
		return
	var rows: Array = got.get("rows", [])
	if rows.is_empty():
		_status.text = "No finished games yet. When a game ends, its teams appear here."
		return
	_status.visible = false
	for i in mini(rows.size(), TOP):
		_list.add_child(_row(i + 1, rows[i]))
	# The player's own teams further down: shown with their real place.
	var further: Array = []
	for i in range(TOP, rows.size()):
		if _mine(rows[i]):
			further.append(i)
	if not further.is_empty():
		var head := Art.label("Your teams", Pal.LABEL, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
		head.name = "YourTeams"
		_list.add_child(head)
		for i: int in further:
			_list.add_child(_row(i + 1, rows[i]))


## Not signed in: this phone's own runs, as before -- nothing to tap into.
func _fill_offline() -> void:
	var rows: Array = Game.leaderboard
	if rows.is_empty():
		_status.text = "No scores yet. Sign in and play a game to see the leaderboard."
		return
	_status.text = "Offline: this phone's own games."
	for i in rows.size():
		var r: Dictionary = rows[i]
		_list.add_child(_row(i + 1, {"name": str(r.get("name", "")), "gems": int(r.get("gems", 0))}))


func _mine(r: Dictionary) -> bool:
	return me != "" and (r.get("player_ids", []) as Array).has(me)


# --- One team ----------------------------------------------------------------
func _row(rank: int, r: Dictionary) -> Control:
	var mine := _mine(r)
	var card := Button.new()
	card.name = "Team_%d" % rank
	card.custom_minimum_size = Vector2(0, 46)
	card.focus_mode = Control.FOCUS_NONE
	card.disabled = str(r.get("team_id", "")) == ""
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var face := StyleBoxFlat.new()
		face.bg_color = Pal.PARCHMENT if state == "pressed" else Pal.PAPER
		face.border_color = Pal.INFO_DEEP if mine else Pal.WOOD
		face.set_border_width_all(3 if mine else 2)
		face.set_corner_radius_all(4)
		card.add_theme_stylebox_override(state, face)
	Ui.click(card)
	card.pressed.connect(_open_team.bind(rank, r))

	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 8
	row.offset_right = -10
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(row)

	row.add_child(_badge(rank))
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", -2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_l := _text(("★ " if mine else "") + str(r.get("name", "")), Pal.BODY,
			Pal.INFO_DEEP if mine else Pal.INK)
	name_l.name = "Name"
	col.add_child(name_l)
	var sub := _game_line(r)
	if sub != "":
		var sub_l := _text(sub, Pal.SMALL, Pal.INK_MUTED)
		sub_l.name = "Game"
		col.add_child(sub_l)
	row.add_child(col)
	var gems := Ui.stat_plank(Ui.GEM, str(int(r.get("gems", 0))), Pal.BODY)
	gems.name = "Gems"
	gems.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(gems)
	if not card.disabled:
		# Not `_text`: a clipped label has no minimum width, and the › vanished.
		var more := Art.label("›", Pal.H2, Pal.WOOD)
		more.name = "More"
		more.mouse_filter = Control.MOUSE_FILTER_IGNORE
		more.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(more)
	return card


## 1st, 2nd and 3rd in the podium's gold, silver and bronze; the rest a number.
func _badge(rank: int) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(34, 30)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var face := StyleBoxFlat.new()
	face.bg_color = Pal.PODIUM[rank - 1] if rank <= 3 else Color(0, 0, 0, 0)
	face.border_color = Pal.WOOD
	face.set_border_width_all(2 if rank <= 3 else 0)
	face.set_corner_radius_all(15)
	p.add_theme_stylebox_override("panel", face)
	var l := Art.label(str(rank), Pal.BODY, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	l.name = "Rank"
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(l)
	return p


## "Game 3 · Sep 27 · 5 players"
func _game_line(r: Dictionary) -> String:
	if not r.has("game_no"):
		return ""
	var bits: Array[String] = ["Game %d" % int(r.game_no)]
	var day := _day(r.get("played_at"))
	if day != "":
		bits.append(day)
	var n := int(r.get("members", 0))
	bits.append("%d player%s" % [n, "" if n == 1 else "s"])
	return "  ·  ".join(bits)


static func _day(v: Variant) -> String:
	var at: int = Teams._stamp(v)
	if at <= 0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(at + int(Time.get_time_zone_from_system().bias) * 60)
	return "%s %d" % [MONTHS[int(d.month) - 1], int(d.day)]


# --- Who played for it -------------------------------------------------------
func _open_team(rank: int, r: Dictionary) -> void:
	if _team != null and is_instance_valid(_team):
		return
	_team = Control.new()
	_team.name = "TeamPanel"
	_team.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_team.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_team)
	Ui.dim(_team)
	var title := "#%d  %s" % [rank, str(r.get("name", ""))]
	var box := Ui.back_panel(_team, Vector2(520, 300), title, _close_team)
	box.add_theme_constant_override("separation", 4)
	var sub := Art.label(_game_line(r), Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(sub)
	var list := VBoxContainer.new()
	list.name = "Players"
	list.add_theme_constant_override("separation", 3)
	box.add_child(list)
	var wait := Art.label("Loading…", Pal.BODY, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	list.add_child(wait)
	var got: Dictionary = await fetch_team.call(str(r.get("team_id", "")))
	if not is_instance_valid(list):
		return
	wait.queue_free()
	if str(got.get("error", "")) != "":
		list.add_child(Art.label("Couldn't load this team. Check your connection.", Pal.BODY,
				Pal.WRONG, HORIZONTAL_ALIGNMENT_CENTER))
		return
	var players: Array = got.get("rows", [])
	list.add_child(_player_line(["Player", "Gems", "Right", "Finish"], true, false))
	var out := 0
	var short := 0
	var sum := 0
	for p: Dictionary in players:
		list.add_child(_player_line([p.username, str(p.gems), str(p.correct), _finish(p)],
				false, str(p.get("profile_id", "")) == me))
		sum += int(p.gems)
		if bool(p.eliminated):
			out += 1
		if int(p.items_done) < Game.TOTAL_ITEMS:
			short += 1
	# How the team's score adds up, when it does -- the gems it earned, less
	# what going out and not finishing cost.
	var parts: Array[String] = ["%d gems" % sum]
	if out > 0:
		parts.append("−%d (%d out)" % [out * -Game.GEM_ELIMINATED, out])
	if short > 0:
		parts.append("−%d (%d didn't finish)" % [short * -Game.GEM_TEAM_FINISH_PENALTY, short])
	var total := sum + out * Game.GEM_ELIMINATED + short * Game.GEM_TEAM_FINISH_PENALTY
	var how := Art.label(("Team score %d = %s" % [total, "  ".join(parts)]) if total == int(r.get("gems", total))
			else "Team score %d" % int(r.get("gems", 0)), Pal.SMALL, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	how.name = "Score"
	box.add_child(how)


func _player_line(cells: Array, head: bool, mine: bool) -> Control:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	var weights := [30, 10, 10, 12]
	for i in cells.size():
		var l := _text(("★ " if mine and i == 0 else "") + str(cells[i]),
				Pal.SMALL if head else Pal.BODY,
				Pal.INK_MUTED if head else (Pal.INFO_DEEP if mine else Pal.INK))
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.size_flags_stretch_ratio = weights[i]
		line.add_child(l)
	return line


## Through the Gate in mm:ss, "Out" if they ran out of gems, else "DNF".
static func _finish(p: Dictionary) -> String:
	if int(p.get("finish_s", -1)) >= 0:
		return Ui.mmss(int(p.finish_s))
	return "Out" if bool(p.get("eliminated", false)) else "DNF"


func _close_team() -> void:
	if _team != null and is_instance_valid(_team):
		_team.queue_free()
	_team = null


func _text(t: String, size: int, col: Color) -> Label:
	var l := Art.label(t, size, col)
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func go_back() -> void:
	if _team != null and is_instance_valid(_team):
		_close_team()
		return
	if main != null:
		main.open("home")

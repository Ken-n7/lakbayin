extends Control

## Team Ranking. Online it is the live board -- gems summed per team by the
## `team_scores` view. Offline it falls back to this machine's saved runs, which
## is all an unconnected dev run has.
##
## A fetch, not a subscription: see `Board` for why only the admin watches.

## Minutes of silence before a teacher should look at that student.
const IDLE_WARN_S := 180

var main: Control

var _list: VBoxContainer
var _tab := 0
var _watching := false


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	Ui.dim(self)
	var box := Ui.screen_panel(self, Vector2(560, 330), "Live Leaderboard"
		if _is_admin() else "Team Ranking")
	box.add_theme_constant_override("separation", 6)

	# Two tabs, per the mockup -- but only for the teacher. A student's board
	# shows teams, because the winner is a team and never a player (§3).
	if _is_admin():
		var tabs := HBoxContainer.new()
		tabs.alignment = BoxContainer.ALIGNMENT_CENTER
		tabs.add_theme_constant_override("separation", 6)
		for i in 2:
			var label: String = "Team Ranking" if i == 0 else "Player Ranking"
			var b := Ui.button(label, 150, Ui.H, Ui.RED if _tab == i else Ui.SMALL)
			var which := i
			b.pressed.connect(func() -> void:
				_tab = which
				_rebuild())
			tabs.add_child(b)
		box.add_child(tabs)

	var scroll := Ui.scroll(box, 165)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)

	var note := Art.label("Gems reset to %d for every adventure. Finish all stations to avoid the −%d penalty." %
			[Game.START_GEMS, -(Game.GEM_TEAM_FINISH_PENALTY)], Pal.TINY, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(note)

	var back := Ui.button("Back", Ui.W_WIDE, Ui.H, Ui.RED)
	back.pressed.connect(func() -> void: main.open("admin" if _is_admin() else "home"))
	Ui.centre_row(box, back)

	_fill()
	_watch()


func _is_admin() -> bool:
	return Net.configured() and Net.signed_in() and Net.role == "admin"


## Only the teacher's board subscribes. Every answered item writes a `members`
## row; forty students watching that turns ~200 realtime messages an adventure
## into ~22,000, for a screen they are not looking at mid-run.
func _watch() -> void:
	if not _is_admin() or Game.session_id == "" or _watching:
		return
	_watching = true
	var rt: Realtime = Net.realtime()
	rt.changed.connect(func(table: String, _t: String, _r: Dictionary) -> void:
		if table == "members" and is_instance_valid(_list):
			_fill())
	rt.watch("members", "session_id=eq." + Game.session_id)


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_watching = false
	_build()


func _fill() -> void:
	if not is_instance_valid(_list):
		return
	for c in _list.get_children():
		c.queue_free()
	if _tab == 1:
		_fill_players()
	else:
		_fill_teams()


func _fill_teams() -> void:
	_row(["Rank", "Team", "Gems"], [12, 40, 12])
	var rows: Array = []
	if Net.configured() and Net.signed_in() and Game.session_id != "":
		rows = await Board.teams(Game.session_id)
	if rows.is_empty():
		rows = Game.leaderboard
	if rows.is_empty():
		_list.add_child(Art.label("No scores yet.", Pal.SMALL, Pal.INK_MUTED,
				HORIZONTAL_ALIGNMENT_CENTER))
		return
	for i in rows.size():
		var r: Dictionary = rows[i]
		_row([str(i + 1), str(r.get("name", "")), str(r.get("gems", 0))], [12, 40, 12],
			_row_is_me(r))


## What a spectating teacher actually reads: who is scoring, who is answering,
## and who has not touched anything in minutes.
func _fill_players() -> void:
	_row(["Rank", "Username", "Gems", "Right", "Idle"], [10, 30, 12, 10, 12])
	var rows: Array = await Board.players(Game.session_id)
	if rows.is_empty():
		_list.add_child(Art.label("Nobody has joined yet.", Pal.SMALL, Pal.INK_MUTED,
				HORIZONTAL_ALIGNMENT_CENTER))
		return
	for i in rows.size():
		var r: Dictionary = rows[i]
		_row([str(i + 1), str(r.username), str(r.gems), str(r.correct),
			Ui.mmss(int(r.idle_s))], [10, 30, 12, 10, 12], false,
			int(r.idle_s) >= IDLE_WARN_S)


## `weights` are the column widths; `mine` highlights the player's own row and
## `stale` flags somebody who has stopped answering.
func _row(cells: Array, weights: Array, mine := false, stale := false) -> void:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	for i in cells.size():
		var c := _cell(str(cells[i]), int(weights[i]))
		if mine:
			c.add_theme_color_override("font_color", Pal.INFO_DEEP)
			c.add_theme_color_override("font_shadow_color", Color(1, 1, 1, 0.6))
		elif stale:
			c.add_theme_color_override("font_color", Pal.WRONG)
		line.add_child(c)
	_list.add_child(line)


func _cell(text: String, weight: int, color: int = -1) -> Label:
	var l := Art.label(text, Pal.BODY,
			Pal.INK if color < 0 else _gem_color(color), HORIZONTAL_ALIGNMENT_LEFT)
	l.custom_minimum_size = Vector2(0, 24)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_stretch_ratio = weight
	return l


func _row_is_me(row: Dictionary) -> bool:
	var me := Game.me()
	return str(row.name) == me


func _gem_color(g: int) -> Color:
	if g >= 450:
		return Pal.AMBER
	if g >= 300:
		return Pal.GOLD_DIM
	return Pal.WOOD
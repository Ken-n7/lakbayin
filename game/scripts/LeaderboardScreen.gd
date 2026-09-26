extends Control

## Team Ranking. Online it is the live board -- gems summed per team by the
## `team_scores` view. Offline it falls back to this machine's saved runs, which
## is all an unconnected dev run has.
##
## A fetch, not a subscription: see `Board` for why only the admin watches.


var main: Control

var _list: VBoxContainer
var _tab := 0
var _watching := false
## Which session this board shows. `Game.session_id` is only ever set by the
## map, which a teacher never opens -- so the admin's "Live Leaderboard" was
## reading "" and showing this device's offline runs instead of the class.
var _sid := ""


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	if _sid == "":
		_sid = await _find_session()
	# No scrim: Main's moving scene is the background (Backdrop.gd), and a
	# 90% dim over it would show nothing on this screen alone.
	# Back is the ← in the title, not a big red button competing with nothing.
	var box := Ui.back_panel(self, Vector2(600, 330), "Live Leaderboard"
		if _is_admin() else "Team Ranking", go_back)
	box.add_theme_constant_override("separation", 6)

	# Two tabs, per the mockup -- but only for the teacher. A student's board
	# shows teams, because the winner is a team and never a player (§3).
	if _is_admin():
		var tabs := HBoxContainer.new()
		tabs.alignment = BoxContainer.ALIGNMENT_CENTER
		tabs.add_theme_constant_override("separation", 18)
		for i in 2:
			var t := Ui.tab_text("Team Ranking" if i == 0 else "Player Ranking", _tab == i)
			var which := i
			Ui.tab_button(t).pressed.connect(func() -> void:
				_tab = which
				_rebuild())
			tabs.add_child(t)
		box.add_child(tabs)

	var scroll := ScrollContainer.new()
	DragScroll.attach(scroll)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)

	var note := Art.label("Gems reset to %d for every adventure. Finish all stations to avoid the −%d penalty." %
			[Game.START_GEMS, -(Game.GEM_TEAM_FINISH_PENALTY)], Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(540, 0)
	box.add_child(note)

	_fill()
	_watch()


## The teacher's newest session, running or finished -- a finished one is the
## result they came to read. A player's is the one they last played, else the
## one they joined by code.
func _find_session() -> String:
	if not (Net.configured() and Net.signed_in()):
		return ""
	if not _is_admin():
		return Game.session_id if Game.session_id != "" else Game.joined_session
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/sessions?select=id&admin_id=eq." + Net.user_id
		+ "&order=created_at.desc&limit=1")
	var rows: Array = got.data if got.data is Array else []
	return str(rows[0].get("id", "")) if not rows.is_empty() else ""


func _is_admin() -> bool:
	return Net.configured() and Net.signed_in() and Net.role == "admin"


## Only the teacher's board subscribes. Every answered item writes a `members`
## row; forty students watching that turns ~200 realtime messages an adventure
## into ~22,000, for a screen they are not looking at mid-run.
func _watch() -> void:
	if not _is_admin() or _sid == "" or _watching:
		return
	_watching = true
	var rt: Realtime = Net.realtime()
	rt.changed.connect(func(table: String, _t: String, _r: Dictionary) -> void:
		if table == "members" and is_instance_valid(_list):
			_fill())
	rt.watch("members", "session_id=eq." + _sid)


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
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
	var rows: Array = []
	if _sid != "":
		rows = await Board.teams(_sid)
	if rows.is_empty():
		rows = Game.leaderboard
	if rows.is_empty():
		_list.add_child(Art.label("No scores yet.", Pal.SMALL, Pal.INK_MUTED,
				HORIZONTAL_ALIGNMENT_CENTER))
		return
	if not is_instance_valid(_list):
		return
	_list.add_child(_podium(rows.slice(0, 3)))
	# Fourth place and below, as rows under the podium.
	if rows.size() > 3:
		_row(["Rank", "Team", "Gems"], [12, 40, 12])
		for i in range(3, rows.size()):
			var r: Dictionary = rows[i]
			_row([str(i + 1), str(r.get("name", "")), str(int(r.get("gems", 0)))], [12, 40, 12],
				_row_is_me(r))


## The mockup's podium: first in the middle and tallest, second to its left,
## third to its right -- gold, silver, bronze -- each team's gems on a plank
## over its step, and the player's own team starred.
func _podium(top: Array) -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	var heights := [74.0, 52.0, 36.0]
	for place in [1, 0, 2]:
		if place >= top.size():
			continue
		var r: Dictionary = top[place]
		var col := VBoxContainer.new()
		col.alignment = BoxContainer.ALIGNMENT_END
		col.add_theme_constant_override("separation", 3)
		col.custom_minimum_size = Vector2(140, 150)
		var mine := _row_is_me(r)
		var name := Art.label(("★ " if mine else "") + str(r.get("name", "")), Pal.LABEL,
			Pal.INFO_DEEP if mine else Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
		name.clip_text = true
		name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col.add_child(name)
		var gems := CenterContainer.new()
		gems.add_child(Ui.stat_plank(Ui.GEM, str(int(r.get("gems", 0))), Pal.BODY))
		col.add_child(gems)
		var step := PanelContainer.new()
		var face := StyleBoxFlat.new()
		face.bg_color = Pal.PODIUM[place]
		face.border_color = Pal.WOOD
		face.set_border_width_all(2)
		face.corner_radius_top_left = 4
		face.corner_radius_top_right = 4
		step.add_theme_stylebox_override("panel", face)
		step.custom_minimum_size = Vector2(130, heights[place])
		var num := Art.label(str(place + 1), Pal.H1, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
		num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		step.add_child(num)
		col.add_child(step)
		row.add_child(col)
	return row


## What a spectating teacher actually reads: who is scoring, who is answering,
## and each player's own time through the Victory Gate ("—" while still out).
func _fill_players() -> void:
	_row(["Rank", "Username", "Gems", "Right", "Time"], [10, 30, 12, 10, 12])
	var rows: Array = await Board.players(_sid)
	if rows.is_empty():
		_list.add_child(Art.label("Nobody has joined yet.", Pal.SMALL, Pal.INK_MUTED,
				HORIZONTAL_ALIGNMENT_CENTER))
		return
	for i in rows.size():
		var r: Dictionary = rows[i]
		_row([str(i + 1), str(r.username), str(r.gems), str(r.correct),
			Ui.mmss(int(r.finish_s)) if int(r.finish_s) >= 0 else "—"], [10, 30, 12, 10, 12])


## `weights` are the column widths; `mine` highlights the player's own row.
func _row(cells: Array, weights: Array, mine := false) -> void:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	for i in cells.size():
		var c := _cell(str(cells[i]), int(weights[i]))
		if mine:
			c.add_theme_color_override("font_color", Pal.INFO_DEEP)
			c.add_theme_color_override("font_shadow_color", Color(1, 1, 1, 0.6))
		line.add_child(c)
	_list.add_child(line)


func _cell(text: String, weight: int, color: int = -1) -> Label:
	var l := Art.label(text, Pal.BODY,
			Pal.INK if color < 0 else _gem_color(color), HORIZONTAL_ALIGNMENT_LEFT)
	l.custom_minimum_size = Vector2(0, 24)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_stretch_ratio = weight
	return l


func go_back() -> void:
	main.open("admin" if _is_admin() else "home")


func _row_is_me(row: Dictionary) -> bool:
	var me := Game.me()
	return str(row.name) == me


func _gem_color(g: int) -> Color:
	if g >= 450:
		return Pal.AMBER
	if g >= 300:
		return Pal.GOLD_DIM
	return Pal.WOOD
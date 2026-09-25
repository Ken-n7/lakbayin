extends Control

## Adventure summary: gem total, per-station results and where the party ranks.

var main: Control
var result: Dictionary = {}


func setup(data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	result = data
	_build()


func _build() -> void:
	# No scrim: Main's moving scene is the background (Backdrop.gd).
	# Online the ranking is the class's, team totals from the server. The
	# local board only knows this phone's runs, and listed the player's own
	# gems as if they were the team's.
	var rows: Array = Game.leaderboard
	if _online():
		var live: Array = await Board.teams(Game.session_id)
		if not is_instance_valid(self):
			return
		if not live.is_empty():
			rows = live
	var me := Game.me()
	var place := -1
	for i in rows.size():
		if str(rows[i].name) == me:
			place = i

	var box := Ui.screen_panel(self, Vector2(600, 330), "")
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 8)

	# What happened, as a banner: the run's own ribbon, not a panel heading.
	var aborted := result.is_empty()
	var time_up := bool(result.get("time_up", false))
	var head := CenterContainer.new()
	head.add_child(Ui.ribbon(Ui.RIBBON_GREY if aborted else Ui.RIBBON_RED if time_up
		else Ui.RIBBON_YELLOW, "Adventure ended" if aborted else "Time's Up!" if time_up
		else "Adventure Complete!", 30, Pal.H2))
	box.add_child(head)
	var line := "Adventure aborted." if aborted else (
		"%s finished #%d of %d teams!" % [me, place + 1, rows.size()] if place >= 0
		else "A brave attempt, %s." % (Net.username if Net.signed_in() else Game.player_name))
	box.add_child(Art.label(line, Pal.LABEL, Pal.BRONZE, HORIZONTAL_ALIGNMENT_CENTER))

	# The number, big on its plank, and how it was made, as four tiles.
	var mid := HBoxContainer.new()
	mid.alignment = BoxContainer.ALIGNMENT_CENTER
	mid.add_theme_constant_override("separation", 10)
	var total := VBoxContainer.new()
	total.alignment = BoxContainer.ALIGNMENT_CENTER
	total.add_child(Art.label("Final gems", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	var gems := Ui.stat_plank(Ui.GEM, str(int(result.get("gems", Game.gems))), 26)
	total.add_child(gems)
	mid.add_child(total)
	for tile in [["Correct", "correct", Pal.CORRECT], ["Wrong", "wrong", Pal.WRONG],
			["Skipped", "skipped", Pal.INK_MUTED], ["Hints", "hints", Pal.INFO]]:
		mid.add_child(_tile(str(result.get(tile[1], 0)), tile[0], tile[2]))
	box.add_child(mid)

	# The three stations, each in its own colour: ★ perfect, ✓ done, ✗ not.
	var stations := HBoxContainer.new()
	stations.alignment = BoxContainer.ALIGNMENT_CENTER
	stations.add_theme_constant_override("separation", 6)
	var colours := [Pal.INFO, Pal.AMBER, Pal.WRONG]
	for i in Game.ITEMS_PER_STATION.size():
		var done: bool = (result.get("completed", [false, false, false]) as Array)[i]
		var perfect: bool = (result.get("perfect", [false, false, false]) as Array)[i]
		var mark := "★" if perfect else "✓" if done else "✗"
		stations.add_child(_chip("%s  %s" % [mark, QuestionGen.station_meta(i).short],
			colours[i], done))
	box.add_child(stations)

	# The top of the class, one line -- the Leaderboard button has the rest.
	var top := rows.slice(0, 3)
	var standing := ""
	for i in top.size():
		standing += "%d. %s  %d      " % [i + 1, str(top[i].name), int(top[i].gems)]
	if standing != "":
		box.add_child(Art.label(standing.strip_edges(), Pal.SMALL, Pal.INK,
			HORIZONTAL_ALIGNMENT_CENTER))

	# The way on is the big one, on the right; the other two beside it.
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 10)
	var home := Ui.button("Home", 110, Ui.H, Ui.SMALL)
	home.pressed.connect(func() -> void: main.open("home"))
	var board_btn := Ui.button("Leaderboard", 130, Ui.H, Ui.SMALL)
	board_btn.pressed.connect(func() -> void: main.open("board"))
	# Online a new run is a new session, joined by code like the first;
	# straight onto the map would be a run the server is not scoring.
	var again := Ui.button("Adventure again", 190, Ui.H, Ui.RED)
	again.pressed.connect(func() -> void: main.open("team" if _online() else "adventure"))
	btns.add_child(home)
	btns.add_child(board_btn)
	btns.add_child(again)
	box.add_child(btns)


## A count and what it counts, on a small card.
func _tile(value: String, caption: String, colour: Color) -> Control:
	var card := PanelContainer.new()
	var face := StyleBoxFlat.new()
	face.bg_color = Pal.PARCHMENT.darkened(0.05)
	face.border_color = colour
	face.set_border_width_all(2)
	face.set_corner_radius_all(4)
	face.set_content_margin_all(4)
	card.add_theme_stylebox_override("panel", face)
	card.custom_minimum_size = Vector2(70, 0)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", -2)
	col.add_child(Art.label(value, Pal.H1, colour, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(Art.label(caption, Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	card.add_child(col)
	return card


## A station's result: bordered in its livery, dimmed if it was not reached.
func _chip(text: String, colour: Color, done: bool) -> Control:
	var chip := PanelContainer.new()
	var face := StyleBoxFlat.new()
	face.bg_color = Color(colour, 0.15 if done else 0.05)
	face.border_color = colour if done else Color(colour, 0.4)
	face.set_border_width_all(2)
	face.set_corner_radius_all(10)
	face.content_margin_left = 8
	face.content_margin_right = 8
	face.content_margin_top = 2
	face.content_margin_bottom = 2
	chip.add_theme_stylebox_override("panel", face)
	chip.add_child(Art.label(text, Pal.SMALL, colour if done else Pal.INK_MUTED))
	return chip


func _online() -> bool:
	return Net.configured() and Net.signed_in() and Game.session_id != ""

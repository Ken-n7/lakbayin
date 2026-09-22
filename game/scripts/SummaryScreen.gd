extends Control

## Adventure summary: gem total, per-station results and where the party ranks.

var main: Control
var result: Dictionary = {}


func setup(data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	result = data
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.10, 0.07, 0.12, 0.92)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var won := false
	if not result.is_empty():
		var rows := Game.leaderboard
		var me := Game.team_name if Game.team_name != "" else Game.player_name
		won = not rows.is_empty() and str(rows[0].name) == me

	var panel := Ui.panel(Vector2(580, 318), "Adventure Complete!" if not result.get("time_up", false) else "Time's Up!")
	panel.position = Vector2(30, 21)
	add_child(panel)
	var box: VBoxContainer = panel.get_child(0) as VBoxContainer
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)

	var headline := Art.label(
		("Legendary finish — the party leads the board!" if won else
		 "A brave attempt, %s." % Game.player_name) if not result.is_empty() else "Adventure aborted.",
		18, Color("7a5216"), HORIZONTAL_ALIGNMENT_CENTER)
	headline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(headline)

	var gems := Art.label("Final gems:  %d" % result.get("gems", Game.gems), 26,
			Color("e09a1f"), HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(gems)

	var line := Art.label(
		"Correct %d   ·   Wrong %d   ·   Skipped %d   ·   Hints %d" %
		[result.get("correct", 0), result.get("wrong", 0),
			result.get("skipped", 0), result.get("hints", 0)],
		14, Color("2a201a"), HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(line)

	var stations := ""
	for i in 3:
		var done: bool = (result.get("completed", [false, false, false]) as Array)[i]
		var perfect: bool = (result.get("perfect", [false, false, false]) as Array)[i]
		var mark := "✗" if not done else ("★" if perfect else "✓")
		stations += "  %s: %s" % [QuestionGen.station_meta(i).short, mark]
	box.add_child(Art.label(stations, 13, Color("3a5a8c"), HORIZONTAL_ALIGNMENT_CENTER))

	var top := Game.leaderboard.slice(0, 4)
	var top_txt := ""
	for i in top.size():
		top_txt += "%d  %s — %d    " % [i + 1, str(top[i].name), int(top[i].gems)]
	# Four ranked entries run well past 640px unwrapped -- found on a real device,
	# where the row ran off the right edge with no way to scroll and see the rest.
	var party := Art.label("Party: " + top_txt.strip_edges(), 13, Color("2a201a"),
			HORIZONTAL_ALIGNMENT_CENTER)
	party.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	party.custom_minimum_size = Vector2(540, 0)
	box.add_child(party)

	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 10)
	var again := Ui.button("Adventure again", 150, 46, Ui.RED)
	again.pressed.connect(func() -> void: main.open("adventure"))
	var board_btn := Ui.button("Leaderboard", 120, 42, Ui.SMALL)
	board_btn.pressed.connect(func() -> void: main.open("board"))
	var home := Ui.button("Home", 90, 42, Ui.SMALL)
	home.pressed.connect(func() -> void: main.open("title"))
	btns.add_child(again)
	btns.add_child(board_btn)
	btns.add_child(home)
	box.add_child(btns)
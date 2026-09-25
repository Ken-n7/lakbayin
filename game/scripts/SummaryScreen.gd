extends Control

## Adventure summary: gem total, per-station results and where the party ranks.

var main: Control
var result: Dictionary = {}


func setup(data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	result = data
	_build()


func _build() -> void:
	# No scrim: Main's moving scene is the background (Backdrop.gd), and a
	# 90% dim over it would show nothing on this screen alone.

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
	var won := false
	if not result.is_empty():
		won = not rows.is_empty() and str(rows[0].name) == Game.me()

	var box := Ui.screen_panel(self, Vector2(580, 318),
			"Adventure Complete!" if not result.get("time_up", false) else "Time's Up!")
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)

	var headline := Art.label(
		("Legendary finish — the party leads the board!" if won else
		 "A brave attempt, %s." % Game.player_name) if not result.is_empty() else "Adventure aborted.",
		18, Pal.BRONZE, HORIZONTAL_ALIGNMENT_CENTER)
	headline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(headline)

	var gems := Art.label("Final gems:  %d" % result.get("gems", Game.gems), 26,
			Pal.AMBER, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(gems)

	var line := Art.label(
		"Correct %d   ·   Wrong %d   ·   Skipped %d   ·   Hints %d" %
		[result.get("correct", 0), result.get("wrong", 0),
			result.get("skipped", 0), result.get("hints", 0)],
		14, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(line)

	var stations := ""
	for i in Game.ITEMS_PER_STATION.size():
		var done: bool = (result.get("completed", [false, false, false]) as Array)[i]
		var perfect: bool = (result.get("perfect", [false, false, false]) as Array)[i]
		var mark := "✗" if not done else ("★" if perfect else "✓")
		stations += "  %s: %s" % [QuestionGen.station_meta(i).short, mark]
	box.add_child(Art.label(stations, Pal.SMALL, Pal.INFO, HORIZONTAL_ALIGNMENT_CENTER))

	var top := rows.slice(0, 4)
	var top_txt := ""
	for i in top.size():
		top_txt += "%d  %s — %d    " % [i + 1, str(top[i].name), int(top[i].gems)]
	# Four ranked entries run well past 640px unwrapped -- found on a real device,
	# where the row ran off the right edge with no way to scroll and see the rest.
	var party := Art.label("Party: " + top_txt.strip_edges(), Pal.SMALL, Pal.INK,
			HORIZONTAL_ALIGNMENT_CENTER)
	party.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	party.custom_minimum_size = Vector2(540, 0)
	box.add_child(party)

	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 10)
	var again := Ui.button("Adventure again", 150, 46, Ui.RED)
	# Online a new run is a new session, joined by team name like the first;
	# straight onto the map would be a run the server is not scoring.
	again.pressed.connect(func() -> void: main.open("team" if _online() else "adventure"))
	var board_btn := Ui.button("Leaderboard", 120, 42, Ui.SMALL)
	board_btn.pressed.connect(func() -> void: main.open("board"))
	var home := Ui.button("Home", 90, 42, Ui.SMALL)
	home.pressed.connect(func() -> void: main.open("home"))
	btns.add_child(again)
	btns.add_child(board_btn)
	btns.add_child(home)
	box.add_child(btns)


func _online() -> bool:
	return Net.configured() and Net.signed_in() and Game.session_id != ""

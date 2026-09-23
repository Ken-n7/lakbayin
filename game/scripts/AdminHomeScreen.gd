extends Control

## The teacher's landing screen. Same furniture as the player's Home, five tabs
## instead of four, and the mockup's copy word for word (SPECS §1: the PDFs are
## a mechanics and wording contract; the art stays ours).

const INSET := 16

var main: Control


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var who := Art.label(Net.username if Net.signed_in() else "admin",
			Pal.LABEL, Pal.GOLD)
	who.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	who.offset_left = INSET
	who.offset_right = INSET + 200
	who.offset_top = INSET
	who.offset_bottom = INSET + 20
	add_child(who)

	var out := Ui.button("Log Out", 76, 28, Ui.SMALL_RED)
	out.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	out.offset_left = -(INSET + 76)
	out.offset_right = -INSET
	out.offset_top = INSET
	out.offset_bottom = INSET + 28
	out.pressed.connect(func() -> void:
		Net.sign_out()
		main.open("login"))
	add_child(out)

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	col.offset_left = -280
	col.offset_right = 280
	col.offset_top = 70
	col.add_theme_constant_override("separation", 8)
	add_child(col)

	var hail := Art.label("Welcome to NumXventure Admin Dashboard!", Pal.H2,
			Pal.PARCHMENT, HORIZONTAL_ALIGNMENT_CENTER)
	Art.shadow(hail, Pal.SHADOW, 2, 0)
	col.add_child(hail)

	var sub := Art.label("Monitor student progress, manage activities, and support "
			+ "learners in mastering mathematical skills through interactive gameplay.",
			Pal.SMALL, Pal.WHITE_SOFT, HORIZONTAL_ALIGNMENT_CENTER)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size = Vector2(520, 0)
	col.add_child(sub)

	_build_status(col)

	Ui.tab_bar(self, [["Home", "admin"], ["Game Controls", "controls"],
			["Leaderboard", "board"], ["Question Management", "questions"],
			["Feedback", "feedback"]],
		func(route: String) -> void: main.open(route), INSET, INSET)


## The one number a teacher needs before pressing Start: whether the bank can
## actually fill the stations. Start Game refuses on the same check.
func _build_status(col: VBoxContainer) -> void:
	var line := Art.label("Checking the question bank...", Pal.SMALL, Pal.WHITE_DIM,
			HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(line)
	var short: String = await QuestionStore.shortfall()
	if not is_instance_valid(line):
		return   # the teacher moved on while the request was in flight
	if short == "":
		line.text = "Question bank ready: %d / %d / %d items." % [
			Game.ITEMS_PER_STATION[0], Game.ITEMS_PER_STATION[1], Game.ITEMS_PER_STATION[2]]
		line.add_theme_color_override("font_color", Pal.GOLD)
	else:
		line.text = "Question bank incomplete — " + short
		line.add_theme_color_override("font_color", Pal.WRONG)


func go_back() -> void:
	get_tree().quit()

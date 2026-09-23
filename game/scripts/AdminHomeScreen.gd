extends Control

## The teacher's landing screen. Same furniture as the player's Home, five tabs
## instead of four, and the mockup's copy word for word (SPECS §1: the PDFs are
## a mechanics and wording contract; the art stays ours).

const INSET := 16
const COL_W := 186
const BTN_H := 30

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

	# Same shape as the player's Home: one column down the left. A landscape
	# phone has width to spare and height to save, and five tabs along the
	# bottom had to clip their own labels to fit.
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	col.offset_left = INSET
	col.offset_right = INSET + COL_W
	col.offset_top = INSET + 30
	col.custom_minimum_size = Vector2(COL_W, 0)
	col.add_theme_constant_override("separation", 4)
	add_child(col)

	var hail := Art.label("Admin Dashboard", Pal.H2,
			Pal.PARCHMENT, HORIZONTAL_ALIGNMENT_CENTER)
	Art.shadow(hail, Pal.SHADOW, 2, 0)
	col.add_child(hail)

	var sub := Art.label("Monitor student progress, manage activities, and support "
			+ "learners in mastering mathematical skills through interactive gameplay.",
			Pal.TINY, Pal.WHITE_SOFT, HORIZONTAL_ALIGNMENT_CENTER)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size = Vector2(COL_W, 0)
	col.add_child(sub)

	_build_status(col)

	for spec in [["Game Controls", "controls"], ["Question Management", "questions"],
			["Leaderboard", "board"], ["Feedback", "feedback"]]:
		var b := Ui.button(spec[0], COL_W, BTN_H, Ui.SMALL)
		b.clip_text = true
		var route: String = spec[1]
		b.pressed.connect(func() -> void: main.open(route))
		col.add_child(b)


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

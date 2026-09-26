extends "res://scripts/HomeScreen.gd"

## The teacher's dashboard. Deliberately the player's Home with different words
## and different destinations -- same island, same header, same column -- so
## the two cannot drift into looking like two different apps.
##
## Copy is the mockup's own, per SPECS §1: the PDFs are a mechanics and wording
## contract, the art stays ours.


func _hail() -> String:
	return "Welcome to NumXventure Admin Dashboard!"


func _sub() -> String:
	return "Run the session."


func _tagline() -> String:
	return ""


func _entries() -> Array:
	return [
		# Straight into a fresh session with its code; Game Controls and the
		# Teams tab are where it is run, and leaving ends it.
		["Start Session", "controls", Ui.RED, {"new": true}, "play"],
		# "Question Bank": "Question Management" did not fit beside its icon,
		# and the line under the menu already calls it the bank.
		["Question Bank", "questions", Ui.SMALL, {}, "question"],
		["Leaderboard", "board", Ui.SMALL, {}, "trophy"],
		["Feedback", "feedback", Ui.SMALL, {}, "feedback"],
	]


## Back on the dashboard quits straight away, as it always has.
func go_back() -> void:
	get_tree().quit()


## A teacher never picked a character.
func _show_portrait() -> bool:
	return false


## The one number a teacher needs before pressing Start: whether the bank can
## fill the stations. Start Game refuses on this same check.
func _after_menu(col: VBoxContainer) -> void:
	# The player's Settings (volumes, Log Out) and a Quit that asks first --
	# side by side, as a sixth full row ran off the canvas.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	for spec: Array in [["Settings", _open_settings, "gear"], ["Quit", _confirm_quit, "exit"]]:
		var b := Ui.button(spec[0], (COL_W - 6) / 2.0, BTN_H, Ui.SMALL)
		b.icon = Art.tex(ICONS % spec[2])
		b.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_constant_override("h_separation", 4)
		b.pressed.connect(spec[1])
		row.add_child(b)
	col.add_child(row)

	var line := Art.label("Checking the question bank...", Pal.TINY, Pal.WHITE_DIM,
			HORIZONTAL_ALIGNMENT_CENTER)
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.custom_minimum_size = Vector2(COL_W, 0)
	col.add_child(line)

	var short: String = await QuestionStore.shortfall()
	if not is_instance_valid(line):
		return   # the teacher moved on while the request was in flight
	if short == "":
		line.text = "Bank ready — %d / %d / %d" % [
			Game.ITEMS_PER_STATION[0], Game.ITEMS_PER_STATION[1], Game.ITEMS_PER_STATION[2]]
		line.add_theme_color_override("font_color", Pal.GOLD)
	else:
		line.text = "Bank short — see Question Bank"
		line.add_theme_color_override("font_color", Pal.WRONG)

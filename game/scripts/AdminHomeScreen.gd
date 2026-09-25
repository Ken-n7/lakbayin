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
		["Start Session", "controls", Ui.RED, {"new": true}],
		["Question Management", "questions", Ui.SMALL],
		["Leaderboard", "board", Ui.SMALL],
		["Feedback", "feedback", Ui.SMALL],
	]


## Log Out stays on the header here: this column has no room for Settings
## and Quit alongside the four destinations.
func _logout_in_settings() -> bool:
	return false


## Back on the dashboard quits straight away, as it always has.
func go_back() -> void:
	get_tree().quit()


## A teacher never picked a character.
func _show_portrait() -> bool:
	return false


## The one number a teacher needs before pressing Start: whether the bank can
## fill the stations. Start Game refuses on this same check.
func _after_menu(col: VBoxContainer) -> void:
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
		line.text = "Bank short — see Question Management"
		line.add_theme_color_override("font_color", Pal.WRONG)

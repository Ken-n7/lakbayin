extends Control

## "Start Adventure -> enter Team Name -> Ready!", split out of hero select.
##
## The team name is also the join code (SPECS §3): the admin generates the
## names in Game Controls and each player types the one they were given, and a
## name that is not one of them is refused.
##
## With no backend there is nobody to check against, so the name is recorded
## and the run starts as it always did -- which is how an offline dev run and
## the headless suites still reach the map.

const PANEL := Vector2(360, 230)

var main: Control

var _team: LineEdit
var _msg: Label
var _go: Button


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := Ui.screen_panel(self, PANEL, "Enter Team Name")
	box.add_child(Art.label("Type the team name your teacher gave you.",
			Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))

	_team = Ui.field(box, "Team", "e.g. Math Mavericks")
	_team.text = Game.team_name
	_team.max_length = 18
	_team.text_submitted.connect(func(_t: String) -> void: _begin())

	_msg = Art.label("", Pal.SMALL, Pal.WRONG, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_msg)

	_go = Ui.button("Ready!", 300, Ui.H, Ui.RED)
	_go.pressed.connect(_begin)
	Ui.centre_row(box, _go)

	var back := Ui.button("Back", 300, Ui.H, Ui.SMALL)
	back.pressed.connect(go_back)
	Ui.centre_row(box, back)
	# Deliberately no grab_focus(): on a phone that opens the soft keyboard
	# immediately, over the form the student has not read yet.


func _begin() -> void:
	var name := _team.text.strip_edges()
	if name.is_empty():
		_say("Enter a team name.", Pal.WRONG)
		return

	if Net.configured() and Net.signed_in():
		_busy(true)
		var err: String = await Teams.join(name)
		_busy(false)
		if err != "":
			_say(err, Pal.WRONG)
			return

	Game.team_name = name
	Game.save_profile()
	Game.begin_adventure(int(Game.duration_seconds))
	main.open("adventure")


func _busy(on: bool) -> void:
	_go.disabled = on
	_go.text = "Joining..." if on else "Ready!"


func _say(text: String, col: Color) -> void:
	_msg.text = text
	_msg.add_theme_color_override("font_color", col)


func go_back() -> void:
	main.open("home")

extends Control

## "Start Adventure -> enter Team Name -> Ready!", split out of hero select.
##
## The team name is also the join code (SPECS §3): the admin generates the
## names in Game Controls and each player types the one they were given. Until
## Phase 4 there is nobody to check it against, so it is recorded and carried
## into the run as it always was.

const PANEL := Vector2(360, 230)

var main: Control

var _team: LineEdit
var _msg: Label


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

	var go := Ui.button("Ready!", 300, Ui.H, Ui.RED)
	go.pressed.connect(_begin)
	Ui.centre_row(box, go)

	var back := Ui.button("Back", 300, Ui.H, Ui.SMALL)
	back.pressed.connect(go_back)
	Ui.centre_row(box, back)
	_team.grab_focus()


func _begin() -> void:
	var name := _team.text.strip_edges()
	if name.is_empty():
		_msg.text = "Enter a team name."
		return
	Game.team_name = name
	Game.save_profile()
	Game.begin_adventure(int(Game.duration_seconds))
	main.open("adventure")


func go_back() -> void:
	main.open("home")

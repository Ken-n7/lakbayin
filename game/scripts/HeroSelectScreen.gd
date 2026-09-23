extends Control

## Profile & hero creation: name, class and colour before
## the adventure map opens. (Login-style flows are web concerns; offline we
## just pick a hero.)

var main: Control

var _name_field: LineEdit
var _team_field: LineEdit
var _preview: AnimatedSprite2D
var _hero_buttons: Dictionary = {}
var _hero_id := 1


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	Ui.dim(self)
	var outer := Ui.screen_panel(self, Vector2(560, 330), "Create your adventurer")
	outer.alignment = BoxContainer.ALIGNMENT_CENTER
	outer.add_theme_constant_override("separation", 6)
	var scroll := Ui.scroll(outer, 205)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 10)
	# Without this the scroll sizes the column to its own minimum width and every
	# row hugs the left edge, centred inside a box narrower than the panel.
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)

	_name_field = Ui.line_edit("Adventurer name", 240, 32)
	_name_field.text = Game.player_name
	_name_field.max_length = 18
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 10)
	name_row.add_child(Art.label("Name:", 15))
	name_row.add_child(_name_field)
	box.add_child(name_row)

	_team_field = Ui.line_edit("Team name (optional)", 240, 32)
	_team_field.text = Game.team_name
	_team_field.max_length = 18
	var team_row := HBoxContainer.new()
	team_row.add_theme_constant_override("separation", 10)
	team_row.add_child(Art.label("Team:", 15))
	team_row.add_child(_team_field)
	box.add_child(team_row)

	box.add_child(_preview_row())

	box.add_child(Art.label("Hero", 16, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER))
	# 32 characters, 8 per row. Each button is just the sheet's standing frame:
	# no colour or class to combine, the sprite IS the choice.
	# A CenterContainer, because SIZE_SHRINK_CENTER on the grid itself leaves it
	# hugging the left edge of the scroll.
	var grid_center := CenterContainer.new()
	var grid := GridContainer.new()
	grid.columns = 8
	grid_center.add_child(grid)
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	for id in range(1, Game.HERO_COUNT + 1):
		var b := Button.new()
		b.custom_minimum_size = Vector2(32, 40)   # exactly x2 of the 16x20 frame
		b.icon = Art.grid(Game.hero_sheet(id), 3, 4)[1]
		b.expand_icon = true
		b.tooltip_text = "Adventurer #%d" % id
		b.focus_mode = Control.FOCUS_ALL
		b.pressed.connect(_pick_hero.bind(id))
		_hero_buttons[id] = b
		grid.add_child(b)
	box.add_child(grid_center)

	var start := Ui.button("Begin Adventure", 210, 52, Ui.RED)
	start.pressed.connect(_begin)
	box.add_child(start)
	var back := Ui.button("Back", 70, 34, Ui.SMALL)
	back.pressed.connect(func() -> void: main.open("home"))
	Ui.centre_row(box, back)

	_pick_hero(Game.hero_id)


func _preview_row() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	# The sprite is centred on its own origin, so it has to sit at the middle of
	# the wrap -- at (0, 10) half the hero was clipped away.
	_preview = AnimatedSprite2D.new()
	_preview.scale = Vector2(3, 3)
	var wrap := Control.new()
	wrap.custom_minimum_size = Vector2(96, 64)
	wrap.add_child(_preview)
	wrap.clip_contents = true
	_preview.position = Vector2(48, 32)
	row.add_child(wrap)
	return row


func _pick_hero(id: int) -> void:
	_hero_id = id
	for k in _hero_buttons:
		for state in ["normal", "pressed", "hover", "focus"]:
			_hero_buttons[k].add_theme_stylebox_override(state, _swatch_style(k == id))
	_preview.sprite_frames = Art.walk_frames(Game.hero_sheet(_hero_id), 6.0)
	_preview.play("down")


## A selected character gets a gold ring; the rest stay bare so the grid reads
## as sprites rather than 32 buttons.
func _swatch_style(selected: bool) -> StyleBox:
	if not selected:
		return StyleBoxEmpty.new()
	var ring := StyleBoxFlat.new()
	ring.bg_color = Color(1, 1, 1, 0.16)
	ring.border_color = Pal.CREAM
	ring.set_border_width_all(2)
	return ring


func _begin() -> void:
	if _name_field.text.strip_edges() == "":
		_name_field.text = "Adventurer"
	Game.player_name = _name_field.text.strip_edges()
	Game.team_name = _team_field.text.strip_edges()
	Game.hero_id = _hero_id
	Game.save_profile()
	Game.begin_adventure(int(Game.duration_seconds))
	main.open("adventure")

extends Control

## Picking the adventurer: which of the 32 heroes, and the name over it. Then
## on to the team screen, which is what starts the run.

var main: Control

var _name_field: LineEdit
var _preview: AnimatedSprite2D
var _hero_buttons: Dictionary = {}
var _hero_id := 1
var _hero_label: Label


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()


## Two halves: who you are on the left -- the hero large, turning, with your
## name under it -- and who you could be on the right. The old stack put a
## 64px preview over a strip that showed two rows of heroes at a time.
func _build() -> void:
	# No scrim: Main's moving scene is the background (Backdrop.gd).
	var outer := Ui.screen_panel(self, Vector2(600, 330), "Create Your Adventurer")
	outer.add_theme_constant_override("separation", 6)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(body)

	# Left: the preview on a little patch of ground, then the name.
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(190, 0)
	left.add_theme_constant_override("separation", 4)
	body.add_child(left)
	left.add_child(_preview_stage())
	_hero_label = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	left.add_child(_hero_label)
	left.add_child(Art.label("Your name", Pal.LABEL, Pal.INK_MUTED))
	_name_field = Ui.line_edit("Adventurer name", 190, 30)
	_name_field.text = Game.player_name
	_name_field.max_length = 18
	left.add_child(_name_field)

	# Right: all 32, six across at a size a thumb can pick from.
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 4)
	body.add_child(right)
	right.add_child(Art.label("Choose your hero", Pal.H2, Pal.TITLE))
	var grid_scroll := ScrollContainer.new()
	grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(grid_scroll)
	var grid_center := CenterContainer.new()
	grid_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_scroll.add_child(grid_center)
	var grid := GridContainer.new()
	grid.columns = 7
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	grid_center.add_child(grid)
	for id in range(1, Game.HERO_COUNT + 1):
		var b := Button.new()
		b.custom_minimum_size = Vector2(46, 54)   # the 16x20 frame, near x2.5
		b.icon = Art.grid(Game.hero_sheet(id), 3, 4)[1]
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.tooltip_text = "Adventurer #%d" % id
		b.focus_mode = Control.FOCUS_ALL
		b.pressed.connect(_pick_hero.bind(id))
		_hero_buttons[id] = b
		grid.add_child(b)

	# Back on the left, the one thing to do on the right and biggest.
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	var back := Ui.button("Back", Ui.W_MED, Ui.H, Ui.SMALL)
	back.pressed.connect(func() -> void: main.open("home"))
	row.add_child(back)
	var start := Ui.button("Begin Adventure", 240, Ui.H, Ui.RED)
	start.pressed.connect(_begin)
	row.add_child(start)
	outer.add_child(row)

	_pick_hero(Game.hero_id)


## The chosen hero, big, on a patch of the map's own grass, walking in place
## and turning to face each way in turn -- a sprite sheet shown off, not a
## thumbnail.
func _preview_stage() -> Control:
	var stage := PanelContainer.new()
	var face := StyleBoxFlat.new()
	face.bg_color = Color("5a9a4a")
	face.border_color = Pal.WOOD
	face.set_border_width_all(2)
	face.set_corner_radius_all(4)
	stage.add_theme_stylebox_override("panel", face)
	stage.custom_minimum_size = Vector2(190, 132)
	var wrap := Control.new()
	wrap.clip_contents = true
	stage.add_child(wrap)
	var shade := Sprite2D.new()
	shade.texture = Art.tex("res://assets/terrain/tileset/Shadow.png")
	shade.scale = Vector2(0.55, 0.4)
	shade.modulate.a = 0.5
	shade.position = Vector2(95, 104)
	wrap.add_child(shade)
	_preview = AnimatedSprite2D.new()
	_preview.scale = Vector2(4, 4)
	_preview.offset = Vector2(0, -10)      # feet on the ground
	_preview.position = Vector2(95, 106)
	wrap.add_child(_preview)
	var turn := stage.create_tween().set_loops()
	for facing in ["down", "right", "up", "left"]:
		turn.tween_callback(func() -> void:
			if is_instance_valid(_preview):
				_preview.play(facing))
		turn.tween_interval(1.4)
	return stage


func _pick_hero(id: int) -> void:
	_hero_id = id
	for k in _hero_buttons:
		for state in ["normal", "pressed", "hover", "focus"]:
			_hero_buttons[k].add_theme_stylebox_override(state, _swatch_style(k == id, state == "hover"))
	var anim: String = _preview.animation if _preview.sprite_frames != null else "down"
	_preview.sprite_frames = Art.walk_frames(Game.hero_sheet(_hero_id), 6.0)
	_preview.play(anim)
	_hero_label.text = "Adventurer #%d" % id


## The chosen one gets a gold ring on a lit tile; the rest a faint tile, so
## the grid reads as a set of choices rather than 32 loose sprites -- and a
## hover shows which one a click would take.
func _swatch_style(selected: bool, hover := false) -> StyleBox:
	var tile := StyleBoxFlat.new()
	tile.set_corner_radius_all(4)
	if selected:
		tile.bg_color = Color(Pal.GOLD, 0.30)
		tile.border_color = Pal.AMBER
		tile.set_border_width_all(3)
	else:
		tile.bg_color = Color(Pal.WOOD, 0.22 if hover else 0.12)
		tile.border_color = Color(Pal.WOOD, 0.6 if hover else 0.0)
		tile.set_border_width_all(2)
	return tile


func _begin() -> void:
	if _name_field.text.strip_edges() == "":
		_name_field.text = "Adventurer"
	Game.player_name = _name_field.text.strip_edges()
	Game.hero_id = _hero_id
	Game.save_profile()
	# The team name is its own screen now (G16), and it is what starts the run.
	main.open("team")

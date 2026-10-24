extends Node

## The logo: "Lakbayin" in Baybayin, in the menus' gold, on the dark paper
## of the Find Match button and the profile plate. Game assets only.
##
##   godot --path game res://tools/logo_shot.tscn -- <out.png> [px] [mode]
##
## px: the image's width and height, 1024 by default. mode:
##   logo   the title on its paper (the default)
##   paper  the paper alone, its border off the edges: an adaptive icon's
##          background layer
##   words  the title alone, small enough for an adaptive icon's safe zone
##          (a circle the middle 61% wide), its foreground layer
##   mono   the same, one flat white: Android's themed-icon layer

## La-k-ba-yi-n, the modern (krus-kudlit) spelling, broken at its syllable
## -- lak / bayin -- to sit square, the shape of an icon.
const TITLE := "ᜎᜃ᜔\nᜊᜌᜒᜈ᜔"
const SIZE := Vector2i(128, 128)
## The words' canvas: the title spans ~72% of SIZE; on this, ~47% -- clear
## of the round mask some launchers cut, and of its pinched sides.
const ICON_SIZE := Vector2i(200, 200)
const LAYERS := [[Pal.INK, Vector2(0, 3), 8], [Pal.INK, Vector2.ZERO, 8],
	[Pal.GOLD_DIM, Vector2(0, 1), 0], [Pal.CREAM, Vector2(0, -1), 0], [Pal.GOLD, Vector2.ZERO, 0]]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var px := int(args[1]) if args.size() > 1 else 1024
	var mode: String = args[2] if args.size() > 2 else "logo"
	var view := ICON_SIZE if mode in ["words", "mono"] else SIZE
	var vp := SubViewport.new()
	vp.size = Vector2i(px, px)
	vp.size_2d_override = view
	vp.size_2d_override_stretch = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var stack := Control.new()
	stack.size = Vector2(view)
	if mode in ["logo", "paper"]:
		var plate := PanelContainer.new()
		plate.add_theme_stylebox_override("panel", Ui.face("res://assets/ui/SpecialPaper.png"))
		plate.size = Vector2(SIZE)
		if mode == "paper":
			# Past every edge, so only the paper's middle shows.
			plate.size = Vector2(SIZE) * 1.5
			plate.position = -Vector2(SIZE) * 0.25
		vp.add_child(plate)
		if mode == "logo":
			stack = Control.new()
			plate.add_child(stack)
	if mode != "paper":
		if stack.get_parent() == null:
			vp.add_child(stack)
		# A title's pop, from the one font in layers: a hard drop shadow, a
		# thick ink outline, then the gold with a darker lip below and a
		# cream glint above, each a pixel off -- a bevel.
		for layer: Array in ([[Color.WHITE, Vector2.ZERO, 8]] if mode == "mono" else LAYERS):
			stack.add_child(_word(layer[0], layer[1], layer[2]))
	for i in 10:
		await get_tree().process_frame
	vp.get_texture().get_image().save_png(args[0])
	get_tree().quit(0)


func _word(colour: Color, shift: Vector2, outline: int) -> Label:
	var word := Art.label(TITLE, 39, colour, HORIZONTAL_ALIGNMENT_CENTER)
	word.add_theme_font_override("font", Art.baybayin())
	# The font's line box holds room for marks above and below each line;
	# the two lines' own marks need much less.
	word.add_theme_constant_override("line_spacing", -16)
	word.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	word.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	word.offset_left = shift.x
	word.offset_right = shift.x
	word.offset_top = shift.y
	word.offset_bottom = shift.y
	if outline > 0:
		word.add_theme_color_override("font_outline_color", colour)
		word.add_theme_constant_override("outline_size", outline)
	return word

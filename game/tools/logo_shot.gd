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
		var title := Art.gold_title(TITLE, 39, -16,
				[[Color.WHITE, Vector2.ZERO, 8]] if mode == "mono" else Art.GOLD_LAYERS)
		title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		stack.add_child(title)
	for i in 10:
		await get_tree().process_frame
	vp.get_texture().get_image().save_png(args[0])
	get_tree().quit(0)


extends Node

## The logo: "Lakbayin" in Baybayin, in the menus' gold, on the dark paper
## of the Find Match button and the profile plate. Game assets only.
##
##   godot --path game res://tools/logo_shot.tscn -- <out.png> [scale]
## The default scale, 8, gives 1024 x 1024.

## La-k-ba-yi-n, the modern (krus-kudlit) spelling, broken at its syllable
## -- lak / bayin -- to sit square, the shape of an icon.
const TITLE := "ᜎᜃ᜔\nᜊᜌᜒᜈ᜔"
const SIZE := Vector2i(128, 128)


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var k := int(args[1]) if args.size() > 1 else 8
	var vp := SubViewport.new()
	vp.size = SIZE * k
	vp.size_2d_override = SIZE
	vp.size_2d_override_stretch = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", Ui.face("res://assets/ui/SpecialPaper.png"))
	plate.size = Vector2(SIZE)
	vp.add_child(plate)
	var word := Art.label(TITLE, 39, Pal.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	# The font's line box holds room for marks above and below each line;
	# the two lines' own marks need much less.
	word.add_theme_constant_override("line_spacing", -16)
	word.add_theme_font_override("font", Art.baybayin())
	word.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	plate.add_child(word)
	for i in 10:
		await get_tree().process_frame
	vp.get_texture().get_image().save_png(args[0])
	get_tree().quit(0)

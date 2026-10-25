extends Node

## The trailer's and the gameplay video's words, drawn the game's way -- its
## fonts, its gold title, its paper -- each a transparent 1920x1080 PNG for
## the edit to lay over the footage (tools/edit.py). Game assets only.
##
##   godot --path game res://tools/cards.tscn -- <cards.json> <out dir>
##
## cards.json: [{"name", "kind", "text", "sub"}]. Kinds: "logo" (the Baybayin
## title, the name, the tagline), "beat" (a trailer's line, centred), "caption"
## (a lower third on a paper plank), "small" (a line along the bottom), "bar"
## (a line in the letterbox's bottom bar), "badge" (a corner tag: 2x).

const LOGO := "ᜎᜃ᜔ᜊᜌᜒᜈ᜔"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var cards: Array = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var vp := SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.size_2d_override = Vector2i(640, 360)
	vp.size_2d_override_stretch = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	for card: Dictionary in cards:
		var root := Control.new()
		root.size = Vector2(640, 360)
		vp.add_child(root)
		_build(root, card)
		for i in 4:
			await get_tree().process_frame
		vp.get_texture().get_image().save_png(args[1].path_join(str(card.name) + ".png"))
		root.queue_free()
		await get_tree().process_frame
	get_tree().quit(0)


func _build(root: Control, card: Dictionary) -> void:
	var text := str(card.get("text", ""))
	var sub := str(card.get("sub", ""))
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	match str(card.kind):
		"logo":
			box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			var t := Art.gold_title(LOGO, 64)
			# Its own measure comes out of the tree, before the font is set.
			t.custom_minimum_size = Vector2(460, 104)
			t.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			box.add_child(t)
			var name := Art.title(Art.label("Lakbayin", 30, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER))
			Art.shadow(name, Color(0, 0, 0, 0.9), 2, 4)
			box.add_child(name)
			var tag := Art.tagline(Pal.H2)
			Art.shadow(tag, Color(0, 0, 0, 0.9), 1, 4)
			box.add_child(tag)
			var en := Art.label("Hanapin. Isulat. Ipanalo.", Pal.SMALL, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
			Art.shadow(en, Color(0, 0, 0, 0.9), 1, 3)
			box.add_child(en)
			if sub != "":
				var s := Art.label(sub, 11, Color(1, 1, 1, 0.85), HORIZONTAL_ALIGNMENT_CENTER)
				Art.shadow(s, Color(0, 0, 0, 0.9), 1, 3)
				box.add_child(s)
			root.add_child(box)
		"beat":
			box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			var l := Art.title(Art.label(text, int(card.get("size", 34)), Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER))
			Art.shadow(l, Color(0, 0, 0, 0.95), 2, 6)
			box.add_child(l)
			if sub != "":
				var s := Art.label(sub, Pal.H2, Pal.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
				if sub.unicode_at(0) >= 0x1700 and sub.unicode_at(0) < 0x1720:
					s.add_theme_font_override("font", Art.baybayin())
				Art.shadow(s, Color(0, 0, 0, 0.95), 1, 4)
				box.add_child(s)
			root.add_child(box)
		"caption":
			var inner := VBoxContainer.new()
			inner.add_theme_constant_override("separation", 0)
			var head := Art.title(Art.label(text, Pal.H2, Pal.TITLE))
			inner.add_child(head)
			if sub != "":
				var s := Art.label(sub, Pal.SMALL, Pal.INK)
				s.add_theme_font_override("font", Art.mixed())
				inner.add_child(s)
			var plate := Ui.panel(Vector2.ZERO)
			(plate.get_child(0) as Node).add_child(inner)
			plate.position = Vector2(14, 0)
			root.add_child(plate)
			await get_tree().process_frame
			plate.position.y = 360 - plate.size.y - 12
		"bar":
			# In the trailer's bottom letterbox bar (edit.py: 132 of 1080 px).
			var l := Art.title(Art.label(text, 22, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER))
			Art.shadow(l, Color(0, 0, 0, 0.95), 1, 3)
			l.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
			l.offset_top = -44
			l.offset_bottom = 0
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			root.add_child(l)
		"badge":
			var plate := PanelContainer.new()
			var bg := StyleBoxFlat.new()
			bg.bg_color = Color(0, 0, 0, 0.55)
			bg.set_corner_radius_all(6)
			bg.content_margin_left = 8
			bg.content_margin_right = 8
			plate.add_theme_stylebox_override("panel", bg)
			plate.add_child(Art.label(text, Pal.BODY, Color.WHITE))
			root.add_child(plate)
			await get_tree().process_frame
			plate.position = Vector2(640 - plate.size.x - 12, 44)
		"small":
			var l := Art.label(text, int(card.get("size", Pal.SMALL)), Color(1, 1, 1, 0.9), HORIZONTAL_ALIGNMENT_CENTER)
			Art.shadow(l, Color(0, 0, 0, 0.9), 1, 3)
			l.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
			l.grow_horizontal = Control.GROW_DIRECTION_BOTH
			l.offset_top = -44
			l.offset_bottom = -12
			root.add_child(l)

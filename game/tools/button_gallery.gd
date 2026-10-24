extends Node

## Every kind of button in the game, grouped, drawn with the real helpers.
##   godot --path game res://tools/button_gallery.tscn -- <out.png>

const GROUPS := [
	["1  Primary action  (Ui.RED, big red)", [["Sign In", 300], ["Register", 300], ["Find Match", 260], ["Create Room", 260], ["Ready!", 300], ["Ready — Enter Map", 230], ["Set", 240], ["Submit", 200], ["Move", 280], ["Find another match", 200]], 1],
	["2  Big blue  (Ui.BLUE)", [["Join", 126]], 0],
	["3  Secondary  (Ui.SMALL, small blue)", [["Create Account", 150], ["Use another account", 190], ["Watch", 126], ["Back", 120], ["Leave", 120], ["Home", 120], ["My Matches", 120], ["Global Players", 180], ["Previous", 100], ["Next", 100], ["Refresh", 90], ["Shuffle", 90], ["Move Player", 118], ["Stay", 110], ["Show", 64], ["Change Character", 280], ["Player Records", 280], ["Credits", 280]], 2],
	["4  Danger  (Ui.SMALL_RED, small red)", [["Log Out", 76], ["Log Out", 137], ["Quit", 110]], 3],
]


func _ready() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	var vp := SubViewport.new()
	vp.size = Vector2i(2850, 3000)
	vp.size_2d_override = Vector2i(950, 1000)
	vp.size_2d_override_stretch = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.size = Vector2(950, 1000)
	vp.add_child(bg)
	var root := VBoxContainer.new()
	root.position = Vector2(10, 6)
	root.add_theme_constant_override("separation", 3)
	vp.add_child(root)

	for g: Array in GROUPS:
		_head(root, g[0])
		var flow := HFlowContainer.new()
		flow.custom_minimum_size = Vector2(930, 0)
		flow.add_theme_constant_override("h_separation", 6)
		flow.add_theme_constant_override("v_separation", 4)
		root.add_child(flow)
		for spec: Array in g[1]:
			flow.add_child(Ui.button(spec[0], spec[1], Ui.H, g[2]))

	_head(root, "5  Home menu column  (200x38, icons)")
	var menu := HBoxContainer.new()
	menu.add_theme_constant_override("separation", 6)
	root.add_child(menu)
	for spec: Array in [["Find Match", 1, "play"], ["Custom Room", 2, "swords"], ["Practice", 2, "shield"], ["Settings", 2, "gear"], ["Quit", 2, "close"]]:
		var b := Ui.button(spec[0], 178, 38, spec[1])
		b.icon = Ui.icon(spec[2])
		b.add_theme_constant_override("h_separation", 6)
		menu.add_child(b)

	_head(root, "6  Baybayin keypad  (44x52 keys, red backspace)   ·   7  In-match touch: GO")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 30)
	root.add_child(row)
	var pad := BaybayinKeypad.new()
	row.add_child(pad)
	var go := TextureRect.new()
	go.texture = Art.tex("res://assets/ui/SmallBlueRoundButton_Regular.png")
	go.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	go.custom_minimum_size = Vector2(66, 66)
	go.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var gl := Art.label("GO", 20, Pal.WHITE_STRONG, HORIZONTAL_ALIGNMENT_CENTER)
	gl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	gl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	go.add_child(gl)
	row.add_child(go)
	var leave := Ui.button("Leave", 70, 30, Ui.SMALL)
	leave.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(leave)

	_head(root, "8  Text links   ·   9  Icon / glyph buttons   ·   10  Dropdown")
	var misc := HBoxContainer.new()
	misc.add_theme_constant_override("separation", 14)
	root.add_child(misc)
	for t: String in ["Back", "Sign In"]:
		misc.add_child(Ui.link(t))
	misc.add_child(Ui.icon_button(Art.tex("res://assets/ui/icons/gear.png"), "Mute"))
	misc.add_child(Ui.glyph("←", 24, Pal.CREAM))
	var opt := Ui.option(200)
	opt.add_item("Pick a player")
	misc.add_child(opt)

	for i in 30:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var used := (root.get_rect().size + Vector2(20, 12)) * 3
	img = img.get_region(Rect2i(0, 0, mini(int(used.x), 2850), mini(int(used.y), 3000)))
	print("ok " if img.save_png(out) == OK else "FAIL ", out)
	get_tree().quit(0)


func _head(root: Control, text: String) -> void:
	var l := Art.label(text, 15, Pal.GOLD)
	root.add_child(l)

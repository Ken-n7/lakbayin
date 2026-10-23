extends Control

## Landing screen: an island diorama behind a left-anchored menu column.
##
## Layout is anchor- and inset-based rather than centred-and-absolute: the column
## stays put and only the scene area grows if the viewport aspect ever widens
## (phones are 19.5:9-20:9, the project canvas is 16:9). Nothing important sits
## within INSET of an edge, which is where a landscape notch and the Android
## gesture bar live.

const WATER_BG := "res://assets/terrain/tileset/Water Background color.png"
const TILEMAP_COLOR := "res://assets/terrain/tileset/Tilemap_color1.png"
const MONASTERY := "res://assets/buildings/Purple_Monastery.png"
const TREE := "res://assets/terrain/decorations/Tree1.png"

const INSET := 16      # safe-area gutter, ~5% of the 360px canvas height
const COL_W := 200     # button width
const MENU_W := 248    # full Baybayin tagline, centred over the buttons
const TITLE_SIZE := 36  # the game's name over the menu
const ICONS := "res://assets/ui/icons/%s.png"
const BTN_H := 38.0    # five equal touch targets fit above the bottom gutter
const TILE := 32       # world px per cell; art is 64px drawn at 0.5
const W := 27          # 27 x 32 = 864: covers 800, which is what `keep_height`
                       # gives a 20:9 phone. At 21 the right edge of the screen
                       # showed the clear colour past the water.
const H := 12          # 12 x 32 = 384, over-covers 360
const ISLE := Vector2(13.2, 6.2)    # island centre, in cells
const ISLE_R := Vector2(6.0, 3.9)   # island radii, in cells

var main: Control

var _world: Node2D
var _land := {}   # Vector2i -> true


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_scene()
	resized.connect(_position_scene)
	_position_scene()
	_build_menu()
	_build_header()
	_build_footer()


# --- What a subclass changes ------------------------------------------------
## The admin dashboard is this screen with different words and different
## destinations, so it inherits the island, the header and the footer and
## overrides only these four. Anything else and the two drift apart.
## The player's strapline. The admin column has no room for it once the
## mockup's longer heading has wrapped.
func _tagline() -> String:
	return Art.TAGLINE


## [label, route, button kind, data, icon]; an empty route means "work it
## out" via `_adventure_route()`, and a Callable is run instead of opened.
## Change Character and Log Out live in Settings (client), which is what
## makes room for Quit.
func _entries() -> Array:
	return [
		["Find Match", "", Ui.SMALL_RED, {}, "play"],
		# Friends by a code, any number a side (RoomScreen).
		["Custom Room", _open_room, Ui.SMALL, {}, "hero"],
		# Alone, offline, with the keypad's Latin labels: learning the script.
		["Practice", "adventure", Ui.SMALL, {"practice": true}, "book"],
		["Settings", _open_settings, Ui.SMALL, {}, "gear"],
		["Quit", _confirm_quit, Ui.SMALL, {}, "exit"],
	]


## Log Out on the header, or in Settings. The admin dashboard keeps it on the
## header: its column has no room for Settings and Quit.
func _logout_in_settings() -> bool:
	return true


## Hook for anything a subclass wants under the buttons.
func _after_menu(_col: VBoxContainer) -> void:
	pass


# --- Scene ------------------------------------------------------------------
## The island is a fixed composition, not a procedural map: every prop is placed
## by hand so the Monastery stays the focal point and the menu column always has
## quiet water behind it. No RNG, so it looks the same every launch.
func _build_scene() -> void:
	_world = Node2D.new()
	_world.y_sort_enabled = true
	add_child(_world)

	var water: TileMapLayer = Art.terrain_layer(WATER_BG, TILE, [Vector2i(0, 0)])
	# The raw tile is a pale teal (#47aba9); multiply it toward a deeper sea blue
	# so the grass reads against it and the menu gradient has something to sit on.
	water.modulate = MapCfg.WATER_TINT
	# Keep the sea fixed while the island centres in the wider scene area.
	add_child(water)
	for y in H:
		for x in W:
			water.set_cell(Vector2i(x, y), 0, Vector2i(0, 0))

	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			if _is_land(c):
				_land[c] = true
	# Water, then the surf breaking on the shore, then the island over it --
	# the pack's own layer order (its tilemap guide).
	water.z_index = -2
	Art.shore_foam(_world, _land, TILE).z_index = -1
	var grass: TileMapLayer = Art.terrain_layer(TILEMAP_COLOR, TILE)
	_world.add_child(grass)
	for cell in _land:
		grass.set_cell(cell, 0, Art.autotile(
				_land.has(cell + Vector2i(-1, 0)), _land.has(cell + Vector2i(1, 0)),
				_land.has(cell + Vector2i(0, -1)), _land.has(cell + Vector2i(0, 1))))

	_build_props()
	_build_hero()
	# Clouds drifting over the island, under the vignette and the menu.
	add_child(Clouds.new(W * TILE, 30.0, 130.0))

	var vignette := ColorRect.new()
	vignette.color = Color(Pal.BG, 0.28)
	vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vignette)


func _position_scene() -> void:
	_world.position.x = maxf(size.x - Pal.CANVAS.x, 0.0) * 0.5


## Ellipse biased right of centre with an angular wobble, so the island body
## clears the menu column and the shoreline is not a perfect oval. Kept small
## enough that open water frames it on all four sides.
func _is_land(c: Vector2i) -> bool:
	var nx := (c.x + 0.5 - ISLE.x) / ISLE_R.x
	var ny := (c.y + 0.5 - ISLE.y) / ISLE_R.y
	var ang := atan2(ny, nx)
	return sqrt(nx * nx + ny * ny) < 0.93 + 0.08 * sin(ang * 2.0 + 3.4) + 0.05 * cos(ang * 4.0 + 1.2)


func _at(cx: float, cy: float) -> Vector2:
	return Vector2(cx * TILE, cy * TILE)


func _build_props() -> void:
	# A village clearing: the place the journey leads back to.
	var monastery := Art.sprite(_world, Art.cell(MONASTERY, 0, 0), _at(13.3, 6.0), 0.5)
	monastery.name = "Monastery"
	for spec in [["Blue_House1", 9.5, 7.6], ["Red_House1", 17.1, 7.5]]:
		var house := Art.sprite(_world, Art.cell("res://assets/buildings/%s.png" % spec[0], 0, 0),
			_at(spec[1], spec[2]), 0.45)
		house.name = str(spec[0])
	for spec in [[8.6, 5.8, 1.0], [17.6, 5.6, -1.0], [9.1, 9.1, 1.0], [17.3, 9.4, 1.0]]:
		var tree := Art.anim_sprite(_world, TREE, _at(spec[0], spec[1]), 0.42, 3.0, spec[2])
		tree.frame = int(abs(tree.position.x)) % 8
	for i in 2:
		var monk := Monk.new()
		monk.name = "GuideMonk%d" % i
		monk.index = i
		monk.position = _at(11.0 if i == 0 else 16.0, 8.7 if i == 0 else 8.5)
		_world.add_child(monk)
	for spec in [["Bush1", 10.0, 5.6], ["Bush3", 15.1, 5.2], ["Bush2", 16.0, 9.7]]:
		var bush := Art.anim_sprite(_world, "res://assets/terrain/decorations/%s.png" % spec[0],
			_at(spec[1], spec[2]), 0.45, 3.0)
		Art.sit_on_art(bush)
	for c in [["blue_b", 10.4, 9.8, 0.85], ["yellow_a", 8.4, 7.0, 0.8], ["red_c", 16.2, 10.0, 0.8]]:
		var rock := Art.sprite(_world, Art.tex(MapCfg.plain_rock(c[0])), _at(c[1], c[2]), c[3])
		rock.name = c[0]


## One adventurer exploring the clearing in front of the Monastery. A looping tween
## rather than _process: the menu has no other per-frame work to do.
func _build_hero() -> void:
	var hero := Node2D.new()
	hero.position = _at(12.0, 9.1)
	_world.add_child(hero)

	var shade := Sprite2D.new()
	shade.texture = Art.tex("res://assets/terrain/tileset/Shadow.png")
	shade.scale = Vector2(0.3, 0.3)
	shade.modulate.a = 0.55
	shade.position = Vector2(0, 2)
	hero.add_child(shade)

	var spr := AnimatedSprite2D.new()
	spr.sprite_frames = Art.walk_frames(Game.hero_sheet(Game.hero_id), 6.0)
	spr.scale = Vector2(2, 2)
	spr.offset = Vector2(0, -10)   # 20px frame, so this puts the feet on the ground
	spr.play("right")
	hero.add_child(spr)

	var tw := create_tween().set_loops()
	tw.tween_property(hero, "position:x", _at(14.7, 0).x, 4.6)
	tw.tween_callback(func() -> void: spr.play("left"))
	tw.tween_property(hero, "position:x", _at(12.0, 0).x, 4.6)
	tw.tween_callback(func() -> void: spr.play("right"))


# --- Header -----------------------------------------------------------------
## Who is signed in, and the way out. Only drawn when there is a session --
## offline dev runs and the headless suites have nobody to show or log out.
func _build_header() -> void:
	if not Net.signed_in():
		return
	# Room for Log Out at the right, when the header carries it.
	var edge := INSET + (0.0 if _logout_in_settings() else 86.0)
	# One line, right-aligned: the player's gems | their name, their character.
	var head := HBoxContainer.new()
	head.alignment = BoxContainer.ALIGNMENT_END
	head.add_theme_constant_override("separation", 6)
	head.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	head.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	head.offset_right = -edge
	head.offset_top = INSET
	head.offset_bottom = INSET + 30
	head.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(head)

	var who := Art.label(Net.username, Pal.LABEL, Pal.GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
	who.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Art.shadow(who, Pal.SHADOW, 2, 0)
	head.add_child(who)

	# The chosen character stands beside the name, per the mockup's header.
	var wrap := Control.new()
	wrap.custom_minimum_size = Vector2(28, 28)
	wrap.clip_contents = true
	wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var face := AnimatedSprite2D.new()
	face.sprite_frames = Art.walk_frames(Game.hero_sheet(Game.hero_id), 1.0)
	face.animation = "right"
	face.scale = Vector2(1.4, 1.4)
	# Centred on the text's line (measured): at y 20 it sat 5px under it.
	face.position = Vector2(14, 13)
	wrap.add_child(face)
	head.add_child(wrap)

	if _logout_in_settings():
		return
	var out := Ui.button("Log Out", 76, Ui.H, Ui.SMALL_RED)
	out.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	out.offset_left = -(INSET + 76)
	out.offset_right = -INSET
	out.offset_top = INSET
	out.offset_bottom = INSET + 28
	out.pressed.connect(func() -> void:
		Net.sign_out()
		main.open("login"))
	add_child(out)


## A room, after a character if there is none yet.
func _open_room() -> void:
	main.open("room" if Game.player_name != "" else "hero",
		{} if Game.player_name != "" else {"then": "room"})


## Team name comes before the map, but a player with no character yet has to
## pick one first -- that is the only reason this is a branch and not a route.
func _adventure_route() -> String:
	return "team" if Game.player_name != "" else "hero"


# --- Menu -------------------------------------------------------------------
func _build_menu() -> void:
	# A gradient rather than a panel: the scene still reads through it, and the
	# buttons keep their contrast wherever the hero happens to be standing.
	var grad := Gradient.new()
	grad.set_color(0, Color(0.06, 0.05, 0.09, 0.88))
	grad.set_color(1, Color(0.06, 0.05, 0.09, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0)
	var shade := TextureRect.new()
	shade.texture = gt
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	shade.offset_right = MENU_W + INSET * 2
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	# The title and the menu as one block, centred down the left side.
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	col.offset_top = INSET
	col.offset_bottom = -INSET
	col.offset_left = INSET
	col.offset_right = INSET + MENU_W
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 6)
	add_child(col)

	var tl := Art.title(Art.label("Lakbayin", TITLE_SIZE, Pal.PARCHMENT, HORIZONTAL_ALIGNMENT_CENTER))
	tl.custom_minimum_size = Vector2(MENU_W, 0)
	Art.shadow(tl, Color(0, 0, 0, 0.6), 3, 0)
	col.add_child(tl)

	if _tagline() != "":
		var tag := Art.tagline(Pal.H2)
		tag.text = _tagline()
		Art.shadow(tag)
		tag.custom_minimum_size = Vector2(MENU_W, 0)
		col.add_child(tag)

	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 6)
	col.add_child(pad)

	# One navigation, not two. This column was carrying Continue / New Game /
	# Learn / Leaderboard / Quit while a tab bar along the bottom carried Home /
	# Start Adventure / Leaderboard / Learn -- nine buttons for four
	# destinations, two of them listed twice. The column wins: this is a
	# landscape phone, where height is the scarce axis and a bottom bar spends
	# it on something the side already does.
	for spec: Array in _entries():
		var b := Ui.button(spec[0], COL_W, BTN_H, spec[2])
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.clip_text = true
		# Solid white pixel icons (tools/make_icons.py), at the left edge.
		if spec.size() > 4 and str(spec[4]) != "":
			b.icon = Art.tex(ICONS % spec[4])
			b.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.add_theme_constant_override("h_separation", 6)
		var route: Variant = spec[1]
		# An optional fourth field is handed to the screen it opens.
		var data: Dictionary = spec[3] if spec.size() > 3 else {}
		if route is Callable:
			b.pressed.connect(route)
		else:
			b.pressed.connect(func() -> void:
				main.open(route if route != "" else _adventure_route(), data))
		col.add_child(b)
		Ui.fit_text(b)
	_after_menu(col)


## Back on the home screen is the way out of the app -- after asking, as Quit
## does. An open dialog closes first.
func go_back() -> void:
	if is_instance_valid(_dialog):
		_dialog.queue_free()
		return
	_confirm_quit()


var _dialog: Control = null


## Change Character (players and teachers alike) and Log Out.
## Two groups (client, redesigned per ui-ux-pro-max): Audio -- each volume
## with a mute toggle on its icon -- and Account, where Log Out asks first.
func _open_settings() -> void:
	_dialog = Ui.dim(self)
	var box := Ui.back_panel(_dialog, Vector2(312, 0), "Settings",
		func() -> void: _dialog.queue_free())
	box.add_theme_constant_override("separation", 8)

	Ui.section(box, "Audio")
	# Volumes, 0 is off, kept on the device. A sound on letting go of Sounds,
	# so it can be heard at the level just set.
	_volume_row(box, "Music", "music", main.music.volume, main.music.set_volume)
	var sounds := _volume_row(box, "Sounds", "sound", Sfx.volume, Sfx.set_volume)
	sounds.drag_ended.connect(func(_changed: bool) -> void: Sfx.play("button"))

	Ui.section(box, "Account")
	var hero := _account_button(box, "Change Character", "hero", Ui.SMALL)
	hero.pressed.connect(func() -> void: main.open("hero", {"then": "home"}))
	var records := _account_button(box, "Player Records", "book", Ui.SMALL)
	records.pressed.connect(func() -> void: main.open("records"))
	# Credits shares Log Out's row, so the panel keeps its height.
	var credits := _account_button(box, "Credits", "book", Ui.SMALL)
	credits.custom_minimum_size.x = 137
	credits.pressed.connect(_open_credits)
	var out := Ui.button("Log Out", 137, Ui.H, Ui.SMALL_RED)
	out.icon = Art.tex(ICONS % "exit")
	out.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	out.add_theme_constant_override("h_separation", 6)
	credits.get_parent().add_child(out)
	out.pressed.connect(_confirm_logout)


## Who made what. The music and the characters' licences require their credit
## in the game; the rest is credited because it is fair.
const CREDITS := [
	["Art", "Tiny Swords by Pixel Frog\nCharacters: Super Retro World by Gif (@gif_not_jif), Noiracide (@Noiracide) and Romi (@DessRomaric)"],
	["Music", "Original music by Marllon Silva (xDeviruchi)"],
	["Sound effects", "Original sounds made for this game\nRetro 512 by Juhani Junkala (CC0)\nInterface Sounds by Kenney (CC0)"],
	["Fonts", "Kalam by the Indian Type Foundry (OFL)\nKaushan Script by Pablo Impallari (OFL)\nNoto Sans Tagalog by the Noto Project Authors (OFL)\nDejaVu Sans by the DejaVu fonts team"],
	["Words", "From the Tagalog Swadesh list, Wiktionary (CC BY-SA 4.0)"],
	["AI disclosure", "Programming assisted by Claude (Anthropic). No AI-generated art, music or voices."],
]


func _open_credits() -> void:
	var d := Ui.dim(_dialog)
	var box := Ui.back_panel(d, Vector2(312, 0), "Credits", func() -> void: d.queue_free())
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	Ui.scroll(box, 230).add_child(list)
	for c: Array in CREDITS:
		Ui.section(list, c[0])
		var l := Art.label(c[1], Pal.SMALL, Pal.INK)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(272, 0)
		list.add_child(l)


## An Account row: a full-width button, its icon at the left like the menu's.
func _account_button(box: Control, text: String, icon: String, kind: int) -> Button:
	var b := Ui.button(text, 280, Ui.H, kind)
	b.icon = Art.tex(ICONS % icon)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_constant_override("h_separation", 6)
	Ui.centre_row(box, b)
	Ui.fit_text(b)
	return b


## One volume: a mute toggle on its icon, its name, the slider and its level.
## Muting remembers the level, so unmuting puts it back.
func _volume_row(box: Control, caption: String, icon: String, value: float,
		set_to: Callable) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var mute := Ui.icon_button(Art.tex(ICONS % icon), "Mute " + caption)
	row.add_child(mute)
	var name := Art.label(caption, Pal.LABEL, Pal.INK)
	name.custom_minimum_size = Vector2(56, 0)
	row.add_child(name)
	var vol := Ui.slider(128)
	vol.value = value
	vol.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var pct := Art.label("", Pal.LABEL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
	pct.custom_minimum_size = Vector2(40, 0)
	var last := [value if value > 0.0 else 0.8]      # the level to unmute to
	var show := func(v: float) -> void:
		pct.text = "Off" if v <= 0.0 else "%d%%" % roundi(v * 100.0)
		mute.icon = Art.tex(ICONS % (icon + "_off" if v <= 0.0 else icon))
		mute.tooltip_text = ("Unmute " if v <= 0.0 else "Mute ") + caption
	show.call(value)
	vol.value_changed.connect(func(v: float) -> void:
		if v > 0.0:
			last[0] = v
		set_to.call(v)
		show.call(v))
	mute.pressed.connect(func() -> void: vol.value = 0.0 if vol.value > 0.0 else last[0])
	row.add_child(vol)
	row.add_child(pct)
	box.add_child(row)
	return vol


## Log Out is the one step here that cannot be undone from this screen, so it
## asks (ui-ux-pro-max: confirm destructive actions) -- over Settings.
func _confirm_logout() -> void:
	var dim := Ui.dim(_dialog)
	var box := Ui.screen_panel(dim, Vector2(280, 0), "Log out?")
	box.add_theme_constant_override("separation", 10)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	var stay := Ui.button("Stay", 110, Ui.H, Ui.SMALL)
	stay.pressed.connect(dim.queue_free)
	var out := Ui.button("Log Out", 110, Ui.H, Ui.SMALL_RED)
	out.pressed.connect(func() -> void:
		Net.sign_out()
		main.open("login"))
	row.add_child(stay)
	row.add_child(out)
	box.add_child(row)


func _confirm_quit() -> void:
	_dialog = Ui.dim(self)
	var box := Ui.screen_panel(_dialog, Vector2(300, 124), "Quit Lakbayin?")
	box.add_theme_constant_override("separation", 10)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	var stay := Ui.button("Stay", 110, Ui.H, Ui.SMALL)
	stay.pressed.connect(func() -> void: _dialog.queue_free())
	var quit := Ui.button("Quit", 110, Ui.H, Ui.SMALL_RED)
	quit.pressed.connect(func() -> void: get_tree().quit())
	row.add_child(stay)
	row.add_child(quit)
	box.add_child(row)


## Only the version. The name used to live down here too, from before there
## were accounts -- now the header carries it, and the second copy was wide
## enough to sit under the last button in the column.
func _build_footer() -> void:
	var ver := Art.label("v%s" % ProjectSettings.get_setting("application/config/version", ""),
			12, Color(1, 1, 1, 0.5), HORIZONTAL_ALIGNMENT_RIGHT)
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.offset_left = -120
	ver.offset_right = -INSET
	ver.offset_top = -(INSET + 16)
	ver.offset_bottom = -INSET
	add_child(ver)

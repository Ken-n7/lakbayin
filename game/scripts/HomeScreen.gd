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
const CASTLE := "res://assets/buildings/Red_Castle.png"
const TREE := "res://assets/terrain/decorations/Tree1.png"

const INSET := 16      # safe-area gutter, ~5% of the 360px canvas height
const COL_W := 186     # menu column width
const HAIL_SIZE := Pal.BODY      # the welcome line; was Pal.H2
const SUB_SIZE := Pal.TINY - 1   # the line under it; was Pal.TINY
const ICONS := "res://assets/ui/icons/%s.png"
const BTN_H := Ui.H      # 30 x the ~3x phone upscale is ~90 physical px, still a
                       # comfortable touch target; 40 did not leave room for the
                       # welcome copy and five buttons above the tab bar
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
	_build_menu()
	_build_header()
	_build_footer()


# --- What a subclass changes ------------------------------------------------
## The admin dashboard is this screen with different words and different
## destinations, so it inherits the island, the header and the footer and
## overrides only these four. Anything else and the two drift apart.
func _hail() -> String:
	return "Welcome, Adventurer!"


func _sub() -> String:
	return "Every problem is a new adventure waiting to be solved."


## The player's strapline. The admin column has no room for it once the
## mockup's longer heading has wrapped.
func _tagline() -> String:
	return "Explore.  Solve.  Conquer."


## [label, route, button kind, data, icon]; an empty route means "work it
## out" via `_adventure_route()`, and a Callable is run instead of opened.
## Change Character and Log Out live in Settings (client), which is what
## makes room for Quit.
func _entries() -> Array:
	var has_profile := Game.player_name != ""
	return [
		["Join Quest" if has_profile else "Start Adventure", "", Ui.RED, {}, "play"],
		["Leaderboard", "board", Ui.SMALL, {}, "trophy"],
		["Learn", "learn", Ui.SMALL, {}, "book"],
		["Settings", _open_settings, Ui.SMALL, {}, "gear"],
		["Quit", _confirm_quit, Ui.SMALL, {}, "exit"],
	]


## Log Out on the header, or in Settings. The admin dashboard keeps it on the
## header: its column has no room for Settings and Quit.
func _logout_in_settings() -> bool:
	return true


## A teacher never picked a character, so there is no portrait to stand there.
func _show_portrait() -> bool:
	return true


## Every gem the player's adventures have come to, ahead of their name: the
## glinting gem and the total, then a bar (client). Sized as it was under the
## menu -- a 16px gem, the number in body text. Shown once the server
## answers; 0 until the first adventure is over.
func _load_gems(head: HBoxContainer) -> void:
	var icon := Art.texrect(Ui.GEM, 16, 16)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var n := Art.label("", Pal.BODY, Pal.GOLD)
	n.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Art.shadow(n, Pal.SHADOW, 2, 0)
	var bar := Art.label("|", Pal.BODY, Pal.CREAM)
	bar.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Art.shadow(bar, Pal.SHADOW, 2, 0)
	for c: Control in [icon, n, bar]:
		c.visible = false
		head.add_child(c)
	var results: Array = await Teams.my_results()
	if not is_instance_valid(n):
		return
	# A new player shows 0 rather than nothing: the count is there to grow.
	var total := 0
	for r: Dictionary in results:
		total += int(r.gems)
	n.text = str(total)
	n.tooltip_text = "Gems from %d adventures" % results.size()
	for c: Control in [icon, n, bar]:
		c.visible = true


## Hook for anything a subclass wants under the buttons.
func _after_menu(_col: VBoxContainer) -> void:
	pass


# --- Scene ------------------------------------------------------------------
## The island is a fixed composition, not a procedural map: every prop is placed
## by hand so the castle stays the focal point and the menu column always has
## quiet water behind it. No RNG, so it looks the same every launch.
func _build_scene() -> void:
	_world = Node2D.new()
	_world.y_sort_enabled = true
	add_child(_world)

	var water: TileMapLayer = Art.terrain_layer(WATER_BG, TILE, [Vector2i(0, 0)])
	# The raw tile is a pale teal (#47aba9); multiply it toward a deeper sea blue
	# so the grass reads against it and the menu gradient has something to sit on.
	water.modulate = MapCfg.WATER_TINT
	_world.add_child(water)
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
	Art.sprite(_world, Art.cell(CASTLE, 0, 0), _at(13.0, 4.8), 0.5)

	for spec in [[8.6, 6.2, 1.0], [17.4, 5.6, -1.0], [9.4, 7.6, 1.0], [16.8, 7.4, 1.0]]:
		var t := Art.anim_sprite(_world, TREE, _at(spec[0], spec[1]), 0.42, 3.0, spec[2])
		t.frame = int(abs(t.position.x)) % 8   # desync the sway so they don't pulse in unison

	Art.sprite(_world, Art.tex("res://assets/terrain/decorations/Rock2.png"), _at(9.8, 4.8), 1.4)
	Art.sprite(_world, Art.tex("res://assets/terrain/decorations/Rock4.png"), _at(16.6, 6.6), 1.4)
	Art.sprite(_world, Art.tex("res://assets/terrain/decorations/Stump 1.png"), _at(11.6, 8.3), 0.4)

	# The island's lower middle is left empty on purpose -- that is the hero's
	# patrol band, and anything standing there y-sorts in front of him.


## One adventurer pacing the shore in front of the castle. A looping tween
## rather than _process: the menu has no other per-frame work to do.
func _build_hero() -> void:
	var hero := Node2D.new()
	hero.position = _at(11.0, 7.4)
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
	tw.tween_property(hero, "position:x", _at(15.6, 0).x, 4.6)
	tw.tween_callback(func() -> void: spr.play("left"))
	tw.tween_property(hero, "position:x", _at(11.0, 0).x, 4.6)
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

	if _show_portrait():
		_load_gems(head)

	var who := Art.label(Net.username, Pal.LABEL, Pal.GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
	who.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Art.shadow(who, Pal.SHADOW, 2, 0)
	head.add_child(who)

	# The chosen character stands beside the name, per the mockup's header --
	# for a player. A teacher never picked one, so the name sits alone.
	if _show_portrait():
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
	shade.offset_right = COL_W + INSET * 3
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	col.offset_top = INSET
	col.offset_left = INSET
	col.offset_right = INSET + COL_W
	col.custom_minimum_size = Vector2(COL_W, 0)
	col.add_theme_constant_override("separation", 4)
	add_child(col)

	var tl := Art.label("NumXventure", Pal.H1, Pal.PARCHMENT, HORIZONTAL_ALIGNMENT_CENTER)
	tl.custom_minimum_size = Vector2(COL_W, 0)
	Art.shadow(tl, Color(0, 0, 0, 0.6), 3, 0)
	col.add_child(tl)

	if _tagline() != "":
		var tag := Art.label(_tagline(), Pal.SMALL, Pal.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
		tag.custom_minimum_size = Vector2(COL_W, 0)
		col.add_child(tag)

	# The mockup's welcome copy, word for word -- §1 treats the PDFs as a
	# wording contract even though the art is ours.
	# A size down (client), with the line under it: room for one more button.
	var hail := Art.label(_hail(), HAIL_SIZE, Pal.PARCHMENT,
			HORIZONTAL_ALIGNMENT_CENTER)
	# Wrapped and pinned to the column width. Without this a longer heading --
	# the admin's -- sets the VBox's minimum width, and every button in it
	# stretches to match: 400px against Home's 186.
	hail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hail.custom_minimum_size = Vector2(COL_W, 0)
	Art.shadow(hail, Pal.SHADOW, 2, 0)
	col.add_child(hail)
	var sub := Art.label(_sub(),
			SUB_SIZE, Pal.WHITE_SOFT, HORIZONTAL_ALIGNMENT_CENTER)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size = Vector2(COL_W, 0)
	col.add_child(sub)

	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 4)
	col.add_child(pad)

	# One navigation, not two. This column was carrying Continue / New Game /
	# Learn / Leaderboard / Quit while a tab bar along the bottom carried Home /
	# Start Adventure / Leaderboard / Learn -- nine buttons for four
	# destinations, two of them listed twice. The column wins: this is a
	# landscape phone, where height is the scarce axis and a bottom bar spends
	# it on something the side already does.
	for spec: Array in _entries():
		var b := Ui.button(spec[0], COL_W, BTN_H, spec[2])
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


## Change Character (once there is one to change) and Log Out.
func _open_settings() -> void:
	_dialog = Ui.dim(self)
	var with_hero := _show_portrait() and Game.player_name != ""
	var box := Ui.back_panel(_dialog, Vector2(260, 236 if with_hero else 196), "Settings",
		func() -> void: _dialog.queue_free())
	box.add_theme_constant_override("separation", 8)
	# Volumes, 0 is off, kept on the device. A sound on letting go of Sounds,
	# so it can be heard at the level just set.
	_volume_row(box, "Music", main.music.volume, main.music.set_volume)
	var sounds := _volume_row(box, "Sounds", Sfx.volume, Sfx.set_volume)
	sounds.drag_ended.connect(func(_changed: bool) -> void: Sfx.play("button"))
	# Players only: a Quest Keeper never picks one, whatever this device last held.
	if with_hero:
		var hero := Ui.button("Change Character", 200, Ui.H, Ui.SMALL)
		hero.pressed.connect(func() -> void: main.open("hero", {"then": "home"}))
		Ui.centre_row(box, hero)
	var out := Ui.button("Log Out", 200, Ui.H, Ui.SMALL_RED)
	out.pressed.connect(func() -> void:
		Net.sign_out()
		main.open("login"))
	Ui.centre_row(box, out)


## A labelled volume slider with its % beside it, into `box`.
func _volume_row(box: Control, caption: String, value: float, set_to: Callable) -> HSlider:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	var name := Art.label(caption, Pal.LABEL, Pal.INK)
	name.custom_minimum_size = Vector2(56, 0)
	row.add_child(name)
	var vol := Ui.slider(110)
	vol.value = value
	var pct := Art.label("", Pal.LABEL, Pal.INK_MUTED)
	pct.custom_minimum_size = Vector2(36, 0)
	var show := func(v: float) -> void: pct.text = "Off" if v <= 0.0 else "%d%%" % roundi(v * 100.0)
	show.call(value)
	vol.value_changed.connect(func(v: float) -> void:
		set_to.call(v)
		show.call(v))
	row.add_child(vol)
	row.add_child(pct)
	box.add_child(row)
	return vol


func _confirm_quit() -> void:
	_dialog = Ui.dim(self)
	var box := Ui.screen_panel(_dialog, Vector2(300, 150 if _show_portrait() else 124), "Quit NumXventure?")
	box.add_theme_constant_override("separation", 10)
	if _show_portrait():                 # a player's reassurance; a teacher has no gems
		box.add_child(Art.label("Your gems are saved.", Pal.SMALL, Pal.INK_MUTED,
			HORIZONTAL_ALIGNMENT_CENTER))
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

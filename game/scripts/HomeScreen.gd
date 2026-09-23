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
const BTN_H := 30      # 30 x the ~3x phone upscale is ~90 physical px, still a
                       # comfortable touch target; 40 did not leave room for the
                       # welcome copy and five buttons above the tab bar
const TILE := 32       # world px per cell; art is 64px drawn at 0.5
const W := 21          # 21 x 32 = 672, over-covers the 640 viewport
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


## [label, route, button kind]; an empty route means "work it out" via
## `_adventure_route()`.
func _entries() -> Array:
	var has_profile := Game.player_name != ""
	var out: Array = [
		["Continue Quest" if has_profile else "Start Adventure", "", Ui.RED],
		["Leaderboard", "board", Ui.SMALL_RED],
		["Learn", "learn", Ui.SMALL],
	]
	# The only route back to the character picker once a hero is saved.
	if has_profile:
		out.insert(1, ["Change Character", "hero", Ui.SMALL])
	return out


## A teacher never picked a character, so there is no portrait to stand there.
func _show_portrait() -> bool:
	return true


## Hook for anything a subclass wants under the buttons.
func _after_menu(_col: VBoxContainer) -> void:
	pass


func _footer() -> String:
	return "Adventurer: %s" % (Game.player_name if Game.player_name != ""
		else "— no profile yet —")


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
	water.modulate = Color(0.70, 0.68, 1.0)
	_world.add_child(water)
	for y in H:
		for x in W:
			water.set_cell(Vector2i(x, y), 0, Vector2i(0, 0))

	var grass: TileMapLayer = Art.terrain_layer(TILEMAP_COLOR, TILE)
	_world.add_child(grass)
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			if _is_land(c):
				_land[c] = true
	for cell in _land:
		grass.set_cell(cell, 0, Art.autotile(
				_land.has(cell + Vector2i(-1, 0)), _land.has(cell + Vector2i(1, 0)),
				_land.has(cell + Vector2i(0, -1)), _land.has(cell + Vector2i(0, 1))))

	_build_props()
	_build_hero()

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
	# The chosen character stands beside the name, per the mockup's header --
	# for a player. A teacher never picked one, so the name sits alone.
	if _show_portrait():
		var wrap := Control.new()
		wrap.custom_minimum_size = Vector2(28, 28)
		wrap.clip_contents = true
		wrap.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		wrap.offset_left = -(INSET + 86 + 30)
		wrap.offset_right = -(INSET + 86 + 2)
		wrap.offset_top = INSET + 2
		wrap.offset_bottom = INSET + 30
		var face := AnimatedSprite2D.new()
		face.sprite_frames = Art.walk_frames(Game.hero_sheet(Game.hero_id), 1.0)
		face.animation = "right"
		face.scale = Vector2(1.4, 1.4)
		face.position = Vector2(14, 20)
		wrap.add_child(face)
		add_child(wrap)

	var who := Art.label(Net.username, Pal.LABEL, Pal.GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
	who.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	who.offset_left = -300
	who.offset_right = -(INSET + 86)
	who.offset_top = INSET + 6
	who.offset_bottom = INSET + 24
	Art.shadow(who, Pal.SHADOW, 2, 0)
	add_child(who)

	var out := Ui.button("Log Out", 76, 28, Ui.SMALL_RED)
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
	Art.shadow(tl, Color(0, 0, 0, 0.6), 3, 0)
	col.add_child(tl)

	col.add_child(Art.label("Explore.  Solve.  Conquer.", Pal.SMALL, Pal.GOLD,
			HORIZONTAL_ALIGNMENT_CENTER))

	# The mockup's welcome copy, word for word -- §1 treats the PDFs as a
	# wording contract even though the art is ours.
	var hail := Art.label(_hail(), Pal.H2, Pal.PARCHMENT,
			HORIZONTAL_ALIGNMENT_CENTER)
	Art.shadow(hail, Pal.SHADOW, 2, 0)
	col.add_child(hail)
	var sub := Art.label(_sub(),
			Pal.TINY, Pal.WHITE_SOFT, HORIZONTAL_ALIGNMENT_CENTER)
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
		var route: String = spec[1]
		b.pressed.connect(func() -> void:
			main.open(route if route != "" else _adventure_route()))
		col.add_child(b)
	_after_menu(col)


## Back on the home screen is the way out of the app.
func go_back() -> void:
	get_tree().quit()


func _build_footer() -> void:
	var who := Art.label(_footer(), 12, Color(1, 1, 1, 0.85))
	who.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	who.offset_left = INSET
	who.offset_top = -(INSET + 16)
	who.offset_bottom = -INSET
	add_child(who)

	var ver := Art.label("v%s" % ProjectSettings.get_setting("application/config/version", ""),
			12, Color(1, 1, 1, 0.5), HORIZONTAL_ALIGNMENT_RIGHT)
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.offset_left = -120
	ver.offset_right = -INSET
	ver.offset_top = -(INSET + 16)
	ver.offset_bottom = -INSET
	add_child(ver)

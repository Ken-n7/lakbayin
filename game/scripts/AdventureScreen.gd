extends Control

## The Adventure Map: an explorable Tiny Swords island with three math-quiz
## stations. WASD/arrows move the hero; E (or Space/Enter) enters a station.

const TILE := 32        # world px per cell; art is 64px drawn at 0.5
const SHEET_TILE := 64  # the tileset's own tile size

const TILEMAP_COLOR := "res://assets/terrain/tileset/Tilemap_color1.png"
const WATER_BG := "res://assets/terrain/tileset/Water Background color.png"

const W := 44
const H := 30

# The Super Retro World sheets are 16x20; x2 in world px lands 80px tall on
# screen, the same height as the tileset's own 64px cells plus a head.
const UNIT_SCALE := 2.0
# Buildings are the tileset's own 64px art, so they take the tileset's scale.
const BUILDING_SCALE := 0.5
const BUILDINGS := [
	"res://assets/buildings/Blue_Tower.png",
	"res://assets/buildings/Yellow_Archery.png",
	"res://assets/buildings/Red_Castle.png",
]
const PLAYER_SPEED := 150.0
const INTERACT_RADIUS := 42.0

var main: Control

var world: Node2D
var grass_layer: TileMapLayer
var water_layer: TileMapLayer
var player: Node2D

var _land := {}       # Vector2i -> true
var _beach := {}      # Vector2i -> true
var _solid: Array[Rect2] = []  # building base walls, in world px
var _station_nodes: Array = []
var _station_locks: Array = []
var _prompt: Label
var _hud_gems: Label
var _hud_time: Label
var _hud_station: Label
var _hud_pips: Label
var _gem_bar: ProgressBar
var _hud_layer: CanvasLayer
var _ui_layer: CanvasLayer

var _touch_pad: Node2D = null
var _overlay: Control = null
var _paused := false
var _flash_active := false


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_hud()
	if not Game.adventure_active:
		Game.begin_adventure()
	world = Node2D.new()
	add_child(world)
	world.y_sort_enabled = true
	_build_terrain()
	_build_island()
	_build_stations()
	_build_decor()
	_spawn_player()
	Game.time_changed.connect(_on_time)
	Game.gems_changed.connect(_on_gems)
	Game.adventure_ended.connect(_on_adventure_end)
	_refresh_hud()


func _exit_tree() -> void:
	Game.time_changed.disconnect(_on_time)
	Game.gems_changed.disconnect(_on_gems)
	Game.adventure_ended.disconnect(_on_adventure_end)


# --- Terrain ----------------------------------------------------------------
## Tiles keep their native 64px size and the layer is scaled down instead, so
## one cell is TILE world px. At the 2x viewport upscale that lands 1:1 on
## screen -- the art is never resampled.
static func _make_layer(tex_path: String, coords: Array = []) -> TileMapLayer:
	var region := Vector2i(SHEET_TILE, SHEET_TILE)
	var src := TileSetAtlasSource.new()
	src.texture = Art.tex(tex_path)
	src.texture_region_size = region
	if coords.is_empty():
		var cols := int(Art.tex(tex_path).get_width() / region.x)
		var rows := int(Art.tex(tex_path).get_height() / region.y)
		for ty in rows:
			for tx in cols:
				src.create_tile(Vector2i(tx, ty))
	else:
		for c in coords:
			src.create_tile(c)
	var ts := TileSet.new()
	ts.tile_size = region
	ts.add_source(src, 0)
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	layer.scale = Vector2.ONE * (float(TILE) / float(SHEET_TILE))
	return layer


## Tilemap_color1.png is a 16-state match-sides autotile set: the column is
## chosen by the left/right neighbours and the row by top/bottom. Derived by
## probing each tile's edges -- see the plan's mapping table.
##   c0 R-only  c1 R+L  c2 L-only  c3 neither
##   r0 B-only  r1 T+B  r2 T-only  r3 neither
static func _autotile(left: bool, right: bool, up: bool, down: bool, cliff := false) -> Vector2i:
	var col := 0 if (right and not left) else (1 if (right and left) else (2 if left else 3))
	var row := 0 if (down and not up) else (1 if (up and down) else (2 if up else 3))
	return Vector2i(col + (5 if cliff else 0), row)


func _build_terrain() -> void:
	water_layer = _make_layer(WATER_BG, [Vector2i(0, 0)])
	world.add_child(water_layer)
	for gy in H:
		for gx in W:
			water_layer.set_cell(Vector2i(gx, gy), 0, Vector2i(0, 0))
	grass_layer = _make_layer(TILEMAP_COLOR)
	world.add_child(grass_layer)
	world.set_meta("grass", grass_layer)
	world.set_meta("tile", TILE)


# --- Island shape -----------------------------------------------------------
func _island_radius(nx: float, ny: float) -> float:
	var ang := atan2(ny, nx)
	return 0.86 + 0.11 * sin(ang * 3.0 + 1.7) + 0.06 * cos(ang * 5.0 + 0.4)


func _cell_inside(cell: Vector2i) -> bool:
	var nx := (float(cell.x) + 0.5) / float(W) * 2.0 - 1.0
	var ny := (float(cell.y) + 0.5) / float(H) * 2.0 - 1.0
	if nx * nx + ny * ny > 1.3:
		return false
	return sqrt(nx * nx + ny * ny) < _island_radius(nx, ny)


func _build_island() -> void:
	for y in H:
		for x in W:
			var cell := Vector2i(x, y)
			if _cell_inside(cell):
				_land[cell] = true
	for cell in _land:
		var up: bool = _land.has(cell + Vector2i(0, -1))
		var down: bool = _land.has(cell + Vector2i(0, 1))
		var left: bool = _land.has(cell + Vector2i(-1, 0))
		var right: bool = _land.has(cell + Vector2i(1, 0))
		var edge := not (up and down and left and right)
		if edge:
			_beach[cell] = true
		# Cols 0-3 are the foam-outlined land-meets-water set, so the shoreline
		# is baked into the tile itself and reads the same on all four sides.
		grass_layer.set_cell(cell, 0, _autotile(left, right, up, down))


func _is_walkable(pos: Vector2) -> bool:
	for r in _solid:
		if r.has_point(pos):
			return false
	var cell := Vector2i(floori(pos.x / TILE), floori(pos.y / TILE))
	return grass_layer.get_cell_source_id(cell) != -1


func _first_land(nx: float, ny: float) -> Vector2:
	for tries in 60:
		var c := Vector2i(floori(nx * W), floori(ny * H))
		if _land.has(c):
			return Vector2(c.x * TILE + TILE / 2, c.y * TILE + TILE / 2)
		nx = lerpf(nx, 0.5, 0.1)
		ny = lerpf(ny, 0.5, 0.1)
	return Vector2(W * TILE / 2, H * TILE / 2)


## First land cell at least MIN_STATION_GAP apart from every already taken spot,
## so stations never share the same (or adjacent) cells.
func _land_away_from(w: Vector2, taken: Array) -> Vector2:
	var base := _first_land(w.x, w.y)
	var bc := Vector2i(floori(base.x / TILE), floori(base.y / TILE))
	for ring in 44:
		for ox in range(-ring, ring + 1):
			for oy in range(-ring, ring + 1):
				if maxi(absi(ox), absi(oy)) != ring:
					continue
				var cand := bc + Vector2i(ox, oy)
				if not _land.has(cand):
					continue
				var pos := Vector2(cand.x * TILE + TILE / 2, cand.y * TILE + TILE / 2)
				if taken.any(func(t) -> bool:
					# 6 cells, not 4: the castle alone is 156 world px wide.
					return (t as Vector2).distance_to(pos) < TILE * 6.0):
					continue
				return pos
	return base


# --- Decorations ------------------------------------------------------------
func _build_decor() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var placed := 0
	while placed < 30:
		var c := Vector2i(rng.randi_range(3, W - 4), rng.randi_range(3, H - 4))
		if not _land.has(c) or _beach.has(c):
			continue
		if _near_station(c):
			continue
		var p := Vector2(c.x * TILE + TILE / 2, c.y * TILE + TILE / 2)
		var roll := rng.randf()
		if roll < 0.5:
			var t := rng.randi_range(1, 4)
			var fl := 1.0 if rng.randf() < 0.9 else -1.0
			Art.anim_sprite(world, "res://assets/terrain/decorations/Tree%d.png" % t, p, 0.42, 3.0, fl)
		elif roll < 0.62:
			Art.sprite(world, Art.tex("res://assets/terrain/decorations/Stump %d.png" % rng.randi_range(1, 4)), p, 0.4)
		elif roll < 0.78:
			Art.sprite(world, Art.tex("res://assets/terrain/decorations/Rock%d.png" % rng.randi_range(1, 4)), p, 1.4)
		elif roll < 0.86:
			Art.sprite(world, Art.tex("res://assets/terrain/decorations/Rubber duck.png"), p, 1.2)
		else:
			var golds := [
				"res://assets/terrain/resources/Gold_Resource.png",
				"res://assets/terrain/resources/Wood Resource.png",
				"res://assets/terrain/resources/Meat Resource.png",
				"res://assets/terrain/resources/Tool_0%d.png" % rng.randi_range(1, 4),
			]
			Art.sprite(world, Art.tex(golds[rng.randi_range(0, golds.size() - 1)]), p, 0.5)
		placed += 1
	# a couple of wandering sheep
	for k in 3:
		var sheep := _sheep_at(rng)
		world.add_child(sheep)
	# water rocks near the shore (animated)
	var wrp := Vector2(W * TILE * 0.28, H * TILE * 0.9)
	if not _is_walkable(wrp):
		Art.anim_sprite(world, "res://assets/terrain/decorations/Water Rocks_0%d.png" % rng.randi_range(1, 4),
				wrp, 1.4, 4.0)


func _sheep_at(rng: RandomNumberGenerator) -> Node2D:
	var sheep := Node2D.new()
	var spr := AnimatedSprite2D.new()
	spr.sprite_frames = Art.anim_spriteframes({
		"idle": ["res://assets/terrain/resources/Sheep_Idle.png", 5.0, true],
		"walk": ["res://assets/terrain/resources/Sheep_Move.png", 7.0, true],
	})
	spr.scale = Vector2(0.9, 0.9)
	sheep.add_child(spr)
	var shadow := Sprite2D.new()
	shadow.texture = Art.tex("res://assets/terrain/tileset/Shadow.png")
	shadow.scale = Vector2(0.5, 0.5)
	shadow.modulate.a = 0.5
	sheep.add_child(shadow)
	sheep.set_script(preload("res://scripts/Wander.gd"))
	sheep.position = _first_land(0.3 + rng.randf() * 0.4, 0.5 + rng.randf() * 0.3)
	return sheep


## A station is now a building, a board off its left side and a keeper off its
## right, so a single radius either lets trees land on the board or blanks out
## half the island. Each station keeps its own box instead.
func _near_station(c: Vector2i) -> bool:
	var p := Vector2(c.x * TILE + TILE / 2, c.y * TILE + TILE / 2)
	for r in _station_rects:
		if (r as Rect2).has_point(p):
			return true
	return false


# --- Stations ---------------------------------------------------------------
var _station_rects: Array = []   # keep-out boxes for decor


func _build_stations() -> void:
	var spots: Array = []
	for w in [Vector2(0.22, 0.30), Vector2(0.78, 0.30), Vector2(0.50, 0.80)]:
		spots.append(_land_away_from(w, spots))
	for i in 3:
		var meta := QuestionGen.station_meta(i)
		var at: Vector2 = spots[i]
		_make_station(i, at, meta.accent)


func _make_station(i: int, at: Vector2, _accent: String) -> void:
	var st := Node2D.new()
	st.position = at
	world.add_child(st)
	# `Art.cell(path, 0, 0)` crops to the alpha bounding box -- every building
	# PNG carries 20-60px of transparent padding, and an uncropped sprite would
	# hang above the grass. Anchored at its base like the decor.
	var btex := Art.cell(BUILDINGS[i], 0, 0)
	var bsize := btex.region.size
	var building := Sprite2D.new()
	building.texture = btex
	building.scale = Vector2(BUILDING_SCALE, BUILDING_SCALE)
	building.offset = Vector2(0, -bsize.y * 0.5)
	st.add_child(building)
	var hw := bsize.x * 0.5 * BUILDING_SCALE
	var bh := bsize.y * BUILDING_SCALE
	# Only the walls standing on the ground, not the whole sprite: the roof is
	# walkable so the player can pass behind, which is what the y-sort expects.
	# `has_point` excludes the bottom edge, so the doorstep row the station node
	# sits on stays open and `INTERACT_RADIUS` is always reachable.
	_solid.append(Rect2(at.x - hw, at.y - bh * 0.45, hw * 2.0, bh * 0.45))
	# Keep decor off the building itself, plus a tile of breathing room.
	_station_rects.append(Rect2(
			at + Vector2(-(hw + TILE), -(bh + TILE)),
			Vector2(hw * 2.0 + TILE * 2.0, bh + TILE * 2.0)))
	# Signage over the doorway rather than over the roof. Above the roof the
	# castle's label sits 138px up, and since the camera centres on the player
	# it slides behind the HUD bar the moment you approach from the south.
	# World-space text, so size 14 is 28px on screen after the 2x upscale.
	var sign_y := -(bh * 0.45) - 22.0
	var title := Art.label("Station %d" % (i + 1), 14, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	title.position = Vector2(-100, sign_y)
	title.size = Vector2(200, 20)
	st.add_child(title)
	_station_locks.append(title)
	var topic := Art.label(QuestionGen.station_meta(i).short, 11, Color(1, 1, 1, 0.92), HORIZONTAL_ALIGNMENT_CENTER)
	topic.position = Vector2(-100, sign_y + 16.0)
	topic.size = Vector2(200, 16)
	st.add_child(topic)
	# Both sit over grass and roof, so they need the same shadow the map prompts
	# use to stay readable.
	for l in [title, topic]:
		Art.shadow(l)
	_station_nodes.append(st)


func _spawn_player() -> void:
	player = Node2D.new()
	player.position = _first_land(0.50, 0.58)
	var shade := Sprite2D.new()
	shade.texture = Art.tex("res://assets/terrain/tileset/Shadow.png")
	shade.scale = Vector2(0.3, 0.3)
	shade.modulate.a = 0.55
	shade.position = Vector2(0, 2)
	player.add_child(shade)
	var spr := AnimatedSprite2D.new()
	spr.name = "Spr"
	spr.scale = Vector2(UNIT_SCALE, UNIT_SCALE)
	spr.offset = Vector2(0, -10)   # 20px frame, so this puts the feet on the ground
	spr.sprite_frames = Art.walk_frames(Game.hero_sheet(Game.hero_id))
	spr.play("down")
	spr.pause()
	player.add_child(spr)
	world.add_child(player)
	var cam := Camera2D.new()
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 6.0
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = W * TILE
	cam.limit_bottom = H * TILE
	player.add_child(cam)


## Which way the sprite faces. Vertical wins ties so a diagonal walk still
## shows the back or front, which reads better than a side-on shuffle.
static func _facing(dir: Vector2) -> String:
	if absf(dir.y) >= absf(dir.x):
		return "down" if dir.y > 0.0 else "up"
	return "right" if dir.x > 0.0 else "left"


func _process(delta: float) -> void:
	if _overlay != null and is_instance_valid(_overlay) and Game.adventure_active:
		return
	if _paused or not Game.adventure_active:
		return
	var dir := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down"))
	if dir.length_squared() > 1.0:
		dir = dir.normalized()
	var spr: AnimatedSprite2D = player.get_node("Spr")
	if dir.length_squared() > 0.001:
		# One axis at a time, so a diagonal into a wall slides along it rather
		# than stopping dead. Buildings only became real walls once the
		# footprint stopped being rounded to tile centres.
		var step := dir * PLAYER_SPEED * delta
		player.position.x += step.x
		if not _is_walkable(player.position):
			player.position.x -= step.x
		player.position.y += step.y
		if not _is_walkable(player.position):
			player.position.y -= step.y
		var face := _facing(dir)
		if spr.animation != face or not spr.is_playing():
			spr.play(face)
	elif spr.is_playing():
		# The middle column is the standing pose, so idle is the walk paused.
		spr.pause()
		spr.frame = 1
	_update_interaction()


func _update_interaction() -> void:
	if _flash_active:
		return
	var next_station := Game.completed_stations.find(false)
	_prompt.text = ""
	for i in 3:
		if _station_nodes[i] != null and _station_nodes[i].position.distance_to(player.position) < INTERACT_RADIUS:
			if next_station < 0:
				_prompt.text = "Every station conquered!"
			elif i == next_station:
				_prompt.text = "%s — enter Station %d" % [
						"Tap GO" if Game.touch else "Press E / Space / Enter", i + 1]
			else:
				_prompt.text = "Complete Station %d first" % (next_station + 1)
			break


func _unhandled_input(event: InputEvent) -> void:
	if _overlay != null or _paused:
		return
	if event.is_action_pressed("interact"):
		_try_enter_station()
	elif event.is_action_pressed("pause"):
		_toggle_pause()


func _try_enter_station() -> void:
	var next := Game.completed_stations.find(false)
	if next < 0:
		return
	for i in 3:
		if _station_nodes[i].position.distance_to(player.position) < INTERACT_RADIUS:
			if i != next:
				_flash_tip("Complete Station %d first!" % (next + 1))
				return
			Game.current_station = i
			var quiz: Control = preload("res://scripts/QuizOverlay.gd").new()
			quiz.adventure = self
			quiz.station_index = i
			_show_overlay(quiz)
			return


# --- HUD --------------------------------------------------------------------
func _build_hud() -> void:
	# The player's Camera2D transforms every canvas item in layer 0, UI included,
	# so screen-space elements have to live in their own CanvasLayers or they
	# get dragged around the world with the camera.
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 1
	add_child(_hud_layer)
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 2
	add_child(_ui_layer)
	var top := PanelContainer.new()
	top.position = Vector2(4, 4)
	top.custom_minimum_size = Vector2(632, 44)
	top.add_theme_stylebox_override("panel", Art.panel("res://assets/ui/BigBar_Base.png", Vector2(10, 2), 0.5))
	_hud_layer.add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	top.add_child(row)

	var av := Art.texrect("res://assets/ui/Avatar_01.png", 32, 32)
	row.add_child(av)
	var name_col := VBoxContainer.new()
	var nm := Art.label(Game.player_name, 13, Color("ffe9a8"))
	name_col.add_child(nm)
	var cls := Art.label("Adventurer #%d" % Game.hero_id, 11, Color(1, 1, 1, 0.8))
	name_col.add_child(cls)
	row.add_child(name_col)

	var stats := VBoxContainer.new()
	stats.alignment = BoxContainer.ALIGNMENT_CENTER
	stats.custom_minimum_size = Vector2(150, 0)
	_hud_station = Art.label("Station 1", 13, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	stats.add_child(_hud_station)
	_hud_pips = Art.label("— — —", 13, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	stats.add_child(_hud_pips)
	row.add_child(stats)

	row.add_child(Control.new()) # spacer
	var gems_icon := Art.texrect("res://assets/ui/Icon_03.png", 26, 26)
	row.add_child(gems_icon)
	var gems_col := VBoxContainer.new()
	_hud_gems = Art.label("50", 15, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	gems_col.add_child(_hud_gems)
	_hud_time = Art.label("10:00", 13, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	gems_col.add_child(_hud_time)
	row.add_child(gems_col)

	_prompt = Art.label("", 15, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.position.y = -72
	_prompt.size = Vector2(640, 30)
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(_prompt)

	var keys := ("arrows — move   ·   GO — enter   ·   MENU / back — pause" if Game.touch
			else "WASD / arrows — move   ·   E — interact   ·   Esc — menu")
	var hint_bar := Art.label(keys, 12,
			Color(1, 1, 1, 0.75), HORIZONTAL_ALIGNMENT_CENTER)
	if Game.touch:
		hint_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		hint_bar.position.y = 52
	else:
		hint_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
		hint_bar.position.y = -46
	hint_bar.size = Vector2(640, 24)
	hint_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(hint_bar)

	# Both float over open terrain, so they need a shadow to stay readable.
	for l in [_prompt, hint_bar]:
		Art.shadow(l)

	var gemrow := HBoxContainer.new()
	gemrow.position = Vector2(4, 50)
	gemrow.add_theme_constant_override("separation", 4)
	_hud_layer.add_child(gemrow)
	# SmallBar_Fill is a 3px sliver and SmallBar_Base a 3x1 patch; they never
	# lined up as a TextureProgressBar. A flat gauge in the pack's palette is
	# both correct at any size and legible at a glance.
	_gem_bar = ProgressBar.new()
	_gem_bar.custom_minimum_size = Vector2(140, 10)
	_gem_bar.show_percentage = false
	_gem_bar.max_value = 100.0
	_gem_bar.value = 0.0
	var trough := StyleBoxFlat.new()
	trough.bg_color = Color(0.08, 0.06, 0.10, 0.75)
	trough.set_corner_radius_all(4)
	trough.set_border_width_all(1)
	trough.border_color = Color(0, 0, 0, 0.6)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Game.GOLD
	fill.set_corner_radius_all(4)
	_gem_bar.add_theme_stylebox_override("background", trough)
	_gem_bar.add_theme_stylebox_override("fill", fill)
	gemrow.add_child(_gem_bar)
	_build_touch_pad()


# --- Touch controls ---------------------------------------------------------
## TouchScreenButton is the only input node that sees more than one finger:
## mouse emulation only ever reports the first touch, so a d-pad made of
## Buttons could not walk and interact at the same time. Each button feeds a
## real InputMap action, so `_process` and `_unhandled_input` stay untouched.
func _build_touch_pad() -> void:
	if not Game.touch:
		return
	_touch_pad = Node2D.new()
	_hud_layer.add_child(_touch_pad)
	# Kept a thumb's width off the bottom edge: that strip is Android's
	# swipe-up-home gesture zone, immersive mode or not.
	for spec in [["move_up", "▲", Vector2(80, 228)], ["move_down", "▼", Vector2(80, 318)],
			["move_left", "◀", Vector2(34, 273)], ["move_right", "▶", Vector2(126, 273)]]:
		_touch_btn(spec[0], spec[1], spec[2], 0.38, 15, false)
	_touch_btn("interact", "GO", Vector2(574, 290), 0.52, 20, false)
	_touch_btn("pause", "MENU", Vector2(606, 74), 0.34, 11, true)


func _touch_btn(action: String, text: String, center: Vector2, s: float, font: int, red: bool) -> void:
	var skin := "res://assets/ui/Small%sRoundButton_%s.png"
	var col := "Red" if red else "Blue"
	var b := TouchScreenButton.new()
	b.texture_normal = Art.tex(skin % [col, "Regular"])
	b.texture_pressed = Art.tex(skin % [col, "Pressed"])
	b.action = action
	b.passby_press = true   # sliding a thumb across the d-pad turns
	# The art is 128px drawn from the node's origin, so the hit circle is its
	# own centre at full size and rides `scale` down with the sprite.
	var circle := CircleShape2D.new()
	circle.radius = 64.0
	b.shape = circle
	b.shape_centered = true
	b.scale = Vector2(s, s)
	b.position = center - Vector2(64.0, 64.0) * s
	b.modulate.a = 0.8
	_touch_pad.add_child(b)
	var l := Art.label(text, font, Color(1, 1, 1, 0.95), HORIZONTAL_ALIGNMENT_CENTER)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size = Vector2(80, 24)
	l.position = center - Vector2(40, 12)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Art.shadow(l)
	_touch_pad.add_child(l)


## Hiding a TouchScreenButton releases its action, so a held direction never
## survives into a quiz or the pause menu.
func _set_pad(on: bool) -> void:
	if _touch_pad != null:
		_touch_pad.visible = on


func _flash_tip(text: String) -> void:
	if not is_instance_valid(_prompt):
		return
	_flash_active = true
	Art.toast(_prompt, text, 1.2, "", func() -> void: _flash_active = false)


func _on_gems(g: int) -> void:
	if is_instance_valid(_hud_gems):
		_hud_gems.text = str(g)
	var ratio := clampf(float(g) / float(Game.START_GEMS + 60), 0.0, 1.0)
	if is_instance_valid(_gem_bar):
		_gem_bar.value = 100.0 * ratio


func _on_time(sec: int) -> void:
	if is_instance_valid(_hud_time):
		_hud_time.text = "%02d:%02d" % [sec / 60, sec % 60]


func _refresh_hud() -> void:
	_on_gems(Game.gems)
	_on_time(int(ceilf(Game.time_left)))
	var next := Game.completed_stations.find(false)
	var label := "All stations!" if next < 0 else "Station %d" % (next + 1)
	_hud_station.text = label
	var marks := ""
	for i in 3:
		marks += ["✓", "★", "—"][ 0 if Game.completed_stations[i] else (1 if Game.perfect_stations[i] else 2) ] + " "
	_hud_pips.text = marks.strip_edges()
	# Label the boards on the map itself, otherwise all three look identical.
	for i in _station_locks.size():
		var mark := "—"
		if Game.completed_stations[i]:
			mark = "★" if Game.perfect_stations[i] else "✓"
		elif i == next:
			mark = "▶"
		_station_locks[i].text = "Station %d  %s" % [i + 1, mark]


## Android's back button, routed here by Main: leaving a station mid-question
## is not on offer, so back opens the pause menu instead.
func go_back() -> void:
	if _overlay == null and not _paused:
		_toggle_pause()


func _toggle_pause() -> void:
	if _paused:
		return
	_paused = true
	_set_pad(false)
	var menu := Ui.panel(Vector2(300, 250), "Paused")
	menu.position = Vector2(170, 46)
	_ui_layer.add_child(menu)
	var box: VBoxContainer = menu.get_child(0) as VBoxContainer
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	# label, kind, height, screen to open ("" = stay on the map), what to do with
	# the run in progress.
	for spec in [["Resume", Ui.BLUE, 44, "", ""], ["Home", Ui.SMALL, 38, "title", "end"],
			["Restart", Ui.SMALL, 38, "adventure", "restart"],
			["Leaderboard", Ui.SMALL_RED, 38, "board", ""],
			["New Game", Ui.SMALL_RED, 38, "hero", "abandon"]]:
		var b := Ui.button(spec[0], 170, spec[2], spec[1])
		b.pressed.connect(_leave_pause.bind(menu, spec[3], spec[4]))
		box.add_child(b)


## Every pause exit closes the menu. `drop` decides the fate of the run in
## progress -- "end" scores it, "restart" and "abandon" discard it unscored --
## and `screen` where to go next. Restart rebuilds the island, because `open()`
## remakes the screen, and the gems go back to the starting purse.
func _leave_pause(menu: Control, screen: String, drop: String) -> void:
	_paused = false
	_set_pad(true)
	menu.queue_free()
	match drop:
		"end": Game.end_adventure()
		"restart": Game.restart_adventure()
		"abandon": Game.abandon_adventure()
	if screen != "":
		main.open(screen)


# --- Quiz overlay -----------------------------------------------------------
func _show_overlay(overlay: Control) -> void:
	_overlay = overlay
	_set_pad(false)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.focus_mode = Control.FOCUS_ALL
	_ui_layer.add_child(overlay)
	overlay.setup({})
	overlay.grab_focus()


func close_overlay() -> void:
	if _overlay != null:
		_overlay.queue_free()
		_overlay = null
		_set_pad(true)
		_refresh_hud()
	# Clearing the board is a win condition, not just a HUD change: without this
	# the player wanders a finished map until the timer runs out.
	if Game.adventure_active and Game.completed_stations.all(func(v: bool) -> bool: return v):
		Game.end_adventure()


func _on_adventure_end(result: Dictionary) -> void:
	if _overlay != null:
		close_overlay()
	_paused = false
	main.open("summary", result)
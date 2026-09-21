extends Control

## The Adventure Map: the client's board laid over a Tiny Swords island --
## base camp, Tower 1, its 20 circles, Tower 2, 10 circles, Tower 3, 10 circles,
## Victory Gate, all on one authored path. One circle is one question item, and
## they resolve strictly in order. WASD/arrows move the hero; E (or Space/Enter)
## enters the tower you stand at, answers the circle you stand on, or walks
## through the gate once all forty are cleared.

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

## The authored path: four horizontal lanes, bottom-right to top-right, inset so
## every corner lands on (or close to) the generated island. Normalized map
## coords; `_stamp_path()` guarantees the walk even where the generator left water.
const PATH_WAY := [
	Vector2(0.72, 0.78),   # base camp
	Vector2(0.28, 0.78),
	Vector2(0.28, 0.5933),
	Vector2(0.72, 0.5933),
	Vector2(0.72, 0.4067),
	Vector2(0.28, 0.4067),
	Vector2(0.28, 0.22),
	Vector2(0.72, 0.22),   # victory gate
]
## Towers stand beside the path, not on it: their walls are up to 150px wide and
## would otherwise swallow the next circle, 68px along. `_tower_lift()` picks the
## side.
const TOWER_LIFT := 56.0
## Zoom that frames the whole board for the pre-start aerial POV. Any lower and
## the visible rect outgrows the camera limits, which then shove it off-centre.
const AERIAL_ZOOM := 0.46

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
var _circles: Array = []        # 40 PathCircle nodes, path order
var _anchors: Array = []        # base camp, 3 towers, 40 circles, gate -- in walk order
var _gate: Node2D = null
var _cam: Camera2D
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
var _frozen := false            # the aerial POV before the adventure starts
var _intro_tw: Tween = null


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_hud()
	if not Game.adventure_active:
		Game.begin_adventure()
	world = Node2D.new()
	add_child(world)
	world.y_sort_enabled = true
	_anchors = _path_anchors()
	_build_terrain()
	_build_island()
	_build_path()
	_build_decor()
	_spawn_player()
	Game.time_changed.connect(_on_time)
	Game.gems_changed.connect(_on_gems)
	Game.adventure_ended.connect(_on_adventure_end)
	_refresh_hud()
	_refresh_circles()
	_start_intro()


func _exit_tree() -> void:
	# Leaving during the frozen POV would otherwise strand the clock paused.
	Game.clock_paused = false
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
	_stamp_path()
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


# --- The path ---------------------------------------------------------------
func _way_world(i: int) -> Vector2:
	return Vector2(PATH_WAY[i].x * W * TILE, PATH_WAY[i].y * H * TILE)


## Evenly spaced stops along the polyline, in walk order: base camp, Tower 1, its
## 20 circles, Tower 2, its 10, Tower 3, its 10, Victory Gate. 45 stops over
## ~3000px of path, so they sit ~68px apart -- wider than INTERACT_RADIUS, which
## is what keeps "the circle you are standing on" unambiguous.
func _path_anchors() -> Array:
	var pts: Array[Vector2] = []
	for i in PATH_WAY.size():
		pts.append(_way_world(i))
	var segs: Array[float] = []
	var total := 0.0
	for i in pts.size() - 1:
		var d := pts[i].distance_to(pts[i + 1])
		segs.append(d)
		total += d
	var count := 1 + 3 + Game.TOTAL_ITEMS + 1
	var out: Array = []
	for k in count:
		var want := total * float(k) / float(count - 1)
		var acc := 0.0
		var at: Vector2 = pts[pts.size() - 1]
		for i in segs.size():
			if want <= acc + segs[i] or i == segs.size() - 1:
				at = pts[i].lerp(pts[i + 1], clampf((want - acc) / segs[i], 0.0, 1.0))
				break
			acc += segs[i]
		out.append(at)
	return out


## Anchor index of each tower: one before each station's run of circles.
func _tower_anchors() -> Array:
	var out: Array = []
	var k := 1                       # anchor 0 is the base camp
	for st in 3:
		out.append(k)
		k += 1 + Game.ITEMS_PER_STATION[st]
	return out


## Which way the building steps off the path: straight up on a lane, outward when
## the anchor sits on a bend. It has to be perpendicular to the walk, or the wall
## covers the next circle -- and its footprint is axis-aligned, so on a vertical
## bend "up" would put the wall right across the path.
func _tower_lift(k: int) -> Vector2:
	var a: Vector2 = _anchors[maxi(k - 1, 0)]
	var b: Vector2 = _anchors[mini(k + 1, _anchors.size() - 1)]
	var dir := (b - a).normalized()
	if absf(dir.x) >= absf(dir.y):
		return Vector2(0, -TOWER_LIFT)
	return Vector2(signf(_anchors[k].x - W * TILE * 0.5) * TOWER_LIFT, 0)


## The path is authored, the island is generated, so the two can disagree: force
## land under the whole walk (three cells wide) before the autotile pass paints
## the shoreline, and the board is never cut by a stray inlet.
func _stamp_path() -> void:
	for i in PATH_WAY.size() - 1:
		var a := _way_world(i)
		var b := _way_world(i + 1)
		var steps := maxi(int(a.distance_to(b) / (TILE * 0.5)), 1)
		for k in steps + 1:
			var pos := a.lerp(b, float(k) / float(steps))
			var c := Vector2i(floori(pos.x / TILE), floori(pos.y / TILE))
			for oy in [-1, 0, 1]:
				for ox in [-1, 0, 1]:
					var cc := c + Vector2i(ox, oy)
					if cc.x >= 0 and cc.y >= 0 and cc.x < W and cc.y < H:
						_land[cc] = true
	# The towers step off the path, so their ground has to be stamped as well or
	# one ends up standing in the shallows at a bend.
	for k in _tower_anchors():
		var base: Vector2 = _anchors[k] + _tower_lift(k)
		var bc := Vector2i(floori(base.x / TILE), floori(base.y / TILE))
		for oy in range(-2, 2):
			for ox in range(-2, 3):
				var cc := bc + Vector2i(ox, oy)
				if cc.x >= 0 and cc.y >= 0 and cc.x < W and cc.y < H:
					_land[cc] = true


func _build_path() -> void:
	var k := 1                       # anchor 0 is the base camp
	for st in 3:
		var meta := QuestionGen.station_meta(st)
		_make_station(st, _anchors[k], meta.accent, _tower_lift(k))
		k += 1
		for _i in Game.ITEMS_PER_STATION[st]:
			var c: Node2D = preload("res://scripts/PathCircle.gd").new()
			c.position = _anchors[k]
			world.add_child(c)
			c.setup(_circles.size(), meta.accent)
			_circles.append(c)
			# Keep trees and rocks off the circle itself.
			_station_rects.append(Rect2(_anchors[k] - Vector2(22, 22), Vector2(44, 44)))
			k += 1
	_build_camp(_anchors[0])
	_build_gate(_anchors[k])


func _build_camp(at: Vector2) -> void:
	Art.anim_sprite(world, "res://assets/fx/Fire_01.png", at + Vector2(0, -26), 0.7, 9.0)
	var l := Art.label("BASE CAMP", 14, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	l.position = at + Vector2(-70, -54)
	l.size = Vector2(140, 20)
	Art.shadow(l)
	world.add_child(l)
	_station_rects.append(Rect2(at - Vector2(48, 60), Vector2(96, 80)))


## The end of the whole player flow: walking in ends the adventure and the
## summary opens (SPECS Q6). Two boulders and a ribbon, no new art.
func _build_gate(at: Vector2) -> void:
	_gate = Node2D.new()
	_gate.position = at
	world.add_child(_gate)
	for side in [-1.0, 1.0]:
		Art.sprite(_gate, Art.tex("res://assets/terrain/decorations/Rock4.png"),
				Vector2(side * 30.0, 0), 1.3)
	var rib := Art.cell("res://assets/ui/BigRibbons.png", 0, 1)
	var spr := Sprite2D.new()
	spr.texture = rib
	spr.scale = Vector2(0.42, 0.42)
	spr.offset = Vector2(0, -rib.region.size.y * 0.5)
	spr.position = Vector2(0, -34)
	_gate.add_child(spr)
	var l := Art.label("VICTORY GATE", 14, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	l.position = Vector2(-80, -30)
	l.size = Vector2(160, 20)
	Art.shadow(l)
	_gate.add_child(l)
	_station_rects.append(Rect2(at - Vector2(64, 96), Vector2(128, 120)))


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


func _make_station(i: int, at: Vector2, _accent: String, lift := Vector2(0, -TOWER_LIFT)) -> void:
	var st := Node2D.new()
	st.position = at
	world.add_child(st)
	# `Art.cell(path, 0, 0)` crops to the alpha bounding box -- every building
	# PNG carries 20-60px of transparent padding, and an uncropped sprite would
	# hang above the grass. Anchored at its base like the decor.
	var btex := Art.cell(BUILDINGS[i], 0, 0)
	var bsize := btex.region.size
	# Lifted off the path and parented to the world, so the y-sort places it by
	# where it actually stands rather than by the doorstep on the path.
	var building := Sprite2D.new()
	building.texture = btex
	building.scale = Vector2(BUILDING_SCALE, BUILDING_SCALE)
	building.position = at + lift
	building.offset = Vector2(0, -bsize.y * 0.5)
	world.add_child(building)
	var hw := bsize.x * 0.5 * BUILDING_SCALE
	var bh := bsize.y * BUILDING_SCALE
	# Only the walls standing on the ground, not the whole sprite: the roof is
	# walkable so the player can pass behind, which is what the y-sort expects.
	# `has_point` excludes the bottom edge, so the doorstep row the station node
	# sits on stays open and `INTERACT_RADIUS` is always reachable.
	var base := at + lift
	_solid.append(Rect2(base.x - hw, base.y - bh * 0.45, hw * 2.0, bh * 0.45))
	# Keep decor off the building itself, plus a tile of breathing room.
	_station_rects.append(Rect2(
			Vector2(base.x - (hw + TILE), base.y - (bh + TILE)),
			Vector2(hw * 2.0 + TILE * 2.0, bh + TILE * 2.0)))
	# Signage over the doorway rather than over the roof. Above the roof the
	# castle's label sits 138px up, and since the camera centres on the player
	# it slides behind the HUD bar the moment you approach from the south.
	# World-space text, so size 14 is 28px on screen after the 2x upscale.
	# Over the doorstep on the path: above the lifted roof it is 200px up, which
	# is off-screen the moment the player stands on the path below it.
	var sign_y := -30.0
	var title := Art.label("Station %d" % (i + 1), 14, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	title.position = Vector2(-100, sign_y)
	title.size = Vector2(200, 20)
	st.add_child(title)
	_station_locks.append(title)
	var topic := Art.label(QuestionGen.station_meta(i).short, 11, Color(1, 1, 1, 0.92), HORIZONTAL_ALIGNMENT_CENTER)
	topic.position = Vector2(-100, sign_y + 18.0)
	topic.size = Vector2(200, 16)
	st.add_child(topic)
	# Both sit over grass and roof, so they need the same shadow the map prompts
	# use to stay readable.
	for l in [title, topic]:
		Art.shadow(l)
	_station_nodes.append(st)


func _spawn_player() -> void:
	player = Node2D.new()
	player.position = _anchors[0]
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
	# On the world, not the hero: the aerial POV has to frame the whole board
	# before it swoops down to him.
	_cam = Camera2D.new()
	_cam.position_smoothing_enabled = true
	_cam.position_smoothing_speed = 6.0
	_cam.limit_left = 0
	_cam.limit_top = 0
	_cam.limit_right = W * TILE
	_cam.limit_bottom = H * TILE
	_cam.position = player.position
	world.add_child(_cam)


# --- Pre-start aerial POV ---------------------------------------------------
## The client's flow shows the board from far away and frozen, then the camera
## swoops to the hero when the adventure starts. Offline that is a timed intro;
## in Phase 3 the admin's Start Game drives it, which is what `Game.clock_paused`
## is for -- no time is spent while the board is still frozen.
func _start_intro() -> void:
	_frozen = true
	Game.clock_paused = true
	_cam.position_smoothing_enabled = false
	_cam.zoom = Vector2(AERIAL_ZOOM, AERIAL_ZOOM)
	_cam.position = Vector2(W * TILE * 0.5, H * TILE * 0.5)
	_prompt.text = "Scouting the board..."
	_intro_tw = create_tween()
	_intro_tw.tween_interval(1.2)
	_intro_tw.set_parallel(true)
	_intro_tw.tween_property(_cam, "zoom", Vector2.ONE, 0.9).set_ease(Tween.EASE_IN_OUT)
	_intro_tw.tween_property(_cam, "position", player.position, 0.9).set_ease(Tween.EASE_IN_OUT)
	_intro_tw.chain().tween_callback(skip_intro)


## Collapse the intro at once -- the tail of the tween, and what the tests call so
## nothing waits on wall-clock time.
func skip_intro() -> void:
	if not _frozen:
		return
	if _intro_tw != null and _intro_tw.is_valid():
		_intro_tw.kill()
	_intro_tw = null
	_frozen = false
	Game.clock_paused = false
	_cam.zoom = Vector2.ONE
	_cam.position = player.position
	_cam.position_smoothing_enabled = true
	_prompt.text = ""
	_update_interaction()


## Which way the sprite faces. Vertical wins ties so a diagonal walk still
## shows the back or front, which reads better than a side-on shuffle.
static func _facing(dir: Vector2) -> String:
	if absf(dir.y) >= absf(dir.x):
		return "down" if dir.y > 0.0 else "up"
	return "right" if dir.x > 0.0 else "left"


func _process(delta: float) -> void:
	if _overlay != null and is_instance_valid(_overlay) and Game.adventure_active:
		return
	if _paused or _frozen or not Game.adventure_active:
		return
	_cam.position = player.position
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


# --- Gating -----------------------------------------------------------------
## One item per circle, strictly in order: the tower briefing unlocks its own
## circles, circle n unlocks only when n-1 is resolved, and the gate only once
## every circle is behind you.
func _can_enter_tower(i: int) -> bool:
	return (Game.items_done < Game.TOTAL_ITEMS
			and Game.station_of_item(Game.items_done) == i
			and not Game.towers_entered[i])


func _can_answer(n: int) -> bool:
	return n == Game.items_done and Game.towers_entered[Game.station_of_item(n)]


func _can_enter_gate() -> bool:
	return Game.items_done >= Game.TOTAL_ITEMS


## Index of the nearest node in `nodes` within reach, or -1.
func _nearest_of(nodes: Array) -> int:
	var best := -1
	var best_d := INTERACT_RADIUS
	for i in nodes.size():
		var n: Node2D = nodes[i]
		if n == null:
			continue
		var d := n.position.distance_to(player.position)
		if d < best_d:
			best_d = d
			best = i
	return best


## What the hero is standing at: {kind: "tower"|"circle"|"gate", index}, or {}.
## Anchors are ~68px apart against a 42px reach, so this is never ambiguous.
func _nearest_target() -> Dictionary:
	var best := {}
	var best_d := INTERACT_RADIUS
	for pair in [["tower", _station_nodes], ["circle", _circles], ["gate", [_gate]]]:
		var nodes: Array = pair[1]
		for i in nodes.size():
			var n: Node2D = nodes[i]
			if n == null:
				continue
			var d := n.position.distance_to(player.position)
			if d < best_d:
				best_d = d
				best = {"kind": pair[0], "index": i}
	return best


func _prompt_for(target: Dictionary) -> String:
	var go := "Tap GO" if Game.touch else "Press E / Space / Enter"
	match target.get("kind", ""):
		"tower":
			var i: int = target.index
			if _can_enter_tower(i):
				return "%s — enter Station %d" % [go, i + 1]
			if Game.items_done >= Game.TOTAL_ITEMS:
				return "Every circle cleared — head for the Victory Gate"
			if Game.towers_entered[i]:
				return "Station %d briefing done — follow the circles" % (i + 1)
			return "Complete Station %d first" % (Game.station_of_item(Game.items_done) + 1)
		"circle":
			var n: int = target.index
			if _can_answer(n):
				return "%s — Answer Quest!" % go
			if n < Game.items_done:
				return "Circle %d cleared" % (n + 1)
			if not Game.towers_entered[Game.station_of_item(n)]:
				return "Enter Station %d first" % (Game.station_of_item(n) + 1)
			return "Answer circle %d first" % (Game.items_done + 1)
		"gate":
			if _can_enter_gate():
				return "%s — enter the Victory Gate" % go
			return "Conquer all %d circles first" % Game.TOTAL_ITEMS
	return ""


func _update_interaction() -> void:
	if _flash_active:
		return
	_prompt.text = _prompt_for(_nearest_target())


func _unhandled_input(event: InputEvent) -> void:
	if _overlay != null or _paused or _frozen:
		return
	if event.is_action_pressed("interact"):
		_interact()
	elif event.is_action_pressed("pause"):
		_toggle_pause()


func _interact() -> void:
	match _nearest_target().get("kind", ""):
		"tower": _try_enter_station()
		"circle": _try_answer_circle()
		"gate": _try_enter_gate()


## The tower briefing: the station intro card, and nothing else. Its circles are
## what ask the questions.
func _try_enter_station() -> void:
	var i := _nearest_of(_station_nodes)
	if i < 0:
		return
	if not _can_enter_tower(i):
		if Game.items_done >= Game.TOTAL_ITEMS:
			_flash_tip("Every circle is cleared — head for the Victory Gate!")
		elif Game.towers_entered[i]:
			_flash_tip("Station %d is briefed — answer its circles!" % (i + 1))
		else:
			_flash_tip("Complete Station %d first!" % (Game.station_of_item(Game.items_done) + 1))
		return
	Game.current_station = i
	var quiz: Control = preload("res://scripts/QuizOverlay.gd").new()
	quiz.adventure = self
	quiz.station_index = i
	quiz.intro_only = true
	_show_overlay(quiz)


func _try_answer_circle() -> void:
	var n := _nearest_of(_circles)
	if n < 0:
		return
	if not _can_answer(n):
		if n < Game.items_done:
			_flash_tip("Circle %d is already cleared!" % (n + 1))
		elif not Game.towers_entered[Game.station_of_item(n)]:
			_flash_tip("Enter Station %d first!" % (Game.station_of_item(n) + 1))
		else:
			_flash_tip("Answer circle %d first!" % (Game.items_done + 1))
		return
	Game.current_station = Game.station_of_item(n)
	var quiz: Control = preload("res://scripts/QuizOverlay.gd").new()
	quiz.adventure = self
	quiz.station_index = Game.current_station
	_show_overlay(quiz)


func _try_enter_gate() -> void:
	if _gate == null or _gate.position.distance_to(player.position) >= INTERACT_RADIUS:
		return
	if not _can_enter_gate():
		_flash_tip("Conquer all %d circles first!" % Game.TOTAL_ITEMS)
		return
	Game.end_adventure()


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
	if Game.items_done >= Game.TOTAL_ITEMS:
		_hud_station.text = "Victory Gate!"
	else:
		var st := Game.station_of_item(Game.items_done)
		_hud_station.text = "Station %d · %d/%d" % [st + 1,
				Game.item_in_station(Game.items_done), Game.ITEMS_PER_STATION[st]]
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


## Locked / current / done for all forty, after every resolved item.
func _refresh_circles() -> void:
	for n in _circles.size():
		var state := "locked"
		if n < Game.items_done:
			state = "done"
		elif _can_answer(n):
			state = "current"
		(_circles[n] as Node2D).set_state(state)


## Android's back button, routed here by Main: leaving a station mid-question
## is not on offer, so back opens the pause menu instead.
func go_back() -> void:
	if _overlay == null and not _paused and not _frozen:
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
		# A briefing overlay unlocks its station's circles on the way out.
		if bool(_overlay.get("intro_only")):
			Game.towers_entered[int(_overlay.get("station_index"))] = true
		_overlay.queue_free()
		_overlay = null
		_set_pad(true)
		_refresh_hud()
		_refresh_circles()
	# Clearing the board no longer ends the run on its own -- the Victory Gate
	# does, and walking to it is the last step of the player flow.


func _on_adventure_end(result: Dictionary) -> void:
	if _overlay != null:
		close_overlay()
	_paused = false
	main.open("summary", result)
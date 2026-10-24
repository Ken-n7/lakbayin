class_name Backdrop
extends Control

## A living scene behind every menu screen -- the splash, sign in, register,
## reset, hero select, the lobby, the boards -- so none of them sits on a flat
## colour. One instance, owned by `Main` and kept across screens, so it drifts
## on smoothly while the screens change in front of it rather than restarting
## with each one.
##
## A monastery, village clearings and forest islands from the same Tiny Swords
## art as the match. Monks carry decorative Baybayin glyphs, adventurers walk
## between the houses, and clouds cross the archipelago. This is
## a fixed menu composition, independent of the procedural match generator.
##
## A dark wash sits over it all: the scene is atmosphere, and the parchment
## panels and white titles in front of it have to read first.

const TILE := 32.0                 # world px per cell; the 64px art drawn at 0.5
const W := 44                      # cells: wider than any screen, for the pan
const H := 13
const WATER := "res://assets/terrain/tileset/Water Background color.png"
const GRASS := "res://assets/terrain/tileset/Tilemap_color1.png"
## One full sweep across and back, in seconds. Slow enough to be felt rather
## than watched: a moving background that pulls the eye is a distraction.
const PAN_S := 70.0
const WASH := 0.38                 # the dark wash over the scene
## Baybayin drifting over the sea.
const SHOW_MOTES := true
const DECO := "res://assets/terrain/decorations/%s.png"
const BUILDINGS := "res://assets/buildings/%s.png"

## The three islands, drawn: . sea, # ground, ^ raised ground (level 1).
## Cliffs fall under each plateau's south edge, as on the match's maps. The
## Monastery's isle, the village round its pond, the wooded plateau.
const MAP := [
	"............................................",
	"............................................",
	"....######..........######.........######...",
	"..##########.......########.....##########..",
	".###^^^^^^^##.....##########...###^^^^^^###.",
	".###^^^^^^^###....##########...###^^^^^^###.",
	".###^^^^^^^###....####...###...###^^^^^^###.",
	".#############....###.....##...############.",
	".#############....####...###...############.",
	"..############.....#########....###########.",
	"..##########.......########......########...",
	"....#####............####..........####.....",
	"............................................",
]
## The ramp up each plateau: [the plateau cell at its bottom corner, side],
## side -1 for a ramp to its left (WorldGen._ramp_fits's geometry).
const RAMPS := [[Vector2i(10, 6), 1], [Vector2i(34, 6), -1]]

## [art, cell x, cell y (the base), scale]. Everything stands wholly on its
## own ground: backdrop_test.gd holds each one to it.
const PROPS := [
	# The Monastery on its plateau; the village below it.
	[BUILDINGS % "Purple_Monastery", 7.5, 6.85, 0.5],
	[BUILDINGS % "Blue_House1", 3.4, 9.8, 0.42],
	[BUILDINGS % "Red_House1", 8.4, 9.9, 0.42],
	# The village round the pond.
	[BUILDINGS % "Blue_House2", 19.6, 5.9, 0.45],
	[BUILDINGS % "Red_House2", 26.2, 10.4, 0.45],
	# Houses under the wooded plateau.
	[BUILDINGS % "Blue_House3", 35.0, 9.8, 0.42],
	[BUILDINGS % "Red_House3", 39.4, 9.6, 0.42],
	[DECO % "Rock4", 2.2, 7.6, 0.5],
	[DECO % "Rock2", 3.0, 3.8, 0.45],
	[DECO % "Rock1", 25.2, 4.2, 0.45],
	[DECO % "Rock3", 20.2, 4.6, 0.5],
	[DECO % "Rock2", 41.4, 8.6, 0.5],
	[DECO % "Rock4", 32.0, 4.6, 0.45],
]
## [tree, cell x, base y]: Tree1-4, swaying.
const TREES := [
	[1, 2.2, 5.6], [3, 9.9, 5.2],
	[4, 21.0, 3.8], [1, 26.2, 5.6], [2, 20.6, 9.6],
	[1, 35.2, 5.4], [2, 38.4, 4.8], [3, 41.6, 6.0],
]
const BUSHES := [[1, 12.4, 4.6], [3, 10.6, 10.4], [2, 23.4, 5.0], [4, 20.4, 8.4],
	[1, 37.2, 9.0], [3, 41.0, 4.4]]
## Water rocks, out at sea between the islands.
const WATER_ROCKS := [["01", 15.6, 10.8], ["02", 29.4, 2.4], ["03", 0.8, 2.4], ["04", 43.0, 11.6],
	["02", 15.2, 2.8], ["03", 29.6, 9.6]]

var _world: Node2D
var grid: MapGrid
var _clouds: Clouds
var _motes: MathMotes
var _land := {}
var _pan_tw: Tween


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_world = Node2D.new()
	_world.y_sort_enabled = true
	add_child(_world)
	_build_ground()
	_build_islands()
	_build_life()
	# Baybayin drifting over the sea, over the islands and under the clouds. Its
	# own node after the world, moved with it (`_pan_to`): inside the y-sorted
	# world it would sort under the islands, and a z_index lifts it over the
	# screens in front too -- it drew on the sign-in form.
	if SHOW_MOTES:
		_motes = MathMotes.new(Vector2(W * TILE, H * TILE))
		_motes.name = "MathMotes"
		add_child(_motes)
	_clouds = Clouds.new(W * TILE * 0.6)
	add_child(_clouds)
	var wash := ColorRect.new()
	wash.color = Color(Pal.BG, WASH)
	wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(wash)
	_start_pan()


## Nothing moves while hidden -- the map and Home have scenes of their own,
## and a phone should not be animating a backdrop nobody can see.
func set_shown(on: bool) -> void:
	visible = on
	process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
	if _pan_tw != null:
		if on:
			_pan_tw.play()
		else:
			_pan_tw.pause()


func _at(cx: float, cy: float) -> Vector2:
	return Vector2(cx * TILE, cy * TILE)


func _build_ground() -> void:
	var water: TileMapLayer = Art.terrain_layer(WATER, int(TILE), [Vector2i(0, 0)])
	# The same deeper sea Home uses, so the two scenes are one world.
	water.modulate = MapCfg.WATER_TINT
	_world.add_child(water)
	for y in H:
		for x in W:
			water.set_cell(Vector2i(x, y), 0, Vector2i(0, 0))
	water.z_index = -2
	_land = shape()
	var grass: TileMapLayer = Art.terrain_layer(GRASS, int(TILE))
	_world.add_child(grass)
	for cell: Vector2i in _land:
		grass.set_cell(cell, 0, Art.autotile(
				_land.has(cell + Vector2i(-1, 0)), _land.has(cell + Vector2i(1, 0)),
				_land.has(cell + Vector2i(0, -1)), _land.has(cell + Vector2i(0, 1))))
	# The raised ground, its cliffs, ramps, shadows and the surf on every
	# shore, painted as the match paints them (MapBuilder.paint_levels).
	grid = MapGrid.new()
	grid.land = _land
	for c: Vector2i in _land:
		grid.height[c] = 1 if MAP[c.y][c.x] == "^" else 0
	for r: Array in RAMPS:
		var side: int = r[1]
		grid.lay_ramp(r[0] + Vector2i(side, -1), 0, side)
	grid.lay_cliffs()
	MapBuilder.new(_world, grid).paint_levels()


## The islands' cells, from the drawing.
static func shape() -> Dictionary:
	var land := {}
	for y in H:
		for x in W:
			if MAP[y][x] != ".":
				land[Vector2i(x, y)] = true
	return land


## A neutral Monastery on its plateau, mixed village houses, woods and rocks.
func _build_islands() -> void:
	for p: Array in PROPS:
		var spr := Art.sprite(_world, Art.tex(p[0]), _at(p[1], p[2]), p[3])
		spr.name = "Monastery" if str(p[0]).ends_with("Purple_Monastery.png") \
				else str(p[0]).get_file().get_basename()
		spr.set_meta("prop", true)
	for i in TREES.size():
		var tr: Array = TREES[i]
		var t := Art.anim_sprite(_world, DECO % ("Tree%d" % tr[0]), _at(tr[1], tr[2]),
				0.4, 3.0, 1.0 if i % 2 == 0 else -1.0)
		t.frame = i % 6          # out of step, or the whole wood sways as one
		t.name = "Tree%d_%d" % [tr[0], i]
		t.set_meta("prop", true)
	for i in BUSHES.size():
		var b: Array = BUSHES[i]
		var bush := Art.anim_sprite(_world, DECO % ("Bush%d" % b[0]), _at(b[1], b[2]),
				0.32, 6.0, 1.0 if i % 2 == 0 else -1.0, 8)
		bush.set_meta("prop", true)
		bush.name = "Bush%d" % i
	for r: Array in WATER_ROCKS:
		var rock := Art.anim_sprite(_world, DECO % ("Water Rocks_%s" % r[0]), _at(r[1], r[2]),
				0.5, 4.0, 1.0, 16)
		rock.set_meta("at_sea", true)


## Peaceful island life: teachers of the script and travellers.
func _build_life() -> void:
	for i in 3:
		var monk := Monk.new()
		monk.index = i + 2
		monk.name = "GuideMonk%d" % i
		monk.position = _at([12.4, 26.6, 32.0][i], [9.0, 8.0, 9.0][i])
		monk.set_meta("prop", true)
		_world.add_child(monk)
	_walker(Game.hero_id, _at(3.0, 10.6), _at(10.0, 10.6), 6.0)
	_walker(14, _at(19.8, 10.5), _at(24.6, 10.5), 4.6)
	_walker(7, _at(34.0, 10.5), _at(39.0, 10.5), 5.0)


## Walks from `a` to `b` and back for ever, turning at each end.
func _walker(hero_id: int, a: Vector2, b: Vector2, secs: float) -> void:
	var walker := AnimatedSprite2D.new()
	walker.set_meta("walk", [a, b])
	walker.sprite_frames = Art.walk_frames(Game.hero_sheet(hero_id), 6.0)
	walker.scale = Vector2(1.6, 1.6)
	walker.offset = Vector2(0, -10)
	walker.position = a
	walker.play("right")
	_world.add_child(walker)
	var tw := walker.create_tween().set_loops()
	tw.tween_property(walker, "position", b, secs)
	tw.tween_callback(func() -> void: walker.play("left"))
	tw.tween_property(walker, "position", a, secs)
	tw.tween_callback(func() -> void: walker.play("right"))


## Across the islands and back, eased at each end so it never visibly stops
## and starts.
func _start_pan() -> void:
	_pan_tw = create_tween().set_loops()
	_pan_tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_pan_tw.tween_method(_pan_to, 0.0, 1.0, PAN_S * 0.5)
	_pan_tw.tween_method(_pan_to, 1.0, 0.0, PAN_S * 0.5)


func _pan_to(t: float) -> void:
	var travel := maxf(W * TILE - maxf(size.x, 1.0), 0.0)
	_world.position.x = -travel * t
	# Centre the band of islands in whatever height this screen has.
	_world.position.y = (size.y - H * TILE) * 0.5
	if _motes != null:
		_motes.position = _world.position

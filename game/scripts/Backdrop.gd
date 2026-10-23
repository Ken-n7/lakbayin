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
## between the houses, sheep graze, and clouds cross the archipelago. This is
## a fixed menu composition, independent of the procedural match generator.
##
## A dark wash sits over it all: the scene is atmosphere, and the parchment
## panels and white titles in front of it have to read first.

const TILE := 32.0                 # world px per cell; the 64px art drawn at 0.5
const W := 44                      # cells: wider than any screen, for the pan
const H := 13
const WATER := "res://assets/terrain/tileset/Water Background color.png"
const GRASS := "res://assets/terrain/tileset/Tilemap_color1.png"
const TREES := ["res://assets/terrain/decorations/Tree1.png",
		"res://assets/terrain/decorations/Tree2.png",
		"res://assets/terrain/decorations/Tree3.png"]
## One full sweep across and back, in seconds. Slow enough to be felt rather
## than watched: a moving background that pulls the eye is a distraction.
const PAN_S := 70.0
const WASH := 0.38                 # the dark wash over the scene
## Baybayin drifting over the sea and ordinary rocks along the shore.
const SHOW_MOTES := true
const SHOW_CARVINGS := true
## [piece, cell x, cell y, scale]: plain rocks placed on each island.
const CARVINGS := [
	["blue_a", 6.4, 10.2, 1.2], ["blue_b", 8.7, 8.3, 1.0], ["blue_c", 4.4, 9.9, 1.1],
	["yellow_a", 20.6, 9.9, 1.25], ["yellow_b", 21.7, 8.1, 1.0],
	["red_a", 37.6, 6.8, 1.15], ["red_b", 34.4, 9.1, 1.0], ["red_c", 37.4, 10.9, 1.0],
	["red_d", 35.8, 10.6, 0.9],
]

## Island: centre and radii in cells.
const ISLANDS := [
	{"c": Vector2(7.5, 6.8), "r": Vector2(5.6, 3.9)},
	{"c": Vector2(21.5, 6.2), "r": Vector2(5.2, 3.7)},
	{"c": Vector2(35.5, 7.0), "r": Vector2(5.8, 3.8)},
]

var _world: Node2D
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
	for y in H:
		for x in W:
			for isl: Dictionary in ISLANDS:
				var n: Vector2 = (Vector2(x + 0.5, y + 0.5) - isl.c) / isl.r
				var ang := atan2(n.y, n.x)
				if n.length() < 0.92 + 0.08 * sin(ang * 3.0 + isl.c.x) + 0.04 * cos(ang * 5.0):
					_land[Vector2i(x, y)] = true
	# Water, then the surf breaking on every shore, then the land over it --
	# the pack's own layer order (its tilemap guide).
	water.z_index = -2
	Art.shore_foam(_world, _land, TILE).z_index = -1
	var grass: TileMapLayer = Art.terrain_layer(GRASS, int(TILE))
	_world.add_child(grass)
	for cell: Vector2i in _land:
		grass.set_cell(cell, 0, Art.autotile(
				_land.has(cell + Vector2i(-1, 0)), _land.has(cell + Vector2i(1, 0)),
				_land.has(cell + Vector2i(0, -1)), _land.has(cell + Vector2i(0, 1))))
	# Sheep ask the world where the grass is (see Wander.gd).
	_world.set_meta("grass", grass)
	_world.set_meta("tile", TILE)


## A neutral Monastery, mixed village houses, and woodland on the outer islands.
func _build_islands() -> void:
	var b := "res://assets/buildings/"
	var place := [
		[b + "Purple_Monastery.png", 7.5, 6.8, 0.5],
		[b + "Blue_House1.png", 4.4, 8.4, 0.45],
		[b + "Red_House1.png", 10.2, 8.8, 0.45],
		[b + "Blue_House2.png", 19.4, 6.7, 0.5],
		[b + "Red_House2.png", 23.5, 7.9, 0.5],
		[b + "Blue_House3.png", 34.2, 7.0, 0.45],
		[b + "Red_House3.png", 38.2, 8.5, 0.45],
	]
	for p: Array in place:
		var building := Art.sprite(_world, Art.cell(p[0], 0, 0), _at(p[1], p[2]), p[3])
		if str(p[0]).ends_with("Purple_Monastery.png"):
			building.name = "Monastery"
	var trees := [[3.0, 5.8], [5.2, 4.4], [11.6, 5.4], [9.4, 9.2], [17.2, 5.2],
		[19.8, 4.0], [25.6, 5.0], [23.4, 9.0], [31.0, 5.8], [33.6, 4.6], [39.8, 5.8], [37.2, 9.4]]
	for i in trees.size():
		var t := Art.anim_sprite(_world, TREES[i % TREES.size()], _at(trees[i][0], trees[i][1]),
				0.42, 3.0, 1.0 if i % 2 == 0 else -1.0)
		t.frame = i % 6          # out of step, or the whole wood sways as one
	if SHOW_CARVINGS:
		for c: Array in CARVINGS:
			var spr := Art.sprite(_world, Art.tex(MapCfg.plain_rock(c[0])), _at(c[1], c[2]), c[3])
			spr.name = c[0]
	for r in [["Rock2", 13.6, 6.0], ["Rock4", 27.4, 7.2], ["Rock1", 41.0, 7.6]]:
		Art.sprite(_world, Art.tex("res://assets/terrain/decorations/%s.png" % r[0]),
				_at(r[1], r[2]), 1.2)
	for r in [["Water Rocks_01", 14.8, 10.6], ["Water Rocks_02", 28.6, 2.4],
			["Water Rocks_03", 1.4, 2.6], ["Water Rocks_04", 42.4, 11.2]]:
		Art.anim_sprite(_world, "res://assets/terrain/decorations/%s.png" % r[0],
				_at(r[1], r[2]), 0.5, 4.0, 1.0, 16)


## Peaceful island life: teachers of the script, travellers, and grazing sheep.
func _build_life() -> void:
	for s in [[6.0, 9.0], [20.4, 8.6], [36.8, 9.2], [9.8, 5.2]]:
		_world.add_child(_sheep(_at(s[0], s[1])))
	for i in 3:
		var monk := Monk.new()
		monk.index = i + 2
		monk.name = "GuideMonk%d" % i
		monk.position = _at([9.2, 21.5, 36.0][i], [7.4, 8.5, 8.4][i])
		_world.add_child(monk)
	_walker(Game.hero_id, _at(5.0, 9.8), _at(9.0, 9.8), 5.0)
	_walker(14, _at(18.6, 9.6), _at(23.6, 9.6), 5.6)
	_walker(7, _at(33.2, 10.0), _at(38.0, 10.0), 5.2)


func _sheep(at: Vector2) -> Node2D:
	var sheep := Node2D.new()
	var spr := AnimatedSprite2D.new()
	spr.sprite_frames = Art.anim_spriteframes({
		"idle": [MapCfg.SHEEP_IDLE, MapCfg.SHEEP_IDLE_FPS, true],
		"walk": [MapCfg.SHEEP_WALK, MapCfg.SHEEP_WALK_FPS, true],
	})
	spr.scale = Vector2(MapCfg.SHEEP_SCALE, MapCfg.SHEEP_SCALE)
	sheep.add_child(spr)
	sheep.position = at
	sheep.set_script(preload("res://scripts/Wander.gd"))
	return sheep


## Walks from `a` to `b` and back for ever, turning at each end.
func _walker(hero_id: int, a: Vector2, b: Vector2, secs: float) -> void:
	var walker := AnimatedSprite2D.new()
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

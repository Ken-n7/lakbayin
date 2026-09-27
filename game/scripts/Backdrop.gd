class_name Backdrop
extends Control

## A living scene behind every menu screen -- the splash, sign in, register,
## reset, hero select, the lobby, the boards -- so none of them sits on a flat
## colour. One instance, owned by `Main` and kept across screens, so it drifts
## on smoothly while the screens change in front of it rather than restarting
## with each one.
##
## Three small islands in the stations' three liveries, from the same Tiny
## Swords art as the map: trees swaying, sheep grazing, workers walking their
## rounds, a guard or two, clouds crossing, and the whole view panning slowly
## back and forth. A fixed composition, no RNG, so every launch looks the same.
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
	# Maths rising out of the sea, over the islands and under the clouds. Its
	# own node after the world, moved with it (`_pan_to`): inside the y-sorted
	# world it would sort under the islands, and a z_index lifts it over the
	# screens in front too -- it drew on the sign-in form.
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


## A keep and its houses per island -- blue, yellow, red, the stations' order.
func _build_islands() -> void:
	var b := "res://assets/buildings/"
	var place := [
		[b + "Blue_Monastery.png", 7.4, 6.6, 0.5], [b + "Blue_House1.png", 4.2, 8.2, 0.5],
		[b + "Blue_Tower.png", 10.6, 7.4, 0.45],
		[b + "Yellow_Archery.png", 21.8, 6.0, 0.5], [b + "Yellow_House2.png", 18.6, 7.8, 0.5],
		[b + "Yellow_Tower.png", 24.8, 8.0, 0.45],
		[b + "Red_Barracks.png", 35.2, 6.8, 0.5], [b + "Red_House3.png", 38.8, 8.4, 0.5],
		[b + "Red_Tower.png", 32.0, 8.2, 0.45],
	]
	for p: Array in place:
		Art.sprite(_world, Art.tex(p[0]), _at(p[1], p[2]), p[3])
	var trees := [[3.0, 5.8], [5.2, 4.4], [11.6, 5.4], [9.4, 9.2], [17.2, 5.2],
		[19.8, 4.0], [25.6, 5.0], [23.4, 9.0], [31.0, 5.8], [33.6, 4.6], [39.8, 5.8], [37.2, 9.4]]
	for i in trees.size():
		var t := Art.anim_sprite(_world, TREES[i % TREES.size()], _at(trees[i][0], trees[i][1]),
				0.42, 3.0, 1.0 if i % 2 == 0 else -1.0)
		t.frame = i % 6          # out of step, or the whole wood sways as one
	for r in [["Rock2", 13.6, 6.0], ["Rock4", 27.4, 7.2], ["Rock1", 41.0, 7.6]]:
		Art.sprite(_world, Art.tex("res://assets/terrain/decorations/%s.png" % r[0]),
				_at(r[1], r[2]), 1.2)
	for r in [["Water Rocks_01", 14.8, 10.6], ["Water Rocks_02", 28.6, 2.4],
			["Water Rocks_03", 1.4, 2.6], ["Water Rocks_04", 42.4, 11.2]]:
		Art.anim_sprite(_world, "res://assets/terrain/decorations/%s.png" % r[0],
				_at(r[1], r[2]), 0.5, 4.0, 1.0, 16)


## Who lives here: sheep grazing, a worker on each island walking a round, a
## knight and an archer standing their posts.
func _build_life() -> void:
	for s in [[6.0, 9.0], [20.4, 8.6], [36.8, 9.2], [9.8, 5.2]]:
		_world.add_child(_sheep(_at(s[0], s[1])))
	var u := "res://assets/units/"
	_walker(u + "Blue/Pawn_Run.png", _at(4.6, 9.6), _at(10.0, 9.6), 5.0)
	_walker(u + "Yellow/Pawn_Run.png", _at(18.4, 9.4), _at(24.2, 9.4), 5.6)
	_walker(u + "Red/Pawn_Run.png", _at(32.6, 9.8), _at(38.4, 9.8), 5.2)
	Art.anim_sprite(_world, u + "Blue/Warrior_Idle.png", _at(12.4, 8.4), 0.34, 8.0)
	Art.anim_sprite(_world, u + "Yellow/Archer_Idle.png", _at(26.2, 6.8), 0.34, 8.0, -1.0)
	Art.anim_sprite(_world, u + "Red/Warrior_Idle.png", _at(30.6, 7.2), 0.34, 8.0)


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
func _walker(path: String, a: Vector2, b: Vector2, secs: float) -> void:
	var w := Art.anim_sprite(_world, path, a, 0.34, 10.0)
	var tw := w.create_tween().set_loops()
	tw.tween_property(w, "position", b, secs)
	tw.tween_callback(func() -> void: w.scale.x = -absf(w.scale.x))
	tw.tween_property(w, "position", a, secs)
	tw.tween_callback(func() -> void: w.scale.x = absf(w.scale.x))


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

class_name Decor
extends RefCounted

## Everything growing on the islands: trees, stumps, rocks, loot, sheep, and the
## animated rocks in the water offshore.
##
## Props arrive in patches of one kind rather than as noise, and keep off the
## road, the shore, the stations and each other -- `MapGrid.plantable()` is the
## single rule for where anything may stand. One fixed seed, so the board is the
## same every run.

var world: Node2D
var grid: MapGrid
## Every prop's solid rect, for `test_collisions`.
var feet: Array[Rect2] = []


func _init(w: Node2D, g: MapGrid) -> void:
	world = w
	grid = g


# --- Decorations ------------------------------------------------------------
## Dressed per island, off one weight table, so the three stations read as three
## places: a wooded valley, a stony quarry, a bare highland. Same weighted roll as
## before -- only the thresholds and the counts now come from `ISLAND_PROPS`.
## Props arrive as patches of one kind, on ground that is clear of the road, the
## stations and every prop already standing. That is the whole difference between
## a wood and a scatter of single trees: the roll picks WHAT grows here, and then
## a handful of it grows here, together.
##
## Deterministic -- one fixed seed, so the board is the same every run. There is
## nothing to be gained from a different mess each time; there is a lot to be lost.
func build() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = MapCfg.DECOR_SEED
	for isl in MapCfg.ISLAND_PROPS.size():
		var mix: Dictionary = MapCfg.ISLAND_PROPS[isl]
		var placed := 0
		var tries := 0
		while placed < int(mix.count) and tries < int(mix.count) * MapCfg.DECOR_TRIES:
			tries += 1
			var c := Vector2i(rng.randi_range(1, MapCfg.WORLD_W - 2), rng.randi_range(1, MapCfg.WORLD_H - 2))
			if not grid.plantable(c, isl):
				continue
			placed += _plant_patch(rng, c, _roll_kind(rng, mix), isl)
		for _k in int(mix.sheep):
			world.add_child(_sheep_at(rng, isl))
	# Animated rocks in the water off each island, to break up the open sea.
	for isl in MapCfg.ISLANDS.size():
		var c: Vector2 = MapCfg.ISLANDS[isl].c
		var r: Vector2 = MapCfg.ISLANDS[isl].r
		for side in [-1.0, 1.0]:
			var wrp := MapGrid.norm(Vector2(c.x + side * (r.x + MapCfg.WATER_ROCK_OUT),
					c.y + MapCfg.WATER_ROCK_DOWN))
			if MapGrid.in_bounds(MapGrid.cell_at(wrp)) and not grid.is_walkable(wrp):
				Art.anim_sprite(world, MapCfg.WATER_ROCK_SHEET % rng.randi_range(1, MapCfg.DECOR_VARIANTS),
						wrp, MapCfg.WATER_ROCK_SCALE, MapCfg.WATER_ROCK_FPS, 1.0, 16)




## Puts a prop scene (`scenes/props/`) on its base point and makes its
## collision boxes solid: every CollisionShape2D rectangle under its `Foot`
## body becomes a wall on the grid -- the trunk, a rock's body, not the canopy
## the hero walks under. The body itself is dropped; nothing here moves by
## physics, the grid is the only thing the hero bumps into. Props keep off the
## road, so this can never close the walk -- `test_collisions` floods the board
## to prove it.
func _prop(name: String, at: Vector2, flip := 1.0) -> void:
	var prop: Node2D = load(MapCfg.PROP_SCENE % name).instantiate()
	prop.position = at
	prop.scale.x = flip
	world.add_child(prop)
	var foot := prop.get_node_or_null("Foot")
	if foot == null:
		return
	for box in foot.get_children():
		var shape := (box as CollisionShape2D).shape as RectangleShape2D
		if shape == null:
			continue
		var xf: Transform2D = prop.transform * (foot as Node2D).transform * (box as Node2D).transform
		var size := shape.size * xf.get_scale().abs()
		var r := Rect2(xf.origin - size * 0.5, size)
		grid.block(r)
		feet.append(r)
	foot.free()


## The same weighted roll as before, but for the patch rather than for one prop.
func _roll_kind(rng: RandomNumberGenerator, mix: Dictionary) -> String:
	var roll := rng.randf()
	if roll < float(mix.tree):
		return "tree"
	if roll < float(mix.stump):
		return "stump"
	if roll < float(mix.rock):
		return "rock"
	return "loot"


func _plant_patch(rng: RandomNumberGenerator, c: Vector2i, kind: String, isl: int) -> int:
	var want := rng.randi_range(1, int(MapCfg.PATCH[kind]))
	var n := 0
	for cc in MapGrid.rings(c, MapCfg.PATCH_RADIUS):
		if n >= want:
			break
		if not grid.plantable(cc, isl):
			continue
		if cc != c and rng.randf() < MapCfg.PATCH_HOLE:
			continue
		grid.taken[cc] = true
		_plant(rng, cc, kind)
		n += 1
	return n


func _plant(rng: RandomNumberGenerator, c: Vector2i, kind: String) -> void:
	var p := MapGrid.cell_mid(c)
	match kind:
		"tree":
			var fl := 1.0 if rng.randf() < MapCfg.TREE_FLIP else -1.0
			_prop("Tree%d" % rng.randi_range(1, MapCfg.DECOR_VARIANTS), p, fl)
		"stump":
			_prop("Stump%d" % rng.randi_range(1, MapCfg.DECOR_VARIANTS), p)
		"rock":
			_prop("Rock%d" % rng.randi_range(1, MapCfg.DECOR_VARIANTS), p)
		_:
			var loot := (MapCfg.LOOT_SHEETS as Array).duplicate()
			loot[-1] = str(loot[-1]) % rng.randi_range(1, MapCfg.DECOR_VARIANTS)
			Art.sprite(world, Art.tex(loot[rng.randi_range(0, loot.size() - 1)]),
					p, MapCfg.LOOT_SCALE)


func _sheep_at(rng: RandomNumberGenerator, isl := 0) -> Node2D:
	var sheep := Node2D.new()
	var spr := AnimatedSprite2D.new()
	spr.sprite_frames = Art.anim_spriteframes({
		"idle": [MapCfg.SHEEP_IDLE, MapCfg.SHEEP_IDLE_FPS, true],
		"walk": [MapCfg.SHEEP_WALK, MapCfg.SHEEP_WALK_FPS, true],
	})
	spr.scale = Vector2(MapCfg.SHEEP_SCALE, MapCfg.SHEEP_SCALE)
	sheep.add_child(spr)
	var shadow := Sprite2D.new()
	shadow.texture = Art.tex(MapCfg.SHADOW_SHEET)
	shadow.scale = Vector2(MapCfg.SHEEP_SHADOW_SCALE, MapCfg.SHEEP_SHADOW_SCALE)
	shadow.modulate.a = MapCfg.SHEEP_SHADOW_ALPHA
	sheep.add_child(shadow)
	sheep.set_script(preload("res://scripts/Wander.gd"))
	var c: Vector2 = MapCfg.ISLANDS[isl].c
	var r: Vector2 = MapCfg.ISLANDS[isl].r
	var spread := MapCfg.SHEEP_SPREAD
	sheep.position = grid.first_land(
			c.x + rng.randf_range(-spread, spread) * r.x,
			c.y + rng.randf_range(-spread, spread) * r.y, c)
	return sheep

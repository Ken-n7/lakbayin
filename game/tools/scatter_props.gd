extends Node

## Scatters the map's trees, stumps and rocks so the board reads as a place:
## woods and meadows from a noise field rather than an even sprinkle, clearings
## along the road and round the stations, groves of one species, rocks in
## outcrops, stumps on the edges of the woods. Each island keeps its character
## from MapCfg.ISLAND_PROPS. Every prop's footprint is its scene's own
## collision boxes, as edited, and must clear the road, the shore, the stations
## and every other prop.
##
## Writes scenes/map/MapProps.tscn, a group per island, and the animated rocks
## in the water off each island -- the map's props are generated, not placed
## by hand. The seed is printed; pass it back to get
## the same board again, or leave it out for a new one:
##
##   godot --headless --path game res://tools/scatter_props.tscn -- [seed=N]
##
## test_collisions afterwards proves the hero can still reach every stop.

const TREES := ["Tree1", "Tree2", "Tree3", "Tree4"]
const STUMPS := ["Stump1", "Stump2", "Stump3", "Stump4"]
const ROCKS := ["Rock1", "Rock2", "Rock3", "Rock4"]

## Closest two props of these kinds may stand, origin to origin, in px.
const SPACING := {"tree": 22.0, "stump": 22.0, "rock": 30.0}
## Darts thrown per land cell; more is a denser, slower, better-spaced pick.
const DARTS := 5
## A rock in the water off either side of each island, to break up the sea:
## how far past the island's own ellipse, as a share of the world.
const WATER_ROCK := "res://assets/terrain/decorations/Water Rocks_0%d.png"
const WATER_ROCK_OUT := 0.035
const WATER_ROCK_DOWN := 0.04
const WATER_ROCK_SCALE := 1.4
const WATER_ROCK_FPS := 4.0

var grid: MapGrid
var rng := RandomNumberGenerator.new()
var _feet := {}                 # variant -> its collision rects, about its origin
var _placed: Array[Dictionary] = []    # {kind, name, at, flip, rects}
var _trail_dist := {}           # cell -> cells to the nearest road cell


func _ready() -> void:
	var seed := int(Time.get_unix_time_from_system()) % 100000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("seed="):
			seed = int(a.trim_prefix("seed="))
	rng.seed = seed

	var world := MapWorld.new()
	world.bare = true
	add_child(world)
	world.build()
	grid = world.grid
	_measure_feet()
	_measure_trail()

	var forest := _noise(seed, 0.0045)
	var stone := _noise(seed + 7, 0.008)
	var grove := _noise(seed + 13, 0.003)

	var darts: Array[Vector2] = []
	for c: Vector2i in grid.land:
		if grid.beach.has(c) or grid.trail.has(c):
			continue
		for _i in DARTS:
			darts.append(MapGrid.cell_mid(c) + Vector2(rng.randf_range(-16, 16), rng.randf_range(-16, 16)))
	# A random order, or the scan direction shows in the result.
	for i in range(darts.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := darts[i]
		darts[i] = darts[j]
		darts[j] = t

	# How much of each island is woods and how much rock is its character,
	# not luck: the noise decides where, a share per island decides how much.
	# Each island's edge of the woods is the noise level that many of its
	# darts clear.
	var levels := {}                # island -> [woods level, rock level]
	var by_island := {}
	for p in darts:
		# Shares of the ground that can hold anything, not of the clearings.
		if _open(p) < 0.5:
			continue
		var isl := int(grid.island_of.get(MapGrid.cell_at(p), 0))
		if not by_island.has(isl):
			by_island[isl] = [[], []]
		by_island[isl][0].append((forest.get_noise_2dv(p) + 1.0) * 0.5)
		by_island[isl][1].append((stone.get_noise_2dv(p) + 1.0) * 0.5)
	for isl in by_island:
		var mix: Dictionary = MapCfg.ISLAND_PROPS[isl]
		var woods := 0.14 + 0.5 * float(mix.tree)
		var rocky := 0.05 + 0.3 * (float(mix.rock) - float(mix.stump))
		levels[isl] = [_level(by_island[isl][0], woods), _level(by_island[isl][1], rocky)]

	for p in darts:
		var cell := MapGrid.cell_at(p)
		var isl := int(grid.island_of.get(cell, 0))
		var mix: Dictionary = MapCfg.ISLAND_PROPS[isl]
		var lv: Array = levels[isl]
		var w_tree := float(mix.tree)
		var w_stump := float(mix.stump) - float(mix.tree)
		var w_rock := float(mix.rock) - float(mix.stump)
		var road := float(_trail_dist.get(cell, 99)) * MapCfg.TILE
		var station := _keep_dist(p)
		var open := _open(p)
		var n := (forest.get_noise_2dv(p) + 1.0) * 0.5
		var s := (stone.get_noise_2dv(p) + 1.0) * 0.5
		var woods: float = lv[0]
		var rocky: float = lv[1]
		var p_tree := smoothstep(woods - 0.04, woods + 0.07, n) * open
		var p_rock := (smoothstep(rocky - 0.03, rocky + 0.05, s) * 0.7 + 0.01) \
			* smoothstep(20.0, 50.0, road) * smoothstep(12.0, 50.0, station)
		var edge := clampf(1.0 - absf(n - (woods - 0.06)) / 0.05, 0.0, 1.0)
		var p_stump := 0.2 * edge * open * clampf(w_stump / 0.15, 0.3, 1.5)
		var roll := rng.randf()
		var kind := ""
		var name := ""
		if roll < p_tree:
			kind = "tree"
			# Groves of one species, with a stranger now and then.
			var g := (grove.get_noise_2dv(p) + 1.0) * 0.5
			name = TREES[clampi(int(g * 4.0), 0, 3)] if rng.randf() > 0.2 else TREES[rng.randi_range(0, 3)]
		elif roll < p_tree + p_rock:
			kind = "rock"
			name = ROCKS[rng.randi_range(0, 3)]
		elif roll < p_tree + p_rock + p_stump:
			kind = "stump"
			name = STUMPS[rng.randi_range(0, 3)]
		else:
			continue
		var flip := -1.0 if kind == "tree" and rng.randf() < 0.3 else 1.0
		var rects := _rects_at(name, p, flip)
		if _fits(kind, p, rects):
			_placed.append({"kind": kind, "name": name, "at": p, "flip": flip, "rects": rects})

	var counts := {}
	for d in _placed:
		counts[d.kind] = int(counts.get(d.kind, 0)) + 1
	print("seed %d: %d props %s" % [seed, _placed.size(), counts])
	_save(world)
	get_tree().quit()


## The value `share` of `values` lie above.
static func _level(values: Array, share: float) -> float:
	var v := values.duplicate()
	v.sort()
	return float(v[clampi(int((1.0 - share) * v.size()), 0, v.size() - 1)])


func _noise(seed: int, freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_octaves = 3
	return n


## Each variant's collision boxes, read off its scene -- the sizes the client
## has set in the editor, not a guess.
func _measure_feet() -> void:
	for name in TREES + STUMPS + ROCKS:
		var inst: Node2D = load(MapCfg.PROP_SCENE % name).instantiate()
		var rects: Array[Rect2] = []
		for body in inst.get_children():
			if body is StaticBody2D:
				for shape_node in body.get_children():
					if shape_node is CollisionShape2D:
						rects.append_array(Decor._walls_of((shape_node as CollisionShape2D).shape,
							(body as Node2D).transform * (shape_node as Node2D).transform))
		inst.free()
		_feet[name] = rects


func _rects_at(name: String, at: Vector2, flip: float) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for r: Rect2 in _feet[name]:
		var x := r.position.x if flip > 0.0 else -r.end.x
		out.append(Rect2(at + Vector2(x, r.position.y), r.size))
	return out


## Cells to the nearest road cell, by a flood from the road outward.
func _measure_trail() -> void:
	var queue: Array[Vector2i] = []
	for c: Vector2i in grid.trail:
		_trail_dist[c] = 0
		queue.append(c)
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if _trail_dist.has(n) or not grid.land.has(n):
				continue
			_trail_dist[n] = int(_trail_dist[c]) + 1
			queue.append(n)


## 0 in the clearings -- a tile or two along the road and round the stations,
## so the way and the landmarks stay open -- rising to 1 beyond them.
func _open(p: Vector2) -> float:
	var road := float(_trail_dist.get(MapGrid.cell_at(p), 99)) * MapCfg.TILE
	return smoothstep(24.0, 72.0, road) * smoothstep(16.0, 60.0, _keep_dist(p))


func _keep_dist(p: Vector2) -> float:
	var best := INF
	for r: Rect2 in grid.station_rects + grid.sign_rects:
		var q := Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
		best = minf(best, p.distance_to(q))
	return best


## Room for this prop here: its boxes on inland grass, off the road and clear
## of every wall, keep-out and prop already placed; and far enough from its
## neighbours.
func _fits(kind: String, at: Vector2, rects: Array[Rect2]) -> bool:
	var all := rects.duplicate()
	all.append(Rect2(at, Vector2.ZERO))
	for r: Rect2 in all:
		for corner in [r.position, Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), r.end]:
			var c := MapGrid.cell_at(corner)
			if not grid.land.has(c) or grid.beach.has(c) or grid.trail.has(c):
				return false
		var wide := r.grow(4.0)
		for w: Rect2 in grid.solid:
			if w.intersects(wide):
				return false
		for k: Rect2 in grid.station_rects + grid.sign_rects:
			if k.intersects(r):
				return false
	for d: Dictionary in _placed:
		var gap := maxf(float(SPACING[kind]), float(SPACING[d.kind]))
		if (d.at as Vector2).distance_to(at) < gap:
			return false
		for a: Rect2 in rects:
			for b: Rect2 in d.rects:
				if a.grow(1.0).intersects(b):
					return false
	return true


func _save(world: MapWorld) -> void:
	var root := Node2D.new()
	root.name = "Props"
	root.y_sort_enabled = true
	var sea := Node2D.new()
	sea.name = "WaterRocks"
	sea.y_sort_enabled = true
	root.add_child(sea)
	sea.owner = root
	for isl in MapCfg.ISLANDS.size():
		var c: Vector2 = MapCfg.ISLANDS[isl].c
		var r: Vector2 = MapCfg.ISLANDS[isl].r
		for side in [-1.0, 1.0]:
			var at := MapGrid.norm(Vector2(c.x + side * (r.x + WATER_ROCK_OUT), c.y + WATER_ROCK_DOWN))
			if not MapGrid.in_bounds(MapGrid.cell_at(at)) or grid.is_walkable(at):
				continue
			var rock := Art.anim_sprite(sea, WATER_ROCK % rng.randi_range(1, 4), at,
				WATER_ROCK_SCALE, WATER_ROCK_FPS, 1.0, 16)
			rock.name = "WaterRock"
			rock.autoplay = rock.animation
			rock.owner = root

	var groups := {}
	for d: Dictionary in _placed:
		var isl := int(grid.island_of.get(MapGrid.cell_at(d.at), 0))
		if not groups.has(isl):
			var g := Node2D.new()
			g.name = "Island%d" % isl
			g.y_sort_enabled = true
			root.add_child(g)
			g.owner = root
			groups[isl] = g
		var prop: Node2D = load(MapCfg.PROP_SCENE % d.name).instantiate()
		prop.name = d.name
		prop.position = (d.at as Vector2).round()
		prop.scale.x = d.flip
		(groups[isl] as Node2D).add_child(prop, true)
		prop.owner = root

	var scene := PackedScene.new()
	scene.pack(root)
	print("saved ", MapCfg.MAP_PROPS, ": ", ResourceSaver.save(scene, MapCfg.MAP_PROPS))
	root.free()

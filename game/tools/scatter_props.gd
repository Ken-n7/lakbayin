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
## Which trees grow at each level: Tree1-2 are pines, Tree3-4 leafy (yellow,
## autumn).
const SPECIES := [["Tree3", "Tree4"], ["Tree3", "Tree4", "Tree1"], ["Tree1", "Tree2"],
	["Tree2", "Tree1"]]
const STUMPS := ["Stump1", "Stump2", "Stump3", "Stump4"]
const ROCKS := ["Rock1", "Rock2", "Rock3", "Rock4"]

## Closest two props of these kinds may stand, origin to origin, in px.
const SPACING := {"tree": 22.0, "stump": 22.0, "rock": 30.0}
## Darts thrown per land cell; more is a denser, slower, better-spaced pick.
const DARTS := 5
const BUSH := "res://assets/terrain/decorations/Bush%d.png"
const BUSH_SCALE := 0.32
const BUSH_FPS := 6.0
## Chance of a bush at each spot along a cliff's foot, and beside stairs.
const BUSH_AT_CLIFF := 0.6
const BUSH_AT_STAIRS := 0.9
## Chance a tree on the ground gets a bush at its foot, on the wood's edge.
const BUSH_AT_WOODS := 0.35
## Clumps of bushes out in the ground-level meadows, and along the roads.
const BUSH_CLUMPS := 70
const BUSH_AT_ROAD := 0.12
## Rocks in the water off every shore, to break up the sea: this many, one to
## four tiles out, far enough apart not to clump, and clear of the bridges.
const WATER_ROCK := "res://assets/terrain/decorations/Water Rocks_0%d.png"
const WATER_ROCKS := 24
const WATER_ROCK_OFFSHORE := Vector2i(3, 6)    # tiles from land, nearest to farthest: a rock is near 3 wide
const WATER_ROCK_APART := 5                    # tiles between two of them
const WATER_ROCK_BRIDGE := 3                   # tiles kept clear of the road
## ...and of the barricade fences, or one off a fence's end reads as the fence
## running on into the sea.
const WATER_ROCK_FENCE := 4
const WATER_ROCK_SCALE := 1.4
const WATER_ROCK_FPS := 4.0

var grid: MapGrid
var rng := RandomNumberGenerator.new()
var _feet := {}                 # variant -> its collision rects, about its origin
var _placed: Array[Dictionary] = []    # {kind, name, at, flip, rects}
var _trail_dist := {}           # cell -> cells to the nearest road cell
var _up_dist := {}              # cell -> cells north to where its level ends
var _shore_dist := {}           # cell -> cells to the nearest shore
var _bushes: Array = []         # {at, v, flip}
var _fences: Array = []         # the barricades' gates, for their rocks


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
	_fences = world.barricades.list
	_measure_feet()
	_measure_trail()
	_measure_levels()

	var forest := _noise(seed, 0.0045)
	var stone := _noise(seed + 7, 0.008)
	var grove := _noise(seed + 13, 0.003)
	# Small copses between the big woods: a finer noise, only its peaks.
	var copse := _noise(seed + 29, 0.03)

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
		var woods := 0.22 + 0.5 * float(mix.tree)
		var rocky := 0.07 + 0.3 * (float(mix.rock) - float(mix.stump))
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
		# Woods frame the ground: they grow along the backs of each level --
		# its north edge, the far side from the cliff you see -- and thin out
		# toward its front, where the road and the view are.
		var back := 1.0 - clampf(float(_up_dist.get(cell, 6)) / 6.0, 0.0, 1.0)
		# Hard-edged woods: in a grove it is thick, outside it there is none --
		# a clean line between wood and meadow reads; a sprinkle does not.
		var p_tree := smoothstep(woods - 0.015, woods + 0.02, n) * open * lerpf(0.55, 1.0, back)
		var cp := (copse.get_noise_2dv(p) + 1.0) * 0.5
		p_tree = maxf(p_tree, smoothstep(0.7, 0.75, cp) * open * 0.9)
		# The high ground is dressed too, whatever the woods noise says there:
		# pine copses on every plateau and on the summit, as the banner's
		# heights have them.
		if int(grid.height.get(cell, 0)) >= 2:
			p_tree = maxf(p_tree, smoothstep(0.52, 0.6, cp) * open)
		# Rocks only in their outcrops, never one on its own in a field.
		var p_rock := smoothstep(rocky - 0.01, rocky + 0.02, s) * 0.3 \
			* smoothstep(20.0, 50.0, road) * smoothstep(12.0, 50.0, station)
		# ...and rocks gather by the sea and up on the summit.
		if int(_shore_dist.get(cell, 99)) <= 2:
			p_rock *= 2.0
		if int(grid.height.get(cell, 0)) >= 2:
			p_rock = maxf(p_rock * 1.5, 0.02 * open)
		# Stumps only just outside a wood's edge: felled trees, not litter.
		var edge := clampf(1.0 - absf(n - (woods - 0.03)) / 0.015, 0.0, 1.0)
		var p_stump := 0.12 * edge * open * clampf(w_stump / 0.15, 0.3, 1.5)
		var roll := rng.randf()
		var kind := ""
		var name := ""
		if roll < p_tree:
			kind = "tree"
			# The species follows the grass, as in the banner: leafy yellow and
			# autumn trees on the light ground, pines on the dark high ground,
			# the terrace between mixing both. Groves keep to one kind, with a
			# stranger now and then.
			var g := (grove.get_noise_2dv(p) + 1.0) * 0.5
			var kinds: Array = SPECIES[mini(int(grid.height.get(cell, 0)), SPECIES.size() - 1)]
			name = kinds[clampi(int(g * kinds.size()), 0, kinds.size() - 1)]
			if rng.randf() < 0.12:
				name = TREES[rng.randi_range(0, 3)]
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

	_plant_bushes()
	var counts := {"bush": _bushes.size()}
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


## Sea cells one to four tiles off land and away from the road, picked in a
## random order, each a good stretch from the last.
func _water_rock_spots() -> Array[Vector2]:
	var shore := {}                    # sea cell -> tiles from the nearest land
	var queue: Array[Vector2i] = []
	# The sea cliffs are drawn over the water, so they count as land here.
	for c: Vector2i in grid.land.merged(grid.cliff):
		shore[c] = 0
		queue.append(c)
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		if int(shore[c]) >= WATER_ROCK_OFFSHORE.y:
			continue
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if shore.has(n) or not MapGrid.in_bounds(n):
				continue
			shore[n] = int(shore[c]) + 1
			queue.append(n)
	var spots: Array[Vector2i] = []
	for c: Vector2i in shore:
		var far := int(shore[c])
		if far < WATER_ROCK_OFFSHORE.x or far > WATER_ROCK_OFFSHORE.y:
			continue
		var near_road := false
		for t: Vector2i in grid.trail:
			if absi(t.x - c.x) <= WATER_ROCK_BRIDGE and absi(t.y - c.y) <= WATER_ROCK_BRIDGE:
				near_road = true
				break
		if not near_road and not _near_fence(c):
			spots.append(c)
	spots.sort()                       # a set order before the seeded shuffle
	for i in range(spots.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := spots[i]
		spots[i] = spots[j]
		spots[j] = t
	var out: Array[Vector2] = []
	var taken: Array[Vector2i] = []
	for c in spots:
		if out.size() >= WATER_ROCKS:
			break
		var clear := true
		for o in taken:
			if absi(o.x - c.x) + absi(o.y - c.y) < WATER_ROCK_APART * 2 \
					and Vector2(o).distance_to(Vector2(c)) < WATER_ROCK_APART:
				clear = false
				break
		if clear:
			taken.append(c)
			out.append(MapGrid.cell_mid(c) + Vector2(rng.randf_range(-8, 8), rng.randf_range(-8, 8)))
	return out


func _near_fence(c: Vector2i) -> bool:
	var p := MapGrid.cell_mid(c)
	for g: Dictionary in _fences:
		for r: Rect2 in g.rocks:
			if r.get_center().distance_to(p) < WATER_ROCK_FENCE * MapCfg.TILE:
				return true
	return false


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
	# The high ground's narrow terraces keep a tighter clearing, or none of
	# them would have a tree.
	if int(grid.height.get(MapGrid.cell_at(p), 0)) >= 2:
		return smoothstep(20.0, 44.0, road) * smoothstep(20.0, 64.0, _keep_dist(p))
	return smoothstep(28.0, 70.0, road) * smoothstep(20.0, 64.0, _keep_dist(p))


## Levels: nothing on a cliff or a stair, or within a cell of one (the way
## up stays open), and a prop's whole footprint and a cell round it on one
## level -- so nothing hangs over a terrace's edge or stands at its foot.
func _level_ok(at: Vector2, rects: Array[Rect2]) -> bool:
	var home := MapGrid.cell_at(at)
	var level := int(grid.height.get(home, -1))
	var cells: Array[Vector2i] = [home]
	for r: Rect2 in rects:
		for corner in [r.position, Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), r.end]:
			cells.append(MapGrid.cell_at(corner))
	# On the high ground only the footprint itself need be on the level --
	# its plateaus are narrow, and a ring round every trunk left them bare.
	var ring := 1 if level < 2 else 0
	# ...but never on its rim: the trunk a cell in from any edge, or the
	# crown hangs out over the cliff.
	for d in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		var n: Vector2i = home + d
		if grid.cliff.has(n) or int(grid.height.get(n, -1)) != level:
			return false
	for c in cells:
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var n := c + Vector2i(dx, dy)
				if grid.stairs.has(n) or grid.cliff.has(n) and (ring > 0 or n == c):
					return false
				if absi(dx) + absi(dy) <= ring * 2 and grid.land.has(n) \
						and int(grid.height.get(n, -1)) != level:
					return false
	return true


func _measure_levels() -> void:
	for c: Vector2i in grid.land:
		var h := int(grid.height.get(c, 0))
		var n := 0
		while n < 6 and int(grid.height.get(c + Vector2i(0, -(n + 1)), -1)) == h:
			n += 1
		_up_dist[c] = n
	var queue: Array[Vector2i] = []
	for c: Vector2i in grid.beach:
		_shore_dist[c] = 0
		queue.append(c)
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb: Vector2i = c + d
			if _shore_dist.has(nb) or not grid.land.has(nb):
				continue
			_shore_dist[nb] = int(_shore_dist[c]) + 1
			queue.append(nb)


## Bushes on the ground level only, where the banner has them: at the foot
## of a cliff (a clear cell below it), beside the foot of a stair, and on the
## edges of the woods. Their whole sprite stands over flat ground -- never on
## raised ground or across a cliff face. No collision: low enough to walk
## through, but never on the road, and never in a yard.
func _plant_bushes() -> void:
	var spots: Array[Array] = []                      # [point, chance]
	for k: Vector2i in grid.cliff:
		if grid.land.has(k + Vector2i(0, 2)):
			spots.append([MapGrid.cell_mid(k + Vector2i(0, 2)) + Vector2(rng.randf_range(-8, 8), 6),
				BUSH_AT_CLIFF])
	for c: Vector2i in grid.stairs:
		var st: Dictionary = grid.stairs[c]
		if bool(st.top):
			continue
		var out := c + Vector2i(int(st.side) * 2, 1)
		spots.append([MapGrid.cell_mid(out) + Vector2(0, 6), BUSH_AT_STAIRS])
	# Clumps of two or three out in the open, and the odd one by the road.
	var ground: Array[Vector2i] = []
	for c: Vector2i in grid.land:
		if int(grid.height.get(c, -1)) == 0 and not grid.trail.has(c):
			ground.append(c)
	ground.sort()
	for _k in BUSH_CLUMPS:
		if ground.is_empty():
			break
		var at := MapGrid.cell_mid(ground[rng.randi_range(0, ground.size() - 1)])
		for _n in rng.randi_range(2, 3):
			spots.append([at + Vector2(rng.randf_range(-22, 22), rng.randf_range(-10, 10)), 1.0])
	for c: Vector2i in grid.trail:
		if int(grid.height.get(c, -1)) == 0 and rng.randf() < BUSH_AT_ROAD:
			for d in [Vector2i(0, 2), Vector2i(0, -2), Vector2i(2, 0), Vector2i(-2, 0)]:
				if not grid.trail.has(c + d):
					spots.append([MapGrid.cell_mid(c + d) + Vector2(0, 8), 1.0])
					break
	for d: Dictionary in _placed:
		if d.kind == "tree" and rng.randf() < BUSH_AT_WOODS:
			spots.append([(d.at as Vector2) + Vector2(rng.randf_range(-24, 24), rng.randf_range(10, 22)), 1.0])
	spots.sort_custom(func(a: Array, b: Array) -> bool:
		return (a[0] as Vector2).y < (b[0] as Vector2).y or \
			((a[0] as Vector2).y == (b[0] as Vector2).y and (a[0] as Vector2).x < (b[0] as Vector2).x))
	var h := 128.0 * BUSH_SCALE
	for spot: Array in spots:
		var at: Vector2 = spot[0]
		if rng.randf() > float(spot[1]):
			continue
		var art := Rect2(at - Vector2(h * 0.5, h * 0.7), Vector2(h, h * 0.7))
		var flat := true
		for corner in [art.position, Vector2(art.end.x, art.position.y),
				Vector2(art.position.x, art.end.y), art.end]:
			var k := MapGrid.cell_at(corner)
			if not grid.land.has(k) or grid.cliff.has(k) or grid.stairs.has(k) \
					or int(grid.height.get(k, -1)) != 0 or grid.trail.has(k):
				flat = false
		if not flat or not grid.clear_of_buildings(art):
			continue
		var near := false
		for d: Dictionary in _placed:
			if (d.at as Vector2).distance_to(at) < 16.0:
				near = true
				break
		for b: Dictionary in _bushes:
			if (b.at as Vector2).distance_to(at) < 12.0:
				near = true
				break
		if near:
			continue
		_bushes.append({"at": at.round(), "v": rng.randi_range(1, 4), "flip": -1.0 if rng.randf() < 0.5 else 1.0})


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
	if not _level_ok(at, rects):
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
	for at in _water_rock_spots():
		var rock := Art.anim_sprite(sea, WATER_ROCK % rng.randi_range(1, 4), at,
			WATER_ROCK_SCALE * rng.randf_range(0.8, 1.1), WATER_ROCK_FPS,
			-1.0 if rng.randf() < 0.5 else 1.0, 16)
		rock.name = "WaterRock"
		rock.autoplay = rock.animation
		# Each one on its own beat, or the whole sea breathes in step.
		rock.frame = rng.randi_range(0, 15)
		rock.owner = root

	var shrubs := Node2D.new()
	shrubs.name = "Bushes"
	shrubs.y_sort_enabled = true
	root.add_child(shrubs)
	shrubs.owner = root
	for b: Dictionary in _bushes:
		var bush := Art.anim_sprite(shrubs, BUSH % int(b.v), b.at, BUSH_SCALE, BUSH_FPS,
			float(b.flip), 8)
		Art.sit_on_art(bush)
		bush.name = "Bush"
		bush.autoplay = bush.animation
		bush.frame = rng.randi_range(0, 7)
		bush.owner = root

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

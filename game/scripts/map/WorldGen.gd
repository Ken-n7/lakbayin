class_name WorldGen
extends RefCounted

## A Lakbayin match's world from one seed (DESIGN.md 5.1). Pure data -- cells,
## points and lists, no nodes -- so it is quick, testable headless, and the
## same on every phone that builds it from the session's seed. `MapWorld`
## draws it.
##
## Mirrored left to right, as competitive maps are: Blue spawns on the left,
## Red at the mirror spot on the right, the monks come in mirrored pairs, and
## the Monastery stands on the centre line -- the same walk from either spawn
## by construction, not by measurement. Where on that line is the seed's.
##
## Everything a player must reach stands on the one big island and is joined
## to both spawns by clearings (`trail`) that no prop may stand on, so nothing
## is ever walled off. Land the noise leaves apart stays as islets: dressed,
## never used.

const W := MapCfg.WORLD_W
const H := MapCfg.WORLD_H
const T := MapCfg.TILE
const HALF := W / 2               # the left half is x < HALF; x mirrors to W - 1 - x
const BORDER := 2                 # open sea round the world's edge, cells

## The land: an oval falling off toward the edges, its coast broken by noise.
const COAST_FREQ := 0.075
const COAST_AMP := 0.5
const LAND_LEVEL := 0.3
const CLEAN_PASSES := 4
## Ground forced round each spawn and the centre, cells, so neither is ever sea.
const SPAWN_GROUND := 6
const CENTRE_GROUND := 6
## Islets smaller than this, in cells, are dropped.
const MIN_ISLET := 16

## Where each team starts, as a share of the world (Blue; Red mirrors it).
const SPAWN_AT := Vector2(0.16, 0.5)
const SPAWN_YARD := 2             # cells round a spawn kept clear

## The Monastery's footprint in cells, centred on the axis, and the rows kept
## clear in front of its door.
const MONASTERY_CELLS := Vector2i(4, 5)
const DOOR_YARD := 2
const DOOR_DROP := 14.0           # px below the base: where a player stands to deposit

## Monks: the least distance between two, and from a spawn and from the door,
## in cells. Relaxed step by step if a world cannot fit them all.
const MONK_GAP := 7
const MONK_FROM_SPAWN := 7
const MONK_FROM_DOOR := 6

## Props: how dense, and how far apart (origin to origin, px), by kind.
const TREES := ["Tree1", "Tree2", "Tree3", "Tree4"]
const STUMPS := ["Stump1", "Stump2", "Stump3", "Stump4"]
const ROCKS := ["Rock1", "Rock2", "Rock3", "Rock4"]
const SPACING := {"tree": 22.0, "stump": 22.0, "rock": 30.0}
const WOODS_FREQ := 0.07
const WOODS_LEVEL := 0.58
const STONE_FREQ := 0.13
const STONE_LEVEL := 0.7
const BUSHES := 40                # per half
const WATER_ROCKS := 8            # per half

## Houses round each spawn: where each one's bottom-left cell goes, from the
## spawn, tried in order -- behind it first (toward the world's edge), then
## above and below, then ahead.
const HOUSE_SPOTS := [Vector2i(-4, -1), Vector2i(-4, 3), Vector2i(-1, -3), Vector2i(-1, 5),
	Vector2i(2, -3), Vector2i(2, 5), Vector2i(-6, 1), Vector2i(3, 1)]
const HOUSES := 2
const HOUSE_CELLS := Vector2i(2, 3)

var seed := 0
var monk_count := 10

## Outputs. Cells are Vector2i; points are world px.
var land := {}                    # every land cell
var main := {}                    # the island everything stands on
var islet_of := {}                # cell -> 0 the main island, 1.. each islet
var trail := {}                   # cells no prop may stand on
var spawns: Array[Vector2] = []   # [Blue, Red], where a hero starts
var monastery := Vector2.ZERO     # the building's base, on the axis
var door := Vector2.ZERO          # where a player stands to deposit
var monks: Array[Vector2] = []    # monk i and its twin i + n/2 mirror each other
var houses: Array = []            # [{at, team, variant}], `at` the building's base
var props: Array = []             # [{name, kind, at, flip}]
var bushes: Array = []            # [{at, v, flip}]
var water_rocks: Array = []       # [{at, v, flip}]

var _rng := RandomNumberGenerator.new()
var _blocked := {}                # cells a building stands on
static var _feet := {}            # prop name -> its collision rects about its origin


static func mirror_cell(c: Vector2i) -> Vector2i:
	return Vector2i(W - 1 - c.x, c.y)


static func mirror(p: Vector2) -> Vector2:
	return Vector2(W * T - p.x, p.y)


func generate() -> void:
	_rng.seed = seed
	_make_land()
	_place_spawns()
	_place_monastery()
	_place_monks()
	_place_houses()
	_carve_trails()
	_scatter_props()
	_scatter_bushes()
	_scatter_water_rocks()


# --- Land -------------------------------------------------------------------
func _make_land() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = COAST_FREQ
	noise.fractal_octaves = 3
	var centre := Vector2(W * 0.5, H * 0.5)
	for y in range(BORDER, H - BORDER):
		for x in range(BORDER, HALF):
			var d := Vector2((x + 0.5 - centre.x) / (centre.x - BORDER),
					(y + 0.5 - centre.y) / (centre.y - BORDER)).length()
			if 1.0 - d + noise.get_noise_2d(x, y) * COAST_AMP > LAND_LEVEL:
				land[Vector2i(x, y)] = true
	var spawn := _spawn_cell()
	for c in _disc(spawn, SPAWN_GROUND) + _disc(Vector2i(HALF - 1, H / 2), CENTRE_GROUND):
		if c.x < HALF and _inside(c):
			land[c] = true
	_mirror_land()
	for _i in CLEAN_PASSES:
		_clean()
	# Joined: if the noise cut the spawn off from the centre, a causeway.
	var reach := _flood(Vector2i(HALF - 1, H / 2), land)
	if not reach.has(spawn):
		for c in _line(spawn, Vector2i(HALF - 1, H / 2)):
			for d in _disc(c, 1):
				if d.x < HALF and _inside(d):
					land[d] = true
		_mirror_land()
		reach = _flood(Vector2i(HALF - 1, H / 2), land)
	main = reach
	# Islets too small to dress read as stray squares of grass: gone.
	for c: Vector2i in _cells():
		if land.has(c) and not main.has(c):
			var piece := _flood(c, land)
			if piece.size() < MIN_ISLET:
				for k: Vector2i in piece:
					land.erase(k)
	var islet := 0
	for c: Vector2i in _cells():
		if not land.has(c) or islet_of.has(c):
			continue
		var piece := main if main.has(c) else _flood(c, land)
		if not main.has(c):
			islet += 1
		for k: Vector2i in piece:
			islet_of[k] = 0 if main.has(c) else islet


## The right half is the left one, mirrored.
func _mirror_land() -> void:
	for c: Vector2i in land.keys():
		if c.x >= HALF:
			land.erase(c)
	for c: Vector2i in land.keys():
		land[mirror_cell(c)] = true


## One pass, read from the land as it was: a strip one cell wide goes, and a
## one-cell inlet fills. The rules are symmetric, so the mirror holds.
func _clean() -> void:
	var was := land.duplicate()
	for c: Vector2i in _cells():
		var l := was.has(c + Vector2i.LEFT)
		var r := was.has(c + Vector2i.RIGHT)
		var u := was.has(c + Vector2i.UP)
		var d := was.has(c + Vector2i.DOWN)
		if was.has(c):
			if (not l and not r) or (not u and not d):
				land.erase(c)
		elif _inside(c) and int(l) + int(r) + int(u) + int(d) >= 3:
			land[c] = true


# --- Places -----------------------------------------------------------------
func _spawn_cell() -> Vector2i:
	return Vector2i(int(W * SPAWN_AT.x), int(H * SPAWN_AT.y))


func _place_spawns() -> void:
	var at := _nearest_open(_spawn_cell(), SPAWN_YARD + 1)
	spawns = [MapGrid.cell_mid(at), mirror(MapGrid.cell_mid(at))]


## On the axis: the footprint straddles cells HALF-2..HALF+1. Rows where all
## of it and its yard are the main island's inland ground, chosen by the seed.
func _place_monastery() -> void:
	var fit: Array[int] = []
	for base in range(BORDER + MONASTERY_CELLS.y + 1, H - BORDER - DOOR_YARD - 2):
		var ok := true
		for y in range(base - MONASTERY_CELLS.y + 1, base + DOOR_YARD + 1):
			for x in range(HALF - 2, HALF + 2):
				if not _inland(Vector2i(x, y)):
					ok = false
		if ok:
			fit.append(base)
	var base_row: int = fit[_rng.randi_range(0, fit.size() - 1)] if not fit.is_empty() else H / 2
	monastery = Vector2(HALF * T, (base_row + 1) * T)
	door = monastery + Vector2(0, DOOR_DROP)
	for y in range(base_row - MONASTERY_CELLS.y + 1, base_row + 1):
		for x in range(HALF - 2, HALF + 2):
			_blocked[Vector2i(x, y)] = true


func _place_monks() -> void:
	var pairs := monk_count / 2
	var spawn := MapGrid.cell_at(spawns[0])
	var door_cell := MapGrid.cell_at(door)
	var spots: Array[Vector2i] = []
	for c: Vector2i in _cells():
		if c.x >= 3 and c.x < HALF - 3 and _inland(c) and not _blocked.has(c) and _room(c, 1):
			spots.append(c)
	_shuffle(spots)
	var left: Array[Vector2i] = []
	for slack in [0, 1, 2, 3, 4]:
		left.clear()
		for c in spots:
			if left.size() >= pairs:
				break
			if _dist(c, spawn) < MONK_FROM_SPAWN - slack or _dist(c, door_cell) < MONK_FROM_DOOR - slack:
				continue
			var near := false
			for o in left:
				# Its twin across the axis counts too.
				if _dist(c, o) < MONK_GAP - slack or _dist(c, mirror_cell(o)) < MONK_GAP - slack:
					near = true
			if not near and _dist(c, mirror_cell(c)) >= MONK_GAP - slack:
				left.append(c)
		if left.size() >= pairs:
			break
	monks.clear()
	for c in left:
		monks.append(MapGrid.cell_mid(c))
	for c in left:
		monks.append(mirror(MapGrid.cell_mid(c)))
	# An odd count: the odd one stands on the axis, below or above the Monastery.
	if monk_count % 2 == 1:
		for dy in [4, -8, 7, -11, 10]:
			var c := door_cell + Vector2i(0, dy)
			if _inland(c) and _inland(c + Vector2i.LEFT):
				monks.append(Vector2(HALF * T, c.y * T + T * 0.5))
				break


## Blue's houses beside its spawn, Red's mirrored: off the yard, on inland
## ground, clear of every other building.
func _place_houses() -> void:
	var spawn := MapGrid.cell_at(spawns[0])
	var placed := 0
	for spot: Vector2i in HOUSE_SPOTS:
		if placed >= HOUSES:
			break
		var base := spawn + spot
		var cells := _footprint(base, HOUSE_CELLS)
		var ok := true
		for c in cells:
			if not _inland(c) or _blocked.has(c) or _dist(c, spawn) <= SPAWN_YARD or _near_monk(c):
				ok = false
		if not ok:
			continue
		for c in cells:
			_blocked[c] = true
			_blocked[mirror_cell(c)] = true
		var at := Vector2(base.x * T + T, (base.y + 1) * T)
		var variant := _rng.randi_range(1, 3)
		houses.append({"at": at, "team": 0, "variant": variant})
		houses.append({"at": mirror(at), "team": 1, "variant": variant})
		placed += 1


## Clearings from Blue's spawn to the door and to each monk on its side, three
## cells wide, then mirrored. Blue reaches Red's side through the door's
## clearing and Red's own; nothing stands on any of them.
func _carve_trails() -> void:
	var walk := {}
	for c: Vector2i in main:
		if not _blocked.has(c):
			walk[c] = true
	var spawn := MapGrid.cell_at(spawns[0])
	var targets: Array[Vector2i] = [MapGrid.cell_at(door)]
	for i in monk_count / 2:
		targets.append(MapGrid.cell_at(monks[i]))
	for t in targets:
		for c in _path(spawn, t, walk):
			for d in _disc(c, 1):
				if main.has(d) and not _blocked.has(d):
					trail[d] = true
	for c in _disc(spawn, SPAWN_YARD):
		trail[c] = true
	var door_cell := MapGrid.cell_at(door)
	for y in range(door_cell.y - 1, door_cell.y + DOOR_YARD):
		for x in range(HALF - 3, HALF + 3):
			trail[Vector2i(x, y)] = true
	for m in monks:
		for c in _disc(MapGrid.cell_at(m), 1):
			trail[c] = true
	for c: Vector2i in trail.keys():
		trail[mirror_cell(c)] = true


# --- Dressing ---------------------------------------------------------------
## Woods from one noise and outcrops from another, as the hand-dressed board
## had them: thick in the woods, none outside, rocks in clusters, stumps on a
## wood's edge. Left half only, then mirrored, so neither side has more cover.
func _scatter_props() -> void:
	_measure_feet()
	var woods := _noise(seed + 1, WOODS_FREQ)
	var stone := _noise(seed + 2, STONE_FREQ)
	var grove := _noise(seed + 3, 0.05)
	var placed: Array = []
	var hash := {}                       # cell -> indexes into `placed` near it
	for c: Vector2i in _cells():
		if c.x >= HALF or not land.has(c) or trail.has(c) or _blocked.has(c) or not _inland(c):
			continue
		var p := MapGrid.cell_mid(c) + Vector2(_rng.randf_range(-12, 12), _rng.randf_range(-12, 12))
		var n := (woods.get_noise_2d(c.x, c.y) + 1.0) * 0.5
		var s := (stone.get_noise_2d(c.x, c.y) + 1.0) * 0.5
		var p_tree := smoothstep(WOODS_LEVEL - 0.02, WOODS_LEVEL + 0.03, n) * 0.85
		var p_rock := smoothstep(STONE_LEVEL - 0.01, STONE_LEVEL + 0.03, s) * 0.35
		var p_stump := 0.12 * clampf(1.0 - absf(n - (WOODS_LEVEL - 0.04)) / 0.025, 0.0, 1.0)
		var roll := _rng.randf()
		var kind := ""
		var name := ""
		if roll < p_tree:
			kind = "tree"
			var g := (grove.get_noise_2d(c.x, c.y) + 1.0) * 0.5
			name = TREES[clampi(int(g * 4.0), 0, 3)]
		elif roll < p_tree + p_rock:
			kind = "rock"
			name = ROCKS[_rng.randi_range(0, 3)]
		elif roll < p_tree + p_rock + p_stump:
			kind = "stump"
			name = STUMPS[_rng.randi_range(0, 3)]
		else:
			continue
		var flip := -1.0 if kind == "tree" and _rng.randf() < 0.3 else 1.0
		var rects := _rects_at(name, p, flip)
		if _fits(kind, p, rects, placed, hash):
			var d := {"name": name, "kind": kind, "at": p.round(), "flip": flip, "rects": rects}
			hash[c] = (hash.get(c, []) as Array) + [placed.size()]
			placed.append(d)
	props.clear()
	for d: Dictionary in placed:
		props.append({"name": d.name, "kind": d.kind, "at": d.at, "flip": d.flip})
	for d: Dictionary in placed:
		props.append({"name": d.name, "kind": d.kind, "at": mirror(d.at), "flip": -float(d.flip)})


## Its boxes on inland ground that is not a clearing, in the left half with room
## to spare at the axis (its mirror must not meet it), and clear of the props
## near it.
func _fits(kind: String, at: Vector2, rects: Array[Rect2], placed: Array, hash: Dictionary) -> bool:
	for r in rects:
		if r.end.x > HALF * T - 6.0:
			return false
		for corner in [r.position, Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), r.end]:
			var c := MapGrid.cell_at(corner)
			if not _inland(c) or trail.has(c) or _blocked.has(c):
				return false
	var home := MapGrid.cell_at(at)
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			for i: int in hash.get(home + Vector2i(dx, dy), []):
				var o: Dictionary = placed[i]
				if (o.at as Vector2).distance_to(at) < maxf(SPACING[kind], SPACING[o.kind]):
					return false
				for a in rects:
					for b: Rect2 in o.rects:
						if a.grow(1.0).intersects(b):
							return false
	return true


func _scatter_bushes() -> void:
	var spots: Array[Vector2i] = []
	for c: Vector2i in _cells():
		if c.x < HALF - 1 and _inland(c) and not _blocked.has(c) and not _near_monk(c):
			spots.append(c)
	_shuffle(spots)
	for i in mini(BUSHES, spots.size()):
		var at := MapGrid.cell_mid(spots[i]) + Vector2(_rng.randf_range(-10, 10), _rng.randf_range(-8, 8))
		var b := {"at": at.round(), "v": _rng.randi_range(1, 4), "flip": -1.0 if _rng.randf() < 0.5 else 1.0}
		bushes.append(b)
		bushes.append({"at": mirror(b.at), "v": b.v, "flip": -float(b.flip)})


## Rocks in the sea, a few cells off the coast and apart from each other.
func _scatter_water_rocks() -> void:
	var spots: Array[Vector2i] = []
	for c: Vector2i in _cells():
		if c.x >= HALF - 2 or land.has(c):
			continue
		var near := false
		var touch := false
		for d in _disc(c, 3):
			if land.has(d):
				near = true
		for d in _disc(c, 1):
			if land.has(d):
				touch = true
		if near and not touch:
			spots.append(c)
	_shuffle(spots)
	var kept: Array[Vector2i] = []
	for c in spots:
		if kept.size() >= WATER_ROCKS:
			break
		var apart := true
		for k in kept:
			if _dist(c, k) < 6:
				apart = false
		if apart:
			kept.append(c)
	for c in kept:
		var r := {"at": MapGrid.cell_mid(c), "v": _rng.randi_range(1, 4), "flip": -1.0 if _rng.randf() < 0.5 else 1.0}
		water_rocks.append(r)
		water_rocks.append({"at": mirror(r.at), "v": r.v, "flip": -float(r.flip)})


# --- Helpers ----------------------------------------------------------------
## Every cell, row by row: the one order anything is ever walked in, so the
## same seed gives the same world.
func _cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in H:
		for x in W:
			out.append(Vector2i(x, y))
	return out


func _inside(c: Vector2i) -> bool:
	return c.x >= BORDER and c.y >= BORDER and c.x < W - BORDER and c.y < H - BORDER


## Main-island ground with land all round it: not shore.
func _inland(c: Vector2i) -> bool:
	if not main.has(c):
		return false
	for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		if not land.has(c + d):
			return false
	return true


## Inland ground for `r` cells round `c`.
func _room(c: Vector2i, r: int) -> bool:
	for d in _disc(c, r):
		if not _inland(d):
			return false
	return true


func _near_monk(c: Vector2i) -> bool:
	for m in monks:
		if _dist(c, MapGrid.cell_at(m)) <= 1:
			return true
	return false


## The main-island cell nearest `c` with `r` cells of inland ground round it.
func _nearest_open(c: Vector2i, r: int) -> Vector2i:
	for k in MapGrid.rings(c, 20):
		if k.x < HALF and _room(k, r):
			return k
	return c


func _footprint(base: Vector2i, size: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(base.y - size.y + 1, base.y + 1):
		for x in range(base.x, base.x + size.x):
			out.append(Vector2i(x, y))
	return out


static func _dist(a: Vector2i, b: Vector2i) -> float:
	return Vector2(a).distance_to(Vector2(b))


static func _disc(c: Vector2i, r: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy <= r * r:
				out.append(c + Vector2i(dx, dy))
	return out


static func _line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var n := maxi(absi(b.x - a.x), absi(b.y - a.y))
	for i in n + 1:
		out.append(Vector2i(Vector2(a).lerp(Vector2(b), float(i) / maxf(n, 1)).round()))
	return out


static func _flood(from: Vector2i, cells: Dictionary) -> Dictionary:
	var seen := {}
	if not cells.has(from):
		return seen
	seen[from] = true
	var queue: Array[Vector2i] = [from]
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var n: Vector2i = c + d
			if cells.has(n) and not seen.has(n):
				seen[n] = true
				queue.append(n)
	return seen


## The shortest four-way path from `a` to `b` over `cells`, both ends included;
## empty if there is none.
static func _path(a: Vector2i, b: Vector2i, cells: Dictionary) -> Array[Vector2i]:
	var from := {a: a}
	var queue: Array[Vector2i] = [a]
	var head := 0
	while head < queue.size() and not from.has(b):
		var c := queue[head]
		head += 1
		for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var n: Vector2i = c + d
			if cells.has(n) and not from.has(n):
				from[n] = c
				queue.append(n)
	var out: Array[Vector2i] = []
	if not from.has(b):
		return out
	var k := b
	while k != a:
		out.append(k)
		k = from[k]
	out.append(a)
	return out


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t


static func _noise(s: int, freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = s
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_octaves = 3
	return n


## Each prop's collision boxes, read off its scene once: the sizes set in the
## editor, not a guess.
static func _measure_feet() -> void:
	if not _feet.is_empty():
		return
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


static func _rects_at(name: String, at: Vector2, flip: float) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for r: Rect2 in _feet[name]:
		var x := r.position.x if flip > 0.0 else -r.end.x
		out.append(Rect2(at + Vector2(x, r.position.y), r.size))
	return out

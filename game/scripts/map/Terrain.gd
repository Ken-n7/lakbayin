class_name Terrain
extends RefCounted

## The ground: islands, their levels, the cliffs and stairs between, the road,
## and every stop on the walk. Generated from `MapCfg.MAP_SEED` by fixed rules,
## so every phone builds the same board; a seed whose layout breaks a rule is
## skipped for the next -- the rules are the design, the seed the variation.
##
## The design, after the Tiny Swords banner, the pack's tilemap guide and the
## usual level-design principles (SPECS "Map redesign"):
##  * **Chokepoints.** Each station stands in a pocket of ground where its
##    bridge lands, walled in by cliffs and the sea; one stair leads out of it,
##    and the station's knight stands on that stair until the briefing.
##  * **Landmarks.** The station is the first thing you meet on an island; the
##    Victory Gate crowns the highest ground on the board.
##  * **Vertical progression.** Islands are stacked: ground (0) at the pockets
##    and round the coast, a terrace (1) over the rest, plateaus (2) where the
##    ground rises inland, and on the last island a summit (3). Circles sit up
##    on the heights, so the walk climbs.
##  * **Loops, not corridors.** Past the knight, every level has stairs on
##    more than one side.
##  * **Natural shapes.** Coasts, rims and plateaus come from noise -- bays,
##    points and coves, plateaus of every shape -- then cleaned so the tiles
##    can draw them. Messy, but never broken.
##
## Stairs are the pack's two-cell ramps, which fit one way only: beside a
## convex south corner of the higher ground, the ramp's top level with the
## corner and its foot beside the cliff below it. So stairs are found, not
## drawn: every corner the shapes happen to make is a candidate.

const SLOPE_LEFT := [Vector2i(0, 4), Vector2i(0, 5)]     # higher ground to its right
const SLOPE_RIGHT := [Vector2i(3, 4), Vector2i(3, 5)]    # higher ground to its left
const CLIFF_ROW := 4                                      # cliff over land
const CLIFF_SEA_ROW := 5                                  # cliff with its foot in the sea
const D4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const UP := Vector2i(0, -1)
const DOWN := Vector2i(0, 1)

var grid: MapGrid
## The walk, in the order the game indexes it (MapGrid.anchors).
var anchors: Array = []
## Anchor index -> where its building stands relative to it.
var lifts := {}
## Per station, the stair its knight holds: {top, foot, side}.
var guard_stairs: Array = []
## The seed that built this board (MAP_SEED, or the first after it that held).
var seed_used := 0

var _rng := RandomNumberGenerator.new()
var _why := ""
var _used := {}                 # (cell, low level) a stair or its margin takes


func _init(g: MapGrid) -> void:
	grid = g


# --- Generate ---------------------------------------------------------------
func generate() -> void:
	for attempt in MapCfg.TERRAIN_TRIES:
		_reset()
		seed_used = MapCfg.MAP_SEED + attempt
		_rng.seed = seed_used
		_why = ""
		if _try():
			return
		print("terrain: seed %d skipped -- %s" % [seed_used, _why])
	push_error("terrain: no seed from %d held -- %s" % [MapCfg.MAP_SEED, _why])


func _reset() -> void:
	for d: Dictionary in [grid.land, grid.island_of, grid.trail, grid.height, grid.cliff,
			grid.stairs, grid.beach]:
		d.clear()
	grid.solid.clear()
	anchors = []
	lifts = {}
	guard_stairs = []
	_used = {}


func _fail(why: String) -> bool:
	_why = why
	return false


func _try() -> bool:
	_noise_land = _noise(seed_used, MapCfg.COAST_FREQ)
	_noise_rim = _noise(seed_used + 11, MapCfg.RIM_FREQ)
	_noise_high = _noise(seed_used + 23, MapCfg.PLATEAU_FREQ)
	_blob(MapCfg.CAMP_REGION, 0, [_landing(MapCfg.BRIDGES[0].cells, MapCfg.CAMP_REGION)])
	var parts: Array = []
	for i in MapCfg.DISTRICTS.size():
		parts.append(_district(i))
	for b: Dictionary in MapCfg.BRIDGES:
		_add_rect(b.cells, int(b.to))
	_islets()
	_coast = _distance(func(c: Vector2i) -> bool: return not grid.land.has(c))
	for i in parts.size():
		if not _levels(i, parts[i]):
			return false
	_lay_cliffs()
	for i in parts.size():
		if not _stairs(i, parts[i]):
			return false
	_lay_cliffs()
	if not _place_stops(parts):
		return false
	return _validate()


var _noise_land: FastNoiseLite
var _noise_rim: FastNoiseLite
var _noise_high: FastNoiseLite
var _coast := {}                # land cell -> steps to the nearest water
var _last_carve: Array = []


func _noise(s: int, freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = s
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_octaves = 3
	return n


# --- Land -------------------------------------------------------------------
func _add_rect(r: Rect2i, isl: int) -> void:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var c := Vector2i(x, y)
			grid.land[c] = true
			grid.island_of[c] = isl
			grid.height[c] = 0


## An organic landmass in `r`: a rounded-rectangle falloff broken up by noise
## into bays, points and coves, cleaned so the tiles can draw it -- one piece,
## no holes, nothing a cell wide. `keep` points always stay land (where the
## bridges land). Returns its cells.
func _blob(r: Rect2i, isl: int, keep: Array) -> Dictionary:
	var cells := {}
	var mid := Vector2(r.position) + Vector2(r.size) * 0.5
	var half := Vector2(r.size) * 0.5
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var nx := absf((x + 0.5 - mid.x) / half.x)
			var ny := absf((y + 0.5 - mid.y) / half.y)
			var fall := 1.0 - pow(pow(nx, 4.0) + pow(ny, 4.0), 0.25)
			if fall + _noise_land.get_noise_2d(x, y) * MapCfg.COAST_AMP > MapCfg.COAST_LEVEL:
				cells[Vector2i(x, y)] = true
	# Where a bridge lands the coast reaches out to meet it: a neck of land
	# from the landing inward until it joins the island.
	for k: Vector2i in keep:
		var at := Vector2(k)
		var toward := (mid - at).normalized()
		for _step in 80:
			var here := Vector2i(at.round())
			var joined := cells.has(here) and Vector2(here - k).length() > 4.0
			for dy in range(-3, 4):
				for dx in range(-3, 4):
					if r.has_point(here + Vector2i(dx, dy)) and Vector2(dx, dy).length() <= 3.2:
						cells[here + Vector2i(dx, dy)] = true
			if joined:
				break
			at += toward
	cells = _smooth(cells)
	cells = _largest(cells, keep)
	_fill_holes(cells, r)
	_thicken(cells)
	for c: Vector2i in cells:
		grid.land[c] = true
		grid.island_of[c] = isl
		grid.height[c] = 0
	return cells


## A district's island, and where its bridges land.
func _district(i: int) -> Dictionary:
	var d: Dictionary = MapCfg.DISTRICTS[i]
	var r: Rect2i = d.region
	var arrive := _landing(MapCfg.BRIDGES[int(d.arrive)].cells, r)
	var leave := Vector2i(-1, -1)
	var keep: Array = [arrive]
	if int(d.exit) >= 0:
		leave = _landing(MapCfg.BRIDGES[int(d.exit)].cells, r)
		keep.append(leave)
	var land := _blob(r, i + 1, keep)
	return {"land": land, "arrive_at": arrive, "leave_at": leave}


## The district cell a bridge touches: its cell in `r` beside the bridge.
static func _landing(bridge: Rect2i, r: Rect2i) -> Vector2i:
	for y in range(bridge.position.y, bridge.end.y):
		for x in range(bridge.position.x, bridge.end.x):
			for d in D4:
				var c: Vector2i = Vector2i(x, y) + d
				if r.has_point(c) and not bridge.has_point(c):
					# The middle of the bridge's edge, not its corner.
					var mid := Vector2i(bridge.position.x + bridge.size.x / 2,
						bridge.position.y + bridge.size.y / 2)
					if bridge.size.x > bridge.size.y:
						return Vector2i(c.x, mid.y)
					return Vector2i(mid.x, c.y)
	return r.get_center()


## Little islands off the coasts: ground to dress, not to walk to.
func _islets() -> void:
	var placed := 0
	var tries := 0
	while placed < MapCfg.ISLETS and tries < 400:
		tries += 1
		var w := _rng.randi_range(3, 6)
		var h := _rng.randi_range(3, 5)
		var at := Vector2i(_rng.randi_range(1, MapCfg.WORLD_W - w - 2),
			_rng.randi_range(1, MapCfg.WORLD_H - h - 2))
		var clear := true
		for y in range(at.y - 3, at.y + h + 3):
			for x in range(at.x - 3, at.x + w + 3):
				if grid.land.has(Vector2i(x, y)):
					clear = false
		if clear and not _blob(Rect2i(at, Vector2i(w, h)), 0, []).is_empty():
			placed += 1


## Steps from each land cell to the nearest cell `from` holds.
func _distance(from: Callable) -> Dictionary:
	var dist := {}
	var queue: Array[Vector2i] = []
	for c: Vector2i in grid.land:
		for d in D4:
			if from.call(c + d):
				dist[c] = 1
				queue.append(c)
				break
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		for d in D4:
			var n: Vector2i = c + d
			if grid.land.has(n) and not dist.has(n):
				dist[n] = int(dist[c]) + 1
				queue.append(n)
	return dist


# --- Levels -----------------------------------------------------------------
## The station's **pocket** -- ground round where the bridge lands, walled in
## by the terrace's cliffs and the sea -- and the exit's; a rim of ground of
## varying width round the rest of the coast (none at all near a pocket, so a
## pocket is never walked out of at ground level); the terrace over everything
## else; plateaus where the noise rises well inland; and on the summit island
## a summit on its biggest plateau.
func _levels(i: int, part: Dictionary) -> bool:
	var d: Dictionary = MapCfg.DISTRICTS[i]
	var land: Dictionary = part.land
	var pocket := _pocket(land, _inland(part.arrive_at, d.region), MapCfg.POCKET_R)
	var out := {}
	if part.leave_at.x >= 0:
		out = _pocket(land, _inland(part.leave_at, d.region), MapCfg.EXIT_POCKET_R)
	var near_pocket := _grow(pocket.merged(out), MapCfg.POCKET_MOAT)
	var terrace := {}
	for c: Vector2i in land:
		if pocket.has(c) or out.has(c):
			continue
		var rim := 0 if near_pocket.has(c) else clampi(
			int(floor((_noise_rim.get_noise_2d(c.x, c.y) + 1.0) * 0.5 * 5.0)) - 1, 0, 3)
		if int(_coast.get(c, 99)) > rim:
			terrace[c] = true
	_thicken(terrace)
	# Each pocket's way up: the ramp needs a south corner of terrace beside
	# it, so one is cut into the terrace's edge where the pocket meets it.
	if not _carve_stair(terrace, pocket, part.arrive_at):
		return _fail("district %d's pocket has no edge to cut a stair into" % (i + 1))
	if not out.is_empty() and not _carve_stair(terrace, out, part.leave_at):
		return _fail("district %d's exit has no edge to cut a stair into" % (i + 1))
	# Plateaus: the noise, lifted toward the summit island's peak.
	var peak := Vector2(-999, -999)
	if bool(d.get("summit", false)):
		var r: Rect2i = d.region
		peak = Vector2(r.end.x - r.size.x * 0.28, r.position.y + r.size.y * 0.35)
	var high := {}
	for c: Vector2i in terrace:
		if int(_coast.get(c, 0)) < MapCfg.PLATEAU_INLAND or near_pocket.has(c):
			continue
		var v := _noise_high.get_noise_2d(c.x, c.y)
		v += MapCfg.SUMMIT_LIFT * exp(-Vector2(c).distance_squared_to(peak) / 60.0)
		if v > MapCfg.PLATEAU_LEVEL:
			high[c] = true
	high = _smooth(high)
	_thicken(high)
	var plateaus: Array = []
	for p: Dictionary in _parts(high):
		if p.size() >= MapCfg.PLATEAU_MIN:
			plateaus.append(p)
	var summit := {}
	if bool(d.get("summit", false)):
		var best := {}
		for p: Dictionary in plateaus:
			if p.has(Vector2i(peak.round())) or p.size() > best.size():
				best = p
				if p.has(Vector2i(peak.round())):
					break
		summit = _erode(_erode(best))
		_thicken(summit)
		if summit.size() < MapCfg.SUMMIT_MIN:
			return _fail("district %d's summit is too small" % (i + 1))
	for c: Vector2i in land:
		grid.height[c] = 0
	for c: Vector2i in terrace:
		grid.height[c] = 1
	for p: Dictionary in plateaus:
		for c: Vector2i in p:
			grid.height[c] = 2
	for c: Vector2i in summit:
		grid.height[c] = 3
	# What thickening took back from the terrace may have joined a pocket to
	# the rim; the pocket is what its flood at ground level reaches.
	part.merge({"terrace": terrace, "plateaus": plateaus, "summit": summit,
		"pocket": _level_part(pocket, 0), "out": _level_part(out, 0)})
	return true


## Makes room for a ramp from `pocket` onto `terrace`: finds the terrace cell
## `c0` that, with the fewest terrace cells lowered into the pocket, becomes a
## convex south corner with the ramp's two cells, the ground above its top
## and at its side, and somewhere to step off its foot all pocket ground. The
## cells lowered join the pocket.
func _carve_stair(terrace: Dictionary, pocket: Dictionary, near: Vector2i) -> bool:
	var best: Array = []
	var score := INF
	var edge := _grow(pocket, 2)
	for c0: Vector2i in terrace:
		if not edge.has(c0):
			continue
		for s in [-1, 1]:
			var t: Vector2i = c0 + Vector2i(s, 0)
			var f := t + DOWN
			var need: Array[Vector2i] = [t, t + UP, t + UP + UP, t + Vector2i(s, 0), f,
				f + DOWN, c0 + DOWN, c0 + DOWN + DOWN, t + Vector2i(s, -1)]
			var ok := true
			var lower: Array[Vector2i] = []
			for k in need:
				if not grid.land.has(k) or int(_coast.get(k, 0)) < 2:
					ok = false
					break
				if terrace.has(k):
					lower.append(k)
				elif not pocket.has(k):
					ok = false
					break
			# The corner stays: terrace above it and behind it, or the tidying
			# that follows takes it back as a stray tip.
			for k in [c0 + UP, c0 + Vector2i(-s, 0), c0 + Vector2i(-s, -1)]:
				if not terrace.has(k) or lower.has(k):
					ok = false
			if not ok:
				continue
			for b: Dictionary in MapCfg.BRIDGES:
				if (b.cells as Rect2i).grow(3).has_point(t) or (b.cells as Rect2i).grow(3).has_point(f):
					ok = false
			if not ok:
				continue
			var sc := lower.size() * 10.0 + Vector2(c0 - near).length()
			if sc < score:
				score = sc
				best = lower
				_last_carve = [c0, s]
	if score == INF:
		return false
	for k: Vector2i in best:
		terrace.erase(k)
		pocket[k] = true
	var before := terrace.duplicate()
	_thicken(terrace)
	for k: Vector2i in before:
		if not terrace.has(k):
			pocket[k] = true
	return true


## A few cells in from a landing, toward the island's middle: where its
## pocket is centred, so the pocket lies over land rather than half in the sea.
static func _inland(at: Vector2i, r: Rect2i) -> Vector2i:
	var toward := (Vector2(r.get_center()) - Vector2(at)).normalized()
	return Vector2i((Vector2(at) + toward * MapCfg.POCKET_INLAND).round())


## Land within `radius` of `at`, the edge wobbled by the noise.
func _pocket(land: Dictionary, at: Vector2i, radius: float) -> Dictionary:
	var out := {}
	for c: Vector2i in land:
		var d := Vector2(c - at).length()
		if d <= radius + _noise_rim.get_noise_2d(c.x * 3.1, c.y * 3.1) * 2.0:
			out[c] = true
	_thicken(out)
	return out


## The cells of `seed` still at `level`, and all ground of that level joined
## to them.
func _level_part(seed: Dictionary, level: int) -> Dictionary:
	var out := {}
	var queue: Array[Vector2i] = []
	var isl := -1
	for c: Vector2i in seed:
		if int(grid.height.get(c, -1)) == level:
			out[c] = true
			queue.append(c)
			isl = int(grid.island_of.get(c, -1))
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		for d in D4:
			var n: Vector2i = c + d
			if not out.has(n) and grid.land.has(n) and int(grid.height.get(n, -1)) == level \
					and int(grid.island_of.get(n, -1)) == isl:
				out[n] = true
				queue.append(n)
	return out


# --- Stairs -----------------------------------------------------------------
## The stairs. One -- **the guarded one** -- from the station's pocket up onto
## the terrace; no other stair touches the pocket, so the knight on it holds
## the whole island. Then as many more as fit: from the exit pocket and the
## coast rim up to the terrace, and round every plateau and the summit, so the
## island inside is all loops.
func _stairs(i: int, part: Dictionary) -> bool:
	var d: Dictionary = MapCfg.DISTRICTS[i]
	var r: Rect2i = d.region
	var pocket: Dictionary = part.pocket
	var terrace := _at_least(1, part.land)
	var guard := _pick_ramp(terrace, 0, part.arrive_at, 0, pocket, true)
	if guard.is_empty():
		return _fail("district %d's pocket has no stair up" % (i + 1))
	part["up"] = guard
	var keep_off := _grow(pocket, 2)
	if part.leave_at.x >= 0:
		var down := _pick_ramp(terrace, 0, part.leave_at, 0, part.out, false, keep_off)
		if down.is_empty():
			return _fail("district %d's exit has no stair" % (i + 1))
		part["down"] = down
	for k in MapCfg.TERRACE_EXTRA_STAIRS:
		var along := Vector2i(_rng.randi_range(r.position.x, r.end.x), _rng.randi_range(r.position.y, r.end.y))
		_pick_ramp(terrace, 0, along, 0, {}, false, keep_off)
	for p: Dictionary in part.plateaus:
		var n := 0
		for side in [-1, 1]:
			if not _pick_ramp(_at_least(2, p), 1, _bottom_corner(p, side), side).is_empty():
				n += 1
		if n == 0:
			return _fail("a plateau in district %d has no stair" % (i + 1))
	if not (part.summit as Dictionary).is_empty():
		var n := 0
		for side in [-1, 1]:
			if not _pick_ramp(part.summit, 2, _bottom_corner(part.summit, side), side).is_empty():
				n += 1
		if n == 0:
			return _fail("district %d's summit has no stair" % (i + 1))
	return true


func _at_least(level: int, among: Dictionary) -> Dictionary:
	var out := {}
	for c: Vector2i in among:
		if int(grid.height.get(c, 0)) >= level:
			out[c] = true
	return out


func _bottom_corner(cells: Dictionary, side: int) -> Vector2i:
	var best := Vector2i.ZERO
	var first := true
	for c: Vector2i in cells:
		if first or c.y > best.y or (c.y == best.y and (c.x - best.x) * side > 0):
			best = c
			first = false
	return best


## A ramp from level `low` onto `high`, nearest `prefer`, on the `side` given
## (0: either). With `within`, both its cells in that set; `off` cells it may
## not touch. Laid at once, so later picks keep their distance. [] if none.
func _pick_ramp(high: Dictionary, low: int, prefer: Vector2i, side: int, within := {},
		guarded := false, off := {}) -> Array:
	var best: Array = []
	var near := INF
	for c: Vector2i in high:
		if high.has(c + DOWN):
			continue
		for s in ([-1, 1] if side == 0 else [side]):
			var t: Vector2i = c + Vector2i(s, 0)
			var f := t + DOWN
			if not _ramp_ok(high, low, t, f, s):
				continue
			# A ramp is walked onto from the ground at its foot: that ground,
			# not only the ramp, has to be in `within`.
			if not within.is_empty() and not (within.has(t) and within.has(f)
					and ((within.has(f + DOWN) and _flat(f + DOWN, low))
						or (within.has(f + Vector2i(s, 0)) and _flat(f + Vector2i(s, 0), low)))):
				continue
			if off.has(t) or off.has(f) or off.has(f + DOWN) or off.has(f + Vector2i(s, 0)):
				continue
			var dist := Vector2(t - prefer).length()
			if dist < near:
				near = dist
				best = [t, f, s]
	if not best.is_empty():
		_lay_ramp(best, low, guarded)
	return best


func _ramp_ok(high: Dictionary, low: int, t: Vector2i, f: Vector2i, s: int) -> bool:
	for k in [t, f, t + UP]:
		if not _flat(k, low) or _used.has(Vector3i(k.x, k.y, low)) or high.has(k):
			return false
	var out := t + Vector2i(s, 0)
	if high.has(out) or not _flat(out, low):
		return false                                  # air, or the other side of it
	if not (_flat(f + DOWN, low) or _flat(f + Vector2i(s, 0), low)):
		return false                                  # nowhere to step off
	# The cliff beside the foot must drop onto low ground, not into a
	# one-cell pit with the high ground again below it.
	var face := f - Vector2i(s, 0)
	if high.has(face + DOWN):
		return false
	if not grid.land.has(f + DOWN):
		return false                                  # stairs into the sea
	for b: Dictionary in MapCfg.BRIDGES:
		if (b.cells as Rect2i).grow(2).has_point(f) or (b.cells as Rect2i).grow(2).has_point(t):
			return false
	return true


func _flat(c: Vector2i, level: int) -> bool:
	return grid.land.has(c) and int(grid.height.get(c, -1)) == level \
		and not grid.cliff.has(c) and not grid.stairs.has(c)


func _lay_ramp(ramp: Array, low: int, guarded := false) -> void:
	if guarded:
		guard_stairs.append({"top": ramp[0], "foot": ramp[1], "side": int(ramp[2])})
	var tiles: Array = SLOPE_LEFT if int(ramp[2]) < 0 else SLOPE_RIGHT
	grid.stairs[ramp[0]] = {"low": low, "tile": tiles[0], "top": true, "side": int(ramp[2])}
	grid.stairs[ramp[1]] = {"low": low, "tile": tiles[1], "top": false, "side": int(ramp[2])}
	# Stairs of one level keep their distance; stairs of different levels
	# may stand closer, one above the other.
	for c: Vector2i in [ramp[0], ramp[1]]:
		for dy in range(-3, 4):
			for dx in range(-5, 6):
				_used[Vector3i(c.x + dx, c.y + dy, low)] = true
	_rail(ramp[0], int(ramp[2]))


## A ramp is climbed from its foot and left at its top onto the higher ground
## -- not off its back or its high outer side, which are air. Two thin walls.
func _rail(top: Vector2i, side: int) -> void:
	var t := float(MapCfg.TILE)
	var at := Vector2(top) * t
	grid.block(Rect2(at + Vector2(0, -2), Vector2(t, 4)))
	var x := at.x if side < 0 else at.x + t
	grid.block(Rect2(Vector2(x - 2, at.y), Vector2(4, t)))


## Under every south edge of every level, the cliff face -- in the cell below,
## over lower ground or the sea -- except where a ramp stands.
func _lay_cliffs() -> void:
	grid.cliff.clear()
	for c: Vector2i in grid.height.keys():
		if grid.stairs.has(c):
			continue
		for level in range(1, int(grid.height[c]) + 1):
			var k := c + DOWN
			if int(grid.height.get(k, -1)) >= level or grid.stairs.has(k):
				continue
			if int(grid.cliff.get(k, 0)) < level:
				grid.cliff[k] = level


# --- The walk ---------------------------------------------------------------
func _place_stops(parts: Array) -> bool:
	var in_camp := func(c: Vector2i) -> bool:
		return int(grid.island_of.get(c, -1)) == 0 and MapCfg.CAMP_REGION.has_point(c)
	var camp := _yard_cell(in_camp, MapCfg.CAMP_REGION.get_center(), Vector2i(2, 2), [])
	if camp == Vector2i(-1, -1):
		return _fail("no room for the base camp")
	anchors.append(MapGrid.cell_mid(camp))
	var from := camp
	for i in parts.size():
		var part: Dictionary = parts[i]
		var up: Array = part.up
		var isl := i + 1
		# The landmark: the station, on the shelf by its bridge, near the foot
		# of the stair up.
		var pocket: Dictionary = part.pocket
		var on_shelf := func(c: Vector2i) -> bool:
			return pocket.has(c) and int(grid.island_of.get(c, -1)) == isl
		var door := _yard_cell(on_shelf, up[1] + DOWN * 2, MapCfg.STATION_YARD, [up[0], up[1]])
		if door == Vector2i(-1, -1):
			return _fail("no room for station %d by its stair" % (i + 1))
		lifts[anchors.size()] = Vector2(0, -MapCfg.TOWER_LIFT)
		anchors.append(MapGrid.cell_mid(door))
		if _road([from, door], 0).is_empty():
			return _fail("no road to station %d" % (i + 1))
		var goal: Vector2i
		if part.has("down"):
			goal = part.down[1]
		else:
			goal = _summit_cell(part)
			if goal == Vector2i(-1, -1):
				return _fail("no room on the summit for the Victory Gate")
		var circles := _circle_cells(i, door, goal)
		if circles.size() < Game.ITEMS_PER_STATION[i]:
			return _fail("no room for district %d's circles (%d)" % [i + 1, circles.size()])
		var way: Array = [door]
		way.append_array(circles)
		way.append(goal)
		var road := _road(way, 0)
		if road.is_empty():
			return _fail("district %d's road does not join up" % (i + 1))
		var building: String = MapCfg.CIRCLE_BUILDINGS[i]
		for c in circles:
			var lift := _circle_lift(road, road.find(c), building)
			if lift == Vector2.INF:
				return _fail("no room for a circle's tower in district %d" % (i + 1))
			lifts[anchors.size()] = lift
			anchors.append(MapGrid.cell_mid(c))
		if part.has("down"):
			from = part.down[1]
		else:
			anchors.append(MapGrid.cell_mid(goal))
	return true


## Where the Victory Gate stands: on the summit, the far side from its stairs,
## with room for the castle.
func _summit_cell(part: Dictionary) -> Vector2i:
	var summit: Dictionary = part.summit
	var ramps: Array = []
	for c: Vector2i in grid.stairs:
		if int(grid.stairs[c].low) == 2:
			ramps.append(c)
	var on_top := func(c: Vector2i) -> bool:
		return summit.has(c)
	return _yard_cell(on_top, ramps[0] if not ramps.is_empty() else Vector2i.ZERO,
		MapCfg.GATE_YARD, ramps, true)


## The district's circles: spread over its raised ground -- a share of them
## on its plateaus -- each with open ground round it, then put in walking
## order from `entry` to `goal`.
func _circle_cells(i: int, entry: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var n: int = Game.ITEMS_PER_STATION[i]
	var pools := {1: [], 2: []}
	for c: Vector2i in grid.land:
		if int(grid.island_of.get(c, -1)) != i + 1:
			continue
		var h := int(grid.height.get(c, 0))
		if (h == 1 or h == 2) and _open_around(c, h, 1):
			(pools[h] as Array).append(c)
	for k in pools:
		(pools[k] as Array).sort()
	var high: int = mini(int(ceil(n * MapCfg.CIRCLES_HIGH)), (pools[2] as Array).size())
	var picked: Array[Vector2i] = []
	for level in [2, 1]:
		var want := high if level == 2 else n - picked.size()
		var pool: Array = pools[level]
		var got := 0
		while got < want and not pool.is_empty():
			# Farthest from everything picked so far (and the ends), so the
			# circles spread over the island instead of bunching.
			var best := Vector2i(-1, -1)
			var score := -1.0
			for c: Vector2i in pool:
				var dd := minf(Vector2(c - entry).length(), Vector2(c - goal).length())
				for p in picked:
					dd = minf(dd, Vector2(c - p).length())
				dd += _rng.randf() * 0.5
				if dd > score:
					score = dd
					best = c
			if score < MapCfg.MIN_STOP_GAP:
				break
			picked.append(best)
			got += 1
	return _order(picked, entry, goal)


func _open_around(c: Vector2i, level: int, r: int) -> bool:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var k := c + Vector2i(dx, dy)
			if not _flat(k, level):
				return false
	# ...and a stair's head and foot kept clear, so nobody waits on one.
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if grid.stairs.has(c + Vector2i(dx, dy)):
				return false
	return true


## A walking order through `pts` from `a` to `b`: nearest first, then untangled
## (2-opt) so the road does not cross itself.
static func _order(pts: Array[Vector2i], a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var left := pts.duplicate()
	var route: Array[Vector2i] = [a]
	var at := a
	while not left.is_empty():
		var bi := 0
		for k in left.size():
			if Vector2(left[k] - at).length() < Vector2(left[bi] - at).length():
				bi = k
		at = left[bi]
		route.append(at)
		left.remove_at(bi)
	route.append(b)
	var better := true
	while better:
		better = false
		for x in range(1, route.size() - 2):
			for y in range(x + 1, route.size() - 1):
				var before := Vector2(route[x - 1] - route[x]).length() + Vector2(route[y] - route[y + 1]).length()
				var after := Vector2(route[x - 1] - route[y]).length() + Vector2(route[x] - route[y + 1]).length()
				if after < before - 0.01:
					var mid := route.slice(x, y + 1)
					mid.reverse()
					for k in mid.size():
						route[x + k] = mid[k]
					better = true
	var out: Array[Vector2i] = []
	out.assign(route.slice(1, route.size() - 1))
	return out


## A cell `ok` with a yard of `half` cells either side and `half.y` above it
## (and one below) all flat, clear ground of its level, off the road and away
## from `avoid`; nearest `near`, or farthest from it with `far`.
func _yard_cell(ok: Callable, near: Vector2i, half: Vector2i, avoid: Array, far := false) -> Vector2i:
	var best := Vector2i(-1, -1)
	var score := INF
	for c: Vector2i in grid.land:
		if not ok.call(c):
			continue
		var h := int(grid.height.get(c, 0))
		var fits := true
		for y in range(c.y - half.y, c.y + 2):
			for x in range(c.x - half.x, c.x + half.x + 1):
				var k := Vector2i(x, y)
				if not _flat(k, h) or grid.trail.has(k):
					fits = false
					break
				for a: Vector2i in avoid:
					if absi(a.x - k.x) <= 1 and absi(a.y - k.y) <= 1:
						fits = false
						break
				if not fits:
					break
			if not fits:
				break
		if not fits:
			continue
		var dist := Vector2(c - near).length()
		var s := -dist if far else dist
		if s < score:
			score = s
			best = c
	return best


## The road through `way`, in order, walking by level (stairs and all); its
## cells marked as road. The cells in order, or [] if a leg has no way.
func _road(way: Array, level: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = [way[0]]
	var lv := level
	for k in way.size() - 1:
		var leg := _route(way[k], lv, way[k + 1])
		if leg.is_empty():
			return []
		for s: Vector3i in leg.slice(1):
			out.append(Vector2i(s.x, s.y))
		lv = leg[-1].z
	for c in out:
		_mark_road(c)
	return out


func _mark_road(c: Vector2i) -> void:
	grid.trail[c] = true
	if grid.stairs.has(c):
		return
	for d in D4:
		var k: Vector2i = c + d
		if _flat(k, int(grid.height.get(c, -2))):
			grid.trail[k] = true


## Cheapest way from `a` (at `level`) to `b`, walking as the hero does; ground
## next to an edge costs more, which keeps the road off the rims.
func _route(a: Vector2i, level: int, b: Vector2i) -> Array[Vector3i]:
	var start := Vector3i(a.x, a.y, level)
	var cost := {start: 0.0}
	var came := {}
	var open: Array = [[0.0, 0.0, start]]
	var end := Vector3i(-1, -1, -1)
	while not open.is_empty():
		var bi := 0
		for k in open.size():
			if float(open[k][0]) < float(open[bi][0]):
				bi = k
		var cur: Array = open[bi]
		open.remove_at(bi)
		var s: Vector3i = cur[2]
		var c := Vector2i(s.x, s.y)
		if c == b:
			end = s
			break
		if float(cur[1]) > float(cost[s]):
			continue
		var low := int(grid.stairs[c].low) if grid.stairs.has(c) else -1
		for d in D4:
			var nc: Vector2i = c + d
			if not grid.cell_ok(nc, s.z, low) or _railed(c, nc):
				continue
			var ns := Vector3i(nc.x, nc.y, grid.level_at(MapGrid.cell_mid(nc), s.z))
			var step := 1.0 if grid.stairs.has(nc) or _clear_round(nc, ns.z) else 2.5
			var g := float(cost[s]) + step
			if not cost.has(ns) or g < float(cost[ns]):
				cost[ns] = g
				came[ns] = s
				open.append([g + Vector2(nc - b).length(), g, ns])
	if end.x < 0:
		return []
	var out: Array[Vector3i] = [end]
	var s := end
	while s != start:
		s = came[s]
		out.push_front(s)
	return out


func _clear_round(c: Vector2i, level: int) -> bool:
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
		var k: Vector2i = c + d
		if not grid.land.has(k) or grid.cliff.has(k) or int(grid.height.get(k, -1)) != level:
			return false
	return true


func _railed(a: Vector2i, b: Vector2i) -> bool:
	var mid := (MapGrid.cell_mid(a) + MapGrid.cell_mid(b)) * 0.5
	for r in grid.solid:
		if r.has_point(mid):
			return true
	return false


## Where a circle's tower stands: up off the road where it runs across, to
## either side where it runs up and down -- only onto flat ground of the
## circle's own level.
func _circle_lift(path: Array[Vector2i], at: int, building: String) -> Vector2:
	if at < 0:
		return Vector2.INF
	var here := path[at]
	var dir := path[mini(at + 2, path.size() - 1)] - path[maxi(at - 2, 0)]
	var tries: Array = []
	if absi(dir.x) >= absi(dir.y):
		tries = [Vector2(0, -MapCfg.CIRCLE_LIFT), Vector2(0, MapCfg.CIRCLE_LIFT + MapCfg.TILE)]
	else:
		tries = [Vector2(MapCfg.CIRCLE_SIDE_LIFT, 0), Vector2(-MapCfg.CIRCLE_SIDE_LIFT, 0)]
	tries.append_array([Vector2(0, -MapCfg.CIRCLE_LIFT), Vector2(MapCfg.CIRCLE_SIDE_LIFT, 0),
		Vector2(-MapCfg.CIRCLE_SIDE_LIFT, 0)])
	var size := Art.cell(building, 0, 0).region.size * MapCfg.CIRCLE_TOWER_SCALE
	var level := int(grid.height.get(here, -1))
	for lift: Vector2 in tries:
		var base := MapGrid.cell_mid(here) + lift
		var foot := Rect2(base - Vector2(size.x * 0.5, size.y * 0.5), Vector2(size.x, size.y * 0.5))
		var clear := true
		for corner in [foot.position, Vector2(foot.end.x, foot.position.y),
				Vector2(foot.position.x, foot.end.y), foot.end]:
			if not _flat(MapGrid.cell_at(corner), level):
				clear = false
		if clear:
			return lift
	return Vector2.INF


# --- Checks -----------------------------------------------------------------
## The rules the design stands on, asked of what was built: every stop can be
## walked to; and with the knights on their stairs, each station and circle is
## in reach exactly when it should be -- a station once the knight before it
## has stood down, its circles once its own has.
func _validate() -> bool:
	var towers: Array = _tower_indices()
	var stairs: Array[Rect2] = []
	for g: Dictionary in guard_stairs:
		stairs.append(Rect2(Vector2(g.top as Vector2i) * MapCfg.TILE, Vector2(1, 2) * MapCfg.TILE))
	for opened in range(-1, guard_stairs.size()):
		var held: Array[Rect2] = stairs.slice(opened + 1)
		grid.solid.append_array(held)
		var reach := grid.flood(anchors[0], 0)
		for r in held:
			grid.solid.erase(r)
		for st in towers.size():
			var k: int = towers[st]
			if reach.has(MapGrid.cell_at(anchors[k])) != (opened >= st - 1):
				return _fail("station %d reachability wrong with %d knight(s) down" % [st + 1, opened + 1])
			for n in Game.ITEMS_PER_STATION[st]:
				if reach.has(MapGrid.cell_at(anchors[k + 1 + n])) != (opened >= st):
					return _fail("a circle of district %d is reachable past its knight" % (st + 1)
						if opened < st else "a circle of district %d cannot be walked to" % (st + 1))
		if opened == guard_stairs.size() - 1 and not reach.has(MapGrid.cell_at(anchors[-1])):
			return _fail("the Victory Gate cannot be walked to")
	return true


func _tower_indices() -> Array:
	var out: Array = []
	var k := 1
	for st in Game.ITEMS_PER_STATION.size():
		out.append(k)
		k += 1 + Game.ITEMS_PER_STATION[st]
	return out


# --- Paint ------------------------------------------------------------------
## Water, surf and flat ground come from MapBuilder (retile + foam); this adds,
## per level as the pack's guide stacks them, a shadow layer and the raised
## ground with its cliffs and stairs -- each level in its own grass colour.
func paint(world: Node2D, builder: MapBuilder) -> void:
	builder.retile(grid.land.keys())
	var surf := grid.land.duplicate()
	for c: Vector2i in grid.cliff:
		if not grid.land.has(c):
			surf[c] = true
	Art.shore_foam(world, surf, MapCfg.TILE).z_index = -1
	var tex := Art.tex(MapCfg.SHADOW_SHEET)
	for level in range(1, MapCfg.LEVEL_COLORS.size()):
		var shade := Node2D.new()
		shade.name = "Shadows%d" % level
		world.add_child(shade)
		var layer := Art.terrain_layer(MapCfg.LEVEL_COLORS[level], MapCfg.TILE)
		layer.name = "Level%d" % level
		world.add_child(layer)
		# A ramp stands on the ground of its low level (the guide): that
		# ground runs on under it, unbroken, and shows through its open corner.
		var up := func(c: Vector2i) -> bool:
			if grid.stairs.has(c):
				return int(grid.stairs[c].low) >= level
			return int(grid.height.get(c, -1)) >= level
		var joins := func(c: Vector2i) -> bool:
			if up.call(c):
				return true
			return grid.stairs.has(c) and int(grid.stairs[c].low) == level - 1 \
				and bool(grid.stairs[c].top)
		for c: Vector2i in grid.height:
			if not up.call(c):
				continue
			layer.set_cell(c, 0, Art.autotile(joins.call(c + Vector2i(-1, 0)),
				joins.call(c + Vector2i(1, 0)), up.call(c + UP), up.call(c + DOWN), true))
			var edge := false
			for d in [Vector2i(-1, 0), Vector2i(1, 0), DOWN]:
				if not up.call(c + d):
					edge = true
			if edge:
				var sp := Sprite2D.new()
				sp.texture = tex
				sp.position = MapGrid.cell_mid(c) + Vector2(0, MapCfg.TILE)
				sp.scale = Vector2.ONE * MapCfg.LEVEL_SHADOW_SCALE
				sp.modulate.a = MapCfg.LEVEL_SHADOW_ALPHA
				shade.add_child(sp)
		# A cliff runs on into more cliff, a ramp's foot, or this level's own
		# ground beside it (the guide's 18 beside 6): only a drop ends it.
		var face := func(c: Vector2i) -> bool:
			if int(grid.cliff.get(c, 0)) == level or up.call(c):
				return true
			return grid.stairs.has(c) and int(grid.stairs[c].low) == level - 1 \
				and not bool(grid.stairs[c].top)
		for c: Vector2i in grid.cliff:
			if int(grid.cliff[c]) != level:
				continue
			var t := Art.autotile(face.call(c + Vector2i(-1, 0)), face.call(c + Vector2i(1, 0)),
				false, false, true)
			layer.set_cell(c, 0, Vector2i(t.x, CLIFF_ROW if grid.land.has(c) else CLIFF_SEA_ROW))
		for c: Vector2i in grid.stairs:
			if int(grid.stairs[c].low) == level - 1:
				layer.set_cell(c, 0, grid.stairs[c].tile as Vector2i)


# --- Shape helpers ------------------------------------------------------------
## Closed then opened: small gaps filled, small spurs taken off.
static func _smooth(cells: Dictionary) -> Dictionary:
	return _grow(_erode(_erode(_grow(cells, 1))), 1)


static func _grow(cells: Dictionary, n: int) -> Dictionary:
	var out := cells.duplicate()
	for _k in n:
		var next := out.duplicate()
		for c: Vector2i in out:
			for d in D4:
				next[c + d] = true
		out = next
	return out


## The biggest piece of `cells`, and any piece holding a `keep` point.
static func _largest(cells: Dictionary, keep: Array) -> Dictionary:
	var parts := _parts(cells)
	var out := {}
	var biggest := {}
	for p: Dictionary in parts:
		if p.size() > biggest.size():
			biggest = p
		for k: Vector2i in keep:
			if p.has(k):
				out.merge(p)
	out.merge(biggest)
	return out


## Water shut inside the land becomes land: a lake a cell wide reads as a
## tiling fault, not a lake.
static func _fill_holes(cells: Dictionary, r: Rect2i) -> void:
	var outside := {}
	var queue: Array[Vector2i] = []
	var box := r.grow(1)
	for y in range(box.position.y, box.end.y):
		for x in range(box.position.x, box.end.x):
			var c := Vector2i(x, y)
			if (x == box.position.x or y == box.position.y or x == box.end.x - 1 or y == box.end.y - 1) \
					and not cells.has(c):
				outside[c] = true
				queue.append(c)
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		for d in D4:
			var n: Vector2i = c + d
			if box.has_point(n) and not cells.has(n) and not outside.has(n):
				outside[n] = true
				queue.append(n)
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var c := Vector2i(x, y)
			if not outside.has(c):
				cells[c] = true


static func _parts(cells: Dictionary) -> Array:
	var seen := {}
	var out: Array = []
	for c: Vector2i in cells:
		if seen.has(c):
			continue
		var part := {}
		var queue: Array[Vector2i] = [c]
		seen[c] = true
		while not queue.is_empty():
			var p: Vector2i = queue.pop_back()
			part[p] = true
			for d in D4:
				var n: Vector2i = p + d
				if cells.has(n) and not seen.has(n):
					seen[n] = true
					queue.append(n)
		out.append(part)
	return out


static func _erode(cells: Dictionary) -> Dictionary:
	var out := {}
	for c: Vector2i in cells:
		var all := true
		for d in D4:
			if not cells.has(c + d):
				all = false
				break
		if all:
			out[c] = true
	return out


## Drops cells until every one has a neighbour on at least one side each way
## (so no part is a single cell wide) and no two cells touch only corner to
## corner (the tiles cannot draw that seam).
static func _thicken(cells: Dictionary) -> void:
	var changed := true
	while changed:
		changed = false
		for c: Vector2i in cells.keys():
			var l := cells.has(c + Vector2i(-1, 0))
			var r := cells.has(c + Vector2i(1, 0))
			var u := cells.has(c + UP)
			var d := cells.has(c + DOWN)
			var pinch := false
			for dx in [-1, 1]:
				for dy in [-1, 1]:
					if cells.has(c + Vector2i(dx, dy)) and not cells.has(c + Vector2i(dx, 0)) \
							and not cells.has(c + Vector2i(0, dy)):
						pinch = true
			if not (l or r) or not (u or d) or pinch:
				cells.erase(c)
				changed = true

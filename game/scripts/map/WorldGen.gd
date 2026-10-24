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
##
## The island has levels: plateaus (1) where one noise rises, hills (2) on the
## big plateaus where another does, cliffs under their south edges -- into the
## sea where they meet it -- and ramps up their sides, after the pack's tilemap
## guide. The shapes are cleaned until the tiles can draw them (`_shape`), and
## nothing stands across a level's edge, on a cliff or by a ramp (`_flat`).

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

## Ponds: PONDS_MIN to PONDS_MAX a side, mirrored, dug in the ground before
## any level rises -- an oval POND_R cells across, give or take, with a 3x3
## core, two cells of ground round it, POND_GAP cells from another, none near
## a spawn or on the Monastery's ground in the middle.
const PONDS_MIN := 1
const PONDS_MAX := 2
const POND_R := Vector2(2.6, 2.0)
const POND_GAP := 4
const POND_FROM_SPAWN := 10
const POND_FROM_AXIS := 7

## Plateaus where this noise is highest, over PLATEAU_SHARE of the island,
## read in blocks of 2x2 cells so their edges step two cells at a time: at
## least MIN_PLATEAU cells with a 5x5 core. On a plateau of BIG_PLATEAU cells or more, by HILL_CHANCE, a
## hill: the plateau again, HILL_INSET cells in, at least MIN_HILL cells.
const PLATEAU_FREQ := 0.06
const PLATEAU_SHARE := 0.25
const MIN_PLATEAU := 30
const BIG_PLATEAU := 150
const HILL_CHANCE := 0.7
const HILL_INSET := 3
const MIN_HILL := 16
## Ground kept round each spawn, cells. The Monastery's ground, this far round
## where it goes, is raised or kept down by the seed: either is fair.
const SPAWN_LOW := 8
const CENTRE_R := 7
## Ramps onto each plateau (a hill needs only one), and how far apart two
## ramps onto one level stand, cells.
const PLATEAU_RAMPS := 2
const RAMP_GAP := 6
## A world whose levels came out mostly let down -- a plateau from coast to
## coast takes no ramp -- tries the next noise, up to LEVEL_TRIES times, for
## at least MIN_RAISED of the island raised.
const LEVEL_TRIES := 6
const MIN_RAISED := 0.12

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

## Each team's houses: a pair side by side beside its spawn, HOUSE_STEP cells
## apart (a cell between them), with a yard round them -- a cell each side,
## HOUSE_FRONT rows in front -- where no tree grows. Behind the spawn
## (toward the world's edge) if they fit, else wherever is nearest.
const HOUSE_STEP := 3
const HOUSE_FRONT := 2
const HOUSE_LOOK := 9             # how far from the spawn to look, cells
const HOUSE_CELLS := Vector2i(2, 3)

var seed := 0
var monk_count := 10

## Outputs. Cells are Vector2i; points are world px.
var land := {}                    # every land cell
var height := {}                  # land cell -> 0 the ground, 1 a plateau, 2 a hill
var ramps: Array = []             # [{top, low, side}], MapGrid.lay_ramp's
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
var _g := MapGrid.new()           # the levels as walked: cliffs, ramps, rails
var _reach := {}                  # cells walked to from the spawns
var _centre_row := 0              # where the Monastery is meant to go
var _raised := false              # ...and whether up on a plateau
var _used := {}                   # Vector3i(cell, low level): a ramp or its margin
static var _feet := {}            # prop name -> its collision rects about its origin
static var _rock_art := {}        # water rock variant -> its art's box about its point


static func mirror_cell(c: Vector2i) -> Vector2i:
	return Vector2i(W - 1 - c.x, c.y)


static func mirror(p: Vector2) -> Vector2:
	return Vector2(W * T - p.x, p.y)


func generate() -> void:
	_rng.seed = seed
	_make_land()
	_place_spawns()
	_dig_ponds()
	for attempt in LEVEL_TRIES:
		_raise(attempt)
		_place_ramps()
		if _above(0).size() >= main.size() * MIN_RAISED or attempt == LEVEL_TRIES - 1:
			break
		for c: Vector2i in land:
			height[c] = 0
		ramps.clear()
		_used.clear()
		_g = MapGrid.new()
		_reach = main
	_place_monastery()
	_place_houses()
	_place_monks()
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
	# Water the noise shut inside the land goes: a lake it leaves is the wrong
	# shape for the tiles as often as not. The ponds are dug on purpose.
	var sea := {}
	for y in H:
		for x in W:
			if not land.has(Vector2i(x, y)):
				sea[Vector2i(x, y)] = true
	var open := _flood(Vector2i.ZERO, sea)
	for c: Vector2i in sea:
		if not open.has(c):
			land[c] = true
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
	for c: Vector2i in land:
		height[c] = 0
	_reach = main


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


## The ponds: left half from the seed, mirrored. Each is cut from the main
## island's ground and the island must stay in one piece without it.
func _dig_ponds() -> void:
	var spawn := MapGrid.cell_at(spawns[0])
	var spots: Array[Vector2i] = []
	for c: Vector2i in main:
		if c.x < HALF - POND_FROM_AXIS and _dist(c, spawn) >= POND_FROM_SPAWN:
			spots.append(c)
	spots.sort()
	_shuffle(spots)
	var want := _rng.randi_range(PONDS_MIN, PONDS_MAX)
	var dug: Array[Dictionary] = []
	var wobble := _noise(seed + 6, 0.35)
	for at in spots:
		if dug.size() >= want:
			break
		var r := POND_R * _rng.randf_range(0.85, 1.25)
		var pond := {}
		for dy in range(-4, 5):
			for dx in range(-4, 5):
				var c := at + Vector2i(dx, dy)
				var d := Vector2(dx / r.x, dy / r.y).length() + wobble.get_noise_2d(c.x, c.y) * 0.35
				if d <= 1.0:
					pond[c] = true
		_thicken(pond)
		if not _core(pond, 1) or not _pond_fits(pond, dug, spawn):
			continue
		var left := main.duplicate()
		for c: Vector2i in pond:
			left.erase(c)
			left.erase(mirror_cell(c))
		if _flood(Vector2i(HALF - 1, H / 2), left).size() != left.size():
			continue                      # it would cut the island in two
		dug.append(pond)
		for c: Vector2i in pond:
			for k in [c, mirror_cell(c)]:
				land.erase(k)
				main.erase(k)
				islet_of.erase(k)
				height.erase(k)


## Every cell of `pond` on the main island's ground, two cells of it round
## each, clear of the other ponds and the spawn's ground, left of the middle.
func _pond_fits(pond: Dictionary, dug: Array[Dictionary], spawn: Vector2i) -> bool:
	for c: Vector2i in pond:
		if c.x >= HALF - POND_FROM_AXIS or _dist(c, spawn) < POND_FROM_SPAWN:
			return false
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				if not main.has(c + Vector2i(dx, dy)):
					return false
		for o in dug:
			for dy in range(-POND_GAP, POND_GAP + 1):
				for dx in range(-POND_GAP, POND_GAP + 1):
					if o.has(c + Vector2i(dx, dy)):
						return false
	return true


# --- Levels -----------------------------------------------------------------
## Plateaus, then hills on the big ones -- left half from the noise, mirrored,
## then shaped -- with the spawns' ground kept down and the Monastery's up or
## down by the seed.
func _raise(attempt := 0) -> void:
	_centre_row = _pick_centre_row()
	_raised = _rng.randf() < 0.5
	var centre := _disc(Vector2i(HALF - 1, _centre_row), CENTRE_R)
	var low := {}
	for c in _disc(MapGrid.cell_at(spawns[0]), SPAWN_LOW):
		low[c] = true
	var hi := {}
	var noise := _noise(seed + 4 + 101 * attempt, PLATEAU_FREQ)
	var rise := {}
	for c: Vector2i in _cells():
		if c.x < HALF and main.has(c):
			rise[c] = noise.get_noise_2d(c.x / 2 * 2, c.y / 2 * 2)
	var by_rise := rise.values()
	by_rise.sort()
	var level: float = by_rise[int(by_rise.size() * (1.0 - PLATEAU_SHARE))]
	for c: Vector2i in rise:
		if float(rise[c]) >= level:
			hi[c] = true
	for c in centre:
		if c.x < HALF and main.has(c):
			if _raised:
				hi[c] = true
			else:
				hi.erase(c)
				low[c] = true
	hi = _shape(_mirrored(hi), _mirrored(low), main, MIN_PLATEAU, 2)
	for c: Vector2i in hi:
		height[c] = 1
	# Hills: a big plateau again, well inside it, never where the Monastery goes.
	var hills := {}
	for piece: Dictionary in _parts(hi):
		if piece.size() >= BIG_PLATEAU and _rng.randf() < HILL_CHANCE:
			for c: Vector2i in piece:
				if c.x < HALF and _inset(c, piece, HILL_INSET):
					hills[c] = true
	for c in centre:
		hills.erase(c)
	var not_room := {}
	for c: Vector2i in land:
		if not hills.has(c) and not hills.has(mirror_cell(c)):
			not_room[c] = true
	hills = _shape(_mirrored(hills), not_room, hi, MIN_HILL, 1)
	for c: Vector2i in hills:
		height[c] = 2


## Rows on the axis where the Monastery and its yard fit the main island's
## inland ground, one picked by the seed: where it is meant to go, before the
## levels are known.
func _pick_centre_row() -> int:
	var fit: Array[int] = []
	for base in range(BORDER + MONASTERY_CELLS.y + 1, H - BORDER - DOOR_YARD - 2):
		var ok := true
		for y in range(base - MONASTERY_CELLS.y + 1, base + DOOR_YARD + 1):
			for x in range(HALF - 2, HALF + 2):
				if not _inland(Vector2i(x, y)):
					ok = false
		if ok:
			fit.append(base)
	return fit[_rng.randi_range(0, fit.size() - 1)] if not fit.is_empty() else H / 2


## `cells`, cleaned until the tiles can draw it and a walker can use it, on
## `base` (the land, or a plateau for its hills) and off `keep_low`: smoothed;
## no strip of lower ground a cell wide left against it; no part of it a cell
## wide, no two cells meeting only at a corner; no piece under `min_size`
## cells or without a core `core` cells deep. Every rule is symmetric left to
## right, so a mirrored set stays mirrored.
func _shape(cells: Dictionary, keep_low: Dictionary, base: Dictionary, min_size: int, core: int) -> Dictionary:
	var out := cells
	for _pass in 8:
		var was := out.duplicate()
		out = _grow(_erode(_erode(_grow(out))))
		for c: Vector2i in out.keys():
			if not base.has(c) or keep_low.has(c):
				out.erase(c)
		_fill_strips(out, keep_low, base)
		_thicken(out)
		for piece: Dictionary in _parts(out):
			if piece.size() < min_size or not _core(piece, core):
				for c: Vector2i in piece:
					out.erase(c)
		if out.size() == was.size() and was.has_all(out.keys()):
			break
	return out


## Lower ground a cell wide between `out` and the edge of `base` (or more of
## `out`, or a cliff under it) is taken in: a strip that thin is no walk, and
## the tiles cannot draw it.
func _fill_strips(out: Dictionary, keep_low: Dictionary, base: Dictionary) -> void:
	var shut := func(k: Vector2i) -> bool:
		return out.has(k) or not base.has(k) or out.has(k + Vector2i.UP)
	for _i in 6:
		var add: Array[Vector2i] = []
		for c: Vector2i in base:
			if out.has(c) or keep_low.has(c):
				continue
			var touch := false
			for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				touch = touch or out.has(c + d)
			if touch and ((shut.call(c + Vector2i.LEFT) and shut.call(c + Vector2i.RIGHT))
					or (shut.call(c + Vector2i.UP) and shut.call(c + Vector2i.DOWN))):
				add.append(c)
		if add.is_empty():
			return
		for c in add:
			out[c] = true


## Drops cells until every one has a neighbour on at least one side each way
## (so no part is a single cell wide) and no two touch only corner to corner
## (the tiles cannot draw that seam). Read from the set as it was each pass,
## so the mirror holds.
static func _thicken(cells: Dictionary) -> void:
	while true:
		var drop: Array[Vector2i] = []
		for c: Vector2i in cells:
			var l := cells.has(c + Vector2i.LEFT)
			var r := cells.has(c + Vector2i.RIGHT)
			var u := cells.has(c + Vector2i.UP)
			var d := cells.has(c + Vector2i.DOWN)
			var pinch := false
			for dx in [-1, 1]:
				for dy in [-1, 1]:
					if cells.has(c + Vector2i(dx, dy)) and not cells.has(c + Vector2i(dx, 0)) \
							and not cells.has(c + Vector2i(0, dy)):
						pinch = true
			if not (l or r) or not (u or d) or pinch:
				drop.append(c)
		if drop.is_empty():
			return
		for c in drop:
			cells.erase(c)


## Each cell, or each cell of its mirror half, as the right half's mirror of
## the left: the left half's cells and their twins.
func _mirrored(cells: Dictionary) -> Dictionary:
	var out := {}
	for c: Vector2i in cells:
		if c.x < HALF:
			out[c] = true
			out[mirror_cell(c)] = true
	return out


## Whether `piece` holds every cell within `n` of `c`, diagonals too.
static func _inset(c: Vector2i, piece: Dictionary, n: int) -> bool:
	for dy in range(-n, n + 1):
		for dx in range(-n, n + 1):
			if not piece.has(c + Vector2i(dx, dy)):
				return false
	return true


static func _core(piece: Dictionary, n: int) -> bool:
	for c: Vector2i in piece:
		if _inset(c, piece, n):
			return true
	return false


## The ramps: onto every plateau from the ground, PLATEAU_RAMPS where they
## fit so none is a dead end, then onto every hill from its plateau; then,
## until all the island is walked to, one more from ground walked to onto
## ground that is not; ground no ramp can reach -- the pack's ramps all face
## south, so none climbs to ground behind a plateau -- is raised onto the
## plateau it backs onto; and a level still out of reach is let down. Laid on
## the left half and mirrored, side for side.
func _place_ramps() -> void:
	_g.land = land
	_g.height = height
	for low in [0, 1]:
		_g.lay_cliffs()
		for piece: Dictionary in _parts(_above(low)):
			var left := false
			for c: Vector2i in piece:
				left = left or c.x < HALF
			if not left:
				continue                  # the mirror of one already done
			_ramps_onto(piece, low, piece.has(mirror_cell(piece.keys()[0])))
	for _round in 40:
		_g.lay_cliffs()
		_reach = _g.flood(spawns[0], 0)
		if not _join() and not _let_up() and not _let_down():
			break
	_g.lay_cliffs()
	_reach = _g.flood(spawns[0], 0)


## Cells above level `low`.
func _above(low: int) -> Dictionary:
	var out := {}
	for c: Vector2i in height:
		if int(height[c]) > low:
			out[c] = true
	return out


## One ramp between ground walked to and ground that is not, the nearest the
## spawn; whether there was one.
func _join() -> bool:
	var spawn := MapGrid.cell_at(spawns[0])
	var best: Array = []
	for c: Vector2i in _cells():
		var low := int(height.get(c, 0)) - 1
		if low < 0 or c.x >= HALF or int(height.get(c + Vector2i.DOWN, -1)) > low:
			continue
		for side in [-1, 1]:
			if _reach.has(c) != _reach.has(c + Vector2i(side * 2, 0)) \
					and (best.is_empty() or _dist(c, spawn) < _dist(best[0], spawn)) \
					and _ramp_spot(c, low, side) != null:
				best = [c, side, low]
	if best.is_empty():
		return false
	_lay_ramp(best[0], best[2], best[1], _ramp_spot(best[0], best[2], best[1]))
	return true


## Each piece of ground no walk reaches, raised to the level of the walked-to
## ground it backs onto; whether any was.
func _let_up() -> bool:
	var lost := {}
	for c: Vector2i in main:
		if not _reach.has(c) and int(height[c]) == 0 and not _g.cliff.has(c):
			lost[c] = true
	var any := false
	for piece: Dictionary in _parts(lost):
		var to := 0
		for c: Vector2i in piece:
			for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				if _reach.has(c + d) and not _g.stairs.has(c + d):
					to = maxi(to, int(height[c + d]))
		if to > 0:
			# Only if the level keeps its shape with it (`_thicken` takes nothing).
			var up := _above(to - 1)
			up.merge(piece)
			var n := up.size()
			_thicken(up)
			if up.size() == n:
				for c: Vector2i in piece:
					height[c] = to
				any = true
	return any


## Every raised piece of the island no walk reaches -- a hill, then a
## plateau with whatever stands on it -- goes down a level, and the ramps
## that led up onto it are taken up; whether any did.
func _let_down() -> bool:
	var any := false
	for level in [2, 1]:
		for piece: Dictionary in _parts(_above(level - 1)):
			var reached := false
			for c: Vector2i in piece:
				reached = reached or _reach.has(c)
			if reached:
				continue
			for c: Vector2i in piece:
				height[c] = int(height[c]) - 1
			any = true
	if any:
		for i in range(ramps.size() - 1, -1, -1):
			var r: Dictionary = ramps[i]
			if not _above(int(r.low)).has(r.top + Vector2i(-int(r.side), 1)) \
					or int(height[r.top + Vector2i(0, 1)]) != int(r.low):
				_g.unlay_ramp(r.top, r.side)
				ramps.remove_at(i)
	return any


## Ramps onto `piece` from `low`, spread out, as many as it wants. For a
## piece that is its own mirror, each one's twin is a ramp onto it too.
func _ramps_onto(piece: Dictionary, low: int, whole: bool) -> void:
	var spots: Array = []
	for c: Vector2i in piece:
		if not piece.has(c + Vector2i.DOWN) and c.x < HALF:
			spots.append(c + Vector2i.LEFT)
			spots.append(c + Vector2i.RIGHT)
	_shuffle(spots)
	var laid: Array[Vector2i] = []
	var want := PLATEAU_RAMPS if low == 0 else 1
	for mid: Vector2i in spots:
		if laid.size() * (2 if whole else 1) >= want:
			break
		var apart := not whole or _dist(mid, mirror_cell(mid)) >= RAMP_GAP
		for o in laid:
			apart = apart and _dist(mid, o) >= RAMP_GAP and _dist(mid, mirror_cell(o)) >= RAMP_GAP
		var c := mid + (Vector2i.RIGHT if piece.has(mid + Vector2i.RIGHT) else Vector2i.LEFT)
		var side := (mid - c).x
		if not apart or not piece.has(c) or piece.has(c + Vector2i.DOWN):
			continue
		var cut: Variant = _ramp_spot(c, low, side)
		if cut != null:
			_lay_ramp(c, low, side, cut)
			laid.append(mid)


## A ramp beside `c`, a south-edge cell of the ground above `low`, on its
## `side`: its three cells (top, middle, foot) on open ground of `low`, the
## middle beside `c` and the foot beside the cliff under it; ground off its
## outer side; somewhere to step off its foot; the cliff beside the foot
## dropping onto ground, not into a pit or the sea; and clear of the axis, so
## its mirror does not meet it. Where the higher ground steps out over the
## ramp's top -- most corners, on shapes drawn in blocks -- that 2x2 block of
## it is cut away, if what is left keeps its shape (`_thicken` takes nothing
## more). The cells to cut (maybe none), or null where no ramp fits.
func _ramp_spot(c: Vector2i, low: int, side: int) -> Variant:
	var mid := c + Vector2i(side, 0)
	var cut: Array[Vector2i] = []
	for dy in [-2, -1]:
		for dx in [0, side]:
			var k := mid + Vector2i(dx, dy)
			if int(height.get(k, -1)) > low:
				if int(height[k]) != low + 1 or _g.stairs.has(k):
					return null
				cut.append(k)
	for k in cut:
		height[k] = low
	var ok := _ramp_fits(c, low, side)
	if ok and not cut.is_empty():
		var above := _above(low)
		var n := above.size()
		_thicken(above)
		ok = above.size() == n
	for k in cut:
		height[k] = low + 1
	return cut if ok else null


func _ramp_fits(c: Vector2i, low: int, side: int) -> bool:
	var mid := c + Vector2i(side, 0)
	var foot := mid + Vector2i.DOWN
	var spawn := MapGrid.cell_at(spawns[0])
	if int(height.get(c, -1)) != low + 1 or int(height.get(c + Vector2i.DOWN, -1)) > low:
		return false
	for k in [mid + Vector2i.UP, mid, foot, mid + Vector2i(side, 0)]:
		if not _open(k, low) or k.x > HALF - 3 or _dist(k, spawn) <= SPAWN_YARD + 1:
			return false
	# Not on the water's edge: a ramp's cells and its way off all dry ground.
	for row in range(-1, 3):
		for dx in range(-1, 2):
			if not land.has(mid + Vector2i(dx, row)) or not land.has(foot + Vector2i(dx + side, 1)):
				return false
	if not (_open(foot + Vector2i.DOWN, low) or _open(foot + Vector2i(side, 0), low)):
		return false
	return int(height.get(c + Vector2i(0, 2), -1)) <= low and land.has(foot + Vector2i.DOWN)


## Ground of level `low` a ramp may stand on: no cliff face (nothing higher
## right above it), no ramp, none near.
func _open(k: Vector2i, low: int) -> bool:
	return main.has(k) and int(height[k]) == low and int(height.get(k + Vector2i.UP, -1)) <= low \
		and not _g.stairs.has(k) and not _used.has(Vector3i(k.x, k.y, low))


## The ramp beside `c` on `side`, the ground cut for it, and their mirrors.
func _lay_ramp(c: Vector2i, low: int, side: int, cut: Array) -> void:
	for k: Vector2i in cut:
		height[k] = low
		height[mirror_cell(k)] = low
	for r in [[c + Vector2i(side, -1), side], [mirror_cell(c + Vector2i(side, -1)), -side]]:
		var top: Vector2i = r[0]
		_g.lay_ramp(top, low, r[1])
		ramps.append({"top": top, "low": low, "side": r[1]})
		for row in 3:
			for dy in range(-3, 4):
				for dx in range(-5, 6):
					_used[Vector3i(top.x + dx, top.y + row + dy, low)] = true


# --- Places -----------------------------------------------------------------
func _spawn_cell() -> Vector2i:
	return Vector2i(int(W * SPAWN_AT.x), int(H * SPAWN_AT.y))


func _place_spawns() -> void:
	var at := _nearest_open(_spawn_cell(), SPAWN_YARD + 1)
	spawns = [MapGrid.cell_mid(at), mirror(MapGrid.cell_mid(at))]


## On the axis: the footprint straddles cells HALF-2..HALF+1, on ground of
## one level -- the plateau or the ground the seed meant for it, else either.
func _place_monastery() -> void:
	# Nearest where it was meant to go, on the level the seed gave it if it fits.
	var base_row := -1
	for want in [1 if _raised else 0, -1]:
		for dy in H:
			for base in [_centre_row + dy, _centre_row - dy]:
				if base_row < 0 and base > BORDER + MONASTERY_CELLS.y and base < H - BORDER - DOOR_YARD - 1 \
						and _monastery_fits(base, want):
					base_row = base
		if base_row >= 0:
			break
	if base_row < 0:
		base_row = H / 2
	monastery = Vector2(HALF * T, (base_row + 1) * T)
	door = monastery + Vector2(0, DOOR_DROP)
	for y in range(base_row - MONASTERY_CELLS.y + 1, base_row + 1):
		for x in range(HALF - 2, HALF + 2):
			_blocked[Vector2i(x, y)] = true


## The footprint and its yard on the base row given, all flat ground of one
## level (`want`, or any with -1).
func _monastery_fits(base: int, want: int) -> bool:
	var level := int(height.get(Vector2i(HALF - 1, base), -1))
	if want >= 0 and level != want:
		return false
	for y in range(base - MONASTERY_CELLS.y + 1, base + DOOR_YARD + 1):
		for x in range(HALF - 2, HALF + 2):
			var c := Vector2i(x, y)
			if not _flat(c) or int(height[c]) != level:
				return false
	return true


func _place_monks() -> void:
	var pairs := monk_count / 2
	var spawn := MapGrid.cell_at(spawns[0])
	var door_cell := MapGrid.cell_at(door)
	var spots: Array[Vector2i] = []
	for c: Vector2i in _cells():
		if c.x >= 3 and c.x < HALF - 3 and _flat(c) and not _blocked.has(c) and not trail.has(c) and _room(c, 1):
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
			if _flat(c) and _flat(c + Vector2i.LEFT) and height[c] == height[c + Vector2i.LEFT]:
				monks.append(Vector2(HALF * T, c.y * T + T * 0.5))
				break


## Blue's houses beside its spawn, Red's mirrored: the pair and its yard on
## flat ground, off the spawn's yard and every other building.
func _place_houses() -> void:
	var spawn := MapGrid.cell_at(spawns[0])
	var best := Vector2i(-1, -1)
	var best_score := INF
	for base: Vector2i in MapGrid.rings(spawn, HOUSE_LOOK):
		var score := _dist(base + Vector2i(2, 0), spawn) + (4.0 if base.x + 4 > spawn.x else 0.0)
		if score < best_score and _houses_fit(base, spawn):
			best = base
			best_score = score
	if best.x < 0:
		return
	var variant := _rng.randi_range(1, 3)
	for i in 2:
		var base := best + Vector2i(HOUSE_STEP * i, 0)
		for c in _footprint(base, HOUSE_CELLS):
			_blocked[c] = true
			_blocked[mirror_cell(c)] = true
		var at := Vector2(base.x * T + T, (base.y + 1) * T)
		houses.append({"at": at, "team": 0, "variant": variant})
		houses.append({"at": mirror(at), "team": 1, "variant": variant})
		variant = variant % 3 + 1
	for c in _house_yard(best):
		trail[c] = true


## The pair with its left house's bottom-left cell at `base`: both houses
## on flat ground off the spawn's yard and other buildings, their yard on
## ground that can be walked.
func _houses_fit(base: Vector2i, spawn: Vector2i) -> bool:
	for i in 2:
		for c in _footprint(base + Vector2i(HOUSE_STEP * i, 0), HOUSE_CELLS):
			if not _flat(c) or int(height[c]) != 0 or _blocked.has(c) or _dist(c, spawn) <= SPAWN_YARD:
				return false
	for c in _house_yard(base):
		if not _reach.has(c) or int(height[c]) != 0 or _g.cliff.has(c) or _g.stairs.has(c) \
				or c.x >= HALF - 3:
			return false
	return true


func _house_yard(base: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(base.y - HOUSE_CELLS.y, base.y + HOUSE_FRONT + 1):
		for x in range(base.x - 1, base.x + HOUSE_STEP + HOUSE_CELLS.x + 1):
			out.append(Vector2i(x, y))
	return out


## Clearings from Blue's spawn to the door and to each monk on its side, three
## cells wide, then mirrored. Blue reaches Red's side through the door's
## clearing and Red's own; nothing stands on any of them.
func _carve_trails() -> void:
	var spawn := MapGrid.cell_at(spawns[0])
	var targets: Array[Vector2i] = [MapGrid.cell_at(door)]
	for i in monk_count / 2:
		targets.append(MapGrid.cell_at(monks[i]))
	for t in targets:
		for c in _g.route(spawn, 0, t, _blocked):
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
		if c.x >= HALF or not land.has(c) or trail.has(c) or _blocked.has(c) or not _flat(c):
			continue
		# Rounded first: it is checked where it will stand, a half-pixel off is a cell.
		var p := (MapGrid.cell_mid(c) + Vector2(_rng.randf_range(-12, 12), _rng.randf_range(-12, 12))).round()
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


## Its boxes on flat ground of its own level that is not a clearing, in the
## left half with room to spare at the axis (its mirror must not meet it), and
## clear of the props near it.
func _fits(kind: String, at: Vector2, rects: Array[Rect2], placed: Array, hash: Dictionary) -> bool:
	var home := MapGrid.cell_at(at)
	if not _flat(home):
		return false
	var level := int(height[home])
	for r in rects:
		if r.end.x > HALF * T - 6.0:
			return false
		for c in _under(r):
			if not _flat(c) or int(height[c]) != level or trail.has(c) or _blocked.has(c):
				return false
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
		if c.x < HALF - 1 and _flat(c) and not _blocked.has(c) and not _near_monk(c):
			spots.append(c)
	_shuffle(spots)
	for i in mini(BUSHES, spots.size()):
		var at := MapGrid.cell_mid(spots[i]) + Vector2(_rng.randf_range(-10, 10), _rng.randf_range(-8, 8))
		var b := {"at": at.round(), "v": _rng.randi_range(1, 4), "flip": -1.0 if _rng.randf() < 0.5 else 1.0}
		bushes.append(b)
		bushes.append({"at": mirror(b.at), "v": b.v, "flip": -float(b.flip)})


## Rocks in the sea, a few cells off the coast and apart from each other.
## Checked where they are drawn, not where they stand: the art sits well
## above and either side of its point (`water_rock_box`), and every cell under
## it, and round those, is open sea -- no land, no cliff.
func _scatter_water_rocks() -> void:
	var spots: Array[Vector2i] = []
	for c: Vector2i in _cells():
		if c.x < HALF - 2 and not land.has(c):
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
		var r := {"at": MapGrid.cell_mid(c), "v": _rng.randi_range(1, 4), "flip": -1.0 if _rng.randf() < 0.5 else 1.0}
		var box := water_rock_box(r.v, r.at, r.flip)
		var near := false
		for d in _disc(MapGrid.cell_at(box.get_center()), 3):
			near = near or land.has(d)
		if not apart or not near:
			continue
		var open := true
		for k in _under(box):
			for d in _disc(k, 1):
				open = open and not land.has(d) and not _g.cliff.has(d)
		if not open:
			continue
		kept.append(c)
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


## Ground to stand a thing on: reached from the spawns, and one level all
## round -- no shore, cliff face, ramp or level's edge within a cell.
func _flat(c: Vector2i) -> bool:
	if not _reach.has(c):
		return false
	var level := int(height[c])
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var k := c + Vector2i(dx, dy)
			if int(height.get(k, -1)) != level or _g.cliff.has(k) or _g.stairs.has(k):
				return false
	return true


## Flat ground of `c`'s level for `r` cells round it.
func _room(c: Vector2i, r: int) -> bool:
	if not _flat(c):
		return false
	for d in _disc(c, r):
		if not _flat(d) or height[d] != height[c]:
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


static func _parts(cells: Dictionary) -> Array:
	var seen := {}
	var out: Array = []
	for c: Vector2i in cells:
		if not seen.has(c):
			var part := _flood(c, cells)
			seen.merge(part)
			out.append(part)
	return out


static func _grow(cells: Dictionary) -> Dictionary:
	var out := cells.duplicate()
	for c: Vector2i in cells:
		for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			out[c + d] = true
	return out


static func _erode(cells: Dictionary) -> Dictionary:
	var out := {}
	for c: Vector2i in cells:
		if cells.has(c + Vector2i.LEFT) and cells.has(c + Vector2i.RIGHT) \
				and cells.has(c + Vector2i.UP) and cells.has(c + Vector2i.DOWN):
			out[c] = true
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


## Every cell `r` covers: a box may be wider than a cell. Its far edges are
## not in it, or an edge on a cell line would take one cell more on the left
## than its mirror does on the right.
static func _under(r: Rect2) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var a := MapGrid.cell_at(r.position)
	var b := MapGrid.cell_at(r.end - Vector2(0.01, 0.01))
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			out.append(Vector2i(x, y))
	return out


## Where water rock `v` at `at` is drawn: its art's opaque box over all its
## frames, placed as MapWorld draws it (Art.anim_sprite: the frame's bottom
## centre at `at`, at WATER_ROCK_SCALE, mirrored by `flip`).
static func water_rock_box(v: int, at: Vector2, flip: float) -> Rect2:
	if not _rock_art.has(v):
		var img := Art.tex(MapWorld.WATER_ROCK % v).get_image()
		if img.is_compressed():
			img.decompress()
		var fw := img.get_width() / 16
		var used := Rect2i()
		for f in 16:
			var r := img.get_region(Rect2i(f * fw, 0, fw, img.get_height())).get_used_rect()
			used = r if used.size == Vector2i.ZERO else used.merge(r)
		var k := MapWorld.WATER_ROCK_SCALE
		_rock_art[v] = Rect2((Vector2(used.position) - Vector2(fw * 0.5, img.get_height())) * k,
			Vector2(used.size) * k)
	var box: Rect2 = _rock_art[v]
	if flip < 0.0:
		box.position.x = -box.end.x
	box.position += at
	return box


static func _rects_at(name: String, at: Vector2, flip: float) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for r: Rect2 in _feet[name]:
		var x := r.position.x if flip > 0.0 else -r.end.x
		out.append(Rect2(at + Vector2(x, r.position.y), r.size))
	return out

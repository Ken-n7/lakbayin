class_name MapBuilder
extends RefCounted

## Builds the ground and works out the walk: the water and grass layers, the
## four islands, the authored trails stamped over them, and where every stop
## along the board stands.
##
## The path is authored and the island is generated, so the two can disagree --
## which is why the walk is stamped as land before the autotile pass paints the
## shoreline. Everything here writes into `MapGrid`; nothing else reads the
## tilemaps directly.

var world: Node2D
var grid: MapGrid
var grass: TileMapLayer
var water: TileMapLayer


func _init(w: Node2D, g: MapGrid) -> void:
	world = w
	grid = g


# --- Terrain ----------------------------------------------------------------
func build_terrain() -> void:
	water = Art.terrain_layer(MapCfg.WATER_BG, MapCfg.TILE, [Vector2i(0, 0)])
	world.add_child(water)
	for gy in MapCfg.WORLD_H:
		for gx in MapCfg.WORLD_W:
			water.set_cell(Vector2i(gx, gy), 0, Vector2i(0, 0))
	grass = Art.terrain_layer(MapCfg.TILEMAP_COLOR, MapCfg.TILE)
	world.add_child(grass)
	grid.grass = grass
	world.set_meta("grass", grass)
	world.set_meta("tile", MapCfg.TILE)


func build_island() -> void:
	for y in MapCfg.WORLD_H:
		for x in MapCfg.WORLD_W:
			var cell := Vector2i(x, y)
			var i := MapGrid.island_index(cell)
			if i >= 0:
				grid.land[cell] = true
				grid.island_of[cell] = i
	_stamp_path()
	retile(grid.land.keys())


## Paint (or erase) a set of cells and their four neighbours from the current land
## set. Runs over the whole island at build time -- the shoreline either side of
## new ground has to be repainted or the foam still says "water here".
func retile(cells: Array) -> void:
	var todo := {}
	for c in cells:
		todo[c] = true
		for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
			if MapGrid.in_bounds(c + d):
				todo[c + d] = true
	for c in todo:
		if not grid.land.has(c):
			grass.erase_cell(c)
			grid.beach.erase(c)
			continue
		var up: bool = grid.land.has(c + Vector2i(0, -1))
		var down: bool = grid.land.has(c + Vector2i(0, 1))
		var left: bool = grid.land.has(c + Vector2i(-1, 0))
		var right: bool = grid.land.has(c + Vector2i(1, 0))
		if up and down and left and right:
			grid.beach.erase(c)
		else:
			grid.beach[c] = true
		# Cols 0-3 are the foam-outlined land-meets-water set, so the shoreline
		# is baked into the tile itself and reads the same on all four sides.
		grass.set_cell(c, 0, Art.autotile(left, right, up, down))


# --- The trails -------------------------------------------------------------
## How many stops each TRAIL carries -- not each island. The camp's trail holds the
## base camp and Station 1, whose briefing opens the road out of camp; the
## crossing between them is the land bridge, so the trail spans two islands and
## Station 1 stands on island 1's ground. Trail `i` then holds station `i - 1`'s
## circles, and stations 2 and 3 keep their own towers. The last one also holds the
## Victory Gate.
##
## Flattened, that is still the same walk order it always was:
## camp, S1, its circles, S2, its circles, S3, its circles, gate.
func _stops_on(i: int) -> int:
	if i == 0:
		return 2                                  # base camp, then Station 1
	var n: int = int(Game.ITEMS_PER_STATION[i - 1])
	if i > 1:
		n += 1                                    # that station's own tower
	if i == MapCfg.TRAILS.size() - 1:
		n += 1                                    # victory gate
	return n


## `stops` points spaced evenly by arc length along a normalized polyline, both
## ends included.
static func _space_along(way: Array, stops: int) -> Array:
	var pts: Array[Vector2] = []
	for p in way:
		pts.append(MapGrid.norm(p))
	var segs: Array[float] = []
	var total := 0.0
	for i in pts.size() - 1:
		var d := pts[i].distance_to(pts[i + 1])
		segs.append(d)
		total += d
	var out: Array = []
	for k in stops:
		var want := total * float(k) / float(maxi(stops - 1, 1))
		var acc := 0.0
		var at: Vector2 = pts[pts.size() - 1]
		for i in segs.size():
			if want <= acc + segs[i] or i == segs.size() - 1:
				at = pts[i].lerp(pts[i + 1], clampf((want - acc) / segs[i], 0.0, 1.0))
				break
			acc += segs[i]
		out.append(at)
	return out


## Every stop on the board, flat, in the global walk order the rest of the file
## indexes by: base camp, Station 1, its circles, Station 2, its circles, Station
## 3, its circles, Victory Gate -- spread over three islands instead of one
## serpentine. The spacing that matters is ~270px at the tightest, far wider than
## INTERACT_RADIUS, which is what keeps "the circle you are standing on"
## unambiguous.
func path_anchors() -> Array:
	var out: Array = []
	for i in MapCfg.TRAILS.size():
		out.append_array(_space_along(MapCfg.TRAILS[i], _stops_on(i)))
	return out


## Which TRAIL a stop belongs to. Indexed by anchor rather than by station, because
## Station 1 rides the camp's trail while its circles ride island 1's. Everything
## that needs "outward from my own island" asks this; for Station 1 that means the
## camp's centre, which is the right answer -- it is the stop nearest the camp.
func island_of_anchor(k: int) -> int:
	var seen := 0
	for i in MapCfg.TRAILS.size():
		seen += _stops_on(i)
		if k < seen:
			return i
	return MapCfg.TRAILS.size() - 1


## Anchor index of each tower: one before each station's run of circles.
func tower_anchors() -> Array:
	var out: Array = []
	var k := 1                       # anchor 0 is the base camp
	for st in Game.ITEMS_PER_STATION.size():
		out.append(k)
		k += 1 + Game.ITEMS_PER_STATION[st]
	return out


## Which way a building steps off the path: straight up on a lane, outward when
## the anchor sits on a bend. It has to be perpendicular to the walk, or the wall
## covers the next stop -- and its footprint is axis-aligned, so on a vertical
## bend "up" would put the wall right across the path.
##
## `up` and `side` differ because the wall is axis-aligned. Stepping *up* only
## has to clear the anchor vertically, and the wall sits above it at any positive
## lift. Stepping *sideways* has to clear it horizontally, so the lift has to
## beat the widest building's wall half-width or the wall reaches back over the
## doorstep.
func _lift(k: int, up: float, side: float) -> Vector2:
	var a: Vector2 = grid.anchors[maxi(k - 1, 0)]
	var b: Vector2 = grid.anchors[mini(k + 1, grid.anchors.size() - 1)]
	var dir := (b - a).normalized()
	if absf(dir.x) >= absf(dir.y):
		return Vector2(0, -up)
	# Outward from its own island's centre -- against the world centre it would
	# step the middle island's tower into the sea.
	var mid := MapGrid.norm(MapCfg.ISLANDS[island_of_anchor(k)].c)
	return Vector2(signf(grid.anchors[k].x - mid.x) * side, 0)


func tower_lift(k: int) -> Vector2:
	return _lift(k, MapCfg.TOWER_LIFT, MapCfg.TOWER_LIFT)


## Much closer in than a keep: the player stands on the anchor to answer, so a
## full TOWER_LIFT leaves the glowing spot stranded half a tower from the door
## it belongs to. Sideways needs more room than up -- enough to beat
## Yellow_Archery's 28px wall half-width once `PathCircle.WALL_WIDTH_FRAC`
## trims it to the base.
func circle_lift(k: int) -> Vector2:
	return _lift(k, MapCfg.CIRCLE_LIFT, MapCfg.CIRCLE_SIDE_LIFT)


## The path is authored, the island is generated, so the two can disagree: force
## land under the whole walk (three cells wide) before the autotile pass paints
## the shoreline, and the board is never cut by a stray inlet.
func _stamp_path() -> void:
	for t in MapCfg.TRAILS.size():
		var way: Array = MapCfg.TRAILS[t]
		_stamp_way(way, t, true)
		if t + 1 >= MapCfg.TRAILS.size():
			continue
		# The hop on to the next trail is walk as well, so it is road for the decor
		# pass either way. It is only *ground* where that seam is bridged -- on an
		# unbridged one there would be nothing to walk on, which is what makes a
		# seam left out of BRIDGED_SEAMS fail loudly rather than quietly.
		var next: Array = MapCfg.TRAILS[t + 1]
		_stamp_way([way[way.size() - 1], next[0]], t + 1, MapCfg.BRIDGED_SEAMS.has(t))
	# The towers step off the path, so their ground has to be stamped as well or
	# one ends up standing in the shallows at a bend.
	_stamp_towers()


## Land (three cells wide) under a polyline, and the corridor recorded in `grid.trail`
## either way: `_build_decor()` plants nothing in it, which is what makes the walk
## read as a road through the trees rather than a line of towers lost in them.
func _stamp_way(way: Array, isl: int, ground: bool) -> void:
	for i in way.size() - 1:
		var a := MapGrid.norm(way[i])
		var b := MapGrid.norm(way[i + 1])
		var steps := maxi(int(a.distance_to(b) / MapCfg.STAMP_STEP), 1)
		for k in steps + 1:
			var pos := a.lerp(b, float(k) / float(steps))
			var c := MapGrid.cell_at(pos)
			for oy: int in MapCfg.STAMP_RING:
				for ox: int in MapCfg.STAMP_RING:
					var cc := c + Vector2i(ox, oy)
					if not MapGrid.in_bounds(cc):
						continue
					grid.trail[cc] = true
					if not ground:
						continue
					# Only ground the walk invents belongs to the walk: the camp
					# trail crosses island 1's east spit to reach Station 1, and
					# relabelling those cells island 0 would dress the spit with
					# the camp's props.
					if not grid.land.has(cc):
						grid.island_of[cc] = isl
					grid.land[cc] = true


func _stamp_towers() -> void:
	for k in tower_anchors():
		var base: Vector2 = grid.anchors[k] + tower_lift(k)
		var bc := MapGrid.cell_at(base)
		var isl := island_of_anchor(k)
		for oy in range(MapCfg.TOWER_PAD_Y.x, MapCfg.TOWER_PAD_Y.y):
			for ox in range(MapCfg.TOWER_PAD_X.x, MapCfg.TOWER_PAD_X.y):
				var cc := bc + Vector2i(ox, oy)
				if MapGrid.in_bounds(cc):
					if not grid.land.has(cc):
						grid.island_of[cc] = isl
					grid.land[cc] = true

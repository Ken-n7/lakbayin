class_name MapGrid
extends RefCounted

## What is where on the board: which cells are land, which are shore, which are
## road, which are already taken by a prop -- and every question anyone asks of
## that.
##
## Before this existed these were seven bare dictionaries and arrays on
## `AdventureScreen`, two of them declared 900 lines from the other five, read
## and written by terrain, path, stations, barricades and decor alike. Anything
## that wanted to know "can a man stand here" reached into the lot of them.
##
## Nothing here builds anything. `MapBuilder`, `Stations`, `Barricades` and
## `Decor` fill it in and read it back; the screen asks it about walkability.

# --- Cells ------------------------------------------------------------------
var land := {}        # Vector2i -> true
var beach := {}       # Vector2i -> true, land with water on at least one side
var island_of := {}   # Vector2i -> island index, for the per-island decor pass
var trail := {}       # Vector2i -> true, the road corridor: decor keeps off it
var taken := {}       # Vector2i -> true, cells a prop already stands on
var height := {}      # Vector2i -> level: 0 the ground, 1 a terrace, 2 the summit
var cliff := {}       # Vector2i -> level, the cliff face under that level's south edge
var stairs := {}      # Vector2i -> {low, tile, top, side}: a ramp's two cells, low and low+1 meet

# --- Boxes, in world px -----------------------------------------------------
var solid: Array[Rect2] = []          # walls: buildings, boulders, guards
var station_rects: Array[Rect2] = []  # keep-outs the decor pass avoids
var sign_rects: Array[Rect2] = []     # the station signboards, specifically

## The walk, in order: base camp, then each station's tower and its circles,
## then the Victory Gate. Owned here because it is the one thing every
## footprint has to be checked against -- nothing the player must stand on may
## end up inside a wall.
var anchors: Array = []

## The grass layer. Walkability asks `land`, which is exactly what it is
## painted from -- and is there before the paint, when Terrain checks its work.
var grass: TileMapLayer = null


# --- Conversions ------------------------------------------------------------
## A normalized (0..1) point to world px.
static func norm(p: Vector2) -> Vector2:
	return Vector2(p.x * MapCfg.WORLD_W * MapCfg.TILE, p.y * MapCfg.WORLD_H * MapCfg.TILE)


static func cell_at(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / MapCfg.TILE), floori(pos.y / MapCfg.TILE))


static func cell_mid(c: Vector2i) -> Vector2:
	return Vector2(c.x * MapCfg.TILE + MapCfg.TILE / 2, c.y * MapCfg.TILE + MapCfg.TILE / 2)


static func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < MapCfg.WORLD_W and c.y < MapCfg.WORLD_H


## `c`, then the cells one step out, then two, ... out to `radius`.
static func rings(c: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = [c]
	for r in range(1, radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) == r:
					out.append(c + Vector2i(dx, dy))
	return out


# --- Questions --------------------------------------------------------------
## Can something stand at `pos` at the level of the ground there: clear of
## walls, on land, not in a cliff face.
func is_walkable(pos: Vector2) -> bool:
	for r in solid:
		if r.has_point(pos):
			return false
	var c := cell_at(pos)
	return land.has(c) and not cliff.has(c)


## May a walker at `level` stand in `c`? Ground of that height takes them; a
## ramp takes either of the two levels it joins; a cliff takes nobody. A
## walker on a ramp now (`stair_low` its lower level, else -1) may step off it
## onto either level.
func cell_ok(c: Vector2i, level: int, stair_low := -1) -> bool:
	if not land.has(c) or cliff.has(c):
		return false
	if stairs.has(c):
		var low := int(stairs[c].low)
		return level == low or level == low + 1 or stair_low == low
	var h := int(height.get(c, 0))
	if stair_low >= 0:
		return h == stair_low or h == stair_low + 1
	return h == level


## The level after standing at `pos`: the ground's own height, or on a ramp,
## whatever it was.
func level_at(pos: Vector2, was: int) -> int:
	var c := cell_at(pos)
	if stairs.has(c):
		return was
	return int(height.get(c, 0))


## The lower level of the ramp at `pos`, or -1 off one.
func stair_low_at(pos: Vector2) -> int:
	var c := cell_at(pos)
	return int(stairs[c].low) if stairs.has(c) else -1


## Every cell reachable from `from` starting at `level`, walking as the hero
## does: by level, up and down ramps, round walls (tested at cell middles).
## `ground_only` never changes level -- the board as it is with no stairs.
func flood(from: Vector2, level: int, ground_only := false) -> Dictionary:
	var start := cell_at(from)
	var seen := {Vector3i(start.x, start.y, level): true}
	var cells := {start: true}
	var queue: Array[Vector3i] = [Vector3i(start.x, start.y, level)]
	while not queue.is_empty():
		var k: Vector3i = queue.pop_back()
		var c := Vector2i(k.x, k.y)
		var low := -1 if ground_only or not stairs.has(c) else int(stairs[c].low)
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			var p := cell_mid(n)
			if not cell_ok(n, k.z, low):
				continue
			var blocked := false
			for r in solid:
				if r.has_point(p):
					blocked = true
					break
			if blocked:
				continue
			var nl := k.z if ground_only else level_at(p, k.z)
			var nk := Vector3i(n.x, n.y, nl)
			if not seen.has(nk):
				seen[nk] = true
				cells[n] = true
				queue.append(nk)
	return cells


## Can the hero stand at `pos`? `box` is their Foot box, relative to their
## feet (scenes/Hero.tscn): clear of every wall, and all four corners on
## ground they may stand on at `level` (see `cell_ok`). A point check let the
## hero's feet squeeze between two rocks 6px apart.
func box_walkable(pos: Vector2, box: Rect2, level := 0, stair_low := -1) -> bool:
	var r := Rect2(box.position + pos, box.size)
	for w in solid:
		if w.intersects(r):
			return false
	for corner in [r.position, Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), r.end]:
		var c := cell_at(corner)
		if not cell_ok(c, level, stair_low):
			return false
		if stairs.has(c) and not on_ramp(corner, c):
			return false
	# A man is wider than his feet: keep them a little off a cliff face
	# beside him, or half of him is drawn over the rock -- except on the
	# landing under a ramp's foot, which may be no wider than the ramp.
	var m := MapCfg.CLIFF_SIDE_MARGIN
	for p in [Vector2(r.position.x - m, r.position.y), Vector2(r.position.x - m, r.end.y),
			Vector2(r.end.x + m, r.position.y), Vector2(r.end.x + m, r.end.y)]:
		if cliff.has(cell_at(p)) and not stairs.has(cell_at(Vector2(clampf(p.x, r.position.x, r.end.x), p.y)) + Vector2i(0, -1)):
			return false
	return true


## Whether `p`, in ramp cell `c`, is on the ramp's grass rather than the open
## corner of its top tile or the rock of its foot -- measured off the art
## (Tilemap row 4-5, cols 0 and 3). In the ramp's own frame: x from its low
## side (0) to its high side (32), y from the top tile's top (0) to the foot's
## bottom (64).
func on_ramp(p: Vector2, c: Vector2i) -> bool:
	var span := _ramp_span(c, p.y)
	var x := _ramp_x(c, p.x)
	return x >= span.x and x <= span.y


## World x of the middle of the ramp's grass at height `y`: where going up or
## down it steers the hero (`AdventureScreen._slip`).
func ramp_mid_x(c: Vector2i, y: float) -> float:
	var span := _ramp_span(c, y)
	return c.x * MapCfg.TILE + _flip(c, (span.x + span.y) * 0.5)


## World x into the ramp's frame.
func _ramp_x(c: Vector2i, x: float) -> float:
	return _flip(c, x - c.x * MapCfg.TILE)


## The frame runs low side to high side; a ramp with its high ground to the
## left runs mirrored. Its own inverse.
func _flip(c: Vector2i, x: float) -> float:
	return MapCfg.TILE - x if int(stairs[c].side) > 0 else x


## The grass's [from, to] across the ramp's frame at world height `y`.
func _ramp_span(c: Vector2i, y: float) -> Vector2:
	var t := float(MapCfg.TILE)
	var top_y := float(c.y if bool(stairs[c].top) else c.y - 1) * t
	var ry := clampf(y - top_y, 4.0, t * 2.0)
	if ry < t:
		return Vector2(maxf(0.0, t - 1.0 - (ry - 4.0)), t)   # the slope's edge, 45 degrees
	if ry < t * 1.6:
		return Vector2(0.0, maxf(20.0, t - (ry - t)))         # the foot narrows toward the rock
	return Vector2(0.0, 16.0)


static func clear_of(r: Rect2, boxes: Array) -> bool:
	for b: Rect2 in boxes:
		if r.intersects(b):
			return false
	return true


## A station is a building, a signboard off one side and a keeper off the
## other, so a single radius either lets trees land on the board or blanks out
## half the island. Each keep-out box is checked on its own, shrunk by a tile:
## touching a station's outermost cell is close enough to plant.
func clear_of_buildings(r: Rect2) -> bool:
	for b: Rect2 in station_rects:
		var box := b.grow(-MapCfg.TILE)
		# A box that was only the margin has nothing left to stand clear of, and
		# Rect2 will not take a negative size.
		if box.size.x > 0.0 and box.size.y > 0.0 and box.intersects(r):
			return false
	return true


func clear_of_signs(r: Rect2) -> bool:
	return clear_of(r, sign_rects)


## Nothing the player has to stand on may end up inside a wall.
func clear_of_anchors(rect: Rect2) -> bool:
	var r := rect.grow(MapCfg.ANCHOR_CLEARANCE)
	for a in anchors:
		if r.has_point(a):
			return false
	return true


# --- Writing ----------------------------------------------------------------
func block(r: Rect2) -> void:
	solid.append(r)


func keep_out(r: Rect2) -> void:
	station_rects.append(r)


## The keep-out box round a base-anchored building: its footprint plus a tile of
## breathing room. Written once because the gate, each station keep and each
## outpost house all wanted the same four terms and each spelled them out.
static func building_keepout(base: Vector2, hw: float, bh: float) -> Rect2:
	var pad := MapCfg.KEEPOUT_PAD
	return Rect2(Vector2(base.x - (hw + pad), base.y - (bh + pad)),
			Vector2(hw * 2.0 + pad * 2.0, bh + pad * 2.0))

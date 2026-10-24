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
var stairs := {}      # Vector2i -> {low, top, side, row}: a ramp's three cells
                      # (rows 0-2: top, middle, foot), where low and low+1 meet;
                      # side -1 when the high ground is to its right

# --- Boxes, in world px -----------------------------------------------------
var solid: Array[Rect2] = []          # walls: buildings, boulders, guards
var rails: Array[Rect2] = []          # the walls round each ramp's top, also in `solid`
var station_rects: Array[Rect2] = []  # keep-outs the decor pass avoids
var sign_rects: Array[Rect2] = []     # the station signboards, specifically


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
## onto either level -- or onto the ramp up from its top, where two stand one
## above the other and the upper one's foot is the lower one's landing.
func cell_ok(c: Vector2i, level: int, stair_low := -1) -> bool:
	if not land.has(c) or cliff.has(c):
		return false
	if stairs.has(c):
		var low := int(stairs[c].low)
		return level == low or level == low + 1 or stair_low == low \
			or (stair_low >= 0 and stair_low + 1 == low)
	var h := int(height.get(c, 0))
	if stair_low >= 0:
		return h == stair_low or h == stair_low + 1
	return h == level


## The level after standing at `pos`: the ground's own height, or on a ramp,
## whatever it was -- one of the two it joins.
func level_at(pos: Vector2, was: int) -> int:
	var c := cell_at(pos)
	if stairs.has(c):
		return clampi(was, int(stairs[c].low), int(stairs[c].low) + 1)
	return int(height.get(c, 0))


## The lower level of the ramp at `pos`, or -1 off one.
func stair_low_at(pos: Vector2) -> int:
	var c := cell_at(pos)
	return int(stairs[c].low) if stairs.has(c) else -1


## One step of a walker from `pos` by `d` (at most 2px, or a thin rail is
## jumped), one axis at a time so a diagonal into a wall slides along it.
## Returns [where it ends, the level it is on].
func step(pos: Vector2, d: Vector2, box: Rect2, level: int) -> Array:
	# Set down somewhere new (a test, a rejoin): the level of the ground there.
	if not cell_ok(cell_at(pos), level, stair_low_at(pos)):
		level = level_at(pos, level)
	var low := stair_low_at(pos)
	pos.x += d.x
	if not box_walkable(pos, box, level, low):
		pos.x -= d.x
	pos.y += d.y
	if not box_walkable(pos, box, level, low):
		pos.y -= d.y
		pos = _slip(pos, d.y, box, level, low)
	return [pos, level_at(pos, level)]


## On a ramp, up and down follow the slope: a step up or down the ramp's edge
## stops is steered toward the middle of its grass instead. At the top, up
## steps off onto the high ground; beside a ramp's top, down steps onto it --
## so straight up or down takes the whole stair.
func _slip(here: Vector2, dy: float, box: Rect2, level: int, low: int) -> Vector2:
	var at := cell_at(here)
	var c := Vector2i(-1, -1)
	# Where the feet are, where they step, and the box's leading edge: walking
	# straight at a foot, the box meets the ramp's rock before the feet do.
	var edge := box.position.y if dy < 0.0 else box.end.y
	for k in [at, cell_at(here + Vector2(0, dy)), cell_at(here + Vector2(0, dy + edge))]:
		if stairs.has(k):
			c = k
			break
	# ...or on the high ground at a ramp's top: that ramp, not a neighbour's foot.
	var beside := false
	for k in [at + Vector2i(-1, 0), at + Vector2i(1, 0)]:
		if c.x < 0 and stairs.has(k) and bool(stairs[k].top) \
				and k - Vector2i(int(stairs[k].side), 0) == at:
			c = k
			beside = true
	if c.x < 0:
		return here
	var d := absf(dy)
	var high := -float(stairs[c].side)          # which way the high ground is
	# Just off the top, the box still part over the ramp's back: on, onto the
	# high ground -- and no further than clear of the ramp. Steering to the
	# ramp's middle here pulled the hero back onto its back and he stuck.
	if beside and dy < 0.0:
		var feet := Rect2(box.position + here, box.size)
		if feet.intersects(Rect2(Vector2(c) * MapCfg.TILE, Vector2.ONE * MapCfg.TILE)) \
				and box_walkable(here + Vector2(high * d, 0.0), box, level, low):
			return here + Vector2(high * d, 0.0)
		return here
	var mid := clampf(ramp_mid_x(c, here.y + dy) - here.x, -d, d)
	var tries: Array[Vector2] = []
	if absf(mid) > 0.01:
		tries.append(Vector2(mid, dy))
	# Off at the ends: up from its top onto the high ground, down from its
	# foot out of its open side.
	if stairs.has(at) and bool(stairs[at].top) == (dy < 0.0):
		tries.append(Vector2((high if dy < 0.0 else -high) * d, 0.0))
	if absf(mid) > 0.01:
		tries.append(Vector2(mid, 0.0))
	for n in tries:
		if box_walkable(here + n, box, level, low):
			return here + n
	return here


## Every cell reachable from `from` starting at `level`, walking as the hero
## does: by level, up and down ramps, round walls (`next_states`).
## `ground_only` never changes level -- the board as it is with no stairs.
func flood(from: Vector2, level: int, ground_only := false) -> Dictionary:
	var walls := wall_cells()
	var start := cell_at(from)
	var seen := {Vector3i(start.x, start.y, level): true}
	var cells := {start: true}
	var queue: Array[Vector3i] = [Vector3i(start.x, start.y, level)]
	while not queue.is_empty():
		for n in next_states(queue.pop_back(), walls, ground_only):
			if not seen.has(n):
				seen[n] = true
				cells[Vector2i(n.x, n.y)] = true
				queue.append(n)
	return cells


## The shortest walk from cell `a` at `level` to cell `b`: its cells, both
## ends included; empty if there is none.
func route(a: Vector2i, level: int, b: Vector2i, walls := {}) -> Array[Vector2i]:
	var start := Vector3i(a.x, a.y, level)
	var from := {start: start}
	var queue: Array[Vector3i] = [start]
	var head := 0
	var out: Array[Vector2i] = []
	while head < queue.size():
		var k := queue[head]
		head += 1
		if k.x == b.x and k.y == b.y:
			while k != start:
				out.append(Vector2i(k.x, k.y))
				k = from[k]
			out.append(a)
			out.reverse()
			return out
		for n in next_states(k, walls):
			if not from.has(n):
				from[n] = k
				queue.append(n)
	return out


## Where a walker in cell (k.x, k.y) at level k.z can step next, as
## (cell, level): onto ground it may stand on (`cell_ok`) whose middle no wall
## covers (`walls`, from `wall_cells`), across no ramp's rail.
func next_states(k: Vector3i, walls: Dictionary, ground_only := false) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var c := Vector2i(k.x, k.y)
	var low := -1 if ground_only or not stairs.has(c) else int(stairs[c].low)
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = c + d
		if walls.has(n) or not cell_ok(n, k.z, low):
			continue
		var edge := (cell_mid(c) + cell_mid(n)) * 0.5
		var railed := false
		for r in rails:
			if r.has_point(edge):
				railed = true
		if railed:
			continue
		out.append(Vector3i(n.x, n.y, k.z if ground_only else level_at(cell_mid(n), k.z)))
	return out


## The cells whose middle a wall covers, laid onto cells once: testing every
## wall at every step of a walk took minutes for a whole world.
func wall_cells() -> Dictionary:
	var out := {}
	for r in solid:
		var a := cell_at(r.position)
		var b := cell_at(r.end)
		for y in range(a.y, b.y + 1):
			for x in range(a.x, b.x + 1):
				if r.has_point(cell_mid(Vector2i(x, y))):
					out[Vector2i(x, y)] = true
	return out


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
## corner of its top or the rock of its foot -- measured off the art (rows
## 6-8 of the level sheets, tools/make_tall_ramp.py). In the ramp's own frame:
## x from its low side (0) to its high side (32), y from the top's top (0) to
## the foot's bottom (96).
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


## The grass's [from, to] across the ramp's frame at world height `y`: the
## slanted top, the middle all grass, the foot narrowing to its rock.
func _ramp_span(c: Vector2i, y: float) -> Vector2:
	var t := float(MapCfg.TILE)
	var top_y := float(c.y - int(stairs[c].row)) * t
	var ry := clampf(y - top_y, 4.0, t * 3.0)
	if ry < t:
		return Vector2(maxf(0.0, t - 1.0 - (ry - 4.0)), t)   # the slope's edge, 45 degrees
	if ry < t * 2.0:
		return Vector2(0.0, t)                               # the middle row
	ry -= t
	if ry < t * 1.6:
		return Vector2(0.0, maxf(20.0, t - (ry - t)))         # the foot narrows toward the rock
	return Vector2(0.0, 16.0)


## The world rect of the ramp whose top cell is `top`: one cell across, three
## down.
static func ramp_rect(top: Vector2i) -> Rect2:
	var t := float(MapCfg.TILE)
	return Rect2(Vector2(top) * t, Vector2(1.0, 3.0) * t)


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


# --- Writing ----------------------------------------------------------------
func block(r: Rect2) -> void:
	solid.append(r)


func keep_out(r: Rect2) -> void:
	station_rects.append(r)


## A ramp from `low` up to the ground beside it, three cells down from `top`.
## It is climbed from its foot or from the side, and left at its top onto the
## higher ground -- not off its back, or the open side of its slanted top,
## which are air: two thin walls round the top cell.
func lay_ramp(top: Vector2i, low: int, side: int) -> void:
	for row in 3:
		stairs[top + Vector2i(0, row)] = {"low": low, "top": row < 2, "side": side, "row": row}
	for r in _rails_of(top, side):
		block(r)
		rails.append(r)


## The ramp laid at `top`, taken up again, rails and all.
func unlay_ramp(top: Vector2i, side: int) -> void:
	for row in 3:
		stairs.erase(top + Vector2i(0, row))
	for r in _rails_of(top, side):
		solid.erase(r)
		rails.erase(r)


static func _rails_of(top: Vector2i, side: int) -> Array[Rect2]:
	var t := float(MapCfg.TILE)
	var at := Vector2(top) * t
	var x := at.x if side < 0 else at.x + t
	return [Rect2(at + Vector2(0, -2), Vector2(t, 4)), Rect2(Vector2(x - 2, at.y), Vector2(4, t))]


## Under every south edge of every level, the cliff face -- in the cell below,
## over lower ground or the sea -- except where a ramp stands.
func lay_cliffs() -> void:
	cliff.clear()
	for c: Vector2i in height:
		if stairs.has(c):
			continue
		for level in range(1, int(height[c]) + 1):
			var k := c + Vector2i(0, 1)
			if int(height.get(k, -1)) >= level or stairs.has(k):
				continue
			if int(cliff.get(k, 0)) < level:
				cliff[k] = level


## The keep-out box round a base-anchored building: its footprint plus a tile of
## breathing room. Written once because the gate, each station keep and each
## outpost house all wanted the same four terms and each spelled them out.
static func building_keepout(base: Vector2, hw: float, bh: float) -> Rect2:
	var pad := MapCfg.KEEPOUT_PAD
	return Rect2(Vector2(base.x - (hw + pad), base.y - (bh + pad)),
			Vector2(hw * 2.0 + pad * 2.0, bh + pad * 2.0))

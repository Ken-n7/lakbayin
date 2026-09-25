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

# --- Boxes, in world px -----------------------------------------------------
var solid: Array[Rect2] = []          # walls: buildings, boulders, guards
var station_rects: Array[Rect2] = []  # keep-outs the decor pass avoids
var sign_rects: Array[Rect2] = []     # the station signboards, specifically

## The walk, in order: base camp, then each station's tower and its circles,
## then the Victory Gate. Owned here because it is the one thing every
## footprint has to be checked against -- nothing the player must stand on may
## end up inside a wall.
var anchors: Array = []

## The grass layer, for the walkability test. A cell is walkable when it has a
## tile, which after `MapBuilder.retile()` is exactly the `land` set -- but the
## tilemap is what the player actually walks on, so it is what gets asked.
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


## A boulder's wall stands on the boulder, not on the cell it was laid on: the
## art is base-anchored, so a box centred on the cell blocks a tile of open
## grass below the stone and leaves the stone's own top walkable.
static func rock_wall(c: Vector2i) -> Rect2:
	return Rect2(cell_mid(c) - Vector2(MapCfg.ROCK_WALL.x * 0.5,
			MapCfg.ROCK_WALL.y + MapCfg.ROCK_WALL_BASE), MapCfg.ROCK_WALL)


# --- Shape ------------------------------------------------------------------
## Which island a cell belongs to, or -1 for open water. The radial wobble is
## what keeps the coastlines ragged -- a bare ellipse reads as a pond.
static func island_index(cell: Vector2i) -> int:
	var px := (float(cell.x) + 0.5) / float(MapCfg.WORLD_W)
	var py := (float(cell.y) + 0.5) / float(MapCfg.WORLD_H)
	for i in MapCfg.ISLANDS.size():
		var isl: Dictionary = MapCfg.ISLANDS[i]
		var c: Vector2 = isl.c
		var r: Vector2 = isl.r
		var dx := (px - c.x) / r.x
		var dy := (py - c.y) / r.y
		var d := sqrt(dx * dx + dy * dy)
		if d > MapCfg.COAST_REJECT:
			continue
		var ang := atan2(dy, dx)
		var edge := MapCfg.COAST_BASE \
				+ MapCfg.COAST_WAVE1.x * sin(ang * MapCfg.COAST_WAVE1.y + float(isl.wobble)) \
				+ MapCfg.COAST_WAVE2.x * cos(ang * MapCfg.COAST_WAVE2.y + MapCfg.COAST_WAVE2_PHASE)
		if d < edge:
			return i
	return -1


# --- Questions --------------------------------------------------------------
func is_walkable(pos: Vector2) -> bool:
	for r in solid:
		if r.has_point(pos):
			return false
	return grass != null and grass.get_cell_source_id(cell_at(pos)) != -1


## Can the hero stand at `pos`? `box` is their Foot box, relative to their
## feet (scenes/Hero.tscn): clear of every wall, and all four corners on grass.
## A point check let the hero's feet squeeze between two rocks 6px apart.
func box_walkable(pos: Vector2, box: Rect2) -> bool:
	var r := Rect2(box.position + pos, box.size)
	for w in solid:
		if w.intersects(r):
			return false
	for corner in [r.position, Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), r.end]:
		if grass == null or grass.get_cell_source_id(cell_at(corner)) == -1:
			return false
	return true


## Nearest land walking inward from a normalized spot, for props that must not
## end up in the sea.
func first_land(nx: float, ny: float, toward: Vector2) -> Vector2:
	for _tries in MapCfg.LAND_SEARCH_TRIES:
		var c := Vector2i(floori(nx * MapCfg.WORLD_W), floori(ny * MapCfg.WORLD_H))
		if land.has(c):
			return cell_mid(c)
		nx = lerpf(nx, toward.x, MapCfg.LAND_SEARCH_STEP)
		ny = lerpf(ny, toward.y, MapCfg.LAND_SEARCH_STEP)
	return norm(MapCfg.ISLANDS[0].c)


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

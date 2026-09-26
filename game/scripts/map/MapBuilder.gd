class_name MapBuilder
extends RefCounted

## The water and the flat ground: the sea under everything, and the grass
## layer's shoreline autotile over whatever `grid.land` holds. What the land
## is -- the islands, their levels, the walk -- is `map/Terrain.gd`'s.

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
	water.modulate = MapCfg.WATER_TINT
	world.add_child(water)
	var pad := MapCfg.WATER_MARGIN
	for gy in range(-pad, MapCfg.WORLD_H + pad):
		for gx in range(-pad, MapCfg.WORLD_W + pad):
			water.set_cell(Vector2i(gx, gy), 0, Vector2i(0, 0))
	water.z_index = -2
	grass = Art.terrain_layer(MapCfg.TILEMAP_COLOR, MapCfg.TILE)
	world.add_child(grass)
	grid.grass = grass
	world.set_meta("grass", grass)
	world.set_meta("tile", MapCfg.TILE)


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


# --- The walk ---------------------------------------------------------------
## Anchor index of each tower: one before each station's run of circles.
func tower_anchors() -> Array:
	var out: Array = []
	var k := 1                       # anchor 0 is the base camp
	for st in Game.ITEMS_PER_STATION.size():
		out.append(k)
		k += 1 + Game.ITEMS_PER_STATION[st]
	return out

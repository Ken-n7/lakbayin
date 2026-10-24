class_name MapBuilder
extends RefCounted

## The water, the flat ground and the levels raised on it: the sea under
## everything, the grass layer's shoreline autotile over whatever `grid.land`
## holds, then per level a shadow and its ground, cliffs and ramps. What the
## land is -- its shape, its levels, its stairs -- is `map/WorldGen.gd`'s.

const CLIFF_ROW := 4          # cliff over land
const CLIFF_SEA_ROW := 5      # cliff with its foot in the sea
const RAMP_ROW := 6           # Art.tall_ramps: rows 6-8, top to foot; col 0 high ground right, col 3 left

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


## Per level, as the pack's guide stacks them: a shadow layer, then the
## raised ground with its cliffs and ramps, each level in its own grass.
func paint_levels() -> void:
	# The guide's foam on every tile touching the sea: raised ground and the
	# cliffs dropping into it have none of their own, as the ground's tiles do.
	var surf := grid.land.duplicate()
	for c: Vector2i in grid.cliff:
		surf[c] = true
	Art.shore_foam(world, surf, MapCfg.TILE).z_index = -1
	var tex := Art.tex(MapCfg.SHADOW_SHEET)
	for level in range(1, MapCfg.LEVEL_COLORS.size()):
		var shade := Node2D.new()
		shade.name = "Shadows%d" % level
		world.add_child(shade)
		var layer := Art.terrain_layer(Art.tall_ramps(MapCfg.LEVEL_COLORS[level]), MapCfg.TILE)
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
			layer.set_cell(c, 0, Art.autotile(joins.call(c + Vector2i.LEFT),
				joins.call(c + Vector2i.RIGHT), up.call(c + Vector2i.UP), up.call(c + Vector2i.DOWN), true))
			var edge := false
			for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.DOWN]:
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
			var t := Art.autotile(face.call(c + Vector2i.LEFT), face.call(c + Vector2i.RIGHT),
				false, false, true)
			layer.set_cell(c, 0, Vector2i(t.x, CLIFF_ROW if grid.land.has(c) else CLIFF_SEA_ROW))
		for c: Vector2i in grid.stairs:
			if int(grid.stairs[c].low) == level - 1:
				layer.set_cell(c, 0, Vector2i(0 if int(grid.stairs[c].side) < 0 else 3,
					RAMP_ROW + int(grid.stairs[c].row)))


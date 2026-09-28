extends Node

## Every spot a circle's tower may stand in, per district, for the towers that
## change from game to game (MapCfg.TOWER_POOL / Terrain.tower_seed). Built on
## the board as it is -- MAP_SEED's terrain, MapProps' trees and rocks, the
## carved rocks -- so a spot is known good before any game picks it:
##   * the circle rules: raised ground (terrace or plateau), flat and open
##     round it, the tower's footprint flat on its level;
##   * nothing under or beside the tower: its footprint and a cell round it
##     free of every prop and wall (today's circle towers aside -- they move);
##   * clear of buildings, signs, bridges, stairs and the fixed stops;
##   * walked to: reachable from the base camp with the knights stood down;
##   * and today's own spots, which the board was dressed round.
## Writes scripts/config/TowerPool.gd. Run windowless:
##   godot --headless --path game res://tools/make_tower_pool.tscn

const OUT := "res://scripts/config/TowerPool.gd"
const BRIDGE_CLEAR := 4        # cells kept between a spot and any bridge
const STOP_CLEAR := 4.0        # cells from the camp, a station's door, the gate


var _circle_keepouts: Array[Rect2] = []


## The cells that must be clear for a tower on `cells`: its footprint, the
## doorstep row under it and the row before that. Beside it a tree or a rock
## may stand -- the plateaus' carved rocks do, where their towers stood.
static func _clear_cells(cells: Array[Vector2i]) -> Array[Vector2i]:
	var lo := cells[0]
	var hi := cells[-1]
	var out: Array[Vector2i] = []
	for y in range(lo.y, hi.y + 3):
		for x in range(lo.x, hi.x + 1):
			out.append(Vector2i(x, y))
	return out


## MapGrid.clear_of_buildings, less today's circle towers' own keep-outs.
func _clear_of_buildings(g: MapGrid, r: Rect2) -> bool:
	for b: Rect2 in g.station_rects:
		if _circle_keepouts.any(func(k: Rect2) -> bool: return k.is_equal_approx(b)):
			continue
		var box := b.grow(-MapCfg.TILE)
		if box.size.x > 0.0 and box.size.y > 0.0 and box.intersects(r):
			return false
	return true


func _why(g: MapGrid, tr: Terrain, c: Vector2i, walls: Array[Rect2], circle_cells: Dictionary,
		reach: Dictionary, fixed: Array[Vector2i]) -> String:
	var T := float(MapCfg.TILE)
	var i := int(g.island_of.get(c, -1)) - 1
	var building: String = MapCfg.CIRCLE_BUILDINGS[i]
	var h := int(g.height.get(c, 0))
	if h != 1 and h != 2: return "level %d" % h
	if not tr._open_around(c, h, 1): return "not open"
	if not reach.has(c): return "unreachable"
	var cells := tr._tower_cells(c, building)
	for k: Vector2i in cells:
		if not tr._flat(k, h): return "footprint not flat"
	var lo := cells[0]
	var hi := cells[-1] + Vector2i(0, 2)
	for k: Vector2i in _clear_cells(cells):
		if g.taken.has(k) and not circle_cells.has(k): return "taken at %s" % k
		var box := Rect2(Vector2(k) * T + Vector2(2, 2), Vector2(T - 4, T - 4))
		for r in walls:
			if box.intersects(r): return "wall %s at %s" % [r, k]
	var area := Rect2(Vector2(lo) * T, Vector2(hi - lo + Vector2i.ONE) * T)
	if not _clear_of_buildings(g, area): return "buildings"
	if not g.clear_of_signs(area): return "signs"
	return ""


func _ready() -> void:
	var screen: Control = load("res://scripts/AdventureScreen.gd").new()
	add_child(screen)
	screen.setup({})
	var world: MapWorld = screen.world
	var g: MapGrid = screen.grid
	var tr: Terrain = world.terrain
	var T := float(MapCfg.TILE)
	for b: Dictionary in screen.barricades.list:
		screen.barricades.open(b)
	var reach := g.flood(g.anchors[0], 0)
	# Today's circle towers move, so their walls do not count against a spot.
	var circle_walls: Array[Rect2] = []
	for c: Node2D in screen._circles:
		var w: Rect2 = c.get("wall")
		circle_walls.append(Rect2(w.position + c.position, w.size))
	var walls: Array[Rect2] = []
	for r: Rect2 in g.solid:
		if not circle_walls.any(func(cw: Rect2) -> bool: return cw.is_equal_approx(r)):
			walls.append(r)
	for b: Rect2 in g.station_rects:
		for cn: Node2D in screen._circles:
			if b.has_point(cn.get_meta("tower_mid")):
				_circle_keepouts.append(b)
	var circle_cells := {}
	for c: Node2D in screen._circles:
		circle_cells[MapGrid.cell_at(c.position)] = true
	var fixed: Array[Vector2i] = []
	for k in g.anchors.size():
		var cell := MapGrid.cell_at(g.anchors[k])
		if not circle_cells.has(cell):
			fixed.append(cell)
	var pools: Array = []
	for i in MapCfg.DISTRICTS.size():
		var building: String = MapCfg.CIRCLE_BUILDINGS[i]
		var pool: Array[Vector2i] = []
		for c: Vector2i in g.land:
			if int(g.island_of.get(c, -1)) != i + 1:
				continue
			var h := int(g.height.get(c, 0))
			if h != 1 and h != 2:
				continue
			if not tr._open_around(c, h, 1) or not reach.has(c):
				continue
			var cells := tr._tower_cells(c, building)
			var ok := true
			for k: Vector2i in cells:
				if not tr._flat(k, h):
					ok = false
			# The footprint, the doorstep and the cell before it: no prop, no
			# wall; beside the tower a tree or a rock may stand.
			var lo := cells[0]
			var hi := cells[-1] + Vector2i(0, 2)
			for k: Vector2i in _clear_cells(cells):
				if g.taken.has(k) and not circle_cells.has(k):
					ok = false
				var box := Rect2(Vector2(k) * T + Vector2(2, 2), Vector2(T - 4, T - 4))
				if not MapGrid.clear_of(box, walls):
					ok = false
			if not ok:
				continue
			var area := Rect2(Vector2(lo) * T, Vector2(hi - lo + Vector2i.ONE) * T)
			if not _clear_of_buildings(g, area) or not g.clear_of_signs(area):
				continue
			var near_bridge := false
			for b: Dictionary in MapCfg.BRIDGES:
				var br: Rect2i = b.cells
				if br.grow(BRIDGE_CLEAR).has_point(c):
					near_bridge = true
			if near_bridge:
				continue
			if fixed.any(func(f: Vector2i) -> bool: return Vector2(f - c).length() < STOP_CLEAR):
				continue
			pool.append(c)
		# Today's own spots are in every pool: the board was dressed round
		# them -- the plateaus' carved rocks stand beside their towers -- and
		# test_collisions has always walked them.
		for cn: Node2D in screen._circles:
			var cc := MapGrid.cell_at(cn.position)
			if int(g.island_of.get(cc, -1)) == i + 1 and not pool.has(cc):
				pool.append(cc)
		pool.sort()
		pools.append(pool)
		var hi_n := pool.filter(func(c: Vector2i) -> bool: return int(g.height.get(c, 0)) == 2).size()
		print("district %d: %d spots (%d on plateaus), needs %d" % [i, pool.size(), hi_n, Game.ITEMS_PER_STATION[i]])
	var src := "## Generated by tools/make_tower_pool.gd -- do not edit by hand; re-run it\n"
	src += "## after the board, its props or its carved rocks change.\n"
	src += "## Every spot a circle's tower may stand in, per district, [cell, level].\n"
	src += "class_name TowerPool\n\nconst SPOTS := [\n"
	for i in pools.size():
		var row: PackedStringArray = []
		for c: Vector2i in pools[i]:
			row.append("[Vector2i(%d, %d), %d]" % [c.x, c.y, int(g.height.get(c, 0))])
		src += "\t[" + ", ".join(row) + "],\n"
	src += "]\n\n"
	# Every tree's, stump's and rock's solid box, carved rocks too: fixed, so a
	# game's pick of towers is walked round them before the board is built.
	src += "## Every prop's solid box (MapProps and the carved rocks), for the walk check.\n"
	src += "const WALLS := [\n"
	var feet: Array[Rect2] = (world.decor as Decor).feet
	for r: Rect2 in feet:
		src += "\tRect2(%.1f, %.1f, %.1f, %.1f),\n" % [r.position.x, r.position.y, r.size.x, r.size.y]
	src += "]\n"
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string(src)
	f.close()
	print("wrote ", OUT)
	get_tree().quit()

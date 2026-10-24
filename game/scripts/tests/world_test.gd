extends TestCase
## The procedural world (map/WorldGen.gd, map/MapWorld.gd; DESIGN.md 5.1):
## mirrored, every monk and the Monastery's door reachable from both spawns,
## the door the same walk from each, the same seed the same world, and quick
## enough to build on a phone at the start of a match.
##   godot --headless res://scripts/tests/world_test.tscn

const SEEDS := [1, 2, 3, 42, 777, 2026, 31337, 900001]


func frames(n := 2) -> void:
	for i in n:
		await get_tree().process_frame


func build(seed: int) -> MapWorld:
	var w := MapWorld.new()
	w.seed = seed
	w.monk_count = 10
	add_child(w)
	w.build()
	return w


## Cells reachable from `at`, walking as the hero does: by level, up and down
## ramps, round walls (MapGrid.flood).
func reach(w: MapWorld, at: Vector2) -> Dictionary:
	return w.grid.flood(at, 0)


## Steps from `from` to the nearest cell within reach of `to`, walking as the
## hero does; -1 if none is.
func steps(w: MapWorld, walls: Dictionary, from: Vector2, to: Vector2) -> int:
	var s := MapGrid.cell_at(from)
	var start := Vector3i(s.x, s.y, 0)
	var dist := {start: 0}
	var queue: Array[Vector3i] = [start]
	var head := 0
	while head < queue.size():
		var k := queue[head]
		head += 1
		if MapGrid.cell_mid(Vector2i(k.x, k.y)).distance_to(to) < MapCfg.INTERACT_RADIUS:
			return int(dist[k])
		for n in w.grid.next_states(k, walls):
			if not dist.has(n):
				dist[n] = int(dist[k]) + 1
				queue.append(n)
	return -1


const RULES := [
	"levels: a fair share of every island is raised",
	"levels: mirrored, ramps and all",
	"levels: no part of a level is a cell wide, no two cells meet only at a corner",
	"levels: every hill stands well inside its plateau",
	"levels: every plateau and hill has a ramp up onto it",
	"levels: every ramp's three cells stand on ground of its low level, its foot has ground to step onto",
	"levels: no prop, bush, house or monk stands across a level's edge, on a cliff or by a ramp",
	"levels: the Monastery and its yard stand on one level, clear of edges",
	"levels: no monk or door is in reach from another level",
	"water rocks are drawn over open sea only: no land, no cliff under them",
	"ponds: 1-2 a side, mirrored, each with a 3x3 core and two cells of land round it, none near a spawn",
]


## Which RULES world `w` breaks, and where.
func rules(w: MapWorld) -> Dictionary:
	var g := w.gen
	var grid := w.grid
	var out := {}
	var lvl := func(c: Vector2i) -> int: return int(g.height.get(c, -1))
	var raised := 0
	for c: Vector2i in g.main:
		raised += int(lvl.call(c) > 0)
	if raised < g.main.size() * WorldGen.MIN_RAISED:
		out[RULES[0]] = "%d of %d" % [raised, g.main.size()]
	for c: Vector2i in g.height:
		if lvl.call(c) != lvl.call(WorldGen.mirror_cell(c)):
			out[RULES[1]] = str(c)
	for r: Dictionary in g.ramps:
		var twin := false
		for o: Dictionary in g.ramps:
			twin = twin or (o.top == WorldGen.mirror_cell(r.top) and int(o.side) == -int(r.side) and o.low == r.low)
		if not twin:
			out[RULES[1]] = "ramp %s" % r
	for level in [1, 2]:
		var up := {}
		for c: Vector2i in g.height:
			if lvl.call(c) >= level:
				up[c] = true
		for c: Vector2i in up:
			var l := up.has(c + Vector2i.LEFT)
			var r := up.has(c + Vector2i.RIGHT)
			var u := up.has(c + Vector2i.UP)
			var d := up.has(c + Vector2i.DOWN)
			var pinch := false
			for dx in [-1, 1]:
				for dy in [-1, 1]:
					pinch = pinch or (up.has(c + Vector2i(dx, dy)) and not up.has(c + Vector2i(dx, 0)) and not up.has(c + Vector2i(0, dy)))
			if not (l or r) or not (u or d) or pinch:
				out[RULES[2]] = "level %d at %s" % [level, c]
		for piece: Dictionary in WorldGen._parts(up):
			var ramped := false
			for r: Dictionary in g.ramps:
				ramped = ramped or (int(r.low) == level - 1 and piece.has(r.top + Vector2i(-int(r.side), 1)))
			if not ramped:
				out[RULES[4]] = "level %d piece of %d at %s" % [level, piece.size(), piece.keys()[0]]
	for c: Vector2i in g.height:
		if lvl.call(c) == 2:
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					if lvl.call(c + Vector2i(dx, dy)) < 1:
						out[RULES[3]] = str(c)
	for r: Dictionary in g.ramps:
		var ok := true
		for row in 3:
			var k: Vector2i = r.top + Vector2i(0, row)
			ok = ok and lvl.call(k) == int(r.low) and not grid.cliff.has(k)
		var foot: Vector2i = r.top + Vector2i(0, 2)
		var off := false
		for k in [foot + Vector2i.DOWN, foot + Vector2i(int(r.side), 0)]:
			off = off or (lvl.call(k) == int(r.low) and not grid.cliff.has(k) and not grid.stairs.has(k))
		if not ok or not off:
			out[RULES[5]] = str(r)
	# Things on the ground: every cell under them flat, of one level, a cell
	# clear of any edge, cliff or ramp.
	var flat := func(c: Vector2i, level: int) -> bool:
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var k := c + Vector2i(dx, dy)
				if lvl.call(k) != level or grid.cliff.has(k) or grid.stairs.has(k):
					return false
		return true
	var feet: Array = []                     # [box, what, the point it stands on]
	for p: Dictionary in g.props:
		for r: Rect2 in WorldGen._rects_at(p.name, p.at, p.flip):
			feet.append([r, p.name, p.at])
	for b: Dictionary in g.bushes:
		feet.append([Rect2(b.at, Vector2.ZERO), "bush", b.at])
	for h: Dictionary in g.houses:
		# Its footprint, WorldGen.HOUSE_CELLS over the cells left and right of
		# its base point; a hair inside, or each corner is the next cell's.
		feet.append([Rect2(h.at - Vector2(MapCfg.TILE, MapCfg.TILE * 3), Vector2(MapCfg.TILE * 2, MapCfg.TILE * 3)).grow(-0.5), "house", h.at - Vector2(0, 1)])
	for m in g.monks:
		feet.append([Rect2(m + MapWorld.MONK_FEET.position, MapWorld.MONK_FEET.size), "monk", m])
	for f: Array in feet:
		var home := MapGrid.cell_at(f[2])
		var level: int = lvl.call(home)
		for c in WorldGen._under(f[0]) + [home]:
			if not flat.call(c, level):
				out[RULES[6]] = "%s at %s" % [f[1], f[2]]
	var base := MapGrid.cell_at(g.monastery - Vector2(0, 1))
	var mlevel: int = lvl.call(base)
	for y in range(base.y - WorldGen.MONASTERY_CELLS.y + 1, base.y + WorldGen.DOOR_YARD + 1):
		for x in range(WorldGen.HALF - 2, WorldGen.HALF + 2):
			if not flat.call(Vector2i(x, y), mlevel):
				out[RULES[7]] = str(Vector2i(x, y))
	var targets: Array[Vector2] = [g.door]
	targets.append_array(g.monks)
	for t in targets:
		var tl: int = lvl.call(MapGrid.cell_at(t))
		var c := MapGrid.cell_at(t)
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				var k := c + Vector2i(dx, dy)
				var near := Rect2(Vector2(k) * MapCfg.TILE, Vector2.ONE * MapCfg.TILE)
				var gap := (near.get_center() - t).length() - MapCfg.TILE * 0.5
				if gap < MapCfg.INTERACT_RADIUS and g.land.has(k) and not grid.cliff.has(k) \
						and (lvl.call(k) != tl or grid.stairs.has(k)):
					out[RULES[8]] = "%s from %s" % [t, k]
	var sea := {}
	for y in WorldGen.H:
		for x in WorldGen.W:
			if not g.land.has(Vector2i(x, y)):
				sea[Vector2i(x, y)] = true
	var open := WorldGen._flood(Vector2i.ZERO, sea)
	var wet := {}
	for c: Vector2i in sea:
		if not open.has(c):
			wet[c] = true
	var ponds := WorldGen._parts(wet)
	if ponds.size() < 2 or ponds.size() > 4:
		out[RULES[10]] = "%d ponds" % ponds.size()
	for pond: Dictionary in ponds:
		var core := WorldGen._core(pond, 1)
		for c: Vector2i in pond:
			if not wet.has(WorldGen.mirror_cell(c)) or g.spawns.any(func(sp: Vector2) -> bool:
					return MapGrid.cell_mid(c).distance_to(sp) < WorldGen.POND_FROM_SPAWN * MapCfg.TILE - MapCfg.TILE):
				core = false
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					var k := c + Vector2i(dx, dy)
					if not pond.has(k) and not g.land.has(k):
						core = false
		if not core:
			out[RULES[10]] = "pond at %s" % pond.keys()[0]
	for r: Dictionary in g.water_rocks:
		for k in WorldGen._under(WorldGen.water_rock_box(r.v, r.at, r.flip)):
			if g.land.has(k) or grid.cliff.has(k):
				out[RULES[9]] = "rock at %s over %s" % [r.at, k]
	return out


func _ready() -> void:
	backup_save()
	_levels()
	var slowest := 0
	var all_monks := true
	var all_reach := true
	var all_fair := true
	var all_mirror := true
	var why := []
	var bad := {}
	var mon_levels := {}
	var any_hill := false
	for seed in SEEDS:
		var t0 := Time.get_ticks_msec()
		var w := build(seed)
		slowest = maxi(slowest, Time.get_ticks_msec() - t0)
		var g := w.gen
		if g.monks.size() != 10 or w.monks.size() != 10:
			all_monks = false
			why.append("seed %d: %d monks" % [seed, g.monks.size()])
		var mirrored := g.spawns[1] == WorldGen.mirror(g.spawns[0]) \
			and is_equal_approx(g.monastery.x, MapCfg.WORLD_W * MapCfg.TILE * 0.5)
		for i in 5:
			mirrored = mirrored and g.monks[i + 5] == WorldGen.mirror(g.monks[i])
		for c: Vector2i in g.land:
			mirrored = mirrored and g.land.has(WorldGen.mirror_cell(c))
		if not mirrored:
			all_mirror = false
			why.append("seed %d not mirrored" % seed)
		var walls := w.grid.wall_cells()
		for team in 2:
			var targets: Array[Vector2] = [g.door]
			targets.append_array(g.monks)
			for at in targets:
				if steps(w, walls, g.spawns[team], at) < 0:
					all_reach = false
					why.append("seed %d team %d cannot reach %s" % [seed, team, at])
		var blue := steps(w, walls, g.spawns[0], g.door)
		var red := steps(w, walls, g.spawns[1], g.door)
		if blue != red or blue < 0:
			all_fair = false
			why.append("seed %d: door %d vs %d steps" % [seed, blue, red])
		var broke := rules(w)
		for rule: String in broke:
			bad[rule] = (bad.get(rule, []) as Array) + ["seed %d: %s" % [seed, broke[rule]]]
		mon_levels[int(g.height[MapGrid.cell_at(g.door)])] = true
		any_hill = any_hill or g.height.values().has(2)
		w.queue_free()
		await frames()
	for rule: String in RULES:
		check(rule, not bad.has(rule), str(bad.get(rule, "")).left(600))
	check("the Monastery stands on the ground in some worlds, up on a plateau in others",
		mon_levels.has(0) and mon_levels.has(1), str(mon_levels))
	check("some worlds have a hill on a plateau", any_hill)
	check("every world has its 10 monks", all_monks, str(why))
	check("every world is mirrored: land, spawns, monks, Monastery on the axis", all_mirror, str(why))
	check("from both spawns, every monk and the Monastery's door can be walked to", all_reach, str(why))
	check("the Monastery is the same walk from either spawn", all_fair, str(why))
	print("  slowest build: %d ms" % slowest)
	check("a world builds in under 4 s headless", slowest < 4000, str(slowest))

	var a := build(42)
	var b := build(42)
	var same: bool = a.gen.monks == b.gen.monks and a.gen.land.size() == b.gen.land.size() \
		and a.gen.props.size() == b.gen.props.size() and a.gen.door == b.gen.door \
		and (a.gen.props.is_empty() or a.gen.props[0].at == b.gen.props[0].at)
	check("the same seed builds the same world", same)
	var c := build(43)
	check("another seed builds another world", c.gen.monks != a.gen.monks or c.gen.door != a.gen.door)
	check("it is dressed: props, bushes, houses", a.gen.props.size() > 60
		and a.gen.bushes.size() > 20 and a.gen.houses.size() == 4,
		"%d props, %d bushes, %d houses" % [a.gen.props.size(), a.gen.bushes.size(), a.gen.houses.size()])
	var inside := true
	for p: Dictionary in a.gen.props:
		if a.grid.trail.has(MapGrid.cell_at(p.at)):
			inside = false
	check("no prop stands on a clearing", inside)
	completed = true
	finish("WORLD")


# --- Levels -----------------------------------------------------------------
## A board drawn by hand, 24x16 of ground: a plateau (1) at x 6-15, y 3-9,
## with a hill (2) on it at x 9-12, y 4-6; a ramp up the plateau's east side
## from the ground, another up the hill's from the plateau.
static func board() -> MapGrid:
	var g := MapGrid.new()
	for y in 16:
		for x in 24:
			var c := Vector2i(x, y)
			g.land[c] = true
			g.height[c] = 2 if x >= 9 and x <= 12 and y >= 4 and y <= 6 \
				else (1 if x >= 6 and x <= 15 and y >= 3 and y <= 9 else 0)
	g.lay_ramp(Vector2i(16, 8), 0, 1)
	g.lay_ramp(Vector2i(13, 5), 1, 1)
	g.lay_cliffs()
	return g


const FEET := Rect2(-6, -5, 12, 5)      # the hero's Foot box (scenes/Hero.tscn)


## Walk as the hero does, `dir` held for `s` seconds: [where, level, the
## lowest and highest level on the way, whether the feet ever stood where
## they may not].
func walk(g: MapGrid, at: Vector2, level: int, dir: Vector2, s: float) -> Array:
	var lo := level
	var hi := level
	var bad := false
	var step := dir.normalized() * MapCfg.PLAYER_SPEED / 60.0
	for _f in int(s * 60.0):
		var n := ceili(step.length() / 2.0)
		for _i in n:
			var got := g.step(at, step / n, FEET, level)
			at = got[0]
			level = got[1]
			lo = mini(lo, level)
			hi = maxi(hi, level)
			var c := MapGrid.cell_at(at)
			if g.cliff.has(c) or not g.land.has(c):
				bad = true
	return [at, level, lo, hi, bad]


static func px(cx: float, cy: float) -> Vector2:
	return Vector2(cx, cy) * MapCfg.TILE


func _levels() -> void:
	var g := board()
	check("each level's south edge has its cliff face, none under a ramp",
		g.cliff.get(Vector2i(10, 10)) == 1 and g.cliff.get(Vector2i(10, 7)) == 2
		and not g.cliff.has(Vector2i(16, 10)) and not g.cliff.has(Vector2i(10, 11)),
		str(g.cliff.keys()))
	var r := walk(g, px(10.5, 13), 0, Vector2.UP, 3.0)
	check("from the ground, a cliff face stops the hero", r[0].y > 11 * MapCfg.TILE and r[3] == 0 and not r[4], str(r))
	r = walk(g, px(3, 6.5), 0, Vector2.RIGHT, 3.0)
	check("from the ground, a plateau's side stops the hero", r[0].x < 6 * MapCfg.TILE and r[3] == 0, str(r))
	r = walk(g, px(4, 2.5), 0, Vector2(1, 0.4), 4.0)
	check("from the ground, a plateau's back stops the hero", r[3] == 0 and not r[4], str(r))
	r = walk(g, px(7.5, 8.5), 1, Vector2.DOWN, 3.0)
	check("on a plateau, its edge over the cliff stops the hero", r[0].y < 10 * MapCfg.TILE and r[2] == 1, str(r))
	r = walk(g, px(7.5, 6.5), 1, Vector2.LEFT, 3.0)
	check("on a plateau, its side stops the hero", r[0].x > 6 * MapCfg.TILE and r[2] == 1, str(r))
	r = walk(g, px(7.5, 4.5), 1, Vector2.UP, 3.0)
	check("on a plateau, its back stops the hero", r[0].y > 3 * MapCfg.TILE and r[2] == 1, str(r))
	r = walk(g, px(7.5, 5.5), 1, Vector2.RIGHT, 3.0)
	check("on a plateau, a hill's side stops the hero", r[0].x < 9 * MapCfg.TILE and r[3] == 1, str(r))
	r = walk(g, px(10.5, 8.5), 1, Vector2.UP, 3.0)
	check("on a plateau, a hill's cliff stops the hero", r[0].y > 8 * MapCfg.TILE and r[3] == 1 and not r[4], str(r))
	r = walk(g, px(16.5, 12.5), 0, Vector2.UP, 3.0)
	check("held straight up, a ramp takes the hero from the ground onto the plateau",
		r[1] == 1 and g.height.get(MapGrid.cell_at(r[0])) == 1 and not g.stairs.has(MapGrid.cell_at(r[0])), str(r))
	r = walk(g, r[0], r[1], Vector2.DOWN, 0.3)
	r = walk(g, px(14.5, 8.5), 1, Vector2.RIGHT, 0.6)
	r = walk(g, r[0], r[1], Vector2.DOWN, 3.0)
	check("and down it again, back onto the ground", r[1] == 0 and r[0].y > 11 * MapCfg.TILE and not r[4], str(r))
	r = walk(g, px(13.5, 9.0), 1, Vector2.UP, 3.0)
	check("a ramp on the plateau takes the hero up onto the hill", r[1] == 2, str(r))
	r = walk(g, px(19, 8.6), 0, Vector2.LEFT, 3.0)
	check("a ramp's top is no way on from its open side", r[3] == 0 and r[0].x > 17 * MapCfg.TILE, str(r))
	r = walk(g, px(16.5, 6.5), 0, Vector2.DOWN, 3.0)
	check("nor from behind it", r[3] == 0 and r[0].y < 8 * MapCfg.TILE, str(r))
	r = walk(g, px(4, 11.5), 0, Vector2.RIGHT, 6.0)
	check("the ground under a cliff is walked along freely", r[0].x > 20 * MapCfg.TILE and r[1] == 0, str(r))
	var all := g.flood(px(2, 2), 0)
	check("walking, every level is reached from the ground", all.has(Vector2i(10, 5)) and all.has(Vector2i(7, 7)))
	var flat := g.flood(px(2, 2), 0, true)
	check("without its stairs, none above it is", not flat.has(Vector2i(7, 7)) and not flat.has(Vector2i(10, 5)))
	var shut := true
	for c: Vector2i in g.cliff:
		for level in 3:
			if g.box_walkable(MapGrid.cell_mid(c), FEET, level):
				shut = false
	check("nobody stands in a cliff face, at any level", shut)


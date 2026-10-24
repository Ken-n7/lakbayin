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


## Cells reachable from `at`, as the hero walks: land whose middle no wall
## covers. The walls are laid onto cells once -- testing every wall at every
## step of the flood (MapGrid.flood) took minutes for eight worlds.
func reach(w: MapWorld, at: Vector2) -> Dictionary:
	var blocked := {}
	for r: Rect2 in w.grid.solid:
		var a := MapGrid.cell_at(r.position)
		var b := MapGrid.cell_at(r.end)
		for y in range(a.y, b.y + 1):
			for x in range(a.x, b.x + 1):
				if r.has_point(MapGrid.cell_mid(Vector2i(x, y))):
					blocked[Vector2i(x, y)] = true
	var open := {}
	for c: Vector2i in w.grid.land:
		if not blocked.has(c):
			open[c] = true
	return WorldGen._flood(MapGrid.cell_at(at), open)


## Steps from `from` to the nearest reached cell within reach of `to`, by a
## breadth-first walk over `cells`; -1 if none is.
func steps(cells: Dictionary, from: Vector2, to: Vector2) -> int:
	var start := MapGrid.cell_at(from)
	var dist := {start: 0}
	var queue: Array[Vector2i] = [start]
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		if MapGrid.cell_mid(c).distance_to(to) < MapCfg.INTERACT_RADIUS:
			return int(dist[c])
		for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var n: Vector2i = c + d
			if cells.has(n) and not dist.has(n):
				dist[n] = int(dist[c]) + 1
				queue.append(n)
	return -1


func _ready() -> void:
	backup_save()
	_levels()
	var slowest := 0
	var all_monks := true
	var all_reach := true
	var all_fair := true
	var all_mirror := true
	var why := []
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
		for team in 2:
			var cells := reach(w, g.spawns[team])
			var targets: Array[Vector2] = [g.door]
			targets.append_array(g.monks)
			for at in targets:
				if steps(cells, g.spawns[team], at) < 0:
					all_reach = false
					why.append("seed %d team %d cannot reach %s" % [seed, team, at])
		var blue := steps(reach(w, g.spawns[0]), g.spawns[0], g.door)
		var red := steps(reach(w, g.spawns[1]), g.spawns[1], g.door)
		if blue != red or blue < 0:
			all_fair = false
			why.append("seed %d: door %d vs %d steps" % [seed, blue, red])
		w.queue_free()
		await frames()
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
func board() -> MapGrid:
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


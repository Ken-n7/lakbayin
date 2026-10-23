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

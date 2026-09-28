extends TestCase
## The signs circling each tower (TowerSymbols, client 2026-09-27): smaller
## than the tower's number, its station's signs, circling at rest; answered,
## they whirl faster, then shoot off each its own way and are gone. A run
## restored with the stop already done shows none, and no whirl.
##   godot --headless res://scripts/tests/tower_test.tscn


func frames(n := 2) -> void:
	for i in n:
		await get_tree().process_frame


func tower(index: int) -> Node2D:
	var world := Node2D.new()
	add_child(world)
	var c: Node2D = load("res://scripts/PathCircle.gd").new()
	world.add_child(c)
	c.setup(index, MapCfg.CIRCLE_BUILDINGS[Game.station_of_item(index)], Vector2(0, -24), world)
	return c


## `dt` seconds of the symbols' own clock.
func run(s: TowerSymbols, dt: float) -> void:
	var step := 1.0 / 60.0
	var t := 0.0
	while t < dt and is_instance_valid(s):
		s._process(step)
		t += step


func angle_of(s: TowerSymbols, i: int) -> float:
	var p: Vector2 = s.place(i)[0]
	return atan2(p.y / TowerSymbols.RADIUS.y, p.x / TowerSymbols.RADIUS.x)


func _ready() -> void:
	backup_save()
	await frames()
	var c := tower(0)
	await frames()
	var s: TowerSymbols = c.get("symbols")
	check("a tower has signs circling it", s != null and is_instance_valid(s))
	check("six of them", TowerSymbols.COUNT == 6)
	check("smaller than the number over the tower", TowerSymbols.SIZE < c.NUMBER_SIZE,
		"%d vs %d" % [TowerSymbols.SIZE, c.NUMBER_SIZE])
	check("station 1's tower: the four operations", s.station == 0 and TowerSymbols.SIGNS[0].has("+"))
	check("station 3's tower: powers", (tower(12).get("symbols") as TowerSymbols).station == 2)
	check("round the tower's top, under its number",
		# The number's box sits 54 px over the tower's top edge; the tower is
		# drawn 92 px tall (its art trimmed).
		absf(s.position.y - (c.get("_label") as Label).position.y - (92.0 * (1.0 - TowerSymbols.TOP) + 54.0)) < 1.0
		# Their highest (the far side, at the widest breath, bobbing up) stays
		# under the number's figure.
		and s.position.y - TowerSymbols.RADIUS.y * 1.26 - 5.0 > (c.get("_label") as Label).position.y + 34.0,
		"%s, number at %s" % [s.position, (c.get("_label") as Label).position])

	# At rest: they go round, and stay on the ring.
	c.set_state("locked")
	var a0 := angle_of(s, 0)
	run(s, 0.5)
	var rest_turn := absf(wrapf(angle_of(s, 0) - a0, -PI, PI))
	check("at rest they circle", rest_turn > 0.15, str(rest_turn))
	var on_ring := true
	for i in TowerSymbols.COUNT:
		var q: Vector2 = s.place(i)[0]
		on_ring = on_ring and absf(q.x) <= TowerSymbols.RADIUS.x * 1.3 and absf(q.y) <= TowerSymbols.RADIUS.y * 1.3 + 5.0
	check("...on a ring round the tower's top", on_ring)
	# Not in lockstep: the spacing between every pair of neighbours changes.
	var gaps0: Array = range(TowerSymbols.COUNT).map(func(k: int) -> float:
		return wrapf(angle_of(s, (k + 1) % TowerSymbols.COUNT) - angle_of(s, k), -PI, PI))
	run(s, 2.0)
	var least := INF
	for k in TowerSymbols.COUNT:
		var g1 := wrapf(angle_of(s, (k + 1) % TowerSymbols.COUNT) - angle_of(s, k), -PI, PI)
		least = minf(least, absf(wrapf(g1 - float(gaps0[k]), -PI, PI)))
	check("not in lockstep: every pair drifts apart and together", least > 0.1,
		"least change %.3f" % least)
	var sizes := {}
	for e: Dictionary in s.get("_each"):
		sizes[e.size] = true
	check("each its own size, all under the number", sizes.size() > 1
		and sizes.keys().max() < c.NUMBER_SIZE, str(sizes.keys()))

	# Answered: the whirl.
	c.set_state("done")
	check("answered: they burst", s.bursting())
	check("the number goes", not (c.get("_label") as Label).visible)
	run(s, TowerSymbols.WHIRL_S * 0.6)
	a0 = angle_of(s, 0)
	run(s, 0.1)
	var whirl_turn := absf(wrapf(angle_of(s, 0) - a0, -PI, PI))
	check("they whirl, much faster than at rest", whirl_turn > rest_turn / 5.0 * 3.0,
		"%.2f rad in 0.1 s, %.2f at rest" % [whirl_turn, rest_turn / 5.0])
	# ...then the dash.
	run(s, TowerSymbols.WHIRL_S * 0.4 + TowerSymbols.DASH_S * 0.5)
	var far := true
	var ways := {}
	for i in TowerSymbols.COUNT:
		var p: Vector2 = s.place(i)[0]
		far = far and p.length() > TowerSymbols.RADIUS.x * 3.0
		ways[int(fposmod(p.angle(), TAU) / (PI * 0.5))] = true
	check("then they shoot out, fast", far)
	check("each its own way", ways.size() >= 3, str(ways.keys()))
	run(s, TowerSymbols.DASH_S)
	await frames()
	check("and are gone", not is_instance_valid(s))

	# A run restored with the stop done: no signs, no whirl.
	var r := tower(3)
	var rs: TowerSymbols = r.get("symbols")
	r.set_state("done")
	check("restored as done: no whirl", not rs.bursting())
	await frames()
	check("...and no signs", not is_instance_valid(rs))
	await _per_game()
	completed = true
	finish("TOWER")


## The towers change from game to game (Terrain.tower_seed), and a game's
## board is the same wherever it is built.
func towers_of(seed: int) -> Array:
	var w := MapWorld.new()
	w.tower_seed = seed
	add_child(w)
	w.build()
	var out: Array = w.circles.map(func(c: Node2D) -> Vector2: return c.position)
	var used: int = w.terrain.tower_try
	w.free()
	return [out, used]


func _per_game() -> void:
	print("-- towers per game")
	var drawn: Array = (await towers_of(0))[0]
	var a: Array = await towers_of(Game.seed_of("session-a"))
	var a2: Array = await towers_of(Game.seed_of("session-a"))
	var b: Array = await towers_of(Game.seed_of("session-b"))
	check("a game's towers are the same wherever its board is built", a[0] == a2[0])
	check("another game's are not", a[0] != b[0])
	check("nor the board as drawn", a[0] != drawn)
	check("each game's pick held (walkable, trees and rocks included)", int(a[1]) >= 0 and int(b[1]) >= 0,
		"%s / %s" % [a[1], b[1]])
	check("still fourteen", (a[0] as Array).size() == Game.TOTAL_ITEMS)
	var spots := {}
	for i in TowerPool.SPOTS.size():
		for sp: Array in TowerPool.SPOTS[i]:
			spots[MapGrid.cell_at(MapGrid.cell_mid(sp[0]))] = i
	var in_pool := (a[0] as Array).all(func(p: Vector2) -> bool: return spots.has(MapGrid.cell_at(p)))
	check("every tower on a spot from its pool", in_pool)
	# Each station's towers on its own island, in its own order of stations.
	var k := 0
	var own := true
	for st in Game.ITEMS_PER_STATION.size():
		for _n in Game.ITEMS_PER_STATION[st]:
			own = own and int(spots.get(MapGrid.cell_at(a[0][k]), -1)) == st
			k += 1
	check("each station's towers on its own island", own)
	# A walking order: no leg much longer than the island needs.
	var hops := []
	for n in range(1, (a[0] as Array).size()):
		if Game.station_of_item(n) == Game.station_of_item(n - 1):
			hops.append((a[0][n] as Vector2).distance_to(a[0][n - 1]) / MapCfg.TILE)
	check("each next tower is on from the last, not across the island and back",
		hops.max() < 30.0, "longest hop %.1f cells" % hops.max())
	# No zig-zag: in no game does a station's route cross itself.
	var crossed := []
	for sd in [Game.seed_of("session-a"), Game.seed_of("session-b"), 4242, 11, 90210, 777777, 31337, 2026]:
		var t: Array = (await towers_of(sd))[0] if sd != Game.seed_of("session-a") else a[0]
		var start := 0
		for st in Game.ITEMS_PER_STATION.size():
			var pts: Array = t.slice(start, start + Game.ITEMS_PER_STATION[st])
			start += Game.ITEMS_PER_STATION[st]
			for x in range(pts.size() - 1):
				for y in range(x + 2, pts.size() - 1):
					if Geometry2D.segment_intersects_segment(pts[x], pts[x + 1], pts[y], pts[y + 1]) != null:
						crossed.append("seed %d station %d legs %d/%d" % [sd, st + 1, x + 1, y + 1])
	check("no game's route crosses itself (no zig-zag)", crossed.is_empty(), str(crossed))
	check("a session's seed is never 0 (0 is the board as drawn)",
		Game.seed_of("") != 0 and Game.seed_of("x") != 0 and Game.seed_of("x") == Game.seed_of("x"))
	# Offline, each run its own.
	Game.begin_adventure()
	var s1 := Game.board_seed()
	Game.begin_adventure()
	check("offline, a new run has its own towers", Game.board_seed() != s1 and s1 != 0)
	# The Quest Keeper's map follows the session it watches.
	var mw := MapWatch.new()
	add_child(mw)
	await frames()
	mw.watch("session-a")
	await frames()
	check("the Quest Keeper's map has that game's towers",
		mw.world.circles.map(func(c: Node2D) -> Vector2: return c.position) == a[0])
	mw.queue_free()

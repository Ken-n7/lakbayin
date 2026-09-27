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
	# Not in lockstep: the spacing between neighbours changes as they go.
	var gap0 := wrapf(angle_of(s, 1) - angle_of(s, 0), -PI, PI)
	run(s, 2.0)
	var gap1 := wrapf(angle_of(s, 1) - angle_of(s, 0), -PI, PI)
	check("not in lockstep: they drift apart and together", absf(gap1 - gap0) > 0.15,
		"%.2f -> %.2f" % [gap0, gap1])
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
	completed = true
	finish("TOWER")

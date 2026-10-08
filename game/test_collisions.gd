extends SceneTree

## Self-check for the building walls. Run:
##   godot --headless --path game --script res://test_collisions.gd
##
## The bug this guards: footprints used to be rounded to whole tiles and a cell
## only counted as blocked when its CENTRE fell inside the walls. The Blue
## Tower is 60 world px wide against a 32px grid, so exactly one column ever
## blocked and the hero walked in through either side.

func _initialize() -> void:
	# A local named `Game` would shadow the autoload, which is a compile error, and
	# the autoload is not a compile-time identifier in a `--script` run anyway.
	var G: Node = root.get_node("Game")
	# Which towers (Terrain.tower_seed): `-- <seed>`, 0 (the board as drawn)
	# if none. run_tests.sh walks the drawn board and a few games' boards.
	var args := OS.get_cmdline_user_args()
	var seed := int(args[0]) if args.size() > 0 else 0
	G.begin_adventure()
	G.solo_seed = seed
	var screen: Control = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(screen)
	screen.setup({})
	var tr: Object = screen.world.get("terrain")     # untyped: see G above
	assert(tr.tower_seed == seed, "the board was not built for seed %d" % seed)
	if seed != 0:
		assert(tr.tower_try >= 0, "no pick of towers held for seed %d: %s" % [seed, tr.tower_skips])
		print("seed %d: towers from try %d, ways %s" % [seed, tr.tower_try, tr.tower_ways])
	print("towers at: ", screen._circles.map(func(c: Node2D) -> Vector2i: return MapGrid.cell_at(c.position)))

	for i in 3:
		var at: Vector2 = screen.stations.nodes[i].position
		# Off the station itself, not `_solid[i]`: the outpost's houses append walls
		# too, so the array is no longer one entry per station.
		var wall: Rect2 = (screen.stations.nodes[i] as Node2D).get_meta("wall")
		var mid_y: float = wall.get_center().y

		assert(not screen.grid.is_walkable(wall.get_center()),
				"station %d: centre of the walls is walkable" % i)
		assert(not screen.grid.is_walkable(Vector2(wall.position.x + 1.0, mid_y)),
				"station %d: left wall leaks" % i)
		assert(not screen.grid.is_walkable(Vector2(wall.end.x - 1.0, mid_y)),
				"station %d: right wall leaks" % i)
		# The tower steps off the path -- up on a lane, sideways on a bend -- so the
		# wall is centred on the building, not on the doorstep.
		assert(not screen.grid.is_walkable(Vector2(wall.get_center().x, wall.position.y + 1.0)),
				"station %d: back wall leaks" % i)

		# The doorstep -- the station node's own spot -- must stay open, or
		# INTERACT_RADIUS can never be satisfied and the quiz is unreachable.
		assert(screen.grid.is_walkable(at),
				"station %d: doorstep is walled in, quiz unreachable" % i)
		assert(at.distance_to(screen.stations.nodes[i].position) < MapCfg.INTERACT_RADIUS)

		# The walls span the sprite, so no side is thinner than the art.
		assert(wall.size.x > MapCfg.TILE, "station %d: walls thinner than a tile" % i)

	# --- The board path (Phase 1) ------------------------------------------
	var circles: Array = screen._circles
	assert(circles.size() == G.TOTAL_ITEMS,
			"expected %d circles, got %d" % [G.TOTAL_ITEMS, circles.size()])
	var seen := {}
	for n in circles.size():
		var pos: Vector2 = (circles[n] as Node2D).position
		assert(not seen.has(pos), "circle %d shares a spot with another" % n)
		seen[pos] = true
		assert(screen.grid.is_walkable(pos), "circle %d stands on unwalkable ground" % n)
		# The question is asked at the tower's front door: the tower stands
		# straight up off its circle, so the circle is below its wall, centred on
		# the door. Towers used to step aside, or even below the circle, which
		# put the "answer here" spot beside the tower or behind it on its roof.
		var wall: Rect2 = (circles[n] as Node2D).get("wall")
		assert(wall.end.y <= 0.0, "circle %d is not in front of its tower (wall %s)" % [n, wall])
		assert(absf(wall.get_center().x) < 1.0,
				"circle %d is beside its tower's door, not in front of it (wall %s)" % [n, wall])
		# ...and the road comes to that door, not through the tower.
		var terrain: Terrain = screen.world.terrain
		var cell := MapGrid.cell_at(pos)
		for k in terrain._tower_cells(cell, MapCfg.CIRCLE_BUILDINGS[G.station_of_item(n)]):
			assert(k == cell + Terrain.UP or not screen.grid.trail.has(k),
					"the road runs under circle %d's tower at %s" % [n, k])
	assert(screen.stations.gate != null, "no victory gate")
	assert(screen.grid.is_walkable(screen.stations.gate.position), "the gate is not walkable")

	# Props are solid at the base -- a trunk, a rock's body -- and the road is
	# not: the hero used to walk straight through the forest.
	var feet: Array[Rect2] = screen.decor.feet
	# Placed by hand now, so any number is fine -- but a prop scene with a
	# collision box must come out solid. Count what should have.
	var boxed := 0
	var placed: Node = (load(MapCfg.MAP_PROPS) as PackedScene).instantiate()
	for p in placed.find_children("*", "StaticBody2D", true, false):
		boxed += p.find_children("*", "CollisionShape2D", true, false).size()
	placed.free()
	assert(feet.size() >= boxed, "only %d walls from %d collision shapes" % [feet.size(), boxed])
	# A circle becomes bands that stay inside it and span it at the middle.
	var disc := CircleShape2D.new()
	disc.radius = 10.0
	var bands: Array[Rect2] = Decor._walls_of(disc, Transform2D(0.0, Vector2(100, 100)))
	assert(bands.size() == 5, "a circle made %d bands" % bands.size())
	for b: Rect2 in bands:
		assert(Rect2(90, 90, 20, 20).encloses(b), "a band leaves the circle's square: %s" % b)
	assert(is_equal_approx(bands[2].size.x, 20.0), "the middle band is not the full width")
	var on_road := 0
	for r: Rect2 in feet:
		assert(not screen.grid.is_walkable(r.get_center()), "a prop's base is walkable")
		# Boxes are placed and sized by hand now (scenes/map/MapProps.tscn), and
		# one reaching over the road's edge is not a failure: the reach checks
		# below -- the cell flood and the hero's own box -- are what say whether
		# the way is still open. Named, so a box that shuts it is easy to find.
		if screen.grid.trail.has(_cell(screen, r.get_center())):
			on_road += 1
			print("  note: a prop's box is over the road at %s" % r)
	if on_road > 0:
		print("  %d prop box(es) over the road -- fine while every stop stays reachable" % on_road)

	# Strictly sequential: nothing is answerable until the tower is briefed, then
	# only the one circle the player is actually on.
	G.begin_adventure(600)
	assert(not screen._can_answer(0), "circle 1 answerable before the Station 1 briefing")
	assert(screen._can_enter_tower(0), "Tower 1 should be open at the start")
	assert(not screen._can_enter_tower(1), "Tower 2 open before Station 1 is done")
	G.towers_entered[0] = true
	assert(screen._can_answer(0), "circle 1 locked after the briefing")
	for n in range(1, G.TOTAL_ITEMS):
		assert(not screen._can_answer(n), "circle %d answerable while circle 1 is open" % (n + 1))
	assert(not screen._can_enter_gate(), "the gate opened with 0 circles resolved")

	# Walk the whole board: each resolved circle unlocks exactly the next one, and
	# a station's tower only opens once the previous station is cleared.
	for n in G.TOTAL_ITEMS:
		var st: int = G.station_of_item(n)
		if not G.towers_entered[st]:
			assert(screen._can_enter_tower(st), "Tower %d shut on its own first circle" % (st + 1))
			G.towers_entered[st] = true
		assert(screen._can_answer(n), "circle %d not current when it should be" % (n + 1))
		assert(not screen._can_enter_gate(), "the gate opened at circle %d" % (n + 1))
		if n + 1 < G.TOTAL_ITEMS:
			assert(not screen._can_answer(n + 1), "circle %d unlocked early" % (n + 2))
		G.mark_correct()
	assert(G.items_done == G.TOTAL_ITEMS, "all circles resolved: %d" % G.items_done)
	assert(screen._can_enter_gate(), "the gate stayed shut after all circles")

	# --- Region gating: one way between islands, and it is held -------------
	# Flood-fill from the base camp over walkable ground. This is what actually
	# proves a gate: a flag can be checked, but only reachability shows that the
	# next island cannot be reached by walking around the obstacle.
	#
	# Every gate is a knight on the only stairs up to his station's terrace;
	# the cliffs are the rest of the wall. The proof does not care how: walk the
	# board, by level, and see where you can get to.
	G.begin_adventure(600)
	assert(screen.barricades.list.size() == 3,
			"expected a knight on each of 3 stations' stairs, got %d" % screen.barricades.list.size())
	for g: Dictionary in screen.barricades.list:
		var who: int = int(g.st) + 1
		assert(not bool(g.open), "station %d's barricade starts open" % who)
		assert(g.guard != null, "station %d has no guard on a fresh run" % who)
		assert(not screen.grid.is_walkable((g.wall as Rect2).get_center()),
				"station %d's guard is not solid" % who)
		assert(screen.grid.clear_of_anchors(g.wall),
				"station %d's wall swallows a stop on the board" % who)
		# He steps aside rather than vanishing, so the spot has to be real ground:
		# open, off the road, and not back inside the rocks he was standing in.
		var rest: Vector2 = g.stand
		assert(screen.grid.is_walkable(rest), "station %d's guard steps into a wall" % who)
		assert(not screen.grid.trail.has(_cell(screen, rest)),
				"station %d's guard steps down onto the road" % who)
		assert(rest.distance_to(g.post as Vector2) > MapCfg.TILE,
				"station %d's guard steps down into the gap he was plugging" % who)

	# Station 1's door has to be open from the camp, or nothing can begin.
	var door: Vector2 = screen.grid.anchors[1]
	assert(screen.grid.is_walkable(door), "Station 1's doorstep is inside the wall")
	var held := _reachable(screen)
	assert(held.has(_cell(screen, door)),
			"Station 1 is unreachable from camp, so it can never be briefed")
	# Which is the whole point: with the guards in their gaps, nothing past any of
	# the three is walkable-to, and `_assert_islands()` is what proves it.
	_assert_islands(screen, G, -1)

	# Each one opens in turn.
	for st in screen.barricades.list.size():
		var g: Dictionary = screen.barricades.list[st]
		screen.barricades.open(g)
		assert(screen.grid.is_walkable((g.wall as Rect2).get_center()),
				"station %d's wall outlived its guard" % (st + 1))
		_assert_islands(screen, G, st)

	# With every gate open, the hero's actual Foot box (scenes/Hero.tscn) gets
	# everywhere it has to: the cell flood above is a point per 32px, and a box
	# can stick in a gap a point slips through.
	_assert_box_reach(screen, G)
	_assert_climbs(screen)

	# Each knight steps off his stair round every wall, never through one.
	var boots: Rect2 = MapCfg.GUARD_BOOTS
	for st in screen.barricades.list.size():
		var g: Dictionary = screen.barricades.list[st]
		var path: Array[Vector2] = screen.barricades.walk_path(g, g.post, g.stand)
		assert(path[-1] == g.stand, "knight %d's walk does not end where he rests" % (st + 1))
		var at: Vector2 = g.post
		for p in path:
			for k in range(1, 21):
				var q := at.lerp(p, k / 20.0)
				assert(MapGrid.clear_of(Rect2(boots.position + q, boots.size),
					screen.barricades.path_stones(g, g.post)),
					"knight %d walks through a wall at %s" % [st + 1, q])
			at = p

	# ...and each one waits on his own station's briefing and nothing else:
	# clearing the station before his does not move him.
	var fresh: Control = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(fresh)
	G.begin_adventure(600)
	fresh.setup({})
	for st in 3:
		assert(not bool(fresh.barricades.list[st].open),
				"station %d's guard gone before its briefing" % (st + 1))
	for n in G.ITEMS_PER_STATION[0]:
		G.mark_correct()
	fresh.barricades.refresh()
	for st in 3:
		assert(not bool(fresh.barricades.list[st].open),
				"station %d's guard stood down on circles, not on its briefing" % (st + 1))
	G.towers_entered[1] = true
	fresh.barricades.refresh()
	assert(bool(fresh.barricades.list[1].open), "station 2's guard held after its briefing")
	assert(not bool(fresh.barricades.list[2].open),
			"station 3's guard moved on Station 2's briefing")

	# A restart mid-run keeps what it had already earned: the guard is not a wall
	# any more, but he is still standing there, beside his station.
	var briefed: Control = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(briefed)
	G.begin_adventure(600)
	G.towers_entered[0] = true
	briefed.setup({})
	assert(bool(briefed.barricades.list[0].open),
			"station 1's guard re-posted on a run that was already briefed")
	assert(briefed.grid.is_walkable((briefed.barricades.list[0].wall as Rect2).get_center()),
			"the stair is walled on a run that was already briefed")
	assert(briefed.barricades.list[0].guard != null,
			"the briefed guard vanished instead of standing aside")
	for st in [1, 2]:
		assert(not bool(briefed.barricades.list[st].open),
				"station %d's guard gone on a briefed restart" % (st + 1))

	# --- The dev panel's Skip Station ----------------------------------------
	# It is the shortcut the later islands are tested through, so it has to leave
	# the board in exactly the state playing the questions would: each skip banks
	# one station and opens what that station's progress opens, and nothing ahead
	# of it. Proved the same way as everything else here -- by walking the ground.
	var rig: Control = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(rig)
	G.begin_adventure(600)
	rig.setup({})
	# The Map tab's tools, as the dev panel makes them (loaded, not named: this
	# runs before the autoloads they use exist).
	var cheats: RefCounted = load("res://scripts/dev/DevMapTools.gd").new(rig)
	_assert_islands(rig, G, -1)
	for st in 3:
		cheats._skip_station()
		assert(G.items_done == _items_through(G, st),
				"skipping station %d left %d items done" % [st + 1, G.items_done])
		assert(bool(G.completed_stations[st]), "station %d was not banked" % (st + 1))
		# A skip briefs the tower, which stands that station's own guard down, and
		# empties its circles. One gate per skip, in order.
		_assert_islands(rig, G, st)
	assert(G.items_done == G.TOTAL_ITEMS,
			"three skips left %d of %d items" % [G.items_done, G.TOTAL_ITEMS])
	assert(rig._can_enter_gate(), "the Victory Gate stayed shut after three skips")
	# ...and it is not a way past the end of the board.
	cheats._skip_station()
	assert(G.items_done == G.TOTAL_ITEMS, "skipping a cleared board ran past the end")

	# The carved rocks (MapCfg.CARVED_ROCKS): all there, carved, and solid --
	# the middle of each one's box is a wall, as a pack rock's is.
	var carved: Node = (screen.world as Node).get("carved")
	assert(carved != null and carved.get_child_count() == MapCfg.CARVED_ROCKS.size(),
			"expected %d carved rocks on the map" % MapCfg.CARVED_ROCKS.size())
	for c: Array in MapCfg.CARVED_ROCKS:
		var rock := carved.get_node(String(c[0])) as Node2D
		var tex := (rock.get_node("Sprite") as Sprite2D).texture
		assert(tex.resource_path == MapCfg.CARVED_ROCK % c[0], "%s is not carved" % c[0])
		var solid := false
		for r: Rect2 in screen.grid.solid:
			if r.has_point(c[2] + Vector2(0, -35)):
				solid = true
		assert(solid and not screen.grid.is_walkable(c[2] + Vector2(0, -35)), "%s does not block the hero" % c[0])
	print("carved rocks: %d, each solid" % MapCfg.CARVED_ROCKS.size())
	print("collisions ok")
	quit()


## `opened` is the last station whose knight has stood down, or -1 while all
## three hold. A station is walkable-to once the knight before it has stood
## down; its circles once its own has; the Victory Gate once the last has.
func _assert_islands(screen: Control, G: Node, opened: int) -> void:
	var reach := _reachable(screen)
	for n in G.TOTAL_ITEMS:
		var st: int = G.station_of_item(n)
		var pos: Vector2 = (screen._circles[n] as Node2D).position
		assert(reach.has(_cell(screen, pos)) == (opened >= st),
				"circle %d (station %d) reachability wrong with %d knight(s) down" % [n + 1, st + 1, opened + 1])
	for st in 3:
		var tp: Vector2 = (screen.stations.nodes[st] as Node2D).position
		assert(reach.has(_cell(screen, tp)) == (opened >= st - 1),
				"station %d reachability wrong with %d knight(s) down" % [st + 1, opened + 1])
	var gate: Vector2 = (screen.stations.gate as Node2D).position
	assert(reach.has(_cell(screen, gate)) == (opened >= 2),
			"victory gate reachability wrong with %d knight(s) down" % (opened + 1))


## Circles resolved by the time station `st` is done -- the same running total
## `AdventureScreen._items_through()` walks, spelled here so the test does not
## lean on the thing it is checking.
static func _items_through(G: Node, st: int) -> int:
	var n := 0
	for i in st + 1:
		n += G.ITEMS_PER_STATION[i]
	return n


static func _cell(screen: Control, at: Vector2) -> Vector2i:
	return Vector2i(floori(at.x / MapCfg.TILE), floori(at.y / MapCfg.TILE))


## Floods the board in 8px steps as the hero's Foot box, from the base camp,
## walking by level as the hero does -- up and down the stairs, never off a
## terrace or through a cliff -- and asserts every station doorstep, circle and
## the gate is within INTERACT_RADIUS of somewhere it got to.
func _assert_box_reach(screen: Control, G: Node) -> void:
	var box: Rect2 = screen.hero_box
	assert(box.size != Vector2.ZERO, "the hero has no Foot box")
	var grid: MapGrid = screen.grid
	# Walls by 64px bucket, or a quarter-million steps x every wall is a long test.
	var buckets := {}
	for w: Rect2 in grid.solid:
		for bx in range(floori(w.position.x / 64.0), floori(w.end.x / 64.0) + 1):
			for by in range(floori(w.position.y / 64.0), floori(w.end.y / 64.0) + 1):
				var k := Vector2i(bx, by)
				if not buckets.has(k):
					buckets[k] = []
				buckets[k].append(w)
	var fits := func(p: Vector2, level: int, stair_low: int) -> bool:
		var r := Rect2(box.position + p, box.size)
		for bx in range(floori(r.position.x / 64.0), floori(r.end.x / 64.0) + 1):
			for by in range(floori(r.position.y / 64.0), floori(r.end.y / 64.0) + 1):
				for w: Rect2 in buckets.get(Vector2i(bx, by), []):
					if w.intersects(r):
						return false
		for c in [r.position, Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), r.end]:
			if not grid.cell_ok(MapGrid.cell_at(c), level, stair_low):
				return false
		return true
	var start: Vector2 = grid.anchors[0]
	assert(fits.call(start, 0, -1), "the hero's box does not fit where they start")
	var first := Vector3i(0, 0, 0)
	var seen := {first: true}
	var queue: Array[Vector3i] = [first]
	var reached: Array[Vector2] = []
	while not queue.is_empty():
		var k: Vector3i = queue.pop_back()
		var here := start + Vector2(k.x, k.y) * 8.0
		reached.append(here)
		var low := grid.stair_low_at(here)
		for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
			var p := start + Vector2(k.x + d.x, k.y + d.y) * 8.0
			if not fits.call(p, k.z, low):
				continue
			var nk := Vector3i(k.x + d.x, k.y + d.y, grid.level_at(p, k.z))
			if not seen.has(nk):
				seen[nk] = true
				queue.append(nk)
	var stops: Array = []
	for st in 3:
		stops.append(["station %d" % (st + 1), (screen.stations.nodes[st] as Node2D).position])
	for n in G.TOTAL_ITEMS:
		stops.append(["circle %d" % (n + 1), (screen._circles[n] as Node2D).position])
	stops.append(["the Victory Gate", screen.stations.gate.position])
	for stop: Array in stops:
		var near := false
		for p: Vector2 in reached:
			if p.distance_to(stop[1]) <= MapCfg.INTERACT_RADIUS:
				near = true
				break
		assert(near, "%s is out of the hero's reach with a %s Foot box" % [stop[0], box.size])
	print("hero box %s reaches all %d stops (%d spots)" % [box.size, stops.size(), reached.size()])
	_assert_stairs(screen)


## Every staircase can be climbed and left: from its foot, walking by level,
## the level above is reached; from beside its top, the level below.
func _assert_stairs(screen: Control) -> void:
	var grid: MapGrid = screen.grid
	var ramps := 0
	for c: Vector2i in grid.stairs:
		var s: Dictionary = grid.stairs[c]
		if bool(s.top):
			continue
		# Three rows (client, 2026-10-01): top, middle and this foot.
		assert(int(s.row) == 2 and int(grid.stairs.get(c + Vector2i(0, -1), {}).get("row", -1)) == 1
				and int(grid.stairs.get(c + Vector2i(0, -2), {}).get("row", -1)) == 0,
				"the stairs at %s are not three rows" % c)
		ramps += 1
		var low := int(s.low)
		var top: Vector2i = c + Vector2i(0, -1)
		var up := false
		for k: Vector2i in grid.flood(MapGrid.cell_mid(c), low):
			if int(grid.height.get(k, -1)) == low + 1 and not grid.stairs.has(k):
				up = true
				break
		assert(up, "the stairs at %s lead nowhere up" % c)
		var down := false
		var above: Vector2i = top - Vector2i(int(s.side), 0)
		for k: Vector2i in grid.flood(MapGrid.cell_mid(above), low + 1):
			if int(grid.height.get(k, -1)) == low and not grid.stairs.has(k):
				down = true
				break
		assert(down, "the stairs at %s cannot be come down" % c)
	assert(ramps >= 6, "only %d staircases" % ramps)
	print("stairs: %d, every one climbable and come down" % ramps)


## The hero, by the real keys, climbs every ramp and comes back down: straight
## up from the ground under its foot, and on from the side onto its middle row
## -- the room the client asked for (2026-10-01) -- and off the other side.
func _assert_climbs(screen: Control) -> void:
	var grid: MapGrid = screen.grid
	screen.skip_intro()
	root.get_node("Game").call("_setup_input")   # the keys, before Game's own _ready
	var was: Vector2 = screen.player.position
	# Holds `action` for `secs`, or until `done` says the walk has got there.
	var hold := func(action: String, secs: float, done := Callable()) -> void:
		Input.action_press(action)
		for i in int(secs * 60):
			screen._process(1.0 / 60.0)
			if done.is_valid() and done.call():
				break
		Input.action_release(action)
	var placed := func(c: Vector2i, low: int) -> bool:
		screen.player.position = MapGrid.cell_mid(c) + Vector2(0, 4)
		screen.hero_level = low
		return grid.box_walkable(screen.player.position, screen.hero_box, low)
	var climbed := 0
	for c: Vector2i in grid.stairs:
		var st: Dictionary = grid.stairs[c]
		var low := int(st.low)
		var flat := func(k: Vector2i) -> bool:
			return grid.land.has(k) and not grid.cliff.has(k) and not grid.stairs.has(k) \
				and int(grid.height.get(k, -1)) == low
		if int(st.row) == 2 and flat.call(c + Vector2i(0, 1)) and placed.call(c + Vector2i(0, 1), low):
			hold.call("move_up", 3.0)
			var top: int = screen.hero_level
			# Up: off the ramp onto higher ground (on the summit's stacked pair,
			# straight on up the next ramp too).
			assert(top > low and not grid.stairs.has(MapGrid.cell_at(screen.player.position)),
					"the hero cannot climb the stair at %s (stopped at %s)" % [c, screen.player.position])
			hold.call("move_down", 3.0)
			assert(screen.hero_level < top, "the hero cannot come down the stair at %s" % c)
			climbed += 1
		var side := int(st.side)
		if int(st.row) == 1 and flat.call(c + Vector2i(side, 0)) and placed.call(c + Vector2i(side, 0), low):
			var on := "move_right" if side < 0 else "move_left"
			var off := "move_left" if side < 0 else "move_right"
			# Until he is up, or the summit's stacked pair takes him on up the next.
			var up := func() -> bool:
				return screen.hero_level == low + 1 and not grid.stairs.has(MapGrid.cell_at(screen.player.position))
			hold.call(on, 2.0, up)
			assert(screen.hero_level == low + 1 and not grid.stairs.has(MapGrid.cell_at(screen.player.position)),
					"the hero cannot cross the stair at %s from the side (stopped at %s)" % [c, screen.player.position])
			hold.call(off, 2.0)
			assert(screen.hero_level == low, "the hero cannot come back off the stair at %s" % c)
			climbed += 1
	assert(climbed >= 20, "only %d climbs" % climbed)
	screen.player.position = was
	screen.hero_level = 0
	print("hero climbs and comes down %d times, from below and from the side" % climbed)


func _reachable(screen: Control) -> Dictionary:
	return screen.grid.flood(screen.grid.anchors[0], 0)
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
	var screen: Control = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(screen)
	screen.setup({})

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
	assert(screen.stations.gate != null, "no victory gate")
	assert(screen.grid.is_walkable(screen.stations.gate.position), "the gate is not walkable")

	# Props are solid at the base -- a trunk, a rock's body -- and the road is
	# not: the hero used to walk straight through the forest.
	var feet: Array[Rect2] = screen.decor.feet
	assert(feet.size() > 50, "props have no solid bases (%d)" % feet.size())
	for r: Rect2 in feet:
		assert(not screen.grid.is_walkable(r.get_center()), "a prop's base is walkable")
		assert(not screen.grid.trail.has(_cell(screen, r.get_center())),
			"a prop stands on the road")

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
	# Every crossing is a land bridge now, so every gate is a body in a wall of
	# rocks -- two of them straight across the walk, one a fence curved right round
	# the station it guards. The proof does not care which: walk the ground and see
	# where you can get to.
	G.begin_adventure(600)
	assert(screen.barricades.list.size() == 3,
			"expected 3 barricades, got %d" % screen.barricades.list.size())
	for g: Dictionary in screen.barricades.list:
		var who: int = int(g.st) + 1
		assert(not bool(g.open), "station %d's barricade starts open" % who)
		assert(g.guard != null, "station %d has no guard on a fresh run" % who)
		assert(not screen.grid.is_walkable((g.wall as Rect2).get_center()),
				"station %d's guard is not solid" % who)
		assert(screen.grid.clear_of_anchors(g.wall),
				"station %d's wall swallows a stop on the board" % who)
		_assert_line(screen, g)
		# He steps aside rather than vanishing, so the spot has to be real ground:
		# open, off the road, and not back inside the rocks he was standing in.
		var rest: Vector2 = g.stand
		assert(screen.grid.is_walkable(rest), "station %d's guard steps into a wall" % who)
		assert(not screen.grid.trail.has(_cell(screen, rest)),
				"station %d's guard steps down onto the road" % who)
		assert(rest.distance_to(g.post as Vector2) > MapCfg.TILE,
				"station %d's guard steps down into the gap he was plugging" % who)

	# Station 1's door has to stay usable from the bridge side, or the briefing
	# that stands its guard down can never happen.
	var door: Vector2 = screen.grid.anchors[1]
	assert(screen.grid.is_walkable(door), "Station 1's doorstep is inside the wall")
	var held := _reachable(screen)
	assert(held.has(_cell(screen, door)),
			"Station 1 is unreachable from camp, so it can never be briefed")
	# Which is the whole point: with the guards in their gaps, nothing past any of
	# the three is walkable-to, and `_assert_islands()` is what proves it.
	_assert_islands(screen, G, -1)

	# Each one opens in turn, and the rocks stay -- only the gap does.
	for st in 3:
		var g: Dictionary = screen.barricades.list[st]
		screen.barricades.open(g)
		assert(screen.grid.is_walkable((g.wall as Rect2).get_center()),
				"station %d's wall outlived its guard" % (st + 1))
		_assert_line(screen, g)
		_assert_islands(screen, G, st)

	# ...and each one waits on its own station's briefing and nothing else:
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
			"the gap is walled on a run that was already briefed")
	assert(briefed.barricades.list[0].guard != null,
			"the briefed guard vanished instead of standing aside")
	for st in [1, 2]:
		assert(not bool(briefed.barricades.list[st].open),
				"station %d's guard gone on a briefed restart" % (st + 1))
	# The line is scenery, not a gate: it is laid on every build, open or not.
	_assert_line(briefed, briefed.barricades.list[0])

	# --- The dev drawer's Skip Station --------------------------------------
	# It is the shortcut the later islands are tested through, so it has to leave
	# the board in exactly the state playing the questions would: each skip banks
	# one station and opens what that station's progress opens, and nothing ahead
	# of it. Proved the same way as everything else here -- by walking the ground.
	var rig: Control = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(rig)
	G.begin_adventure(600)
	rig.setup({})
	assert(rig.hud.dev != null, "no dev drawer on a debug build")
	_assert_islands(rig, G, -1)
	for st in 3:
		rig.hud.dev._skip_station()
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
	rig.hud.dev._skip_station()
	assert(G.items_done == G.TOTAL_ITEMS, "skipping a cleared board ran past the end")

	print("collisions ok")
	quit()


## The rung of `opened` at which each station's doorstep becomes walkable-to.
const TOWER_OPENS_AT := [-1, 0, 1]


## `opened` is how many guards have stood down, or -1 while all three still hold.
## Station `st`'s circles are walkable-to from the base camp exactly when
## `opened >= st`, and the Victory Gate once the last guard has moved -- it stands
## past Station 3's wall with its circles.
func _assert_islands(screen: Control, G: Node, opened: int) -> void:
	var reach := _reachable(screen)
	for n in G.TOTAL_ITEMS:
		var st: int = G.station_of_item(n)
		var pos: Vector2 = (screen._circles[n] as Node2D).position
		var cell := Vector2i(floori(pos.x / MapCfg.TILE), floori(pos.y / MapCfg.TILE))
		if opened >= st:
			assert(reach.has(cell),
					"circle %d (station %d) unreachable with %d guard(s) stood down" % [n + 1, st + 1, opened])
		else:
			assert(not reach.has(cell),
					"circle %d (station %d) reachable with only %d guard(s) stood down" % [n + 1, st + 1, opened])
	for st in 3:
		var tp: Vector2 = (screen.stations.nodes[st] as Node2D).position
		var tcell := Vector2i(floori(tp.x / MapCfg.TILE), floori(tp.y / MapCfg.TILE))
		# Every station stands on the near side of its own guard -- you have to
		# reach a station to be briefed by it, which is what moves him. So a tower
		# waits on whatever gate is in front of it, not on its own: Station 1 is
		# open from the first step, Station 2 is over the bridge that leaves past
		# Station 1's knight, and Station 3 over the one past Station 2's.
		assert(reach.has(tcell) == (opened >= TOWER_OPENS_AT[st]),
				"Tower %d reachability wrong with %d gate(s) open" % [st + 1, opened])
	var gate: Vector2 = (screen.stations.gate as Node2D).position
	var gcell := Vector2i(floori(gate.x / MapCfg.TILE), floori(gate.y / MapCfg.TILE))
	assert(reach.has(gcell) == (opened >= 2),
			"victory gate reachability wrong with %d guard(s) stood down" % opened)


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


## One barricade's boulders: every rock solid, and none of them swallowing a stop
## on the board. That the fence actually *seals* is not checked here and cannot
## usefully be -- one is a straight line across the walk and the other a curve
## right round a station, and "does it hold" has the same answer for both:
## `_assert_islands()` walks the ground from the base camp and sees where it gets.
func _assert_line(screen: Control, g: Dictionary) -> void:
	var rocks: Array = g.rocks
	var who: int = int(g.st) + 1
	assert(rocks.size() >= 3,
			"station %d's boulder line is only %d rocks long" % [who, rocks.size()])
	var in_the_sea := 0
	for r in rocks:
		var rock: Rect2 = r
		assert(not screen.grid.is_walkable(rock.get_center()),
				"a boulder at %s is not solid" % rock.get_center())
		assert(screen.grid.clear_of_anchors(rock),
				"a boulder at %s swallows a stop on the board" % rock.get_center())
		# The cell the boulder was laid on, back out of the wall that stands on it.
		var cell: Vector2i = MapGrid.cell_at(rock.get_center()
				+ Vector2(0.0, MapCfg.ROCK_WALL.y * 0.5 + MapCfg.ROCK_WALL_BASE))
		# `Art.sprite()` draws a boulder upward from its cell, so a wall centred on
		# the cell blocks a tile of open grass *below* the stone -- the bump into
		# nothing that made this fence feel unfinished. The wall stands on the art.
		assert(rock.end.y <= MapGrid.cell_mid(cell).y,
				"the wall at %s sits below its boulder" % rock.get_center())
		if not screen.grid.land.has(cell):
			in_the_sea += 1
	# Which leaves the cell at each arm's end -- the stone's own foot -- open, and
	# that foot is the way round the whole fence. So each arm takes one more step,
	# into the shallows, and there the beach behind the last stone is the wall.
	assert(in_the_sea == 2,
			"station %d's fence ends on dry land (%d stones in the water)" % [who, in_the_sea])


## Cells walkable from the base camp, by flood fill over cell centres.
func _reachable(screen: Control) -> Dictionary:
	var start: Vector2 = screen.grid.anchors[0]
	var seen := {}
	var queue: Array[Vector2i] = [Vector2i(floori(start.x / MapCfg.TILE), floori(start.y / MapCfg.TILE))]
	seen[queue[0]] = true
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
			var nc: Vector2i = c + d
			if seen.has(nc) or not MapGrid.in_bounds(nc):
				continue
			if not screen.grid.is_walkable(MapGrid.cell_mid(nc)):
				continue
			seen[nc] = true
			queue.append(nc)
	return seen

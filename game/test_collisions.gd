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
		var at: Vector2 = screen._station_nodes[i].position
		# Off the station itself, not `_solid[i]`: the outpost's houses append walls
		# too, so the array is no longer one entry per station.
		var wall: Rect2 = (screen._station_nodes[i] as Node2D).get_meta("wall")
		var mid_y: float = wall.get_center().y

		assert(not screen._is_walkable(wall.get_center()),
				"station %d: centre of the walls is walkable" % i)
		assert(not screen._is_walkable(Vector2(wall.position.x + 1.0, mid_y)),
				"station %d: left wall leaks" % i)
		assert(not screen._is_walkable(Vector2(wall.end.x - 1.0, mid_y)),
				"station %d: right wall leaks" % i)
		# The tower steps off the path -- up on a lane, sideways on a bend -- so the
		# wall is centred on the building, not on the doorstep.
		assert(not screen._is_walkable(Vector2(wall.get_center().x, wall.position.y + 1.0)),
				"station %d: back wall leaks" % i)

		# The doorstep -- the station node's own spot -- must stay open, or
		# INTERACT_RADIUS can never be satisfied and the quiz is unreachable.
		assert(screen._is_walkable(at),
				"station %d: doorstep is walled in, quiz unreachable" % i)
		assert(at.distance_to(screen._station_nodes[i].position) < screen.INTERACT_RADIUS)

		# The walls span the sprite, so no side is thinner than the art.
		assert(wall.size.x > screen.TILE, "station %d: walls thinner than a tile" % i)

	# --- The board path (Phase 1) ------------------------------------------
	var circles: Array = screen._circles
	assert(circles.size() == G.TOTAL_ITEMS,
			"expected %d circles, got %d" % [G.TOTAL_ITEMS, circles.size()])
	var seen := {}
	for n in circles.size():
		var pos: Vector2 = (circles[n] as Node2D).position
		assert(not seen.has(pos), "circle %d shares a spot with another" % n)
		seen[pos] = true
		assert(screen._is_walkable(pos), "circle %d stands on unwalkable ground" % n)
	assert(screen._gate != null, "no victory gate")
	assert(screen._is_walkable(screen._gate.position), "the gate is not walkable")

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
	G.begin_adventure(600)
	assert(screen._causeways.size() == 1,
			"expected 1 causeway, got %d" % screen._causeways.size())
	for i in screen._causeways.size():
		var cw: Dictionary = screen._causeways[i]
		assert(not cw.cells.is_empty(), "causeway %d found no water to cross" % i)
		assert(not bool(cw.open), "causeway %d starts open" % i)
		var mid: Vector2 = screen._cell_mid(cw.cells[cw.cells.size() / 2])
		assert(not screen._is_walkable(mid), "causeway %d is walkable before its station" % i)

	# --- The guards in the boulder lines ------------------------------------
	# Two of the three crossings are land bridges, so their gate is not terrain
	# that rises but a wall of rocks with a body in its one gap. Same proof
	# either way: walk the ground and see where you can get to.
	assert(screen._barricades.size() == 2,
			"expected 2 barricades, got %d" % screen._barricades.size())
	var b0: Dictionary = screen._barricades[0]
	var b1: Dictionary = screen._barricades[1]
	for g: Dictionary in [b0, b1]:
		var who: int = int(g.st) + 1
		assert(not bool(g.open), "station %d's barricade starts open" % who)
		assert(g.guard != null, "station %d has no guard on a fresh run" % who)
		assert(not screen._is_walkable((g.wall as Rect2).get_center()),
				"station %d's guard is not solid" % who)
		assert(screen._clear_of_anchors(g.wall),
				"station %d's wall swallows a stop on the board" % who)
		_assert_line(screen, g)
		# He steps aside rather than vanishing, so the spot has to be real ground:
		# open, off the road, and not back inside the rocks he was standing in.
		var rest: Vector2 = g.stand
		assert(screen._is_walkable(rest), "station %d's guard steps into a wall" % who)
		assert(not screen._trail.has(_cell(screen, rest)),
				"station %d's guard steps down onto the road" % who)
		assert(rest.distance_to(g.post as Vector2) > screen.TILE,
				"station %d's guard steps down into the gap he was plugging" % who)

	# Station 1's door has to stay usable from the bridge side, or the briefing
	# that stands its guard down can never happen.
	var door: Vector2 = screen._anchors[1]
	assert(screen._is_walkable(door), "Station 1's doorstep is inside the wall")
	var held := _reachable(screen)
	assert(held.has(_cell(screen, door)),
			"Station 1 is unreachable from camp, so it can never be briefed")
	# Which is the whole point: with the guards in their gaps, nothing past either
	# line is walkable-to, and `_assert_islands()` is what proves it.
	_assert_islands(screen, G, -1)

	screen._open_barricade(b0)
	assert(screen._is_walkable((b0.wall as Rect2).get_center()),
			"station 1's wall outlived its guard")
	# He goes, the rocks do not -- only his gap opens.
	_assert_line(screen, b0)
	_assert_islands(screen, G, 0)

	screen._open_barricade(b1)
	assert(screen._is_walkable((b1.wall as Rect2).get_center()),
			"station 2's wall outlived its guard")
	_assert_line(screen, b1)
	_assert_islands(screen, G, 1)

	screen.open_causeway(0)
	assert(screen._is_walkable(screen._cell_mid(screen._causeways[0].cells[0])),
			"the causeway stayed water after it opened")
	_assert_islands(screen, G, 2)

	# ...and each gate lifts on its own: Station 1's guard on its briefing,
	# Station 2's and the causeway when the station before them runs out of circles.
	var fresh: Control = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(fresh)
	G.begin_adventure(600)
	fresh.setup({})
	assert(not bool(fresh._barricades[0].open), "station 1's guard gone before the briefing")
	assert(not bool(fresh._barricades[1].open), "station 2's guard gone before its briefing")
	assert(not bool(fresh._causeways[0].open), "causeway open at circle 0")
	# A guard waits on his own station's briefing and nothing else -- clearing the
	# station before his does not move him.
	for n in G.ITEMS_PER_STATION[0]:
		G.mark_correct()
	fresh._refresh_barricades()
	fresh._refresh_causeways()
	assert(not bool(fresh._barricades[0].open),
			"station 1's guard stood down on circles rather than on its briefing")
	assert(not bool(fresh._barricades[1].open),
			"station 2's guard stood down before his own briefing")
	assert(not bool(fresh._causeways[0].open), "causeway opened one station early")
	# ...and the causeway is the one that does wait on circles, a station later.
	G.towers_entered[1] = true
	for n in G.ITEMS_PER_STATION[1]:
		G.mark_correct()
	fresh._refresh_barricades()
	fresh._refresh_causeways()
	assert(bool(fresh._barricades[1].open), "station 2's guard held after its briefing")
	assert(bool(fresh._causeways[0].open), "causeway shut after Station 2 was cleared")

	# A restart mid-run keeps what it had already earned: the guard is not a wall
	# any more, but he is still standing there, beside his station.
	var briefed: Control = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(briefed)
	G.begin_adventure(600)
	G.towers_entered[0] = true
	briefed.setup({})
	assert(bool(briefed._barricades[0].open),
			"station 1's guard re-posted on a run that was already briefed")
	assert(briefed._is_walkable((briefed._barricades[0].wall as Rect2).get_center()),
			"the gap is walled on a run that was already briefed")
	assert(briefed._barricades[0].guard != null,
			"the briefed guard vanished instead of standing aside")
	assert(not bool(briefed._barricades[1].open), "station 2's guard gone on a briefed restart")
	# The line is scenery, not a gate: it is laid on every build, open or not.
	_assert_line(briefed, briefed._barricades[0])

	# --- The dev drawer's Skip Station --------------------------------------
	# It is the shortcut the later islands are tested through, so it has to leave
	# the board in exactly the state playing the questions would: each skip banks
	# one station and opens what that station's progress opens, and nothing ahead
	# of it. Proved the same way as everything else here -- by walking the ground.
	var rig: Control = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(rig)
	G.begin_adventure(600)
	rig.setup({})
	assert(rig._dev != null, "no dev drawer on a debug build")
	_assert_islands(rig, G, -1)
	for st in 3:
		rig._dev._skip_station()
		assert(G.items_done == _items_through(G, st),
				"skipping station %d left %d items done" % [st + 1, G.items_done])
		assert(bool(G.completed_stations[st]), "station %d was not banked" % (st + 1))
		# A skip briefs the tower, which stands that station's own guard down, and
		# empties its circles, which is what the causeway waits on. So skipping
		# Station 1 opens one gate, skipping Station 2 opens its guard AND the
		# causeway behind it, and the last skip has nothing left to open.
		_assert_islands(rig, G, [0, 2, 2][st])
	assert(G.items_done == G.TOTAL_ITEMS,
			"three skips left %d of %d items" % [G.items_done, G.TOTAL_ITEMS])
	assert(rig._can_enter_gate(), "the Victory Gate stayed shut after three skips")
	# ...and it is not a way past the end of the board.
	rig._dev._skip_station()
	assert(G.items_done == G.TOTAL_ITEMS, "skipping a cleared board ran past the end")

	print("collisions ok")
	quit()


## The rung of `opened` at which each station's doorstep becomes walkable-to.
const TOWER_OPENS_AT := [-1, 0, 2]


## `opened` is how many causeways have risen, or -1 while the knight still holds the
## neck. Station `st`'s circles are walkable-to from the base camp exactly when
## `opened >= st`; the gate needs both causeways. Tower 1 is the exception and the
## point of the layout: it stands on the headland this side of the knight, so it is
## reachable from the very first step while Towers 2 and 3 are not.
func _assert_islands(screen: Control, G: Node, opened: int) -> void:
	var reach := _reachable(screen)
	for n in G.TOTAL_ITEMS:
		var st: int = G.station_of_item(n)
		var pos: Vector2 = (screen._circles[n] as Node2D).position
		var cell := Vector2i(floori(pos.x / screen.TILE), floori(pos.y / screen.TILE))
		if opened >= st:
			assert(reach.has(cell),
					"circle %d (station %d) unreachable with %d causeway(s) open" % [n + 1, st + 1, opened])
		else:
			assert(not reach.has(cell),
					"circle %d (station %d) reachable with only %d causeway(s) open" % [n + 1, st + 1, opened])
	for st in 3:
		var tp: Vector2 = (screen._station_nodes[st] as Node2D).position
		var tcell := Vector2i(floori(tp.x / screen.TILE), floori(tp.y / screen.TILE))
		# Every station stands on the near side of its own guard -- you have to
		# reach a station to be briefed by it, which is what moves him. So a tower
		# waits on whatever gate is in front of it, not on its own: Station 1 is
		# open from the first step, Station 2 is over the bridge that leaves past
		# Station 1's knight, and Station 3 is across the causeway.
		assert(reach.has(tcell) == (opened >= TOWER_OPENS_AT[st]),
				"Tower %d reachability wrong with %d gate(s) open" % [st + 1, opened])
	var gate: Vector2 = (screen._gate as Node2D).position
	var gcell := Vector2i(floori(gate.x / screen.TILE), floori(gate.y / screen.TILE))
	assert(reach.has(gcell) == (opened >= 2),
			"victory gate reachability wrong with %d causeway(s) open" % opened)


## Circles resolved by the time station `st` is done -- the same running total
## `AdventureScreen._items_through()` walks, spelled here so the test does not
## lean on the thing it is checking.
static func _items_through(G: Node, st: int) -> int:
	var n := 0
	for i in st + 1:
		n += G.ITEMS_PER_STATION[i]
	return n


static func _cell(screen: Control, at: Vector2) -> Vector2i:
	return Vector2i(floori(at.x / screen.TILE), floori(at.y / screen.TILE))


## One barricade's boulder line: every rock solid and clear of the board, and both
## ends of the line running off the land -- if either end stopped short there would
## be a way round it and the guard would be decoration.
func _assert_line(screen: Control, g: Dictionary) -> void:
	var rocks: Array = g.rocks
	var who: int = int(g.st) + 1
	assert(rocks.size() >= 3,
			"station %d's boulder line is only %d rocks long" % [who, rocks.size()])
	for r in rocks:
		assert(not screen._is_walkable((r as Rect2).get_center()),
				"a boulder at %s is not solid" % (r as Rect2).get_center())
		assert(screen._clear_of_anchors(r),
				"a boulder at %s swallows a stop on the board" % (r as Rect2).get_center())
	# The rocks are laid outward from the gap in both directions until they run out
	# of land, so the ends are the two extremes along the line's own axis.
	var axis := 0 if absf(rocks[0].position.x - rocks[rocks.size() - 1].position.x) \
			> absf(rocks[0].position.y - rocks[rocks.size() - 1].position.y) else 1
	var lo: Rect2 = rocks[0]
	var hi: Rect2 = rocks[0]
	for r in rocks:
		if (r as Rect2).get_center()[axis] < lo.get_center()[axis]:
			lo = r
		if (r as Rect2).get_center()[axis] > hi.get_center()[axis]:
			hi = r
	for spec in [[lo, -1.0], [hi, 1.0]]:
		var beyond: Vector2 = (spec[0] as Rect2).get_center()
		beyond[axis] += float(spec[1]) * screen.TILE
		assert(not screen._land.has(_cell(screen, beyond)),
				"station %d's line stops on dry land at %s -- walk around it" % [who, beyond])


## Cells walkable from the base camp, by flood fill over cell centres.
func _reachable(screen: Control) -> Dictionary:
	var start: Vector2 = screen._anchors[0]
	var seen := {}
	var queue: Array[Vector2i] = [Vector2i(floori(start.x / screen.TILE), floori(start.y / screen.TILE))]
	seen[queue[0]] = true
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
			var nc: Vector2i = c + d
			if seen.has(nc) or not screen._in_bounds(nc):
				continue
			if not screen._is_walkable(screen._cell_mid(nc)):
				continue
			seen[nc] = true
			queue.append(nc)
	return seen

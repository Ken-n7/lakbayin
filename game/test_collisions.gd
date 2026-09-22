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

	# --- Region gating: the causeway is the ONLY way between islands --------
	# Flood-fill from the base camp over walkable ground. This is what actually
	# proves the gate: a flag can be checked, but only reachability shows that the
	# next island cannot be reached by walking around the obstacle.
	G.begin_adventure(600)
	assert(screen._causeways.size() == 2, "expected 2 causeways, got %d" % screen._causeways.size())
	for i in 2:
		var cw: Dictionary = screen._causeways[i]
		assert(not cw.cells.is_empty(), "causeway %d found no water to cross" % i)
		assert(not bool(cw.open), "causeway %d starts open" % i)
		var mid: Vector2 = screen._cell_mid(cw.cells[cw.cells.size() / 2])
		assert(not screen._is_walkable(mid), "causeway %d is walkable before its station" % i)

	# --- The knight in the neck --------------------------------------------
	# The camp crossing is a land bridge, so the first gate is not terrain that
	# rises but a body standing in the one place the geography is narrow. Same
	# proof either way: walk the ground and see where you can get to.
	assert(screen._knight != null, "no knight posted on a fresh run")
	assert(not screen._is_walkable(screen._knight_wall.get_center()),
			"the knight is not solid")
	assert(screen._clear_of_anchors(screen._knight_wall),
			"the knight's wall swallows a stop on the board")
	# ...and the door he is guarding has to stay usable from the bridge side, or
	# the briefing that dismisses him can never happen.
	var door: Vector2 = screen._anchors[1]
	assert(screen._is_walkable(door), "Tower 1's doorstep is inside the knight's wall")
	var held := _reachable(screen)
	assert(held.has(Vector2i(floori(door.x / screen.TILE), floori(door.y / screen.TILE))),
			"Tower 1 is unreachable from camp, so it can never be briefed")
	_assert_islands(screen, G, -1)

	screen._dismiss_knight()
	assert(screen._is_walkable(screen._knight_wall.get_center()),
			"the knight's wall outlived him")
	_assert_islands(screen, G, 0)
	screen.open_causeway(0)
	assert(screen._is_walkable(screen._cell_mid(screen._causeways[0].cells[0])),
			"causeway 0 stayed water after it opened")
	_assert_islands(screen, G, 1)
	screen.open_causeway(1)
	_assert_islands(screen, G, 2)

	# ...and each gate lifts on its own: the knight on the Station 1 briefing, the
	# causeways the moment their station runs out of circles.
	var fresh: Control = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(fresh)
	G.begin_adventure(600)
	fresh.setup({})
	assert(fresh._knight != null, "knight missing before the briefing")
	assert(not bool(fresh._causeways[0].open), "causeway 0 open at circle 0")
	for n in G.ITEMS_PER_STATION[0]:
		G.mark_correct()
	fresh._refresh_causeways()
	assert(bool(fresh._causeways[0].open), "causeway 0 shut after Station 1 was cleared")
	assert(not bool(fresh._causeways[1].open), "causeway 1 opened one station early")

	# A restart mid-run keeps what it had already briefed, so it never posts him.
	var briefed: Control = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(briefed)
	G.begin_adventure(600)
	G.towers_entered[0] = true
	briefed.setup({})
	assert(briefed._knight == null, "knight re-posted on a run that was already briefed")
	assert(briefed._is_walkable(briefed._knight_wall.get_center()),
			"the neck is walled on a run that was already briefed")

	print("collisions ok")
	quit()


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
		assert(reach.has(tcell) == (st == 0 or opened >= st),
				"Tower %d reachability wrong with %d causeway(s) open" % [st + 1, opened])
	var gate: Vector2 = (screen._gate as Node2D).position
	var gcell := Vector2i(floori(gate.x / screen.TILE), floori(gate.y / screen.TILE))
	assert(reach.has(gcell) == (opened >= 2),
			"victory gate reachability wrong with %d causeway(s) open" % opened)


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

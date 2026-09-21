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
		var wall: Rect2 = screen._solid[i]
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
	assert(G.items_done == G.TOTAL_ITEMS, "40 circles resolved: %d" % G.items_done)
	assert(screen._can_enter_gate(), "the gate stayed shut after all 40 circles")

	print("collisions ok")
	quit()

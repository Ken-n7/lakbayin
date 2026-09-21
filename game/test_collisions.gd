extends SceneTree

## Self-check for the building walls. Run:
##   godot --headless --path game --script res://test_collisions.gd
##
## The bug this guards: footprints used to be rounded to whole tiles and a cell
## only counted as blocked when its CENTRE fell inside the walls. The Blue
## Tower is 60 world px wide against a 32px grid, so exactly one column ever
## blocked and the hero walked in through either side.

func _initialize() -> void:
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
		assert(not screen._is_walkable(Vector2(at.x, wall.position.y + 1.0)),
				"station %d: back wall leaks" % i)

		# The doorstep -- the station node's own spot -- must stay open, or
		# INTERACT_RADIUS can never be satisfied and the quiz is unreachable.
		assert(screen._is_walkable(at),
				"station %d: doorstep is walled in, quiz unreachable" % i)
		assert(at.distance_to(screen._station_nodes[i].position) < screen.INTERACT_RADIUS)

		# The walls span the sprite, so no side is thinner than the art.
		assert(wall.size.x > screen.TILE, "station %d: walls thinner than a tile" % i)

	print("collisions ok")
	quit()

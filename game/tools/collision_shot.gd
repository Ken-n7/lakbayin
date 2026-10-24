extends Node

## The whole world of one seed, drawn at 2x with what stops the hero over it:
## walls red, cliff faces orange, stairs cyan, the hero's feet box yellow at
## each spawn. For checking the collision boxes against the art by eye.
## Windowed, like ui_shot:
##
##   godot --path game res://tools/collision_shot.tscn -- <out.png> [seed | board]
##
## `board`: world_test's hand-drawn plateau and hill instead, painted, with a
## hero and a tree on each level, to see the levels drawn and sorted.

const K := 2


class Overlay extends Node2D:
	var grid: MapGrid
	var feet: Array[Rect2] = []

	func _draw() -> void:
		var t := float(MapCfg.TILE)
		for c: Vector2i in grid.cliff:
			draw_rect(Rect2(Vector2(c) * t, Vector2.ONE * t), Color(1, 0.5, 0, 0.35))
		for c: Vector2i in grid.stairs:
			draw_rect(Rect2(Vector2(c) * t, Vector2.ONE * t), Color(0, 1, 1, 0.3))
		for r in grid.solid:
			draw_rect(r, Color(1, 0, 0, 0.35))
			draw_rect(r, Color(1, 0, 0), false, 0.5)
		for r in feet:
			draw_rect(r, Color(1, 1, 0, 0.6))


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://collisions.png"
	var size := Vector2i(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE
	var vp := SubViewport.new()
	vp.size = size * K
	vp.size_2d_override = size
	vp.size_2d_override_stretch = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var hero: Node2D = load(MapCfg.HERO_SCENE).instantiate()
	var box: RectangleShape2D = hero.get_node("Foot/Box").shape
	var at: Vector2 = hero.get_node("Foot/Box").position
	hero.free()
	var o := Overlay.new()
	var world: Node2D
	if args.size() > 1 and args[1] == "board":
		world = _board(vp, o)
	else:
		var w := MapWorld.new()
		w.seed = int(args[1]) if args.size() > 1 else 1
		vp.add_child(w)
		w.build()
		for c in w.cloud_bands:
			c.visible = false
		o.grid = w.grid
		for s in w.gen.spawns:
			o.feet.append(Rect2(s + at - box.size * 0.5, box.size))
		world = w
	o.z_index = 100
	world.add_child(o)
	for i in 10:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	vp.get_texture().get_image().save_png(out)
	print("ok ", out)
	# And as the player sees it.
	o.visible = false
	for i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	vp.get_texture().get_image().save_png(out.get_basename() + "_plain.png")
	get_tree().quit(0)


func _board(vp: SubViewport, o: Overlay) -> Node2D:
	var world := Node2D.new()
	world.y_sort_enabled = true
	vp.add_child(world)
	var grid: MapGrid = load("res://scripts/tests/world_test.gd").board()
	var b := MapBuilder.new(world, grid)
	b.build_terrain()
	b.retile(grid.land.keys())
	b.paint_levels()
	o.grid = grid
	var t := float(MapCfg.TILE)
	# A hero on the ground under the cliff, on the plateau's rim over it, on
	# the hill, on each ramp; trees under the cliff, on the rim, behind it.
	for p in [Vector2(10.5, 11.6), Vector2(7.5, 9.9), Vector2(11.5, 6.9), Vector2(16.5, 9.5),
			Vector2(13.5, 6.5), Vector2(5.5, 6.5)]:
		var h: Node2D = load(MapCfg.HERO_SCENE).instantiate()
		h.position = p * t
		world.add_child(h)
	var props := Node2D.new()
	props.y_sort_enabled = true
	world.add_child(props)
	for d in [["Tree1", Vector2(8.5, 11.5)], ["Tree2", Vector2(13.5, 9.8)], ["Rock2", Vector2(10.5, 3.9)],
			["Tree3", Vector2(11, 2.6)], ["Tree4", Vector2(3.5, 9.5)]]:
		var prop: Node2D = load(MapCfg.PROP_SCENE % d[0]).instantiate()
		prop.position = (d[1] as Vector2) * t
		props.add_child(prop)
	Decor.new(world, grid).solidify(props)
	return world


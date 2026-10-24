extends Node

## The whole world of one seed, drawn at 2x with what stops the hero over it:
## walls red, cliff faces orange, stairs cyan, the hero's feet box yellow at
## each spawn. For checking the collision boxes against the art by eye.
## Windowed, like ui_shot:
##
##   godot --path game res://tools/collision_shot.tscn -- <out.png> [seed]

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
	var world := MapWorld.new()
	world.seed = int(args[1]) if args.size() > 1 else 1
	vp.add_child(world)
	world.build()
	for c in world.cloud_bands:
		c.visible = false
	var hero: Node2D = load(MapCfg.HERO_SCENE).instantiate()
	var box: RectangleShape2D = hero.get_node("Foot/Box").shape
	var at: Vector2 = hero.get_node("Foot/Box").position
	hero.free()
	var o := Overlay.new()
	o.grid = world.grid
	for s in world.gen.spawns:
		o.feet.append(Rect2(s + at - box.size * 0.5, box.size))
	o.z_index = 100
	world.add_child(o)
	for i in 10:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	vp.get_texture().get_image().save_png(out)
	print("ok ", out)
	get_tree().quit(0)

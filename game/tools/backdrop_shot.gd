extends Node

## The menu backdrop's whole strip in one picture, at 3x like a phone draws it:
##
##   godot --path game res://tools/backdrop_shot.tscn -- <out.png>

func _ready() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	var vp := SubViewport.new()
	var world := Vector2i(int(Backdrop.W * Backdrop.TILE), int(Backdrop.H * Backdrop.TILE))
	vp.size = world * 3
	vp.size_2d_override = world
	vp.size_2d_override_stretch = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var b := Backdrop.new()
	vp.add_child(b)
	for i in 90:
		await get_tree().process_frame
	vp.get_texture().get_image().save_png(out)
	# The cells, for placing props: . sea, # ground, ^ raised, C cliff, S ramp.
	for y in Backdrop.H:
		var row := "%2d " % y
		for x in Backdrop.W:
			var c := Vector2i(x, y)
			row += "S" if b.grid.stairs.has(c) else "C" if b.grid.cliff.has(c) else \
				"^" if int(b.grid.height.get(c, -1)) > 0 else "#" if b.grid.land.has(c) else "."
		print(row)
	for bad in preload("res://scripts/tests/backdrop_test.gd").misplaced(b, b.grid.land, b.grid):
		print("misplaced: ", bad)
	get_tree().quit(0)

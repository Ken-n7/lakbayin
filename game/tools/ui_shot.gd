extends Node

## Screenshots of the menu screens, for looking at layout rather than measuring
## it. Windowed -- it needs a real GL context, so no `--headless`:
##
##   godot --path game res://tools/ui_shot.tscn -- <out dir> [screen ...]
##
## Renders into a SubViewport rather than photographing the window. Capturing
## `root.get_texture()` returned a flat fill here however long it waited -- the
## GUI never reached the window texture on this session -- while a SubViewport
## draws to its own target and hands back exactly what it drew.

const SHOT_SIZE := Vector2i(1280, 720)
const DEFAULT := ["home", "admin"]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://"
	var wanted: Array = args.slice(1) if args.size() > 1 else DEFAULT

	var vp := SubViewport.new()
	vp.size = Vector2i(640, 360)
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.handle_input_locally = false
	add_child(vp)

	var main: Control = load("res://scenes/Main.tscn").instantiate()
	vp.add_child(main)
	await get_tree().process_frame

	for name: String in wanted:
		main.open(name)
		for i in 60:
			await get_tree().process_frame
		# The viewport texture holds the last *drawn* frame, so the capture has
		# to wait for the draw, not merely for the frame to be processed.
		await RenderingServer.frame_post_draw
		var path: String = out.path_join("%s.png" % name)
		var err := vp.get_texture().get_image().save_png(path)
		print("%s  %s" % ["ok " if err == OK else "FAIL", ProjectSettings.globalize_path(path)])
	get_tree().quit(0)

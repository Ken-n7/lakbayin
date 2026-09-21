extends SceneTree
## Dev probe: force-compile a single script and surface its parse errors.
func _initialize() -> void:
	for path in OS.get_cmdline_user_args():
		var s := load(path)
		print("loaded ", path, " -> ", s)
	quit(0)
extends Node

## Does a plain launch -- no env vars -- now reach the login screen? That is
## what a phone does, and the APK had no keys at all until the settings landed.

func _ready() -> void:
	await get_tree().process_frame
	var fails := 0
	print("  ", "ok    " if Net.configured() else "FAIL  ", "backend configured with no env vars")
	if not Net.configured():
		fails += 1
	var main: Control = load("res://scripts/Main.gd").new()
	get_tree().root.add_child(main)
	await get_tree().process_frame
	main.current.skip()
	await get_tree().process_frame
	var path: String = main.current.get_script().resource_path
	var gated: bool = path.ends_with("LoginScreen.gd")
	print("  ", "ok    " if gated else "FAIL  ", "launch lands on the login screen  ", path)
	if not gated:
		fails += 1
	print("---- GATE %s ----" % ("PASS" if fails == 0 else "FAIL"))
	get_tree().quit(fails)

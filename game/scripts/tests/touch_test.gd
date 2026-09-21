extends Node
## The on-screen d-pad: a TouchScreenButton feeds a real InputMap action, so
## this pokes the buttons through the viewport and checks the hero actually
## walks. Run with:  godot --headless res://scripts/tests/touch_test.tscn

var failures := 0
var checks := 0
var _map: Node = null


func check(name: String, condition: bool, detail := "") -> void:
	checks += 1
	if condition:
		print("  ok    ", name)
	else:
		failures += 1
		print("  FAIL  ", name, "  ", detail)


## Viewport coordinates: the pad is laid out in the 640x360 design space.
func touch(at: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = 0
	ev.position = at
	ev.pressed = pressed
	get_viewport().push_input(ev, true)


func frames(n := 4) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	Game.touch = true
	Game.player_name = "TouchTest"
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await frames(2)
	main.open("adventure")
	await frames(4)
	_map = main.current
	check("pad built", _map._touch_pad != null)

	var start: Vector2 = _map.player.position
	touch(Vector2(34, 273), true)   # left arrow
	await frames(10)
	check("left arrow presses the action", Input.is_action_pressed("move_left"))
	check("hero walks left", _map.player.position.x < start.x - 1.0,
			"%s -> %s" % [start, _map.player.position])
	touch(Vector2(34, 273), false)
	await frames(2)
	check("release stops the action", not Input.is_action_pressed("move_left"))

	# A miss must stay a miss: the gap between the arrows is not a button.
	var idle: Vector2 = _map.player.position
	touch(Vector2(300, 180), true)
	await frames(6)
	check("empty map is not a d-pad", _map.player.position.is_equal_approx(idle))
	touch(Vector2(300, 180), false)
	await frames(2)

	# GO on a station doorstep opens the quiz, and the pad gets out of the way.
	_map.player.position = _map._station_nodes[0].position
	await frames(2)
	touch(Vector2(574, 290), true)
	await frames(4)
	touch(Vector2(574, 290), false)
	await frames(4)
	check("GO enters the station", _map._overlay != null)
	check("pad hidden under the quiz", not _map._touch_pad.visible)
	_map.close_overlay()
	await frames(2)
	check("pad back after the quiz", _map._touch_pad.visible)

	Game.abandon_adventure()
	print("---- TOUCH %s ---- %d checks, %d failures" %
			["PASS" if failures == 0 else "FAIL", checks, failures])
	get_tree().quit(1 if failures > 0 else 0)

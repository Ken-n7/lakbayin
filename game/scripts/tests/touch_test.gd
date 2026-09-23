extends Node
## The on-screen joystick and buttons: touch/drag events pushed through the
## viewport should feed the same InputMap actions the keyboard does, and the
## hero should actually walk. Run with:
##   godot --headless res://scripts/tests/touch_test.tscn

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


## Same finger (index 0) sliding, for the joystick's knob.
func drag(at: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = 0
	ev.position = at
	get_viewport().push_input(ev, true)


func frames(n := 4) -> void:
	for i in n:
		await get_tree().process_frame


## `_swoop()`'s zoom/position tween runs 0.9s of real engine time, which a fixed
## frame count can't wait out reliably -- poll wall time instead, same trick the
## `_start_intro()` exploration probe used.
func wait_until(cond: Callable, timeout := 3.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()


func _ready() -> void:
	Game.touch = true
	Game.player_name = "TouchTest"
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await frames(2)
	main.open("adventure")
	await frames(4)
	_map = main.current
	# The map opens frozen on the aerial POV. The client was explicit: no joystick
	# before the adventure starts, and only a press starts it.
	check("pad built", _map.hud.pad != null)
	check("pad hidden on the aerial POV", not _map.hud.pad.visible)
	check("start hint offered", _map._start_hint != null)
	check("clock held while frozen", Game.clock_paused)

	# A tap anywhere on the frozen board starts the adventure -- there is no
	# button to miss, so this is the one thing that has to actually be proven.
	touch(Vector2(80, 80), true)
	await frames(2)
	touch(Vector2(80, 80), false)
	await wait_until(func() -> bool: return not _map._frozen)
	check("tap on the frozen board swoops", not Game.clock_paused)
	check("pad back after a tap-started swoop", _map.hud.pad.visible)
	check("start hint gone after a tap-started swoop", _map._start_hint == null)

	# Re-freeze and prove the button removal didn't just move the trigger --
	# skip_intro() is still the instant collapse the rest of the suite uses.
	main.open("adventure")
	await frames(8)
	_map = main.current
	check("start hint offered", _map._start_hint != null)
	check("clock held while frozen", Game.clock_paused)
	# Collapse it so the hero can walk.
	_map.skip_intro()
	check("intro collapsed", not Game.clock_paused)
	check("pad back after the swoop", _map.hud.pad.visible)
	check("start hint gone", _map._start_hint == null)

	var start: Vector2 = _map.player.position
	touch(Vector2(80, 273), true)   # spawns the floating stick right here
	await frames(2)
	drag(Vector2(34, 273))          # drag to full deflection, due left
	await frames(10)
	check("dragging the stick presses the action", Input.is_action_pressed("move_left"))
	check("full deflection reads full strength",
			is_equal_approx(Input.get_action_strength("move_left"), 1.0),
			str(Input.get_action_strength("move_left")))
	check("hero walks left", _map.player.position.x < start.x - 1.0,
			"%s -> %s" % [start, _map.player.position])
	touch(Vector2(34, 273), false)
	await frames(2)
	check("release stops the action", not Input.is_action_pressed("move_left"))

	# A tap and release with no drag between them applies no strength -- the
	# stick spawned right there (still inside the left-half zone) but never
	# moved off its own centre.
	var idle: Vector2 = _map.player.position
	touch(Vector2(300, 180), true)
	await frames(6)
	check("a tap with no drag applies no strength", _map.player.position.is_equal_approx(idle))
	touch(Vector2(300, 180), false)
	await frames(2)

	# A touch outside the zone (clear of GO and MENU too) never spawns a stick.
	touch(Vector2(400, 150), true)
	await frames(6)
	check("a touch outside the zone does nothing", _map.player.position.is_equal_approx(idle))
	touch(Vector2(400, 150), false)
	await frames(2)

	# GO on a station doorstep opens the quiz, and the pad gets out of the way.
	_map.player.position = _map.stations.nodes[0].position
	await frames(2)
	touch(Vector2(574, 290), true)
	await frames(4)
	touch(Vector2(574, 290), false)
	await frames(4)
	check("GO enters the station", _map._overlay != null)
	check("pad hidden under the quiz", not _map.hud.pad.visible)
	_map.close_overlay()
	await frames(2)
	check("pad back after the quiz", _map.hud.pad.visible)

	Game.abandon_adventure()
	print("---- TOUCH %s ---- %d checks, %d failures" %
			["PASS" if failures == 0 else "FAIL", checks, failures])
	get_tree().quit(1 if failures > 0 else 0)

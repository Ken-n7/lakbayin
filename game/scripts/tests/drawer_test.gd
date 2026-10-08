extends TestCase
## The dev drawer, tapped the way a finger taps it: open it from its tab, then
## press every button where it is on screen. Each tap has to reach its button
## -- not the floating joystick, which takes the left half of the screen --
## and do its job -- and all of them have to fit on the screen.
##   godot --headless res://scripts/tests/drawer_test.tscn

var _map: Node = null


## What a phone delivers for one finger going down or up: the touch (which
## the floating joystick listens for) and then the mouse press Godot makes
## from it (which buttons answer), both in the 640x360 layout's coordinates.
func touch(at: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = 0
	ev.position = at
	ev.pressed = pressed
	get_viewport().push_input(ev, true)
	var m := InputEventMouseButton.new()
	m.button_index = MOUSE_BUTTON_LEFT
	m.position = at
	m.global_position = at
	m.pressed = pressed
	m.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	get_viewport().push_input(m, true)


func tap(at: Vector2) -> void:
	touch(at, true)
	await frames(2)
	touch(at, false)
	await frames(3)


func frames(n := 4) -> void:
	for i in n:
		await get_tree().process_frame


## Taps the button for `fn` where it is drawn; true if that button was pressed.
func press(fn: String) -> bool:
	var b: Button = _map.hud.dev.get("_buttons")[fn]
	var hit := [false]
	var mark := func() -> void: hit[0] = true
	b.pressed.connect(mark)
	await tap(b.get_global_rect().get_center())
	if is_instance_valid(b):             # End Run closes the map, drawer and all
		b.pressed.disconnect(mark)
	return hit[0]


func _ready() -> void:
	backup_save()
	Game.touch = true
	Game.player_name = "DrawerTest"
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await frames(2)
	main.open("adventure")
	await frames(4)
	_map = main.current
	_map.skip_intro()
	await frames(4)
	var dev: Control = _map.hud.dev
	check("the drawer is there (debug build)", dev != null)
	if dev == null:
		finish("DRAWER")
		return

	var handle: Button = dev.get("_handle")
	await tap(handle.get_global_rect().get_center())
	var panel: Control = dev.get("_panel")
	check("its tab opens it", panel.visible)
	var screen := get_viewport().get_visible_rect()
	check("every button fits on the screen", screen.encloses(panel.get_global_rect()),
		"%s in %s" % [panel.get_global_rect(), screen])

	var was_time: float = Game.time_left
	check("+1:00 is pressed", await press("_add_minute"))
	check("...and adds a minute", is_equal_approx(Game.time_left, was_time + 60.0) or Game.time_left > was_time + 59.0,
		"%.1f -> %.1f" % [was_time, Game.time_left])

	check("Freeze is pressed", await press("_freeze"))
	check("...and stops the clock", Game.clock_paused)
	await press("_freeze")
	check("...and again starts it", not Game.clock_paused)

	check("Fast Walk is pressed", await press("_fast_walk"))
	check("...and speeds the hero up", float(_map.get("_speed_mult")) > 1.0)
	await press("_fast_walk")
	check("...and again slows him down", is_equal_approx(float(_map.get("_speed_mult")), 1.0))

	var spr: AnimatedSprite2D = _map.player.get_node("Spr")
	var size0: float = spr.scale.x
	check("Hero + is pressed", await press("_hero_bigger"))
	check("...and the hero grows", spr.scale.x > size0, "%.2f -> %.2f" % [size0, spr.scale.x])
	check("Hero - is pressed", await press("_hero_smaller"))
	check("...and shrinks back", is_equal_approx(spr.scale.x, size0), "%.2f" % spr.scale.x)

	check("Show Walls is pressed", await press("_show_walls"))
	check("...and draws them", dev.get("_walls") != null)
	await press("_show_walls")
	check("...and again takes them away", dev.get("_walls") == null)

	check("Aerial is pressed", await press("_aerial"))
	check("...and lifts the camera", bool(_map.get("_dev_aerial")))
	await press("_aerial")
	check("...and again brings it down", not bool(_map.get("_dev_aerial")))

	check("Relay Off is pressed", await press("_relay_off"))
	check("...and keeps this phone off the relay", RelayLink.off)
	await press("_relay_off")
	check("...and again lets it on", not RelayLink.off)

	check("Echo Ghost is pressed", await press("_echo_ghost"))
	check("...and turns the echo on", RelayLink.echo)
	await press("_echo_ghost")
	check("...and again off", not RelayLink.echo)

	check("Open Gates is pressed", await press("_open_gates"))

	var at: Vector2 = _map.player.position
	check("Teleport is pressed", await press("_teleport"))
	check("...and moves the hero", _map.player.position.distance_to(at) > 1.0,
		"%s -> %s" % [at, _map.player.position])

	var done: int = Game.items_done
	check("Skip Station is pressed", await press("_skip_station"))
	check("...and clears the station", Game.items_done > done, "%d -> %d" % [done, Game.items_done])

	check("no tap reached the joystick", not Input.is_action_pressed("move_left")
		and not Input.is_action_pressed("move_right") and not Input.is_action_pressed("move_up")
		and not Input.is_action_pressed("move_down"))

	check("End Run is pressed", await press("_end_run"))
	await frames(4)
	check("...and ends the run", not Game.adventure_active)

	completed = true
	finish("DRAWER")

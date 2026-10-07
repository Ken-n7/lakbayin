extends TestCase
## The on-screen joystick and buttons: touch/drag events pushed through the
## viewport should feed the same InputMap actions the keyboard does, and the
## hero should actually walk. Run with:
##   godot --headless res://scripts/tests/touch_test.tscn

var _map: Node = null
var _last := {}      # finger index -> where it last was, for a drag's `relative`


## Viewport coordinates: the pad is laid out in the 640x360 design space.
func touch(at: Vector2, pressed: bool, index := 0) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = at
	ev.pressed = pressed
	_last[index] = at
	get_viewport().push_input(ev, true)


## A finger sliding, as a phone reports it: where it is and how far it came.
func drag(at: Vector2, index := 0) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = at
	ev.relative = at - _last.get(index, at)
	_last[index] = at
	get_viewport().push_input(ev, true)


## A finger sliding from `from` to `to` in `steps` moves, a frame apart.
func slide(from: Vector2, to: Vector2, index := 0, steps := 8) -> void:
	for k in range(1, steps + 1):
		drag(from.lerp(to, float(k) / steps), index)
		await frames(1)


## The hero put at `at` with the camera already on him: headless frames run
## far faster than real time, so smoothing would still be on its way.
func place_hero(at: Vector2) -> void:
	_map.player.position = at
	await frames(2)
	_map._cam.reset_smoothing()
	await frames(2)


## Where the camera is looking, world px.
func view() -> Vector2:
	return _map._cam.get_screen_center_position()


## The screen position of circle `n`'s tower, as the player sees it.
func tower_on_screen(n: int) -> Vector2:
	var c: Node2D = _map._circles[n]
	return get_viewport().get_canvas_transform() * (c.get_meta("tower_mid", c.position) as Vector2)


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

	await _looking_around()

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
	completed = true
	finish("TOUCH")


## Dragging the board moves the camera at the play zoom, and it stays where it
## is left until the player moves, presses GO or taps the arrow home -- MOBA.
## Every way a look can collide with the controls is tried here.
func _looking_around() -> void:
	var zoom: float = _map._cam.zoom.x
	# The hero just left of circle 1's tower, so the tower sits right of the
	# joystick's half of the screen, where the board takes touches.
	await place_hero((_map._circles[0] as Node2D).position + Vector2(-120, 40))
	var tower := tower_on_screen(0)
	check("the test tower is on the board's side of the screen", tower.x > 330.0 and tower.x < 560.0,
			str(tower))

	# A tap on a tower still opens its card -- on the lift, not the press.
	touch(tower, true, 1)
	await frames(2)
	check("pressing a tower opens nothing yet", _map._card == null)
	touch(tower, false, 1)
	await frames(2)
	check("a tap on a tower opens its card", _map._card != null)
	_map._close_card()

	# A drag that starts on that tower looks around instead, and opens no card.
	var before := view()
	touch(tower, true, 1)
	await slide(tower, tower + Vector2(-200, 0), 1)
	check("dragging the board looks around", _map._looking)
	check("a drag that starts on a tower opens no card", _map._card == null)
	var moved := view() - before
	check("the view follows the finger 1:1", absf(moved.x - 200.0 / zoom) < 2.0 and absf(moved.y) < 1.0,
			str(moved))
	touch(tower + Vector2(-200, 0), false, 1)
	await frames(2)
	check("lifting the finger opens no card", _map._card == null)
	check("zoom unchanged by a look", is_equal_approx(_map._cam.zoom.x, zoom))

	# The camera stays where it was left -- no drifting home on its own.
	var left_at := view()
	await frames(40)
	check("the camera stays where it is left", view().distance_to(left_at) < 0.5,
			"%s -> %s" % [left_at, view()])

	# Far enough away, the arrow on the edge points home; tapping it goes home.
	touch(Vector2(500, 180), true, 1)
	await slide(Vector2(500, 180), Vector2(100, 180), 1)
	touch(Vector2(100, 180), false, 1)
	await frames(2)
	var ptr: Control = _map.hud.hero_pointer
	check("the arrow home shows with the hero off screen", ptr.visible)
	var ptr_at: Vector2 = ptr.position + ptr.size * 0.5
	var hero_screen: Vector2 = get_viewport().get_canvas_transform() * _map.player.position
	check("the arrow points at the hero", ptr._dir.dot((hero_screen - ptr_at).normalized()) > 0.95)
	touch(ptr_at, true, 1)
	await frames(2)
	touch(ptr_at, false, 1)
	check("tapping the arrow ends the look", not _map._looking)
	check("the arrow hides once home", not ptr.visible)
	check("tapping the arrow opens no card", _map._card == null)
	var home: Vector2 = _map._settled_cam(_map.player.position, zoom)
	await wait_until(func() -> bool: return view().distance_to(home) < 4.0)
	check("the camera glides home to the hero",
			view().distance_to(_map._settled_cam(_map.player.position, zoom)) < 4.0,
			"%s vs %s" % [view(), _map.player.position])

	# Moving the stick brings the camera home too.
	touch(Vector2(500, 180), true, 1)
	await slide(Vector2(500, 180), Vector2(380, 150), 1)
	touch(Vector2(380, 150), false, 1)
	check("looking again", _map._looking)
	touch(Vector2(80, 273), true, 0)
	await frames(2)
	drag(Vector2(34, 273), 0)
	await frames(4)
	check("moving the stick ends the look", not _map._looking)
	touch(Vector2(34, 273), false, 0)
	await frames(2)

	# Steer with the left thumb and look with the right at the same time: the
	# look holds while its finger is down, and the hero keeps walking.
	var walk_from: Vector2 = _map.player.position
	touch(Vector2(80, 273), true, 0)
	await frames(2)
	drag(Vector2(34, 273), 0)
	touch(Vector2(500, 150), true, 1)
	await slide(Vector2(500, 150), Vector2(420, 120), 1)
	check("a look holds while the stick steers", _map._looking)
	# On the clock, not a frame count: the hero walks speed x frame time, and
	# headless frames are ~1ms, so ten of them came to about one pixel -- the
	# check's own threshold. It failed on a fast run, never on a slow one.
	await wait_until(func() -> bool: return _map.player.position.x < walk_from.x - 1.0, 1.0)
	check("the hero walks while the player looks", _map.player.position.x < walk_from.x - 1.0,
			"%s -> %s" % [walk_from, _map.player.position])
	touch(Vector2(420, 120), false, 1)
	await frames(3)
	check("lifting the look while still walking goes home", not _map._looking)
	touch(Vector2(34, 273), false, 0)
	await frames(2)

	# A look that slides across GO does not press it.
	await place_hero((_map._circles[0] as Node2D).position + Vector2(-120, 40))
	var pressed_go := false
	touch(Vector2(430, 200), true, 1)
	for k in range(1, 13):
		drag(Vector2(430, 200).lerp(Vector2(590, 300), k / 12.0), 1)
		await frames(1)
		pressed_go = pressed_go or Input.is_action_pressed("interact")
	check("a look sliding over GO never presses it", not pressed_go)
	check("...and opens nothing", _map._overlay == null)
	touch(Vector2(590, 300), false, 1)
	await frames(2)

	# A touch that starts on GO is GO's, not a look -- and GO brings the view home.
	check("still looking before GO", _map._looking)
	touch(Vector2(574, 290), true, 1)
	await frames(2)
	drag(Vector2(530, 290), 1)
	await frames(3)
	check("GO ends the look", not _map._looking)
	check("a drag that starts on GO does not look", not _map._looking)
	touch(Vector2(530, 290), false, 1)
	await frames(2)

	# A desktop mouse drags the view the same way...
	var m_from := view()
	_mouse_drag(Vector2(450, 200), Vector2(350, 200), 0)
	await frames(3)
	check("a mouse drag looks around", _map._looking and view().x > m_from.x + 50.0)
	_map.end_look()
	await frames(2)
	_map._cam.reset_smoothing()
	await frames(2)
	# ...but the mouse a phone makes out of a touch is not read a second time.
	var e_from := view()
	_mouse_drag(Vector2(450, 200), Vector2(350, 200), InputEvent.DEVICE_ID_EMULATION)
	await frames(3)
	check("a touch's emulated mouse is ignored", not _map._looking and view().distance_to(e_from) < 0.5)


func _mouse_drag(from: Vector2, to: Vector2, device: int) -> void:
	var down := InputEventMouseButton.new()
	down.device = device
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = from
	get_viewport().push_input(down, true)
	var at := from
	for k in range(1, 9):
		var mv := InputEventMouseMotion.new()
		mv.device = device
		mv.button_mask = MOUSE_BUTTON_MASK_LEFT
		var nxt := from.lerp(to, k / 8.0)
		mv.position = nxt
		mv.relative = nxt - at
		at = nxt
		get_viewport().push_input(mv, true)
	var up := down.duplicate() as InputEventMouseButton
	up.pressed = false
	up.position = to
	get_viewport().push_input(up, true)

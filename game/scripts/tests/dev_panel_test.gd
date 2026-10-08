extends TestCase
## The dev panel (DevPanel), tapped the way a finger taps it: the DEV tab
## opens it; every Map button, tapped where it is drawn, reaches its button --
## not the floating joystick, which takes touches before any button -- and
## does its job; the Network switches flip; each tab shows only where it
## applies; and every tab fits on the screen.
##   godot --headless res://scripts/tests/dev_panel_test.tscn

var _main: Node = null
var _map: Node = null
var _panel: Node = null
var _cfg_backup := PackedByteArray()


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


## Taps `b` where it is drawn; true if that button was pressed.
func press(b: Button) -> bool:
	var hit := [false]
	var mark := func() -> void: hit[0] = true
	b.pressed.connect(mark)
	await tap(b.get_global_rect().get_center())
	if is_instance_valid(b):             # End Run closes the map, panel tab and all
		b.pressed.disconnect(mark)
	return hit[0]


func tab(name: String) -> Button:
	return (_panel.get("_tab_buttons") as Dictionary)[name]


func fits(what: String) -> void:
	var box: Control = _panel.get("_box")
	check("%s fits on the screen" % what, get_viewport().get_visible_rect().encloses(box.get_global_rect()),
		"%s in %s" % [box.get_global_rect(), get_viewport().get_visible_rect()])


func _ready() -> void:
	backup_save()
	# The panel remembers its last tab on this device: start from nothing.
	if FileAccess.file_exists(DevPanel.SAVE):
		_cfg_backup = FileAccess.get_file_as_bytes(DevPanel.SAVE)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DevPanel.SAVE))
	DevPanel.last_tabs = {}
	DevPanel.hub_pinned = false
	Game.touch = true
	Game.player_name = "PanelTest"
	_main = load("res://scenes/Main.tscn").instantiate()
	add_child(_main)
	await frames(2)
	_panel = _main.get("dev_panel")
	check("the panel is built (debug build)", _panel != null)
	if _panel == null:
		finish("DEVPANEL")
		return
	_main.open("adventure")
	await frames(4)
	_map = _main.current
	_map.skip_intro()
	await frames(4)

	var dev_tab: Button = _panel.get("_tab")
	check("the DEV tab is on the screen", get_viewport().get_visible_rect().encloses(dev_tab.get_global_rect()))
	check("a tap on the DEV tab reaches it", await press(dev_tab))
	check("...and opens the panel", _panel.is_open())
	check("on the map it opens on the Map tab", _panel.get("_shown") == "Map", str(_panel.get("_shown")))
	check("Map is offered on the map", tab("Map").visible)
	check("Hub is not, off Game Controls", not tab("Hub").visible)
	fits("the Map tab")

	var b: Dictionary = _panel.map_buttons()
	var was_time: float = Game.time_left
	check("+1:00 is pressed", await press(b["_add_minute"]))
	check("...and adds a minute", Game.time_left > was_time + 59.0, "%.1f -> %.1f" % [was_time, Game.time_left])

	check("Freeze is pressed", await press(b["_freeze"]))
	check("...and stops the clock", Game.clock_paused)
	check("...and says it is on", (b["_freeze"] as Button).text.ends_with(DevUi.ON))
	await press(b["_freeze"])
	check("...and again starts it", not Game.clock_paused and not (b["_freeze"] as Button).text.ends_with(DevUi.ON))

	check("Fast Walk is pressed", await press(b["_fast_walk"]))
	check("...and speeds the hero up", float(_map.get("_speed_mult")) > 1.0)
	await press(b["_fast_walk"])
	check("...and again slows him down", is_equal_approx(float(_map.get("_speed_mult")), 1.0))

	var spr: AnimatedSprite2D = _map.player.get_node("Spr")
	var size0: float = spr.scale.x
	check("Hero + is pressed", await press(b["_hero_bigger"]))
	check("...and the hero grows", spr.scale.x > size0, "%.2f -> %.2f" % [size0, spr.scale.x])
	check("Hero - is pressed", await press(b["_hero_smaller"]))
	check("...and shrinks back", is_equal_approx(spr.scale.x, size0), "%.2f" % spr.scale.x)

	check("Show Walls is pressed", await press(b["_show_walls"]))
	check("...and draws them", _panel.get("_map").get("_walls") != null)
	await press(b["_show_walls"])
	check("...and again takes them away", _panel.get("_map").get("_walls") == null)

	check("Aerial is pressed", await press(b["_aerial"]))
	check("...and lifts the camera", bool(_map.get("_dev_aerial")))
	await press(b["_aerial"])
	check("...and again brings it down", not bool(_map.get("_dev_aerial")))

	check("Open Gates is pressed", await press(b["_open_gates"]))

	var at: Vector2 = _map.player.position
	check("Teleport is pressed", await press(b["_teleport"]))
	check("...and moves the hero", _map.player.position.distance_to(at) > 1.0,
		"%s -> %s" % [at, _map.player.position])

	var done: int = Game.items_done
	check("Skip Station is pressed", await press(b["_skip_station"]))
	check("...and clears the station", Game.items_done > done, "%d -> %d" % [done, Game.items_done])

	# The Network tab: on every screen, its switches flip and say so.
	check("the Network tab is pressed", await press(tab("Network")))
	check("...and shown", _panel.get("_shown") == "Network")
	fits("the Network tab")
	var n: Dictionary = _panel.net_buttons()
	check("Relay off is pressed", await press(n["relay_off"]))
	check("...and keeps this device off the relay", RelayLink.off)
	await press(n["relay_off"])
	check("...and again lets it on", not RelayLink.off)
	check("Echo ghost flips", await press(n["echo"]) and RelayLink.echo)
	await press(n["echo"])
	check("Force IPv4 flips", await press(n["force_v4"]) and Dial.force_v4)
	await press(n["force_v4"])
	check("Log realtime flips", await press(n["log"]) and Realtime.log_traffic)
	await press(n["log"])
	check("...all back off", not RelayLink.echo and not Dial.force_v4 and not Realtime.log_traffic)
	check("Reports can't be switched where none are sent (desktop)", (n["reports"] as Button).disabled)
	check("the readout says how the line is", "Line " in str((_panel.get("_net") as DevNetTools).lines(get_tree())[0]))

	check("no tap reached the joystick", not Input.is_action_pressed("move_left")
		and not Input.is_action_pressed("move_right") and not Input.is_action_pressed("move_up")
		and not Input.is_action_pressed("move_down"))

	# The Screens tab, and where the screen-only tabs show.
	check("the Screens tab is pressed", await press(tab("Screens")))
	fits("the Screens tab")
	_panel.on_screen("controls")
	check("on Game Controls, Hub is offered", _panel.available("Hub") and not _panel.available("Map"))
	_panel.on_screen("home")
	check("on Home, neither Map nor Hub", not _panel.available("Hub") and not _panel.available("Map"))
	_panel.on_screen("adventure")

	# Last: End Run, which closes the map.
	_panel.show_tab("Map")
	await frames(2)
	check("End Run is pressed", await press(_panel.map_buttons()["_end_run"]))
	await frames(4)
	check("...and ends the run", not Game.adventure_active)
	check("the panel is still there for the next screen", is_instance_valid(_panel))

	_panel.close()
	if not _cfg_backup.is_empty():
		var f := FileAccess.open(DevPanel.SAVE, FileAccess.WRITE)
		f.store_buffer(_cfg_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DevPanel.SAVE))
	completed = true
	finish("DEVPANEL")

class_name DevPanel
extends Control

## Every developer tool, in one place: a small DEV tab in the same spot on
## every screen, opening one panel whose tabs show only what applies here.
##   Screens  -- jump to any screen, the board with no session, sign out
##   Map      -- the cheats, on the adventure map only (DevMapTools)
##   Network  -- this device's connections now, and switches (DevNetTools)
##   Hub      -- the teacher's live message stats, on Game Controls only
## Debug builds only: Main never builds it in a release export. Lives on
## Main's own layer, so opening a screen -- which frees the last -- leaves it.
## F1 opens and closes it on a desktop.
##
## Replaced a "D" tab for screens on every screen (on the map it sat on the
## player's name) and a second "D" tab for the map's cheats; the teacher's
## stats needed a launch flag and covered the join code.

## The tab: the bottom-left corner, where no screen keeps anything to press
## (layout_check proves it on every screen).
const TAB_RECT := Rect2(0, 340, 30, 18)
const PANEL_POS := Vector2(4, 4)
const PANEL_W := 300.0
const CONTENT_H := 292.0
## Where the pinned Hub stats sit on Game Controls: against the right edge,
## under the top bar's buttons -- over the map or the team list, never over
## anything to press (layout_check).
const PIN_TOP := 100.0
const PIN_RIGHT := 8.0
const SAVE := "user://dev.cfg"
const TABS := ["Screens", "Map", "Network", "Hub"]

var main: Control
var _screen := ""
var _tab: Button
var _box: PanelContainer
var _tab_row: HBoxContainer
var _tab_buttons := {}           # tab name -> Button
var _scroll: ScrollContainer
var _shown := ""                 # the tab whose contents are up
var _map: DevMapTools = null
var _net := DevNetTools.new()
var _pin: Control = null
var _clock := 0.0

## Remembered on this device (SAVE): the last tab on each kind of screen (the
## map, Game Controls, the rest), the Hub pin, the phone reports. The other
## switches are for one test and reset with the app.
static var last_tabs := {}
static var hub_pinned := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("dev_panel")
	_load()
	if "--hub-debug" in OS.get_cmdline_user_args():
		hub_pinned = true          # the live test scripts start with it pinned

	_tab = DevUi.button("DEV", TAB_RECT.size.y)
	_tab.custom_minimum_size = TAB_RECT.size
	_tab.position = TAB_RECT.position
	_tab.add_theme_font_size_override("font_size", 10)
	_tab.pressed.connect(toggle)
	_tab.add_to_group(DevUi.GROUP)
	add_child(_tab)

	_box = DevUi.box(PANEL_W)
	_box.position = PANEL_POS
	_box.visible = false
	_box.mouse_filter = Control.MOUSE_FILTER_STOP
	_box.add_to_group(DevUi.GROUP)
	add_child(_box)
	var col := DevUi.column(_box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 2)
	col.add_child(head)
	_tab_row = HBoxContainer.new()
	_tab_row.add_theme_constant_override("separation", 2)
	_tab_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_tab_row)
	for t: String in TABS:
		var b := DevUi.button(t)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(show_tab.bind(t))
		_tab_row.add_child(b)
		_tab_buttons[t] = b
	var shut := DevUi.button("×")
	shut.custom_minimum_size = Vector2(22, 19)
	shut.pressed.connect(close)
	head.add_child(shut)
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(PANEL_W - 8.0, CONTENT_H)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(_scroll)


## Main, every time it opens a screen.
func on_screen(name: String) -> void:
	_screen = name
	if name != "adventure" and _map != null:
		_map = null
	_place_pin()
	if is_open():
		show_tab(_shown if available(_shown) else _default_tab())


func available(t: String) -> bool:
	match t:
		"Map":
			return _screen == "adventure" and main != null and is_instance_valid(main.current)
		"Hub":
			return _screen == "controls"
	return t in TABS


func is_open() -> bool:
	return _box.visible


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


func open() -> void:
	_box.visible = true
	var last: String = last_tabs.get(_kind(), "")
	show_tab(last if available(last) else _default_tab())


## The map, Game Controls, or any other screen: each remembers its own tab.
func _kind() -> String:
	return _screen if _screen in ["adventure", "controls"] else "other"


func close() -> void:
	_box.visible = false


func show_tab(t: String) -> void:
	if not available(t):
		t = _default_tab()
	_shown = t
	for name: String in TABS:
		var b: Button = _tab_buttons[name]
		b.visible = available(name)
		DevUi.mark(b, false)
		b.text = name
	(_tab_buttons[t] as Button).add_theme_stylebox_override("normal", DevUi._face(DevUi.FACE_ON))
	if last_tabs.get(_kind(), "") != t:
		last_tabs[_kind()] = t
		save_switches()
	for c in _scroll.get_children():
		_scroll.remove_child(c)
		c.queue_free()
	var body: Control
	match t:
		"Screens":
			body = _screens()
		"Map":
			body = _map_tools().build()
		"Network":
			body = _net.build(get_tree())
		"Hub":
			body = _hub()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(body)
	_fit.call_deferred(body)


## As tall as the tab's contents, up to CONTENT_H (then it scrolls): a short
## tab is a short panel.
func _fit(body: Control) -> void:
	if not is_instance_valid(body):
		return
	_scroll.custom_minimum_size.y = minf(body.get_combined_minimum_size().y, CONTENT_H)
	_box.reset_size()


## The tab that fits where we are: the map's cheats on the map, the teacher's
## stats on Game Controls, else the screen list.
func _default_tab() -> String:
	if available("Map"):
		return "Map"
	if available("Hub"):
		return "Hub"
	return "Screens"


## The Map tab's tools belong to one adventure screen: a new one, new tools.
func _map_tools() -> DevMapTools:
	if _map == null or not _map.is_for(main.current):
		_map = DevMapTools.new(main.current)
	return _map


## Only the tools: tests press the Map tab's buttons through this.
func map_buttons() -> Dictionary:
	return _map.buttons if _map != null else {}


func net_buttons() -> Dictionary:
	return _net.buttons


func _process(delta: float) -> void:
	_clock -= delta
	if _clock > 0.0:
		return
	_clock = 0.5
	if is_open() and _shown == "Network":
		_net.refresh(get_tree())


func _input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo \
			and (event as InputEventKey).keycode == KEY_F1:
		toggle()
		get_viewport().set_input_as_handled()


# --- Screens -----------------------------------------------------------------
func _screens() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.add_child(DevUi.heading("Open a screen"))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	col.add_child(grid)
	for name: String in (main.get_script() as Script).get_script_constant_map().SCREENS:
		grid.add_child(_go(name, func() -> void: main._dev_open(name)))
	col.add_child(DevUi.heading("Without a session"))
	var row := GridContainer.new()
	row.columns = 3
	row.add_theme_constant_override("h_separation", 2)
	col.add_child(row)
	# The board with no session: for looking at the map, not playing it.
	row.add_child(_go("explore map", func() -> void: main.explore_map()))
	# The team picker, which otherwise needs a live session to reach.
	row.add_child(_go("lobby preview", func() -> void: main.open("team", {"preview": true})))
	row.add_child(_go("sign out", func() -> void:
		Net.sign_out()
		main.open("login")))
	col.add_child(DevUi.heading("This build"))
	var relay: RelayLink = Net.get("_relay")
	col.add_child(DevUi.note("v%s debug · profile %s · %s · relay %s" % [
		ProjectSettings.get_setting("application/config/version", "?"),
		Game.profile_suffix().trim_prefix("-") if Game.profile_suffix() != "" else "default",
		Dial.host_of(Net.url) if Net.configured() else "offline",
		relay.host if is_instance_valid(relay) and relay.host != "" else "none yet"], 9))
	col.add_child(DevUi.note("Flags, env vars and tools: game/DEVTOOLS.md", 9))
	return col


func _go(text: String, then: Callable) -> Button:
	var b := DevUi.button(text)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(func() -> void:
		close()
		then.call())
	return b


# --- Hub -----------------------------------------------------------------------
func _hub() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	var pin := DevUi.button("Pin on screen")
	DevUi.mark(pin, hub_pinned)
	pin.pressed.connect(func() -> void:
		hub_pinned = not hub_pinned
		save_switches()
		_place_pin()
		show_tab("Hub"))
	col.add_child(pin)
	if hub_pinned:
		col.add_child(DevUi.note("Pinned: the stats stay on Game Controls with this panel shut."))
	else:
		var stats := HubDebug.new()
		stats.gc = main.current
		stats.inline = true
		col.add_child(stats)
	return col


## The pinned stats: on Game Controls while pinned, nowhere else. One at a
## time -- HubDebug counts messages as it reads them.
func _place_pin() -> void:
	var want := hub_pinned and _screen == "controls" and main != null and is_instance_valid(main.current)
	if want and (_pin == null or not is_instance_valid(_pin) or _pin.get("gc") != main.current):
		if _pin != null and is_instance_valid(_pin):
			_pin.queue_free()
		_pin = HubDebug.new()
		_pin.gc = main.current
		_pin.compact = true
		add_child(_pin)
		_pin.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		_pin.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		_pin.offset_top = PIN_TOP
		_pin.offset_right = -PIN_RIGHT
		move_child(_pin, 0)           # under the tab and the panel
	elif not want and _pin != null and is_instance_valid(_pin):
		_pin.queue_free()
		_pin = null


# --- Remembered ----------------------------------------------------------------
func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE) != OK:
		return
	var tabs: Variant = cfg.get_value("dev", "tabs", {})
	last_tabs = tabs if tabs is Dictionary else {}
	hub_pinned = bool(cfg.get_value("dev", "hub_pinned", hub_pinned))
	NetReport.enabled = bool(cfg.get_value("dev", "reports", NetReport.enabled))


static func save_switches() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("dev", "tabs", last_tabs)
	cfg.set_value("dev", "hub_pinned", hub_pinned)
	cfg.set_value("dev", "reports", NetReport.enabled)
	cfg.save(SAVE)

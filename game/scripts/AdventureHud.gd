class_name AdventureHud
extends RefCounted

## Everything drawn over the board: the top bar (name, station, pips, gems,
## clock), the prompt line, the controls crib, the gem gauge, the touch pad and
## the pause menu.
##
## Two CanvasLayers, because the player's Camera2D transforms every canvas item
## in layer 0 -- UI included -- so screen-space elements dragged around the
## world with the camera until they were lifted out of it.
##
## Holds no game state: it reads `Game` and the screen it was handed, and is
## told when to refresh.

var adv: Control
var hud_layer: CanvasLayer   # the board furniture
var ui_layer: CanvasLayer    # overlays and the dev drawer, over the top of it

var prompt: Label
var joystick: Node2D = null
var dev: Control = null      # the cheat drawer, debug builds only

var _gems: Label
var _time: Label
var _station: Label
var _pips: Label
var _gem_bar: ProgressBar
var _hint_bar: Label = null  # the controls crib, hidden while the board is frozen
## The stick and the GO/MENU buttons. Null on desktop, where there is no pad.
var pad: Node2D = null
var _flash_active := false

## The pause menu is up. The screen reads this to stop the hero walking and to
## keep the board from taking taps behind the panel.
var paused := false


func _init(screen: Control) -> void:
	adv = screen


# --- HUD --------------------------------------------------------------------
func build() -> void:
	# The player's Camera2D transforms every canvas item in layer 0, UI included,
	# so screen-space elements have to live in their own CanvasLayers or they
	# get dragged around the world with the camera.
	hud_layer = CanvasLayer.new()
	hud_layer.layer = 1
	adv.add_child(hud_layer)
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 2
	adv.add_child(ui_layer)
	var top := PanelContainer.new()
	top.position = Vector2(4, 4)
	top.custom_minimum_size = Vector2(632, 44)
	top.add_theme_stylebox_override("panel", Art.panel("res://assets/ui/BigBar_Base.png", Vector2(10, 2), 0.5))
	hud_layer.add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	top.add_child(row)

	var av := Art.texrect("res://assets/ui/Avatar_01.png", 32, 32)
	row.add_child(av)
	var name_col := VBoxContainer.new()
	var nm := Art.label(Game.player_name, Pal.SMALL, Pal.CREAM)
	name_col.add_child(nm)
	var cls := Art.label("Adventurer #%d" % Game.hero_id, Pal.TINY, Pal.WHITE_SOFT)
	name_col.add_child(cls)
	row.add_child(name_col)

	var stats := VBoxContainer.new()
	stats.alignment = BoxContainer.ALIGNMENT_CENTER
	stats.custom_minimum_size = Vector2(150, 0)
	_station = Art.label("Station 1", Pal.SMALL, Pal.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	stats.add_child(_station)
	_pips = Art.label("— — —", Pal.SMALL, Pal.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	stats.add_child(_pips)
	row.add_child(stats)

	row.add_child(Control.new()) # spacer
	var gems_icon := Art.texrect("res://assets/ui/Icon_03.png", 26, 26)
	row.add_child(gems_icon)
	var gems_col := VBoxContainer.new()
	_gems = Art.label(str(Game.START_GEMS), Pal.BODY, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	gems_col.add_child(_gems)
	_time = Art.label(Ui.mmss(int(Game.time_left)), Pal.SMALL, Pal.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	gems_col.add_child(_time)
	row.add_child(gems_col)

	# Full-width, not centre-anchored: PRESET_CENTER_BOTTOM puts the box's left
	# edge at mid-screen, so a 640-wide label started in the middle and ran off
	# the right edge -- centred text ended up hanging off the screen.
	prompt = Art.label("", Pal.BODY, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	prompt.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	prompt.offset_top = -104.0
	prompt.offset_bottom = -74.0
	prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(prompt)

	var keys := ("joystick — move   ·   GO — enter   ·   MENU / back — pause" if Game.touch
			else "WASD / arrows — move   ·   E — interact   ·   Esc — menu")
	var hint_bar: Label = Art.label(keys, Pal.TINY,
			Pal.WHITE_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	if Game.touch:
		hint_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		hint_bar.offset_top = 52.0
		hint_bar.offset_bottom = 76.0
	else:
		hint_bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		hint_bar.offset_top = -40.0
		hint_bar.offset_bottom = -16.0
	hint_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(hint_bar)
	_hint_bar = hint_bar

	# Both float over open terrain, so they need a shadow to stay readable.
	for l in [prompt, hint_bar]:
		Art.shadow(l)

	var gemrow := HBoxContainer.new()
	gemrow.position = Vector2(4, 50)
	gemrow.add_theme_constant_override("separation", 4)
	hud_layer.add_child(gemrow)
	# SmallBar_Fill is a 3px sliver and SmallBar_Base a 3x1 patch; they never
	# lined up as a TextureProgressBar. A flat gauge in the pack's palette is
	# both correct at any size and legible at a glance.
	_gem_bar = ProgressBar.new()
	_gem_bar.custom_minimum_size = Vector2(140, 10)
	_gem_bar.show_percentage = false
	_gem_bar.max_value = 100.0
	_gem_bar.value = 0.0
	var trough := StyleBoxFlat.new()
	trough.bg_color = Color(0.08, 0.06, 0.10, 0.75)
	trough.set_corner_radius_all(4)
	trough.set_border_width_all(1)
	trough.border_color = Pal.SHADOW
	var fill := StyleBoxFlat.new()
	fill.bg_color = Pal.GOLD
	fill.set_corner_radius_all(4)
	_gem_bar.add_theme_stylebox_override("background", trough)
	_gem_bar.add_theme_stylebox_override("fill", fill)
	gemrow.add_child(_gem_bar)
	_build_pad()
	# The cheat drawer, and only where cheating is free: a release export never
	# builds the node, so there is nothing in it to reach.
	if OS.is_debug_build():
		dev = preload("res://scripts/DevDrawer.gd").new()
		ui_layer.add_child(dev)
		dev.setup(adv)


# --- Touch controls ---------------------------------------------------------
## The stick is a raw-touch Node2D (its own finger index, like TouchScreenButton
## tracks), and GO/MENU stay TouchScreenButtons -- both read real touch rather
## than mouse-emulated, so steering and pressing GO work on separate fingers at
## once. Each feeds a real InputMap action (the stick with analog strength), so
## `_process` and `_unhandled_input` stay untouched.
func _build_pad() -> void:
	if not Game.touch:
		return
	pad = Node2D.new()
	hud_layer.add_child(pad)
	# Kept a thumb's width off the bottom edge: that strip is Android's
	# swipe-up-home gesture zone, immersive mode or not.
	joystick = preload("res://scripts/Joystick.gd").new()
	pad.add_child(joystick)
	_touch_btn("interact", "GO", Vector2(574, 290), 0.52, 20, false)
	_touch_btn("pause", "MENU", Vector2(606, 74), 0.34, 11, true)


func _touch_btn(action: String, text: String, center: Vector2, s: float, font: int, red: bool) -> void:
	var skin := "res://assets/ui/Small%sRoundButton_%s.png"
	var col := "Red" if red else "Blue"
	var b := TouchScreenButton.new()
	b.texture_normal = Art.tex(skin % [col, "Regular"])
	b.texture_pressed = Art.tex(skin % [col, "Pressed"])
	b.action = action
	b.passby_press = true   # a thumb sliding onto GO/MENU still presses it
	# The art is 128px drawn from the node's origin, so the hit circle is its
	# own centre at full size and rides `scale` down with the sprite.
	var circle := CircleShape2D.new()
	circle.radius = 64.0
	b.shape = circle
	b.shape_centered = true
	b.scale = Vector2(s, s)
	b.position = center - Vector2(64.0, 64.0) * s
	b.modulate.a = 0.8
	pad.add_child(b)
	var l := Art.label(text, font, Pal.WHITE_STRONG, HORIZONTAL_ALIGNMENT_CENTER)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size = Vector2(80, 24)
	l.position = center - Vector2(40, 12)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Art.shadow(l)
	pad.add_child(l)


## The controls crib, hidden while the board is frozen: the aerial POV is the
## one screen the client asked to be left alone to look at.
func set_crib(on: bool) -> void:
	if _hint_bar != null and is_instance_valid(_hint_bar):
		_hint_bar.visible = on


## The drawer stays out of the way of anything that wants the whole screen.
func close_dev() -> void:
	if dev != null and is_instance_valid(dev):
		dev.close()


## Hiding a TouchScreenButton releases its action on its own; the stick is a
## plain Node2D, so a held drag needs the same release told explicitly, or it
## would survive into a quiz or the pause menu.
func set_pad(on: bool) -> void:
	if pad != null:
		pad.visible = on
	if not on and joystick != null:
		joystick.release()


func flash(text: String) -> void:
	if not is_instance_valid(prompt):
		return
	_flash_active = true
	Art.toast(prompt, text, 1.2, "", func() -> void: _flash_active = false)


## The prompt line -- what pressing E would do, right now. Ignored while a
## toast owns the line: a tip has no business being overwritten a frame later
## by the walk's running commentary.
func set_prompt(text: String) -> void:
	if _flash_active or not is_instance_valid(prompt):
		return
	prompt.text = text


func on_gems(g: int) -> void:
	if is_instance_valid(_gems):
		_gems.text = str(g)
	var ratio := clampf(float(g) / float(Game.START_GEMS + 60), 0.0, 1.0)
	if is_instance_valid(_gem_bar):
		_gem_bar.value = 100.0 * ratio


func on_time(sec: int) -> void:
	if is_instance_valid(_time):
		_time.text = Ui.mmss(sec)


func refresh() -> void:
	on_gems(Game.gems)
	on_time(int(ceilf(Game.time_left)))
	var next := Game.completed_stations.find(false)
	if Game.items_done >= Game.TOTAL_ITEMS:
		_station.text = "Victory Gate!"
	else:
		var st := Game.station_of_item(Game.items_done)
		_station.text = "Station %d · %d/%d" % [st + 1,
				Game.item_in_station(Game.items_done), Game.ITEMS_PER_STATION[st]]
	var marks := ""
	for i in Game.ITEMS_PER_STATION.size():
		marks += ["✓", "★", "—"][ 0 if Game.completed_stations[i] else (1 if Game.perfect_stations[i] else 2) ] + " "
	_pips.text = marks.strip_edges()
	# Label the boards on the map itself, otherwise all three look identical.
	for i in adv.stations.locks.size():
		var mark := "—"
		if Game.completed_stations[i]:
			mark = "★" if Game.perfect_stations[i] else "✓"
		elif i == next:
			mark = "▶"
		adv.stations.locks[i].text = "Station %d  %s" % [i + 1, mark]


func toggle_pause() -> void:
	if paused:
		return
	paused = true
	adv._close_card()
	close_dev()
	set_pad(false)
	var box := Ui.screen_panel(ui_layer, Vector2(300, 250), "Paused")
	var menu := box.get_parent()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	# label, kind, height, screen to open ("" = stay on the map), what to do with
	# the run in progress.
	for spec in [["Resume", Ui.BLUE, 44, "", ""], ["Home", Ui.SMALL, 38, "home", "end"],
			["Restart", Ui.SMALL, 38, "adventure", "restart"],
			["Leaderboard", Ui.SMALL_RED, 38, "board", ""],
			["New Game", Ui.SMALL_RED, 38, "hero", "abandon"]]:
		var b := Ui.button(spec[0], 170, spec[2], spec[1])
		b.pressed.connect(_leave_pause.bind(menu, spec[3], spec[4]))
		box.add_child(b)


## Every pause exit closes the menu. `drop` decides the fate of the run in
## progress -- "end" scores it, "restart" and "abandon" discard it unscored --
## and `screen` where to go next. Restart rebuilds the island, because `open()`
## remakes the screen, and the gems go back to the starting purse.
func _leave_pause(menu: Control, screen: String, drop: String) -> void:
	paused = false
	set_pad(true)
	menu.queue_free()
	match drop:
		"end": Game.end_adventure()
		"restart": Game.restart_adventure()
		"abandon": Game.abandon_adventure()
	if screen != "":
		adv.main.open(screen)

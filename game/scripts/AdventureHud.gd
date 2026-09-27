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
var _time_plate: PanelContainer
var _ribbon: HBoxContainer        # the station banner, re-coloured per station
var _pips: HBoxContainer          # one dot per item in this station
var _bar: HBoxContainer           # the three plates and the ribbon between
var _shown_gems := -99999         # what the plate last showed, to flash the change
var _gem_tw: Tween = null
var _hint_bar: Label = null  # the controls crib, hidden while the board is frozen
## The stick and the GO/MENU buttons. Null on desktop, where there is no pad.
var pad: Node2D = null
var _pad_buttons: Array[TouchScreenButton] = []
## The way back while the camera is off looking at the map: an arrow on the
## screen's edge, pointing at the hero, that brings the view home when tapped.
var hero_pointer: HeroPointer = null
var _flash_active := false

## The menu is up. The screen reads this to stop the hero walking and to
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
	_build_top_bar()

	# Full-width, not centre-anchored: PRESET_CENTER_BOTTOM puts the box's left
	# edge at mid-screen, so a 640-wide label started in the middle and ran off
	# the right edge -- centred text ended up hanging off the screen.
	prompt = Art.label("", Pal.BODY, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	prompt.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	prompt.offset_top = -104.0
	prompt.offset_bottom = -74.0
	prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(prompt)

	var keys := ("joystick — move   ·   drag — look   ·   GO — enter   ·   MENU — menu" if Game.touch
			else "WASD / arrows — move   ·   drag — look   ·   E — interact   ·   Esc — menu")
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

	_build_pad()
	hero_pointer = HeroPointer.new()
	hero_pointer.visible = false
	hero_pointer.pressed.connect(func() -> void: adv.end_look())
	hud_layer.add_child(hero_pointer)
	# The cheat drawer, and only where cheating is free: a release export never
	# builds the node, so there is nothing in it to reach.
	if OS.is_debug_build():
		dev = preload("res://scripts/DevDrawer.gd").new()
		ui_layer.add_child(dev)
		dev.setup(adv)


# --- The top bar ------------------------------------------------------------
## Three plates floating over the board, not one plank across it: the map
## shows between them, and each plate is one thing to read.
##   left   -- the player's own hero in a wooden frame, name and team
##   centre -- the station as a ribbon in its own livery, a dot per item
##   right  -- gems (flashes on a change) and the clock (red in the last minute,
##             "Paused" while the teacher holds it)
## All from the Tiny Swords UI pack already in `assets/ui`.
## The pack's wooden bar: thin end caps, made for a strip this height. The
## WoodTable and paper sheets carry 30px+ corners at any readable scale, which
## made every plate twice the height of the bar.
const PLANK := "res://assets/ui/BigBar_Base.png"
## BigRibbons rows, per station, matching the towers on the map: blue, the
## yellow that stands in for the mockups' orange, red. The gate gets purple.
const RIBBON_ROW := Ui.STATION_RIBBON
const GATE_ROW := Ui.RIBBON_PURPLE
const BAR_H := 40.0
const LAST_MINUTE := 60


func _plate(pad_x: float) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", Art.panel(PLANK, Vector2(pad_x, 0), 0.6))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _build_top_bar() -> void:
	# Anchored across the top, not a fixed width: at 20:9 the canvas is ~800
	# wide and a 632px bar left a quarter of a phone's top edge bare.
	var bar := HBoxContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = 6.0
	bar.offset_right = -6.0
	bar.offset_top = 4.0
	bar.offset_bottom = 4.0 + BAR_H
	bar.add_theme_constant_override("separation", 4)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(bar)
	_bar = bar

	# Left: who is playing. The hero is the one they picked and the one
	# walking on the board -- a stock portrait here matched neither.
	var who := _plate(4)
	var who_row := HBoxContainer.new()
	who_row.add_theme_constant_override("separation", 6)
	who.add_child(who_row)
	var face := TextureRect.new()
	face.texture = Art.grid(Game.hero_sheet(Game.hero_id), 3, 4)[1]   # facing out, standing
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	face.custom_minimum_size = Vector2(26, 32)
	who_row.add_child(face)
	var names := VBoxContainer.new()
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	names.add_theme_constant_override("separation", -2)
	# A fixed column: an 18-letter team name must not widen the plate and
	# squeeze the ribbon off the far end of a 640px screen.
	var team := Game.team_name if Game.team_name != "" else "Adventurer"
	# The account's username is the player's name; the typed one is gone.
	var me := Net.username if Net.signed_in() else Game.player_name
	for spec in [[me, Pal.CREAM], [team, Pal.WHITE_SOFT]]:
		var l := Art.label(str(spec[0]), Pal.SMALL, spec[1])
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.custom_minimum_size = Vector2(100, 0)
		names.add_child(l)
	who_row.add_child(names)
	bar.add_child(who)

	# Centre: where they are. The ribbon takes the station's colour.
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.alignment = BoxContainer.ALIGNMENT_CENTER
	mid.add_theme_constant_override("separation", 2)
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ribbon_centre := CenterContainer.new()
	ribbon_centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ribbon = HBoxContainer.new()
	_ribbon.add_theme_constant_override("separation", 0)
	ribbon_centre.add_child(_ribbon)
	mid.add_child(ribbon_centre)
	var pips_centre := CenterContainer.new()
	pips_centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pips = HBoxContainer.new()
	_pips.add_theme_constant_override("separation", 3)
	pips_centre.add_child(_pips)
	mid.add_child(pips_centre)
	bar.add_child(mid)

	# Right: the two numbers that change -- gems, then the clock.
	var gems := _plate(4)
	var gems_row := HBoxContainer.new()
	gems_row.add_theme_constant_override("separation", 3)
	gems.add_child(gems_row)
	gems_row.add_child(Art.texrect(Ui.GEM, 22, 22))
	_gems = Art.label(str(Game.START_GEMS), Pal.BODY, Pal.CREAM)
	_gems.custom_minimum_size = Vector2(30, 0)
	_gems.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	gems_row.add_child(_gems)
	bar.add_child(gems)

	_time_plate = _plate(6)
	_time = Art.label(Ui.mmss(int(Game.time_left)), Pal.BODY, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	_time.custom_minimum_size = Vector2(58, 0)   # "Paused" and "10:00" alike
	_time.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_time_plate.add_child(_time)
	bar.add_child(_time_plate)


## Whether the bar, ribbon and all, fits the screen as painted. Measured, not
## estimated: the ribbon's end caps and the plates' own margins are whatever
## the art makes them.
func _fits() -> bool:
	if not is_instance_valid(_bar) or not adv.is_inside_tree():
		return true
	return _bar.get_combined_minimum_size().x <= adv.get_viewport_rect().size.x - 12.0


## The station ribbon, in the row of BigRibbons that is this station's colour.
func _paint_ribbon(row: int, text: String) -> void:
	if not is_instance_valid(_ribbon):
		return
	for c in _ribbon.get_children():
		_ribbon.remove_child(c)
		c.queue_free()
	_ribbon.add_child(Ui.ribbon(row, text))


## A dot per item in the current station: done, the one being played, to come.
## Shape as well as colour -- done is filled, current is ringed.
func _paint_pips(station: int, done_in_station: int) -> void:
	if not is_instance_valid(_pips):
		return
	for c in _pips.get_children():
		c.queue_free()
	var total: int = Game.ITEMS_PER_STATION[station] if station >= 0 else 0
	for i in total:
		var dot := Panel.new()
		dot.custom_minimum_size = Vector2(9, 9)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var face := StyleBoxFlat.new()
		face.set_corner_radius_all(5)
		if i < done_in_station:
			face.bg_color = Pal.GOLD
			face.border_color = Pal.SHADOW
			face.set_border_width_all(1)
		elif i == done_in_station:
			face.bg_color = Color(1, 1, 1, 0.25)
			face.border_color = Pal.WHITE
			face.set_border_width_all(2)
		else:
			face.bg_color = Color(0, 0, 0, 0.45)
			face.border_color = Color(1, 1, 1, 0.35)
			face.set_border_width_all(1)
		dot.add_theme_stylebox_override("panel", face)
		_pips.add_child(dot)


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
	joystick.ignore = pointer_hit
	pad.add_child(joystick)
	# Measured in from the right edge, not from 640: `keep_height` makes the
	# canvas ~800 wide on a 20:9 phone, and fixed coordinates left GO and MENU
	# stranded 160px short of the thumb that reaches for them.
	var right := adv.get_viewport_rect().size.x
	_touch_btn("interact", "GO", Vector2(right - 66, 290), 0.52, 20, false)
	_touch_btn("pause", "MENU", Vector2(right - 34, 74), 0.34, 11, true)


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
	_pad_buttons.append(b)
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


# --- Looking around the map -------------------------------------------------
## While a finger drags the view, GO and MENU stop pressing themselves when a
## finger slides onto them (`passby_press`): a look across the bottom-right
## corner would otherwise press GO on the way past.
func set_panning(on: bool) -> void:
	for b in _pad_buttons:
		b.passby_press = not on


## A touch at `pos` (viewport px) that belongs to the HUD, not to the board:
## GO or MENU, the hero pointer, or any HUD control that takes clicks (the top
## bar's plates, the dev drawer). The board neither pans nor taps from these.
func owns_touch(pos: Vector2) -> bool:
	if pad != null and pad.visible:
		for b in _pad_buttons:
			var r := 64.0 * b.scale.x
			if (b.position + Vector2(r, r)).distance_to(pos) <= r:
				return true
	if pointer_hit(pos):
		return true
	for layer in [hud_layer, ui_layer]:
		for c: Control in layer.find_children("*", "Control", true, false):
			if c.is_visible_in_tree() and c.mouse_filter == Control.MOUSE_FILTER_STOP \
					and c.get_global_rect().has_point(pos):
				return true
	return false


## `pos` is on the hero pointer (and it is showing). The screen asks this for
## raw touches, because a second finger -- the left thumb already on the stick
## -- is never turned into the mouse click the button itself listens for.
func pointer_hit(pos: Vector2) -> bool:
	return hero_pointer != null and hero_pointer.visible \
			and hero_pointer.get_global_rect().grow(6.0).has_point(pos)


## Shows the pointer at `at` (its centre, viewport px) aiming along `dir`, or
## hides it.
func point_to_hero(show: bool, at := Vector2.ZERO, dir := Vector2.RIGHT) -> void:
	if hero_pointer == null:
		return
	hero_pointer.visible = show
	if show:
		hero_pointer.position = at - hero_pointer.size * 0.5
		hero_pointer.aim(dir)


## Hiding a TouchScreenButton releases its action on its own; the stick is a
## plain Node2D, so a held drag needs the same release told explicitly, or it
## would survive into a quiz or the pause menu.
func set_pad(on: bool) -> void:
	if pad != null:
		pad.visible = on
	if not on and joystick != null:
		joystick.release()


## A line over everything -- the question screen included -- for news from
## another player: "ana rescued you! +15 gems". The prompt line sits under the
## overlays, where a player mid-question would never see it.
## On the HUD's own wooden plate, so it reads over the parchment of a question
## as well as over the map.
var _news: Label = null
var _news_bar: Control = null
var _news_tw: Tween = null


func announce(text: String) -> void:
	if _news_bar == null or not is_instance_valid(_news_bar):
		_news_bar = CenterContainer.new()
		_news_bar.name = "NewsBar"
		_news_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		_news_bar.offset_top = 46.0
		_news_bar.offset_bottom = 84.0
		_news_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_news = Art.label("", Pal.BODY + 2, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
		_news.name = "News"
		_news.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var plate := Ui.plank(_news, 14.0)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_news_bar.add_child(plate)
		ui_layer.add_child(_news_bar)
	ui_layer.move_child(_news_bar, -1)       # over whatever opened since
	_news.text = text
	_news_bar.visible = true
	_news_bar.modulate.a = 1.0
	if _news_tw != null and _news_tw.is_valid():
		_news_tw.kill()
	_news_tw = _news_bar.create_tween()
	_news_tw.tween_interval(3.5)
	_news_tw.tween_property(_news_bar, "modulate:a", 0.0, 0.5)
	_news_tw.tween_callback(func() -> void:
		_news_bar.visible = false
		_news.text = "")


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


## The gem plate, and a flash of the change: green up, red down. A number
## that just changes is easy to miss mid-walk.
func on_gems(g: int) -> void:
	if not is_instance_valid(_gems):
		return
	_gems.text = str(g)
	if _shown_gems != -99999 and g != _shown_gems:
		if _gem_tw != null and _gem_tw.is_valid():
			_gem_tw.kill()
		_gems.add_theme_color_override("font_color", Pal.CORRECT_BRIGHT if g > _shown_gems else Pal.WRONG_BRIGHT)
		_gem_tw = _gems.create_tween()
		_gem_tw.tween_interval(0.6)
		_gem_tw.tween_callback(func() -> void: _gems.add_theme_color_override("font_color", Pal.CREAM))
	_shown_gems = g


## The clock: red in the last minute, and "Paused" while the teacher holds it
## -- a frozen number alone reads as the game having hung.
func on_time(sec: int) -> void:
	if not is_instance_valid(_time):
		return
	if Game.session_state == "paused":
		_time.text = "Paused"
		_time.add_theme_color_override("font_color", Pal.AMBER)
		return
	_time.text = Ui.mmss(sec)
	_time.add_theme_color_override("font_color",
		Pal.WRONG_BRIGHT if sec <= LAST_MINUTE and Game.adventure_active else Pal.CREAM)


func refresh() -> void:
	on_gems(Game.gems)
	on_time(int(ceilf(Game.time_left)))
	var next := Game.completed_stations.find(false)
	if Game.items_done >= Game.TOTAL_ITEMS:
		_paint_ribbon(GATE_ROW, "Victory Gate!")
		_paint_pips(-1, 0)
	else:
		var st := Game.station_of_item(Game.items_done)
		var meta: Dictionary = QuestionGen.station_meta(st)
		# "Station 1: Master the Basics!" -> "Station 1 · Master the Basics!",
		# or the topic's short name when the full title will not fit between
		# the plates -- at 640 wide, Station 3's pushed the clock off-screen.
		var full := str(meta.title).replace(": ", "  ·  ")
		var brief := "Station %d  ·  %s" % [st + 1, str(meta.short)]
		_paint_ribbon(RIBBON_ROW[st], full)
		if not _fits():
			_paint_ribbon(RIBBON_ROW[st], brief)
		_paint_pips(st, Game.item_in_station(Game.items_done))
	# Label the boards on the map itself, otherwise all three look identical.
	for i in adv.stations.locks.size():
		var mark := "—"
		if Game.completed_stations[i]:
			mark = "★" if Game.perfect_stations[i] else "✓"
		elif i == next:
			mark = "▶"
		adv.stations.locks[i].text = "Station %d  %s" % [i + 1, mark]


## Not a pause. Players have no pause button -- only the admin can stop the
## clock, and one press stops it for everyone (SPECS §2, confirmed by the
## client 2026-09-23). This menu never touched `Game.clock_paused` anyway; it
## was only ever called "Paused", which was a lie the label told.
func open_menu() -> void:
	if paused:
		return
	paused = true
	adv._close_card()
	close_dev()
	set_pad(false)
	Sfx.play("panel_open")
	var box := Ui.screen_panel(ui_layer, Vector2(300, 270), "Menu")
	var menu := box.get_parent()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)
	# Not a pause -- only the teacher stops the clock -- and it has to say so,
	# or a student reads the menu as a breather.
	var note := Art.label("The clock keeps running.", Pal.SMALL, Pal.WRONG,
		HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(note)
	# label, kind, screen to open ("" = stay on the map), what to do with the
	# run in progress. Resume is the one primary; New Game throws the run
	# away, so it is last and the only red -- it was red beside Leaderboard,
	# which made a harmless look match a destructive one.
	for spec in [["Resume", Ui.RED, "", ""],
			["Leaderboard", Ui.SMALL, "board", ""],
			["Home", Ui.SMALL, "home", "end"],
			["Restart", Ui.SMALL, "adventure", "restart"],
			["New Game", Ui.SMALL_RED, "hero", "abandon"]]:
		var b := Ui.button(spec[0], 200, Ui.H, spec[1])
		b.pressed.connect(_leave_menu.bind(menu, spec[2], spec[3]))
		Ui.centre_row(box, b)
		if spec[0] == "Resume" and Game.session_id != "":
			_menu_rescue(box, menu)


## Rescue from the map, not only from a question: whoever is running low needs
## it now, not at the rescuer's next circle. Team games only; greyed with the
## reason once it cannot be used.
func _menu_rescue(box: VBoxContainer, menu: Control) -> void:
	var why := Game.rescue_block()
	var r := Ui.button("Rescue used" if Game.rescue_sent else "Rescue a teammate", 200, Ui.H, Ui.SMALL)
	r.name = "Rescue"
	r.disabled = why != ""
	r.tooltip_text = why if why != "" else "Give some of your gems to a teammate"
	r.pressed.connect(func() -> void:
		_leave_menu(menu, "", "")
		adv.open_rescue())
	Ui.centre_row(box, r)


## Every exit closes the menu. `drop` decides the fate of the run in
## progress -- "end" scores it, "restart" and "abandon" discard it unscored --
## and `screen` where to go next. Restart rebuilds the island, because `open()`
## remakes the screen, and the gems go back to the starting purse.
func _leave_menu(menu: Control, screen: String, drop: String) -> void:
	paused = false
	set_pad(true)
	menu.queue_free()
	if screen == "":
		Sfx.play("panel_close")         # Resume: back to the map
	match drop:
		"end": Game.end_adventure()
		"restart": Game.restart_adventure()
		"abandon": Game.abandon_adventure()
	if screen != "":
		adv.main.open(screen)


## The arrow back to the hero: a wooden disc on the edge of the screen with an
## arrow aimed at where the hero stands. Tapping it (or moving, or GO) brings
## the camera home. 44px, the touch-target floor.
class HeroPointer extends Control:
	signal pressed

	const SIDE := 44.0
	var _dir := Vector2.RIGHT

	func _init() -> void:
		size = Vector2(SIDE, SIDE)
		custom_minimum_size = size
		mouse_filter = Control.MOUSE_FILTER_STOP
		tooltip_text = "Back to your hero"

	func aim(dir: Vector2) -> void:
		if dir.length_squared() > 0.0001 and not dir.normalized().is_equal_approx(_dir):
			_dir = dir.normalized()
			queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		draw_circle(c + Vector2(0, 2), SIDE * 0.5 - 2.0, Color(0, 0, 0, 0.35))
		draw_circle(c, SIDE * 0.5 - 2.0, Color(0.42, 0.29, 0.19))
		draw_arc(c, SIDE * 0.5 - 3.0, 0.0, TAU, 40, Pal.GOLD, 2.0)
		var side := _dir.orthogonal()
		var tip := c + _dir * 13.0
		var back := c - _dir * 7.0
		draw_colored_polygon(PackedVector2Array([tip, back + side * 10.0, c - _dir * 2.0,
				back - side * 10.0]), Pal.CREAM)

	## A touch arrives here as a touch, not only as the mouse a phone makes of
	## it -- and a second finger (the first on the stick) only ever as a touch.
	func _gui_input(event: InputEvent) -> void:
		var tap := (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
				or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed
					and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT)
		if tap:
			accept_event()
			pressed.emit()

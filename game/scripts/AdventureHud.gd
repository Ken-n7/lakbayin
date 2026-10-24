class_name AdventureHud
extends RefCounted

## Everything drawn over the match (Lakbayin): the top bar -- who you are, the
## score, what you carry, the clock -- the minimap, the prompt line, the
## controls crib and the touch pad.
##
## Two CanvasLayers, because the player's Camera2D transforms every canvas item
## in layer 0 -- UI included -- so screen-space elements dragged around the
## world with the camera until they were lifted out of it.
##
## Holds no game state: it reads the screen's `Match` and `Game`'s clock, and
## is told when to refresh (the screen's `play`).

var adv: Control
var hud_layer: CanvasLayer   # the board furniture
var ui_layer: CanvasLayer    # overlays, over the top of it

var prompt: Label
var joystick: Node2D = null
var minimap: Minimap = null

var _score_box: HBoxContainer
var _carry: Label
var _time: Label
var _hint_bar: Label = null  # the controls crib, hidden while the board is frozen
var _conn_label: Label = null   # "Weak connection" / "Reconnecting…", while it is
var _crib_tw: Tween = null
## How long the phone's crib stays up once play starts (set_crib).
const CRIB_HOLD_S := 10.0
## The stick and the GO button. Null on desktop, where there is no pad.
var pad: Node2D = null
var _pad_buttons: Array[TouchScreenButton] = []
## The way back while the camera is off looking at the map: an arrow on the
## screen's edge, pointing at the hero, that brings the view home when tapped.
var hero_pointer: HeroPointer = null
var _flash_active := false

## The board is held -- the intro, or the match over. The screen reads this to
## stop the hero walking and to keep the board from taking taps.
var paused := false


func _init(screen: Control) -> void:
	adv = screen


# --- HUD --------------------------------------------------------------------
func build() -> void:
	hud_layer = CanvasLayer.new()
	hud_layer.layer = 1
	adv.add_child(hud_layer)
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 2
	adv.add_child(ui_layer)
	_build_top_bar()

	# Full-width, not centre-anchored: PRESET_CENTER_BOTTOM puts the box's left
	# edge at mid-screen, so a 640-wide label started in the middle and ran off
	# the right edge. The CenterContainer keeps the label hugging its text.
	var prompt_row := CenterContainer.new()
	prompt_row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	prompt_row.offset_top = -104.0
	prompt_row.offset_bottom = -74.0
	prompt_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(prompt_row)
	# The one line that says what to do next, on a dark plate: bare text over
	# grass and trees was easy to miss.
	prompt = Art.label("", Pal.H2, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	var plate := StyleBoxFlat.new()
	plate.bg_color = Color(0, 0, 0, 0.6)
	plate.set_corner_radius_all(8)
	plate.content_margin_left = 12.0
	plate.content_margin_right = 12.0
	plate.content_margin_top = 2.0
	plate.content_margin_bottom = 2.0
	prompt.add_theme_stylebox_override("normal", plate)
	prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prompt.visible = false
	prompt_row.add_child(prompt)

	var keys := ("joystick — move   ·   drag — look   ·   GO — answer / deposit" if Game.touch
			else "WASD / arrows — move   ·   drag — look   ·   E — answer / deposit")
	var hint_bar: Label = Art.label(keys, Pal.TINY, Pal.WHITE_DIM, HORIZONTAL_ALIGNMENT_CENTER)
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
	for l in [prompt, hint_bar]:
		Art.shadow(l)

	# The map in the top-left corner, where the name plate was (Minimap below).
	# Its rim is your team's colour: with the plate gone, that is what says
	# which side you are on.
	minimap = Minimap.new()
	minimap.name = "Minimap"
	minimap.rim = Peers.TEAM_COLOURS[adv.play.team]
	minimap.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	minimap.offset_left = 10.0
	minimap.offset_right = 10.0 + Minimap.SIZE.x
	minimap.offset_top = 8.0
	minimap.offset_bottom = 8.0 + Minimap.SIZE.y
	hud_layer.add_child(minimap)

	# The line, when it is bad -- a game's red signal bars, in words. Under the
	# plates, on the right.
	_conn_label = Art.label("", Pal.SMALL, Pal.CREAM, HORIZONTAL_ALIGNMENT_RIGHT)
	_conn_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_conn_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_conn_label.offset_left = -330.0
	_conn_label.offset_right = -10.0
	_conn_label.offset_top = 48.0
	_conn_label.offset_bottom = 72.0
	_conn_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_conn_label.visible = false
	var conn_plate := StyleBoxFlat.new()
	conn_plate.bg_color = Color(0, 0, 0, 0.6)
	conn_plate.set_corner_radius_all(6)
	conn_plate.content_margin_left = 8.0
	conn_plate.content_margin_right = 8.0
	_conn_label.add_theme_stylebox_override("normal", conn_plate)
	hud_layer.add_child(_conn_label)

	_build_pad()
	hero_pointer = HeroPointer.new()
	hero_pointer.visible = false
	hero_pointer.pressed.connect(func() -> void: adv.end_look())
	hud_layer.add_child(hero_pointer)


# --- The top bar ------------------------------------------------------------
## Plates floating over the board, not one plank across it: the map shows
## between them, and each plate is one thing to read.
##   left   -- the player's own hero in a wooden frame, name and team
##   centre -- the score: Blue's deposits and Red's, or yours of the words
##   right  -- what you carry, and the clock (red in the last minute)
const PLANK := "res://assets/ui/BigBar_Base.png"
const BAR_H := 40.0
const LAST_MINUTE := 60


func _plate(pad_x: float) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", Ui.frame(PLANK, Ui.BAR_K, Vector2(pad_x, 0)))
	p.custom_minimum_size.y = 51.0 * Ui.BAR_K
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _build_top_bar() -> void:
	var bar := HBoxContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = 6.0
	bar.offset_right = -6.0
	bar.offset_top = 4.0
	bar.offset_bottom = 4.0 + BAR_H
	bar.add_theme_constant_override("separation", 4)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(bar)

	# Left: room for the minimap, which sits over this end of the bar.
	var m: Match = adv.play
	var room := Control.new()
	room.custom_minimum_size = Vector2(Minimap.SIZE.x + 8.0, 0)
	room.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(room)

	# Centre: the score on a ribbon -- the one number everybody watches.
	var mid := CenterContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_score_box = HBoxContainer.new()
	_score_box.add_theme_constant_override("separation", 0)
	mid.add_child(_score_box)
	bar.add_child(mid)

	# Right: what you carry, then the clock.
	var carry := _plate(6)
	_carry = Art.label("", Pal.BODY, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	_carry.name = "Carry"
	_carry.custom_minimum_size = Vector2(70, 0)
	_carry.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	carry.add_child(_carry)
	bar.add_child(carry)
	var clock := _plate(6)
	_time = Art.label(Ui.mmss(int(Game.time_left)), Pal.BODY, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	_time.custom_minimum_size = Vector2(52, 0)
	_time.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	clock.add_child(_time)
	bar.add_child(clock)
	# Settings, last on the bar: volumes, and Leave in Practice.
	var gear := Ui.button("", 38, BAR_H - 6, Ui.SMALL)
	gear.name = "Settings"
	gear.tooltip_text = "Settings"
	gear.icon = Ui.icon("gear")
	gear.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gear.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	gear.pressed.connect(adv.open_settings)
	bar.add_child(gear)


## The score and what is carried, from the match.
func refresh() -> void:
	var m: Match = adv.play
	for c in _score_box.get_children():
		_score_box.remove_child(c)
		c.queue_free()
	var text := ("%d / %d words" % [m.deposited(), m.monk_count()] if m.practice
		else "Blue %d  –  %d Red" % [m.deposited(0), m.deposited(1)])
	var rib := Ui.ribbon(Ui.RIBBON_BLUE if m.team == 0 else Ui.RIBBON_RED, text)
	rib.name = "Score"
	_score_box.add_child(rib)
	var n := m.carried().size()
	_carry.text = "Carry %d" % n
	_carry.add_theme_color_override("font_color", Pal.GOLD if n > 0 else Pal.CREAM)
	on_time(int(ceilf(Game.time_left)))


## The clock: red in the last minute.
func on_time(sec: int) -> void:
	if not is_instance_valid(_time):
		return
	_time.text = Ui.mmss(sec)
	_time.add_theme_color_override("font_color",
		Pal.WRONG_BRIGHT if sec <= LAST_MINUTE and Game.adventure_active else Pal.CREAM)


# --- Touch controls ---------------------------------------------------------
## The stick is a raw-touch Node2D (its own finger index, like TouchScreenButton
## tracks), and GO stays a TouchScreenButton -- both read real touch rather
## than mouse-emulated, so steering and pressing GO work on separate fingers at
## once. Each feeds a real InputMap action (the stick with analog strength).
func _build_pad() -> void:
	if not Game.touch:
		return
	pad = Node2D.new()
	hud_layer.add_child(pad)
	joystick = preload("res://scripts/Joystick.gd").new()
	# The arrow back to the hero, and the dev panel: the stick takes touches
	# before any button, so it has to be told what is not its.
	joystick.ignore = func(at: Vector2) -> bool: return pointer_hit(at) or DevUi.owns(adv.get_tree(), at)
	pad.add_child(joystick)
	# Measured in from the right edge, not from 640: `keep_height` makes the
	# canvas ~800 wide on a 20:9 phone.
	var right := adv.get_viewport_rect().size.x
	_touch_btn("interact", "GO", Vector2(right - 66, 290), 0.52, 20)


func _touch_btn(action: String, text: String, center: Vector2, s: float, font: int) -> void:
	var skin := "res://assets/ui/SmallBlueRoundButton_%s.png"
	var b := TouchScreenButton.new()
	b.texture_normal = Art.tex(skin % "Regular")
	b.texture_pressed = Art.tex(skin % "Pressed")
	b.action = action
	b.passby_press = true   # a thumb sliding onto GO still presses it
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


## "good", "weak" or "offline" (Net.connection()): nothing, amber, red.
func set_connection(state: String) -> void:
	if not is_instance_valid(_conn_label):
		return
	_conn_label.visible = state != "good"
	_conn_label.text = ("Reconnecting… your answers are saved" if state == "offline"
			else "Weak connection")
	_conn_label.add_theme_color_override("font_color",
			Pal.WRONG_BRIGHT if state == "offline" else Pal.GOLD)


## The controls crib: a reminder for the first moments of play on a phone,
## then it fades and leaves the top of the board clear.
func set_crib(on: bool) -> void:
	if _hint_bar == null or not is_instance_valid(_hint_bar):
		return
	if _crib_tw != null and _crib_tw.is_valid():
		_crib_tw.kill()
	_hint_bar.modulate.a = 1.0
	_hint_bar.visible = on
	if on and Game.touch:
		_crib_tw = _hint_bar.create_tween()
		_crib_tw.tween_interval(CRIB_HOLD_S)
		_crib_tw.tween_property(_hint_bar, "modulate:a", 0.0, 1.0)
		_crib_tw.tween_callback(func() -> void: _hint_bar.visible = false)


## The dev panel (DevPanel, debug builds), shut: a monk's panel coming up
## should not open under it.
func close_dev() -> void:
	adv.get_tree().call_group("dev_panel", "close")


# --- Looking around the map -------------------------------------------------
## While a finger drags the view, GO stops pressing itself when a finger slides
## onto it (`passby_press`): a look across the bottom-right corner would
## otherwise press GO on the way past.
func set_panning(on: bool) -> void:
	for b in _pad_buttons:
		b.passby_press = not on


## A touch at `pos` (viewport px) that belongs to the HUD, not to the board:
## GO, the hero pointer, any HUD control that takes clicks, or the dev panel.
func owns_touch(pos: Vector2) -> bool:
	if DevUi.owns(adv.get_tree(), pos):
		return true
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


## `pos` is on the hero pointer (and it is showing). Asked for raw touches: a
## second finger -- the left thumb already on the stick -- is never turned into
## the mouse click the button itself listens for.
func pointer_hit(pos: Vector2) -> bool:
	return hero_pointer != null and hero_pointer.visible \
			and hero_pointer.get_global_rect().grow(6.0).has_point(pos)


func point_to_hero(show: bool, at := Vector2.ZERO, dir := Vector2.RIGHT) -> void:
	if hero_pointer == null:
		return
	hero_pointer.visible = show
	if show:
		hero_pointer.position = at - hero_pointer.size * 0.5
		hero_pointer.aim(dir)


## Hiding a TouchScreenButton releases its action on its own; the stick is a
## plain Node2D, so a held drag needs the same release told explicitly, or it
## would survive into a monk's panel.
func set_pad(on: bool) -> void:
	if pad != null:
		pad.visible = on
	if not on and joystick != null:
		joystick.release()


## A line over everything -- a monk's panel included -- for news: a teammate's
## answer, the other team's last word.
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
	_news_tw.tween_interval(3.0)
	_news_tw.tween_property(_news_bar, "modulate:a", 0.0, 0.5)
	_news_tw.tween_callback(func() -> void:
		_news_bar.visible = false
		_news.text = "")


func flash(text: String) -> void:
	if not is_instance_valid(prompt):
		return
	_flash_active = true
	_fit_prompt(text)
	Art.toast(prompt, text, 1.2, "", func() -> void:
		_flash_active = false
		prompt.visible = false)   # an empty plate is a dark blob


## The prompt line -- what pressing E would do, right now. Ignored while a
## toast owns the line.
func set_prompt(text: String) -> void:
	if _flash_active or not is_instance_valid(prompt):
		return
	_fit_prompt(text)
	prompt.text = text
	prompt.visible = text != ""


## The prompt hugs its text, up to PROMPT_MAX_W; longer wraps onto more lines
## instead of running off both sides.
const PROMPT_MAX_W := 560.0
func _fit_prompt(text: String) -> void:
	var w := prompt.get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, prompt.get_theme_font_size("font_size")).x
	var wraps := w > PROMPT_MAX_W
	prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wraps else TextServer.AUTOWRAP_OFF
	prompt.custom_minimum_size.x = PROMPT_MAX_W if wraps else 0.0


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

	func _gui_input(event: InputEvent) -> void:
		var tap := (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
				or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed
					and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT)
		if tap:
			accept_event()
			pressed.emit()


## The world in the corner: the island, the monks your team has come near
## (Black) or answered (your colour), your teammates, you, and the Monastery
## once found (DESIGN.md 3.2, team vision). Drawn from `points()` five times a
## second -- the screen hands it the lot.
class Minimap extends Control:
	const SIZE := Vector2(132, 74)
	const EVERY_S := 0.2
	var land: Texture2D = null
	## {me, mates: [Vector2], mate_colour, monks: [[Vector2, state]], monastery}
	## in world px; a monk's state is "seen" or "ours"; monastery null till seen.
	var source: Callable
	var rim := Color("986050")
	## The world px the picture covers (the whole world until the aerial view
	## replaces the plain island).
	var area := Rect2(Vector2.ZERO, Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE)
	var _t := 0.0
	var _pts := {}

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = SIZE

	## The island as an image, a pixel a cell, drawn scaled.
	func set_land(cells: Dictionary) -> void:
		var img := Image.create(MapCfg.WORLD_W, MapCfg.WORLD_H, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.16, 0.27, 0.45, 0.85))
		for c: Vector2i in cells:
			img.set_pixelv(c, Color(0.49, 0.66, 0.31))
		land = ImageTexture.create_from_image(img)
		queue_redraw()

	func _process(delta: float) -> void:
		_t -= delta
		if _t > 0.0 or not source.is_valid():
			return
		_t = EVERY_S
		_pts = source.call()
		queue_redraw()

	func _at(p: Vector2) -> Vector2:
		return (p - area.position) / area.size * SIZE

	func _draw() -> void:
		# The pack's edge: a navy outline round a rim in your team's colour.
		draw_rect(Rect2(Vector2(-4, -4), SIZE + Vector2(8, 8)), Color("101828"))
		draw_rect(Rect2(Vector2(-3, -3), SIZE + Vector2(6, 6)), rim)
		draw_rect(Rect2(Vector2(-1, -1), SIZE + Vector2(2, 2)), Color("101828"))
		if land != null:
			draw_texture_rect(land, Rect2(Vector2.ZERO, SIZE), false)
		if _pts.is_empty():
			return
		if _pts.get("monastery") != null:
			# Found: the building itself, small, standing on its door.
			var tex := Art.cell(MapWorld.MONASTERY, 0, 0)
			var h := 16.0
			var w := h * tex.region.size.x / tex.region.size.y
			var c := _at(_pts.monastery)
			draw_texture_rect(tex, Rect2(c - Vector2(w * 0.5, h), Vector2(w, h)), false)
		var col: Color = _pts.get("mate_colour", Color.WHITE)
		for m: Array in _pts.get("monks", []):
			var c := _at(m[0])
			draw_circle(c, 2.6, Pal.SHADOW)
			draw_circle(c, 2.0, col if m[1] == "ours" else Color(0.85, 0.85, 0.85))
		for p: Vector2 in _pts.get("mates", []):
			draw_circle(_at(p), 2.2, col)
		if _pts.has("me"):
			draw_circle(_at(_pts.me), 3.2, Pal.SHADOW)
			draw_circle(_at(_pts.me), 2.4, Color.WHITE)

class_name MapWatch
extends Control

## The teacher's view of the board: the class's map with every student on it,
## to fly over while the game runs. Drag to move, scroll or pinch to zoom,
## WASD / arrows too; + / − / Whole map in the corner for a phone.
##
## No camera: the board is moved and scaled itself. A Camera2D moves the whole
## canvas, and Game Controls' own bar and dialogs live on that canvas -- they
## would fly off with the map.
##
## Students come from `Peers`, fed the same way the players' boards feed it:
## positions off the Broadcast socket, the roster off `members`. The teacher is
## not a member and never tracks presence, so watching counts for nobody's
## "ready".

## Closest the view goes -- a little nearer than the players' own 0.75, to
## read a name tag. The farthest is the whole board, worked out from the screen.
const MAX_ZOOM := 1.25
const WHEEL_STEP := 1.15
const BUTTON_STEP := 1.6
const KEY_PAN := 600.0           # px a second at the screen, whatever the zoom
const GLIDE_S := 0.25
const SEA := Color("47aba9")     # the water tile's own colour, before the tint
## Under the 44 the guidelines ask for, on purpose: at 44 the stack sat on
## the base camp. 36 in a row keeps to the open sea below the islands.
const BTN := 36.0
## Kept clear when the whole map is framed: the bar above, the zoom row below.
const FIT_PAD := Vector2(24, 96)
const ROUND_UP := "res://assets/ui/SmallBlueRoundButton_Regular.png"
const ROUND_DOWN := "res://assets/ui/SmallBlueRoundButton_Pressed.png"
const PLATE := Color(0.42, 0.29, 0.19)   # the HUD planks' wood, as a flat plate

var world: MapWorld
var _peers: Peers
var _sid := ""
var _rows := {}                  # profile_id -> the row Peers draws from
var _loading := false
var _touches := {}               # index -> position, for the pinch
var _glide: Tween
var _zoom_in: TextureButton
var _zoom_out: TextureButton


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	# Past the board's edge when zoomed out: more sea, not a black frame.
	# Under everything -- the water tiles themselves sit at a negative z.
	var sea := ColorRect.new()
	sea.color = SEA * MapCfg.WATER_TINT
	sea.z_index = RenderingServer.CANVAS_ITEM_Z_MIN
	sea.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sea.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(sea)
	world = MapWorld.new()
	add_child(world)
	world.build()
	_peers = Peers.new()
	world.add_child(_peers)
	_build_buttons()
	resized.connect(func() -> void: _set_zoom(world.scale.x, size * 0.5))
	# The whole board from the first frame -- the lowest zoom there is.
	_set_zoom.call_deferred(0.0, Vector2.ZERO)


## Starts following a session: who is in it, and where they walk.
func watch(session_id: String) -> void:
	if session_id == _sid:
		return
	_sid = session_id
	_rows = {}
	var rt: Realtime = Net.realtime()
	if not rt.broadcast.is_connected(_on_broadcast):
		rt.broadcast.connect(_on_broadcast)
	if not rt.changed.is_connected(_on_row):
		rt.changed.connect(_on_row)
	_load()


## Nothing animates while Game Controls has the map put away.
func set_shown(on: bool) -> void:
	visible = on
	process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED


func _load() -> void:
	if _sid == "" or _loading:
		return
	_loading = true
	var sid := _sid
	var rows: Array = await Teams.everyone(sid)
	var teams: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/teams?select=id&session_id=eq." + sid + "&order=name")
	_loading = false
	if not is_instance_valid(self) or sid != _sid:
		return
	_peers.set_team_order((teams.data if teams.data is Array else []).map(
		func(t: Dictionary) -> String: return str(t.get("id", ""))))
	_rows = {}
	for r: Dictionary in rows:
		_rows[str(r.profile_id)] = r
	_redraw()


func _redraw() -> void:
	_peers.refresh(_rows.values(), world.peer_anchors(), world.gate_at(), Net.user_id)


func _on_broadcast(event: String, data: Dictionary) -> void:
	if event == "pos" and str(data.get("sid", "")) == _sid and _sid != "":
		_peers.move(str(data.get("id", "")), data)


## A member's row changed -- an answer, a team move, an elimination. Merged
## where it stands; anything the row does not carry (a newcomer's name, a
## removal) costs one read.
func _on_row(table: String, type: String, record: Dictionary) -> void:
	if _sid == "" or str(record.get("session_id", _sid)) != _sid:
		return
	if table == "teams":
		_load()
		return
	if table != "members":
		return
	var id := str(record.get("profile_id", ""))
	if type == "UPDATE" and _rows.has(id):
		var row: Dictionary = _rows[id]
		row.items_done = int(record.get("items_done", row.items_done))
		row.eliminated = bool(record.get("eliminated", row.eliminated))
		row.gems = int(record.get("gems", row.gems))
		row.team_id = "" if record.get("team_id") == null else str(record.get("team_id"))
		_redraw()
	else:
		_load()


# --- Flying -----------------------------------------------------------------
## The whole board, centred.
func fit() -> void:
	_glide_to(_min_zoom(), size * 0.5)


## Framed inside the room the bar and the zoom row leave, so the whole map
## is the whole map -- at full height the row sat on the base camp.
func _min_zoom() -> float:
	var board := Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE
	var room := size - FIT_PAD
	return minf(room.x / board.x, room.y / board.y) if room.x > 0.0 and room.y > 0.0 else 0.2


## Zoom to `z`, keeping the board point under `at` (a screen point) under it.
func _set_zoom(z: float, at: Vector2) -> void:
	var old := world.scale.x
	z = clampf(z, _min_zoom(), MAX_ZOOM)
	var point := (at - world.position) / old
	world.scale = Vector2(z, z)
	world.position = at - point * z
	_clamp()
	_update_buttons()


func _glide_to(z: float, at: Vector2) -> void:
	if _glide != null and _glide.is_valid():
		_glide.kill()
	_glide = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_glide.tween_method(_set_zoom.bind(at), world.scale.x, clampf(z, _min_zoom(), MAX_ZOOM),
		GLIDE_S)


## The board never slides off the screen; smaller than the screen, it sits
## in the middle.
func _clamp() -> void:
	var board := Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE * world.scale.x
	for a in 2:
		if board[a] <= size[a]:
			world.position[a] = (size[a] - board[a]) * 0.5
		else:
			world.position[a] = clampf(world.position[a], size[a] - board[a], 0.0)


func _pan(by: Vector2) -> void:
	world.position += by
	_clamp()


func _process(delta: float) -> void:
	var dir := Vector2(Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down"))
	if dir != Vector2.ZERO and not _typing():
		_pan(-dir * KEY_PAN * delta)


## WASD must not fly the map while the teacher types a team name.
func _typing() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_zoom(world.scale.x * WHEEL_STEP, event.position)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_zoom(world.scale.x / WHEEL_STEP, event.position)
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT \
			and _touches.size() < 2:
		# One finger arrives here too (touch is emulated as the mouse).
		_pan(event.relative)
	elif event is InputEventMagnifyGesture:
		_set_zoom(world.scale.x * event.factor, event.position)
	elif event is InputEventPanGesture:
		_pan(-event.delta * 12.0)
	elif event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
	elif event is InputEventScreenDrag and _touches.size() == 2 and _touches.has(event.index):
		# Two fingers: the gap between them is the zoom, their midpoint the pan.
		var other: Vector2 = _touches[_touches.keys().filter(
			func(k: int) -> bool: return k != event.index)[0]]
		var was: Vector2 = _touches[event.index]
		_touches[event.index] = event.position
		var gap0 := was.distance_to(other)
		if gap0 > 1.0:
			_set_zoom(world.scale.x * event.position.distance_to(other) / gap0,
				(was + other) * 0.5)
		_pan(((event.position + other) - (was + other)) * 0.5)


## Bottom-right in one low row, the way map apps group it: zoom in and out
## together on a wooden plate, the whole-map button apart from it so it is
## never hit by mistake. Round pack buttons with the symbols drawn as pixels -- a font's
## "+" and "⤢" were two different styles on one control. Each goes dim at the
## end of its range, so the limit is visible rather than a tap that does
## nothing.
func _build_buttons() -> void:
	var col := HBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	col.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	col.grow_vertical = Control.GROW_DIRECTION_BEGIN
	col.offset_right = -10.0
	col.offset_bottom = -8.0
	add_child(col)

	var zoom := HBoxContainer.new()
	zoom.add_theme_constant_override("separation", 4)
	var plate := PanelContainer.new()
	var wood := StyleBoxFlat.new()
	wood.bg_color = PLATE
	wood.border_color = Pal.WOOD.darkened(0.35)
	wood.set_border_width_all(2)
	wood.set_corner_radius_all(8)
	wood.set_content_margin_all(3)
	plate.add_theme_stylebox_override("panel", wood)
	plate.add_child(zoom)
	col.add_child(plate)
	_zoom_in = _round_button("plus", "Zoom in", func() -> void:
		_glide_to(world.scale.x * BUTTON_STEP, size * 0.5))
	_zoom_out = _round_button("minus", "Zoom out", func() -> void:
		_glide_to(world.scale.x / BUTTON_STEP, size * 0.5))
	zoom.add_child(_zoom_out)
	zoom.add_child(_zoom_in)
	var whole := _round_button("frame", "Whole map", fit)
	var holder := CenterContainer.new()
	holder.add_child(whole)
	col.add_child(holder)

	# How to fly it, on a plank so it reads over grass or sea, then gone.
	var hint := Art.label("Drag to move  ·  pinch or scroll to zoom", Pal.SMALL, Pal.CREAM)
	var pill := Ui.plank(hint, 10.0)
	pill.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	pill.grow_vertical = Control.GROW_DIRECTION_BEGIN
	pill.offset_left = 12.0
	pill.offset_bottom = -12.0
	add_child(pill)
	pill.create_tween().tween_property(pill, "modulate:a", 0.0, 0.6).set_delay(6.0)
	_update_buttons()


func _round_button(icon: String, tip: String, act: Callable) -> TextureButton:
	var b := TextureButton.new()
	# Cropped to the drawn circle: the sheets carry a wide transparent margin,
	# and the button came out half the size of its own touch target.
	b.texture_normal = Art.cell(ROUND_UP, 0, 0)
	b.texture_pressed = Art.cell(ROUND_DOWN, 0, 0)
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	b.custom_minimum_size = Vector2(BTN, BTN)
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(act)
	var glyph := Control.new()
	glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glyph.draw.connect(_draw_icon.bind(glyph, icon, b))
	b.add_child(glyph)
	# The pressed art sits lower; the symbol goes down with it.
	b.button_down.connect(func() -> void: glyph.position.y = 2.0)
	b.button_up.connect(func() -> void: glyph.position.y = 0.0)
	return b


## Chunky pixel symbols: a dark outline, cream on top, like the pack's icons.
func _draw_icon(c: Control, icon: String, b: TextureButton) -> void:
	var mid := (c.size * 0.5 - Vector2(0, 2)).round()
	var k := BTN / 44.0                       # drawn for 44, scaled to fit
	var rects: Array[Rect2] = []
	match icon:
		"plus":
			rects = [Rect2(mid.x - 8, mid.y - 2, 16, 4), Rect2(mid.x - 2, mid.y - 8, 4, 16)]
		"minus":
			rects = [Rect2(mid.x - 8, mid.y - 2, 16, 4)]
		"frame":
			# Four corners of a frame: the whole board, in view.
			for sx in [-1, 1]:
				for sy in [-1, 1]:
					var corner := mid + Vector2(sx * 10, sy * 9)
					rects.append(Rect2(corner.x - (0 if sx < 0 else 8), corner.y - (0 if sy < 0 else 2), 8, 2))
					rects.append(Rect2(corner.x - (0 if sx < 0 else 2), corner.y - (0 if sy < 0 else 7), 2, 7))
	var ink := Pal.CREAM if not b.disabled else Pal.CREAM.darkened(0.45)
	rects.assign(rects.map(func(r: Rect2) -> Rect2:
		return Rect2((mid + (r.position - mid) * k).round(), (r.size * k).round().max(Vector2(2, 2)))))
	for r in rects:
		c.draw_rect(r.grow(2), Color(0.1, 0.07, 0.1, 0.9))
	for r in rects:
		c.draw_rect(r, ink)


## + goes dim at the closest, − at the whole board.
func _update_buttons() -> void:
	if _zoom_in == null:
		return
	var z := world.scale.x
	for pair: Array in [[_zoom_in, z >= MAX_ZOOM - 0.001], [_zoom_out, z <= _min_zoom() + 0.001]]:
		var b: TextureButton = pair[0]
		if b.disabled != pair[1]:
			b.disabled = pair[1]
			b.modulate.a = 0.5 if b.disabled else 1.0
			b.queue_redraw()
			b.get_child(0).queue_redraw()

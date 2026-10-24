extends Control

## Event screen: the same seeded island, with both sides visible. No Match,
## player, keypad, input topic, relay ticket, or score-writing call is created.
var main: Control
var session_id := ""
var data := {}
var world: MapWorld
var peers: Peers
var _code := ""
var _busy := false
var _clock := 0.0
var _offset := 0.0
var _status: Label
var _time: Label
var _totals: Array[Label] = []
var _lists: Array[VBoxContainer] = []
var _map_box: SubViewportContainer
var _map_view: SubViewport
var _camera: Camera2D
var _pins: Pins
var _roster := {}


## A room's own spectator (Lobby.SPECTATE), not a visitor with the code.
var _spectator := false
## The aerial view: where it looks and how near. `_fit` shows the whole world;
## a spectator drags to move and pinches, scrolls or taps +/- to look closer.
var _center := Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE * 0.5
var _zoom := 0.0
var _fit := 0.1
const ZOOM_MAX := 5.0      # times the whole-world fit


func setup(options: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_code = Teams.clean_code(str(options.get("code", "")))
	_spectator = bool(options.get("spectator", false))
	_build_ui()
	if not Net.signed_in():
		_unavailable("Sign in to watch a match.")
		return
	if _code.length() != 4 or Teams.bad_chars(_code) != "":
		_unavailable("Enter a live room's four-character code.")
		return
	var got := await WatchFeed.enter(_code)
	if not is_inside_tree():
		return
	if got.error != "":
		_unavailable(str(got.error).capitalize())
		return
	session_id = str(got.data)
	var rt := Net.realtime()
	rt.track({"sid": session_id, "where": "watch", "name": Net.username})
	rt.open_socket()
	rt.watch_positions([Realtime.snap_topic(session_id)])
	rt.position.connect(_on_position)
	await _poll()


## Nothing to watch: the reason on a panel and a way back, instead of the
## empty match chrome around it.
func _unavailable(why: String) -> void:
	for c in get_children():
		if c is not ColorRect:
			c.visible = false
	var box := Ui.screen_panel(self, Vector2(320, 0), "Watch")
	var l := Art.label(why, Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(l)
	Ui.centre_row(box, Ui.back_button(go_back, 280))


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = MapCfg.WATER_TINT * Color("47aba9")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var bar := HBoxContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = 8
	bar.offset_right = -8
	bar.offset_top = 6
	bar.offset_bottom = 42
	bar.add_theme_constant_override("separation", 6)
	add_child(bar)
	var title := Art.label("Watch  " + _code, Pal.BODY, Pal.CREAM)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Art.shadow(title)
	bar.add_child(title)
	for i in 2:
		var l := Art.label("%s  0 + 0" % Match.TEAMS[i], Pal.SMALL, Peers.TEAM_COLOURS[i].lightened(0.3))
		l.custom_minimum_size.x = 128
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		bar.add_child(Ui.plank(l))
		_totals.append(l)
	_time = Art.label("--:--", Pal.SMALL, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	_time.custom_minimum_size.x = 48
	_time.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(Ui.plank(_time))
	var back := Ui.button("Leave", 70, Ui.H, Ui.SMALL)
	back.pressed.connect(go_back)
	bar.add_child(back)
	_status = Art.label("Opening live match…", Pal.SMALL, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	_status.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_status.offset_top = 43
	_status.offset_bottom = 64
	_status.clip_text = true
	Art.shadow(_status)
	add_child(_status)
	_map_box = SubViewportContainer.new()
	_map_box.stretch = true
	_map_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_box.offset_left = 8
	_map_box.offset_right = -8
	_map_box.offset_top = 68
	_map_box.offset_bottom = -103
	add_child(_map_box)
	_map_view = SubViewport.new()
	_map_view.disable_3d = true
	_map_view.transparent_bg = true
	_map_view.handle_input_locally = false
	_map_box.add_child(_map_view)
	_pins = Pins.new()
	_pins.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_pins)
	var bottom := HBoxContainer.new()
	bottom.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_left = 12
	bottom.offset_right = -12
	bottom.offset_top = -99
	bottom.offset_bottom = -25
	bottom.add_theme_constant_override("separation", 8)
	add_child(bottom)
	for i in 2:
		var paper := PanelContainer.new()
		paper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		paper.add_theme_stylebox_override("panel", Ui._paper_box(false))
		bottom.add_child(paper)
		var scroll := ScrollContainer.new()
		Ui.style_scroll(scroll)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		paper.add_child(scroll)
		DragScroll.attach(scroll)
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 0)
		scroll.add_child(list)
		_lists.append(list)
	var legend := Art.label("Monks: Blue left / Red right · ring = carried · solid = deposited",
		Pal.TINY, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	legend.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	legend.offset_left = 40
	legend.offset_right = -8
	legend.offset_top = -23
	legend.offset_bottom = -3
	Art.shadow(legend)
	add_child(legend)
	resized.connect(_frame_map)
	_map_box.gui_input.connect(_on_map_input)
	# Touch has no wheel: + and - over the map's corner.
	var zoom_row := HBoxContainer.new()
	zoom_row.add_theme_constant_override("separation", 4)
	zoom_row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	zoom_row.offset_left = -92
	zoom_row.offset_right = -14
	zoom_row.offset_top = -141
	zoom_row.offset_bottom = -107
	for step: Array in [["−", 1.0 / 1.4], ["+", 1.4]]:
		var b := Ui.button(step[0], 36, Ui.H, Ui.SMALL)
		b.add_theme_font_size_override("font_size", 20)
		b.pressed.connect(func() -> void: _look(_center, _zoom * float(step[1])))
		zoom_row.add_child(b)
	add_child(zoom_row)


func _process(delta: float) -> void:
	if session_id == "":
		return
	_clock -= delta
	if _clock <= 0 and not _busy:
		_poll()
	if not data.is_empty():
		_update_clock()
		_pins.queue_redraw()


func _poll() -> void:
	if _busy:
		return
	_busy = true
	_clock = 2.0
	var got := await WatchFeed.snapshot(session_id)
	if not is_inside_tree():
		return
	_busy = false
	if got.error != "":
		_status.text = "Reconnecting… " + str(got.error)
		# A long network outage lets the lease expire. Register again by code.
		if str(got.error).contains("watch expired"):
			var renewed := await WatchFeed.enter(_code)
			if is_inside_tree() and renewed.error == "":
				session_id = str(renewed.data)
		return
	_apply(got.data if got.data is Dictionary else {})


func _apply(snapshot: Dictionary) -> void:
	data = snapshot
	var session: Dictionary = data.get("session", {})
	_offset = WatchFeed.stamp(str(session.get("server_now", ""))) - Time.get_unix_time_from_system()
	if world == null:
		world = MapWorld.new()
		world.seed = Game.seed_of(str(session.get("id", session_id)))
		world.monk_count = int(data.get("monks", 10))
		_map_view.add_child(world)
		world.build()
		_camera = Camera2D.new()
		_camera.position = Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE * 0.5
		world.add_child(_camera)
		peers = Peers.new()
		world.add_child(peers)
		_frame_map()
	var teams: Array = data.get("teams", [])
	var ids: Array = []
	for t: Dictionary in teams:
		ids.append(str(t.id))
	peers.set_team_order(ids)
	_roster.clear()
	var players: Array = data.get("players", [])
	for row: Dictionary in players:
		_roster[str(row.profile_id)] = row
	peers.refresh(players, [], world.door(), "")
	for i in 2:
		for c in _lists[i].get_children():
			_lists[i].remove_child(c)
			c.queue_free()
		if i >= teams.size():
			continue
		var t: Dictionary = teams[i]
		_totals[i].text = "%s %d · carry %d" % [t.name, int(t.deposited), int(t.carried)]
		for p: Dictionary in players:
			if str(p.get("team_id", "")) != str(t.id):
				continue
			var label := Art.label("%s  ·  carry %d  ·  deposited %d" % [p.username, int(p.carried), int(p.deposited)],
				Pal.SMALL, Peers.TEAM_COLOURS[i].darkened(0.4))
			label.clip_text = true
			label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			_lists[i].add_child(label)
	_pins.world = world
	_pins.peers = peers
	_pins.snapshot = data
	_update_clock()


func _frame_map() -> void:
	if world == null:
		return
	var area := _map_box.size
	_fit = minf(area.x / float(MapCfg.WORLD_W * MapCfg.TILE), area.y / float(MapCfg.WORLD_H * MapCfg.TILE))
	_pins.position = _map_box.position
	_pins.size = area
	_look(_center, _zoom if _zoom > 0.0 else _fit)


## Drag to move the view; wheel or pinch to zoom.
func _on_map_input(e: InputEvent) -> void:
	if world == null:
		return
	if e is InputEventScreenDrag or (e is InputEventMouseMotion
			and (e as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT):
		_look(_center - e.relative / _zoom, _zoom)
	elif e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
		var button := (e as InputEventMouseButton).button_index
		if button == MOUSE_BUTTON_WHEEL_UP:
			_look(_center, _zoom * 1.15)
		elif button == MOUSE_BUTTON_WHEEL_DOWN:
			_look(_center, _zoom / 1.15)
	elif e is InputEventMagnifyGesture:
		_look(_center, _zoom * (e as InputEventMagnifyGesture).factor)


## Point the aerial view, kept on the world and between whole-world and close.
func _look(center: Vector2, zoom: float) -> void:
	if world == null:
		return
	_zoom = clampf(zoom, _fit, _fit * ZOOM_MAX)
	var world_px := Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE
	var half := _map_box.size / _zoom / 2.0
	_center = Vector2(clampf(center.x, minf(half.x, world_px.x / 2.0), maxf(world_px.x - half.x, world_px.x / 2.0)),
			clampf(center.y, minf(half.y, world_px.y / 2.0), maxf(world_px.y - half.y, world_px.y / 2.0)))
	_camera.zoom = Vector2(_zoom, _zoom)
	_camera.position = _center
	_pins.zoom = _zoom
	_pins.center = _center
	_pins.queue_redraw()


func _update_clock() -> void:
	var session: Dictionary = data.get("session", {})
	var sec := WatchFeed.time_left(session, Time.get_unix_time_from_system() + _offset)
	_time.text = "Final" if str(session.get("state", "")) == "ended" else Ui.mmss(sec)
	if str(session.get("state", "")) == "lobby":
		_status.text = "Waiting for the host to start · scores count deposited words"
	elif str(session.get("state", "")) == "ended" or sec == 0:
		_status.text = WatchFeed.outcome(data)
	else:
		_status.text = "Live · scores count deposited words"


func _on_position(event: String, snapshot: Dictionary) -> void:
	if event != "snap" or str(snapshot.get("sid", "")) != session_id or peers == null:
		return
	for p: Dictionary in snapshot.get("p", []):
		if _roster.has(str(p.get("id", ""))):
			peers.move(str(p.id), p)


func _exit_tree() -> void:
	if session_id == "":
		return
	var rt := Net.realtime()
	if rt.position.is_connected(_on_position):
		rt.position.disconnect(_on_position)
	if rt.get("_tracked").get("where") == "watch" and rt.get("_tracked").get("sid") == session_id:
		rt.untrack()
		rt.watch_positions([])
	WatchFeed.leave(session_id)


## A visitor goes back to the code form. A room's spectator goes Home and
## forgets the room -- the room screen would only send them back here; the
## code and Watch bring them back while it runs.
func go_back() -> void:
	if _spectator:
		Game.joined_code = ""
		Game.joined_session = ""
		Game.save_profile()
		main.open("home")
		return
	main.open("room")


## Fixed-size aerial pins stay legible while the actual world is zoomed out.
## Each monk has two halves: independent state for Blue and for Red.
class Pins extends Control:
	var world: MapWorld
	var peers: Peers
	var snapshot := {}
	var zoom := 0.1
	var center := Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE * 0.5
	func _at(point: Vector2) -> Vector2:
		return size * 0.5 + (point - center) * zoom
	func _draw() -> void:
		if world == null:
			return
		var teams: Array = snapshot.get("teams", [])
		# Zoomed in, what is off the view is skipped, not drawn over the page.
		var view := Rect2(Vector2.ZERO, size).grow(-2)
		for i in world.monks.size():
			var at := _at(world.monks[i].position)
			if not view.has_point(at):
				continue
			for side in mini(2, teams.size()):
				var pos := at + Vector2(-4 if side == 0 else 4, -5)
				var state := WatchFeed.monk_state(snapshot, str(teams[side].id), i)
				draw_circle(pos, 4, Pal.SHADOW)
				var col: Color = Peers.TEAM_COLOURS[side]
				if state == 2:
					draw_circle(pos, 3, col)
				else:
					draw_arc(pos, 3, 0, TAU, 16, col if state == 1 else Pal.WHITE_DIM, 1.3)
			var font := ThemeDB.fallback_font
			draw_string(font, at + Vector2(-3, 12), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Pal.CREAM)
		if peers != null:
			for id: String in peers.get("_markers"):
				var marker: Node2D = peers.get("_markers")[id]
				# Unknown / stale positions aren't fabricated at the Monastery.
				marker.visible = peers._is_live(id)
				if marker.visible and view.has_point(_at(marker.position)):
					var at := _at(marker.position)
					var row: Dictionary = peers.get("_roster").get(id, {})
					draw_circle(at, 4, Pal.SHADOW)
					draw_circle(at, 2.8, peers.colour_of(str(row.get("team_id", ""))))

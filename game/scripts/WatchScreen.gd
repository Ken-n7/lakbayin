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
var _stats: PanelContainer   # the players' lists and the legend, behind Stats
var _heads: Array[Label] = []  # each side's name and totals, over its list
## When the delayed feed reaches the start (local clock), while it has not.
var _starts_at := 0.0
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
	var box := Ui.back_panel(self, Vector2(320, 0), "Watch", go_back)
	var l := Art.label(why, Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(l)


## A MOBA-style spectator view: the aerial map fills the screen and the UI
## floats over it -- scores and clock on top, zoom in the corner. Who carries
## and has deposited what sits behind a Stats button, not under the map.
func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = MapCfg.WATER_TINT * Color("47aba9")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_map_box = SubViewportContainer.new()
	_map_box.stretch = true
	_map_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_map_box)
	_map_view = SubViewport.new()
	_map_view.disable_3d = true
	_map_view.transparent_bg = true
	_map_view.handle_input_locally = false
	_map_box.add_child(_map_view)
	_pins = Pins.new()
	_pins.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_pins)

	var bar := HBoxContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = 8
	bar.offset_right = -8
	bar.offset_top = 6
	bar.offset_bottom = 42
	bar.add_theme_constant_override("separation", 6)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)
	var title := Art.label("Watch  " + _code, Pal.BODY, Pal.CREAM)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Art.shadow(title)
	bar.add_child(title)
	for i in 2:
		var l := Art.label("%s  0 + 0" % Match.TEAMS[i], Pal.SMALL, Peers.TEAM_COLOURS[i].lightened(0.3))
		l.custom_minimum_size.x = 100
		l.clip_text = true
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		bar.add_child(Ui.plank(l))
		_totals.append(l)
	_time = Art.label("--:--", Pal.SMALL, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	_time.custom_minimum_size.x = 48
	_time.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(Ui.plank(_time))
	var stats := Ui.button("Stats", 58, Ui.H, Ui.SMALL)
	stats.pressed.connect(func() -> void: _stats.visible = not _stats.visible)
	bar.add_child(stats)
	# Leave as the arrow alone: the bar is the whole width of a phone.
	var back := Ui.button("", 38, Ui.H, Ui.SMALL)
	back.icon = Ui.icon("back")
	back.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	back.tooltip_text = "Leave"
	back.pressed.connect(go_back)
	bar.add_child(back)
	_status = Art.label("Opening live match…", Pal.SMALL, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	_status.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_status.offset_top = 43
	_status.offset_bottom = 64
	_status.clip_text = true
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Art.shadow(_status)
	add_child(_status)

	# Stats: centred over the map, Blue on the left and Red on the right, on a
	# dark see-through plate -- the match still shows behind, the text reads.
	_stats = PanelContainer.new()
	var plate := StyleBoxFlat.new()
	plate.bg_color = Color(0.06, 0.05, 0.09, 0.72)
	plate.border_color = Color(Pal.CREAM, 0.35)
	plate.set_border_width_all(1)
	plate.set_corner_radius_all(6)
	plate.set_content_margin_all(10)
	_stats.add_theme_stylebox_override("panel", plate)
	_stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats.visible = false
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.offset_top = 44
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	centre.add_child(_stats)
	var inside := VBoxContainer.new()
	inside.add_theme_constant_override("separation", 6)
	_stats.add_child(inside)
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 0)
	inside.add_child(columns)
	for i in 2:
		if i == 1:
			var line := ColorRect.new()          # the split between the sides
			line.color = Color(Pal.CREAM, 0.25)
			line.custom_minimum_size = Vector2(1, 0)
			columns.add_child(line)
		var side := VBoxContainer.new()
		side.custom_minimum_size = Vector2(230, 0)
		side.add_theme_constant_override("separation", 2)
		columns.add_child(side)
		var head := Art.title(Art.label(Match.TEAMS[i], Pal.H2, Peers.TEAM_COLOURS[i].lightened(0.35),
			HORIZONTAL_ALIGNMENT_CENTER))
		Art.shadow(head)
		side.add_child(head)
		_heads.append(head)
		var list := VBoxContainer.new()
		list.add_theme_constant_override("separation", 1)
		side.add_child(list)
		_lists.append(list)
	var legend := Art.label("Each monk: Blue's mark left, Red's right · ring = carried · solid = deposited",
		Pal.TINY, Color(Pal.CREAM, 0.8), HORIZONTAL_ALIGNMENT_CENTER)
	inside.add_child(legend)

	resized.connect(_frame_map)
	_map_box.gui_input.connect(_on_map_input)


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
		_heads[i].text = "%s  ·  %d deposited  ·  %d carried" % [t.name, int(t.deposited), int(t.carried)]
		for p: Dictionary in players:
			if str(p.get("team_id", "")) != str(t.id):
				continue
			var label := Art.label("%s  ·  carry %d  ·  deposited %d" % [p.username, int(p.carried), int(p.deposited)],
				Pal.SMALL, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
			label.clip_text = true
			label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			_lists[i].add_child(label)
	_pins.world = world
	_pins.peers = peers
	_pins.snapshot = data
	_starts_at = Time.get_unix_time_from_system() + float(data.get("starts_in", 0))
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
	var delay := int(data.get("delay_s", 0))
	if str(session.get("state", "")) == "lobby" and data.has("starts_in"):
		_status.text = "Spectator delay %ds · the match starts here in %ds" % [delay,
			maxi(0, ceili(_starts_at - Time.get_unix_time_from_system()))]
	elif str(session.get("state", "")) == "lobby":
		_status.text = "Waiting for the host to start · scores count deposited words"
	elif str(session.get("state", "")) == "ended" or sec == 0:
		_status.text = WatchFeed.outcome(data)
	else:
		_status.text = ("%ds behind live · scores count deposited words" % delay if delay > 0
			else "Live · scores count deposited words")


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
	## A hero stands 32 world px (a 20px frame x 1.6); drawn x zoom, but
	## never under HERO_MIN_H canvas px.
	const HERO_WORLD_H := 32.0
	const HERO_MIN_H := 16.0
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
			var font := get_theme_default_font()
			for id: String in peers.get("_markers"):
				var marker: Node2D = peers.get("_markers")[id]
				# The world's own hero is hidden and drawn here instead, so it
				# keeps a readable size zoomed out (and its name stays legible).
				marker.visible = false
				# Unknown / stale positions aren't fabricated at the Monastery.
				if not peers._is_live(id) or not view.has_point(_at(marker.position)):
					continue
				var at := _at(marker.position)
				var row: Dictionary = peers.get("_roster").get(id, {})
				var col: Color = peers.colour_of(str(row.get("team_id", "")))
				# The player's own hero, at the map's scale like a MOBA camera --
				# real size zoomed all the way in, never smaller than HERO_MIN_H
				# zoomed out -- on a small ring in the team's colour.
				var h := maxf(HERO_WORLD_H * zoom, HERO_MIN_H)
				draw_set_transform(at, 0.0, Vector2(1.0, 0.45))
				draw_circle(Vector2.ZERO, h * 0.32, Color(col, 0.5))
				draw_arc(Vector2.ZERO, h * 0.32, 0.0, TAU, 20, col, 1.5)
				draw_set_transform(Vector2.ZERO)
				var spr: AnimatedSprite2D = marker.get_node("Spr")
				if spr.sprite_frames != null and spr.sprite_frames.has_animation(spr.animation):
					var tex := spr.sprite_frames.get_frame_texture(spr.animation, spr.frame)
					var sz := tex.get_size() * (h / tex.get_size().y)
					var r := Rect2(at - Vector2(sz.x * 0.5, sz.y - 1.0), sz)
					if spr.flip_h:
						r = Rect2(r.position + Vector2(r.size.x, 0), Vector2(-r.size.x, r.size.y))
					draw_texture_rect(tex, r, false)
				# ...and the name over its head, in the team's colour.
				var name := str(row.get("username", ""))
				var w := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
				var at_name := at + Vector2(-w * 0.5, -h - 3.0)
				draw_string_outline(font, at_name, name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 4, Color(0, 0, 0, 0.75))
				draw_string(font, at_name, name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col.lightened(0.45))

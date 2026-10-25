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
var _lists: Array[GridContainer] = []   # each side's Player / Carry / Deposited table
var _camera: Camera2D
## The scores, Stats and the drag surface, on a layer of their own: the
## camera moves the world, not them.
var _ui: CanvasLayer
var _pad: Control
var _roster := {}


## A room's own spectator (Lobby.SPECTATE), not a visitor with the code.
var _spectator := false
var _stats: PanelContainer   # the players' lists and the legend, behind Stats
var _heads: Array[Label] = []  # each side's totals, under its name
const STATS_SIDE_W := 286.0
const STATS_HEAD_H := 64.0     # a side's name and totals
const STATS_ROW_H := 30.0
## When the delayed feed reaches the start (local clock), while it has not.
var _starts_at := 0.0
## The aerial view: the match's own (AdventureScreen's start and end), the
## island drawn straight on the screen by a camera, at the phone's own
## resolution. Where it looks and how near: `_fit` shows the whole world; a
## spectator drags to move and pinches or scrolls to look closer.
var _center := Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE * 0.5
var _zoom := 0.0
var _fit := 0.1
const ZOOM_MAX := 5.0      # times the whole-world fit
## Zoomed out, a hero is kept at least this tall and a name this big (layout
## px): at the whole-island view they would be specks.
const HERO_MIN_H := 16.0
const HERO_WORLD_H := 32.0
const TAG_MIN_PX := 10.0


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
	var sea := CanvasLayer.new()
	sea.layer = -1
	add_child(sea)
	var bg := ColorRect.new()
	bg.color = MapCfg.WATER_TINT * Color("47aba9")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sea.add_child(bg)
	_ui = CanvasLayer.new()
	_ui.layer = 2
	add_child(_ui)
	_pad = Control.new()
	_pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui.add_child(_pad)

	var bar := HBoxContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = 8
	bar.offset_right = -8
	bar.offset_top = 6
	bar.offset_bottom = 42
	bar.add_theme_constant_override("separation", 6)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(bar)
	var title := Art.label("Watch  " + _code, Pal.BODY, Pal.CREAM)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Art.shadow(title)
	bar.add_child(title)
	for i in 2:
		# The score alone, as a MOBA's top bar: carried counts are in Stats.
		var l := Art.label("%s  0" % Match.NAMES[i], Pal.SMALL, Peers.TEAM_COLOURS[i].lightened(0.3))
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
	_ui.add_child(_status)

	# Stats: centred over the map, Blue on the left and Red on the right, on a
	# dark see-through plate -- the match still shows behind, the text reads.
	_stats = PanelContainer.new()
	var plate := StyleBoxFlat.new()
	plate.bg_color = Color(0.06, 0.05, 0.09, 0.72)
	plate.border_color = Color(Pal.CREAM, 0.35)
	plate.set_border_width_all(1)
	plate.set_corner_radius_all(6)
	plate.set_content_margin_all(18)
	_stats.add_theme_stylebox_override("panel", plate)
	_stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats.visible = false
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.offset_top = 44
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(centre)
	centre.add_child(_stats)
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 0)
	_stats.add_child(columns)
	for i in 2:
		if i == 1:
			var line := ColorRect.new()          # the split between the sides
			line.color = Color(Pal.CREAM, 0.25)
			line.custom_minimum_size = Vector2(1, 0)
			columns.add_child(line)
		var side := VBoxContainer.new()
		side.custom_minimum_size = Vector2(STATS_SIDE_W, 0)
		side.add_theme_constant_override("separation", 4)
		columns.add_child(side)
		var head := Art.title(Art.label(Match.NAMES[i], Pal.H1, Peers.TEAM_COLOURS[i].lightened(0.35),
			HORIZONTAL_ALIGNMENT_CENTER))
		Art.shadow(head)
		side.add_child(head)
		var totals := Art.label("", Pal.SMALL, Color(Pal.CREAM, 0.85), HORIZONTAL_ALIGNMENT_CENTER)
		side.add_child(totals)
		_heads.append(totals)
		# Player, carried, deposited: a table, so the numbers line up.
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 6)
		var pad := MarginContainer.new()
		pad.add_theme_constant_override("margin_left", 14)
		pad.add_theme_constant_override("margin_right", 14)
		pad.add_theme_constant_override("margin_top", 6)
		pad.add_child(grid)
		side.add_child(pad)
		_lists.append(grid)

	resized.connect(_frame_map)
	_pad.gui_input.connect(_on_map_input)


func _process(delta: float) -> void:
	if session_id == "":
		return
	_clock -= delta
	if _clock <= 0 and not _busy:
		_poll()
	if not data.is_empty():
		_update_clock()
	_keep_legible()


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
		add_child(world)
		world.build()
		_camera = Camera2D.new()
		_camera.position = Vector2(MapCfg.WORLD_W, MapCfg.WORLD_H) * MapCfg.TILE * 0.5
		world.add_child(_camera)
		_camera.make_current()
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
		_totals[i].text = "%s  %d" % [t.name, int(t.deposited)]
		_heads[i].text = "%d deposited  ·  %d carried" % [int(t.deposited), int(t.carried)]
		for h: String in ["Player", "Carry", "Deposited"]:
			_lists[i].add_child(_cell(h, Color(Pal.CREAM, 0.6), h == "Player", Pal.SMALL))
		for p: Dictionary in players:
			if str(p.get("team_id", "")) != str(t.id):
				continue
			_lists[i].add_child(_cell(str(p.username), Pal.CREAM, true))
			_lists[i].add_child(_cell(str(int(p.carried)), Pal.CREAM, false))
			_lists[i].add_child(_cell(str(int(p.deposited)), Pal.CREAM, false))
	# One size for the match: as tall as the bigger side needs, so the board
	# does not jump about, and never cramped.
	var most := 1
	for i in teams.size():
		most = maxi(most, players.filter(func(p: Dictionary) -> bool:
			return str(p.get("team_id", "")) == str(teams[i].id)).size())
	_stats.custom_minimum_size = Vector2(STATS_SIDE_W * 2 + 1, STATS_HEAD_H + STATS_ROW_H * (most + 1)) \
		+ Vector2(36, 36)
	# A monk in the colour of the team that answered him first, as a match
	# shows its own team's: who got there is the race. Both sides' counts
	# are in Stats.
	for i in world.monks.size():
		for a: Dictionary in data.get("answers", []):
			if int(a.get("monk", -1)) == i:
				var side := ids.find(str(a.get("team_id", "")))
				if side >= 0:
					world.monks[i].take(Match.TEAMS[side])
				break
	_starts_at = Time.get_unix_time_from_system() + float(data.get("starts_in", 0))
	_update_clock()


## One cell of a side's table: the name left, the numbers centred.
func _cell(text: String, colour: Color, name: bool, size := Pal.BODY) -> Label:
	var l := Art.label(text, size, colour,
		HORIZONTAL_ALIGNMENT_LEFT if name else HORIZONTAL_ALIGNMENT_CENTER)
	l.custom_minimum_size = Vector2(110 if name else 64, STATS_ROW_H - 6)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


func _frame_map() -> void:
	if world == null:
		return
	_fit = minf(size.x / float(MapCfg.WORLD_W * MapCfg.TILE), size.y / float(MapCfg.WORLD_H * MapCfg.TILE))
	_look(_center, _zoom if _zoom > 0.0 else _fit)


## Heroes at the map's scale, like the match's own -- but never smaller than
## HERO_MIN_H zoomed out, their names never under TAG_MIN_PX.
func _keep_legible() -> void:
	if peers == null or _zoom <= 0.0:
		return
	var hero := maxf(1.0, HERO_MIN_H / (HERO_WORLD_H * _zoom))
	var markers: Dictionary = peers.get("_markers")
	for id: String in markers:
		var marker: Node2D = markers[id]
		# No position yet, or a stale one: not guessed at the Monastery.
		marker.visible = peers._is_live(id)
		marker.scale = Vector2(hero, hero)
		var tag := marker.get_node_or_null("Tag") as Control
		if tag != null:
			var k := maxf(1.0, TAG_MIN_PX / (11.0 * _zoom * hero))
			tag.pivot_offset = tag.size * Vector2(0.5, 1.0)
			tag.scale = Vector2(k, k)


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
	var half := size / _zoom / 2.0
	_center = Vector2(clampf(center.x, minf(half.x, world_px.x / 2.0), maxf(world_px.x - half.x, world_px.x / 2.0)),
			clampf(center.y, minf(half.y, world_px.y / 2.0), maxf(world_px.y - half.y, world_px.y / 2.0)))
	_camera.zoom = Vector2(_zoom, _zoom)
	_camera.position = _center
	_keep_legible()


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

extends Node

## Footage for the trailer and the gameplay video: real matches on a local
## server, played by scripted players, the hero's (or the spectator's) view
## recorded as it happens (Recorder). Driven by tools/showcase.py:
##
##   godot --path game res://tools/showcase.tscn -- --player=N --role=R --out=DIR
##
## Roles: "hero" plays a matchmade game on the phone layout, by taps and the
## stick, and is recorded from Home to the Records; "bot" plays the same way
## unseen (headless); "watch" makes a custom room, spectates it and is
## recorded. SHOW_SCENARIO=match|room. LAKBAYIN_TEST_INFO names the accounts.

var index := 0
var role := "bot"
var out := "user://"
var vp: SubViewport
var main: Control
var rec: Recorder
var taps: Taps
var spellings := {}


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 60
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--player="):
			index = int(arg.trim_prefix("--player="))
		elif arg.begins_with("--role="):
			role = arg.trim_prefix("--role=")
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	for w: Dictionary in JSON.parse_string(FileAccess.get_file_as_string("res://data/words.json")):
		spellings[w.word] = str(w.modern)
	var info: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
			OS.get_environment("LAKBAYIN_TEST_INFO")))
	var account: Dictionary = info.accounts[index]
	var err := await Net.sign_in(account.username, account.password)
	if err != "":
		push_error(err)
		get_tree().quit(1)
		return
	Game.guide_seen = true
	Game.hero_id = int(account.hero)
	Game.touch = role == "hero"
	vp = SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.size_2d_override = Vector2i(640, 360)
	vp.size_2d_override_stretch = true
	# The project's Nearest filter is the root window's; a view of its own
	# smooths the pixel art unless told.
	vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if role != "bot" else SubViewport.UPDATE_DISABLED
	add_child(vp)
	main = load("res://scenes/Main.tscn").instantiate()
	vp.add_child(main)
	taps = Taps.new()
	var layer := CanvasLayer.new()
	layer.layer = 120
	vp.add_child(layer)
	layer.add_child(taps)
	await _wait(1.0)
	main.open("home")
	await _wait(1.0)
	if main.dev_panel != null and is_instance_valid(main.dev_panel):
		main.dev_panel.get_parent().queue_free()
	print("player %d role %s ready" % [index, role])
	match [OS.get_environment("SHOW_SCENARIO"), role]:
		["match", "hero"]:
			await _hero_match()
		["room", "watch"]:
			await _watch_room()
		["room", _]:
			await _join_room()
		_:
			await _bot_match()
	if rec != null:
		rec.stop()
	Net.realtime().close_socket()
	get_tree().quit(0)


func _mark(name: String) -> void:
	if rec != null:
		rec.mark(name)


func _record(name: String) -> void:
	rec = Recorder.new()
	add_child(rec)
	rec.start(vp, out.path_join(name))


# --- The hero: Home, How to Play, a matchmade game, the Records ------------------
func _hero_match() -> void:
	_record("hero")
	_mark("home")
	if OS.get_environment("SHOW_QUICK") == "":
		await _guide()
	_mark("find")
	await tap(_button("Find Match"))
	await _wait(3.0)
	_mark("lock_in")
	await tap(_button("Lock In"))
	await _wait(2.0)
	_mark("queue")
	await tap(_button("Find Match"))
	FileAccess.open(out.path_join("queue"), FileAccess.WRITE).store_string("go")
	await _play_match()


## Settings, then How to Play page by page, its keys tapped.
func _guide() -> void:
	await _wait(3.0)
	await tap(_button("Settings"))
	await _wait(1.6)
	_mark("guide")
	await tap(_button("How to Play"))
	await _wait(4.5)
	_mark("guide_2")
	await tap(_button("Next"))                     # 2: the letters
	await _wait(1.5)
	var pad := _keypad(main)
	for g in ["ᜊ", "ᜃ", "ᜎ", "ᜐ"]:
		await tap(HowToPlay._key_of(pad, g))
		await _wait(0.9)
	await _wait(1.0)
	_mark("guide_3")
	await tap(_button("Next"))                     # 3: the marks
	await _wait(9.0)
	_mark("guide_4")
	await tap(_button("Next"))                     # 4: a word built
	await _wait(8.0)
	_mark("guide_5")
	await tap(_button("Next"))                     # 5: your turn
	await _wait(2.0)
	for word in ["ᜀᜐᜓ", "ᜁᜊᜓᜈ᜔"]:
		await _type(_keypad(main), word, 0.55)
		await _wait(2.6)
	_mark("guide_6")
	await tap(_button("Next"))                     # 6: the match
	await _wait(5.0)
	_mark("guide_7")
	await tap(_button("Next"))                     # 7: the team
	await _wait(5.0)
	_mark("guide_end")
	await tap(_button("Let's Go"))
	await _wait(1.2)
	await tap(_button("Settings", true))           # the panel's back arrow is its title row
	if _button("How to Play") != null:
		main.open("home")
	await _wait(1.5)


func _play_match() -> void:
	var screen := await _until_screen("AdventureScreen.gd", 120.0)
	if screen == null:
		push_error("no match")
		return
	_mark("match")
	await _wait(2.5)
	_mark("swoop")
	await tap_at(Vector2(420, 220))                 # tap to start: the swoop
	await _wait(3.0)
	_mark("play")
	await _play(screen, true)
	var results := await _until_screen("ResultsScreen.gd", 60.0)
	_mark("results")
	if results == null:
		return
	await _wait(6.0)
	_mark("words")
	await tap(_button("Words"))
	await _wait(6.0)
	await tap(_button("Scoreboard"))
	await _wait(2.0)
	_mark("records")
	await tap(_button("My Matches"))
	await _wait(5.0)
	_mark("board")
	main.open("records", {"tab": "player_board"})
	await _wait(5.0)
	_mark("home_end")
	main.open("home")
	await _wait(3.0)


# --- Everyone else ---------------------------------------------------------------
func _bot_match() -> void:
	print("bot %d waiting" % index)
	await _until_file("queue", 600.0)
	print("bot %d queues" % index)
	# One by one, as a lobby fills.
	await _wait(2.5 + index * 2.2)
	main.open("team")
	await _wait(0.5)
	main.current.call("_find")
	var screen := await _until_screen("AdventureScreen.gd", 120.0)
	print("bot %d in match: %s" % [index, screen != null])
	if screen == null:
		return
	await _wait(5.5)
	screen.call("skip_intro")
	await _play(screen, false)
	await _until_screen("ResultsScreen.gd", 60.0)
	await _wait(3.0)


## A spectator's room: made, filled, started, then watched the way a caster
## would -- the whole island, then close on one player after another.
func _watch_room() -> void:
	_record("watch")
	await _wait(1.5)
	_mark("home")
	await tap(_button("Custom Room"))
	await _wait(1.5)
	_mark("create")
	await tap(_button("Create Room"))
	await _until(func() -> bool: return str(main.current.get("_session").get("code", "")) != "", 20.0)
	FileAccess.open(out.path_join("room_code.txt"), FileAccess.WRITE).store_string(
			str(main.current.get("_session").get("code", "")))
	await _wait(2.0)
	_mark("spectate")
	main.current.call("_pick", Lobby.SPECTATE)
	var want := int(OS.get_environment("SHOW_PLAYERS"))
	await _until(func() -> bool:
		var l: Lobby = main.current.get("_lobby")
		return l.members_of(l.teams[0].id).size() + l.members_of(l.teams[1].id).size() >= want, 120.0)
	_mark("full")
	await _wait(3.0)
	_mark("start")
	await tap(_button("Start"))
	var watch := await _until_screen("WatchScreen.gd", 30.0)
	if watch == null:
		return
	_mark("watch")
	await _wait(8.0)
	var fit: float = watch.get("_fit")
	var pe: Node = watch.get("peers")
	var shots := 0
	var quiet := 0
	while main.current == watch and shots < 16 and quiet < 4:
		var ids: Array = (pe.get("_markers") as Dictionary).keys().filter(func(id: String) -> bool: return pe._is_live(id))
		if ids.is_empty():
			# Nobody left on the island: the match is over.
			quiet += 1
			await _wait(1.0)
			continue
		quiet = 0
		var id: String = ids[shots % ids.size()]
		shots += 1
		# Ease in on the player, follow, ease back out now and then.
		var t := 0.0
		var from: Vector2 = watch.get("_center")
		var z0: float = watch.get("_zoom")
		var z1 := fit * (3.2 if shots % 3 else 2.2)
		_mark("follow")
		while t < 9.0 and main.current == watch and (pe.get("_markers") as Dictionary).has(id):
			var at: Vector2 = pe.get("_markers")[id].position
			var k := smoothstep(0.0, 1.6, t)
			watch.call("_look", from.lerp(at, k), lerpf(z0, z1, k))
			await get_tree().process_frame
			t += get_process_delta_time()
		if shots % 4 == 0 and main.current == watch:
			_mark("stats")
			(watch.get("_stats") as Control).visible = true
			await _wait(5.0)
			if main.current == watch:
				(watch.get("_stats") as Control).visible = false
	_mark("watch_end")
	await _wait(3.0)


func _join_room() -> void:
	await _until_file("room_code.txt", 120.0)
	await _wait(2.0 + index * 1.6)
	main.open("room")
	await _wait(1.0)
	main.current.get("_code").text = FileAccess.get_file_as_string(out.path_join("room_code.txt"))
	main.current.call("_enter")
	await _until(func() -> bool: return main.current.get("_lobby").teams.size() == 2, 20.0)
	await _wait(1.0)
	main.current.call("_pick", main.current.get("_lobby").teams[(index - 1) % 2].id)
	var screen := await _until_screen("AdventureScreen.gd", 180.0)
	if screen == null:
		return
	await _wait(5.5)
	screen.call("skip_intro")
	await _play(screen, false)
	await _until_screen("ResultsScreen.gd", 60.0)
	await _wait(3.0)


# --- Playing -----------------------------------------------------------------------
## Until the match ends: walk to a monk this team still needs, write its word,
## and carry what is held to the Monastery. Teammates share the island by
## thirds (west to east) and help each other once their own third is done.
## The hero gets one word wrong once, to show the lockout.
func _play(screen: Control, hero: bool) -> void:
	var team: int = screen.play.team
	var slot: int = index / 2 if OS.get_environment("SHOW_SCENARIO") == "match" else (index - 1) / 2
	var size := 3
	var order: Array = range(screen.world.monks.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		return screen.world.monks[a].position.x < screen.world.monks[b].position.x)
	var mine: Array = order.slice(slot * order.size() / size, (slot + 1) * order.size() / size)
	# Pula slower, so a game ends the way the video tells it.
	var think := 0.6 if hero else (3.0 if team == 0 else 9.0)
	var keys := 0.5 if hero else (0.35 if team == 0 else 0.9)
	var wrong_once := hero
	var answered := 0
	while _live(screen):
		var todo: Array = order.filter(func(i: int) -> bool: return not screen.play.ours(i))
		var carried: int = screen.play.carried().size()
		if todo.is_empty() and carried == 0:
			await _wait(1.0)
			continue
		var pick := -1
		for i: int in todo:
			if i in mine and (pick < 0 or _d(screen, i) < _d(screen, pick)):
				pick = i
		if pick < 0 and not todo.is_empty() and carried == 0:
			pick = todo[0]
			for i: int in todo:
				if _d(screen, i) < _d(screen, pick):
					pick = i
		if carried >= 2 or (carried > 0 and (pick < 0 or _d(screen, pick) > screen.world.door().distance_to(screen.player.position) * 1.5)):
			_mark("walk_door")
			await _walk(screen, screen.world.door(), hero)
			if not _live(screen):
				return
			_mark("deposit")
			await _go(screen, hero)
			await _wait(2.0 if hero else 1.0)
			continue
		if pick < 0:
			await _wait(1.0)
			continue
		await _wait(think * randf_range(0.6, 1.4))
		_mark("walk_monk")
		await _walk(screen, screen.world.monks[pick].position + Vector2(0, 26), hero)
		if not _live(screen) or screen.play.ours(pick):
			continue
		_mark("monk")
		await _go(screen, hero)
		await _wait(1.2)
		var pad := _keypad(screen)
		if pad == null:
			continue
		var word: String = spellings.get(screen.play.words[pick].word, "")
		if wrong_once and answered == 1:
			wrong_once = false
			await _type(pad, word.substr(0, word.length() - 1) + ("ᜒ" if not word.ends_with("ᜒ") else "ᜓ"), keys, hero)
			await _wait(1.0)
			_mark("wrong")
			await _submit(screen, hero)
			await _wait(11.0)
		_mark("type")
		await _type(pad, word, keys, hero)
		await _wait(0.8)
		_mark("submit")
		await _submit(screen, hero)
		answered += 1
		await _wait(2.4)


func _d(screen: Control, i: int) -> float:
	return screen.world.monks[i].position.distance_to(screen.player.position)


func _live(screen: Control) -> bool:
	return is_instance_valid(screen) and main.current == screen and not screen.get("_ending")


## GO: by its button on the phone layout, by E otherwise.
func _go(screen: Control, hero: bool) -> void:
	if hero:
		for b: TouchScreenButton in screen.find_children("*", "TouchScreenButton", true, false):
			if b.action == "interact":
				taps.show_at(b.get_global_transform_with_canvas() * (b.shape.get_rect().get_center() if b.shape else Vector2(24, 24)))
	var ev := InputEventAction.new()
	ev.action = "interact"
	ev.pressed = true
	vp.push_input(ev)
	await get_tree().process_frame
	ev = ev.duplicate()
	ev.pressed = false
	vp.push_input(ev)
	await _wait(0.2)


func _submit(screen: Control, hero: bool) -> void:
	var b := _button("Submit")
	if b == null:
		b = _button("Check")
	if b != null and hero:
		await tap(b)
	else:
		var o: Node = _keypad(screen)
		while o != null and not o.has_method("_on_submit"):
			o = o.get_parent()
		if o != null:
			o.call("_on_submit")


func _type(pad: BaybayinKeypad, word: String, every: float, shown := true) -> void:
	for g in word:
		if shown:
			var k := HowToPlay._key_of(pad, g)
			if k != null:
				await tap(k)
			else:
				pad.press(g)
		else:
			pad.press(g)
		await _wait(every * randf_range(0.75, 1.25))


## Along the grid's route to `to`: the stick on the phone layout, held toward
## the next cell; the keys for a bot.
func _walk(screen: Control, to: Vector2, hero: bool) -> void:
	var grid: MapGrid = screen.grid
	var walls := {}
	for c: Vector2i in grid.land:
		if not grid.stairs.has(c) and not grid.box_walkable(MapGrid.cell_mid(c), screen.hero_box,
				int(grid.height.get(c, 0))):
			walls[c] = true
	var way: Array[Vector2i] = grid.route(MapGrid.cell_at(screen.player.position), screen.hero_level,
		MapGrid.cell_at(to), walls)
	var points: Array[Vector2] = []
	for c in way:
		points.append(MapGrid.cell_mid(c))
	points.append(to)
	var stick: Node2D = screen.hud.joystick if hero else null
	var keys := ["move_left", "move_right", "move_up", "move_down"]
	var t := 0.0
	var next := 1
	var stuck := 0.0
	var was: Vector2 = screen.player.position
	while t < 60.0 and next < points.size() + 1 and _live(screen):
		var last := next >= points.size() - 1
		var aim: Vector2 = points[mini(next, points.size() - 1)]
		if not last and MapGrid.cell_at(screen.player.position) == MapGrid.cell_at(aim):
			next += 1
			continue
		if last and screen.player.position.distance_to(aim) < 4.0:
			break
		var d: Vector2 = aim - screen.player.position
		# Straight at the next cell; along one axis when that is blocked (a
		# ramp only goes straight up or down).
		var dir := d.normalized()
		if stuck > 0.15:
			dir = Vector2(signf(d.x), 0) if (absf(d.x) > absf(d.y)) == (fmod(stuck, 0.8) < 0.4) and absf(d.x) > 1.0 \
				else Vector2(0, signf(d.y))
		if stick != null:
			stick.set("_touch_index", 0)
			stick.position = Vector2(118, 268)
			stick.call("_drag_to", stick.position + dir * 40.0)
		else:
			for k in keys:
				Input.action_release(k)
			if absf(dir.x) > 0.3:
				Input.action_press("move_right" if dir.x > 0 else "move_left")
			if absf(dir.y) > 0.3:
				Input.action_press("move_down" if dir.y > 0 else "move_up")
		await get_tree().process_frame
		t += get_process_delta_time()
		stuck = stuck + get_process_delta_time() if screen.player.position.distance_to(was) < 0.2 else 0.0
		was = screen.player.position
	if stick != null and is_instance_valid(stick):
		stick.call("release")
	for k in keys:
		Input.action_release(k)
	await _wait(0.3)


# --- Taps, screens, waiting ---------------------------------------------------------
## A finger on `c`: pressed and let go where it is, the ring showing where.
func tap(c: Control) -> void:
	if c == null:
		push_warning("tap: nothing to tap")
		return
	await tap_at(c.get_global_rect().get_center())


func tap_at(at: Vector2) -> void:
	taps.show_at(at)
	var move := InputEventMouseMotion.new()
	move.position = at
	move.global_position = at
	vp.push_input(move, true)
	await get_tree().process_frame
	for down in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = down
		ev.position = at
		ev.global_position = at
		vp.push_input(ev, true)
		await _wait(0.09)


## The visible button reading `text` (the last one, `last`: a panel's own
## over the screen behind it).
func _button(text: String, last := false) -> Button:
	var found: Button = null
	for b: Button in vp.find_children("*", "Button", true, false):
		if b.text == text and b.is_visible_in_tree():
			found = b
			if not last:
				return b
	return found


func _keypad(n: Node) -> BaybayinKeypad:
	for k in n.find_children("*", "BaybayinKeypad", true, false):
		if (k as Control).is_visible_in_tree():
			return k
	return null


func _until(ok: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if main.current != null and ok.call():
			return true
		await _wait(0.25)
		t += 0.25
	return false


func _until_file(name: String, timeout: float) -> bool:
	var t := 0.0
	while t < timeout and not FileAccess.file_exists(out.path_join(name)):
		await _wait(0.25)
		t += 0.25
	return t < timeout


func _until_screen(script_end: String, timeout: float) -> Control:
	var t := 0.0
	while t < timeout:
		var s: Control = main.current
		if s != null and s.get_script().resource_path.ends_with(script_end):
			return s
		await _wait(0.25)
		t += 0.25
	return null


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


## Where a finger touched: a ring that grows and fades, as a phone's screen
## recorder draws it.
class Taps:
	extends Node2D
	var _rings: Array = []

	func show_at(at: Vector2) -> void:
		_rings.append({"at": at, "t": 0.0})

	func _process(delta: float) -> void:
		for r: Dictionary in _rings:
			r.t += delta
		_rings = _rings.filter(func(r: Dictionary) -> bool: return r.t < 0.45)
		queue_redraw()

	func _draw() -> void:
		for r: Dictionary in _rings:
			var k: float = r.t / 0.45
			draw_circle(r.at, 9.0 + 6.0 * k, Color(1, 1, 1, 0.35 * (1.0 - k)))
			draw_arc(r.at, 9.0 + 6.0 * k, 0.0, TAU, 32, Color(1, 1, 1, 0.9 * (1.0 - k)), 1.5)

extends Node

## Screenshots of the online flow -- Find Match, the lobby, the match, a monk,
## Results -- from a real client against a local server. Windowed (it needs a
## GL context), two at once, driven by tools/flow_shots.py:
##
##   godot --path game res://tools/flow_shots.tscn -- --player=N --out=DIR
##
## LAKBAYIN_TEST_INFO names the accounts file; LAKBAYIN_SERVER_URL the server.
## Player 0 queues first, answers a monk and finishes the match; player 1
## joins second and watches it end.

var index := 0
var out := "user://"
var vp: SubViewport
var main: Control


func _ready() -> void:
	# Two test windows side by side: GNOME withholds frame callbacks from a
	# window it considers hidden, and with vsync on that pins it near 1 fps.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 60
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--player="):
			index = int(arg.trim_prefix("--player="))
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	var info: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
			OS.get_environment("LAKBAYIN_TEST_INFO")))
	var account: Dictionary = info.accounts[index]
	var err := await Net.sign_in(account.username, account.password)
	if err != "":
		push_error(err)
		get_tree().quit(1)
		return
	vp = SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.size_2d_override = Vector2i(640, 360)
	vp.size_2d_override_stretch = true
	# Drawn only for a shot: two clients each redrawing a 1080p target every
	# frame starved the frame rate, and Godot's HTTP advances once a frame --
	# requests took seconds and the lobby dropped the slower client.
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	# FLOW_LIVE: redraw every frame -- nested views (Watch's map) only stay
	# current that way. Costlier; fine for the room scenario.
	if OS.get_environment("FLOW_LIVE") != "" and (index == 0 or OS.get_environment("FLOW_LIVE") == "all"):
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	main = load("res://scenes/Main.tscn").instantiate()
	vp.add_child(main)
	await _wait(1.0)
	main.open("home")
	await _wait(1.5)
	await _shot("home")
	# FLOW_SCREENS="room,records": just those screens, signed in.
	if OS.get_environment("FLOW_SCREENS") != "":
		for name in OS.get_environment("FLOW_SCREENS").split(","):
			if name == "leaderboard":
				main.open("records", {"tab": "player_board"})
			else:
				main.open(name.get_slice(":", 0))
			await _wait(1.5)
			if name.contains(":"):
				main.current.call(name.get_slice(":", 1))
				await _wait(1.0)
			await _shot(name.replace(":", "_"))
		get_tree().quit(0)
		return
	if OS.get_environment("FLOW_SCENARIO") == "room":
		await _room_flow()
		return

	# Player 0 queues alone first, so the waiting lobby can be seen.
	await _wait(1.0 if index == 0 else float(OS.get_environment("FLOW_JOIN_DELAY") if OS.get_environment("FLOW_JOIN_DELAY") != "" else "6"))
	main.open("team")
	await _wait(0.5)
	main.current.call("_find")
	await _wait(0.9)
	await _shot("finding")
	if OS.get_environment("FLOW_DEBUG") != "":
		for i in 40:
			var c: Control = main.current
			if c != null and c.get_script().resource_path.ends_with("TeamNameScreen.gd"):
				print("dbg fps=%d t=%d state=%s mine=%s entering=%s polling=%s players=%s" % [Engine.get_frames_per_second(), i,
					str(c.get("_session").get("state", "")), str(c.get("_mine")), str(c.get("_entering")),
					str(c.get("_polling")), str(c.get("_lobby").players.keys().size())])
			else:
				print("dbg t=%d screen=%s" % [i, c.get_script().resource_path.get_file() if c else "-"])
				break
			await _wait(1.0)
	var screen := await _until_screen("AdventureScreen.gd", 30.0)
	if screen == null:
		await _shot("stuck")
		get_tree().quit(1)
		return
	await _wait(1.0)
	await _shot("match_intro")
	screen.call("skip_intro")
	await _wait(2.0)
	await _shot("match")

	if index == 0:
		screen.call("_open_monk", 0)
		await _wait(1.0)
		await _shot("monk")
		var spelling := _spelling(screen.play.words[0])
		var pad: BaybayinKeypad = _find_keypad(screen)
		for ch in spelling:
			pad.press(ch)
		await _wait(0.5)
		await _shot("monk_typed")
		var overlay: Node = pad
		while overlay != null and not overlay.has_method("_on_submit"):
			overlay = overlay.get_parent()
		overlay.call("_on_submit")
		await _wait(1.5)
		await _shot("monk_answered")
		await _wait(2.0)
		await _shot("match_carrying")
		# Finish: the rest answered and everything deposited.
		for i in range(1, screen.play.words.size()):
			var r: String = await Monks.answer(screen.play.session_id, i, _spelling(screen.play.words[i]))
			if r != "correct":
				push_error(r)
		await Monks.deposit(screen.play.session_id)
	else:
		await _wait(4.0)
		await _shot("match_other")

	var results := await _until_screen("ResultsScreen.gd", 40.0)
	await _wait(2.5)
	await _shot("results" if results != null else "no_results")
	Net.realtime().close_socket()
	get_tree().quit(0)


## FLOW_SCENARIO=room, three clients: 0 creates a room and spectates, 1 and 2
## join by code onto Blue and Red, 0 starts, 1 finishes the match.
func _room_flow() -> void:
	var code_file := out.path_join("room_code.txt")
	main.open("room")
	await _wait(1.0)
	if index == 0:
		main.current.call("_create")
		var lobby := await _until(func() -> bool: return str(main.current.get("_session").get("code", "")) != "", 15.0)
		var code := str(main.current.get("_session").get("code", ""))
		FileAccess.open(code_file, FileAccess.WRITE).store_string(code)
		await _wait(1.0)
		main.current.call("_pick", Lobby.SPECTATE)
		await _wait(1.5)
		# FLOW_HINTS: the host turns letter hints on.
		if OS.get_environment("FLOW_HINTS") != "":
			await main.current.call("_toggle_hints")
			await _wait(1.0)
		await _shot("room_host")
		# Everyone else on a side: N players, alternating Blue and Red.
		var want := int(OS.get_environment("FLOW_CLIENTS")) - 1
		await _until(func() -> bool:
			var l: Lobby = main.current.get("_lobby")
			return l.members_of(l.teams[0].id).size() + l.members_of(l.teams[1].id).size() >= want, 90.0)
		await _wait(2.0)
		await _shot("room_full")
		main.current.call("_start")
		var watch := await _until_screen("WatchScreen.gd", 20.0)
		for i in 4:
			if watch == null:
				break
			var pe: Node = watch.get("peers")
			var live: Array = []
			if pe != null:
				for id: String in pe.get("_markers"):
					if pe._is_live(id):
						live.append("%s@%s" % [id.left(4), str(pe.get("_markers")[id].position.round())])
			print("dbgwatch t=%d live=%s roster=%d" % [i, str(live), (watch.get("_roster") as Dictionary).size()])
			await _wait(1.0)
		await _shot("spectator" if watch != null else "spectator_missing")
		if watch != null:
			# Close in on a walking player.
			var pe: Node = watch.get("peers")
			var aim: Vector2 = watch.get("world").door()
			for id: String in pe.get("_markers"):
				aim = pe.get("_markers")[id].position
			watch.call("_look", aim, float(watch.get("_fit")) * 2.5)
			await _wait(1.5)
			await _shot("spectator_zoom")
			(watch.get("_stats") as Control).visible = true
			await _wait(1.0)
			await _shot("spectator_stats")
			(watch.get("_stats") as Control).visible = false
			await _wait(25.0)
			await _shot("spectator_end")
	else:
		await _until(func() -> bool: return FileAccess.file_exists(code_file), 40.0)
		await _wait(float(index) * 0.7)
		main.current.get("_code").text = FileAccess.get_file_as_string(code_file)
		main.current.call("_enter")
		await _until(func() -> bool: return main.current.get("_lobby").teams.size() == 2, 15.0)
		await _wait(1.0)
		main.current.call("_pick", main.current.get("_lobby").teams[(index - 1) % 2].id)
		await _wait(2.0)
		await _shot("room_player")
		var screen := await _until_screen("AdventureScreen.gd", 60.0)
		if screen == null:
			await _shot("stuck")
			get_tree().quit(1)
			return
		screen.call("skip_intro")
		# Walk, so a spectator has movement to see -- each of a team's players
		# a different way, so they are apart on the minimap too.
		var way: String = ["move_right", "move_left", "move_down", "move_up", "move_down", "move_up"][(index - 1) % 6]
		Input.action_press(way)
		await _wait(3.0)
		await _shot("match")
		# FLOW_CHECKS: the server checks positions; walk there for real.
		if index == 1 and OS.get_environment("FLOW_CHECKS") != "":
			Input.action_release(way)
			await _honest(screen)
		# The minimap with everything found: every monk seen, the Monastery
		# found, one monk answered by this team.
		elif index == 1:
			await Monks.answer(screen.play.session_id, 0, _spelling(screen.play.words[0]))
			for i in screen.world.monks.size():
				screen.get("_seen")[i] = true
			screen.set("_monastery_seen", true)
			await _wait(2.0)
			await _shot("match_minimap")
			# A monk's answer pad, as the room set it: hints or none.
			screen.call("_open_monk", 1)
			await _wait(1.0)
			await _shot("monk_pad")
			(screen.get("_overlay") as Node).queue_free()
		await _wait(10.0)
		Input.action_release(way)
		if index == 1:
			for i in screen.play.words.size():
				await Monks.answer(screen.play.session_id, i, _spelling(screen.play.words[i]))
			await Monks.deposit(screen.play.session_id)
		var res := await _until_screen("ResultsScreen.gd", 40.0)
		await _wait(2.0)
		await _shot("results")
		if res != null and index == 1:
			for b: Button in res.find_children("*", "Button", true, false):
				if b.text == "Words":
					b.pressed.emit()
			await _wait(0.5)
			await _shot("results_words")
			main.open("records")
			await _wait(2.5)
			await _shot("records")
			main.open("records", {"tab": "player_board"})
			await _wait(2.0)
			await _shot("records_board")
			main.open("home")
			await _wait(2.5)
			await _shot("home_after")
	Net.realtime().close_socket()
	get_tree().quit(0)


func _until(ok: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if main.current != null and ok.call():
			return true
		await _wait(0.25)
		t += 0.25
	return false


func _spelling(word: Dictionary) -> String:
	var source: Array = JSON.parse_string(FileAccess.get_file_as_string("res://data/words.json"))
	for w: Dictionary in source:
		if w.word == word.word:
			return str(w.modern)
	return ""


func _find_keypad(n: Node) -> BaybayinKeypad:
	if n is BaybayinKeypad:
		return n
	for c in n.get_children():
		var k := _find_keypad(c)
		if k != null:
			return k
	return null


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


func _shot(name: String) -> void:
	if vp.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var path := out.path_join("p%d_%s.png" % [index, name])
	vp.get_texture().get_image().save_png(path)
	print("shot ", path)


## Walks the hero to the nearest monk by the keys, as a player would, answers
## him, tries a monk across the map (the server must refuse), then walks to
## the Monastery and deposits. Prints each result for flow_shots.py's log.
func _honest(screen: Control) -> void:
	var grid: MapGrid = screen.grid
	# The nearest monk up on a plateau if there is one: the walk takes a ramp.
	var near := -1
	var up := false
	for i in screen.world.monks.size():
		var high: bool = grid.level_at(screen.world.monks[i].position, 0) > 0
		if near < 0 or (high and not up) or (high == up and screen.world.monks[i].position.distance_to(screen.player.position)
				< screen.world.monks[near].position.distance_to(screen.player.position)):
			near = i
			up = high
	print("honest target on level %d" % grid.level_at(screen.world.monks[near].position, 0))
	print("honest walk to monk %d: %s" % [near, await _walk(screen, screen.world.monks[near].position + Vector2(0, 26))])
	print("honest answer: ", await screen.play.answer(near, _spelling(screen.play.words[near]), screen.player.position))
	var far: int = (near + 5) % screen.world.monks.size()
	print("cheat answer from afar: ", await Monks.answer(screen.play.session_id, far, _spelling(screen.play.words[far]), screen.world.monks[far].position))
	print("honest walk to door: %s" % await _walk(screen, screen.world.door()))
	var got: Dictionary = await screen.play.deposit(10.0, screen.player.position)
	print("honest deposit: ", got)
	await _shot("honest")


## Holds the keys toward each cell of the way to `to` in turn. "ok" or how far off.
func _walk(screen: Control, to: Vector2) -> String:
	var grid: MapGrid = screen.grid
	# Round any cell the hero's feet do not fit in the middle of: a trunk
	# that only clips a cell still stops a hero walking through it.
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
	var keys := ["move_left", "move_right", "move_up", "move_down"]
	var t := 0.0
	var next := 1
	var other := false               # held against something: the other key
	var was: Vector2 = screen.player.position
	while t < 90.0 and next < points.size() + 1:
		var last := next >= points.size() - 1
		var aim: Vector2 = points[mini(next, points.size() - 1)]
		if not last and MapGrid.cell_at(screen.player.position) == MapGrid.cell_at(aim):
			next += 1
			continue
		if last and screen.player.position.distance_to(aim) < 4.0:
			break
		var d: Vector2 = aim - screen.player.position
		for k in keys:
			Input.action_release(k)
		# One key at a time: on a ramp straight up or down follows its slope.
		if (absf(d.x) > absf(d.y)) != other and absf(d.x) > 1.0:
			Input.action_press("move_right" if d.x > 0 else "move_left")
		else:
			Input.action_press("move_down" if d.y > 0 else "move_up")
		await get_tree().process_frame
		t += get_process_delta_time()
		other = screen.player.position == was and not other
		was = screen.player.position
	for k in keys:
		Input.action_release(k)
	await _wait(0.5)
	return "ok" if screen.player.position.distance_to(to) < 12.0 else "stopped %.0fpx off at %s, %d steps" \
		% [screen.player.position.distance_to(to), screen.player.position, way.size()]


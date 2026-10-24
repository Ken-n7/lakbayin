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
	add_child(vp)
	main = load("res://scenes/Main.tscn").instantiate()
	vp.add_child(main)
	await _wait(1.0)
	main.open("home")
	await _wait(1.5)
	await _shot("home")

	# Player 0 queues alone first, so the waiting lobby can be seen.
	await _wait(1.0 if index == 0 else float(OS.get_environment("FLOW_JOIN_DELAY") if OS.get_environment("FLOW_JOIN_DELAY") != "" else "6"))
	main.open("team")
	await _wait(0.5)
	main.current.call("_find")
	await _wait(2.0)
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
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var path := out.path_join("p%d_%s.png" % [index, name])
	vp.get_texture().get_image().save_png(path)
	print("shot ", path)

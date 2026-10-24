extends TestCase
## E2E: drives the real UI -- splash -> sign in -> Home -> hero select -> the
## offline team form -> a Practice match: a monk answered and deposited through
## GO, every word deposited -> the results and their buttons -- then restores
## the saved profile. The match's own rules are match_test's; this is the
## flow between screens.
## Run with:  godot --headless res://scripts/tests/e2e_test.tscn

var _main_scene: Node = null
var _pname := ""
var _tname := ""


func _ready() -> void:
	seed(20260921)
	process_mode = Node.PROCESS_MODE_ALWAYS
	backup_save()
	_pname = Game.player_name
	_tname = Game.team_name
	Game.player_name = ""
	Game.team_name = ""
	await _run()
	Game.player_name = _pname
	Game.team_name = _tname
	finish("E2E")


func _screen() -> Node:
	return _main_scene.get("current")


func _script_of(node: Node, path: String) -> bool:
	return node != null and node.get_script() == load(path)


func _find_button(root: Node, text: String) -> Button:
	for child in root.get_children():
		if child is Button and child.text.contains(text):
			return child
		var hit := _find_button(child, text)
		if hit != null:
			return hit
	return null


func _find_label(root: Node, text: String) -> Label:
	for child in root.get_children():
		if child is Label and child.text.contains(text):
			return child
		var hit := _find_label(child, text)
		if hit != null:
			return hit
	return null


func _find_line_edit(root: Node) -> LineEdit:
	for child in root.get_children():
		if child is LineEdit:
			return child
		var hit := _find_line_edit(child)
		if hit != null:
			return hit
	return null


func _find_button_tooltip(root: Node, tip: String) -> Button:
	for child in root.get_children():
		if child is Button and child.tooltip_text == tip:
			return child
		var hit := _find_button_tooltip(child, tip)
		if hit != null:
			return hit
	return null


func _click(root: Node, text: String) -> void:
	var b := _find_button(root, text)
	if b == null:
		b = _find_button_tooltip(root, text)
	if b == null:
		check("button exists: %s" % text, false)
		return
	check("button exists: %s" % text, true)
	b.pressed.emit()


func _wait(frames := 3) -> void:
	for i in frames:
		await get_tree().process_frame


## GO, as the keyboard presses it: the interact action.
func _press_go() -> void:
	var ev := InputEventAction.new()
	ev.action = "interact"
	ev.pressed = true
	Input.parse_input_event(ev)
	await _wait(2)
	ev = ev.duplicate()
	ev.pressed = false
	Input.parse_input_event(ev)
	await _wait(1)


func _run() -> void:
	_main_scene = preload("res://scenes/Main.tscn").instantiate()
	add_child(_main_scene)
	await _wait(4)

	print("== 1. splash -> sign in -> home ==")
	check("booted to splash", _script_of(_screen(), "res://scripts/SplashScreen.gd"))
	check("splash shows the tagline", _find_label(_screen(), Art.TAGLINE) != null)
	_screen().call("skip")
	await _wait(3)
	# With a project configured, a launch lands on the login form. This suite
	# is offline by design: it asserts the gate, then steps over it.
	check("a fresh launch asks you to sign in", _script_of(_screen(), "res://scripts/LoginScreen.gd"))
	check("login offers a way to register", _find_button(_screen(), "Create Account") != null)
	check("login has no email recovery", _find_button(_screen(), "Forgot Password?") == null)
	_main_scene.call("open", "register")
	await _wait(3)
	check("registering asks for no role", _find_label(_screen(), "Role") == null)
	check("registering asks for no email", _find_label(_screen(), "Email") == null)
	_main_scene.call("open", "home")
	await _wait(3)
	check("home is the title", _script_of(_screen(), "res://scripts/HomeScreen.gd"))
	check("Find Match present", _find_button(_screen(), "Find Match") != null)
	check("Practice present", _find_button(_screen(), "Practice") != null)
	check("Custom Room present", _find_button(_screen(), "Custom Room") != null)
	_main_scene.call("open", "room")
	await _wait(3)
	check("Custom Room opens its own screen", _script_of(_screen(), "res://scripts/RoomScreen.gd"))
	_main_scene.call("open", "home")
	await _wait(3)
	for gone in ["Learn", "Leaderboard"]:
		check("no %s button" % gone, _find_button(_screen(), gone) == null)

	print("== 2. hero select -> sign in to Find Match; Practice -> a match ==")
	_click(_screen(), "Find Match")
	await _wait(3)
	var hero := _screen()
	check("reached hero select", _script_of(hero, "res://scripts/HeroSelectScreen.gd"))
	check("no name field", _find_line_edit(hero) == null)
	for id in [1, Game.HERO_COUNT]:
		check("adventurer #%d present" % id, _find_button_tooltip(hero, "Adventurer #%d" % id) != null)
	_find_button_tooltip(hero, "Adventurer #12").pressed.emit()
	_click(hero, "Lock In")
	await _wait(3)
	check("hero 12 kept", Game.hero_id == 12, str(Game.hero_id))
	# Signed out, Find Match asks for an account; Home's Practice is the
	# offline game.
	check("signed out, Find Match asks to sign in", _find_label(_screen(), "Sign in to find a match.") != null)
	_find_button_tooltip(_screen(), "Back").pressed.emit()   # the title's arrow
	await _wait(3)
	_click(_screen(), "Practice")
	await _wait(6)
	var adv := _screen()
	check("reached the match", _script_of(adv, "res://scripts/AdventureScreen.gd"))
	check("offline, it is Practice", adv.play.practice)
	adv.skip_intro()
	await _wait(2)
	check("the world is built", adv.world.gen.land.size() > 800, str(adv.world.gen.land.size()))
	check("ten monks stand on it", adv.world.monks.size() == 10)
	check("the hero starts at Blue's spawn", adv.player.position == adv.world.spawn_of(0))
	check("the clock runs", Game.adventure_active and not Game.clock_paused)

	print("== 3. a monk through GO, then the Monastery ==")
	adv.player.position = adv.world.monks[2].position + Vector2(0, 24)
	await _wait(2)
	await _press_go()
	var monk: Control = adv._overlay
	check("GO beside a monk opens his word", monk != null)
	if monk != null:
		var spelling := str(adv.play.words[2].modern)
		for i in spelling.length():
			monk._keypad.press(spelling[i])
		_click(monk, "Submit")
		await get_tree().create_timer(1.5).timeout
		check("his word is carried", adv.play.carried() == [2])
		check("the panel closed itself", adv._overlay == null)
	adv.player.position = adv.world.door()
	await _wait(2)
	await _press_go()
	await _wait(2)
	check("GO at the Monastery deposits it", adv.play.deposited() == 1)

	print("== 4. every word deposited -> results ==")
	for i in 10:
		if not adv.play.ours(i):
			await adv.play.answer(i, str(adv.play.words[i].modern))
	var first_word := str(adv.play.words[0].modern)
	await _press_go()
	check("the last deposit ends the match", adv._ending)
	await get_tree().create_timer(4.6).timeout
	var res := _screen()
	check("the results open", _script_of(res, "res://scripts/ResultsScreen.gd"))
	check("they say every word went in", _find_label(res, "Every word deposited") != null)
	check("they show the words in Baybayin", _find_label(res, first_word) != null)
	_click(res, "Practice again")
	await _wait(6)
	check("Practice again opens a new match", _script_of(_screen(), "res://scripts/AdventureScreen.gd")
		and _screen().play.practice)
	_screen().go_back()
	await _wait(4)
	check("back from Practice goes Home", _script_of(_screen(), "res://scripts/HomeScreen.gd"))
	check("and the clock stops", not Game.adventure_active)

	print("== 5. join codes ==")
	check("codes are cleaned as typed", Teams.clean_code(" k7-qm ") == "K7QM", Teams.clean_code(" k7-qm "))
	check("a look-alike twin becomes the character codes use",
		Teams.clean_code("zsbvg") == "258U6", Teams.clean_code("zsbvg"))
	for twin: String in Teams.TWINS:
		check("codes never contain %s" % twin, not Teams.CODE_CHARS.contains(twin))
		check("but do contain its twin %s" % Teams.TWINS[twin],
			Teams.CODE_CHARS.contains(Teams.TWINS[twin]))
	check("look-alikes are caught", Teams.bad_chars("O0I1L") == "O0I1L", Teams.bad_chars("O0I1L"))
	check("a real code has none", Teams.bad_chars("K7QM") == "")
	# The game's alphabet and the server's must be one string, or the game
	# would refuse codes the server hands out.
	var schema := FileAccess.get_file_as_string(
		ProjectSettings.globalize_path("res://") + "../supabase/schema.sql")
	check("the code alphabet matches session_code() in schema.sql",
		schema.contains("abc text := '%s';" % Teams.CODE_CHARS))
	completed = true

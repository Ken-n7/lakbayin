extends TestCase
## E2E: drives the real UI — title → hero select → adventure map → tower
## briefing → one circle per item → Victory Gate → summary → leaderboard/learn —
## then restores the saved profile.
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


func _click(root: Node, text: String) -> void:
	var b := _find_button(root, text)
	# A bare glyph -- the "←" in a screen's title -- is found by what it says
	# it does: its tooltip.
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


func _stash_text(s: String) -> String:
	if s == "":
		return "Adventurer"
	return s


func _find_button_tooltip(root: Node, tip: String) -> Button:
	for child in root.get_children():
		if child is Button and child.tooltip_text == tip:
			return child
		var hit := _find_button_tooltip(child, tip)
		if hit != null:
			return hit
	return null


## Every map open starts frozen on the aerial POV; collapse it so nothing in the
## test waits on a tween — and so the clock is running again.
func _map() -> Node:
	var scr := _screen()
	if scr != null and scr.has_method("skip_intro"):
		scr.call("skip_intro")
	return scr


## The tower hands out the station briefing card and nothing else.
func _enter_tower(adv: Node, s: int) -> void:
	(adv.get("player") as Node2D).position = (adv.get("stations").nodes[s] as Node2D).position
	adv.call("_try_enter_station")
	await _wait(2)
	var ov: Node = adv.get("_overlay")
	check("station %d briefing opened" % (s + 1), ov != null)
	if ov == null:
		return
	check("briefing is the intro card", bool(ov.get("intro_only")))
	_click(ov, "Continue")
	await _wait(2)
	check("briefing returns to the map", adv.get("_overlay") == null)
	check("station %d circles unlocked" % (s + 1), Game.towers_entered[s])


## Walk onto circle `n` and open its item. Returns the overlay, or null.
func _open_circle(adv: Node, n: int) -> Node:
	(adv.get("player") as Node2D).position = (adv.get("_circles")[n] as Node2D).position
	adv.call("_try_answer_circle")
	await _wait(2)
	return adv.get("_overlay")


## Answers every circle of station `s` correctly, one overlay each, and clicks
## through the completion ribbon its last item raises.
func _play_station(adv: Node, s: int) -> void:
	await _enter_tower(adv, s)
	var count: int = Game.ITEMS_PER_STATION[s]
	for i in count:
		var n: int = Game.items_done
		var ov: Node = await _open_circle(adv, n)
		if ov == null:
			check("circle %d opened" % (n + 1), false)
			return
		check("circle %d in question phase" % (n + 1), int(ov.get("phase")) == 1, str(ov.get("phase")))
		_find_line_edit(ov).text = str(ov.get("answer"))
		_click(ov, "Submit Answer")
		await _wait(1)
		check("feedback on circle %d" % (n + 1), int(ov.get("phase")) == 2, str(ov.get("phase")))
		_click(ov, "Continue")
		await _wait(1)
		if i < count - 1:
			check("circle %d returned to the map" % (n + 1), adv.get("_overlay") == null)
		else:
			# The station's last item pays the perfect bonus on its own ribbon.
			check("station %d ribbon shown" % (s + 1), int(ov.get("phase")) == 3, str(ov.get("phase")))
			_click(ov, "Return to Map")
			await _wait(2)


## Deterministically end the active adventure by exhausting the timer:
## headless runs unthrottled frames, so waiting on wall-clock would flake.
func _end_via_time() -> void:
	Game.time_left = 0.01
	await Game.adventure_ended
	await _wait(2)


## Start Adventure is two steps now: the home screen, then the team name.
## Every "Join Quest" in this suite goes through both.
## A player types a name every run, so the default is a name and not "".
## Section 8 clears `Game.team_name`, and an empty field is refused -- which
## is the screen behaving, not a broken step.
func _continue_quest(team := "Test Team") -> void:
	_click(_screen(), "Join Quest")
	await _wait(3)
	_screen()._team.text = team
	_click(_screen(), "Ready!")
	await _wait(4)


func _run() -> void:
	_main_scene = preload("res://scenes/Main.tscn").instantiate()
	add_child(_main_scene)
	await _wait(4)

	print("== 1. splash -> sign in -> home ==")
	check("booted to splash", _script_of(_screen(), "res://scripts/SplashScreen.gd"))
	check("splash shows the tagline", _find_label(_screen(), "Explore.") != null)
	_screen().call("skip")
	await _wait(3)
	# With keys in project.godot the backend is always configured, so a launch
	# lands on the login form -- which is the point, and what a phone does.
	# This suite is offline by design: it asserts the gate, then steps over it
	# rather than signing in, because a suite that needs the network is a suite
	# that fails on a train.
	check("a fresh launch asks you to sign in",
		_script_of(_screen(), "res://scripts/LoginScreen.gd"))
	check("login offers a way to register", _find_button(_screen(), "Create Account") != null)
	check("login offers recovery", _find_button(_screen(), "Forgot Password?") != null)
	_main_scene.call("open", "home")
	await _wait(3)
	check("splash routes to title", _script_of(_screen(), "res://scripts/HomeScreen.gd"))
	check("start button present", _find_button(_screen(), "Start Adventure") != null)
	check("learn button present", _find_button(_screen(), "Learn") != null)
	check("board button present", _find_button(_screen(), "Leaderboard") != null)

	print("== 2. hero select ==")
	_click(_screen(), "Start Adventure")
	await _wait(3)
	var hero := _screen()
	check("reached hero select", _script_of(hero, "res://scripts/HeroSelectScreen.gd"))
	var name_field := _find_line_edit(hero)
	check("name field present", name_field != null)
	name_field.text = "E2E Hero"
	_find_button_tooltip(hero, "Adventurer #12").pressed.emit()
	_click(hero, "Begin Adventure")
	await _wait(3)
	# Hero select hands off to the team name, which is what begins the run.
	_screen()._team.text = "Test Team"
	_click(_screen(), "Ready!")
	await _wait(4)

	print("== 3. adventure map ==")
	var adv := _map()
	check("reached adventure", adv.has_method("_try_enter_station"))
	var land: Dictionary = adv.get("grid").land
	check("island cells", land.size() > 700, str(land.size()))
	check("three stations", (adv.get("stations").nodes as Array).size() == 3)
	check("all circles built", (adv.get("_circles") as Array).size() == Game.TOTAL_ITEMS,
			str((adv.get("_circles") as Array).size()))
	check("victory gate built", adv.get("stations").gate != null)
	check("player spawned", adv.get("player") != null and adv.get("player").get_child_count() > 0)
	check("player starts at base camp", (adv.get("player") as Node2D).position == (adv.get("grid").anchors as Array)[0])
	check("world y-sorted", (adv.get("world") as Node2D).y_sort_enabled)
	check("grass meta set", (adv.get("world") as Node2D).has_meta("grass"))
	check("intro collapsed, clock running", not Game.clock_paused)

	# No circle answers before its tower briefing, and the gate is shut.
	var stations: Array = adv.get("stations").nodes
	var player: Node2D = adv.get("player")
	check("circle 1 locked before the briefing", not bool(adv.call("_can_answer", 0)))
	check("gate shut at the start", not bool(adv.call("_can_enter_gate")))
	var early: Node = await _open_circle(adv, 0)
	check("locked circle opens nothing", early == null)

	print("== 4. station 1: briefing, then one circle per item ==")
	var gems0 := Game.gems
	check("start gems 50", Game.gems == Game.START_GEMS, str(Game.gems))
	await _enter_tower(adv, 0)
	check("circle 1 current after the briefing", bool(adv.call("_can_answer", 0)))
	check("circle 2 still locked", not bool(adv.call("_can_answer", 1)))

	# The "!" over the hero is the only cue that an item is answerable -- there is
	# no marker on the ground any more -- so it has to track the gating exactly.
	var bang: Control = adv.get("_bang")
	check("bang exists, hidden until something is in reach", bang != null and not bang.visible)
	(adv.get("player") as Node2D).position = (adv.get("_circles")[0] as Node2D).position
	adv.call("_update_interaction")
	check("bang on at the answerable circle", bang != null and bang.visible)
	(adv.get("player") as Node2D).position = (adv.get("_circles")[3] as Node2D).position
	adv.call("_update_interaction")
	check("bang off at a locked circle", bang != null and not bang.visible)
	(adv.get("player") as Node2D).position += Vector2(400, 0)
	adv.call("_update_interaction")
	check("bang off in open grass", bang != null and not bang.visible)

	# circle 1: correct
	var ov: Node = await _open_circle(adv, 0)
	check("circle overlay opened", ov != null)
	check("circle is not the intro card", not bool(ov.get("intro_only")))
	check("question phase", int(ov.get("phase")) == 1, str(ov.get("phase")))
	_find_line_edit(ov).text = str(ov.get("answer"))
	_click(ov, "Submit Answer")
	await _wait(2)
	check("feedback after submit", int(ov.get("phase")) == 2, str(ov.get("phase")))
	check("correct gains +10", Game.gems == gems0 + 10, str(Game.gems))
	_click(ov, "Continue")
	await _wait(2)
	check("one item, then back to the map", adv.get("_overlay") == null)
	check("circle 1 done", Game.items_done == 1, str(Game.items_done))

	# circle 2: wrong
	ov = await _open_circle(adv, 1)
	var rescue := _find_button(ov, "Rescue")
	check("rescue present", rescue != null)
	check("rescue disabled", rescue != null and rescue.disabled)
	_find_line_edit(ov).text = "999"
	_click(ov, "Submit Answer")
	await _wait(2)
	check("wrong loses 5", Game.gems == gems0 + 5, str(Game.gems))
	_click(ov, "Continue")
	await _wait(2)

	# circle 3: hint, then correct
	ov = await _open_circle(adv, 2)
	_click(ov, "Hint")
	await _wait(1)
	check("hint consumed", Game.hints_used == 1, str(Game.hints_used))
	_find_line_edit(ov).text = str(ov.get("answer"))
	_click(ov, "Submit Answer")
	await _wait(2)
	check("hint costs 5 then +10", Game.gems == gems0 + 10, str(Game.gems))
	_click(ov, "Continue")
	await _wait(2)

	# circle 4: skip
	ov = await _open_circle(adv, 3)
	_click(ov, "Skip")
	await _wait(2)
	check("skip costs 15", Game.gems == gems0 - 5, str(Game.gems))
	check("skip resolves the circle", Game.items_done == 4, str(Game.items_done))
	check("skip returns to the map", adv.get("_overlay") == null)

	print("== 5. finish run -> summary ==")
	Game.end_adventure()
	await _wait(4)
	var sum := _screen()
	check("summary shown", _script_of(sum, "res://scripts/SummaryScreen.gd"))
	var result: Dictionary = Game.last_run
	check("result recorded", not result.is_empty())
	check("penalty applied (45-25=20)", result.get("gems", 0) == 20, str(result.get("gems")))

	print("== 6. navigate onward ==")
	_click(sum, "Leaderboard")
	await _wait(3)
	check("leaderboard shown", _script_of(_screen(), "res://scripts/LeaderboardScreen.gd"))
	_click(_screen(), "Back")
	await _wait(3)
	check("back to home", _script_of(_screen(), "res://scripts/HomeScreen.gd"))
	_click(_screen(), "Learn")
	await _wait(3)
	check("learn shown", _script_of(_screen(), "res://scripts/LearnScreen.gd"))
	_click(_screen(), "Back")
	await _wait(3)
	check("back to title again", _script_of(_screen(), "res://scripts/HomeScreen.gd"))
	check("main backref wired", true)

	print("== 7. continue quest + pause menu ==")
	check("continue quest shown", _find_button(_screen(), "Join Quest") != null)
	# With a profile saved, the title needs its own way back to hero creation.
	check("title change character shown", _find_button(_screen(), "Change Character") != null)
	# Quit is gone with the second navigation: on a phone the back button
	# leaves, and Log Out is the action that means something to a student.
	check("no stray Quit button", _find_button(_screen(), "Quit") == null)
	_click(_screen(), "Change Character")
	await _wait(3)
	check("change character opens hero select", _script_of(_screen(), "res://scripts/HeroSelectScreen.gd"))
	_click(_screen(), "Back")
	await _wait(3)
	# Start Adventure now goes by way of the team name, per SPECS §3.
	_click(_screen(), "Join Quest")
	await _wait(3)
	check("continue quest asks for the team name",
		_script_of(_screen(), "res://scripts/TeamNameScreen.gd"))
	_screen()._team.text = "Test Team"
	_click(_screen(), "Ready!")
	await _wait(4)
	adv = _map()
	check("reached adventure from continue", adv.has_method("_try_enter_station"))
	check("team name carried into the run", Game.team_name == "Test Team")
	adv.get("hud").open_menu()
	await _wait(1)
	check("paused", bool(adv.get("hud").paused))
	check("resume button", _find_button(adv, "Resume") != null)
	check("home button", _find_button(adv, "Home") != null)
	check("board button", _find_button(adv, "Leaderboard") != null)
	check("restart button", _find_button(adv, "Restart") != null)
	check("new game button", _find_button(adv, "New Game") != null)
	_click(adv, "Resume")
	await _wait(1)
	check("resumed", not bool(adv.get("hud").paused))

	# Restart drops the run and starts a fresh one on a rebuilt map.
	Game.gems = 999
	Game.completed_stations[0] = true
	var rows_before: int = Game.leaderboard.size()
	adv.get("hud").open_menu()
	await _wait(1)
	_click(adv, "Restart")
	await _wait(4)
	adv = _map()
	check("restart reopened the map", adv.has_method("_try_enter_station"))
	check("restart reset gems", Game.gems == Game.START_GEMS, str(Game.gems))
	check("restart reset stations", (Game.completed_stations as Array) == [false, false, false])
	check("restart scored nothing", Game.leaderboard.size() == rows_before)

	# New Game goes back to hero creation, also without scoring the run.
	adv.get("hud").open_menu()
	await _wait(1)
	_click(adv, "New Game")
	await _wait(4)
	check("new game reached hero select", _script_of(_screen(), "res://scripts/HeroSelectScreen.gd"))
	check("new game dropped the run", not Game.adventure_active)
	check("new game scored nothing", Game.leaderboard.size() == rows_before)
	_click(_screen(), "Back")
	await _wait(3)
	await _continue_quest()   # team name is remembered from the last run
	adv = _map()
	check("back on the map", adv.has_method("_try_enter_station"))
	adv.get("hud").open_menu()
	await _wait(1)
	_click(adv, "Leaderboard")
	await _wait(3)
	check("leaderboard from pause", _script_of(_screen(), "res://scripts/LeaderboardScreen.gd"))
	_click(_screen(), "Back")
	await _wait(3)
	check("back to home", _script_of(_screen(), "res://scripts/HomeScreen.gd"))

	print("== 8. hero select variations ==")
	Game.player_name = ""
	Game.team_name = ""
	_main_scene.call("open", "home")
	await _wait(3)
	check("start button without profile", _find_button(_screen(), "Start Adventure") != null)
	_click(_screen(), "Start Adventure")
	await _wait(3)
	hero = _screen()
	for id in [1, Game.HERO_COUNT]:
		check("adventurer #%d present" % id, _find_button_tooltip(hero, "Adventurer #%d" % id) != null)
	# Duration left this screen with G6 -- the admin owns the clock now, and a
	# player who could pick their own length could out-sit the class.
	for dur in ["5 min", "10 min", "15 min"]:
		check("duration %s is gone from hero select" % dur, _find_button(hero, dur) == null)
	_find_button_tooltip(hero, "Adventurer #7").pressed.emit()
	check("hero local set", int(hero.get("_hero_id")) == 7, str(hero.get("_hero_id")))
	_click(hero, "Back")
	await _wait(3)
	check("hero back to title", _script_of(_screen(), "res://scripts/HomeScreen.gd"))
	_click(_screen(), "Start Adventure")
	await _wait(3)
	hero = _screen()
	var name2 := _find_line_edit(hero)
	check("name field present", name2 != null)
	name2.text = "E2E Hero"
	# re-pick after the screen was recreated (Back discarded the locals)
	_find_button_tooltip(hero, "Adventurer #7").pressed.emit()
	_click(hero, "Begin Adventure")
	await _wait(3)
	# Hero select hands off to the team name, which is what begins the run.
	_screen()._team.text = "Test Team"
	_click(_screen(), "Ready!")
	await _wait(4)
	check("reached adventure (hero 7)", _screen().has_method("_try_enter_station"))
	check("hero 7 persisted", Game.hero_id == 7, str(Game.hero_id))
	# The run takes whatever duration the admin set; hero select no longer has
	# a say, so the default is what survives.
	check("duration came from Game, not the player",
		Game.duration_seconds == 600, str(Game.duration_seconds))
	adv = _map()
	adv.get("hud").open_menu()
	await _wait(1)
	_click(adv, "Home")
	await _wait(4)
	check("home lands on title", _script_of(_screen(), "res://scripts/HomeScreen.gd"))
	check("home ends adventure", not Game.adventure_active)
	var res8: Dictionary = Game.last_run
	check("unfinished penalty recorded (25)", int(res8.get("gems", 0)) == 25, str(res8.get("gems")))

	print("== 9. summary buttons / natural end ==")
	await _continue_quest()
	_map()
	check("adventure again (fresh)", Game.adventure_active and Game.gems == Game.START_GEMS, str(Game.gems))
	await _end_via_time()
	sum = _screen()
	check("summary after time up", _script_of(sum, "res://scripts/SummaryScreen.gd"))
	var res9: Dictionary = Game.last_run
	check("time_up flagged", res9.get("time_up", false))
	check("penalty applied (25)", int(res9.get("gems", 0)) == 25, str(res9.get("gems")))
	_click(sum, "Adventure again")
	await _wait(4)
	_map()
	check("adventure again reached", _screen().has_method("_try_enter_station"))
	await _end_via_time()
	sum = _screen()
	check("summary again", _script_of(sum, "res://scripts/SummaryScreen.gd"))
	_click(sum, "Home")
	await _wait(3)
	check("summary home to title", _script_of(_screen(), "res://scripts/HomeScreen.gd"))
	_click(_screen(), "Leaderboard")
	await _wait(3)
	check("board reachable", _script_of(_screen(), "res://scripts/LeaderboardScreen.gd"))
	check("board non-empty", not (Game.leaderboard.is_empty()))
	_click(_screen(), "Back")
	await _wait(3)
	check("board back to title", _script_of(_screen(), "res://scripts/HomeScreen.gd"))

	print("== 10. walk the whole board via the UI ==")
	await _continue_quest()
	adv = _map()
	check("fresh adventure", Game.adventure_active and Game.gems == Game.START_GEMS, str(Game.gems))
	check("all stations locked", (Game.completed_stations as Array) == [false, false, false])
	check("no circles resolved", Game.items_done == 0, str(Game.items_done))
	player = adv.get("player") as Node2D
	stations = adv.get("stations").nodes as Array
	var p0: Vector2 = (stations[0] as Node2D).position
	var p1: Vector2 = (stations[1] as Node2D).position
	var p2: Vector2 = (stations[2] as Node2D).position
	check("stations distinct cells", p0 != p1 and p1 != p2 and p0 != p2, "%s / %s / %s" % [p0, p1, p2])
	for s in 3:
		await _play_station(adv, s)
		check("station %d returned to map" % (s + 1), adv.get("_overlay") == null)
		check("station %d complete" % (s + 1), Game.completed_stations[s])
		check("station %d perfect" % (s + 1), Game.perfect_stations[s])
		if s < 2:
			check("station %d does not end the run" % (s + 1), Game.adventure_active)
	check("all stations complete", (Game.completed_stations as Array) == [true, true, true])
	check("all circles resolved", Game.items_done == Game.TOTAL_ITEMS, str(Game.items_done))
	check("perfect gems 220 (14 correct + 3 perfect bonuses)", Game.gems == 220, str(Game.gems))
	check("board cleared but the run is still live", Game.adventure_active)

	# The Victory Gate is the end of the player flow (SPECS Q6): it scores the run.
	var gate: Node2D = adv.get("stations").gate
	check("gate now open", bool(adv.call("_can_enter_gate")))
	player.position = gate.position
	adv.call("_try_enter_gate")
	await _wait(4)
	check("gate ended the adventure", not Game.adventure_active)
	sum = _screen()
	check("summary after full run", _script_of(sum, "res://scripts/SummaryScreen.gd"))
	var res10: Dictionary = Game.last_run
	check("finished_all", res10.get("finished_all", false))
	check("no penalty (220)", int(res10.get("gems", 0)) == 220, str(res10.get("gems")))
	check("14 correct", int(res10.get("correct", 0)) == 14, str(res10.get("correct")))
	check("0 wrong/skip/hint", int(res10.get("wrong", 0)) == 0 and int(res10.get("skipped", 0)) == 0 and int(res10.get("hints", 0)) == 0)
	_click(sum, "Home")
	await _wait(3)
	check("title after full run", _script_of(_screen(), "res://scripts/HomeScreen.gd"))

	print("== 11. learn tabs ==")
	_click(_screen(), "Learn")
	await _wait(3)
	var learn := _screen()
	var lessons := [
		["Basic Operations", "operation"],
		["Exponential Notation", "exponent"],
		# The mockup's Learn copy says GEMDAS, not PEMDAS, and so do we now.
		["Order of Operations", "gemdas"],
	]
	for l in lessons:
		_click(learn, l[0])
		await _wait(1)
		var content_label: Label = learn.get("_content")
		check("%s lesson shown" % l[0], content_label != null and String(content_label.text).to_lower().contains(l[1]))
	_click(learn, "Back")
	await _wait(3)
	check("learn back to title", _script_of(_screen(), "res://scripts/HomeScreen.gd"))
	# The last line of _run(): anything that aborts the coroutine early leaves
	# this unset and `finish()` fails the suite.
	completed = true

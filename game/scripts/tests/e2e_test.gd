extends Node
## E2E: drives the real UI — title → hero select → adventure map → station quiz
## → summary → leaderboard/learn — then restores the saved profile.
## Run with:  godot --headless res://scripts/tests/e2e_test.tscn

var failures := 0
var checks := 0
var _save_backup: PackedByteArray = []
var _main_scene: Node = null
var _pname := ""
var _tname := ""

func check(name: String, condition: bool, detail := "") -> void:
	checks += 1
	if condition:
		print("  ok    ", name)
	else:
		failures += 1
		print("  FAIL  ", name, "  ", detail)


func _backup_save() -> void:
	var path := Game.SAVE_PATH
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		_save_backup = f.get_buffer(f.get_length())
		f.close()


func _restore_save() -> void:
	if _save_backup.size() > 0:
		var f := FileAccess.open(Game.SAVE_PATH, FileAccess.WRITE)
		f.store_buffer(_save_backup)
		f.close()
	Game.player_name = _pname
	Game.team_name = _tname


func _ready() -> void:
	seed(20260921)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backup_save()
	_pname = Game.player_name
	_tname = Game.team_name
	Game.player_name = ""
	Game.team_name = ""
	await _run()
	_restore_save()
	var verdict := "PASS" if failures == 0 else "FAIL"
	print("---- E2E %s ---- %d checks, %d failures" % [verdict, checks, failures])
	get_tree().quit(0 if failures == 0 else 1)


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


## Drives a full station quiz through the real UI: answers every item
## correctly (submit → continue) and leaves the overlay in the DONE phase
## so the caller can click "Return to Map".
func _play_quiz(ov: Node, count: int) -> void:
	for i in count:
		if not is_instance_valid(ov):
			check("item %d overlay still alive" % (i + 1), false)
			return
		check("item %d in question phase" % (i + 1), int(ov.get("phase")) == 1, str(ov.get("phase")))
		var ans: int = ov.get("answer")
		_find_line_edit(ov).text = str(ans)
		_click(ov, "Submit Answer")
		await _wait(1)
		check("feedback after item %d" % (i + 1), int(ov.get("phase")) == 2, str(ov.get("phase")))
		_click(ov, "Continue")
		await _wait(1)


## Deterministically end the active adventure by exhausting the timer:
## headless runs unthrottled frames, so waiting on wall-clock would flake.
func _end_via_time() -> void:
	Game.time_left = 0.01
	await Game.adventure_ended
	await _wait(2)


func _run() -> void:
	_main_scene = preload("res://scenes/Main.tscn").instantiate()
	add_child(_main_scene)
	await _wait(4)

	print("== 1. boot to title ==")
	check("booted to title", _script_of(_screen(), "res://scripts/TitleScreen.gd"))
	check("start button present", _find_button(_screen(), "Start New Journey") != null)
	check("learn button present", _find_button(_screen(), "Learn") != null)
	check("board button present", _find_button(_screen(), "Leaderboard") != null)

	print("== 2. hero select ==")
	_click(_screen(), "Start New Journey")
	await _wait(3)
	var hero := _screen()
	check("reached hero select", _script_of(hero, "res://scripts/HeroSelectScreen.gd"))
	var name_field := _find_line_edit(hero)
	check("name field present", name_field != null)
	name_field.text = "E2E Hero"
	_find_button_tooltip(hero, "Adventurer #12").pressed.emit()
	_click(hero, "15 min")
	_click(hero, "Begin Adventure")
	await _wait(4)

	print("== 3. adventure map ==")
	var adv := _screen()
	check("reached adventure", adv.has_method("_try_enter_station"))
	check("island cells", int(adv.get("_land").size()) > 700, str(adv.get("_land").size()))
	check("three stations", (adv.get("_station_nodes") as Array).size() == 3)
	check("player spawned", adv.get("player") != null and adv.get("player").get_child_count() > 0)
	check("world y-sorted", (adv.get("world") as Node2D).y_sort_enabled)
	check("grass meta set", (adv.get("world") as Node2D).has_meta("grass"))

	# walk to station 1 and interact
	var stations: Array = adv.get("_station_nodes")
	var player: Node2D = adv.get("player")
	player.position = (stations[0] as Node2D).position
	adv.call("_try_enter_station")
	await _wait(3)
	var ov: Node = adv.get("_overlay")
	check("quiz overlay opened", ov != null)
	check("quiz panel built (intro)", not str(ov.get("phase")) == "" )

	print("== 4. station 1 quiz items ==")
	var gems0 := Game.gems
	check("start gems 50", Game.gems == Game.START_GEMS, str(Game.gems))
	# intro -> first question
	_click(ov, "Continue")
	await _wait(2)
	check("question phase", int(ov.get("phase")) == 1, str(ov.get("phase")))
	# item 1: correct
	var ans1: int = ov.get("answer")
	_find_line_edit(ov).text = str(ans1)
	_click(ov, "Submit Answer")
	await _wait(2)
	check("feedback after submit", int(ov.get("phase")) == 2, str(ov.get("phase")))
	check("correct gains +10", Game.gems == gems0 + 10, str(Game.gems))
	_click(ov, "Continue")
	await _wait(2)
	# item 2: wrong
	_find_line_edit(ov).text = "999"
	_click(ov, "Submit Answer")
	await _wait(2)
	check("wrong loses 5", Game.gems == gems0 + 5, str(Game.gems))
	_click(ov, "Continue")
	await _wait(2)
	# item 3: hint, then correct
	_click(ov, "Hint")
	await _wait(1)
	check("hint consumed", Game.hints_used == 1, str(Game.hints_used))
	var ans3: int = ov.get("answer")
	_find_line_edit(ov).text = str(ans3)
	_click(ov, "Submit Answer")
	await _wait(2)
	check("hint costs 5 then +10", Game.gems == gems0 + 10, str(Game.gems))
	_click(ov, "Continue")
	await _wait(2)
	# item 4: skip
	_click(ov, "Skip")
	await _wait(2)
	check("skip costs 15", Game.gems == gems0 - 5, str(Game.gems))
	check("advanced past skip feedback", int(ov.get("item_index")) == 5, str(ov.get("item_index")))

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
	check("back to title", _script_of(_screen(), "res://scripts/TitleScreen.gd"))
	_click(_screen(), "Learn")
	await _wait(3)
	check("learn shown", _script_of(_screen(), "res://scripts/LearnScreen.gd"))
	_click(_screen(), "Back")
	await _wait(3)
	check("back to title again", _script_of(_screen(), "res://scripts/TitleScreen.gd"))
	check("main backref wired", true)

	print("== 7. continue quest + pause menu ==")
	check("continue quest shown", _find_button(_screen(), "Continue Quest") != null)
	# With a profile saved, the title needs its own way back to hero creation.
	check("title new game shown", _find_button(_screen(), "New Game") != null)
	check("title quit shown", _find_button(_screen(), "Quit") != null)
	_click(_screen(), "New Game")
	await _wait(3)
	check("title new game opens hero select", _script_of(_screen(), "res://scripts/HeroSelectScreen.gd"))
	_click(_screen(), "Back")
	await _wait(3)
	_click(_screen(), "Continue Quest")
	await _wait(4)
	adv = _screen()
	check("reached adventure from continue", adv.has_method("_try_enter_station"))
	adv.call("_toggle_pause")
	await _wait(1)
	check("paused", bool(adv.get("_paused")))
	check("resume button", _find_button(adv, "Resume") != null)
	check("home button", _find_button(adv, "Home") != null)
	check("board button", _find_button(adv, "Leaderboard") != null)
	check("restart button", _find_button(adv, "Restart") != null)
	check("new game button", _find_button(adv, "New Game") != null)
	_click(adv, "Resume")
	await _wait(1)
	check("resumed", not bool(adv.get("_paused")))

	# Restart drops the run and starts a fresh one on a rebuilt map.
	Game.gems = 999
	Game.completed_stations[0] = true
	var rows_before: int = Game.leaderboard.size()
	adv.call("_toggle_pause")
	await _wait(1)
	_click(adv, "Restart")
	await _wait(4)
	adv = _screen()
	check("restart reopened the map", adv.has_method("_try_enter_station"))
	check("restart reset gems", Game.gems == Game.START_GEMS, str(Game.gems))
	check("restart reset stations", (Game.completed_stations as Array) == [false, false, false])
	check("restart scored nothing", Game.leaderboard.size() == rows_before)

	# New Game goes back to hero creation, also without scoring the run.
	adv.call("_toggle_pause")
	await _wait(1)
	_click(adv, "New Game")
	await _wait(4)
	check("new game reached hero select", _script_of(_screen(), "res://scripts/HeroSelectScreen.gd"))
	check("new game dropped the run", not Game.adventure_active)
	check("new game scored nothing", Game.leaderboard.size() == rows_before)
	_click(_screen(), "Back")
	await _wait(3)
	_click(_screen(), "Continue Quest")
	await _wait(4)
	adv = _screen()
	check("back on the map", adv.has_method("_try_enter_station"))
	adv.call("_toggle_pause")
	await _wait(1)
	_click(adv, "Leaderboard")
	await _wait(3)
	check("leaderboard from pause", _script_of(_screen(), "res://scripts/LeaderboardScreen.gd"))
	_click(_screen(), "Back")
	await _wait(3)
	check("back to title", _script_of(_screen(), "res://scripts/TitleScreen.gd"))

	print("== 8. hero select variations ==")
	Game.player_name = ""
	Game.team_name = ""
	_main_scene.call("open", "title")
	await _wait(3)
	check("start button without profile", _find_button(_screen(), "Start New Journey") != null)
	_click(_screen(), "Start New Journey")
	await _wait(3)
	hero = _screen()
	for id in [1, Game.HERO_COUNT]:
		check("adventurer #%d present" % id, _find_button_tooltip(hero, "Adventurer #%d" % id) != null)
	for dur in ["5 min", "10 min", "15 min"]:
		check("duration %s present" % dur, _find_button(hero, dur) != null)
	_find_button_tooltip(hero, "Adventurer #7").pressed.emit()
	check("hero local set", int(hero.get("_hero_id")) == 7, str(hero.get("_hero_id")))
	_click(hero, "5 min")
	check("duration local set", int(hero.get("_duration")) == 300, str(hero.get("_duration")))
	_click(hero, "Back")
	await _wait(3)
	check("hero back to title", _script_of(_screen(), "res://scripts/TitleScreen.gd"))
	_click(_screen(), "Start New Journey")
	await _wait(3)
	hero = _screen()
	var name2 := _find_line_edit(hero)
	check("name field present", name2 != null)
	name2.text = "E2E Hero"
	# re-pick after the screen was recreated (Back discarded the locals)
	_find_button_tooltip(hero, "Adventurer #7").pressed.emit()
	_click(hero, "5 min")
	_click(hero, "Begin Adventure")
	await _wait(4)
	check("reached adventure (hero 7 / 5min)", _screen().has_method("_try_enter_station"))
	check("hero 7 persisted", Game.hero_id == 7, str(Game.hero_id))
	check("duration 300 persisted", Game.duration_seconds == 300, str(Game.duration_seconds))
	adv = _screen()
	adv.call("_toggle_pause")
	await _wait(1)
	_click(adv, "Home")
	await _wait(4)
	check("home lands on title", _script_of(_screen(), "res://scripts/TitleScreen.gd"))
	check("home ends adventure", not Game.adventure_active)
	var res8: Dictionary = Game.last_run
	check("unfinished penalty recorded (25)", int(res8.get("gems", 0)) == 25, str(res8.get("gems")))

	print("== 9. summary buttons / natural end ==")
	_click(_screen(), "Continue Quest")
	await _wait(4)
	check("adventure again (fresh)", Game.adventure_active and Game.gems == Game.START_GEMS, str(Game.gems))
	await _end_via_time()
	sum = _screen()
	check("summary after time up", _script_of(sum, "res://scripts/SummaryScreen.gd"))
	var res9: Dictionary = Game.last_run
	check("time_up flagged", res9.get("time_up", false))
	check("penalty applied (25)", int(res9.get("gems", 0)) == 25, str(res9.get("gems")))
	_click(sum, "Adventure again")
	await _wait(4)
	check("adventure again reached", _screen().has_method("_try_enter_station"))
	await _end_via_time()
	sum = _screen()
	check("summary again", _script_of(sum, "res://scripts/SummaryScreen.gd"))
	_click(sum, "Home")
	await _wait(3)
	check("summary home to title", _script_of(_screen(), "res://scripts/TitleScreen.gd"))
	_click(_screen(), "Leaderboard")
	await _wait(3)
	check("board reachable", _script_of(_screen(), "res://scripts/LeaderboardScreen.gd"))
	check("board non-empty", not (Game.leaderboard.is_empty()))
	_click(_screen(), "Back")
	await _wait(3)
	check("board back to title", _script_of(_screen(), "res://scripts/TitleScreen.gd"))

	print("== 10. complete all three stations via the UI ==")
	_click(_screen(), "Continue Quest")
	await _wait(4)
	adv = _screen()
	check("fresh adventure", Game.adventure_active and Game.gems == Game.START_GEMS, str(Game.gems))
	check("all stations locked", (Game.completed_stations as Array) == [false, false, false])
	player = adv.get("player") as Node2D
	stations = adv.get("_station_nodes") as Array
	var p0: Vector2 = (stations[0] as Node2D).position
	var p1: Vector2 = (stations[1] as Node2D).position
	var p2: Vector2 = (stations[2] as Node2D).position
	check("stations distinct cells", p0 != p1 and p1 != p2 and p0 != p2, "%s / %s / %s" % [p0, p1, p2])
	for s in 3:
		player.position = (stations[s] as Node2D).position
		adv.call("_try_enter_station")
		await _wait(3)
		var ov2: Node = adv.get("_overlay")
		check("station %d overlay opened" % (s + 1), ov2 != null)
		_click(ov2, "Continue")
		await _wait(1)
		if s == 0:
			var rescue := _find_button(ov2, "Rescue")
			check("rescue present", rescue != null)
			check("rescue disabled", rescue != null and rescue.disabled)
		var items: int = Game.ITEMS_PER_STATION[s]
		await _play_quiz(ov2, items)
		_click(ov2, "Return to Map")
		await _wait(3)
		# Clearing the last station ends the adventure, which frees the map.
		if s < 2:
			check("station %d returned to map" % (s + 1), adv.get("_overlay") == null)
		check("station %d complete" % (s + 1), Game.completed_stations[s])
		check("station %d perfect" % (s + 1), Game.perfect_stations[s])
	check("all stations complete", (Game.completed_stations as Array) == [true, true, true])
	check("perfect gems 480 (40 correct + 3 perfect bonuses)", Game.gems == 480, str(Game.gems))
	check("adventure ended on the last station", not Game.adventure_active)
	sum = _screen()
	check("summary after full run", _script_of(sum, "res://scripts/SummaryScreen.gd"))
	var res10: Dictionary = Game.last_run
	check("finished_all", res10.get("finished_all", false))
	check("no penalty (480)", int(res10.get("gems", 0)) == 480, str(res10.get("gems")))
	check("40 correct", int(res10.get("correct", 0)) == 40, str(res10.get("correct")))
	check("0 wrong/skip/hint", int(res10.get("wrong", 0)) == 0 and int(res10.get("skipped", 0)) == 0 and int(res10.get("hints", 0)) == 0)
	_click(sum, "Home")
	await _wait(3)
	check("title after full run", _script_of(_screen(), "res://scripts/TitleScreen.gd"))

	print("== 11. learn tabs ==")
	_click(_screen(), "Learn")
	await _wait(3)
	var learn := _screen()
	var lessons := [
		["Basic Operations", "operation"],
		["Exponential Notation", "exponent"],
		["Order of Operations", "pemdas"],
	]
	for l in lessons:
		_click(learn, l[0])
		await _wait(1)
		var content_label: Label = learn.get("_content")
		check("%s lesson shown" % l[0], content_label != null and String(content_label.text).to_lower().contains(l[1]))
	_click(learn, "Back")
	await _wait(3)
	check("learn back to title", _script_of(_screen(), "res://scripts/TitleScreen.gd"))
extends TestCase
## A Practice match end to end (DESIGN.md 3): walk to a monk, a wrong answer
## locks it, the right one is carried and the monk turns your colour; deposit
## at the Monastery; every word deposited finishes the match into the results;
## and the clock running out loses what was still carried.
##   godot --headless res://scripts/tests/match_test.tscn

var main: Control


func frames(n := 2) -> void:
	for i in n:
		await get_tree().process_frame


func screen() -> Control:
	return main.current


## Type `text` on the open panel's keypad, glyph by glyph.
func type_on(overlay: Control, text: String) -> void:
	for i in text.length():
		overlay._keypad.press(text[i])


## The hero beside monk `i`, on the clearing south of him.
func stand_at_monk(s: Control, i: int) -> void:
	s.player.position = s.world.monks[i].position + Vector2(0, 24)


func _ready() -> void:
	backup_save()
	main = load("res://scripts/Main.gd").new()
	add_child(main)
	main.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	main.open("adventure", {"practice": true})
	await frames(4)
	var s := screen()
	check("Practice opens the match screen", s.get_script().resource_path == "res://scripts/AdventureScreen.gd")
	check("it opens on the aerial view", s._frozen)
	check("Practice starts with a fifteen-minute clock", Game.duration_seconds == 900.0 and s.hud._time.text == "15:00")
	s.skip_intro()
	await frames()
	var play: Match = s.play
	check("ten monks, ten words", s.world.monks.size() == 10 and play.words.size() == 10)
	check("the hero starts at Blue's spawn", s.player.position == s.world.spawn_of(0))
	check("the score reads 0 of 10", _score(s).contains("0 / 10"), _score(s))

	stand_at_monk(s, 0)
	check("the hero can stand beside a monk", s.grid.box_walkable(s.player.position, s.hero_box))
	s._update_interaction()
	check("beside a monk, the prompt offers his word", s.hud.prompt.text.contains("write this monk's word"),
		s.hud.prompt.text)
	s._try_monk(0)
	await frames()
	var overlay: Control = s._overlay
	check("pressing E opens his word and the keypad", overlay != null and overlay.word == play.words[0])
	check("Practice shows the Latin labels", overlay != null and overlay.labels)
	type_on(overlay, "ᜀ")
	await overlay._on_submit()
	check("a wrong answer locks him", overlay._submit.disabled and not play.ours(0))
	overlay._locked_until = 0.01
	await frames()
	type_on(overlay, str(play.words[0].modern))
	await overlay._on_submit()
	check("the right answer is carried", play.ours(0) and play.carried() == [0] and play.deposited() == 0)
	check("the monk turns Blue", s.world.monks[0].colour == "Blue")
	check("the HUD says one carried", (s.hud._carry as Label).text == "Carry 1")
	await get_tree().create_timer(1.4).timeout
	check("the panel closes itself", s._overlay == null)
	s._update_interaction()
	check("the monk's word is the team's now", s.hud.prompt.text.contains("Your team has"), s.hud.prompt.text)

	s.player.position = s.world.door()
	s._update_interaction()
	check("at the Monastery, deposit is offered", s.hud.prompt.text.contains("deposit 1 word"), s.hud.prompt.text)
	await s._deposit()
	check("depositing banks it", play.deposited() == 1 and play.carried().is_empty())
	check("the score reads 1 of 10", _score(s).contains("1 / 10"), _score(s))
	# The flash of the deposit owns the line a moment; what it says next:
	var next: String = s._prompt_for(s._nearest_target())
	check("nothing left to deposit is said", next.contains("Nothing to deposit"), next)

	for i in range(1, 10):
		check("monk %d's own spelling is correct" % i, await play.answer(i, str(play.words[i].modern)) == "correct")
	await s._deposit()
	check("every word deposited finishes the match", s._ending and play.winner == 0)
	await get_tree().create_timer(4.6).timeout
	var r := screen()
	check("then the results open", r.get_script().resource_path == "res://scripts/ResultsScreen.gd")
	var words: Array = r.result.get("words", [])
	check("they list all ten words, all deposited", words.size() == 10
		and words.all(func(w: Dictionary) -> bool: return w.state == "deposited"))
	check("with their Baybayin", words.all(func(w: Dictionary) -> bool: return str(w.modern) != ""))
	var labels: Array = r.find_children("*", "Label", true, false).map(func(l: Label) -> String: return l.text)
	check("results display Filipino and Baybayin without English meanings", words.all(func(w: Dictionary) -> bool:
		return labels.has(str(w.word)) and labels.has(str(w.modern)) and not labels.has(str(w.meaning))))

	# Time up with a word still carried: lost.
	main.open("adventure", {"practice": true})
	await frames(4)
	s = screen()
	s.skip_intro()
	await frames()
	play = s.play
	await play.answer(3, str(play.words[3].modern))
	Game.time_left = 0.2
	await get_tree().create_timer(0.6).timeout
	check("the clock running out ends the match", s._ending)
	await get_tree().create_timer(4.6).timeout
	r = screen()
	var lost: Array = (r.result.get("words", []) as Array).filter(func(w: Dictionary) -> bool: return w.state == "lost")
	check("a word still carried at the end is lost", r.get_script().resource_path == "res://scripts/ResultsScreen.gd"
		and lost.size() == 1 and bool(r.result.time_up))
	_online_rows()
	_online_standings()
	completed = true
	finish("MATCH")


## Online the rows come off the socket (`monk_answers`): what a teammate
## answered is ours, what I carry is mine, deposits count per team, and the
## other team's answers never colour our monks.
func _online_rows() -> void:
	var was_user: String = Net.user_id
	Net.user_id = "me"
	var m := Match.new()
	m.practice = false
	m.words = Baybayin.draw(10, RandomNumberGenerator.new())
	m.team_ids.assign(["blue-id", "red-id"])
	m.team = 0
	m.take_row("INSERT", {"team_id": "blue-id", "monk": 3, "profile_id": "me", "deposited_at": null})
	check("online: my answer is carried", m.ours(3) and m.carried() == [3])
	m.take_row("INSERT", {"team_id": "blue-id", "monk": 5, "profile_id": "ana", "deposited_at": null})
	check("online: a teammate's answer greys that monk out for me too", m.ours(5) and m.carried() == [3])
	m.take_row("INSERT", {"team_id": "red-id", "monk": 7, "profile_id": "red1", "deposited_at": null})
	check("online: the other team's answer is not ours", not m.ours(7))
	m.take_row("UPDATE", {"team_id": "blue-id", "monk": 3, "profile_id": "me", "deposited_at": "2026-10-23T10:00:00+00:00"})
	m.take_row("UPDATE", {"team_id": "red-id", "monk": 7, "profile_id": "red1", "deposited_at": "2026-10-23T10:00:05+00:00"})
	check("online: deposits count per team", m.deposited(0) == 1 and m.deposited(1) == 1 and m.carried().is_empty())
	check("online: and mine are mine", m.my_deposits() == 1)
	m.take_row("INSERT", {"team_id": "stranger", "monk": 1, "profile_id": "x"})
	check("online: a row from no team of this match is ignored", not m.ours(1) and m.answers.size() == 3)
	Net.user_id = was_user


## A timed-out match has no winner_team: SQL returns null, not false, for
## team_standings.finished. Parse that live response and rank by deposits/time.
func _online_standings() -> void:
	var results_script := load("res://scripts/ResultsScreen.gd")
	var start := float(Time.get_unix_time_from_datetime_string("2026-10-23T10:00:00"))
	var blue: Dictionary = results_script._team_standing({"name": "Blue", "deposited": 1,
		"finished": null, "reached_at": "2026-10-23T10:00:30+00:00"}, 0, start)
	var red: Dictionary = results_script._team_standing({"name": "Red", "deposited": 1,
		"finished": null, "reached_at": "2026-10-23T10:00:20+00:00"}, 1, start)
	check("online results: null finished parses as false", blue.finished == false and red.finished == false)
	var ordered: Array = results_script.ranked([blue, red])
	check("online results: timeout standings break equal deposits by time", ordered[0].name == "Red")
	red.deposited = 0
	red.reached_s = -1.0
	ordered = results_script.ranked([red, blue])
	check("online results: deposited words outrank an empty team", ordered[0].name == "Blue")
	# Ranking also tolerates nullable or absent flags, while true still wins.
	ordered = results_script.ranked([
		{"name": "unfinished", "finished": null, "deposited": 2, "reached_s": 10.0},
		{"name": "finished", "finished": true, "deposited": 1, "reached_s": 30.0},
		{"name": "player", "deposited": 1, "reached_s": 20.0}])
	check("online results: only true marks a finisher, and missing flags are safe",
		ordered[0].name == "finished" and ordered[1].name == "unfinished" and ordered[2].name == "player")


func _score(s: Control) -> String:
	var rib: Node = s.hud._score_box.get_child(0) if s.hud._score_box.get_child_count() > 0 else null
	if rib == null:
		return ""
	var labels := rib.find_children("*", "Label", true, false)
	return " ".join(labels.map(func(l: Label) -> String: return l.text))

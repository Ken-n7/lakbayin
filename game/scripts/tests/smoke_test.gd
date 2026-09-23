extends TestCase
## Headless smoke test for the question generator, gems economy and leaderboard.
## Run with:  godot --headless res://scripts/tests/smoke_test.tscn
## Exits nonzero if any check fails.



func _count_name(rows: Array, name: String) -> int:
	var n := 0
	for r in rows:
		if str(r.name) == name:
			n += 1
	return n


func _ready() -> void:
	seed(20240913)   # deterministic generator output for repeatable runs
	process_mode = Node.PROCESS_MODE_ALWAYS
	backup_save()
	_t_generator()
	_t_scoring()
	_t_perfect_bonus()
	_t_skip_and_penalty()
	_t_leaderboard()
	completed = true
	finish("SMOKE")


func _t_generator() -> void:
	print("== question generator ==")
	for station in 3:
		var n: int = Game.ITEMS_PER_STATION[station]
		var seen: Dictionary = {}
		var dups := 0
		for i in n:
			var q := QuestionGen.item_for_station(station, i)
			check("station %d prompt non-empty" % (station + 1), str(q.prompt) != "")
			check("station %d answer is int" % (station + 1), q.answer is int, str(q.answer))
			check("station %d rule present" % (station + 1), not str(q.rule).is_empty())
			var key := "%s:%s" % [str(q.prompt), q.answer]
			if seen.has(key):
				dups += 1
			else:
				seen[key] = true
		# some repeat is inevitable (small sample spaces); just ban degenerate output
		check("station %d not degenerate duplicates" % (station + 1), dups <= 3, str(dups))
	# spot-check computed answers against direct re-computation
	var a := QuestionGen.item_for_station(0, 0)
	check("basic add 8+(-3)=5", int(a.answer) == 5, str(a.answer))
	var b := QuestionGen.item_for_station(2, 1)
	check("exponent is perfect square", is_sqrt(int(b.answer)), str(b.answer))
	var c := QuestionGen.item_for_station(1, 0)
	check("pemdas is int", c.answer is int, str(c.answer))


func is_sqrt(v: int) -> bool:
	var r := int(sqrt(float(v)))
	return r * r == v


func _t_scoring() -> void:
	print("== gems economy ==")
	Game.begin_adventure(300)
	check("start gems 50", Game.gems == Game.START_GEMS, str(Game.gems))
	Game.mark_correct()
	check("correct +10", Game.gems == Game.START_GEMS + 10, str(Game.gems))
	Game.mark_correct()
	Game.mark_wrong()
	check("wrong -5", Game.gems == Game.START_GEMS + 10 + 10 - 5, str(Game.gems))
	var spent := Game.spend_hint()
	check("hint spent once", spent and Game.hints_used == 1, str(Game.hints_used))
	check("hint -5", Game.gems == Game.START_GEMS + 10 + 10 - 5 - 5, str(Game.gems))


func _t_perfect_bonus() -> void:
	print("== perfect station bonus ==")
	Game.begin_adventure(300)
	Game.mark_correct()
	var before := Game.gems
	var bonus := Game.finish_station(0)
	check("perfect bonus +10", bonus == 10, str(bonus))
	check("bonus applied", Game.gems == before + 10, str(Game.gems))
	check("station flagged perfect", Game.perfect_stations[0])
	check("station completed", Game.completed_stations[0])
	# next station reached
	check("next station index", Game.completed_stations.find(false) == 1)


func _t_skip_and_penalty() -> void:
	print("== skip and finish penalty ==")
	Game.begin_adventure(300)
	Game.mark_skipped()
	check("skip -15", Game.gems == Game.START_GEMS - 15, str(Game.gems))
	Game.end_adventure()
	check("unfinished penalty -25", Game.gems == Game.START_GEMS - 15 - 25, str(Game.gems))
	check("adventure stopped", not Game.adventure_active)
	check("result recorded", Game.last_run.has("gems") and Game.last_run.has("correct"), str(Game.last_run))


func _t_leaderboard() -> void:
	print("== leaderboard ==")
	Game.team_name = "First Team"
	Game.begin_adventure(300)
	Game.mark_correct()
	Game.end_adventure()
	# Two runs under different team names: one row each, best first. It used to
	# take two rows for granted because four invented rival teams padded the
	# board -- they are gone, so the test makes its own.
	Game.team_name = "Second Team"
	Game.begin_adventure(300)
	Game.mark_correct()
	Game.mark_correct()
	Game.end_adventure()
	var rows := Game.leaderboard
	check("rows sorted desc", rows.size() >= 2 and int(rows[0].gems) >= int(rows[1].gems), str(rows))
	check("no duplicate entry", _count_name(rows, Game.player_name) <= 1, str(Game.player_name))
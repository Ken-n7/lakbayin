extends SceneTree

## Self-check for the gems rules. Run:
##   godot --headless --path game --script res://test_rules.gd

func _init() -> void:
	var G: Node = load("res://scripts/Game.gd").new()
	G.begin_adventure(600)
	assert(G.gems == 50, "starts at 50")

	# Fix #3: one hint per ITEM, -5 each -- not one per station.
	G.begin_item()
	assert(G.spend_hint() == true, "first hint of item 1 lands")
	assert(G.spend_hint() == false, "second hint on the SAME item is refused")
	assert(G.gems == 45, "one -5, not two: %d" % G.gems)
	G.begin_item()
	assert(G.spend_hint() == true, "hint works again on the next item")
	assert(G.gems == 40, "second item's hint charged: %d" % G.gems)
	assert(G.hints_used == 2, "both hints counted")

	# A hint anywhere in the station still forfeits the perfect bonus.
	assert(G.finish_station(0) == 0, "hinted station earns no bonus")
	assert(G.completed_stations[0] == true)
	assert(G.item_used_hint == false and G.station_used_hint == false, "flags reset")

	# Clean station -> +10 bonus.
	G.begin_item(); G.mark_correct()
	assert(G.finish_station(1) == 10, "flawless station pays the bonus")
	assert(G.gems == 60, "40 +10 correct +10 bonus: %d" % G.gems)

	# Wrong/skip spoil it.
	G.begin_item(); G.mark_wrong()
	assert(G.finish_station(2) == 0, "a wrong answer kills the bonus")

	# Fix #1's condition: all three done is detectable.
	assert(G.completed_stations.all(func(v: bool) -> bool: return v), "all complete")

	# Finishing everything must NOT trigger the -25 incomplete penalty.
	var before: int = G.gems
	G.end_adventure()
	assert(G.gems == before, "no -25 when every station is done: %d -> %d" % [before, G.gems])
	assert(G.last_run.finished_all == true)

	# One row per team, however many runs are saved. The four invented rival
	# parties are gone -- a board the client reads as a result should not be
	# padded with teams that never played.
	G.player_name = "Ken"
	for run in 3:
		G._register_leaderboard("Ken", 200 + run)
	var seen := {}
	for row in G.leaderboard:
		assert(not seen.has(row.name), "duplicate leaderboard row: %s" % row.name)
		seen[row.name] = true
	assert(seen.has("Ken"), "the player's own run is listed")
	assert(G.leaderboard.size() == 1, "only real runs: %d rows" % G.leaderboard.size())
	assert(int(G.leaderboard[0].gems) == 202, "best run kept: %d" % int(G.leaderboard[0].gems))

	# Fix #8: no item should demand five-digit arithmetic.
	var QG := load("res://scripts/QuestionGen.gd")
	for station in [1, 2]:
		var worst := 0
		for i in 600:
			var item: Dictionary = QG.item_for_station(station, i)
			worst = maxi(worst, absi(int(item.answer)))
		assert(worst <= 400, "station %d answers stay sane, worst was %d" % [station + 1, worst])
		print("station %d worst answer over 600 items: %d" % [station + 1, worst])

	# The mockups order the stations Basics / Order of Operations / Exponents.
	assert(QG.station_meta(1).short == "Order of Operations", "S2 is order of operations")
	assert(QG.station_meta(2).short == "Exponential Notation", "S3 is exponents")
	assert(QG.item_for_station(2, 1).topic == "exp", "S3 items are exponents")
	assert(QG.item_for_station(1, 0).topic == "pemdas", "S2 items are PEMDAS")

	# The pixel font has no tick/star/arrow; without the symbol fallback the HUD
	# pips and Learn screen arrows silently render as blank boxes.
	var A := load("res://scripts/Art.gd")
	A.apply_font_fallback()
	var f := load(A.PIXEL_FONT) as FontFile
	assert(f.fallbacks.size() == 1, "symbol fallback attached")
	for ch in ["\u2713", "\u2605", "\u25b6", "\u2192"]:
		assert(f.has_char(ch.unicode_at(0)), "font resolves %s via fallback" % ch)
	for ch in ["\u00b2", "\u00b3", "\u2212", "\u00d7", "\u00f7"]:
		assert(f.has_char(ch.unicode_at(0)), "font resolves %s" % ch)
	print("font: superscripts and marks all resolve")

	# BigRibbons has 20px of gutter above its first row; slicing it by
	# width/cols cut straight through the flag.
	var rib: AtlasTexture = A.cell("res://assets/ui/BigRibbons.png", 0, 1)
	assert(rib.region == Rect2(30, 148, 98, 103), "ribbon cell (0,1) cropped clean, got %s" % rib.region)
	print("ribbon cell: %s" % rib.region)

	# --- The shared clock ---------------------------------------------------
	# The admin's session row is what the clock reads, so it is worth pinning
	# down offline: these are the four states a phone can arrive into.
	var now := int(Time.get_unix_time_from_system())
	var deadline := Time.get_datetime_string_from_unix_time(now + 300) + "Z"

	G.apply_session({"state": "lobby", "duration_s": 600})
	assert(G.clock_paused, "lobby does not run the clock")
	assert(is_equal_approx(G.time_left, 600.0), "lobby shows the full duration: %f" % G.time_left)

	G.apply_session({"state": "running", "duration_s": 600, "ends_at": deadline})
	assert(not G.clock_paused, "running releases the clock")
	assert(absf(G.time_left - 300.0) < 3.0,
		"running reads the deadline, not the duration: %f" % G.time_left)

	# A pause hands back what it banked -- not what this phone had counted to,
	# which is the whole reason the number lives on the server.
	G.apply_session({"state": "paused", "duration_s": 600, "remaining_s": 123})
	assert(G.clock_paused, "paused stops the clock")
	assert(is_equal_approx(G.time_left, 123.0), "paused reads remaining_s: %f" % G.time_left)

	G.apply_session({"state": "ended", "duration_s": 600})
	assert(G.clock_paused and G.time_left == 0.0, "ended is zero and stopped")
	assert(G.session_state == "ended", "state recorded")

	# A phone joining after the deadline gets zero, never a negative countdown.
	G.apply_session({"state": "running", "duration_s": 600,
		"ends_at": Time.get_datetime_string_from_unix_time(now - 60) + "Z"})
	assert(G.time_left == 0.0, "a passed deadline clamps at zero: %f" % G.time_left)
	print("clock: lobby / running / paused / ended all read the session")

	# The countdown reads the deadline, not the frames. Two boards that drew
	# a different number of frames -- one in the background -- show one time.
	G.adventure_active = true
	G.apply_session({"state": "running", "duration_s": 600, "ends_at": deadline})
	var at_start: float = G.time_left
	for _i in 50:
		G._process(1.0)            # fifty "seconds" of frames, no time passed
	assert(absf(G.time_left - at_start) < 1.0,
		"frames moved the clock: %f -> %f" % [at_start, G.time_left])
	# A device whose clock is 4 minutes fast is told so by the server, and
	# reads the same deadline as everyone else.
	G.clock_offset = -240.0
	G.apply_session({"state": "running", "duration_s": 600, "ends_at": deadline})
	assert(absf(G.time_left - 540.0) < 3.0, "offset ignored: %f" % G.time_left)
	G.clock_offset = 0.0
	# Resuming after a pause starts from what was left, not from the old deadline.
	G.clock_paused = true
	G.time_left = 100.0
	G.clock_paused = false
	G._process(0.0)
	assert(absf(G.time_left - 100.0) < 1.0, "resume jumped: %f" % G.time_left)
	G.adventure_active = false
	assert(G.http_date("Thu, 25 Sep 2026 10:11:56 GMT")
		== Time.get_unix_time_from_datetime_string("2026-09-25T10:11:56"), "Date header parse")
	assert(G.http_date("garbage") == 0, "a bad Date is ignored")
	print("clock: deadline-driven, server-corrected, frame rate irrelevant")

	# Only a running session scores; offline ("") always does.
	G.apply_session({"state": "paused", "duration_s": 600, "remaining_s": 60})
	assert(not G.can_score(), "a paused session refuses answers")
	G.apply_session({"state": "running", "duration_s": 600, "ends_at": deadline})
	assert(G.can_score(), "a running session takes them")
	G.begin_adventure(600)
	assert(G.session_state == "" and G.session_id == "", "a new run forgets the last session")
	assert(G.can_score(), "offline scores")

	# A rejoin picks up the server's row: circle 10 is station 2's third item.
	var R: Node = load("res://scripts/Game.gd").new()
	R.begin_adventure(600)
	R.restore_from({"gems": 72, "correct": 7, "items_done": 10, "eliminated": false})
	assert(R.gems == 72 and R.items_done == 10 and R.correct == 7, "row restored")
	assert(R.current_station == 1, "on station 2: %d" % R.current_station)
	assert(R.completed_stations == [true, false, false], "station 1 done")
	assert(R.towers_entered == [true, true, false], "briefings 1 and 2 read")
	R.free()
	print("session: pause refuses, rejoin restores")

	# --- Elimination --------------------------------------------------------
	# The paper: "Eliminated Member (reaching 0 gems): -50 gems". It could
	# never fire while gems floored at zero, which they did until now.
	var E: Node = load("res://scripts/Game.gd").new()
	E.begin_adventure(600)
	assert(not E.eliminated, "nobody starts eliminated")
	for i in 10:
		E.begin_item()
		E.mark_wrong()          # -5 each: 50 -> 0
	assert(E.gems == 0, "ten wrong answers reach exactly zero: %d" % E.gems)
	assert(E.eliminated, "reaching zero eliminates")

	# Gems go past zero rather than sticking, and the team is charged once.
	E.begin_item()
	E.mark_wrong()
	assert(E.gems == -5, "gems do not clamp: %d" % E.gems)
	assert(E.eliminated, "still eliminated, not re-eliminated")

	# A hint with no gems left is still allowed -- the cost is the point, and
	# refusing it used to be an accident of the clamp rather than a rule.
	E.begin_item()
	assert(E.spend_hint(), "a hint is affordable even at zero")
	print("elimination: fires at zero, latches, and gems run negative")

	# --- Everyone else on the board -----------------------------------------
	# `items_done` is the position: a player who has answered three items
	# stands at circle three, and one who has finished stands at the gate.
	var P: Node2D = load("res://scripts/map/Peers.gd").new()
	var anchors: Array = []
	for i in 14:
		anchors.append(Vector2(i * 100, 0))
	var gate := Vector2(9999, 0)
	var rows: Array = [
		{"profile_id": "me", "username": "me", "team_id": "a", "items_done": 5},
		{"profile_id": "b", "username": "bea", "team_id": "a", "items_done": 3},
		{"profile_id": "c", "username": "cy", "team_id": "z", "items_done": 14},
		{"profile_id": "d", "username": "dee", "team_id": "z", "items_done": 0,
			"eliminated": true},
	]
	P.refresh(rows, anchors, gate, "me")
	assert(P.get_child_count() == 3, "the player themselves is not a marker: %d" % P.get_child_count())
	var spots := {}
	for m in P.get_children():
		spots[(m as Node2D).position] = true
	assert(spots.has(Vector2(300, 0)), "three items done stands at circle three")
	assert(spots.has(gate), "everything done stands at the gate")
	assert(spots.has(Vector2(0, 0)), "nothing done stands at the first circle")

	# Two teams, two colours, and the same team keeps its colour.
	assert(P._colour("a") == P._colour("a"), "a team's colour is stable")
	assert(P._colour("a") != P._colour("z"), "two teams read apart")

	# A live position beats the circle: bea is standing on the road, not on 3.
	P.move("b", {"x": 555.0, "y": 77.0, "face": "left", "moving": true, "hero": 4})
	P.refresh(rows, anchors, gate, "me")
	# Heading there, not snapped: `_process` walks the hero onto it frame by frame.
	assert(P._is_live("b") and P._live_pos("b") == Vector2(555, 77),
		"a live hero heads where it was sent: %s" % P._live_pos("b"))
	P._process(1.0)
	assert(P._markers["b"].position == Vector2(555, 77),
		"and gets there: %s" % P._markers["b"].position)
	P.move("new", {"x": 1.0, "y": 2.0, "name": "late", "team": "z"})
	assert(P._markers.has("new"), "someone the roster has not caught up with still appears")
	P.move("me", {"x": 1.0, "y": 2.0})
	assert(not P._markers.has("me"), "your own echo is not a second you")

	# Drawn in the past, between two positions: halfway in time is halfway there,
	# and past the newest it walks on only briefly.
	var PeersScript: GDScript = load("res://scripts/map/Peers.gd")
	var trail := {"samples": [
		{"ts": 1.0, "pos": Vector2(0, 0), "vel": Vector2(100, 0), "face": "right", "moving": true},
		{"ts": 1.2, "pos": Vector2(20, 0), "vel": Vector2(100, 0), "face": "right", "moving": true}]}
	assert(PeersScript._sample_at(trail, 1.1).pos == Vector2(10, 0), "interpolates between positions")
	assert(PeersScript._sample_at(trail, 1.3).pos.is_equal_approx(Vector2(30, 0)), "walks on past the newest")
	assert(PeersScript._sample_at(trail, 9.0).pos.is_equal_approx(Vector2(50, 0)), "but only for PREDICT_S")

	# A refresh updates heroes where they stand rather than rebuilding them --
	# rebuilding reset every walk cycle on every answer anyone gave.
	var bea_before: Node2D = P._markers["b"]
	P.refresh(rows, anchors, gate, "me")
	assert(P._markers["b"] == bea_before, "a refresh keeps the same hero")

	# Somebody who leaves the session leaves the board. "new" stays: known only
	# from live positions, it goes when those stop.
	P.refresh(rows.slice(0, 2), anchors, gate, "me")
	assert(not P._markers.has("c") and not P._markers.has("d"), "left the session, left the board")
	assert(P._markers.has("b") and P._markers.has("new"), "the rest stay: %s" % str(P._markers.keys()))
	print("peers: markers stand where items_done says, and leave when the player does")

	print("test_rules: all assertions passed")
	quit()

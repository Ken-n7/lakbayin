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

	print("test_rules: all assertions passed")
	quit()

extends TestCase
## The players' Leaderboards (client, 2026-09-27): every team of every finished
## game in one list, best first; tap a team to see who played for it. The real
## screen throughout; only its two network calls are stood in for. The view
## behind them is supabase/test/leaderboard_test.sql.
##   godot --headless res://scripts/tests/alltime_test.tscn

const ME := "me-id"

var _board := {"error": "", "rows": []}
var _team := {"error": "", "rows": []}
var _board_calls := 0
var _team_asked: Array = []
var _opened: Array = []     # what the stand-in Main was asked to open


## Main, as far as a screen's ← needs it.
class FakeMain extends Control:
	var opened: Array
	func open(what: String, _data := {}) -> void:
		opened.append(what)


func frames(n := 3) -> void:
	for i in n:
		await get_tree().process_frame


func row(team: String, name: String, gems: int, game: int, members := 5, ids: Array = []) -> Dictionary:
	return {"team_id": team, "session_id": "s%d" % game, "name": name, "gems": gems,
		"members": members, "game_no": game, "played_at": "2026-09-%02dT09:00:00Z" % (19 + game % 10),
		"player_ids": ids}


## Game 1's four teams, then Game 2's: the client's own example, merged.
func two_games() -> Array:
	return [
		row("t5", "Team 5", 26, 2),
		row("t1", "Team 1", 25, 1, 5, [ME, "ana"]),
		row("t6", "Team 6", 24, 2),
		row("t2", "Team 2", 20, 1),
		row("t7", "Team 7", 18, 2, 1),
		row("t3", "Team 3", 15, 1),
		row("t8", "Team 8", -30, 2),
		row("t4", "Team 4", -75, 1),
	]


func board(offline := false) -> Control:
	var b: Control = load("res://scripts/AllTimeBoard.gd").new()
	b.fetch_board = func() -> Dictionary:
		_board_calls += 1
		await get_tree().process_frame
		return _board
	b.fetch_team = func(team_id: String) -> Dictionary:
		_team_asked.append(team_id)
		await get_tree().process_frame
		return _team
	b.me = ME
	b.offline = offline
	var m := FakeMain.new()
	m.opened = _opened
	b.main = m
	add_child(b)
	b.setup({})
	await frames(4)
	return b


func node(root: Node, path: String) -> Node:
	return root.find_child(path, true, false)


func text_of(root: Node, path: String) -> String:
	var l := node(root, path) as Label
	return "" if l == null else l.text


func visible_text(root: Node, contains: String) -> String:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text.contains(contains) and (l as Label).is_visible_in_tree():
			return (l as Label).text
	return ""


func teams(b: Control) -> Array:
	return b.find_children("Team_*", "Button", true, false)


func gems_of(card: Node) -> String:
	for l in node(card, "Gems").find_children("*", "Label", true, false):
		if (l as Label).text.is_valid_int():
			return (l as Label).text
	return ""


func _ready() -> void:
	backup_save()
	Net.user_id = ""
	await frames(2)
	await _states()
	await _list()
	await _your_teams()
	await _team_panel()
	await _routing()
	completed = true
	finish("ALLTIME")


func _states() -> void:
	print("-- loading, empty, error, offline")
	_board = {"error": "", "rows": []}
	var b := await board()
	check("it is the Leaderboards", visible_text(b, "Leaderboards") != "")
	check("it says what it is", visible_text(b, "every finished game") != "")
	check("no finished games: says so, and when they will appear",
		visible_text(b, "No finished games yet") != "" and teams(b).is_empty())
	b.queue_free()

	_board = {"error": "HTTP 503", "rows": []}
	_board_calls = 0
	b = await board()
	check("a failed load says so", visible_text(b, "Couldn't load") != "")
	var retry := node(b, "Retry") as Button
	check("…with a Try again", retry != null)
	_board = {"error": "", "rows": two_games()}
	if retry != null:
		retry.pressed.emit()
	await frames(4)
	check("Try again loads it", _board_calls == 2 and teams(b).size() == 8
		and not (node(b, "Status") as Label).visible, "calls %d teams %d" % [_board_calls, teams(b).size()])
	check("…and the Try again is gone", node(b, "Retry") == null or node(b, "Retry").is_queued_for_deletion())
	b.queue_free()

	Game.leaderboard = [{"name": "Kidlat", "gems": 40}, {"name": "Alon", "gems": 12}]
	_board_calls = 0
	b = await board(true)
	check("offline: the phone's own games, said so",
		visible_text(b, "Offline") != "" and teams(b).size() == 2 and _board_calls == 0)
	check("offline rows cannot be tapped into (no team to ask about)",
		(teams(b)[0] as Button).disabled if teams(b).size() > 0 else false)
	b.queue_free()
	Game.leaderboard = []


func _list() -> void:
	print("-- every game's teams, best first")
	_board = {"error": "", "rows": two_games()}
	var b := await board()
	var cards := teams(b)
	var order: Array = []
	for c in cards:
		order.append(text_of(c, "Name").trim_prefix("★ ") + ":" + gems_of(c))
	check("both games' teams, merged, best first",
		order == ["Team 5:26", "Team 1:25", "Team 6:24", "Team 2:20", "Team 7:18", "Team 3:15",
			"Team 8:-30", "Team 4:-75"], str(order))
	check("ranked 1 to 8", text_of(cards[0], "Rank") == "1" and text_of(cards[7], "Rank") == "8")
	check("each row says its game and who played",
		text_of(cards[0], "Game").begins_with("Game 2") and text_of(cards[1], "Game").begins_with("Game 1")
		and text_of(cards[0], "Game").ends_with("5 players"), text_of(cards[0], "Game"))
	check("one player is 'player', not 'players'", text_of(cards[4], "Game").ends_with("1 player"),
		text_of(cards[4], "Game"))
	check("with the day it was played", text_of(cards[0], "Game").contains("Sep 2"), text_of(cards[0], "Game"))
	check("the player's own team is starred", text_of(cards[1], "Name") == "★ Team 1"
		and not text_of(cards[0], "Name").begins_with("★"))
	var gold := (node(cards[0], "Rank").get_parent() as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
	var fourth := (node(cards[3], "Rank").get_parent() as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
	var more := node(cards[0], "More") as Label
	check("a row says it can be tapped (›), and is wide enough to show it",
		more != null and more.size.x >= 6, "" if more == null else str(more.size))
	check("the gems sit clear of the ›", more != null
		and (node(cards[0], "Gems") as Control).get_global_rect().end.x <= more.get_global_rect().position.x)
	check("the top three wear the podium's colours", gold.bg_color == Pal.PODIUM[0] and fourth.bg_color.a == 0.0)
	check("no Your teams heading when yours are already shown", node(b, "YourTeams") == null)
	b.queue_free()


func _your_teams() -> void:
	print("-- the top 50, then yours")
	var rows: Array = []
	for i in 60:
		rows.append(row("t%d" % i, "T%d" % i, 1000 - i, 1 + i / 6, 5, [ME] if i == 57 else []))
	_board = {"error": "", "rows": rows}
	var b := await board()
	var cards := teams(b)
	check("the top 50, and one more: yours", cards.size() == 51, str(cards.size()))
	check("under a Your teams heading", node(b, "YourTeams") != null)
	check("at its real place, 58th", text_of(cards[50], "Rank") == "58" and text_of(cards[50], "Name") == "★ T57",
		text_of(cards[50], "Rank") + " " + text_of(cards[50], "Name"))
	b.queue_free()


func _team_panel() -> void:
	print("-- tap a team: who played for it")
	_board = {"error": "", "rows": two_games()}
	_team = {"error": "", "rows": [
		{"profile_id": ME, "username": "me", "gems": 60, "correct": 12, "items_done": 14, "finish_s": 754, "eliminated": false},
		{"profile_id": "ana", "username": "ana", "gems": 40, "correct": 9, "items_done": 11, "finish_s": -1, "eliminated": false},
		{"profile_id": "bo", "username": "bo", "gems": 0, "correct": 3, "items_done": 5, "finish_s": -1, "eliminated": true},
	]}
	# 60 + 40 + 0, -50 for bo going out, -25 each for ana and bo: 0.
	var rows := two_games()
	rows[1].gems = 100 - 50 - 50
	_board.rows = rows
	_team_asked.clear()
	_opened.clear()
	var b := await board()
	(teams(b)[1] as Button).pressed.emit()
	await frames(4)
	var panel := node(b, "TeamPanel")
	check("tapping a team opens it", panel != null)
	check("…asking for that team's players", _team_asked == ["t1"], str(_team_asked))
	check("titled with its place and name", visible_text(panel, "#2  Team 1") != "")
	var players := node(panel, "Players")
	check("a heading and a line per player", players.get_child_count() == 4, str(players.get_child_count()))
	var line := func(i: int) -> Array:
		return players.get_child(i).get_children().map(func(l: Label) -> String: return l.text)
	check("the heading", line.call(0) == ["Player", "Gems", "Correct", "Finish"], str(line.call(0)))
	var fits := true
	for l: Label in players.get_child(0).get_children():
		var need := l.get_theme_font("font").get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
				l.get_theme_font_size("font_size")).x
		fits = fits and need <= l.size.x
	check("every heading fits its column, Correct included", fits)
	check("me, starred, with my finish time", line.call(1) == ["★ me", "60", "12", "12:34"], str(line.call(1)))
	check("a player who didn't finish: DNF", line.call(2) == ["ana", "40", "9", "DNF"], str(line.call(2)))
	check("a player who ran out: Out", line.call(3) == ["bo", "0", "3", "Out"], str(line.call(3)))
	check("how the score adds up", text_of(panel, "Score") == "Team score 0 = 100 gems  −50 (1 out)  −50 (2 didn't finish)",
		text_of(panel, "Score"))
	(teams(b)[0] as Button).pressed.emit()
	await frames(2)
	check("a second tap behind the panel opens nothing more", _team_asked.size() == 1
		and b.find_children("TeamPanel", "", true, false).size() == 1)

	b.call("go_back")
	await frames(2)
	check("← closes the team first, staying on the board",
		(node(b, "TeamPanel") == null or node(b, "TeamPanel").is_queued_for_deletion()) and _opened.is_empty())
	b.call("go_back")
	check("← again goes Home", _opened == ["home"], str(_opened))

	# A team far past the planned five (client, 2026-10-12: 20 players ran off
	# the panel and would not scroll): the list scrolls, the score stays in.
	var few: Array = _team.rows
	var many: Array = []
	for i in 20:
		many.append({"profile_id": "p%d" % i, "username": "sim%03d" % i, "gems": 50, "correct": 0,
			"items_done": 0, "finish_s": -1, "eliminated": false})
	_team.rows = many
	(teams(b)[1] as Button).pressed.emit()
	await frames(4)
	panel = node(b, "TeamPanel")
	players = node(panel, "Players")
	var sc := players.get_parent() as ScrollContainer
	var score := node(panel, "Score") as Control
	check("20 players: the list scrolls", sc != null and players.get_child_count() == 21
		and players.size.y > sc.size.y + 1.0, "%s in %s" % [players.size.y, sc.size.y if sc != null else -1.0])
	check("...inside the panel, the score line still in it", sc != null
		and panel.get_global_rect().encloses(sc.get_global_rect())
		and get_viewport().get_visible_rect().encloses(score.get_global_rect()) and score.get_global_rect().position.y
		>= sc.get_global_rect().end.y - 1.0, str(score.get_global_rect()))
	sc.scroll_vertical = 100000
	await frames(2)
	check("...down to the last player", sc.scroll_vertical > 0 and sc.get_global_rect().intersects(
		(players.get_child(20) as Control).get_global_rect()))
	_team.rows = few
	b.call("go_back")
	await frames(2)

	# A total that doesn't match the players (someone's row went missing):
	# the plain score, not a sum that doesn't add up.
	(teams(b)[3] as Button).pressed.emit()
	await frames(4)
	check("a score that doesn't add up is shown plain", text_of(node(b, "TeamPanel"), "Score") == "Team score 20",
		text_of(node(b, "TeamPanel"), "Score"))
	b.call("go_back")
	await frames(2)

	_team = {"error": "HTTP 500", "rows": []}
	(teams(b)[0] as Button).pressed.emit()
	await frames(4)
	check("a team that fails to load says so", visible_text(node(b, "TeamPanel"), "Couldn't load this team") != "")
	b.queue_free()
	await frames(2)


func _routing() -> void:
	print("-- who gets which board")
	Net.user_id = ""
	var host := FakeMain.new()
	host.opened = _opened
	add_child(host)
	var s: Control = load("res://scripts/LeaderboardScreen.gd").new()
	s.main = host
	host.add_child(s)
	s.setup({})
	await frames(2)
	check("a player's Leaderboard is the all-time one",
		s.get_children().any(func(c: Node) -> bool: return c.has_method("_open_team")))
	s.queue_free()

	s = load("res://scripts/LeaderboardScreen.gd").new()
	s.main = host
	host.add_child(s)
	s.setup({"session": "", "close": true, "live": false})
	await frames(2)
	check("the in-game panel stays the game's own board",
		not s.get_children().any(func(c: Node) -> bool: return c.has_method("_open_team")))
	_opened.clear()
	s.call("go_back")
	await frames(2)
	check("…and its ← closes it, not leaving for Home", _opened.is_empty() and not is_instance_valid(s))
	host.queue_free()

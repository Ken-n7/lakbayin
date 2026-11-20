extends TestCase

## The client's own server calls -- Backend, Teams, Lobby, Monks, WatchFeed --
## against a real server, every answer and every refusal the screens rely on.
## The offline suites fake these replies; this is where a change on either
## side that the other did not follow shows up.
##
## Run by server/tests/test_server.py (test_client_calls_against_a_real_server),
## which starts a server on a fresh database and passes four accounts in
## LAKBAYIN_TEST_INFO: 0 hosts, 1 plays, 2 spectates (and is an admin), 3 is
## a stranger. Run under its own `--profile`, so no real login is touched.

var info: Dictionary
var ids: Array = []
var words: Array = []          # the game's word list, for the right spellings


func _ready() -> void:
	info = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("LAKBAYIN_TEST_INFO")))
	for a: Dictionary in info.accounts:
		ids.append(str(a.id))
	words = JSON.parse_string(FileAccess.get_file_as_string("res://data/words.json"))
	await _accounts()
	var room := await _room()
	await _match(room)
	await _matchmaking()
	_forget_profile()
	completed = true
	finish("CONTRACT")


func _as(n: int) -> void:
	var a: Dictionary = info.accounts[n]
	var err: String = await Net.sign_in(a.username, a.password)
	check("signed in as account %d" % n, err == "" and Net.username == a.username and Net.user_id == ids[n], err)


func _spelling(word: String) -> String:
	for w: Dictionary in words:
		if w.word == word:
			return str(w.modern)
	return ""


# --- Backend: accounts --------------------------------------------------------
func _accounts() -> void:
	var name := "c%s" % str(randi() % 100000000)
	var pw := "contract-password"
	check("a short password is refused", await Net.sign_up(name, "short") != "" and not Net.signed_in())
	check("sign up signs the new account in", await Net.sign_up(name, pw) == ""
		and Net.signed_in() and Net.username == name and Net.user_id != "")
	var me := Net.user_id
	check("the same name cannot be taken twice", await Net.sign_up(name, pw) == "Username already taken")
	check("...nor in other capitals", await Net.sign_up(name.to_upper(), pw) == "Username already taken")
	check("a wrong password is refused", await Net.sign_in(name, "wrong-password") == "Invalid login credentials")
	check("a refused sign-in keeps the account that was signed in", Net.user_id == me and Net.username == name)
	check("sign-in ignores spaces round the name and its capitals",
		await Net.sign_in("  %s " % name.to_upper(), pw) == "" and Net.username == name and Net.user_id == me)
	# A restart: nothing in memory, the saved login brings the account back.
	Net.access_token = ""
	Net.username = ""
	Net.user_id = ""
	check("a restart restores the saved login", await Net.restore_session() == ""
		and Net.username == name and Net.user_id == me)
	Net.username = ""
	check("signed in without a name: only the profile is read again",
		await Net.restore_session() == "" and Net.username == name)
	Net.sign_out()
	check("sign out forgets the account", not Net.signed_in() and Net.user_id == "" and Net.username == "")
	check("after sign out there is no login to restore", await Net.restore_session() == "no saved session")
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET, "/rest/v1/match_config")
	check("signed out, the server answers nothing", got.error != "" and not bool(got.get("network", false)), str(got))


# --- Teams and Lobby: a custom room -------------------------------------------
func _room() -> Dictionary:
	await _as(0)
	var made: Dictionary = await Teams.create_room()
	var room: Dictionary = made.session
	var sid := str(room.get("id", ""))
	check("a room is made, in its lobby, custom", made.error == "" and sid != ""
		and room.state == "lobby" and room.custom == true, str(made))
	var code := str(room.get("code", ""))
	check("its code is four characters codes use", code.length() == 4 and Teams.bad_chars(code) == "", code)
	check("the room reads back by id", str((await Teams.session(sid)).get("id", "")) == sid)
	check("no id reads as nothing", (await Teams.session("")) == {})
	var gone: Dictionary = await Teams.session_read("no-such-session")
	check("a session that is not there is no error, just empty", gone.error == "" and gone.session == {}, str(gone))
	var teams: Array = await Teams.teams_of(sid)
	check("two sides", teams.size() == 2 and teams.all(func(t: Dictionary) -> bool: return str(t.id) != "" and str(t.name) != ""), str(teams))
	var t0 := str(teams[0].id)
	var t1 := str(teams[1].id)
	var mine: Dictionary = await Teams.membership(sid)
	check("the host is in it, on a side", str(mine.get("profile_id", "")) == ids[0] and str(mine.get("team_id", "")) in [t0, t1], str(mine))
	var host_team := str(mine.team_id)
	var everyone: Array = await Teams.everyone(sid)
	check("everyone: the host, by name and side", everyone.size() == 1 and everyone[0].username == info.accounts[0].username
		and everyone[0].team_id == host_team, str(everyone))
	check("hints are the host's to turn on", await Teams.set_room_hints(sid, true) == ""
		and (await Teams.session(sid)).get("hints") == true)
	var control: Dictionary = await Teams.control()
	check("the control panel is not for everyone", control.error == "Admins only", str(control))
	var poll: Dictionary = await Teams.poll_room(sid)
	check("the host's check-in sees the room", poll.error == "" and poll.data.member == true
		and poll.data.roster.size() == 1 and poll.data.session.id == sid, str(poll))
	var lobby := Lobby.new()
	check("the lobby reads in one go", await lobby.load(sid) == "" and lobby.session.get("id") == sid
		and lobby.teams.size() == 2 and lobby.team_of(ids[0]) == host_team
		and lobby.name_of(host_team) != "" and lobby.members_of(host_team).size() == 1)
	var empty := Lobby.new()
	check("a lobby that is not there reads empty, not as an error", await empty.load("no-such-session") == ""
		and empty.session == {} and empty.teams.is_empty())

	# A player comes in with the code, as typed.
	await _as(1)
	var other := "AAAA" if code != "AAAA" else "CCCC"
	check("a code is found in small letters", str((await Teams.find(code.to_lower())).session.get("id", "")) == sid)
	check("...and with spaces and a dash", str((await Teams.find(" %s-%s " % [code.left(2), code.right(2)])).session.get("id", "")) == sid)
	check("a short code is refused before asking", (await Teams.find("AB")).error == "The code is 4 letters and numbers.")
	check("characters codes never use are named", (await Teams.find("O0IL")).error == "Codes never use O 0 I L — check that character.")
	check("a code nobody has", (await Teams.find(other)).error == "No room with the code %s. Check it with the host." % other)
	var entered: Dictionary = await Teams.enter(code)
	check("into the room with its code", entered.error == "" and str(entered.session.id) == sid, str(entered))
	mine = await Teams.membership(sid)
	check("in, on no side yet", str(mine.get("profile_id", "")) == ids[1] and mine.get("team_id") == null, str(mine))
	check("coming in again keeps the one place", (await Teams.enter(code)).error == "" and (await Teams.everyone(sid)).size() == 2)
	check("a side that is not this room's is refused", await Teams.pick(sid, "no-such-team") == "Invalid side")
	var away := t1 if host_team == t0 else t0
	check("a side is picked", await Teams.pick(sid, away) == "" and str((await Teams.membership(sid)).team_id) == away)
	check("join by a team name nobody has", await Teams.join(code, "Nobody's") == "No team by that name.")
	var host_name := ""
	for t: Dictionary in teams:
		if str(t.id) == host_team:
			host_name = str(t.name)
	check("join by name, any capitals, onto the host's side", await Teams.join(code, "  %s " % host_name.to_upper()) == ""
		and str((await Teams.membership(sid)).team_id) == host_team)
	for what: String in ["move", "shuffle", "start", "hints"]:
		var err := ""
		match what:
			"move": err = await Teams.move_room_member(sid, ids[0], away)
			"shuffle": err = await Teams.shuffle_room(sid)
			"start": err = await Teams.start_room(sid)
			"hints": err = await Teams.set_room_hints(sid, false)
		check("only the host may %s" % what, err == "Only the host can change this lobby", err)
	check("a player cannot watch their own match", (await WatchFeed.enter(code)).error == "Players cannot watch their own match")
	check("out of the room before Start", await Teams.leave_room(sid) == "")
	var after: Dictionary = await Teams.poll_room(sid)
	check("...and no longer in it", after.error == "" and after.data.member == false, str(after))
	check("back in with the code", (await Teams.enter(code)).error == "")

	# A spectator: a member on no side, who only watches.
	await _as(2)
	check("a spectator comes in and takes the spectators' place", (await Teams.enter(code)).error == ""
		and await Teams.pick(sid, Lobby.SPECTATE) == "")

	# The host arranges the sides and starts.
	await _as(0)
	check("the host cannot move a stranger", await Teams.move_room_member(sid, ids[3], away) == "Invalid member or side")
	check("...nor onto a side that is not there", await Teams.move_room_member(sid, ids[1], "no-such-team") == "Invalid member or side")
	check("the host moves a player", await Teams.move_room_member(sid, ids[1], host_team) == ""
		and (await Teams.everyone(sid)).any(func(r: Dictionary) -> bool: return r.profile_id == ids[1] and r.team_id == host_team))
	check("one side empty: no start", await Teams.start_room(sid) == "Both sides need a player")
	check("shuffle", await Teams.shuffle_room(sid) == "")
	var sides := {}
	var spectating := false
	for r: Dictionary in await Teams.everyone(sid):
		if r.team_id == Lobby.SPECTATE:
			spectating = r.profile_id == ids[2]
		else:
			sides[r.team_id] = true
	check("a shuffle puts a player on each side and leaves the spectator watching", sides.size() == 2 and spectating, str(sides))
	check("start", await Teams.start_room(sid) == "")
	check("started is started", await Teams.start_room(sid) == "Only the host can change this lobby")
	check("no hints changed once it runs", await Teams.set_room_hints(sid, false) == "Only the host can change this lobby")
	var running: Dictionary = await Teams.session(sid)
	check("it runs, with a deadline", running.state == "running" and running.get("ends_at") != null
		and not Teams.expired(running), str(running))
	return running


# --- Monks and WatchFeed: the match --------------------------------------------
func _match(room: Dictionary) -> void:
	var sid := str(room.id)
	var code := str(room.code)
	await _as(0)
	var state: Dictionary = await Monks.state(sid)
	var data: Dictionary = state.data
	check("the match reads in one answer", state.error == "" and data.session.state == "running"
		and data.words.size() == 10 and data.teams.size() == 2 and data.has("answers"), str(state.error))
	check("no spelling is given while it runs", data.words.all(func(w: Dictionary) -> bool: return not w.has("modern") and not w.has("traditional")))
	var first := str(data.words[0].word)
	var right := _spelling(first)
	check("the word list knows every word the server drew", data.words.all(func(w: Dictionary) -> bool: return _spelling(str(w.word)) != ""))
	check("a wrong answer", await Monks.answer(sid, 0, "wrong") == "wrong")
	check("...locks that player out of that monk", await Monks.answer(sid, 0, right) == "locked")
	check("a monk that is not there", await Monks.answer(sid, 10, right) == "error: Invalid monk")
	check("...nor below the first", await Monks.answer(sid, -1, right) == "error: Invalid monk")
	check("nothing carried, nothing deposited", (await Monks.deposit(sid)) == {"error": "", "deposited": 0})

	await _as(1)                   # the other side: account 0's lock is not theirs
	check("the right spelling", await Monks.answer(sid, 0, right) == "correct")
	check("a monk the side has answered", await Monks.answer(sid, 0, right) == "taken")
	check("deposit what is carried", (await Monks.deposit(sid)) == {"error": "", "deposited": 1})
	check("...once", (await Monks.deposit(sid)).deposited == 0)

	await _as(2)
	check("a spectator does not answer", await Monks.answer(sid, 1, "x") == "error: Spectators only watch")
	check("...or deposit", (await Monks.deposit(sid)).error == "Spectators only watch")
	var watch: Dictionary = await WatchFeed.enter(code)
	check("a spectator watches", watch.error == "" and str(watch.data) == sid, str(watch))
	var snap: Dictionary = await WatchFeed.snapshot(sid)
	check("the watched match", snap.error == "" and snap.data.session.id == sid and snap.data.teams.size() == 2, str(snap.error))
	await WatchFeed.leave(sid)
	check("after leaving, no more of it", (await WatchFeed.snapshot(sid)).error == "watch expired")

	await _as(3)
	var late: Dictionary = await Teams.enter(code)
	check("a stranger cannot join a match under way", late.error == "That room has already started.", late.error)
	check("...nor read it", (await Monks.state(sid)).error == "Not a member or viewer")
	check("...but may watch it", str((await WatchFeed.enter(code)).data) == sid)

	# The rest of the words, and the match is over.
	await _as(1)
	for i in range(1, data.words.size()):
		check("monk %d answered" % i, await Monks.answer(sid, i, _spelling(str(data.words[i].word))) == "correct")
	check("the other nine deposited", (await Monks.deposit(sid)).deposited == data.words.size() - 1)
	var over: Dictionary = await Monks.state(sid)
	check("the match ends when a side has every word", over.data.session.state == "ended"
		and over.data.words.all(func(w: Dictionary) -> bool: return str(w.get("modern", "")) != ""), str(over.error))
	var ended: Dictionary = await Teams.session(sid)
	check("an ended session is over", Teams.expired(ended))
	check("its code now says the room has ended", (await Teams.find(code)).error == "Room %s has ended. Ask the host for the new code." % code)
	check("nobody watches an ended room", (await WatchFeed.enter(code)).error == "No live room with that code")
	var history: Dictionary = await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/rpc/my_matches", {})
	check("it is in the player's records", history.error == "" and history.data.size() == 1
		and history.data[0].session_id == sid and history.data[0].custom == true, str(history))


# --- Teams: Find Match ----------------------------------------------------------
func _matchmaking() -> void:
	await _as(2)
	var ctl: Dictionary = await Teams.control({"p_team_size": 1})
	check("the admin's control panel answers", ctl.error == "" and ctl.data.team_size == 1, str(ctl))
	check("the control panel refuses a size out of range", (await Teams.control({"p_team_size": 9})).error == "Team size is 1 to 5")
	await _as(0)
	var q: Dictionary = await Teams.find_match()
	var sid := str(q.session.get("id", ""))
	check("Find Match: a lobby to wait in", q.error == "" and q.session.state == "lobby" and q.session.matchmade == true, str(q))
	var poll: Dictionary = await Teams.poll_match(sid)
	check("waiting, one of two", poll.get("queued") == true and int(poll.players) == 1 and int(poll.needed) == 2, str(poll))
	check("Find Match again: the same place", str((await Teams.find_match()).session.id) == sid)
	check("leave the queue", await Teams.leave_match(sid) == "")
	check("...out of it", (await Teams.poll_match(sid)).get("queued") == false)
	sid = str((await Teams.find_match()).session.id)
	await _as(1)
	var met: Dictionary = await Teams.find_match()
	check("the second player fills it and it starts", str(met.session.id) == sid and met.session.state == "running", str(met))
	check("one game at a time", (await Teams.create_room()).error == "Finish the match you're in first")
	var roster: Array = await Teams.everyone(sid)
	check("one on each side", roster.size() == 2 and roster[0].team_id != roster[1].team_id and roster.all(func(r: Dictionary) -> bool: return r.team_id != ""), str(roster))
	await _as(2)
	ctl = await Teams.control()
	check("the control panel counts the match and its players", ctl.data.matches == 1 and ctl.data.playing == 2, str(ctl))


func _forget_profile() -> void:
	Net.sign_out()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Game.SAVE_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Net.SESSION_PATH))

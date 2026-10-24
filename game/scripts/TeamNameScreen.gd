extends Control

## Start Adventure -> Find Match -> the match's lobby -> the map.
##
## Online, Find Match puts the player in a match and the server deals the
## teams; the lobby waits until it is full, then opens the map by itself. A
## phone that already joined comes straight back to its lobby.
##
## The lobby itself -- teams as boxes, live off the socket -- is shared with
## RoomScreen (a custom room), which extends this screen with a code, sides
## the players pick, and a host's Start.
##
## Offline there is nobody to match with, so it is the old form: a team name,
## recorded, and a Practice run starts -- which is how a dev run and the
## headless suites still reach the map.

const PANEL := Vector2(360, 230)
const LOBBY := Vector2(600, 330)
## A team box: its name, its count, and a line per player on it.
const CARD := Vector2(132, 64)
## One line in a card, measured: a 20px label and the column's 1px gap. At 18
## a full team of 5 cut the card's last line ("Tap to join") in half.
const NAME_LINE := 21.0
## Names shown per box before "+N more": four fit the 360px canvas with
## everything else on the screen; a team of six would push Ready off it.
const SHOW_NAMES := 4

var main: Control

var _msg: Label
var _go: Button

var _session := {}
var _lobby := Lobby.new()
var _mine := ""              # the team this player is on, "" for none yet
var _cards: GridContainer
var _spect_slot: CenterContainer   # a custom room's Spectators bar, under the cards
var _status: Label
var _steps: Label            # "1 Pick a team -> 2 Ready!", the current one lit
var _banner: PanelContainer  # the status line's backing, coloured by state
var _reloading := false
var _reload_again := false
var _joining := false
var _join_version := 0
var _find_btn: Button
## A match's lobby: its check-in clock, and whether the map is already opening.
var _poll_clock := 0.0
var _polling := false
var _poll_count := 0
## The last check-in's queue status (Teams.poll_match), and when it came.
var _queue := {}
var _queue_at := 0.0
var _entering := false


func setup(data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The dev panel's "lobby preview": the team picker mid-pick, made-up teams, no
	# server -- for looking at it without a live session.
	if OS.is_debug_build() and bool(data.get("preview", false)):
		_lobby.session = {"id": "preview", "code": "AB3K", "state": "lobby"}
		_lobby.teams = [{"id": "t1", "name": "Math Mavericks"},
			{"id": "t2", "name": "Number Ninjas"}, {"id": "t3", "name": "Prime Pirates"}]
		_lobby.players = {Net.user_id: {"username": "you", "team_id": "t1"},
			"p2": {"username": "ana", "team_id": "t1"}, "p3": {"username": "ben", "team_id": "t2"},
			"p4": {"username": "cai", "team_id": "t2"}, "p5": {"username": "dee", "team_id": "t3"}}
		_build_lobby()
		return
	if not (Net.configured() and Net.signed_in()):
		_build_offline()
		return
	_build_code()
	if bool(data.get("removed", false)):
		_say("You were removed from that session.", Pal.WRONG)
		return
	_resume()


## Joined a match before: back to it quietly if it is still going.
func _resume() -> void:
	if Game.joined_session != "":
		_rejoin_match()


## The code form keeps Home's town songs; the lobby is the battle songs, on
## into the map until the adventure starts (client).
func _music(list: String) -> void:
	if main != null:
		main.music.play(list)


func _background() -> void:
	for c in get_children():
		c.queue_free()
	# No backdrop of its own: Main's moving scene shows through (Backdrop.gd).


# --- Signed out --------------------------------------------------------------
## Find Match needs an account. (A team-name form for an offline run used to
## be here -- a leftover: Practice on Home is the offline game.)
func _build_offline() -> void:
	_background()
	var box := Ui.screen_panel(self, Vector2(320, 0), "Find Match")
	box.add_child(Art.label("Sign in to find a match.",
			Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	_back_button(box)


# --- Online: the code -------------------------------------------------------
func _build_code() -> void:
	_background()
	_music("town")
	# The sign-in screens' layout: the game's name on the scene, the form
	# beside it -- this is the third form a student meets, and it should look
	# like the other two.
	var box := Ui.auth_layout(self, "Join Adventure", 300)
	# No teacher needed: the server finds the match and picks the teams.
	_find_btn = Ui.button("Find Match", 260, Ui.H, Ui.RED)
	_find_btn.pressed.connect(_find)
	Ui.centre_row(box, _find_btn)
	_msg = Art.label("", Pal.SMALL, Pal.WRONG, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(260, 0)
	box.add_child(_msg)
	Ui.centre_row(box, Ui.back_button(go_back))


## Find Match: the server picks the match and the team (Teams.find_match).
func _find() -> void:
	if _joining:
		return
	_say("", Pal.INK)
	_find_btn.disabled = true
	_find_btn.text = "Finding a match..."
	_joining = true
	_join_version += 1
	var version := _join_version
	var got: Dictionary = await Teams.find_match()
	if not is_instance_valid(self) or version != _join_version:
		return
	if got.error != "":
		_joining = false
		_find_btn.disabled = false
		_find_btn.text = "Find Match"
		_say(got.error, Pal.WRONG)
		return
	await _open_lobby(got.session, false, version)


## Back to a match this phone was in, if it is still going -- never a new one
## found on the player's behalf without a tap.
func _rejoin_match() -> void:
	_joining = true
	_join_version += 1
	var version := _join_version
	var session: Dictionary = await Teams.session(Game.joined_session)
	if not is_instance_valid(self) or version != _join_version:
		return
	if bool(session.get("custom", false)):
		_joining = false      # a room's: RoomScreen goes back to it
		return
	if session.is_empty() or Teams.expired(session) or not bool(session.get("matchmade", false)):
		_joining = false
		Game.joined_session = ""
		Game.save_profile()
		return
	await _open_lobby(session, true, version)


func _open_lobby(session: Dictionary, quiet: bool, version: int) -> void:
	_session = session
	_queue = {}
	_lobby = Lobby.new()
	_lobby.session = _session.duplicate()
	var lobby := _lobby
	Game.joined_session = str(_session.get("id", ""))
	# A match is found again by its id; a room by its code.
	Game.joined_code = "" if _matchmade() else str(_session.get("code", ""))
	Game.save_profile()
	# Listening before the first read, so nothing that happens in between is
	# missed; anything that lands early is folded in once the read is back.
	_watch()
	var err := await lobby.load(Game.joined_session)
	if not is_instance_valid(self) or version != _join_version or lobby != _lobby:
		return
	_joining = false
	if err == "" and not lobby.session.is_empty() and not lobby.players.has(Net.user_id):
		_kicked()
		return
	_build_lobby()
	if err == "" and not quiet:
		Sfx.play("success")
	if err != "":
		_say(err, Pal.WRONG)


# --- Online: the lobby ------------------------------------------------------
func _build_lobby() -> void:
	_background()
	_music("battle")
	var box := Ui.screen_panel(self, LOBBY, "Your Match" if _matchmade() else "Pick Your Team")
	box.add_theme_constant_override("separation", 6)
	# Two steps, and which one you are on: a Grade 8 student should not have
	# to work out that entering the map is what "ready" means. The code rides
	# the same line -- a line of its own pushed Ready off a 360px screen.
	var head := HBoxContainer.new()
	var code := Art.label("" if _matchmade() else "Code %s" % str(_lobby.session.get("code", Game.joined_code)),
			Pal.SMALL, Pal.INK_MUTED)
	code.custom_minimum_size = Vector2(110, 0)
	head.add_child(code)
	_steps = Art.label("", Pal.LABEL, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	_steps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_steps)
	var balance := Control.new()
	balance.custom_minimum_size = Vector2(110, 0)
	head.add_child(balance)
	box.add_child(head)

	# Up to six teams (the client's 6 of 5): a grid, three across at most, that
	# scrolls when two full rows outgrow a 360px screen. One row of six ran
	# off the panel's sides.
	var scroll := ScrollContainer.new()
	Ui.style_scroll(scroll)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var centre := CenterContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(centre)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 8)
	centre.add_child(stack)
	_cards = GridContainer.new()
	_cards.add_theme_constant_override("h_separation", 10)
	_cards.add_theme_constant_override("v_separation", 8)
	stack.add_child(_cards)
	_spect_slot = CenterContainer.new()
	stack.add_child(_spect_slot)

	_banner = PanelContainer.new()
	_status = Art.label("", Pal.SMALL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(520, 0)
	_banner.add_child(_status)
	var banner_row := CenterContainer.new()
	banner_row.add_child(_banner)
	box.add_child(banner_row)
	_msg = Art.label("", Pal.SMALL, Pal.WRONG, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.visible = false          # shown only with something to say (_say)
	box.add_child(_msg)

	# Leave on the left, the one thing to do on the right and biggest -- the
	# thumb's side, and the same order as every other two-button choice here.
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	var leave := Ui.button("Leave", Ui.W_MED, Ui.H, Ui.SMALL)
	leave.pressed.connect(_leave)
	row.add_child(leave)
	_go = Ui.button("Ready — Enter Map", 230, Ui.H, Ui.RED)
	_go.pressed.connect(_to_map)
	# A match opens the map by itself when it starts.
	_go.visible = not _matchmade()
	row.add_child(_go)
	box.add_child(row)
	_draw_lobby()


## The teams, who is on each, and which one is this player's -- drawn from
## `_lobby`, which the socket keeps current, so this never waits on the
## network. Rebuilt whole on every change: six boxes at most.
func _draw_lobby() -> void:
	if not is_instance_valid(_cards):
		return
	if _lobby.session.is_empty() or Teams.expired(_lobby.session):
		Game.joined_code = ""
		Game.joined_session = ""
		Game.save_profile()
		var was_match := _matchmade()
		_build_code()
		_say("That match has ended." if was_match else "That room has ended.",
				Pal.WRONG)
		return
	_session = _lobby.session
	_mine = _lobby.team_of(Net.user_id)
	for c in _cards.get_children():
		_cards.remove_child(c)
		c.queue_free()
	var locked := str(_session.get("state", "")) != "lobby" or _matchmade()
	# Two, three in a row; four as two by two; five and six as rows of three.
	var n := _lobby.teams.size()
	_cards.columns = maxi(1, 2 if n == 4 else mini(n, 3))
	# Every box the same height, so a team with more players does not read
	# as the "bigger" choice.
	# A room's cards leave a line for its Spectators bar underneath.
	var most := 2 if _matchmade() else 1
	for t: Dictionary in _lobby.teams:
		most = maxi(most, mini(_lobby.members_of(t.id).size(), SHOW_NAMES + 1))
	for t: Dictionary in _lobby.teams:
		# Locked: only somebody with no team (never picked, or theirs was
		# removed) may still pick. The server holds the same line.
		_cards.add_child(_team_box(t, locked and _mine != "", most))
	if is_instance_valid(_spect_slot):
		for c in _spect_slot.get_children():
			_spect_slot.remove_child(c)
			c.queue_free()
		if not _matchmade():
			_spect_slot.add_child(_spectator_box(locked and _mine != ""))

	var team_name := _lobby.name_of(_mine)
	var tone := Pal.INK
	if _matchmade():
		_steps.text = "Matchmaking"
		_status.text = _match_status()
		if str(_session.get("state", "")) == "running" and _mine != "" and not _entering:
			_entering = true
			_to_map.call_deferred()
	elif _mine == "":
		_status.text = "Tap a team to join it."
		_steps.text = "▶ 1  Pick a team      2  Ready!"
	elif locked:
		_status.text = "The adventure has started — you're on %s. Go!" % team_name
		_steps.text = "✓ 1  Pick a team      ▶ 2  Ready!"
		tone = Pal.CORRECT
	else:
		_status.text = "You're on %s. Tap another team to switch, or press Ready." % team_name
		_steps.text = "✓ 1  Pick a team      ▶ 2  Ready!"
	_status.add_theme_color_override("font_color", tone)
	var face := StyleBoxFlat.new()
	face.bg_color = Pal.PARCHMENT.darkened(0.06)
	face.set_corner_radius_all(3)
	face.set_content_margin_all(4)
	_banner.add_theme_stylebox_override("panel", face)
	Game.team_name = team_name
	_go.disabled = _mine == ""


## One team as a box to tap: its name, how many, and who -- the same list the
## teacher sees. Tapping it puts this player's name in it. Yours is marked
## YOU in words as well as in gold, never by colour alone. (Not red: red is
## a team, and "you" in red read as "you are on Red".)
func _team_box(t: Dictionary, locked: bool, most: int) -> Control:
	var id: String = t.id
	var mine := id == _mine
	var members := _lobby.members_of(id)
	var box := Button.new()
	# More than three teams means two rows, and two rows of full cards do not
	# fit a 360px screen: then a card is its name, its count and one line of
	# names, and the banner below says to tap one.
	var compact := _lobby.teams.size() > 3
	# Every line, and the column's 4px inset top and bottom.
	box.custom_minimum_size = Vector2(CARD.x,
			NAME_LINE * (3 if compact else most + 3) + 8)
	box.focus_mode = Control.FOCUS_NONE
	box.disabled = mine or locked
	Ui.click(box)
	box.tooltip_text = "" if box.disabled else "Join " + str(t.name)
	_card_face(box, mine)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 6.0
	col.offset_top = 4.0
	col.offset_right = -6.0
	col.offset_bottom = -4.0
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(col)
	var title := Art.label(str(t.name), Pal.LABEL, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(title)
	var count := Art.label("%d joined" % members.size(), Pal.SMALL,
			Pal.BRONZE if mine else Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(count)
	# You first, so your own name is never the one cut off.
	var ordered := members.filter(func(w: Dictionary) -> bool: return w.profile_id == Net.user_id) \
		+ members.filter(func(w: Dictionary) -> bool: return w.profile_id != Net.user_id)
	if compact:
		var who_all := ordered.map(func(w: Dictionary) -> String:
			return ("★ " if w.profile_id == Net.user_id else "") + str(w.username))
		var names := Art.label(", ".join(who_all) if not who_all.is_empty() else "nobody yet",
				Pal.SMALL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
		names.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		names.clip_text = true
		names.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(names)
		if not box.disabled:
			box.pressed.connect(func() -> void: _pick(id))
		return box
	for i in mini(ordered.size(), SHOW_NAMES):
		var who: Dictionary = ordered[i]
		var me: bool = who.profile_id == Net.user_id
		var line := Art.label(("★ " if me else "• ") + str(who.username), Pal.SMALL,
				Pal.BRONZE if me else Pal.INK, HORIZONTAL_ALIGNMENT_LEFT)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(line)
	if ordered.size() > SHOW_NAMES:
		var more := Art.label("+%d more" % (ordered.size() - SHOW_NAMES), Pal.SMALL,
				Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_LEFT)
		more.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(more)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(fill)
	# What tapping does, on the box itself.
	var foot := Art.label("YOU" if mine else "Rivals" if _matchmade() else "Locked" if locked else "Tap to join",
			Pal.SMALL,
			Pal.BRONZE if mine else Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(foot)
	if not box.disabled:
		box.pressed.connect(func() -> void: _pick(id))
	return box


## A team card's face: parchment, a gold edge when it is yours.
func _card_face(box: Button, mine: bool) -> void:
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		var face := StyleBoxFlat.new()
		face.bg_color = Pal.PARCHMENT if st != "hover" else Pal.PARCHMENT.lightened(0.25)
		if st == "pressed":
			face.bg_color = Pal.PARCHMENT.darkened(0.1)
		face.border_color = Pal.AMBER if mine else (Pal.WOOD if st != "hover" else Pal.TITLE)
		face.set_border_width_all(3 if mine else 2)
		face.set_corner_radius_all(3)
		box.add_theme_stylebox_override(st, face)


## A custom room's Spectators: a wide bar under the two sides. Anyone may
## watch instead of playing -- from above, the whole map, never a hero.
func _spectator_box(locked: bool) -> Control:
	var mine := _mine == Lobby.SPECTATE
	var box := Button.new()
	box.custom_minimum_size = Vector2(CARD.x * 2 + 10, NAME_LINE * 2 + 8)
	box.focus_mode = Control.FOCUS_NONE
	box.disabled = mine or locked
	box.tooltip_text = "" if box.disabled else "Watch instead of playing"
	Ui.click(box)
	_card_face(box, mine)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 8.0
	col.offset_top = 4.0
	col.offset_right = -8.0
	col.offset_bottom = -4.0
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(col)
	var title := Art.label("Spectators — watch from above, never play", Pal.LABEL, Pal.TITLE,
			HORIZONTAL_ALIGNMENT_CENTER)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(title)
	var who := _lobby.members_of(Lobby.SPECTATE).map(func(w: Dictionary) -> String:
		return ("★ " if w.profile_id == Net.user_id else "") + str(w.username))
	var foot := "YOU" if mine else "Locked" if locked else "Tap to watch instead"
	var line := Art.label(("%s  ·  %s" % [", ".join(who), foot]) if not who.is_empty() else foot,
			Pal.SMALL, Pal.BRONZE if mine else Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	line.clip_text = true
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(line)
	if not box.disabled:
		box.pressed.connect(func() -> void: _pick(Lobby.SPECTATE))
	return box


## Shown picked at once; the server's answer only matters if it says no, and
## then the lobby is read back to undo the guess.
func _pick(team_id: String) -> void:
	var lobby := _lobby
	_say("", Pal.INK)
	var was := _lobby.team_of(Net.user_id)
	if _lobby.players.has(Net.user_id):
		_lobby.players[Net.user_id].team_id = team_id
	_draw_lobby()
	var sid: String = str(_session.get("id", ""))
	Lobby.tell(sid, "members", "UPDATE", {"session_id": sid,
		"profile_id": Net.user_id, "team_id": team_id, "username": Net.username})
	var err: String = await Teams.pick(sid, team_id)
	if not is_instance_valid(self) or lobby != _lobby or err == "":
		return
	_say(err, Pal.WRONG)
	Lobby.tell(sid, "members", "RELOAD", {})
	if _lobby.players.has(Net.user_id):
		_lobby.players[Net.user_id].team_id = was
	await lobby.load(sid)
	if is_instance_valid(self) and lobby == _lobby:
		_draw_lobby()


## Teams, members and the session itself, live: a team-mate appearing, the
## teacher renaming or removing a team, and the moment Start locks the teams.
func _watch() -> void:
	var sid: String = str(_session.get("id", ""))
	var rt: Realtime = Net.realtime()
	if not rt.subscribed.is_connected(_reload_lobby):
		rt.subscribed.connect(_reload_lobby)
	if not rt.changed.is_connected(_on_row):
		rt.changed.connect(_on_row)
	if not rt.broadcast.is_connected(_on_hint):
		rt.broadcast.connect(_on_hint)
	# On the teacher's list as here, in the lobby.
	rt.track({"sid": sid, "where": "lobby", "name": Net.username})
	rt.watch("sessions", "id=eq." + sid)
	rt.watch("teams", "session_id=eq." + sid)
	rt.watch("members", "session_id=eq." + sid)


func _reload_lobby() -> void:
	if _reloading:
		_reload_again = true
		return
	_reloading = true
	var lobby := _lobby
	while true:
		_reload_again = false
		var sid := str(_session.get("id", ""))
		if sid == "":
			break
		var err := await lobby.load(sid)
		if not is_instance_valid(self) or lobby != _lobby:
			return
		if err == "" and sid == str(_session.get("id", "")) \
				and not lobby.session.is_empty() and not lobby.players.has(Net.user_id):
			_kicked()
			return
		elif err == "" and sid == str(_session.get("id", "")):
			_draw_lobby()
		elif err != "":
			_say(err, Pal.WRONG)
		if not _reload_again:
			break
	_reloading = false


func _on_row(table: String, type: String, record: Dictionary) -> void:
	if not is_instance_valid(self) or _session.is_empty():
		return
	if table == "members" and type == "DELETE" \
			and str(record.get("profile_id", "")) == Net.user_id \
			and str(record.get("session_id", "")) == str(_session.get("id", "")):
		_kicked()
		return
	match _lobby.apply(table, type, record):
		"changed":
			_draw_lobby()
		"reload":
			_reload_lobby()


## The fast road: the same changes, announced by whoever made them.
func _on_hint(event: String, data: Dictionary) -> void:
	if not is_instance_valid(self) or _session.is_empty():
		return
	match _lobby.hear(event, data):
		"changed":
			_draw_lobby()
		"reload":
			_reload_lobby()


func _to_map() -> void:
	if _mine == "":
		return
	# A spectator never gets a hero: the room's aerial view instead.
	if _mine == Lobby.SPECTATE:
		main.open("watch", {"code": str(_session.get("code", "")), "spectator": true})
		return
	Game.save_profile()
	Game.begin_adventure(int(Game.duration_seconds))
	main.open("adventure")


## The teacher removed this membership while the session was still a lobby.
## Forget the remembered code and put the player back where they can enter a
## code. The server allows a fresh join until Start; after it, entry is locked.
func _kicked() -> void:
	Net.realtime().untrack()
	_join_version += 1
	_joining = false
	_reloading = false
	_reload_again = false
	Game.joined_code = ""
	Game.joined_session = ""
	Game.save_profile()
	var was_match := _matchmade()
	_session = {}
	# A load already in flight may still finish. Give this screen a new model
	# so that response cannot repopulate it or overwrite a later deliberate join.
	_lobby = Lobby.new()
	_mine = ""
	_build_code()
	# A match drops a phone that stopped checking in (poll_match).
	_say("No match found — tap Find Match to search again." if was_match
			else "You were removed from that room.", Pal.WRONG)


## Out of this lobby on this phone. After Start the membership stays on the
## server (the result still counts), but this phone forgets it.
func _leave() -> void:
	Net.realtime().untrack()
	# Out of a match's queue too, or the match waits for this player; out of
	# a room, or the host could start with a side nobody plays.
	if str(_session.get("state", "")) == "lobby":
		if _matchmade():
			Teams.leave_match(str(_session.get("id", "")))
		elif bool(_session.get("custom", false)):
			Teams.leave_room(str(_session.get("id", "")))
	Game.joined_code = ""
	Game.joined_session = ""
	Game.save_profile()
	main.open("home")


# --- A match ----------------------------------------------------------------
func _matchmade() -> bool:
	return bool(_session.get("matchmade", false))


## What the lobby is waiting for: players still needed, and how long this
## player has left before the search gives up -- both from the last check-in.
func _match_status() -> String:
	if str(_session.get("state", "")) != "lobby":
		return "The match has started — go!"
	if _queue.is_empty():
		return "Searching for players..."
	var since := Time.get_ticks_msec() / 1000.0 - _queue_at
	var left := maxi(0, int(_queue.get("search_s", 0)) - int(_queue.get("waited_s", 0)) - int(since))
	return "Searching for players — %d of %d · %d:%02d left" % [int(_queue.get("players", 0)),
		int(_queue.get("needed", 0)), left / 60, left % 60]


## Once a second the countdown is redrawn; every other second this phone
## checks in, which keeps its place and lets the server start a match that is
## due -- there is no teacher to press Start.
func _process(delta: float) -> void:
	if not _matchmade() or str(_session.get("state", "")) != "lobby" or not is_instance_valid(_status):
		return
	_poll_clock -= delta
	if _poll_clock > 0.0:
		return
	_poll_clock = 1.0
	_status.text = _match_status()
	_poll_count += 1
	if _polling or _poll_count % 2 == 1:
		return
	_polling = true
	var lobby := _lobby
	var got: Dictionary = await Teams.poll_match(str(_session.get("id", "")))
	_polling = false
	if not is_instance_valid(self) or lobby != _lobby or got.is_empty():
		return
	if not bool(got.get("queued", true)):
		_kicked()
		return
	_queue = got
	_queue_at = Time.get_ticks_msec() / 1000.0
	if got.get("session") is Dictionary:
		_lobby.session.merge(got.session, true)
	_draw_lobby()


# --- Shared -----------------------------------------------------------------
func _back_button(box: Control) -> void:
	Ui.centre_row(box, Ui.back_button(go_back, 300))


func _say(text: String, col: Color) -> void:
	if col == Pal.WRONG and text != "":
		Sfx.play("error")
	if is_instance_valid(_msg):
		_msg.visible = text != ""
		_msg.text = text
		_msg.add_theme_color_override("font_color", col)


func go_back() -> void:
	main.open("home")

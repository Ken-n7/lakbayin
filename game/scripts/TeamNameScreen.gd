extends Control

## Start Adventure -> the session code -> pick your team -> the map.
##
## Online, the teacher presses New Session and reads out a four-character
## code; the student types it, then taps the team they want in the lobby. They
## can switch until the teacher presses Start, after which teams are locked --
## the server refuses a switch, this screen only says so first. A phone that
## already joined comes straight back to the lobby with no code to retype.
##
## Offline there is nobody to check a code against, so it is the old form: a
## team name, recorded, and the run starts -- which is how a dev run and the
## headless suites still reach the map.

const PANEL := Vector2(360, 230)
const LOBBY := Vector2(600, 300)
const CARD := Vector2(132, 58)

var main: Control

var _team: LineEdit          # offline: the team name
var _code: LineEdit          # online: the session code
var _msg: Label
var _go: Button

var _session := {}
var _lobby := Lobby.new()
var _mine := ""              # the team this player is on, "" for none yet
var _cards: HBoxContainer
var _status: Label


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not (Net.configured() and Net.signed_in()):
		_build_offline()
		return
	_build_code()
	# Already in a session that is still going: straight back to the lobby.
	if Game.joined_code != "":
		_code.text = Game.joined_code
		_enter()


func _background() -> void:
	for c in get_children():
		c.queue_free()
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)


# --- Offline: a team name ---------------------------------------------------
func _build_offline() -> void:
	_background()
	var box := Ui.screen_panel(self, PANEL, "Enter Team Name")
	box.add_child(Art.label("Type the team name your teacher gave you.",
			Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	_team = Ui.field(box, "Team", "e.g. Math Mavericks")
	_team.text = Game.team_name
	_team.max_length = 18
	_team.text_submitted.connect(func(_t: String) -> void: _begin_offline())
	_msg = Art.label("", Pal.SMALL, Pal.WRONG, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_msg)
	_go = Ui.button("Ready!", 300, Ui.H, Ui.RED)
	_go.pressed.connect(_begin_offline)
	Ui.centre_row(box, _go)
	_back_button(box)
	# Deliberately no grab_focus(): on a phone that opens the soft keyboard
	# immediately, over the form the student has not read yet.


func _begin_offline() -> void:
	var name := _team.text.strip_edges()
	if name.is_empty():
		_say("Enter a team name.", Pal.WRONG)
		return
	Game.team_name = name
	Game.save_profile()
	Game.begin_adventure(int(Game.duration_seconds))
	main.open("adventure")


# --- Online: the code -------------------------------------------------------
func _build_code() -> void:
	_background()
	var box := Ui.screen_panel(self, PANEL, "Join Adventure")
	box.add_child(Art.label("Type the code your teacher shows.",
			Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	_code = Ui.field(box, "Code", "e.g. K7QM")
	_code.max_length = 4
	_code.text_changed.connect(func(t: String) -> void:
		var up := t.to_upper()
		if up != t:
			var at := _code.caret_column
			_code.text = up
			_code.caret_column = at)
	_code.text_submitted.connect(func(_t: String) -> void: _enter())
	_msg = Art.label("", Pal.SMALL, Pal.WRONG, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_msg)
	_go = Ui.button("Join", 300, Ui.H, Ui.RED)
	_go.pressed.connect(_enter)
	Ui.centre_row(box, _go)
	_back_button(box)


func _enter() -> void:
	if _code.text.strip_edges().is_empty():
		_say("Enter the code.", Pal.WRONG)
		return
	_go.disabled = true
	_go.text = "Joining..."
	var got: Dictionary = await Teams.enter(_code.text)
	if not is_instance_valid(self):
		return
	if got.error != "":
		_go.disabled = false
		_go.text = "Join"
		_say(got.error, Pal.WRONG)
		# A remembered code that has since ended is simply forgotten.
		Game.joined_code = ""
		Game.joined_session = ""
		Game.save_profile()
		return
	_session = got.session
	Game.joined_session = str(_session.get("id", ""))
	Game.joined_code = str(_session.get("code", ""))
	Game.save_profile()
	# Listening before the first read, so nothing that happens in between is
	# missed; anything that lands early is folded in once the read is back.
	_watch()
	var err := await _lobby.load(Game.joined_session)
	if not is_instance_valid(self):
		return
	_build_lobby()
	if err != "":
		_say(err, Pal.WRONG)


# --- Online: the lobby ------------------------------------------------------
func _build_lobby() -> void:
	_background()
	var box := Ui.screen_panel(self, LOBBY, "Pick Your Team")
	box.add_child(Art.label("Adventure code  %s" % Game.joined_code, Pal.LABEL,
			Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	var centre := CenterContainer.new()
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(centre)
	_cards = HBoxContainer.new()
	_cards.add_theme_constant_override("separation", 8)
	centre.add_child(_cards)
	_status = Art.label("", Pal.SMALL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(540, 0)
	box.add_child(_status)
	_msg = Art.label("", Pal.SMALL, Pal.WRONG, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_msg)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	_go = Ui.button("Enter Map", Ui.W_WIDE, Ui.H, Ui.RED)
	_go.pressed.connect(_to_map)
	row.add_child(_go)
	var leave := Ui.button("Leave", Ui.W_MED, Ui.H, Ui.SMALL)
	leave.pressed.connect(_leave)
	row.add_child(leave)
	box.add_child(row)
	_draw_lobby()


## The teams, who is on each, and which one is this player's -- drawn from
## `_lobby`, which the socket keeps current, so this never waits on the
## network. Rebuilt whole on every change: four cards at most.
func _draw_lobby() -> void:
	if not is_instance_valid(_cards):
		return
	if _lobby.session.is_empty() or Teams.expired(_lobby.session):
		Game.joined_code = ""
		Game.joined_session = ""
		Game.save_profile()
		_build_code()
		_say("That adventure has ended. Enter the new code.", Pal.WRONG)
		return
	_session = _lobby.session
	_mine = _lobby.team_of(Net.user_id)
	for c in _cards.get_children():
		c.queue_free()
	var locked := str(_session.get("state", "")) != "lobby"
	for t: Dictionary in _lobby.teams:
		var id: String = t.id
		var card := Ui.button("%s\n%d joined" % [t.name, _lobby.members_of(id).size()],
				CARD.x, CARD.y, Ui.RED if id == _mine else Ui.SMALL)
		# Locked: only somebody with no team (never picked, or theirs was
		# removed) may still pick. The server holds the same line.
		card.disabled = id == _mine or (locked and _mine != "")
		card.pressed.connect(func() -> void: _pick(id))
		_cards.add_child(card)
	if _lobby.teams.is_empty():
		_cards.add_child(Art.label("Your teacher has not made any teams yet.",
				Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))

	var team_name := _lobby.name_of(_mine)
	if _mine == "":
		_status.text = "Tap the team you want to join."
	elif locked:
		_status.text = "You're on %s. Teams are locked — the adventure has started." % team_name
	else:
		_status.text = "You're on %s. You can switch until your teacher starts." % team_name
	Game.team_name = team_name
	_go.disabled = _mine == ""


## Shown picked at once; the server's answer only matters if it says no, and
## then the lobby is read back to undo the guess.
func _pick(team_id: String) -> void:
	_say("", Pal.INK)
	var was := _lobby.team_of(Net.user_id)
	if _lobby.players.has(Net.user_id):
		_lobby.players[Net.user_id].team_id = team_id
	_draw_lobby()
	var sid: String = str(_session.get("id", ""))
	Lobby.tell(sid, "members", "UPDATE", {"session_id": sid,
		"profile_id": Net.user_id, "team_id": team_id, "username": Net.username})
	var err: String = await Teams.pick(sid, team_id)
	if not is_instance_valid(self) or err == "":
		return
	_say(err, Pal.WRONG)
	Lobby.tell(sid, "members", "RELOAD", {})
	if _lobby.players.has(Net.user_id):
		_lobby.players[Net.user_id].team_id = was
	await _lobby.load(str(_session.get("id", "")))
	if is_instance_valid(self):
		_draw_lobby()


## Teams, members and the session itself, live: a team-mate appearing, the
## teacher renaming or removing a team, and the moment Start locks the teams.
func _watch() -> void:
	var sid: String = str(_session.get("id", ""))
	var rt: Realtime = Net.realtime()
	if not rt.changed.is_connected(_on_row):
		rt.changed.connect(_on_row)
	if not rt.broadcast.is_connected(_on_hint):
		rt.broadcast.connect(_on_hint)
	# On the teacher's list as here, in the lobby.
	rt.track({"sid": sid, "where": "lobby", "name": Net.username})
	rt.watch("sessions", "id=eq." + sid)
	rt.watch("teams", "session_id=eq." + sid)
	rt.watch("members", "session_id=eq." + sid)


func _on_row(table: String, type: String, record: Dictionary) -> void:
	if not is_instance_valid(self):
		return
	match _lobby.apply(table, type, record):
		"changed":
			_draw_lobby()
		"reload":
			await _lobby.load(str(_session.get("id", "")))
			if is_instance_valid(self):
				_draw_lobby()


## The fast road: the same changes, announced by whoever made them.
func _on_hint(event: String, data: Dictionary) -> void:
	if not is_instance_valid(self):
		return
	match _lobby.hear(event, data):
		"changed":
			_draw_lobby()
		"reload":
			await _lobby.load(str(_session.get("id", "")))
			if is_instance_valid(self):
				_draw_lobby()


func _to_map() -> void:
	if _mine == "":
		return
	Game.save_profile()
	Game.begin_adventure(int(Game.duration_seconds))
	main.open("adventure")


## Out of this session for good on this phone: the membership stays on the
## server (the teacher still sees them, and the gems still count), but the
## code is forgotten so Start Adventure asks for one again.
func _leave() -> void:
	Net.realtime().untrack()
	Game.joined_code = ""
	Game.joined_session = ""
	Game.save_profile()
	main.open("home")


# --- Shared -----------------------------------------------------------------
func _back_button(box: Control) -> void:
	var back := Ui.button("Back", 300, Ui.H, Ui.SMALL)
	back.pressed.connect(go_back)
	Ui.centre_row(box, back)


func _say(text: String, col: Color) -> void:
	if is_instance_valid(_msg):
		_msg.text = text
		_msg.add_theme_color_override("font_color", col)


func go_back() -> void:
	main.open("home")

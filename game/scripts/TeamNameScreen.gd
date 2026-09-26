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
const LOBBY := Vector2(600, 330)
## A team box: its name, its count, and a line per player on it.
const CARD := Vector2(132, 64)
const NAME_LINE := 18.0
## Names shown per box before "+N more": four fit the 360px canvas with
## everything else on the screen; a team of six would push Ready off it.
const SHOW_NAMES := 4

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
var _steps: Label            # "1 Pick a team -> 2 Ready!", the current one lit
var _banner: PanelContainer  # the status line's backing, coloured by state


func setup(data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Dev navigator's "lobby": the team picker mid-pick, made-up teams, no
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
	# Joined a session before: try it quietly. Still going -> straight back to
	# the lobby. Over -> forgotten, and the student sees an empty field, not a
	# warning about a code they never typed.
	if Game.joined_code != "":
		_code.text = Game.joined_code
		_enter(true)


## The code form keeps Home's town songs; the lobby is the battle songs, on
## into the map until the adventure starts (client).
func _music(list: String) -> void:
	if main != null:
		main.music.play(list)


func _background() -> void:
	for c in get_children():
		c.queue_free()
	# No backdrop of its own: Main's moving scene shows through (Backdrop.gd).


# --- Offline: a team name ---------------------------------------------------
func _build_offline() -> void:
	_background()
	var box := Ui.screen_panel(self, PANEL, "Enter Team Name")
	box.add_child(Art.label("Type the team name your Quest Keeper gave you.",
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
	_music("town")
	# The sign-in screens' layout: the game's name on the scene, the form
	# beside it -- this is the third form a student meets, and it should look
	# like the other two.
	var box := Ui.auth_layout(self, "Join Adventure", 300)
	box.add_child(Art.label("Type the code your Quest Keeper shows.",
			Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	# The code as a code: four big spaced letters, the way it is read off the
	# board, not a line of small text in a form field.
	_code = Ui.line_edit("K7QM", 200, 52, 32)
	_code.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code.max_length = 4
	_code.add_theme_constant_override("minimum_character_width", 4)
	var code_row := CenterContainer.new()
	code_row.add_child(_code)
	box.add_child(code_row)
	# Capitals as they type, and a character no code has is said at once,
	# not after a trip to the server.
	# A look-alike becomes the character codes use (a typed Z shows as 2).
	_code.text_changed.connect(func(t: String) -> void:
		var up := Teams.clean_code(t)
		if up != t:
			var at := mini(_code.caret_column, up.length())
			_code.text = up
			_code.caret_column = at
		var bad := Teams.bad_chars(up)
		_say(Teams.bad_note(bad) if bad != "" else "", Pal.WRONG))
	_code.text_submitted.connect(func(_t: String) -> void: _enter())
	_msg = Art.label("", Pal.SMALL, Pal.WRONG, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(260, 0)
	box.add_child(_msg)
	_go = Ui.button("Join", 260, Ui.H, Ui.RED)
	_go.pressed.connect(_enter)
	Ui.centre_row(box, _go)
	var back := Ui.link("Back")
	back.pressed.connect(go_back)
	Ui.centre_row(box, back)


## `quiet`: the code came from memory, not from the student, so a failure
## just clears the field instead of warning about it.
func _enter(quiet := false) -> void:
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
		if quiet:
			_code.text = ""
		else:
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
	_music("battle")
	var box := Ui.screen_panel(self, LOBBY, "Pick Your Team")
	box.add_theme_constant_override("separation", 6)
	# Two steps, and which one you are on: a Grade 8 student should not have
	# to work out that entering the map is what "ready" means. The code rides
	# the same line -- a line of its own pushed Ready off a 360px screen.
	var head := HBoxContainer.new()
	var code := Art.label("Code %s" % str(_lobby.session.get("code", Game.joined_code)), Pal.SMALL, Pal.INK_MUTED)
	code.custom_minimum_size = Vector2(110, 0)
	head.add_child(code)
	_steps = Art.label("", Pal.LABEL, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	_steps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_steps)
	var balance := Control.new()
	balance.custom_minimum_size = Vector2(110, 0)
	head.add_child(balance)
	box.add_child(head)

	var centre := CenterContainer.new()
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(centre)
	_cards = HBoxContainer.new()
	_cards.add_theme_constant_override("separation", 10)
	_cards.alignment = BoxContainer.ALIGNMENT_CENTER
	centre.add_child(_cards)

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
	row.add_child(_go)
	box.add_child(row)
	_draw_lobby()


## The teams, who is on each, and which one is this player's -- drawn from
## `_lobby`, which the socket keeps current, so this never waits on the
## network. Rebuilt whole on every change: four boxes at most.
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
		_cards.remove_child(c)
		c.queue_free()
	var locked := str(_session.get("state", "")) != "lobby"
	# Every box the same height, so a team with more players does not read
	# as the "bigger" choice.
	var most := 2
	for t: Dictionary in _lobby.teams:
		most = maxi(most, mini(_lobby.members_of(t.id).size(), SHOW_NAMES + 1))
	for t: Dictionary in _lobby.teams:
		# Locked: only somebody with no team (never picked, or theirs was
		# removed) may still pick. The server holds the same line.
		_cards.add_child(_team_box(t, locked and _mine != "", most))
	if _lobby.teams.is_empty():
		_cards.add_child(Art.label("Your Quest Keeper has not made any teams yet.",
				Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))

	var team_name := _lobby.name_of(_mine)
	var tone := Pal.INK
	if _mine == "":
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
## YOU in words as well as in red, never by colour alone.
func _team_box(t: Dictionary, locked: bool, most: int) -> Control:
	var id: String = t.id
	var mine := id == _mine
	var members := _lobby.members_of(id)
	var box := Button.new()
	box.custom_minimum_size = Vector2(CARD.x, 44 + NAME_LINE * most + 18)
	box.focus_mode = Control.FOCUS_NONE
	box.disabled = mine or locked
	box.tooltip_text = "" if box.disabled else "Join " + str(t.name)
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		var face := StyleBoxFlat.new()
		face.bg_color = Pal.PARCHMENT if st != "hover" else Pal.PARCHMENT.lightened(0.25)
		if st == "pressed":
			face.bg_color = Pal.PARCHMENT.darkened(0.1)
		face.border_color = Pal.WRONG if mine else (Pal.WOOD if st != "hover" else Pal.TITLE)
		face.set_border_width_all(3 if mine else 2)
		face.set_corner_radius_all(3)
		box.add_theme_stylebox_override(st, face)

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
			Pal.WRONG if mine else Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(count)
	# You first, so your own name is never the one cut off.
	var ordered := members.filter(func(w: Dictionary) -> bool: return w.profile_id == Net.user_id) \
		+ members.filter(func(w: Dictionary) -> bool: return w.profile_id != Net.user_id)
	for i in mini(ordered.size(), SHOW_NAMES):
		var who: Dictionary = ordered[i]
		var me: bool = who.profile_id == Net.user_id
		var line := Art.label(("★ " if me else "• ") + str(who.username), Pal.SMALL,
				Pal.WRONG if me else Pal.INK, HORIZONTAL_ALIGNMENT_LEFT)
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
	var foot := Art.label("YOU" if mine else "Locked" if locked else "Tap to join", Pal.SMALL,
			Pal.WRONG if mine else Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(foot)
	if not box.disabled:
		box.pressed.connect(func() -> void: _pick(id))
	return box


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
		_msg.visible = text != ""
		_msg.text = text
		_msg.add_theme_color_override("font_color", col)


func go_back() -> void:
	main.open("home")

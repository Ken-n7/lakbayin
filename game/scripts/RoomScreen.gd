extends "res://scripts/TeamNameScreen.gd"

## Custom Room: play with friends. One player makes a room and reads out its
## four-character code; friends type it, then each taps the side they want
## and may switch until the host presses Start. Any number a side, uneven
## too -- the host starts once both sides have somebody, and everyone's map
## opens by itself. The rules are the server's (`create_room`, `start_room`,
## `leave_room`, schema 4f); this screen only says so first.
##
## The lobby is Find Match's (TeamNameScreen); what differs is the form in
## front of it, the host's Start, and its lines.

var _code: LineEdit
var _make: Button


## Joined a room before: try it quietly. Still going -> straight back to it.
## Over -> forgotten, and the player sees an empty field, not a warning about
## a code they never typed.
func _resume() -> void:
	if Game.joined_code != "":
		_code.text = Game.joined_code
		_enter(true)


func _build_offline() -> void:
	_background()
	var box := Ui.screen_panel(self, PANEL, "Custom Room")
	box.add_child(Art.label("Sign in to play with friends.",
			Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	_back_button(box)


func _build_code() -> void:
	_background()
	_music("town")
	var box := Ui.auth_layout(self, "Custom Room", 300)
	_make = Ui.button("Create Room", 260, Ui.H, Ui.RED)
	_make.pressed.connect(_create)
	Ui.centre_row(box, _make)
	box.add_child(Art.label("or type a friend's room code",
			Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	# The code as a code: four big spaced letters, the way it is read out.
	_code = Ui.line_edit("K7QM", 200, 52, 32)
	_code.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code.max_length = 4
	_code.add_theme_constant_override("minimum_character_width", 4)
	var code_row := CenterContainer.new()
	code_row.add_child(_code)
	box.add_child(code_row)
	# Capitals as they type, a look-alike as the character codes use (a typed
	# Z shows as 2), and a character no code has said at once.
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
	_go = Ui.button("Join", 260, Ui.H, Ui.BLUE)
	_go.pressed.connect(_enter)
	Ui.centre_row(box, _go)
	var back := Ui.link("Back")
	back.pressed.connect(go_back)
	Ui.centre_row(box, back)


func _create() -> void:
	if _joining:
		return
	_say("", Pal.INK)
	_make.disabled = true
	_make.text = "Making a room..."
	_joining = true
	_join_version += 1
	var version := _join_version
	var got: Dictionary = await Teams.create_room()
	if not is_instance_valid(self) or version != _join_version:
		return
	if got.error != "":
		_joining = false
		_make.disabled = false
		_make.text = "Create Room"
		_say(_sentence(got.error), Pal.WRONG)
		return
	await _open_lobby(got.session, false, version)


## `quiet`: the code came from memory, not from the player, so a failure
## just clears the field instead of warning about it.
func _enter(quiet := false) -> void:
	if _joining:
		return
	if _code.text.strip_edges().is_empty():
		_say("Enter the code.", Pal.WRONG)
		return
	_go.disabled = true
	_go.text = "Joining..."
	_joining = true
	_join_version += 1
	var version := _join_version
	var got: Dictionary = await Teams.enter(_code.text)
	if not is_instance_valid(self) or version != _join_version:
		return
	if got.error != "":
		_joining = false
		_go.disabled = false
		_go.text = "Join"
		if quiet:
			_code.text = ""
		else:
			_say(_sentence(got.error), Pal.WRONG)
		# A remembered code that has since ended is simply forgotten.
		Game.joined_code = ""
		Game.joined_session = ""
		Game.save_profile()
		return
	await _open_lobby(got.session, quiet, version)


func _build_lobby() -> void:
	super._build_lobby()
	# The one button on the right is the host's Start, not Ready: everyone's
	# map opens when the room starts.
	_go.pressed.disconnect(_to_map)
	_go.pressed.connect(_start)
	_go.text = "Start"


func _draw_lobby() -> void:
	var ended := _lobby.session.is_empty() or Teams.expired(_lobby.session)
	super._draw_lobby()
	if ended or not is_instance_valid(_cards) or _session.is_empty():
		return
	var host := str(_session.get("admin_id", ""))
	var hosting := host == Net.user_id
	var host_name := str(_lobby.players.get(host, {}).get("username", "the host"))
	var started := str(_session.get("state", "")) != "lobby"
	var team_name := _lobby.name_of(_mine)
	var ready := _lobby.members_of("").is_empty()
	for t: Dictionary in _lobby.teams:
		ready = ready and not _lobby.members_of(t.id).is_empty()
	_steps.text = "Room code  %s" % str(_session.get("code", ""))
	if started:
		_status.text = "The room has started — go!"
		if _mine != "" and not _entering:
			_entering = true
			_to_map.call_deferred()
	elif _mine == "":
		_status.text = "Tap a side to join it."
	elif hosting:
		_status.text = ("You host, on %s. Press Start when everyone is in." if ready
			else "You host, on %s. Both sides need a player to start.") % team_name
	else:
		_status.text = "You're on %s — tap the other side to switch. Waiting for %s to start." \
			% [team_name, host_name]
	_go.visible = hosting and not started
	_go.disabled = not ready


func _start() -> void:
	_go.disabled = true
	_go.text = "Starting..."
	var err: String = await Teams.start_room(str(_session.get("id", "")))
	if not is_instance_valid(self) or not is_instance_valid(_go):
		return
	_go.text = "Start"
	if err != "":
		_go.disabled = false
		_say(_sentence(err), Pal.WRONG)
		return
	# The socket brings the start too; this is for a socket that is slow.
	_reload_lobby()


## A server reason ("both sides need a player") as a line to show.
static func _sentence(err: String) -> String:
	return err if err == "" else err[0].to_upper() + err.substr(1) + ("" if err.ends_with(".") else ".")

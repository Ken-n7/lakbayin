extends Control

## Set Adventure Duration · Apply Time · Start / Pause / Resume, and the Teams
## panel, per the mockups.
##
## These write real rows into `sessions` and `teams` now; what is still missing
## is anybody reading them, which is Phase 4. The clock is stored the way the
## schema wants it: `ends_at` while running, `remaining_s` while paused, so a
## phone that joins late computes the same countdown as everyone else.
##
## Start Game refuses on an incomplete bank rather than generating the
## difference -- the teacher authored those questions and gets to know.

const PANEL := Vector2(600, 310)
const SESSIONS := "/rest/v1/sessions"
const TEAMS := "/rest/v1/teams"

var main: Control

var _hours := 0
var _minutes := 10
var _time_label: Label
var _msg: Label
var _state_label: Label
var _teams_box: VBoxContainer
var _session := {}


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := Ui.screen_panel(self, PANEL, "Game Controls")
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	box.add_child(cols)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	left.custom_minimum_size = Vector2(280, 0)
	cols.add_child(left)
	_build_duration(left)
	_build_buttons(left)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 4)
	right.custom_minimum_size = Vector2(260, 0)
	cols.add_child(right)
	right.add_child(Art.label("Teams", Pal.H2, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER))
	var scroll := Ui.scroll(right, 110)
	_teams_box = VBoxContainer.new()
	_teams_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_teams_box)
	var add_team := Ui.button("Add Team", Ui.W_MED, Ui.H, Ui.SMALL)
	add_team.pressed.connect(_add_team)
	Ui.centre_row(right, add_team)

	_msg = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(560, 0)
	box.add_child(_msg)

	var back := Ui.button("Back", Ui.W_WIDE, Ui.H, Ui.SMALL)
	back.pressed.connect(go_back)
	Ui.centre_row(box, back)

	_load()


func _build_duration(col: VBoxContainer) -> void:
	col.add_child(Art.label("Set Adventure Duration", Pal.H2, Pal.TITLE))
	# Each pair sits under its own caption. Unlabelled, the row read
	# "- + 0 hr 10 min - +" and gave no clue which pair moved which number.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for spec in [["hr", 1, 0], ["min", 0, 5]]:
		var group := VBoxContainer.new()
		group.add_theme_constant_override("separation", 2)
		group.add_child(Art.label(spec[0], Pal.TINY, Pal.INK_MUTED,
				HORIZONTAL_ALIGNMENT_CENTER))
		var pair := HBoxContainer.new()
		pair.add_theme_constant_override("separation", 2)
		var dh: int = spec[1]
		var dm: int = spec[2]
		for sign in [-1, 1]:
			var b := Ui.button("−" if sign < 0 else "+", Ui.H, Ui.H, Ui.SMALL)
			b.pressed.connect(func() -> void: _bump(dh * sign, dm * sign))
			pair.add_child(b)
		group.add_child(pair)
		row.add_child(group)
	_time_label = Art.label("", Pal.BODY, Pal.INK)
	row.add_child(_time_label)
	col.add_child(row)

	var apply := Ui.button("Apply Time", Ui.W_WIDE, Ui.H, Ui.SMALL)
	apply.pressed.connect(_apply_time)
	col.add_child(apply)
	_show_time()


## The schema's floor and ceiling, enforced here so a stepper cannot compose a
## duration Postgres will reject.
func _bump(dh: int, dm: int) -> void:
	var total: int = clampi((_hours + dh) * 60 + _minutes + dm, 1, 120)
	_hours = total / 60
	_minutes = total % 60
	_show_time()


func _show_time() -> void:
	_time_label.text = "  %d hr  %02d min  " % [_hours, _minutes]


func _build_buttons(col: VBoxContainer) -> void:
	_state_label = Art.label("", Pal.SMALL, Pal.INK_MUTED)
	col.add_child(_state_label)
	# Start on its own, Pause and Resume paired: they are the same decision seen
	# twice, and stacking all three ran the column off the bottom.
	var start := Ui.button("Start Game", Ui.W_WIDE, Ui.H, Ui.RED)
	start.pressed.connect(func() -> void: _set_state("running", true))
	col.add_child(start)

	var pair := HBoxContainer.new()
	pair.add_theme_constant_override("separation", 4)
	for spec in [["Pause Game", "paused"], ["Resume", "running"]]:
		var b := Ui.button(spec[0], (Ui.W_WIDE - 4) / 2.0, Ui.H, Ui.SMALL)
		var want: String = spec[1]
		b.pressed.connect(func() -> void: _set_state(want, false))
		pair.add_child(b)
	col.add_child(pair)


func _seconds() -> int:
	return (_hours * 60 + _minutes) * 60


# --- The session row --------------------------------------------------------
func _load() -> void:
	if not Net.signed_in():
		_say("Sign in as an admin to run a session.", Pal.INK_MUTED)
		return
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		SESSIONS + "?select=*&admin_id=eq." + Net.user_id + "&order=created_at.desc&limit=1")
	if not is_instance_valid(self):
		return
	if got.error != "":
		_say(got.error, Pal.WRONG)
		return
	if got.data is Array and not (got.data as Array).is_empty():
		_session = got.data[0]
		var secs: int = int(_session.get("duration_s", 600))
		_hours = secs / 3600
		_minutes = (secs % 3600) / 60
		_show_time()
	_refresh_state()
	_load_teams()


## One session per admin, reused. A second row would leave players guessing
## which adventure they joined.
func _ensure_session() -> String:
	if not Net.signed_in():
		return "Sign in as an admin first."
	if not _session.is_empty():
		return ""
	var made: Dictionary = await Net.rest(HTTPClient.METHOD_POST, SESSIONS,
		{"admin_id": Net.user_id, "duration_s": _seconds()})
	if made.error != "":
		return made.error
	if made.data is Array and not (made.data as Array).is_empty():
		_session = made.data[0]
	return ""


func _apply_time() -> void:
	var err := await _ensure_session()
	if err != "":
		_say(err, Pal.WRONG)
		return
	var done: Dictionary = await _patch({"duration_s": _seconds()})
	if done.error == "":
		_say("Duration set to %d hr %02d min." % [_hours, _minutes], Pal.CORRECT)


## Start writes the deadline every phone will read; pause stores what was left
## of it, so resuming does not hand the class extra time.
func _set_state(want: String, is_start: bool) -> void:
	var err := await _ensure_session()
	if err != "":
		_say(err, Pal.WRONG)
		return
	if is_start:
		var short: String = await QuestionStore.shortfall()
		if short != "":
			_say("Cannot start — question bank incomplete:  " + short, Pal.WRONG)
			return

	var fields := {"state": want}
	var now := Time.get_unix_time_from_system()
	if want == "paused":
		var ends: float = Time.get_unix_time_from_datetime_string(
			str(_session.get("ends_at", ""))) if _session.get("ends_at") != null else 0.0
		fields["remaining_s"] = maxi(int(ends - now), 0)
	elif is_start:
		fields["ends_at"] = Time.get_datetime_string_from_unix_time(
			int(now) + _seconds(), true) + "Z"
		fields["remaining_s"] = null
	else:
		# Resume: hand back exactly what the pause banked.
		var left: int = int(_session.get("remaining_s", _seconds()))
		fields["ends_at"] = Time.get_datetime_string_from_unix_time(
			int(now) + left, true) + "Z"
		fields["remaining_s"] = null

	var done: Dictionary = await _patch(fields)
	if done.error == "":
		_say("Game %s." % want, Pal.CORRECT)
	_refresh_state()


func _patch(fields: Dictionary) -> Dictionary:
	var done: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
		SESSIONS + "?id=eq." + str(_session.get("id", "")), fields)
	if done.error != "":
		_say(done.error, Pal.WRONG)
	elif done.data is Array and not (done.data as Array).is_empty():
		_session = done.data[0]
	return done


func _refresh_state() -> void:
	if not is_instance_valid(_state_label):
		return
	_state_label.text = "State: %s" % (_session.get("state", "no session yet"))


# --- Teams ------------------------------------------------------------------
func _load_teams() -> void:
	if _session.is_empty():
		return
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		TEAMS + "?select=id,name&session_id=eq." + str(_session.get("id", "")) + "&order=name")
	if not is_instance_valid(_teams_box):
		return
	for c in _teams_box.get_children():
		c.queue_free()
	if got.error != "":
		_say(got.error, Pal.WRONG)
		return
	for t: Dictionary in (got.data if got.data is Array else []):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		row.add_child(Art.label(str(t.get("name", "")), Pal.SMALL, Pal.INK))
		# "Joined Members:" stays empty until Phase 4 gives players a way in.
		row.add_child(Art.label("  Joined: 0", Pal.TINY, Pal.INK_MUTED))
		var del := Ui.button("×", Ui.H, Ui.H, Ui.SMALL_RED)
		var id: String = str(t.get("id", ""))
		del.pressed.connect(func() -> void:
			await Net.rest(HTTPClient.METHOD_DELETE, TEAMS + "?id=eq." + id)
			_load_teams())
		row.add_child(del)
		_teams_box.add_child(row)


func _add_team() -> void:
	var err := await _ensure_session()
	if err != "":
		_say(err, Pal.WRONG)
		return
	var n := _teams_box.get_child_count() + 1
	var made: Dictionary = await Net.rest(HTTPClient.METHOD_POST, TEAMS,
		{"session_id": _session.get("id", ""), "name": "Team %d" % n})
	if made.error != "":
		_say(made.error, Pal.WRONG)
		return
	_say("Team added — rename it to the code you give that team.", Pal.INK_MUTED)
	_load_teams()


func _say(text: String, col: Color) -> void:
	_msg.text = text
	_msg.add_theme_color_override("font_color", col)


func go_back() -> void:
	main.open("admin")

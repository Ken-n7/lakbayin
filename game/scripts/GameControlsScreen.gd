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
## Four is the ceiling the client asked for; two cards across keeps them
## readable at 640 canvas and centred as a group however many there are.
const MAX_TEAMS := 4
const CARD := Vector2(250, 62)
const SESSIONS := "/rest/v1/sessions"
const TEAMS := "/rest/v1/teams"

var main: Control

var _hours := 0
var _minutes := 10
var _time_label: Label
var _msg: Label
var _state_label: Label
var _teams_grid: GridContainer
var _body: VBoxContainer
var _add_btn: Button
var _tab := 0
var _session := {}
var _watching := false


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := Ui.screen_panel(self, PANEL, "Game Controls")

	# Two tabs rather than two columns. Side by side, the clock and the teams
	# each got half a panel and neither had room -- the teams especially, which
	# is the half a teacher works in while the class files in.
	var tabs := HBoxContainer.new()
	tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	tabs.add_theme_constant_override("separation", 6)
	for i in 2:
		var label: String = "Controls" if i == 0 else "Teams"
		var b := Ui.button(label, 150, Ui.H, Ui.RED if _tab == i else Ui.SMALL)
		var which := i
		b.pressed.connect(func() -> void:
			_tab = which
			_rebuild())
		tabs.add_child(b)
	box.add_child(tabs)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_body)

	_msg = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(540, 0)
	box.add_child(_msg)

	var back := Ui.button("Back", Ui.W_WIDE, Ui.H, Ui.SMALL)
	back.pressed.connect(go_back)
	Ui.centre_row(box, back)

	if _tab == 0:
		_build_duration(_body)
		_build_buttons(_body)
	else:
		_build_teams_tab(_body)

	_load()


## Rebuilt rather than hidden: the two tabs share no widgets, and keeping both
## alive means keeping both in sync for no reason.
func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_watching = false
	setup({})


# --- Teams tab --------------------------------------------------------------
## Up to four teams in a centred grid, two across. Each one is a card with its
## name editable on top -- the teacher hands that name out as the join code, so
## "Team 1" is not a name anybody was given.
func _build_teams_tab(col: VBoxContainer) -> void:
	var centre := CenterContainer.new()
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(centre)
	_teams_grid = GridContainer.new()
	_teams_grid.columns = 2
	_teams_grid.add_theme_constant_override("h_separation", 10)
	_teams_grid.add_theme_constant_override("v_separation", 8)
	centre.add_child(_teams_grid)

	_add_btn = Ui.button("Add Team", Ui.W_MED, Ui.H, Ui.SMALL)
	_add_btn.pressed.connect(_add_team)
	Ui.centre_row(col, _add_btn)


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
	# Beside the steppers, not beneath: the tab row above costs a line, and
	# this is the one control that reads fine on the same row as its value.
	var apply := Ui.button("Apply Time", Ui.W_MED, Ui.H, Ui.SMALL)
	apply.pressed.connect(_apply_time)
	row.add_child(apply)
	col.add_child(row)
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
	_watch_roster()


## One session per admin, reused. A second row would leave players guessing
## which adventure they joined.
## The teacher's own board is the one that subscribes; forty students watching
## `members` would turn ~200 realtime messages an adventure into ~22,000.
func _watch_roster() -> void:
	if _watching or _session.is_empty():
		return
	_watching = true
	var rt: Realtime = Net.realtime()
	rt.changed.connect(func(table: String, _t: String, _r: Dictionary) -> void:
		if table in ["members", "teams"] and is_instance_valid(_teams_grid):
			_load_teams())
	var sid: String = str(_session.get("id", ""))
	rt.watch("members", "session_id=eq." + sid)
	rt.watch("teams", "session_id=eq." + sid)


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
		# No `use_space`: that writes "2026-09-23 15:06:13", and the clock has
		# to round-trip through `Time.get_unix_time_from_datetime_string()`.
		fields["ends_at"] = Time.get_datetime_string_from_unix_time(
			int(now) + _seconds()) + "Z"
		fields["remaining_s"] = null
	else:
		# Resume: hand back exactly what the pause banked.
		var left: int = int(_session.get("remaining_s", _seconds()))
		fields["ends_at"] = Time.get_datetime_string_from_unix_time(
			int(now) + left) + "Z"
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
## One card per team: the name editable across the top, an × in its corner,
## and who is in it underneath. Live -- a student joining appears without the
## teacher reopening anything.
func _load_teams() -> void:
	if _session.is_empty() or not is_instance_valid(_teams_grid):
		return
	var sid: String = str(_session.get("id", ""))
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		TEAMS + "?select=id,name&session_id=eq." + sid + "&order=name")
	var joined: Dictionary = await Teams.roster(sid)
	if not is_instance_valid(_teams_grid):
		return
	for c in _teams_grid.get_children():
		c.queue_free()
	if got.error != "":
		_say(got.error, Pal.WRONG)
		return

	var teams: Array = got.data if got.data is Array else []
	for t: Dictionary in teams:
		_teams_grid.add_child(_team_card(t, joined.get(str(t.get("id", "")), [])))
	if is_instance_valid(_add_btn):
		_add_btn.disabled = teams.size() >= MAX_TEAMS
		_add_btn.text = "Add Team" if teams.size() < MAX_TEAMS else "4 teams is the most"


func _team_card(t: Dictionary, names: Array) -> Control:
	var id: String = str(t.get("id", ""))
	var card := PanelContainer.new()
	card.custom_minimum_size = CARD
	var face := StyleBoxFlat.new()
	face.bg_color = Pal.PARCHMENT
	face.border_color = Pal.WOOD
	face.set_border_width_all(2)
	face.set_corner_radius_all(3)
	face.set_content_margin_all(6)
	card.add_theme_stylebox_override("panel", face)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	card.add_child(col)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 4)
	var field := Ui.line_edit("Team Name", CARD.x - 46, 26, 13)
	field.text = str(t.get("name", ""))
	field.max_length = 18
	# Saved on Enter and on leaving the field, so a teacher who taps away does
	# not silently lose the name they just typed.
	field.text_submitted.connect(func(v: String) -> void: _rename(id, v))
	field.focus_exited.connect(func() -> void: _rename(id, field.text))
	top.add_child(field)
	var del := Ui.button("×", 28, 26, Ui.SMALL_RED)
	del.pressed.connect(func() -> void: _remove_team(id, str(t.get("name", "")), names))
	top.add_child(del)
	col.add_child(top)

	# The count is what a teacher scans: five of six means somebody is still on
	# the login screen.
	var who := Art.label("Joined %d%s" % [names.size(),
			"" if names.is_empty() else ":  " + ", ".join(names)],
			Pal.TINY, Pal.INK_MUTED if names.is_empty() else Pal.CORRECT)
	who.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	who.custom_minimum_size = Vector2(CARD.x - 12, 0)
	col.add_child(who)
	return card


## An empty team goes straight away; one with players in it asks first, because
## deleting it takes their membership with it and they would be dropped out of
## the adventure mid-run with no idea why.
func _remove_team(id: String, name: String, names: Array) -> void:
	if names.is_empty():
		await Net.rest(HTTPClient.METHOD_DELETE, TEAMS + "?id=eq." + id)
		_load_teams()
		return

	var dim := Ui.dim(self)
	var ask := Ui.screen_panel(dim, Vector2(360, 170), "Remove this team?")
	var warn := Art.label("%s has %d player%s in it. Removing it takes them out of the adventure."
			% [name, names.size(), "" if names.size() == 1 else "s"],
			Pal.SMALL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warn.custom_minimum_size = Vector2(320, 0)
	ask.add_child(warn)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	var yes := Ui.button("Remove", 140, Ui.H, Ui.RED)
	var no := Ui.button("Keep it", 140, Ui.H, Ui.SMALL)
	yes.pressed.connect(func() -> void:
		dim.queue_free()
		await Net.rest(HTTPClient.METHOD_DELETE, TEAMS + "?id=eq." + id)
		_load_teams())
	no.pressed.connect(func() -> void: dim.queue_free())
	row.add_child(yes)
	row.add_child(no)
	ask.add_child(row)


func _rename(id: String, name: String) -> void:
	var wanted := name.strip_edges()
	if wanted.is_empty():
		return
	var done: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
		TEAMS + "?id=eq." + id, {"name": wanted})
	if done.error != "":
		_say(done.error, Pal.WRONG)
		_load_teams()      # put the old name back on screen
	else:
		_say("Team renamed to \"%s\" — that is the code to hand out." % wanted,
			Pal.CORRECT)


func _add_team() -> void:
	var err := await _ensure_session()
	if err != "":
		_say(err, Pal.WRONG)
		return
	var n := _teams_grid.get_child_count() + 1
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

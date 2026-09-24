extends Control

## Set Adventure Duration · Start / Pause / Resume / End, and the Teams panel,
## per the mockups.
##
## These write real rows into `sessions` and `teams` now; what is still missing
## is anybody reading them, which is Phase 4. The clock is stored the way the
## schema wants it: `ends_at` while running, `remaining_s` while paused, so a
## phone that joins late computes the same countdown as everyone else.
##
## Start Game refuses on an incomplete bank rather than generating the
## difference -- the teacher authored those questions and gets to know.

const PANEL := Vector2(600, 310)
## Four is the ceiling the client asked for, and they sit in one row: at this
## width four fit across a 640 canvas and the group stays centred however many
## there are.
const MAX_TEAMS := 4
const CARD := Vector2(132, 54)
const SESSIONS := "/rest/v1/sessions"
const TEAMS := "/rest/v1/teams"

var main: Control

## The duration the fields show, in seconds. Mirrors the session row.
var duration_seconds := 600
var _min_field: LineEdit
var _sec_field: LineEdit
var _msg: Label
var _start_btn: Button
var _hold_btn: Button
var _end_btn: Button
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

	# The back arrow sits on the screen, not in the panel: a boxed "Back" at the
	# bottom was a whole row of panel for one word.
	var back := Ui.glyph("←", 26, Pal.PARCHMENT)
	back.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	back.offset_left = 8.0
	back.offset_top = 6.0
	back.offset_right = 44.0
	back.offset_bottom = 40.0
	back.pressed.connect(go_back)
	add_child(back)

	var box := Ui.screen_panel(self, PANEL, "Game Controls")

	var tabs := HBoxContainer.new()
	tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	tabs.add_theme_constant_override("separation", 18)
	for i in 2:
		var t := Ui.tab_text("Controls" if i == 0 else "Teams", _tab == i)
		var which := i
		Ui.tab_button(t).pressed.connect(func() -> void:
			_tab = which
			_rebuild())
		tabs.add_child(t)
	box.add_child(tabs)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_body)

	_msg = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(540, 0)
	box.add_child(_msg)

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
## Four teams in one row, small enough to fit. Add Team sits under them.
func _build_teams_tab(col: VBoxContainer) -> void:
	var centre := CenterContainer.new()
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(centre)
	_teams_grid = GridContainer.new()
	_teams_grid.columns = MAX_TEAMS
	_teams_grid.add_theme_constant_override("h_separation", 8)
	centre.add_child(_teams_grid)

	_add_btn = Ui.button("Add Team", Ui.W_MED, Ui.H, Ui.SMALL)
	_add_btn.pressed.connect(_add_team)
	Ui.centre_row(col, _add_btn)


## Minutes and seconds, typed. The steppers were eleven taps to reach half an
## hour, and Apply Time is gone with them: Start Game is when the duration is
## set, which is the moment it can actually matter.
func _build_duration(col: VBoxContainer) -> void:
	col.add_child(Art.label("Set Adventure Duration", Pal.H2, Pal.TITLE,
			HORIZONTAL_ALIGNMENT_CENTER))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	_min_field = Ui.number_field(52)
	_sec_field = Ui.number_field(52)
	row.add_child(_min_field)
	row.add_child(Art.label("min", Pal.SMALL, Pal.INK_MUTED))
	row.add_child(_sec_field)
	row.add_child(Art.label("sec", Pal.SMALL, Pal.INK_MUTED))
	col.add_child(row)
	_show_time()


## The schema's floor and ceiling, so a typed duration cannot compose one
## Postgres will refuse.
func _seconds() -> int:
	var mins := int(_min_field.text) if is_instance_valid(_min_field) else 10
	var secs := int(_sec_field.text) if is_instance_valid(_sec_field) else 0
	return clampi(mins * 60 + secs, 60, 7200)


func _show_time() -> void:
	if not is_instance_valid(_min_field):
		return
	var total := int(duration_seconds)
	_min_field.text = str(total / 60)
	_sec_field.text = "%02d" % (total % 60)


## Start, one button that is Pause or Resume depending on the state, and a way
## to end a run early. Start disables once the adventure is running: pressing
## it again would hand the class a fresh deadline mid-question.
func _build_buttons(col: VBoxContainer) -> void:
	_start_btn = Ui.button("Start Game", Ui.W_WIDE, Ui.H, Ui.RED)
	_start_btn.pressed.connect(func() -> void: _set_state("running", true))
	Ui.centre_row(col, _start_btn)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	_hold_btn = Ui.button("⏸  Pause Game", 120, Ui.H, Ui.SMALL)
	_hold_btn.pressed.connect(_toggle_hold)
	row.add_child(_hold_btn)
	_end_btn = Ui.button("End Game", 120, Ui.H, Ui.SMALL_RED)
	_end_btn.pressed.connect(_confirm_end)
	row.add_child(_end_btn)
	col.add_child(row)


## One control for the same decision seen twice. The label carries the state,
## so there is never a Resume to press while the clock is already running.
func _toggle_hold() -> void:
	if str(_session.get("state", "")) == "paused":
		_set_state("running", false)
	else:
		_set_state("paused", false)


## Ending early takes the run away from everyone at once, so it asks.
func _confirm_end() -> void:
	var dim := Ui.dim(self)
	var ask := Ui.screen_panel(dim, Vector2(360, 170), "End the adventure?")
	var warn := Art.label("Every player stops where they are and the run is "
			+ "scored as it stands.", Pal.SMALL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warn.custom_minimum_size = Vector2(320, 0)
	ask.add_child(warn)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	var yes := Ui.button("End it", 140, Ui.H, Ui.RED)
	var no := Ui.button("Keep playing", 140, Ui.H, Ui.SMALL)
	yes.pressed.connect(func() -> void:
		dim.queue_free()
		_set_state("ended", false))
	no.pressed.connect(func() -> void: dim.queue_free())
	row.add_child(yes)
	row.add_child(no)
	ask.add_child(row)


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
		duration_seconds = int(_session.get("duration_s", 600))
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
		{"admin_id": Net.user_id, "duration_s": duration_seconds})
	if made.error != "":
		return made.error
	if made.data is Array and not (made.data as Array).is_empty():
		_session = made.data[0]
	return ""


## Start writes the deadline every phone will read; pause stores what was left
## of it, so resuming does not hand the class extra time.
func _set_state(want: String, is_start: bool) -> void:
	var err := await _ensure_session()
	if err != "":
		_say(err, Pal.WRONG)
		return
	if is_start:
		# The typed duration goes up with the start, which is why there is no
		# Apply Time: the only moment it matters is the moment it begins.
		duration_seconds = _seconds()
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
			int(now) + duration_seconds) + "Z"
		fields["duration_s"] = duration_seconds
		fields["remaining_s"] = null
	else:
		# Resume: hand back exactly what the pause banked.
		var left: int = int(_session.get("remaining_s", duration_seconds))
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


## The buttons carry the state, so there is nothing else to label it with.
func _refresh_state() -> void:
	if not is_instance_valid(_start_btn):
		return
	var state := str(_session.get("state", ""))
	_start_btn.disabled = state == "running" or state == "paused"
	_hold_btn.disabled = state != "running" and state != "paused"
	_hold_btn.text = "▶  Resume" if state == "paused" else "⏸  Pause Game"
	_end_btn.disabled = state == "" or state == "ended"


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
	# A wrapper so the × can sit ON the corner rather than inside the box,
	# where a boxed button was eating a third of a card this narrow.
	var wrap := Control.new()
	wrap.custom_minimum_size = CARD

	var card := PanelContainer.new()
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var face := StyleBoxFlat.new()
	face.bg_color = Pal.PARCHMENT
	face.border_color = Pal.WOOD
	face.set_border_width_all(2)
	face.set_corner_radius_all(3)
	face.set_content_margin_all(5)
	card.add_theme_stylebox_override("panel", face)
	wrap.add_child(card)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	card.add_child(col)

	var field := Ui.line_edit("Team Name", CARD.x - 16, 22, 12)
	field.text = str(t.get("name", ""))
	field.max_length = 18
	# Saved on Enter and on leaving the field, so a teacher who taps away does
	# not silently lose the name they just typed.
	field.text_submitted.connect(func(v: String) -> void: _rename(id, v))
	field.focus_exited.connect(func() -> void: _rename(id, field.text))
	col.add_child(field)

	# The count is what a teacher scans: five of six means somebody is still on
	# the login screen.
	var who := Art.label("Joined %d%s" % [names.size(),
			"" if names.is_empty() else ": " + ", ".join(names)],
			Pal.TINY, Pal.INK_MUTED if names.is_empty() else Pal.CORRECT)
	who.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	who.custom_minimum_size = Vector2(CARD.x - 16, 0)
	col.add_child(who)

	var del := Ui.glyph("×", 16, Pal.WRONG)
	del.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	del.offset_left = -18.0
	del.offset_top = -9.0
	del.offset_right = 4.0
	del.offset_bottom = 13.0
	del.pressed.connect(func() -> void: _remove_team(id, str(t.get("name", "")), names))
	wrap.add_child(del)
	return wrap


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


## The new card appears as soon as the row does. It used to wait on
## `_load_teams()`, which re-fetches every team AND the whole roster -- two
## more round trips before a button press showed any sign of having worked.
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
	if made.data is Array and not (made.data as Array).is_empty() \
			and is_instance_valid(_teams_grid):
		_teams_grid.add_child(_team_card(made.data[0], []))
		if is_instance_valid(_add_btn):
			_add_btn.disabled = _teams_grid.get_child_count() >= MAX_TEAMS
	_say("Team added — rename it to the code you give that team.", Pal.INK_MUTED)


func _say(text: String, col: Color) -> void:
	_msg.text = text
	_msg.add_theme_color_override("font_color", col)


func go_back() -> void:
	main.open("admin")

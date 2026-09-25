extends Control

## A session, from start to finish: Set Adventure Duration · Start / Pause /
## Resume / End, and the Teams panel.
##
## The dashboard's Start Session opens this with `{"new": true}`: the
## teacher's previous session is ended and a fresh one made, with a
## four-character code to read out. Leaving this screen ends the session,
## after asking -- the dashboard is where the next one starts. Students type the code,
## then pick their own team; the teacher can Move anyone or Shuffle everyone
## until Start, which locks the teams. The clock is stored the way the schema
## wants it: `ends_at` while running, `remaining_s` while paused, so a phone
## that joins late computes the same countdown as everyone else.
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
var _code_label: Label
var _start_btn: Button
var _hold_btn: Button
var _end_btn: Button
var _teams_grid: GridContainer
var _body: VBoxContainer
var _add_btn: Button
var _shuffle_btn: Button
var _players: MenuButton       # everyone in the session, left of the tabs
var _loose: HBoxContainer      # players who have not picked a team
var _tab := 0
var _session := {}
## The session's teams and players, kept current off the socket -- see `Lobby`.
var _lobby := Lobby.new()
## The session whose roster the socket is following, "" for none. Tracked by id
## because a new session (Start after an ended run) needs watching afresh.
var _watching := ""


## Set by `setup({"new": true})` for the first build only; a tab switch
## rebuilds with `{}` and must not make another session.
var _fresh := false
## A session is being made right now -- the first second after Start Session.
var _making := false


func setup(data: Dictionary) -> void:
	if bool(data.get("new", false)):
		_fresh = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := Ui.screen_panel(self, PANEL, "Game Controls")

	# The back arrow on the title's own line, inside the panel: on the
	# screen's corner it sat in the dark margin, half under the dev tab.
	var title_row := HBoxContainer.new()
	var back := Ui.glyph("←", 24, Pal.TITLE)
	back.custom_minimum_size = Vector2(40, 0)
	back.tooltip_text = "Leave (ends the session)"
	back.pressed.connect(go_back)
	title_row.add_child(back)
	var title: Control = box.get_child(0)      # the panel's own title label
	box.add_child(title_row)
	box.move_child(title_row, 0)
	title.reparent(title_row)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title_balance := Control.new()   # keeps the title centred
	title_balance.custom_minimum_size = Vector2(40, 0)
	title_row.add_child(title_balance)

	# Everyone in the session, whatever tab: the teacher's roll call.
	var head := HBoxContainer.new()
	_players = _players_menu()
	head.add_child(_players)
	var tabs := HBoxContainer.new()
	tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_theme_constant_override("separation", 18)
	for i in 2:
		var t := Ui.tab_text("Controls" if i == 0 else "Teams", _tab == i)
		var which := i
		Ui.tab_button(t).pressed.connect(func() -> void:
			_tab = which
			_rebuild())
		tabs.add_child(t)
	head.add_child(tabs)
	var balance := Control.new()          # keeps the tabs centred
	balance.custom_minimum_size = _players.custom_minimum_size
	head.add_child(balance)
	box.add_child(head)

	# The code, on both tabs: it is what the teacher reads out, and what they
	# glance at when a student asks "what was it again?".
	_code_label = Art.label("", Pal.H2, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_code_label)

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

	# A tab switch rebuilds the screen: draw what is already known at once,
	# and let the read below catch anything missed.
	if not _session.is_empty():
		_draw_teams()
	# Every button in its real state from the first frame. Built enabled and
	# left that way until the session arrived, Start and End both looked
	# pressable for the second it took.
	_making = _making or _fresh
	_refresh_state()
	if _fresh:
		_fresh = false
		_open_fresh()
	else:
		_load()


## Rebuilt rather than hidden: the two tabs share no widgets, and keeping both
## alive means keeping both in sync for no reason.
func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
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

	_loose = HBoxContainer.new()
	_loose.alignment = BoxContainer.ALIGNMENT_CENTER
	_loose.add_theme_constant_override("separation", 4)
	col.add_child(_loose)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	_add_btn = Ui.button("Add Team", Ui.W_MED, Ui.H, Ui.SMALL)
	_add_btn.pressed.connect(_add_team)
	row.add_child(_add_btn)
	# For when picking freely has put all the friends on one side.
	_shuffle_btn = Ui.button("Shuffle", Ui.W_MED, Ui.H, Ui.SMALL)
	_shuffle_btn.pressed.connect(_shuffle)
	row.add_child(_shuffle_btn)
	col.add_child(row)


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


## Where each player is, by Presence: on the map (ready), in the lobby, or
## not connected at all. Usernames in each.
func _readiness() -> Dictionary:
	var out := {"ready": [], "lobby": [], "away": []}
	for pid: String in _lobby.players:
		var name: String = _lobby.players[pid].username
		if not _is_here(pid):
			out.away.append(name)
		elif _is_ready(pid) and _lobby.players[pid].team_id != "":
			out.ready.append(name)
		else:
			out.lobby.append(name)
	return out


## Start waits for everyone, the way a match lobby waits for every Ready.
## Ready is being on the map. Anyone connected but still in the lobby holds
## the start, and the teacher is told who. Someone not connected at all -- a
## dead phone -- can be left behind on purpose ("Start without them"), or one
## flat battery would hold the whole class; they can still come in later.
func _everyone_ready(without_away: bool) -> bool:
	var r := _readiness()
	if r.ready.is_empty() and r.lobby.is_empty():
		_notice("Nobody is ready yet",
			"No one has entered the map. Students join with code %s, pick a team, "
			% str(_session.get("code", "")) + "then press Enter Map.", "")
		return false
	if not r.lobby.is_empty():
		_notice("Not everyone is ready",
			"%s still in the lobby: %s. Start opens once everyone has entered the map."
			% ["1 player is" if r.lobby.size() == 1 else "%d players are" % r.lobby.size(),
				", ".join(r.lobby)], "")
		return false
	if not r.away.is_empty() and not without_away:
		_notice("Some players are not connected",
			"%s: %s. Start without them? They can still join the adventure later."
			% ["Not connected" if r.away.size() == 1 else "%d not connected" % r.away.size(),
				", ".join(r.away)], "Start without them")
		return false
	return true


## A message with an OK, and optionally one action that starts anyway.
func _notice(title: String, text: String, action: String) -> void:
	var dim := Ui.dim(self)
	var ask := Ui.screen_panel(dim, Vector2(380, 180), title)
	var body := Art.label(text, Pal.SMALL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(340, 0)
	ask.add_child(body)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	if action != "":
		var go := Ui.button(action, 170, Ui.H, Ui.RED)
		go.pressed.connect(func() -> void:
			dim.queue_free()
			_set_state("running", true, true))
		row.add_child(go)
	var ok := Ui.button("OK" if action == "" else "Wait", 110, Ui.H, Ui.SMALL)
	ok.pressed.connect(func() -> void: dim.queue_free())
	row.add_child(ok)
	ask.add_child(row)


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


## Start Session, from the dashboard. Usually that is simply a new
## session. The one exception is an adventure still being played -- the app
## closed mid-lesson and reopened -- where making a new one would end it for
## the whole class, so it asks: carry on with it, or end it.
func _open_fresh() -> void:
	if not Net.signed_in():
		_making = false
		_refresh_state()
		_say("Sign in as an admin to run a session.", Pal.INK_MUTED)
		return
	var live := await _live_session()
	if not is_instance_valid(self):
		return
	var state := str(live.get("state", ""))
	if state != "running" and state != "paused":
		_new_session()
		return
	_making = false
	_refresh_state()
	var dim := Ui.dim(self)
	var ask := Ui.screen_panel(dim, Vector2(380, 180), "An adventure is still going")
	var warn := Art.label("Session %s is %s. Carry on with it, or end it for everyone "
			% [str(live.get("code", "")), state] + "and start a new one?",
			Pal.SMALL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warn.custom_minimum_size = Vector2(340, 0)
	ask.add_child(warn)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	var keep := Ui.button("Carry on", 150, Ui.H, Ui.RED)
	var fresh := Ui.button("End it, start new", 150, Ui.H, Ui.SMALL)
	keep.pressed.connect(func() -> void:
		dim.queue_free()
		_adopt(live))
	fresh.pressed.connect(func() -> void:
		dim.queue_free()
		_session = live
		_new_session())
	row.add_child(keep)
	row.add_child(fresh)
	ask.add_child(row)


## The teacher's newest session still in play, `{}` for none.
func _live_session() -> Dictionary:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		SESSIONS + "?select=*&admin_id=eq." + Net.user_id
		+ "&state=neq.ended&order=created_at.desc&limit=5")
	if got.error != "":
		_say(got.error, Pal.WRONG)
		return {}
	for row: Dictionary in (got.data if got.data is Array else []):
		if not Teams.expired(row):
			return row
	return {}


## Every session this teacher still has open is ended -- one live adventure per
## teacher, so nobody is ever left in yesterday's game -- and a fresh one takes
## its place with a new code and two teams ready to rename.
func _new_session() -> void:
	if not Net.signed_in():
		_say("Sign in as an admin first.", Pal.WRONG)
		return
	if not _session.is_empty():
		_tell("sessions", "UPDATE", {"id": _session.get("id", ""), "state": "ended"})
	await Net.rest(HTTPClient.METHOD_PATCH,
		SESSIONS + "?admin_id=eq." + Net.user_id + "&state=neq.ended", {"state": "ended"})
	var made: Dictionary = await Net.rest(HTTPClient.METHOD_POST, SESSIONS,
		{"admin_id": Net.user_id, "duration_s": _seconds()})
	if not is_instance_valid(self):
		return
	_making = false
	if made.error != "" or not (made.data is Array) or (made.data as Array).is_empty():
		_say(made.error if made.error != "" else "Could not make a session.", Pal.WRONG)
		_refresh_state()
		return
	_session = made.data[0]
	_watch_roster()
	# Both teams in one request -- PostgREST inserts an array as one statement.
	var sid: String = str(_session.get("id", ""))
	var teams: Dictionary = await Net.rest(HTTPClient.METHOD_POST, TEAMS,
		[{"session_id": sid, "name": "Team 1"}, {"session_id": sid, "name": "Team 2"}])
	if not is_instance_valid(self):
		return
	_lobby.session = _session.duplicate()
	_lobby.players = {}
	_lobby.teams = []
	for t: Dictionary in (teams.data if teams.data is Array else []):
		_lobby.apply("teams", "INSERT", t)
	_say("New session ready. Students type the code, then pick a team.", Pal.CORRECT)
	_refresh_state()
	_draw_teams()


# --- The session row --------------------------------------------------------
func _load() -> void:
	if not Net.signed_in():
		_say("Sign in as an admin to run a session.", Pal.INK_MUTED)
		return
	# Only a live one: an ended session is not something to show or add to.
	var live := await _live_session()
	if not is_instance_valid(self):
		return
	_adopt(live)


func _adopt(row: Dictionary) -> void:
	_session = row
	if not row.is_empty():
		duration_seconds = int(row.get("duration_s", 600))
		_show_time()
	_refresh_state()
	_watch_roster()
	_load_teams()


## One session per admin, reused. A second row would leave players guessing
## which adventure they joined.
## The teacher's own board is the one that subscribes; forty students watching
## `members` would turn ~200 realtime messages an adventure into ~22,000.
func _watch_roster() -> void:
	var sid: String = str(_session.get("id", ""))
	if _session.is_empty() or _watching == sid:
		return
	_watching = sid
	var rt: Realtime = Net.realtime()
	if not rt.changed.is_connected(_on_roster_row):
		rt.changed.connect(_on_roster_row)
	# The fast road: students' own picks and joins, announced as they happen.
	if not rt.broadcast.is_connected(_on_hint):
		rt.broadcast.connect(_on_hint)
	# Who is actually here -- a dot by each name.
	if not rt.presence_changed.is_connected(_on_presence):
		rt.presence_changed.connect(_on_presence)
	rt.watch("members", "session_id=eq." + sid)
	rt.watch("teams", "session_id=eq." + sid)


## Applied from the message: a student joining or switching shows at once,
## with no fetch. Only a newcomer, whose name the message lacks, costs one.
func _on_roster_row(table: String, type: String, record: Dictionary) -> void:
	if not is_instance_valid(self) or table == "sessions":
		return
	match _lobby.apply(table, type, record):
		"changed":
			_draw_teams()
			_refresh_state()
		"reload":
			_load_teams()


func _on_presence() -> void:
	if is_instance_valid(self):
		_draw_teams()
		_refresh_state()


## A parchment dropdown -- the engine's grey read as an OS widget dropped onto
## the artwork, the complaint `Ui.option()` was written for.
func _players_menu() -> MenuButton:
	var m := MenuButton.new()
	m.flat = false
	m.custom_minimum_size = Vector2(120, 24)
	m.alignment = HORIZONTAL_ALIGNMENT_LEFT
	m.add_theme_font_size_override("font_size", Art.MIN_FONT)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		m.add_theme_color_override(c, Pal.INK)
	for state in ["normal", "hover", "pressed", "focus"]:
		m.add_theme_stylebox_override(state, Ui._paper_box(state != "normal"))
	var pop := m.get_popup()
	pop.add_theme_stylebox_override("panel", Ui._paper_box(false))
	pop.add_theme_color_override("font_color", Pal.INK)
	pop.add_theme_color_override("font_hover_color", Pal.TITLE)
	pop.add_theme_font_size_override("font_size", Art.MIN_FONT)
	var lit := Ui._paper_box(false)
	lit.bg_color = Pal.PARCHMENT.darkened(0.12)
	lit.set_border_width_all(0)
	pop.add_theme_stylebox_override("hover", lit)
	m.text = "Players (0) ▾"
	return m


## Everyone in the session: ✓ ready (on the map), ● in the lobby, ○ not
## connected -- and which team, or none yet.
func _fill_players() -> void:
	if not is_instance_valid(_players):
		return
	var menu := _players.get_popup()
	menu.clear()
	var ids: Array = _lobby.players.keys()
	ids.sort_custom(func(a: String, b: String) -> bool:
		return str(_lobby.players[a].username) < str(_lobby.players[b].username))
	for pid: String in ids:
		var p: Dictionary = _lobby.players[pid]
		var mark := "✓" if _is_ready(pid) else "●" if _is_here(pid) else "○"
		var team := _lobby.name_of(str(p.team_id))
		menu.add_item("%s %s  —  %s" % [mark, p.username, team if team != "" else "no team"])
	_players.text = "Players (%d) ▾" % ids.size()


func _on_hint(event: String, data: Dictionary) -> void:
	if not is_instance_valid(self):
		return
	match _lobby.hear(event, data):
		"changed":
			_draw_teams()
		"reload":
			_load_teams()


## Tell the lobbies, then (for the caller) write it. A refused write is
## followed by a RELOAD so nobody keeps showing what did not happen.
func _tell(table: String, type: String, record: Dictionary) -> void:
	Lobby.tell(str(_session.get("id", "")), table, type, record)


func _tell_reload() -> void:
	_tell("members", "RELOAD", {})


## Everything but New Session needs a session still in play. An ended or
## expired one is not something to add teams to or start -- nobody can join it.
func _ensure_session() -> String:
	if not Net.signed_in():
		return "Sign in as an admin first."
	if _session.is_empty() or Teams.expired(_session):
		return "This session has ended. Go back and press Start Session."
	return ""


## Start writes the deadline every phone will read; pause stores what was left
## of it, so resuming does not hand the class extra time.
func _set_state(want: String, is_start: bool, without_away := false) -> void:
	var err := await _ensure_session()
	if err != "":
		_say(err, Pal.WRONG)
		return
	if is_start and not _everyone_ready(without_away):
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
	elif want == "ended":
		# Only the state. It used to fall through to the Resume branch below,
		# whose `int(remaining_s)` is an error while the clock runs (a running
		# session has no banked time) -- so End only worked after a Pause.
		pass
	else:
		# Resume: hand back exactly what the pause banked.
		var banked: Variant = _session.get("remaining_s")
		var left: int = int(banked) if banked != null else duration_seconds
		fields["ends_at"] = Time.get_datetime_string_from_unix_time(
			int(now) + left) + "Z"
		fields["remaining_s"] = null

	# The lobbies show Start as teams locking; announced as it is written.
	# The whole change, deadline included: a bare {state: running} left the
	# lobbies holding a running session with no deadline at all.
	var told := fields.duplicate()
	told["id"] = _session.get("id", "")
	_tell("sessions", "UPDATE", told)
	var done: Dictionary = await _patch(fields)
	if done.error != "":
		_tell("sessions", "UPDATE", _session)
	if done.error == "":
		_say("Game %s." % want if not is_start
			else "Game running. Teams are locked now.", Pal.CORRECT)
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
	var state := str(_session.get("state", ""))
	# Out of time is over, whatever the row says -- the same rule the players
	# go by, so nothing is offered for a dead clock.
	if _session.is_empty() or Teams.expired(_session):
		state = "ended"
	if is_instance_valid(_code_label):
		if _making:
			_code_label.text = "Making a session…"
		elif state == "ended":
			_code_label.text = "Session ended — go back to start a new one"
		elif state == "lobby":
			# Before Start, the number that decides whether Start will go.
			var r := _readiness()
			_code_label.text = "Code:  %s   ·   %d/%d ready" % [str(_session.get("code", "")),
				r.ready.size(), _lobby.players.size()]
		else:
			_code_label.text = "Code:  %s   ·   %s" % [str(_session.get("code", "")), state.capitalize()]
	if is_instance_valid(_shuffle_btn):
		_shuffle_btn.disabled = state != "lobby"
	_fill_players()
	if not is_instance_valid(_start_btn):
		return
	_start_btn.disabled = state != "lobby"
	_hold_btn.disabled = state != "running" and state != "paused"
	_hold_btn.text = "▶  Resume" if state == "paused" else "⏸  Pause Game"
	# Nothing to end until it has started: before Start, leaving is how a
	# session goes.
	_end_btn.disabled = state != "running" and state != "paused"


# --- Teams ------------------------------------------------------------------
## One card per team: the name editable across the top, an × in its corner,
## and who is in it underneath. Live -- a student joining appears without the
## teacher reopening anything.
func _load_teams() -> void:
	if _session.is_empty():
		return
	var err := await _lobby.load(str(_session.get("id", "")))
	if not is_instance_valid(self):
		return
	if err != "":
		_say(err, Pal.WRONG)
	_draw_teams()
	_refresh_state()


## The Teams tab, drawn from `_lobby` -- never waits on the network.
func _draw_teams() -> void:
	if not is_instance_valid(_teams_grid):
		return
	for c in _teams_grid.get_children():
		_teams_grid.remove_child(c)
		c.queue_free()
	var teams: Array = _lobby.teams
	for t: Dictionary in teams:
		_teams_grid.add_child(_team_card(t, _lobby.members_of(t.id), teams))
	# Joined the session, no team yet -- or their team was removed.
	if is_instance_valid(_loose):
		for c in _loose.get_children():
			c.queue_free()
		var loose: Array = _lobby.members_of("")
		if not loose.is_empty():
			_loose.add_child(Art.label("No team:", Pal.TINY, Pal.WRONG))
			for who: Dictionary in loose:
				_loose.add_child(_player_chip(who, "", teams))
	if is_instance_valid(_add_btn):
		_add_btn.disabled = teams.size() >= MAX_TEAMS
		_add_btn.text = "Add Team" if teams.size() < MAX_TEAMS else "4 teams is the most"


func _team_card(t: Dictionary, members: Array, teams: Array) -> Control:
	var id: String = str(t.get("id", ""))
	# A wrapper so the × can sit ON the corner rather than inside the box,
	# where a boxed button was eating a third of a card this narrow.
	var wrap := Control.new()
	# A plain Control does not grow with what is in it, so the card is sized
	# for its names: a line each under the name field and the count.
	wrap.custom_minimum_size = CARD + Vector2(0, 15 * members.size())

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
	# the login screen. Each name is a menu, for Move.
	var ready := members.filter(func(m: Dictionary) -> bool: return _is_ready(m.profile_id)).size()
	col.add_child(Art.label("Joined %d · %d ready" % [members.size(), ready], Pal.TINY,
			Pal.INK_MUTED if members.is_empty() else Pal.CORRECT))
	for who: Dictionary in members:
		col.add_child(_player_chip(who, id, teams))

	var del := Ui.glyph("×", 16, Pal.WRONG)
	del.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	del.offset_left = -18.0
	del.offset_top = -9.0
	del.offset_right = 4.0
	del.offset_bottom = 13.0
	del.pressed.connect(func() -> void: _remove_team(id, str(t.get("name", "")), members))
	wrap.add_child(del)
	return wrap


## An empty team goes straight away; one with players in it asks first. Its
## players are not removed: they stay in the session with no team and are sent
## back to pick another, gems and all.
func _remove_team(id: String, name: String, names: Array) -> void:
	if names.is_empty():
		_drop_team(id)
		return

	var dim := Ui.dim(self)
	var ask := Ui.screen_panel(dim, Vector2(360, 170), "Remove this team?")
	var warn := Art.label("%s has %d player%s in it. They stay in the adventure and pick another team."
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
		_drop_team(id))
	no.pressed.connect(func() -> void: dim.queue_free())
	row.add_child(yes)
	row.add_child(no)
	ask.add_child(row)


## Gone from the screen at once; if the server refuses, it is read back.
func _drop_team(id: String) -> void:
	_lobby.apply("teams", "DELETE", {"id": id})
	_draw_teams()
	_tell("teams", "DELETE", {"id": id})
	var done: Dictionary = await Net.rest(HTTPClient.METHOD_DELETE, TEAMS + "?id=eq." + id)
	if is_instance_valid(self) and done.error != "":
		_say(done.error, Pal.WRONG)
		_tell_reload()
		_load_teams()


func _rename(id: String, name: String) -> void:
	var wanted := name.strip_edges()
	# Leaving the field saves too, so most calls change nothing: skip those.
	if wanted.is_empty() or wanted == _lobby.name_of(id):
		return
	var row := {"id": id, "name": wanted, "session_id": _session.get("id", "")}
	_lobby.apply("teams", "UPDATE", row)
	_tell("teams", "UPDATE", row)
	var done: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
		TEAMS + "?id=eq." + id, {"name": wanted})
	if not is_instance_valid(self):
		return
	if done.error != "":
		_say(done.error, Pal.WRONG)
		_tell_reload()
		_load_teams()      # put the old name back on screen
	else:
		_say("Team renamed to \"%s\"." % wanted, Pal.CORRECT)


func _add_team() -> void:
	var err := await _ensure_session()
	if err != "":
		_say(err, Pal.WRONG)
		return
	# The first "Team N" nobody has. Counting cards gave "Team 2" again after
	# Team 1 was removed, and the unique name refused it. Read off `_lobby`,
	# which is current, rather than asked of the server first.
	var taken: Array = []
	for t: Dictionary in _lobby.teams:
		taken.append(str(t.name).to_lower())
	if taken.size() >= MAX_TEAMS:
		return
	var n := 1
	while ("team %d" % n) in taken:
		n += 1
	# The id is made here, so the card and every lobby's copy of it can
	# appear before the server has answered.
	var row := {"id": Teams.uuid(), "session_id": _session.get("id", ""), "name": "Team %d" % n}
	_lobby.apply("teams", "INSERT", row)
	_draw_teams()
	_tell("teams", "INSERT", row)
	var made: Dictionary = await Net.rest(HTTPClient.METHOD_POST, TEAMS, row)
	if not is_instance_valid(self):
		return
	if made.error != "":
		_say(made.error, Pal.WRONG)
		_tell_reload()
		_load_teams()
		return
	_say("Team added — tap its name to rename it.", Pal.INK_MUTED)


## A player's name, which opens "Move to ..." for every other team. Before
## Start only -- after it the teams are locked, and the server says so too.
func _player_chip(who: Dictionary, on_team: String, teams: Array) -> Control:
	var chip := MenuButton.new()
	chip.flat = true
	# ✓ ready (on the map), ● connected but still in the lobby, ○ joined but
	# not connected -- a phone that died, or a student who wandered off.
	var pid: String = str(who.get("profile_id", ""))
	var here: bool = _is_here(pid)
	var ready := _is_ready(pid)
	chip.text = ("✓ " if ready else "● " if here else "○ ") + str(who.get("username", "?"))
	chip.add_theme_font_size_override("font_size", Pal.TINY)
	chip.add_theme_color_override("font_color",
		Pal.CORRECT if ready else Pal.INK if here else Pal.INK_MUTED)
	chip.add_theme_color_override("font_hover_color", Pal.WRONG)
	chip.alignment = HORIZONTAL_ALIGNMENT_LEFT
	chip.custom_minimum_size = Vector2(0, 14)
	chip.disabled = str(_session.get("state", "")) != "lobby"
	chip.tooltip_text = "Move to another team" if not chip.disabled else "Teams are locked"
	var menu := chip.get_popup()
	var ids: Array = []
	for t: Dictionary in teams:
		if str(t.get("id", "")) == on_team:
			continue
		menu.add_item("Move to " + str(t.get("name", "")), ids.size())
		ids.append(str(t.get("id", "")))
	menu.id_pressed.connect(func(i: int) -> void: _move(str(who.get("profile_id", "")), ids[i]))
	return chip


## Moved on screen at once; read back only if the server says no.
func _is_ready(profile_id: String) -> bool:
	return Net.realtime().where_is(profile_id, str(_session.get("id", ""))) == "map"


func _is_here(profile_id: String) -> bool:
	return Net.realtime().where_is(profile_id, str(_session.get("id", ""))) != ""


func _move(profile_id: String, team_id: String) -> void:
	if _lobby.players.has(profile_id):
		_lobby.players[profile_id].team_id = team_id
	_draw_teams()
	_tell("members", "UPDATE", {"session_id": _session.get("id", ""),
		"profile_id": profile_id, "team_id": team_id})
	var done: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
		"/rest/v1/members?session_id=eq." + str(_session.get("id", ""))
		+ "&profile_id=eq." + profile_id, {"team_id": team_id})
	if is_instance_valid(self) and done.error != "":
		_say(done.error, Pal.WRONG)
		_tell_reload()
		_load_teams()


## Everyone dealt round the teams at random, on the server in one go.
func _shuffle() -> void:
	var err := await _ensure_session()
	if err != "":
		_say(err, Pal.WRONG)
		return
	var done: Dictionary = await Net.rest(HTTPClient.METHOD_POST,
		"/rest/v1/rpc/shuffle_teams", {"p_session": _session.get("id", "")})
	_say(done.error if done.error != "" else "Teams shuffled.",
		Pal.WRONG if done.error != "" else Pal.CORRECT)
	# Too many rows to describe one by one: every lobby reads it again.
	_tell_reload()
	_load_teams()


func _say(text: String, col: Color) -> void:
	_msg.text = text
	_msg.add_theme_color_override("font_color", col)


## Leaving ends the session, so it asks -- the code stops working and anyone
## still in it is sent out. A session already over just leaves.
func go_back() -> void:
	if _session.is_empty() or Teams.expired(_session):
		main.open("admin")
		return
	var dim := Ui.dim(self)
	var ask := Ui.screen_panel(dim, Vector2(360, 170), "End this session?")
	var warn := Art.label("Code %s stops working and everyone in it is sent out. "
			% str(_session.get("code", "")) + "You can start a new session from the dashboard.",
			Pal.SMALL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warn.custom_minimum_size = Vector2(320, 0)
	ask.add_child(warn)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	var yes := Ui.button("End session", 140, Ui.H, Ui.RED)
	var no := Ui.button("Stay", 140, Ui.H, Ui.SMALL)
	yes.pressed.connect(func() -> void:
		dim.queue_free()
		_end_and_leave())
	no.pressed.connect(func() -> void: dim.queue_free())
	row.add_child(yes)
	row.add_child(no)
	ask.add_child(row)


func _end_and_leave() -> void:
	var sid: String = str(_session.get("id", ""))
	_tell("sessions", "UPDATE", {"id": sid, "state": "ended"})
	var done: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
		SESSIONS + "?id=eq." + sid, {"state": "ended"})
	if not is_instance_valid(self):
		return
	if done.error != "":
		_say(done.error, Pal.WRONG)
		return
	main.open("admin")

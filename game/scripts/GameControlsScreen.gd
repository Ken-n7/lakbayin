extends Control

## A session, from start to finish: Set Adventure Duration · Start / Pause /
## Resume / End, and the Teams panel.
##
## The dashboard's Start Session opens this with `{"new": true}`: the
## teacher's session still in its lobby is picked up again, code and all, and
## only when there is none is a fresh one made, with a four-character code to
## read out. Replacing it silently was how a code the class was typing died
## under them -- a second press, a second window, an app restart. Leaving this screen ends the session,
## after asking -- the dashboard is where the next one starts. Students type the code,
## then pick their own team; the teacher can Move anyone or Shuffle everyone
## until Start, which locks the teams. The clock is stored the way the schema
## wants it: `ends_at` while running, `remaining_s` while paused, so a phone
## that joins late computes the same countdown as everyone else.
##
## Start Game refuses on an incomplete bank rather than generating the
## difference -- the teacher authored those questions and gets to know.

const PANEL := Vector2(624, 344)
## The session column's width; the teams board takes the rest.
const SIDE_W := 196.0
## Four is the ceiling the client asked for, and they sit in one row: at this
## width four fit across a 640 canvas and the group stays centred however many
## there are.
const MAX_TEAMS := 4
const CARD_W := 188.0
## A player's line on a card: tall enough to tap, which the 14px rows were not.
const CHIP_H := 26.0
const SESSIONS := "/rest/v1/sessions"
const TEAMS := "/rest/v1/teams"

var main: Control

## The duration the fields show, in seconds. Mirrors the session row.
var duration_seconds := 600
var _min_field: LineEdit
var _sec_field: LineEdit
var _msg: Label
var _code_label: Label        # the join code, large
var _status: Label            # lobby · N/M ready / running / paused
var _clock: Label             # time left, once it is running
var _time_row: Control        # duration fields, before Start
var _why: Label               # what Start is waiting for
var _start_btn: Button
var _hold_btn: Button
var _end_btn: Button
var _teams_grid: GridContainer
var _add_btn: Button
var _shuffle_btn: Button
var _players: MenuButton       # everyone in the session, in the title bar
var _loose: HFlowContainer     # players who have not picked a team
var _session := {}
## The session's teams and players, kept current off the socket -- see `Lobby`.
var _lobby := Lobby.new()
## The session whose roster the socket is following, "" for none. Tracked by id
## because a new session (Start after an ended run) needs watching afresh.
var _watching := ""


## The map view (`MapWatch`) and the slim bar that stands in for the panel
## while it is up -- built the first time the teacher opens the map, then
## kept, so going back and forth costs nothing.
var _map: MapWatch = null
var _panel_root: Control
var _bar: Control
var _bar_status: Label
var _bar_code: Label
var _bar_start: Button         # the lobby's one red button
var _bar_hold: Button          # Pause / Resume, once it runs
var _bar_dot: Panel            # the state as a colour, beside its word
var _bar_end: Button
var _bar_note: Label           # why Start waits
var _bar_msg: Label            # the last thing said, for a few seconds


## Set by `setup({"new": true})` for the first build only; a tab switch
## rebuilds with `{}` and must not make another session.
var _fresh := false
## A session is being made right now -- the first second after Start Session.
var _making := false
## The session this screen is ending itself, so its own "ended" coming back
## over the socket is not mistaken for somebody else ending it.
var _ending_id := ""


func setup(data: Dictionary) -> void:
	if bool(data.get("new", false)):
		_fresh = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# No backdrop of its own: Main's moving scene shows through (Backdrop.gd).

	var box := Ui.screen_panel(self, PANEL, "Game Controls")
	_panel_root = get_child(get_child_count() - 1)

	# Title bar: ← on the title's own line (on the screen's corner it sat in
	# the dark margin, under the dev tab), the roll call on the right.
	var title_row := HBoxContainer.new()
	var back := Ui.glyph("←", 24, Pal.TITLE)
	back.custom_minimum_size = Vector2(40, 30)
	back.tooltip_text = "Leave (ends the session)"
	back.pressed.connect(go_back)
	title_row.add_child(back)
	var title: Control = box.get_child(0)      # the panel's own title label
	box.add_child(title_row)
	box.move_child(title_row, 0)
	title.reparent(title_row)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var view := Ui.button("View Map", 100, Ui.H, Ui.SMALL)
	view.tooltip_text = "Watch the class on the map"
	view.pressed.connect(_show_map.bind(true))
	title_row.add_child(view)
	_players = _players_menu()
	title_row.add_child(_players)

	# One screen, not two tabs. Whether Start will go depends on the teams,
	# so the teams sit beside it: the teacher used to flip tabs to find out.
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(body)
	body.add_child(_build_session_side())
	body.add_child(_build_teams_board())

	_msg = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(560, 0)
	box.add_child(_msg)

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


## The paper a card sits on -- a shade off the panel, so it reads as a thing.
func _card_face(border: Color = Pal.WOOD, width := 2) -> StyleBoxFlat:
	var face := StyleBoxFlat.new()
	face.bg_color = Pal.PARCHMENT
	face.border_color = border
	face.set_border_width_all(width)
	face.set_corner_radius_all(3)
	face.set_content_margin_all(6)
	return face


## Left column: the code to read out, where things stand, the clock, and the
## buttons -- Start first and biggest, since it is the one decision here.
func _build_session_side() -> Control:
	var side := PanelContainer.new()
	side.custom_minimum_size = Vector2(SIDE_W, 0)
	side.add_theme_stylebox_override("panel", _card_face())
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	side.add_child(col)

	col.add_child(Art.label("JOIN CODE", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	# Read out to a room of thirty: as big as the column allows.
	_code_label = Art.label("····", 32, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_code_label)
	_status = Art.label("", Pal.LABEL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_status)

	# Before Start: how long it will run. After: how long is left.
	var fields := HBoxContainer.new()
	fields.alignment = BoxContainer.ALIGNMENT_CENTER
	fields.add_theme_constant_override("separation", 4)
	_min_field = Ui.number_field(46)
	_sec_field = Ui.number_field(46)
	fields.add_child(_min_field)
	fields.add_child(Art.label("min", Pal.SMALL, Pal.INK_MUTED))
	fields.add_child(_sec_field)
	fields.add_child(Art.label("sec", Pal.SMALL, Pal.INK_MUTED))
	# The fields and the clock swap in one fixed-height slot, and the reason
	# under Start keeps its two lines even when empty: the column is the same
	# height in every state, so the panel never grows past the canvas.
	var slot := Control.new()
	slot.custom_minimum_size = Vector2(0, 30)
	col.add_child(slot)
	fields.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_time_row = fields
	slot.add_child(fields)
	_show_time()
	_clock = Art.label("", 24, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	_clock.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_clock.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_clock.visible = false
	slot.add_child(_clock)

	var gap := Control.new()
	gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(gap)

	_start_btn = Ui.button("Start Game", SIDE_W - 12, Ui.H, Ui.RED)
	_start_btn.pressed.connect(func() -> void: _set_state("running", true))
	col.add_child(_start_btn)
	# The reason, where the eye already is -- not only in a popup after a
	# press that did nothing.
	_why = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_why.custom_minimum_size = Vector2(SIDE_W - 12, 36)
	col.add_child(_why)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_hold_btn = Ui.button("⏸ Pause", (SIDE_W - 18) / 2.0, Ui.H, Ui.SMALL)
	_hold_btn.pressed.connect(_toggle_hold)
	row.add_child(_hold_btn)
	_end_btn = Ui.button("End Game", (SIDE_W - 18) / 2.0, Ui.H, Ui.SMALL_RED)
	_end_btn.pressed.connect(_confirm_end)
	row.add_child(_end_btn)
	col.add_child(row)
	return side


## Right side: every team as a card of its players, the unassigned below, and
## the two team tools in the header, where they act on the whole board.
func _build_teams_board() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var label := Art.label("Teams", Pal.H2, Pal.TITLE)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(label)
	_add_btn = Ui.button("+ Team", 90, Ui.H, Ui.SMALL)
	_add_btn.pressed.connect(_add_team)
	head.add_child(_add_btn)
	# For when picking freely has put all the friends on one side.
	_shuffle_btn = Ui.button("Shuffle", 90, Ui.H, Ui.SMALL)
	_shuffle_btn.pressed.connect(_shuffle)
	head.add_child(_shuffle_btn)
	col.add_child(head)

	# Four teams of six outgrow the board, so it scrolls rather than spills.
	var scroll := ScrollContainer.new()
	DragScroll.attach(scroll)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 6)
	scroll.add_child(inner)
	# The unassigned first: they are the ones who need the teacher, and below
	# a scrolled board they were out of sight.
	_loose = HFlowContainer.new()
	inner.add_child(_loose)
	_teams_grid = GridContainer.new()
	_teams_grid.columns = 2
	_teams_grid.add_theme_constant_override("h_separation", 8)
	_teams_grid.add_theme_constant_override("v_separation", 8)
	inner.add_child(_teams_grid)
	return col


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
	if state == "lobby":
		_making = false
		_adopt(live)
		_say("Your session is still open — same code.", Pal.CORRECT)
		return
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
		_ending_id = str(_session.get("id", ""))
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
	if _map != null:
		_map.watch(str(row.get("id", "")))
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
	# Its own row too: the code on this screen has to be a code that works.
	rt.watch("sessions", "id=eq." + sid)


## Applied from the message: a student joining or switching shows at once,
## with no fetch. Only a newcomer, whose name the message lacks, costs one.
func _on_roster_row(table: String, type: String, record: Dictionary) -> void:
	if not is_instance_valid(self):
		return
	if table == "sessions":
		_on_own_session(type, record)
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
	_paper_popup(m.get_popup())
	m.text = "Players (0) ▾"
	return m


## Parchment on a dropdown's list too, hover included.
static func _paper_popup(pop: PopupMenu) -> void:
	pop.add_theme_stylebox_override("panel", Ui._paper_box(false))
	pop.add_theme_color_override("font_color", Pal.INK)
	pop.add_theme_color_override("font_hover_color", Pal.TITLE)
	pop.add_theme_font_size_override("font_size", Art.MIN_FONT)
	var lit := Ui._paper_box(false)
	lit.bg_color = Pal.PARCHMENT.darkened(0.12)
	lit.set_border_width_all(0)
	pop.add_theme_stylebox_override("hover", lit)


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
	var now := Game.now()
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
	if want == "ended":
		_ending_id = str(_session.get("id", ""))
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
	# Teams are locked from here on: the map is the thing to watch.
	if is_start and done.error == "":
		_show_map(true)


func _patch(fields: Dictionary) -> Dictionary:
	var done: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
		SESSIONS + "?id=eq." + str(_session.get("id", "")), fields)
	if done.error != "":
		_say(done.error, Pal.WRONG)
	elif done.data is Array and not (done.data as Array).is_empty():
		_session = done.data[0]
	return done


## Everything on the session side follows the state from here: the code, the
## status line, the clock or the duration, Start and why it waits, and the
## two run buttons.
func _refresh_state() -> void:
	var state := str(_session.get("state", ""))
	# Out of time is over, whatever the row says -- the same rule the players
	# go by, so nothing is offered for a dead clock.
	if _session.is_empty() or Teams.expired(_session):
		state = "ended"
	# The music follows the session as the players' phones do: battle songs in
	# the lobby, The Journey once it runs, Victory! once it is over.
	if main != null:
		main.music.play("battle" if _making or state == "lobby"
			else "journey" if state == "running" or state == "paused"
			else "town" if _session.is_empty() else "victory")
	var r := _readiness()
	var total: int = _lobby.players.size()
	if is_instance_valid(_code_label):
		_code_label.text = str(_session.get("code", "····")) if state != "ended" else "····"
		if _making:
			_status.text = "Making a session…"
		elif state == "ended":
			_status.text = "Session ended — ← to start again"
		elif state == "lobby":
			_status.text = "Lobby  ·  %d/%d ready" % [r.ready.size(), total]
		else:
			_status.text = state.capitalize() + ("  ·  %d playing" % total)
		_status.add_theme_color_override("font_color",
			Pal.CORRECT if state == "running" else Pal.WRONG if state == "paused" else Pal.INK)
		# The duration is set before Start; after it, the clock takes its place.
		var live := state == "running" or state == "paused"
		_time_row.visible = not live
		_clock.visible = live
		_tick_clock()
	if is_instance_valid(_shuffle_btn):
		_shuffle_btn.disabled = state != "lobby"
		_add_btn.disabled = state == "ended" or _lobby.teams.size() >= MAX_TEAMS
	_fill_players()
	if not is_instance_valid(_start_btn):
		return
	# Start waits for everyone connected to be on the map, and says so here.
	# Only the not-connected is left to the dialog ("Start without them").
	_start_btn.disabled = state != "lobby" or total == 0 or not r.lobby.is_empty()
	_why.text = _start_reason(state, r, total)
	_hold_btn.disabled = state != "running" and state != "paused"
	_hold_btn.text = "▶ Resume" if state == "paused" else "⏸ Pause"
	# Nothing to end until it has started: before Start, leaving is how a
	# session goes.
	_end_btn.disabled = state != "running" and state != "paused"
	_sync_bar()


func _start_reason(state: String, r: Dictionary, total: int) -> String:
	if _making or state != "lobby":
		return ""
	if total == 0:
		return "Waiting for students to join"
	if not r.lobby.is_empty():
		return "Waiting for %s to enter the map" % _names(r.lobby)
	if not r.away.is_empty():
		return "%s not connected" % _names(r.away)
	return "Everyone is ready!"


## "a, b and 3 more" -- a line, not a paragraph, however big the class.
static func _names(list: Array) -> String:
	if list.size() <= 2:
		return " and ".join(list)
	return "%s, %s and %d more" % [list[0], list[1], list.size() - 2]


## Time left, off the session row: the deadline while running, what the
## pause banked while paused. The same numbers the players' clocks read.
func _tick_clock() -> void:
	if not is_instance_valid(_clock) or not _clock.visible:
		return
	var left := 0
	if str(_session.get("state", "")) == "paused":
		var banked: Variant = _session.get("remaining_s")
		left = int(banked) if banked != null else 0
	else:
		left = maxi(Teams._stamp(_session.get("ends_at")) - int(Game.now()), 0)
	_clock.text = Ui.mmss(left) + (" paused" if str(_session.get("state", "")) == "paused" else " left")
	_sync_bar()


var _since_tick := 0.0


func _process(delta: float) -> void:
	_since_tick += delta
	if _since_tick >= 0.5:
		_since_tick = 0.0
		_tick_clock()


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
			_loose.add_child(Art.label("No team yet:", Pal.SMALL, Pal.WRONG))
			for who: Dictionary in loose:
				_loose.add_child(_player_chip(who, "", teams))
	if teams.is_empty() and is_instance_valid(_teams_grid):
		_teams_grid.add_child(Art.label("No teams — press + Team.", Pal.SMALL, Pal.INK_MUTED))
	_refresh_state()      # "+ Team" and the ready counts follow the board


func _team_card(t: Dictionary, members: Array, teams: Array) -> Control:
	var id: String = str(t.get("id", ""))
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(CARD_W, 0)
	card.add_theme_stylebox_override("panel", _card_face())
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	card.add_child(col)

	# The name, editable -- it is what the class sees -- with remove beside
	# it at a size a thumb can hit (the corner × was 16px).
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 4)
	var field := Ui.line_edit("Team Name", CARD_W - 50, 26, 14)
	field.text = str(t.get("name", ""))
	field.max_length = 18
	# Saved on Enter and on leaving the field, so a teacher who taps away does
	# not silently lose the name they just typed.
	field.text_submitted.connect(func(v: String) -> void: _rename(id, v))
	field.focus_exited.connect(func() -> void: _rename(id, field.text))
	top.add_child(field)
	var del := Ui.glyph("×", 20, Pal.WRONG)
	del.custom_minimum_size = Vector2(30, 28)
	del.tooltip_text = "Remove team"
	del.pressed.connect(func() -> void: _remove_team(id, str(t.get("name", "")), members))
	top.add_child(del)
	col.add_child(top)

	# The count is what a teacher scans: five of six means somebody is still on
	# the login screen. Each name is a menu, for Move.
	var ready := members.filter(func(m: Dictionary) -> bool: return _is_ready(m.profile_id)).size()
	col.add_child(Art.label("%d joined  ·  %d ready" % [members.size(), ready], Pal.SMALL,
			Pal.INK_MUTED if members.is_empty() else Pal.CORRECT))
	for who: Dictionary in members:
		col.add_child(_player_chip(who, id, teams))
	return card


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
## ✓ ready (on the map), ● in the lobby, ○ not connected: a mark and a colour,
## never the colour alone.
func _player_chip(who: Dictionary, on_team: String, teams: Array) -> Control:
	var chip := MenuButton.new()
	chip.flat = true
	var pid: String = str(who.get("profile_id", ""))
	var here: bool = _is_here(pid)
	var ready := _is_ready(pid)
	chip.text = ("✓ " if ready else "● " if here else "○ ") + str(who.get("username", "?"))
	chip.add_theme_font_size_override("font_size", Art.MIN_FONT)
	var ink: Color = Pal.CORRECT if ready else Pal.INK if here else Pal.INK_MUTED
	for c in ["font_color", "font_pressed_color", "font_focus_color"]:
		chip.add_theme_color_override(c, ink)
	chip.add_theme_color_override("font_hover_color", Pal.WRONG)
	chip.add_theme_color_override("font_disabled_color", ink)
	chip.alignment = HORIZONTAL_ALIGNMENT_LEFT
	chip.custom_minimum_size = Vector2(0, CHIP_H)
	chip.disabled = str(_session.get("state", "")) != "lobby"
	chip.tooltip_text = "Move to another team" if not chip.disabled else "Teams are locked"
	var menu := chip.get_popup()
	_paper_popup(menu)
	var ids: Array = []
	for t: Dictionary in teams:
		if str(t.get("id", "")) == on_team:
			continue
		menu.add_item("Move to " + str(t.get("name", "")), ids.size())
		ids.append(str(t.get("id", "")))
	menu.id_pressed.connect(func(i: int) -> void: _move(pid, ids[i]))
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
	# On the map the panel is away: say it in the bar, then let it go.
	if _bar != null and _bar.visible:
		_bar_msg.text = text
		_bar_msg.modulate.a = 1.0
		_bar_msg.create_tween().tween_property(_bar_msg, "modulate:a", 0.0, 1.0).set_delay(4.0)


## Leaving ends the session, so it asks -- the code stops working and anyone
## still in it is sent out. A session already over just leaves.
func go_back() -> void:
	# From the map, back is back to the controls -- not "end the session?".
	if _map != null and _map.visible:
		_show_map(false)
		return
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
	_ending_id = sid
	_tell("sessions", "UPDATE", {"id": sid, "state": "ended"})
	var done: Dictionary = await Net.rest(HTTPClient.METHOD_PATCH,
		SESSIONS + "?id=eq." + sid, {"state": "ended"})
	if not is_instance_valid(self):
		return
	if done.error != "":
		_say(done.error, Pal.WRONG)
		return
	main.open("admin")


# --- Map view ---------------------------------------------------------------
## The map in place of the panel, with what the teacher needs mid-game kept
## in a bar across the top: the code, where things stand, Start / Pause /
## Resume, End, and the way back to everything else.
func _show_map(on: bool) -> void:
	if on and _map == null:
		_map = MapWatch.new()
		add_child(_map)
		move_child(_map, 0)             # under the bar and every dialog
		_build_bar()
	if _map == null:
		return
	if on:
		_map.watch(str(_session.get("id", "")))
	_map.set_shown(on)
	_bar.visible = on
	_panel_root.visible = not on
	if main != null:
		main.backdrop.set_shown(not on)
	_sync_bar()


func _build_bar() -> void:
	var top := VBoxContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 8.0
	top.offset_right = -8.0
	top.offset_top = 6.0
	top.add_theme_constant_override("separation", 2)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top)
	_bar = top

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(row)
	# Back where back is on every screen: the top left.
	var back := Ui.button("← Controls", 100, Ui.H, Ui.SMALL)
	back.tooltip_text = "Teams, duration and the full controls"
	back.pressed.connect(_show_map.bind(false))
	row.add_child(back)
	_bar_code = Art.label("", Pal.BODY, Pal.GOLD)
	row.add_child(Ui.plank(_bar_code, 10.0))
	var state := HBoxContainer.new()
	state.add_theme_constant_override("separation", 6)
	_bar_dot = Panel.new()
	_bar_dot.custom_minimum_size = Vector2(10, 10)
	_bar_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	state.add_child(_bar_dot)
	_bar_status = Art.label("", Pal.SMALL, Pal.CREAM)
	state.add_child(_bar_status)
	row.add_child(Ui.plank(state, 10.0))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gap)
	_bar_start = Ui.button("Start Game", 100, Ui.H, Ui.SMALL_RED)
	_bar_start.pressed.connect(func() -> void: _set_state("running", true))
	row.add_child(_bar_start)
	_bar_hold = Ui.button("⏸ Pause", 92, Ui.H, Ui.SMALL)
	_bar_hold.pressed.connect(_toggle_hold)
	row.add_child(_bar_hold)
	# The one that cannot be undone, set apart from the one that can.
	var apart := Control.new()
	apart.custom_minimum_size = Vector2(6, 0)
	apart.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(apart)
	_bar_end = Ui.button("End", 56, Ui.H, Ui.SMALL_RED)
	_bar_end.pressed.connect(_confirm_end)
	row.add_child(_bar_end)

	_bar_note = Art.label("", Pal.SMALL, Pal.CREAM, HORIZONTAL_ALIGNMENT_RIGHT)
	Art.shadow(_bar_note)
	_bar_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(_bar_note)
	_bar_msg = Art.label("", Pal.SMALL, Pal.CREAM, HORIZONTAL_ALIGNMENT_RIGHT)
	Art.shadow(_bar_msg)
	_bar_msg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(_bar_msg)


## The bar says what the panel says -- read off the panel's own labels and
## buttons, so the two can never disagree about the state.
func _sync_bar() -> void:
	if _bar == null or not _bar.visible:
		return
	var state := str(_session.get("state", ""))
	_bar_code.text = "Code " + _code_label.text
	var lobby := state == "lobby"
	# Short, so the bar fits a 640-wide phone: the head count is on Controls.
	_bar_status.text = state.capitalize() + "  ·  " + _clock.text.get_slice(" ", 0) \
		if _clock.visible else _status.text
	_bar_start.visible = lobby
	_bar_start.disabled = _start_btn.disabled
	_bar_hold.visible = not lobby
	_bar_hold.text = _hold_btn.text
	_bar_hold.disabled = _hold_btn.disabled
	_bar_end.visible = not lobby
	var dot := StyleBoxFlat.new()
	dot.set_corner_radius_all(5)
	dot.border_color = Color(0, 0, 0, 0.6)
	dot.set_border_width_all(1)
	dot.bg_color = Pal.CORRECT_BRIGHT if state == "running" \
		else Pal.GOLD if state == "paused" or lobby else Pal.INK_MUTED
	_bar_dot.add_theme_stylebox_override("panel", dot)
	_bar_end.disabled = _end_btn.disabled
	_bar_note.text = _why.text


# --- The code has to work ----------------------------------------------------
## The session row, changed anywhere -- another window paused it, or ended
## it. Ended by somebody else means the code on this screen is dead, and the
## teacher is told at once rather than finding out from thirty students.
func _on_own_session(type: String, record: Dictionary) -> void:
	var sid := str(_session.get("id", ""))
	if sid == "" or str(record.get("id", sid)) != sid:
		return
	if type == "DELETE" or str(record.get("state", "")) == "ended":
		_session["state"] = "ended"
		_refresh_state()
		if sid != _ending_id:
			_lost_session()
		return
	_session.merge(record, true)
	_refresh_state()


## Back from the background, or the socket was down: read the row again.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_recheck()


func _recheck() -> void:
	var sid := str(_session.get("id", ""))
	if sid == "" or str(_session.get("state", "")) == "ended" or not Net.signed_in():
		return
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET, SESSIONS + "?select=*&id=eq." + sid)
	if not is_instance_valid(self) or got.error != "":
		return
	var rows: Array = got.data if got.data is Array else []
	_on_own_session("DELETE" if rows.is_empty() else "UPDATE",
		{"id": sid} if rows.is_empty() else rows[0])


func _lost_session() -> void:
	var dim := Ui.dim(self)
	var ask := Ui.screen_panel(dim, Vector2(390, 190), "This code no longer works")
	var body := Art.label(("Session %s was ended somewhere else — another screen signed in "
			% str(_session.get("code", "")) + "as you started or ended one. Students cannot "
			+ "join it any more."), Pal.SMALL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(350, 0)
	ask.add_child(body)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	var go := Ui.button("Open a session", 170, Ui.H, Ui.RED)
	go.pressed.connect(func() -> void:
		dim.queue_free()
		_session = {}
		_making = true
		_refresh_state()
		_open_fresh())
	row.add_child(go)
	var home := Ui.button("Dashboard", 110, Ui.H, Ui.SMALL)
	home.pressed.connect(func() -> void: main.open("admin"))
	row.add_child(home)
	ask.add_child(row)

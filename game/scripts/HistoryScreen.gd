extends Control

## The Quest Keeper's History (client): every session they hosted that was
## actually played, newest first -- when, how it ended, how many played, and
## the top team and top player (by gems, for now). Tapping one opens its full
## results on the Leaderboard screen. The live board is on Game Controls.
##
## "Played" is started (it has a deadline) with somebody in it, and over. How
## it ended:
##   Completed    everyone who played was done: through the Gate, or out
##   Time's up    the clock ran out
##   Ended early  End was pressed with time still left (running or paused)
##   Ended        ended before the server stamped `ended_at` -- older sessions

const SESSIONS := "/rest/v1/sessions"
const SCORES := "/rest/v1/team_scores"
const LIMIT := 40
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var main: Control
var _list: VBoxContainer


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := Ui.back_panel(self, Vector2(600, 330), "History", go_back)
	box.add_theme_constant_override("separation", 6)
	var scroll := Ui.scroll(box, 250)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)
	_note("Loading your sessions…")
	_load()


func _load() -> void:
	if not (Net.configured() and Net.signed_in()):
		_note("Sign in to see the sessions you hosted.")
		return
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET, SESSIONS
		+ "?select=id,created_at,ends_at,ended_at,state,remaining_s,"
		+ "members(gems,eliminated,items_done,finished,profiles(username))"
		+ "&admin_id=eq." + Net.user_id + "&order=created_at.desc&limit=%d" % LIMIT)
	if not is_instance_valid(_list):
		return
	if got.error != "":
		_note("Could not load your sessions — " + got.error)
		return
	var played: Array = []
	for s: Dictionary in (got.data if got.data is Array else []):
		if s.get("ends_at") != null and not (s.get("members", []) as Array).is_empty() \
				and Teams.expired(s):
			played.append(s)
	if played.is_empty():
		_note("No sessions played yet. They appear here once one ends.")
		return
	# Every played session's best team in one read, best first.
	var ids := PackedStringArray(played.map(func(s: Dictionary) -> String: return str(s.id)))
	var scores: Dictionary = await Net.rest(HTTPClient.METHOD_GET, SCORES
		+ "?select=session_id,name,gems&session_id=in.(" + ",".join(ids) + ")&order=gems.desc")
	if not is_instance_valid(_list):
		return
	var top_team := {}
	for t: Dictionary in (scores.data if scores.data is Array else []):
		if not top_team.has(str(t.session_id)):
			top_team[str(t.session_id)] = t
	for c in _list.get_children():
		c.queue_free()
	for s: Dictionary in played:
		_list.add_child(_card(s, top_team.get(str(s.id), {})))


## One session: when and how it ended on the left, its best team and player
## beside, the whole card a button into its results.
func _card(s: Dictionary, team: Dictionary) -> Control:
	var members: Array = s.get("members", [])
	var best := {}
	for m: Dictionary in members:
		if best.is_empty() or Teams.final_gems(m) > Teams.final_gems(best):
			best = m
	var ended := _how_it_ended(s, members)

	var card := Button.new()
	card.custom_minimum_size = Vector2(0, 58)
	card.focus_mode = Control.FOCUS_NONE
	for state in ["normal", "hover", "pressed", "focus"]:
		var face := StyleBoxFlat.new()
		face.bg_color = Pal.PAPER if state != "pressed" else Pal.PARCHMENT
		face.border_color = Pal.WOOD
		face.set_border_width_all(2)
		face.set_corner_radius_all(4)
		face.content_margin_left = 10
		face.content_margin_right = 10
		card.add_theme_stylebox_override(state, face)
	Ui.click(card)
	card.pressed.connect(func() -> void:
		main.open("board", {"session": str(s.id), "title": "Results · " + _when(s),
			"back": "history", "live": false}))

	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 10
	row.offset_right = -10
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(row)

	var when := _column(row, 150)
	when.add_child(_text(_when(s), Pal.LABEL, Pal.TITLE))
	when.add_child(_text("%s · %d played" % [ended[0], members.size()], Pal.SMALL, ended[1]))

	var top := _column(row, 170)
	top.add_child(_text("Top team", Pal.SMALL, Pal.INK_MUTED))
	top.add_child(_text("%s · %d" % [team.get("name", "—"), int(team.get("gems", 0))]
		if not team.is_empty() else "—", Pal.LABEL, Pal.INK))

	var star := _column(row, 170)
	star.add_child(_text("Top player", Pal.SMALL, Pal.INK_MUTED))
	var who: Variant = best.get("profiles")
	star.add_child(_text("%s · %d" % [(who as Dictionary).get("username", "?") if who is Dictionary
		else "?", Teams.final_gems(best)], Pal.LABEL, Pal.INK))

	var more := _text("→", Pal.H2, Pal.WOOD)
	more.size_flags_horizontal = Control.SIZE_SHRINK_END
	row.add_child(more)
	return card


## [label, colour]: see the class comment.
static func _how_it_ended(s: Dictionary, members: Array) -> Array:
	if members.all(func(m: Dictionary) -> bool:
			return bool(m.get("finished", false)) or bool(m.get("eliminated", false))):
		return ["Completed", Pal.CORRECT]
	if str(s.get("state", "")) == "ended":
		var ended_at := Teams._stamp(s.get("ended_at"))
		var left: Variant = s.get("remaining_s")
		if (left != null and int(left) > 0) \
				or (ended_at > 0 and ended_at < Teams._stamp(s.get("ends_at"))):
			return ["Ended early", Pal.WRONG]
		if ended_at == 0:
			return ["Ended", Pal.INK_MUTED]
	return ["Time's up", Pal.INFO_DEEP]


## "Sep 26 · 2:10 PM", in this device's time zone.
static func _when(s: Dictionary) -> String:
	var at: int = Teams._stamp(s.get("created_at")) + int(Time.get_time_zone_from_system().bias) * 60
	var d := Time.get_datetime_dict_from_unix_time(at)
	var h := int(d.hour) % 12
	return "%s %d · %d:%02d %s" % [MONTHS[int(d.month) - 1], d.day, 12 if h == 0 else h,
		d.minute, "PM" if int(d.hour) >= 12 else "AM"]


func _column(row: Control, w: float) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(w, 0)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	return col


func _text(t: String, size: int, col: Color) -> Label:
	var l := Art.label(t, size, col)
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _note(t: String) -> void:
	for c in _list.get_children():
		c.queue_free()
	var l := Art.label(t, Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_list.add_child(l)


func go_back() -> void:
	main.open("admin")

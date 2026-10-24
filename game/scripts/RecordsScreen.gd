extends Control

var main: Control
var _tab := "my_matches"
var _offset := 0
var _version := 0
var _more := false          # the server has rows past the ones shown
var _fetching := false
var _tail: Label            # "Loading…" under the last row while more come
var _message: Label
var _list: VBoxContainer
var _scroll: ScrollContainer
var _summary: HBoxContainer


## One screen, two uses: Player Records (your profile and matches) and,
## with {"tab": "player_board"}, the Leaderboard -- opened from Home's trophy.
func setup(options: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tab = str(options.get("tab", "my_matches"))
	var box := Ui.back_panel(self, Vector2(600,330),
			"Leaderboard" if _tab == "player_board" else "Player Records", go_back)
	box.add_theme_constant_override("separation", 6)
	# A MOBA profile's strip: games, wins, win rate, words -- My Matches only.
	_summary = HBoxContainer.new()
	_summary.alignment = BoxContainer.ALIGNMENT_CENTER
	_summary.add_theme_constant_override("separation", 6)
	box.add_child(_summary)
	_message = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_message)
	# Infinite scroll: 20 rows at a time, the next 20 fetched as the list
	# nears its end -- no page buttons. Opening the screen reloads it.
	_scroll = Ui.scroll(box, 220)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	_scroll.add_child(_list)
	_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _near_end())
	_load()


const PAGE := 20
const NEAR_END_PX := 60.0


func _load() -> void:
	_version += 1
	var version := _version
	_offset = 0
	_more = false
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	if not Net.signed_in():
		_message.text = "Sign in to see match records."
		return
	_message.visible = true
	_message.text = "Loading…"
	_load_summary(version)
	await _fetch(version)


## The next PAGE rows, added under the ones shown.
func _fetch(version: int) -> void:
	_fetching = true
	var got := await Net.rest(HTTPClient.METHOD_POST,"/rest/v1/rpc/"+_tab,{"p_offset":_offset})
	if not is_inside_tree() or version != _version:
		return
	_fetching = false
	if got.error != "":
		_message.visible = true
		_message.text = "Could not load records. Open this screen again to retry."
		_set_tail("")
		return
	_show(got.data if got.data is Array else [])


## Scrolled close to the bottom with more to come: fetch them.
func _near_end() -> void:
	if not _more or _fetching:
		return
	var bar := _scroll.get_v_scroll_bar()
	if bar.value + bar.page >= bar.max_value - NEAR_END_PX:
		_set_tail("Loading…")
		_fetch(_version)


## `rows` is a page from the server (up to PAGE + 1: the extra says more
## exist). The first page replaces the list; later ones are added to it.
func _show(rows: Array) -> void:
	var history := _tab == "my_matches"
	if _offset == 0:
		for child in _list.get_children():
			_list.remove_child(child)
			child.queue_free()
		_message.text = "" if history else "Ranked games · wins, then words deposited"
		_message.visible = not history
		_scroll.scroll_vertical = 0
		if rows.is_empty():
			_list.add_child(Art.label("No completed matches yet." if history else "No completed matchmade games yet.",Pal.BODY,Pal.INK))
	_set_tail("")
	for p: Dictionary in rows.slice(0, PAGE):
		_list.add_child(_match_row(p) if history else _ladder_row(p))
	_more = rows.size() > PAGE
	_offset += mini(rows.size(), PAGE)
	# A short first page may not fill the view, so no scroll would ask for
	# the rest: check once the rows are laid out.
	if _more:
		_near_end.call_deferred()


func _set_tail(text: String) -> void:
	if is_instance_valid(_tail):
		_tail.queue_free()
		_tail = null
	if text != "":
		_tail = Art.label(text, Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		_list.add_child(_tail)


## One match, as a MOBA history row: a stripe in its result's colour, the
## result, ranked or custom, and how you did.
func _match_row(p: Dictionary) -> Control:
	var result := str(p.get("result","draw"))
	var colour: Color = {"win": Pal.CORRECT, "loss": Pal.WRONG}.get(result, Pal.INK_MUTED)
	var row := _row_panel(false)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	row.add_child(line)
	var stripe := ColorRect.new()
	stripe.color = colour
	stripe.custom_minimum_size = Vector2(5, 0)
	line.add_child(stripe)
	var what := Art.title(Art.label({"win": "Victory", "loss": "Defeat"}.get(result, "Draw"), Pal.LABEL + 2, colour))
	what.custom_minimum_size.x = 92
	what.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(what)
	var middle := VBoxContainer.new()
	middle.add_theme_constant_override("separation", 0)
	middle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(middle)
	var kind := "Custom" if bool(p.get("custom",false)) else "Ranked"
	middle.add_child(Art.label("%s  ·  room %s" % [kind, str(p.get("code",""))] if kind == "Custom" else kind,
			Pal.SMALL, Pal.INK))
	var date := str(p.get("completed_at","")).left(16).replace("T"," ") + " UTC"
	middle.add_child(Art.label(date, Pal.TINY, Pal.INK_MUTED))
	var how := Art.label("rank %d  ·  %d words" % [int(p.get("place",0)), int(p.get("deposited",0))],
			Pal.SMALL, Pal.INK, HORIZONTAL_ALIGNMENT_RIGHT)
	how.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(how)
	return row


## One player on the ladder: the place (gold, silver and bronze for the top
## three), the name, and the record. You are on the gold-trimmed paper.
func _ladder_row(p: Dictionary) -> Control:
	var me := str(p.get("profile_id","")) == Net.user_id
	var place := int(p.get("place",0))
	var row := _row_panel(me)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	row.add_child(line)
	var podium: Color = Pal.PODIUM[place - 1] if place >= 1 and place <= 3 else (Pal.GOLD if me else Pal.INK_MUTED)
	var num := Art.title(Art.label("%d" % place, Pal.H2, podium,
			HORIZONTAL_ALIGNMENT_CENTER))
	num.custom_minimum_size.x = 40
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(num)
	var name := Art.label(("★ " if me else "") + str(p.get("username","?")), Pal.BODY, Pal.GOLD if me else Pal.INK)
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(name)
	var rec := Art.label("%d wins  ·  %d deposited  ·  %d games" % [int(p.get("wins",0)),
			int(p.get("deposited",0)), int(p.get("played",0))], Pal.SMALL, Pal.CREAM if me else Pal.INK_MUTED,
			HORIZONTAL_ALIGNMENT_RIGHT)
	rec.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(rec)
	return row


func _row_panel(gold: bool) -> PanelContainer:
	var row := PanelContainer.new()
	row.custom_minimum_size.y = 34
	var face := Ui.face("res://assets/ui/SpecialPaper.png" if gold else "res://assets/ui/RegularPaper.png",
			Color.WHITE if gold else Ui._TAN)
	face.content_margin_left = 8
	face.content_margin_right = 12
	face.content_margin_top = 1
	face.content_margin_bottom = 1
	row.add_theme_stylebox_override("panel", face)
	return row


## The strip over My Matches: games, wins, win rate and words, from every
## completed game (custom too).
func _load_summary(version: int) -> void:
	for c in _summary.get_children():
		_summary.remove_child(c)
		c.queue_free()
	_summary.visible = _tab == "my_matches"
	if not _summary.visible:
		return
	var got := await Net.rest(HTTPClient.METHOD_POST, "/rest/v1/rpc/my_summary", {})
	if not is_inside_tree() or version != _version or got.error != "" or not (got.data is Dictionary):
		return
	var d: Dictionary = got.data
	var played := int(d.get("played", 0))
	var rate := "%d%%" % roundi(100.0 * int(d.get("wins", 0)) / played) if played > 0 else "—"
	for stat: Array in [["Games", str(played)], ["Wins", str(int(d.get("wins", 0)))],
			["Win rate", rate], ["Words", str(int(d.get("deposited", 0)))]]:
		_summary.add_child(Ui.stat_plank("", "%s  %s" % stat, Pal.SMALL))


func go_back() -> void:
	main.open("home")

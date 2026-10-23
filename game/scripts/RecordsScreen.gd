extends Control

var main: Control
var _tab := "my_matches"
var _offset := 0
var _version := 0
var _history: Button
var _board: Button
var _previous: Button
var _next: Button
var _page: Label
var _message: Label
var _list: VBoxContainer
var _scroll: ScrollContainer


func setup(_options: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := Ui.screen_panel(self, Vector2(600,330), "Player Records")
	box.add_theme_constant_override("separation", 6)
	_history = Ui.button("My Matches", 180, Ui.H, Ui.SMALL)
	_board = Ui.button("Global Players", 180, Ui.H, Ui.SMALL)
	Ui.centre_row(box, _history).add_child(_board)
	_history.pressed.connect(func() -> void: _select("my_matches"))
	_board.pressed.connect(func() -> void: _select("player_board"))
	_message = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_message)
	_scroll = Ui.scroll(box, 156)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	_scroll.add_child(_list)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	_previous = Ui.button("Previous", 100, Ui.H, Ui.SMALL)
	_previous.pressed.connect(func() -> void:
		_offset = maxi(0,_offset-20)
		_load())
	row.add_child(_previous)
	_page = Art.label("Page 1", Pal.SMALL, Pal.INK)
	_page.custom_minimum_size.x = 62
	_page.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_page)
	_next = Ui.button("Next", 100, Ui.H, Ui.SMALL)
	_next.pressed.connect(func() -> void:
		_offset += 20
		_load())
	row.add_child(_next)
	var refresh := Ui.button("Refresh", 90, Ui.H, Ui.SMALL)
	refresh.pressed.connect(_load)
	row.add_child(refresh)
	var back := Ui.button("Home", 90, Ui.H, Ui.SMALL)
	back.pressed.connect(go_back)
	row.add_child(back)
	_load()


func _select(tab: String) -> void:
	_tab = tab
	_offset = 0
	_load()


func _load() -> void:
	_version += 1
	var version := _version
	_history.disabled = _tab == "my_matches"
	_board.disabled = _tab == "player_board"
	_previous.disabled = true
	_next.disabled = true
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	if not Net.signed_in():
		_message.text = "Sign in to see match records."
		return
	_message.text = "Loading…"
	var got := await Net.rest(HTTPClient.METHOD_POST,"/rest/v1/rpc/"+_tab,{"p_offset":_offset})
	if not is_inside_tree() or version != _version:
		return
	if got.error != "":
		_message.text = "Could not load records. Press Refresh to retry."
		_previous.disabled = _offset == 0
		return
	_show(got.data if got.data is Array else [])


func _show(rows: Array) -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	var history := _tab == "my_matches"
	_message.text = ("Completed games · Custom rooms are tagged" if history else "Matchmade games · wins, then deposited answers")
	_page.text = "Page %d" % (_offset / 20 + 1)
	_previous.disabled = _offset == 0
	_next.disabled = rows.size() <= 20
	_scroll.scroll_vertical = 0
	if rows.is_empty():
		_list.add_child(Art.label("No completed matches yet." if history else "No completed matchmade games yet.",Pal.BODY,Pal.INK))
	for p: Dictionary in rows.slice(0,20):
		var panel := PanelContainer.new()
		panel.add_theme_stylebox_override("panel",Ui._paper_box(false))
		_list.add_child(panel)
		var content := VBoxContainer.new()
		content.add_theme_constant_override("separation",0)
		panel.add_child(content)
		if history:
			var result := str(p.get("result","draw")).capitalize()
			var kind := "Custom" if bool(p.get("custom",false)) else "Matchmade"
			content.add_child(Art.label("%s  ·  %s  ·  %s" % [result,kind,str(p.get("code",""))],Pal.BODY,
				Pal.CORRECT_BRIGHT.darkened(0.5) if result == "Win" else Pal.INK))
			var date := str(p.get("completed_at","")).left(16).replace("T"," ") + " UTC"
			content.add_child(Art.label("%s  ·  rank %d  ·  deposited %d" % [date,int(p.get("place",0)),int(p.get("deposited",0))],Pal.SMALL,Pal.INK_MUTED))
		else:
			var me := str(p.get("profile_id","")) == Net.user_id
			var name := Art.label("%d.  %s%s" % [int(p.get("place",0)),"★ " if me else "",str(p.get("username","?"))],Pal.BODY,Pal.WRONG if me else Pal.INK)
			content.add_child(name)
			content.add_child(Art.label("%d wins  ·  %d deposited  ·  %d games" % [int(p.get("wins",0)),int(p.get("deposited",0)),int(p.get("played",0))],Pal.SMALL,Pal.INK_MUTED))


func go_back() -> void:
	main.open("home")

extends Control

## Per-station list of the bank, each row `prompt (Ans: x)` with Set / Edit /
## Delete, and an Add form of Enter Question · Enter Hint · Enter Answer.
##
## "Set" marks the question as one of the items the next adventure draws from
## (SPECS §11 Q5 -- no PDF defines the button; this is the recorded default).
## The label says what state it would move to, so a teacher can read the bank
## without a legend: an active row offers "Unset".

const PANEL := Vector2(600, 330)

var main: Control

var _list: VBoxContainer
var _msg: Label
var _station := 1
var _prompt: LineEdit
var _hint: LineEdit
var _answer: LineEdit
## The id being edited, or "" when the form is adding a new question.
var _editing := ""
var _add_btn: Button
var _cancel: Button
var _form_title: Label
var _tabs: HBoxContainer


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# No backdrop of its own: Main's moving scene shows through (Backdrop.gd).
	var box := Ui.back_panel(self, PANEL, "Question Bank", go_back)
	box.add_theme_constant_override("separation", 5)

	# The stations as tabs, and the sample-question seed as a quiet link
	# beside them -- it was a red button, the loudest thing on a screen whose
	# job is the teacher's own questions.
	var head := HBoxContainer.new()
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 18)
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_tabs)
	var seed_btn := Ui.link("Use sample questions")
	seed_btn.pressed.connect(_seed)
	head.add_child(seed_btn)
	box.add_child(head)
	_draw_tabs()

	_msg = Art.label("", Pal.SMALL, Pal.INK_MUTED)
	box.add_child(_msg)

	var scroll := ScrollContainer.new()
	DragScroll.attach(scroll)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)

	_build_add_form(box)
	_refresh()


func _draw_tabs() -> void:
	for c in _tabs.get_children():
		c.queue_free()
	for st in [1, 2, 3]:
		var t := Ui.tab_text("Station %d" % st, st == _station)
		Ui.tab_button(t).pressed.connect(func() -> void:
			_station = st
			_cancel_edit()
			_draw_tabs()
			_refresh())
		_tabs.add_child(t)


## The form on a card of its own, its three fields labelled -- placeholders
## alone vanish the moment a teacher starts typing. It says which station it
## adds to, and becomes Save / Cancel while a question is loaded for editing.
func _build_add_form(box: VBoxContainer) -> void:
	var card := PanelContainer.new()
	var face := StyleBoxFlat.new()
	face.bg_color = Pal.PARCHMENT.darkened(0.06)
	face.set_corner_radius_all(4)
	face.set_content_margin_all(6)
	card.add_theme_stylebox_override("panel", face)
	box.add_child(card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	card.add_child(col)
	_form_title = Art.label("", Pal.SMALL, Pal.TITLE)
	col.add_child(_form_title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	col.add_child(row)
	_prompt = _labelled(row, "Question", "e.g. 8 + (−3)", 200)
	_hint = _labelled(row, "Hint", "optional", 150)
	_answer = _labelled(row, "Answer", "e.g. 5", 80)
	var buttons := VBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	_add_btn = Ui.button("Add", Ui.W_TINY, Ui.H, Ui.RED)
	_add_btn.pressed.connect(_add)
	buttons.add_child(_add_btn)
	row.add_child(buttons)
	_cancel = Ui.link("Cancel")
	_cancel.pressed.connect(_cancel_edit)
	_cancel.visible = false
	row.add_child(_cancel)
	_cancel_edit()


func _labelled(row: HBoxContainer, caption: String, placeholder: String, w: float) -> LineEdit:
	var c := VBoxContainer.new()
	c.add_theme_constant_override("separation", 0)
	c.add_child(Art.label(caption, Pal.SMALL, Pal.INK_MUTED))
	var le := Ui.line_edit(placeholder, w, 28)
	c.add_child(le)
	row.add_child(c)
	return le


func _cancel_edit() -> void:
	_editing = ""
	if not is_instance_valid(_add_btn):
		return
	_add_btn.text = "Add"
	_cancel.visible = false
	_form_title.text = "Add a question to Station %d" % _station
	for f in [_prompt, _hint, _answer]:
		f.text = ""


func _refresh() -> void:
	_say("Loading Station %d..." % _station, Pal.INK_MUTED)
	var got: Dictionary = await QuestionStore.fetch(_station)
	if not is_instance_valid(_list):
		return
	for child in _list.get_children():
		child.queue_free()
	if got.error != "":
		_say(got.error, Pal.WRONG)
		return
	var want: int = Game.ITEMS_PER_STATION[_station - 1]
	var active := 0
	for row: Dictionary in got.rows:
		if row.get("active", false):
			active += 1
		_list.add_child(_row(row))
	if got.rows.is_empty():
		_list.add_child(Art.label("No questions yet for this station.",
				Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	_say("Station %d: %d of %d items set." % [_station, active, want],
		Pal.INK_MUTED if active >= want else Pal.WRONG)


## `prompt (Ans: x)` with Set · Edit · Delete, as the mockups draw it -- on a
## card, so a list of them reads as questions rather than a run of text. An
## unset question is dimmed: it is in the bank but not in the next adventure.
func _row(q: Dictionary) -> Control:
	var on: bool = q.get("active", false)
	var card := PanelContainer.new()
	var face := StyleBoxFlat.new()
	face.bg_color = Pal.PARCHMENT if on else Pal.PARCHMENT.darkened(0.08)
	face.border_color = Pal.WOOD if on else Color(Pal.WOOD, 0.35)
	face.set_border_width_all(1)
	face.set_corner_radius_all(3)
	face.content_margin_left = 6
	face.content_margin_right = 4
	face.content_margin_top = 2
	face.content_margin_bottom = 2
	card.add_theme_stylebox_override("panel", face)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	card.add_child(row)

	var text := Art.label(str(q.get("prompt", "")), Pal.LABEL,
			Pal.INK if on else Color(Pal.INK_MUTED, 0.7))
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.clip_text = true
	text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(text)
	var ans := Art.label("Ans: %s" % q.get("answer", ""), Pal.SMALL,
			Pal.CORRECT if on else Pal.INK_MUTED)
	ans.custom_minimum_size = Vector2(70, 0)
	ans.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(ans)

	var id: String = str(q.get("id", ""))
	var set_btn := Ui.button("Unset" if on else "Set", Ui.W_TINY, Ui.H, Ui.SMALL)
	set_btn.pressed.connect(func() -> void: _apply(await QuestionStore.set_active(id, not on)))
	row.add_child(set_btn)

	var edit := Ui.button("Edit", Ui.W_TINY, Ui.H, Ui.SMALL)
	edit.pressed.connect(func() -> void: _load_into_form(q))
	row.add_child(edit)

	var del := Ui.button("Delete", Ui.W_TINY, Ui.H, Ui.SMALL_RED)
	del.pressed.connect(func() -> void: _confirm_delete(id, str(q.get("prompt", ""))))
	row.add_child(del)
	return card


## Delete is the one thing here that cannot be taken back, so it asks.
func _confirm_delete(id: String, prompt: String) -> void:
	var dim := Ui.dim(self)
	var ask := Ui.screen_panel(dim, Vector2(360, 160), "Delete this question?")
	var warn := Art.label("\"%s\" and its feedback are removed from the bank." % prompt,
		Pal.SMALL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warn.custom_minimum_size = Vector2(320, 0)
	ask.add_child(warn)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	var keep := Ui.button("Keep it", 130, Ui.H, Ui.SMALL)
	keep.pressed.connect(func() -> void: dim.queue_free())
	var yes := Ui.button("Delete", 130, Ui.H, Ui.RED)
	yes.pressed.connect(func() -> void:
		dim.queue_free()
		_apply(await QuestionStore.remove(id)))
	row.add_child(keep)
	row.add_child(yes)
	ask.add_child(row)


## Edit is a load-into-the-form, not a second dialog: the form below already
## has the three fields, and Add becomes Save while a question is loaded.
func _load_into_form(q: Dictionary) -> void:
	_prompt.text = str(q.get("prompt", ""))
	_hint.text = str(q.get("hint", ""))
	_answer.text = str(q.get("answer", ""))
	_editing = str(q.get("id", ""))
	_add_btn.text = "Save"
	_cancel.visible = true
	_form_title.text = "Editing a Station %d question" % _station


## Answers are typed on a numeric keypad and graded by comparison, so a
## non-numeric answer is one no student can enter and no check can settle.
func _numeric(answer: String) -> bool:
	var a := answer.strip_edges().replace("\u2212", "-")
	return a.is_valid_int() or a.is_valid_float()


func _add() -> void:
	if not _numeric(_answer.text):
		_say("The answer has to be a number — that is what the keypad types.", Pal.WRONG)
		return
	var result: Dictionary
	if _editing != "":
		result = await QuestionStore.edit(_editing, {
			"prompt": _prompt.text.strip_edges(),
			"hint": _hint.text.strip_edges(),
			"answer": _answer.text.strip_edges(),
		})
	else:
		result = await QuestionStore.add(_station, _prompt.text, _answer.text, _hint.text)
	if result.error != "":
		_say(result.error, Pal.WRONG)
		return
	_cancel_edit()
	_refresh()


func _seed() -> void:
	_say("Adding sample questions...", Pal.INK_MUTED)
	_apply(await QuestionStore.seed(_station))


func _apply(result: Dictionary) -> void:
	if result.error != "":
		_say(result.error, Pal.WRONG)
		return
	_refresh()


func _say(text: String, col: Color) -> void:
	_msg.text = text
	_msg.add_theme_color_override("font_color", col)


func go_back() -> void:
	main.open("admin")

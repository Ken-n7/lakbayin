extends Control

## Per-station list of the bank, each row `prompt (Ans: x)` with Set / Edit /
## Delete, and an Add form of Enter Question · Enter Hint · Enter Answer.
##
## "Set" marks the question as one of the items the next adventure draws from
## (SPECS §11 Q5 -- no PDF defines the button; this is the recorded default).
## The label says what state it would move to, so a teacher can read the bank
## without a legend: an active row offers "Unset".

const PANEL := Vector2(600, 300)

var main: Control

var _list: VBoxContainer
var _msg: Label
var _station := 1
var _prompt: LineEdit
var _hint: LineEdit
var _answer: LineEdit
## The id being edited, or "" when the form is adding a new question.
var _editing := ""


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := Ui.screen_panel(self, PANEL, "Question Management")

	var picker := HBoxContainer.new()
	picker.alignment = BoxContainer.ALIGNMENT_CENTER
	picker.add_theme_constant_override("separation", 6)
	for st in [1, 2, 3]:
		var b := Ui.button("Station %d" % st, 110, 26, Ui.SMALL)
		b.pressed.connect(func() -> void:
			_station = st
			_refresh())
		picker.add_child(b)
	var seed_btn := Ui.button("Use Sample Questions", 170, 26, Ui.SMALL_RED)
	seed_btn.pressed.connect(_seed)
	picker.add_child(seed_btn)
	box.add_child(picker)

	_msg = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_msg)

	var scroll := Ui.scroll(box, 120)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)

	_build_add_form(box)

	var back := Ui.button("Back", 200, 24, Ui.SMALL)
	back.pressed.connect(go_back)
	Ui.centre_row(box, back)

	_refresh()


func _build_add_form(box: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_prompt = Ui.line_edit("Enter Question", 220, 26)
	_hint = Ui.line_edit("Enter Hint", 170, 26)
	_answer = Ui.line_edit("Enter Answer", 100, 26)
	var add := Ui.button("Add", 70, 26)
	add.pressed.connect(_add)
	for c: Control in [_prompt, _hint, _answer, add]:
		row.add_child(c)
	box.add_child(row)


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


## `prompt (Ans: x)` with its three buttons, exactly as the mockups draw it.
func _row(q: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var on: bool = q.get("active", false)

	var text := Art.label("%s   (Ans: %s)" % [q.get("prompt", ""), q.get("answer", "")],
			Pal.SMALL, Pal.INK if on else Color(Pal.INK_MUTED, 0.7))
	text.custom_minimum_size = Vector2(280, 0)
	text.clip_text = true
	row.add_child(text)

	var id: String = str(q.get("id", ""))
	var set_btn := Ui.button("Unset" if on else "Set", 66, 24, Ui.SMALL)
	set_btn.pressed.connect(func() -> void: _apply(await QuestionStore.set_active(id, not on)))
	row.add_child(set_btn)

	var edit := Ui.button("Edit", 60, 24, Ui.SMALL)
	edit.pressed.connect(func() -> void: _load_into_form(q))
	row.add_child(edit)

	var del := Ui.button("Delete", 70, 24, Ui.SMALL_RED)
	del.pressed.connect(func() -> void: _apply(await QuestionStore.remove(id)))
	row.add_child(del)
	return row


## Edit is a load-into-the-form, not a second dialog: the form below already
## has the three fields, and Add becomes Save while a question is loaded.
func _load_into_form(q: Dictionary) -> void:
	_prompt.text = str(q.get("prompt", ""))
	_hint.text = str(q.get("hint", ""))
	_answer.text = str(q.get("answer", ""))
	_editing = str(q.get("id", ""))
	_say("Editing — press Add to save the change.", Pal.INFO_DEEP)


func _add() -> void:
	var result: Dictionary
	if _editing != "":
		result = await QuestionStore.edit(_editing, {
			"prompt": _prompt.text.strip_edges(),
			"hint": _hint.text.strip_edges(),
			"answer": _answer.text.strip_edges(),
		})
		_editing = ""
	else:
		result = await QuestionStore.add(_station, _prompt.text, _answer.text, _hint.text)
	if result.error != "":
		_say(result.error, Pal.WRONG)
		return
	_prompt.text = ""
	_hint.text = ""
	_answer.text = ""
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

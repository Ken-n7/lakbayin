extends Control

## "Set specific feedback or rule reminders that will appear on the player's
## point screen when they answer a question incorrectly." -- the mockup's own
## words. Select Question, type up to 300 characters, SAVE FEEDBACK.
##
## The feedback lives on the question row, which is why deleting a question
## takes its feedback with it.

const PANEL := Vector2(560, 280)
const LIMIT := 300

var main: Control

var _pick: OptionButton
var _text: TextEdit
var _count: Label
var _msg: Label
var _rows: Array = []


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := Ui.screen_panel(self, PANEL, "Feedback and Rule Reminder")
	box.add_child(Art.label("Shown on the player's result screen when they answer "
			+ "a question incorrectly.", Pal.TINY, Pal.INK_MUTED,
			HORIZONTAL_ALIGNMENT_CENTER))

	box.add_child(Art.label("1. Select Question", Pal.LABEL, Pal.TITLE))
	_pick = OptionButton.new()
	_pick.add_theme_font_size_override("font_size", Art.MIN_FONT)
	_pick.item_selected.connect(func(_i: int) -> void: _show_selected())
	box.add_child(_pick)

	box.add_child(Art.label("2. Feedback Message", Pal.LABEL, Pal.TITLE))
	_text = TextEdit.new()
	_text.custom_minimum_size = Vector2(500, 70)
	_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_text.add_theme_font_size_override("font_size", Art.MIN_FONT)
	_text.add_theme_color_override("font_color", Pal.INK)
	_text.text_changed.connect(_on_typed)
	box.add_child(_text)

	_count = Art.label("0/%d" % LIMIT, Pal.TINY, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
	box.add_child(_count)

	_msg = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_msg)

	var save := Ui.button("SAVE FEEDBACK", Ui.W_WIDE, Ui.H, Ui.RED)
	save.pressed.connect(_save)
	Ui.centre_row(box, save)

	var back := Ui.button("Back", Ui.W_WIDE, Ui.H, Ui.SMALL)
	back.pressed.connect(go_back)
	Ui.centre_row(box, back)

	_load()


func _load() -> void:
	var got: Dictionary = await QuestionStore.fetch()
	if not is_instance_valid(_pick):
		return
	if got.error != "":
		_say(got.error, Pal.WRONG)
		return
	_rows = got.rows
	_pick.clear()
	for q: Dictionary in _rows:
		_pick.add_item("S%d  %s" % [int(q.get("station", 0)), q.get("prompt", "")])
	if _rows.is_empty():
		_say("No questions yet — add some in Question Management.", Pal.INK_MUTED)
		return
	_show_selected()


func _show_selected() -> void:
	var q: Dictionary = _current()
	if q.is_empty():
		return
	_text.text = str(q.get("feedback", ""))
	_on_typed()


func _current() -> Dictionary:
	var i := _pick.selected
	return _rows[i] if i >= 0 and i < _rows.size() else {}


## Trimmed as it is typed rather than refused on save: the column has a 300
## character check constraint, and finding that out after writing 400 is worse
## than not being able to type the 301st.
func _on_typed() -> void:
	if _text.text.length() > LIMIT:
		var caret := _text.get_caret_column()
		_text.text = _text.text.substr(0, LIMIT)
		_text.set_caret_column(mini(caret, LIMIT))
	_count.text = "%d/%d" % [_text.text.length(), LIMIT]


func _save() -> void:
	var q: Dictionary = _current()
	if q.is_empty():
		_say("Pick a question first.", Pal.WRONG)
		return
	var done: Dictionary = await QuestionStore.edit(str(q.get("id", "")),
		{"feedback": _text.text})
	if done.error != "":
		_say(done.error, Pal.WRONG)
		return
	q["feedback"] = _text.text
	_say("Feedback saved.", Pal.CORRECT)


func _say(text: String, col: Color) -> void:
	_msg.text = text
	_msg.add_theme_color_override("font_color", col)


func go_back() -> void:
	main.open("admin")

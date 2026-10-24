extends Control

## A monk's word, and the keypad to write it in Baybayin (DESIGN.md 3.2).
##
## The word is shown in Latin letters; the player types its Baybayin. `check`
## decides: in a match the server (`Monks.answer`), in Practice the same rule
## locally (`Baybayin.matches`). It is awaited and returns "correct", "wrong",
## "locked", "taken" or "error: ...". A wrong answer is not corrected here --
## the team would copy it -- the results screen shows every spelling.

signal answered(result: String)
signal activity_changed(active: bool)

const LOCK_S := 10.0
const ANSWER_SIZE := 30

var word: Dictionary = {}          # {word, meaning, modern, traditional}
var monk := 0
var labels := true                 # Latin under the keys: Practice only
var check: Callable                # (typed: String) -> String, awaited

var _keypad: BaybayinKeypad
var _answer: Label
var _status: Label
var _submit: Button
var _locked_until := 0.0
var _busy := false


func setup(data: Dictionary) -> void:
	word = data.get("word", {})
	monk = int(data.get("monk", 0))
	labels = bool(data.get("labels", true))
	check = data.get("check", Callable())
	_build()


func _build() -> void:
	Ui.dim(self)                   # first, so the panel is drawn over it
	var box := Ui.back_panel(self, Vector2(600, 0), "Monk %d" % (monk + 1), close)
	box.add_theme_constant_override("separation", 6)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	box.add_child(row)

	# Left: the word, what has been typed, what happened, Submit.
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(220, 0)
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	left.add_theme_constant_override("separation", 6)
	left.add_child(Art.label("Write in Baybayin", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	var w := Art.label(str(word.get("word", "")), Pal.H1 + 6, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	w.name = "Word"
	left.add_child(w)
	var shown := PanelContainer.new()
	# A sunken sand slot the answer is written into.
	var face := Ui.frame(Ui.SLOT)
	face.set_content_margin_all(4)
	shown.add_theme_stylebox_override("panel", face)
	shown.custom_minimum_size = Vector2(210, 52)
	_answer = Art.label("", ANSWER_SIZE, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	_answer.name = "Answer"
	_answer.add_theme_font_override("font", Art.baybayin())
	_answer.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	shown.add_child(_answer)
	left.add_child(shown)
	_status = Art.label("", Pal.SMALL, Pal.INFO, HORIZONTAL_ALIGNMENT_CENTER)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(210, 0)
	left.add_child(_status)
	_submit = Ui.button("Submit", 200, Ui.H, Ui.RED)
	_submit.pressed.connect(_on_submit)
	Ui.quiet(_submit)
	Ui.centre_row(left, _submit)
	row.add_child(left)

	# Right: the keypad, under the thumb.
	_keypad = BaybayinKeypad.new()
	_keypad.labels = labels
	_keypad.changed.connect(func(t: String) -> void:
		_answer.text = t
		if not _busy and _locked_until <= 0.0 and not _submit.disabled:
			activity_changed.emit(true))
	row.add_child(_keypad)


func _process(_delta: float) -> void:
	if _locked_until <= 0.0:
		return
	var left := _locked_until - Time.get_ticks_msec() / 1000.0
	if left > 0.0:
		_status.text = "Not quite. Try this monk again in %d s." % ceili(left)
		_submit.disabled = true
	else:
		_locked_until = 0.0
		_status.text = ""
		_submit.disabled = false
		activity_changed.emit(true)


func _on_submit() -> void:
	if _busy or _locked_until > 0.0:
		return
	if Baybayin.clean(_keypad.text) == "":
		_status.text = "Type the word with the keys first."
		Sfx.play("refused")
		return
	_busy = true
	activity_changed.emit(true)
	_submit.disabled = true
	var result: String = await check.call(_keypad.text)
	if not is_instance_valid(self):
		return
	_busy = false
	_submit.disabled = false
	activity_changed.emit(false)
	match result:
		"correct":
			Sfx.play("correct")
			_status.add_theme_color_override("font_color", Pal.CORRECT)
			_status.text = "Correct! Carry it to the Monastery."
			_submit.disabled = true
			answered.emit(result)
			await get_tree().create_timer(1.2).timeout
			if is_instance_valid(self):
				close()
		"wrong", "locked":
			Sfx.play("wrong")
			_status.add_theme_color_override("font_color", Pal.WRONG)
			_locked_until = Time.get_ticks_msec() / 1000.0 + LOCK_S
			_submit.disabled = true
			_keypad.clear()
			answered.emit(result)
		"taken":
			_status.text = "Your team already has this word."
			answered.emit(result)
		_:
			_status.add_theme_color_override("font_color", Pal.WRONG)
			_status.text = result.trim_prefix("error: ")


func close() -> void:
	queue_free()

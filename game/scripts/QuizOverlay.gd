extends Control

## One stop on the board. Opened by the tower as the station briefing
## (`intro_only`), or by a circle as a single item: prompt, input, hint/skip,
## then the feedback with its rule reminder. The station's last item also shows
## the completion ribbon, which is where the perfect-station bonus is paid.
##
## Progress lives in `Game.items_done`, not here: the map drives one item at a
## time and the player walks between them.

enum Phase { INTRO, QUESTION, FEEDBACK, DONE }

var adventure: Control
var station_index := 0
var intro_only := false      # the tower briefing card, no question

var phase := Phase.INTRO
var item_index := 0
var current: Dictionary = {}
## The expected answer as text: authored questions are free text, and the
## generator's integers are stringified to match.
var answer := ""
var meta: Dictionary = {}

## The question, one size up from the 32 it was (client). The left column's
## width is what the keypad and the panel leave.
const PROMPT_SIZE := 33
const ASK_W := 330.0

var _panel: VBoxContainer
var _q_prompt: Label
var _q_index: Label
var _mission_text: Label   # the intro's welcome paragraph, shown under "MISSION"
var _input: LineEdit
var _hint_text: Label
var _btn_submit: Button
var _btn_hint: Button
var _btn_skip: Button
## Give a teammate gems (client, 2026-09-27) -- team games only.
var _btn_rescue: Button
var _inrow: HBoxContainer
var _ask: Label                # the question, over its answer box
var _ask_row: Control          # question + answer on the left, keypad right
var _keypad: CenterContainer
var _action: HBoxContainer
var _result_title: Label
var _result_rule: Label
var _delta_label: Label
var _continue_btn: Button
var _gems_row: Label          # the value on the gem plank
var _time_row: Label          # the value on the clock plank
var _answer_box: PanelContainer   # "Correct answer: 5", on a wrong result
var _answer_label: Label
var _digits := RegEx.create_from_string("[^0-9]")
var _station_end := 0        # items_done once this station's last item is resolved


func setup(_data: Dictionary) -> void:
	meta = QuestionGen.station_meta(station_index)
	_station_end = 0
	for s in station_index + 1:
		_station_end += Game.ITEMS_PER_STATION[s]
	_build()
	if intro_only:
		_show_intro()
	else:
		_next_question()


func _ready() -> void:
	Ui.dim(self, false)            # the quiz has sounds of its own
	Game.time_changed.connect(_on_time)
	Game.gems_changed.connect(_on_gems)


func _exit_tree() -> void:
	Game.time_changed.disconnect(_on_time)
	Game.gems_changed.disconnect(_on_gems)


func _build() -> void:
	# No panel title: the header row says where you are, in the same pieces
	# the top bar uses -- the station's ribbon, then gems and the clock on
	# planks -- rather than a heading and a line of small text.
	_panel = Ui.screen_panel(self, Vector2(600, 310), "")
	_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	_panel.add_theme_constant_override("separation", 7)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	_q_index = Art.label("", Pal.SMALL, Pal.WOOD)
	_q_index.custom_minimum_size = Vector2(130, 0)
	_q_index.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(_q_index)
	var ribbon_box := CenterContainer.new()
	ribbon_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ribbon_box.add_child(Ui.ribbon(Ui.STATION_RIBBON[station_index], "Station %d" % meta.id))
	head.add_child(ribbon_box)
	var gems := Ui.stat_plank(Ui.GEM, str(Game.gems), Pal.SMALL)
	_gems_row = gems.find_child("Value", true, false)
	head.add_child(gems)
	var clock := Ui.stat_plank("", Ui.mmss(int(Game.time_left)), Pal.SMALL)
	_time_row = clock.find_child("Value", true, false)
	head.add_child(clock)
	_panel.add_child(head)

	_q_prompt = Art.label("", PROMPT_SIZE, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	_panel.add_child(_q_prompt)

	# Built here, right after the heading, and just shown/hidden by
	# `_layout()` -- `_show_intro()` used to `add_child` a fresh label instead,
	# which always lands at the END of the VBox (after Continue, already a
	# child from here), rendering the welcome paragraph below the button.
	_mission_text = Art.label("", Pal.BODY, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	_mission_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mission_text.custom_minimum_size = Vector2(520, 0)
	_panel.add_child(_mission_text)

	var inrow := HBoxContainer.new()
	inrow.alignment = BoxContainer.ALIGNMENT_CENTER
	inrow.add_theme_constant_override("separation", 8)
	_input = Ui.line_edit("", 150, 40, 25)
	_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_input.max_length = 12
	# No OS keyboard on this field. The answers are numbers, and forty cheap
	# phones means forty keyboard apps -- different heights, different "done"
	# keys, some with autocorrect that would helpfully mangle "-5". The keypad
	# beside it is the input, and it cannot cover the Submit button.
	_input.virtual_keyboard_enabled = false
	_input.text_changed.connect(_filter_input)
	_input.text_submitted.connect(func(_t: String) -> void: _submit())
	inrow.add_child(Art.label("=", 27, Pal.INK))
	inrow.add_child(_input)
	_inrow = inrow

	# Two halves while a question is up (client): the question with its
	# answer box under it on the left, where the eye reads down from one to
	# the other, and the keypad on the right, under the thumb.
	var pad_row := HBoxContainer.new()
	pad_row.alignment = BoxContainer.ALIGNMENT_CENTER
	pad_row.add_theme_constant_override("separation", 24)
	var left := VBoxContainer.new()
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	left.add_theme_constant_override("separation", 8)
	left.custom_minimum_size = Vector2(ASK_W, 0)
	_ask = Art.label("", PROMPT_SIZE, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	_ask.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ask.custom_minimum_size = Vector2(ASK_W, 0)
	left.add_child(_ask)
	left.add_child(inrow)
	_hint_text = Art.label("", Pal.SMALL + 1, Pal.INFO, HORIZONTAL_ALIGNMENT_CENTER)
	_hint_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_text.custom_minimum_size = Vector2(ASK_W, 0)
	left.add_child(_hint_text)
	pad_row.add_child(left)
	pad_row.add_child(_build_keypad())
	_panel.add_child(pad_row)
	_ask_row = pad_row

	# The helps on the left, quiet; Submit alone on the right, and the only
	# red. Skip was red too, and two reds made the escape look like the goal.
	var action := HBoxContainer.new()
	action.alignment = BoxContainer.ALIGNMENT_CENTER
	action.add_theme_constant_override("separation", 8)
	_btn_hint = Ui.button("Hint  −5", 100, Ui.H, Ui.SMALL)
	_btn_hint.pressed.connect(_use_hint)
	Ui.quiet(_btn_hint)
	var btn_skip := Ui.button("Skip  −15", 100, Ui.H, Ui.SMALL)
	btn_skip.pressed.connect(_skip)
	Ui.quiet(btn_skip)
	# Where the mockups put it: with the helps, "Rescue". Team games only --
	# playing alone there is nobody to give gems to.
	_btn_rescue = Ui.button("Rescue", 100, Ui.H, Ui.SMALL)
	_btn_rescue.pressed.connect(_open_rescue)
	Ui.quiet(_btn_rescue)
	_btn_submit = Ui.button("Submit Answer", 170, Ui.H, Ui.RED)
	_btn_submit.pressed.connect(_submit)
	Ui.quiet(_btn_submit)
	action.add_child(_btn_hint)
	action.add_child(btn_skip)
	action.add_child(_btn_rescue)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(12, 0)
	action.add_child(gap)
	action.add_child(_btn_submit)
	_btn_skip = btn_skip
	_action = action
	_panel.add_child(action)

	# The result: what happened, what it cost or paid, the right answer on a
	# card of its own, then the rule -- in that order of size.
	_result_title = Art.title(Art.label("", Pal.H1, Pal.CORRECT, HORIZONTAL_ALIGNMENT_CENTER)) as Label
	_panel.add_child(_result_title)
	_delta_label = Art.label("", Pal.H2, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	_panel.add_child(_delta_label)
	_answer_box = PanelContainer.new()
	var card := StyleBoxFlat.new()
	card.bg_color = Pal.PARCHMENT.darkened(0.06)
	card.border_color = Pal.WRONG
	card.set_border_width_all(2)
	card.set_corner_radius_all(4)
	card.set_content_margin_all(6)
	_answer_box.add_theme_stylebox_override("panel", card)
	_answer_label = Art.label("", Pal.H2, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	_answer_box.add_child(_answer_label)
	var answer_row := CenterContainer.new()
	answer_row.add_child(_answer_box)
	_panel.add_child(answer_row)
	_result_rule = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_result_rule.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_rule.custom_minimum_size = Vector2(520, 0)
	_panel.add_child(_result_rule)
	_continue_btn = Ui.button("Continue", 220, 44, Ui.RED)
	_continue_btn.pressed.connect(_advance)
	Ui.centre_row(_panel, _continue_btn)


func _show_intro() -> void:
	phase = Phase.INTRO
	_q_index.text = "Mission briefing"      # the card's "Mission" line, per SPECS §5
	_q_prompt.text = str(meta.title).get_slice(": ", 1)
	Art.title(_q_prompt)      # the station's name, a banner; questions set it back
	_mission_text.text = meta.mission
	_layout()
	_continue_btn.text = "Continue"
	_hint_text.text = ""


## QUESTION shows the entry row; FEEDBACK/DONE hide it and reveal the result
## block so the panel never overflows its 300px frame. INTRO shows neither, just
## the mission text and Continue. Every caller sets `phase` first.
func _layout() -> void:
	var asking := phase == Phase.QUESTION
	for c in [_ask_row, _inrow, _action, _btn_hint, _btn_submit, _btn_skip, _input, _hint_text, _keypad]:
		(c as Control).visible = asking
	# The heading line is the briefing's title and the result's question;
	# while asking, the question sits in its own column instead.
	_q_prompt.visible = not asking
	for c in [_result_title, _delta_label, _result_rule]:
		(c as Control).visible = phase == Phase.FEEDBACK or phase == Phase.DONE
	# The answer card appears with a result; `_show_result` fills it.
	_answer_box.get_parent().visible = false
	_mission_text.visible = phase == Phase.INTRO
	_continue_btn.get_parent().visible = not asking


func _next_question() -> void:
	phase = Phase.QUESTION
	Game.begin_item()
	var total: int = Game.ITEMS_PER_STATION[station_index]
	item_index = Game.item_in_station(Game.items_done)
	current = QuestionStore.item_for(station_index, item_index)
	answer = current.answer
	_q_index.text = "Question %d of %d" % [item_index + 1, total]
	_q_prompt.remove_theme_font_override("font")
	_q_prompt.text = current.prompt
	_ask.text = current.prompt
	_layout()
	_hint_text.text = ""
	_input.text = ""
	_btn_hint.disabled = false
	_refresh_rescue()


func _submit() -> void:
	if phase != Phase.QUESTION or not _may_score():
		return
	var t := _input.text.strip_edges()
	if t.is_empty():
		_flash_trouble("Type your answer first")
		return
	var ok := _matches(t, str(answer))
	if ok:
		Game.mark_correct()
		Sfx.play("correct")
		_show_result(true)
	else:
		Game.mark_wrong()
		Sfx.play("wrong")
		_show_result(false)


## The teacher's pause reaches a student mid-question too. The server would
## refuse the score, so the answer is held here rather than counted on this
## phone alone and lost from the team's total.
func _may_score() -> bool:
	if Game.can_score():
		return true
	_flash_trouble("Paused by your Quest Keeper — wait for Resume")
	return false


## Authored answers are free text, so "-2", "-2 " and "−2" (the minus sign the
## ± button types) all have to count. Numbers compare as numbers so that "07"
## and "7" agree; anything else compares as trimmed, case-folded text.
func _matches(typed: String, want: String) -> bool:
	var a := typed.strip_edges().replace("\u2212", "-")
	var b := want.strip_edges().replace("\u2212", "-")
	if a.is_valid_int() and b.is_valid_int():
		return a.to_int() == b.to_int()
	if a.is_valid_float() and b.is_valid_float():
		return is_equal_approx(a.to_float(), b.to_float())
	return a.to_lower() == b.to_lower()


func _show_result(correct: bool) -> void:
	phase = Phase.FEEDBACK
	_layout()
	_continue_btn.text = "Continue"
	if correct:
		_result_title.text = "CORRECT!  You got it!"
		_result_title.add_theme_color_override("font_color", Pal.CORRECT)
		_delta_label.text = "+%d gems" % Game.GEM_CORRECT
		_delta_label.add_theme_color_override("font_color", Pal.AMBER)
		_result_rule.text = "You applied the correct rule!"
		_show_answer("Answer:  %s" % str(answer), Pal.CORRECT)
		_burst()
	else:
		_result_title.text = "Almost there!  Keep trying!"
		_result_title.add_theme_color_override("font_color", Pal.WRONG)
		_delta_label.text = "%d gems" % Game.GEM_WRONG
		_delta_label.add_theme_color_override("font_color", Pal.WRONG)
		_show_answer("Correct answer:  %s" % str(answer), Pal.WRONG)
		_result_rule.text = str(current.rule)
	_continue_btn.grab_focus()


## The answer on a card of its own -- the mockups show it on both results --
## edged in the result's colour.
func _show_answer(text: String, edge: Color) -> void:
	_answer_label.text = text
	(_answer_box.get_theme_stylebox("panel") as StyleBoxFlat).border_color = edge
	_answer_box.get_parent().visible = true


func _advance() -> void:
	match phase:
		Phase.INTRO:
			_finish()
		Phase.FEEDBACK:
			_finish_item_or_station()
		Phase.DONE:
			_finish()


## The item is resolved (right, wrong or skipped). Its station's last circle also
## earns the completion ribbon and the perfect bonus; otherwise it is back to the
## map to walk to the next circle.
func _finish_item_or_station() -> void:
	if Game.items_done >= _station_end:
		_show_complete()
	else:
		_finish()


func _show_complete() -> void:
	phase = Phase.DONE
	Sfx.play("station_complete")
	var bonus := Game.finish_station(station_index)
	_layout()
	_continue_btn.text = "Return to Map"
	_result_title.text = "Station complete!"
	_result_title.add_theme_color_override("font_color", Pal.AMBER)
	_delta_label.text = "Perfect run! +%d bonus gems" % bonus if bonus > 0 else "All %d items finished" % Game.ITEMS_PER_STATION[station_index]
	_delta_label.add_theme_color_override("font_color", Pal.CORRECT if bonus > 0 else Pal.INK)
	_result_rule.text = "Return to the map and seek the next station."
	if bonus > 0:
		_burst()
	_continue_btn.grab_focus()


func _finish() -> void:
	if adventure != null and adventure.has_method("close_overlay"):
		adventure.close_overlay()


func _use_hint() -> void:
	if phase != Phase.QUESTION or Game.item_used_hint or not _may_score():
		return
	if Game.spend_hint():
		Sfx.play("hint")
		_hint_text.text = "Hint: " + current.hint
		_btn_hint.disabled = true
	else:
		_flash_trouble("No gems left for a hint")


func _skip() -> void:
	if phase != Phase.QUESTION or not _may_score():
		return
	if Game.gems <= 0:
		_flash_trouble("No gems left to skip")
		return
	Game.mark_skipped()
	Sfx.play("skip")
	_finish_item_or_station()


func _on_time(sec: int) -> void:
	if is_instance_valid(_time_row):
		_time_row.text = Ui.mmss(sec)
		_time_row.add_theme_color_override("font_color",
			Pal.WRONG_BRIGHT if sec <= 60 else Pal.CREAM)


func _on_gems(g: int) -> void:
	if is_instance_valid(_gems_row):
		_gems_row.text = str(g)


## Android's number pad has no minus key, and plenty of the answers here are
## negative. Assigning `text` skips `text_changed`, so the filter stays out.
## Three rows of digits, then sign / zero / backspace. Big targets on a clock,
## the minus sign a key rather than a toggle nobody finds, and nothing that can
## slide up over the answer.
func _build_keypad() -> Control:
	var grid := GridContainer.new()
	# Four across, three down. Stacked 3x4 it was one row too tall and pushed
	# Submit off the canvas -- and the button heights are not the lever they
	# look like, since the nine-patch has a floor of its own.
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 3)
	_keypad = CenterContainer.new()
	_keypad.add_child(grid)

	for key in ["7", "8", "9", "⌫", "4", "5", "6", "±", "1", "2", "3", "0"]:
		var b := Ui.button(key, 46, 28, Ui.SMALL if key.is_valid_int() else Ui.SMALL_RED)
		b.add_theme_font_size_override("font_size", 18)
		var k: String = key
		b.pressed.connect(func() -> void: _key(k))
		Ui.quiet(b)                 # no keypad sound (client)
		grid.add_child(b)
	return _keypad


## One place every key goes through, so the field can never hold something the
## answer check would not understand.
func _key(k: String) -> void:
	if phase != Phase.QUESTION:
		return
	match k:
		"±":
			_toggle_sign()
		"⌫":
			_input.text = _input.text.substr(0, maxi(_input.text.length() - 1, 0))
		_:
			if _input.text.length() < _input.max_length:
				_input.text += k
	_input.caret_column = _input.text.length()


func _toggle_sign() -> void:
	_input.text = _input.text.substr(1) if _input.text.begins_with("-") else "-" + _input.text
	_input.caret_column = _input.text.length()


## Digits, plus a leading minus. LineEdit has no numeric mode of its own.
func _filter_input(text: String) -> void:
	var out := ("-" if text.begins_with("-") else "") + _digits.sub(text, "", true)
	_input.set_text(out)
	_input.caret_column = out.length()


## A line under the question for a moment -- mostly why something was refused,
## so that is its sound unless told otherwise.
## Rescue shows in team games, and says why when it cannot be used: spent,
## out of gems, or too few to give one and keep one.
func _refresh_rescue() -> void:
	if not is_instance_valid(_btn_rescue):
		return
	_btn_rescue.visible = Game.session_id != ""
	var why := Game.rescue_block()
	_btn_rescue.disabled = why != ""
	_btn_rescue.text = "Rescued" if Game.rescue_sent else "Rescue"
	_btn_rescue.tooltip_text = why if why != "" else "Give some of your gems to a teammate"


func _open_rescue() -> void:
	if Game.rescue_block() != "":
		return
	var r: Control = preload("res://scripts/RescueOverlay.gd").new()
	add_child(r)
	r.setup({})
	r.finished.connect(func(summary: String) -> void:
		if summary != "":
			_flash_trouble(summary, "")
		_refresh_rescue())


func _flash_trouble(msg: String, sound := "refused") -> void:
	if sound != "":
		Sfx.play(sound)
	Art.toast(_hint_text, msg, 1.0, _hint_text.text)


func _burst() -> void:
	var fx := AnimatedSprite2D.new()
	fx.sprite_frames = Art.anim_spriteframes({"boom": ["res://assets/fx/Explosion_01.png", 14.0, false]})
	fx.scale = Vector2(0.9, 0.9)
	fx.position = Vector2(320, 130)
	fx.z_index = 10
	fx.centered = true
	add_child(fx)
	fx.play("boom")
	fx.animation_finished.connect(fx.queue_free)
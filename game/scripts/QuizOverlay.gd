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

var _panel: VBoxContainer
var _q_prompt: Label
var _q_index: Label
var _mission_text: Label   # the intro's welcome paragraph, shown under "MISSION"
var _input: LineEdit
var _hint_text: Label
var _btn_submit: Button
var _btn_hint: Button
var _btn_skip: Button
var _inrow: HBoxContainer
var _keypad: CenterContainer
var _rescue: MenuButton
## The team-mates the dropdown is currently offering.
var _mates: Array = []
var _action: HBoxContainer
var _result_title: Label
var _result_rule: Label
var _delta_label: Label
var _continue_btn: Button
var _gems_row: Label
var _time_row: Label
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
	Ui.dim(self)
	Game.time_changed.connect(_on_time)
	Game.gems_changed.connect(_on_gems)


func _exit_tree() -> void:
	Game.time_changed.disconnect(_on_time)
	Game.gems_changed.disconnect(_on_gems)


func _build() -> void:
	_panel = Ui.screen_panel(self, Vector2(560, 300), meta.title)
	_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	_panel.add_theme_constant_override("separation", 7)

	var hud := HBoxContainer.new()
	hud.add_theme_constant_override("separation", 26)
	_gems_row = Art.label("Gems: %d" % Game.gems, Pal.SMALL, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	_time_row = Art.label("Time: %s" % Ui.mmss(int(Game.time_left)),
			13, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	hud.add_child(_gems_row)
	hud.add_child(_time_row)
	_panel.add_child(hud)

	_q_index = Art.label("", Pal.SMALL, Pal.WOOD, HORIZONTAL_ALIGNMENT_CENTER)
	_panel.add_child(_q_index)

	_q_prompt = Art.label("", 30, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	_panel.add_child(_q_prompt)

	# Built here, right after the "MISSION" heading, and just shown/hidden by
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
	_input = Ui.line_edit("", 150, 36, 22)
	_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_input.max_length = 12
	# No OS keyboard on this field. The answers are numbers, and forty cheap
	# phones means forty keyboard apps -- different heights, different "done"
	# keys, some with autocorrect that would helpfully mangle "-5". The keypad
	# below is the input, and it cannot cover the Submit button.
	_input.virtual_keyboard_enabled = false
	_input.text_changed.connect(_filter_input)
	_input.text_submitted.connect(func(_t: String) -> void: _submit())
	var go_lbl := Art.label("=", 24, Pal.INK)
	var img := Art.texrect("res://assets/ui/Icon_03.png", 28, 28)
	inrow.add_child(go_lbl)
	inrow.add_child(_input)
	inrow.add_child(img)
	_inrow = inrow

	var pad_row := HBoxContainer.new()
	pad_row.alignment = BoxContainer.ALIGNMENT_CENTER
	pad_row.add_theme_constant_override("separation", 16)
	inrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pad_row.add_child(inrow)
	pad_row.add_child(_build_keypad())
	_panel.add_child(pad_row)

	_hint_text = Art.label("", Pal.SMALL, Pal.INFO, HORIZONTAL_ALIGNMENT_CENTER)
	_hint_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_text.custom_minimum_size = Vector2(500, 0)
	_panel.add_child(_hint_text)

	var action := HBoxContainer.new()
	action.alignment = BoxContainer.ALIGNMENT_CENTER
	action.add_theme_constant_override("separation", 10)
	_btn_hint = Ui.button("Hint (−5)", 120, Ui.H, Ui.SMALL)
	_btn_hint.pressed.connect(_use_hint)
	_btn_submit = Ui.button("Submit Answer", 150, Ui.H, Ui.RED)
	_btn_submit.pressed.connect(_submit)
	var btn_skip := Ui.button("Skip (−15)", 120, Ui.H, Ui.SMALL_RED)
	btn_skip.pressed.connect(_skip)
	_rescue = Ui.menu_button("Rescue", 92, Ui.H, Ui.SMALL)
	_rescue.disabled = true
	_rescue.tooltip_text = "Needs a team-mate to transfer gems to"
	_rescue.get_popup().id_pressed.connect(_send_rescue)
	action.add_child(_btn_hint)
	action.add_child(_btn_submit)
	action.add_child(btn_skip)
	action.add_child(_rescue)
	_btn_skip = btn_skip
	_action = action
	_panel.add_child(action)

	# Feedback sub-panel (hidden until a result is shown)
	_result_title = Art.label("", Pal.H1, Pal.CORRECT, HORIZONTAL_ALIGNMENT_CENTER)
	_panel.add_child(_result_title)
	_delta_label = Art.label("", Pal.H2, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	_panel.add_child(_delta_label)
	_result_rule = Art.label("", Pal.LABEL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	_result_rule.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_rule.custom_minimum_size = Vector2(520, 0)
	_panel.add_child(_result_rule)
	_continue_btn = Ui.button("Continue", 160, 44, Ui.RED)
	_continue_btn.pressed.connect(_advance)
	_panel.add_child(_continue_btn)


func _show_intro() -> void:
	phase = Phase.INTRO
	_q_index.text = "Station %d — %s" % [meta.id, meta.short]
	_q_prompt.text = "MISSION"
	_mission_text.text = meta.mission
	_layout()
	_continue_btn.text = "Continue"
	_hint_text.text = ""


## QUESTION shows the entry row; FEEDBACK/DONE hide it and reveal the result
## block so the panel never overflows its 300px frame. INTRO shows neither, just
## the mission text and Continue. Every caller sets `phase` first.
func _layout() -> void:
	var asking := phase == Phase.QUESTION
	for c in [_inrow, _action, _btn_hint, _btn_submit, _btn_skip, _input, _hint_text, _keypad]:
		(c as Control).visible = asking
	for c in [_result_title, _delta_label, _result_rule]:
		(c as Control).visible = phase == Phase.FEEDBACK or phase == Phase.DONE
	_mission_text.visible = phase == Phase.INTRO
	_continue_btn.visible = not asking


func _next_question() -> void:
	phase = Phase.QUESTION
	Game.begin_item()
	var total: int = Game.ITEMS_PER_STATION[station_index]
	item_index = Game.item_in_station(Game.items_done)
	current = QuestionStore.item_for(station_index, item_index)
	answer = current.answer
	_q_index.text = "Item %d / %d" % [item_index + 1, total]
	_q_prompt.text = current.prompt
	_layout()
	_hint_text.text = ""
	_input.text = ""
	_refresh_rescue()
	_btn_hint.disabled = false


func _submit() -> void:
	if phase != Phase.QUESTION:
		return
	var t := _input.text.strip_edges()
	if t.is_empty():
		_flash_trouble("Type your answer first")
		return
	var ok := _matches(t, str(answer))
	if ok:
		Game.mark_correct()
		_show_result(true)
	else:
		Game.mark_wrong()
		_show_result(false)


## Who Rescue can send to, refreshed per item because a team-mate's gems and
## their being out both change while the adventure runs.
##
## -10 from the sender and +10 to the receiver is net zero for the team; the
## point is keeping somebody above zero, since hitting it costs the team 50.
func _refresh_rescue() -> void:
	if not is_instance_valid(_rescue):
		return
	_rescue.disabled = true
	if Game.session_id == "" or Game.rescue_sent or Game.gems < 10:
		return
	_mates = await Teams.teammates(Game.session_id)
	if not is_instance_valid(_rescue):
		return
	var menu := _rescue.get_popup()
	menu.clear()
	for i in _mates.size():
		var m: Dictionary = _mates[i]
		menu.add_item("%s  (%d gems)" % [m.username, m.gems], i)
		# Already out: the team has been charged, and refunding that would
		# make elimination negotiable. The server refuses it too.
		menu.set_item_disabled(i, bool(m.eliminated))
	_rescue.disabled = _mates.is_empty()


func _send_rescue(id: int) -> void:
	if id < 0 or id >= _mates.size():
		return
	var mate: Dictionary = _mates[id]
	var reply: Dictionary = await Scores.rescue(Game.session_id, str(mate.profile_id))
	if reply.error != "":
		_flash_trouble(reply.error)
		return
	Game.mark_rescue_sent()
	_flash_trouble("Sent 10 gems to %s" % mate.username)
	_refresh_rescue()


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
		_result_rule.text = current.hint
		_burst()
	else:
		_result_title.text = "Almost there!  Keep trying!"
		_result_title.add_theme_color_override("font_color", Pal.WRONG)
		_delta_label.text = "%d gems" % Game.GEM_WRONG
		_delta_label.add_theme_color_override("font_color", Pal.WRONG)
		_result_rule.text = "Correct answer: %s\n%s" % [str(answer), current.rule]
	_continue_btn.grab_focus()


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
	if phase != Phase.QUESTION or Game.item_used_hint:
		return
	if Game.spend_hint():
		_hint_text.text = "Hint: " + current.hint
		_btn_hint.disabled = true
	else:
		_flash_trouble("No gems left for a hint")


func _skip() -> void:
	if phase != Phase.QUESTION:
		return
	if Game.gems <= 0:
		_flash_trouble("No gems left to skip")
		return
	Game.mark_skipped()
	_finish_item_or_station()


func _on_time(sec: int) -> void:
	if is_instance_valid(_time_row):
		_time_row.text = "Time: %s" % Ui.mmss(sec)


func _on_gems(g: int) -> void:
	if is_instance_valid(_gems_row):
		_gems_row.text = "Gems: %d" % g


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
		b.add_theme_font_size_override("font_size", 17)
		var k: String = key
		b.pressed.connect(func() -> void: _key(k))
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


func _flash_trouble(msg: String) -> void:
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
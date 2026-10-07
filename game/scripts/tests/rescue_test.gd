extends TestCase
## Rescue, as a player meets it (client, 2026-09-27): the Rescue button, the
## teammate list, the amount screen, the one chance, and the news on the
## rescued player's phone. The real screens throughout; only the three network
## calls are stood in for. The server's own rules are supabase/test/run.sh.
##   godot --headless res://scripts/tests/rescue_test.tscn

const SID := "s-rescue-test"

var _sent: Array = []       # [to, amount] per call the overlay made
var _told: Array = []       # payloads it broadcast
var _reply := {"error": "", "row": {}}


func frames(n := 3) -> void:
	for i in n:
		await get_tree().process_frame


func mates() -> Array:
	return [
		{"profile_id": "ben-id", "username": "ben", "gems": 6, "eliminated": false, "finished": false},
		{"profile_id": "dee-id", "username": "dee", "gems": 0, "eliminated": true, "finished": false},
		{"profile_id": "eli-id", "username": "eli", "gems": 80, "eliminated": false, "finished": true},
		{"profile_id": "fay-id", "username": "fay", "gems": 40, "eliminated": false, "finished": false},
	]


## A rescue screen on the stand-in network, opened as a teammate would open it.
func overlay(list := mates()) -> Control:
	var r: Control = load("res://scripts/RescueOverlay.gd").new()
	r.fetch_mates = func() -> Array:
		await get_tree().process_frame
		return list
	r.send = func(to: String, amount: int) -> Dictionary:
		_sent.append([to, amount])
		await get_tree().process_frame
		await get_tree().process_frame
		return _reply
	r.notify = func(payload: Dictionary) -> void: _told.append(payload)
	add_child(r)
	r.setup({})
	await frames(4)
	return r


func node(root: Node, path: String) -> Node:
	return root.find_child(path, true, false)


func pick(r: Control, who: String) -> Button:
	var row := node(r, "Mate_" + who)
	return null if row == null else row.find_child("Pick", true, false) as Button


func label_text(root: Node, contains: String) -> String:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text.contains(contains) and (l as Label).is_visible_in_tree():
			return (l as Label).text
	return ""


func fresh(gems := 50) -> void:
	Game.begin_adventure(600)
	Game.session_id = SID
	Game.gems = gems
	_sent.clear()
	_told.clear()
	_reply = {"error": "", "row": {}}


func _ready() -> void:
	backup_save()
	Net.user_id = "me-id"
	Net.username = "me"
	await frames(2)
	await _rules()
	await _question_screen()
	await _flow()
	await _refusals()
	await _map_and_news()
	Game.session_id = ""
	Game.abandon_adventure()
	completed = true
	finish("RESCUE")


# --- The rules the button follows -----------------------------------------
func _rules() -> void:
	Game.begin_adventure(600)
	check("playing alone: no rescue", Game.rescue_block().begins_with("Rescue is for team games"),
			Game.rescue_block())
	fresh(50)
	check("in a team game with gems: rescue open", Game.rescue_block() == "", Game.rescue_block())
	check("the most you can give is all but 1", Game.rescue_max() == 49, str(Game.rescue_max()))
	Game.gems = 2
	check("2 gems: can give 1", Game.rescue_block() == "" and Game.rescue_max() == 1)
	Game.gems = 1
	check("1 gem: nothing to give", Game.rescue_block().contains("at least 2"), Game.rescue_block())
	Game.gems = 50
	Game.eliminated = true
	check("out of the game: no rescue", Game.rescue_block().contains("out of gems"), Game.rescue_block())
	fresh(50)
	Game.give_rescue(15)
	check("giving takes the gems now", Game.gems == 35, str(Game.gems))
	check("...and spends the one chance", Game.rescue_sent and Game.rescue_block().contains("used"))
	Game.begin_adventure(600)
	check("a new adventure gives the chance back", not Game.rescue_sent)
	Game.restore_from({"gems": 30, "rescued_at": "2026-09-27T10:00:00Z", "items_done": 2, "correct": 2})
	check("back into a run: a spent rescue stays spent", Game.rescue_sent)
	Game.restore_from({"gems": 30, "rescued_at": null, "items_done": 2, "correct": 2})
	check("...and an unspent one stays open", not Game.rescue_sent)


# --- The question screen's Rescue button -------------------------------------
func _question_screen() -> void:
	for alone in [true, false]:
		fresh(50)
		if alone:
			Game.session_id = ""
		var q: Control = load("res://scripts/QuizOverlay.gd").new()
		q.station_index = 0
		add_child(q)
		q.setup({})
		await frames(2)
		var b: Button = q.get("_btn_rescue")
		if alone:
			check("question screen, playing alone: no Rescue", not b.is_visible_in_tree())
		else:
			check("question screen, team game: Rescue beside Hint and Skip",
					b.is_visible_in_tree() and not b.disabled and b.get_parent() == q.get("_btn_skip").get_parent())
			b.pressed.emit()
			await frames(4)
			var r: Node = q.find_children("*", "Control", false, false).filter(
					func(c: Node) -> bool: return c.has_signal("finished")).front()
			check("Rescue opens the rescue screen over the question", r != null)
			if r != null:
				# Cancelled: the button is still there to use.
				r.call("_cancel")
				await frames(2)
				check("cancelled: Rescue still ready", not b.disabled and b.text == "Rescue")
			b.pressed.emit()
			await frames(4)
			r = q.find_children("*", "Control", false, false).filter(
					func(c: Node) -> bool: return c.has_signal("finished")).front()
			Game.give_rescue(10)          # what a confirmed rescue does, then it closes
			r.call("_close", "You gave 10 gems to ben")
			await frames(2)
			check("once used, the button says so and is off", b.disabled and b.text == "Rescued",
					"%s %s" % [b.disabled, b.text])
			check("...and the question screen says what was given",
					label_text(q, "You gave 10 gems to ben") != "")
			check("...and why", b.tooltip_text.contains("used"), b.tooltip_text)
		q.queue_free()
		await frames(1)


# --- Picking a teammate, choosing the amount, giving ------------------------
func _flow() -> void:
	fresh(50)
	var r := await overlay()
	check("title", label_text(r, "Rescue a teammate") != "")
	check("the one-chance rule is stated up front", label_text(r, "ONE rescue") != "")
	check("every teammate listed", pick(r, "ben") != null and pick(r, "dee") != null
			and pick(r, "eli") != null and pick(r, "fay") != null)
	check("an eliminated teammate is shown, not offered", pick(r, "dee").disabled and pick(r, "dee").text == "Out")
	check("a finished teammate is shown, not offered", pick(r, "eli").disabled and pick(r, "eli").text == "Finished")
	check("the others can be picked", not pick(r, "ben").disabled and not pick(r, "fay").disabled)
	var ben_gems: Label = node(node(r, "Mate_ben"), "Gems")
	var fay_gems: Label = node(node(r, "Mate_fay"), "Gems")
	check("a teammate running low is in red",
			ben_gems.get_theme_color("font_color") == Pal.WRONG and fay_gems.get_theme_color("font_color") != Pal.WRONG)

	pick(r, "ben").pressed.emit()
	await frames(2)
	var amount: LineEdit = node(r, "Amount")
	var give: Button = node(r, "Give")
	var preview: Label = node(r, "Preview")
	check("the amount screen names the teammate", label_text(r, "Give gems to ben") != "")
	check("it starts at 10", amount.text == "10", amount.text)
	check("it shows what it leaves you both", preview.text == "You: 50 → 40   ·   ben: 6 → 16", preview.text)
	check("the button says what it gives", give.text == "Give 10 gems" and not give.disabled, give.text)
	check("the warning is there", label_text(r, "one rescue") != "")
	check("a phone opens its number pad", amount.virtual_keyboard_type == LineEdit.KEYBOARD_TYPE_NUMBER)
	var more: Button = node(r, "More")
	var less: Button = node(r, "Less")
	more.pressed.emit(); more.pressed.emit()
	check("+ adds one", amount.text == "12", amount.text)
	for i in 15:
		less.pressed.emit()
	check("− stops at 1", amount.text == "1", amount.text)
	check("one gem reads right", give.text == "Give 1 gem", give.text)
	amount.text = "7x"
	amount.text_changed.emit("7x")
	check("only digits stay in the box", amount.text == "7", amount.text)
	amount.text = "99"
	amount.text_changed.emit("99")
	check("past the most you can give it stops there", amount.text == "49", amount.text)
	check("...and says why", label_text(r, "at most 49") != "")
	amount.text = ""
	amount.text_changed.emit("")
	check("an empty box cannot give", give.disabled and preview.text.begins_with("Enter"))

	(node(r, "Give").get_parent().get_child(0) as Button).pressed.emit()   # Back
	await frames(4)
	check("Back returns to the list", pick(r, "fay") != null and node(r, "Amount") == null)

	pick(r, "fay").pressed.emit()
	await frames(2)
	amount = node(r, "Amount")
	give = node(r, "Give")
	amount.text = "20"
	amount.text_changed.emit("20")
	var summary := [""]
	r.finished.connect(func(s: String) -> void: summary[0] = s)
	give.pressed.emit()
	give.pressed.emit()         # a second tap while it is sending
	await frames(6)
	check("one tap, one rescue", _sent.size() == 1, str(_sent))
	check("sent to the teammate picked, with the amount chosen", _sent.size() == 1 and _sent[0] == ["fay-id", 20],
			str(_sent))
	check("the gems leave the rescuer", Game.gems == 30, str(Game.gems))
	check("the one chance is spent", Game.rescue_sent)
	check("the teammate's phone is told who and how many", _told.size() == 1
			and _told[0].to == "fay-id" and _told[0].from == "me" and _told[0].amount == 20
			and _told[0].sid == SID, str(_told))
	check("it closes with what happened", summary[0] == "You gave 20 gems to fay", summary[0])
	check("...and is gone", not is_instance_valid(r))


# --- What the server refuses, and the odd cases ------------------------------
func _refusals() -> void:
	fresh(50)
	_reply = {"error": "you have already used your rescue", "row": {}}
	var r := await overlay()
	pick(r, "ben").pressed.emit()
	await frames(2)
	(node(r, "Give") as Button).pressed.emit()
	await frames(5)
	check("a refused rescue moves no gems here", Game.gems == 50, str(Game.gems))
	check("the server's reason is shown", label_text(r, "You have already used your rescue.") != "")
	check("if the server says it is spent, it is spent", Game.rescue_sent)
	check("and the rescue screen stays open to read it", is_instance_valid(r))
	r.queue_free()

	fresh(50)
	_reply = {"error": "that player is already out", "row": {}}
	r = await overlay()
	pick(r, "ben").pressed.emit()
	await frames(2)
	(node(r, "Give") as Button).pressed.emit()
	await frames(5)
	check("a teammate who went out meanwhile: said, nothing spent",
			label_text(r, "That player is already out.") != "" and not Game.rescue_sent and Game.gems == 50)
	check("...and Give can be tried again", not (node(r, "Give") as Button).disabled)
	r.queue_free()

	fresh(50)
	r = await overlay([])
	check("alone on a team: said plainly", label_text(r, "No teammates to rescue") != "")
	r.queue_free()

	fresh(12)
	r = await overlay()
	pick(r, "ben").pressed.emit()
	await frames(2)
	check("with 12 gems it starts at 10 and tops out at 11",
			(node(r, "Amount") as LineEdit).text == "10" and Game.rescue_max() == 11)
	r.queue_free()
	await frames(1)


# --- From the map, and on the rescued player's phone -------------------------
func _map_and_news() -> void:
	Game.touch = true
	Game.session_id = ""
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await frames(2)
	main.open("adventure")
	await frames(6)
	var adv: Node = main.current
	adv.skip_intro()
	Game.session_id = ""
	await frames(2)

	# Playing alone: no Rescue on the top bar.
	adv.hud.refresh()
	await frames(2)
	var mb := _hud_button(adv, "Rescue")
	check("playing alone: no Rescue on the bar", mb == null)

	Game.session_id = SID
	adv.hud.refresh()
	await frames(2)
	mb = _hud_button(adv, "Rescue")
	check("team game: Rescue on the bar, right after the gems", mb != null and not mb.disabled
			and mb.get_parent() == adv.hud._bar and mb.get_index() == adv.hud._gems.get_parent().get_parent().get_index() + 1)
	check("...and not focusable, so E / Space / Enter stay the map's", mb.focus_mode == Control.FOCUS_NONE)
	check("the bar still fits the screen with it", adv.hud._bar.get_combined_minimum_size().x
			<= adv.get_viewport_rect().size.x - 12.0,
			"%d > %d" % [adv.hud._bar.get_combined_minimum_size().x, adv.get_viewport_rect().size.x - 12.0])
	mb.pressed.emit()
	await frames(4)
	check("it opens the rescue screen", adv._overlay != null and adv._overlay.has_signal("finished"))
	check("the stick is put away while it is open", not adv.hud.pad.visible)
	(adv._overlay as Control).call("_cancel")
	await frames(3)
	check("Cancel goes back to the map", adv._overlay == null and adv.hud.pad.visible)

	Game.gems = 1
	Game.gems_changed.emit(Game.gems)
	await frames(1)
	check("1 gem: greyed, and says why", mb.disabled and mb.tooltip_text.contains("at least 2"), mb.tooltip_text)
	Game.gems = 50
	Game.rescue_sent = true
	Game.gems_changed.emit(Game.gems)
	await frames(1)
	check("once used, the bar says so and it is off", mb.text == "Rescued" and mb.disabled, mb.text)

	# The old menu could not open while paused or while watching; the bar's
	# button must not either (a finished player giving gems after their finish).
	Game.rescue_sent = false
	adv.hud.paused = true
	await frames(1)
	check("paused by the Quest Keeper: greyed, and says why", mb.disabled
			and mb.tooltip_text.contains("paused"), mb.tooltip_text)
	adv.open_rescue()
	await frames(2)
	check("...and it does not open", adv._overlay == null)
	adv.hud.paused = false
	adv._spectate = "finished"
	adv.hud._refresh_rescue()
	adv.hud.set_pad(false)
	await frames(1)
	check("finished and watching: greyed", mb.disabled and mb.tooltip_text.contains("done"), mb.tooltip_text)
	adv.open_rescue()
	await frames(2)
	check("...it does not open, and the stick stays away", adv._overlay == null and not adv.hud.pad.visible)
	adv._spectate = ""
	adv.hud._refresh_rescue()
	adv.hud.set_pad(true)
	await frames(1)
	check("back on the board: open again", not mb.disabled, mb.tooltip_text)

	# No menu: Esc and the back button leave the player on the map, playing.
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	Input.parse_input_event(esc)
	await frames(2)
	adv.go_back()
	await frames(2)
	check("Esc and back open nothing", main.current == adv and adv._overlay == null
			and not adv.hud.paused and Game.adventure_active)
	check("no MENU button on the pad", adv.hud._pad_buttons.size() == 1)

	# The rescued player's phone: the news, over everything, and no gems from it.
	var gems_before: int = Game.gems
	adv._on_broadcast("rescue", {"sid": SID, "to": "someone-else", "from": "ana", "amount": 15})
	await frames(1)
	var news: Label = adv.hud.ui_layer.find_child("News", true, false)
	check("news for someone else is not shown here", news == null or news.text == "")
	adv._on_broadcast("rescue", {"sid": "another-session", "to": Net.user_id, "from": "ana", "amount": 15})
	await frames(1)
	news = adv.hud.ui_layer.find_child("News", true, false)
	check("news from another session is not shown", news == null or news.text == "")
	var q: Control = load("res://scripts/QuizOverlay.gd").new()
	q.station_index = 0
	adv._show_overlay(q)
	await frames(2)
	adv._on_broadcast("rescue", {"sid": SID, "to": Net.user_id, "from": "ana", "amount": 15})
	await frames(1)
	news = adv.hud.ui_layer.find_child("News", true, false)
	check("rescued: who and how many", news != null and news.text == "ana rescued you!  +15 gems",
			news.text if news != null else "none")
	var bar: Node = adv.hud.ui_layer.find_child("NewsBar", true, false)
	check("...shown over the question screen", bar != null and bar.get_index() > q.get_index()
			and (bar as Control).visible)
	check("the message alone moves no gems", Game.gems == gems_before, str(Game.gems))
	adv._take_server_row({"gems": gems_before + 15, "eliminated": false})
	await frames(1)
	check("the server's row brings the gems", Game.gems == gems_before + 15, str(Game.gems))
	check("...and the question screen shows them",
			(q.get("_gems_row") as Label).text == str(gems_before + 15), (q.get("_gems_row") as Label).text)
	adv.close_overlay()
	Game.session_id = ""
	await frames(2)


func _hud_button(adv: Node, text: String) -> Button:
	for b in adv.hud.hud_layer.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with(text) and (b as Button).is_visible_in_tree():
			return b
	return null

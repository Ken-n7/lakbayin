extends Control

## Rescue (client, 2026-09-27): give a teammate who is running out of gems some
## of your own. Two steps on one panel:
##   1. pick the teammate -- your team, lowest gems first, with who is out or
##      already through the Victory Gate shown but not offered;
##   2. choose how many gems to give, see what it leaves both of you, confirm.
## ONE rescue per player per adventure; at least 1 gem, and never your last.
## `public.rescue()` decides all of it again -- this screen only makes the
## allowed thing easy.
##
## Opened by the question screen's Rescue button and by the map's menu. Its
## network is three Callables, so the tests drive the real screen offline.

signal finished(summary: String)   # "" when cancelled

const PANEL := Vector2(430, 300)
## A teammate at or under this many gems is the one who needs it: in red.
const LOW_GEMS := 10

## () -> Array of {profile_id, username, gems, eliminated, finished}
var fetch_mates: Callable = func() -> Array:
	return await Teams.teammates(Game.session_id)
## (to_profile_id, amount) -> {error, row}
var send: Callable = func(to: String, amount: int) -> Dictionary:
	return await Scores.rescue(Game.session_id, to, amount)
## (payload) -> void: tells the teammate's phone, which says who and how many.
var notify: Callable = func(payload: Dictionary) -> void:
	Net.realtime().send_broadcast("rescue", payload)

var _box: VBoxContainer
var _msg: Label
var _mate: Dictionary = {}
var _amount: LineEdit
var _preview: Label
var _give: Button
var _busy := false
var _keep := 0          # the panel's own title and rule, which steps never clear


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP     # nothing under it takes a tap
	Ui.dim(self)
	_box = Ui.screen_panel(self, PANEL, "Rescue a teammate")
	_box.add_theme_constant_override("separation", 6)
	_keep = _box.get_child_count()
	_show_list()


# --- Step 1: who -------------------------------------------------------------
func _show_list() -> void:
	_clear()
	_mate = {}
	_box.add_child(_line("Give some of your gems to a teammate who is running low. "
			+ "You get ONE rescue this adventure.", Pal.SMALL, Pal.INK_MUTED))
	var loading := _line("Finding your teammates…", Pal.BODY, Pal.INK_MUTED)
	_box.add_child(loading)
	_add_msg()
	_add_footer([["Cancel", Ui.SMALL, _cancel]])
	var mates: Array = await fetch_mates.call()
	if not is_instance_valid(loading):
		return
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if mates.is_empty():
		loading.text = "No teammates to rescue — you are the only one on your team."
		return
	loading.queue_free()
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.custom_minimum_size = Vector2(0, mini(mates.size(), 4) * 40)
	sc.add_child(list)
	_box.add_child(sc)
	_box.move_child(sc, _keep + 1)     # under the explainer, over the message
	DragScroll.attach(sc)
	for m: Dictionary in mates:
		list.add_child(_mate_row(m))


func _mate_row(m: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.name = "Mate_" + str(m.get("username", "?"))
	row.add_theme_constant_override("separation", 8)
	var who := Art.label(str(m.get("username", "?")), Pal.BODY, Pal.INK)
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	who.clip_text = true
	row.add_child(who)
	var gems := int(m.get("gems", 0))
	var gem_row := HBoxContainer.new()
	gem_row.add_theme_constant_override("separation", 3)
	gem_row.add_child(Art.texrect(Ui.GEM, 18, 18))
	var g := Art.label(str(gems), Pal.BODY, Pal.WRONG if gems <= LOW_GEMS else Pal.INK)
	g.name = "Gems"
	g.custom_minimum_size = Vector2(36, 0)
	gem_row.add_child(g)
	row.add_child(gem_row)
	var why := ""
	if bool(m.get("eliminated", false)):
		why = "Out"
	elif bool(m.get("finished", false)):
		why = "Finished"
	var b := Ui.button(why if why != "" else "Rescue", 96, Ui.H, Ui.SMALL if why != "" else Ui.SMALL_RED)
	b.name = "Pick"
	b.disabled = why != ""
	b.tooltip_text = ("%s is already out of gems" if why == "Out" else
			"%s has already finished" if why == "Finished" else "Give gems to %s") % m.get("username", "?")
	b.pressed.connect(_show_amount.bind(m))
	row.add_child(b)
	return row


# --- Step 2: how many --------------------------------------------------------
func _show_amount(m: Dictionary) -> void:
	_clear()
	_mate = m
	var name_s := str(m.get("username", "?"))
	_box.add_child(_line("Give gems to %s" % name_s, Pal.H2, Pal.TITLE))
	_box.add_child(_line("%s has %d gems  ·  you have %d" % [name_s, int(m.get("gems", 0)), Game.gems],
			Pal.SMALL, Pal.INK_MUTED))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	var minus := Ui.button("−", 48, 40, Ui.SMALL)
	minus.name = "Less"
	minus.tooltip_text = "One gem less"
	minus.pressed.connect(func() -> void: _set_amount(_value() - 1))
	_amount = Ui.line_edit("", 90, 40, 24)
	_amount.name = "Amount"
	_amount.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_amount.max_length = 3
	_amount.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	_amount.text_changed.connect(_typed)
	var plus := Ui.button("+", 48, 40, Ui.SMALL)
	plus.name = "More"
	plus.tooltip_text = "One gem more"
	plus.pressed.connect(func() -> void: _set_amount(_value() + 1))
	row.add_child(minus)
	row.add_child(_amount)
	row.add_child(plus)
	_box.add_child(row)
	_preview = _line("", Pal.BODY, Pal.INK)
	_preview.name = "Preview"
	_box.add_child(_preview)
	_box.add_child(_line("This uses your one rescue. It can't be undone.", Pal.SMALL, Pal.WRONG))
	_add_msg()
	_give = _add_footer([["Back", Ui.SMALL, _show_list], ["", Ui.RED, _confirm]])[1]
	_give.name = "Give"
	_set_amount(mini(10, Game.rescue_max()))


func _value() -> int:
	return int(_amount.text) if _amount.text.is_valid_int() else 0


## The field holds only digits, and only 1..rescue_max(): past the top it
## stops at the top and says why, rather than refusing the key silently.
func _typed(t: String) -> void:
	var digits := ""
	for ch in t:
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits != t:
		_amount.text = digits
		_amount.caret_column = digits.length()
	var v := int(digits) if digits != "" else 0
	if v > Game.rescue_max():
		_set_amount(Game.rescue_max())
		_say("You can give at most %d — you keep 1 gem." % Game.rescue_max(), Pal.WRONG)
		return
	_refresh_preview()


func _set_amount(v: int) -> void:
	v = clampi(v, 1, maxi(Game.rescue_max(), 1))
	_amount.text = str(v)
	_amount.caret_column = _amount.text.length()
	_say("", Pal.INK)
	_refresh_preview()


func _refresh_preview() -> void:
	var v := _value()
	var ok := v >= 1 and v <= Game.rescue_max()
	var mate_gems := int(_mate.get("gems", 0))
	_preview.text = ("You: %d → %d   ·   %s: %d → %d" % [Game.gems, Game.gems - v,
			_mate.get("username", "?"), mate_gems, mate_gems + v]) if ok else "Enter how many gems to give"
	_give.text = "Give %d gem%s" % [v, "" if v == 1 else "s"] if ok else "Give"
	_give.disabled = not ok or _busy


func _confirm() -> void:
	var v := _value()
	if _busy or _mate.is_empty() or v < 1 or v > Game.rescue_max() or Game.rescue_block() != "":
		return
	_busy = true
	_refresh_preview()
	_say("Sending…", Pal.INK_MUTED)
	var name_s := str(_mate.get("username", "?"))
	var reply: Dictionary = await send.call(str(_mate.get("profile_id", "")), v)
	if not is_instance_valid(self):
		return
	_busy = false
	if str(reply.get("error", "")) != "":
		var err := str(reply.error)
		# The server keeps the count: if it says the rescue is spent, it is.
		if err.contains("already used"):
			Game.rescue_sent = true
		_say(err.left(1).to_upper() + err.substr(1) + ("" if err.ends_with(".") else "."), Pal.WRONG)
		_refresh_preview()
		return
	var settled: Dictionary = Scores.latest(reply.get("row", {}))
	Scores.know(settled)
	Game.give_rescue(v, settled)
	Sfx.play("rescue")
	notify.call({"sid": Game.session_id, "to": str(_mate.get("profile_id", "")),
			"from": Net.username, "amount": v})
	_close("You gave %d gem%s to %s" % [v, "" if v == 1 else "s", name_s])


# --- Bits --------------------------------------------------------------------
func _cancel() -> void:
	_close("")


func _close(summary: String) -> void:
	finished.emit(summary)
	queue_free()


func _clear() -> void:
	for c in _box.get_children():
		if c.get_index() < _keep:
			continue
		_box.remove_child(c)
		c.queue_free()
	_msg = null


func _line(text: String, size: int, color: Color) -> Label:
	var l := Art.label(text, size, color, HORIZONTAL_ALIGNMENT_CENTER)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(PANEL.x - 40, 0)
	return l


func _add_msg() -> void:
	_msg = _line("", Pal.SMALL, Pal.WRONG)
	_msg.name = "Message"
	_box.add_child(_msg)


func _say(text: String, color: Color) -> void:
	if _msg != null and is_instance_valid(_msg):
		_msg.text = text
		_msg.add_theme_color_override("font_color", color)


## A centred row of [label, kind, callable] buttons; returns them in order.
func _add_footer(specs: Array) -> Array:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	var out: Array = []
	for s: Array in specs:
		var b := Ui.button(s[0] if s[0] != "" else "Give", 140, Ui.H, s[1])
		b.pressed.connect(s[2])
		row.add_child(b)
		out.append(b)
	_box.add_child(row)
	return out

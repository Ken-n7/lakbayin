class_name HowToPlay
extends RefCounted

## How to Play, over whatever screen opened it: what Baybayin is, how it is
## read, a word built key by key, one to write yourself, then the match and
## its teamwork. Home opens it the first time it shows on a device; Settings
## opens it again on request.
##
## Every picture is the game's own: its keypad, its font, its art, and
## screenshots of the game itself (assets/ui/guide/, tools/guide_shots.py).

const W := 584.0
const PAGE := Vector2(552, 222)
const SIDE_W := 200.0            # the text column, right of each picture
const ART_W := PAGE.x - SIDE_W - 14.0
const BEAT := 0.9                # seconds a key, when the keypad types itself
const SHOTS := "res://assets/ui/guide/%s.png"

const WHAT := "ᜊᜌ᜔ᜊᜌᜒᜈ᜔"       # baybayin, in Baybayin
const DEMO := ["ᜊ", "ᜑ", "ᜌ", "᜔"]  # bahay, a key at a time
## Page 5's words, one after the other: one ending in a vowel, then one in
## a consonant -- the cross, typed by the player.
const TRIES := [
	{"word": "aso", "modern": "ᜀᜐᜓ", "traditional": "ᜀᜐᜓ",
		"ask": "Write aso (dog).", "hint": "Hint: ᜀ a, then ᜐ sa with the mark below: so."},
	{"word": "ibon", "modern": "ᜁᜊᜓᜈ᜔", "traditional": "ᜁᜊᜓ",
		"ask": "Now ibon (bird). It ends in n.", "hint": "Hint: ᜁ i, ᜊ ba with the mark below: bo, then ᜈ na with the cross: n."},
]


## Opens over `parent`; `on_close` runs when it is closed, however.
static func open(parent: Node, on_close := Callable()) -> Control:
	var d := Ui.dim(parent)
	d.name = "HowToPlay"
	var close := func() -> void:
		d.queue_free()
		if on_close.is_valid():
			on_close.call()
	var box := Ui.back_panel(d, Vector2(W, 0), "How to Play", close)
	box.add_theme_constant_override("separation", 6)
	var head: Label = box.get_child(0).get_child(1)
	var stack := Control.new()
	stack.custom_minimum_size = PAGE
	box.add_child(stack)
	var pages := [_what(), _letters(), _marks(), _build(), _turn(), _match(), _team()]
	for p: Array in pages:
		var page: Control = p[1]
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		stack.add_child(page)

	var back := Ui.button("Back", 110, Ui.H, Ui.SMALL)
	back.name = "Back"
	var count := Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	count.custom_minimum_size = Vector2(80, 0)
	var next := Ui.button("Next", 110, Ui.H, Ui.RED)
	next.name = "Next"
	var row := Ui.centre_row(box, back)
	row.add_theme_constant_override("separation", 24)
	row.add_child(count)
	row.add_child(next)

	var at := [0]   # a box: lambdas capture locals by value
	var show := func() -> void:
		for i in pages.size():
			(pages[i][1] as Control).visible = i == at[0]
		head.text = pages[at[0]][0]
		count.text = "%d / %d" % [at[0] + 1, pages.size()]
		back.disabled = at[0] == 0
		next.text = "Let's Go" if at[0] == pages.size() - 1 else "Next"
	back.pressed.connect(func() -> void:
		at[0] = maxi(at[0] - 1, 0)
		show.call())
	next.pressed.connect(func() -> void:
		if at[0] == pages.size() - 1:
			close.call()
		else:
			at[0] += 1
			show.call())
	show.call()
	return d


# --- Pages: [title, page] ---------------------------------------------------
static func _what() -> Array:
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", Ui.face("res://assets/ui/SpecialPaper.png"))
	plate.custom_minimum_size = Vector2(ART_W - 20.0, 120)
	plate.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	plate.add_child(Art.gold_title(WHAT, 44))
	col.add_child(plate)
	col.add_child(Art.label("baybayin", Pal.BODY, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	return ["What Is Baybayin?", _two(col, [
		"A script of the Philippines from before the Spanish came.",
		"Spanish accounts from around 1600 describe it in everyday use for Tagalog.",
		"The Doctrina Christiana (1593), among the first books printed here, uses it.",
		"Each letter is a syllable.",
	])]


static func _letters() -> Array:
	var pad := BaybayinKeypad.new()
	var shown := _reading()
	pad.changed.connect(func(t: String) -> void:
		if t.length() > 8:
			pad.clear()
		_show(shown, pad.text))
	return ["Letters Say \"a\"", _two(_centred(pad), [
		"Each letter is a syllable: ᜊ is ba, ᜃ is ka, ᜋ is ma.",
		"Three letters are vowels: ᜀ a, ᜁ e/i, ᜂ o/u.",
		"ng is one letter: ᜅ, nga.",
		"Tap any key.",
	], shown)]


static func _marks() -> Array:
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 6)
	var big := Art.label("ᜊ", 64, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	big.add_theme_font_override("font", Art.baybayin())
	col.add_child(big)
	var sound := Art.label("ba", Pal.H2, Pal.GOLD_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(sound)
	var keys := HBoxContainer.new()
	keys.alignment = BoxContainer.ALIGNMENT_CENTER
	keys.add_theme_constant_override("separation", 6)
	col.add_child(keys)
	# The last step is a whole word: the cross on the n that ends ibon.
	var steps := [["ᜊ", "ba", 0], ["ᜊᜒ", "bi / be", 1], ["ᜊᜓ", "bu / bo", 2], ["ᜊ᜔", "b", 3],
		["ᜁᜊᜓᜈ᜔", "ibon: i · bo · n", 3]]
	var lit: Array[Button] = []
	for g: String in ["ᜊ", "ᜒ", "ᜓ", "᜔"]:
		lit.append(_key(keys, g))
	var tw := col.create_tween().set_loops()
	for i in steps.size():
		tw.tween_callback(func() -> void:
			big.text = steps[i][0]
			sound.text = steps[i][1]
			for k in lit.size():
				lit[k].button_pressed = k == int(steps[i][2]))
		tw.tween_interval(BEAT * 1.6)
	return ["Marks Change the Sound", _two(col, [
		"Above: the a becomes i or e.",
		"Below: the a becomes u or o.",
		"The cross: no vowel at all.",
		"So a letter with no vowel after it takes the cross: the n of ibon, the k of bundok.",
	])]


static func _build() -> Array:
	var pad := BaybayinKeypad.new()
	var shown := _reading()
	pad.changed.connect(func(_t: String) -> void: _show(shown, pad.text))
	# It types by itself: a demonstration, not something to press.
	pad.ready.connect(func() -> void:
		for b: Node in pad.get_children():
			(b as Button).mouse_filter = Control.MOUSE_FILTER_IGNORE
			(b as Button).toggle_mode = true
		var tw := pad.create_tween().set_loops()
		tw.tween_callback(pad.clear)
		tw.tween_interval(BEAT)
		for g: String in DEMO:
			tw.tween_callback(func() -> void:
				var key := _key_of(pad, g)
				key.button_pressed = true
				pad.press(g))
			tw.tween_interval(BEAT * 0.5)
			tw.tween_callback(func() -> void: _key_of(pad, g).button_pressed = false)
			tw.tween_interval(BEAT * 0.5)
		tw.tween_interval(BEAT * 2.5))
	return ["Build a Word", _two(_centred(pad), [
		"bahay (house), a key at a time:",
		"ᜊ ba, then ᜑ ha, then ᜌ ya, and the cross makes it y.",
		"The old style leaves a vowel-less letter out: ᜊᜑ. That counts too.",
	], shown)]


static func _turn() -> Array:
	var pad := BaybayinKeypad.new()
	var shown := _reading()
	var ask := _line("")
	var hint := _line("")
	var verdict := Art.label("", Pal.BODY, Pal.GOLD_DIM)
	verdict.name = "Verdict"
	var at := [0, false]   # which word; written yet
	var pose := func() -> void:
		ask.text = TRIES[at[0]].ask
		hint.text = TRIES[at[0]].hint
		verdict.text = ""
		at[1] = false
	pad.changed.connect(func(_t: String) -> void:
		_show(shown, pad.text)
		var want: Dictionary = TRIES[at[0]]
		if at[1] or not Baybayin.matches(pad.text, want):
			return
		at[1] = true
		verdict.text = "Tama! That is %s." % want.word
		Sfx.play("correct")
		if at[0] < TRIES.size() - 1:
			var tw := pad.create_tween()
			tw.tween_interval(1.6)
			tw.tween_callback(func() -> void:
				at[0] += 1
				pad.clear()
				pose.call()))
	pose.call()
	var side := _side([], shown)
	for c: Control in [ask, hint, verdict]:
		side.add_child(c)
	var page := HBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	page.add_child(_centred(pad))
	page.add_child(side)
	return ["Your Turn", page]


static func _match() -> Array:
	return ["The Match", _shots([
		["monk", "Walk up to a monk and tap GO."],
		["keypad", "Write its word in Baybayin, then Submit."],
		["deposit", "Carry it to the Monastery and tap GO: only deposited words score."],
		["clock", "Words scored, carried, time left. All words, or the most at the end, wins."],
	])]


static func _team() -> Array:
	return ["Play as a Team", _shots([
		["typing", "A teammate is on this one: try another."],
		["answered", "Your team already has this monk's word."],
		["minimap", "Monks anyone on your team has seen show on the minimap."],
		["locked", "Wrong? That monk waits 10 s for you. Teammates can still try."],
	])]


# --- Pieces -----------------------------------------------------------------
## A picture on the left, a column of short lines on the right.
static func _two(picture: Control, lines: Array, extra: Control = null) -> HBoxContainer:
	var page := HBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	picture.custom_minimum_size.x = ART_W
	page.add_child(picture)
	page.add_child(_side(lines, extra))
	return page


static func _side(lines: Array, extra: Control = null) -> VBoxContainer:
	var side := VBoxContainer.new()
	side.alignment = BoxContainer.ALIGNMENT_CENTER
	side.add_theme_constant_override("separation", 8)
	side.custom_minimum_size.x = SIDE_W
	if extra != null:
		side.add_child(extra)
	for line: String in lines:
		side.add_child(_line(line))
	return side


static func _line(text: String) -> Label:
	var l := Art.label(text, Pal.SMALL, Pal.INK)
	l.add_theme_font_override("font", Art.mixed())   # Latin and Baybayin in one line
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = SIDE_W
	return l


static func _centred(c: Control) -> CenterContainer:
	var box := CenterContainer.new()
	box.add_child(c)
	return box


## What has been typed, big, and how it reads under it.
static func _reading() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", -2)
	col.custom_minimum_size.y = 58
	var g := Art.label(" ", 32, Pal.INK)
	g.add_theme_font_override("font", Art.baybayin())
	col.add_child(g)
	col.add_child(Art.label(" ", Pal.BODY, Pal.GOLD_DIM))
	return col


static func _show(reading: VBoxContainer, text: String) -> void:
	(reading.get_child(0) as Label).text = text if text != "" else " "
	(reading.get_child(1) as Label).text = read(text) if text != "" else " "


## Typed Baybayin as its sounds, a syllable at a time: ᜊᜑᜌ᜔ is "ba · ha · y".
## A kudlit's two vowels both shown (bi/be), as the script cannot tell them
## apart either.
static func read(text: String) -> String:
	var sounds := {}
	for k: Array in Baybayin.KEYS:
		sounds[k[0]] = k[1]
	var out: Array[String] = []
	for ch in text:
		var last := out[-1] if not out.is_empty() else ""
		if ch == Baybayin.KUDLIT_I and last.ends_with("a"):
			out[-1] = last.trim_suffix("a") + "i/e"
		elif ch == Baybayin.KUDLIT_U and last.ends_with("a"):
			out[-1] = last.trim_suffix("a") + "u/o"
		elif (ch == Baybayin.KRUS or ch == Baybayin.PAMUDPOD) and last.ends_with("a"):
			out[-1] = last.trim_suffix("a")
		elif sounds.has(ch):
			out.append(str(sounds[ch]))
	return " · ".join(out)


## A key drawn as the keypad draws it, lit (pressed) on cue.
static func _key(row: Container, glyph: String) -> Button:
	var b := Ui.button("", BaybayinKeypad.KEY.x, BaybayinKeypad.KEY.y - 8, Ui.KEY)
	b.toggle_mode = true
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var face := ("◌" + glyph) if Baybayin.MARKS.has(glyph) else glyph
	var g := Art.label(face, BaybayinKeypad.GLYPH_SIZE, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	g.add_theme_font_override("font", Art.baybayin())
	g.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	g.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(g)
	row.add_child(b)
	return b


static func _key_of(pad: BaybayinKeypad, glyph: String) -> Button:
	for k: Array in Baybayin.KEYS:
		if k[0] == glyph:
			return pad.get_node(("Key_" + str(k[1])).validate_node_name()) as Button
	return null


## Four screenshots of the game, two by two, each with its line under it.
static func _shots(items: Array) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 4)
	for it: Array in items:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 2)
		var pic := TextureRect.new()
		pic.texture = load(SHOTS % it[0]) if ResourceLoader.exists(SHOTS % it[0]) else null
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.custom_minimum_size = Vector2(PAGE.x * 0.5 - 6.0, 70)
		cell.add_child(pic)
		var l := Art.label(it[1], Pal.SMALL, Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(PAGE.x * 0.5 - 6.0, 0)
		cell.add_child(l)
		grid.add_child(cell)
	return grid

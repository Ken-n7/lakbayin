extends TestCase
## The Baybayin pieces (Lakbayin, DESIGN.md 4): the word list, the answer check
## (both spellings, the pamudpod), the keypad's rule for marks, the monk's
## answer panel end to end in Practice, and the monk on the map.
##   godot --headless res://scripts/tests/baybayin_test.tscn


func frames(n := 2) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	backup_save()
	var words := Baybayin.words()
	check("the word list loads", words.size() >= 100, str(words.size()))
	var bahay := {"word": "bahay", "modern": "ᜊᜑᜌ᜔", "traditional": "ᜊᜑ"}
	check("modern spelling is correct", Baybayin.matches("ᜊᜑᜌ᜔", bahay))
	check("traditional spelling is correct", Baybayin.matches("ᜊᜑ", bahay))
	check("the pamudpod counts as the krus-kudlit", Baybayin.matches("ᜊᜑᜌ᜕", bahay))
	check("spaces are ignored", Baybayin.matches(" ᜊ ᜑᜌ᜔", bahay))
	check("a wrong spelling is wrong", not Baybayin.matches("ᜊᜌ᜔", bahay))
	check("nothing typed is never correct", not Baybayin.matches("", {"modern": "", "traditional": ""}))
	var every := words.all(func(w: Dictionary) -> bool:
		return Baybayin.matches(str(w.modern), w) and Baybayin.matches(str(w.traditional), w))
	check("every word accepts both of its own spellings", every)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var drawn := Baybayin.draw(10, rng)
	var names := drawn.map(func(w: Dictionary) -> String: return str(w.word))
	check("a match draws ten different words", drawn.size() == 10
		and names.filter(func(n: String) -> bool: return names.count(n) == 1).size() == 10)
	rng.seed = 42
	check("the same seed draws the same words", Baybayin.draw(10, rng).map(
		func(w: Dictionary) -> String: return str(w.word)) == names)

	var pad := BaybayinKeypad.new()
	add_child(pad)
	await frames()
	check("the keypad has 20 keys and backspace", pad.get_child_count() == 21)
	pad.press(Baybayin.KUDLIT_I)
	check("a mark with nothing under it is refused", pad.text == "")
	for g in ["ᜊ", Baybayin.KUDLIT_I, Baybayin.KUDLIT_U]:
		pad.press(g)
	check("one mark per consonant", pad.text == "ᜊᜒ", pad.text)
	pad.press("ᜀ")
	pad.press(Baybayin.KRUS)
	check("no mark on a vowel", pad.text == "ᜊᜒᜀ", pad.text)
	pad.press(Baybayin.BACKSPACE)
	pad.press(Baybayin.BACKSPACE)
	check("backspace takes the mark first, then its consonant", pad.text == "ᜊ", pad.text)
	pad.queue_free()

	# The panel in Practice: a wrong answer locks, a right one closes it.
	var overlay: Control = load("res://scripts/MonkOverlay.gd").new()
	var results: Array = []
	overlay.setup({"word": bahay, "monk": 0, "labels": true,
		"check": func(typed: String) -> String:
			return "correct" if Baybayin.matches(typed, bahay) else "wrong"})
	overlay.answered.connect(func(r: String) -> void: results.append(r))
	add_child(overlay)
	await frames()
	check("the panel shows the word in Latin letters",
		(overlay.find_child("Word", true, false) as Label).text == "bahay")
	for g in ["ᜊ", "ᜌ", Baybayin.KRUS]:
		overlay._keypad.press(g)
	check("typed glyphs appear in the answer box",
		(overlay.find_child("Answer", true, false) as Label).text == "ᜊᜌ᜔")
	await overlay._on_submit()
	check("a wrong answer locks the panel", results == ["wrong"] and overlay._submit.disabled
		and overlay._keypad.text == "", str(results))
	overlay._locked_until = 0.01           # the 10 s, skipped
	await frames()
	for g in ["ᜊ", "ᜑ", "ᜌ", Baybayin.KRUS]:
		overlay._keypad.press(g)
	await overlay._on_submit()
	check("the right answer is accepted", results == ["wrong", "correct"], str(results))
	await get_tree().create_timer(1.4).timeout
	check("and the panel closes itself", not is_instance_valid(overlay))

	var monk := Monk.new()
	monk.index = 3
	add_child(monk)
	await frames()
	var glyphs: Array = monk._signs.signs
	check("a monk wears four Baybayin glyphs", glyphs.size() == 4
		and glyphs.all(func(g: String) -> bool: return g.unicode_at(0) >= 0x1700 and g.unicode_at(0) <= 0x1711))
	var twin := Monk.new()
	twin.index = 3
	add_child(twin)
	await frames()
	check("the same monk wears the same glyphs on every phone", twin._signs.signs == glyphs)
	monk.take("Blue")
	await frames()
	check("answered, it takes the team's colour",
		monk.colour == "Blue" and monk._body.sprite_frames.get_frame_texture("sway", 0) != null)

	# How to Play (HowToPlay.gd): typed Baybayin read back as its sounds.
	check("the guide reads Baybayin as sounds", HowToPlay.read("ᜊᜑᜌ᜔") == "ba · ha · y"
		and HowToPlay.read("ᜀᜐᜓ") == "a · su/o" and HowToPlay.read("ᜅᜒ") == "ngi/e",
		HowToPlay.read("ᜀᜐᜓ"))
	# It opens over Home the first time, and once closed, only from Settings.
	Game.guide_seen = false
	var main: Control = preload("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await frames(4)
	main.open("home")
	await frames(4)
	var guide := main.current.find_child("HowToPlay", true, false) as Control
	check("How to Play opens over Home the first time", guide != null)
	var next := guide.find_child("Next", true, false) as Button
	for i in 4:
		next.pressed.emit()
	await frames()
	var pads: Array = guide.find_children("*", "BaybayinKeypad", true, false).filter(
		func(p: Node) -> bool: return (p as Control).is_visible_in_tree())
	check("page 5 is a keypad to write on", pads.size() == 1, str(pads.size()))
	for g in ["ᜀ", "ᜐ", Baybayin.KUDLIT_U]:
		(pads[0] as BaybayinKeypad).press(g)
	var tama: Array = guide.find_children("*", "Label", true, false).filter(
		func(l: Node) -> bool: return (l as Label).text.begins_with("Tama!"))
	check("writing aso there is praised", tama.size() == 1)
	await get_tree().create_timer(1.8).timeout
	var asks: Array = guide.find_children("*", "Label", true, false).filter(
		func(l: Node) -> bool: return (l as Label).text.begins_with("Now ibon"))
	check("then it asks for ibon, a word ending in a consonant", asks.size() == 1
		and (pads[0] as BaybayinKeypad).text == "")
	for g in ["ᜁ", "ᜊ", Baybayin.KUDLIT_U, "ᜈ", Baybayin.KRUS]:
		(pads[0] as BaybayinKeypad).press(g)
	var verdict := guide.find_child("Verdict", true, false) as Label
	check("writing it, the cross and all, is praised", verdict != null and verdict.text == "Tama! That is ibon.",
		verdict.text if verdict != null else "no verdict")
	while next.text == "Next":
		next.pressed.emit()
	next.pressed.emit()
	await frames()
	var saved := ConfigFile.new()
	saved.load(Game.SAVE_PATH)
	check("Let's Go closes it, and the device remembers",
		not is_instance_valid(guide) and Game.guide_seen and saved.get_value("profile", "guide_seen", false))
	main.open("home")
	await frames(4)
	check("Home does not show it again", main.current.find_child("HowToPlay", true, false) == null)
	main.current._open_settings()
	await frames()
	var again: Array = main.current.find_children("*", "Button", true, false).filter(
		func(b: Node) -> bool: return (b as Button).text == "How to Play")
	check("Settings has How to Play", again.size() == 1)
	if again.size() == 1:
		(again[0] as Button).pressed.emit()
		await frames()
	check("and it opens from there", main.current.find_child("HowToPlay", true, false) != null)
	main.queue_free()
	completed = true
	finish("BAYBAYIN")

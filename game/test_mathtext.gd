extends SceneTree

## Self-check for MathText: exponents typed with a caret become superscripts.
## Run:
##   godot --headless --path game --script res://test_mathtext.gd
##
## Every case is checked and every failure printed, not just the first.

var _fails := 0
var _checks := 0


func _initialize() -> void:
	var M: GDScript = load("res://scripts/MathText.gd")

	# --- Written with a caret (and the spreadsheet's **) -------------------
	for pair: Array in [
		["2^3 = ?", "2³ = ?"],
		["(-2)^3 + 4^2 = ?", "(-2)³ + 4² = ?"],
		["(−2)^3", "(−2)³"],
		["10^12", "10¹²"],
		["5^0 + 10^2 = ?", "5⁰ + 10² = ?"],
		["2^-1", "2⁻¹"],
		["2^−3", "2⁻³"],
		["2^(10)", "2¹⁰"],
		["2^(-1)", "2⁻¹"],
		["2^(n+1)", "2ⁿ⁺¹"],
		["2^( 3 )", "2³"],
		["2**3", "2³"],
		["2 ** 3", "2³"],
		["2 ^ 3 = ?", "2³ = ?"],
		["2^ 3", "2³"],
		["x^2y", "x²y"],
		["2^x+1", "2ˣ+1"],
		["2^n", "2ⁿ"],
		["3^2 × 2^3 − 1", "3² × 2³ − 1"],
		["(3 + 2)^2 ÷ 5", "(3 + 2)² ÷ 5"],
		["-3^2", "-3²"],
	]:
		_check("superscripts(%s)" % pair[0], M.superscripts(pair[0]), pair[1])

	# --- Left exactly as typed ----------------------------------------------
	# Nothing a teacher writes is lost or turned into a different number.
	for same: String in ["8 + (−3)", "2 * 3", "", "What is 2 to the power of 3?",
			"2^", "2^ ", "2^q", "2^Q", "2^(1.5)", "2^()", "2^(3", "2^-", "2^-x",
			"2³ = ?", "(−2)³ + 4²", "15 ÷ (−3)", "½ + ¼", "Ñ^é"]:
		_check("unchanged: %s" % same, M.superscripts(same), same)
	# A caret straight after an exponent stays: 2^3^2 is not 2³² (2 to the 32nd).
	_check("tower keeps its second caret", M.superscripts("2^3^2"), "2³^2")

	# --- Converting twice changes nothing -----------------------------------
	for t: String in ["2^3 = ?", "10^12", "2^(n+1)", "2^q", "2^3^2", "2 ** -1"]:
		var once: String = M.superscripts(t)
		_check("idempotent: %s" % t, M.superscripts(once), once)

	# --- Typed a key at a time ----------------------------------------------
	for pair: Array in [
		["2^3 = ?", "2³ = ?"],
		["10^12 + 2^-3 = ?", "10¹² + 2⁻³ = ?"],
		["(-2)^3 + 4^2 = ?", "(-2)³ + 4² = ?"],
		["2^(n+1)", "2ⁿ⁺¹"],
		["2^10 - 1", "2¹⁰ - 1"],
		["5^0", "5⁰"],
		["2^3^2", "2³^2"],
		["2^q", "2^q"],
	]:
		var typed := _type(M, "", 0, pair[0])
		_check("typed: %s" % pair[0], typed[0], pair[1])
		_check("typed: %s -- caret at the end" % pair[0], typed[1], (pair[1] as String).length())
	# Typing into the middle of a question already there.
	var mid := _type(M, "2 + 3 = ?", 1, "^4")
	_check("typed mid-line", mid[0], "2⁴ + 3 = ?")
	_check("typed mid-line -- caret after the exponent", mid[1], 2)
	# Only the key just typed rides on an exponent before it.
	var still: Array = M.live("x²5 + 1", 7)
	_check("a digit after an exponent elsewhere is left", still[0], "x²5 + 1")
	# An open bracket waits for its close, caret and all.
	var open_b := _type(M, "", 0, "2^(1")
	_check("open bracket waits", open_b[0], "2^(1")
	_check("open bracket waits -- caret", open_b[1], 4)

	# --- The Question Bank form, as a teacher uses it ------------------------
	# Real key presses through the viewport into the real form's fields.
	await process_frame
	var screen: Control = load("res://scripts/QuestionMgmtScreen.gd").new()
	root.add_child(screen)
	screen.call("setup", {})
	await process_frame
	var q: LineEdit = screen.get("_prompt")
	_check("Question placeholder shows the caret", q.placeholder_text, "e.g. (-2)^3 + 4")
	await _keys(q, "(-2)^3 + 4^2 = ?")
	_check("Question field raises as it goes", q.text, "(-2)³ + 4² = ?")
	_check("Question field caret at the end", q.caret_column, q.text.length())
	var h: LineEdit = screen.get("_hint")
	await _keys(h, "Remember 2^3 = 2 × 2 × 2")
	_check("Hint field raises too", h.text, "Remember 2³ = 2 × 2 × 2")
	var a: LineEdit = screen.get("_answer")
	_check("Answer opens a number pad with a minus", a.virtual_keyboard_type,
			LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL)
	await _keys(a, "-8^2")
	_check("Answer field is never raised", a.text, "-8^2")
	screen.queue_free()

	# --- What reaches the quiz ---------------------------------------------
	# A row saved as typed, before this, or straight into the table.
	var QS: GDScript = load("res://scripts/QuestionStore.gd")
	QS.bank = {0: [{"prompt": "(-2)^3 + 4^2 = ?", "answer": "8", "hint": "cube first: 2^3",
		"feedback": "(-2)^3 = -8 and 4^2 = 16"}]}
	var item: Dictionary = QS.item_for(0, 0)
	_check("quiz prompt", item.prompt, "(-2)³ + 4² = ?")
	_check("quiz hint", item.hint, "cube first: 2³")
	_check("quiz rule reminder", item.rule, "(-2)³ = -8 and 4² = 16")
	_check("quiz answer untouched", item.answer, "8")
	QS.bank = {}
	# Saving raises the text fields and nothing else.
	var row: Dictionary = QS._raise({"station": 3, "prompt": "2^10 = ?", "answer": "1024",
		"hint": "2^5 × 2^5", "active": true})
	_check("saved prompt", row.prompt, "2¹⁰ = ?")
	_check("saved hint", row.hint, "2⁵ × 2⁵")
	_check("saved answer", row.answer, "1024")
	_check("saved flag", row.active, true)

	print("---- MATHTEXT %s ---- %d checks, %d failures"
			% ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(1 if _fails > 0 else 0)


## Presses `keys` into `le` one at a time, through the viewport, as a keyboard
## does: focus, then a pressed key event carrying each character.
func _keys(le: LineEdit, keys: String) -> void:
	le.grab_focus()
	if le.has_method("edit"):
		le.call("edit")
	for ch in keys:
		var ev := InputEventKey.new()
		ev.pressed = true
		ev.unicode = ch.unicode_at(0)
		root.push_input(ev)
		var up := ev.duplicate() as InputEventKey
		up.pressed = false
		root.push_input(up)
		await process_frame


## Types `keys` into `text` at `caret`, one key at a time, as a LineEdit would.
func _type(M: GDScript, text: String, caret: int, keys: String) -> Array:
	for ch in keys:
		text = text.substr(0, caret) + ch + text.substr(caret)
		caret += 1
		var got: Array = M.live(text, caret)
		text = got[0]
		caret = got[1]
	return [text, caret]


func _check(what: String, got: Variant, want: Variant) -> void:
	_checks += 1
	if got != want:
		_fails += 1
		print("FAIL  %s\n        got  %s\n        want %s" % [what, got, want])

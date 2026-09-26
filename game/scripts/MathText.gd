class_name MathText
extends RefCounted

## Exponents as a teacher can type them. Phone and laptop keyboards have no
## key for ³, so the Question Bank takes the calculator's spelling -- `2^3`,
## `(-2)^3`, `10^12`, `2^-1`, `2^(n+1)`, and `2**3` for anyone used to a
## spreadsheet -- and turns it into the superscripts the quiz shows: 2³,
## (-2)³, 10¹², 2⁻¹, 2ⁿ⁺¹. Brackets after the caret only group, as they do on
## a calculator, so they are not raised with what they hold.
##
## What follows the caret is either a run of digits (with an optional minus in
## front) or a single letter -- `x^2y` is x²y, `2^x+1` is 2ˣ+1 -- or a bracket
## of those. Anything else is left exactly as typed, caret and all, so nothing
## a teacher writes is lost or silently changed into something else: `2^q`
## (there is no superscript q), `2^`, `2^(1.5)`.
##
## Patrick Hand (Art.TEXT_FONT) draws ⁰-⁹ and ⁿ itself; the rest come from the
## symbol fallback, which at superscript size sits in the line well enough.

const _SUP := {
	"0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
	"5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
	"-": "⁻", "−": "⁻", "+": "⁺",
	"a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ",
	"h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ",
	"o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ",
	"w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
}
const _DIGITS := "0123456789"
const _SUP_DIGITS := "⁰¹²³⁴⁵⁶⁷⁸⁹"


## `text` with every exponent it can read raised; the rest untouched.
static func superscripts(text: String) -> String:
	var out := ""
	var i := 0
	while i < text.length():
		var mark := _caret_at(text, i)
		if mark == 0:
			out += text[i]
			i += 1
			continue
		var j := i + mark
		while j < text.length() and text[j] == " ":
			j += 1
		var got := _exponent(text, j)
		# A caret straight after an exponent (`2^3^2`) stays as typed: raising it
		# would read 2³², which is another number, not a tower.
		if got.is_empty() or (out != "" and _raised(out[out.length() - 1])):
			out += text.substr(i, mark)       # not one we can read: keep as typed
			i += mark
			continue
		out = out.rstrip(" ") + str(got.sup)   # "2 ^ 3" is 2³, not "2 ³"
		i = int(got.end)
	return out


## For a field being typed in: `text` converted, and where the caret goes.
##
## One more rule than `superscripts()`, because typing arrives a key at a time:
## `10^1` has already become 10¹ by the time the 2 of `10^12` is pressed, so a
## digit typed straight after a raised digit (or a raised minus) is raised too.
## Only the key just behind the caret is looked at: a digit sitting after an
## exponent anywhere else in the line (`x²5 + 1`) is never touched.
static func live(text: String, caret: int) -> Array:
	caret = clampi(caret, 0, text.length())
	if caret >= 2 and _DIGITS.contains(text[caret - 1]) \
			and (_SUP_DIGITS.contains(text[caret - 2]) or text[caret - 2] == "⁻"):
		text = text.substr(0, caret - 1) + str(_SUP[text[caret - 1]]) + text.substr(caret)
	var head := superscripts(text.substr(0, caret))
	var all := superscripts(text)
	# The caret stays after what it was after. The head converts the same way
	# the whole does unless a bracket is still open across the caret -- `2^(1|`
	# -- and an open bracket is left as typed, so the head is exact.
	return [all, mini(head.length(), all.length())]


static func _raised(ch: String) -> bool:
	return _SUP.values().has(ch)


## 2 for `**`, 1 for `^`, 0 for anything else.
static func _caret_at(text: String, i: int) -> int:
	if text[i] == "^":
		return 1
	if text[i] == "*" and i + 1 < text.length() and text[i + 1] == "*":
		return 2
	return 0


## The exponent starting at `j`: {sup, end} or {} when there is none to read.
static func _exponent(text: String, j: int) -> Dictionary:
	if j >= text.length():
		return {}
	if text[j] == "(":
		var close := text.find(")", j)
		if close < 0:
			return {}
		var inner := text.substr(j + 1, close - j - 1).replace(" ", "")
		if inner.is_empty():
			return {}
		var sup := ""
		for ch in inner:
			if not _SUP.has(ch):
				return {}
			sup += str(_SUP[ch])
		return {"sup": sup, "end": close + 1}
	var k := j
	var sup := ""
	if text[k] == "-" or text[k] == "−":
		sup = "⁻"
		k += 1
	var start := k
	while k < text.length() and _DIGITS.contains(text[k]):
		sup += str(_SUP[text[k]])
		k += 1
	if k > start:
		return {"sup": sup, "end": k}
	if sup == "" and k < text.length() and text[k] >= "a" and text[k] <= "z" and _SUP.has(text[k]):
		return {"sup": str(_SUP[text[k]]), "end": k + 1}
	return {}

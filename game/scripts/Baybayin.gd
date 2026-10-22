class_name Baybayin
extends RefCounted

## The script itself: the keypad's 20 keys, the word list, and the answer check.
##
## The server decides answers in a match (`answer_monk`, schema 4e); this check
## is the same rule, for Practice -- which has no server -- and for the keypad's
## own feedback. Both spellings are correct (DESIGN.md 4.2): `modern` writes a
## vowelless consonant with the krus-kudlit, `traditional` leaves it out.

const WORDS_PATH := "res://data/words.json"

const KRUS := "᜔"          # krus-kudlit: cancels the vowel
const PAMUDPOD := "᜕"      # the newer mark for the same thing
const KUDLIT_I := "ᜒ"
const KUDLIT_U := "ᜓ"

## [glyph, Latin label], in keypad order: three rows of seven, the last key
## backspace. Vowels and the marks sit at the row ends, consonants between.
const KEYS := [
	["ᜀ", "a"], ["ᜁ", "e/i"], ["ᜂ", "o/u"],
	["ᜃ", "ka"], ["ᜄ", "ga"], ["ᜅ", "nga"], ["ᜆ", "ta"],
	["ᜇ", "da"], ["ᜈ", "na"], ["ᜉ", "pa"], ["ᜊ", "ba"],
	["ᜋ", "ma"], ["ᜌ", "ya"], ["ᜎ", "la"],
	["ᜏ", "wa"], ["ᜐ", "sa"], ["ᜑ", "ha"],
	[KUDLIT_I, "i"], [KUDLIT_U, "u"], [KRUS, "×"], ["⌫", ""],
]
const BACKSPACE := "⌫"
const MARKS := [KUDLIT_I, KUDLIT_U, KRUS]
const CONSONANTS := "ᜃᜄᜅᜆᜇᜈᜉᜊᜋᜌᜎᜏᜐᜑ"

static var _words: Array = []


## Every word: [{word, meaning, syllables, modern, traditional}].
static func words() -> Array:
	if _words.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(WORDS_PATH))
		_words = parsed if parsed is Array else []
	return _words


## `n` different words, drawn by `rng` (a match's seed, or Practice's own).
static func draw(n: int, rng: RandomNumberGenerator) -> Array:
	var pool := words().duplicate()
	var out: Array = []
	while out.size() < n and not pool.is_empty():
		out.append(pool.pop_at(rng.randi_range(0, pool.size() - 1)))
	return out


## What was typed, as the server compares it: no spaces, and the pamudpod read
## as the krus-kudlit -- both cancel the vowel.
static func clean(typed: String) -> String:
	return typed.replace(" ", "").replace(PAMUDPOD, KRUS).strip_edges()


static func matches(typed: String, entry: Dictionary) -> bool:
	var t := clean(typed)
	return t != "" and (t == str(entry.get("modern", "")) or t == str(entry.get("traditional", "")))


## A mark goes only on a consonant that has none yet: ᜊ + ᜒ, never ᜒ alone,
## on a vowel, or twice.
static func can_add(text: String, key: String) -> bool:
	if not MARKS.has(key):
		return true
	return text != "" and CONSONANTS.contains(text[text.length() - 1])

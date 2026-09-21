class_name QuestionGen
extends RefCounted

## Procedural problem generators for the three NumXventure stations, plus the
## station metadata (titles, missions, colors) and rule-reminder feedback text.
##
## Questions are generated (never hand-typed) so every run is different; the
## answers are computed in-engine so the scoring can be trusted.

const SUPER := ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]

const RULES := {
	"add": "Addition: same signs → add and keep the sign. Different signs → subtract the smaller number from the bigger number and keep the sign of the bigger number.",
	"sub": "Subtraction: add the opposite. a − b = a + (−b), then follow the addition rule.",
	"mul": "Multiplication: same signs → positive. Different signs → negative.",
	"div": "Division: same signs → positive. Different signs → negative. You may only divide exactly.",
	"exp": "Exponents: multiply the base by itself 'exponent' times. 2³ = 2 × 2 × 2 = 8. A negative base with an odd exponent stays negative.",
	"pemdas": "Order of operations: Parentheses → Exponents → Multiply / Divide (left to right) → Add / Subtract (left to right).",
}

const HINTS := {
	"add": "Check the signs: subtract when signs differ, keep the bigger number's sign.",
	"sub": "Rewrite subtraction as adding the opposite first.",
	"mul": "Count the negative signs: an even number → positive, odd → negative.",
	"div": "Divide the numbers, then apply the sign rule.",
	"exp": "Write it out as repeated multiplication, then multiply step by step.",
	"pemdas": "Solve inside parentheses first, then exponents, then × and ÷ before + and −.",
}

const STATIONS := [
	{
		"id": 1,
		"title": "Station 1: Master the Basics!",
		"accent": "Blue",
		"short": "Basic Operations",
		"mission": "Welcome, adventurer! In this station you will practice the four fundamental operations: addition, subtraction, multiplication, and division of integers. Learn how to handle positive and negative numbers correctly.",
	},
	{
		"id": 2,
		"title": "Station 2: Follow the Right Order!",
		"accent": "Orange",
		"short": "Order of Operations",
		"mission": "Not all math problems are solved left to right! In this station you'll apply the correct order of operations: Parentheses, Exponents, Multiplication & Division, Addition & Subtraction.",
	},
	{
		"id": 3,
		"title": "Station 3: Power Up with Exponents!",
		"accent": "Red",
		"short": "Exponential Notation",
		"mission": "Welcome to the power zone! In this station you will learn how exponential notation represents repeated multiplication. Understand bases and exponents to simplify expressions easily.",
	},
]


static func station_meta(index: int) -> Dictionary:
	return STATIONS[index]


static func item_for_station(station_index: int, item_index: int) -> Dictionary:
	match station_index:
		0: return _basic(item_index)
		1: return _pemdas(item_index)
		2: return _exponent(item_index)
	return _basic(item_index)


# --- Station 1: Basic operations ---------------------------------------------
static func _basic(i: int) -> Dictionary:
	var ops := ["add", "sub", "mul", "div"]
	var op: String = ops[i % 4]
	var a := 0
	var b := 0
	match op:
		"add":
			a = randi_range(-14, 14)
			b = randi_range(-14, 14)
			# keep a few sign-sensible classics
			if i == 0:
				a = 8; b = -3
			return {
				"prompt": "%d + %d" % [a, b] if b >= 0 else "%d + (%d)" % [a, b],
				"answer": a + b,
				"topic": op,
				"rule": RULES[op],
				"hint": HINTS[op],
			}
		"sub":
			a = randi_range(-14, 14)
			b = randi_range(-14, 14)
			if i == 1:
				a = 5; b = -7
			return {
				"prompt": "%d − %d" % [a, b] if b >= 0 else "%d − (%d)" % [a, b],
				"answer": a - b,
				"topic": op,
				"rule": RULES[op],
				"hint": HINTS[op],
			}
		"mul":
			a = randi_range(2, 9)
			b = randi_range(2, 9)
			if randi_range(0, 1) == 1:
				a = -a
			if i == 2:
				a = -6; b = 4
			return {
				"prompt": "%d × %d" % [a, b],
				"answer": a * b,
				"topic": op,
				"rule": RULES[op],
				"hint": HINTS[op],
			}
		"div":
			var q := randi_range(2, 9)
			b = randi_range(2, 9)
			a = q * b
			if randi_range(0, 1) == 1:
				a = -a
			if i == 3:
				a = -24; b = 6
			return {
				"prompt": "%d ÷ %d" % [a, b],
				"answer": a / b,
				"topic": op,
				"rule": RULES[op],
				"hint": HINTS[op],
			}
	return {}


# --- Station 3: Exponential notation -----------------------------------------
static func _exponent(i: int) -> Dictionary:
	var mode := i % 3
	var base := randi_range(2, 6)
	var exp := randi_range(2, 4)
	# Each mode needs enough distinct outputs that a 10-item station does not
	# repeat itself: mode 2 used to be base 2 only, i.e. two possible questions.
	if mode == 0:
		base = -randi_range(2, 5)
		exp = randi_range(2, 3)
	elif mode == 1:
		base = randi_range(2, 9)
		exp = 2
	elif mode == 2:
		base = randi_range(2, 4)
		exp = randi_range(3, 4)
	var display := "%s%s" % [("%d" % base) if base >= 0 else "(%d)" % base, SUPER[exp]]
	return {
		"prompt": "%s = ?" % display,
		"answer": int(pow(float(base), float(exp))),
		"topic": "exp",
		"rule": RULES["exp"],
		"hint": HINTS["exp"],
	}


# --- Station 2: Order of operations (PEMDAS) --------------------------------
static func _pemdas(i: int) -> Dictionary:
	var tpl := i % 6
	match tpl:
		0:
			var a := randi_range(2, 9); var b := randi_range(2, 9); var c := randi_range(2, 9)
			return {
				"prompt": "%d + %d × %d" % [a, b, c],
				"answer": a + b * c, "topic": "pemdas", "rule": RULES["pemdas"], "hint": HINTS["pemdas"],
			}
		1:
			var a := randi_range(2, 9); var b := randi_range(2, 9); var c := randi_range(2, 9)
			return {
				"prompt": "%d × %d − %d" % [a, b, c],
				"answer": a * b - c, "topic": "pemdas", "rule": RULES["pemdas"], "hint": HINTS["pemdas"],
			}
		2:
			var a := randi_range(2, 9); var b := randi_range(2, 9); var c := randi_range(2, 9)
			return {
				"prompt": "(%d + %d) × %d" % [a, b, c],
				"answer": (a + b) * c, "topic": "pemdas", "rule": RULES["pemdas"], "hint": HINTS["pemdas"],
			}
		3:
			var q := randi_range(2, 6); var c := randi_range(2, 9)
			var b := q * c
			var a := randi_range(2, 9)
			return {
				"prompt": "%d − %d ÷ %d" % [a, b, c],
				"answer": a - b / c, "topic": "pemdas", "rule": RULES["pemdas"], "hint": HINTS["pemdas"],
			}
		4:
			var b := randi_range(2, 5); var e := randi_range(2, 3); var a := randi_range(2, 9)
			return {
				"prompt": "%d + %d%s" % [a, b, SUPER[e]],
				"answer": a + int(pow(float(b), float(e))), "topic": "pemdas", "rule": RULES["pemdas"], "hint": HINTS["pemdas"],
			}
		_:
			# Separate base, squared only: the old (a+b) x a^e reached 10206.
			var a := randi_range(2, 6); var b := randi_range(2, 6); var c := randi_range(2, 4)
			return {
				"prompt": "(%d + %d) × %d%s" % [a, b, c, SUPER[2]],
				"answer": (a + b) * c * c, "topic": "pemdas", "rule": RULES["pemdas"], "hint": HINTS["pemdas"],
			}
class_name BaybayinKeypad
extends GridContainer

## The 20 Baybayin keys and backspace, three rows of seven (DESIGN.md 4.1).
## Typing a mark after a consonant combines with it on screen by itself: the
## font shapes ᜊ + ᜒ into ᜊᜒ. A mark with nothing to sit on is refused.
##
## `labels`: the Latin syllable under each glyph -- Practice only. In a match
## the glyphs stand alone.

signal changed(text: String)

const KEY := Vector2(44, 52)
const GLYPH_SIZE := 22
const MAX_LEN := 24

var text := ""
var labels := true


func _ready() -> void:
	columns = 7
	add_theme_constant_override("h_separation", 4)
	add_theme_constant_override("v_separation", 4)
	for k: Array in Baybayin.KEYS:
		add_child(_key(k[0], k[1]))


func _key(glyph: String, latin: String) -> Button:
	var back := glyph == Baybayin.BACKSPACE
	var b := Ui.button("", KEY.x, KEY.y, Ui.SMALL_RED if back else Ui.KEY)
	b.name = "Key_" + (latin if latin != "" else "back")
	b.tooltip_text = latin
	Ui.quiet(b)
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A mark is shown on a dotted circle, the way type specimens show them.
	var face := ("◌" + glyph) if Baybayin.MARKS.has(glyph) else glyph
	var g := Art.label(face, GLYPH_SIZE, Pal.CREAM if back else Pal.INK, HORIZONTAL_ALIGNMENT_CENTER)
	g.add_theme_font_override("font", Art.baybayin())
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(g)
	if labels and latin != "":
		var l := Art.label(latin, Art.MIN_FONT, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(l)
	b.add_child(col)
	b.pressed.connect(func() -> void: press(glyph))
	return b


## One place every key goes through, so the text can never hold a mark with
## nothing under it.
func press(glyph: String) -> void:
	if glyph == Baybayin.BACKSPACE:
		text = text.substr(0, maxi(text.length() - 1, 0))
	elif text.length() < MAX_LEN and Baybayin.can_add(text, glyph):
		text += glyph
	else:
		return
	changed.emit(text)


func clear() -> void:
	text = ""
	changed.emit(text)

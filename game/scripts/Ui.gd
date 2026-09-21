class_name Ui
extends RefCounted

## Small helpers to compose the HUD and menu screens from the pack's UI assets.

enum { BLUE, RED, SMALL, SMALL_RED }

## Per kind: base texture, pressed texture, font size.
const KINDS := [
	["res://assets/ui/BigBlueButton_Regular.png", "res://assets/ui/BigBlueButton_Pressed.png", 17],
	["res://assets/ui/BigRedButton_Regular.png", "res://assets/ui/BigRedButton_Pressed.png", 17],
	["res://assets/ui/SmallBlueSquareButton_Regular.png", "res://assets/ui/SmallBlueSquareButton_Pressed.png", 14],
	["res://assets/ui/SmallRedSquareButton_Regular.png", "res://assets/ui/SmallRedSquareButton_Pressed.png", 14],
]
const PAPER := "res://assets/ui/RegularPaper.png"


static func button(text: String, w: float, h: float, kind := BLUE) -> Button:
	var normal: String = KINDS[kind][0]
	var down: String = KINDS[kind][1]
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, h)
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_stylebox_override("normal", Art.panel(normal, Vector2(8, 1), 0.22))
	b.add_theme_stylebox_override("pressed", Art.panel(down, Vector2(8, 1), 0.22))
	b.add_theme_stylebox_override("hover", Art.panel(normal, Vector2(8, 1), 0.22))
	var ring := StyleBoxFlat.new()
	ring.bg_color = Color(0, 0, 0, 0)
	ring.border_color = Color("ffe9a8")
	ring.set_border_width_all(2)
	b.add_theme_stylebox_override("focus", ring)
	# Without this the engine's flat grey box shows through for Hint-after-use
	# and the stubbed Rescue button.
	var off := Art.panel(normal, Vector2(8, 1), 0.22)
	off.modulate_color = Color(0.62, 0.62, 0.66, 0.85)
	b.add_theme_stylebox_override("disabled", off)
	b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.45))
	b.add_theme_color_override("font_color", Color(1, 1, 1, 0.96))
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
	b.add_theme_font_size_override("font_size", maxi(int(KINDS[kind][2]), Art.MIN_FONT))
	return b


## Text field styled for the parchment panels; the engine default grey box
## read as an OS form dropped onto the artwork.
static func line_edit(placeholder: String, w: float, h := 30.0, size := 15) -> LineEdit:
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.custom_minimum_size = Vector2(w, h)
	le.add_theme_font_size_override("font_size", maxi(size, Art.MIN_FONT))
	le.add_theme_color_override("font_color", Color("2a201a"))
	le.add_theme_color_override("font_placeholder_color", Color(0.35, 0.28, 0.22, 0.6))
	le.add_theme_color_override("caret_color", Color("3a2c22"))
	var box := StyleBoxFlat.new()
	box.bg_color = Color("f7ecd2")
	box.set_corner_radius_all(3)
	box.set_border_width_all(2)
	box.border_color = Color("8a6a3a")
	box.content_margin_left = 8.0
	box.content_margin_right = 8.0
	le.add_theme_stylebox_override("normal", box)
	var focused := box.duplicate()
	focused.border_color = Color("e09a1f")
	le.add_theme_stylebox_override("focus", focused)
	return le


## A paper panel with a title bar; returns a PanelContainer sized to `s`.
static func panel(s: Vector2, title := "", title_col: Color = Color("3a2c22")) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.custom_minimum_size = s
	pc.add_theme_stylebox_override("panel", Art.panel(PAPER, Vector2(8, 4), 0.3))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_child(box)
	if title != "":
		var head := Art.label(title, 18, title_col, HORIZONTAL_ALIGNMENT_CENTER)
		box.add_child(head)
		var rule := HSeparator.new()
		rule.modulate = Color(0.6, 0.5, 0.4, 0.6)
		box.add_child(rule)
	return pc

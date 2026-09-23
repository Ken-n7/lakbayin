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

## How a button's nine-patch is sliced -- the same three numbers at all four
## states, so a button never changes shape when it is pressed or disabled.
const BTN_SLICE := Vector2(8, 1)
const BTN_K := 0.22


static func button(text: String, w: float, h: float, kind := BLUE) -> Button:
	var normal: String = KINDS[kind][0]
	var down: String = KINDS[kind][1]
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, h)
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_stylebox_override("normal", Art.panel(normal, BTN_SLICE, BTN_K))
	b.add_theme_stylebox_override("pressed", Art.panel(down, BTN_SLICE, BTN_K))
	b.add_theme_stylebox_override("hover", Art.panel(normal, BTN_SLICE, BTN_K))
	var ring := StyleBoxFlat.new()
	ring.bg_color = Color.TRANSPARENT
	ring.border_color = Pal.CREAM
	ring.set_border_width_all(2)
	b.add_theme_stylebox_override("focus", ring)
	# Without this the engine's flat grey box shows through for Hint-after-use
	# and the stubbed Rescue button.
	var off := Art.panel(normal, BTN_SLICE, BTN_K)
	off.modulate_color = Color(0.62, 0.62, 0.66, 0.85)
	b.add_theme_stylebox_override("disabled", off)
	b.add_theme_color_override("font_disabled_color", Pal.WHITE_FAINT)
	b.add_theme_color_override("font_color", Pal.WHITE_STRONG)
	b.add_theme_color_override("font_hover_color", Pal.WHITE)
	b.add_theme_color_override("font_pressed_color", Pal.WHITE)
	b.add_theme_font_size_override("font_size", maxi(int(KINDS[kind][2]), Art.MIN_FONT))
	return b


## Text field styled for the parchment panels; the engine default grey box
## read as an OS form dropped onto the artwork.
static func line_edit(placeholder: String, w: float, h := 30.0, size := 15) -> LineEdit:
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.custom_minimum_size = Vector2(w, h)
	le.add_theme_font_size_override("font_size", maxi(size, Art.MIN_FONT))
	le.add_theme_color_override("font_color", Pal.INK)
	le.add_theme_color_override("font_placeholder_color", Color(0.35, 0.28, 0.22, 0.6))
	le.add_theme_color_override("caret_color", Pal.TITLE)
	var box := StyleBoxFlat.new()
	box.bg_color = Pal.PAPER
	box.set_corner_radius_all(3)
	box.set_border_width_all(2)
	box.border_color = Pal.WOOD
	box.content_margin_left = 8.0
	box.content_margin_right = 8.0
	le.add_theme_stylebox_override("normal", box)
	var focused := box.duplicate()
	focused.border_color = Pal.AMBER
	le.add_theme_stylebox_override("focus", focused)
	return le


## A labelled text field on its own row. The three auth forms are the same
## shape six times over; only the caption and the secrecy change.
static func field(parent: Node, caption: String, placeholder: String,
		secret := false, w := 300.0) -> LineEdit:
	parent.add_child(Art.label(caption, Pal.LABEL, Pal.INK_MUTED))
	var le := line_edit(placeholder, w)
	le.secret = secret
	parent.add_child(le)
	return le


## A paper panel with a title bar; returns a PanelContainer sized to `s`.
static func panel(s: Vector2, title := "", title_col: Color = Pal.TITLE) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.custom_minimum_size = s
	pc.add_theme_stylebox_override("panel", Art.panel(PAPER, Vector2(8, 4), 0.3))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_child(box)
	if title != "":
		var head := Art.label(title, Pal.H2, title_col, HORIZONTAL_ALIGNMENT_CENTER)
		box.add_child(head)
		var rule := HSeparator.new()
		rule.modulate = Color(0.6, 0.5, 0.4, 0.6)
		box.add_child(rule)
	return pc


## A parchment panel centred in the canvas, mounted on `parent`, with its
## content box handed straight back.
##
## This is what every full-screen panel wanted. They each built the panel, then
## worked out the centring offset by hand (and one of the five was 4px out),
## then reached `panel.get_child(0) as VBoxContainer` -- an undocumented
## structural contract that seven call sites depended on.
static func screen_panel(parent: Node, s: Vector2, title := "",
		title_col: Color = Pal.TITLE) -> VBoxContainer:
	var pc := panel(s, title, title_col)
	pc.position = ((Pal.CANVAS - s) * 0.5).floor()
	parent.add_child(pc)
	return pc.get_child(0) as VBoxContainer


## The scrim that darkens whatever is behind a screen.
static func dim(parent: Node) -> ColorRect:
	var d := ColorRect.new()
	d.color = Pal.DIM
	d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	parent.add_child(d)
	return d


## A vertical scroll region `h` tall. Horizontal scrolling is always off: the
## panels are fixed width, so a horizontal bar only ever appeared by accident.
static func scroll(parent: Node, h: float) -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.custom_minimum_size = Vector2(0, h)
	sc.add_theme_constant_override("scrollbar_margin", 0)
	parent.add_child(sc)
	return sc


## One control, centred on its own row. What every "Back" button wanted.
static func centre_row(parent: Node, c: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(c)
	parent.add_child(row)
	return row


## mm:ss. The clock reads the same on the map header and on every question.
static func mmss(sec: int) -> String:
	return "%02d:%02d" % [sec / 60, sec % 60]

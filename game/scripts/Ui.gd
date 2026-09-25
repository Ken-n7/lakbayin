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

## One button height, everywhere. Not a preference: the nine-patch these
## buttons are cut from has a ~31px minimum, so every screen that asked for
## 22, 24, 26 or 28 got 31 and only the *spacing* around them differed. The
## admin screens looked unstyled next to Home for exactly that reason.
const H := 32
## The three widths worth having: a column entry, an inline action, a chip.
const W_WIDE := 186
const W_MED := 120
const W_TINY := 70

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


## A button that drops a list, wearing the same skin as the rest. The one
## place the game needs it is Rescue, which the mockups draw as "Rescue ▾".
static func menu_button(text: String, w: float, h: float, kind := BLUE) -> MenuButton:
	var m := MenuButton.new()
	m.text = text
	m.custom_minimum_size = Vector2(w, h)
	m.clip_text = true
	var normal: String = KINDS[kind][0]
	var down: String = KINDS[kind][1]
	for state in ["normal", "hover", "focus"]:
		m.add_theme_stylebox_override(state, Art.panel(normal, BTN_SLICE, BTN_K))
	m.add_theme_stylebox_override("pressed", Art.panel(down, BTN_SLICE, BTN_K))
	var off := Art.panel(normal, BTN_SLICE, BTN_K)
	off.modulate_color = Color(0.62, 0.62, 0.66, 0.85)
	m.add_theme_stylebox_override("disabled", off)
	m.add_theme_color_override("font_color", Pal.WHITE_STRONG)
	m.add_theme_color_override("font_disabled_color", Pal.WHITE_FAINT)
	m.add_theme_font_size_override("font_size", maxi(int(KINDS[kind][2]), Art.MIN_FONT))
	return m


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


## The same parchment field, as a dropdown. `OptionButton` and `TextEdit` come
## with the engine's grey, which on these panels reads as an OS form dropped
## onto the artwork -- the exact complaint `line_edit()` was written to fix.
static func option(w: float, h := 30.0) -> OptionButton:
	var o := OptionButton.new()
	o.custom_minimum_size = Vector2(w, h)
	o.clip_text = true
	o.add_theme_font_size_override("font_size", Art.MIN_FONT)
	o.add_theme_color_override("font_color", Pal.INK)
	o.add_theme_color_override("font_hover_color", Pal.TITLE)
	o.add_theme_color_override("font_focus_color", Pal.INK)
	for state in ["normal", "hover", "pressed", "focus"]:
		o.add_theme_stylebox_override(state, _paper_box(state == "focus"))
	var pop := o.get_popup()
	pop.add_theme_stylebox_override("panel", _paper_box(false))
	pop.add_theme_color_override("font_color", Pal.INK)
	pop.add_theme_color_override("font_hover_color", Pal.TITLE)
	pop.add_theme_font_size_override("font_size", Art.MIN_FONT)
	return o


static func text_area(w: float, h: float) -> TextEdit:
	var t := TextEdit.new()
	t.custom_minimum_size = Vector2(w, h)
	t.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	t.add_theme_font_size_override("font_size", Art.MIN_FONT)
	t.add_theme_color_override("font_color", Pal.INK)
	t.add_theme_color_override("caret_color", Pal.TITLE)
	t.add_theme_stylebox_override("normal", _paper_box(false))
	t.add_theme_stylebox_override("focus", _paper_box(true))
	return t


## The field face both of those wear, and the one `line_edit()` already used.
static func _paper_box(focused: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Pal.PAPER
	box.set_corner_radius_all(3)
	box.set_border_width_all(2)
	box.border_color = Pal.AMBER if focused else Pal.WOOD
	box.content_margin_left = 8.0
	box.content_margin_right = 8.0
	box.content_margin_top = 3.0
	box.content_margin_bottom = 3.0
	return box


## A tab that is text, not a button: underlined when it is the one you are on.
## Buttons here cost a whole row of panel for something that only has to say
## which of two places you are looking at.
static func tab_text(text: String, active: bool) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	var b := Button.new()
	b.text = text
	b.flat = true
	b.add_theme_font_size_override("font_size", Pal.LABEL)
	b.add_theme_color_override("font_color", Pal.TITLE if active else Pal.INK_MUTED)
	b.add_theme_color_override("font_hover_color", Pal.TITLE)
	b.add_theme_color_override("font_pressed_color", Pal.TITLE)
	col.add_child(b)
	var rule := ColorRect.new()
	rule.color = Pal.TITLE if active else Color.TRANSPARENT
	rule.custom_minimum_size = Vector2(0, 2)
	col.add_child(rule)
	return col


## The button inside a `tab_text`, for connecting `pressed`.
static func tab_button(t: VBoxContainer) -> Button:
	return t.get_child(0) as Button


## A glyph with no box around it: the back arrow, a card's close ×. Anything
## where a nine-patch would be louder than the thing it frames.
static func glyph(text: String, size := 20, color: Color = Pal.TITLE) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", size)
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(state, color)
	return b


## A field a soft keyboard opens as a numpad. Typing a duration on a full
## QWERTY is the same mistake the quiz screen already fixed.
static func number_field(w: float, h := 26.0, size := 15) -> LineEdit:
	var le := line_edit("", w, h, size)
	le.alignment = HORIZONTAL_ALIGNMENT_CENTER
	le.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	le.max_length = 2
	return le


## A paper panel with a title bar; returns a PanelContainer sized to `s`.
static func panel(s: Vector2, title := "", title_col: Color = Pal.TITLE) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.custom_minimum_size = s
	pc.add_theme_stylebox_override("panel", Art.panel(PAPER, Vector2(8, 4), 0.3))
	var box := VBoxContainer.new()
	# 4, not 8. Four pixels a row is nothing to look at and 32px across an
	# eight-row form, which is the difference between a Back button on the
	# canvas and one below it. Button heights are not the lever they look
	# like: Ui.button's nine-patch has a ~31px floor, so asking for 24 gets
	# 31 and the gaps are the only give in a full form.
	box.add_theme_constant_override("separation", 4)
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
	# Centred by a container, not by arithmetic. The old line positioned the
	# panel from its *declared* size while the box grew to fit its contents, so
	# every screen whose content ran past that guess hung off the bottom of the
	# canvas -- by 47px on the login form, and a button nobody could tap.
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(centre)
	centre.add_child(pc)
	return pc.get_child(0) as VBoxContainer


## The sign-in family's layout: the game's name on the left, standing on the
## moving scene, and the form on a parchment panel to its right. A landscape
## phone has width to spare and no height -- one tall centred form ran into
## the soft keyboard; two columns keep every form short. Returns the form's
## content box.
static func auth_layout(parent: Node, title: String, form_w := 330.0) -> VBoxContainer:
	var split := HBoxContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	split.offset_left = 20.0
	split.offset_right = -20.0
	split.add_theme_constant_override("separation", 16)
	split.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(split)

	var brand := VBoxContainer.new()
	brand.alignment = BoxContainer.ALIGNMENT_CENTER
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brand.add_theme_constant_override("separation", 4)
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 34, not the splash's 44: beside a 330px form on a 640 canvas the column
	# is ~250 wide, and the full-size name ran past it.
	var logo := Art.label("NumXventure", 34, Pal.PARCHMENT, HORIZONTAL_ALIGNMENT_CENTER)
	Art.shadow(logo, Color(0, 0, 0, 0.6), 3, 0)
	brand.add_child(logo)
	var tag := Art.label("Explore.  Solve.  Conquer.", Pal.H2, Pal.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	Art.shadow(tag)
	brand.add_child(tag)
	split.add_child(brand)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pc := panel(Vector2(form_w, 0), title)
	centre.add_child(pc)
	split.add_child(centre)
	var box := pc.get_child(0) as VBoxContainer
	box.add_theme_constant_override("separation", 5)
	return box


## A password field with its Show toggle beside it, where the eye is -- not a
## separate button floating under the form.
static func password_field(parent: Node, caption: String, placeholder: String,
		w := 300.0) -> LineEdit:
	parent.add_child(Art.label(caption, Pal.LABEL, Pal.INK_MUTED))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var le := line_edit(placeholder, w - 70.0)
	le.secret = true
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(le)
	var show := button("Show", 64, H, SMALL)
	show.toggle_mode = true
	show.focus_mode = Control.FOCUS_NONE
	show.toggled.connect(func(on: bool) -> void:
		le.secret = not on
		show.text = "Hide" if on else "Show")
	row.add_child(show)
	parent.add_child(row)
	return le


## A quiet text action -- "Forgot password?" -- for the paths that should not
## compete with the one primary button on a form.
static func link(text: String, color: Color = Pal.INFO_DEEP) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 28)          # still a thumb's worth to hit
	b.add_theme_font_size_override("font_size", Pal.SMALL)
	for c in ["font_color", "font_focus_color", "font_pressed_color"]:
		b.add_theme_color_override(c, color)
	b.add_theme_color_override("font_hover_color", Pal.TITLE)
	return b


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
	# `h` is a cap, not a suggestion. With SIZE_EXPAND_FILL the box grew to its
	# contents inside a panel that has no height of its own, so a scroll region
	# scrolled nothing and pushed everything below it off the canvas instead.
	sc.size_flags_vertical = Control.SIZE_FILL
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

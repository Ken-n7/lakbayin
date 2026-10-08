class_name DevUi
extends RefCounted

## Plain widgets for the developer tools. No pack art, no nine-patches, no
## tweens -- a flat box and white text on grey.
##
## Deliberately not `Ui`: that styles the game, and a cheat panel dressed as
## parchment reads as part of it. These want to be obviously not the game, and
## to stay readable whatever is behind them.

const BG := Color(0.08, 0.08, 0.10, 1.0)   # solid: the screen behind showed through
const FACE := Color(0.20, 0.21, 0.25)
const FACE_DOWN := Color(0.33, 0.35, 0.40)
const EDGE := Color(0.55, 0.57, 0.62)
const FONT := 12
const FACE_ON := Color(0.24, 0.42, 0.36)
const ON := " · on"
## Every dev control that takes touches joins this (DevUi.owns).
const GROUP := "dev_ui"


static func box(width: float) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(width, 0.0)
	var style := StyleBoxFlat.new()
	style.bg_color = BG
	style.border_color = EDGE
	style.set_border_width_all(1)
	style.set_content_margin_all(4)
	pc.add_theme_stylebox_override("panel", style)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	pc.add_child(col)
	return pc


## The column inside a box, which is where the buttons go.
static func column(b: PanelContainer) -> VBoxContainer:
	return b.get_child(0) as VBoxContainer


static func button(text: String, h := 19.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0.0, h)
	b.clip_text = true
	b.add_theme_font_size_override("font_size", FONT)
	for state in ["normal", "hover", "focus"]:
		b.add_theme_stylebox_override(state, _face(FACE))
	b.add_theme_stylebox_override("pressed", _face(FACE_DOWN))
	for state2 in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(state2, Color.WHITE)
	return b


static func _face(c: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_content_margin_all(3)
	s.content_margin_left = 6.0
	return s

## A small heading over a group of buttons.
static func heading(text: String) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", 9)
	l.add_theme_color_override("font_color", EDGE)
	return l


## A line of explanation or readout, wrapping in its column.
static func note(text: String, size := 10) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	return l


## A switch's state, on its own label: " · on" while on, and a lighter face.
static func mark(b: Button, on: bool) -> void:
	b.text = b.text.trim_suffix(ON) + (ON if on else "")
	for state in ["normal", "hover", "focus"]:
		b.add_theme_stylebox_override(state, _face(FACE_ON if on else FACE))


## Whether a point (viewport px) is on dev UI -- for the map's joystick and
## board, which would otherwise take the touch first (AdventureHud).
static func owns(tree: SceneTree, at: Vector2) -> bool:
	for n in tree.get_nodes_in_group(GROUP):
		var c := n as Control
		if c != null and c.is_visible_in_tree() and c.mouse_filter == Control.MOUSE_FILTER_STOP \
				and c.get_global_rect().has_point(at):
			return true
	return false

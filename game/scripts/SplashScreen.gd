extends Control

## Loading / splash screen — the client asked for one explicitly. Holds the
## title for HOLD seconds while the first screen's textures warm up, then routes
## on. Tap or press anything to cut it short.

const HOLD := 1.8
const BAR_W := 260.0
const BAR_H := 10.0

var main: Control

var _bar: ColorRect
var _done := false


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var back := ColorRect.new()
	back.color = Pal.BG
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(back)

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 10)
	add_child(col)

	var logo := Art.label("NumXventure", Pal.LOGO, Pal.PARCHMENT, HORIZONTAL_ALIGNMENT_CENTER)
	Art.shadow(logo, Color(0, 0, 0, 0.6), 3, 0)
	col.add_child(logo)
	col.add_child(Art.label("Explore.  Solve.  Conquer.", Pal.H2, Pal.GOLD,
			HORIZONTAL_ALIGNMENT_CENTER))

	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 18)
	col.add_child(pad)

	var track := ColorRect.new()
	track.color = Color(1, 1, 1, 0.14)
	track.custom_minimum_size = Vector2(BAR_W, BAR_H)
	track.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(track)

	_bar = ColorRect.new()
	_bar.color = Pal.GOLD
	_bar.size = Vector2(0, BAR_H)
	track.add_child(_bar)

	col.add_child(Art.label("Loading...", Pal.BODY, Color(1, 1, 1, 0.7),
			HORIZONTAL_ALIGNMENT_CENTER))

	var tw := create_tween()
	tw.tween_property(_bar, "size:x", BAR_W, HOLD)
	tw.tween_callback(skip)


func _gui_input(event: InputEvent) -> void:
	if event.is_pressed():
		skip()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_pressed():
		skip()


## Idempotent: the tween's callback and an impatient tap both land here.
func skip() -> void:
	if _done:
		return
	_done = true
	main.open("title")


func go_back() -> void:
	get_tree().quit()

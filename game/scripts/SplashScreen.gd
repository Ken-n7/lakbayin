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

	# Main's moving scene is the splash's background (Backdrop.gd) -- the
	# first thing a student sees is the world they are about to play in.

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 10)
	add_child(col)

	var logo := Art.label("NumXventure", Pal.LOGO, Pal.PARCHMENT, HORIZONTAL_ALIGNMENT_CENTER)
	Art.shadow(logo, Color(0, 0, 0, 0.6), 3, 0)
	col.add_child(logo)
	var tag := Art.label("Explore.  Solve.  Conquer.", Pal.H2, Pal.GOLD,
			HORIZONTAL_ALIGNMENT_CENTER)
	Art.shadow(tag)      # over a moving scene now, not a flat colour
	col.add_child(tag)

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

	var loading := Art.label("Loading...", Pal.BODY, Color(1, 1, 1, 0.8),
			HORIZONTAL_ALIGNMENT_CENTER)
	Art.shadow(loading)
	col.add_child(loading)

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
	# Sign in first -- unless there is no backend to sign in to, which is how
	# the headless suites and an offline dev run still reach the game.
	if not Net.configured():
		main.open("home")
		return
	# An app stays signed in. Trade the stored refresh token for a new access
	# token before deciding, so a returning student never sees the form.
	# Not for a tool run: the live checks leave a throwaway account's login in
	# the tools' own file, and a screenshot tool should not open signed in as it.
	if not Net.signed_in() and Game.profile_suffix() != "-tools":
		await Net.restore_session()
	if not Net.signed_in():
		main.open("login")
	else:
		main.open("admin" if Net.role == "admin" else "home")


func go_back() -> void:
	get_tree().quit()

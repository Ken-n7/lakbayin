extends Control

## Loading / splash screen — the client asked for one explicitly. Holds the
## title for HOLD seconds while the first screen's textures warm up, then routes
## on. Tap or press anything to cut it short.

const HOLD := 1.8
const BAR_W := 260.0
const BAR_H := 10.0

var main: Control

## No connection at launch: try the saved login again this often, up to the
## last, for as long as it takes -- the login is still good.
const RETRY_S := [2.0, 4.0, 8.0, 15.0]

var _bar: ColorRect
var _done := false
var _status: Label
var _other: Button


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Main's moving scene is the splash's background (Backdrop.gd) -- the
	# first thing a student sees is the world they are about to play in.

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 10)
	add_child(col)

	var logo := Art.title(Art.label("NumXventure", Pal.LOGO, Pal.PARCHMENT, HORIZONTAL_ALIGNMENT_CENTER))
	Art.shadow(logo, Color(0, 0, 0, 0.6), 3, 0)
	col.add_child(logo)
	var tag := Art.title(Art.label("Explore.  Solve.  Conquer.", Pal.H2, Pal.GOLD,
			HORIZONTAL_ALIGNMENT_CENTER))
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

	_status = Art.label("Loading...", Pal.BODY, Color(1, 1, 1, 0.8),
			HORIZONTAL_ALIGNMENT_CENTER)
	Art.shadow(_status)
	col.add_child(_status)
	# Only while waiting on the line: a way out to the Sign In form.
	_other = Ui.button("Use another account", 190, Ui.H, Ui.SMALL)
	_other.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_other.visible = false
	_other.pressed.connect(func() -> void: main.open("login"))
	col.add_child(_other)

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
	# No line is not "signed out": wait here and try again, rather than show a
	# signed-in student the Sign In form (where signing in would fail too).
	if (not Net.signed_in() or Net.role == "") and Game.profile_suffix() != "-tools":
		var tries := 0
		var err: String = await Net.restore_session()
		while err == Net.NO_CONNECTION:
			if not is_inside_tree():
				return                  # "Use another account" took them on
			var wait: float = RETRY_S[mini(tries, RETRY_S.size() - 1)]
			tries += 1
			_status.text = "No connection — trying again..."
			_other.visible = true
			await get_tree().create_timer(wait).timeout
			if not is_inside_tree():
				return
			err = await Net.restore_session()
	if not is_inside_tree():
		return
	if not Net.signed_in() or Net.role == "":
		main.open("login")
	else:
		main.open("admin" if Net.role == "admin" else "home")


func go_back() -> void:
	get_tree().quit()

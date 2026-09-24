extends Control

## Email + password, against `Net`. The first screen after the splash whenever
## there is no live session.
##
## Every form on this screen and its two siblings follows the same rule: the
## submit button disables for the duration of the request, because a second tap
## on a slow classroom connection is otherwise a second signup.

const PANEL := Vector2(360, 260)

var main: Control

var _email: LineEdit
var _pass: LineEdit
var _msg: Label
var _go: Button


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := Ui.screen_panel(self, PANEL, "NumXventure")
	box.add_child(Art.label("Sign in to begin", Pal.SMALL, Pal.INK_MUTED,
			HORIZONTAL_ALIGNMENT_CENTER))

	_email = Ui.field(box, "Email or Username", "you@example.com  or  yourname")
	_email.keep_editing_on_text_submit = true
	_pass = Ui.field(box, "Password", "at least 8 characters", true)

	var show := Ui.button("Show", Ui.W_TINY, Ui.H, Ui.SMALL)
	show.toggle_mode = true
	show.toggled.connect(func(on: bool) -> void: _pass.secret = not on)
	Ui.centre_row(box, show)

	_msg = Art.label("", Pal.SMALL, Pal.WRONG, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_msg)

	_go = Ui.button("Sign In", 300, Ui.H, Ui.RED)
	Ui.centre_row(box, _go)
	_go.pressed.connect(_submit)
	# Enter on the email moves along; enter on the password signs in. The
	# on-screen Sign In button sits under the soft keyboard, so the keyboard's
	# own key has to do the job.
	_email.text_submitted.connect(func(_t: String) -> void: _pass.grab_focus())
	_pass.text_submitted.connect(func(_t: String) -> void: _submit())

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	var reg := Ui.button("Create Account", 146, Ui.H, Ui.SMALL)
	var forgot := Ui.button("Forgot Password", 146, Ui.H, Ui.SMALL_RED)
	reg.pressed.connect(func() -> void: main.open("register"))
	forgot.pressed.connect(func() -> void: main.open("reset", {"email": _email.text}))
	row.add_child(reg)
	row.add_child(forgot)
	box.add_child(row)

	# Deliberately no grab_focus(): on a phone that opens the soft keyboard
	# immediately, over the form the student has not read yet.


func _submit() -> void:
	if _email.text.strip_edges().is_empty() or _pass.text.is_empty():
		_say("Enter your email or username, and your password.")
		return
	_busy(true)
	var err: String = await Net.sign_in(_email.text, _pass.text)
	_busy(false)
	if err != "":
		# GoTrue says "Invalid login credentials" for a wrong password and an
		# unknown address alike, which is the behaviour we want -- pass it on.
		_say(err)
		return
	main.open("admin" if Net.role == "admin" else "home")


func _busy(on: bool) -> void:
	_go.disabled = on
	_go.text = "Signing in..." if on else "Sign In"


func _say(text: String) -> void:
	_msg.text = text


## Back on the first screen is the way out of the app.
func go_back() -> void:
	get_tree().quit()

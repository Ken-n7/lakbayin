extends Control

## Email + password, against `Net`. The first screen after the splash whenever
## there is no live session.
##
## Every form on this screen and its two siblings follows the same rule: the
## submit button disables for the duration of the request, because a second tap
## on a slow classroom connection is otherwise a second signup.

var main: Control

var _email: LineEdit
var _pass: LineEdit
var _msg: Label
var _go: Button


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# No backdrop of its own: Main's moving scene shows through (Backdrop.gd).
	# The game's name stands on the scene; the form sits beside it.
	var box := Ui.auth_layout(self, "Sign In")

	_email = Ui.field(box, "Email or Username", "you@example.com  or  yourname")
	_email.keep_editing_on_text_submit = true
	_pass = Ui.password_field(box, "Password", "at least 8 characters")

	# Recovery is a quiet link under the field it is about, not a red button
	# competing with Sign In.
	var forgot := Ui.link("Forgot Password?")
	forgot.pressed.connect(func() -> void: main.open("reset", {"email": _email.text}))
	var forgot_row := HBoxContainer.new()
	forgot_row.alignment = BoxContainer.ALIGNMENT_END
	forgot_row.add_child(forgot)
	box.add_child(forgot_row)

	_msg = Art.label("", Pal.SMALL, Pal.WRONG, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(300, 0)
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
	row.add_child(Art.label("New here?", Pal.SMALL, Pal.INK_MUTED))
	var reg := Ui.button("Create Account", 150, Ui.H, Ui.SMALL)
	reg.pressed.connect(func() -> void: main.open("register"))
	row.add_child(reg)
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

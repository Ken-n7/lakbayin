extends Control

## Forgot Password, in two steps on one screen: ask for a code, then spend it.
##
## A code and not a link -- a recovery link needs a web page or an Android deep
## link to land on, and this app has neither. Its length is whatever the
## project's OTP setting says, so nothing here assumes one. See
## `supabase/README.md`.

const MIN_PASSWORD := 8

var main: Control

var _email: LineEdit
var _code: LineEdit
var _pass: LineEdit
var _msg: Label
var _send: Button
var _save: Button
var _steps: Label
var _step1: VBoxContainer
var _step2: VBoxContainer


func setup(data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# No backdrop of its own: Main's moving scene shows through (Backdrop.gd).
	var box := Ui.auth_layout(self, "Reset Password")
	# One step at a time: all four controls at once asked for a code before
	# the student had been told one was coming.
	_steps = Art.label("", Pal.LABEL, Pal.TITLE, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_steps)

	_step1 = VBoxContainer.new()
	_step1.add_theme_constant_override("separation", 5)
	box.add_child(_step1)
	_email = Ui.field(_step1, "Email", "you@example.com")
	_email.text = data.get("email", "")   # carried over from the login form
	_email.text_submitted.connect(func(_t: String) -> void: _request())
	_send = Ui.button("Email Me a Code", 300, Ui.H, Ui.RED)
	_send.pressed.connect(_request)
	Ui.centre_row(_step1, _send)
	var have := Ui.link("I already have a code")
	have.pressed.connect(func() -> void: _show_step(2))
	Ui.centre_row(_step1, have)

	_step2 = VBoxContainer.new()
	_step2.add_theme_constant_override("separation", 5)
	box.add_child(_step2)
	# No length claimed: Supabase's OTP length is a project setting (6-10), and
	# a real reset code arrived as 8 digits while this said "6 digits".
	_code = Ui.field(_step2, "Code from the email", "the code we sent you")
	_pass = Ui.password_field(_step2, "New password", "at least %d characters" % MIN_PASSWORD)
	_pass.text_submitted.connect(func(_t: String) -> void: _apply())
	_save = Ui.button("Set New Password", 300, Ui.H, Ui.RED)
	_save.pressed.connect(_apply)
	Ui.centre_row(_step2, _save)

	_msg = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(300, 0)
	box.add_child(_msg)

	var back := Ui.link("Back to Sign In")
	back.pressed.connect(go_back)
	Ui.centre_row(box, back)
	_show_step(1)


func _show_step(n: int) -> void:
	_step1.visible = n == 1
	_step2.visible = n == 2
	_steps.text = ("▶ 1  Email      2  New password" if n == 1
		else "✓ 1  Email      ▶ 2  New password")


func _request() -> void:
	if _email.text.strip_edges().is_empty():
		_say("Enter your email first.", Pal.WRONG)
		return
	_send.disabled = true
	var err: String = await Net.send_reset_code(_email.text)
	_send.disabled = false
	if err != "":
		_say(err, Pal.WRONG)
		return
	# Deliberately says the same thing whether or not the address is registered.
	_say("If that email has an account, a code is on its way.", Pal.INK_MUTED)
	_show_step(2)


func _apply() -> void:
	if _email.text.strip_edges().is_empty():
		_show_step(1)
		_say("Enter your email first.", Pal.WRONG)
		return
	if _code.text.strip_edges().is_empty():
		_say("Enter the code from the email.", Pal.WRONG)
		return
	if _pass.text.length() < MIN_PASSWORD:
		_say("Password must be at least %d characters." % MIN_PASSWORD, Pal.WRONG)
		return
	_save.disabled = true
	_save.text = "Saving..."
	var err: String = await Net.confirm_reset(_email.text, _code.text, _pass.text)
	_save.disabled = false
	_save.text = "Set New Password"
	if err != "":
		_say(err, Pal.WRONG)
		return
	# confirm_reset leaves a live session behind, so there is nothing to sign
	# back in to.
	main.open("admin" if Net.role == "admin" else "home")


func _say(text: String, col: Color) -> void:
	_msg.text = text
	_msg.add_theme_color_override("font_color", col)


func go_back() -> void:
	main.open("login")

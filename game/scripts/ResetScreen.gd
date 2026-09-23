extends Control

## Forgot Password, in two steps on one screen: ask for a code, then spend it.
##
## A code and not a link -- a recovery link needs a web page or an Android deep
## link to land on, and this app has neither. See `supabase/README.md`.

const PANEL := Vector2(380, 290)
const MIN_PASSWORD := 8

var main: Control

var _email: LineEdit
var _code: LineEdit
var _pass: LineEdit
var _msg: Label
var _send: Button
var _save: Button


func setup(data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := Ui.screen_panel(self, PANEL, "Forgot Password")
	_email = Ui.field(box, "Email", "you@example.com")
	_email.text = data.get("email", "")   # carried over from the login form

	_send = Ui.button("Email Me a Code", 300, 32, Ui.SMALL_RED)
	_send.pressed.connect(_request)
	Ui.centre_row(box, _send)

	_code = Ui.field(box, "Code from the email", "6 digits")
	_pass = Ui.field(box, "New password", "at least %d characters" % MIN_PASSWORD, true)

	_msg = Art.label("", Pal.SMALL, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(320, 0)
	box.add_child(_msg)

	_save = Ui.button("Set New Password", 300, 34)
	_save.pressed.connect(_apply)
	Ui.centre_row(box, _save)

	var back := Ui.button("Back to Sign In", 300, 28, Ui.SMALL)
	back.pressed.connect(go_back)
	Ui.centre_row(box, back)


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
	_code.grab_focus()


func _apply() -> void:
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

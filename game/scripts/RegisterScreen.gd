extends Control

## Email + Username + Password + Role, per SPECS §2. Anyone may register as an
## admin, no approval -- that is the client's stated rule, not an oversight.

const FORM_W := 290.0
## Username and Role share a row; Role gets the wider half, because
## "Player (student)" is longer than any username hint needs.
const USER_W := 118.0
const ROLE_W := 162.0
const MIN_PASSWORD := 8

var main: Control

var _email: LineEdit
var _user: LineEdit
var _pass: LineEdit
var _role: OptionButton
var _msg: Label
var _go: Button


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# No backdrop of its own: Main's moving scene shows through (Backdrop.gd).
	var box := Ui.auth_layout(self, "Create Account", 320)

	# Three rows, not five: Email, then Username beside Role, then Password.
	# Stacked, the form ran into a phone keyboard; two full columns ran off a
	# 640px screen beside the logo, and squeezed the password under its Show.
	_email = Ui.field(box, "Email", "you@example.com", false, FORM_W)
	var pair := HBoxContainer.new()
	pair.add_theme_constant_override("separation", 10)
	box.add_child(pair)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 2)
	pair.add_child(left)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 2)
	pair.add_child(right)
	_user = Ui.field(left, "Username", "3-20 letters", false, USER_W)
	right.add_child(Art.label("Role", Pal.LABEL, Pal.INK_MUTED))
	_role = Ui.option(ROLE_W, 30.0)
	# Who each role is, in the words of a classroom -- "Admin" alone does not
	# tell a student not to pick it.
	_role.add_item("Player (student)")
	_role.add_item("Admin (Quest Keeper)")
	right.add_child(_role)
	_pass = Ui.password_field(box, "Password", "at least %d characters" % MIN_PASSWORD, FORM_W)

	_msg = Art.label("", Pal.SMALL, Pal.WRONG, HORIZONTAL_ALIGNMENT_CENTER)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(FORM_W, 0)
	box.add_child(_msg)

	# Enter walks the form and the last field registers -- the button is under
	# the soft keyboard on a phone.
	_email.text_submitted.connect(func(_t: String) -> void: _user.grab_focus())
	_user.text_submitted.connect(func(_t: String) -> void: _pass.grab_focus())
	_pass.text_submitted.connect(func(_t: String) -> void: _submit())

	_go = Ui.button("Register", FORM_W, Ui.H, Ui.RED)
	Ui.centre_row(box, _go)
	_go.pressed.connect(_submit)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	row.add_child(Art.label("Already have an account?", Pal.SMALL, Pal.INK_MUTED))
	var back := Ui.link("Sign In")
	back.pressed.connect(go_back)
	row.add_child(back)
	box.add_child(row)
	# Deliberately no grab_focus(): on a phone that opens the soft keyboard
	# immediately, over the form the student has not read yet.


## Checked here as well as in Postgres: a round trip to say "too short" is a
## round trip the classroom's connection does not need to make.
func _submit() -> void:
	var user := _user.text.strip_edges()
	if _email.text.strip_edges().is_empty():
		_err("Enter your email.")
		return
	if not RegEx.create_from_string("^[A-Za-z0-9_-]{3,20}$").search(user):
		_err("Username: 3-20 letters, digits, _ or - only.")
		return
	if _pass.text.length() < MIN_PASSWORD:
		_err("Password must be at least %d characters." % MIN_PASSWORD)
		return

	_go.disabled = true
	_go.text = "Registering..."
	var role := "admin" if _role.selected == 1 else "player"
	var err: String = await Net.sign_up(_email.text, user, _pass.text, role)
	_go.disabled = false
	_go.text = "Register"
	if err != "":
		_err(err)
		return
	# Registered and signed in: straight to the character pick, per §2.
	# An admin never plays, so there is no character to pick.
	Sfx.play("success")
	main.open("admin" if Net.role == "admin" else "hero")


## A form problem, said and sounded.
func _err(text: String) -> void:
	_msg.text = text
	Sfx.play("error")


func go_back() -> void:
	main.open("login")

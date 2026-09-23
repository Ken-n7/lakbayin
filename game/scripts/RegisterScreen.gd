extends Control

## Email + Username + Password + Role, per SPECS §2. Anyone may register as an
## admin, no approval -- that is the client's stated rule, not an oversight.

const PANEL := Vector2(380, 300)
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
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := Ui.screen_panel(self, PANEL, "Create Account")
	_email = Ui.field(box, "Email", "you@example.com")
	_user = Ui.field(box, "Username", "3-20 letters, digits, _ or -")
	_pass = Ui.field(box, "Password", "at least %d characters" % MIN_PASSWORD, true)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var show := Ui.button("Show", 70, 22, Ui.SMALL)
	show.toggle_mode = true
	show.toggled.connect(func(on: bool) -> void: _pass.secret = not on)
	row.add_child(show)
	row.add_child(Art.label("Role", Pal.LABEL, Pal.INK_MUTED))
	_role = OptionButton.new()
	_role.add_item("Player")
	_role.add_item("Admin")
	_role.add_theme_font_size_override("font_size", Art.MIN_FONT)
	row.add_child(_role)
	box.add_child(row)

	_msg = Art.label("", Pal.SMALL, Pal.WRONG, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_msg)

	_go = Ui.button("Register", 300, 30)
	Ui.centre_row(box, _go)
	_go.pressed.connect(_submit)

	var back := Ui.button("Back to Sign In", 300, 24, Ui.SMALL)
	back.pressed.connect(go_back)
	Ui.centre_row(box, back)
	_email.grab_focus()


## Checked here as well as in Postgres: a round trip to say "too short" is a
## round trip the classroom's connection does not need to make.
func _submit() -> void:
	var user := _user.text.strip_edges()
	if _email.text.strip_edges().is_empty():
		_msg.text = "Enter your email."
		return
	if not RegEx.create_from_string("^[A-Za-z0-9_-]{3,20}$").search(user):
		_msg.text = "Username: 3-20 letters, digits, _ or - only."
		return
	if _pass.text.length() < MIN_PASSWORD:
		_msg.text = "Password must be at least %d characters." % MIN_PASSWORD
		return

	_go.disabled = true
	_go.text = "Registering..."
	var role := "admin" if _role.selected == 1 else "player"
	var err: String = await Net.sign_up(_email.text, user, _pass.text, role)
	_go.disabled = false
	_go.text = "Register"
	if err != "":
		_msg.text = err
		return
	# Registered and signed in: straight to the character pick, per §2.
	# An admin never plays, so there is no character to pick.
	main.open("admin" if Net.role == "admin" else "hero")


func go_back() -> void:
	main.open("login")

extends Control

## Top-level screen router. Each screen is a Control built in code (no .tscn),
## registered here and switched via `Main.open(name, data)`.

const SCREENS := {
	"splash": preload("res://scripts/SplashScreen.gd"),
	"login": preload("res://scripts/LoginScreen.gd"),
	"register": preload("res://scripts/RegisterScreen.gd"),
	"reset": preload("res://scripts/ResetScreen.gd"),
	"home": preload("res://scripts/HomeScreen.gd"),
	"hero": preload("res://scripts/HeroSelectScreen.gd"),
	"team": preload("res://scripts/TeamNameScreen.gd"),
	"admin": preload("res://scripts/AdminHomeScreen.gd"),
	"questions": preload("res://scripts/QuestionMgmtScreen.gd"),
	"controls": preload("res://scripts/GameControlsScreen.gd"),
	"feedback": preload("res://scripts/FeedbackScreen.gd"),
	"adventure": preload("res://scripts/AdventureScreen.gd"),
	"learn": preload("res://scripts/LearnScreen.gd"),
	"board": preload("res://scripts/LeaderboardScreen.gd"),
	"summary": preload("res://scripts/SummaryScreen.gd"),
}

var current: Control = null


func _ready() -> void:
	Art.apply_font_fallback()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	focus_mode = Control.FOCUS_ALL
	open("splash")
	if OS.is_debug_build():
		_build_dev_nav()


# --- Dev navigator ----------------------------------------------------------
## Debug builds only: jump to any screen from any screen, because walking the
## real flow to reach the sixth one gets old. Lives on its own CanvasLayer so
## `open()` -- which frees `current` -- cannot take it with it.
##
## Not a substitute for the suites. It is for looking at a screen, which is the
## one thing a headless check cannot do.
func _build_dev_nav() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128
	add_child(layer)

	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 2)
	panel.position = Vector2(4, 24)
	panel.visible = false
	layer.add_child(panel)

	var toggle := Ui.button("DEV", 42, 18, Ui.SMALL_RED)
	# Bottom left: the dashboards put their title top-left and Log Out
	# top-right, and every panel screen puts its title top-centre. This is the
	# one corner nothing claims.
	toggle.position = Vector2(4, 334)
	toggle.add_theme_font_size_override("font_size", 10)
	toggle.pressed.connect(func() -> void: panel.visible = not panel.visible)
	layer.add_child(toggle)

	for name: String in SCREENS:
		var b := Ui.button(name, 96, 17, Ui.SMALL)
		b.add_theme_font_size_override("font_size", 10)
		b.pressed.connect(func() -> void:
			panel.visible = false
			_dev_open(name))
		panel.add_child(b)

	var out := Ui.button("sign out", 96, 17, Ui.SMALL_RED)
	out.add_theme_font_size_override("font_size", 10)
	out.pressed.connect(func() -> void:
		Net.sign_out()
		panel.visible = false
		open("login"))
	panel.add_child(out)


## The map is the one screen with a precondition -- it reads a run that may not
## exist yet -- so jumping to it starts one rather than showing a dead board.
func _dev_open(name: String) -> void:
	if name == "adventure" and not Game.adventure_active:
		Game.begin_adventure(int(Game.duration_seconds))
	open(name)


func open(name: String, data: Dictionary = {}) -> void:
	if current != null:
		current.queue_free()
	current = SCREENS[name].new()
	current.set("main", self)
	add_child(current)
	current.setup(data)


## The soft keyboard covers the bottom half of a landscape phone -- on this
## screen it hid the password field and the Sign In button together. Lift the
## whole screen by half the keyboard's height while it is up, which keeps the
## focused field and the button under it in view without anyone having to know
## to dismiss the keyboard first.
##
## One place for every screen: the alternative is each form handling it, and
## the ones that forget are the ones nobody can sign in on.
func _process(_delta: float) -> void:
	if current == null:
		return
	var keyboard := DisplayServer.virtual_keyboard_get_height()
	var window_h := float(DisplayServer.window_get_size().y)
	var want := 0.0
	if keyboard > 0 and window_h > 0.0:
		# Keyboard height is in real pixels; the screen is laid out in canvas
		# units, so scale it before shifting anything.
		want = -keyboard * (get_viewport_rect().size.y / window_h) * 0.5
	current.position.y = lerpf(current.position.y, want, 0.25)


## Android's back button. The engine quits the app outright by default (see
## `quit_on_go_back`), which mid-run throws away the adventure; screens that
## have somewhere to go back to say so with `go_back()`.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if current != null and current.has_method("go_back"):
		current.go_back()
	else:
		open("home")


## Cheap fade between screens so pops and flashes are softer.
func fade() -> void:
	const FADE_COLOR := Color(Pal.BG, 0.0)
	var shade := ColorRect.new()
	shade.color = FADE_COLOR
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	shade.move_to_front()
	shade.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(shade, "modulate:a", 0.7, 0.12)
	tw.tween_property(shade, "modulate:a", 0.0, 0.18)
	tw.tween_callback(shade.queue_free)
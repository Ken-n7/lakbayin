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

## Music per screen (client), a playlist in `Music.gd`: the town songs on the
## sign-in screens and all that Home opens, the shop's on Choose Hero; a screen
## not listed is silent.
const MUSIC := {
	"login": "town", "register": "town", "reset": "town", "home": "town",
	"team": "town", "board": "town", "learn": "town",
	"hero": "shop",
}

var current: Control = null
## The background music; Home's Settings sets its volume.
var music: Music
## The moving scene behind the menu screens, kept here rather than in each
## screen so it carries on across screen changes instead of restarting.
var backdrop: Backdrop
## Screens with a scene of their own: the map, and Home's island diorama.
const OWN_SCENE := ["adventure", "home", "admin"]


func _ready() -> void:
	Art.apply_font_fallback()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	focus_mode = Control.FOCUS_ALL
	backdrop = Backdrop.new()
	add_child(backdrop)
	music = Music.new()
	add_child(music)
	# `godot --path game -- --explore`: straight onto the board, for looking.
	if OS.is_debug_build() and "--explore" in OS.get_cmdline_user_args():
		explore_map()
	else:
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

	var box := DevUi.box(184.0)
	box.position = Vector2(20, 4)
	box.visible = false
	layer.add_child(box)
	# Two columns: fifteen entries in one ran off the bottom of the canvas, and
	# a row is ~24px however small the height asked for -- the content margins
	# set the floor, not the request.
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 1)
	DevUi.column(box).add_child(grid)
	var col := grid

	for name: String in SCREENS:
		var b := DevUi.button(name)
		b.custom_minimum_size = Vector2(88, 19)
		b.pressed.connect(func() -> void:
			box.visible = false
			_dev_open(name))
		col.add_child(b)

	# The board with no session: for looking at the map, not for playing it.
	var explore := DevUi.button("explore map")
	explore.custom_minimum_size = Vector2(88, 19)
	explore.pressed.connect(func() -> void:
		box.visible = false
		explore_map())
	col.add_child(explore)

	var out := DevUi.button("sign out")
	out.custom_minimum_size = Vector2(88, 19)
	out.pressed.connect(func() -> void:
		Net.sign_out()
		box.visible = false
		open("login"))
	col.add_child(out)

	# A tab on the edge, not a button in the corner: it has to be reachable on
	# every screen without landing on anything the screen owns.
	var tab := DevUi.button("D", 40.0)
	tab.custom_minimum_size = Vector2(18, 40)
	tab.position = Vector2(0, 4)
	tab.pressed.connect(func() -> void: box.visible = not box.visible)
	layer.add_child(tab)


## Dev only: the map with no session, signed in or not -- nothing online,
## nothing scored, a clock long enough not to end on you. The dev drawer on the
## map (Teleport, Skip Station, Open Gates, Fast Walk, Show Walls) does the rest.
const EXPLORE_S := 7200


func explore_map() -> void:
	Game.abandon_adventure()
	Game.begin_adventure(EXPLORE_S)
	open("adventure", {"explore": true})


## The map is the one screen with a precondition -- it reads a run that may not
## exist yet -- so jumping to it starts one rather than showing a dead board.
func _dev_open(name: String) -> void:
	if name == "adventure" and not Game.adventure_active:
		Game.begin_adventure(int(Game.duration_seconds))
	open(name)


func open(name: String, data: Dictionary = {}) -> void:
	if current != null:
		current.queue_free()
	backdrop.set_shown(not name in OWN_SCENE)
	current = SCREENS[name].new()
	current.set("main", self)
	add_child(current)
	current.setup(data)
	music.play(str(MUSIC.get(name, "")))



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
	# Asked only where there is one: on desktop this warns every frame, which
	# is 60 lines a second of "Virtual keyboard not supported".
	if not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
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
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
	"history": preload("res://scripts/HistoryScreen.gd"),
	"summary": preload("res://scripts/SummaryScreen.gd"),
}

## Music per screen (client), a playlist in `Music.gd`: the town songs on the
## sign-in screens and all that Home opens, the shop's on Choose Hero, the
## battle songs on the map while it waits for the start, Victory! on the
## end-of-game summary; a screen not listed is silent. A screen may change its
## own as it goes (`music.play()`): the team lobby to the battle songs, the map
## to The Journey once the adventure starts.
const MUSIC := {
	"login": "town", "register": "town", "reset": "town", "home": "town",
	"team": "town", "board": "town", "learn": "town",
	"hero": "shop",
	"summary": "victory",
	"adventure": "battle",
	# The Quest Keeper's side matches the players' (client): its home and what
	# that opens are the town songs; Game Controls follows its session.
	"admin": "town", "questions": "town", "feedback": "town", "controls": "town",
	"history": "town",
}

var current: Control = null
var current_name := ""
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
	Sfx.attach(self)
	# `godot --path game -- --explore`: straight onto the board, for looking.
	if OS.is_debug_build() and "--explore" in OS.get_cmdline_user_args():
		explore_map()
	else:
		open("splash")
	if OS.is_debug_build():
		_build_dev_panel()


# --- Dev panel -----------------------------------------------------------------
## Debug builds only: every developer tool behind one DEV tab (DevPanel). On
## its own CanvasLayer so `open()` -- which frees `current` -- cannot take it
## with it.
var dev_panel: Control = null


func _build_dev_panel() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128
	add_child(layer)
	dev_panel = DevPanel.new()
	dev_panel.set("main", self)
	layer.add_child(dev_panel)
	if current != null:
		dev_panel.on_screen(current_name)


## Dev only: the map with no session, signed in or not -- nothing online,
## nothing scored, a clock long enough not to end on you. The dev panel's Map
## tab (Teleport, Skip Station, Open Gates, Fast Walk, Show Walls) does the rest.
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
	current_name = name
	current.set("main", self)
	add_child(current)
	# Before setup, so a screen that picks its own music there has the last word.
	music.play(str(MUSIC.get(name, "")))
	current.setup(data)
	if dev_panel != null:
		dev_panel.on_screen(name)



## The soft keyboard covers over half of a landscape phone. While it is up, the
## panel holding the field being typed in is lifted just enough to put that
## field above it -- no more, and never so far the field leaves the top.
##
## It used to lift the whole screen by half the keyboard, whatever was being
## typed in: the Feedback box and Question Management's fields, low on their
## screens, stayed under it, and pop-ups (Rescue's amount, on the map's own
## layer) did not move at all. Now it is the focused field that decides, and
## what moves is its panel: the screen, or a pop-up on a layer of its own.
##
## One place for every screen: the alternative is each form handling it, and
## the ones that forget are the ones nobody can sign in on.

## Gap kept between the field and the keyboard, and the top of the screen.
const KEYBOARD_GAP := 8.0
## Tests only: a keyboard this tall, in canvas units, as if one were up. -1 off.
var fake_keyboard := -1.0
var _lifted := {}      # panel -> [rest y, current lift]


## The keyboard's height in canvas units; 0 when there is none.
func keyboard_height() -> float:
	if fake_keyboard >= 0.0:
		return fake_keyboard
	# Asked only where there is one: on desktop this warns every frame, which
	# is 60 lines a second of "Virtual keyboard not supported".
	if not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		return 0.0
	var px := DisplayServer.virtual_keyboard_get_height()
	var window_h := float(DisplayServer.window_get_size().y)
	if px <= 0 or window_h <= 0.0:
		return 0.0
	# Real pixels; the screen is laid out in canvas units.
	return px * get_viewport_rect().size.y / window_h


## What moves for `field`: its ancestor sitting directly on Main or on a
## CanvasLayer -- the screen, or a pop-up on a layer of its own.
func _panel_of(field: Control) -> Control:
	var n: Node = field
	while n.get_parent() != null and n.get_parent() != self and not n.get_parent() is CanvasLayer:
		n = n.get_parent()
	return n as Control if n.get_parent() != null else null


## How far `panel` should be lifted: 0 unless a field in it is being typed in.
func _lift_wanted(panel: Control, field: Control, keyboard: float) -> float:
	if keyboard <= 0.0 or field == null or _panel_of(field) != panel:
		return 0.0
	var now: float = _lifted[panel][1] if _lifted.has(panel) else 0.0
	var r := field.get_global_rect()
	var top := r.position.y + now          # where it sits unlifted
	var bottom := r.end.y + now
	var over := bottom + KEYBOARD_GAP - (get_viewport_rect().size.y - keyboard)
	return clampf(over, 0.0, maxf(top - KEYBOARD_GAP, 0.0))


func _process(_delta: float) -> void:
	var keyboard := keyboard_height()
	var focus := get_viewport().gui_get_focus_owner()
	# Not a field that never opens the keyboard (the answer, typed on the
	# quiz's own keypad): nothing of it can be under one.
	var field: Control = focus if (focus is LineEdit or focus is TextEdit) and focus.is_visible_in_tree() \
			and bool(focus.get("virtual_keyboard_enabled")) else null
	var panel: Control = _panel_of(field) if field != null and keyboard > 0.0 else null
	if panel != null and not _lifted.has(panel):
		_lifted[panel] = [panel.position.y, 0.0]
	for p: Control in _lifted.keys():
		if not is_instance_valid(p):
			_lifted.erase(p)
			continue
		var want := _lift_wanted(p, field, keyboard)
		var lift: float = lerpf(_lifted[p][1], want, 0.25)
		if absf(lift - want) < 0.5:
			lift = want
		_lifted[p][1] = lift
		p.position.y = _lifted[p][0] - lift
		if lift == 0.0 and want == 0.0:
			_lifted.erase(p)


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
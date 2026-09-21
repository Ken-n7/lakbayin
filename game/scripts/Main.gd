extends Control

## Top-level screen router. Each screen is a Control built in code (no .tscn),
## registered here and switched via `Main.open(name, data)`.

const SCREENS := {
	"splash": preload("res://scripts/SplashScreen.gd"),
	"title": preload("res://scripts/TitleScreen.gd"),
	"hero": preload("res://scripts/HeroSelectScreen.gd"),
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


func open(name: String, data: Dictionary = {}) -> void:
	if current != null:
		current.queue_free()
	current = SCREENS[name].new()
	current.set("main", self)
	add_child(current)
	current.setup(data)


## Android's back button. The engine quits the app outright by default (see
## `quit_on_go_back`), which mid-run throws away the adventure; screens that
## have somewhere to go back to say so with `go_back()`.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if current != null and current.has_method("go_back"):
		current.go_back()
	else:
		open("title")


## Cheap fade between screens so pops and flashes are softer.
func fade() -> void:
	const FADE_COLOR := Color(0.10, 0.08, 0.13, 0.0)
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
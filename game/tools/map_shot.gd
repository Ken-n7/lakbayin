extends SceneTree

## Screenshots of the Adventure Map, for looking at the board without playing to
## it. Run it windowed -- it needs a real GL context, so no `--headless`:
##
##   godot --path game --script res://tools/map_shot.gd [-- <out dir>]
##
## Writes one PNG per entry in SHOTS and prints the absolute paths. Dev tool: it
## is never loaded by the game, and the only thing it knows about
## `AdventureScreen` is its camera.

const SHOT_SIZE := Vector2i(1920, 1080)

## `zoom` 0 means "frame the whole board" (`_aerial_zoom()`); `at` is in normalized
## world coords, matching `ISLANDS` and `TRAILS`. `dismiss` brief the station first
## and `hold` waits that many frames, which is how the after state of anything that
## animates gets photographed.
const SHOTS := [
	{"name": "map_full", "at": Vector2(0.50, 0.50), "zoom": 0.0},
	{"name": "island1", "at": Vector2(0.45, 0.78), "zoom": 0.45},
	{"name": "station1", "at": Vector2(0.70, 0.79), "zoom": 1.0},
	{"name": "barricade", "at": Vector2(0.665, 0.775), "zoom": 0.75},
	{"name": "camp_bridge", "at": Vector2(0.86, 0.82), "zoom": 0.75},
	{"name": "dev_drawer", "at": Vector2(0.70, 0.79), "zoom": 0.75, "drawer": true},
	{"name": "island2_bridge", "at": Vector2(0.345, 0.48), "zoom": 0.6},
	{"name": "island2", "at": Vector2(0.27, 0.28), "zoom": 0.5},
	{"name": "island3", "at": Vector2(0.74, 0.27), "zoom": 0.5},
	{"name": "island3_gate", "at": Vector2(0.625, 0.255), "zoom": 0.75},
	{"name": "island3_open", "at": Vector2(0.625, 0.255), "zoom": 0.75,
			"dismiss": true, "hold": 120},
	{"name": "island2_open", "at": Vector2(0.30, 0.375), "zoom": 0.65,
			"dismiss": true, "hold": 120},
	{"name": "barricade_walking", "at": Vector2(0.665, 0.775), "zoom": 0.75,
			"dismiss": true, "hold": 30},
	{"name": "barricade_open", "at": Vector2(0.665, 0.775), "zoom": 0.75, "hold": 120},
]

var _screen: Control
var _out := "user://"
var _shot := 0
var _armed := false
var _hold := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	DisplayServer.window_set_size(SHOT_SIZE)
	_screen = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(_screen)
	_screen.setup({})
	# The board, not the game: no HUD bar, no joystick, no "tap to start".
	_screen.hud.hud_layer.visible = false
	_screen.hud.ui_layer.visible = false
	_screen._sky.visible = false    # the board, not the sky over it
	_screen._cam.position_smoothing_enabled = false
	_screen._clamp_cam(false)


## One frame to move the camera, the next to save what it drew.
func _process(_delta: float) -> bool:
	if _shot >= SHOTS.size():
		return true
	var shot: Dictionary = SHOTS[_shot]
	if not _armed:
		_hold = int(shot.get("hold", 0))
		var z: float = float(shot.zoom)
		if z <= 0.0:
			z = _screen._aerial_zoom()
		_screen._cam.zoom = Vector2(z, z)
		_screen._cam.position = MapGrid.norm(shot.at)
		# The HUD is off for every other shot; the drawer is the one thing here
		# that only exists on the UI layer, so it gets it back.
		_screen.hud.ui_layer.visible = bool(shot.get("drawer", false))
		if bool(shot.get("drawer", false)) and _screen.hud.dev != null:
			_screen.hud.dev.toggle()
			_hold = maxi(_hold, 30)
		if bool(shot.get("dismiss", false)):
			for g: Dictionary in _screen.barricades.list:
				_screen.barricades.open(g)
		_armed = true
		return false
	if _hold > 0:
		_hold -= 1
		return false
	var path: String = _out.path_join("%s.png" % shot.name)
	var err := root.get_texture().get_image().save_png(path)
	print("%s  %s" % ["ok " if err == OK else "FAIL", ProjectSettings.globalize_path(path)])
	_shot += 1
	_armed = false
	return false

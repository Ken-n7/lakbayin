extends SceneTree

## Every question tower, photographed with its interact spot marked, plus a
## line per tower saying which face of the building that spot is on. The spot
## (the circle's anchor) is where the hero stands to be asked the question; it
## belongs at the tower's front door -- below the building on screen -- never
## behind it or beside it. Windowed, like map_shot:
##
##   godot --path game --script res://tools/tower_shot.gd [-- <out dir>]

const SHOT_SIZE := Vector2i(900, 700)
const ZOOM := 1.6

var _screen: Control
var _out := "user://"
var _shot := 0
var _armed := false
var _marks: Array[Node2D] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	DisplayServer.window_set_size(SHOT_SIZE)
	_screen = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(_screen)
	_screen.setup({})
	_screen.hud.hud_layer.visible = false
	_screen.hud.ui_layer.visible = false
	_screen._sky.visible = false
	_screen._cam.position_smoothing_enabled = false
	var terrain = _screen.world.terrain
	var k := 1
	var n := 0
	for st in Game.ITEMS_PER_STATION.size():
		k += 1
		for _i in Game.ITEMS_PER_STATION[st]:
			var lift: Vector2 = terrain.lifts[k]
			print("circle %2d  station %d  lift %s  door %s" % [n + 1, st + 1, lift, _face(lift)])
			n += 1
			k += 1
	for c: Node2D in _screen.world.circles:
		var m := _Mark.new()
		m.position = c.position
		m.z_index = 100
		_screen.world.add_child(m)


static func _face(lift: Vector2) -> String:
	if lift.y < 0.0 and absf(lift.x) < 1.0:
		return "FRONT"
	if lift.y > 0.0:
		return "BACK"
	return "SIDE"


func _process(_delta: float) -> bool:
	var circles: Array = _screen.world.circles
	if _shot >= circles.size():
		return true
	var c: Node2D = circles[_shot]
	if not _armed:
		_screen._cam.zoom = Vector2(ZOOM, ZOOM)
		_screen._cam.position = c.position + Vector2(0, -40)
		_armed = true
		return false
	var path: String = _out.path_join("tower_%02d.png" % (_shot + 1))
	root.get_texture().get_image().save_png(path)
	_shot += 1
	_armed = false
	return false


## A red ring on the anchor: where the hero has to stand to get the question.
class _Mark extends Node2D:
	func _draw() -> void:
		draw_arc(Vector2.ZERO, 12.0, 0.0, TAU, 32, Color.RED, 3.0)
		draw_circle(Vector2.ZERO, 3.0, Color.RED)

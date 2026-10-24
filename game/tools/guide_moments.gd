extends Node

## The match moments How to Play shows, staged in offline Practice through the
## game's own calls and photographed whole. tools/guide_shots.py crops them
## into assets/ui/guide/:
##
##   godot --path game res://tools/guide_moments.tscn -- <out dir>

var out := ""
var vp: SubViewport
var main: Control
var screen: Node


func _ready() -> void:
	out = OS.get_cmdline_user_args()[0]
	DirAccess.make_dir_recursive_absolute(out)
	Game.touch = true              # GO and the joystick, as on a phone
	vp = SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.size_2d_override = Vector2i(640, 360)
	vp.size_2d_override_stretch = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	main = load("res://scenes/Main.tscn").instantiate()
	vp.add_child(main)
	await _wait(1.0)
	main.open("adventure", {"practice": true})
	await _wait(3.0)
	screen = main.current
	screen.skip_intro()
	await _wait(1.0)
	var monks: Array = screen.world.monks

	# A monk in reach: GO lights, the prompt says what it does.
	_beside(monks[0].position)
	await _wait(1.0)
	await _shot("monk")
	# Its keypad, a word half written.
	screen._try_monk(0)
	await _wait(1.0)
	var pad := screen._overlay.find_children("*", "BaybayinKeypad", true, false)[0] as BaybayinKeypad
	var spelt: String = screen.play.words[0].modern
	for g in spelt.substr(0, 2):
		pad.press(g)
	await _wait(0.6)
	await _shot("keypad")
	# Wrong: the keypad shuts for 10 s.
	pad.clear()
	pad.press("ᜑ")
	screen._overlay._submit.pressed.emit()
	await _wait(0.5)
	await _shot("locked")
	screen._overlay.close()
	await _wait(0.6)

	# Right, at another monk: carried, and the monk wears the team's colour.
	_beside(monks[1].position)
	await _wait(0.5)
	screen._try_monk(1)
	await _wait(0.8)
	pad = screen._overlay.find_children("*", "BaybayinKeypad", true, false)[0] as BaybayinKeypad
	for g in str(screen.play.words[1].modern):
		pad.press(g)
	screen._overlay._submit.pressed.emit()
	await _wait(2.5)
	if is_instance_valid(screen._overlay):
		screen._overlay.close()
	await _wait(1.2)
	await _shot("answered")
	await _shot("clock")

	# A teammate at work on the next one.
	monks[2].set_busy(true)
	_beside(monks[2].position)
	await _wait(1.0)
	await _shot("typing")

	# At the Monastery's door with a word to deposit.
	_beside(screen.world.door(), 0)
	await _wait(1.2)
	await _shot("deposit")

	# Every monk seen: the minimap shows them all.
	for i in monks.size():
		screen._seen[i] = true
	await _wait(1.5)
	await _shot("minimap")
	get_tree().quit(0)


## The hero set down on open ground of the target's level, just short of it.
func _beside(at: Vector2, level := -1) -> void:
	var grid: MapGrid = screen.grid
	if level < 0:
		level = int(grid.height.get(MapGrid.cell_at(at), 0))
	for r in [26.0, 34.0, 42.0]:
		for k in 16:
			var p: Vector2 = at + Vector2.from_angle(PI * 0.5 + k * TAU / 16.0) * r
			if grid.cell_ok(MapGrid.cell_at(p), level):
				screen.player.position = p
				screen.hero_level = level
				return


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	vp.get_texture().get_image().save_png("%s/%s.png" % [out, name])
	print("shot ", name)


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout

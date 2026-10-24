extends Node

## Every How to Play page as a picture, at 3x like a phone draws it:
##
##   godot --path game res://tools/guide_shot.tscn -- <out dir>
##
## Pages that animate are shot mid-way, after `WAIT` seconds on each.

const WAIT := 2.4


func _ready() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	DirAccess.make_dir_recursive_absolute(out)
	var vp := SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.size_2d_override = Vector2i(640, 360)
	vp.size_2d_override_stretch = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.size = Vector2(640, 360)
	vp.add_child(bg)
	var guide := HowToPlay.open(bg)
	var next := guide.find_child("Next", true, false) as Button
	var n := 1
	while true:
		await get_tree().create_timer(WAIT).timeout
		vp.get_texture().get_image().save_png("%s/page%d.png" % [out, n])
		if next.text != "Next":
			break
		next.pressed.emit()
		n += 1
	get_tree().quit(0)

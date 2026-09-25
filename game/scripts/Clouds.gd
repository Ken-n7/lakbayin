class_name Clouds
extends Node2D

## A few clouds from the Tiny Swords pack drifting across a scene, faint, and
## wrapping round once they leave it. Home's diorama and the menu backdrop
## both float them over their islands.

const PATHS := ["res://assets/terrain/decorations/clouds/Clouds_01.png",
		"res://assets/terrain/decorations/clouds/Clouds_03.png",
		"res://assets/terrain/decorations/clouds/Clouds_05.png"]
const SPEED := 9.0            # px a second -- slow enough to feel, not watch
const ALPHA := 0.55
const SCALE := 0.55

## How far right a cloud goes before it comes back in from the left.
var span := 1000.0


## `count` clouds spread across `width`, alternating between `top` and
## `top + gap`; more of them, at `alpha`, over a bigger scene.
func _init(width := 1000.0, top := 40.0, gap := 110.0, count := 3, alpha := ALPHA) -> void:
	span = width
	for i in count:
		var c := Sprite2D.new()
		c.texture = Art.tex(PATHS[i % PATHS.size()])
		c.scale = Vector2(SCALE, SCALE)
		c.modulate = Color(1, 1, 1, alpha)
		c.position = Vector2(i * width / count, top + (i % 3) * gap)
		add_child(c)


func _process(delta: float) -> void:
	for c: Sprite2D in get_children():
		c.position.x += SPEED * delta
		if c.position.x > span + 200.0:
			c.position.x = -200.0

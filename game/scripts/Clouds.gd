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
## A cloud drifting near any of these fades nearly out, so it never hides
## them -- the hero and the knights, on the map. Empty, clouds keep their alpha.
var keep_clear: Array = []
const CLEAR_NEAR := 110.0     # px: fully faded inside this
const CLEAR_FAR := 220.0      # px: fully there beyond this
const CLEAR_ALPHA := 0.12
var _alpha := ALPHA


## `count` clouds spread across `width`, alternating between `top` and
## `top + gap`; more of them, at `alpha`, over a bigger scene. `phase` (0..1)
## slides the whole row along, so two rows do not line up.
func _init(width := 1000.0, top := 40.0, gap := 110.0, count := 3, alpha := ALPHA,
		phase := 0.0) -> void:
	span = width
	_alpha = alpha
	for i in count:
		var c := Sprite2D.new()
		c.texture = Art.tex(PATHS[i % PATHS.size()])
		c.scale = Vector2(SCALE, SCALE)
		c.modulate = Color(1, 1, 1, alpha)
		c.position = Vector2((i + phase) * width / count, top + (i % 3) * gap)
		add_child(c)


func _process(delta: float) -> void:
	var spots: Array[Vector2] = []
	for n in keep_clear:
		if is_instance_valid(n):
			spots.append(to_local((n as Node2D).global_position))
	for c: Sprite2D in get_children():
		c.position.x += SPEED * delta
		if c.position.x > span + 200.0:
			c.position.x = -200.0
		if not spots.is_empty():
			var d := INF
			for p in spots:
				d = minf(d, c.position.distance_to(p))
			var want := lerpf(CLEAR_ALPHA, _alpha, smoothstep(CLEAR_NEAR, CLEAR_FAR, d))
			c.modulate.a = move_toward(c.modulate.a, want, delta * 1.5)

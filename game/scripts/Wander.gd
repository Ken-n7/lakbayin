extends Node2D

## Tiny ambient wanderer for sheep: picks a near target, idles, and shuffles
## between grazing spots — never into the water.

var rng := RandomNumberGenerator.new()
var _home := Vector2.ZERO
var _target := Vector2.ZERO
var _speed := 26.0
var _timer := 0.0
## How far round a wall a sheep's feet keep (half its body, near enough).
const SOLID_MARGIN := 8.0


func _ready() -> void:
	rng.seed = int(Time.get_unix_time_from_system()) + randi()
	if OS.is_debug_build():
		rng.seed = absi(position.x) * 31 + absi(position.y) * 17
	# Stand on the feet, as Art.anim_sprite() does: centred, a sheep y-sorted by
	# its middle and a hero behind it drew over it.
	var spr := get_child(0) as AnimatedSprite2D
	spr.offset.y = -spr.sprite_frames.get_frame_texture("idle", 0).get_height() * 0.5
	_home = position
	_pick_target()


func _process(delta: float) -> void:
	var spr: AnimatedSprite2D = get_child(0) as AnimatedSprite2D
	var moving := position.distance_to(_target) > 6.0
	if moving:
		var dir := (_target - position).normalized()
		position += dir * _speed * delta
		if not _walkable(position + dir * 4.0):
			_pick_target()
		# Face the way it walks, at the size it was placed at (MapCfg.SHEEP_SCALE):
		# a 0.45 left here from the first draft halved every sheep that moved.
		spr.scale.x = absf(spr.scale.y) * (1.0 if dir.x >= 0.0 else -1.0)
	if spr.animation != ("walk" if moving else "idle"):
		spr.play("walk" if moving else "idle")
	_timer += delta
	if not moving and _timer > rng.randf_range(1.5, 4.0):
		_timer = 0.0
		_pick_target()


func _pick_target() -> void:
	_target = _home + Vector2(rng.randf_range(-46.0, 46.0), rng.randf_range(-34.0, 34.0))


func _walkable(p: Vector2) -> bool:
	var world := get_parent()
	if world == null or not world.has_meta("grass"):
		return true
	var layer: TileMapLayer = world.get_meta("grass")
	var t: float = world.get_meta("tile", 32.0)
	var c := Vector2i(floori(p.x / t), floori(p.y / t))
	# On the map, a sheep keeps to the level it grazes on: never over a cliff's
	# edge, onto a stair, or up one.
	if world.has_meta("height"):
		var height: Dictionary = world.get_meta("height")
		var home := Vector2i(floori(_home.x / t), floori(_home.y / t))
		if (world.get_meta("no_walk", {}) as Dictionary).has(c) \
				or int(height.get(c, -1)) != int(height.get(home, -2)):
			return false
	# Not through a rock, a trunk or a building: the walls the hero bumps
	# into, a little wider, since a sheep is wider than its feet.
	for r: Rect2 in world.get_meta("solid", []):
		if r.grow(SOLID_MARGIN).has_point(p):
			return false
	return layer.get_cell_source_id(c) != -1
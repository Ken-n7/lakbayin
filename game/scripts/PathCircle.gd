extends Node2D

## One circle on the board path: exactly one question item. Colour is the
## station's accent; state is locked / current / done.
##
## The disc is generated, not loaded: the pack has no circle in three colours,
## and a white disc tinted by `modulate` is one texture for all forty nodes.

const ACCENT := {
	"Blue": Color("3f7ad9"),
	"Orange": Color("e8891c"),
	"Red": Color("c8452e"),
}

static var _disc_tex: ImageTexture = null

var index := 0
var state := "locked"

var _spr: Sprite2D
var _label: Label
var _accent := Color.WHITE
var _pulse: Tween = null


## White fill with a darker rim, so a single `modulate` tints both together.
static func disc() -> ImageTexture:
	if _disc_tex != null:
		return _disc_tex
	const D := 24
	var img := Image.create(D, D, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := Vector2(D * 0.5 - 0.5, D * 0.5 - 0.5)
	for y in D:
		for x in D:
			var r := Vector2(x, y).distance_to(c)
			if r <= 11.0:
				img.set_pixel(x, y, Color(0.55, 0.55, 0.55) if r > 8.5 else Color.WHITE)
	_disc_tex = ImageTexture.create_from_image(img)
	return _disc_tex


func setup(circle_index: int, accent: String) -> void:
	index = circle_index
	_accent = ACCENT.get(accent, Color.WHITE)
	_spr = Sprite2D.new()
	_spr.texture = disc()
	# Nudged up so the disc reads as painted on the ground the node stands on.
	_spr.offset = Vector2(0, -2)
	add_child(_spr)
	_label = Art.label(str(index + 1), 11, Color("2a201a"), HORIZONTAL_ALIGNMENT_CENTER)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.size = Vector2(40, 24)
	_label.position = Vector2(-20, -14)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Art.shadow(_label, Color(1, 1, 1, 0.55), 0, 2)
	add_child(_label)
	set_state("locked")


func set_state(s: String) -> void:
	state = s
	if _pulse != null and _pulse.is_valid():
		_pulse.kill()
	_pulse = null
	match s:
		"current":
			_spr.modulate = _accent
			_spr.scale = Vector2.ONE
			_label.text = str(index + 1)
			# The one circle the player may answer has to be findable at a glance.
			_pulse = create_tween().set_loops()
			_pulse.tween_property(_spr, "scale", Vector2(1.18, 1.18), 0.5)
			_pulse.tween_property(_spr, "scale", Vector2.ONE, 0.5)
		"done":
			_spr.modulate = _accent.darkened(0.45)
			_spr.scale = Vector2.ONE
			_label.text = "✓"
		_:
			_spr.modulate = Color(_accent.darkened(0.3), 0.7)
			_spr.scale = Vector2(0.85, 0.85)
			_label.text = str(index + 1)

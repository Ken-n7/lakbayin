class_name Monk
extends Node2D

## One monk on the map: a station holding one Filipino word (DESIGN.md 3.2).
## Black until your team has answered it, then your team's colour; Baybayin
## glyphs drift round its head. They are decoration, never its answer -- the
## word is only on the answer panel.

const SCALE := 0.5
const FPS := 8.0
const FRAMES := 6                    # Idle.png: six 192px frames in a row
## Round the head, not a tower top: TowerSymbols' ring, scaled down to a monk.
const SIGNS_AT := Vector2(0, -76)
const SIGNS_SCALE := 0.7

var index := 0
var colour := "Black"                # Black, Blue or Red: the pack's monks

var _body: AnimatedSprite2D
var _signs: TowerSymbols


func _ready() -> void:
	_body = Art.anim_sprite(self, _idle(), Vector2.ZERO, SCALE, FPS, 1.0, FRAMES)
	_body.name = "Body"
	_signs = TowerSymbols.new()
	_signs.signs = _glyphs()
	_signs.position = SIGNS_AT
	_signs.scale = Vector2(SIGNS_SCALE, SIGNS_SCALE)
	add_child(_signs)


func _idle() -> String:
	return "res://assets/units/%s/Monk/Idle.png" % colour


## Four glyphs, its own: the seed is the monk's index, so every phone in a
## match draws the same ones round the same monk.
func _glyphs() -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7919 * (index + 1)
	var out: Array = []
	while out.size() < 4:
		var k: Array = Baybayin.KEYS[rng.randi_range(0, 16)]      # vowels and consonants
		if not out.has(k[0]):
			out.append(k[0])
	return out


## Answered by a team: their colour, and the glyphs burst away.
func take(team_colour: String) -> void:
	if team_colour == colour:
		return
	colour = team_colour
	var at := _body.position
	_body.queue_free()
	_body = Art.anim_sprite(self, _idle(), at, SCALE, FPS, 1.0, FRAMES)
	_body.name = "Body"
	if is_instance_valid(_signs) and not _signs.bursting():
		_signs.burst()

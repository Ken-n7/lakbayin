class_name Monk
extends Node2D

## One monk on the map: a station holding one Filipino word (DESIGN.md 3.2).
## Black until your team has answered it, then your team's colour; Baybayin
## glyphs drift round its head. They are decoration, never its answer -- the
## word is only on the answer panel.

const SCALE := 0.5
const FPS := 8.0
const FRAMES := 6                    # Idle.png: six 192px frames in a row
## Round the head, not a tower top: TowerSymbols' ring, scaled down to a monk
## whose head is 35px over his feet (the node's origin, `Art.sit_on_art`).
const SIGNS_AT := Vector2(0, -19)
const SIGNS_SCALE := 0.7

var index := 0
var colour := "Black"                # Black, Blue or Red: the pack's monks

var _body: AnimatedSprite2D
var _signs: TowerSymbols
var _typing: Label
var busy := false


func _ready() -> void:
	_body = _make_body()
	_signs = TowerSymbols.new()
	_signs.signs = _glyphs()
	_signs.position = SIGNS_AT
	_signs.scale = Vector2(SIGNS_SCALE, SIGNS_SCALE)
	add_child(_signs)
	_typing = Art.label("Teammate typing…", 14, Pal.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	_typing.name = "Typing"
	_typing.position = Vector2(-68, -49)
	_typing.size = Vector2(136, 22)
	_typing.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Art.shadow(_typing)
	add_child(_typing)
	set_busy(busy)


## Standing on his feet: the frame's empty rows below them taken up.
func _make_body() -> AnimatedSprite2D:
	var b := Art.anim_sprite(self, _idle(), Vector2.ZERO, SCALE, FPS, 1.0, FRAMES)
	Art.sit_on_art(b)
	# sit_on_art leaves the picture where it was, 29px over the node. The
	# node is where he stands -- his wall (MapWorld.MONK_FEET), his tap point
	# and his draw order are all measured from it -- so his feet go there.
	b.position = Vector2.ZERO
	b.name = "Body"
	b.frame = index % FRAMES          # not in step with every other monk
	return b


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
	set_busy(false)
	_body.queue_free()
	_body = _make_body()
	if is_instance_valid(_signs) and not _signs.bursting():
		_signs.burst()


## A cooperative hint; a player can still interact with a busy monk.
func set_busy(on: bool) -> void:
	busy = on and colour == "Black"
	if is_instance_valid(_typing):
		_typing.visible = busy
	if is_instance_valid(_signs) and not _signs.bursting():
		_signs.visible = not busy

class_name Peers
extends Node2D

## Everybody else, on your board.
##
## A marker per other player, standing at the circle they have reached, in
## their team's colour with their name over it. Not a walking avatar: the map
## is a progress track, so the circles are the only positions the game models,
## and streaming x/y at 10Hz would cost a hundred times the messages to show
## something the board does not mean.
##
## `items_done` is the position. It is already written by `apply_answer` and
## already on the realtime publication, so this listens to data the game was
## sending anyway and adds no writes at all.

## Four teams, four colours, in the order the teams were created.
const TEAM_COLOURS := [
	Color("4aa3df"),   # blue
	Color("e8663c"),   # red
	Color("52b262"),   # green
	Color("d9a125"),   # amber
]

var _markers := {}          # profile_id -> Node2D
var _team_order: Array = []


func _init() -> void:
	# Above the ground, below the hero -- y-sorted with everything else so a
	# marker behind a tower is behind it.
	y_sort_enabled = true


## `anchors` are the circle positions in path order; `gate` is where somebody
## who has finished everything stands.
## Rebuilt from the rows each time rather than diffed. There are at most a
## handful of markers, this runs only when somebody answers, and a diff has to
## get removal exactly right -- which it did not, the first time.
func refresh(rows: Array, anchors: Array, gate: Vector2, me: String) -> void:
	for old in get_children():
		remove_child(old)
		old.queue_free()
	_markers.clear()

	for row: Dictionary in rows:
		var id: String = str(row.get("profile_id", ""))
		if id == me or id == "":
			continue
		var done: int = clampi(int(row.get("items_done", 0)), 0, anchors.size())
		var marker := _make(str(row.get("username", "?")),
			_colour(str(row.get("team_id", ""))))
		marker.position = gate if done >= anchors.size() else anchors[done]
		# Out of the adventure: still shown, because a teacher and a team-mate
		# both want to know where somebody stopped.
		marker.modulate.a = 0.45 if bool(row.get("eliminated", false)) else 1.0
		_markers[id] = marker
		add_child(marker)


## Teams take colours in the order they first appear, so the same team keeps
## the same colour for as long as the board is open.
func _colour(team_id: String) -> Color:
	if team_id == "":
		return Color.WHITE
	var at := _team_order.find(team_id)
	if at == -1:
		_team_order.append(team_id)
		at = _team_order.size() - 1
	return TEAM_COLOURS[at % TEAM_COLOURS.size()]


## A pin, not a person: a coloured lozenge with the name over it. Nothing here
## pretends to be a second hero -- there is one hero on this board and it is
## the player's.
func _make(username: String, colour: Color) -> Node2D:
	var node := Node2D.new()

	var pin := Polygon2D.new()
	var pts := PackedVector2Array()
	for i in 10:
		var a := TAU * i / 10.0
		pts.append(Vector2(cos(a) * 9.0, sin(a) * 6.0))
	pin.polygon = pts
	pin.color = colour
	pin.position = Vector2(0, -4)
	node.add_child(pin)

	var ring := Polygon2D.new()
	ring.polygon = pts
	ring.color = Color(0, 0, 0, 0.35)
	ring.scale = Vector2(1.25, 1.25)
	ring.position = Vector2(0, -3)
	node.add_child(ring)
	node.move_child(ring, 0)

	var tag := Label.new()
	tag.text = username
	tag.add_theme_font_size_override("font_size", 11)
	tag.add_theme_color_override("font_color", Color.WHITE)
	tag.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	tag.add_theme_constant_override("shadow_offset_y", 1)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.position = Vector2(-40, -30)
	tag.custom_minimum_size = Vector2(80, 0)
	tag.size = Vector2(80, 14)
	node.add_child(tag)
	return node

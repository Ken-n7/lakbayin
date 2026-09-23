class_name Barricades
extends RefCounted

## The gates: a fence of boulders swung round each station, with a giant knight
## filling its one gap.
##
## One rule for all three -- **his own station's briefing stands him down** --
## so a station is always on the near side of its own guard. A guard is a wall,
## not a trigger: what keeps the walk in order is the gating in
## `AdventureScreen`, not the man.
##
## A fence rather than a line across the walk because every station stands in a
## corner or at an end of its island, where a line either has nowhere to go or
## strands a stop on the wrong side of itself.

var world: Node2D
var grid: MapGrid

## One entry per `MapCfg.BARRICADES` row. See `_build_one()` for its shape.
var list: Array[Dictionary] = []

## Anchor index of each station's tower, handed in by `MapBuilder`: it is the
## station a guard steps aside toward, and the side he faces.
var _towers: Array = []


func _init(w: Node2D, g: MapGrid) -> void:
	world = w
	grid = g


## One gate per `GATES` entry, each posted in whatever state this run has already
## earned. Built last, because a gate needs the stations standing (for the decor
## keep-outs it checks) and the finished `grid.anchors`.
func build(towers: Array) -> void:
	list.clear()
	_towers = towers
	for spec: Dictionary in MapCfg.BARRICADES:
		var g := _build_one(spec, int(towers[int(spec.st)]))
		list.append(g)
		_post_guard(g)


## The boulder line and the gap in it the guard fills, laid across the walk from
## stop `ai` to the next one along, cell by cell out to land's end on both sides,
## so there is no way round it and exactly one way through.
##
## Objects rather than terrain: the rocks are what the player reads, and one
## `grid.solid` rect per cell is what stops them. The line is laid on every build, open
## or not -- only the guard in its gap comes and goes.
func _build_one(spec: Dictionary, ai: int) -> Dictionary:
	var a: Vector2 = grid.anchors[ai]          # the station's doorstep
	var b: Vector2 = grid.anchors[ai + 1]      # its first circle: the way out
	var g := {
		"st": int(spec.st),
		"post": Vector2.ZERO,
		"wall": Rect2(),
		"rocks": [] as Array[Rect2],
		"stand": Vector2.ZERO,
		"guard": null,
		"open": false,
		"offset": spec.get("offset", Vector2.ZERO),
		"rest": spec.get("rest", Vector2.ZERO),
	}
	_lay_arc(g, a, b, float(spec.arc), float(spec.get("shift", 0.0)))
	g.stand = _guard_rest(g)
	# Nothing grows in the gap, along the walk he takes out of it, or where he ends
	# up standing -- a tree in any of the three reads as him shoving through a wood.
	# The extra headroom is because he is base-anchored and stands ~90px tall, so a
	# trunk a clear cell above him still draws down over his head. Reserved here,
	# before `_build_decor()` runs, which is also what makes it the same clear
	# ground on a restart that has already opened this gate.
	grid.keep_out(Rect2(g.post as Vector2, Vector2.ZERO).expand(g.stand as Vector2)
			.grow_individual(MapCfg.GUARD_CLEARING.x, MapCfg.GUARD_CLEARING.y,
					MapCfg.GUARD_CLEARING.z, MapCfg.GUARD_CLEARING.w))
	# Keep the decor pass clear of the rubble on both sides. Touching it is not
	# enough: a loose boulder alongside the line reads as part of the wall and
	# walking through that one is the bug it looks like, and one tile is not
	# enough either -- a pine two cells off still reads as standing in the line.
	var rocks: Array = g.rocks
	if not rocks.is_empty():
		var span: Rect2 = rocks[0]
		for r in rocks:
			span = span.merge(r)
		grid.keep_out(span.grow(MapCfg.RUBBLE_CLEARING))
	return g


## A fence swung right round the station at `radius` cells, from land's end on one
## side of it to land's end on the other, with the gap on the bearing the walk
## leaves by. This is the gate for a station standing in a corner of its island:
## island 2's walk doubles back on itself, so a line square across it always
## leaves the last circle on the station's side -- but a fence around the corner
## has the whole island outside it.
##
## Each cell's wall is `ROCK_WALL`, wider than its cell, so neighbours overlap
## however the curve steps and there is no diagonal slip between two of them.
func _lay_arc(g: Dictionary, a: Vector2, b: Vector2, radius: float, shift: float) -> void:
	var r := radius * MapCfg.TILE
	# The gap sits on the bearing the walk leaves by, give or take `shift` cells of
	# arc -- clockwise is downward on screen. It is only where the guard stands;
	# the way out is open wherever it is, since nothing draws the road.
	var bearing := (b - a).angle() + shift * MapCfg.TILE / r
	# Half a cell of arc per step, so the walk round never skips a cell.
	var da := MapCfg.ARC_STEP / r
	g.post = a + Vector2.from_angle(bearing) * r
	var stretch := Rect2(MapCfg.GUARD_REACH.position + (g.post as Vector2), MapCfg.GUARD_REACH.size)
	var seen := {}
	var wall := Rect2(g.post as Vector2, Vector2.ZERO)
	for side: float in [1.0, -1.0]:
		var n := 0
		while true:
			var c := MapGrid.cell_at(a + Vector2.from_angle(bearing + side * float(n) * da) * r)
			n += 1
			if seen.has(c):
				continue
			if not grid.land.has(c):
				# The arm has run out of island. A boulder's wall stands on the
				# boulder, which leaves the boulder's own cell -- the ground at
				# its foot -- open, and at the end of an arm that foot is the way
				# round the whole fence. So the fence takes one more step, into
				# the shallows: the last stone stands in the water with its wall
				# over the beach behind it, and the arm ends where the map does.
				if MapGrid.in_bounds(c):
					_lay_rock(g, c, MapGrid.rock_wall(c))
				break
			seen[c] = true
			var rect := MapGrid.rock_wall(c)
			if stretch.has_point(MapGrid.cell_mid(c)):
				wall = wall.merge(rect)   # the guard's own stretch of it
			else:
				_lay_rock(g, c, rect)
	g.wall = wall


func _lay_rock(g: Dictionary, c: Vector2i, rect: Rect2) -> void:
	(g.rocks as Array).append(rect)
	grid.block(rect)
	# Round-robin off the cell so the wall is not four of the same stone.
	Art.sprite(world, Art.tex(MapCfg.ROCK_SHEET % (1 + posmod(c.x + c.y, MapCfg.ROCK_VARIANTS))),
			MapGrid.cell_mid(c), MapCfg.ROCK_SCALE)


## Has this run already earned its way past `g`? One rule: the briefing.
func _is_due(g: Dictionary) -> bool:
	return Game.towers_entered[int(g.st)]


func _post_guard(g: Dictionary) -> void:
	# A restart mid-run keeps whatever it had already earned. He is not a wall any
	# more, but he is still the station's man, so he stands where he stepped aside
	# to -- and the gate is marked open, which is what "no blocker" means here.
	if _is_due(g):
		g.open = true
		g.guard = _spawn_guard(int(g.st), g.stand as Vector2)
		_face(g, g.stand as Vector2)
		return
	grid.block(g.wall as Rect2)
	# `offset` moves the man and nothing else. The gap, the stretch of wall that
	# plugs it and the ground kept clear around it are all the bearing's, measured
	# off the post itself -- this is only where in his own gap he is drawn, and
	# folding it back into the post laid a boulder at his boots.
	var at := (g.post as Vector2) + (g.offset as Vector2)
	g.guard = _spawn_guard(int(g.st), at)
	_face(g, at)


## Idle and walk on the one node, so standing him down is a change of animation
## while the tween carries him. Same base anchoring `Art.anim_sprite()` uses.
func _spawn_guard(st: int, at: Vector2) -> AnimatedSprite2D:
	var k := AnimatedSprite2D.new()
	k.sprite_frames = Art.anim_spriteframes({
		"idle": [MapCfg.GUARD_IDLE_SHEET % MapCfg.LIVERY[st], MapCfg.GUARD_IDLE_FPS, true],
		"walk": [MapCfg.GUARD_WALK_SHEET % MapCfg.LIVERY[st], MapCfg.GUARD_WALK_FPS, true],
	})
	k.position = at
	k.scale = Vector2(MapCfg.GUARD_SCALE, MapCfg.GUARD_SCALE)
	var f: Texture2D = k.sprite_frames.get_frame_texture("idle", 0)
	if f != null:
		k.offset = Vector2(0, -f.get_height() * 0.5)
	k.play("idle")
	# Over the grass like the outpost guards, who are decoration at the same depth.
	k.z_index = MapCfg.GUARD_Z
	world.add_child(k)
	return k


## Face him back down the road, toward his own station: that is the only side
## anyone reaches his wall from, because reaching the station is what opens it.
## The sheets' own direction is east, so a station west of him flips the sprite.
func _face(g: Dictionary, from: Vector2) -> void:
	var home: Vector2 = grid.anchors[_towers[int(g.st)]]
	(g.guard as AnimatedSprite2D).scale.x = MapCfg.GUARD_SCALE * (1.0 if home.x >= from.x else -1.0)


## Where opening the gate will send him: open ground beside his own station, on
## his own side of the wall if there is room for him there. Often there is not --
## a yard with an outpost, a road and a wall of rocks in it fills up fast, and
## island 2's is half sea besides -- so it widens to anywhere near the station,
## then to anywhere just off the gap. By then the gate is open and standing past
## it is no lie. Searched rather than authored, so retuning a gate or moving a
## station cannot strand him. Called once, from `_build_one()`.
func _guard_rest(g: Dictionary) -> Vector2:
	var home: Vector2 = grid.anchors[_towers[int(g.st)]]
	var post: Vector2 = g.post
	# An authored `rest` is asked for first, and the same question is put to it as
	# to anywhere else -- can he stand there. So it steers the search instead of
	# overriding it, and a spot that has since grown a boulder gives up the nearest
	# one that has not rather than planting him in the rubble.
	var want: Vector2 = g.rest
	if want != Vector2.ZERO:
		for c in MapGrid.rings(MapGrid.cell_at(post + want), int(MapCfg.GUARD_REST_RINGS[0])):
			var at := MapGrid.cell_mid(c)
			if _stands_clear(g, at):
				return at
	var inside := post.distance_to(home)
	for c in MapGrid.rings(MapGrid.cell_at(home), int(MapCfg.GUARD_REST_RINGS[1])):
		var at := MapGrid.cell_mid(c)
		if at.distance_to(home) <= inside and _stands_clear(g, at):
			return at
	for centre: Vector2 in [home, post]:
		for c in MapGrid.rings(MapGrid.cell_at(centre), int(MapCfg.GUARD_REST_RINGS[2])):
			var at := MapGrid.cell_mid(c)
			if _stands_clear(g, at):
				return at
	# Nothing open at all: at least get out of the gap.
	return post + (home - post).normalized() * MapCfg.GUARD_REST_FALLBACK


## Ground a man his size can stand on: nothing under him, nothing drawn over him.
## One box for all of it, because the question is the same each time -- "is he
## clear of that" -- and he is about two cells across and two high.
func _stands_clear(g: Dictionary, at: Vector2) -> bool:
	var c := MapGrid.cell_at(at)
	if not grid.is_walkable(at) or grid.trail.has(c):
		return false
	var body := Rect2(MapCfg.GUARD_BODY.position + at, MapCfg.GUARD_BODY.size)
	# The rubble gets his body plus a little below his feet: a boulder's wall is
	# the stone and stops above the cell it stands on, and the y-sort draws a
	# stone in the cell below him over his boots.
	if not MapGrid.clear_of(body.grow_individual(0.0, 0.0, 0.0, MapCfg.GUARD_FOOT_SLACK), g.rocks as Array):
		return false
	return grid.clear_of_signs(body) and grid.clear_of_buildings(body)


## Whatever the gate was waiting for has happened. The wall goes the moment it
## does, so the player can walk on while the guard is still moving -- and he walks,
## rather than fading out: the gate was a man, and a man who has let you past is
## still standing there.
func open(g: Dictionary) -> void:
	if bool(g.open):
		return
	g.open = true
	grid.solid.erase(g.wall as Rect2)
	var k: AnimatedSprite2D = g.guard
	if k == null or not is_instance_valid(k):
		return
	var to: Vector2 = g.stand
	# Facing the way he is about to go -- the sheets' own direction is east.
	k.scale.x = MapCfg.GUARD_SCALE * (1.0 if to.x >= k.position.x else -1.0)
	k.play("walk")
	var tw := k.create_tween()
	tw.tween_property(k, "position", to, MapCfg.GUARD_STEP_TIME).set_ease(Tween.EASE_IN_OUT)
	# Arriving, he turns back to face his station, which is where `_post_guard()`
	# leaves him on a restart. Without this the walk's own direction sticks, and
	# the same knight faced two ways depending on whether you saw him step aside.
	tw.tween_callback(func() -> void:
		if is_instance_valid(k):
			k.play("idle")
			_face(g, to))


## Called wherever progress is made: setup, and every overlay that closes.
func refresh() -> void:
	for g: Dictionary in list:
		if not bool(g.open) and _is_due(g):
			open(g)

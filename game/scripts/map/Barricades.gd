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
				# the shallows, for its wall: that wall covers the beach behind
				# it. The stone is drawn standing on that beach, at the wall's
				# foot, not out in the water (client: rocks in the sea).
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


## One boulder of the fence, and the loose stones at its foot. The wall is
## `rect` whatever happens to the stone; the stone is dressing, placed only
## where every pixel of it stands over land. On a north shore a stone at its
## cell hung out over the sea (it is drawn upward from its foot), so each is
## tried at its cell and then a little inland, and smaller; if none fits the
## wall stands bare -- only ever at the waterline, where the sea is the wall.
## Each cell rolls its own stone, size, flip and pebbles, off the cell, so
## every run lays the same fence.
func _lay_rock(g: Dictionary, c: Vector2i, rect: Rect2) -> void:
	(g.rocks as Array).append(rect)
	grid.block(rect)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(c) ^ MapCfg.FENCE_SEED
	var v := 1 + (posmod(c.x * 3 + c.y, MapCfg.ROCK_VARIANTS) + rng.randi_range(0, 1)) % MapCfg.ROCK_VARIANTS
	var k := MapCfg.ROCK_SCALE * rng.randf_range(0.85, 1.12)
	var flip := -1.0 if rng.randf() < 0.5 else 1.0
	var nudge := Vector2(rng.randf_range(-4.0, 4.0), rng.randf_range(-3.0, 2.0))
	var home := MapGrid.cell_mid(c)
	var base := Vector2.INF
	for shrink in [1.0, 0.8, 0.62]:
		for d: Vector2 in STONE_SHIFTS:
			var at := home + nudge + d
			if _on_land(_stone_art(v, k * shrink, flip, at)):
				base = at
				k *= shrink
				break
		if base != Vector2.INF:
			break
	if base == Vector2.INF:
		return
	var stone := Node2D.new()
	stone.position = base
	world.add_child(stone)
	var big := Art.sprite(stone, Art.tex(MapCfg.ROCK_SHEET % v), Vector2.ZERO, k, flip)
	big.name = "Stone"
	# A pebble or two at its foot now and then, to break the line -- on land too.
	for _i in (rng.randi_range(0, 2) if rng.randf() < 0.55 else 0):
		var pv := rng.randi_range(1, MapCfg.ROCK_VARIANTS)
		var pk := MapCfg.ROCK_SCALE * rng.randf_range(0.35, 0.5)
		var pf := -1.0 if rng.randf() < 0.5 else 1.0
		var off := Vector2(rng.randf_range(-20.0, 20.0), rng.randf_range(2.0, 8.0))
		if _on_land(_stone_art(pv, pk, pf, base + off)):
			Art.sprite(stone, Art.tex(MapCfg.ROCK_SHEET % pv), off, pk, pf)
	# Sorted where it blocks, like every prop: in front from the front and
	# sides, behind only from the back (Decor.sort_at).
	Decor.sort_at(stone, rect.position.y)


## Where a stone may go instead of its own cell, in order: a little either
## side, then inland (down the screen -- the art rises from its foot).
const STONE_SHIFTS := [Vector2(0, 0), Vector2(0, 8), Vector2(-8, 0), Vector2(8, 0),
	Vector2(0, 16), Vector2(-10, 10), Vector2(10, 10), Vector2(0, 24)]
## Each Rock sheet's drawn pixels in its 64px texture (x, y, w, h).
const ROCK_PIXELS := [Rect2(15, 25, 32, 26), Rect2(7, 17, 50, 36),
	Rect2(14, 23, 39, 29), Rect2(2, 14, 59, 42)]


## The world rect a base-anchored stone's pixels cover.
static func _stone_art(v: int, k: float, flip: float, base: Vector2) -> Rect2:
	var px: Rect2 = ROCK_PIXELS[v - 1]
	var x0 := (px.position.x - 32.0) * k
	var x1 := (px.end.x - 32.0) * k
	if flip < 0.0:
		var t := -x1
		x1 = -x0
		x0 = t
	return Rect2(base + Vector2(x0, (px.position.y - 64.0) * k), Vector2(x1 - x0, px.size.y * k))


## Every part of `r` over grass -- sampled every 6px, corners included.
func _on_land(r: Rect2) -> bool:
	var nx := maxi(1, ceili(r.size.x / 6.0))
	var ny := maxi(1, ceili(r.size.y / 6.0))
	for ix in nx + 1:
		for iy in ny + 1:
			var p := r.position + Vector2(r.size.x * ix / nx, r.size.y * iy / ny)
			if grid.grass.get_cell_source_id(MapGrid.cell_at(p)) == -1:
				return false
	return true


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
	# Round the rubble, not through it: a straight line from the gap to where
	# he rests crossed the fence, and he walked over the boulders (client).
	var path := walk_path(g, k.position, to)
	var total := 0.0
	var at := k.position
	for p in path:
		total += at.distance_to(p)
		at = p
	k.play("walk")
	var tw := k.create_tween()
	at = k.position
	for p in path:
		var leg := at.distance_to(p)
		var dir := p.x - at.x
		# Facing the way each leg goes -- the sheets' own direction is east.
		tw.tween_callback(func() -> void:
			if is_instance_valid(k) and absf(dir) > 1.0:
				k.scale.x = MapCfg.GUARD_SCALE * (1.0 if dir > 0.0 else -1.0))
		tw.tween_property(k, "position", p, MapCfg.GUARD_STEP_TIME * leg / maxf(total, 1.0))
		at = p
	# Arriving, he turns back to face his station, which is where `_post_guard()`
	# leaves him on a restart. Without this the walk's own direction sticks, and
	# the same knight faced two ways depending on whether you saw him step aside.
	tw.tween_callback(func() -> void:
		if is_instance_valid(k):
			k.play("idle")
			_face(g, to))


## The knight's way from the gap to where he rests, as points to walk through:
## the shortest run of cells whose ground his boots clear every boulder of,
## straightened wherever a straight line is just as clear. Ends at `to`.
func walk_path(g: Dictionary, from: Vector2, to: Vector2) -> Array[Vector2]:
	var boots := MapCfg.GUARD_BOOTS
	var stones := path_stones(g, from)
	var clear := func(p: Vector2) -> bool:
		return MapGrid.clear_of(Rect2(boots.position + p, boots.size), stones)
	var start := MapGrid.cell_at(from)
	var goal := MapGrid.cell_at(to)
	var came := {start: start}
	var queue: Array[Vector2i] = [start]
	var head := 0
	while head < queue.size() and not came.has(goal):
		var c := queue[head]
		head += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
				Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
			var n: Vector2i = c + d
			if came.has(n) or not grid.land.has(n) or absi(n.x - start.x) + absi(n.y - start.y) > 40:
				continue
			if n != goal and not clear.call(MapGrid.cell_mid(n)):
				continue
			came[n] = c
			queue.append(n)
	if not came.has(goal):
		return [to] as Array[Vector2]
	var cells: Array[Vector2i] = []
	var c := goal
	while c != start:
		cells.push_front(c)
		c = came[c]
	# Straighten: from each point, skip ahead to the farthest one in plain view.
	var pts: Array[Vector2] = []
	for cell in cells:
		pts.append(MapGrid.cell_mid(cell))
	pts[-1] = to
	var out: Array[Vector2] = []
	var here := from
	var i := 0
	while i < pts.size():
		var j := pts.size() - 1
		while j > i and not _line_clear(here, pts[j], clear):
			j -= 1
		out.append(pts[j])
		here = pts[j]
		i = j + 1
	return out


## The boulders his walk must not cross: all of them but the ones his boots
## already touch where he starts -- his post is set into the fence, and the
## stones either side of the gap are what he steps away from.
static func path_stones(g: Dictionary, from: Vector2) -> Array:
	var at := Rect2(MapCfg.GUARD_BOOTS.position + from, MapCfg.GUARD_BOOTS.size)
	return (g.rocks as Array).filter(func(r: Rect2) -> bool: return not r.intersects(at))


static func _line_clear(a: Vector2, b: Vector2, clear: Callable) -> bool:
	var steps := maxi(1, int(a.distance_to(b) / 8.0))
	for s in range(1, steps + 1):
		if not clear.call(a.lerp(b, float(s) / steps)):
			return false
	return true


## Called wherever progress is made: setup, and every overlay that closes.
func refresh() -> void:
	for g: Dictionary in list:
		if not bool(g.open) and _is_due(g):
			open(g)

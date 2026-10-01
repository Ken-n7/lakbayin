class_name Barricades
extends RefCounted

## The gates: a giant knight on each station's stair.
##
## Every station stands in a pocket of ground where its bridge lands, walled
## in by cliffs and the sea (map/Terrain.gd); one stair leads out, and the
## station's knight stands on it. One rule for all three -- **his own
## station's briefing stands him down** -- so a station is always on the near
## side of its own guard. He is a wall over the stair, not a trigger: what
## keeps the walk in order is the gating in `AdventureScreen`, not the man.

var world: Node2D
var grid: MapGrid

## One entry per station. See `_build_one()` for its shape.
var list: Array[Dictionary] = []

## Anchor index of each station's tower, handed in by `MapBuilder`: it is the
## station a guard steps aside toward, and the side he faces.
var _towers: Array = []
## The stations' outpost houses (Stations.houses), for a knight told to stand
## behind one.
var _houses: Array = []


func _init(w: Node2D, g: MapGrid) -> void:
	world = w
	grid = g


## One gate per station, on the stair `stairs[st]` holds ({top, foot, side},
## from Terrain), each posted in whatever state this run has already earned.
func build(towers: Array, stairs: Array, houses := []) -> void:
	list.clear()
	_towers = towers
	_houses = houses
	for st in stairs.size():
		var g := _build_one(st, stairs[st])
		list.append(g)
		_post_guard(g)


## He stands at the foot of the stair, facing down it; his wall is the whole
## ramp, so nobody climbs past him. When the gate opens he steps off to the
## side, into the pocket.
func _build_one(st: int, stair: Dictionary) -> Dictionary:
	var top: Vector2i = stair.top
	var t := float(MapCfg.TILE)
	var ramp := MapGrid.ramp_rect(top)
	var g := {
		"st": st,
		"post": Vector2(ramp.get_center().x, ramp.end.y - 2.0),
		"wall": ramp,
		"span": ramp,
		"rocks": [] as Array[Rect2],
		"stand": Vector2.ZERO,
		"guard": null,
		"open": false,
		"offset": Vector2.ZERO,
		"rest": Vector2.ZERO,
	}
	g.stand = _behind_house(g) if MapCfg.GUARD_REST_BEHIND_HOUSE[st] else Vector2.INF
	if g.stand == Vector2.INF:
		g.stand = _guard_rest(g)
	grid.keep_out(Rect2(g.post as Vector2, Vector2.ZERO).expand(g.stand as Vector2)
			.grow_individual(MapCfg.GUARD_CLEARING.x, MapCfg.GUARD_CLEARING.y,
					MapCfg.GUARD_CLEARING.z, MapCfg.GUARD_CLEARING.w))
	grid.keep_out(ramp.grow(t))
	return g


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
	# In the y-sort with everything else, so a house in front of him hides him.
	k.z_index = 0
	world.add_child(k)
	return k


## Face him back down the road, toward his own station: that is the only side
## anyone reaches his wall from, because reaching the station is what opens it.
## The sheets' own direction is east, so a station west of him flips the sprite.
func _face(g: Dictionary, from: Vector2) -> void:
	var home: Vector2 = grid.anchors[_towers[int(g.st)]]
	(g.guard as AnimatedSprite2D).scale.x = MapCfg.GUARD_SCALE * (1.0 if home.x >= from.x else -1.0)


## Behind his station's left-hand house: close to his stair, and the house
## stands in front of him -- he is drawn behind it by the y-sort, never over
## it. The nearest spot along the back of the house whose ground takes his
## boots; INF if there is none.
func _behind_house(g: Dictionary) -> Vector2:
	var st := int(g.st)
	if st >= _houses.size():
		return Vector2.INF
	for h: Dictionary in _houses[st]:
		if float(h.side) > 0.0:
			continue
		var at: Vector2 = h.at
		var back := at.y - float(h.bh) * MapCfg.HOUSE_WALL_FRAC - MapCfg.GUARD_BEHIND_GAP
		var best := Vector2.INF
		for k in range(-6, 7):
			var p := Vector2(at.x + k * 6.0, back)
			var boots := Rect2(MapCfg.GUARD_BOOTS.position + p, MapCfg.GUARD_BOOTS.size)
			var c := MapGrid.cell_at(p)
			if not grid.land.has(c) or grid.cliff.has(c) or grid.stairs.has(c) \
					or int(grid.height.get(c, -1)) != 0 or not MapGrid.clear_of(boots, grid.solid):
				continue
			if best == Vector2.INF or p.distance_to(g.post) < best.distance_to(g.post):
				best = p
		return best
	return Vector2.INF


## Where opening the gate sends him: the nearest open ground beside his
## stair, clear of it, in the pocket. Searched rather than authored, so moving a stair
## cannot strand him. Called once, from `_build_one()`.
func _guard_rest(g: Dictionary) -> Vector2:
	var post: Vector2 = g.post
	for c in MapGrid.rings(MapGrid.cell_at(post), int(MapCfg.GUARD_REST_RINGS[1])):
		var at := MapGrid.cell_mid(c)
		if _stands_clear(g, at):
			return at
	return post + Vector2(0, MapCfg.GUARD_REST_FALLBACK)


## Ground a man his size can stand on: nothing under him, nothing drawn over him.
## One box for all of it, because the question is the same each time -- "is he
## clear of that" -- and he is about two cells across and two high.
func _stands_clear(g: Dictionary, at: Vector2) -> bool:
	var c := MapGrid.cell_at(at)
	if not grid.is_walkable(at) or grid.trail.has(c):
		return false
	if int(grid.height.get(c, 0)) != 0 or grid.stairs.has(c):
		return false                                  # on the ground, off any stair
	var body := Rect2(MapCfg.GUARD_BODY.position + at, MapCfg.GUARD_BODY.size)
	# Off the stair and a cell clear of it, so he never stands in the way.
	if body.intersects((g.span as Rect2).grow(MapCfg.TILE)):
		return false
	# ...and every cell under him on the ground, not in a cliff face.
	for corner in [body.position, Vector2(body.end.x, body.position.y),
			Vector2(body.position.x, body.end.y), body.end]:
		var k := MapGrid.cell_at(corner)
		if not grid.land.has(k) or grid.cliff.has(k) or int(grid.height.get(k, -1)) != 0:
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


## The knight's way off the stairs to where he rests, as points to walk
## through: the shortest run of ground cells his boots clear every wall of,
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
			if came.has(n) or not grid.land.has(n) or grid.cliff.has(n) \
					or (int(grid.height.get(n, 0)) != 0 and not grid.stairs.has(n)) \
					or absi(n.x - start.x) + absi(n.y - start.y) > 40:
				continue
			if n != goal and not clear.call(MapGrid.cell_mid(n)):
				continue
			# No step may cross a wall: a diagonal cut a wall's corner, and a
			# straight one stepped over a stair's thin rail between two cells.
			if n != goal and not _line_clear(MapGrid.cell_mid(c), MapGrid.cell_mid(n), clear):
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


## The walls his walk must not cross: every one but those his boots already
## touch where he starts -- the stairs he is stepping off.
func path_stones(_g: Dictionary, from: Vector2) -> Array:
	var at := Rect2(MapCfg.GUARD_BOOTS.position + from, MapCfg.GUARD_BOOTS.size)
	return grid.solid.filter(func(r: Rect2) -> bool: return not r.intersects(at))


static func _line_clear(a: Vector2, b: Vector2, clear: Callable) -> bool:
	var steps := maxi(1, int(a.distance_to(b) / 2.0))
	for s in range(1, steps + 1):
		if not clear.call(a.lerp(b, float(s) / steps)):
			return false
	return true


## Called wherever progress is made: setup, and every overlay that closes.
## True if a knight stood aside just now (the screen plays his sound).
func refresh() -> bool:
	var any := false
	for g: Dictionary in list:
		if not bool(g.open) and _is_due(g):
			open(g)
			any = true
	return any

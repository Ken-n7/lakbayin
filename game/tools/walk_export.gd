extends Node

## Honest walks on real maps, for the server's movement check to be tried
## against: on each session's world, the hero walks from Bughaw's spawn to
## every monk and the door with the game's own movement (MapGrid.step, as
## AdventureScreen), sampled as the client samples it. One JSON line per
## session: {session, map (as map_export prints it), walks: [{to, reached,
## samples: [[t, x, y]]}]}. server/tests/test_server.py runs it.
##
##   godot --headless --path game res://tools/walk_export.tscn -- <session> ...

const DT := 1.0 / 60.0
const SAMPLE_S := 0.05           # AdventureScreen.SAMPLE_S
const LIMIT_S := 60.0


func _ready() -> void:
	var hero: Node2D = load(MapCfg.HERO_SCENE).instantiate()
	var shape: RectangleShape2D = hero.get_node("Foot/Box").shape
	var box := Rect2(hero.get_node("Foot/Box").position - shape.size * 0.5, shape.size)
	hero.free()
	for session in OS.get_cmdline_user_args():
		var w := MapWorld.new()
		w.seed = Game.seed_of(session)
		w.monk_count = 10
		add_child(w)
		w.build()
		var walks: Array = []
		var targets: Array[Vector2] = []
		for m in w.monks:
			targets.append(m.position + Vector2(0, 24))
		targets.append(w.door())
		for i in targets.size():
			walks.append(_walk(w.grid, box, w.spawn_of(0), targets[i]).merged({"to": i}))
		print(JSON.stringify({"session": session, "walks": walks}))
		w.free()
	get_tree().quit(0)


## The hero held toward each cell of the way in turn, one key at a time; a
## waypoint is passed on reaching its cell.
func _walk(grid: MapGrid, box: Rect2, from: Vector2, to: Vector2) -> Dictionary:
	var walls := {}
	for c: Vector2i in grid.land:
		if not grid.stairs.has(c) and not grid.box_walkable(MapGrid.cell_mid(c), box, int(grid.height.get(c, 0))):
			walls[c] = true
	var pos := from
	var level := grid.level_at(pos, 0)
	var way := grid.route(MapGrid.cell_at(pos), level, MapGrid.cell_at(to), walls)
	var samples: Array = [[0.0, pos.x, pos.y]]
	var t := 0.0
	var next := 1
	var clock := 0.0
	while t < LIMIT_S and next <= way.size():
		var aim: Vector2 = to if next == way.size() else MapGrid.cell_mid(way[next])
		if next < way.size() and MapGrid.cell_at(pos) == way[next]:
			next += 1
			continue
		if next == way.size() and pos.distance_to(to) < 4.0:
			break
		# The longer way first; held against something, the other -- as a
		# player edges along a rail or a trunk.
		var d := aim - pos
		var keys: Array[Vector2] = [Vector2(signf(d.x), 0), Vector2(0, signf(d.y))]
		if absf(d.y) > absf(d.x):
			keys.reverse()
		for dir in keys:
			if dir == Vector2.ZERO:
				continue
			var was := pos
			var step := dir * MapCfg.PLAYER_SPEED * DT
			var n := ceili(step.length() / 2.0)
			for _k in n:
				var got := grid.step(pos, step / n, box, level)
				pos = got[0]
				level = got[1]
			if pos != was:
				break
		t += DT
		clock += DT
		if clock >= SAMPLE_S:
			clock -= SAMPLE_S
			samples.append([snappedf(t, 0.001), snappedf(pos.x, 0.01), snappedf(pos.y, 0.01)])
	var stuck := {}
	if pos.distance_to(to) >= 12.0:
		var c := MapGrid.cell_at(pos)
		stuck = {"at": [pos.x, pos.y], "cell": [c.x, c.y], "level": level, "h": int(grid.height.get(c, -1)),
			"stair": grid.stairs.get(c, {}), "next": [way[mini(next, way.size() - 1)].x, way[mini(next, way.size() - 1)].y] if not way.is_empty() else [],
			"next_h": int(grid.height.get(way[mini(next, way.size() - 1)], -1)) if not way.is_empty() else -9,
			"next_stair": grid.stairs.get(way[mini(next, way.size() - 1)], {}) if not way.is_empty() else {}, "way": way.size()}
	return {"reached": pos.distance_to(to) < 12.0, "samples": samples, "stuck": stuck}

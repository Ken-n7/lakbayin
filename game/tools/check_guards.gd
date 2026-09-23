extends SceneTree

## Self-check for the station gates. Run it windowed -- building the board needs a
## real GL context, same as `map_shot.gd`:
##
##   godot --path game --script res://tools/check_guards.gd
##
## Two rules, and between them they cover what editing `BARRICADES`, `ISLANDS` or
## `TRAILS` can quietly break.
##
## **He has somewhere to stand.** A hand-placed `rest` that lands in the rubble drew
## him standing on the fence he had just opened; one that lands on the road puts him
## back in the player's way. `_stands_clear()` itself is no good after the fact -- a
## barricade reserves the ground between its post and its rest against the decor
## pass, and that box is exactly the one the knight is standing in -- so the facts
## that outlive the build get asked directly.
##
## **The fence gates the right way round.** A fence is an arc swung round its station
## out to land's end on both sides, so it only works while the station stands in a
## corner: move the station inland and both arms run on and on, the arc closes round
## the station instead of standing across the walk, and the gate ends up between the
## player and the briefing with the circles loose outside it. Walking the board is
## the only honest way to ask. So: open every earlier gate, flood the walkable ground
## from the base camp, and check this station's door is reachable while its own first
## circle is not.
##
## It reports and exits rather than asserting: a failed `assert` in `_initialize()`
## leaves the window up with the tree still running, and a check you have to go and
## kill is one nobody runs twice.

var _s: Control


func _initialize() -> void:
	_s = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(_s)
	_s.setup({})
	var bad := 0
	var towers: Array = _s._tower_anchors()
	for st in (_s._barricades as Array).size():
		var g: Dictionary = _s._barricades[st]
		var at: Vector2 = g.stand
		var name := "station %d" % (int(g.st) + 1)
		# His body plus a little below his boots, the same slack `_stands_clear()`
		# gives the rubble: the y-sort draws a stone in the cell below him over his
		# feet, which reads as standing in the wall even when he is a cell clear.
		var body := Rect2(MapCfg.GUARD_BODY.position + at, MapCfg.GUARD_BODY.size)
		var why := ""
		if not _s._clear_of(body.grow_individual(0.0, 0.0, 0.0, 24.0), g.rocks as Array):
			why = "rests on its own fence"
		elif _s._trail.has(_s._cell_at(at)):
			why = "rests on the road"
		elif not _s._is_walkable(at):
			why = "rests off the island"
		# Everything this station's own briefing has already earned is open; its gate
		# alone is shut, which is the board the moment the player walks up to it.
		for j in st:
			_s._solid.erase(_s._barricades[j].wall as Rect2)
		var seen := _flood()
		if not seen.has(_s._cell_at(_s._anchors[towers[st]])):
			why = "fences the player out of its own door"
		elif seen.has(_s._cell_at(_s._anchors[towers[st] + 1])):
			why = "leaves its first circle open"
		if why.is_empty():
			print("%s: post %s -> rest %s, gate holds" % [name, g.post, at])
			continue
		bad += 1
		printerr("%s %s: %s" % [name, why, at])
	if bad > 0:
		printerr("check_guards: %d of %d gates wrong"
				% [bad, (_s._barricades as Array).size()])
		quit(1)
		return
	print("check_guards: every knight has somewhere to stand, every gate holds")
	quit()


## Every cell you can walk to from the base camp, given whatever is in `_solid`.
func _flood() -> Dictionary:
	var start: Vector2i = _s._cell_at(_s._anchors[0])
	var seen := {start: true}
	var q: Array[Vector2i] = [start]
	while not q.is_empty():
		var c: Vector2i = q.pop_back()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if seen.has(n) or not _s._in_bounds(n) or not _s._is_walkable(_s._cell_mid(n)):
				continue
			seen[n] = true
			q.append(n)
	return seen

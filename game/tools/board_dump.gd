extends SceneTree

## Canonical text dump of the built Adventure board. Run:
##   godot --headless --path game --script res://tools/board_dump.gd -- <out file>
##
## The refactor oracle. Screenshots cannot serve: every unit is animating, so
## two runs of `map_shot.gd` differ by 0.002-1.7% of their pixels on animation
## phase alone, and a threshold loose enough to swallow that is loose enough to
## swallow a boulder moving a cell. This dumps the *derived board* instead --
## every anchor, wall, keep-out, guard post and planted prop -- sorted into a
## stable order and printed. Nothing here depends on frame timing: the dump is
## taken the instant `setup()` returns, before a single idle frame, so no tween
## has advanced and no sheep has wandered.
##
## Take one before a change and one after; `diff` them. They must be identical.

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path: String = args[0] if args.size() > 0 else "user://board_dump.txt"

	var G: Node = root.get_node("Game")
	var screen: Control = load("res://scripts/AdventureScreen.gd").new()
	root.add_child(screen)
	screen.setup({})

	var L: Array[String] = []

	L.append("# anchors")
	for k in screen.grid.anchors.size():
		L.append("anchor %02d %s" % [k, _v(screen.grid.anchors[k])])

	L.append("# stations")
	for i in screen.stations.nodes.size():
		var n: Node2D = screen.stations.nodes[i]
		L.append("station %d at %s wall %s" % [i, _v(n.position), _r(n.get_meta("wall"))])

	L.append("# circles")
	for i in screen._circles.size():
		var c = screen._circles[i]
		L.append("circle %02d at %s wall %s state %s" % [i, _v(c.position), _r(c.wall), c.state])

	L.append("# gate")
	L.append("gate at %s" % _v(screen.stations.gate.position))

	L.append("# barricades")
	for i in screen.barricades.list.size():
		var g: Dictionary = screen.barricades.list[i]
		for key in _sorted_keys(g):
			L.append("barricade %d %s = %s" % [i, key, _any(g[key])])

	L.append("# walls")
	for line in _sorted(screen.grid.solid.map(func(r): return _r(r))):
		L.append("wall %s" % line)

	L.append("# keep-outs")
	for line in _sorted(screen.grid.station_rects.map(func(r): return _r(r))):
		L.append("keepout %s" % line)
	for line in _sorted(screen.grid.sign_rects.map(func(r): return _r(r))):
		L.append("sign %s" % line)

	L.append("# cells")
	L.append("land %d %s" % [screen.grid.land.size(), _cells(screen.grid.land)])
	L.append("beach %d %s" % [screen.grid.beach.size(), _cells(screen.grid.beach)])
	L.append("trail %d %s" % [screen.grid.trail.size(), _cells(screen.grid.trail)])
	L.append("taken %d %s" % [screen.grid.taken.size(), _cells(screen.grid.taken)])
	L.append("island_of %d %s" % [screen.grid.island_of.size(), _cells(screen.grid.island_of)])

	L.append("# scene")
	var nodes: Array[String] = []
	_walk(screen.world, nodes)
	for line in _sorted(nodes):
		L.append("node %s" % line)

	L.append("# tiles")
	L.append("grass %s" % _tiles(screen.builder.grass))
	L.append("water %s" % _tiles(screen.builder.water))

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("cannot write ", out_path)
		quit(1)
		return
	f.store_string("\n".join(L) + "\n")
	f.close()
	print("wrote %s -- %d lines" % [out_path, L.size()])
	quit(0)


## Every node under `world`, as class + local transform + what it draws. Node
## *names* are deliberately not in the dump: Godot auto-numbers them from
## creation order, so reordering two `add_child()` calls that place identical
## art would show up as a diff when nothing on the board moved.
func _walk(n: Node, out: Array[String]) -> void:
	for c in n.get_children():
		if c is Node2D:
			var d: Node2D = c
			out.append("%s %s s%s z%d %s" % [
					d.get_class(), _v(d.position), _v(d.scale), d.z_index, _draws(d)])
		_walk(c, out)


func _draws(n: Node2D) -> String:
	if n is Sprite2D:
		return _tex((n as Sprite2D).texture)
	if n is AnimatedSprite2D:
		var a := n as AnimatedSprite2D
		var sf := a.sprite_frames
		if sf == null:
			return "anim:none"
		var names := Array(sf.get_animation_names())
		names.sort()
		return "anim:%s:%s" % [a.animation, "/".join(names)]
	return "-"


## An `Art.cell()` texture is an AtlasTexture with no resource path of its own,
## so report the sheet it was cut from plus the region.
func _tex(t: Texture2D) -> String:
	if t == null:
		return "tex:none"
	if t is AtlasTexture:
		var a := t as AtlasTexture
		return "tex:%s%s" % [a.atlas.resource_path if a.atlas else "?", _r(a.region)]
	return "tex:%s" % t.resource_path


func _tiles(l: TileMapLayer) -> String:
	if l == null:
		return "none"
	var cells := l.get_used_cells()
	var parts: Array[String] = []
	for c in cells:
		parts.append("%d,%d:%s" % [c.x, c.y, l.get_cell_atlas_coords(c)])
	parts.sort()
	return "%d %s" % [cells.size(), "|".join(parts).md5_text()]


## Cell dictionaries are dumped as a count plus a digest: 5000 land cells in
## full would bury every other line in the diff, and any single cell changing
## moves the digest.
func _cells(d: Dictionary) -> String:
	var parts: Array[String] = []
	for k in d:
		parts.append("%s=%s" % [k, d[k]])
	parts.sort()
	return "|".join(parts).md5_text()


func _sorted(a: Array) -> Array:
	var out: Array[String] = []
	for x in a:
		out.append(str(x))
	out.sort()
	return out


func _sorted_keys(d: Dictionary) -> Array:
	var k: Array[String] = []
	for x in d:
		k.append(str(x))
	k.sort()
	return k


## Floats are rounded to 3 decimals throughout. The board is built from
## trigonometry, and reassociating `a * b * c` during a move can shift the last
## bit of a float without moving anything a player could see.
func _any(x) -> String:
	if x is Vector2:
		return _v(x)
	if x is Rect2:
		return _r(x)
	if x is float:
		return "%.3f" % x
	if x is Array:
		return "[%s]" % ", ".join(x.map(func(y): return _any(y)))
	if x is Object:
		return (x as Object).get_class()
	return str(x)


func _v(p: Vector2) -> String:
	return "(%.3f,%.3f)" % [p.x, p.y]


func _r(r: Rect2) -> String:
	return "(%.3f,%.3f,%.3f,%.3f)" % [r.position.x, r.position.y, r.size.x, r.size.y]

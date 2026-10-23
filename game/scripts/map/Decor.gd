class_name Decor
extends RefCounted

## Everything growing on the islands, made solid. The trees, stumps and rocks
## are placed by `WorldGen`; `solidify()` turns every prop's collision boxes
## into walls on the grid.

var world: Node2D
var grid: MapGrid
## Every prop's solid rect, for `test_collisions`.
var feet: Array[Rect2] = []


func _init(w: Node2D, g: MapGrid) -> void:
	world = w
	grid = g


## Makes every prop under `props` solid, however the editor arranged them --
## loose, or in groups (a "forest" node), at any depth. A prop is any node
## with a StaticBody2D child (the prop scenes call theirs Foot): every
## rectangle or circle under its bodies becomes walls on the grid -- the
## trunk, a rock's body, not the canopy the hero walks under -- and the bodies
## are dropped: nothing here moves by physics, the grid is the only thing the
## hero bumps into. Every prop on land also takes its cell, as planting did.
## A group is made to Y-sort, so its trees still sort against the hero one by
## one rather than as a single block.
func solidify(props: Node, xf := Transform2D.IDENTITY) -> void:
	for prop: Node in props.get_children():
		if not (prop is Node2D):
			continue
		var here: Transform2D = xf * (prop as Node2D).transform
		var bodies: Array = prop.get_children().filter(func(c: Node) -> bool: return c is StaticBody2D)
		if bodies.is_empty():
			# A group of props, or a prop with no collision (loot, water rocks).
			if prop.get_child_count() > 0 and not (prop is Sprite2D or prop is AnimatedSprite2D):
				(prop as Node2D).y_sort_enabled = true
				solidify(prop, here)
			else:
				_take(here.origin)
			continue
		_take(here.origin)
		var top := INF
		for body: StaticBody2D in bodies:
			for shape_node in body.get_children():
				if not (shape_node is CollisionShape2D):
					continue
				var shape_xf: Transform2D = here * body.transform * (shape_node as Node2D).transform
				for r: Rect2 in _walls_of((shape_node as CollisionShape2D).shape, shape_xf):
					grid.block(r)
					feet.append(r)
					top = minf(top, r.position.y)
			body.free()
		# In its parent's space. ponytail: groups are moved, never scaled or
		# turned; a turned group would need the full inverse here.
		sort_at(prop as Node2D, top - xf.origin.y)


func _take(at: Vector2) -> void:
	var cell := MapGrid.cell_at(at)
	if grid.land.has(cell):
		grid.taken[cell] = true


## A collision shape as wall rectangles. A rectangle is itself; a circle is a
## stack of bands that follow its curve (the grid only knows rectangles).
static func _walls_of(shape: Shape2D, xf: Transform2D) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var k := xf.get_scale().abs()
	if shape is RectangleShape2D:
		var size := (shape as RectangleShape2D).size * k
		out.append(Rect2(xf.origin - size * 0.5, size))
	elif shape is CircleShape2D:
		var r := (shape as CircleShape2D).radius
		const BANDS := 5
		for i in BANDS:
			# Each band as wide as the circle at the band's middle.
			var y0 := -r + 2.0 * r * i / BANDS
			var mid := y0 + r / BANDS
			var half := sqrt(maxf(r * r - mid * mid, 0.0))
			out.append(Rect2(xf.origin + Vector2(-half, y0) * k, Vector2(half * 2.0, 2.0 * r / BANDS) * k))
	return out


## Draw order follows the box, not the art: a prop sorts at the TOP edge of
## its collision box. Anywhere the box stops the hero from the front or the
## sides, their feet are below that edge, so they are drawn in front; only
## north of the box -- behind it -- does the prop cover them, which is what
## gives it height. At the base, a rock with its box moved up its body drew
## over a hero it had just stopped from the front; at the box's bottom edge,
## over one standing beside it (client, both). The prop's origin moves to the
## edge and its children move back as much, so nothing on screen shifts.
## The barricades' boulders go through here too.
static func sort_at(prop: Node2D, edge: float) -> void:
	var dy := edge - prop.position.y
	if is_inf(dy) or absf(dy) < 0.5:
		return
	prop.position.y += dy
	for c in prop.get_children():
		if c is Node2D:
			(c as Node2D).position.y -= dy

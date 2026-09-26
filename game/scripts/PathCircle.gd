extends Node2D

## One stop on the board path: exactly one question item. Its tower is the same
## building as its own station's outpost keep (Blue_Tower / Yellow_Archery /
## Red_House1) -- native colors, no tint, per the client's call: three towers
## already exist in the pack in three different colors, use those.
##
## It stands lifted just off the path, the same trick `_tower_lift()` uses for
## the three station keeps, so its wall (the base only -- the roof stays
## walkable) doesn't cover the anchor point itself, which is where the player
## has to stand to interact. Nothing is drawn at that anchor: the tower is what
## you walk up to, and `AdventureScreen` pops a "!" over the player's head once
## the item is actually answerable.

const TOWER_SCALE := 0.5      # same scale as the real station buildings and the gate
const WALL_HEIGHT_FRAC := 0.45   # only the base blocks; the roof is walkable
## ...and only the stone base blocks across, not the crenellated top, which
## overhangs it. Full sprite width would make a tower on a vertical trail bend
## step 58px aside just to keep its own wall off its doorstep.
const WALL_WIDTH_FRAC := 0.62

var index := 0
var state := "locked"
var wall: Rect2   # local to this node; the caller offsets it by the anchor position

var _label: Label


## `lift` is local: where the tower building stands relative to the anchor
## point (this node's own position, which stays the interact spot). The
## building itself is parented to `world`, not to this node -- same reason
## `_make_station`/`_build_gate` do it, so the y-sort places it by where it
## actually stands rather than by the anchor it steps off of.
func setup(circle_index: int, building_path: String, lift: Vector2, world: Node2D) -> void:
	index = circle_index

	# Anchored at its base like every other building on the board: native art,
	# no modulate.
	var btex := Art.cell(building_path, 0, 0)
	var bsize := btex.region.size
	var spr := Sprite2D.new()
	spr.texture = btex
	spr.scale = Vector2(TOWER_SCALE, TOWER_SCALE)
	spr.offset = Vector2(0, -bsize.y * 0.5)
	spr.position = position + lift
	world.add_child(spr)

	var bh := bsize.y * TOWER_SCALE
	var hw := bsize.x * 0.5 * TOWER_SCALE * WALL_WIDTH_FRAC
	wall = Rect2(lift + Vector2(-hw, -bh * WALL_HEIGHT_FRAC), Vector2(hw * 2.0, bh * WALL_HEIGHT_FRAC))

	# The item number, floating above the roof. One constant color in every
	# state; it just disappears once the item is done.
	# Two sizes over the labels' 14 (client): it is read from across the map.
	_label = Art.label(str(index + 1), Pal.LABEL + 2, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	_label.position = Vector2(lift.x - 20.0, lift.y - bh - 26.0)
	_label.size = Vector2(40, 22)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Art.shadow(_label)
	add_child(_label)

	set_state("locked")


## Only "done" looks different -- it drops the number. Locked and current towers
## are deliberately identical; which one is yours is the number sequence, and the
## "!" over the player when you reach it.
func set_state(s: String) -> void:
	state = s
	_label.visible = s != "done"

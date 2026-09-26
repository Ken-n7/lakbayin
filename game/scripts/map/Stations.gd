class_name Stations
extends RefCounted

## The buildings: each station's keep with its two flanking houses and two idle
## door guards, the base camp, and the Victory Gate.
##
## Every sprite here is base-anchored and only the walls standing on the ground
## are solid -- the roof stays walkable so the player can pass behind it, which
## is what the y-sort expects.

var world: Node2D
var grid: MapGrid

## One per station, in order. The screen reads these for gating and targeting;
## `locks` is the station's title label, repainted as progress is made.
var nodes: Array = []
var locks: Array = []
## Per station, its outpost's houses: [{at, hw, bh, side}], side -1 the left.
var houses: Array = []
var gate: Node2D = null


func _init(w: Node2D, g: MapGrid) -> void:
	world = w
	grid = g


## A building sprite: cropped to its alpha bounding box, base-anchored, parented
## to the world. Every building PNG in the pack carries 20-60px of transparent
## padding, so an uncropped sprite hangs above the grass; and centring one sinks
## half its height into the ground and y-sorts it by its midpoint, which puts
## the hero in front of walls he should be behind.
##
## Returns `{node, hw, bh}` -- the half-width and full height of what was drawn,
## which is what every wall and keep-out box here is sized off.
func _building(path: String, at: Vector2) -> Dictionary:
	var tex := Art.cell(path, 0, 0)
	var size := tex.region.size
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.scale = Vector2(MapCfg.BUILDING_SCALE, MapCfg.BUILDING_SCALE)
	spr.position = at
	spr.offset = Vector2(0, -size.y * 0.5)
	world.add_child(spr)
	return {
		"node": spr,
		"hw": size.x * 0.5 * MapCfg.BUILDING_SCALE,
		"bh": size.y * MapCfg.BUILDING_SCALE,
	}


func build_camp(at: Vector2) -> void:
	Art.anim_sprite(world, MapCfg.CAMP_FIRE, at + MapCfg.CAMP_FIRE_OFFSET,
			MapCfg.CAMP_FIRE_SCALE, MapCfg.CAMP_FIRE_FPS)
	var l := Art.label("BASE CAMP", 14, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	l.position = at + Vector2(-70, -54)
	l.size = Vector2(140, 20)
	Art.shadow(l)
	world.add_child(l)
	grid.keep_out(Rect2(MapCfg.CAMP_KEEPOUT.position + at, MapCfg.CAMP_KEEPOUT.size))


## The end of the whole player flow: walking up and interacting ends the
## adventure and the summary opens (SPECS Q6). GATE_BUILDING (the castle) is
## the centerpiece, ribbon and label riding above its roof.
func build_gate(at: Vector2) -> void:
	gate = Node2D.new()
	gate.position = at
	world.add_child(gate)
	# Same crop-to-bbox, base-anchored pattern as `_make_station`'s tower sprite,
	# parented to `world` (not `gate`) so the y-sort places it by where it
	# actually stands rather than by the gate's own transform.
	var b := _building(MapCfg.GATE_BUILDING, at)
	var bh: float = b.bh
	# The whole three-piece banner (the HUD's `Ui.ribbon`), clear above the
	# roof. It used to be one `Art.cell` -- only the ribbon's left end, which
	# read as a stray red flag -- with small text laid over the roof tiles.
	var rib := Ui.ribbon(MapCfg.GATE_RIBBON_ROW, "Victory Gate", MapCfg.GATE_RIBBON_H, Pal.H2)
	rib.reset_size()
	rib.position = Vector2(-rib.size.x * 0.5, -bh - MapCfg.GATE_RIBBON_H - MapCfg.GATE_RIBBON_GAP)
	gate.add_child(rib)
	grid.keep_out(MapGrid.building_keepout(at, b.hw, bh))


## A station is a small outpost, not a lone building: its keep, two houses of the
## same livery, and a pair of idle guards. The signage is untouched -- `Station N`
## plus the topic line, the client's wording.
func build_keep(i: int, at: Vector2, _accent: String, lift := Vector2(0, -MapCfg.TOWER_LIFT)) -> void:
	var st := Node2D.new()
	st.position = at
	world.add_child(st)
	# `Art.cell(path, 0, 0)` crops to the alpha bounding box -- every building
	# PNG carries 20-60px of transparent padding, and an uncropped sprite would
	# hang above the grass. Anchored at its base like the decor.
	# Lifted off the path, so the y-sort places it by where it actually stands
	# rather than by the doorstep on the path.
	var b := _building(MapCfg.BUILDINGS[i], at + lift)
	var hw: float = b.hw
	var bh: float = b.bh
	# Only the walls standing on the ground, not the whole sprite: the roof is
	# walkable so the player can pass behind, which is what the y-sort expects.
	# `has_point` excludes the bottom edge, so the doorstep row the station node
	# sits on stays open and `INTERACT_RADIUS` is always reachable.
	var base := at + lift
	var wall := Rect2(base.x - hw, base.y - bh * MapCfg.WALL_HEIGHT_FRAC,
			hw * 2.0, bh * MapCfg.WALL_HEIGHT_FRAC)
	grid.block(wall)
	# The test reads the wall off the station itself: the outpost's houses append
	# walls too, so `grid.solid[i]` is no longer "station i".
	st.set_meta("wall", wall)
	_build_outpost(i, base, hw)
	grid.keep_out(MapGrid.building_keepout(base, hw, bh))
	# ...and off the signage below it, which is wider than any of the buildings
	# and was getting a tree planted through the middle of the topic line.
	# Signage over the doorway rather than over the roof. Above the roof the
	# castle's label sits 138px up, and since the camera centres on the player
	# it slides behind the HUD bar the moment you approach from the south.
	# World-space text, so size 14 is 28px on screen after the 2x upscale.
	# Over the doorstep on the path: above the lifted roof it is 200px up, which
	# is off-screen the moment the player stands on the path below it.
	#
	# A keep that stepped sideways rather than up is the exception: its houses sit
	# at the doorstep's own height and print themselves across the line. Below the
	# outpost is the clear ground there -- past the guards, who stand 30px down.
	var sign_y := MapCfg.SIGN_Y_UP if lift.y < 0.0 else MapCfg.SIGN_Y_DOWN
	var sign_box := Rect2(at + Vector2(-MapCfg.SIGN_BOX.x * 0.5, sign_y), MapCfg.SIGN_BOX)
	grid.keep_out(sign_box)
	grid.sign_rects.append(sign_box)
	var title := Art.label("Station %d" % (i + 1), 14, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	title.position = Vector2(-MapCfg.SIGN_BOX.x * 0.5, sign_y)
	title.size = Vector2(MapCfg.SIGN_BOX.x, 20)
	st.add_child(title)
	locks.append(title)
	var topic := Art.label(QuestionGen.station_meta(i).short, 11, Color(1, 1, 1, 0.92), HORIZONTAL_ALIGNMENT_CENTER)
	topic.position = Vector2(-MapCfg.SIGN_BOX.x * 0.5, sign_y + MapCfg.SIGN_LINE_GAP)
	topic.size = Vector2(MapCfg.SIGN_BOX.x, 16)
	st.add_child(topic)
	# Both sit over grass and roof, so they need the same shadow the map prompts
	# use to stay readable.
	for l in [title, topic]:
		Art.shadow(l)
	nodes.append(st)




func _build_outpost(i: int, base: Vector2, keep_hw: float) -> void:
	var col: String = MapCfg.LIVERY[i]
	var rng := RandomNumberGenerator.new()
	rng.seed = MapCfg.OUTPOST_SEED + i
	for side in [-1.0, 1.0]:
		var path := MapCfg.HOUSE_SHEET % [col, rng.randi_range(1, MapCfg.HOUSE_VARIANTS)]
		# Measured before it is placed: how far out it has to step depends on how
		# wide it is. `Art.cell` is cached, so `_building()` re-reading it is free.
		var size := Art.cell(path, 0, 0).region.size
		var hw := size.x * 0.5 * MapCfg.BUILDING_SCALE
		var bh := size.y * MapCfg.BUILDING_SCALE
		# A wide keep plus a house can reach the next circle 200px along, so the
		# house steps further out until its footprint is clear of every anchor --
		# and is dropped rather than built if the island never gives it room.
		var at := Vector2.ZERO
		var wall := Rect2()
		var ok := false
		for push: float in MapCfg.HOUSE_PUSH:
			at = base + Vector2(side * (keep_hw + hw + MapCfg.HOUSE_GAP + push), MapCfg.HOUSE_DROP)
			wall = Rect2(at.x - hw, at.y - bh * MapCfg.HOUSE_WALL_FRAC,
					hw * 2.0, bh * MapCfg.HOUSE_WALL_FRAC)
			if grid.clear_of_anchors(wall) and grid.land.has(MapGrid.cell_at(at)):
				ok = true
				break
		if not ok:
			continue
		_building(path, at)
		while houses.size() <= i:
			houses.append([])
		(houses[i] as Array).append({"at": at, "hw": hw, "bh": bh, "side": side})
		grid.block(wall)
		grid.keep_out(MapGrid.building_keepout(at, hw, bh))
	# Idle guards: the unit sheets are 8-frame strips with transparent gutters, so
	# `Art.anim_sprite` slices them the same way it slices the swaying trees.
	for n in MapCfg.DOOR_GUARDS.size():
		var dx := (keep_hw + MapCfg.DOOR_GUARD_GAP) * (-1.0 if n == 0 else 1.0)
		var g := Art.anim_sprite(world, MapCfg.UNIT_SHEET % [col, MapCfg.DOOR_GUARDS[n]],
				base + Vector2(dx, MapCfg.DOOR_GUARD_DROP),
				MapCfg.DOOR_GUARD_SCALE, MapCfg.DOOR_GUARD_FPS, signf(dx))
		g.z_index = MapCfg.GUARD_Z

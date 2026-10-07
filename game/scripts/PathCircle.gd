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
## The item number over each tower. World pixels, so at play zoom (0.95) this
## is about its own size on a 640x360 screen.
const NUMBER_SIZE := 32
## Every number floats, so the map reads as alive and the numbers catch the eye
## from across it: this far above and below its resting place, on a sine, so it
## eases at both ends. Slower than the hero's "!": forty of them.
const NUMBER_BOB := 4.0
const NUMBER_BOB_S := 2.0      # one full up-and-back
## The firefly round the number to answer next: how far it wanders from the
## number's middle, across and up-down (it loops wider than it is tall).
const FIREFLY_REACH := Vector2(28, 16)

var index := 0
var state := "locked"
var wall: Rect2   # local to this node; the caller offsets it by the anchor position

var _label: Label
var _label_y := 0.0
var _t := 0.0
## A gold glow wandering round the number, leaving sparkles; only while current.
var _firefly: Node2D
var _trail: CPUParticles2D
## 0 -> 1 as a firefly opens out from the number's middle into its loop, so one
## that just arrived (or just appeared) does not jump to the rim.
var _settle := 1.0
## Seconds the arriving firefly stays hidden: the one flying in is still on
## its way (firefly_arrives_in).
var _arrive_wait := 0.0
## Where the firefly was when this stopped being the current tower: the flight
## leaves from there (set_state() hides it before send_firefly() runs).
var _fly_from := Vector2.ZERO
## True while it crosses the board: refreshes leave it alone till it lands.
var _flying := false
## Its station's signs circling it until it is answered (TowerSymbols).
var symbols: TowerSymbols
## False until the board first says where this stop stands: a stop already
## done then -- a restored run -- just drops its signs; one done after is
## answered in front of the player, and its signs whirl off.
var _settled := false


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

	symbols = TowerSymbols.new()
	symbols.name = "Symbols"
	symbols.station = Game.station_of_item(index)
	symbols.position = lift + TowerSymbols.top_of(bh)
	add_child(symbols)

	# The item number, just over the roof: gold on the one to answer next,
	# cream on the rest, gone once done (set_state).
	# NUMBER_SIZE, not a UI size (client, twice): it is read from across the
	# map, and at play zoom the old 16 came out a sliver over the roof.
	_label = Art.label(str(index + 1), NUMBER_SIZE, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	# 24 over the top, sitting on the tower (client): at the bottom of its bob
	# the figure dips onto the roof's rim. The ring of signs reaches up into
	# it, so the label is added after them and they pass behind it.
	_label.position = Vector2(lift.x - 30.0, lift.y - bh - 24.0)
	_label_y = _label.position.y
	# Each tower its own place in the bob, from its index rather than instance
	# ids, so neighbours never float in step.
	_t = fmod(index * 0.37, 1.0) * NUMBER_BOB_S
	_label.size = Vector2(60, 40)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_color_override("font_outline_color", Color(0.1, 0.07, 0.05))
	_label.add_theme_constant_override("outline_size", 8)
	Art.shadow(_label, Color(0, 0, 0, 0.6), 2, 0)
	add_child(_label)
	_build_firefly()

	set_state("locked")
	_settled = false


## A soft gold glow with a bright core, and a trail of sparkles it leaves in
## the world (`local_coords` off) that fade from white-gold to nothing.
func _build_firefly() -> void:
	_firefly = Node2D.new()
	_firefly.name = "Firefly"
	_firefly.draw.connect(func() -> void:
		_firefly.draw_circle(Vector2.ZERO, 7.0, Color(Pal.GOLD, 0.22))
		_firefly.draw_circle(Vector2.ZERO, 4.0, Color(Pal.GOLD, 0.55))
		_firefly.draw_circle(Vector2.ZERO, 2.0, Color("fffbe6")))
	_trail = CPUParticles2D.new()
	_trail.local_coords = false
	_trail.show_behind_parent = true
	_trail.amount = 48
	_trail.lifetime = 1.1
	_trail.gravity = Vector2(0, 6)       # the sparkles settle a touch
	_trail.spread = 180.0
	_trail.initial_velocity_min = 2.0
	_trail.initial_velocity_max = 7.0
	_trail.scale_amount_min = 1.5
	_trail.scale_amount_max = 3.0
	var fade := Gradient.new()
	fade.set_color(0, Color("fffbe6"))
	fade.set_color(1, Color(Pal.GOLD, 0.0))
	fade.add_point(0.35, Pal.GOLD)
	_trail.color_ramp = fade
	_firefly.add_child(_trail)
	_firefly.visible = false
	add_child(_firefly)


## "current" -- the one to answer next -- has a gold number; locked ones cream;
## "done" drops the number.
func set_state(s: String) -> void:
	if s == "done" and state != "done" and is_instance_valid(symbols):
		if _settled:
			symbols.burst()
		else:
			symbols.queue_free()
	if s == "current" and state != "current":
		_settle = 0.0
	if state == "current" and s != "current":
		# Answered before its own firefly landed (skipped ahead) means it was
		# never placed: it leaves from the number rather than the doorstep.
		_fly_from = _firefly.position if _firefly.visible else _label.position + _label.size * 0.5
	state = s
	_settled = true
	_label.visible = s != "done"
	_label.add_theme_color_override("font_color", Pal.GOLD if s == "current" else Pal.CREAM)
	# A firefly in flight, or one waiting for it to land, is the flight's to
	# show: a refresh mid-way (Rescue opened and shut) must not cut it short.
	if not _flying and _arrive_wait <= 0.0:
		_firefly.visible = s == "current"
		_trail.emitting = s == "current"
	set_process(s != "done")


func _process(delta: float) -> void:
	_t += delta
	_label.position.y = _label_y + NUMBER_BOB * sin(TAU * _t / NUMBER_BOB_S)
	if _arrive_wait > 0.0:
		_arrive_wait -= delta
		if _arrive_wait <= 0.0:
			_firefly.visible = true
			_trail.emitting = true
			_settle = 0.0
	_settle = minf(_settle + delta / 0.6, 1.0)
	if _firefly.visible:
		# Two loops at unrelated speeds, so its path never quite repeats, plus
		# a quick small wobble: it drifts like a firefly, not a moon.
		var mid := _label.position + _label.size * 0.5
		_firefly.position = mid + smoothstep(0.0, 1.0, _settle) * Vector2(
			FIREFLY_REACH.x * sin(_t * 1.3) + 3.0 * sin(_t * 7.1),
			FIREFLY_REACH.y * sin(_t * 2.1 + 0.7) + 3.0 * cos(_t * 6.3))
		# Round the number, not just past it: over the top half of its loop it
		# is on the far side, so it goes behind the figure (still over the signs).
		var behind := _firefly.position.y < mid.y
		if behind != (_firefly.get_index() < _label.get_index()):
			move_child(_firefly, _label.get_index() if behind else get_child_count() - 1)


## The number's middle on the board, for a firefly flying in to aim at.
func number_mid() -> Vector2:
	return to_global(_label.position + _label.size * 0.5)


## Answered: the firefly leaves this number for the next tower's, in an arc
## over the board with its trail, fading as it lands. `to` INF means there is
## no next tower yet (a station still to enter, or the last circle): it flies
## up and fades. Returns how long the flight takes.
func send_firefly(to: Vector2) -> float:
	var from := _fly_from
	_arrive_wait = 0.0
	_flying = true
	var end := from + Vector2(0, -90) if to == Vector2.INF else to_local(to)
	var lift := 40.0 + from.distance_to(end) * 0.25
	var bend := (from + end) * 0.5 + Vector2(0, -lift)
	var secs := clampf(from.distance_to(end) / 260.0, 0.7, 1.6)
	_firefly.visible = true
	_trail.emitting = true
	_firefly.z_index = 1                 # over the board while it crosses it
	var tw := create_tween()
	tw.tween_method(func(k: float) -> void:
		_firefly.position = from.lerp(bend, k).lerp(bend.lerp(end, k), k),
		0.0, 1.0, secs).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.parallel().tween_property(_firefly, "modulate:a", 0.0, 0.3).set_delay(secs - 0.3)
	tw.tween_callback(func() -> void:
		_firefly.visible = false
		_trail.emitting = false
		_firefly.z_index = 0
		_firefly.modulate.a = 1.0
		_flying = false)
	return secs


## The firefly flying in from the tower just answered takes `secs` to land:
## this one stays hidden till then and opens out from the number's middle.
func firefly_arrives_in(secs: float) -> void:
	_firefly.visible = false
	_trail.emitting = false
	_arrive_wait = maxf(secs - 0.3, 0.01)

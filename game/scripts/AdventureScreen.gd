extends Control

## The Adventure Map: the client's board laid over a Tiny Swords island --
## base camp, Station 1, its circles, Station 2, its circles, Station 3, its circles,
## Victory Gate, all on one authored path. One circle is one question item, and
## they resolve strictly in order. WASD/arrows move the hero; E (or Space/Enter)
## enters the tower you stand at, answers the circle you stand on, or walks
## through the gate once all of Game.TOTAL_ITEMS are cleared.

const TILE := 32        # world px per cell; art is 64px drawn at 0.5
const SHEET_TILE := 64  # the tileset's own tile size

const TILEMAP_COLOR := "res://assets/terrain/tileset/Tilemap_color1.png"
const WATER_BG := "res://assets/terrain/tileset/Water Background color.png"

## Three islands over open water. The world is deliberately much larger than the
## 640x360 canvas -- the board needs room for forty circles to read as a walk
## rather than a dotted line. Tuning knobs, not fixed truths.
const W := 96
const H := 54

# The Super Retro World sheets are 16x20; scale picked by eye with DevTools'
# live [ / ] tuner (see `_unhandled_input`) against the tileset's 64px cells.
const UNIT_SCALE := 1.4
# Buildings are the tileset's own 64px art, so they take the tileset's scale.
const BUILDING_SCALE := 0.5
## Each station's keep -- one building per station, each its own kind, so the
## three stations do not read as the same outpost three times.
const BUILDINGS := [
	"res://assets/buildings/Blue_Monastery.png",
	"res://assets/buildings/Yellow_Archery.png",
	"res://assets/buildings/Red_Barracks.png",
]
## The walk-up towers on the circles. Every circle is a tower -- the keep is what
## tells the stations apart, the towers are what tell a stop from a keep -- so it
## is the same art in the station's own livery, no tint.
const CIRCLE_BUILDINGS := [
	"res://assets/buildings/Blue_Tower.png",
	"res://assets/buildings/Yellow_Tower.png",
	"res://assets/buildings/Red_Tower.png",
]
## The Victory Gate's building -- the only castle-scale asset in the red livery,
## and nothing else on the board is that big.
const GATE_BUILDING := "res://assets/buildings/Red_Castle.png"
const PLAYER_SPEED := 150.0
const INTERACT_RADIUS := 42.0
## Half a circle tower, near enough: every circle is the same tower, 92px tall
## drawn, so this reaches the whole body from its middle. Tap reach only -- walking
## up to a tower is still `INTERACT_RADIUS` against the anchor it stands beside.
const TOWER_TAP_REACH := 46.0

## Four islands, as normalized centre + radii. `wobble` only shifts the coastline
## noise so they do not come out as the same shape rotated. Island 0 is the camp,
## bottom right; island 1 beside it is the big one, carrying Station 1 and its
## eight circles. The walk runs right to left along the bottom, then up and back
## across the top: camp -> island 1 -> island 2 -> island 3 and the Victory Gate.
const ISLANDS := [
	{"c": Vector2(0.925, 0.800), "r": Vector2(0.058, 0.135), "wobble": 0.6},
	{"c": Vector2(0.415, 0.765), "r": Vector2(0.365, 0.225), "wobble": 1.7},
	{"c": Vector2(0.260, 0.270), "r": Vector2(0.215, 0.175), "wobble": 3.1},
	{"c": Vector2(0.740, 0.270), "r": Vector2(0.215, 0.175), "wobble": 5.3},
]

## One authored trail per island, in normalized world coords. Each is a serpentine
## that fills its island and ends near the causeway mouth, so the walk flows from
## one island into the next. `_stamp_path()` guarantees land under all of it.
const TRAILS := [
	# The camp: the fire, then Station 1. Its anchor is across the channel on
	# island 1 -- the trail runs over open water to get there, so `_stamp_path()`
	# lays the land bridge under the walk. The monastery itself stands on island
	# ground, well clear of the shore, which is the point of the crossing being
	# the trail's and not the building's problem.
	[Vector2(0.955, 0.855), Vector2(0.720, 0.800)],
	# Island 1: Station 1's eight circles, starting west of the boulder line that
	# `_build_barricade()` draws between them and the monastery.
	[Vector2(0.585, 0.780), Vector2(0.60, 0.90), Vector2(0.28, 0.92),
	 Vector2(0.10, 0.83), Vector2(0.16, 0.70), Vector2(0.33, 0.665),
	 Vector2(0.17, 0.635)],
	# Island 2, west to east. It used to land in the south-east and loop back on
	# itself to reach the seam, which left nowhere to put a gate: a line square
	# across that walk always stranded the last circle on the station's side of
	# it (checked every column), and the one cut that worked ran through a
	# circle's own doorstep. Landing in the south-west and running away east gives
	# the same shape island 1 has -- station, gate, circles -- and the seam to
	# island 3 is where the walk ends anyway.
	[Vector2(0.175, 0.355), Vector2(0.28, 0.185), Vector2(0.39, 0.29),
	 Vector2(0.45, 0.24)],
	[Vector2(0.60, 0.23), Vector2(0.75, 0.16), Vector2(0.89, 0.22),
	 Vector2(0.88, 0.34), Vector2(0.70, 0.38)],
]

## Each island gets its own dressing, so the stations do not read as the same field
## three times: a thin camp clearing, a wooded starter valley, a stony quarry, a
## bare highland. Cumulative thresholds for the one weighted roll in `_build_decor()`,
## and `count` is props, not patches -- since they arrive in clumps the counts are
## higher than they were when every roll dropped one prop on its own.
const ISLAND_PROPS := [
	{"tree": 0.55, "stump": 0.70, "rock": 0.88, "count": 14, "sheep": 1},
	{"tree": 0.60, "stump": 0.70, "rock": 0.86, "count": 140, "sheep": 3},
	{"tree": 0.22, "stump": 0.46, "rock": 0.90, "count": 70, "sheep": 1},
	{"tree": 0.08, "stump": 0.20, "rock": 0.80, "count": 60, "sheep": 0},
]

## Half-width of a causeway, in cells: 1 gives a three-tile crossing, wide enough
## to walk without the shoreline tiles pinching it shut.
const CAUSEWAY_HALF := 1

## Seams crossed by a **land bridge** rather than by a causeway that rises. Seam
## `i` is the water between island `i` and island `i + 1`. The walk simply carries
## on over it and `_stamp_path()` lays ground under the corridor, so the crossing
## is there from the first step -- and a gate holds it instead of the tide.
## Seam 0 (camp -> Station 1) falls out of trail 0, which spans it; seam 1 is
## stamped between trail 1's end and trail 2's start. Seam 2 is still a causeway.
const BRIDGED_SEAMS := [0, 1]

## The gates: a line of boulders across the walk with a giant guard in its one gap
## -- the same Warrior sheets `_build_outpost()` gives its little guards, at three
## times their 0.3 scale. A guard is a wall, not a trigger.
##
## One rule, every station: **his own station's briefing stands him down.** So the
## line always stands between that station's tower and its first circle -- walk up,
## take the briefing, and the way to the circles opens. `st` is the station (his
## livery too, and the tower he steps aside toward) and `t` how far along that
## stretch the line stands.
##
## What keeps the walk in order is not the guards, then, but `_can_enter_tower()`:
## a station only opens its briefing while the current item belongs to it. Reaching
## Station 2's door early gets you nothing but the view.
const BARRICADES := [
	{"st": 0, "t": 0.55},
	{"st": 1, "t": 0.55},
]
const GUARD_SCALE := 0.9
## A boulder line is laid cell by cell straight across the walk, land's end to
## land's end. Objects, not terrain -- the old three-tile neck had to be stamped
## because `_island_index()` gives a shore ten cells wide, and a line of rocks just
## plugs whatever is there. `BARRICADE_GAP` is the cells of it the guard fills,
## `ROCK_SCALE` picked by eye against the 32px grid with DevTools' live tuner.
const BARRICADE_GAP := 2
const ROCK_SCALE := 1.0

## Towers stand beside the path, not on it: their walls are up to 150px wide and
## would otherwise swallow the next circle along. `_tower_lift()` picks the side.
const TOWER_LIFT := 56.0
## A question circle's tower stands at its own doorstep, close enough that the
## glowing "answer here" ring reads as the tower's entrance. See `_circle_lift()`
## for why stepping sideways needs more room than stepping up.
const CIRCLE_LIFT := 26.0
const CIRCLE_SIDE_LIFT := 40.0
## How close the play camera sits. 1.0 is the crispest -- the art is never
## resampled -- but shows only a screenful of a world this size; 0.75 trades a
## little sharpness for a third more trail in view. Try both on the device.
const PLAY_ZOOM := 0.75

const DevTools := preload("res://scripts/DevTools.gd")

var main: Control

var world: Node2D
var grass_layer: TileMapLayer
var water_layer: TileMapLayer
var player: Node2D

var _land := {}       # Vector2i -> true
var _beach := {}      # Vector2i -> true
var _island_of := {}  # Vector2i -> island index, for the per-island props pass
var _trail := {}      # Vector2i -> true, the road corridor: decor keeps off it
var _taken := {}      # Vector2i -> true, cells a prop already stands on
var _causeways: Array = []   # [{cells, open, props, sign}] -- one per island seam
var _solid: Array[Rect2] = []  # building base walls, in world px
var _barricades: Array[Dictionary] = []  # one per BARRICADES entry; see `_build_barricade()`
var _station_nodes: Array = []
var _station_locks: Array = []
var _circles: Array = []        # Game.TOTAL_ITEMS PathCircle nodes, path order
var _anchors: Array = []        # base camp, 3 towers, Game.TOTAL_ITEMS circles, gate -- in walk order
var _gate: Node2D = null
var _cam: Camera2D
var _prompt: Label
var _bang: Label = null         # the "!" over the hero when something is in reach
var _hud_gems: Label
var _hud_time: Label
var _hud_station: Label
var _hud_pips: Label
var _gem_bar: ProgressBar
var _hud_layer: CanvasLayer
var _ui_layer: CanvasLayer

var _touch_pad: Node2D = null
var _joystick: Node2D = null
var _overlay: Control = null
var _paused := false
var _flash_active := false
var _frozen := false            # the aerial POV before the adventure starts
var _intro_tw: Tween = null
var _start_hint: Label = null   # "Tap anywhere to start" -- freed once it does
var _card: Control = null       # the tapped circle's info card
var _hint_bar: Label = null     # the controls crib, hidden while the board is frozen
var _dev: Control = null        # the cheat drawer, on debug builds only
## Dev knobs the drawer drives: a walk-speed multiplier, and the flag that stops
## `_process()` dragging the camera back to the hero while the board is framed.
var _speed_mult := 1.0
var _dev_aerial := false
var _hero_scale := UNIT_SCALE   # live-tunable via [ / ], DevTools.key_step()


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# A bare Control defaults to MOUSE_FILTER_STOP, which swallows every click or
	# tap right here as "handled" before _unhandled_input ever sees it -- taps on
	# the board (start, circle cards) would silently do nothing. The HUD buttons
	# and panels are their own Controls with their own filters, unaffected by this.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_hud()
	if not Game.adventure_active:
		Game.begin_adventure()
	world = Node2D.new()
	add_child(world)
	world.y_sort_enabled = true
	_anchors = _path_anchors()
	_build_terrain()
	_build_island()
	_build_path()
	_dress_causeways()
	_build_decor()
	_spawn_player()
	Game.time_changed.connect(_on_time)
	Game.gems_changed.connect(_on_gems)
	Game.adventure_ended.connect(_on_adventure_end)
	_refresh_hud()
	_refresh_circles()
	# A restart mid-run keeps whatever it had already opened.
	_refresh_causeways()
	_refresh_barricades()
	_start_intro()


func _exit_tree() -> void:
	# Only if THIS screen was the one holding the freeze. `Main.open()` frees the
	# old screen with `queue_free()` (deferred), so on a Restart this runs after
	# the new screen's `setup()` already set clock_paused = true for its own
	# fresh intro -- an unconditional clear here would clobber that.
	if _frozen:
		Game.clock_paused = false
	Game.time_changed.disconnect(_on_time)
	Game.gems_changed.disconnect(_on_gems)
	Game.adventure_ended.disconnect(_on_adventure_end)


# --- Terrain ----------------------------------------------------------------
## Tiles keep their native 64px size and the layer is scaled down instead, so
## one cell is TILE world px. At the 2x viewport upscale that lands 1:1 on
## screen -- the art is never resampled.
static func _make_layer(tex_path: String, coords: Array = []) -> TileMapLayer:
	var region := Vector2i(SHEET_TILE, SHEET_TILE)
	var src := TileSetAtlasSource.new()
	src.texture = Art.tex(tex_path)
	src.texture_region_size = region
	if coords.is_empty():
		var cols := int(Art.tex(tex_path).get_width() / region.x)
		var rows := int(Art.tex(tex_path).get_height() / region.y)
		for ty in rows:
			for tx in cols:
				src.create_tile(Vector2i(tx, ty))
	else:
		for c in coords:
			src.create_tile(c)
	var ts := TileSet.new()
	ts.tile_size = region
	ts.add_source(src, 0)
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	layer.scale = Vector2.ONE * (float(TILE) / float(SHEET_TILE))
	return layer


## Tilemap_color1.png is a 16-state match-sides autotile set: the column is
## chosen by the left/right neighbours and the row by top/bottom. Derived by
## probing each tile's edges -- see the plan's mapping table.
##   c0 R-only  c1 R+L  c2 L-only  c3 neither
##   r0 B-only  r1 T+B  r2 T-only  r3 neither
static func _autotile(left: bool, right: bool, up: bool, down: bool, cliff := false) -> Vector2i:
	var col := 0 if (right and not left) else (1 if (right and left) else (2 if left else 3))
	var row := 0 if (down and not up) else (1 if (up and down) else (2 if up else 3))
	return Vector2i(col + (5 if cliff else 0), row)


func _build_terrain() -> void:
	water_layer = _make_layer(WATER_BG, [Vector2i(0, 0)])
	world.add_child(water_layer)
	for gy in H:
		for gx in W:
			water_layer.set_cell(Vector2i(gx, gy), 0, Vector2i(0, 0))
	grass_layer = _make_layer(TILEMAP_COLOR)
	world.add_child(grass_layer)
	world.set_meta("grass", grass_layer)
	world.set_meta("tile", TILE)


# --- Island shapes ----------------------------------------------------------
## Normalized map coords to world px, and back to a cell.
static func _norm(p: Vector2) -> Vector2:
	return Vector2(p.x * W * TILE, p.y * H * TILE)


static func _cell_at(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / TILE), floori(pos.y / TILE))


static func _cell_mid(c: Vector2i) -> Vector2:
	return Vector2(c.x * TILE + TILE / 2, c.y * TILE + TILE / 2)


static func _in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < W and c.y < H


## Which island a cell belongs to, or -1 for open water. The radial wobble is what
## keeps the coastlines ragged -- a bare ellipse reads as a pond, not an island.
func _island_index(cell: Vector2i) -> int:
	var px := (float(cell.x) + 0.5) / float(W)
	var py := (float(cell.y) + 0.5) / float(H)
	for i in ISLANDS.size():
		var isl: Dictionary = ISLANDS[i]
		var c: Vector2 = isl.c
		var r: Vector2 = isl.r
		var dx := (px - c.x) / r.x
		var dy := (py - c.y) / r.y
		var d := sqrt(dx * dx + dy * dy)
		if d > 1.3:
			continue
		var ang := atan2(dy, dx)
		if d < 0.86 + 0.11 * sin(ang * 3.0 + float(isl.wobble)) + 0.06 * cos(ang * 5.0 + 0.4):
			return i
	return -1


func _build_island() -> void:
	for y in H:
		for x in W:
			var cell := Vector2i(x, y)
			var i := _island_index(cell)
			if i >= 0:
				_land[cell] = true
				_island_of[cell] = i
	_stamp_path()
	_causeways = _find_causeways()
	_retile(_land.keys())


## Paint (or erase) a set of cells and their four neighbours from the current land
## set. Runs over the whole island at build time, and over one causeway's cells
## when it rises -- the shoreline either side of the new ground has to be repainted
## or the foam still says "water here".
func _retile(cells: Array) -> void:
	var todo := {}
	for c in cells:
		todo[c] = true
		for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
			if _in_bounds(c + d):
				todo[c + d] = true
	for c in todo:
		if not _land.has(c):
			grass_layer.erase_cell(c)
			_beach.erase(c)
			continue
		var up: bool = _land.has(c + Vector2i(0, -1))
		var down: bool = _land.has(c + Vector2i(0, 1))
		var left: bool = _land.has(c + Vector2i(-1, 0))
		var right: bool = _land.has(c + Vector2i(1, 0))
		if up and down and left and right:
			_beach.erase(c)
		else:
			_beach[c] = true
		# Cols 0-3 are the foam-outlined land-meets-water set, so the shoreline
		# is baked into the tile itself and reads the same on all four sides.
		grass_layer.set_cell(c, 0, _autotile(left, right, up, down))


# --- Causeways: the gate between stations -----------------------------------
## Each causeway is the stretch of water along the line between two island
## centres: the shortest crossing, and the only one, because everything either
## side of it is sea -- one boulder on open ground can be walked around, a channel
## cannot, so the sequential rule is enforced by the geography rather than by a
## flag the player never sees. (A whole LINE of boulders, land's end to land's end,
## cannot be walked around either: that is what `_build_barricade()` lays down, and
## is what holds the bridged seams, where there is no channel to use.)
##
## `BRIDGED_SEAMS` are skipped -- those crossings are land bridges `_stamp_path()`
## lays under the walk, held by a gate. Without the skip this would lay a second
## crossing alongside each bridge, along the line between the two island centres.
## Each entry carries its own `seam`, so the rest of the file stays right however
## many are skipped: seam `i` leads into island `i + 1`, and rises when station
## `i - 1` runs out of circles.
func _find_causeways() -> Array:
	var out: Array = []
	for i in range(ISLANDS.size() - 1):
		if BRIDGED_SEAMS.has(i):
			continue
		var a := _norm(ISLANDS[i].c)
		var b := _norm(ISLANDS[i + 1].c)
		var perp := (b - a).normalized().orthogonal()
		var steps := maxi(int(a.distance_to(b) / (TILE * 0.5)), 1)
		var cells: Array[Vector2i] = []
		for k in steps + 1:
			var p := a.lerp(b, float(k) / float(steps))
			if _land.has(_cell_at(p)):
				continue
			for wi in range(-CAUSEWAY_HALF, CAUSEWAY_HALF + 1):
				var cc := _cell_at(p + perp * (float(wi) * TILE))
				if _in_bounds(cc) and not _land.has(cc) and not cells.has(cc):
					cells.append(cc)
		out.append({"seam": i, "cells": cells, "open": false, "props": [], "sign": null})
	return out


## Stones just under the surface plus a sign on the near shore: the crossing is
## visible, and named, long before it is walkable.
func _dress_causeways() -> void:
	for i in _causeways.size():
		var cw: Dictionary = _causeways[i]
		if cw.cells.is_empty():
			continue
		for k in cw.cells.size():
			if k % 3 != 0:
				continue
			var spr := Art.anim_sprite(world,
					"res://assets/terrain/decorations/Water Rocks_0%d.png" % (1 + k % 4),
					_cell_mid(cw.cells[k]), 1.1, 4.0)
			spr.modulate = Color(0.75, 0.85, 0.95, 0.75)
			cw.props.append(spr)
		var l := Art.label("Clear Station %d to raise the causeway" % int(cw.seam), 13,
				Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
		# High over the crossing, not just off the shore, and drawn over the
		# buildings rather than y-sorted behind them: a tower standing near a
		# causeway mouth otherwise prints its own signage across this line.
		l.position = _cell_mid(cw.cells[0]) + Vector2(-170, -96)
		l.size = Vector2(340, 20)
		l.z_index = 3
		Art.shadow(l)
		world.add_child(l)
		cw.sign = l


## A causeway on seam `s` leads to station `s`, so it rises the moment station
## `s - 1` has no circles left. Called after every resolved item.
func _refresh_causeways() -> void:
	for i in _causeways.size():
		var cw: Dictionary = _causeways[i]
		if not bool(cw.open) and Game.items_done >= _items_through(int(cw.seam) - 1):
			open_causeway(i)


## Circles resolved by the time station `st` is finished -- the same running total
## `_tower_anchors()` walks.
static func _items_through(st: int) -> int:
	var n := 0
	for i in st + 1:
		n += Game.ITEMS_PER_STATION[i]
	return n


func open_causeway(i: int) -> void:
	var cw: Dictionary = _causeways[i]
	if bool(cw.open):
		return
	cw.open = true
	for c in cw.cells:
		_land[c] = true
		# It belongs to the island it leads to, so that island's props keep off it.
		_island_of[c] = int(cw.seam) + 1
	_retile(cw.cells)
	# The same stones, now dry: what rises reads as a stone causeway rather than
	# grass climbing out of the sea.
	for pr in cw.props:
		if is_instance_valid(pr):
			create_tween().tween_property(pr, "modulate", Color.WHITE, 0.5)
	if cw.sign != null and is_instance_valid(cw.sign):
		(cw.sign as Node).queue_free()
		cw.sign = null
	if not cw.cells.is_empty():
		var mid := _cell_mid(cw.cells[cw.cells.size() / 2])
		var puff := Art.anim_sprite(world, "res://assets/fx/Dust_01.png", mid, 1.2, 12.0)
		# The dust sheet loops, so it has to be told when to stop being dust.
		var done := create_tween()
		done.tween_interval(0.9)
		done.tween_callback(puff.queue_free)
	_flash_tip("The causeway rises! Cross to Station %d." % (int(cw.seam) + 1))


func _is_walkable(pos: Vector2) -> bool:
	for r in _solid:
		if r.has_point(pos):
			return false
	var cell := Vector2i(floori(pos.x / TILE), floori(pos.y / TILE))
	return grass_layer.get_cell_source_id(cell) != -1


## Nearest land walking inward from a normalized spot, for props that must not
## end up in the sea.
func _first_land(nx: float, ny: float, toward: Vector2) -> Vector2:
	for tries in 60:
		var c := Vector2i(floori(nx * W), floori(ny * H))
		if _land.has(c):
			return _cell_mid(c)
		nx = lerpf(nx, toward.x, 0.1)
		ny = lerpf(ny, toward.y, 0.1)
	return _norm(ISLANDS[0].c)


# --- The trails -------------------------------------------------------------
## How many stops each TRAIL carries -- not each island. The camp's trail holds the
## base camp and Station 1, whose briefing raises the causeway out of camp; the
## crossing between them is the land bridge, so the trail spans two islands and
## Station 1 stands on island 1's ground. Trail `i` then holds station `i - 1`'s
## circles, and stations 2 and 3 keep their own towers. The last one also holds the
## Victory Gate.
##
## Flattened, that is still the same walk order it always was:
## camp, S1, its circles, S2, its circles, S3, its circles, gate.
func _stops_on(i: int) -> int:
	if i == 0:
		return 2                                  # base camp, then Station 1
	var n: int = int(Game.ITEMS_PER_STATION[i - 1])
	if i > 1:
		n += 1                                    # that station's own tower
	if i == TRAILS.size() - 1:
		n += 1                                    # victory gate
	return n


## `stops` points spaced evenly by arc length along a normalized polyline, both
## ends included.
static func _space_along(way: Array, stops: int) -> Array:
	var pts: Array[Vector2] = []
	for p in way:
		pts.append(_norm(p))
	var segs: Array[float] = []
	var total := 0.0
	for i in pts.size() - 1:
		var d := pts[i].distance_to(pts[i + 1])
		segs.append(d)
		total += d
	var out: Array = []
	for k in stops:
		var want := total * float(k) / float(maxi(stops - 1, 1))
		var acc := 0.0
		var at: Vector2 = pts[pts.size() - 1]
		for i in segs.size():
			if want <= acc + segs[i] or i == segs.size() - 1:
				at = pts[i].lerp(pts[i + 1], clampf((want - acc) / segs[i], 0.0, 1.0))
				break
			acc += segs[i]
		out.append(at)
	return out


## Every stop on the board, flat, in the global walk order the rest of the file
## indexes by: base camp, Station 1, its circles, Station 2, its circles, Station
## 3, its circles, Victory Gate -- spread over three islands instead of one
## serpentine. The spacing that matters is ~270px at the tightest, far wider than
## INTERACT_RADIUS, which is what keeps "the circle you are standing on"
## unambiguous.
func _path_anchors() -> Array:
	var out: Array = []
	for i in TRAILS.size():
		out.append_array(_space_along(TRAILS[i], _stops_on(i)))
	return out


## Which TRAIL a stop belongs to. Indexed by anchor rather than by station, because
## Station 1 rides the camp's trail while its circles ride island 1's. Everything
## that needs "outward from my own island" asks this; for Station 1 that means the
## camp's centre, which is the right answer -- it is the stop nearest the camp.
func _island_of_anchor(k: int) -> int:
	var seen := 0
	for i in TRAILS.size():
		seen += _stops_on(i)
		if k < seen:
			return i
	return TRAILS.size() - 1


## Anchor index of each tower: one before each station's run of circles.
func _tower_anchors() -> Array:
	var out: Array = []
	var k := 1                       # anchor 0 is the base camp
	for st in 3:
		out.append(k)
		k += 1 + Game.ITEMS_PER_STATION[st]
	return out


## Which way the building steps off the path: straight up on a lane, outward when
## the anchor sits on a bend. It has to be perpendicular to the walk, or the wall
## covers the next circle -- and its footprint is axis-aligned, so on a vertical
## bend "up" would put the wall right across the path.
func _tower_lift(k: int) -> Vector2:
	var a: Vector2 = _anchors[maxi(k - 1, 0)]
	var b: Vector2 = _anchors[mini(k + 1, _anchors.size() - 1)]
	var dir := (b - a).normalized()
	if absf(dir.x) >= absf(dir.y):
		return Vector2(0, -TOWER_LIFT)
	# Outward from its own island's centre -- against the world centre it would
	# step the middle island's tower into the sea.
	var mid := _norm(ISLANDS[_island_of_anchor(k)].c)
	return Vector2(signf(_anchors[k].x - mid.x) * TOWER_LIFT, 0)


## Same direction logic for a question circle's tower, but much closer in: the
## player stands on the anchor to answer, so a full TOWER_LIFT leaves the glowing
## spot stranded half a tower away from the door it belongs to.
##
## The two magnitudes differ because the wall is axis-aligned. Stepping *up* only
## has to clear the anchor vertically, and the wall sits above it at any positive
## lift. Stepping *sideways* has to clear it horizontally, so the lift has to beat
## the widest circle building's wall half-width (Yellow_Archery, 28px once
## `PathCircle.WALL_WIDTH_FRAC` trims it to the base) or the wall reaches back
## over the doorstep.
func _circle_lift(k: int) -> Vector2:
	var a: Vector2 = _anchors[maxi(k - 1, 0)]
	var b: Vector2 = _anchors[mini(k + 1, _anchors.size() - 1)]
	var dir := (b - a).normalized()
	if absf(dir.x) >= absf(dir.y):
		return Vector2(0, -CIRCLE_LIFT)
	var mid := _norm(ISLANDS[_island_of_anchor(k)].c)
	return Vector2(signf(_anchors[k].x - mid.x) * CIRCLE_SIDE_LIFT, 0)


## The path is authored, the island is generated, so the two can disagree: force
## land under the whole walk (three cells wide) before the autotile pass paints
## the shoreline, and the board is never cut by a stray inlet.
func _stamp_path() -> void:
	for t in TRAILS.size():
		var way: Array = TRAILS[t]
		_stamp_way(way, t, true)
		if t + 1 >= TRAILS.size():
			continue
		# The hop on to the next trail is walk as well, so it is road for the decor
		# pass either way. It is only *ground* where that seam is bridged -- on an
		# unbridged one the causeway is what rises there later, and stamping would
		# hand the player the crossing for free.
		var next: Array = TRAILS[t + 1]
		_stamp_way([way[way.size() - 1], next[0]], t + 1, BRIDGED_SEAMS.has(t))
	# The towers step off the path, so their ground has to be stamped as well or
	# one ends up standing in the shallows at a bend.
	_stamp_towers()


## Land (three cells wide) under a polyline, and the corridor recorded in `_trail`
## either way: `_build_decor()` plants nothing in it, which is what makes the walk
## read as a road through the trees rather than a line of towers lost in them.
func _stamp_way(way: Array, isl: int, ground: bool) -> void:
	for i in way.size() - 1:
		var a := _norm(way[i])
		var b := _norm(way[i + 1])
		var steps := maxi(int(a.distance_to(b) / (TILE * 0.5)), 1)
		for k in steps + 1:
			var pos := a.lerp(b, float(k) / float(steps))
			var c := _cell_at(pos)
			for oy in [-1, 0, 1]:
				for ox in [-1, 0, 1]:
					var cc := c + Vector2i(ox, oy)
					if not _in_bounds(cc):
						continue
					_trail[cc] = true
					if not ground:
						continue
					# Only ground the walk invents belongs to the walk: the camp
					# trail crosses island 1's east spit to reach Station 1, and
					# relabelling those cells island 0 would dress the spit with
					# the camp's props.
					if not _land.has(cc):
						_island_of[cc] = isl
					_land[cc] = true


func _stamp_towers() -> void:
	for k in _tower_anchors():
		var base: Vector2 = _anchors[k] + _tower_lift(k)
		var bc := _cell_at(base)
		var isl := _island_of_anchor(k)
		for oy in range(-2, 2):
			for ox in range(-2, 3):
				var cc := bc + Vector2i(ox, oy)
				if _in_bounds(cc):
					if not _land.has(cc):
						_island_of[cc] = isl
					_land[cc] = true


func _build_path() -> void:
	var PathCircle := preload("res://scripts/PathCircle.gd")
	var k := 1                       # anchor 0 is the base camp
	for st in 3:
		var meta := QuestionGen.station_meta(st)
		_make_station(st, _anchors[k], meta.accent, _tower_lift(k))
		k += 1
		# Every circle is a tower in its station's livery -- native colors, no
		# tint -- so size the decor keep-out box off it too.
		var building: String = CIRCLE_BUILDINGS[st]
		var ctex := Art.cell(building, 0, 0)
		var chw := ctex.region.size.x * 0.5 * PathCircle.TOWER_SCALE
		var cbh := ctex.region.size.y * PathCircle.TOWER_SCALE
		for _i in Game.ITEMS_PER_STATION[st]:
			var c: Node2D = PathCircle.new()
			c.position = _anchors[k]
			world.add_child(c)
			var lift := _circle_lift(k)
			c.setup(_circles.size(), building, lift, world)
			# The middle of the drawn building, for anything aiming at what the
			# player can see rather than at the anchor it steps off of. Same
			# `set_meta` channel `_make_station` uses for its wall.
			c.set_meta("tower_mid", _anchors[k] + lift - Vector2(0, cbh * 0.5))
			_circles.append(c)
			# The wall PathCircle computed is local to the anchor; place it in
			# world space and keep decor off the lifted tower's real footprint.
			var w: Rect2 = c.wall
			w.position += _anchors[k]
			_solid.append(w)
			_station_rects.append(Rect2(
					_anchors[k] + lift - Vector2(chw + TILE * 0.5, cbh),
					Vector2(chw * 2.0 + TILE, cbh + TILE * 0.5)))
			k += 1
	_build_camp(_anchors[0])
	_build_gate(_anchors[k])
	_build_barricades()


## One gate per `GATES` entry, each posted in whatever state this run has already
## earned. Built last, because a gate needs the stations standing (for the decor
## keep-outs it checks) and the finished `_anchors`.
func _build_barricades() -> void:
	_barricades.clear()
	var towers := _tower_anchors()
	for spec: Dictionary in BARRICADES:
		var g := _build_barricade(spec, int(towers[int(spec.st)]))
		_barricades.append(g)
		_post_guard(g)


## The boulder line and the gap in it the guard fills, laid across the walk from
## stop `ai` to the next one along, cell by cell out to land's end on both sides,
## so there is no way round it and exactly one way through.
##
## Objects rather than terrain: the rocks are what the player reads, and one
## `_solid` rect per cell is what stops them. The line is laid on every build, open
## or not -- only the guard in its gap comes and goes.
func _build_barricade(spec: Dictionary, ai: int) -> Dictionary:
	var a: Vector2 = _anchors[ai]
	var b: Vector2 = _anchors[ai + 1]
	var dir := (b - a).normalized()
	# Whole cells, square to the grid, or the rects leave diagonal slips between
	# them: across the walk is the other axis, whichever one that is.
	var step := Vector2i(0, 1) if absf(dir.x) >= absf(dir.y) else Vector2i(1, 0)
	# Each cell of the line is two cells deep along the walk, one across. Two deep
	# because `_is_walkable()` is a point test against the player's position, and a
	# one-tile wall can be stepped clean over in a single frame after a hitch.
	var size := (Vector2(2, 1) if step == Vector2i(0, 1) else Vector2(1, 2)) * TILE
	# The gap runs from `mid` outward for BARRICADE_GAP cells; the rocks start on
	# either side of it and run to the water.
	var mid := _cell_at(a.lerp(b, float(spec.t)))
	var last := BARRICADE_GAP - 1
	var g := {
		"st": int(spec.st),
		"post": _cell_mid(mid) + Vector2(step) * (float(last) * 0.5 * TILE),
		"wall": _cells_rect(mid, step, 0, last, size),
		"rocks": [] as Array[Rect2],
		"stand": Vector2.ZERO,
		"guard": null,
		"open": false,
	}
	for run in [[-1, -1], [last + 1, 1]]:
		var n: int = run[0]
		while true:
			var c := mid + step * n
			if not _land.has(c):
				break
			var rect := _cells_rect(c, step, 0, 0, size)
			(g.rocks as Array).append(rect)
			_solid.append(rect)
			# Round-robin off the cell so the wall is not four of the same stone.
			Art.sprite(world, Art.tex("res://assets/terrain/decorations/Rock%d.png"
					% (1 + posmod(c.x + c.y, 4))), _cell_mid(c), ROCK_SCALE)
			n += int(run[1])
	g.stand = _guard_rest(g)
	# Nothing grows in the gap, along the walk he takes out of it, or where he ends
	# up standing -- a tree in any of the three reads as him shoving through a wood.
	# The extra headroom is because he is base-anchored and stands ~90px tall, so a
	# trunk a clear cell above him still draws down over his head. Reserved here,
	# before `_build_decor()` runs, which is also what makes it the same clear
	# ground on a restart that has already opened this gate.
	_station_rects.append(Rect2(g.post as Vector2, Vector2.ZERO).expand(g.stand as Vector2)
			.grow_individual(TILE * 1.5, TILE * 2.5, TILE * 1.5, TILE * 1.5))
	# Keep the decor pass clear of the rubble on both sides. Touching it is not
	# enough: a loose boulder alongside the line reads as part of the wall and
	# walking through that one is the bug it looks like, and one tile is not
	# enough either -- a pine two cells off still reads as standing in the line.
	var rocks: Array = g.rocks
	if not rocks.is_empty():
		var span: Rect2 = rocks[0]
		for r in rocks:
			span = span.merge(r)
		_station_rects.append(span.grow(TILE * 2.0))
	return g


## The rect covering the cells `lo` to `hi` steps of `step` away from `c`, each cell
## being `size` (already deeper along the walk than one tile). Shared so the
## guard's plug and the rocks either side of it line up exactly.
func _cells_rect(c: Vector2i, step: Vector2i, lo: int, hi: int, size: Vector2) -> Rect2:
	var from := _cell_mid(c) + Vector2(step) * (float(lo) * TILE) - size * 0.5
	var to := _cell_mid(c) + Vector2(step) * (float(hi) * TILE) + size * 0.5
	return Rect2(from, to - from)


## Has this run already earned its way past `g`? One rule: the briefing.
func _barricade_is_due(g: Dictionary) -> bool:
	return Game.towers_entered[int(g.st)]


func _post_guard(g: Dictionary) -> void:
	# A restart mid-run keeps whatever it had already earned. He is not a wall any
	# more, but he is still the station's man, so he stands where he stepped aside
	# to -- and the gate is marked open, which is what "no blocker" means here.
	if _barricade_is_due(g):
		g.open = true
		g.guard = _spawn_guard(int(g.st), g.stand as Vector2)
		return
	_solid.append(g.wall as Rect2)
	g.guard = _spawn_guard(int(g.st), g.post as Vector2)


## Idle and walk on the one node, so standing him down is a change of animation
## while the tween carries him. Same base anchoring `Art.anim_sprite()` uses.
func _spawn_guard(st: int, at: Vector2) -> AnimatedSprite2D:
	var k := AnimatedSprite2D.new()
	k.sprite_frames = Art.anim_spriteframes({
		"idle": ["res://assets/units/%s/Warrior_Idle.png" % LIVERY[st], 5.0, true],
		"walk": ["res://assets/units/%s/Warrior_Run.png" % LIVERY[st], 9.0, true],
	})
	k.position = at
	k.scale = Vector2(GUARD_SCALE, GUARD_SCALE)
	var f: Texture2D = k.sprite_frames.get_frame_texture("idle", 0)
	if f != null:
		k.offset = Vector2(0, -f.get_height() * 0.5)
	k.play("idle")
	# Over the grass like the outpost guards, who are decoration at the same depth.
	k.z_index = 1
	world.add_child(k)
	return k


## Where opening the gate will send him: open ground between his post and his own
## station's tower, off the road so he is not standing in the walk, and clear of
## the rocks, the buildings and the signage. Searched rather than authored, so
## retuning a gate's `t` or moving a station cannot strand him in a wall. Called
## once, from `_build_barricade()`, and kept on the barricade as `stand`.
func _guard_rest(g: Dictionary) -> Vector2:
	var post: Vector2 = g.post
	var home: Vector2 = _anchors[_tower_anchors()[int(g.st)]]
	var dir := (home - post).normalized()
	var perp := dir.orthogonal()
	# Out along the walk toward his station, nearest first, then off to one side --
	# inland side first, since the seaward one is a strip of beach that props keep
	# off anyway. A guard posted mid-bridge has to go the whole way to the far
	# shore before there is anywhere to stand, which is why this runs to `reach`
	# rather than a couple of cells.
	var reach := int(post.distance_to(home) / TILE)
	# Two passes. The first asks that his whole body clears the keep-outs -- he is
	# ~90px across and as tall again, and a spot that clears one by a pixel still
	# plants him over the station's signage. The second settles for the cell he
	# stands on, which is what a crowded landing can afford.
	for strict: bool in [true, false]:
		# Furthest first, so he ends up beside his own station rather than hovering
		# at the wall he just stopped holding.
		for along: int in range(maxi(reach, 3), 1, -1):
			for across: int in [2, -2, 3, -3, 4, -4]:
				var at: Vector2 = post + dir * (float(along) * TILE) \
						+ perp * (float(across) * TILE)
				var c := _cell_at(at)
				if not _is_walkable(at) or _trail.has(c):
					continue
				var body := Rect2(at - Vector2(44.0, 90.0), Vector2(88.0, 90.0))
				if strict:
					if _clear_of_stations(body):
						return at
				# The loose pass gives up the decor keep-outs but never the
				# signage: standing in a flower bed is fine, standing across the
				# station's own name is not.
				elif not _near_station(c) and _clear_of_signs(body):
					return at
	# Nothing open: at least get out of the gap.
	return post + dir * (3.0 * TILE)


## Whatever the gate was waiting for has happened. The wall goes the moment it
## does, so the player can walk on while the guard is still moving -- and he walks,
## rather than fading out: the gate was a man, and a man who has let you past is
## still standing there.
func _open_barricade(g: Dictionary) -> void:
	if bool(g.open):
		return
	g.open = true
	_solid.erase(g.wall as Rect2)
	var k: AnimatedSprite2D = g.guard
	if k == null or not is_instance_valid(k):
		return
	var to: Vector2 = g.stand
	# Facing the way he is about to go -- the sheets' own direction is east.
	k.scale.x = GUARD_SCALE * (1.0 if to.x >= k.position.x else -1.0)
	k.play("walk")
	var tw := k.create_tween()
	tw.tween_property(k, "position", to, 1.2).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(func() -> void:
		if is_instance_valid(k):
			k.play("idle"))


## Called wherever progress is made, like `_refresh_causeways()` beside it.
func _refresh_barricades() -> void:
	for g: Dictionary in _barricades:
		if not bool(g.open) and _barricade_is_due(g):
			_open_barricade(g)


func _build_camp(at: Vector2) -> void:
	Art.anim_sprite(world, "res://assets/fx/Fire_01.png", at + Vector2(0, -26), 0.7, 9.0)
	var l := Art.label("BASE CAMP", 14, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	l.position = at + Vector2(-70, -54)
	l.size = Vector2(140, 20)
	Art.shadow(l)
	world.add_child(l)
	_station_rects.append(Rect2(at - Vector2(48, 60), Vector2(96, 80)))


## The end of the whole player flow: walking up and interacting ends the
## adventure and the summary opens (SPECS Q6). GATE_BUILDING (the castle) is
## the centerpiece, ribbon and label riding above its roof.
func _build_gate(at: Vector2) -> void:
	_gate = Node2D.new()
	_gate.position = at
	world.add_child(_gate)
	# Same crop-to-bbox, base-anchored pattern as `_make_station`'s tower sprite,
	# parented to `world` (not `_gate`) so the y-sort places it by where it
	# actually stands rather than by the gate's own transform.
	var btex := Art.cell(GATE_BUILDING, 0, 0)
	var bsize := btex.region.size
	var building := Sprite2D.new()
	building.texture = btex
	building.scale = Vector2(BUILDING_SCALE, BUILDING_SCALE)
	building.position = at
	building.offset = Vector2(0, -bsize.y * 0.5)
	world.add_child(building)
	var bh := bsize.y * BUILDING_SCALE
	var rib := Art.cell("res://assets/ui/BigRibbons.png", 0, 1)
	var spr := Sprite2D.new()
	spr.texture = rib
	spr.scale = Vector2(0.42, 0.42)
	spr.offset = Vector2(0, -rib.region.size.y * 0.5)
	spr.position = Vector2(0, -bh - 10.0)
	_gate.add_child(spr)
	var l := Art.label("VICTORY GATE", 14, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	l.position = Vector2(-80, -bh - 6.0)
	l.size = Vector2(160, 20)
	Art.shadow(l)
	_gate.add_child(l)
	var hw := bsize.x * 0.5 * BUILDING_SCALE
	_station_rects.append(Rect2(
			Vector2(at.x - (hw + TILE), at.y - (bh + TILE)),
			Vector2(hw * 2.0 + TILE * 2.0, bh + TILE * 2.0)))


# --- Decorations ------------------------------------------------------------
## Dressed per island, off one weight table, so the three stations read as three
## places: a wooded valley, a stony quarry, a bare highland. Same weighted roll as
## before -- only the thresholds and the counts now come from `ISLAND_PROPS`.
## Props arrive as patches of one kind, on ground that is clear of the road, the
## stations and every prop already standing. That is the whole difference between
## a wood and a scatter of single trees: the roll picks WHAT grows here, and then
## a handful of it grows here, together.
##
## Deterministic -- one fixed seed, so the board is the same every run. There is
## nothing to be gained from a different mess each time; there is a lot to be lost.
func _build_decor() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	for isl in ISLAND_PROPS.size():
		var mix: Dictionary = ISLAND_PROPS[isl]
		var placed := 0
		var tries := 0
		while placed < int(mix.count) and tries < int(mix.count) * 60:
			tries += 1
			var c := Vector2i(rng.randi_range(1, W - 2), rng.randi_range(1, H - 2))
			if not _plantable(c, isl):
				continue
			placed += _plant_patch(rng, c, _roll_kind(rng, mix), isl)
		for _k in int(mix.sheep):
			world.add_child(_sheep_at(rng, isl))
	# Animated rocks in the water off each island, to break up the open sea.
	for isl in ISLANDS.size():
		var c: Vector2 = ISLANDS[isl].c
		var r: Vector2 = ISLANDS[isl].r
		for side in [-1.0, 1.0]:
			var wrp := _norm(Vector2(c.x + side * (r.x + 0.035), c.y + 0.04))
			if _in_bounds(_cell_at(wrp)) and not _is_walkable(wrp):
				Art.anim_sprite(world, "res://assets/terrain/decorations/Water Rocks_0%d.png" % rng.randi_range(1, 4),
						wrp, 1.4, 4.0)


## How many of a kind stand together at most. A wood is a wood, a rock field is a
## handful of stones, and loot is a single thing someone dropped.
const PATCH := {"tree": 6, "stump": 3, "rock": 4, "loot": 1}


## The same weighted roll as before, but for the patch rather than for one prop.
func _roll_kind(rng: RandomNumberGenerator, mix: Dictionary) -> String:
	var roll := rng.randf()
	if roll < float(mix.tree):
		return "tree"
	if roll < float(mix.stump):
		return "stump"
	if roll < float(mix.rock):
		return "rock"
	return "loot"


## Ground a prop may stand on: this island's, inland of the shore, off the road,
## off the stations and not already occupied. Everything that makes the board read
## as a place rather than as noise is this one predicate.
func _plantable(c: Vector2i, isl: int) -> bool:
	if _taken.has(c) or _trail.has(c):
		return false
	if not _land.has(c) or _beach.has(c):
		return false
	if int(_island_of.get(c, -1)) != isl:
		return false
	return not _near_station(c)


## Grow a patch of `kind` out from `c`, centre first then ring by ring, and return
## how many actually took. The skipped cells are the point: a patch with no holes
## in it reads as a hedge, not as a wood.
func _plant_patch(rng: RandomNumberGenerator, c: Vector2i, kind: String, isl: int) -> int:
	var want := rng.randi_range(1, int(PATCH[kind]))
	var n := 0
	for cc in _rings(c, 2):
		if n >= want:
			break
		if not _plantable(cc, isl):
			continue
		if cc != c and rng.randf() < 0.45:
			continue
		_taken[cc] = true
		_plant(rng, cc, kind)
		n += 1
	return n


## `c`, then the cells one step out, then two, ... out to `radius`.
static func _rings(c: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = [c]
	for r in range(1, radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) == r:
					out.append(c + Vector2i(dx, dy))
	return out


## One prop of `kind`, base-anchored on the cell.
func _plant(rng: RandomNumberGenerator, c: Vector2i, kind: String) -> void:
	var p := _cell_mid(c)
	match kind:
		"tree":
			var fl := 1.0 if rng.randf() < 0.9 else -1.0
			Art.anim_sprite(world, "res://assets/terrain/decorations/Tree%d.png"
					% rng.randi_range(1, 4), p, 0.42, 3.0, fl)
		"stump":
			Art.sprite(world, Art.tex("res://assets/terrain/decorations/Stump %d.png"
					% rng.randi_range(1, 4)), p, 0.4)
		"rock":
			Art.sprite(world, Art.tex("res://assets/terrain/decorations/Rock%d.png"
					% rng.randi_range(1, 4)), p, 1.4)
		_:
			var loot := [
				"res://assets/terrain/resources/Gold_Resource.png",
				"res://assets/terrain/resources/Wood Resource.png",
				"res://assets/terrain/resources/Meat Resource.png",
				"res://assets/terrain/resources/Tool_0%d.png" % rng.randi_range(1, 4),
			]
			Art.sprite(world, Art.tex(loot[rng.randi_range(0, loot.size() - 1)]), p, 0.5)


func _sheep_at(rng: RandomNumberGenerator, isl := 0) -> Node2D:
	var sheep := Node2D.new()
	var spr := AnimatedSprite2D.new()
	spr.sprite_frames = Art.anim_spriteframes({
		"idle": ["res://assets/terrain/resources/Sheep_Idle.png", 5.0, true],
		"walk": ["res://assets/terrain/resources/Sheep_Move.png", 7.0, true],
	})
	spr.scale = Vector2(0.9, 0.9)
	sheep.add_child(spr)
	var shadow := Sprite2D.new()
	shadow.texture = Art.tex("res://assets/terrain/tileset/Shadow.png")
	shadow.scale = Vector2(0.5, 0.5)
	shadow.modulate.a = 0.5
	sheep.add_child(shadow)
	sheep.set_script(preload("res://scripts/Wander.gd"))
	var c: Vector2 = ISLANDS[isl].c
	var r: Vector2 = ISLANDS[isl].r
	sheep.position = _first_land(
			c.x + rng.randf_range(-0.45, 0.45) * r.x,
			c.y + rng.randf_range(-0.45, 0.45) * r.y, c)
	return sheep


## A station is now a building, a board off its left side and a keeper off its
## right, so a single radius either lets trees land on the board or blanks out
## half the island. Each station keeps its own box instead.
## Same keep-out set as `_near_station()`, for something with a footprint rather
## than a cell -- a guard looking for somewhere to stand that is not on top of a
## building, its houses or its signage.
func _clear_of_stations(r: Rect2) -> bool:
	return _clear_of(r, _station_rects)


func _clear_of_signs(r: Rect2) -> bool:
	return _clear_of(r, _sign_rects)


static func _clear_of(r: Rect2, boxes: Array) -> bool:
	for b in boxes:
		if (b as Rect2).intersects(r):
			return false
	return true


func _near_station(c: Vector2i) -> bool:
	var p := Vector2(c.x * TILE + TILE / 2, c.y * TILE + TILE / 2)
	for r in _station_rects:
		if (r as Rect2).has_point(p):
			return true
	return false


# --- Stations ---------------------------------------------------------------
var _station_rects: Array = []   # keep-out boxes for decor
## The signage boxes on their own as well. Decor treats them like any other
## keep-out, but a guard looking for somewhere to stand has to clear them with his
## whole body or he ends up printed across the station's name.
var _sign_rects: Array[Rect2] = []


## A station is a small outpost, not a lone building: its keep, two houses of the
## same livery, and a pair of idle guards. The signage is untouched -- `Station N`
## plus the topic line, the client's wording.
func _make_station(i: int, at: Vector2, _accent: String, lift := Vector2(0, -TOWER_LIFT)) -> void:
	var st := Node2D.new()
	st.position = at
	world.add_child(st)
	# `Art.cell(path, 0, 0)` crops to the alpha bounding box -- every building
	# PNG carries 20-60px of transparent padding, and an uncropped sprite would
	# hang above the grass. Anchored at its base like the decor.
	var btex := Art.cell(BUILDINGS[i], 0, 0)
	var bsize := btex.region.size
	# Lifted off the path and parented to the world, so the y-sort places it by
	# where it actually stands rather than by the doorstep on the path.
	var building := Sprite2D.new()
	building.texture = btex
	building.scale = Vector2(BUILDING_SCALE, BUILDING_SCALE)
	building.position = at + lift
	building.offset = Vector2(0, -bsize.y * 0.5)
	world.add_child(building)
	var hw := bsize.x * 0.5 * BUILDING_SCALE
	var bh := bsize.y * BUILDING_SCALE
	# Only the walls standing on the ground, not the whole sprite: the roof is
	# walkable so the player can pass behind, which is what the y-sort expects.
	# `has_point` excludes the bottom edge, so the doorstep row the station node
	# sits on stays open and `INTERACT_RADIUS` is always reachable.
	var base := at + lift
	var wall := Rect2(base.x - hw, base.y - bh * 0.45, hw * 2.0, bh * 0.45)
	_solid.append(wall)
	# The test reads the wall off the station itself: the outpost's houses append
	# walls too, so `_solid[i]` is no longer "station i".
	st.set_meta("wall", wall)
	_build_outpost(i, base, hw)
	# Keep decor off the building itself, plus a tile of breathing room.
	_station_rects.append(Rect2(
			Vector2(base.x - (hw + TILE), base.y - (bh + TILE)),
			Vector2(hw * 2.0 + TILE * 2.0, bh + TILE * 2.0)))
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
	var sign_y := -30.0 if lift.y < 0.0 else 46.0
	var sign_box := Rect2(at + Vector2(-100.0, sign_y), Vector2(200.0, 44.0))
	_station_rects.append(sign_box)
	_sign_rects.append(sign_box)
	var title := Art.label("Station %d" % (i + 1), 14, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	title.position = Vector2(-100, sign_y)
	title.size = Vector2(200, 20)
	st.add_child(title)
	_station_locks.append(title)
	var topic := Art.label(QuestionGen.station_meta(i).short, 11, Color(1, 1, 1, 0.92), HORIZONTAL_ALIGNMENT_CENTER)
	topic.position = Vector2(-100, sign_y + 18.0)
	topic.size = Vector2(200, 16)
	st.add_child(topic)
	# Both sit over grass and roof, so they need the same shadow the map prompts
	# use to stay readable.
	for l in [title, topic]:
		Art.shadow(l)
	_station_nodes.append(st)


## The keep's livery, for the houses and the guards that flank it.
const LIVERY := ["Blue", "Yellow", "Red"]


## Nothing the player has to stand on may end up inside a wall. The disc's own
## radius plus a margin, against every stop on the board.
func _clear_of_anchors(rect: Rect2) -> bool:
	var r := rect.grow(20.0)
	for a in _anchors:
		if r.has_point(a):
			return false
	return true


## Two houses either side of the keep and two guards on the doorstep. Houses are
## real walls; guards are decoration and stay walk-through, so they can stand near
## the path without blocking the trail.
func _build_outpost(i: int, base: Vector2, keep_hw: float) -> void:
	var col: String = LIVERY[i]
	var rng := RandomNumberGenerator.new()
	rng.seed = 4400 + i
	for side in [-1.0, 1.0]:
		var path := "res://assets/buildings/%s_House%d.png" % [col, rng.randi_range(1, 3)]
		var tex := Art.cell(path, 0, 0)
		var size := tex.region.size
		var hw := size.x * 0.5 * BUILDING_SCALE
		var bh := size.y * BUILDING_SCALE
		# A wide keep plus a house can reach the next circle 200px along, so the
		# house steps further out until its footprint is clear of every anchor --
		# and is dropped rather than built if the island never gives it room.
		var at := Vector2.ZERO
		var wall := Rect2()
		var ok := false
		for push in [0.0, 30.0, 60.0, 90.0]:
			at = base + Vector2(side * (keep_hw + hw + 14.0 + push), 14.0)
			wall = Rect2(at.x - hw, at.y - bh * 0.4, hw * 2.0, bh * 0.4)
			if _clear_of_anchors(wall) and _land.has(_cell_at(at)):
				ok = true
				break
		if not ok:
			continue
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.scale = Vector2(BUILDING_SCALE, BUILDING_SCALE)
		spr.position = at
		spr.offset = Vector2(0, -size.y * 0.5)
		world.add_child(spr)
		_solid.append(wall)
		_station_rects.append(Rect2(
				Vector2(at.x - (hw + TILE), at.y - (bh + TILE)),
				Vector2(hw * 2.0 + TILE * 2.0, bh + TILE * 2.0)))
	# Idle guards: the unit sheets are 8-frame strips with transparent gutters, so
	# `Art.anim_sprite` slices them the same way it slices the swaying trees.
	for spec in [["Pawn_Idle", -keep_hw - 6.0], ["Warrior_Idle", keep_hw + 6.0]]:
		var g := Art.anim_sprite(world, "res://assets/units/%s/%s.png" % [col, spec[0]],
				base + Vector2(float(spec[1]), 30.0), 0.3, 6.0,
				1.0 if float(spec[1]) > 0.0 else -1.0)
		g.z_index = 1


func _spawn_player() -> void:
	player = Node2D.new()
	player.position = _anchors[0]
	var shade := Sprite2D.new()
	shade.texture = Art.tex("res://assets/terrain/tileset/Shadow.png")
	shade.scale = Vector2(0.3, 0.3)
	shade.modulate.a = 0.55
	shade.position = Vector2(0, 2)
	player.add_child(shade)
	var spr := AnimatedSprite2D.new()
	spr.name = "Spr"
	spr.scale = Vector2(_hero_scale, _hero_scale)
	spr.offset = Vector2(0, -10)   # 20px frame, so this puts the feet on the ground
	spr.sprite_frames = Art.walk_frames(Game.hero_sheet(Game.hero_id))
	spr.play("down")
	spr.pause()
	player.add_child(spr)
	# "There is something here you can actually do." Clears the hero's head: the
	# 20px frame sits at `offset` -10 and scales by `_hero_scale`. Bobs so it
	# catches the eye without a marker on the ground under it.
	_bang = Art.label("!", 16, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	_bang.position = Vector2(-20, -20.0 * _hero_scale - 24.0)
	_bang.size = Vector2(40, 20)
	_bang.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_bang.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bang.visible = false
	Art.shadow(_bang)
	player.add_child(_bang)
	var bob := _bang.create_tween().set_loops()
	bob.tween_property(_bang, "position:y", _bang.position.y - 4.0, 0.45) \
			.set_trans(Tween.TRANS_SINE)
	bob.tween_property(_bang, "position:y", _bang.position.y, 0.45) \
			.set_trans(Tween.TRANS_SINE)
	world.add_child(player)
	# On the world, not the hero: the aerial POV has to frame the whole board
	# before it swoops down to him.
	_cam = Camera2D.new()
	_cam.position_smoothing_enabled = true
	_cam.position_smoothing_speed = 6.0
	_cam.position = player.position
	world.add_child(_cam)
	_clamp_cam(true)


## Camera limits, on for play and off for the aerial POV. A visible rect wider
## than the limits does not get letterboxed -- it gets shoved off-centre, so the
## whole-board view has to run unclamped.
func _clamp_cam(on: bool) -> void:
	_cam.limit_left = 0 if on else -1000000
	_cam.limit_top = 0 if on else -1000000
	_cam.limit_right = W * TILE if on else 1000000
	_cam.limit_bottom = H * TILE if on else 1000000


## Frames the whole board. Computed, not a constant: the old 0.46 framed a
## 1408x960 world and would show a corner of this one.
static func _aerial_zoom() -> float:
	return minf(640.0 / float(W * TILE), 360.0 / float(H * TILE))


# --- Pre-start aerial POV ---------------------------------------------------
## The client's flow shows the board from far away and frozen, then the camera
## swoops to the hero when the adventure starts. The board holds here until
## something starts it: offline that is any tap / click / interact press, and in
## Phase 3 the admin's Start Game calls `_swoop()` over `Net.gd` instead -- no
## button to delete, just route that signal in wherever `_swoop()` is called from
## `_unhandled_input()` now. `Game.clock_paused` is why the wait is free: no time
## is spent while the board is still frozen, however long the player looks. No
## joystick either, which the client asked for twice.
func _start_intro() -> void:
	_frozen = true
	Game.clock_paused = true
	_set_pad(false)
	_cam.position_smoothing_enabled = false
	_clamp_cam(false)
	var z := _aerial_zoom()
	_cam.zoom = Vector2(z, z)
	_cam.position = Vector2(W * TILE * 0.5, H * TILE * 0.5)
	_prompt.text = "Scouting the board..."
	# The controls crib goes with the joystick -- there is nothing to drive yet.
	if _hint_bar != null:
		_hint_bar.visible = false
	# Right under the prompt, lower centre -- nothing sits on the board itself.
	_start_hint = Art.label("Tap anywhere to start", 13, Color(1, 1, 1, 0.85), HORIZONTAL_ALIGNMENT_CENTER)
	_start_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_start_hint.offset_top = -74.0
	_start_hint.offset_bottom = -50.0
	_start_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_layer.add_child(_start_hint)


## The transition: the POV comes down onto the board and the hero.
func _swoop() -> void:
	if not _frozen:
		return
	_drop_start_hint()
	_prompt.text = ""
	_intro_tw = create_tween()
	_intro_tw.set_parallel(true)
	_intro_tw.tween_property(_cam, "zoom", Vector2(PLAY_ZOOM, PLAY_ZOOM), 0.9).set_ease(Tween.EASE_IN_OUT)
	_intro_tw.tween_property(_cam, "position", player.position, 0.9).set_ease(Tween.EASE_IN_OUT)
	_intro_tw.chain().tween_callback(skip_intro)


func _drop_start_hint() -> void:
	if _start_hint != null and is_instance_valid(_start_hint):
		_start_hint.queue_free()
	_start_hint = null


## Collapse the intro at once -- the tail of the tween, and what the tests call so
## nothing waits on wall-clock time.
func skip_intro() -> void:
	if not _frozen:
		return
	if _intro_tw != null and _intro_tw.is_valid():
		_intro_tw.kill()
	_intro_tw = null
	_drop_start_hint()
	if _hint_bar != null:
		_hint_bar.visible = true
	_frozen = false
	Game.clock_paused = false
	_cam.zoom = Vector2(PLAY_ZOOM, PLAY_ZOOM)
	_clamp_cam(true)
	_cam.position = player.position
	_cam.position_smoothing_enabled = true
	_set_pad(true)
	_prompt.text = ""
	_update_interaction()


## Which way the sprite faces. Vertical wins ties so a diagonal walk still
## shows the back or front, which reads better than a side-on shuffle.
static func _facing(dir: Vector2) -> String:
	if absf(dir.y) >= absf(dir.x):
		return "down" if dir.y > 0.0 else "up"
	return "right" if dir.x > 0.0 else "left"


func _process(delta: float) -> void:
	if _overlay != null and is_instance_valid(_overlay) and Game.adventure_active:
		return
	if _paused or _frozen or not Game.adventure_active:
		return
	if not _dev_aerial:
		_cam.position = player.position
	var dir := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down"))
	if dir.length_squared() > 1.0:
		dir = dir.normalized()
	var spr: AnimatedSprite2D = player.get_node("Spr")
	if dir.length_squared() > 0.001:
		# One axis at a time, so a diagonal into a wall slides along it rather
		# than stopping dead. Buildings only became real walls once the
		# footprint stopped being rounded to tile centres.
		var step := dir * PLAYER_SPEED * _speed_mult * delta
		player.position.x += step.x
		if not _is_walkable(player.position):
			player.position.x -= step.x
		player.position.y += step.y
		if not _is_walkable(player.position):
			player.position.y -= step.y
		var face := _facing(dir)
		if spr.animation != face or not spr.is_playing():
			spr.play(face)
	elif spr.is_playing():
		# The middle column is the standing pose, so idle is the walk paused.
		spr.pause()
		spr.frame = 1
	_update_interaction()


# --- Gating -----------------------------------------------------------------
## One item per circle, strictly in order: the tower briefing unlocks its own
## circles, circle n unlocks only when n-1 is resolved, and the gate only once
## every circle is behind you.
func _can_enter_tower(i: int) -> bool:
	return (Game.items_done < Game.TOTAL_ITEMS
			and Game.station_of_item(Game.items_done) == i
			and not Game.towers_entered[i])


func _can_answer(n: int) -> bool:
	return n == Game.items_done and Game.towers_entered[Game.station_of_item(n)]


func _can_enter_gate() -> bool:
	return Game.items_done >= Game.TOTAL_ITEMS


## Index of the nearest node in `nodes` within reach, or -1.
func _nearest_of(nodes: Array) -> int:
	var best := -1
	var best_d := INTERACT_RADIUS
	for i in nodes.size():
		var n: Node2D = nodes[i]
		if n == null:
			continue
		var d := n.position.distance_to(player.position)
		if d < best_d:
			best_d = d
			best = i
	return best


## What the hero is standing at: {kind: "tower"|"circle"|"gate", index}, or {}.
## Anchors are ~200px apart against a 42px reach, so this is never ambiguous.
## Measured against the anchor, not the tower beside it: the anchor sits on the
## trail the hero walks, which gives a wide window of availability, where a disc
## centred on a sideways-lifted tower would only catch ~25px of that walk.
func _nearest_target() -> Dictionary:
	var best := {}
	var best_d := INTERACT_RADIUS
	for pair in [["tower", _station_nodes], ["circle", _circles], ["gate", [_gate]]]:
		var nodes: Array = pair[1]
		for i in nodes.size():
			var n: Node2D = nodes[i]
			if n == null:
				continue
			var d := n.position.distance_to(player.position)
			if d < best_d:
				best_d = d
				best = {"kind": pair[0], "index": i}
	return best


## Would pressing E / GO right now actually do something? The "!" over the
## player's head is exactly this, and `_prompt_for` opens on the same question,
## so the rule lives here rather than in both.
func _can_act_on(target: Dictionary) -> bool:
	match target.get("kind", ""):
		"tower": return _can_enter_tower(target.index)
		"circle": return _can_answer(target.index)
		"gate": return _can_enter_gate()
	return false


func _prompt_for(target: Dictionary) -> String:
	var go := "Tap GO" if Game.touch else "Press E / Space / Enter"
	var ready := _can_act_on(target)
	match target.get("kind", ""):
		"tower":
			var i: int = target.index
			if ready:
				return "%s — enter Station %d" % [go, i + 1]
			if Game.items_done >= Game.TOTAL_ITEMS:
				return "Every circle cleared — head for the Victory Gate"
			if Game.towers_entered[i]:
				return "Station %d briefing done — follow the circles" % (i + 1)
			return "Complete Station %d first" % (Game.station_of_item(Game.items_done) + 1)
		"circle":
			var n: int = target.index
			if ready:
				return "%s — Answer Quest!" % go
			if n < Game.items_done:
				return "Circle %d cleared" % (n + 1)
			if not Game.towers_entered[Game.station_of_item(n)]:
				return "Enter Station %d first" % (Game.station_of_item(n) + 1)
			return "Answer circle %d first" % (Game.items_done + 1)
		"gate":
			if ready:
				return "%s — enter the Victory Gate" % go
			return "Conquer all %d circles first" % Game.TOTAL_ITEMS
	return ""


func _update_interaction() -> void:
	var target := _nearest_target()
	_bang.visible = _can_act_on(target)
	# A toast owns the prompt line for a moment, but it has no business freezing
	# the "!" -- that is a separate channel and has to keep tracking what is in
	# reach while the tip is up.
	if _flash_active:
		return
	_prompt.text = _prompt_for(target)


func _unhandled_input(event: InputEvent) -> void:
	if _overlay != null or _paused:
		return
	var tap := ((event is InputEventMouseButton
					and (event as InputEventMouseButton).pressed
					and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT)
			or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed))
	if _frozen:
		# Any tap, click or interact press starts the adventure -- nothing to
		# inspect yet, the whole board is the thing being looked at.
		if tap or event.is_action_pressed("interact"):
			_swoop()
		return
	if tap:
		_tap_at((event as InputEventWithModifiers).position if event is InputEventMouseButton
				else (event as InputEventScreenTouch).position)
		return
	var scale_step := DevTools.key_step(event, KEY_BRACKETLEFT, KEY_BRACKETRIGHT, 0.1)
	if scale_step != 0.0:
		_nudge_hero_scale(scale_step)
		return
	if event.is_action_pressed("interact"):
		_interact()
	elif event.is_action_pressed("pause"):
		_toggle_pause()


## Dev-only sizing knob: [ shrinks, ] grows, the readout is the number to bake
## back into UNIT_SCALE once something looks right. Rescales in place, so it is
## visible mid-walk without a restart.
func _nudge_hero_scale(delta: float) -> void:
	_hero_scale = clampf(_hero_scale + delta, 0.5, 3.0)
	var spr: AnimatedSprite2D = player.get_node("Spr")
	spr.scale = Vector2(_hero_scale, _hero_scale)
	_flash_tip("Hero scale: %.1f  (was UNIT_SCALE = %.1f)" % [_hero_scale, UNIT_SCALE])


## Tap-to-inspect. `self` is a canvas item under the camera, so the viewport's
## canvas transform is what undoes the zoom and the scroll. Aimed at the tower
## the player can see, not at the anchor below it -- nothing is drawn there any
## more, so hit-testing the anchor meant tapping bare grass. TOWER_TAP_REACH
## covers the building; the screen-px slack on top keeps it tappable once the
## aerial zoom has shrunk it.
func _tap_at(screen_pos: Vector2) -> void:
	var at: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * screen_pos
	var best := -1
	var best_d := TOWER_TAP_REACH + 14.0 / maxf(_cam.zoom.x, 0.01)
	for n in _circles.size():
		var c := _circles[n] as Node2D
		var d: float = (c.get_meta("tower_mid", c.position) as Vector2).distance_to(at)
		if d < best_d:
			best_d = d
			best = n
	if best < 0:
		_close_card()
		return
	_show_circle_card(best)


func _close_card() -> void:
	if _card != null and is_instance_valid(_card):
		_card.queue_free()
	_card = null


## What a circle is, on tap: which item, which station, and whether it is yours.
## The client's flow puts an "Answer Quest!" button on the circle you are standing
## on, so the card carries it -- but only within reach, which is what keeps "walk
## to the circle" true. E / GO still goes straight to the question, the fast path
## for forty items.
func _show_circle_card(n: int) -> void:
	_close_card()
	var st := Game.station_of_item(n)
	var meta: Dictionary = QuestionGen.station_meta(st)
	var card := Ui.panel(Vector2(300, 0), "Circle %d of %d" % [n + 1, Game.TOTAL_ITEMS])
	card.position = Vector2(170, 92)
	_ui_layer.add_child(card)
	_card = card
	var box: VBoxContainer = card.get_child(0) as VBoxContainer
	box.add_child(Art.label(meta.title, 14, Color("3a2c22"), HORIZONTAL_ALIGNMENT_CENTER))
	var state := ("Cleared" if n < Game.items_done
			else ("Your turn" if _can_answer(n) else "Locked"))
	box.add_child(Art.label("Item %d of Station %d   -   %s"
			% [Game.item_in_station(n) + 1, st + 1, state],
			14, Color("5a4632"), HORIZONTAL_ALIGNMENT_CENTER))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	if _can_answer(n) and (_circles[n] as Node2D).position.distance_to(player.position) < INTERACT_RADIUS:
		var go := Ui.button("Answer Quest!", 170, 44, Ui.RED)
		go.pressed.connect(func() -> void:
			_close_card()
			_try_answer_circle())
		row.add_child(go)
	var x := Ui.button("X", 44, 44, Ui.SMALL_RED)
	x.pressed.connect(_close_card)
	row.add_child(x)


func _interact() -> void:
	match _nearest_target().get("kind", ""):
		"tower": _try_enter_station()
		"circle": _try_answer_circle()
		"gate": _try_enter_gate()


## The tower briefing: the station intro card, and nothing else. Its circles are
## what ask the questions.
func _try_enter_station() -> void:
	var i := _nearest_of(_station_nodes)
	if i < 0:
		return
	if not _can_enter_tower(i):
		if Game.items_done >= Game.TOTAL_ITEMS:
			_flash_tip("Every circle is cleared — head for the Victory Gate!")
		elif Game.towers_entered[i]:
			_flash_tip("Station %d is briefed — answer its circles!" % (i + 1))
		else:
			_flash_tip("Complete Station %d first!" % (Game.station_of_item(Game.items_done) + 1))
		return
	Game.current_station = i
	var quiz: Control = preload("res://scripts/QuizOverlay.gd").new()
	quiz.adventure = self
	quiz.station_index = i
	quiz.intro_only = true
	_show_overlay(quiz)


func _try_answer_circle() -> void:
	var n := _nearest_of(_circles)
	if n < 0:
		return
	if not _can_answer(n):
		if n < Game.items_done:
			_flash_tip("Circle %d is already cleared!" % (n + 1))
		elif not Game.towers_entered[Game.station_of_item(n)]:
			_flash_tip("Enter Station %d first!" % (Game.station_of_item(n) + 1))
		else:
			_flash_tip("Answer circle %d first!" % (Game.items_done + 1))
		return
	Game.current_station = Game.station_of_item(n)
	var quiz: Control = preload("res://scripts/QuizOverlay.gd").new()
	quiz.adventure = self
	quiz.station_index = Game.current_station
	_show_overlay(quiz)


func _try_enter_gate() -> void:
	if _gate == null or _gate.position.distance_to(player.position) >= INTERACT_RADIUS:
		return
	if not _can_enter_gate():
		_flash_tip("Conquer all %d circles first!" % Game.TOTAL_ITEMS)
		return
	Game.end_adventure()


# --- HUD --------------------------------------------------------------------
func _build_hud() -> void:
	# The player's Camera2D transforms every canvas item in layer 0, UI included,
	# so screen-space elements have to live in their own CanvasLayers or they
	# get dragged around the world with the camera.
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 1
	add_child(_hud_layer)
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 2
	add_child(_ui_layer)
	var top := PanelContainer.new()
	top.position = Vector2(4, 4)
	top.custom_minimum_size = Vector2(632, 44)
	top.add_theme_stylebox_override("panel", Art.panel("res://assets/ui/BigBar_Base.png", Vector2(10, 2), 0.5))
	_hud_layer.add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	top.add_child(row)

	var av := Art.texrect("res://assets/ui/Avatar_01.png", 32, 32)
	row.add_child(av)
	var name_col := VBoxContainer.new()
	var nm := Art.label(Game.player_name, 13, Color("ffe9a8"))
	name_col.add_child(nm)
	var cls := Art.label("Adventurer #%d" % Game.hero_id, 11, Color(1, 1, 1, 0.8))
	name_col.add_child(cls)
	row.add_child(name_col)

	var stats := VBoxContainer.new()
	stats.alignment = BoxContainer.ALIGNMENT_CENTER
	stats.custom_minimum_size = Vector2(150, 0)
	_hud_station = Art.label("Station 1", 13, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	stats.add_child(_hud_station)
	_hud_pips = Art.label("— — —", 13, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	stats.add_child(_hud_pips)
	row.add_child(stats)

	row.add_child(Control.new()) # spacer
	var gems_icon := Art.texrect("res://assets/ui/Icon_03.png", 26, 26)
	row.add_child(gems_icon)
	var gems_col := VBoxContainer.new()
	_hud_gems = Art.label("50", 15, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	gems_col.add_child(_hud_gems)
	_hud_time = Art.label("10:00", 13, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	gems_col.add_child(_hud_time)
	row.add_child(gems_col)

	# Full-width, not centre-anchored: PRESET_CENTER_BOTTOM puts the box's left
	# edge at mid-screen, so a 640-wide label started in the middle and ran off
	# the right edge -- centred text ended up hanging off the screen.
	_prompt = Art.label("", 15, Color("ffe9a8"), HORIZONTAL_ALIGNMENT_CENTER)
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_prompt.offset_top = -104.0
	_prompt.offset_bottom = -74.0
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(_prompt)

	var keys := ("joystick — move   ·   GO — enter   ·   MENU / back — pause" if Game.touch
			else "WASD / arrows — move   ·   E — interact   ·   Esc — menu")
	var hint_bar: Label = Art.label(keys, 12,
			Color(1, 1, 1, 0.75), HORIZONTAL_ALIGNMENT_CENTER)
	if Game.touch:
		hint_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		hint_bar.offset_top = 52.0
		hint_bar.offset_bottom = 76.0
	else:
		hint_bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		hint_bar.offset_top = -40.0
		hint_bar.offset_bottom = -16.0
	hint_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(hint_bar)
	_hint_bar = hint_bar

	# Both float over open terrain, so they need a shadow to stay readable.
	for l in [_prompt, hint_bar]:
		Art.shadow(l)

	var gemrow := HBoxContainer.new()
	gemrow.position = Vector2(4, 50)
	gemrow.add_theme_constant_override("separation", 4)
	_hud_layer.add_child(gemrow)
	# SmallBar_Fill is a 3px sliver and SmallBar_Base a 3x1 patch; they never
	# lined up as a TextureProgressBar. A flat gauge in the pack's palette is
	# both correct at any size and legible at a glance.
	_gem_bar = ProgressBar.new()
	_gem_bar.custom_minimum_size = Vector2(140, 10)
	_gem_bar.show_percentage = false
	_gem_bar.max_value = 100.0
	_gem_bar.value = 0.0
	var trough := StyleBoxFlat.new()
	trough.bg_color = Color(0.08, 0.06, 0.10, 0.75)
	trough.set_corner_radius_all(4)
	trough.set_border_width_all(1)
	trough.border_color = Color(0, 0, 0, 0.6)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Game.GOLD
	fill.set_corner_radius_all(4)
	_gem_bar.add_theme_stylebox_override("background", trough)
	_gem_bar.add_theme_stylebox_override("fill", fill)
	gemrow.add_child(_gem_bar)
	_build_touch_pad()
	# The cheat drawer, and only where cheating is free: a release export never
	# builds the node, so there is nothing in it to reach.
	if OS.is_debug_build():
		_dev = preload("res://scripts/DevDrawer.gd").new()
		_ui_layer.add_child(_dev)
		_dev.setup(self)


# --- Touch controls ---------------------------------------------------------
## The stick is a raw-touch Node2D (its own finger index, like TouchScreenButton
## tracks), and GO/MENU stay TouchScreenButtons -- both read real touch rather
## than mouse-emulated, so steering and pressing GO work on separate fingers at
## once. Each feeds a real InputMap action (the stick with analog strength), so
## `_process` and `_unhandled_input` stay untouched.
func _build_touch_pad() -> void:
	if not Game.touch:
		return
	_touch_pad = Node2D.new()
	_hud_layer.add_child(_touch_pad)
	# Kept a thumb's width off the bottom edge: that strip is Android's
	# swipe-up-home gesture zone, immersive mode or not.
	_joystick = preload("res://scripts/Joystick.gd").new()
	_touch_pad.add_child(_joystick)
	_touch_btn("interact", "GO", Vector2(574, 290), 0.52, 20, false)
	_touch_btn("pause", "MENU", Vector2(606, 74), 0.34, 11, true)


func _touch_btn(action: String, text: String, center: Vector2, s: float, font: int, red: bool) -> void:
	var skin := "res://assets/ui/Small%sRoundButton_%s.png"
	var col := "Red" if red else "Blue"
	var b := TouchScreenButton.new()
	b.texture_normal = Art.tex(skin % [col, "Regular"])
	b.texture_pressed = Art.tex(skin % [col, "Pressed"])
	b.action = action
	b.passby_press = true   # a thumb sliding onto GO/MENU still presses it
	# The art is 128px drawn from the node's origin, so the hit circle is its
	# own centre at full size and rides `scale` down with the sprite.
	var circle := CircleShape2D.new()
	circle.radius = 64.0
	b.shape = circle
	b.shape_centered = true
	b.scale = Vector2(s, s)
	b.position = center - Vector2(64.0, 64.0) * s
	b.modulate.a = 0.8
	_touch_pad.add_child(b)
	var l := Art.label(text, font, Color(1, 1, 1, 0.95), HORIZONTAL_ALIGNMENT_CENTER)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size = Vector2(80, 24)
	l.position = center - Vector2(40, 12)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Art.shadow(l)
	_touch_pad.add_child(l)


## The drawer stays out of the way of anything that wants the whole screen.
func _close_dev() -> void:
	if _dev != null and is_instance_valid(_dev):
		_dev.close()


## Hiding a TouchScreenButton releases its action on its own; the stick is a
## plain Node2D, so a held drag needs the same release told explicitly, or it
## would survive into a quiz or the pause menu.
func _set_pad(on: bool) -> void:
	if _touch_pad != null:
		_touch_pad.visible = on
	if not on and _joystick != null:
		_joystick.release()


func _flash_tip(text: String) -> void:
	if not is_instance_valid(_prompt):
		return
	_flash_active = true
	Art.toast(_prompt, text, 1.2, "", func() -> void: _flash_active = false)


func _on_gems(g: int) -> void:
	if is_instance_valid(_hud_gems):
		_hud_gems.text = str(g)
	var ratio := clampf(float(g) / float(Game.START_GEMS + 60), 0.0, 1.0)
	if is_instance_valid(_gem_bar):
		_gem_bar.value = 100.0 * ratio


func _on_time(sec: int) -> void:
	if is_instance_valid(_hud_time):
		_hud_time.text = "%02d:%02d" % [sec / 60, sec % 60]


func _refresh_hud() -> void:
	_on_gems(Game.gems)
	_on_time(int(ceilf(Game.time_left)))
	var next := Game.completed_stations.find(false)
	if Game.items_done >= Game.TOTAL_ITEMS:
		_hud_station.text = "Victory Gate!"
	else:
		var st := Game.station_of_item(Game.items_done)
		_hud_station.text = "Station %d · %d/%d" % [st + 1,
				Game.item_in_station(Game.items_done), Game.ITEMS_PER_STATION[st]]
	var marks := ""
	for i in 3:
		marks += ["✓", "★", "—"][ 0 if Game.completed_stations[i] else (1 if Game.perfect_stations[i] else 2) ] + " "
	_hud_pips.text = marks.strip_edges()
	# Label the boards on the map itself, otherwise all three look identical.
	for i in _station_locks.size():
		var mark := "—"
		if Game.completed_stations[i]:
			mark = "★" if Game.perfect_stations[i] else "✓"
		elif i == next:
			mark = "▶"
		_station_locks[i].text = "Station %d  %s" % [i + 1, mark]


## Locked / current / done for all forty, after every resolved item.
func _refresh_circles() -> void:
	for n in _circles.size():
		var state := "locked"
		if n < Game.items_done:
			state = "done"
		elif _can_answer(n):
			state = "current"
		(_circles[n] as Node2D).set_state(state)


## Android's back button, routed here by Main: leaving a station mid-question
## is not on offer, so back opens the pause menu instead.
func go_back() -> void:
	if _overlay == null and not _paused and not _frozen:
		_toggle_pause()


func _toggle_pause() -> void:
	if _paused:
		return
	_paused = true
	_close_card()
	_close_dev()
	_set_pad(false)
	var menu := Ui.panel(Vector2(300, 250), "Paused")
	menu.position = Vector2(170, 46)
	_ui_layer.add_child(menu)
	var box: VBoxContainer = menu.get_child(0) as VBoxContainer
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	# label, kind, height, screen to open ("" = stay on the map), what to do with
	# the run in progress.
	for spec in [["Resume", Ui.BLUE, 44, "", ""], ["Home", Ui.SMALL, 38, "title", "end"],
			["Restart", Ui.SMALL, 38, "adventure", "restart"],
			["Leaderboard", Ui.SMALL_RED, 38, "board", ""],
			["New Game", Ui.SMALL_RED, 38, "hero", "abandon"]]:
		var b := Ui.button(spec[0], 170, spec[2], spec[1])
		b.pressed.connect(_leave_pause.bind(menu, spec[3], spec[4]))
		box.add_child(b)


## Every pause exit closes the menu. `drop` decides the fate of the run in
## progress -- "end" scores it, "restart" and "abandon" discard it unscored --
## and `screen` where to go next. Restart rebuilds the island, because `open()`
## remakes the screen, and the gems go back to the starting purse.
func _leave_pause(menu: Control, screen: String, drop: String) -> void:
	_paused = false
	_set_pad(true)
	menu.queue_free()
	match drop:
		"end": Game.end_adventure()
		"restart": Game.restart_adventure()
		"abandon": Game.abandon_adventure()
	if screen != "":
		main.open(screen)


# --- Quiz overlay -----------------------------------------------------------
func _show_overlay(overlay: Control) -> void:
	_overlay = overlay
	_close_card()
	_close_dev()
	_set_pad(false)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.focus_mode = Control.FOCUS_ALL
	_ui_layer.add_child(overlay)
	overlay.setup({})
	overlay.grab_focus()


func close_overlay() -> void:
	if _overlay != null:
		# A briefing overlay unlocks its station's circles on the way out.
		if bool(_overlay.get("intro_only")):
			Game.towers_entered[int(_overlay.get("station_index"))] = true
		_overlay.queue_free()
		_overlay = null
		_set_pad(true)
		_refresh_hud()
		_refresh_circles()
		_refresh_causeways()
		_refresh_barricades()
	# Clearing the board no longer ends the run on its own -- the Victory Gate
	# does, and walking to it is the last step of the player flow.


func _on_adventure_end(result: Dictionary) -> void:
	if _overlay != null:
		close_overlay()
	_paused = false
	main.open("summary", result)
class_name MapWorld
extends Node2D

## A match's world, built: the island `WorldGen` lays out from the seed, its
## trees and rocks made solid, the monks, the Monastery, each team's houses at
## its spawn, and clouds. One build for every screen that shows it -- the
## player's map walks it, the aerial view and a spectator fly over it -- so all
## of them see the same world.
##
## Who has answered what is the screen's business; this lays the world out as
## it stands before anyone has played.

## Set before `build()`: the match's seed and how many monks it has.
var seed := 1
var monk_count := 10

var grid := MapGrid.new()
var builder: MapBuilder
var decor: Decor
var gen: WorldGen
## The monks, monk i at gen.monks[i].
var monks: Array[Monk] = []
## Every tree, stump, rock, bush and water rock, under one node.
var props: Node2D
## The cloud layers, for the screen to tell them what to keep clear of.
var cloud_bands: Array[Clouds] = []

const MONASTERY := "res://assets/buildings/Purple_Monastery.png"
const HOUSE := "res://assets/buildings/%s_House%d.png"
const TEAM_COLOURS := ["Blue", "Red"]
const PAWN := "res://assets/units/%s/Pawn_Idle.png"
const PAWN_SCALE := 0.3
const BUSH := "res://assets/terrain/decorations/Bush%d.png"
const BUSH_SCALE := 0.32
const WATER_ROCK := "res://assets/terrain/decorations/Water Rocks_0%d.png"
const WATER_ROCK_SCALE := 1.4
## What of a monk blocks the hero: his feet, so you walk up to him, not into him.
const MONK_FEET := Rect2(-11, -8, 22, 8)


func build() -> void:
	y_sort_enabled = true
	gen = WorldGen.new()
	gen.seed = seed
	gen.monk_count = monk_count
	gen.generate()
	builder = MapBuilder.new(self, grid)
	decor = Decor.new(self, grid)
	builder.build_terrain()
	for c: Vector2i in gen.land:
		grid.land[c] = true
		grid.island_of[c] = int(gen.islet_of.get(c, 0))
	builder.retile(gen.land.keys())
	grid.height = gen.height
	for r: Dictionary in gen.ramps:
		grid.lay_ramp(r.top, r.low, r.side)
	grid.lay_cliffs()
	builder.paint_levels()
	grid.trail = gen.trail
	_build_monastery()
	_build_houses()
	_build_monks()
	_build_props()
	set_meta("solid", grid.solid)
	for band: Array in MapCfg.MAP_CLOUD_BANDS:
		var clouds := Clouds.new(MapCfg.WORLD_W * MapCfg.TILE,
			float(band[0]) * MapCfg.WORLD_H * MapCfg.TILE, 0.0, int(band[1]),
			MapCfg.MAP_CLOUD_ALPHA, float(band[2]))
		clouds.z_index = 50
		add_child(clouds)
		cloud_bands.append(clouds)


## Base-anchored and cropped to its art, like every building on the board;
## the lower `wall_frac` of it is wall, the roof the hero may pass behind.
func _building(path: String, at: Vector2, wall_frac: float, flip := 1.0) -> Sprite2D:
	var tex := Art.cell(path, 0, 0)
	var size := tex.region.size * MapCfg.BUILDING_SCALE
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.scale = Vector2(MapCfg.BUILDING_SCALE * flip, MapCfg.BUILDING_SCALE)
	spr.position = at
	spr.offset = Vector2(0, -tex.region.size.y * 0.5)
	add_child(spr)
	grid.block(Rect2(at.x - size.x * 0.5, at.y - size.y * wall_frac, size.x, size.y * wall_frac))
	grid.keep_out(MapGrid.building_keepout(at, size.x * 0.5, size.y))
	return spr


func _build_monastery() -> void:
	var m := _building(MONASTERY, gen.monastery, MapCfg.WALL_HEIGHT_FRAC)
	m.name = "Monastery"
	var l := Art.title(Art.label("Monastery", 14, Pal.CREAM, HORIZONTAL_ALIGNMENT_CENTER)) as Label
	l.size = Vector2(140, 20)
	l.position = gen.door + Vector2(-70, 6)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Art.shadow(l)
	l.z_index = 5
	l.name = "MonasteryLabel"
	add_child(l)


## Each team's houses beside its spawn, and a pawn at each house's door.
func _build_houses() -> void:
	for h: Dictionary in gen.houses:
		var colour: String = TEAM_COLOURS[int(h.team)]
		var flip := 1.0 if int(h.team) == 0 else -1.0
		_building(HOUSE % [colour, int(h.variant)], h.at, MapCfg.HOUSE_WALL_FRAC, flip)
		# In front of the door, his feet on the spot: sit_on_art leaves the
		# picture where it was, 17px up, and the house's wall drew over him.
		var feet: Vector2 = h.at + Vector2(14.0 * flip, 10)
		var pawn := Art.anim_sprite(self, PAWN % colour, feet, PAWN_SCALE, 6.0, flip, 8)
		Art.sit_on_art(pawn)
		pawn.position = feet
		pawn.frame = absi(int(h.at.y)) % 8


func _build_monks() -> void:
	for i in gen.monks.size():
		var m := Monk.new()
		m.index = i
		m.position = gen.monks[i]
		m.name = "Monk%d" % i
		add_child(m)
		monks.append(m)
		grid.block(Rect2(MONK_FEET.position + gen.monks[i], MONK_FEET.size))


func _build_props() -> void:
	props = Node2D.new()
	props.name = "Props"
	props.y_sort_enabled = true
	add_child(props)
	for d: Dictionary in gen.props:
		var prop: Node2D = load(MapCfg.PROP_SCENE % d.name).instantiate()
		prop.position = d.at
		prop.scale.x = float(d.flip)
		props.add_child(prop)
	decor.solidify(props)
	for b: Dictionary in gen.bushes:
		var bush := Art.anim_sprite(props, BUSH % int(b.v), b.at, BUSH_SCALE, 6.0, float(b.flip), 8)
		Art.sit_on_art(bush)
		bush.frame = absi(int(b.at.x)) % 8
	for r: Dictionary in gen.water_rocks:
		var rock := Art.anim_sprite(props, WATER_ROCK % int(r.v), r.at,
			WATER_ROCK_SCALE, 4.0, float(r.flip), 16)
		rock.frame = absi(int(r.at.x)) % 16


## Where each team starts.
## What the aerial minimap must not give away: the Monastery and its sign
## (shown once found), the monks (dots once seen), and the clouds.
func minimap_hidden() -> Array[Node]:
	var out: Array[Node] = [get_node("Monastery"), get_node("MonasteryLabel")]
	out.append_array(monks)
	out.append_array(cloud_bands)
	return out


func spawn_of(team: int) -> Vector2:
	return gen.spawns[clampi(team, 0, 1)]


func door() -> Vector2:
	return gen.door

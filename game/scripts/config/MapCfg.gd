class_name MapCfg
extends RefCounted

## Every knob the Adventure map is built from, in one file.
##
## Nothing here draws or decides anything -- `map/MapBuilder.gd`,
## `map/Stations.gd`, `map/Barricades.gd` and `map/Decor.gd` read these and do
## the work. Change a number here, run `tools/board_dump.gd` before and after,
## and the diff is exactly what moved.
##
## The long derivations behind the values that are *not* free choices live in
## SPECS.md under "Known compromises"; the note at the knob says which those
## are.

const TILE := 32        # world px per cell; art is 64px drawn at 0.5

const TILEMAP_COLOR := "res://assets/terrain/tileset/Tilemap_color1.png"
## Water drawn beyond the board on every side. A taller-than-16:9 phone sees
## past the world when the aerial view frames the whole height, and what it
## saw there was the clear colour.
const WATER_MARGIN := 20
const WATER_BG := "res://assets/terrain/tileset/Water Background color.png"

## Three islands over open water. The world is deliberately much larger than the
## 640x360 canvas -- the board needs room for forty circles to read as a walk
## rather than a dotted line. Tuning knobs, not fixed truths.
const WORLD_W := 96
const WORLD_H := 54

# The Super Retro World sheets are 16x20; scale picked by eye against the
# tileset's 64px cells with the [ and ] tuner (AdventureScreen._nudge_hero_scale).
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

# --- The board (map/Terrain.gd) -------------------------------------------
## One seed builds the whole board; a layout that breaks a design rule moves
## on to the next, up to TERRAIN_TRIES.
const MAP_SEED := 7310
const TERRAIN_TRIES := 40
## The camp's islet, bottom right, in cells (x, y, w, h).
const CAMP_REGION := Rect2i(84, 37, 10, 14)
## The three districts in walk order. `region` bounds the island, in cells;
## `arrive` is the bridge in (the station's pocket is where it lands) and `exit`
## the bridge out (-1: none; the last district climbs to its summit instead).
const DISTRICTS := [
	{"region": Rect2i(5, 30, 69, 22), "arrive": 0, "exit": 1},
	{"region": Rect2i(4, 4, 41, 20), "arrive": 1, "exit": 2},
	{"region": Rect2i(51, 5, 41, 23), "arrive": 2, "exit": -1, "summit": true},
]
## Land bridges, in cells, and the island each belongs to.
const BRIDGES := [
	{"cells": Rect2i(74, 43, 10, 3), "to": 1},
	{"cells": Rect2i(8, 24, 3, 6), "to": 2},
	{"cells": Rect2i(45, 13, 6, 3), "to": 3},
]
## Coasts: how much noise breaks up an island's rounded outline, its scale, and
## where land ends (higher: smaller islands).
const COAST_AMP := 0.42
const COAST_FREQ := 0.07
const COAST_LEVEL := 0.1
## The station's pocket: ground this far round where the bridge lands; the
## exit's; and how wide a band of terrace keeps each from the coast rim.
const POCKET_R := 10.0
const EXIT_POCKET_R := 7.0
const POCKET_MOAT := 3
## How far inland from its landing a pocket is centred.
const POCKET_INLAND := 5.0
## The coast rim's width varies with this noise, 0-3 cells.
const RIM_FREQ := 0.09
## Plateaus: where this noise tops PLATEAU_LEVEL at least PLATEAU_INLAND cells
## from the sea; pieces under PLATEAU_MIN cells are dropped. The summit island
## is lifted by SUMMIT_LIFT round its north-east, and its summit is its
## biggest plateau's heart -- at least SUMMIT_MIN cells.
const PLATEAU_FREQ := 0.08
const PLATEAU_LEVEL := 0.12
const PLATEAU_INLAND := 4
const PLATEAU_MIN := 14
const SUMMIT_LIFT := 0.9
const SUMMIT_MIN := 40
## Stairs up the terrace besides the one from each shelf, spread along it.
const TERRACE_EXTRA_STAIRS := 2
## The share of a district's circles set on its plateaus.
const CIRCLES_HIGH := 0.34
## Room a station needs round its doorstep for the keep and its houses, and the
## Victory Gate for its castle: cells either side, and above.
const STATION_YARD := Vector2i(4, 3)
const GATE_YARD := Vector2i(3, 4)
## Circles are at least this many cells apart.
const MIN_STOP_GAP := 5.0
## A circle's tower is drawn at this scale (PathCircle.TOWER_SCALE).
const CIRCLE_TOWER_SCALE := 0.5
## Little islands off the coasts, to dress.
const ISLETS := 5
## Each level's grass, as the pack's guide suggests, so the heights read apart:
## the ground, the terraces, the plateaus, the summit.
const LEVEL_COLORS := ["res://assets/terrain/tileset/Tilemap_color1.png",
	"res://assets/terrain/tileset/Tilemap_color2.png",
	"res://assets/terrain/tileset/Tilemap_color3.png",
	"res://assets/terrain/tileset/Tilemap_color1.png"]
## The guide's shadow under each raised level, one tile down.
const LEVEL_SHADOW_SCALE := 0.36
const LEVEL_SHADOW_ALPHA := 0.55

## Each island gets its own dressing, so the stations do not read as the same field
## three times: a thin camp clearing, a wooded starter valley, a stony quarry, a
## bare highland. Cumulative shares -- trees up to `tree`, stumps to `stump`, rocks
## to `rock` -- which tools/scatter_props turns into how much of the island is
## woods and how much is rock; and the sheep each island keeps.
const ISLAND_PROPS := [
	{"tree": 0.55, "stump": 0.70, "rock": 0.88, "sheep": 1},
	{"tree": 0.60, "stump": 0.70, "rock": 0.86, "sheep": 3},
	{"tree": 0.22, "stump": 0.46, "rock": 0.90, "sheep": 1},
	{"tree": 0.08, "stump": 0.20, "rock": 0.80, "sheep": 0},
]

const GUARD_SCALE := 0.9
## The knight himself, as a box round his boots: about two cells across and two
## high, base-anchored like everything else. What `_stands_clear()` asks its
## questions of, and what `tools/check_guards.gd` re-asks them of afterwards.
const GUARD_BODY := Rect2(-34.0, -64.0, 68.0, 64.0)
## His feet, for the walk out of the gap: what must not cross a boulder's wall.
const GUARD_BOOTS := Rect2(-18.0, -10.0, 36.0, 12.0)

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
const PLAY_ZOOM := 0.95

# --- Decor ------------------------------------------------------------------

## The keep's livery, for the houses and the guards that flank it. Indexed by
## station, like BUILDINGS and CIRCLE_BUILDINGS.
const LIVERY := ["Blue", "Yellow", "Red"]

# --- Guards -----------------------------------------------------------------
## The giant knight in each fence's gap. Sheets are the ordinary guards' own,
## at three times their decoration scale.
const GUARD_IDLE_SHEET := "res://assets/units/%s/Warrior_Idle.png"
const GUARD_WALK_SHEET := "res://assets/units/%s/Warrior_Run.png"
const GUARD_IDLE_FPS := 5.0
const GUARD_WALK_FPS := 9.0
## Over the grass, at the same depth as the outpost guards he matches.
const GUARD_Z := 1
## How long he takes to walk out of the gap when his station is briefed.
const GUARD_STEP_TIME := 1.2
## Ground kept clear around the gap, his walk and his spot, so the decor pass
## does not stand a tree in any of the three. Left, TOP, right, bottom -- the
## extra headroom is because he is base-anchored and ~90px tall, so a trunk a
## clear cell above him still draws down over his head.
const GUARD_CLEARING := Vector4(TILE * 1.5, TILE * 2.5, TILE * 1.5, TILE * 1.5)
## Where to look for somewhere he can stand aside to, in order and in cells:
## around an authored `rest` first, then in toward his own station, then
## anywhere near the station or the gap. First fit wins.
const GUARD_REST_RINGS := [4, 12, 8]
## Nothing open anywhere: at least get him out of the gap, this far toward his
## station.
const GUARD_REST_FALLBACK := TILE * 3.0

# --- Stations ---------------------------------------------------------------
## How much of a building's height is wall. Only what stands on the ground: the
## roof is walkable so the player can pass behind it, which is what the y-sort
## expects. Houses are squatter than keeps.
const WALL_HEIGHT_FRAC := 0.45
const HOUSE_WALL_FRAC := 0.4
## Breathing room around a building, kept clear of decor.
const KEEPOUT_PAD := TILE
## Nothing the player has to stand on may end up inside a wall: an anchor plus
## this margin is checked against every footprint before it is built.
const ANCHOR_CLEARANCE := 20.0

## The two houses flanking each keep, and the fixed seed that picks which of the
## three variants they are -- the board is the same every run.
const HOUSE_SHEET := "res://assets/buildings/%s_House%d.png"
const HOUSE_VARIANTS := 3
const OUTPOST_SEED := 4400
## A house sits this far out from the keep's edge, and this far down.
const HOUSE_GAP := 14.0
const HOUSE_DROP := 14.0
## A wide keep plus a house can reach the next circle 200px along, so the house
## steps further out until its footprint is clear of every anchor -- and is
## dropped rather than built if the island never gives it room.
const HOUSE_PUSH := [0.0, 30.0, 60.0, 90.0]

## The two idle guards on a keep's doorstep. Decoration: no walls, so they can
## stand near the path without blocking the trail.
const UNIT_SHEET := "res://assets/units/%s/%s.png"
const DOOR_GUARDS := ["Pawn_Idle", "Warrior_Idle"]
const DOOR_GUARD_SCALE := 0.3
const DOOR_GUARD_FPS := 6.0
const DOOR_GUARD_GAP := 6.0
const DOOR_GUARD_DROP := 30.0

## The station signboard, in world space. Over the doorstep, not the roof: above
## a lifted roof it sits 200px up and goes off-screen as soon as the player
## stands on the path below it. A keep that stepped sideways instead of up is
## the exception -- its houses print across that line, so its signage goes below
## the outpost, past the door guards.
const SIGN_Y_UP := -30.0
const SIGN_Y_DOWN := 46.0
const SIGN_BOX := Vector2(200.0, 44.0)
const SIGN_LINE_GAP := 18.0

# --- Camp and gate ----------------------------------------------------------
const CAMP_FIRE := "res://assets/fx/Fire_01.png"
const CAMP_FIRE_OFFSET := Vector2(0, -26)
const CAMP_FIRE_SCALE := 0.7
const CAMP_FIRE_FPS := 9.0
const CAMP_KEEPOUT := Rect2(-48, -60, 96, 80)
const GATE_RIBBON_ROW := 1        # BigRibbons: red, the castle's livery
const GATE_RIBBON_H := 30.0
const GATE_RIBBON_GAP := 4.0      # px of air between roof and banner

## Where the sheep start: one fixed seed, the same every run.
const DECOR_SEED := 90210

## Trees, stumps and rocks are scenes (`Tree1`..`Rock4`): the sprite, and a
## `Foot` body whose shapes are the solid part -- resize them in the editor.
const PROP_SCENE := "res://scenes/props/%s.tscn"
## Where every prop on the map stands, generated by tools/scatter_props.tscn.
const MAP_PROPS := "res://scenes/map/MapProps.tscn"
## The hero on the map: sprite, shadow and the Foot box walls stop.
const HERO_SCENE := "res://scenes/Hero.tscn"
## Clouds over the board: fewer and fainter than on the menus, since here
## they pass over circles and the hero.
## Clouds on the play map keep to the open sea along the top of the world.
## Over grass the pack's clouds turn a muddy beige at any see-through alpha,
## and opaque they would hide a circle or the hero passing under them.
const MAP_CLOUD_ALPHA := 0.9
## Bands of cloud, as [height as a share of the world, clouds, phase]: the top
## edge, over the north islands, the channel, over the south island, the bottom
## edge. Each band slides by its phase so they never line up. Over land a cloud
## fades as it nears the hero (`Clouds.keep_clear`), so it never hides them.
const MAP_CLOUD_BANDS := [[0.022, 6, 0.0], [0.26, 3, 0.2], [0.48, 5, 0.45],
	[0.72, 3, 0.85], [0.985, 4, 0.7]]
## The sea's colour, everywhere the world is drawn: the raw tile is a pale
## teal (#47aba9) that the pack's white surf all but vanishes against, so it
## is multiplied toward a deeper blue -- the map, Home and the menu backdrop
## alike, so the three read as one world.
const WATER_TINT := Color(0.70, 0.68, 1.0)

const SHEEP_IDLE := "res://assets/terrain/resources/Sheep_Idle.png"
const SHEEP_WALK := "res://assets/terrain/resources/Sheep_Move.png"
const SHEEP_IDLE_FPS := 5.0
const SHEEP_WALK_FPS := 7.0
const SHEEP_SCALE := 0.9

const SHADOW_SHEET := "res://assets/terrain/tileset/Shadow.png"
const SHEEP_SHADOW_SCALE := 0.5
const SHEEP_SHADOW_ALPHA := 0.5

# --- The hero ---------------------------------------------------------------
const HERO_SHADOW_SCALE := 0.3
const HERO_SHADOW_ALPHA := 0.55
const HERO_SHADOW_OFFSET := Vector2(0, 2)
## The Super Retro World frame is 20px tall, so this puts the feet on the
## ground.
const HERO_FOOT_OFFSET := Vector2(0, -10)
## The "!" over his head when something is in reach. Cleared above the frame,
## which is HERO_FRAME_H tall before `_hero_scale`.
const HERO_FRAME_H := 20.0
const BANG_CLEARANCE := 24.0
const BANG_BOX := Vector2(40, 20)
## It bobs so it catches the eye without a marker on the ground under it.
const BANG_BOB := 4.0
const BANG_BOB_TIME := 0.45

# --- Camera -----------------------------------------------------------------
const CAM_SMOOTH := 6.0
## Far enough out that the camera limits are off for the aerial POV: a visible
## rect wider than the limits is shoved off-centre rather than letterboxed.
const CAM_UNCLAMPED := 1000000
## How long the swoop from the aerial POV down onto the hero takes.
const SWOOP_TIME := 0.9


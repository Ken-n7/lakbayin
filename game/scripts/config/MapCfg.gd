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

## Four islands, as normalized centre + radii. `wobble` only shifts the coastline
## noise so they do not come out as the same shape rotated. Island 0 is the camp,
## bottom right; island 1 beside it is the big one, carrying Station 1 and its
## eight circles. The walk runs right to left along the bottom, then up and back
## across the top: camp -> island 1 -> island 2 -> island 3 and the Victory Gate.
const ISLANDS := [
	{"c": Vector2(0.925, 0.800), "r": Vector2(0.058, 0.135), "wobble": 0.6},
	{"c": Vector2(0.415, 0.765), "r": Vector2(0.365, 0.225), "wobble": 1.7},
	{"c": Vector2(0.260, 0.270), "r": Vector2(0.215, 0.175), "wobble": 3.1},
	# Island 3 carries a station, its circles, a fence and the Victory Gate, which is
	# more than its first size could hold -- the fence had shrunk to clear the shore and
	# the keep's left house stood in the water. `c.y` and `r.y` move together so the
	# north coast stays where it was and only the south shore travels, ~4 cells down
	# into open sea. Island 1 is still a clear channel below it; close that and the two
	# merge, and `_island_index()` hands the overlap to island 1 and its forest.
	{"c": Vector2(0.740, 0.307), "r": Vector2(0.215, 0.212), "wobble": 5.3},
]

## One authored trail per island, in normalized world coords. Each is a serpentine
## that fills its island and ends near the next crossing, so the walk flows from
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
	 Vector2(0.10, 0.83), Vector2(0.16, 0.69), Vector2(0.40, 0.65),
	 Vector2(0.38, 0.60)],
	# Island 2: the bridge lands in the south-east corner, where Station 2 stands,
	# and the walk loops west, north and back east to the seam. Nothing square
	# across that walk can gate it -- it doubles back, so a line always leaves the
	# last circle on the station's side. What does gate it is a fence drawn *round*
	# the corner the station sits in; see `BARRICADES`.
	[Vector2(0.325, 0.395), Vector2(0.12, 0.35), Vector2(0.12, 0.22),
	 Vector2(0.25, 0.16), Vector2(0.40, 0.23)],
	# Station 3 starts this walk, so its first point is where the keep stands. East of
	# the old 0.60, which put the left house of the outpost over the water -- but only
	# just, and not by eye: how far east it may go is fixed by its fence. See
	# `BARRICADES`.
	[Vector2(0.61, 0.23), Vector2(0.75, 0.16), Vector2(0.89, 0.22),
	 Vector2(0.88, 0.34), Vector2(0.70, 0.38)],
]

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

## Every seam is crossed by a **land bridge**. Seam `i` is the water between island
## `i` and island `i + 1`: the walk simply carries on over it and `_stamp_path()`
## lays ground under the corridor, so every crossing is there from the first step
## and a guard holds it rather than the tide. Seam 0 (camp -> Station 1) falls out
## of trail 0, which spans it; the rest are stamped between one trail's end and the
## next one's start.
##
## Kept as a list rather than assumed, because it is what `_stamp_path()` asks --
## take a seam out of it and that crossing goes back to being open water with no
## way over, which is a loud enough failure to find at once.
const BRIDGED_SEAMS := [0, 1, 2]

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
## Each is a fence of `arc` cells' radius swung right round its station, with the
## gap on the bearing the walk leaves by, `shift` cells of arc along the curve
## from it. A fence rather than a line across the walk because every station
## stands in a corner or at an end of its island, where a line either has nowhere
## to go or strands a stop on the wrong side of itself -- and because a wall that
## bows away from the station reads as one from the yard inside it.
##
## `offset` nudges the guard within his own gap, and only him: the fence, the gap
## and the wall that plugs it stay on the bearing, so this is framing rather than
## geometry. `rest` is where he should step aside to when the gate opens, measured
## from his post, and it is a wish rather than a decree -- the nearest ground he
## actually fits on wins, so a spot that has since grown a boulder stands him
## beside it instead of on it. Both default to zero.
const BARRICADES := [
	# Radius picked so the gap lands on the cell the old straight line put him on:
	# the knight has not moved, the wall around him has curved.
	{"st": 0, "arc": 8.0, "offset": Vector2(0, -20)},
	{"st": 1, "arc": 7.0, "offset": Vector2(0, -25)},
	# Station 3 is at a forced compromise -- keep, knight and fence are one
	# problem, and `arc` is bounded below by the west shore and above by the
	# Victory Gate. See SPECS.md "Known compromises"; `tools/check_guards.gd`
	# fails if it stops holding.
	{"st": 2, "arc": 6.0, "shift": 2.0, "offset": Vector2(0, -30),
			# Due west of his post is the road, and below that the station's own
			# signboard, so there is no standing aside on the keep's side of this
			# gate: he steps out through the gap and holds the north shoulder of it.
			"rest": Vector2(-192, -32)},
]
const GUARD_SCALE := 0.9
## A fence is laid cell by cell round its station, shore to shore. Objects, not
## terrain -- the old three-tile neck had to be stamped because `_island_index()`
## gives a shore ten cells wide, and a line of rocks just plugs whatever is there.
## `ROCK_SCALE` is big enough that neighbouring stones touch even where the curve
## steps diagonally and their cells are a cell and a half apart: below that the
## fence reads as scattered pebbles with walls between them.
const ROCK_SCALE := 1.2
## The stretch of fence the guard stands in for, as a box round his boots: his
## shoulders either side, his chest above, and just enough below to keep the cell
## he stands on. He is base-anchored like everything else here, so all of him is
## drawn *upward* -- measured evenly round him, the slack landed under his boots,
## which is the one shape a fence can take that reads as a way through.
##
## Against each cell's **middle**, not along the arc. A post sits wherever the
## bearing puts it inside its own cell, so an arc length that rounded to two cells
## at one gate rounded to three at the next -- which is how the red knight came to
## have a stride of bare grass over his head with the wall still in it.
const GUARD_REACH := Rect2(-35.0, -42.0, 70.0, 59.0)
## The knight himself, as a box round his boots: about two cells across and two
## high, base-anchored like everything else. What `_stands_clear()` asks its
## questions of, and what `tools/check_guards.gd` re-asks them of afterwards.
const GUARD_BODY := Rect2(-34.0, -64.0, 68.0, 64.0)
## A boulder's wall, like a building's, is the foot of what you can see and not
## the cell it was laid on. `Art.sprite()` base-anchors a 64px stone, so the
## stone is drawn a whole texture-height *above* its cell: a box centred on the
## cell blocked a tile of open grass below the rock and left the rock's own top
## walkable -- the bump into nothing the wall gave off. 1.5 cells across so
## neighbours still overlap however the curve steps, 1.25 down from a quarter
## cell above the base, which lands inside all four Rock sheets' pixels.
const ROCK_WALL := Vector2(TILE * 1.5, TILE * 1.25)
const ROCK_WALL_BASE := TILE * 0.25

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
## And around the rubble. One tile is not enough: a pine two cells off still
## reads as standing in the line, and walking through it looks like the bug.
const RUBBLE_CLEARING := TILE * 2.0
## A little below his feet, on top of GUARD_BODY: a boulder's wall stops above
## the cell it stands on, and the y-sort draws a stone in the cell below him
## over his boots.
const GUARD_FOOT_SLACK := 24.0
## Where to look for somewhere he can stand aside to, in order and in cells:
## around an authored `rest` first, then in toward his own station, then
## anywhere near the station or the gap. First fit wins.
const GUARD_REST_RINGS := [4, 8, 8]
## Nothing open anywhere: at least get him out of the gap, this far toward his
## station.
const GUARD_REST_FALLBACK := TILE * 3.0

# --- Boulders ---------------------------------------------------------------
const ROCK_SHEET := "res://assets/terrain/decorations/Rock%d.png"
## Four stones in the pack, picked round-robin off the cell so a fence is not
## four of the same one.
const ROCK_VARIANTS := 4
## How far round the arc each step goes. Half a cell, so the sweep never skips
## a cell and leaves a gap in the fence.
const ARC_STEP := TILE * 0.5

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
const MAP_CLOUDS := 4
const MAP_CLOUD_ALPHA := 0.9
const MAP_CLOUD_Y := TILE * 1.2
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
## How far into its island a sheep may start, as a fraction of its radii.
const SHEEP_SPREAD := 0.45

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

# --- Island shape -----------------------------------------------------------
## The radial wobble that keeps a coastline ragged -- a bare ellipse reads as a
## pond, not an island. `base` is how much of the ellipse is land; the two waves
## ripple the edge, and each island's own `wobble` phase-shifts the first so
## they do not come out as the same shape rotated.
const COAST_BASE := 0.86
const COAST_WAVE1 := Vector2(0.11, 3.0)   # amplitude, frequency
const COAST_WAVE2 := Vector2(0.06, 5.0)
const COAST_WAVE2_PHASE := 0.4
## Past this the wobble cannot reach, so the cell is open water either way.
const COAST_REJECT := 1.3

## Walking inward from a spot in the sea to find land: how many steps, and how
## far each one moves toward the island's centre.
const LAND_SEARCH_TRIES := 60
const LAND_SEARCH_STEP := 0.1

# --- Stamping the walk ------------------------------------------------------
## The authored path is stamped as land before the autotile pass, so a stray
## inlet in the generated island can never cut the board in half.
##
## Three cells wide -- the walk itself plus a shoulder either side. This is also
## the corridor `_trail` records, which is what keeps the decor pass off the
## road and makes the walk read as a road through the trees.
const STAMP_RING := [-1, 0, 1]
## Half a cell per step along a trail segment, so the stamp never skips a cell.
const STAMP_STEP := TILE * 0.5
## Ground under a tower, which steps off the path and would otherwise stand in
## the shallows at a bend. Asymmetric: the sprite is base-anchored, so it needs
## more room above its feet than below.
const TOWER_PAD_X := Vector2i(-2, 3)
const TOWER_PAD_Y := Vector2i(-2, 2)

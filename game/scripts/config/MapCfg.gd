class_name MapCfg
extends RefCounted

## Every knob the match's world is drawn and walked by, in one file.
##
## Nothing here draws or decides anything -- `map/WorldGen.gd` lays the world
## out, `map/MapWorld.gd` builds it, `AdventureScreen` walks it, and they read
## these. The world's own shape (coasts, monks, the Monastery) is WorldGen's.

const TILE := 32        # world px per cell; art is 64px drawn at 0.5

const TILEMAP_COLOR := "res://assets/terrain/tileset/Tilemap_color1.png"
## Water drawn beyond the world on every side. A taller-than-16:9 phone sees
## past the world when the aerial view frames the whole height.
const WATER_MARGIN := 20
const WATER_BG := "res://assets/terrain/tileset/Water Background color.png"
## Each level's grass, as the pack's guide suggests, so the heights read
## apart: the ground, the plateaus, the hills on them.
const LEVEL_COLORS := ["res://assets/terrain/tileset/Tilemap_color1.png",
	"res://assets/terrain/tileset/Tilemap_color2.png",
	"res://assets/terrain/tileset/Tilemap_color3.png"]
## The guide's shadow under each raised level, one tile down.
const SHADOW_SHEET := "res://assets/terrain/tileset/Shadow.png"
const LEVEL_SHADOW_SCALE := 0.5      # the guide: three tiles of 64px, at our 0.5
const LEVEL_SHADOW_ALPHA := 1.0

## The world, in cells. Much larger than the 640x360 canvas: finding the monks
## is half the game.
const WORLD_W := 96
const WORLD_H := 54

# The Super Retro World sheets are 16x20; scale picked by eye against the
# tileset's 64px cells.
const UNIT_SCALE := 1.6
# Buildings are the tileset's own 64px art, so they take the tileset's scale.
const BUILDING_SCALE := 0.5
const PLAYER_SPEED := 150.0
## How far the hero's feet keep off a cliff face beside them, px.
const CLIFF_SIDE_MARGIN := 5.0
## How near a monk or the Monastery's door the hero must stand to act on it.
const INTERACT_RADIUS := 42.0
const PLAY_ZOOM := 0.95

## The lower share of a building that is wall; the roof the hero may pass
## behind, which is what the y-sort expects.
const WALL_HEIGHT_FRAC := 0.45
const HOUSE_WALL_FRAC := 0.4
const KEEPOUT_PAD := TILE

## Trees, stumps and rocks are scenes (`Tree1`..`Rock4`): the sprite, and a
## `Foot` body whose shapes are the solid part -- resize them in the editor.
const PROP_SCENE := "res://scenes/props/%s.tscn"

## The rocks on the menus' islands (Backdrop, Home), by name: which of the
## pack's rocks each one is.
const MENU_ROCKS := {
	"blue_a": "Rock4", "blue_b": "Rock2", "blue_c": "Rock1",
	"yellow_a": "Rock3", "yellow_b": "Rock2",
	"red_a": "Rock4", "red_b": "Rock2", "red_c": "Rock3", "red_d": "Rock1",
}


static func plain_rock(name: String) -> String:
	return "res://assets/terrain/decorations/%s.png" % MENU_ROCKS[name] if MENU_ROCKS.has(name) else ""


## The hero on the map: sprite, shadow and the Foot box walls stop.
const HERO_SCENE := "res://scenes/Hero.tscn"
## Clouds over the world: fewer and fainter than on the menus. Over land a
## cloud fades as it nears the hero (`Clouds.keep_clear`), so it never hides
## them.
const MAP_CLOUD_ALPHA := 0.9
## Bands of cloud, as [height as a share of the world, clouds, phase].
const MAP_CLOUD_BANDS := [[0.022, 6, 0.0], [0.26, 3, 0.2], [0.48, 5, 0.45],
	[0.72, 3, 0.85], [0.985, 4, 0.7]]
## The sea's colour, everywhere the world is drawn: the raw tile is a pale
## teal that the pack's white surf all but vanishes against, so it is
## multiplied toward a deeper blue -- the map, Home and the menu backdrop alike.
const WATER_TINT := Color(0.70, 0.68, 1.0)

const SHEEP_IDLE := "res://assets/terrain/resources/Sheep_Idle.png"
const SHEEP_WALK := "res://assets/terrain/resources/Sheep_Move.png"
const SHEEP_IDLE_FPS := 5.0
const SHEEP_WALK_FPS := 7.0
const SHEEP_SCALE := 0.45

# --- The hero ---------------------------------------------------------------
## The "!" over his head when something is in reach. Cleared above the frame,
## which is HERO_FRAME_H tall before the hero's scale.
const HERO_FRAME_H := 20.0
const BANG_CLEARANCE := 34.0   # over the team arrow (Peers.ARROW_Y)
const BANG_BOX := Vector2(40, 20)
## It bobs so it catches the eye without a marker on the ground under it.
const BANG_BOB := 4.0
const BANG_BOB_TIME := 0.45

# --- Camera -----------------------------------------------------------------
const CAM_SMOOTH := 6.0
## Far enough out that the camera limits are off for the aerial view: a visible
## rect wider than the limits is shoved off-centre rather than letterboxed.
const CAM_UNCLAMPED := 1000000
## How long the swoop from the aerial view down onto the hero takes.
const SWOOP_TIME := 2.0

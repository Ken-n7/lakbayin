extends Node

## A match's map as the server checks positions against it: the world every
## phone builds from the session's seed (WorldGen), as JSON on one line --
## monks, the Monastery's door, the spawns, which cells a hero may stand in,
## and the reach and speed a hero has. The server runs this once per match.
##
##   godot --headless --path game res://tools/map_export.tscn -- <session id> <monks>


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("usage: -- <session id> <monks>")
		get_tree().quit(2)
		return
	var gen := WorldGen.new()
	gen.seed = Game.seed_of(args[0])
	gen.monk_count = int(args[1])
	gen.generate()
	var walk := PackedByteArray()
	walk.resize(WorldGen.W * WorldGen.H)
	for c: Vector2i in gen.land:
		if not gen._g.cliff.has(c):
			walk[c.y * WorldGen.W + c.x] = 49        # "1"
	for i in walk.size():
		if walk[i] == 0:
			walk[i] = 48                             # "0"
	var at := func(p: Vector2) -> Array: return [p.x, p.y]
	print(JSON.stringify({
		"monks": gen.monks.map(at), "door": at.call(gen.door), "spawns": gen.spawns.map(at),
		"w": WorldGen.W, "h": WorldGen.H, "tile": MapCfg.TILE, "walk": walk.get_string_from_ascii(),
		"reach": MapCfg.INTERACT_RADIUS, "speed": MapCfg.PLAYER_SPEED,
	}))
	get_tree().quit(0)

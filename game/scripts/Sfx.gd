class_name Sfx
extends RefCounted

## Sound effects: `Sfx.play("correct")` from anywhere. The client picked every
## one by ear (five review rounds); most are our own, made for this game in
## the style of Zelda: The Minish Cap, the rest CC0 (Juhani Junkala's retro
## 512, Kenney's Interface Sounds).
##
## A small pool of players on the root, so a sound outlives the screen that
## played it -- the Victory Gate's fanfare carries on into the results.

const BUS := "Sfx"
const DIR := "res://assets/sfx/"
## event -> file. Several events share a sound (client).
const SOUNDS := {
	"correct": "correct.wav", "wrong": "wrong.wav", "station_complete": "station_complete.wav",
	"hint": "hint.wav", "skip": "hint.wav", "refused": "blocked.wav", "blocked": "blocked.wav",
	"rescue": "rescue.wav", "enter_tower": "enter_tower.wav", "knight": "knight_opens.wav",
	"circle_unlock": "circle_unlock.wav", "gate": "victory_gate.wav",
	"time_warning": "time_warning.wav", "time_up": "time_up.wav", "eliminated": "eliminated.wav",
	"paused": "paused.wav", "resumed": "resumed.wav", "ended": "ended.wav",
	"team_changed": "team_changed.wav", "gem": "gem.wav", "button": "button.wav",
	"panel_open": "panel_open.wav", "panel_close": "panel_close.wav", "error": "time_warning.wav",
	"success": "success.wav", "player_joins": "player_joins.wav", "qk_start": "qk_start.wav",
	"qk_team": "qk_team.ogg",
}
const POOL := 6

## 0..1, the Sounds slider in Home's Settings; 0 is off. Kept with the music's
## volume in `Music.SAVE_PATH`.
static var volume := 0.8
## The last few sounds asked for, oldest first -- what the suites check
## (e2e_test.gd), since a headless run cannot listen.
static var heard: Array[String] = []
static var _pool: Array[AudioStreamPlayer] = []
static var _next := 0


static func play(event: String, delay := 0.0) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or not SOUNDS.has(event):
		return
	if delay > 0.0:
		tree.create_timer(delay).timeout.connect(func() -> void: play(event))
		return
	heard.append(event)
	if heard.size() > 64:
		heard.pop_front()
	if _pool.is_empty() or not is_instance_valid(_pool[0]):
		attach(tree.root, true)
	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()
	if not p.is_inside_tree():
		return                    # made this frame, deferred: in on the next
	p.stream = load(DIR + SOUNDS[event])
	p.play()


## Set, apply and keep the sound-effects volume.
static func set_volume(v: float) -> void:
	volume = clampf(v, 0.0, 1.0)
	_apply()
	Music.save_setting("sfx", volume)


## The players, under `host` -- `Main`, which lasts the whole run. Tools that
## run a screen without `Main` get them on the root, lazily (`deferred`, as the
## root may be mid-setup).
static func attach(host: Node, deferred := false) -> void:
	if AudioServer.get_bus_index(BUS) < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, BUS)
	volume = Music.load_setting("sfx", volume)
	_apply()
	_pool.clear()
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = BUS
		# Let go of the sound on the way out, or it outlives the engine at quit.
		p.tree_exiting.connect(func() -> void:
			p.stop()
			p.stream = null)
		if deferred:
			host.add_child.call_deferred(p)
		else:
			host.add_child(p)
		_pool.append(p)


static func _apply() -> void:
	var bus := AudioServer.get_bus_index(BUS)
	if bus < 0:
		return
	AudioServer.set_bus_volume_db(bus, linear_to_db(volume))
	AudioServer.set_bus_mute(bus, volume <= 0.0)

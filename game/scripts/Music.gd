class_name Music
extends Node

## The background music: one playlist per screen (`Main.MUSIC`), crossfaded.
##
## A playlist of one song loops it, from its loop start in xDeviruchi's table
## (16-bit Fantasy & Adventure pack; the files end exactly on their loop's end).
## A longer one plays each song through once, then fades into another picked at
## random -- never the same one twice running (client: shuffle the town songs).
## Screens that share a playlist carry it on; a change of playlist, or to none,
## fades across.

const FADE := 2.0                     # seconds, every crossfade
const BUS := "Music"
## The volume is the device's, not the player's: its own file, not the profile.
const SAVE_PATH := "user://audio.cfg"
const SONGS := {                      # name -> [file, loop start in seconds]
	"our_town": ["res://assets/music/definitely_our_town.ogg", 23.106],
	"winds": ["res://assets/music/where_the_winds_roam.ogg", 0.639],
	"port": ["res://assets/music/port_town.ogg", 2.135],
	"shop": ["res://assets/music/shop.ogg", 0.0],
	"victory": ["res://assets/music/victory.ogg", 8.501],
	"battle_1": ["res://assets/music/battle_1.ogg", 10.760],
	"battle_2": ["res://assets/music/battle_2.ogg", 0.63],
	"journey": ["res://assets/music/the_journey.ogg", 0.0],   # not loopable: from the top
}
const PLAYLISTS := {
	"town": ["our_town", "winds", "port"],
	"shop": ["shop"],
	"victory": ["victory"],
	"battle": ["battle_1", "battle_2"],
	"journey": ["journey"],
}

## 0..1, the Music slider in Home's Settings; 0 is off.
var volume := 0.8
var _players: Array[AudioStreamPlayer] = []
var _on := 0                          # which of the two is the one playing
var _list := ""
var _song := ""
var _fade: Tween


func _ready() -> void:
	# Its own bus, so its volume is only the music's.
	if AudioServer.get_bus_index(BUS) < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, BUS)
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.volume_db = linear_to_db(0.0)
		p.bus = BUS
		add_child(p)
		_players.append(p)
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		volume = clampf(float(cfg.get_value("audio", "music", volume)), 0.0, 1.0)
	_apply()


## Set, apply and keep the music volume.
func set_volume(v: float) -> void:
	volume = clampf(v, 0.0, 1.0)
	_apply()
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "music", volume)
	cfg.save(SAVE_PATH)


func _apply() -> void:
	var bus := AudioServer.get_bus_index(BUS)
	AudioServer.set_bus_volume_db(bus, linear_to_db(volume))
	AudioServer.set_bus_mute(bus, volume <= 0.0)


## Switch to `list` ("" for silence). The same list carries on.
func play(list: String) -> void:
	if list == _list:
		return
	_list = list
	if list == "":
		_song = ""
		_cross(null)
		return
	_next()


## Fade into another song of this list before the playing one runs out.
func _process(_delta: float) -> void:
	var p := _players[_on]
	if _list == "" or not p.playing or p.stream == null or (p.stream as AudioStreamOggVorbis).loop:
		return
	if p.stream.get_length() - p.get_playback_position() < FADE:
		_next()


func _next() -> void:
	var names: Array = PLAYLISTS[_list]
	var others := names.filter(func(n: String) -> bool: return n != _song)
	_song = str(others.pick_random() if not others.is_empty() else names[0])
	var song: AudioStreamOggVorbis = load(SONGS[_song][0])
	song.loop = names.size() == 1
	song.loop_offset = float(SONGS[_song][1])
	_cross(song)


## Fade the playing player out and `song` (null: nothing) in on the other.
func _cross(song: AudioStream) -> void:
	# A fade cut short leaves its outgoing song playing, quietly: stop it.
	if _fade != null and _fade.is_valid():
		_fade.kill()
	_players[1 - _on].stop()
	var old := _players[_on]
	_fade = create_tween().set_parallel(true)
	_fade.tween_method(func(v: float) -> void: old.volume_db = linear_to_db(v),
			db_to_linear(old.volume_db), 0.0, FADE)
	if song != null:
		_on = 1 - _on
		var fresh := _players[_on]
		fresh.stream = song
		fresh.volume_db = linear_to_db(0.0)
		fresh.play()
		_fade.tween_method(func(v: float) -> void: fresh.volume_db = linear_to_db(v),
				0.0, 1.0, FADE)
	_fade.chain().tween_callback(old.stop)

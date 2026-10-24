extends Node

## Lakbayin's global state: the match clock (read off the server's deadline),
## the session this phone is in, the player's profile and hero, and the input
## map. The match itself -- words, answers, deposits -- is `Match`'s.

signal time_changed(seconds_left: int)
signal adventure_started
## The clock ran out (or `end_adventure` was called): the match screen ends it.
signal adventure_ended(result: Dictionary)
## lobby / running / ended, as the session row says.
signal session_state_changed(state: String)

# --- Hero roster ------------------------------------------------------------
## Super Retro World character pack: 32 sheets, one per adventurer.
const HERO_COUNT := 32

## `--profile=NAME` (after `--`) gives a desktop window its own save, so three
## windows can be three players instead of one login three times.
var SAVE_PATH := "user://lakbayin%s.cfg" % profile_suffix()


## The live checks under `res://tools/` sign up throwaway accounts, and saved
## them over the real login. They get a profile of their own.
static func profile_suffix() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--profile="):
			return "-" + a.trim_prefix("--profile=")
	for a in OS.get_cmdline_args():
		if a.begins_with("res://tools/"):
			return "-tools"
	return ""


var adventure_active := false
var duration_seconds := 900.0
## Seconds left, read off a deadline rather than counted down frame by frame.
## Adding up frame deltas ran slow wherever frames stall -- a phone in the
## background, a window out of focus -- so every phone showed a different
## clock. Anything that sets it (a session row, the dev panel's +1:00) moves
## the deadline with it.
var time_left := 0.0:
	set(v):
		time_left = v
		_deadline = now() + v
var _deadline := 0.0
## Server time minus this device's clock, from the `Date` on every reply (see
## Backend.gd). Phones disagree by seconds to minutes; a deadline read against
## each one's own clock gave each a different countdown.
var clock_offset := 0.0
## The aerial view before the start holds Practice's clock. Unpausing starts
## the deadline again from what was left.
var clock_paused := false:
	set(v):
		clock_paused = v
		if not v:
			_deadline = now() + time_left

var player_name := ""
var team_name := ""
## The session this phone joined, kept across launches so it goes straight
## back in -- a dead phone mid-match must not lose its place.
var joined_session := ""
var joined_code := ""
var hero_id := 1
## How to Play has shown itself once on this device (HomeScreen).
var guide_seen := false


## Sheet for an adventurer. Kept here so every screen spells the path once.
static func hero_sheet(id: int) -> String:
	return "res://assets/characters/character_%d.png" % id


func _setup_input() -> void:
	var binds := {
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"move_up": [KEY_W, KEY_UP],
		"move_down": [KEY_S, KEY_DOWN],
		"interact": [KEY_E, KEY_SPACE, KEY_ENTER],
	}
	for action in binds:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in binds[action]:
			if not InputMap.action_has_event(action, _make_event(key)):
				InputMap.action_add_event(action, _make_event(key))
	# ui actions are built-in; map enter/esc to accept/cancel too.
	for pair in [["ui_accept", KEY_ENTER], ["ui_cancel", KEY_ESCAPE]]:
		if not InputMap.action_has_event(pair[0], _make_event(pair[1])):
			InputMap.action_add_event(pair[0], _make_event(pair[1]))


func _make_event(key: Key) -> InputEvent:
	var ev := InputEventKey.new()
	ev.keycode = key
	return ev


## Phones and tablets get on-screen controls; `--touch` forces them on a
## desktop run so the layout can be checked without a device.
var touch := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	touch = (DisplayServer.is_touchscreen_available() or OS.has_feature("mobile")
			or "--touch" in OS.get_cmdline_user_args())
	_setup_input()
	load_profile()


## The state of the session, "" in Practice.
var session_state := ""
## The session being played, "" in Practice.
var session_id := ""


## The time everyone's clock is read against: the server's, as near as this
## device can tell. Unix seconds.
func now() -> float:
	return Time.get_unix_time_from_system() + clock_offset


## "Thu, 25 Sep 2026 10:11:56 GMT" -> unix seconds, or 0.
static func http_date(v: String) -> int:
	var p := v.split(" ", false)
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	if p.size() < 5 or months.find(p[2]) == -1:
		return 0
	return Time.get_unix_time_from_datetime_string("%s-%02d-%02dT%s" % [
		p[3], months.find(p[2]) + 1, int(p[1]), p[4]])


## The server owns the clock: `ends_at` is the deadline while running. The
## local tick in `_process` only fills the gaps between updates, so a phone
## that joins late or sleeps still agrees with the room.
func apply_session(row: Dictionary) -> void:
	var state := str(row.get("state", ""))
	duration_seconds = float(int(row.get("duration_s", 900)))
	match state:
		"running":
			var ends := Time.get_unix_time_from_datetime_string(str(row.get("ends_at", "")))
			time_left = maxf(0.0, float(ends) - now())
			clock_paused = false
		"ended":
			time_left = 0.0
			clock_paused = true
		_:
			# lobby: the clock has not started.
			time_left = duration_seconds
			clock_paused = true
	session_state = state
	session_id = str(row.get("id", session_id))
	time_changed.emit(int(ceilf(time_left)))
	session_state_changed.emit(state)


func _process(_delta: float) -> void:
	if adventure_active and not clock_paused:
		time_left = maxf(0.0, _deadline - now())
		time_changed.emit(int(ceilf(time_left)))
		if time_left <= 0.0:
			end_adventure()


# --- The match's clock ------------------------------------------------------
func begin_adventure(seconds: int = 600) -> void:
	duration_seconds = float(seconds)
	time_left = duration_seconds
	adventure_active = true
	clock_paused = false
	# Last match's session must not leak into this one.
	session_id = ""
	session_state = ""
	adventure_started.emit()


## The clock stops, nothing more: the match screen has already ended the match.
func abandon_adventure() -> void:
	adventure_active = false


## The clock ran out.
func end_adventure() -> void:
	if not adventure_active:
		return
	adventure_active = false
	adventure_ended.emit({"time_up": time_left <= 0.0})


## A session's world seed: positive, never 0.
static func seed_of(session: String) -> int:
	return (hash(session) & 0x3FFFFFFF) + 1


# --- Profile ----------------------------------------------------------------
func load_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	player_name = cfg.get_value("profile", "name", "")
	team_name = cfg.get_value("profile", "team", "")
	joined_session = cfg.get_value("profile", "session", "")
	joined_code = cfg.get_value("profile", "code", "")
	hero_id = clampi(int(cfg.get_value("profile", "hero_id", 1)), 1, HERO_COUNT)
	guide_seen = bool(cfg.get_value("profile", "guide_seen", false))


func save_profile() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("profile", "name", player_name)
	cfg.set_value("profile", "team", team_name)
	cfg.set_value("profile", "session", joined_session)
	cfg.set_value("profile", "code", joined_code)
	cfg.set_value("profile", "hero_id", hero_id)
	cfg.set_value("profile", "guide_seen", guide_seen)
	cfg.save(SAVE_PATH)

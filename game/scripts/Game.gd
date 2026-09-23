extends Node

## NumXventure global run state: gems economy, adventure timer, scoring rules,
## player profile and persistence. Mirrors the rules in the game design doc.

signal gems_changed(gems: int)
signal time_changed(seconds_left: int)
signal adventure_started
signal adventure_ended(result: Dictionary)
## lobby / running / paused / ended, as the admin's session row says.
signal session_state_changed(state: String)

# --- Gems scoring rules (from the NumXventure design) -----------------------
const START_GEMS := 50
const GEM_CORRECT := 10
const GEM_WRONG := -5
const GEM_HINT := -5
const GEM_SKIP := -15
const GEM_PERFECT_BONUS := 10
const GEM_TEAM_FINISH_PENALTY := -25

# --- Adventure shape --------------------------------------------------------
const ITEMS_PER_STATION := [8, 3, 3]      # Station 1/2/3
const TOTAL_ITEMS := 14                   # sum of ITEMS_PER_STATION: one circle each
const DURATION_CHOICES := [300, 600, 900] # 5 / 10 / 15 minutes

# --- Hero roster ------------------------------------------------------------
## Super Retro World character pack: 32 sheets, one per adventurer.
const HERO_COUNT := 32

const SAVE_PATH := "user://numxventure.cfg"

# --- Palette (sampled from the pack) ---------------------------------------


var gems := START_GEMS
var correct := 0
var wrong := 0
var skipped := 0
var hints_used := 0

var adventure_active := false
var duration_seconds := 600.0
var time_left := 0.0

var current_station := 0          # 0-based index of the active quiz station
var items_done := 0               # global circle progress, 0..TOTAL_ITEMS
var towers_entered: Array[bool] = [false, false, false]  # station intro card seen
var clock_paused := false         # frozen aerial POV now; the admin's pause in Phase 3
var completed_stations: Array[bool] = [false, false, false]
var perfect_stations: Array[bool] = [false, false, false]
var station_flawed := false       # flags a "no errors" run inside the current station
var station_used_hint := false    # any hint this station -> no perfect bonus
var item_used_hint := false       # one hint per item; reset by the quiz per question

var player_name := ""
var team_name := ""
var hero_id := 1

var leaderboard: Array = []   # [{name, gems}]
var last_run: Dictionary = {}


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
		"pause": [KEY_ESCAPE],
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


## The state of the admin's session, "" when playing offline.
var session_state := ""
## The session the score belongs to, "" when playing offline.
var session_id := ""


## The server owns the clock (SPECS §3: "durungan an ira pag-answer dapat").
## `ends_at` is the deadline while running and `remaining_s` is what was banked
## at a pause; the local tick in `_process` only fills the gaps between
## updates, so a phone that joins late or sleeps still agrees with the room.
func apply_session(row: Dictionary) -> void:
	var state := str(row.get("state", ""))
	duration_seconds = float(int(row.get("duration_s", 600)))
	match state:
		"running":
			var ends := Time.get_unix_time_from_datetime_string(str(row.get("ends_at", "")))
			time_left = maxf(0.0, float(ends) - Time.get_unix_time_from_system())
			clock_paused = false
		"paused":
			# What the pause banked, not what this phone had counted to.
			time_left = float(int(row.get("remaining_s", 0)))
			clock_paused = true
		"ended":
			time_left = 0.0
			clock_paused = true
		_:
			# lobby: the board is up, the clock has not started.
			time_left = duration_seconds
			clock_paused = true
	session_state = state
	session_id = str(row.get("id", session_id))
	time_changed.emit(int(ceilf(time_left)))
	session_state_changed.emit(state)


## Something happened that changes the score. Whoever is online listens and
## forwards it; `Game` itself never names the backend, because `test_rules.gd`
## loads this file with `--script`, which registers no autoloads -- naming
## `Net` here hangs a suite instead of failing it.
##
## `kind` is answer / hint / skip / station; `flag` is correct, or perfect.
signal scored(kind: String, flag: bool)


func _process(delta: float) -> void:
	if adventure_active and not clock_paused and time_left > 0.0:
		time_left = maxf(0.0, time_left - delta)
		time_changed.emit(int(ceilf(time_left)))
		if time_left <= 0.0:
			end_adventure()


# --- Adventure lifecycle ----------------------------------------------------
func begin_adventure(seconds: int = 600) -> void:
	_gems_reset()
	duration_seconds = float(seconds)
	time_left = duration_seconds
	adventure_active = true
	clock_paused = false
	current_station = 0
	items_done = 0
	towers_entered = [false, false, false]
	completed_stations = [false, false, false]
	perfect_stations = [false, false, false]
	adventure_started.emit()


## Walking away from a run: dropped, not scored. No summary, no leaderboard row
## and no -25 for the stations left unfinished.
func abandon_adventure() -> void:
	adventure_active = false


## A do-over: same discard, then straight into a fresh run.
func restart_adventure() -> void:
	abandon_adventure()
	begin_adventure(int(duration_seconds))


func end_adventure() -> void:
	if not adventure_active:
		return
	adventure_active = false
	var finished_all := completed_stations.all(func(v: bool) -> bool: return v)
	var result := {
		"gems": gems,
		"correct": correct,
		"wrong": wrong,
		"skipped": skipped,
		"hints": hints_used,
		"completed": completed_stations,
		"perfect": perfect_stations,
		"finished_all": finished_all,
		"time_up": time_left <= 0.0,
	}
	if not finished_all:
		gems += GEM_TEAM_FINISH_PENALTY
		gems_changed.emit(gems)
		result.gems = gems
	last_run = result
	_register_leaderboard(me(), gems)
	save_profile()
	adventure_ended.emit(result)


## Who this run scores as: the team if one was joined, else the player. The
## client's winner is always a team, so this is the leaderboard's row key and
## the name the summary highlights.
func me() -> String:
	return team_name if team_name != "" else player_name


# --- Circle progress --------------------------------------------------------
## The 20/10/10 split is decoded in exactly these two places. `items_done` is a
## single global counter because the path is strictly sequential -- circle n+1
## cannot be resolved before n, so one number is the whole progress state.
static func station_of_item(i: int) -> int:
	var seen := 0
	for s in ITEMS_PER_STATION.size():
		seen += ITEMS_PER_STATION[s]
		if i < seen:
			return s
	return ITEMS_PER_STATION.size() - 1   # past the last circle: stay on station 3


static func item_in_station(i: int) -> int:
	var seen := 0
	for s in ITEMS_PER_STATION.size():
		if i < seen + ITEMS_PER_STATION[s]:
			return i - seen
		seen += ITEMS_PER_STATION[s]
	return ITEMS_PER_STATION[ITEMS_PER_STATION.size() - 1] - 1


# --- Gems bookkeeping -------------------------------------------------------
func _gems_reset() -> void:
	gems = START_GEMS
	correct = 0
	wrong = 0
	skipped = 0
	hints_used = 0
	station_flawed = false
	station_used_hint = false
	item_used_hint = false
	gems_changed.emit(gems)


func _apply(delta: int) -> void:
	gems = maxi(gems + delta, 0)
	gems_changed.emit(gems)


## One hint per item, -5 gems each (design doc: "Use of Hint: -5 gems").
func spend_hint() -> bool:
	if gems <= 0 or item_used_hint:
		return false
	item_used_hint = true
	station_used_hint = true
	hints_used += 1
	_apply(GEM_HINT)
	scored.emit("hint", false)
	return true


func begin_item() -> void:
	item_used_hint = false


func mark_wrong() -> void:
	wrong += 1
	items_done += 1
	station_flawed = true
	_apply(GEM_WRONG)
	scored.emit("answer", false)


func mark_correct() -> void:
	correct += 1
	items_done += 1
	_apply(GEM_CORRECT)
	scored.emit("answer", true)


func mark_skipped() -> void:
	skipped += 1
	items_done += 1
	station_flawed = true
	_apply(GEM_SKIP)
	scored.emit("skip", false)


## Call after finishing a station's last item.
func finish_station(station_index: int) -> int:
	var bonus := 0
	if not station_flawed and not station_used_hint:
		bonus = GEM_PERFECT_BONUS
		_apply(bonus)
	scored.emit("station", bonus > 0)
	completed_stations[station_index] = true
	perfect_stations[station_index] = bonus > 0
	station_flawed = false
	station_used_hint = false
	item_used_hint = false
	return bonus


# --- Profile / leaderboard persistence --------------------------------------
func load_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	player_name = cfg.get_value("profile", "name", "")
	team_name = cfg.get_value("profile", "team", "")
	hero_id = clampi(int(cfg.get_value("profile", "hero_id", 1)), 1, HERO_COUNT)
	leaderboard = cfg.get_value("leaderboard", "rows", leaderboard)


func save_profile() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("profile", "name", player_name)
	cfg.set_value("profile", "team", team_name)
	cfg.set_value("profile", "hero_id", hero_id)
	cfg.set_value("leaderboard", "rows", leaderboard)
	cfg.save(SAVE_PATH)


## The offline board: this machine's own runs, best score per team name. The
## four invented rival parties are gone -- they sat above real students on a
## board the client reads as a result.
func _register_leaderboard(entry_name: String, entry_gems: int) -> void:
	var best: Dictionary = {}
	for row in leaderboard:
		best[row.name] = maxi(int(row.gems), int(best.get(row.name, 0)))
	if entry_name != "":
		best[entry_name] = entry_gems   # this run replaces the player's old row
	best.erase("")
	var rows: Array = []
	for n in best:
		rows.append({"name": n, "gems": best[n]})
	rows.sort_custom(func(a, b): return a.gems > b.gems)
	leaderboard = rows.slice(0, 8)

extends Node

## NumXventure global run state: gems economy, adventure timer, scoring rules,
## player profile and persistence. Mirrors the rules in the game design doc.

signal gems_changed(gems: int)
signal time_changed(seconds_left: int)
signal adventure_started
signal adventure_ended(result: Dictionary)
## lobby / running / paused / ended, as the admin's session row says.
signal session_state_changed(state: String)
## Gems reached zero. The team is charged GEM_ELIMINATED once.
signal eliminated_changed

# --- Gems scoring rules (from the NumXventure design) -----------------------
const START_GEMS := 50
const GEM_CORRECT := 10
const GEM_WRONG := -5
const GEM_HINT := -5
const GEM_SKIP := -15
const GEM_PERFECT_BONUS := 10
const GEM_TEAM_FINISH_PENALTY := -25
## Charged to the team the first time a member reaches zero gems.
const GEM_ELIMINATED := -50

# --- Adventure shape --------------------------------------------------------
const ITEMS_PER_STATION := [8, 3, 3]      # Station 1/2/3
const TOTAL_ITEMS := 14                   # sum of ITEMS_PER_STATION: one circle each
const DURATION_CHOICES := [300, 600, 900] # 5 / 10 / 15 minutes

# --- Hero roster ------------------------------------------------------------
## Super Retro World character pack: 32 sheets, one per adventurer.
const HERO_COUNT := 32

## `--profile=NAME` (after `--`) gives a desktop window its own save, so three
## windows can be a teacher and two students instead of one login three times.
var SAVE_PATH := "user://numxventure%s.cfg" % profile_suffix()


##
## The live checks under `res://tools/` sign up throwaway accounts, and saved
## them over the real login -- the teacher's window came back as a test admin
## that owned none of the class's sessions. They get a profile of their own.
static func profile_suffix() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--profile="):
			return "-" + a.trim_prefix("--profile=")
	for a in OS.get_cmdline_args():
		if a.begins_with("res://tools/"):
			return "-tools"
	return ""

# --- Palette (sampled from the pack) ---------------------------------------


var gems := START_GEMS
var correct := 0
var wrong := 0
var skipped := 0
var hints_used := 0

var adventure_active := false
var duration_seconds := 600.0
## Seconds left, read off a deadline rather than counted down frame by frame.
## Adding up frame deltas ran slow wherever frames stall -- a phone in the
## background, a window out of focus -- so every board in the room showed a
## different clock, and none the teacher's. Anything that sets it (a session
## row, the dev drawer's +60) moves the deadline with it.
var time_left := 0.0:
	set(v):
		time_left = v
		_deadline = now() + v
var _deadline := 0.0
## Server time minus this device's clock, from the `Date` on every reply (see
## Supabase.gd). Phones in one classroom disagree by seconds to minutes; a
## deadline read against each one's own clock gave each a different countdown.
var clock_offset := 0.0

var current_station := 0          # 0-based index of the active quiz station
var items_done := 0               # global circle progress, 0..TOTAL_ITEMS
var towers_entered: Array[bool] = [false, false, false]  # station intro card seen
## Frozen aerial POV, and the admin's pause. Unpausing starts the deadline
## again from what was left.
var clock_paused := false:
	set(v):
		clock_paused = v
		if not v:
			_deadline = now() + time_left
var completed_stations: Array[bool] = [false, false, false]
var perfect_stations: Array[bool] = [false, false, false]
var station_flawed := false       # flags a "no errors" run inside the current station
var station_used_hint := false    # any hint this station -> no perfect bonus
var item_used_hint := false       # one hint per item; reset by the quiz per question

var player_name := ""
var team_name := ""
## The session this phone joined by code, kept across launches so Continue
## Quest goes straight back in -- a dead phone mid-lesson must not need the
## code read out again. `session_id` is the run being played; this is the door.
var joined_session := ""
var joined_code := ""
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
## Latches once. An eliminated player keeps answering -- the penalty is already
## taken, and benching a student for the rest of a proctored class is the worse
## outcome -- but the team is only ever charged for it once.
var eliminated := false
## One assist per sender per adventure -- the paper's "to assist one member
## only". The server enforces it; this only keeps the button honest.
var rescue_sent := false
## The session the score belongs to, "" when playing offline.
var session_id := ""


## The server owns the clock (SPECS §3: "durungan an ira pag-answer dapat").
## `ends_at` is the deadline while running and `remaining_s` is what was banked
## at a pause; the local tick in `_process` only fills the gaps between
## updates, so a phone that joins late or sleeps still agrees with the room.
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


func apply_session(row: Dictionary) -> void:
	var state := str(row.get("state", ""))
	duration_seconds = float(int(row.get("duration_s", 600)))
	match state:
		"running":
			var ends := Time.get_unix_time_from_datetime_string(str(row.get("ends_at", "")))
			time_left = maxf(0.0, float(ends) - now())
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


func _process(_delta: float) -> void:
	if adventure_active and not clock_paused and time_left > 0.0:
		time_left = maxf(0.0, _deadline - now())
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
	eliminated = false
	rescue_sent = false
	current_station = 0
	items_done = 0
	towers_entered = [false, false, false]
	completed_stations = [false, false, false]
	perfect_stations = [false, false, false]
	# Last run's session must not leak into this one: an `ended` state left
	# over would refuse every answer until the fresh fetch landed.
	session_id = ""
	session_state = ""
	adventure_started.emit()


## Only while the clock runs does an answer count. The server refuses a score
## outside `running`, so a phone that took one locally anyway would walk on
## ahead of its own row and the team total would never see it.
func can_score() -> bool:
	return session_state == "" or session_state == "running"


## Back into a run already under way -- a phone that died, an app restarted,
## "Join Quest" after leaving the board. The server's member row is the
## progress; a fresh local run would put the player back on circle 1 while
## every answer still moved the server's counter on from where it was.
func restore_from(row: Dictionary) -> void:
	gems = int(row.get("gems", START_GEMS))
	correct = int(row.get("correct", 0))
	items_done = clampi(int(row.get("items_done", 0)), 0, TOTAL_ITEMS)
	wrong = maxi(items_done - correct, 0)   # wrong and skipped are not kept apart
	eliminated = bool(row.get("eliminated", false))
	rescue_sent = row.get("rescued_at") != null
	current_station = station_of_item(items_done)
	var end := 0
	for s in ITEMS_PER_STATION.size():
		var start := end
		end += ITEMS_PER_STATION[s]
		completed_stations[s] = items_done >= end
		# Past its first circle means its briefing was read.
		towers_entered[s] = items_done > start
	gems_changed.emit(gems)


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


## No clamp. Gems reach zero and the player is eliminated -- the paper's
## "Eliminated Member (reaching 0 gems): -50 gems", which could never fire
## while this floored at zero. The -50 is charged once, by `eliminated`
## latching, so a run cannot keep billing the team.
func _apply(delta: int) -> void:
	gems += delta
	if gems <= 0 and not eliminated:
		eliminated = true
		eliminated_changed.emit()
	gems_changed.emit(gems)


## One hint per item, -5 gems each (design doc: "Use of Hint: -5 gems").
func spend_hint() -> bool:
	if item_used_hint:
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


## Through the Victory Gate: the server records this player's own time.
func mark_finished() -> void:
	scored.emit("finish", true)


## Ten gems to a team-mate, already applied on the server.
func mark_rescue_sent() -> void:
	rescue_sent = true
	_apply(-10)


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
	joined_session = cfg.get_value("profile", "session", "")
	joined_code = cfg.get_value("profile", "code", "")
	hero_id = clampi(int(cfg.get_value("profile", "hero_id", 1)), 1, HERO_COUNT)
	leaderboard = cfg.get_value("leaderboard", "rows", leaderboard)


func save_profile() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("profile", "name", player_name)
	cfg.set_value("profile", "team", team_name)
	cfg.set_value("profile", "session", joined_session)
	cfg.set_value("profile", "code", joined_code)
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

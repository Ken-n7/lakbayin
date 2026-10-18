class_name PosHub
extends Node

## The teacher's screen as the class's position hub, the way a battle royale
## server works: every student's phone sends its hero's position on a channel
## of its own that only this teacher joins (`Realtime.in_topic`), and this
## sends everyone ONE snapshot of all who moved, SNAP_S apart, on the session's
## snapshot channel. Every student still sees every other walk.
##
## Why: sent straight to the whole class, each position reached every phone --
## players x players deliveries -- and Supabase's free tier cut a class of 30
## off. Through here it is players x 2 plus a snapshot per phone: measured at
## ~155 messages a second for 30 walking, 99-100% delivered (tools/sim
## classroom.py --move --channel hub; MERGE_CHECKLIST "Server load").
##
## Lives on Game Controls: the teacher keeps it open while the class plays.
## If it goes, no snapshots come and the phones' heroes fall back to their
## towers (Peers.STALE_S); answers and gems never pass through here.

## Three a second: each phone's path comes a bundle every half second
## (AdventureScreen.BUNDLE_S); a third of a second is the most one waits here.
const SNAP_S := 1.0 / 3.0
## What a phone needs of a message: who, their path (`p`, a bundle), or a lone
## position from an older sender. Name and team come with the roster
## (Peers.refresh), the session from the channel.
const KEEP_KEYS := ["id", "hero", "p", "x", "y", "ts", "sent"]

var _sid := ""
var _players: Array = []
## profile id -> their latest position since the last snapshot.
var _moved := {}
## profile id -> their progress row since the last snapshot ({} once gone).
## Phones used to get every classmate's row from the database on every
## answer -- 31 deliveries an answer; it rides in the snapshot instead, and a
## phone's own feed carries only its own row.
var _rows := {}
const ROW_KEYS := ["profile_id", "team_id", "items_done", "gems", "eliminated"]
var _clock := 0.0
## The bridge. Phones that cannot reach the movement relay (a school filter,
## a dead tunnel) still send here; while any has in the last BRIDGE_S, every
## snapshot also carries the relay's students -- so those phones see the
## whole class, and the relay's phones, which hear these snapshots for the
## progress rows anyway, see them. Nobody on the hub path: nothing bridged,
## no extra messages. Points kept BRIDGE_STEP_S apart, the hub's own pace.
const BRIDGE_S := 10.0
const BRIDGE_STEP_S := 0.1
var _bridge := {}                # profile id -> {id, hero, p: [[t, x, y], ...]}
var _hub_path_at := -INF
var bridged_out := 0
## For HubDebug: totals since the hub started, and each player's last position
## (when it came in, where).
var pos_in := 0
var snaps_out := 0
var heroes_out := 0
var rows_out := 0
var last_seen := {}         # profile id -> [ticks_msec, x, y]


func _ready() -> void:
	var rt: Realtime = Net.realtime()
	if not rt.position.is_connected(_on_broadcast):
		rt.position.connect(_on_broadcast)
	if not rt.changed.is_connected(_on_row):
		rt.changed.connect(_on_row)
	if not Net.relay().snap.is_connected(_on_relay_snap):
		Net.relay().snap.connect(_on_relay_snap)


## Follow `session_id`'s players: their channels in, the snapshot channel out.
## Called again whenever the roster changes; only a change re-joins.
func follow(session_id: String, player_ids: Array) -> void:
	var ids := player_ids.duplicate()
	ids.sort()
	if session_id == _sid and ids == _players:
		return
	_sid = session_id
	_players = ids
	if _sid == "":
		Net.realtime().watch_positions([])
		return
	var topics: Array = ids.map(func(id: String) -> String: return Realtime.in_topic(_sid, id))
	topics.append(Realtime.snap_topic(_sid))
	Net.realtime().watch_positions(topics)


func stop() -> void:
	follow("", [])
	_moved = {}
	_rows = {}
	_bridge = {}


## Some phone is on the hub path right now.
func bridging() -> bool:
	return Time.get_ticks_msec() / 1000.0 - _hub_path_at < BRIDGE_S


func _on_relay_snap(entries: Array) -> void:
	if _sid == "" or not bridging():
		return
	for e: Dictionary in entries:
		var id := str(e.get("id", ""))
		var got: Dictionary = _bridge.get(id, {"id": id, "hero": e.get("hero", 1), "p": []})
		var pts: Array = got.p
		for q: Array in e.get("p", []):
			if pts.is_empty() or float(q[0]) - float(pts[-1][0]) >= BRIDGE_STEP_S - 0.001:
				pts.append(q)
		_bridge[id] = got


## Game Controls watches this session's members: each change, kept for the
## next snapshot. Deletes come unfiltered, matched against who is followed.
func _on_row(table: String, type: String, record: Dictionary) -> void:
	if table != "members" or _sid == "":
		return
	var pid := str(record.get("profile_id", ""))
	if type == "DELETE":
		if _players.has(pid):
			_rows[pid] = {"profile_id": pid, "gone": true}
		return
	if str(record.get("session_id", "")) != _sid:
		return
	var row := {}
	for k: String in ROW_KEYS:
		if record.has(k):
			row[k] = record[k]
	_rows[pid] = row


func _on_broadcast(event: String, data: Dictionary) -> void:
	if event == "pos" and _sid != "" and str(data.get("sid", "")) == _sid:
		var slim := {}
		for k: String in KEEP_KEYS:
			if data.has(k):
				slim[k] = data[k]
		_moved[str(data.get("id", ""))] = slim
		_hub_path_at = Time.get_ticks_msec() / 1000.0
		pos_in += 1
		var at := Vector2(float(data.get("x", 0)), float(data.get("y", 0)))
		var p: Variant = data.get("p")
		if p is Dictionary and not (p.get("x", []) as Array).is_empty():
			at = Vector2(float(p.x[-1]), float(p.y[-1]))
		last_seen[str(data.get("id", ""))] = [Time.get_ticks_msec(), int(at.x), int(at.y)]


func _process(delta: float) -> void:
	_clock -= delta
	if _clock > 0.0:
		return
	_clock = SNAP_S
	var snap := take_snapshot()
	if not snap.is_empty():
		Net.realtime().send_position(Realtime.snap_topic(_sid), snap, "snap")


## Everything since the last snapshot, as the next one -- {} if nothing
## happened -- and the slate wiped for the one after.
func take_snapshot() -> Dictionary:
	if not bridging():
		_bridge = {}
	if _sid == "" or (_moved.is_empty() and _rows.is_empty() and _bridge.is_empty()):
		return {}
	var snap := {"sid": _sid, "p": _moved.values() + _bridge.values()}
	if not _rows.is_empty():
		snap["r"] = _rows.values()
	snaps_out += 1
	heroes_out += _moved.size()
	rows_out += _rows.size()
	bridged_out += _bridge.size()
	_moved = {}
	_rows = {}
	_bridge = {}
	return snap


func _exit_tree() -> void:
	if _sid != "":
		Net.realtime().watch_positions([])

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

## Three a second: each phone's positions already come a second apart walking
## straight (AdventureScreen.POS_EVERY_S), so a fourth bought ~0.1s of lag for
## 30 more deliveries a second.
const SNAP_S := 1.0 / 3.0
## What a phone needs of a position: who, where, which way. Its name and team
## come with the roster (Peers.refresh), the session from the channel.
const KEEP_KEYS := ["id", "hero", "x", "y", "vx", "vy", "ts", "face", "moving", "sent"]

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


func _ready() -> void:
	var rt: Realtime = Net.realtime()
	if not rt.broadcast.is_connected(_on_broadcast):
		rt.broadcast.connect(_on_broadcast)
	if not rt.changed.is_connected(_on_row):
		rt.changed.connect(_on_row)


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


func _process(delta: float) -> void:
	_clock -= delta
	if _clock > 0.0:
		return
	_clock = SNAP_S
	if _sid == "" or (_moved.is_empty() and _rows.is_empty()):
		return
	var snap := {"sid": _sid, "p": _moved.values()}
	if not _rows.is_empty():
		snap["r"] = _rows.values()
	Net.realtime().send_position(Realtime.snap_topic(_sid), snap, "snap")
	_moved = {}
	_rows = {}


func _exit_tree() -> void:
	if _sid != "":
		Net.realtime().watch_positions([])

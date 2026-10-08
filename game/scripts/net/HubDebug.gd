class_name HubDebug
extends PanelContainer

## Debug builds only: what the teacher's screen is sending and receiving, live.
## Game Controls adds it when the game is started with `-- --hub-debug`, or
## from the dev navigator. Rates are per second over the last second; the log
## is the newest messages, << in and >> out.
##
##   godot --path game -- --hub-debug

var gc: Node                   # the GameControlsScreen it reports on
var _text: Label
var _last := {}                # counter -> value a second ago
var _clock := 0.0


func _ready() -> void:
	var face := StyleBoxFlat.new()
	face.bg_color = Color(0.05, 0.06, 0.08, 0.82)
	face.set_corner_radius_all(4)
	face.content_margin_left = 6.0
	face.content_margin_right = 6.0
	face.content_margin_top = 4.0
	face.content_margin_bottom = 4.0
	add_theme_stylebox_override("panel", face)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text = Label.new()
	_text.add_theme_font_override("font", SystemFont.new())
	_text.add_theme_font_size_override("font_size", 7)
	_text.add_theme_color_override("font_color", Color(0.75, 1.0, 0.8))
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_text)
	Net.realtime().debug = true


func _exit_tree() -> void:
	if Net.realtime() != null:
		Net.realtime().debug = false


func _process(delta: float) -> void:
	_clock -= delta
	if _clock > 0.0:
		return
	_clock = 1.0
	_text.text = _report()


func _rate(key: String, now: int) -> int:
	var was: int = _last.get(key, now)
	_last[key] = now
	return now - was


func _report() -> String:
	var rt: Realtime = Net.realtime()
	var hub: PosHub = gc.get("_hub")
	var lines: PackedStringArray = []
	lines.append("HUB DEBUG   line %s   rtt %dms   silent %.1fs   socket %s" % [
		Net.connection(), int(rt.rtt * 1000.0), rt.silent_for(),
		["connecting", "open", "closing", "closed"][rt.get_ws_state()]])
	# Every kind of message, in and out, this last second.
	var in_total := 0
	var out_total := 0
	var kinds: PackedStringArray = []
	for k: String in rt.received:
		in_total += int(rt.received[k])
	for k: String in rt.sent:
		out_total += int(rt.sent[k])
	var all := {}
	for k in rt.received.keys() + rt.sent.keys():
		all[k] = true
	for k: String in all:
		kinds.append("%s %d/%d" % [k, int(rt.received.get(k, 0)), int(rt.sent.get(k, 0))])
	lines.append("this second: %d in, %d out   (in/out) %s" % [in_total, out_total, "  ".join(kinds)])
	rt.received = {}
	rt.sent = {}
	if hub != null:
		lines.append("hub: %d players followed   positions in %d/s   snapshots out %d/s (%d heroes, %d rows)" % [
			(hub.get("_players") as Array).size(), _rate("pos", hub.pos_in),
			_rate("snaps", hub.snaps_out), _rate("heroes", hub.heroes_out), _rate("rows", hub.rows_out)])
	else:
		lines.append("hub: not running (no session yet)")
	var relay: RelayLink = Net.get("_relay")
	if is_instance_valid(relay):
		lines.append("relay: %s  %s  rtt %dms  %d on it  snapshots in %d/s  bridge %s (%d heroes/s)" % [
			"UP" if relay.up else "down (%s)" % relay.last_close, relay.host, int(relay.rtt * 1000.0),
			relay.get("_roster").size(), _rate("relay_snaps", relay.snaps_in),
			"ON" if hub != null and hub.bridging() else "off",
			_rate("bridged", hub.bridged_out) if hub != null else 0])
	# Each player: where Game Controls has them, and their last position.
	var lobby: Variant = gc.get("_lobby")
	var players: Dictionary = lobby.get("players") if lobby != null else {}
	var now := Time.get_ticks_msec()
	for pid: String in players:
		var name: String = str(players[pid].get("username", "?"))
		var where := "map" if gc.call("_is_ready", pid) else ("lobby" if gc.call("_is_here", pid) else "away")
		var seen := "no position yet"
		if hub != null and hub.last_seen.has(pid):
			var s: Array = hub.last_seen[pid]
			seen = "pos %.1fs ago at (%d,%d)" % [(now - int(s[0])) / 1000.0, int(s[1]), int(s[2])]
		lines.append("  %-18s %-5s %s" % [name.left(18), where, seen])
	lines.append("--- last messages (<< in, >> out) ---")
	for l in rt.log_lines:
		lines.append(l)
	return "\n".join(lines)

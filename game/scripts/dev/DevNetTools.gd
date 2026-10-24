class_name DevNetTools
extends RefCounted

## The dev panel's Network tab (DevPanel), on every screen: how this device's
## line to the server is doing right now, and the switches for testing it.

var _readout: Label
var buttons := {}           # switch name -> Button (the panel's tests press them)


func build(tree: SceneTree) -> Control:
	buttons = {}
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.add_child(DevUi.heading("Now"))
	_readout = DevUi.note("", 10)
	col.add_child(_readout)
	col.add_child(DevUi.heading("Switches"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	col.add_child(grid)
	for spec: Array in [["Force IPv4", "force_v4"], ["Log realtime", "log"]]:
		var b := DevUi.button(String(spec[0]))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_flip.bind(String(spec[1]), tree))
		grid.add_child(b)
		buttons[String(spec[1])] = b
	col.add_child(DevUi.note("Force IPv4: connect by the server's IPv4 address, the path for "
		+ "networks with broken IPv6. Log realtime: every socket message to the console.", 9))
	_marks()
	refresh(tree)
	return col


func _flip(what: String, tree: SceneTree) -> void:
	match what:
		"force_v4":
			Dial.force_v4 = not Dial.force_v4
			Dial.forget_all()            # dialed afresh on the next connection
		"log":
			Realtime.log_traffic = not Realtime.log_traffic
	DevPanel.save_switches()
	_marks()
	refresh(tree)


func _marks() -> void:
	DevUi.mark(buttons.force_v4, Dial.force_v4)
	DevUi.mark(buttons.log, Realtime.log_traffic)


func refresh(tree: SceneTree) -> void:
	if _readout != null and is_instance_valid(_readout):
		_readout.text = "\n".join(lines(tree))


## The readout, one line per thing; also what tests and docs quote.
static func lines(tree: SceneTree) -> PackedStringArray:
	var out := PackedStringArray()
	if Net.http_ok + Net.http_failed == 0:
		out.append("Line  %s · no calls yet" % Net.connection())
	else:
		out.append("Line  %s · HTTP %d ms typical · %d ok, %d failed" % [Net.connection(),
			int(float(Net.get("_rest_rtt")) * 1000.0), Net.http_ok, Net.http_failed])
	var rt: Realtime = Net.get("_realtime")
	if is_instance_valid(rt):
		out.append("Realtime  %s (%s) · rtt %d ms · quiet %.1f s · opened %d, dropped %d" % [
			["connecting", "open", "closing", "closed"][rt.get_ws_state()], rt.socket_kind(),
			int(rt.rtt * 1000.0), rt.silent_for(), rt.opens, rt.closes])
	else:
		out.append("Realtime  not started")
	for host: String in Dial.last:
		var d: Dictionary = Dial.last[host]
		out.append("Address  %s: %s (of %d) in %d ms" % [host.get_slice(".", 0),
			"by name" if str(d.pick) == "" else "pinned " + str(d.pick), (d.addrs as Array).size(), int(d.ms)])
	var buffer := _buffer_ms(tree)
	out.append("Playback  %s" % ("%d ms behind" % buffer if buffer >= 0 else "no other heroes"))
	return out


## How far behind the other heroes are played back (Peers), in ms: the
## buffer that smooths their walks over the network's jitter.
static func _buffer_ms(tree: SceneTree) -> int:
	var peers: Node = tree.get_first_node_in_group("peers")
	if peers == null:
		return -1
	var lags: Array = (peers.get("_live") as Dictionary).values().map(
		func(g: Dictionary) -> float: return float(g.get("lag", 0.0)))
	if lags.is_empty():
		return -1
	return int(lags.reduce(func(a: float, b: float) -> float: return a + b, 0.0) / lags.size() * 1000.0)

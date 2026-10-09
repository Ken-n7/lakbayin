class_name DevNetTools
extends RefCounted

## The dev panel's Network tab (DevPanel), on every screen: how this device's
## connections are doing right now, and the switches for testing them. What a
## phone's NetReport sends the laptop, readable on the phone itself.

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
	for spec: Array in [["Relay off", "relay_off"], ["Echo ghost", "echo"], ["Reports", "reports"],
			["Force IPv4", "force_v4"], ["Log realtime", "log"]]:
		var b := DevUi.button(String(spec[0]))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_flip.bind(String(spec[1]), tree))
		grid.add_child(b)
		buttons[String(spec[1])] = b
	col.add_child(DevUi.note("Relay off: this device uses the teacher's hub, as if the relay were "
		+ "blocked. Echo ghost: your own walk drawn as the relay returns it. Force IPv4: the "
		+ "path for networks with broken IPv6. Log realtime: every socket message to the console.", 9))
	_marks(tree)
	refresh(tree)
	return col


func _flip(what: String, tree: SceneTree) -> void:
	match what:
		"relay_off":
			Net.relay().set_off(not RelayLink.off)
		"echo":
			RelayLink.echo = not RelayLink.echo
		"reports":
			NetReport.enabled = not NetReport.enabled
		"force_v4":
			Dial.force_v4 = not Dial.force_v4
			Dial.forget_all()            # dialed afresh on the next connection
		"log":
			Realtime.log_traffic = not Realtime.log_traffic
	DevPanel.save_switches()
	_marks(tree)
	refresh(tree)


func _marks(tree: SceneTree) -> void:
	DevUi.mark(buttons.relay_off, RelayLink.off)
	DevUi.mark(buttons.echo, RelayLink.echo)
	DevUi.mark(buttons.reports, NetReport.enabled and _reporter(tree) != null)
	buttons.reports.disabled = _reporter(tree) == null
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
	var relay: RelayLink = Net.get("_relay")
	if not is_instance_valid(relay):
		out.append("Relay  not joined")
	elif relay.up:
		var e := relay.echo_ms()
		out.append("Relay  UP %d/s%s · rtt %d ms%s%s" % [relay.hz,
			" (weak line: %d/s)" % relay.rate if relay.rate > 0 and relay.rate < relay.hz else "",
			int(relay.rtt * 1000.0),
			" · echo %d/%d/%d ms" % e if e.size() == 3 else "",
			" · buffer %d ms" % _buffer_ms(tree) if _buffer_ms(tree) >= 0 else ""])
	else:
		out.append("Relay  down: %s" % (relay.last_close if relay.last_close != "" else "connecting"))
	var host: Node = tree.get_first_node_in_group("relay_host")
	if host != null:
		out.append("Backup relay  %s%s" % [host.get("state"),
			" at " + Dial.host_of(str(host.get("url"))) if str(host.get("url")) != "" else ""])
	var rep: Node = _reporter(tree)
	out.append("Reports  %s" % ("phones only (debug builds)" if rep == null
		else "off" if not NetReport.enabled
		else "sent %d, lost %d" % [int(rep.get("_sent")), int(rep.get("_lost"))]))
	return out


static func _reporter(tree: SceneTree) -> Node:
	for c in Net.get_children():
		if c is NetReport:
			return c
	return null


## The playback buffer of the heroes played from the relay (Peers), in ms.
static func _buffer_ms(tree: SceneTree) -> int:
	var peers: Node = tree.get_first_node_in_group("peers")
	if peers == null:
		return -1
	var lags: Array = (peers.get("_live") as Dictionary).values().filter(
		func(g: Dictionary) -> bool: return bool(g.get("fast", false))).map(
		func(g: Dictionary) -> float: return float(g.get("lag", 0.0)))
	if lags.is_empty():
		return -1
	return int(lags.reduce(func(a: float, b: float) -> float: return a + b, 0.0) / lags.size() * 1000.0)

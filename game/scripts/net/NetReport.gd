class_name NetReport
extends Node

## Debug builds on a phone: every EVERY_S, how this phone's network is
## treating the game, sent to the laptop over Supabase's REST broadcast on
## TOPIC -- no table, nothing kept on the server. Read it on the laptop with
##   python3 tools/sim/netreport_listen.py
##
## Over HTTP rather than the socket so a report still goes when the socket
## cannot (the case worth hearing about); reports that fail are counted and
## the next one says so.

const TOPIC := "netreport"
const EVERY_S := 10.0
const FIRST_S := 3.0

var _clock := FIRST_S
var _sent := 0
var _lost := 0
var _busy := false


func _process(delta: float) -> void:
	_clock -= delta
	if _clock > 0.0 or _busy:
		return
	_clock = EVERY_S
	_send()


func _send() -> void:
	_busy = true
	var got: Dictionary = await Net.broadcast_rest(TOPIC, "report", report())
	if str(got.get("error", "")) == "":
		_sent += 1
	else:
		_lost += 1
	_busy = false


func report() -> Dictionary:
	var rt: Realtime = Net.get("_realtime")         # not made here if nothing opened one
	var r := {
		"up_s": snappedf(Time.get_ticks_msec() / 1000.0, 0.1),
		"device": OS.get_model_name(),
		"os": "%s %s" % [OS.get_name(), OS.get_version()],
		"user": Net.username,
		"line": Net.connection(),
		# This phone's own addresses: which network it is on (a hotspot's
		# 10.x, a home router's 192.168.x, a carrier's IPv6 prefix).
		"local": Array(IP.get_local_addresses()).filter(
			func(a: String) -> bool: return not a.begins_with("127.") and a != "::1" and not a.begins_with("fe80")),
		"dial": Dial.last,
		"http": {"ok": Net.http_ok, "failed": Net.http_failed, "last_failure": Net.http_last_failure,
			"rtt_ms": int(float(Net.get("_rest_rtt")) * 1000.0)},
		"reports": {"sent": _sent, "lost": _lost},
	}
	var relay: RelayLink = Net.get("_relay")
	if is_instance_valid(relay):
		r["relay"] = {"up": relay.up, "host": relay.host, "rtt_ms": int(relay.rtt * 1000.0),
			"hz": relay.hz, "snaps": relay.snaps_in, "last_close": relay.last_close,
			"echo_ms": relay.echo_ms(), "lag_ms": _relay_lag_ms()}
	if is_instance_valid(rt):
		r["rt"] = {"socket": rt.socket_kind(), "state": rt.get_ws_state(), "rtt_ms": int(rt.rtt * 1000.0),
			"silent_s": snappedf(rt.silent_for(), 0.1), "opens": rt.opens, "closes": rt.closes,
			"first_open_s": snappedf(rt.first_open_s, 0.1)}
	return r


## The playback buffer of the heroes this phone is playing from the relay,
## in ms (Peers): what is shown behind is about the fastest trip plus this.
func _relay_lag_ms() -> int:
	var peers: Node = get_tree().get_first_node_in_group("peers")
	if peers == null:
		return -1
	var lags: Array = (peers.get("_live") as Dictionary).values().filter(
		func(g: Dictionary) -> bool: return bool(g.get("fast", false))).map(
		func(g: Dictionary) -> float: return float(g.get("lag", 0.0)))
	if lags.is_empty():
		return -1
	return int(lags.reduce(func(a: float, b: float) -> float: return a + b, 0.0) / lags.size() * 1000.0)

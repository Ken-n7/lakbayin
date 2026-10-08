class_name Dial
extends RefCounted

## Which of a server's addresses actually answers on this network.
##
## Godot tries a name's addresses one at a time, IPv6 first, and waits on each
## until the phone gives up -- 31s on Android -- before the next. On a network
## whose IPv6 is broken that is every request: found on a phone on a home WiFi
## (DNS64, 2026-10-08) where Supabase's two IPv6 addresses never answered and
## its IPv4 ones did in 50ms. Every HTTP call hit its 12s timeout, the session
## could not be restored, and Realtime opened after 61s.
##
## So: dial every address at once, keep the first to answer. "" when Godot's
## own first choice is that one (the usual case -- nothing changes); otherwise
## the IPv4 address to connect to instead, with the name still used for the
## certificate and the Host header (Supabase._call, PinnedSocket).

const RACE_S := 4.0
## How much longer the first address gets once another has answered.
const GRACE_S := 0.3

## host -> "" (connect by name) or the address to use. Kept until forget():
## a request that cannot get through forgets, and the next one dials again.
static var _picked := {}
static var _dialing := {}
## host -> what the last dial saw: {addrs, pick, ms, resolve_ms}. For NetReport.
static var last := {}
## Take the pinned IPv4 path even where nothing is broken: the dev panel's
## "Force IPv4" switch, and `NUMX_DIAL=v4` for scripts.
static var force_v4 := false


static func address(host: String, port := 443) -> String:
	if host == "" or host.is_valid_ip_address():
		return ""
	var tree := Engine.get_main_loop() as SceneTree
	while _dialing.has(host):           # someone else is dialing it: share the answer
		await tree.process_frame
	if _picked.has(host):
		return _picked[host]
	_dialing[host] = true
	var t0 := Time.get_ticks_msec()
	var all := await _resolve(host, tree)
	var resolved_ms := Time.get_ticks_msec() - t0
	var pick := ""
	if force_v4 or OS.get_environment("NUMX_DIAL") == "v4":
		# Tests: take the IPv4 path on a network where nothing is broken.
		pick = _first_v4(all)
	else:
		pick = choose(all, await race(all, port, RACE_S))
	_picked[host] = pick
	last[host] = {"addrs": all, "pick": pick, "ms": Time.get_ticks_msec() - t0, "resolve_ms": resolved_ms}
	_dialing.erase(host)
	return pick


static func forget(host: String) -> void:
	_picked.erase(host)


## Every host dialed afresh on its next connection (after `force_v4` changes).
static func forget_all() -> void:
	_picked.clear()


## "https://name:port/path" -> "name".
static func host_of(url: String) -> String:
	var rest := url.get_slice("://", 1) if "://" in url else url
	rest = rest.get_slice("/", 0)
	if rest.begins_with("["):
		return rest.get_slice("]", 0).trim_prefix("[")
	return rest.get_slice(":", 0)


## The race's winner against the order Godot would try: nothing to do when it
## is the first; its IPv4 address (or the first IPv4 one) when it is not.
static func choose(all: Array, winner: String) -> String:
	if winner == "" or all.is_empty() or winner == str(all[0]):
		return ""
	if _is_v4(winner):
		return winner
	# ponytail: an IPv6 winner behind a dead first address would need [brackets]
	# in every URL; an IPv4 one is simpler and Android reaches IPv4 everywhere.
	return _first_v4(all)


## Connect to every address at once. The first address -- the one Godot
## would use -- wins if it answers at all within GRACE_S of the quickest, so a
## working network keeps its usual path (two healthy addresses race within
## milliseconds of each other); otherwise the quickest. "" if none answers
## within `limit_s`, and Godot's own order is all there is.
static func race(addrs: Array, port: int, limit_s: float) -> String:
	var tree := Engine.get_main_loop() as SceneTree
	var tries: Array = []
	for a in addrs:
		var tcp := StreamPeerTCP.new()
		if tcp.connect_to_host(str(a), port) == OK:
			tries.append([str(a), tcp])
	var first := str(addrs[0]) if not addrs.is_empty() else ""
	var answered: Array[String] = []
	var answered_at := 0
	var winner := ""
	var t0 := Time.get_ticks_msec()
	while winner == "" and Time.get_ticks_msec() - t0 < limit_s * 1000.0:
		var first_pending := false
		for t: Array in tries.duplicate():
			var tcp: StreamPeerTCP = t[1]
			tcp.poll()
			var s := tcp.get_status()
			if s == StreamPeerTCP.STATUS_CONNECTED and not answered.has(t[0]):
				answered.append(t[0])
				if answered.size() == 1:
					answered_at = Time.get_ticks_msec()
			elif s != StreamPeerTCP.STATUS_CONNECTED and s != StreamPeerTCP.STATUS_CONNECTING:
				tries.erase(t)
				continue
			if t[0] == first and s == StreamPeerTCP.STATUS_CONNECTING:
				first_pending = true
		if answered.has(first):
			winner = first
		elif not answered.is_empty() and (not first_pending or Time.get_ticks_msec() - answered_at > GRACE_S * 1000.0):
			winner = answered[0]
		elif tries.is_empty():
			break
		else:
			await tree.process_frame
	for t: Array in tries:
		(t[1] as StreamPeerTCP).disconnect_from_host()
	return winner


static func _resolve(host: String, tree: SceneTree) -> Array:
	var id := IP.resolve_hostname_queue_item(host, IP.TYPE_ANY)
	while IP.get_resolve_item_status(id) == IP.RESOLVER_STATUS_WAITING:
		await tree.process_frame
	var got: Array = IP.get_resolve_item_addresses(id) \
		if IP.get_resolve_item_status(id) == IP.RESOLVER_STATUS_DONE else []
	IP.erase_resolve_item(id)
	return got


static func _first_v4(all: Array) -> String:
	for a in all:
		if _is_v4(str(a)):
			return str(a)
	return ""


static func _is_v4(a: String) -> bool:
	return a.is_valid_ip_address() and not ":" in a

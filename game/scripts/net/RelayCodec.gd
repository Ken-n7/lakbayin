class_name RelayCodec
extends RefCounted

## The movement relay's wire format, shared by the relay (RelayServer), the
## game (RelayLink) and the tests. Binary for the many small messages, JSON
## text (`{"e": event, "p": payload}`) for the rare ones: hello / welcome,
## roster, ping / pong. A refusal is a close, code DENIED, the reason its text.
##
## Up, phone -> relay, one sample (TCP keeps them in order and loses none,
## so nothing is sent twice -- the Supabase path needs its overlap, this
## does not):
##     [0x01][t u32 ms][x s16][y s16]                         9 bytes
## Snapshot, relay -> everyone in the session, encoded once a tick:
##     [0x02][count u8] then per hero [idx u8][n u8] + n x [t u32][x s16][y s16]
## `t` is the sender's own clock in ms (Peers learns its offset); x and y are
## map pixels -- the map is 3072x1728, signed for the water round it.

const VERSION := 1
const UP := 0x01
const SNAP := 0x02
const UP_SIZE := 9
const POINT_SIZE := 8
const DENIED := 4003


static func up(t_ms: int, x: int, y: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(UP_SIZE)
	b[0] = UP
	b.encode_u32(1, t_ms & 0xFFFFFFFF)
	b.encode_s16(5, clampi(x, -32768, 32767))
	b.encode_s16(7, clampi(y, -32768, 32767))
	return b


## [t_ms, x, y], or [] if `b` is not an up frame.
static func read_up(b: PackedByteArray) -> Array:
	if b.size() != UP_SIZE or b[0] != UP:
		return []
	return [b.decode_u32(1), b.decode_s16(5), b.decode_s16(7)]


## `heroes`: idx -> [[t_ms, x, y], ...]. At most 255 heroes and 255 points
## each; the rest wait for the next tick (they never get near it: 40 phones,
## one or two points a tick).
static func snap(heroes: Dictionary) -> PackedByteArray:
	var take: Array = []
	var size := 2
	for idx: int in heroes:
		if take.size() == 255:
			break
		var pts: Array = heroes[idx]
		var n := mini(pts.size(), 255)
		if n == 0:
			continue
		take.append([idx, pts, n])
		size += 2 + n * POINT_SIZE
	var b := PackedByteArray()
	b.resize(size)
	b[0] = SNAP
	b[1] = take.size()
	var at := 2
	for h: Array in take:
		b[at] = int(h[0]) & 0xFF
		b[at + 1] = h[2]
		at += 2
		for i in int(h[2]):
			var q: Array = h[1][i]
			b.encode_u32(at, int(q[0]) & 0xFFFFFFFF)
			b.encode_s16(at + 4, clampi(int(q[1]), -32768, 32767))
			b.encode_s16(at + 6, clampi(int(q[2]), -32768, 32767))
			at += POINT_SIZE
	return b


## idx -> [[t_ms, x, y], ...], or {} if `b` is not a whole snapshot.
static func read_snap(b: PackedByteArray) -> Dictionary:
	if b.size() < 2 or b[0] != SNAP:
		return {}
	var out := {}
	var at := 2
	for h in b[1]:
		if at + 2 > b.size():
			return {}
		var idx := b[at]
		var n := b[at + 1]
		at += 2
		if at + n * POINT_SIZE > b.size():
			return {}
		var pts: Array = []
		for i in n:
			pts.append([b.decode_u32(at), b.decode_s16(at + 4), b.decode_s16(at + 6)])
			at += POINT_SIZE
		out[idx] = pts
	return out if at == b.size() else {}


static func text(event: String, payload: Dictionary) -> String:
	return JSON.stringify({"e": event, "p": payload})


## [event, payload], or ["", {}] if `raw` is not one of ours.
static func read_text(raw: String) -> Array:
	var j := JSON.new()
	if j.parse(raw) != OK:
		return ["", {}]
	var m: Variant = j.data
	if not (m is Dictionary) or not ((m as Dictionary).get("p") is Dictionary):
		return ["", {}]
	return [str(m.get("e", "")), m.p]

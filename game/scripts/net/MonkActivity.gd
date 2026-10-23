class_name MonkActivity
extends RefCounted

## Transient hints only. Membership comes from the server roster, while the
## presence payload contains a monk index and expiry, never a typed answer.
const TTL := 12.0
const REFRESH_S := 4.0


static func active(presence: Dictionary, teammates: Array[String], session: String,
		monk_count: int, now: float) -> Dictionary:
	var out := {}
	for id: String in teammates:
		var connections: Variant = presence.get(id, [])
		if not connections is Array:
			continue
		for meta: Variant in connections:
			if not meta is Dictionary or str(meta.get("sid", "")) != session \
					or str(meta.get("where", "")) != "map":
				continue
			var monk: Variant = meta.get("typing_monk")
			var until: Variant = meta.get("typing_until")
			if not (monk is int or monk is float) or not (until is int or until is float):
				continue
			if not is_finite(float(monk)) or not is_finite(float(until)) \
					or float(monk) != floorf(float(monk)):
				continue
			if int(monk) < 0 or int(monk) >= monk_count \
					or float(until) <= now or float(until) > now + TTL + 5.0:
				continue
			out[int(monk)] = true
	return out

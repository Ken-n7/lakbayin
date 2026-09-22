extends RefCounted

## Live-tuning helpers for picking a number by eye while the game runs -- move a
## sprite scale, a speed, a radius, whatever -- then bake the chosen value back
## into its real constant and stop calling these. Nothing here reads or writes
## game state; it only turns a keypress into a delta.

## +-`step` if `event` is `dec` or `inc`, else 0.0. Keeps the key-to-delta mapping
## in one place so a caller just applies the result to whatever it's tuning.
static func key_step(event: InputEvent, dec: Key, inc: Key, step: float) -> float:
	if not (event is InputEventKey and (event as InputEventKey).pressed):
		return 0.0
	var key := (event as InputEventKey).keycode
	if key == dec:
		return -step
	if key == inc:
		return step
	return 0.0

extends TestCase
## The phone's keyboard never covers the field being typed in (client,
## 2026-09-27). Every screen with a text field, and the Rescue pop-up on the
## map's own layer: each field focused in turn under keyboards from 50% to 70%
## of a landscape screen, and it has to sit fully between the top of the screen
## and the keyboard. The keyboard is `Main.fake_keyboard` -- a real one only
## exists on a phone -- and the rest is the real Main and the real screens.
##   godot --headless res://scripts/tests/keyboard_test.tscn

## [what, screen, how to get to its fields]. Some fields only show part way
## through: the join code (signed in), the reset's second step, the team
## names on the teacher's cards once there are teams.
var SCREENS := [
	["login", "login", Callable()], ["register", "register", Callable()],
	["reset, step 1", "reset", Callable()], ["reset, step 2", "reset", _reset_step2],
	["team name (offline)", "team", Callable()], ["join code", "team", _join_code],
	["questions", "questions", Callable()], ["controls", "controls", Callable()],
	["controls, team cards", "controls", _team_cards], ["feedback", "feedback", Callable()],
]
const KEYBOARDS := [0.5, 0.6, 0.7]      # share of the screen's height

var main: Control


func frames(n := 3) -> void:
	for i in n:
		await get_tree().process_frame


func view_h() -> float:
	return main.get_viewport_rect().size.y


func fields(root: Node) -> Array:
	var out: Array = []
	for f: Control in root.find_children("*", "LineEdit", true, false) + root.find_children("*", "TextEdit", true, false):
		if f.is_visible_in_tree() and f.editable and f.virtual_keyboard_enabled:
			out.append(f)
	return out


func label(f: Control) -> String:
	return str(f.get("placeholder_text")) if str(f.get("placeholder_text")) != "" else str(f.name)


## Lets the lift settle -- it eases in over a few frames.
func settle() -> void:
	await frames(40)


## `f`, focused under a keyboard `share` of the screen tall: is it in view?
func in_view(f: Control, share: float) -> Array:
	# A field down a scrolled list is scrolled to first, as a thumb would.
	var n: Node = f.get_parent()
	while n != null and not n is ScrollContainer:
		n = n.get_parent()
	if n != null:
		(n as ScrollContainer).ensure_control_visible(f)
		await frames(2)
	main.fake_keyboard = view_h() * share
	f.grab_focus()
	await settle()
	var r := f.get_global_rect()
	var kb_top: float = view_h() - main.fake_keyboard
	return [r.position.y >= 0.0 and r.end.y <= kb_top, "field %d-%d, keyboard from %d" % [r.position.y, r.end.y, kb_top]]


func release() -> void:
	main.fake_keyboard = 0.0
	var f := get_viewport().gui_get_focus_owner()
	if f != null:
		f.release_focus()
	await settle()


func _ready() -> void:
	backup_save()
	main = preload("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await frames(4)
	await _every_field()
	await _how_it_moves()
	await _rescue_popup()
	main.fake_keyboard = -1.0
	completed = true
	finish("KEYBOARD")


func _reset_step2(screen: Control) -> void:
	screen.call("_show_step", 2)


func _join_code(screen: Control) -> void:
	for c in screen.get_children():
		c.free()
	screen.call("_build_code")


## Six teams, the class the client plays with.
func _team_cards(screen: Control) -> void:
	var lobby: Object = screen.get("_lobby")
	lobby.set("teams", range(6).map(func(i: int) -> Dictionary:
		return {"id": "t%d" % i, "name": "Team %d" % (i + 1)}))
	screen.call("_draw_teams")


func _every_field() -> void:
	print("-- every field on every screen, above the keyboard")
	for c: Array in SCREENS:
		main.open(c[1])
		await frames(20)
		if (c[2] as Callable).is_valid():
			(c[2] as Callable).call(main.current)
			await frames(20)
		var list := fields(main.current)
		check("%s has a field to type in" % c[0], not list.is_empty())
		for f: Control in list:
			var worst := ""
			for share: float in KEYBOARDS:
				var got: Array = await in_view(f, share)
				if not got[0]:
					worst += " %d%%: %s" % [int(share * 100), got[1]]
			check("%s: '%s' stays in view" % [c[0], label(f)], worst == "", worst)
		await release()
		check("%s: back where it was once the keyboard is gone" % c[0], main.current.position.y == 0.0,
			str(main.current.position.y))


func _how_it_moves() -> void:
	print("-- no more than it needs")
	main.open("login")
	await frames(20)
	var list := fields(main.current)
	var email: Control = list[0]
	var password: Control = list[1]
	# A small keyboard that clears the email field: nothing moves.
	main.fake_keyboard = view_h() - email.get_global_rect().end.y - 40.0
	email.grab_focus()
	await settle()
	check("a field already clear of the keyboard: nothing moves", main.current.position.y == 0.0,
		str(main.current.position.y))
	# A tall one: just enough to clear it, the gap and no more.
	var share := 0.6
	main.fake_keyboard = view_h() * share
	password.grab_focus()
	await settle()
	var gap: float = view_h() - main.fake_keyboard - password.get_global_rect().end.y
	check("lifted just enough: the field sits right above the keyboard", absf(gap - main.KEYBOARD_GAP) < 1.0,
		"gap %.1f" % gap)
	# Focus moves up to the email field: the screen comes down to suit it.
	var lifted: float = main.current.position.y
	email.grab_focus()
	await settle()
	check("focus moving to a higher field lowers the screen again", main.current.position.y > lifted,
		"%.1f -> %.1f" % [lifted, main.current.position.y])
	# A keyboard taller than the room under the field: the field keeps to the top.
	main.fake_keyboard = view_h() - 20.0
	password.grab_focus()
	await settle()
	check("with no room at all, the field stops at the top, not off it",
		absf(password.get_global_rect().position.y - main.KEYBOARD_GAP) < 1.0,
		str(password.get_global_rect().position.y))
	# Focus somewhere that is not a field (a button): down again.
	var button := main.current.find_children("*", "Button", true, false).filter(
		func(b: Button) -> bool: return b.is_visible_in_tree()).front() as Button
	button.focus_mode = Control.FOCUS_ALL
	button.grab_focus()
	await settle()
	check("focus off the fields: the screen comes back down", main.current.position.y == 0.0,
		str(main.current.position.y))
	# The quiz's answer never opens the keyboard -- its own keypad is the
	# input -- so nothing lifts for it, whatever keyboard there might be.
	var answer := Ui.line_edit("", 150, 40, 25)
	answer.virtual_keyboard_enabled = false
	answer.position = Vector2(100, view_h() - 50.0)
	main.current.add_child(answer)
	main.fake_keyboard = view_h() * 0.6
	answer.grab_focus()
	await settle()
	check("a field on its own keypad (the quiz answer) lifts nothing", main.current.position.y == 0.0,
		str(main.current.position.y))
	answer.queue_free()
	await release()
	main.open("register")
	await frames(20)
	check("a new screen starts where it belongs", main.current.position.y == 0.0)


func _rescue_popup() -> void:
	print("-- a pop-up on a layer of its own")
	Game.begin_adventure(600)
	Game.gems = 50
	main.open("home")
	await frames(10)
	var layer := CanvasLayer.new()
	layer.layer = 2
	main.current.add_child(layer)
	var r: Control = load("res://scripts/RescueOverlay.gd").new()
	r.fetch_mates = func() -> Array:
		await get_tree().process_frame
		return [{"profile_id": "ben-id", "username": "ben", "gems": 6, "eliminated": false, "finished": false}]
	layer.add_child(r)
	r.setup({})
	await frames(6)
	(r.find_child("Mate_ben", true, false).find_child("Pick", true, false) as Button).pressed.emit()
	await frames(6)
	var amount := r.find_child("Amount", true, false) as Control
	var worst := ""
	for share: float in KEYBOARDS:
		var got: Array = await in_view(amount, share)
		if not got[0]:
			worst += " %d%%: %s" % [int(share * 100), got[1]]
	check("Rescue's amount stays in view", worst == "", worst)
	check("it is the pop-up that moves, not the screen under it",
		r.position.y < 0.0 and main.current.position.y == 0.0, "%s / %s" % [r.position.y, main.current.position.y])
	await release()
	check("the pop-up comes back down", r.position.y == 0.0, str(r.position.y))
	Game.abandon_adventure()

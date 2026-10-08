extends Node

## Does every screen fit in the 640x360 canvas? Reports anything that hangs off
## an edge, and anything wider or taller than the canvas itself.
##
##   godot --headless --path game res://tools/layout.tscn
##
## Headless on purpose: Control layout runs fine without a GL context, and a
## measurement beats a screenshot for this -- "it goes over the screen" is a
## number, not an opinion.

## 16:9 and 20:9 at the same height, which is what `keep_height` gives a phone.
## The narrow one catches overflow; the wide one catches anything that assumed
## 640 and ends up floating in the middle of a wider screen.
const SIZES := [Vector2(640, 360), Vector2(800, 360)]
var CANVAS := Vector2(640, 360)
## Splash, team and adventure are settled; the client asked to leave them be.
const SCREENS := ["login", "register", "reset", "home", "admin", "controls", "history",
		"questions", "feedback", "hero", "learn", "board", "summary"]

var _bad := 0


func _ready() -> void:
	await get_tree().process_frame
	var main: Control = load("res://scripts/Main.gd").new()
	get_tree().root.add_child(main)
	main.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	Game.player_name = "Adventurer"
	Game.team_name = "Math Mavericks"
	Game.begin_adventure(600)

	for size: Vector2 in SIZES:
		CANVAS = size
		main.size = CANVAS
		print("== %d x %d ==" % [int(size.x), int(size.y)])
		# The quiz overlay is not a route, so the loop below never reached it --
		# and it is the screen a student spends the whole session on. Checked
		# first, in both the states it has.
		for intro in [true, false]:
			var quiz: Control = load("res://scripts/QuizOverlay.gd").new()
			quiz.station_index = 0
			quiz.intro_only = intro
			main.add_child(quiz)
			quiz.size = CANVAS
			quiz.setup({})
			for i in 20:
				await get_tree().process_frame
			_audit("quiz (%s)" % ("intro" if intro else "question"), quiz)
			quiz.queue_free()
			await get_tree().process_frame

		for name: String in SCREENS:
			main.open(name)
			main.current.size = CANVAS
			for i in 30:
				await get_tree().process_frame
			_audit(name, main.current)
			await _dev_clear(name, main, [main.current])

		# The map is settled (see SCREENS), but the DEV tab is new on it: only
		# that is checked there, against the HUD.
		main.open("adventure")
		for i in 30:
			await get_tree().process_frame
		await _dev_clear("adventure", main, [main.current.hud.hud_layer, main.current.hud.ui_layer])


	print("---- LAYOUT %s ---- %d overflowing controls" %
		["PASS" if _bad == 0 else "FAIL", _bad])
	get_tree().quit(1 if _bad > 0 else 0)


func _audit(screen: String, root: Control) -> void:
	var hits: Array[String] = []
	_walk(root, hits)
	_overlaps(root, hits)
	if hits.is_empty():
		print("  ok    %s" % screen)
		return
	print("  FAIL  %s" % screen)
	for h in hits:
		print("          " + h)
	_bad += hits.size()


## The dev panel's tab (debug builds) sits on every screen, and the pinned
## Hub stats on Game Controls: neither may cover anything of the screen's.
func _dev_clear(screen: String, main: Control, roots: Array) -> void:
	var panel: Control = main.get("dev_panel")
	if panel == null:
		return
	var mine := [["the DEV tab", (panel.get("_tab") as Control).get_global_rect()]]
	if screen == "controls":
		DevPanel.hub_pinned = true
		panel.call("_place_pin")
		for i in 10:
			await get_tree().process_frame
		var pin: Control = panel.get("_pin")
		if pin != null:
			mine.append(["the pinned Hub stats", pin.get_global_rect()])
		DevPanel.hub_pinned = false
		panel.call("_place_pin")
	var leaves: Array[Control] = []
	for r: Node in roots:
		_collect(r, leaves)
	var hits: Array[String] = []
	for m: Array in mine:
		for c: Control in leaves:
			var r := (m[1] as Rect2).intersection(c.get_global_rect())
			if r.size.x > 1.0 and r.size.y > 1.0:
				hits.append("%s covers %s %s by %dx%d" % [m[0], c.get_class(), _name_of(c), int(r.size.x), int(r.size.y)])
	if not hits.is_empty():
		print("  FAIL  %s (dev panel)" % screen)
		for h in hits:
			print("          " + h)
		_bad += hits.size()


## Two things drawn on top of each other. Everything fitting the canvas is not
## the same as everything being readable -- the admin column's last button sat
## squarely on the footer and every measurement here still passed.
func _overlaps(root: Control, hits: Array[String]) -> void:
	var leaves: Array[Control] = []
	_collect(root, leaves)
	for i in leaves.size():
		for j in range(i + 1, leaves.size()):
			var a := leaves[i]
			var b := leaves[j]
			# Text is allowed to sit inside its own button.
			if a.is_ancestor_of(b) or b.is_ancestor_of(a):
				continue
			var r := a.get_global_rect().intersection(b.get_global_rect())
			if r.size.x > 2.0 and r.size.y > 2.0:
				hits.append("%s %s overlaps %s %s by %dx%d" % [
					a.get_class(), _name_of(a), b.get_class(), _name_of(b),
					int(r.size.x), int(r.size.y)])


## Buttons, labels, fields -- and any Control holding a sprite, which is how
## the hero portrait on Home sat on top of the username for a day without this
## check saying a word. Panels, scrims and containers are meant to sit under
## things, and reporting those is noise that hides the real collisions.
func _collect(node: Node, out: Array[Control]) -> void:
	for child in node.get_children():
		if child is ScrollContainer:
			continue
		if (child is Button or child is Label or child is LineEdit
				or _holds_sprite(child)) and child is Control \
				and (child as Control).is_visible_in_tree():
			var c := child as Control
			if c.get_global_rect().size.x > 0.0:
				out.append(c)
		_collect(child, out)


## Only leaves and sized boxes are worth reporting: a container that overflows
## does so because a child does, and naming both just doubles the noise.
func _walk(node: Node, hits: Array[String]) -> void:
	for child in node.get_children():
		# A scroll region's contents are supposed to run past it -- that is the
		# whole point. Check the region itself, then stop; otherwise every
		# scrollable list reads as broken layout.
		if child is ScrollContainer:
			_check_rect(child as Control, hits)
			continue
		if child is Control and (child as Control).get_child_count() == 0:
			_check_rect(child as Control, hits)
		_walk(child, hits)


func _check_rect(c: Control, hits: Array[String]) -> void:
	var r := c.get_global_rect()
	if not c.is_visible_in_tree() or r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	var over := ""
	if r.position.x < -0.5:
		over += " left by %d" % int(-r.position.x)
	if r.position.y < -0.5:
		over += " top by %d" % int(-r.position.y)
	if r.end.x > CANVAS.x + 0.5:
		over += " right by %d" % int(r.end.x - CANVAS.x)
	if r.end.y > CANVAS.y + 0.5:
		over += " bottom by %d" % int(r.end.y - CANVAS.y)
	if over != "":
		hits.append("%s %s%s  rect=%s" % [c.get_class(), _name_of(c), over, str(r)])


## A bare Control wrapping an AnimatedSprite2D or Sprite2D draws something,
## even though it has no text and is not a widget.
func _holds_sprite(node: Node) -> bool:
	if not (node is Control):
		return false
	for c in node.get_children():
		if c is AnimatedSprite2D or c is Sprite2D:
			return true
	return false


func _name_of(c: Control) -> String:
	if c is Button:
		return "'%s'" % (c as Button).text
	if c is Label:
		return "'%s'" % (c as Label).text.substr(0, 30)
	if c is LineEdit:
		return "'%s'" % (c as LineEdit).placeholder_text
	return ""

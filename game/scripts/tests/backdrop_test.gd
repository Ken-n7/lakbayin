extends TestCase
## The math drifting over the menus' scene (MathMotes, in Backdrop): behind the
## screens, never over them; rising, fading in and out, never popping; the
## same every launch.
##   godot --headless res://scripts/tests/backdrop_test.tscn


func frames(n := 3) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	backup_save()
	var main: Control = preload("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await frames(4)
	main.open("login")
	await frames(10)
	var motes := main.backdrop.find_child("MathMotes", true, false) as MathMotes
	check("the menus' scene has math drifting over it", motes != null)
	if motes == null:
		completed = true
		finish("BACKDROP")
		return

	# The first try drew on the sign-in form: a z_index lifts a node over
	# every screen in front of the backdrop, whatever the tree order.
	var n: Node = motes
	var raised := false
	while n != main:
		if n is CanvasItem and ((n as CanvasItem).z_index > 0 or (n as CanvasItem).top_level):
			raised = true
		n = n.get_parent()
	check("it is behind the screens: nothing lifts it over them", not raised
		and main.backdrop.get_index() < main.current.get_index())

	var ms: Array = motes.get("_motes")
	var spread := ms.map(func(mm: Dictionary) -> float: return mm.lane)
	check("spread across the whole width of the pan", spread.min() < 0.1 and spread.max() > 0.9)
	check("fewer than before: sixteen over the whole pan", ms.size() == 16, str(ms.size()))
	# Every way, not only up: headings in every quarter of the circle.
	var quarters := {}
	for mm: Dictionary in ms:
		quarters[int(fposmod((mm.dir as Vector2).angle(), TAU) / (PI * 0.5))] = true
	check("they drift in every direction, not only up", quarters.size() == 4, str(quarters.keys()))
	var rising := ms.filter(func(mm: Dictionary) -> bool: return (mm.dir as Vector2).y < 0.0).size()
	check("more rise than sink", rising > ms.size() / 2, "%d of %d" % [rising, ms.size()])
	var m: Dictionary = ms[0]
	var a: Array = motes.place(m, 10.0)
	var b: Array = motes.place(m, 10.5)
	check("they move", (a[1] as Vector2).distance_to(b[1]) > 1.0)
	# Each drift starts somewhere new: the same moment of two drifts in a row.
	var period: float = m.travel / m.speed
	var here: Vector2 = motes.place(m, 10.0)[1]
	var next: Vector2 = motes.place(m, 10.0 + period)[1]
	check("each drift begins somewhere new", here.distance_to(next) > 2.0, "%s / %s" % [here, next])
	check("faded in and out at each end of a drift, full between",
		MathMotes.fade(0.0) == 0.0 and MathMotes.fade(1.0) == 0.0 and MathMotes.fade(0.5) == 1.0)
	var inside := true
	for mm: Dictionary in ms:
		for t in range(0, 900, 3):
			var at: Array = motes.place(mm, float(t))
			if MathMotes.fade(at[0]) > 0.0:
				var pos: Vector2 = at[1]
				inside = inside and pos.x > 0 and pos.x < motes.area.x and pos.y > 0 and pos.y < motes.area.y
	check("seen only over the scene, never off it", inside)
	var again := MathMotes.new(motes.area)
	add_child(again)
	await frames(1)
	check("the same composition every launch", str(again.get("_motes")) == str(ms))
	again.queue_free()

	# Carved into the pack's rocks: a big one and a small one on each island.
	var carved := ["rock_blue", "stone_blue", "rock_yellow", "stone_yellow", "rock_red", "stone_red"]
	var found := carved.filter(func(c: String) -> bool:
		var spr := main.backdrop.find_child(c, true, false) as Sprite2D
		return spr != null and spr.texture != null)
	check("each island has its two carved rocks", found.size() == carved.size() or not Backdrop.SHOW_CARVINGS,
		str(found))

	main.open("home")
	await frames(3)
	check("hidden with the backdrop where a screen has its own scene", not motes.is_visible_in_tree())
	completed = true
	finish("BACKDROP")

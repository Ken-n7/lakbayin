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
	check("a few dozen, not a swarm", ms.size() >= 12 and ms.size() <= 40, str(ms.size()))
	var spread := ms.map(func(m: Dictionary) -> float: return m.x)
	check("spread across the whole width of the pan",
		spread.min() < motes.area.x * 0.1 and spread.max() > motes.area.x * 0.9)
	var m: Dictionary = ms[0]
	var a: Array = motes.place(m, 10.0)
	var b: Array = motes.place(m, 11.0)
	check("they rise", (b[1] as Vector2).y < (a[1] as Vector2).y or b[0] < a[0])
	check("faded out at the bottom and the top, full between",
		MathMotes.fade(0.0) == 0.0 and MathMotes.fade(1.0) == 0.0 and MathMotes.fade(0.5) == 1.0)
	var inside := true
	for mm: Dictionary in ms:
		for t in range(0, 400, 7):
			var at: Array = motes.place(mm, float(t))
			if MathMotes.fade(at[0]) > 0.0:
				var pos: Vector2 = at[1]
				inside = inside and pos.x > -20 and pos.x < motes.area.x + 20 and pos.y > -60 and pos.y < motes.area.y + 40
	check("seen only over the scene, never off it", inside)
	var again := MathMotes.new(motes.area)
	add_child(again)
	await frames(1)
	check("the same composition every launch", str(again.get("_motes")) == str(ms))
	again.queue_free()

	main.open("home")
	await frames(3)
	check("hidden with the backdrop where a screen has its own scene", not motes.is_visible_in_tree())
	completed = true
	finish("BACKDROP")

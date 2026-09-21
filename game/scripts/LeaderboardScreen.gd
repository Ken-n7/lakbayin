extends Control

## Team leaderboard. Offline: your saved runs are ranked beside fixed rival
## adventuring parties from the game design doc.

var main: Control


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.10, 0.07, 0.12, 0.9)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var panel := Ui.panel(Vector2(560, 330), "Team Ranking")
	panel.position = Vector2(40, 15)
	add_child(panel)
	var box: VBoxContainer = panel.get_child(0) as VBoxContainer
	box.add_theme_constant_override("separation", 6)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 165)
	scroll.add_theme_constant_override("scrollbar_margin", 0)
	box.add_child(scroll)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	header.add_child(_cell("Rank", 12))
	header.add_child(_cell("Team", 40))
	header.add_child(_cell("Gems", 12))
	list.add_child(header)

	var rows := Game.leaderboard
	if rows.is_empty():
		rows = Game.RIVALS
	for i in rows.size():
		var row: Dictionary = rows[i]
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 10)
		var rank := _cell(str(i + 1), 12)
		var name := _cell(str(row.name), 40)
		var gems := _cell(str(row.gems), 12, int(row.gems))
		if _row_is_me(row):
			for c in [rank, name, gems]:
				c.add_theme_color_override("font_color", Color("1c5b8c"))
				c.add_theme_color_override("font_shadow_color", Color(1, 1, 1, 0.6))
		line.add_child(rank)
		line.add_child(name)
		line.add_child(gems)
		list.add_child(line)

	var note := Art.label("Gems reset to %d for every adventure. Finish all stations to avoid the −%d penalty." %
			[Game.START_GEMS, -(Game.GEM_TEAM_FINISH_PENALTY)], 12, Color("5a4630"), HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(note)

	var back := Ui.button("Back", 110, 44, Ui.RED)
	back.pressed.connect(func() -> void: main.open("title"))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(back)
	box.add_child(row)


func _cell(text: String, weight: int, color: int = -1) -> Label:
	var l := Art.label(text, 15,
			Color("2a201a") if color < 0 else _gem_color(color), HORIZONTAL_ALIGNMENT_LEFT)
	l.custom_minimum_size = Vector2(0, 24)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_stretch_ratio = weight
	return l


func _row_is_me(row: Dictionary) -> bool:
	var me := Game.team_name if Game.team_name != "" else Game.player_name
	return str(row.name) == me


func _gem_color(g: int) -> Color:
	if g >= 450:
		return Color("e09a1f")
	if g >= 300:
		return Color("b9831a")
	return Color("8a6a3a")
extends Control

## Team leaderboard. Offline: your saved runs are ranked beside fixed rival
## adventuring parties from the game design doc.

var main: Control


func setup(_data: Dictionary) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	Ui.dim(self)
	var box := Ui.screen_panel(self, Vector2(560, 330), "Team Ranking")
	box.add_theme_constant_override("separation", 6)
	var scroll := Ui.scroll(box, 165)

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
				c.add_theme_color_override("font_color", Pal.INFO_DEEP)
				c.add_theme_color_override("font_shadow_color", Color(1, 1, 1, 0.6))
		line.add_child(rank)
		line.add_child(name)
		line.add_child(gems)
		list.add_child(line)

	var note := Art.label("Gems reset to %d for every adventure. Finish all stations to avoid the −%d penalty." %
			[Game.START_GEMS, -(Game.GEM_TEAM_FINISH_PENALTY)], Pal.TINY, Pal.INK_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(note)

	var back := Ui.button("Back", 110, 44, Ui.RED)
	back.pressed.connect(func() -> void: main.open("title"))
	Ui.centre_row(box, back)


func _cell(text: String, weight: int, color: int = -1) -> Label:
	var l := Art.label(text, Pal.BODY,
			Pal.INK if color < 0 else _gem_color(color), HORIZONTAL_ALIGNMENT_LEFT)
	l.custom_minimum_size = Vector2(0, 24)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_stretch_ratio = weight
	return l


func _row_is_me(row: Dictionary) -> bool:
	var me := Game.me()
	return str(row.name) == me


func _gem_color(g: int) -> Color:
	if g >= 450:
		return Pal.AMBER
	if g >= 300:
		return Pal.GOLD_DIM
	return Pal.WOOD
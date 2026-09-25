class_name Art
extends RefCounted

## Texture helpers for the Tiny Swords pack.
##
## The pack's unit sheets are strips of packed frames with *uneven* widths, so
## a fixed hframes grid would mis-cut. `frames()` scans the alpha channel to
## find each frame's bounding box, then builds AtlasTextures for animation.

## The client asked twice for large, legible text. Nothing renders below this;
## at the 640x360 canvas a phone upscales ~3x, so 14 lands near 42 physical px.
## Raise it here after a real-device read, not per call site.
const MIN_FONT := 14

const PIXEL_FONT := "res://assets/fonts/PixelifySans.ttf"
const SYMBOL_FONT := "res://assets/fonts/DejaVuSans.ttf"

static var _tex_cache: Dictionary = {}
static var _frames_cache: Dictionary = {}
static var _patch_cache: Dictionary = {}


## Pixelify Sans is the project-wide font (project.godot `gui/theme/custom_font`)
## and carries the superscripts and math signs the questions need, but has no
## tick, star or arrow. Attach a symbol face for those.
##
## `load()` returns the very instance the project theme already uses, so setting
## its fallback here is enough -- no Theme juggling. Note the fallback must not
## be `ThemeDB.fallback_font`: once the pixel font is the project default, that
## *is* this font, and Godot rejects the cycle.
static func apply_font_fallback() -> void:
	var f := load(PIXEL_FONT) as FontFile
	var sym := load(SYMBOL_FONT) as FontFile
	if f == null or sym == null or not f.fallbacks.is_empty():
		return
	f.fallbacks = [sym]


static func tex(path: String) -> Texture2D:
	if not _tex_cache.has(path):
		_tex_cache[path] = load(path)
	return _tex_cache[path]


## Runs of non-transparent pixels along one axis. `horizontal` scans columns.
static func _runs(img: Image, horizontal: bool) -> Array:
	var w := img.get_width()
	var h := img.get_height()
	var n := w if horizontal else h
	var m := h if horizontal else w
	var out: Array = []
	var start := -1
	for i in n:
		var solid := false
		for j in m:
			var a := img.get_pixel(i, j).a if horizontal else img.get_pixel(j, i).a
			if a > 0.01:
				solid = true
				break
		if solid and start < 0:
			start = i
		elif not solid and start >= 0:
			out.append([start, i - 1])
			start = -1
	if start >= 0:
		out.append([start, n - 1])
	return out


## The Tiny Swords UI sheets are nine-patches whose pieces are separated by
## transparent gutters, so StyleBoxTexture's margins land in empty space and the
## frame renders as floating fragments. Crop the pieces and blit them adjacent,
## producing a contiguous texture a real nine-patch can slice.
##
## Sheets come as 3x3 (panels, big buttons), 3x1 (the HUD bars) or 1x1 (the
## small square buttons, which are a single image). An axis with one run gets a
## zero margin, i.e. it simply stretches.
## Returns {"texture": ImageTexture, "margins": Vector4(l, t, r, b)}.
static func ninepatch(path: String) -> Dictionary:
	if _patch_cache.has(path):
		return _patch_cache[path]
	var src: Image = tex(path).get_image()
	src.convert(Image.FORMAT_RGBA8)
	var cols := _runs(src, true)
	var rows := _runs(src, false)
	var out: Dictionary = {}
	if not (cols.size() in [1, 3]) or not (rows.size() in [1, 3]):
		out = {"texture": tex(path), "margins": Vector4(20, 20, 20, 20)}
		_patch_cache[path] = out
		return out
	var cw: Array = cols.map(func(r): return int(r[1]) - int(r[0]) + 1)
	var rh: Array = rows.map(func(r): return int(r[1]) - int(r[0]) + 1)
	var tw := 0
	for v in cw:
		tw += v
	var th := 0
	for v in rh:
		th += v
	var dst := Image.create(tw, th, false, Image.FORMAT_RGBA8)
	dst.fill(Color(0, 0, 0, 0))
	var dy := 0
	for ri in rows.size():
		var dx := 0
		for ci in cols.size():
			var piece := Rect2i(int(cols[ci][0]), int(rows[ri][0]), cw[ci], rh[ri])
			dst.blit_rect(src, piece, Vector2i(dx, dy))
			dx += cw[ci]
		dy += rh[ri]
	# A single run on an axis means there are no separate border pieces. For a
	# bar (3x1) that axis just stretches; for a lone rounded button (1x1) keep a
	# corner-sized margin so the rounding survives being resized.
	var solo := cols.size() == 1 and rows.size() == 1
	var mx: int = cw[0] if cols.size() == 3 else (int(cw[0] * 0.3) if solo else 0)
	var mz: int = cw[2] if cols.size() == 3 else (int(cw[0] * 0.3) if solo else 0)
	var my: int = rh[0] if rows.size() == 3 else (int(rh[0] * 0.3) if solo else 0)
	var mw: int = rh[2] if rows.size() == 3 else (int(rh[0] * 0.3) if solo else 0)
	out = {
		"texture": ImageTexture.create_from_image(dst),
		"margins": Vector4(mx, my, mz, mw),
	}
	_patch_cache[path] = out
	return out


## Slice an animation strip into AtlasTextures. Each frame is cropped to the
## smallest vertical box too, and `pad` keeps a little slack so frames don't
## bleed. Returns empty array if the sheet looks unreadable.
static func frames(path: String, pad := 2) -> Array[AtlasTexture]:
	# Slicing is a ~45ms per-sheet alpha scan; the adventure map asks for the
	# same four tree sheets 23 times. Frames are immutable, so share them.
	var key := "%s#%d" % [path, pad]
	if _frames_cache.has(key):
		return _frames_cache[key]
	var t := tex(path)
	var img: Image = t.get_image()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var out: Array[AtlasTexture] = []
	for pair in _runs(img, true):
		var rx0: int = maxi(int(pair[0]) - pad, 0)
		var rw: int = mini(int(pair[1]) + pad + 1, w) - rx0
		# Vertical crop of this frame: the alpha bounding box of its own column band.
		var used := img.get_region(Rect2i(rx0, 0, rw, h)).get_used_rect()
		if used.size.y == 0:
			continue
		var ry0 := maxi(used.position.y - pad, 0)
		var rh := mini(used.position.y + used.size.y + pad, h) - ry0
		var atlas := AtlasTexture.new()
		atlas.atlas = t
		atlas.region = Rect2(rx0, ry0, rw, rh)
		atlas.filter_clip = true
		out.append(atlas)
	_frames_cache[key] = out
	return out


## Crop one cell out of a gutter-separated grid sheet. BigRibbons' cells are not
## on a regular pitch -- its rows start 20px down and its columns have uneven
## gutters -- so naive `width / cols` arithmetic cuts through the artwork. The
## alpha runs give the real cell boxes.
static func cell(path: String, col: int, row: int) -> AtlasTexture:
	var key := "%s#cell%d,%d" % [path, col, row]
	if _patch_cache.has(key):
		return _patch_cache[key]
	var t := tex(path)
	var img: Image = t.get_image()
	img.convert(Image.FORMAT_RGBA8)
	var cols := _runs(img, true)
	var rows := _runs(img, false)
	var at := AtlasTexture.new()
	at.atlas = t
	at.filter_clip = true
	if col < cols.size() and row < rows.size():
		var cx: Array = cols[col]
		var ry: Array = rows[row]
		at.region = Rect2(cx[0], ry[0], cx[1] - cx[0] + 1, ry[1] - ry[0] + 1)
	else:
		at.region = Rect2(0, 0, t.get_width(), t.get_height())
	_patch_cache[key] = at
	return at


## Fixed-grid slicing: the Super Retro World character sheets are a 3x4 grid of
## 16x20 cells, and every cell must keep the same box or the walk jitters --
## `frames()` crops each frame to its own alpha bounds, which is wrong here.
static func grid(path: String, cols: int, rows: int) -> Array[AtlasTexture]:
	var key := "%s@grid%dx%d" % [path, cols, rows]
	if _frames_cache.has(key):
		return _frames_cache[key]
	var t := tex(path)
	var fw := t.get_width() / cols
	var fh := t.get_height() / rows
	var out: Array[AtlasTexture] = []
	for r in rows:
		for c in cols:
			var at := AtlasTexture.new()
			at.atlas = t
			at.region = Rect2(c * fw, r * fh, fw, fh)
			at.filter_clip = true
			out.append(at)
	_frames_cache[key] = out
	return out


## A Super Retro World character sheet -> one looping walk cycle per facing.
## Rows are down, left, right, up; the middle column is the standing pose, so
## idle is this animation paused on frame 1.
static func walk_frames(path: String, fps := 8.0) -> SpriteFrames:
	var cells := grid(path, 3, 4)
	var sf := SpriteFrames.new()
	sf.remove_animation("default")
	var dirs := ["down", "left", "right", "up"]
	for r in dirs.size():
		var anim: String = dirs[r]
		sf.add_animation(anim)
		sf.set_animation_speed(anim, fps)
		sf.set_animation_loop(anim, true)
		for c in 3:
			sf.add_frame(anim, cells[r * 3 + c])
	return sf


## Build a SpriteFrames resource with one animation per key in `specs`,
## e.g. {"idle": [path, fps, loop]}. The sheet is sliced once into frames
## which can be shared across animations made from the same texture.
static func anim_spriteframes(specs: Dictionary, cache: Array[AtlasTexture] = []) -> SpriteFrames:
	var sf := SpriteFrames.new()
	var per_path: Dictionary = {}
	for anim in specs:
		var path: String = specs[anim][0]
		var fps: float = specs[anim][1]
		var loop: bool = specs[anim][2]
		if not per_path.has(path):
			per_path[path] = frames(path)
		var anim_frames: Array[AtlasTexture] = per_path[path]
		sf.add_animation(anim)
		sf.set_animation_speed(anim, fps)
		sf.set_animation_loop(anim, loop)
		for f in anim_frames:
			sf.add_frame(anim, f)
	return sf


## Nine-patch style box from a packed-UI sheet. Margins come from the sheet's
## own corner pieces, so callers no longer have to guess them; `pad` is extra
## breathing room between the border and the content.
##
## `k` shrinks the whole patch. The pack draws its frames ~45px thick, which is
## most of a 52px button, so the border has to be scaled down with the texture
## rather than just clamped -- StyleBoxTexture draws the border at whatever the
## texture margin says.
static func panel(path: String, pad: Vector2 = Vector2(8, 6), k := 1.0) -> StyleBoxTexture:
	var np := ninepatch(path)
	var m: Vector4 = np.margins
	var sb := StyleBoxTexture.new()
	sb.texture = np.texture
	if not is_equal_approx(k, 1.0):
		var key := "%s@k%0.3f" % [path, k]
		if not _patch_cache.has(key):
			var img: Image = np.texture.get_image().duplicate()
			img.resize(maxi(int(img.get_width() * k), 3), maxi(int(img.get_height() * k), 3),
					Image.INTERPOLATE_NEAREST)
			_patch_cache[key] = {"texture": ImageTexture.create_from_image(img), "margins": m * k}
		sb.texture = _patch_cache[key].texture
		m = _patch_cache[key].margins
	sb.texture_margin_left = m.x
	sb.texture_margin_top = m.y
	sb.texture_margin_right = m.z
	sb.texture_margin_bottom = m.w
	sb.content_margin_left = m.x + pad.x
	sb.content_margin_top = m.y + pad.y
	sb.content_margin_right = m.z + pad.x
	sb.content_margin_bottom = m.w + pad.y
	# Stretching a ~23px centre across a 560px panel smears the paper grain into
	# streaks, so tile instead -- but only on an axis that actually has border
	# pieces. Tiling a bar's borderless vertical axis just repeats the whole bar.
	sb.axis_stretch_horizontal = (StyleBoxTexture.AXIS_STRETCH_MODE_TILE if m.x > 0
			else StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH)
	sb.axis_stretch_vertical = (StyleBoxTexture.AXIS_STRETCH_MODE_TILE if m.y > 0
			else StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH)
	return sb


static func texrect(path: String, w: float, h: float, region := Rect2()) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = tex(path)
	if region.size != Vector2.ZERO:
		var at := AtlasTexture.new()
		at.atlas = tr.texture
		at.region = region
		at.filter_clip = true
		tr.texture = at
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.custom_minimum_size = Vector2(w, h)
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	return tr


static func label(text: String, size := 16, color: Color = Color.WHITE, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", maxi(size, MIN_FONT))
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	l.clip_text = false
	return l


## Props are anchored at their BASE. A centred sprite sinks half its height into
## the ground and y-sorts by its midpoint, so the hero walks in front of trees
## he should be behind. `flip` mirrors horizontally only -- a negative uniform
## scale would stand the sprite on its head.
static func sprite(parent: Node, t: Texture2D, at: Vector2, s: float, flip := 1.0) -> Sprite2D:
	var spr := Sprite2D.new()
	spr.texture = t
	spr.position = at
	spr.scale = Vector2(s * flip, s)
	spr.offset = Vector2(0, -t.get_height() * 0.5)
	parent.add_child(spr)
	return spr


## Same base anchoring, for a looping sheet (swaying trees, water rocks).
## `cols` > 0 slices the sheet on a fixed grid instead of by alpha: the Water
## Rocks' surf spills across their frame borders, and the alpha scan cut them
## into slivers and doubles, so the rocks blinked in and out.
static func anim_sprite(parent: Node, path: String, at: Vector2, s: float, fps := 5.0,
		flip := 1.0, cols := 0) -> AnimatedSprite2D:
	var a := AnimatedSprite2D.new()
	if cols > 0:
		a.sprite_frames = SpriteFrames.new()
		a.sprite_frames.add_animation("sway")
		a.sprite_frames.set_animation_speed("sway", fps)
		for f in grid(path, cols, 1):
			a.sprite_frames.add_frame("sway", f)
	else:
		a.sprite_frames = anim_spriteframes({"sway": [path, fps, true]})
	a.position = at
	a.scale = Vector2(s * flip, s)
	var f: Texture2D = a.sprite_frames.get_frame_texture("sway", 0)
	if f != null:
		a.offset = Vector2(0, -f.get_height() * 0.5)
	a.play("sway")
	parent.add_child(a)
	return a


## Text floating over open terrain or artwork needs this to stay readable.
static func shadow(l: Control, col: Color = Color(0, 0, 0, 0.85), off := 1, outline := 2) -> void:
	l.add_theme_color_override("font_shadow_color", col)
	l.add_theme_constant_override("shadow_offset_x", off)
	l.add_theme_constant_override("shadow_offset_y", off)
	l.add_theme_constant_override("shadow_outline_size", outline)


## Flash a message on an existing label, then fade out and restore `back`.
## The tween is bound to the label, so a freed screen takes it with it.
static func toast(l: Label, msg: String, hold := 1.0, back := "", done := Callable()) -> void:
	if not is_instance_valid(l):
		return
	l.text = msg
	l.visible = true
	l.modulate.a = 1.0
	var tw := l.create_tween()
	tw.tween_interval(hold)
	tw.tween_property(l, "modulate:a", 0.0, 0.4)
	tw.tween_callback(func() -> void:
		l.text = back
		l.modulate.a = 1.0
		if done.is_valid():
			done.call())


# --- Terrain ----------------------------------------------------------------
## The tileset's own tile size. Layers keep the art at native size and scale
## the layer instead, so a cell is `tile` world px and the pixels are never
## resampled.
const SHEET_TILE := 64


## Tiles keep their native 64px size and the layer is scaled down instead, so
## one cell is TILE world px. At the 2x viewport upscale that lands 1:1 on
## screen -- the art is never resampled.
## The pack's animated surf, laid the way its tilemap guide says: one Water
## Foam sprite on every land cell that touches water, between the water and
## the land, each starting on its own frame so the shore does not pulse in
## unison. A frame is three tiles wide centred on its cell, so it spills out
## from under the grass as the waves; the land drawn over it hides the rest.
## `land` is the set of land cells (Vector2i -> true). Returns the layer,
## already added to `parent` -- add it after the water and before the land.
const WATER_FOAM := "res://assets/terrain/tileset/Water Foam.png"
const FOAM_FPS := 8.0


static func shore_foam(parent: Node, land: Dictionary, tile: float) -> Node2D:
	var layer := Node2D.new()
	parent.add_child(layer)
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	frames.add_animation("surf")
	frames.set_animation_speed("surf", FOAM_FPS)
	frames.set_animation_loop("surf", true)
	var cells := grid(WATER_FOAM, 16, 1)
	for c in cells:
		frames.add_frame("surf", c)
	var k := tile * 3.0 / float(cells[0].region.size.x)
	for cell: Vector2i in land:
		var shore := false
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
				Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
			if not land.has(cell + d):
				shore = true
				break
		if not shore:
			continue
		var foam := AnimatedSprite2D.new()
		foam.sprite_frames = frames
		foam.position = (Vector2(cell) + Vector2(0.5, 0.5)) * tile
		foam.scale = Vector2(k, k)
		foam.play("surf")
		# Out of step, cell by cell -- the guide's "start the animation at a
		# different frame" -- but fixed, so every launch looks the same.
		foam.frame = absi(cell.x * 7 + cell.y * 13) % 16
		layer.add_child(foam)
	return layer


static func terrain_layer(tex_path: String, tile: int, coords: Array = []) -> TileMapLayer:
	var region := Vector2i(SHEET_TILE, SHEET_TILE)
	var src := TileSetAtlasSource.new()
	src.texture = tex(tex_path)
	src.texture_region_size = region
	if coords.is_empty():
		var cols := int(tex(tex_path).get_width() / region.x)
		var rows := int(tex(tex_path).get_height() / region.y)
		for ty in rows:
			for tx in cols:
				src.create_tile(Vector2i(tx, ty))
	else:
		for c in coords:
			src.create_tile(c)
	var ts := TileSet.new()
	ts.tile_size = region
	ts.add_source(src, 0)
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	layer.scale = Vector2.ONE * (float(tile) / float(SHEET_TILE))
	return layer


## Tilemap_color1.png is a 16-state match-sides autotile set: the column is
## chosen by the left/right neighbours and the row by top/bottom. Derived by
## probing each tile's edges -- see the plan's mapping table.
##   c0 R-only  c1 R+L  c2 L-only  c3 neither
##   r0 B-only  r1 T+B  r2 T-only  r3 neither
static func autotile(left: bool, right: bool, up: bool, down: bool, cliff := false) -> Vector2i:
	var col := 0 if (right and not left) else (1 if (right and left) else (2 if left else 3))
	var row := 0 if (down and not up) else (1 if (up and down) else (2 if up else 3))
	return Vector2i(col + (5 if cliff else 0), row)

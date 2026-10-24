class_name PixelBox
extends StyleBox

## A nine-slice drawn from the full-resolution pack art at a fixed scale.
##
## StyleBoxTexture draws its borders at the texture's own pixel size, so the
## only way to get a small button out of it was to shrink the image first --
## nearest-neighbour at 0.15-0.34, which dropped pixels unevenly: thin broken
## outlines, dashed wood seams. This draws the untouched art scaled instead.
## Every piece uses the same `Ui.ART_K`, so outlines are one thickness
## everywhere; at a phone's 3x canvas that is one art pixel per screen pixel.

var texture: Texture2D
## Border widths in source pixels: left, top, right, bottom.
var margins := Vector4.ZERO
var k := 1.0 / 3.0
var modulate := Color.WHITE


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	var t := texture.get_size()
	var m := margins
	# An axis with no border pieces (a bar's height) keeps its drawn size,
	# centred, rather than stretching the art out of proportion.
	if m.y + m.w == 0.0 and rect.size.y > t.y * k:
		rect = Rect2(rect.position.x, rect.get_center().y - t.y * k / 2.0, rect.size.x, t.y * k)
	if m.x + m.z == 0.0 and rect.size.x > t.x * k:
		rect = Rect2(rect.get_center().x - t.x * k / 2.0, rect.position.y, t.x * k, rect.size.y)
	# A box smaller than its two borders squeezes the borders, never inverts.
	var kx := minf(k, rect.size.x / maxf(m.x + m.z, 1.0))
	var ky := minf(k, rect.size.y / maxf(m.y + m.w, 1.0))
	var sx := [0.0, m.x, t.x - m.z, t.x]
	var sy := [0.0, m.y, t.y - m.w, t.y]
	var dx := [rect.position.x, rect.position.x + m.x * kx, rect.end.x - m.z * kx, rect.end.x]
	var dy := [rect.position.y, rect.position.y + m.y * ky, rect.end.y - m.w * ky, rect.end.y]
	var rid := texture.get_rid()
	for j in 3:
		for i in 3:
			var src := Rect2(sx[i], sy[j], sx[i + 1] - sx[i], sy[j + 1] - sy[j])
			var dst := Rect2(dx[i], dy[j], dx[i + 1] - dx[i], dy[j + 1] - dy[j])
			if src.size.x <= 0 or src.size.y <= 0 or dst.size.x <= 0 or dst.size.y <= 0:
				continue
			# Edges and centre repeat at scale rather than stretch: stretched
			# paper grain and wood seams smear into streaks.
			var step := Vector2(src.size.x * kx if i == 1 else dst.size.x,
					src.size.y * ky if j == 1 else dst.size.y)
			var y := dst.position.y
			while y < dst.end.y - 0.01:
				var h := minf(step.y, dst.end.y - y)
				var x := dst.position.x
				while x < dst.end.x - 0.01:
					var w := minf(step.x, dst.end.x - x)
					var part := Rect2(src.position, src.size * Vector2(w / step.x, h / step.y))
					RenderingServer.canvas_item_add_texture_rect_region(
							to_canvas_item, Rect2(x, y, w, h), rid, part, modulate)
					x += w
				y += h

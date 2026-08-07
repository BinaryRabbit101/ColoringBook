extends Control
## Dev tool (BL-36) -- draws the free "Starter Stickers" set and writes one
## transparent PNG per sticker to [constant OUTPUT_DIR].
##
## Run WINDOWED (it renders through a SubViewport, which produces nothing under
## the headless dummy rasteriser), then re-import:
##
##   <godot_exe> --path <project> res://scenes/dev/sticker_render.tscn
##   <godot_exe> --path <project> --headless --import
##
## Extra user args (after a bare `--`):
##   --out <res://dir>   where to write (default [constant OUTPUT_DIR])
##   --stay              leave the window up with the sheet on screen
##
## [b]Why a generator and not hand-painted art.[/b] Same argument as
## [code]splash_render.gd[/code]: everything in this shell is drawn from
## primitives in palette colours, and a generated sheet cannot drift from the
## palette it was drawn against. It also means the free starter pack the server
## ships (BL-37) and the repo's dev fixtures are literally the same pixels, from
## one source, re-runnable.
##
## [b]These are placeholders with a job, not the art direction.[/b] Real sticker
## sets flow through BL-37's authoring pipeline; this set exists so the feature,
## the smokes and the pack pipeline have something honest to carry end to end.

## Where the sheet is written. Excluded from release exports exactly like
## [code]assets/books/*[/code] (BL-25's rule): a shipped build's stickers all come
## from the server.
const OUTPUT_DIR := "res://assets/stickers/starter"
## One sticker, square, at a size that still looks crisp scaled onto a 2048 px
## page (a sticker is drawn at ~18% of the page's short side).
const STICKER_SIZE := Vector2i(256, 256)

## Ink every sticker is outlined in, so it reads on paper AND on paint.
const INK := Color(0.176471, 0.129412, 0.09)
const OUTLINE := 7.0
## The white keyline outside the ink, which is what makes a sticker look STUCK ON
## rather than drawn: real stickers are die-cut with a paper border.
const KEYLINE := Color(1.0, 0.996078, 0.972549)
const KEYLINE_WIDTH := 16.0

## Every sticker of the starter set: id, display name, and which drawing runs.
## The ids are the pack's stable identifiers -- they key a saved placement, so
## they may never be renamed (the save reader tolerates an id it cannot resolve,
## but the sticker simply vanishes).
const STICKERS: Array[Dictionary] = [
	{"id": "star", "name": "Star"},
	{"id": "heart", "name": "Heart"},
	{"id": "smiley", "name": "Smiley"},
	{"id": "rainbow", "name": "Rainbow"},
	{"id": "balloon", "name": "Balloon"},
	{"id": "paw", "name": "Paw Print"},
	{"id": "flower", "name": "Flower"},
	{"id": "crown", "name": "Crown"},
]


## One sticker, drawn from primitives on a transparent square.
##
## Each shape is built as a POLYGON first and then drawn three times -- keyline,
## ink, fill -- so every sticker gets the die-cut border for free and no drawing
## code is forked per sticker (the [CrayonButton] rule).
class StickerArt extends Control:
	var sticker_id: String

	func _init(id: String) -> void:
		sticker_id = id
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var box := Rect2(Vector2.ZERO, size)
		match sticker_id:
			"star": _draw_star(box)
			"heart": _draw_heart(box)
			"smiley": _draw_smiley(box)
			"rainbow": _draw_rainbow(box)
			"balloon": _draw_balloon(box)
			"paw": _draw_paw(box)
			"flower": _draw_flower(box)
			"crown": _draw_crown(box)

	# ------------------------------------------------------------- primitives --

	## The three-pass draw every shape goes through: white die-cut border, ink
	## outline, then the colour. Passing [param fill] transparent draws only the
	## border and the line, which is what the rainbow's arcs want.
	func _stamp(points: PackedVector2Array, fill: Color) -> void:
		if points.size() < 3:
			return
		var closed := points.duplicate()
		closed.append(points[0])
		draw_polyline(closed, KEYLINE, KEYLINE_WIDTH, true)
		draw_polyline(closed, INK, OUTLINE, true)
		if fill.a > 0.0:
			draw_colored_polygon(points, fill)
			draw_polyline(closed, INK, OUTLINE, true)

	func _circle_points(centre: Vector2, radius: Vector2, steps: int = 48) -> PackedVector2Array:
		var points := PackedVector2Array()
		for i in steps:
			var angle := TAU * float(i) / float(steps)
			points.append(centre + Vector2(cos(angle) * radius.x, sin(angle) * radius.y))
		return points

	func _stamp_circle(centre: Vector2, radius: Vector2, fill: Color) -> void:
		_stamp(_circle_points(centre, radius), fill)

	# ---------------------------------------------------------------- shapes --

	func _draw_star(box: Rect2) -> void:
		var centre := box.get_center()
		var outer := box.size.x * 0.40
		var inner := outer * 0.44
		var points := PackedVector2Array()
		for i in 10:
			var angle := -PI * 0.5 + TAU * float(i) / 10.0
			var radius := outer if i % 2 == 0 else inner
			points.append(centre + Vector2(cos(angle), sin(angle)) * radius)
		_stamp(points, Color(1.0, 0.803922, 0.223529))
		# A highlight wedge, so a flat yellow star has a face.
		draw_colored_polygon(
			PackedVector2Array([
				centre + Vector2(0.0, -outer * 0.80),
				centre + Vector2(inner * 0.42, -inner * 0.30),
				centre + Vector2(-inner * 0.42, -inner * 0.30),
			]),
			Color(1.0, 0.937255, 0.658824, 0.85)
		)

	func _draw_heart(box: Rect2) -> void:
		var centre := box.get_center()
		var scale := box.size.x * 0.030
		var points := PackedVector2Array()
		for i in 72:
			var t := TAU * float(i) / 72.0
			# The classic parametric heart, flipped into screen coordinates.
			var x := 16.0 * pow(sin(t), 3.0)
			var y := -(13.0 * cos(t) - 5.0 * cos(2.0 * t) - 2.0 * cos(3.0 * t) - cos(4.0 * t))
			points.append(centre + Vector2(x, y) * scale + Vector2(0.0, box.size.y * 0.02))
		_stamp(points, Color(0.929412, 0.294118, 0.372549))
		draw_colored_polygon(
			_circle_points(centre + Vector2(-box.size.x * 0.13, -box.size.y * 0.13),
				Vector2(box.size.x, box.size.y) * 0.055),
			Color(1.0, 0.780392, 0.815686, 0.9)
		)

	func _draw_smiley(box: Rect2) -> void:
		var centre := box.get_center()
		var radius := Vector2(box.size.x, box.size.y) * 0.38
		_stamp_circle(centre, radius, Color(1.0, 0.843137, 0.290196))
		var eye := Vector2(radius.x * 0.36, radius.y * 0.16)
		for side in [-1.0, 1.0]:
			draw_colored_polygon(
				_circle_points(centre + Vector2(eye.x * side, -eye.y * 1.6),
					Vector2(radius.x * 0.12, radius.y * 0.17)),
				INK
			)
		# The smile: an arc thick enough to survive being scaled down on a page.
		var mouth := PackedVector2Array()
		for i in 17:
			var angle := PI * 0.18 + PI * 0.64 * float(i) / 16.0
			mouth.append(centre + Vector2(cos(angle) * radius.x * 0.60, sin(angle) * radius.y * 0.56))
		draw_polyline(mouth, INK, OUTLINE * 1.6, true)

	func _draw_rainbow(box: Rect2) -> void:
		var centre := box.get_center() + Vector2(0.0, box.size.y * 0.22)
		var bands: Array[Color] = [
			Color(0.913725, 0.317647, 0.290196),
			Color(0.964706, 0.615686, 0.235294),
			Color(1.0, 0.843137, 0.290196),
			Color(0.396078, 0.752941, 0.435294),
			Color(0.309804, 0.541176, 0.898039),
		]
		var outer := box.size.x * 0.44
		var thickness := outer / float(bands.size() + 1)
		# The white keyline goes round the whole arch once, before any band, so the
		# bands read as one sticker rather than five.
		_arc_band(centre, outer + KEYLINE_WIDTH * 0.4, thickness + KEYLINE_WIDTH * 0.8, KEYLINE)
		for i in bands.size():
			var radius := outer - thickness * float(i)
			_arc_band(centre, radius, thickness, INK)
			_arc_band(centre, radius - OUTLINE * 0.5, thickness - OUTLINE, bands[i])

	## One half-ring of the rainbow, as a filled polygon.
	func _arc_band(centre: Vector2, radius: float, thickness: float, color: Color) -> void:
		if thickness <= 0.0 or radius <= 0.0:
			return
		var points := PackedVector2Array()
		var inner := maxf(radius - thickness, 0.0)
		for i in 33:
			var angle := PI + PI * float(i) / 32.0
			points.append(centre + Vector2(cos(angle), sin(angle)) * radius)
		for i in range(32, -1, -1):
			var angle := PI + PI * float(i) / 32.0
			points.append(centre + Vector2(cos(angle), sin(angle)) * inner)
		draw_colored_polygon(points, color)

	func _draw_balloon(box: Rect2) -> void:
		var centre := box.get_center() - Vector2(0.0, box.size.y * 0.10)
		var radius := Vector2(box.size.x * 0.30, box.size.y * 0.35)
		# The string first, so the balloon's keyline covers where they meet.
		var string := PackedVector2Array()
		for i in 21:
			var t := float(i) / 20.0
			string.append(Vector2(
				centre.x + sin(t * PI * 1.6) * box.size.x * 0.06,
				centre.y + radius.y + box.size.y * 0.40 * t
			))
		draw_polyline(string, KEYLINE, OUTLINE * 1.8, true)
		draw_polyline(string, INK, OUTLINE * 0.7, true)
		_stamp_circle(centre, radius, Color(0.396078, 0.658824, 0.929412))
		# The knot.
		_stamp(PackedVector2Array([
			centre + Vector2(-radius.x * 0.16, radius.y * 0.94),
			centre + Vector2(radius.x * 0.16, radius.y * 0.94),
			centre + Vector2(0.0, radius.y * 1.16),
		]), Color(0.317647, 0.552941, 0.827451))
		draw_colored_polygon(
			_circle_points(centre + Vector2(-radius.x * 0.34, -radius.y * 0.36),
				Vector2(radius.x * 0.22, radius.y * 0.16)),
			Color(1.0, 1.0, 1.0, 0.72)
		)

	func _draw_paw(box: Rect2) -> void:
		var centre := box.get_center()
		var fur := Color(0.611765, 0.415686, 0.290196)
		_stamp(_circle_points(centre + Vector2(0.0, box.size.y * 0.13),
			Vector2(box.size.x * 0.26, box.size.y * 0.23)), fur)
		var toes: Array[Vector2] = [
			Vector2(-0.26, -0.20), Vector2(-0.09, -0.29),
			Vector2(0.09, -0.29), Vector2(0.26, -0.20),
		]
		for toe in toes:
			_stamp_circle(
				centre + Vector2(toe.x * box.size.x, toe.y * box.size.y),
				Vector2(box.size.x * 0.095, box.size.y * 0.115),
				fur
			)

	func _draw_flower(box: Rect2) -> void:
		var centre := box.get_center()
		var petal := Vector2(box.size.x * 0.135, box.size.y * 0.185)
		var reach := box.size.x * 0.24
		for i in 6:
			var angle := -PI * 0.5 + TAU * float(i) / 6.0
			var at := centre + Vector2(cos(angle), sin(angle)) * reach
			var points := PackedVector2Array()
			for step in 32:
				var t := TAU * float(step) / 32.0
				var local := Vector2(cos(t) * petal.x, sin(t) * petal.y)
				points.append(at + local.rotated(angle + PI * 0.5))
			_stamp(points, Color(0.945098, 0.462745, 0.686275))
		_stamp_circle(centre, Vector2(box.size.x, box.size.y) * 0.135,
			Color(1.0, 0.843137, 0.290196))

	func _draw_crown(box: Rect2) -> void:
		var left := box.position.x + box.size.x * 0.16
		var right := box.end.x - box.size.x * 0.16
		var top := box.position.y + box.size.y * 0.26
		var dip := box.position.y + box.size.y * 0.48
		var base := box.end.y - box.size.y * 0.28
		var mid := (left + right) * 0.5
		_stamp(PackedVector2Array([
			Vector2(left, base),
			Vector2(left, top),
			Vector2(left + (mid - left) * 0.5, dip),
			Vector2(mid, top - box.size.y * 0.06),
			Vector2(right - (right - mid) * 0.5, dip),
			Vector2(right, top),
			Vector2(right, base),
		]), Color(1.0, 0.784314, 0.219608))
		for x in [left + (mid - left) * 0.28, mid, right - (right - mid) * 0.28]:
			draw_colored_polygon(
				_circle_points(Vector2(x, base - box.size.y * 0.09),
					Vector2(box.size.x, box.size.y) * 0.035),
				Color(0.929412, 0.294118, 0.372549)
			)


func _ready() -> void:
	get_window().size = Vector2i(900, 520)
	await get_tree().process_frame
	await _run()


func _run() -> void:
	print("=== BL-36 starter sticker render ===")
	var out_dir := _arg_value("--out", OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(out_dir)

	var sheet := HBoxContainer.new()
	sheet.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sheet.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(sheet)

	var failures := 0
	for sticker in STICKERS:
		var id := String(sticker["id"])
		var viewport := SubViewport.new()
		viewport.size = STICKER_SIZE
		# Transparent, because a sticker is a cut-out shape laid over a drawing.
		viewport.transparent_bg = true
		viewport.disable_3d = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(viewport)

		var art := StickerArt.new(id)
		art.size = Vector2(STICKER_SIZE)
		viewport.add_child(art)

		var preview := TextureRect.new()
		preview.custom_minimum_size = Vector2(96.0, 96.0)
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		preview.texture = viewport.get_texture()
		sheet.add_child(preview)

		for i in 3:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw

		var image := viewport.get_texture().get_image()
		var path := out_dir.path_join("%s.png" % id)
		var error := image.save_png(path)
		if error != OK:
			failures += 1
		print("   %s %s" % [
			"wrote" if error == OK else "FAILED to write (error %d)" % error,
			ProjectSettings.globalize_path(path)
		])

	print("   %d sticker(s), %d failure(s)" % [STICKERS.size(), failures])
	print("   remember: <godot_exe> --path godot --headless --import")

	if "--stay" in OS.get_cmdline_user_args():
		print("[dev] --stay given; the sheet is on screen.")
		return
	get_tree().quit(0 if failures == 0 else 1)


static func _arg_value(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(flag)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return fallback

extends SceneTree
## Dev tool — generates the hand-made test line-art pages for `test_book`.
##
## Usage:
##   <godot_exe> --headless --path godot --script tools/generate_test_page.gd
##   <godot_exe> ... --script tools/generate_test_page.gd -- --layout 2 --out res://.../page_02.png
##   <godot_exe> ... --script tools/generate_test_page.gd -- <res://out.png>   (legacy positional)
##
## Two layouts ship, both 1024x1024 white pages with anti-aliased dark outlines:
##
## [b]--layout 1[/b] (default, page_01) — eight regions: seven shape interiors
## plus the background. A circle nested inside a square gives the mapping
## pipeline a hole to trace; the shapes mix straight edges (rectangles, triangle)
## with curved ones (circles, ellipse, stadium/capsule).
##
## [b]--layout 2[/b] (page_02) — a deliberately DIFFERENT arrangement so the
## page-flip flow has real second-page data: eight regions again, but built from
## a concentric sun (ring + core: the nested pair), a diamond, a banner
## rectangle, an ellipse, a horizontal capsule and a small circle. Nothing sits
## where a layout-1 shape sat, so a coordinate that is line art on page 1 is
## paintable on page 2 (and vice versa) — which is exactly how the flow smoke
## test proves the page really swapped.
##
## Invoking with NO arguments reproduces page_01 byte-for-byte; layout 1's
## drawing code is untouched.

# --------------------------------------------------------------- tunables ---
## Default destination. Overridable with `--out <path>` or a single positional
## user argument after `--`.
const DEFAULT_OUTPUT_PATH := "res://assets/books/test_book/page_01.png"
## Default layout id. Overridable with `--layout <n>`.
const DEFAULT_LAYOUT := 1
## Layout id -> { draw: method name, name, outlines, nested, regions }. The
## expected region count is what the mapping pipeline must report and what the
## flow smoke test asserts against the generated JSON.
const LAYOUTS := {
	1: {
		"draw": "_draw_layout_1",
		"name": "shape sampler",
		"outlines": 7,
		"nested": 1,
		"regions": 8,
	},
	2: {
		"draw": "_draw_layout_2",
		"name": "sun, diamond and banner",
		"outlines": 7,
		"nested": 1,
		"regions": 8,
	},
}
## Page dimensions in pixels.
const PAGE_WIDTH := 1024
const PAGE_HEIGHT := 1024
## Stroke thickness of the line art, in pixels (design target: 4-8 px).
const LINE_WIDTH := 6.0
## Paper and ink colors. Ink is anti-aliased against paper so the mapping
## pipeline's binarize step has soft edge pixels to classify.
const PAPER_COLOR := Color.WHITE
const INK_COLOR := Color.BLACK

# ------------------------------------------------------------ working state --
## Per-pixel ink coverage in 0..1, accumulated with max() so overlapping strokes
## do not double-darken.
var _coverage := PackedFloat32Array()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var layout := DEFAULT_LAYOUT
	var output_path := ""
	var arg_index := 0
	while arg_index < args.size():
		var arg: String = args[arg_index]
		match arg:
			"--layout":
				if arg_index + 1 >= args.size():
					printerr("--layout needs a number")
					quit(2)
					return
				layout = int(args[arg_index + 1])
				arg_index += 2
			"--out":
				if arg_index + 1 >= args.size():
					printerr("--out needs a path")
					quit(2)
					return
				output_path = args[arg_index + 1]
				arg_index += 2
			_:
				if arg.begins_with("--"):
					printerr("Unknown option: %s" % arg)
					quit(2)
					return
				# Legacy positional form: `-- <res://out.png>`.
				output_path = arg
				arg_index += 1
	if output_path == "":
		output_path = DEFAULT_OUTPUT_PATH

	if not LAYOUTS.has(layout):
		printerr("Unknown layout %d (known: %s)" % [layout, LAYOUTS.keys()])
		quit(2)
		return

	_coverage.resize(PAGE_WIDTH * PAGE_HEIGHT)
	call(String(LAYOUTS[layout]["draw"]))

	var bytes := PackedByteArray()
	bytes.resize(PAGE_WIDTH * PAGE_HEIGHT * 4)
	for i in _coverage.size():
		var ink := _coverage[i]
		var value := int(round(lerpf(PAPER_COLOR.r, INK_COLOR.r, ink) * 255.0))
		bytes[i * 4] = value
		bytes[i * 4 + 1] = value
		bytes[i * 4 + 2] = value
		bytes[i * 4 + 3] = 255
	var image := Image.create_from_data(PAGE_WIDTH, PAGE_HEIGHT, false, Image.FORMAT_RGBA8, bytes)

	var dir_path := output_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			printerr("Could not create directory %s (error %d)" % [dir_path, err])
			quit(1)
			return

	var save_err := image.save_png(output_path)
	if save_err != OK:
		printerr("Could not write %s (error %d)" % [output_path, save_err])
		quit(1)
		return

	var info: Dictionary = LAYOUTS[layout]
	print("Wrote %s (%dx%d, line width %.1f px)" % [
		output_path, PAGE_WIDTH, PAGE_HEIGHT, LINE_WIDTH
	])
	print("Layout %d (%s): %d closed outlines (%d nested) -> %d expected regions incl. background" % [
		layout, info["name"], int(info["outlines"]), int(info["nested"]), int(info["regions"])
	])
	quit(0)


## Layout 1 (page_01). Coordinates are hand-tuned so no two shapes come
## closer than ~10 px, leaving a clean channel of background between them.
func _draw_layout_1() -> void:
	# 1. Square with a circle nested inside it -> region with a hole.
	_stroke_rect(Rect2(64.0, 64.0, 400.0, 400.0))
	_stroke_circle(Vector2(264.0, 264.0), 120.0)
	# 2. Small rectangle (smallest region).
	_stroke_rect(Rect2(480.0, 60.0, 80.0, 130.0))
	# 3. Large circle.
	_stroke_circle(Vector2(770.0, 250.0), 170.0)
	# 4. Triangle (straight edges only).
	_stroke_polygon(PackedVector2Array([
		Vector2(600.0, 520.0), Vector2(950.0, 520.0), Vector2(775.0, 845.0)
	]))
	# 5. Ellipse.
	_stroke_ellipse(Vector2(250.0, 760.0), Vector2(185.0, 140.0))
	# 6. Stadium/capsule — straight sides with curved caps.
	_stroke_capsule(Vector2(660.0, 930.0), Vector2(920.0, 930.0), 55.0)


## Layout 2 (page_02) — the second page of the test book. Same rules as layout 1
## (>= ~10 px of clear background between any two outlines, one nested pair), but
## every shape is in a different place and of a different kind, so the two pages
## are trivially distinguishable by an ID-map lookup at a fixed coordinate.
func _draw_layout_2() -> void:
	# 1. Concentric "sun": ring + core. The core is the nested region (a hole in
	#    the ring), this layout's counterpart to layout 1's circle-in-a-square.
	_stroke_circle(Vector2(270.0, 250.0), 180.0)
	_stroke_circle(Vector2(270.0, 250.0), 80.0)
	# 2. Diamond (straight edges, rotated 45 degrees -- no axis-aligned edges).
	_stroke_polygon(PackedVector2Array([
		Vector2(760.0, 90.0), Vector2(940.0, 250.0), Vector2(760.0, 410.0), Vector2(580.0, 250.0)
	]))
	# 3. Wide banner rectangle, left of centre.
	_stroke_rect(Rect2(80.0, 520.0, 480.0, 180.0))
	# 4. Ellipse, right of the banner.
	_stroke_ellipse(Vector2(810.0, 600.0), Vector2(150.0, 110.0))
	# 5. Horizontal capsule along the bottom left.
	_stroke_capsule(Vector2(200.0, 860.0), Vector2(500.0, 860.0), 70.0)
	# 6. Small circle, bottom right (the smallest region on the page).
	_stroke_circle(Vector2(820.0, 860.0), 90.0)


# ------------------------------------------------------------- primitives ---

func _stroke_rect(rect: Rect2) -> void:
	_stroke_polygon(PackedVector2Array([
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	]))


func _stroke_polygon(points: PackedVector2Array) -> void:
	for i in points.size():
		_stroke_segment(points[i], points[(i + 1) % points.size()])


func _stroke_segment(a: Vector2, b: Vector2) -> void:
	var bounds := _bounds_of(PackedVector2Array([a, b]))
	_stamp(bounds, func(p: Vector2) -> float: return _distance_to_segment(p, a, b))


func _stroke_circle(center: Vector2, radius: float) -> void:
	var extent := Vector2(radius, radius)
	_stamp(
		_bounds_of(PackedVector2Array([center - extent, center + extent])),
		func(p: Vector2) -> float: return absf(p.distance_to(center) - radius)
	)


func _stroke_ellipse(center: Vector2, radii: Vector2) -> void:
	_stamp(
		_bounds_of(PackedVector2Array([center - radii, center + radii])),
		func(p: Vector2) -> float: return _distance_to_ellipse(p, center, radii)
	)


## Stadium: the set of points at `radius` from the segment a-b.
func _stroke_capsule(a: Vector2, b: Vector2, radius: float) -> void:
	var extent := Vector2(radius, radius)
	_stamp(
		_bounds_of(PackedVector2Array([a - extent, a + extent, b - extent, b + extent])),
		func(p: Vector2) -> float: return absf(_distance_to_segment(p, a, b) - radius)
	)


## Rasterizes one stroke: `distance_fn` returns the distance from a pixel center
## to the stroke centerline; coverage falls off over one pixel for anti-aliasing.
func _stamp(bounds: Rect2i, distance_fn: Callable) -> void:
	var half_width := LINE_WIDTH * 0.5
	for y in range(bounds.position.y, bounds.end.y):
		var row := y * PAGE_WIDTH
		for x in range(bounds.position.x, bounds.end.x):
			var distance: float = distance_fn.call(Vector2(x, y))
			var ink := clampf(half_width + 0.5 - distance, 0.0, 1.0)
			if ink > _coverage[row + x]:
				_coverage[row + x] = ink


## Clipped integer bounding box padded for the stroke width and the AA falloff.
func _bounds_of(points: PackedVector2Array) -> Rect2i:
	var pad := LINE_WIDTH * 0.5 + 2.0
	var min_point := points[0]
	var max_point := points[0]
	for p in points:
		min_point = min_point.min(p)
		max_point = max_point.max(p)
	var start := Vector2i((min_point - Vector2(pad, pad)).floor())
	var end := Vector2i((max_point + Vector2(pad, pad)).ceil())
	start = start.clamp(Vector2i.ZERO, Vector2i(PAGE_WIDTH, PAGE_HEIGHT))
	end = end.clamp(Vector2i.ZERO, Vector2i(PAGE_WIDTH, PAGE_HEIGHT))
	return Rect2i(start, end - start)


static func _distance_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_squared := ab.length_squared()
	if length_squared < 0.000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / length_squared, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## First-order distance to the ellipse outline: |f| / |grad f| for the implicit
## form f(p) = (x/rx)^2 + (y/ry)^2 - 1. Accurate to well under a pixel near the
## curve, which is all the anti-aliased falloff needs.
static func _distance_to_ellipse(p: Vector2, center: Vector2, radii: Vector2) -> float:
	var d := p - center
	var rx2 := radii.x * radii.x
	var ry2 := radii.y * radii.y
	var f := (d.x * d.x) / rx2 + (d.y * d.y) / ry2 - 1.0
	var gradient := Vector2(2.0 * d.x / rx2, 2.0 * d.y / ry2)
	var gradient_length := gradient.length()
	if gradient_length < 0.000001:
		return minf(radii.x, radii.y)
	return absf(f) / gradient_length

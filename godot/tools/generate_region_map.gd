extends SceneTree
## Dev tool — the ColoringBook mapping pipeline (docs/DESIGN.md §3.1 & §4).
##
## Turns a line-art page PNG into the per-page runtime artifacts:
##   <page>_idmap.png    lossless region ID map (#000000 = line / unpaintable)
##   <page>_regions.json version-1 region polygons, centroids and areas
##   <page>_mask.png     --display runs only: the masking image resampled to the
##                       display page's resolution (BL-12 — a RUNTIME asset now,
##                       drawn as a layer under the display art)
##
## Usage:
##   <godot_exe> --headless --path <project> \
##       --script tools/generate_region_map.gd -- assets/books/<book>/page_01.png
##
## The positional argument is the MAPPING SOURCE: the image whose lines decide
## where paint may go. For a plain page that is the page art itself, and the
## artifacts land next to it.
##
## Pages mapped from a separate masking image (BL-9) pass the mask as the source
## and name the page's display art with --display:
##   ... -- assets/books/coyote/source/coyote_outline_source.png \
##          --display assets/books/coyote/page_01.png
## The artifacts are then written next to the DISPLAY image (page_01_idmap.png,
## page_01_regions.json, page_01_mask.png), because that is the page they belong
## to, and the mask is resized to the display image's dimensions when the two
## differ — the artist's mask arrives at print resolution while the shipped page
## is inside the 2048 px budget, and an ID map that does not match the display
## image pixel for pixel is unusable.
##
## That resampled mask is ALSO written out as <page>_mask.png (BL-12): it is no
## longer build-only. The runtime draws it as a permanent layer between the paint
## and the display art, so its outlines stay visible over the paint as region
## guides. Only the resampled artifact ships; the artist's print-size original
## stays behind the source/ .gdignore, named in the JSON's "mask_image" field for
## provenance.
##
## Optional flags, after the source path (M6 — real art varies in line weight and
## the shipped defaults are not going to suit every page; overriding them per run
## beats editing constants and forgetting to put them back):
##   --display <path>             page art the artifacts belong to (see above)
##   --line-alpha-min <0..1>      opacity floor for a pixel to count as ink
##   --line-luminance-max <0..1>  brightness ceiling for a pixel to count as ink
##   --dilate <px>                line-mask growth; 0 disables the halo
##   --min-area <px>              components smaller than this are specks
##   --rdp <px>                   polygon simplification tolerance
##   --giant-fraction <0..1>      "one region ate the page" failure threshold
##
## The values actually used are printed in the run summary, so a page's mapping
## can always be reproduced from its log.
##
## Never referenced by game scenes. Outputs are build artifacts of the source
## PNG — regenerate rather than hand-edit.

# --------------------------------------------------------------- tunables ---
# Defaults live here as constants (mapping-pipeline: "keep thresholds/tolerances
# as script constants at the top of the file"); the working copies below are the
# same values unless a CLI flag overrides them.

## A pixel counts as LINE when it is at least this opaque AND at most this
## bright. The luminance ceiling is deliberately generous so anti-aliased line
## edges land on the LINE side — a region must never own a half-dark pixel.
const DEFAULT_LINE_ALPHA_MIN := 0.5
const DEFAULT_LINE_LUMINANCE_MAX := 0.75
## Grow the line mask by this many pixels (8-neighbourhood) before segmenting.
## This is what guarantees the ~1 px #000000 halo around every region, so two
## region colors can never end up touching (not even diagonally) in the ID map.
## Set to 0 to disable.
const DEFAULT_LINE_DILATE_PX := 1
## Connected components smaller than this are anti-aliasing specks, not regions;
## they are folded back into the line mask.
const DEFAULT_MIN_REGION_AREA_PX := 64
## Ramer-Douglas-Peucker tolerance in pixels for outline/hole simplification.
## Larger = fewer vertices, coarser polygons. The ID map stays pixel-exact.
const DEFAULT_RDP_TOLERANCE_PX := 1.5
## Hard-fail when a single region owns more than this fraction of all paintable
## pixels — the classic symptom of a gap in the line art merging everything.
const DEFAULT_GIANT_REGION_FRACTION := 0.9

var LINE_ALPHA_MIN := DEFAULT_LINE_ALPHA_MIN
var LINE_LUMINANCE_MAX := DEFAULT_LINE_LUMINANCE_MAX
var LINE_DILATE_PX := DEFAULT_LINE_DILATE_PX
var MIN_REGION_AREA_PX := DEFAULT_MIN_REGION_AREA_PX
var RDP_TOLERANCE_PX := DEFAULT_RDP_TOLERANCE_PX
var GIANT_REGION_FRACTION := DEFAULT_GIANT_REGION_FRACTION
## --display: the page's visible art when the source above is a masking image.
## Empty means "the source IS the page", which is the plain single-image case.
var DISPLAY_IMAGE_PATH := ""
## Snap a centroid onto its own region when the area-weighted mean falls in a
## hole or outside a concave region. Consumers use centroids as "tap here"
## markers, so a centroid that is not inside its region is useless.
const CENTROID_SNAP_TO_REGION := true
## Schema version written to the JSON (docs/DESIGN.md §3.1).
const SCHEMA_VERSION := 1

# ------------------------------------------------------- contour direction --
const DIR_N := 0
const DIR_E := 1
const DIR_S := 2
const DIR_W := 3
const DIR_STEPS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)
]

# ------------------------------------------------------------ working state --
var _width := 0
var _height := 0
## 1 = line / unpaintable, 0 = paintable. Length _width * _height.
var _line_mask := PackedByteArray()
## 0 = line / unpaintable, >0 = region id. Length _width * _height.
var _labels := PackedInt32Array()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("Usage: --script tools/generate_region_map.gd -- <path/to/page.png>")
		quit(2)
		return

	if not _apply_flags(args):
		quit(2)
		return

	var source_path := _to_res_path(args[0])
	var image := Image.load_from_file(source_path)
	if image == null:
		printerr("Could not load source image: %s" % source_path)
		quit(2)
		return

	image.convert(Image.FORMAT_RGBA8)
	print("Source: %s (%dx%d)" % [source_path, image.get_width(), image.get_height()])

	# With --display, the mapping source is a MASK and the artifacts belong to the
	# page art instead: they are written next to it and must match its dimensions.
	var page_path := source_path
	if DISPLAY_IMAGE_PATH != "":
		page_path = _to_res_path(DISPLAY_IMAGE_PATH)
		if not _align_to_display(image, page_path):
			quit(2)
			return

	_width = image.get_width()
	_height = image.get_height()
	print("Tunables: %s" % _tunable_summary())

	_binarize(image.get_data())
	if LINE_DILATE_PX > 0:
		_dilate_line_mask(LINE_DILATE_PX)
	var raw_region_count := _flood_fill_regions()
	var stats := _compact_regions(raw_region_count)
	var regions: Array[Dictionary] = stats["regions"]
	var dropped_specks: int = stats["dropped_specks"]

	# Validate before writing anything: a failed run must never leave a broken
	# ID map or JSON next to the art for the game to pick up.
	var problem := _validate(regions)
	if problem != "":
		printerr("FAIL: " + problem)
		quit(1)
		return

	var base_path := page_path.get_basename()
	var idmap_path := base_path + "_idmap.png"
	if not _write_idmap(idmap_path):
		quit(1)
		return

	# BL-12: the mask is a runtime layer now, so the display-resolution version we
	# just mapped from is written out beside the ID map. `image` is exactly that --
	# _binarize() only READ it -- so this costs a PNG encode and nothing else.
	var mask_path := ""
	if DISPLAY_IMAGE_PATH != "":
		mask_path = base_path + "_mask.png"
		if not _write_mask(mask_path, image):
			quit(1)
			return

	_trace_regions(regions)
	if CENTROID_SNAP_TO_REGION:
		_snap_centroids(regions)

	var json_path := base_path + "_regions.json"
	var mask_file := source_path.get_file() if DISPLAY_IMAGE_PATH != "" else ""
	if not _write_regions_json(json_path, page_path.get_file(), mask_file, regions):
		quit(1)
		return

	_report(regions, dropped_specks, idmap_path, json_path, mask_path)
	quit(0)


# ---------------------------------------------------------- 0. CLI flags ----

## Reads the optional `--flag value` pairs that may follow the source path.
## Returns false (after printing why) on an unknown flag or a missing value, so a
## typo can never silently produce a mapping made with the wrong thresholds.
func _apply_flags(args: PackedStringArray) -> bool:
	var index := 1
	while index < args.size():
		var flag := args[index]
		if index + 1 >= args.size():
			printerr("FAIL: '%s' needs a value." % flag)
			return false
		var value := args[index + 1]
		index += 2
		match flag:
			"--display":
				DISPLAY_IMAGE_PATH = value
			"--line-alpha-min":
				LINE_ALPHA_MIN = clampf(value.to_float(), 0.0, 1.0)
			"--line-luminance-max":
				LINE_LUMINANCE_MAX = clampf(value.to_float(), 0.0, 1.0)
			"--dilate":
				LINE_DILATE_PX = maxi(value.to_int(), 0)
			"--min-area":
				MIN_REGION_AREA_PX = maxi(value.to_int(), 1)
			"--rdp":
				RDP_TOLERANCE_PX = maxf(value.to_float(), 0.0)
			"--giant-fraction":
				GIANT_REGION_FRACTION = clampf(value.to_float(), 0.01, 1.0)
			_:
				printerr("FAIL: unknown flag '%s'. See the header of this script." % flag)
				return false
	return true


## Makes the mask [param image] line up with the page art at [param page_path],
## in place. Returns false (after printing why) when the page art cannot be read.
##
## Same size is the normal case and costs nothing. Different size means the mask
## is the artist's print-resolution original and the page is the downscaled ship
## version: resample the mask rather than making the artist do it, because the ID
## map has to be pixel-for-pixel the size of the display image. Lanczos keeps thin
## ink dark enough to survive binarization; the aspect ratio is checked so a mask
## that is not the same drawing gets caught instead of being squashed.
func _align_to_display(image: Image, page_path: String) -> bool:
	var page_image := Image.load_from_file(page_path)
	if page_image == null:
		printerr("FAIL: --display image could not be loaded: %s" % page_path)
		return false
	var page_size := Vector2i(page_image.get_width(), page_image.get_height())
	print("Display: %s (%dx%d) — artifacts are written next to it"
		% [page_path, page_size.x, page_size.y])
	if Vector2i(image.get_width(), image.get_height()) == page_size:
		return true
	var mask_aspect := float(image.get_width()) / float(image.get_height())
	var page_aspect := float(page_size.x) / float(page_size.y)
	if absf(mask_aspect - page_aspect) > 0.01:
		printerr(("FAIL: mask aspect %.3f does not match display aspect %.3f. These are not "
			+ "the same drawing at two resolutions; a squashed mask would map the wrong "
			+ "pixels.") % [mask_aspect, page_aspect])
		return false
	print("   mask resized %dx%d -> %dx%d (lanczos) to match the display image"
		% [image.get_width(), image.get_height(), page_size.x, page_size.y])
	image.resize(page_size.x, page_size.y, Image.INTERPOLATE_LANCZOS)
	image.convert(Image.FORMAT_RGBA8)
	return true


func _tunable_summary() -> String:
	return (
		"line alpha >= %.2f, luminance <= %.2f | dilate %d px | min area %d px | "
		+ "rdp %.2f px | giant limit %.0f%%"
	) % [
		LINE_ALPHA_MIN, LINE_LUMINANCE_MAX, LINE_DILATE_PX,
		MIN_REGION_AREA_PX, RDP_TOLERANCE_PX, 100.0 * GIANT_REGION_FRACTION,
	]


# ----------------------------------------------------------- 1. binarize ----

## Classifies every pixel as LINE or paintable. Anti-aliased edges belong to the
## line: they are dark enough to fail the luminance ceiling.
func _binarize(rgba: PackedByteArray) -> void:
	var count := _width * _height
	_line_mask.resize(count)
	var alpha_min := int(round(LINE_ALPHA_MIN * 255.0))
	var luminance_max := LINE_LUMINANCE_MAX * 255.0
	for i in count:
		var offset := i * 4
		var alpha := rgba[offset + 3]
		if alpha < alpha_min:
			_line_mask[i] = 0
			continue
		# Rec. 709 luma.
		var luminance := (
			0.2126 * rgba[offset] + 0.7152 * rgba[offset + 1] + 0.0722 * rgba[offset + 2]
		)
		_line_mask[i] = 1 if luminance <= luminance_max else 0


## Grows the line mask by `radius` pixels using an 8-neighbourhood, iteratively.
## Written as a scatter from the ink rather than a gather per pixel: the inner
## 3x3 work only runs on line pixels.
func _dilate_line_mask(radius: int) -> void:
	for _step in radius:
		var grown := _line_mask.duplicate()
		for y in _height:
			var row := y * _width
			for x in _width:
				if _line_mask[row + x] == 0:
					continue
				for dy in range(maxi(y - 1, 0), mini(y + 2, _height)):
					var neighbour_row := dy * _width
					for dx in range(maxi(x - 1, 0), mini(x + 2, _width)):
						grown[neighbour_row + dx] = 1
		_line_mask = grown


# ------------------------------------------------- 2. flood-fill segments ---

## Scanline flood fill (explicit span stack — never recursion; a 1024x1024 page
## is over a million pixels and would blow the call stack). Returns the number
## of raw components found; labels are 1..n in raster discovery order.
func _flood_fill_regions() -> int:
	_labels = PackedInt32Array()
	_labels.resize(_width * _height)
	var stack: Array[int] = []
	var next_id := 0

	for start_y in _height:
		var start_row := start_y * _width
		for start_x in _width:
			if _line_mask[start_row + start_x] != 0 or _labels[start_row + start_x] != 0:
				continue
			next_id += 1
			stack.append(start_x)
			stack.append(start_y)

			while not stack.is_empty():
				var y: int = stack.pop_back()
				var x: int = stack.pop_back()
				var row := y * _width
				if _labels[row + x] != 0:
					continue
				var left := x
				while left > 0 and _line_mask[row + left - 1] == 0 and _labels[row + left - 1] == 0:
					left -= 1
				var right := x
				while (
					right < _width - 1
					and _line_mask[row + right + 1] == 0
					and _labels[row + right + 1] == 0
				):
					right += 1
				for fill_x in range(left, right + 1):
					_labels[row + fill_x] = next_id
				if y > 0:
					_push_spans(stack, left, right, y - 1)
				if y < _height - 1:
					_push_spans(stack, left, right, y + 1)
	return next_id


## Pushes one seed per unlabelled run of `row_y` between `left` and `right`.
## Seeds that get swallowed by another span before they pop are skipped by the
## label check in the fill loop.
func _push_spans(stack: Array[int], left: int, right: int, row_y: int) -> void:
	var row := row_y * _width
	var x := left
	while x <= right:
		if _line_mask[row + x] != 0 or _labels[row + x] != 0:
			x += 1
			continue
		stack.append(x)
		stack.append(row_y)
		while x <= right and _line_mask[row + x] == 0 and _labels[row + x] == 0:
			x += 1


# ------------------------------------------- 3. drop specks & assign ids ----

## Measures every raw component, folds sub-minimum ones back into the line mask,
## and renumbers the survivors to a contiguous 1..n id space (id 0 / #000000
## stays reserved for lines). Returns { "regions": [...], "dropped_specks": n }.
func _compact_regions(raw_region_count: int) -> Dictionary:
	var areas := PackedInt32Array()
	areas.resize(raw_region_count + 1)
	var sum_x := PackedFloat64Array()
	sum_x.resize(raw_region_count + 1)
	var sum_y := PackedFloat64Array()
	sum_y.resize(raw_region_count + 1)
	var min_x := PackedInt32Array()
	min_x.resize(raw_region_count + 1)
	var min_y := min_x.duplicate()
	var max_x := min_x.duplicate()
	var max_y := min_x.duplicate()
	for i in raw_region_count + 1:
		min_x[i] = _width
		min_y[i] = _height
		max_x[i] = -1
		max_y[i] = -1

	for y in _height:
		var row := y * _width
		for x in _width:
			var raw_id := _labels[row + x]
			if raw_id == 0:
				continue
			areas[raw_id] += 1
			sum_x[raw_id] += x
			sum_y[raw_id] += y
			min_x[raw_id] = mini(min_x[raw_id], x)
			min_y[raw_id] = mini(min_y[raw_id], y)
			max_x[raw_id] = maxi(max_x[raw_id], x)
			max_y[raw_id] = maxi(max_y[raw_id], y)

	var remap := PackedInt32Array()
	remap.resize(raw_region_count + 1)
	var regions: Array[Dictionary] = []
	var dropped_specks := 0
	for raw_id in range(1, raw_region_count + 1):
		if areas[raw_id] < MIN_REGION_AREA_PX:
			dropped_specks += 1
			continue
		var id := regions.size() + 1
		remap[raw_id] = id
		regions.append({
			"id": id,
			"id_color": _id_to_hex(id),
			"area_px": areas[raw_id],
			"centroid": Vector2(
				sum_x[raw_id] / float(areas[raw_id]), sum_y[raw_id] / float(areas[raw_id])
			),
			"bounds": Rect2i(
				min_x[raw_id],
				min_y[raw_id],
				max_x[raw_id] - min_x[raw_id] + 1,
				max_y[raw_id] - min_y[raw_id] + 1
			),
			"outline": PackedVector2Array(),
			"holes": [],
		})

	for i in _labels.size():
		var raw_id := _labels[i]
		if raw_id == 0:
			continue
		var id := remap[raw_id]
		_labels[i] = id
		if id == 0:
			_line_mask[i] = 1

	return {"regions": regions, "dropped_specks": dropped_specks}


func _write_idmap(path: String) -> bool:
	var bytes := PackedByteArray()
	bytes.resize(_width * _height * 3)
	for i in _labels.size():
		var id := _labels[i]
		var offset := i * 3
		bytes[offset] = (id >> 16) & 0xFF
		bytes[offset + 1] = (id >> 8) & 0xFF
		bytes[offset + 2] = id & 0xFF
	var image := Image.create_from_data(_width, _height, false, Image.FORMAT_RGB8, bytes)
	var err := image.save_png(path)
	if err != OK:
		printerr("FAIL: could not write %s (error %d)" % [path, err])
		return false
	return true


## The third artifact (BL-12): the masking image at the DISPLAY page's resolution,
## which is precisely the image the segmentation above ran on. It ships and is
## rendered as a layer under the display art, so its outlines stay visible over
## the paint. Ordinary art as far as the importer is concerned -- unlike the ID
## map, nothing here has to survive bit-exactly.
func _write_mask(path: String, image: Image) -> bool:
	var err := image.save_png(path)
	if err != OK:
		printerr("FAIL: could not write %s (error %d)" % [path, err])
		return false
	return true


# ------------------------------------------------ 4. marching-squares trace --

## Traces every region's boundary loops, classifies them into outline + holes
## and simplifies each with Ramer-Douglas-Peucker.
func _trace_regions(regions: Array[Dictionary]) -> void:
	var loops_by_id := _trace_all_loops()
	for region in regions:
		var id: int = region["id"]
		var loops: Array = loops_by_id.get(id, [])
		var outline := PackedVector2Array()
		var holes: Array[PackedVector2Array] = []
		for loop: PackedVector2Array in loops:
			var simplified := _simplify(loop, RDP_TOLERANCE_PX)
			if simplified.size() < 3:
				continue
			# The walk keeps the region on its left, which makes outer loops
			# negative and holes positive under the shoelace formula (y-down).
			if _signed_area(loop) < 0.0:
				outline = simplified
			else:
				holes.append(simplified)
		region["outline"] = outline
		region["holes"] = holes


## Single raster pass that finds a start edge for every boundary loop of every
## region: a horizontal label change means a vertical crack, and every closed
## loop contains at least one. Each loop is then walked once (marching-squares
## case table) with a shared visited-edge set for deduplication.
func _trace_all_loops() -> Dictionary:
	var loops_by_id := {}
	var visited := {}
	for y in _height:
		var row := y * _width
		var previous_label := 0
		for x in _width + 1:
			var current_label := _labels[row + x] if x < _width else 0
			if current_label != previous_label:
				if current_label != 0:
					_maybe_trace(Vector2i(x, y), DIR_S, current_label, visited, loops_by_id)
				if previous_label != 0:
					_maybe_trace(Vector2i(x, y + 1), DIR_N, previous_label, visited, loops_by_id)
			previous_label = current_label
	return loops_by_id


func _maybe_trace(
	start: Vector2i, start_dir: int, id: int, visited: Dictionary, loops_by_id: Dictionary
) -> void:
	if visited.has(_edge_key(start, start_dir)):
		return
	var loop := _walk_loop(start, start_dir, id, visited)
	if loop.size() < 3:
		return
	if not loops_by_id.has(id):
		loops_by_id[id] = []
	loops_by_id[id].append(loop)


## Walks one closed boundary loop along pixel cracks, emitting a vertex wherever
## the direction changes. Coordinates are pixel corners (0.._width, 0.._height).
func _walk_loop(start: Vector2i, start_dir: int, id: int, visited: Dictionary) -> PackedVector2Array:
	var points := PackedVector2Array()
	var point := start
	var dir := start_dir
	while true:
		var key := _edge_key(point, dir)
		if visited.has(key):
			break
		visited[key] = true
		point += DIR_STEPS[dir]
		var next_dir := _next_dir(point.x, point.y, id, dir)
		if next_dir < 0:
			break
		if next_dir != dir:
			points.append(Vector2(point))
		dir = next_dir
	return points


func _edge_key(point: Vector2i, dir: int) -> int:
	return ((point.y * (_width + 1) + point.x) << 2) | dir


## Marching-squares case table for the 2x2 pixel block around corner (x, y).
## Bits: 1 = up-left, 2 = up-right, 4 = down-left, 8 = down-right belong to the
## region. The two saddles (6 and 9) are resolved by keeping the same pixel on
## the walker's left, which keeps the walk on one boundary component.
func _next_dir(x: int, y: int, id: int, previous_dir: int) -> int:
	var state := 0
	if _label_at(x - 1, y - 1) == id:
		state |= 1
	if _label_at(x, y - 1) == id:
		state |= 2
	if _label_at(x - 1, y) == id:
		state |= 4
	if _label_at(x, y) == id:
		state |= 8
	match state:
		1, 5, 13:
			return DIR_N
		2, 3, 7:
			return DIR_E
		8, 10, 11:
			return DIR_S
		4, 12, 14:
			return DIR_W
		6:
			return DIR_W if previous_dir == DIR_N else DIR_E
		9:
			return DIR_N if previous_dir == DIR_E else DIR_S
	return -1


func _label_at(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= _width or y >= _height:
		return 0
	return _labels[y * _width + x]


## Ramer-Douglas-Peucker on a closed loop, keeping the first and last vertex.
## Iterative: the recursion depth of RDP is O(n) in the worst case.
static func _simplify(points: PackedVector2Array, tolerance: float) -> PackedVector2Array:
	if points.size() < 3:
		return points
	var keep := PackedByteArray()
	keep.resize(points.size())
	keep[0] = 1
	keep[points.size() - 1] = 1
	var stack: Array[Vector2i] = [Vector2i(0, points.size() - 1)]
	while not stack.is_empty():
		var span: Vector2i = stack.pop_back()
		var farthest := -1
		var farthest_distance := tolerance
		for i in range(span.x + 1, span.y):
			var distance := _point_to_segment_distance(points[i], points[span.x], points[span.y])
			if distance > farthest_distance:
				farthest_distance = distance
				farthest = i
		if farthest < 0:
			continue
		keep[farthest] = 1
		stack.push_back(Vector2i(span.x, farthest))
		stack.push_back(Vector2i(farthest, span.y))

	var simplified := PackedVector2Array()
	for i in points.size():
		if keep[i] == 1:
			simplified.append(points[i])
	return simplified


static func _point_to_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_squared := ab.length_squared()
	if length_squared < 0.000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / length_squared, 0.0, 1.0)
	return p.distance_to(a + ab * t)


static func _signed_area(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in points.size():
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		total += a.x * b.y - b.x * a.y
	return total * 0.5


## The area-weighted mean can land in a hole or outside a concave region. When
## it does, move it to the region pixel nearest to that mean so the centroid is
## always a valid "point inside this region".
func _snap_centroids(regions: Array[Dictionary]) -> void:
	for region in regions:
		var id: int = region["id"]
		var centroid: Vector2 = region["centroid"]
		if _label_at(int(round(centroid.x)), int(round(centroid.y))) == id:
			continue
		var bounds: Rect2i = region["bounds"]
		var best := Vector2(centroid)
		var best_distance := INF
		for y in range(bounds.position.y, bounds.end.y):
			var row := y * _width
			for x in range(bounds.position.x, bounds.end.x):
				if _labels[row + x] != id:
					continue
				var distance := centroid.distance_squared_to(Vector2(x, y))
				if distance < best_distance:
					best_distance = distance
					best = Vector2(x, y)
		region["centroid"] = best


# ------------------------------------------------------- JSON serialization --

## [param source_file] is the page the artifacts belong to (the display image);
## [param mask_file] is the masking image they were generated FROM, or "" when
## the page was its own mapping source. "mask_image" is an additive, optional
## schema-v1 field: consumers that predate it (PageView) ignore unknown keys, and
## it is what makes a page's mapping reproducible from the JSON alone.
func _write_regions_json(
	path: String, source_file: String, mask_file: String, regions: Array[Dictionary]
) -> bool:
	var lines := PackedStringArray()
	lines.append("{")
	lines.append("\"version\": %d," % SCHEMA_VERSION)
	lines.append("\"source_image\": %s," % JSON.stringify(source_file))
	if mask_file != "":
		lines.append("\"mask_image\": %s," % JSON.stringify(mask_file))
	lines.append("\"image_size\": [%d, %d]," % [_width, _height])
	lines.append("\"regions\": [")
	var entries := PackedStringArray()
	for region in regions:
		var holes: Array = []
		for hole: PackedVector2Array in region["holes"]:
			holes.append(_polygon_to_array(hole))
		var centroid: Vector2 = region["centroid"]
		entries.append("{\"id\": %d, \"id_color\": %s, \"outline\": %s, \"holes\": %s, \"centroid\": %s, \"area_px\": %d}" % [
			region["id"],
			JSON.stringify(region["id_color"]),
			JSON.stringify(_polygon_to_array(region["outline"])),
			JSON.stringify(holes),
			JSON.stringify([_round2(centroid.x), _round2(centroid.y)]),
			region["area_px"],
		])
	lines.append(",\n".join(entries))
	lines.append("]")
	lines.append("}")

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("FAIL: could not write %s (error %d)" % [path, FileAccess.get_open_error()])
		return false
	file.store_string("\n".join(lines) + "\n")
	file.close()
	return true


static func _polygon_to_array(polygon: PackedVector2Array) -> Array:
	var out: Array = []
	for point in polygon:
		out.append([int(point.x), int(point.y)])
	return out


static func _round2(value: float) -> float:
	return snappedf(value, 0.01)


static func _id_to_hex(id: int) -> String:
	return "#%02x%02x%02x" % [(id >> 16) & 0xFF, (id >> 8) & 0xFF, id & 0xFF]


# ------------------------------------------------------ 5. report & verdict --

## Returns "" when the segmentation looks sane, otherwise the reason it does not.
func _validate(regions: Array[Dictionary]) -> String:
	if regions.is_empty():
		return ("no regions found. Check LINE_LUMINANCE_MAX / LINE_ALPHA_MIN " +
			"(is the art dark line work on white or transparent?) or MIN_REGION_AREA_PX.")
	var paintable := 0
	var largest: Dictionary = regions[0]
	for region in regions:
		paintable += int(region["area_px"])
		if int(region["area_px"]) > int(largest["area_px"]):
			largest = region
	var fraction := float(largest["area_px"]) / float(paintable)
	if fraction > GIANT_REGION_FRACTION:
		return (("region %d covers %.1f%% of all paintable pixels (limit %.0f%%). " +
			"This is almost always a gap in the line art letting the fill leak between " +
			"shapes — close the outline, or lower LINE_LUMINANCE_MAX so faint lines still " +
			"binarize.") % [largest["id"], 100.0 * fraction, 100.0 * GIANT_REGION_FRACTION])
	return ""


## Prints the run summary.
func _report(
	regions: Array[Dictionary], dropped_specks: int, idmap_path: String, json_path: String,
	mask_path: String = ""
) -> void:
	var paintable := 0
	var min_area := int(regions[0]["area_px"])
	var max_area := 0
	var total_holes := 0
	for region in regions:
		var area := int(region["area_px"])
		paintable += area
		min_area = mini(min_area, area)
		max_area = maxi(max_area, area)
		total_holes += (region["holes"] as Array).size()

	print("Wrote %s" % idmap_path)
	print("Wrote %s" % json_path)
	if mask_path != "":
		print("Wrote %s (display-resolution mask layer, BL-12)" % mask_path)
	print("Regions: %d | dropped specks: %d | holes traced: %d" % [
		regions.size(), dropped_specks, total_holes
	])
	print("Area px  min: %d | max: %d | paintable total: %d (%.1f%% of image)" % [
		min_area, max_area, paintable, 100.0 * paintable / float(_width * _height)
	])
	for region in regions:
		print("  id %d %s  area %d  holes %d  outline %d pts  centroid (%.1f, %.1f)" % [
			region["id"], region["id_color"], region["area_px"],
			(region["holes"] as Array).size(), (region["outline"] as PackedVector2Array).size(),
			region["centroid"].x, region["centroid"].y,
		])


static func _to_res_path(path: String) -> String:
	if path.begins_with("res://") or path.is_absolute_path():
		return path
	return "res://" + path

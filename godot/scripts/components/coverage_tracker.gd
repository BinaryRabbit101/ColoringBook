class_name CoverageTracker
extends RefCounted
## Per-region paint coverage and page completion (DESIGN.md 3.2 "coverage
## tracking", coloring-mechanics "Coverage & completion").
##
## [b]Not a node[/b] (godot-practices "not everything is a node"): this is pure
## logic over precomputed geometry, owned by the coloring screen as a plain
## member. It never touches the SceneTree, never reads [code]GameState[/code] and
## never talks to a [PageView] except to READ region geometry once, at page load.
## Everything it needs is injected, which is also what makes it testable without a
## GPU: hand it region polygons and an [Image] and it answers.
##
## [b]How coverage is measured[/b] -- strategy (b) of the two the design allows:
## one paint-layer readback per STROKE END, sampled at a precomputed sparse grid
## of points per region. Never per frame, never a full-image scan.
##
## Why (b) and not the CPU-analytic stroke-path variant: [PageView] is a frozen,
## verified component whose only coverage hook is [signal PageView.stroke_ended]
## -- it deliberately publishes no stroke geometry. Reconstructing the dab path
## would mean either editing [PageView] or running a SECOND input code path in the
## parent, which DESIGN.md 3.3 forbids ("one code path"), and it would silently
## miss strokes driven programmatically. Sampling the real paint layer also
## measures what the region-clipping shader actually produced rather than an
## analytic approximation of it. DESIGN.md 3.2 names exactly this approach:
## "on stroke end, sample the SubViewport texture at a sparse grid of points per
## region ... rather than reading back full images every frame".
##
## The readback itself is the caller's job (it needs the SceneTree to wait for the
## stamp batch to render). The caller times it and passes the [Image] to
## [method update_region]; see [code]coloring_page.gd[/code].
##
## [b]Monotonicity[/b]: covered samples are OR-ed in, so coverage can only rise.
## Re-sampling with an empty image never un-completes a region.

## A region reached [member threshold]. Fires at most once per region.
signal region_completed(region_id: int)
## Every tracked region is done. Fires at most once per page.
signal page_completed()

# ------------------------------------------------------------- sample grids --

## Sample points per region we aim for, and the band the grid search must land
## in. 240 sits in the middle of the 100-400 band the design calls for:
##   * 240 points quantise coverage to ~0.4%, an order of magnitude finer than
##     the gap between the child (0.70) and adult (0.92) thresholds;
##   * the whole page is then ~2000 point lookups per stroke end, two orders of
##     magnitude cheaper than the 1M-pixel scan the naive version would do;
##   * density is per-AREA, so a 1 kpx region and a 600 kpx background get the
##     same statistical confidence rather than the same spacing.
const TARGET_SAMPLES_PER_REGION := 240
const MIN_SAMPLES_PER_REGION := 100
const MAX_SAMPLES_PER_REGION := 400
## Bound on the grid-step search below, so pathological geometry cannot spin.
const MAX_GRID_ATTEMPTS := 10

## Alpha byte at or above which a sample counts as painted. The brush is soft
## (hardness 0.6 in the child palette), so a sample on the feathered edge of a
## dab can be part-transparent; half opacity is unambiguously "the player put
## paint here" while ignoring the faintest fringe.
const COVERED_ALPHA := 128

## Reserved ID-map value: line art / not paintable.
const UNPAINTABLE_ID := 0

# ------------------------------------------------------------------- state --

## Coverage fraction at which a region counts as done. INJECTED (from the active
## [PaletteDef]) -- this class never reads GameState.
var _threshold := 0.7

## region id -> { points: PackedVector2Array, covered: PackedByteArray,
##                covered_count: int, done: bool }
var _regions: Dictionary = {}
## Tracked ids in build order, so [method page_coverage] is deterministic.
var _order: PackedInt32Array = PackedInt32Array()
var _page_done := false


## [param threshold] is the completion fraction, normally
## [member PaletteDef.completion_threshold].
func _init(threshold: float = 0.7) -> void:
	set_threshold(threshold)


## Changes the completion fraction. Raising it can leave a region flagged done
## from before -- completion is sticky by design, a finished page must not
## un-finish under the player.
func set_threshold(threshold: float) -> void:
	_threshold = clampf(threshold, 0.01, 1.0)


func get_threshold() -> float:
	return _threshold


# =================================================================== building ==

## Builds sample grids for every region of the page currently in [param page_view].
## Returns the number of regions tracked.
##
## Reads [method PageView.get_region_data] (JSON polygons) for the geometry and
## [method PageView.get_id_map_image] to reject any grid point the ID map does not
## actually award to the region -- the ~1 px dilated line halo, and the sliver
## between a simplified polygon and the true pixel boundary. That keeps "100%
## coverage" achievable: every sample is a pixel the brush shader is allowed to
## paint.
func build_from_page_view(page_view: PageView) -> int:
	clear()
	if page_view == null or not page_view.is_page_loaded():
		return 0
	var id_image := page_view.get_id_map_image()
	for region_id in page_view.get_region_ids():
		var data := page_view.get_region_data(region_id)
		if data.is_empty():
			continue
		add_region(
			region_id,
			data["outline"],
			data["holes"],
			int(data["area_px"]),
			id_image
		)
	return _order.size()


## Adds one region's sample grid. The low-level entry point: tests call it with
## hand-built polygons and no ID map.
##
## [param outline] / [param holes] are the schema-v1 polygons in page pixel space
## (pixel-corner coordinates); [param area_px] is the region's ID-map pixel count
## and only sets the grid density. Points are taken at pixel CENTRES, so a point
## and the polygon it is tested against are in the same space.
func add_region(
	region_id: int,
	outline: PackedVector2Array,
	holes: Array[PackedVector2Array],
	area_px: int,
	id_image: Image = null
) -> int:
	if region_id <= UNPAINTABLE_ID or outline.size() < 3:
		return 0
	var points := _build_sample_grid(region_id, outline, holes, area_px, id_image)
	if points.is_empty():
		push_warning("CoverageTracker: region %d produced no sample points; not tracked." % region_id)
		return 0
	var covered := PackedByteArray()
	covered.resize(points.size())
	covered.fill(0)
	if not _regions.has(region_id):
		_order.append(region_id)
	_regions[region_id] = {
		"points": points,
		"covered": covered,
		"covered_count": 0,
		"done": false,
	}
	_page_done = false
	return points.size()


## Grid step search: start from the density that would give
## [constant TARGET_SAMPLES_PER_REGION] over the region's area, then nudge the
## step until the point count lands inside [MIN, MAX]. Concave regions and
## regions full of holes lose points to the containment test, which is why the
## first estimate is corrected rather than trusted.
func _build_sample_grid(
	region_id: int,
	outline: PackedVector2Array,
	holes: Array[PackedVector2Array],
	area_px: int,
	id_image: Image
) -> PackedVector2Array:
	var bounds := _bounds_of(outline)
	var effective_area := maxi(area_px, 1)
	var step := maxi(1, int(round(sqrt(float(effective_area) / float(TARGET_SAMPLES_PER_REGION)))))
	var best := PackedVector2Array()
	var best_distance := INF
	for attempt in MAX_GRID_ATTEMPTS:
		var points := _sample_grid_at_step(region_id, outline, holes, bounds, step, id_image)
		var count := points.size()
		# Keep the closest-to-target attempt, so an oscillating search still
		# returns its best grid rather than its last one.
		var distance := absf(float(count) - float(TARGET_SAMPLES_PER_REGION))
		if distance < best_distance:
			best_distance = distance
			best = points
		if count >= MIN_SAMPLES_PER_REGION and count <= MAX_SAMPLES_PER_REGION:
			break
		if count > MAX_SAMPLES_PER_REGION:
			step += maxi(1, step / 4)
		elif step > 1:
			step = maxi(1, int(float(step) * 0.6))
		else:
			break  # Already at one point per pixel; the region is simply tiny.
	return best


func _sample_grid_at_step(
	region_id: int,
	outline: PackedVector2Array,
	holes: Array[PackedVector2Array],
	bounds: Rect2i,
	step: int,
	id_image: Image
) -> PackedVector2Array:
	var points := PackedVector2Array()
	# Half a step of inset so the grid is centred in the region's bounding box
	# instead of hugging its top-left corner.
	var start_x := bounds.position.x + step / 2
	var start_y := bounds.position.y + step / 2
	var has_id_image := id_image != null and not id_image.is_compressed()
	var width := id_image.get_width() if has_id_image else 0
	var height := id_image.get_height() if has_id_image else 0
	var y := start_y
	while y < bounds.end.y:
		var x := start_x
		while x < bounds.end.x:
			var point := Vector2(float(x) + 0.5, float(y) + 0.5)
			if _is_inside(point, outline, holes):
				if not has_id_image:
					points.append(point)
				elif x >= 0 and y >= 0 and x < width and y < height:
					var pixel := id_image.get_pixel(x, y)
					if ((pixel.r8 << 16) | (pixel.g8 << 8) | pixel.b8) == region_id:
						points.append(point)
			x += step
		y += step
	return points


## Inside the outline and outside every hole (DESIGN.md 3.1: holes are separate
## polygons, not stitched into the outline).
static func _is_inside(
	point: Vector2, outline: PackedVector2Array, holes: Array[PackedVector2Array]
) -> bool:
	if not Geometry2D.is_point_in_polygon(point, outline):
		return false
	for hole in holes:
		if hole.size() >= 3 and Geometry2D.is_point_in_polygon(point, hole):
			return false
	return true


static func _bounds_of(polygon: PackedVector2Array) -> Rect2i:
	var minimum := polygon[0]
	var maximum := polygon[0]
	for point in polygon:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return Rect2i(Vector2i(minimum.floor()), Vector2i(maximum.ceil()) - Vector2i(minimum.floor()))


# =================================================================== updating ==

## Re-samples one region against [param paint_image] (the paint layer read back
## once, at stroke end) and emits [signal region_completed] / [signal page_completed]
## as thresholds are crossed. Returns the region's new coverage.
##
## Safe to call with a stale or empty image: coverage only ever rises.
func update_region(region_id: int, paint_image: Image) -> float:
	if not _regions.has(region_id) or paint_image == null:
		return region_coverage(region_id)
	var record: Dictionary = _regions[region_id]
	var points: PackedVector2Array = record["points"]
	var covered: PackedByteArray = record["covered"]
	var count: int = record["covered_count"]
	var width := paint_image.get_width()
	var height := paint_image.get_height()

	for i in points.size():
		if covered[i] != 0:
			continue
		var x := int(points[i].x)
		var y := int(points[i].y)
		if x < 0 or y < 0 or x >= width or y >= height:
			continue
		if paint_image.get_pixel(x, y).a8 >= COVERED_ALPHA:
			covered[i] = 1
			count += 1

	record["covered"] = covered
	record["covered_count"] = count
	_regions[region_id] = record
	_settle_completion(region_id, record)
	return region_coverage(region_id)


## Re-samples EVERY region against one image. Used when paint arrives outside the
## stroke lifecycle (page reload with saved paint, dev tooling, tests).
func update_all(paint_image: Image) -> void:
	for region_id in _order:
		update_region(region_id, paint_image)


func _settle_completion(region_id: int, record: Dictionary) -> void:
	if not bool(record["done"]) and region_coverage(region_id) >= _threshold:
		record["done"] = true
		_regions[region_id] = record
		region_completed.emit(region_id)
	if not _page_done and is_page_complete():
		_page_done = true
		page_completed.emit()


# ==================================================================== queries ==

## 0.0 .. 1.0 for a tracked region; 0.0 for an unknown one.
func region_coverage(region_id: int) -> float:
	if not _regions.has(region_id):
		return 0.0
	var record: Dictionary = _regions[region_id]
	var points: PackedVector2Array = record["points"]
	if points.is_empty():
		return 0.0
	return float(int(record["covered_count"])) / float(points.size())


func is_region_done(region_id: int) -> bool:
	if not _regions.has(region_id):
		return false
	return bool((_regions[region_id] as Dictionary)["done"])


## Progress over the whole page: the MEAN of the per-region coverages, so every
## region carries equal weight. A page is not "94% done" because the background
## happens to be most of its pixels -- the player still has seven shapes to fill.
func page_coverage() -> float:
	if _order.is_empty():
		return 0.0
	var total := 0.0
	for region_id in _order:
		total += region_coverage(region_id)
	return total / float(_order.size())


## True once every tracked region is done. False for a page with no regions --
## an empty tracker must never report a finished page.
func is_page_complete() -> bool:
	if _order.is_empty():
		return false
	for region_id in _order:
		if not bool((_regions[region_id] as Dictionary)["done"]):
			return false
	return true


func region_ids() -> PackedInt32Array:
	return _order.duplicate()


func region_count() -> int:
	return _order.size()


func done_region_count() -> int:
	var done := 0
	for region_id in _order:
		if bool((_regions[region_id] as Dictionary)["done"]):
			done += 1
	return done


func sample_count(region_id: int) -> int:
	if not _regions.has(region_id):
		return 0
	return ((_regions[region_id] as Dictionary)["points"] as PackedVector2Array).size()


## The precomputed grid for a region. Copy -- callers may not mutate it.
func get_sample_points(region_id: int) -> PackedVector2Array:
	if not _regions.has(region_id):
		return PackedVector2Array()
	return ((_regions[region_id] as Dictionary)["points"] as PackedVector2Array).duplicate()


func total_sample_count() -> int:
	var total := 0
	for region_id in _order:
		total += sample_count(region_id)
	return total


## Drops every grid. Call before building a new page's grids.
func clear() -> void:
	_regions.clear()
	_order = PackedInt32Array()
	_page_done = false

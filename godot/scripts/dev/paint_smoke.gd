extends Control
## Automated GPU verification for Milestone 2 -- no user input required.
##
## Run WINDOWED (a SubViewport renders nothing under --headless, which uses the
## dummy rasteriser):
##
##   <godot_exe> --path <project> res://scenes/dev/paint_smoke.tscn
##
## Add `-- --stay` to skip the auto-quit and poke at the page by hand (F1 toggles
## the region debug overlay).
##
## Every check drives the SAME methods the touch path drives
## (begin_stroke/continue_stroke/end_stroke), then reads the paint SubViewport
## back and asserts against the ID map. Exit code is 0 only if every check passes.

const BASE_IMAGE := "res://assets/books/test_book/page_01.png"
const ID_MAP := "res://assets/books/test_book/page_01_idmap.png"
const REGIONS_JSON := "res://assets/books/test_book/page_01_regions.json"

## Alpha byte at/above which a pixel counts as "solidly painted".
const SOLID_ALPHA := 200
## Test brush diameter in page pixels.
const BRUSH_DIAMETER := 56.0

@onready var _page_view: PageView = $PageView

var _id_rgba: Image
var _page_width := 0
var _page_height := 0
var _failures := 0
var _checks := 0
var _locked_events: Array[int] = []
var _ended_events: Array[int] = []


func _ready() -> void:
	_page_view.region_locked.connect(func(id: int) -> void: _locked_events.append(id))
	_page_view.stroke_ended.connect(func(id: int) -> void: _ended_events.append(id))
	await get_tree().process_frame
	_run()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		var shown := _page_view.toggle_debug_overlay()
		print("[dev] debug overlay: %s" % ("on" if shown else "off"))
		get_viewport().set_input_as_handled()


func _run() -> void:
	print("=== M2 paint smoke test ===")
	if not _page_view.load_page(BASE_IMAGE, ID_MAP, REGIONS_JSON):
		print("FAIL - load_page(%s) returned false" % BASE_IMAGE)
		_finish(1)
		return

	_page_view.brush_size = BRUSH_DIAMETER
	_page_view.brush_color = Color(0.9, 0.2, 0.15, 1.0)

	var page_size := _page_view.get_page_size()
	_page_width = page_size.x
	_page_height = page_size.y
	_id_rgba = _page_view.get_id_map_image().duplicate()
	_id_rgba.convert(Image.FORMAT_RGBA8)
	print("page loaded: %dx%d, regions: %s" % [_page_width, _page_height, _page_view.get_region_ids()])

	await _check_cross_region_clip()
	await _check_line_press_paints_nothing()
	await _check_fast_drag_is_gap_free()
	await _check_nested_region()
	_check_signals()
	_check_debug_overlay()
	await _check_composited_layer_stack()
	await _check_painting_disabled()
	await _check_stroke_replay()

	print("=== %d/%d checks passed ===" % [_checks - _failures, _checks])
	if "--stay" in OS.get_cmdline_user_args():
		print("[dev] --stay given; not quitting. F1 toggles the debug overlay.")
		return
	_finish(0 if _failures == 0 else 1)


func _finish(code: int) -> void:
	print("exit code: %d" % code)
	get_tree().quit(code)


# ==================================================================== checks ==

## (a) paint lands inside the locked region along the stroke, and
## (b) nothing lands anywhere else, for a stroke that deliberately leaves the
##     region (big circle 4 -> background 1).
func _check_cross_region_clip() -> void:
	print("\n-- check 1: stroke crossing region 4 -> region 1 --")
	_expect(_page_view.get_region_id_at(Vector2(700.5, 250.5)) == 4,
		"precondition: (700,250) is in region 4")
	_expect(_page_view.get_region_id_at(Vector2(1010.5, 250.5)) == 1,
		"precondition: (1010,250) is in region 1 (stroke really leaves the region)")

	await _clear()
	_page_view.begin_stroke(Vector2(700.5, 250.5))
	for x in range(720, 1020, 20):
		_page_view.continue_stroke(Vector2(x + 0.5, 250.5))
	_page_view.end_stroke()
	var paint := await _read_paint()

	var counts := _count_painted_by_region(paint)
	var inside := int(counts.get(4, 0))
	_expect(inside > 2000, "(a) region 4 has paint (%d px)" % inside)

	var missing := 0
	for x in range(700, 910, 10):
		if paint.get_pixel(x, 250).a8 < SOLID_ALPHA:
			missing += 1
	_expect(missing == 0, "(a) stroke is solid along its path inside region 4 (%d/21 samples empty)" % missing)

	var leaks := _describe_leaks(counts, 4)
	_expect(leaks == "", "(b) zero painted pixels outside region 4%s" % ("" if leaks == "" else " -- " + leaks))


## (c) a press that starts on a line pixel starts no stroke and paints nothing.
func _check_line_press_paints_nothing() -> void:
	print("\n-- check 2: press on a line pixel --")
	var line_position := _find_line_pixel()
	_expect(line_position.x >= 0.0, "found a line (#000000) pixel to press on: %s" % line_position)
	if line_position.x < 0.0:
		return

	await _clear()
	var started := _page_view.begin_stroke(line_position)
	_page_view.continue_stroke(line_position + Vector2(-60.0, 0.0))
	_page_view.continue_stroke(line_position + Vector2(-120.0, 0.0))
	_page_view.end_stroke()
	var paint := await _read_paint()

	_expect(not started, "(c) begin_stroke() on a line pixel returned false")
	var counts := _count_painted_by_region(paint)
	_expect(counts.is_empty(), "(c) nothing was painted at all (%s)" % counts)


## (d) a single huge drag event still stamps a gap-free stroke.
func _check_fast_drag_is_gap_free() -> void:
	print("\n-- check 3: fast (single-event) drag --")
	await _clear()
	_page_view.begin_stroke(Vector2(660.5, 250.5))
	# One event, 230 px of travel -- ~33x the 7 px stamp spacing.
	_page_view.continue_stroke(Vector2(890.5, 250.5))
	_page_view.end_stroke()
	var paint := await _read_paint()

	var gaps: Array[int] = []
	for x in range(661, 891):
		if paint.get_pixel(x, 250).a8 < SOLID_ALPHA:
			gaps.append(x)
	_expect(gaps.is_empty(), "(d) all 230 path samples painted (gaps at x=%s)" % [gaps.slice(0, 12)])

	var counts := _count_painted_by_region(paint)
	var leaks := _describe_leaks(counts, 4)
	_expect(leaks == "", "(d) fast drag leaked nothing outside region 4%s" % ("" if leaks == "" else " -- " + leaks))


## The nested circle (5) inside the square (3): the square must stay clean.
func _check_nested_region() -> void:
	print("\n-- check 4: nested circle 5 inside square 3 --")
	_expect(_page_view.get_region_id_at(Vector2(264.5, 264.5)) == 5,
		"precondition: (264,264) is in region 5")
	_expect(_page_view.get_region_id_at(Vector2(264.5, 100.5)) == 3,
		"precondition: (264,100) is in region 3 (stroke really crosses into it)")

	await _clear()
	_page_view.begin_stroke(Vector2(264.5, 264.5))
	for y in range(250, 90, -20):
		_page_view.continue_stroke(Vector2(264.5, y + 0.5))
	_page_view.end_stroke()
	var paint := await _read_paint()

	var counts := _count_painted_by_region(paint)
	_expect(int(counts.get(5, 0)) > 2000, "region 5 has paint (%d px)" % int(counts.get(5, 0)))
	_expect(int(counts.get(3, 0)) == 0, "surrounding square (region 3) stayed clean (%d px)" % int(counts.get(3, 0)))
	var leaks := _describe_leaks(counts, 5)
	_expect(leaks == "", "zero painted pixels outside region 5%s" % ("" if leaks == "" else " -- " + leaks))


func _check_signals() -> void:
	print("\n-- check 5: signals --")
	var expected: Array[int] = [4, 4, 5]
	_expect(_locked_events == expected,
		"region_locked fired once per successful press with the locked id (got %s)" % [_locked_events])
	_expect(_ended_events == expected,
		"stroke_ended fired once per stroke with the locked id (got %s)" % [_ended_events])


## The JSON-driven region overlay: off by default, one Polygon2D per region,
## drawn largest-first so nested regions land on top of their parent's hole.
func _check_debug_overlay() -> void:
	print("\n-- check 6: debug overlay --")
	var overlay := _page_view.get_node("PageRoot/DebugOverlay") as Node2D
	_expect(not _page_view.is_debug_overlay_visible(), "overlay is hidden by default")
	var region_count := _page_view.get_region_ids().size()
	_expect(overlay.get_child_count() == region_count,
		"one Polygon2D per region (%d children / %d regions)" % [overlay.get_child_count(), region_count])
	var descending := true
	var previous := 1 << 62
	for child in overlay.get_children():
		var area := int(_page_view.get_region_data(int(String(child.name).trim_prefix("Region")))["area_px"])
		descending = descending and area <= previous
		previous = area
	_expect(descending, "overlay polygons are ordered largest area first (hole handling)")
	_expect(_page_view.toggle_debug_overlay(), "toggle_debug_overlay() turns it on")
	_expect(not _page_view.toggle_debug_overlay(), "toggle_debug_overlay() turns it off again")


## The whole layer stack as the player sees it: paper behind, paint in the
## middle, line art on top (and therefore still visible over fresh paint).
func _check_composited_layer_stack() -> void:
	print("\n-- check 7: composited layer stack --")
	await _clear()
	_page_view.begin_stroke(Vector2(770.5, 250.5))
	_page_view.continue_stroke(Vector2(770.5, 340.5))
	_page_view.end_stroke()
	await _settle()
	var screen := get_viewport().get_texture().get_image()

	var painted := _screen_sample(screen, Vector2(770.5, 300.5))
	_expect(painted.r > painted.g + 0.2 and painted.r > painted.b + 0.2,
		"painted pixel shows the brush colour on screen (%s)" % painted)
	var paper := _screen_sample(screen, Vector2(500.5, 500.5))
	_expect(paper.r > 0.85 and paper.g > 0.85 and paper.b > 0.85,
		"unpainted background shows the paper colour (%s)" % paper)
	var darkest := _screen_darkest(screen, Vector2(936.5, 250.5), 3)
	_expect(darkest < 0.45,
		"line art still renders on top (darkest luminance near a line pixel: %.3f)" % darkest)


## BL-10's coloring lock, at the level the component owns it: `painting_enabled`
## off means a press starts NO stroke and reports it instead. Everything else --
## the paint already down, the view, the region data -- is untouched.
func _check_painting_disabled() -> void:
	print("\n-- check 8: painting_enabled (BL-10 coloring lock) --")
	var blocked: Array[Vector2] = []
	var handler := func(position: Vector2) -> void: blocked.append(position)
	_page_view.paint_blocked.connect(handler)

	await _clear()
	var point := Vector2(700.5, 250.5)
	_page_view.painting_enabled = false
	var started := _page_view.begin_stroke(point)
	# The drag and release must be as harmless as the press: a lock that only
	# stopped the FIRST event would still paint on any pointer that was already
	# down when it went on.
	_page_view.continue_stroke(point + Vector2(120.0, 0.0))
	_page_view.end_stroke()
	var paint := await _read_paint()

	_expect(not started, "begin_stroke() is refused while painting is disabled")
	_expect(not _page_view.is_stroke_active(), "no stroke is left active")
	_expect(blocked.size() == 1 and blocked[0] == point,
		"paint_blocked fired once with the press position (%s)" % [blocked])
	_expect(_count_painted_by_region(paint).is_empty(),
		"nothing was painted at all (%s)" % _count_painted_by_region(paint))

	# --- and back on again ----------------------------------------------------
	_page_view.painting_enabled = true
	_expect(_page_view.begin_stroke(point), "re-enabling painting lets the next press through")
	_page_view.continue_stroke(point + Vector2(120.0, 0.0))
	# Turning the lock on MID-STROKE cancels what is down, so the flag is safe to
	# flip at any moment.
	_page_view.painting_enabled = false
	_expect(not _page_view.is_stroke_active(), "disabling mid-stroke cancels the stroke in progress")
	var during := await _read_paint()
	_expect(int(_count_painted_by_region(during).get(4, 0)) > 0,
		"...and the paint it had already laid down STAYS (%d px)"
		% int(_count_painted_by_region(during).get(4, 0)))
	_expect(blocked.size() == 1, "no extra paint_blocked came from the successful press (%d)"
		% blocked.size())

	_page_view.paint_blocked.disconnect(handler)
	_page_view.painting_enabled = true
	await _clear()


## BL-17: stroke recipes, the rebuild, and the one property undo/redo lives or dies
## by -- that replaying a stroke reproduces it EXACTLY. Everything here is compared
## byte-for-byte against the layer the live strokes produced, not "roughly the same
## number of pixels": an undo that shifted a dab by a pixel would look like a bug
## the moment a child undid twice.
func _check_stroke_replay() -> void:
	print("\n-- check 9: stroke recipes & replay (BL-17) --")
	await _clear()

	# --- stroke one, recorded ------------------------------------------------
	_page_view.brush_color = Color(0.15, 0.35, 0.85, 1.0)
	_page_view.begin_stroke(Vector2(700.5, 250.5))
	for x in range(720, 900, 20):
		_page_view.continue_stroke(Vector2(x + 0.5, 250.5))
	_page_view.end_stroke()
	var recipe_a := _page_view.take_last_stroke_recipe()
	_expect(not recipe_a.is_empty(), "a finished stroke leaves a recipe")
	_expect(int(recipe_a.get("region_id", -1)) == 4,
		"...naming the region it locked (%s)" % recipe_a.get("region_id"))
	_expect(recipe_a.get("color") == Color(0.15, 0.35, 0.85, 1.0)
		and is_equal_approx(float(recipe_a.get("diameter", 0.0)), BRUSH_DIAMETER),
		"...with the brush it used (#%s at %.0f px)"
		% [(recipe_a.get("color") as Color).to_html(false), recipe_a.get("diameter")])
	var points_a: PackedVector2Array = recipe_a.get("points", PackedVector2Array())
	_expect(points_a.size() > 20,
		"...and every dab centre it stamped (%d points)" % points_a.size())
	_expect(_page_view.take_last_stroke_recipe().is_empty(),
		"taking the recipe consumes it -- one stroke cannot be recorded twice")
	var after_a := (await _read_paint()).get_data()

	# --- stroke two, on top --------------------------------------------------
	_page_view.brush_color = Color(0.95, 0.75, 0.10, 1.0)
	_page_view.begin_stroke(Vector2(264.5, 264.5))
	_page_view.continue_stroke(Vector2(264.5, 200.5))
	_page_view.end_stroke()
	var recipe_b := _page_view.take_last_stroke_recipe()
	var after_b := (await _read_paint()).get_data()
	_expect(after_a != after_b, "precondition: the second stroke really changed the layer")

	# --- undo: rebuild the page without it -----------------------------------
	await _page_view.rebuild_paint(null, [recipe_a])
	var rebuilt := (await _read_paint()).get_data()
	_expect(rebuilt == after_a,
		"rebuilding from the first recipe alone reproduces the layer BYTE FOR BYTE"
		+ " (%d bytes)" % rebuilt.size())

	# --- redo: stamp the popped recipe back on top ---------------------------
	_page_view.stamp_recipe(recipe_b)
	var redone := (await _read_paint()).get_data()
	_expect(redone == after_b, "re-stamping the second recipe restores it exactly -- undo/redo is pixel-stable")

	# --- the brush moved on, the recipe did not ------------------------------
	# A replay must not be disturbed by whatever the palette is holding NOW.
	_page_view.brush_color = Color(0.1, 0.9, 0.2, 1.0)
	_page_view.brush_size = 8.0
	await _page_view.rebuild_paint(null, [recipe_a, recipe_b])
	var replayed := (await _read_paint()).get_data()
	_expect(replayed == after_b,
		"a replay uses the recipe's own brush, not the live one (colour and size changed under it)")
	_page_view.brush_size = BRUSH_DIAMETER

	# --- a baseline image goes back in bit-exact -----------------------------
	# This is the M5 restore path, which the rebuild leans on for "the page as it
	# was when it opened". Premultiplied over a freshly cleared target or it drifts.
	var baseline := await _read_paint()
	await _page_view.rebuild_paint(baseline, [])
	var restored := (await _read_paint()).get_data()
	_expect(restored == after_b, "a rebuild over a BASELINE image alone is bit-exact too")

	# --- the clip travels with the recipe ------------------------------------
	var counts := _count_painted_by_region(await _read_paint())
	_expect(int(counts.get(4, 0)) > 0 and int(counts.get(5, 0)) > 0,
		"both replayed strokes landed in their own regions (%s)" % counts)
	_expect(int(counts.get(3, 0)) == 0 and int(counts.get(1, 0)) == 0,
		"...and a replayed stroke is clipped by the shader exactly like a live one"
		+ " (%d px in region 3, %d in region 1)" % [int(counts.get(3, 0)), int(counts.get(1, 0))])

	_expect(not _page_view.is_replaying(), "the rebuild reported itself finished")
	await _clear()
	_expect(_page_view.take_last_stroke_recipe().is_empty(),
		"clearing the page drops the pending recipe with the pixels")


func _screen_sample(screen: Image, page_position: Vector2) -> Color:
	var p := _page_view.to_viewport_position(page_position)
	return screen.get_pixel(clampi(int(p.x), 0, screen.get_width() - 1), clampi(int(p.y), 0, screen.get_height() - 1))


func _screen_darkest(screen: Image, page_position: Vector2, radius: int) -> float:
	var p := _page_view.to_viewport_position(page_position)
	var darkest := 1.0
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var x := clampi(int(p.x) + dx, 0, screen.get_width() - 1)
			var y := clampi(int(p.y) + dy, 0, screen.get_height() - 1)
			darkest = minf(darkest, screen.get_pixel(x, y).get_luminance())
	return darkest


# =================================================================== helpers ==

func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("%s - %s" % ["PASS" if condition else "FAIL", description])


func _clear() -> void:
	_page_view.clear_paint()
	await _settle()


func _read_paint() -> Image:
	await _settle()
	var image := _page_view.get_paint_image()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image


## Waits until every queued stamp has been rendered into the SubViewport.
func _settle() -> void:
	for i in 8:
		await get_tree().process_frame
		if not _page_view.has_pending_paint():
			break
	await get_tree().process_frame
	await RenderingServer.frame_post_draw


## region id -> number of painted pixels, over the whole page. Key 0 is line art.
func _count_painted_by_region(paint: Image) -> Dictionary:
	var paint_bytes := paint.get_data()
	var id_bytes := _id_rgba.get_data()
	var counts := {}
	var pixel_count := _page_width * _page_height
	for i in pixel_count:
		if paint_bytes[i * 4 + 3] == 0:
			continue
		var offset := i * 4
		var region_id := (id_bytes[offset] << 16) | (id_bytes[offset + 1] << 8) | id_bytes[offset + 2]
		counts[region_id] = int(counts.get(region_id, 0)) + 1
	return counts


func _describe_leaks(counts: Dictionary, locked_id: int) -> String:
	var parts: PackedStringArray = []
	var keys := counts.keys()
	keys.sort()
	for key in keys:
		if int(key) != locked_id:
			parts.append("region %d: %d px" % [int(key), int(counts[key])])
	return ", ".join(parts)


## Walks right from the big circle's centre until the ID map says "line art".
func _find_line_pixel() -> Vector2:
	for x in range(770, _page_width):
		if _page_view.get_region_id_at(Vector2(x + 0.5, 250.5)) == 0:
			return Vector2(x + 0.5, 250.5)
	return Vector2(-1.0, -1.0)

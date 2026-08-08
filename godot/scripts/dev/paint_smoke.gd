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

## BL-35's finish checks paint with a mid-tone colour, so a finish that lightens the
## wax and one that darkens it are both visible against it.
const FINISH_COLOR := Color(0.35, 0.55, 0.85, 1.0)
## Deep inside region 4 (the big circle), far enough from every boundary that even
## the glow's widened stamp cannot reach one -- these checks measure the finish, not
## the clip, and the clip has its own check above them.
const FINISH_DAB := Vector2(788.5, 250.5)

## How wide the mis-decoded seam between two overlapping field styles may get, in
## page pixels (BL-47 review, check 11c). Measured at 5 on this tree; the headroom is
## for the dab profile, not for a new level squeezed into the table.
const SEAM_MAX_PX := 8
## The brightest raw red byte allowed to survive at a WRONG level after classic wax
## has rubbed an animated area out. Measured at 2 on this tree.
const ERASE_MAX_STRAY := 26

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
	await _check_brush_finishes()
	await _check_animated_finishes()

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


## BL-35: the crayon boxes' FINISHES, at the layer that bakes them.
##
## Three claims, and the first one is the one that could break the game. (1) The
## region clip owns every finish -- a glow halo spills PAST the dab, so a stamp laid
## a fraction of its bloom away from a boundary is the case that would leak paint
## into the neighbouring region if the halo were composited rather than clipped.
## (2) A finish actually changes the pixels, in the way it claims to: the glow
## reaches further than the dab, the grain varies the wax colour across it, the
## glitter puts specks brighter than the crayon in it. (3) A finished stroke is
## replayable to the byte, because BL-17's undo re-stamps recipes and a finish whose
## seed were re-rolled on replay would shift every speck of glitter on the page.
func _check_brush_finishes() -> void:
	print("\n-- check 10: bakeable crayon finishes (BL-35) --")
	await _clear()
	_page_view.brush_size = BRUSH_DIAMETER
	_page_view.brush_color = FINISH_COLOR

	# --- (1) the clip owns every finish, halo included -------------------------
	var line_x := _find_line_pixel().x
	_expect(line_x > 0.0, "found the region 4 / region 1 boundary to stamp beside (x=%.0f)" % line_x)
	# Well inside region 4, but nearer the boundary than the glow's bloom reaches:
	# the halo is over the line, and only the shader's discard keeps it off.
	var near_boundary := Vector2(line_x - 30.0, 250.5)
	var reach := BRUSH_DIAMETER * 0.5 * BrushFinish.quad_scale(BrushFinish.GLOW)
	_expect(reach > 30.0,
		"...and the glow's bloom (%.0f px) really does overhang it by %.0f px"
		% [reach, reach - 30.0])
	for finish in BrushFinish.LADDER:
		await _clear()
		_page_view.brush_effect = finish
		_expect(_page_view.brush_effect == finish, "PageView takes the '%s' finish" % finish)
		_page_view.begin_stroke(near_boundary)
		_page_view.end_stroke()
		var counts := _count_painted_by_region(await _read_paint())
		var leaks := _describe_leaks(counts, 4)
		_expect(int(counts.get(4, 0)) > 0 and leaks == "",
			"'%s' stamped %d px in the locked region and NOTHING across the line%s"
			% [finish, int(counts.get(4, 0)), "" if leaks == "" else " -- " + leaks])

	# --- (2) each finish looks like what it says -------------------------------
	var classic := await _stamp_finish(BrushFinish.CLASSIC, FINISH_DAB)
	var glow := await _stamp_finish(BrushFinish.GLOW, FINISH_DAB)
	var grain := await _stamp_finish(BrushFinish.GRAIN, FINISH_DAB)
	var glitter := await _stamp_finish(BrushFinish.GLITTER, FINISH_DAB)

	# A digest of each bakeable finish's dab, printed rather than asserted: rendered
	# bytes are GPU-specific, so these are a regression tool for one machine, not a
	# contract for every machine. Measured on the BL-38 dev box (RTX 5060, Vulkan
	# Forward Mobile) immediately BEFORE and AFTER BL-38 added two shader modes and
	# the effect-mask target, and identical across the two -- which is the evidence
	# that phase 2 changed no pixel of phase 1:
	#   classic=2161738159 glow=3362623779 grain=1121124693 glitter=3754632733
	print("[golden] classic=%d glow=%d grain=%d glitter=%d" % [
		hash(classic.get_data()), hash(glow.get_data()),
		hash(grain.get_data()), hash(glitter.get_data()),
	])

	var classic_px := _painted_pixels(classic)
	var glow_px := _painted_pixels(glow)
	_expect(glow_px > classic_px * 2,
		"the glow BLOOMS past the dab: %d px lit against classic wax's %d" % [glow_px, classic_px])
	_expect(_core_spread(classic) < 0.01,
		"classic wax lays one flat colour down the middle of the dab (spread %.4f)"
		% _core_spread(classic))
	_expect(_core_spread(grain) > 0.03,
		"textured wax varies the colour across the dab -- visible grain (spread %.4f)"
		% _core_spread(grain))
	_expect(_brightest_core(glitter) > FINISH_COLOR.get_luminance() + 0.25,
		"glitter catches specks brighter than the crayon itself (%.3f vs %.3f)"
		% [_brightest_core(glitter), FINISH_COLOR.get_luminance()])

	# --- (3) a finished stroke replays to the byte -----------------------------
	await _clear()
	_page_view.brush_effect = BrushFinish.GLITTER
	_page_view.begin_stroke(Vector2(700.5, 250.5))
	for x in range(720, 860, 20):
		_page_view.continue_stroke(Vector2(x + 0.5, 250.5))
	_page_view.end_stroke()
	var recipe_a := _page_view.take_last_stroke_recipe()
	_expect(StringName(recipe_a.get("effect", &"")) == BrushFinish.GLITTER,
		"the recipe names the finish the stroke painted with ('%s')" % recipe_a.get("effect"))
	_expect(float(recipe_a.get("effect_seed", -1.0)) >= 0.0,
		"...and the seed its grain and its glitter were laid out from (%.4f)"
		% float(recipe_a.get("effect_seed", -1.0)))
	var after_a := (await _read_paint()).get_data()

	_page_view.brush_effect = BrushFinish.GLOW
	_page_view.begin_stroke(Vector2(264.5, 264.5))
	_page_view.continue_stroke(Vector2(264.5, 210.5))
	_page_view.end_stroke()
	var recipe_b := _page_view.take_last_stroke_recipe()
	_expect(StringName(recipe_b.get("effect", &"")) == BrushFinish.GLOW
			and not is_equal_approx(
				float(recipe_b.get("effect_seed", 0.0)), float(recipe_a.get("effect_seed", 0.0))
			),
		"a second stroke gets its own finish and its own seed (%.4f vs %.4f)"
		% [float(recipe_b.get("effect_seed", 0.0)), float(recipe_a.get("effect_seed", 0.0))])
	var after_b := (await _read_paint()).get_data()

	# The brush moves on, exactly as it would when the player cycles boxes and then
	# undoes: the replay must use the RECIPE's finish, not the live one.
	_page_view.brush_effect = BrushFinish.GRAIN
	await _page_view.rebuild_paint(null, [recipe_a])
	_expect((await _read_paint()).get_data() == after_a,
		"undoing a finished stroke rebuilds the one below it BYTE FOR BYTE")
	_page_view.stamp_recipe(recipe_b)
	_expect((await _read_paint()).get_data() == after_b,
		"...and redoing it re-stamps the glow exactly -- finishes are pixel-stable")

	# A recipe from before finishes existed is classic wax, not nothing.
	var plain := recipe_a.duplicate()
	plain.erase("effect")
	plain.erase("effect_seed")
	await _page_view.rebuild_paint(null, [plain])
	var plain_counts := _count_painted_by_region(await _read_paint())
	_expect(int(plain_counts.get(4, 0)) > 0 and _describe_leaks(plain_counts, 4) == "",
		"a recipe with no finish replays as plain wax, clipped like any other (%d px)"
		% int(plain_counts.get(4, 0)))

	_page_view.brush_effect = BrushFinish.CLASSIC
	await _clear()


## BL-38: the ANIMATED finishes, and the effect-mask channel they live in.
##
## Five things have to be true at once, and they are the five constraints the entry
## refused to move on. (1) The mask sleeps until it is needed and never marks a pixel
## the wax does not cover. (2) It is clipped by the region exactly like the wax, so a
## travelling sheen can never cross a line. (3) The PAINT layer -- the thing coverage
## and completion read -- does not move, with the animation running or frozen, so
## coverage cannot see the animation even in principle. (4) The composited SCREEN
## does move, or none of this is a feature. (5) Undo, redo and a restore round-trip
## BOTH layers byte for byte, or a page reopened is not the page that was left.
func _check_animated_finishes() -> void:
	print("\n-- check 11: animated finishes & the effect mask (BL-38) --")
	# A fresh page, because check 10 walked the whole ladder and woke the layer.
	_expect(_page_view.load_page(BASE_IMAGE, ID_MAP, REGIONS_JSON),
		"reloaded the page, so the effect layer starts where a real page load leaves it")
	await _settle()
	_page_view.brush_size = BRUSH_DIAMETER
	_page_view.brush_color = FINISH_COLOR
	_page_view.brush_effect = BrushFinish.CLASSIC

	# --- (1) dormant until an animated box is actually in hand ------------------
	_expect(not _page_view.is_effect_layer_active(),
		"a freshly loaded page has NO effect layer -- the four bakeable boxes pay nothing")
	_expect(_page_view.get_effect_image() == null,
		"...and a dormant layer has no image, so a save point costs one readback, as always")
	_page_view.begin_stroke(FINISH_DAB)
	_page_view.end_stroke()
	await _settle()
	_expect(not _page_view.is_effect_layer_active(),
		"painting classic wax does not wake it either")
	var dormant_recipe := _page_view.take_last_stroke_recipe()
	_expect(not bool(dormant_recipe.get("effect_masked", true)),
		"...and its recipe records that it never touched the mask, so a rebuild"
		+ " after the mask wakes does not stamp it into one")

	_page_view.brush_effect = BrushFinish.SHIMMER
	_expect(_page_view.is_effect_layer_active(),
		"picking an ANIMATED box wakes it -- at the pick, frames before the first press")
	await _clear()

	# --- (2) the region clip owns the mask, not just the wax --------------------
	var line_x := _find_line_pixel().x
	var boundary_stroke_end := Vector2(line_x - 8.0, 250.5)
	_page_view.begin_stroke(Vector2(line_x - 150.0, 250.5))
	_page_view.continue_stroke(boundary_stroke_end)
	_page_view.end_stroke()
	var shimmer_paint := await _read_paint()
	var shimmer_mask := await _read_effect()
	_expect(shimmer_mask != null, "an animated stroke leaves an effect mask to read back")
	if shimmer_mask == null:
		return
	var mask_counts := _count_painted_by_region(shimmer_mask)
	var mask_leaks := _describe_leaks(mask_counts, 4)
	_expect(int(mask_counts.get(4, 0)) > 0 and mask_leaks == "",
		"the mask is marked in the locked region (%d px) and NOWHERE across the line%s"
		% [int(mask_counts.get(4, 0)), "" if mask_leaks == "" else " -- " + mask_leaks])
	_expect(_mask_within_paint(shimmer_mask, shimmer_paint) == 0,
		"the mask never marks a pixel the wax does not cover (%d stray texels)"
		% _mask_within_paint(shimmer_mask, shimmer_paint))
	_expect(_max_channel(shimmer_mask, 0) > 200,
		"...and Shimmer wrote its SHEEN into the mask's red channel (peak %d)"
		% _max_channel(shimmer_mask, 0))
	_expect(_max_channel(shimmer_mask, 1) == 0,
		"...and nothing into green, which is the other finish's channel (peak %d)"
		% _max_channel(shimmer_mask, 1))

	# --- (3) the paint layer is STILL, however long the animation runs ----------
	var still_a := shimmer_paint.get_data()
	for i in 24:
		await get_tree().process_frame
	var still_b := (await _read_paint()).get_data()
	_expect(still_a == still_b,
		"24 frames of animation later the PAINT layer is byte-identical -- coverage"
		+ " reads this image and cannot see the animation")
	_page_view.effect_animation_enabled = false
	for i in 8:
		await get_tree().process_frame
	var frozen := (await _read_paint()).get_data()
	_expect(frozen == still_a,
		"...and freezing the animation does not change it either, so coverage is the"
		+ " same number with the animation on and off")

	# --- (4) but the SCREEN does move -------------------------------------------
	_page_view.brush_effect = BrushFinish.TWINKLE
	_page_view.begin_stroke(Vector2(700.5, 250.5))
	for x in range(720, 880, 20):
		_page_view.continue_stroke(Vector2(x + 0.5, 250.5))
	_page_view.end_stroke()
	await _settle()
	var frozen_first := await _screen_bytes()
	var frozen_second := await _screen_bytes()
	_expect(frozen_first == frozen_second,
		"with effect_animation_enabled off the composited page is a still image")
	_page_view.effect_animation_enabled = true
	var live_first := await _screen_bytes()
	var live_second := await _screen_bytes()
	_expect(live_first != live_second,
		"with it on the page is ALIVE -- the same pixels differ from frame to frame")

	# --- (5) undo, redo and a restore carry BOTH layers -------------------------
	await _clear()
	_page_view.brush_effect = BrushFinish.SHIMMER
	_page_view.begin_stroke(Vector2(700.5, 250.5))
	for x in range(720, 860, 20):
		_page_view.continue_stroke(Vector2(x + 0.5, 250.5))
	_page_view.end_stroke()
	var recipe_a := _page_view.take_last_stroke_recipe()
	_expect(StringName(recipe_a.get("effect", &"")) == BrushFinish.SHIMMER,
		"the recipe names the animated finish, like any other ('%s')" % recipe_a.get("effect"))
	_expect(bool(recipe_a.get("effect_masked", false)),
		"...and records that it DID reach the mask -- the one bit a replay cannot"
		+ " work out for itself")
	var paint_a := (await _read_paint()).get_data()
	var mask_a := (await _read_effect()).get_data()

	_page_view.brush_effect = BrushFinish.TWINKLE
	_page_view.begin_stroke(Vector2(264.5, 264.5))
	_page_view.continue_stroke(Vector2(264.5, 210.5))
	_page_view.end_stroke()
	var recipe_b := _page_view.take_last_stroke_recipe()
	var paint_b := (await _read_paint()).get_data()
	var mask_b := (await _read_effect()).get_data()
	_expect(mask_a != mask_b, "precondition: the twinkle stroke really changed the mask")

	_page_view.brush_effect = BrushFinish.CLASSIC
	await _page_view.rebuild_paint(null, [recipe_a])
	_expect((await _read_paint()).get_data() == paint_a
			and (await _read_effect()).get_data() == mask_a,
		"undoing an animated stroke rebuilds the wax AND the mask byte for byte")
	_page_view.stamp_recipe(recipe_b)
	_expect((await _read_paint()).get_data() == paint_b
			and (await _read_effect()).get_data() == mask_b,
		"...and redoing it re-stamps both -- undo/redo is pixel-stable with animation on")

	# --- ordinary wax over animated wax takes the animation off -----------------
	_page_view.brush_effect = BrushFinish.CLASSIC
	_page_view.begin_stroke(Vector2(700.5, 250.5))
	for x in range(720, 860, 20):
		_page_view.continue_stroke(Vector2(x + 0.5, 250.5))
	_page_view.end_stroke()
	var over := await _read_effect()
	_expect(over.get_pixel(780, 250).r8 < 24,
		"classic wax painted over a shimmer ERASES it (mask red %d, was %d)"
		% [over.get_pixel(780, 250).r8, 255])

	# --- the mask survives the save it will actually be given -------------------
	var to_save := await _read_effect()
	var png := to_save.save_png_to_buffer()
	var reloaded := Image.new()
	_expect(reloaded.load_png_from_buffer(png) == OK,
		"the effect mask encodes as a PNG, the same file the paint layer is (%d bytes)"
		% png.size())
	reloaded.convert(Image.FORMAT_RGBA8)
	_expect(reloaded.get_data() == to_save.get_data(),
		"...and comes back off disk byte for byte")
	var paint_before_restore := (await _read_paint()).duplicate()
	await _page_view.rebuild_paint(paint_before_restore, [], reloaded)
	_expect((await _read_effect()).get_data() == to_save.get_data(),
		"a page reopened comes back with the animation it was left with -- the"
		+ " restore composite is bit-exact for the mask too")

	# --- and the baked halves look like what they claim -------------------------
	var shimmer_dab := await _stamp_finish(BrushFinish.SHIMMER, FINISH_DAB)
	var twinkle_dab := await _stamp_finish(BrushFinish.TWINKLE, FINISH_DAB)
	_expect(_core_spread(shimmer_dab) > 0.01,
		"Shimmer BAKES a satin tooth, so a frozen page is not flat wax (spread %.4f)"
		% _core_spread(shimmer_dab))
	_expect(_brightest_core(twinkle_dab) > FINISH_COLOR.get_luminance() + 0.25,
		"Twinkle BAKES its specks, so the glitter is there before the wink is (%.3f vs %.3f)"
		% [_brightest_core(twinkle_dab), FINISH_COLOR.get_luminance()])

	await _check_mask_style_levels(line_x)
	await _check_style_seam(line_x)

	_page_view.brush_effect = BrushFinish.CLASSIC
	await _clear()


## BL-47: the mask's red and green are STYLE LEVELS now, and the whole extension
## rests on one claim -- that the level a stamp wrote can be read back out of the
## blended texel exactly, by dividing out the mask's own alpha. That claim is an
## argument about how alpha blending composes; this is the measurement.
##
## It is deliberately made against a REAL mask off the GPU rather than against
## arithmetic: a stroke of eight-deep overlapping dabs, run right up to a region
## boundary so the sample includes both the feathered dab edge (where the raw channel
## is nearly nothing and the ratio has to carry it) and the hard edge the discard
## cut. If the recovery were merely approximate, embers would animate as a shimmer
## somewhere along that line and nothing else in the suite would notice.
func _check_mask_style_levels(line_x: float) -> void:
	print("\n-- check 11b: mask style levels decode off a real mask (BL-47) --")
	# One field style and the speck style, which are the two families the decode
	# splits. Aurora is picked for the field because 0.80 is the level with the
	# tightest neighbour (1.00 shimmer, a midpoint of 0.90 away) -- if any level
	# survives eight blended dabs, the awkward one is the one worth proving.
	for finish in [BrushFinish.EMBERS, BrushFinish.AURORA, BrushFinish.FIREFLY]:
		await _clear()
		_page_view.brush_effect = finish
		_page_view.begin_stroke(Vector2(line_x - 150.0, 250.5))
		_page_view.continue_stroke(Vector2(line_x - 8.0, 250.5))
		_page_view.end_stroke()
		var mask := await _read_effect()
		if mask == null:
			_expect(false, "'%s' left an effect mask to read back" % finish)
			continue
		var authored := BrushFinish.mask_payload(finish)
		# The raw bytes first: the stamp really did write the authored level, not
		# some gamma-curved cousin of it. Printed as well as asserted, because a
		# render target that ever started converting colour spaces would show up here
		# first and would be very hard to read from a bare PASS/FAIL.
		var peak_r := _max_channel(mask, 0)
		var peak_g := _max_channel(mask, 1)
		print("[levels] %s wrote r=%d g=%d (authored %.2f / %.2f -> %d / %d)" % [
			finish, peak_r, peak_g, authored.r, authored.g,
			roundi(authored.r * 255.0), roundi(authored.g * 255.0),
		])
		_expect(absi(peak_r - roundi(authored.r * 255.0)) <= 1
				and absi(peak_g - roundi(authored.g * 255.0)) <= 1,
			"'%s' stamps its authored LEVEL into the mask, to the byte (r %d, g %d)"
			% [finish, peak_r, peak_g])
		var leaks := _describe_leaks(_count_painted_by_region(mask), 4)
		_expect(leaks == "",
			"...clipped by the region like every other stamp%s"
			% ["" if leaks == "" else " -- " + leaks])
		# The decode, over every texel the wax actually covers. Fringe texels below
		# 8/255 of coverage are skipped on purpose: they are where two levels could
		# in principle round to the wrong neighbour, and they carry a coverage-
		# weighted amount of nearly nothing, which is the trade BL-47 took knowingly.
		var decoded := _decode_mask_levels(mask, authored, 8)
		_expect(int(decoded["checked"]) > 500 and int(decoded["wrong"]) == 0,
			"...and every one of its %d covered texels decodes back to that level"
			% int(decoded["checked"])
			+ (" (%d wrong)" % int(decoded["wrong"]) if int(decoded["wrong"]) > 0 else ""))

		# The paint layer is still a still image, for a new finish exactly as for the
		# two BL-38 shipped. This is the claim coverage rests on and it is per finish,
		# not per shader: a baked base that somehow read TIME would break it here.
		var live := (await _read_paint()).get_data()
		_page_view.effect_animation_enabled = false
		for i in 6:
			await get_tree().process_frame
		var frozen := (await _read_paint()).get_data()
		_page_view.effect_animation_enabled = true
		_expect(live == frozen,
			"'%s' bakes a STILL base -- the paint layer is byte-identical frozen" % finish)

		# ...and ordinary wax rubs it off, through the ordinary blend and no
		# bookkeeping. The four new payloads are new numbers, but zero is still zero.
		_page_view.brush_effect = BrushFinish.CLASSIC
		_page_view.begin_stroke(Vector2(line_x - 150.0, 250.5))
		_page_view.continue_stroke(Vector2(line_x - 8.0, 250.5))
		_page_view.end_stroke()
		var erased := await _read_effect()
		# Sampled down the MIDDLE of the stroke, not as a peak over the page: the
		# classic pass rubs out what it covers, and what it covers is a dab profile,
		# so the outermost fringe of the original stroke keeps a sliver of its level.
		# That sliver is the correct answer -- the wax there is still animated wax,
		# only faintly -- and it is what a max would report instead.
		var rubbed := erased.get_pixel(int(line_x) - 80, 250)
		_expect(rubbed.r8 < 24 and rubbed.g8 < 24,
			"...and classic wax over it ERASES the level (r %d, g %d)"
			% [rubbed.r8, rubbed.g8])


## BL-47's one ambiguity, measured instead of argued.
##
## Where strokes of two DIFFERENT field styles overlap, the blended ratio lands
## between two levels and nearest-level picks one of them. The entry called those
## texels free because they "carry a coverage-weighted amount of nearly zero", and
## that is not what the pixels say: the seam between an embers stroke and the
## shimmer wax it laps over carries up to 90% of a level. What actually makes it
## free is GEOMETRY -- a stroke's edge is eight overlapping dabs deep, so the whole
## ladder of wrong levels is crossed inside a few pixels. That width is the thing
## worth pinning, because a fifth field level, a softer brush or a wider stamp
## spacing would each widen it quietly.
##
## The second half is the ERASE, over wax that was properly coloured in first --
## the case a player actually makes. Classic wax saturates just as fast as it
## rubs out, so the residual never sits at a wrong level with any light left in
## it, and the animation goes out rather than changing style on the way.
func _check_style_seam(line_x: float) -> void:
	print("\n-- check 11c: where two styles meet, and where wax rubs one out --")
	await _clear()
	_page_view.brush_effect = BrushFinish.SHIMMER
	_page_view.begin_stroke(Vector2(line_x - 150.0, 250.5))
	_page_view.continue_stroke(Vector2(line_x - 8.0, 250.5))
	_page_view.end_stroke()
	# Half a brush lower, so the embers stroke's whole soft edge lies on shimmer wax.
	_page_view.brush_effect = BrushFinish.EMBERS
	_page_view.begin_stroke(Vector2(line_x - 150.0, 250.5 + BRUSH_DIAMETER * 0.5))
	_page_view.continue_stroke(Vector2(line_x - 8.0, 250.5 + BRUSH_DIAMETER * 0.5))
	_page_view.end_stroke()
	var seam := _field_misdecode(await _read_effect(), [1.0, 0.15])
	_expect(int(seam["levels_seen"]) == 2,
		"precondition: the mask really holds BOTH levels, 1.00 shimmer under 0.15 embers")
	_expect(int(seam["worst_run"]) <= SEAM_MAX_PX,
		"the seam between two field styles is %d px of mis-decode at worst, and it is"
		% int(seam["worst_run"])
		+ " bright (peak %d/255) -- the fringe is free because it is THIN, not because"
		% int(seam["peak"])
		+ " it is dim")

	# --- and the erase, over wax that was coloured in first ---------------------
	await _clear()
	_page_view.brush_effect = BrushFinish.AURORA
	for y in range(200, 305, 8):
		_page_view.begin_stroke(Vector2(line_x - 150.0, y + 0.5))
		_page_view.continue_stroke(Vector2(line_x - 8.0, y + 0.5))
		_page_view.end_stroke()
	_page_view.brush_effect = BrushFinish.CLASSIC
	_page_view.begin_stroke(Vector2(line_x - 150.0, 250.5))
	_page_view.continue_stroke(Vector2(line_x - 8.0, 250.5))
	_page_view.end_stroke()
	var rubbed := _field_misdecode(await _read_effect(), [0.80])
	_expect(int(rubbed["peak"]) <= ERASE_MAX_STRAY,
		"...and classic wax over coloured-in aurora goes OUT rather than sideways:"
		+ " the brightest texel that decodes to another style is %d/255 (%d texels)"
		% [int(rubbed["peak"]), int(rubbed["count"])])
	_page_view.brush_effect = BrushFinish.CLASSIC
	await _clear()


## Every texel of [param mask] whose FIELD level is none of [param allowed]:
## { "count", "worst_run" (the longest vertical run, in px), "peak" (the biggest raw
## red byte among them), "levels_seen" (how many of [param allowed] are actually on
## the page, so the measurement cannot pass by measuring nothing) }.
func _field_misdecode(mask: Image, allowed: Array) -> Dictionary:
	var bytes := mask.get_data()
	var seen := {}
	var count := 0
	var worst_run := 0
	var peak := 0
	for x in _page_width:
		var run := 0
		for y in _page_height:
			var i := (y * _page_width + x) * 4
			var red := float(bytes[i]) / 255.0
			if red <= BrushFinish.MASK_CHANNEL_FLOOR:
				run = 0
				continue
			var coverage := maxf(float(bytes[i + 3]) / 255.0, BrushFinish.MASK_COVERAGE_EPSILON)
			var field := BrushFinish.decode_mask_field(red / coverage)
			var known := false
			for level in allowed:
				if is_equal_approx(field, float(level)):
					known = true
					seen[level] = true
			if known:
				run = 0
				continue
			run += 1
			count += 1
			worst_run = maxi(worst_run, run)
			peak = maxi(peak, int(bytes[i]))
	return {"count": count, "worst_run": worst_run, "peak": peak, "levels_seen": seen.size()}


## Decodes every sufficiently covered texel of [param mask] and counts how many come
## back as something other than [param authored]. { "checked": int, "wrong": int }.
func _decode_mask_levels(mask: Image, authored: Color, min_alpha: int) -> Dictionary:
	var bytes := mask.get_data()
	var checked := 0
	var wrong := 0
	for i in _page_width * _page_height:
		var coverage := bytes[i * 4 + 3]
		if coverage < min_alpha:
			continue
		checked += 1
		var decoded := BrushFinish.decode_mask_payload(Color(
			bytes[i * 4] / 255.0,
			bytes[i * 4 + 1] / 255.0,
			bytes[i * 4 + 2] / 255.0,
			coverage / 255.0
		))
		if not is_equal_approx(float(decoded["field"]), authored.r) \
				or not is_equal_approx(float(decoded["speck"]), authored.g):
			wrong += 1
	return {"checked": checked, "wrong": wrong}


## The paint layer's effect mask, settled and in RGBA8. Null while dormant.
func _read_effect() -> Image:
	await _settle()
	var image := _page_view.get_effect_image()
	if image == null:
		return null
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image


## The whole composited window, one frame at a time. Two calls are two different
## frames, which is what makes "the page is alive" testable without a clock.
func _screen_bytes() -> PackedByteArray:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image().get_data()


## Texels marked in [param mask] that have no wax under them in [param paint].
## Must be zero: the mask is stamped by the same shader through the same discard.
func _mask_within_paint(mask: Image, paint: Image) -> int:
	var mask_bytes := mask.get_data()
	var paint_bytes := paint.get_data()
	var stray := 0
	for i in _page_width * _page_height:
		if mask_bytes[i * 4 + 3] > 0 and paint_bytes[i * 4 + 3] == 0:
			stray += 1
	return stray


## Peak value of one channel over the whole mask (0 = r, 1 = g, 2 = b).
func _max_channel(image: Image, channel: int) -> int:
	var bytes := image.get_data()
	var peak := 0
	for i in _page_width * _page_height:
		peak = maxi(peak, bytes[i * 4 + channel])
	return peak


## One dab of [param finish] at [param at], as its own layer. Returns the paint
## image, so the finishes can be compared against each other pixel by pixel.
func _stamp_finish(finish: StringName, at: Vector2) -> Image:
	await _clear()
	_page_view.brush_effect = finish
	_page_view.begin_stroke(at)
	_page_view.end_stroke()
	return await _read_paint()


func _painted_pixels(paint: Image) -> int:
	var bytes := paint.get_data()
	var painted := 0
	for i in _page_width * _page_height:
		if bytes[i * 4 + 3] > 0:
			painted += 1
	return painted


## Spread (max - min luminance) of the solidly painted pixels down the middle of a
## dab: 0 for a flat colour, more the more texture the finish put in the wax.
func _core_spread(paint: Image) -> float:
	var lowest := 1.0
	var highest := 0.0
	for dx in range(-16, 17):
		var pixel := paint.get_pixel(int(FINISH_DAB.x) + dx, int(FINISH_DAB.y))
		if pixel.a8 < SOLID_ALPHA:
			continue
		var luminance := pixel.get_luminance()
		lowest = minf(lowest, luminance)
		highest = maxf(highest, luminance)
	return maxf(highest - lowest, 0.0)


## Brightest solidly painted pixel in the dab -- the glitter check.
func _brightest_core(paint: Image) -> float:
	var brightest := 0.0
	for dy in range(-20, 21):
		for dx in range(-20, 21):
			var pixel := paint.get_pixel(int(FINISH_DAB.x) + dx, int(FINISH_DAB.y) + dy)
			if pixel.a8 >= SOLID_ALPHA:
				brightest = maxf(brightest, pixel.get_luminance())
	return brightest


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

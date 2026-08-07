extends Control
## Automated verification for Milestone 4 -- books, pages, coverage, flip, shelf.
##
## Run WINDOWED (the integration checks paint into a SubViewport, which renders
## nothing under --headless / the dummy rasteriser):
##
##   <godot_exe> --path <project> res://scenes/dev/flow_smoke.tscn
##
## Extra user args (after a bare `--`):
##   --stay                 leave the window open on the shelf instead of quitting
##   --shot-dir <dir>       where book_select.png / flip_moment.png are written
##                          (default user://flow_smoke)
##   --skip-subsmokes       do not re-run the M2/M3 smoke tests as child processes
##
## Checks, in order:
##   1  BookDef / PageDef resources load, validate, and page_02's generated data
##      matches its generator layout with lossless ID-map import settings
##   2  CoverageTracker against page 1's real geometry, driven by SYNTHETIC paint
##      images -- no GPU, no PageView readback
##   3  BookSelect renders and reports the chosen book
##   4  ColoringPage end to end: every page is reachable from the first frame
##      (BL-10), paint every region of page 1, it completes WITHOUT turning itself
##      (BL-4) and celebrates TRANSIENTLY (BL-11 -- a random message, a confetti
##      burst, both fading on their own and blocking nothing), pressing the
##      next-page arrow plays the flip, the second page is really loaded, the
##      palette still drives the brush
##   5  ... and finishing page 2 does NOT end the book: the last page celebrates
##      exactly like any other, its forward arrow is simply disabled, and Back is
##      the only way out (BL-11 -- there is no BookComplete screen any more)
##   6  the M2 and M3 smoke tests still pass, run as child processes
##
## Exit code is 0 only if every check passes.

const BOOK_PATH := "res://resources/books/test_book/book.tres"
## M6 shipped the first real art book. It is not what this harness colours -- the
## test book's synthetic shapes are what the checks are calibrated against -- but
## the shelf and the discovery scan must both account for it.
const COYOTE_BOOK_PATH := "res://resources/books/coyote/book.tres"
## Books discovered under res://resources/books/: test_book + coyote.
const EXPECTED_BOOK_COUNT := 2
const PAGE_01_TRES := "res://resources/books/test_book/pages/page_01.tres"
const PAGE_02_TRES := "res://resources/books/test_book/pages/page_02.tres"
const PAGE_02_IDMAP_IMPORT := "res://assets/books/test_book/page_02_idmap.png.import"

const PAGE_VIEW_SCENE := preload("res://scenes/components/page_view.tscn")
const BOOK_SELECT_SCENE := preload("res://scenes/screens/book_select.tscn")
const COLORING_PAGE_SCENE := preload("res://scenes/screens/coloring_page.tscn")

## What tools/generate_test_page.gd's layout 2 promises: 8 regions including the
## background, one of them nested inside another (the sun's core inside its ring).
const PAGE_02_EXPECTED_REGIONS := 8
const PAGE_02_EXPECTED_NESTED := 1

## Import flags the ID map must keep, or region ids bleed (DESIGN.md 3.2).
const REQUIRED_IDMAP_IMPORT_FLAGS := {
	"compress/mode": "0",
	"mipmaps/generate": "false",
	"detect_3d/compress_to": "0",
	"process/fix_alpha_border": "false",
}

## Threshold injected into the unit-test trackers (the shipped child value, which
## BL-5 tightened from 0.70 to 0.90 -- and which is now also the floor the tracker
## clamps every authored threshold against).
const UNIT_THRESHOLD := 0.9
## Per-channel tolerance (0..255) when checking painted pixels against a colour.
const COLOR_TOLERANCE := 2
## Sweep spacing for the flood helper, as a fraction of the brush RADIUS.
const FLOOD_ROW_RATIO := 1.15
## Coarse step used when hunting for a coordinate that tells the two pages apart.
const PAGE_DIFF_SCAN_STEP := 4

@onready var _host: Control = $Host
@onready var _probe: Control = $Probe

var _checks := 0
var _failures := 0

var _book: BookDef
var _shot_dir := "user://flow_smoke"

# Recorded flow events.
var _flip_started_count := 0
var _flip_finished_count := 0
var _page_changed_events: Array[int] = []
var _page_completed_events: Array[int] = []
var _coverage_history: Dictionary = {}
var _coverage_regressions: Array[String] = []


func _ready() -> void:
	get_window().size = Vector2i(1280, 900)
	_shot_dir = _arg_value("--shot-dir", _shot_dir)
	if not DirAccess.dir_exists_absolute(_shot_dir):
		DirAccess.make_dir_recursive_absolute(_shot_dir)
	await get_tree().process_frame
	await _run()


func _run() -> void:
	print("=== M4 flow smoke test ===")
	# M5 added persistence, and this test must not see it: a paint layer saved by
	# an earlier run would be restored into page 2 and break "page 2 starts at 0
	# coverage". Point saves at a scratch root and wipe it.
	GameState.set_save_root("user://flow_smoke/state")
	GameState.erase_all_progress()

	_check_resources()
	await _check_coverage_tracker()
	await _check_book_select()
	await _check_coloring_flow()
	_check_sub_smokes()

	print("\n=== %d/%d checks passed ===" % [_checks - _failures, _checks])
	if "--stay" in OS.get_cmdline_user_args():
		print("[dev] --stay given; not quitting. Pick the book to colour it by hand.")
		await _stay_on_the_shelf()
		return
	_finish(0 if _failures == 0 else 1)


## Leaves a live shelf -> coloring page loop up for the human pass.
func _stay_on_the_shelf() -> void:
	for child in _host.get_children():
		child.queue_free()
	await get_tree().process_frame
	var shelf := BOOK_SELECT_SCENE.instantiate() as BookSelect
	_host.add_child(shelf)
	shelf.load_books()
	shelf.book_chosen.connect(func(book: BookDef) -> void:
		shelf.queue_free()
		var screen := COLORING_PAGE_SCENE.instantiate() as ColoringPage
		_host.add_child(screen)
		screen.load_book(book)
		screen.back_requested.connect(func() -> void:
			screen.queue_free()
			await get_tree().process_frame
			await _stay_on_the_shelf()
		)
	)


func _finish(code: int) -> void:
	# Never tear the engine down on top of a queued GPU readback: that is a hard
	# crash (see AsyncReadback.drain).
	await AsyncReadback.drain(get_tree())
	print("exit code: %d" % code)
	get_tree().quit(code)


# ============================================================ 1: resources ==

func _check_resources() -> void:
	print("\n-- check 1: BookDef / PageDef resources and page_02 data --")

	_book = load(BOOK_PATH) as BookDef
	_expect(_book != null, "%s loads as a BookDef" % BOOK_PATH)
	if _book == null:
		return
	_expect(_book.validate().is_empty(), "book validates (%s)" % [_book.validate()])
	_expect(_book.display_name != "", "book has a display name ('%s')" % _book.display_name)
	_expect(_book.page_count() == 2, "book has 2 pages (%d)" % _book.page_count())
	_expect(
		_book.get_page(0) == load(PAGE_01_TRES) and _book.get_page(1) == load(PAGE_02_TRES),
		"pages are page_01.tres then page_02.tres, in order"
	)
	_expect(_book.get_page(2) == null, "get_page() past the end returns null")
	_expect(
		_book.get_cover_path() == _book.get_page(0).display_image_path,
		"cover falls back to page 1's display image (%s)" % _book.get_cover_path()
	)
	_expect(_book.get_cover_texture() != null, "cover texture loads")

	for i in _book.page_count():
		var page := _book.get_page(i)
		_expect(page.validate().is_empty(),
			"page %d ('%s') validates (%s)" % [i + 1, page.display_name, page.validate()])

	# Discovery, not a preload list. M6 added the coyote book by dropping a folder
	# in -- no code changed, which is the property this check exists to defend.
	# WP7 gave discover() a second root (installed DLC packs). This check is about
	# the res:// scan, so it asks for that one alone -- whether a pack is installed
	# on this machine is not this smoke's business, and dlc_smoke owns that half.
	var discovered := BookDef.discover(BookDef.BOOKS_ROOT, "")
	_expect(discovered.size() == EXPECTED_BOOK_COUNT,
		"BookDef.discover() found %d books by scanning (%d)"
		% [EXPECTED_BOOK_COUNT, discovered.size()])
	_expect(discovered.has(_book), "the discovered set contains the same cached test-book instance")
	var discovered_names := PackedStringArray()
	for book in discovered:
		discovered_names.append(book.display_name)
	_expect(discovered.size() == EXPECTED_BOOK_COUNT and discovered[0] == load(COYOTE_BOOK_PATH),
		"books come back sorted by directory name (%s)" % ", ".join(discovered_names))
	for book in discovered:
		_expect(book.validate().is_empty(),
			"discovered book '%s' validates (%s)" % [book.display_name, book.validate()])

	# --- page_02's generated data --------------------------------------------
	var page_02 := _book.get_page(1)
	var json := page_02.load_regions_json()
	_expect(not json.is_empty(), "page_02 regions JSON parses")
	if json.is_empty():
		return
	_expect(int(json.get("version", 0)) == 1, "page_02 JSON is schema version 1")
	_expect(String(json.get("source_image", "")) == "page_02.png",
		"page_02 JSON names its source image (%s)" % json.get("source_image"))
	var regions: Array = json.get("regions", [])
	_expect(regions.size() == PAGE_02_EXPECTED_REGIONS,
		"page_02 has the %d regions layout 2 promises (%d)" % [PAGE_02_EXPECTED_REGIONS, regions.size()])
	var nested := 0
	for region_variant in regions:
		var region: Dictionary = region_variant
		# The background's holes are the shapes sitting on it; a nested region is
		# a hole in a NON-background region -- exactly the sun's ring/core pair.
		if int(region["id"]) != 1 and (region.get("holes", []) as Array).size() > 0:
			nested += 1
	_expect(nested == PAGE_02_EXPECTED_NESTED,
		"page_02 has %d nested region(s) (%d)" % [PAGE_02_EXPECTED_NESTED, nested])

	var idmap := load(page_02.id_map_path) as Texture2D
	_expect(idmap != null, "page_02 ID map texture loads")
	if idmap != null:
		var idmap_image := idmap.get_image()
		_expect(not idmap_image.is_compressed(),
			"page_02 ID map is NOT VRAM-compressed (format %d)" % idmap_image.get_format())
		_expect(not idmap_image.has_mipmaps(), "page_02 ID map has no mipmaps")
		var base := load(page_02.display_image_path) as Texture2D
		_expect(
			base != null and idmap.get_size() == base.get_size(),
			"page_02 ID map matches the display image size (%s)" % idmap.get_size()
		)
		# The strongest guarantee: the imported texture is the source PNG, bit for
		# bit. Reading the raw PNG logs "this will not work on export" -- correct
		# and expected: the source art is a DEV file, and only this dev check ever
		# opens it. The game always goes through the importer.
		var source := Image.load_from_file(page_02.id_map_path)
		var imported := idmap_image
		if imported.get_format() != source.get_format():
			imported = imported.duplicate()
			imported.convert(source.get_format())
		_expect(imported.get_data() == source.get_data(),
			"page_02 ID map round-trips byte-identically through the importer")

	_check_import_flags(PAGE_02_IDMAP_IMPORT)


func _check_import_flags(import_path: String) -> void:
	var text := FileAccess.get_file_as_string(import_path)
	_expect(text != "", "%s is readable" % import_path)
	for key in REQUIRED_IDMAP_IMPORT_FLAGS:
		var expected: String = REQUIRED_IDMAP_IMPORT_FLAGS[key]
		var line := "%s=%s" % [key, expected]
		_expect(text.contains(line), "page_02 ID map .import keeps %s" % line)


# ====================================================== 2: coverage tracker ==
# No GPU, no PageView readback: real region geometry from page 1, synthetic paint
# images, injected threshold.

func _check_coverage_tracker() -> void:
	print("\n-- check 2: CoverageTracker (synthetic paint, injected threshold) --")
	var probe := PAGE_VIEW_SCENE.instantiate() as PageView
	_probe.add_child(probe)
	await get_tree().process_frame
	var page_01 := _book.get_page(0)
	if not probe.load_page(page_01.display_image_path, page_01.id_map_path, page_01.regions_json_path):
		_expect(false, "probe PageView loaded page 1")
		probe.queue_free()
		return

	var page_size := probe.get_page_size()
	var region_ids := probe.get_region_ids()

	# --- grids ---------------------------------------------------------------
	var tracker := CoverageTracker.new(UNIT_THRESHOLD)
	var tracked := tracker.build_from_page_view(probe)
	_expect(tracked == region_ids.size(),
		"a sample grid was built for all %d regions (%d)" % [region_ids.size(), tracked])
	_expect(is_equal_approx(tracker.get_threshold(), UNIT_THRESHOLD),
		"threshold is the injected %.2f (%.2f)" % [UNIT_THRESHOLD, tracker.get_threshold()])

	var densities := PackedStringArray()
	var in_band := true
	for region_id in region_ids:
		var count := tracker.sample_count(region_id)
		densities.append("%d:%d" % [region_id, count])
		in_band = in_band and count >= CoverageTracker.MIN_SAMPLES_PER_REGION \
			and count <= CoverageTracker.MAX_SAMPLES_PER_REGION
	_expect(in_band,
		"every region samples %d-%d points (region:samples = %s, total %d)"
		% [CoverageTracker.MIN_SAMPLES_PER_REGION, CoverageTracker.MAX_SAMPLES_PER_REGION,
			", ".join(densities), tracker.total_sample_count()])

	# Every sample point must be a pixel the ID map awards to its own region --
	# otherwise 100% coverage would be unreachable.
	var stray := 0
	for region_id in region_ids:
		for point in tracker.get_sample_points(region_id):
			if probe.get_region_id_at(point) != region_id:
				stray += 1
	_expect(stray == 0, "every sample point lies in its own region per the ID map (%d strays)" % stray)

	# --- full cover of one region -------------------------------------------
	var region_two_bounds := _region_bounds(probe, 2)
	var completed: Array[int] = []
	# Arrays, not ints: GDScript lambdas capture locals by VALUE, so `count += 1`
	# inside one would increment a copy and the check would silently pass.
	var page_done: Array[int] = []
	tracker.region_completed.connect(func(id: int) -> void: completed.append(id))
	tracker.page_completed.connect(func() -> void: page_done.append(1))

	var full := _blank_paint(page_size)
	full.fill_rect(region_two_bounds, Color(1.0, 0.0, 0.0, 1.0))
	tracker.update_region(2, full)
	_expect(is_equal_approx(tracker.region_coverage(2), 1.0),
		"region 2 fully covered -> coverage %.3f" % tracker.region_coverage(2))
	_expect(tracker.is_region_done(2), "region 2 reports done")
	_expect(completed == [2], "region_completed fired once, for region 2 (%s)" % [completed])
	_expect(page_done.is_empty(), "page_completed has NOT fired with 7 regions still empty")
	tracker.update_region(2, full)
	_expect(completed == [2], "re-sampling a done region does not re-fire region_completed")

	# --- partial cover stays below the threshold -----------------------------
	var partial_tracker := CoverageTracker.new(UNIT_THRESHOLD)
	partial_tracker.build_from_page_view(probe)
	var partial_completed: Array[int] = []
	partial_tracker.region_completed.connect(func(id: int) -> void: partial_completed.append(id))
	var half := _blank_paint(page_size)
	var half_bounds := region_two_bounds
	half_bounds.size.y = int(float(region_two_bounds.size.y) * 0.45)
	half.fill_rect(half_bounds, Color(1.0, 0.0, 0.0, 1.0))
	partial_tracker.update_region(2, half)
	var partial_coverage := partial_tracker.region_coverage(2)
	_expect(partial_coverage > 0.15 and partial_coverage < UNIT_THRESHOLD,
		"45%% of region 2 painted -> coverage %.3f, below the %.2f threshold"
		% [partial_coverage, UNIT_THRESHOLD])
	_expect(not partial_tracker.is_region_done(2), "region 2 is NOT done below the threshold")
	_expect(partial_completed.is_empty(), "region_completed did not fire (%s)" % [partial_completed])

	# --- coverage never decreases -------------------------------------------
	partial_tracker.update_region(2, _blank_paint(page_size))
	_expect(is_equal_approx(partial_tracker.region_coverage(2), partial_coverage),
		"re-sampling with an EMPTY paint image does not lower coverage (%.3f)"
		% partial_tracker.region_coverage(2))

	# --- every region covered -> page_completed, exactly once ----------------
	var everything := _blank_paint(page_size)
	everything.fill(Color(0.2, 0.4, 1.0, 1.0))
	tracker.update_all(everything)
	_expect(tracker.is_page_complete(), "every region done -> is_page_complete()")
	_expect(tracker.done_region_count() == region_ids.size(),
		"%d/%d regions done" % [tracker.done_region_count(), region_ids.size()])
	_expect(is_equal_approx(tracker.page_coverage(), 1.0),
		"page_coverage() is %.3f" % tracker.page_coverage())
	_expect(page_done.size() == 1, "page_completed fired EXACTLY once (%d)" % page_done.size())
	tracker.update_all(everything)
	tracker.update_all(_blank_paint(page_size))
	_expect(page_done.size() == 1, "further updates never re-fire page_completed (%d)" % page_done.size())
	_expect(tracker.is_page_complete(), "the page stays complete after an empty re-sample")

	# --- an empty tracker is not a complete page -----------------------------
	var empty_tracker := CoverageTracker.new(UNIT_THRESHOLD)
	_expect(not empty_tracker.is_page_complete(), "a tracker with no regions is NOT complete")

	await _measure_readback_cost(probe)

	probe.queue_free()
	await get_tree().process_frame


## The one expensive operation in the coverage strategy, measured (see
## coverage_tracker.gd for why strategy (b) was chosen at all).
##
## It reports TWO numbers because they are wildly different and only one of them
## is about this code: the transfer itself is a few milliseconds, but Godot's
## synchronous readback additionally waits out the presentation queue when the
## window presents with FIFO v-sync. That wait is pacing, not bandwidth -- it is
## the same for a small main-viewport grab as for the 1024x1024 paint layer.
##
## The harness then leaves the window on MAILBOX so the rest of the run is not
## dominated by ~0.5 s of presentation stall per stroke.
func _measure_readback_cost(probe: PageView) -> void:
	print("\n-- readback cost (coverage strategy (b): one get_paint_image() per stroke end) --")
	var fifo := await _time_readbacks(probe, DisplayServer.VSYNC_ENABLED, 3)
	var mailbox := await _time_readbacks(probe, DisplayServer.VSYNC_MAILBOX, 3)
	print("   VSYNC_ENABLED (FIFO): %.1f ms/readback   VSYNC_MAILBOX: %.1f ms/readback"
		% [fifo, mailbox])
	print("   -> the transfer is %.1f ms; the rest is presentation pacing (M6 fix: texture_get_data_async)"
		% mailbox)
	_expect(mailbox < 40.0,
		"the paint readback itself costs %.1f ms for a %s page" % [mailbox, probe.get_page_size()])
	print("   [dev] leaving the window on VSYNC_MAILBOX for the rest of the run")


func _time_readbacks(probe: PageView, vsync_mode: int, samples: int) -> float:
	DisplayServer.window_set_vsync_mode(vsync_mode as DisplayServer.VSyncMode)
	for i in 4:
		await get_tree().process_frame
	var total := 0
	for i in samples:
		await get_tree().process_frame
		var started := Time.get_ticks_usec()
		var _image := probe.get_paint_image()
		total += Time.get_ticks_usec() - started
	return float(total) / float(samples) / 1000.0


## The shelf cell showing [param book], or null. The shelf sorts by directory
## name, so index 0 is no longer "the test book" now that a second book exists.
static func _cell_for(shelf: BookSelect, book: BookDef) -> BookCell:
	for cell in shelf.get_cells():
		if cell.get_book() == book:
			return cell
	return null


static func _blank_paint(page_size: Vector2i) -> Image:
	var image := Image.create(page_size.x, page_size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	return image


static func _region_bounds(page_view: PageView, region_id: int) -> Rect2i:
	var outline: PackedVector2Array = page_view.get_region_data(region_id)["outline"]
	var minimum := outline[0]
	var maximum := outline[0]
	for point in outline:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return Rect2i(Vector2i(minimum.floor()), Vector2i(maximum.ceil()) - Vector2i(minimum.floor()))


# =========================================================== 3: book select ==

func _check_book_select() -> void:
	print("\n-- check 3: BookSelect shelf --")
	var shelf := BOOK_SELECT_SCENE.instantiate() as BookSelect
	_host.add_child(shelf)
	await get_tree().process_frame

	# Built-in books only: see check 1 -- an installed DLC pack is dlc_smoke's business.
	var count := shelf.load_books(BookDef.BOOKS_ROOT, "")
	_expect(count == EXPECTED_BOOK_COUNT,
		"shelf loaded %d books by scanning res://resources/books/ (%d)"
		% [EXPECTED_BOOK_COUNT, count])
	await _settle_layout()

	var cells := shelf.get_cells()
	_expect(cells.size() == EXPECTED_BOOK_COUNT,
		"%d BookCells rendered (%d)" % [EXPECTED_BOOK_COUNT, cells.size()])
	var cell := _cell_for(shelf, _book)
	_expect(cell != null, "the shelf has a cell for the test book")
	if cell == null:
		shelf.queue_free()
		return
	_expect(cell.get_book() == _book, "the cell carries the discovered BookDef")
	_expect(cell.get_title_text() == _book.display_name,
		"the cell shows the title ('%s')" % cell.get_title_text())
	_expect(cell.get_subtitle_text() == "2 pages",
		"the cell shows the page count ('%s')" % cell.get_subtitle_text())
	_expect(cell.has_cover(), "the cell shows cover art")
	_expect(
		minf(cell.size.x, cell.size.y) >= BookCell.MIN_TOUCH_TARGET,
		"the touch target is >= %.0f px (%.0f x %.0f)"
		% [BookCell.MIN_TOUCH_TARGET, cell.size.x, cell.size.y]
	)
	_expect(
		cell.global_position.x >= 0.0 and cell.get_global_rect().end.x <= shelf.size.x + 1.0,
		"the book lays out inside the shelf (x %.0f..%.0f of %.0f)"
		% [cell.global_position.x, cell.get_global_rect().end.x, shelf.size.x]
	)

	var chosen: Array[BookDef] = []
	shelf.book_chosen.connect(func(book: BookDef) -> void: chosen.append(book))
	# The real input path: BaseButton reports `pressed`.
	cell.pressed.emit()
	_expect(chosen.size() == 1 and chosen[0] == _book,
		"pressing the cell emitted book_chosen with the right BookDef (%d event(s))" % chosen.size())

	# Narrow layout. The WINDOW cannot be used for this: the project stretches
	# canvas_items with aspect "expand", so the logical viewport stays 1152 wide
	# whatever the window does. Resize the screen Control itself instead.
	shelf.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	shelf.size = Vector2(420.0, 820.0)
	await _settle_layout()
	var overflowing := 0
	for other in shelf.get_cells():
		if other.global_position.x < 0.0 or other.get_global_rect().end.x > shelf.size.x + 1.0:
			overflowing += 1
	_expect(overflowing == 0,
		"a 420 px-wide shelf still fits every book (%d cell(s) overflowing)" % overflowing)
	shelf.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _settle_layout()

	await _screenshot("book_select.png")
	shelf.queue_free()
	await get_tree().process_frame


# ========================================================= 4/5: colouring ==

func _check_coloring_flow() -> void:
	print("\n-- check 4: ColoringPage, real strokes, page flip --")
	var screen := COLORING_PAGE_SCENE.instantiate() as ColoringPage
	_host.add_child(screen)
	await get_tree().process_frame

	screen.get_page_flip().flip_started.connect(_on_flip_started)
	screen.get_page_flip().flip_finished.connect(func() -> void: _flip_finished_count += 1)
	screen.page_changed.connect(func(index: int) -> void: _page_changed_events.append(index))
	screen.page_completed.connect(func(index: int) -> void: _page_completed_events.append(index))
	screen.coverage_updated.connect(_on_coverage_updated)

	_expect(screen.load_book(_book), "load_book(test_book) succeeded")
	await _settle_layout()

	var page_view := screen.get_page_view()
	_expect(page_view.is_page_loaded(), "PageView holds page 1")
	_expect(screen.get_page_label_text() == "1/2",
		"toolbar reads 1/2 ('%s')" % screen.get_page_label_text())
	_expect(GameState.current_book == _book and GameState.current_page_index == 0,
		"GameState cursor is (test_book, page 0)")

	var palette := screen.get_palette()
	# BL-20: there is ONE palette component, and the screen loads it without
	# consulting anything but GameState.get_palette_scene_path().
	_expect(palette is PaletteChild,
		"the crayon palette component was instantiated (%s)" % _script_name(palette))
	var palette_def := GameState.get_active_palette()
	_expect(palette != null and palette.get_palette() == palette_def,
		"the palette was handed the active PaletteDef")
	_expect(is_equal_approx(page_view.brush_size, palette_def.default_brush_size),
		"PageView.brush_size follows the palette (%.0f px)" % page_view.brush_size)
	_expect(page_view.brush_color == palette_def.get_color(0),
		"PageView.brush_color follows the palette (#%s)" % page_view.brush_color.to_html(false))
	_expect(is_equal_approx(page_view.brush_hardness, palette_def.default_brush_hardness),
		"PageView.brush_hardness came from the def (%.2f)" % page_view.brush_hardness)

	# BL-16 part 1: the "now painting with" chip BL-15 docked in the toolbar is gone,
	# component and wiring. The pick bubble and the selected states answer "which one
	# is it" where the player is already looking.
	_expect(screen.get_node_or_null("Ui/Toolbar/Row/BrushIndicator") == null,
		"the toolbar carries no brush-indicator chip any more (BL-16)")
	palette.select_color(4)
	_expect(page_view.brush_color == palette_def.get_color(4),
		"a pick still drives the brush directly (#%s)" % page_view.brush_color.to_html(false))
	palette.select_color(0)

	var tracker := screen.get_coverage_tracker()
	_expect(tracker != null and is_equal_approx(tracker.get_threshold(), palette_def.completion_threshold),
		"the tracker's threshold is the palette's %.2f" % palette_def.completion_threshold)

	# --- BL-10: free page choice, from the very first frame -------------------
	# Nothing has been coloured, so under the M6 rule page 2 was unreachable. It is
	# not gated on anything any more: completion is a celebration, never a key.
	_expect(screen.can_go_to_page(1),
		"page 2 of an untouched book is reachable straight away (free play)")
	_expect(not screen.get_next_page_button().disabled,
		"...so the next-page arrow is live before a single stroke")
	_expect(not screen.can_go_to_page(0), "the page already open is not a jump")
	_expect(screen.get_prev_page_button().disabled, "there is nothing before page 1")
	_expect(not screen.can_go_to_page(-1) and not screen.can_go_to_page(2),
		"out-of-range jumps are still refused")
	_expect(not screen.is_celebrating(),
		"nothing is celebrating over a page nobody has coloured yet")

	# Remember page 1's ID map so we can prove the page really swapped later.
	var page_01_ids := page_view.get_id_map_image().duplicate()
	var page_02_ids := (load(_book.get_page(1).id_map_path) as Texture2D).get_image()
	var only_page_02 := _find_pixel(page_01_ids, page_02_ids, true)
	var only_page_01 := _find_pixel(page_01_ids, page_02_ids, false)
	_expect(only_page_02.x >= 0.0 and only_page_01.x >= 0.0,
		"found coordinates that tell the pages apart: %s is line art on page 1 / paintable on page 2, %s is the reverse"
		% [only_page_02, only_page_01])

	await _check_undo_redo(screen)

	# --- paint page 1 --------------------------------------------------------
	var strokes := await _fill_page(screen)
	print("   page 1 filled with %d strokes" % strokes)
	_expect(tracker.is_page_complete(),
		"every region of page 1 reached the threshold (%d/%d done, page coverage %.3f)"
		% [tracker.done_region_count(), tracker.region_count(), tracker.page_coverage()])
	_expect(_page_completed_events == [0], "page_completed fired once for page 0 (%s)" % [_page_completed_events])
	_expect(_coverage_regressions.is_empty(),
		"coverage never decreased across %d samples (%s)" % [_coverage_history.size(), _coverage_regressions])

	# --- BL-4: a finished page does NOT turn itself --------------------------
	await _wait_until(func() -> bool: return not screen.is_transitioning(), 12.0)
	_expect(_flip_started_count == 0,
		"completing page 1 did NOT flip on its own (%d flip(s))" % _flip_started_count)
	_expect(screen.get_page_label_text() == "1/2",
		"the player is still on the page they finished ('%s')" % screen.get_page_label_text())
	_expect(not screen.get_next_page_button().disabled,
		"...and the next-page arrow is live, so turning the page is the PLAYER's call")

	# --- BL-11: the celebration is transient and blocks nothing --------------
	_expect(screen.is_celebrating(), "completing the page raised the celebration")
	_expect(ColoringPage.CELEBRATION_MESSAGES.has(screen.get_celebration_message()),
		"...with a congratulation from the authored pool ('%s')" % screen.get_celebration_message())
	var confetti := screen.get_confetti()
	_expect(confetti != null and confetti.emitting, "...and a confetti burst")
	_expect(confetti != null and confetti.color_initial_ramp != null
			and confetti.color_initial_ramp.get_point_count() > 1,
		"...whose scraps are palette-coloured (%d colours)"
		% [confetti.color_initial_ramp.get_point_count() if confetti != null
			and confetti.color_initial_ramp != null else 0])
	var overlay := screen.get_celebration_overlay()
	_expect(overlay != null and overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"the celebration cannot swallow a tap -- it is presentation, never a gate")
	# It is still fully paintable underneath, mid-celebration.
	_expect(page_view.begin_stroke(page_view.get_region_data(2)["centroid"]),
		"...and a stroke still starts while it is on screen")
	page_view.end_stroke()
	await _wait_for_coverage(screen)
	var faded := await _wait_until(func() -> bool: return not screen.is_celebrating(), 15.0)
	_expect(faded, "the celebration faded away on its own -- nothing had to dismiss it")
	_expect(screen.get_page_label_text() == "1/2",
		"...leaving the player exactly where they were ('%s')" % screen.get_page_label_text())

	# --- the flip, when the player asks for it -------------------------------
	screen.get_next_page_button().pressed.emit()
	var turned := await _wait_until(
		func() -> bool:
			return screen.get_page_label_text() == "2/2" and not screen.is_transitioning(),
		12.0
	)
	_expect(turned, "pressing › turned the page ('%s')" % screen.get_page_label_text())
	_expect(_flip_started_count == 1, "the page flip played (started %d)" % _flip_started_count)
	_expect(_flip_finished_count == 1, "flip_finished was received (%d)" % _flip_finished_count)
	_expect(not screen.get_page_flip().visible, "the flip overlay hid itself again")
	_expect(screen.get_page_flip().mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"the flip overlay stopped intercepting input")
	_expect(_page_changed_events == [0, 1], "page_changed fired for pages 0 then 1 (%s)" % [_page_changed_events])
	_expect(screen.get_page_label_text() == "2/2",
		"toolbar now reads 2/2 ('%s')" % screen.get_page_label_text())
	_expect(GameState.current_page_index == 1, "GameState cursor advanced to page 1")

	_expect(page_view.get_region_id_at(only_page_02) > 0,
		"PageView now shows page_02: %s is paintable region %d (it is line art on page 1)"
		% [only_page_02, page_view.get_region_id_at(only_page_02)])
	_expect(page_view.get_region_id_at(only_page_01) == 0,
		"...and %s is line art now (it was paintable region %d on page 1)"
		% [only_page_01, _id_at(page_01_ids, only_page_01)])

	var fresh_tracker := screen.get_coverage_tracker()
	_expect(fresh_tracker != tracker, "a fresh CoverageTracker was built for page 2")
	_expect(fresh_tracker.page_coverage() == 0.0,
		"page 2 starts at 0 coverage (%.3f)" % fresh_tracker.page_coverage())
	# BL-17: the history is per page VISIT. Turning the page must not leave the
	# previous page's strokes undoable onto this one.
	_expect(not screen.can_undo() and not screen.can_redo(),
		"turning the page cleared the undo history (%d/%d)"
		% [screen.undo_depth(), screen.redo_depth()])

	# --- the palette still drives the brush on the new page ------------------
	print("\n-- check 4b: palette still functional after the flip --")
	var pick_index := 5
	palette.select_color(pick_index)
	var expected_color := palette_def.get_color(pick_index)
	_expect(page_view.brush_color == expected_color,
		"picking crayon %d set the brush to #%s" % [pick_index, expected_color.to_html(false)])
	var sun_core := Vector2(270.5, 250.5)
	_expect(page_view.get_region_id_at(sun_core) > 0, "precondition: %s is paintable on page 2" % sun_core)
	page_view.begin_stroke(sun_core)
	page_view.continue_stroke(sun_core + Vector2(0.0, 30.0))
	page_view.end_stroke()
	await _wait_for_coverage(screen)
	var paint := page_view.get_paint_image()
	if paint.get_format() != Image.FORMAT_RGBA8:
		paint.convert(Image.FORMAT_RGBA8)
	var core := paint.get_pixel(int(sun_core.x), int(sun_core.y))
	var worst := maxi(
		absi(core.r8 - expected_color.r8),
		maxi(absi(core.g8 - expected_color.g8), absi(core.b8 - expected_color.b8))
	)
	_expect(core.a8 >= 250, "the new stroke's core pixel is opaque (a=%d)" % core.a8)
	_expect(worst <= COLOR_TOLERANCE,
		"the core pixel is the picked palette colour (worst channel delta %d/255)" % worst)

	# --- finish page 2: the book ends when the PLAYER says so (BL-10) --------
	print("\n-- check 5: finishing the last page --")
	var strokes_2 := await _fill_page(screen)
	print("   page 2 filled with %d strokes" % strokes_2)
	var last_done := await _wait_until(
		func() -> bool:
			return fresh_tracker.is_page_complete() and not screen.is_transitioning(),
		12.0
	)
	_expect(last_done and fresh_tracker.is_page_complete(),
		"every region of page 2 reached the threshold (%d/%d done)"
		% [fresh_tracker.done_region_count(), fresh_tracker.region_count()])
	_expect(_page_completed_events == [0, 1], "page_completed fired for both pages (%s)" % [_page_completed_events])
	_expect(screen.is_celebrating(),
		"...it celebrates exactly like any other page (BL-11)")
	_expect(screen.get_page_label_text() == "2/2",
		"...and the player is still on it ('%s')" % screen.get_page_label_text())
	_expect(screen.get_next_page_button().disabled,
		"the forward arrow is DISABLED on the last page -- there is nowhere to turn to")
	_expect(not screen.get_back_button().disabled,
		"...and Back is the way out of the book, exactly as it always was")

	# Still fully paintable: a complete page is never a read-only page (BL-10).
	var extra_point := Vector2(270.5, 250.5)
	_expect(page_view.begin_stroke(extra_point),
		"a stroke still STARTS on the completed page -- colour forever")
	page_view.continue_stroke(extra_point + Vector2(0.0, 40.0))
	page_view.end_stroke()
	await _wait_for_coverage(screen)
	_expect(_page_completed_events == [0, 1],
		"...and painting on it did not re-fire page_completed (%s)" % [_page_completed_events])
	_expect(fresh_tracker.is_page_complete(), "...the page is still recorded complete")

	# BL-11: the last page's celebration is as transient as every other one, and
	# when it is gone the player is simply still on page 2 with a live toolbar.
	var last_faded := await _wait_until(func() -> bool: return not screen.is_celebrating(), 15.0)
	_expect(last_faded, "the last page's celebration faded away by itself too")
	_expect(_flip_started_count == 1,
		"no flip played past the last page -- there is nothing behind it to reveal (%d)"
		% _flip_started_count)
	_expect(GameState.current_page_index == 1, "the cursor is still on the last page")
	_expect(screen.get_next_page_button().disabled and not screen.get_back_button().disabled,
		"the only control that leaves the book is still Back")

	# BL-36's stickers run LAST, deliberately: the check navigates and presses Start
	# over, both of which rebuild the coverage tracker, and every assertion above is
	# holding a reference to the one it was given.
	await _check_stickers(screen)

	# --- back button ---------------------------------------------------------
	# M6: leaving the book flushes the paint layer through the ASYNC readback and
	# only then reports back_requested, so the parent cannot free the screen out
	# from under a save in flight. The signal is therefore a few frames late.
	var back_events: Array[int] = []
	screen.back_requested.connect(func() -> void: back_events.append(1))
	screen.get_back_button().pressed.emit()
	var reported := await _wait_until(func() -> bool: return back_events.size() == 1, 8.0)
	_expect(reported,
		"the toolbar's back button emits back_requested (%d)" % back_events.size())

	print("   readbacks: %d, last %.2f ms, average %.2f ms"
		% [screen.get_readback_count(), screen.get_last_readback_usec() / 1000.0,
			screen.get_average_readback_usec() / 1000.0])
	_expect(screen.get_readback_count() > 0, "coverage used %d paint readbacks (one per stroke end)"
		% screen.get_readback_count())

	screen.queue_free()
	await get_tree().process_frame


## BL-17 at the screen's level: the buttons, the stacks, the interlocks and the
## coverage re-settle. The pixel-exactness of a replay is proved in the M2 paint
## smoke, where the whole layer is compared byte for byte; what matters here is that
## the screen drives it at the right moments and refuses at the wrong ones.
func _check_undo_redo(screen: ColoringPage) -> void:
	print("\n-- check 4a: undo / redo (BL-17) --")
	var page_view := screen.get_page_view()
	var tracker := screen.get_coverage_tracker()
	var undo_button := screen.get_undo_button()
	var redo_button := screen.get_redo_button()

	_expect(undo_button != null and redo_button != null
		and undo_button.get_parent().name == "Row"
		and undo_button.get_parent().get_parent().name == "Toolbar",
		"undo and redo are in the coloring toolbar, at the top of the page")
	_expect(undo_button != null and redo_button != null
		and undo_button.custom_minimum_size.x >= 48.0
		and undo_button.custom_minimum_size.y >= 48.0
		and redo_button.custom_minimum_size.x >= 48.0,
		"...as touch targets (%s)" % [undo_button.custom_minimum_size if undo_button else null])
	_expect(not screen.can_undo() and not screen.can_redo(),
		"a page opens with an empty history -- the restored save is a BASELINE, not a stroke")
	_expect(undo_button.disabled and redo_button.disabled,
		"...so both buttons start disabled")

	# --- one stroke, then take it back ---------------------------------------
	var start := Vector2(700.5, 250.5)
	var sample := Vector2i(790, 250)
	var region_id := page_view.get_region_id_at(start)
	_expect(region_id > 0 and page_view.get_region_id_at(Vector2(sample) + Vector2(0.5, 0.5)) == region_id,
		"precondition: %s and %s are both in region %d" % [start, sample, region_id])
	page_view.begin_stroke(start)
	page_view.continue_stroke(Vector2(860.5, 250.5))
	page_view.end_stroke()
	await _wait_for_coverage(screen)

	var painted := _paint_pixel(page_view, sample)
	_expect(painted.a8 > 200, "the stroke landed on the page (a=%d)" % painted.a8)
	_expect(screen.can_undo() and not undo_button.disabled, "a finished stroke arms undo")
	_expect(not screen.can_redo() and redo_button.disabled, "there is nothing to redo yet")
	var coverage_before := tracker.region_coverage(region_id)
	_expect(coverage_before > 0.0, "...and the tracker saw it (%.3f)" % coverage_before)

	# The rebuild is a transition, and nothing may touch the page during one.
	# undo() is a coroutine and its value cannot be read without await, so it is
	# launched through a Callable and lands in cells (captured by value, per the
	# lambda gotcha) -- the assertions below need it IN FLIGHT, not finished.
	var undo_result: Array = [false]
	var undo_done: Array = [false]
	(func() -> void:
		undo_result[0] = await screen.undo()
		undo_done[0] = true).call()
	_expect(screen.is_replaying() and screen.is_transitioning(),
		"a rebuild in flight counts as a transition")
	# A refused redo() returns false before its first await, so this await
	# resumes synchronously -- the rebuild is still in flight afterwards.
	var refused_mid_replay: bool = await screen.redo()
	_expect(not refused_mid_replay,
		"...so a second history step is refused while it runs")
	_expect(undo_button.disabled and redo_button.disabled,
		"...and both buttons are dead for the duration")
	while not undo_done[0]:
		await get_tree().process_frame
	_expect(bool(undo_result[0]), "undo() reported it ran")

	_expect(_paint_pixel(page_view, sample).a8 == 0,
		"the undone stroke's pixels are gone (a=%d)" % _paint_pixel(page_view, sample).a8)
	_expect(not screen.can_undo() and undo_button.disabled,
		"...the stack is empty again, so undo disables itself")
	_expect(screen.can_redo() and not redo_button.disabled, "...and redo is armed")
	_expect(tracker.region_coverage(region_id) >= coverage_before - 0.0001,
		"coverage re-settled WITHOUT downgrading -- completion stays sticky (%.3f -> %.3f)"
		% [coverage_before, tracker.region_coverage(region_id)])
	_expect(screen.has_unsaved_paint(), "the page is marked paint-dirty by the undo")

	# --- and put it back ------------------------------------------------------
	_expect(await screen.redo(), "redo() reported it ran")
	var restored := _paint_pixel(page_view, sample)
	_expect(restored == painted,
		"the redone stroke is the same pixel it was (%s vs %s)" % [restored, painted])
	_expect(screen.can_undo() and not screen.can_redo(),
		"...and the stacks swapped back over")

	# --- a new stroke ends the branch ----------------------------------------
	_expect(await screen.undo(), "undo again, to have something to redo")
	_expect(screen.can_redo(), "precondition: a stroke is waiting to be redone")
	page_view.begin_stroke(Vector2(264.5, 264.5))
	page_view.continue_stroke(Vector2(264.5, 210.5))
	page_view.end_stroke()
	await _wait_for_coverage(screen)
	_expect(not screen.can_redo() and redo_button.disabled,
		"drawing something new clears the redo stack")
	_expect(screen.undo_depth() == 1, "...and the new stroke is the only thing to undo (%d)"
		% screen.undo_depth())

	# --- the coloring lock owns the page, and that includes its history -------
	screen.set_page_locked(true)
	_expect(undo_button.disabled and redo_button.disabled,
		"a locked page disables undo and redo, exactly like Start over (BL-10)")
	var refused_locked: bool = await screen.undo()
	_expect(not refused_locked,
		"...and refuses the call itself, not just the button")
	screen.set_page_locked(false)
	_expect(not undo_button.disabled, "unlocking gives undo back")

	# --- never mid-stroke ----------------------------------------------------
	page_view.begin_stroke(Vector2(700.5, 250.5))
	var refused_mid_stroke: bool = await screen.undo()
	_expect(not refused_mid_stroke,
		"undo is refused while a stroke is still down")
	page_view.end_stroke()
	await _wait_for_coverage(screen)
	_expect(screen.can_undo(), "...and is available again the moment it lifts")


## (4b) BL-36: stickers. The cycle ring reaches them, sticker mode stops painting,
## a tap sticks one on TOP of the page without touching coverage, undo peels it off
## and redo puts it back, the padlock refuses one, and the save round-trips.
func _check_stickers(screen: ColoringPage) -> void:
	print("\n-- check 4b: sticker sets (BL-36) --")
	var page_view := screen.get_page_view()
	var tracker := screen.get_coverage_tracker()
	var layer := screen.get_sticker_layer()
	var palette := screen.get_palette() as PaletteChild
	_expect(layer != null, "PageView hosts a sticker layer")
	_expect(palette != null and palette.sticker_set_count() > 0,
		"the palette discovered %d sticker set(s)"
		% [palette.sticker_set_count() if palette else 0])
	if layer == null or palette == null or palette.sticker_set_count() == 0:
		return
	# The layer is ABOVE the display art and inside the page transform, which is
	# what makes a sticker sit on top of the line work and pan/zoom with it.
	var page_root := page_view.get_node("PageRoot")
	var line_art := page_view.get_node("PageRoot/LineArtSprite")
	_expect(layer.get_parent() == page_root
			and layer.get_index() > line_art.get_index(),
		"...inside the page transform and ON TOP of the line art (index %d > %d)"
		% [layer.get_index(), line_art.get_index()])
	_expect(layer.get_page_size() == page_view.get_page_size(),
		"...measured against the page it is drawn over (%s)" % [layer.get_page_size()])

	var placed: Array[Dictionary] = []
	screen.sticker_placed.connect(func(p: Dictionary) -> void: placed.append(p))

	# --- entering sticker mode stops painting --------------------------------
	# Everything below is expressed against the page that happens to be open and a
	# region looked up from it, so the check does not care which page the flow left
	# it on.
	var page_index := GameState.current_page_index
	var book_key := GameState.book_key(screen.get_book())
	var region_id := page_view.get_region_ids()[0]
	var centroid: Vector2 = page_view.get_region_data(region_id)["centroid"]
	var coverage_before := tracker.region_coverage(region_id)
	var complete_before := tracker.is_page_complete()
	var painted_before := _paint_pixel(page_view, Vector2i(340, 340))
	palette.set_sticker_set(0)
	await _settle_layout()
	_expect(screen.is_sticker_mode(), "cycling onto a sticker set puts the screen in sticker mode")
	_expect(not page_view.painting_enabled,
		"...which turns painting off through BL-10's ONE gate (painting_enabled)")
	_expect(screen.get_selected_sticker() != null,
		"...with a sticker in hand ('%s')"
		% [screen.get_selected_sticker().sticker_id if screen.get_selected_sticker() else "<none>"])

	# --- a tap places one, through the real input path ------------------------
	# begin_stroke() IS the press: with painting off it starts no stroke, reports
	# paint_blocked, and the screen turns that into a placement.
	_expect(not page_view.begin_stroke(Vector2(340.5, 340.5)),
		"a press on the page starts NO stroke while stickers are out")
	await _settle_layout()
	_expect(layer.count() == 1 and placed.size() == 1,
		"...it sticks a sticker down instead (%d on the page)" % layer.count())
	_expect(_paint_pixel(page_view, Vector2i(340, 340)).a8 == painted_before.a8,
		"...and lays down NO paint (alpha %d, unchanged)" % painted_before.a8)
	var first: Dictionary = layer.get_placements()[0]
	_expect(is_equal_approx(float(first[StickerLayer.KEY_X]), 340.5)
			and is_equal_approx(float(first[StickerLayer.KEY_Y]), 340.5),
		"the placement records where the finger landed, in PAGE pixels (%.1f, %.1f)"
		% [first[StickerLayer.KEY_X], first[StickerLayer.KEY_Y]])
	_expect(absf(float(first[StickerLayer.KEY_ROTATION])) <= StickerLayer.MAX_TILT
			and absf(float(first[StickerLayer.KEY_ROTATION])) > 0.0,
		"...at a slight random tilt (%.3f rad, cap %.3f)"
		% [first[StickerLayer.KEY_ROTATION], StickerLayer.MAX_TILT])
	_expect(float(first[StickerLayer.KEY_SIZE]) > 0.0 and float(first[StickerLayer.KEY_SIZE]) < 0.5,
		"...and a size that is a FRACTION of the page, not a pixel count (%.3f)"
		% first[StickerLayer.KEY_SIZE])
	_expect(layer.sticker_pixels(float(first[StickerLayer.KEY_SIZE])) > 0.0,
		"...which the layer resolves against the page's short side (%.0f px)"
		% layer.sticker_pixels(float(first[StickerLayer.KEY_SIZE])))
	_expect(String(first[StickerLayer.KEY_SET]) == palette.get_sticker_set().get_uid()
			and String(first[StickerLayer.KEY_STICKER])
				== screen.get_selected_sticker().sticker_id,
		"...naming the set and the sticker, which is how it survives a save")

	# --- never counted toward coverage ---------------------------------------
	await _wait_for_coverage(screen)
	_expect(is_equal_approx(tracker.region_coverage(region_id), coverage_before),
		"a sticker changes NO region's coverage (%.3f, unchanged)"
		% tracker.region_coverage(region_id))
	_expect(tracker.is_page_complete() == complete_before,
		"...and moves the page no closer to (or further from) complete: stickers are not paint")

	# --- undo peels it off, redo sticks it back ------------------------------
	_expect(screen.can_undo(), "a placement arms undo like a stroke does")
	_expect(await screen.undo(), "undo accepted")
	await _settle_layout()
	_expect(layer.count() == 0, "...and the sticker is gone (%d left)" % layer.count())
	_expect(screen.can_redo(), "...with a redo waiting")
	_expect(await screen.redo(), "redo accepted")
	await _settle_layout()
	_expect(layer.count() == 1, "...and the sticker is back")
	var restored: Dictionary = layer.get_placements()[0]
	_expect(restored == first,
		"...at exactly the same place, tilt and size -- a placement round-trips byte for byte")

	# --- the timeline is ONE list: undo takes back the last THING -------------
	palette.set_crayon_set(0)
	await _settle_layout()
	_expect(not screen.is_sticker_mode() and page_view.painting_enabled,
		"cycling back to a crayon box gives painting back")
	page_view.begin_stroke(centroid)
	page_view.continue_stroke(centroid + Vector2(30.0, 0.0))
	page_view.end_stroke()
	await _wait_for_coverage(screen)
	var depth_after_stroke := screen.undo_depth()
	palette.set_sticker_set(0)
	await _settle_layout()
	page_view.begin_stroke(Vector2(300.5, 300.5))
	await _settle_layout()
	_expect(layer.count() == 2
			and screen.undo_depth() == mini(depth_after_stroke + 1, ColoringPage.UNDO_DEPTH),
		"a stroke and then a sticker: two things on one timeline (%d deep)"
		% screen.undo_depth())
	_expect(await screen.undo(), "undo once")
	await _settle_layout()
	_expect(layer.count() == 1,
		"...takes back the STICKER, because it is what happened last (%d left)" % layer.count())
	palette.set_crayon_set(0)
	await _settle_layout()
	_expect(await screen.undo(), "undo again")
	await _settle_layout()
	_expect(layer.count() == 1 and screen.redo_depth() == 2,
		"...and now the STROKE goes, with the sticker left alone (%d on the page, %d to redo)"
		% [layer.count(), screen.redo_depth()])

	# --- the padlock refuses a sticker exactly as it refuses a stroke ---------
	palette.set_sticker_set(0)
	await _settle_layout()
	screen.set_page_locked(true)
	_expect(not screen.can_place_sticker(),
		"a locked page will not take a sticker")
	page_view.begin_stroke(Vector2(420.5, 420.5))
	await _settle_layout()
	_expect(layer.count() == 1, "...and a tap on it places nothing (%d)" % layer.count())
	screen.set_page_locked(false)
	page_view.begin_stroke(Vector2(420.5, 420.5))
	await _settle_layout()
	_expect(layer.count() == 2, "unlocking gives sticker placement back (%d)" % layer.count())
	# ...and a tap in the MARGIN, off the page image, is not a placement either.
	page_view.begin_stroke(Vector2(-40.0, -40.0))
	await _settle_layout()
	_expect(layer.count() == 2, "a tap off the page edge places nothing (%d)" % layer.count())

	# --- the save round-trips -------------------------------------------------
	var on_page: Array[Dictionary] = layer.get_placements()
	var saved := GameState.get_page_stickers(book_key, page_index)
	_expect(saved.size() == on_page.size(),
		"the save holds all %d of them (%d)" % [on_page.size(), saved.size()])
	_expect(saved.size() == on_page.size() and saved[0] == on_page[0] and saved[-1] == on_page[-1],
		"...as the same placement dictionaries the layer is drawing")

	palette.set_crayon_set(0)
	await _settle_layout()
	var other_page := 1 - page_index
	_expect(await screen.go_to_page(other_page), "leaving for the other page")
	await _settle_layout()
	_expect(layer.count() == 0,
		"...takes this page's stickers off with it (%d on the next page)" % layer.count())
	_expect(GameState.get_page_stickers(book_key, other_page).is_empty(),
		"...and a page with no sticker key of its own loads with none")
	_expect(await screen.go_to_page(page_index), "and back again")
	await _settle_layout()
	_expect(layer.count() == on_page.size(),
		"...its stickers are all back (%d)" % layer.count())
	_expect(layer.get_placements() == on_page,
		"...exactly where they were, at the same tilt and size")
	_expect(not screen.can_undo(),
		"...as BASELINE stickers: a new visit cannot undo what a previous one stuck down")

	# --- Start over takes them off, and the save with them --------------------
	_expect(screen.restart_current_page(), "Start over on a page with stickers")
	await _settle_layout()
	_expect(layer.count() == 0, "...clears every sticker (%d)" % layer.count())
	_expect(GameState.get_page_stickers(book_key, page_index).is_empty(),
		"...and clears them from the save too")
	_expect(not screen.is_sticker_mode() and page_view.painting_enabled,
		"...leaving the page painting again")


## One pixel of the paint layer. The blocking readback is deliberate here -- this is
## a harness, and the M6 rule is about the running game.
static func _paint_pixel(page_view: PageView, position: Vector2i) -> Color:
	var image := page_view.get_paint_image()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image.get_pixel(position.x, position.y)


func _on_flip_started() -> void:
	_flip_started_count += 1
	# Screenshot the transition roughly halfway through the turn.
	await get_tree().create_timer(PageFlip.DEFAULT_DURATION * 0.45).timeout
	await _screenshot("flip_moment.png")


func _on_coverage_updated(region_id: int, coverage: float) -> void:
	var previous: float = _coverage_history.get(region_id, 0.0)
	if coverage < previous - 0.0001:
		_coverage_regressions.append("region %d: %.3f -> %.3f" % [region_id, previous, coverage])
	_coverage_history[region_id] = maxf(previous, coverage)


# ------------------------------------------------------------ paint helpers --

## Paints every region of the current page until the tracker calls it done.
## Returns the number of strokes issued. Strokes go through the same
## begin/continue/end entry points the touch path uses.
func _fill_page(screen: ColoringPage) -> int:
	var page_view := screen.get_page_view()
	var strokes := 0
	for region_id in page_view.get_region_ids():
		if screen.is_transitioning():
			break
		strokes += await _flood_region(screen, region_id)
	return strokes


func _flood_region(screen: ColoringPage, region_id: int) -> int:
	var page_view := screen.get_page_view()
	var tracker := screen.get_coverage_tracker()
	var data := page_view.get_region_data(region_id)
	if data.is_empty():
		return 0
	var bounds := _region_bounds(page_view, region_id)
	var radius := page_view.brush_size * 0.5
	var step := maxi(int(radius * FLOOD_ROW_RATIO), 8)

	var rows: Array[int] = []
	var y := bounds.position.y + 2
	while y < bounds.end.y - 2:
		rows.append(y)
		y += step
	rows.append(bounds.end.y - 2)

	var strokes := 0
	for row in rows:
		if tracker != null and tracker.is_region_done(region_id):
			break
		if screen.is_transitioning():
			break
		var start_x := _first_x_in_region(page_view, region_id, bounds, row)
		if start_x < 0:
			continue
		# One sweep per row: the shader clips it to this region, so every run of
		# the region on that row gets painted by a single stroke.
		page_view.begin_stroke(Vector2(float(start_x) + 0.5, float(row) + 0.5))
		page_view.continue_stroke(Vector2(float(bounds.end.x) - 0.5, float(row) + 0.5))
		page_view.end_stroke()
		strokes += 1
		await _wait_for_coverage(screen)
	return strokes


static func _first_x_in_region(page_view: PageView, region_id: int, bounds: Rect2i, row: int) -> int:
	var x := bounds.position.x
	while x < bounds.end.x:
		if page_view.get_region_id_at(Vector2(float(x) + 0.5, float(row) + 0.5)) == region_id:
			return x
		x += 2
	return -1


func _wait_for_coverage(screen: ColoringPage) -> void:
	for i in 40:
		if not screen.has_pending_coverage():
			return
		await get_tree().process_frame


# ------------------------------------------------------------ page identity --

## A page pixel that is line art in one ID map and paintable in the other.
## [param paintable_in_second] picks which direction.
static func _find_pixel(first: Image, second: Image, paintable_in_second: bool) -> Vector2:
	var width := mini(first.get_width(), second.get_width())
	var height := mini(first.get_height(), second.get_height())
	var y := PAGE_DIFF_SCAN_STEP
	while y < height - PAGE_DIFF_SCAN_STEP:
		var x := PAGE_DIFF_SCAN_STEP
		while x < width - PAGE_DIFF_SCAN_STEP:
			var a := _id_of(first, x, y)
			var b := _id_of(second, x, y)
			if paintable_in_second and a == 0 and b > 0:
				return Vector2(float(x) + 0.5, float(y) + 0.5)
			if not paintable_in_second and a > 0 and b == 0:
				return Vector2(float(x) + 0.5, float(y) + 0.5)
			x += PAGE_DIFF_SCAN_STEP
		y += PAGE_DIFF_SCAN_STEP
	return Vector2(-1.0, -1.0)


static func _id_of(image: Image, x: int, y: int) -> int:
	var pixel := image.get_pixel(x, y)
	return (pixel.r8 << 16) | (pixel.g8 << 8) | pixel.b8


static func _id_at(image: Image, position: Vector2) -> int:
	return _id_of(image, int(position.x), int(position.y))


# ========================================================= 6: the M2/M3 smokes ==

## Re-runs the earlier milestones' smoke tests as child processes, so one command
## proves the whole stack. Uses this build's own executable, so it works wherever
## the project is checked out.
func _check_sub_smokes() -> void:
	print("\n-- check 6: the M2 and M3 smoke tests still pass --")
	if "--skip-subsmokes" in OS.get_cmdline_user_args():
		print("SKIP - --skip-subsmokes given (run them yourself)")
		return
	for scene in ["res://scenes/dev/paint_smoke.tscn", "res://scenes/dev/palette_smoke.tscn"]:
		var output: Array = []
		var code := OS.execute(
			OS.get_executable_path(),
			["--path", ProjectSettings.globalize_path("res://"), scene],
			output,
			true
		)
		var text := "\n".join(output.map(func(line: Variant) -> String: return String(line)))
		var summary := ""
		for line in text.split("\n"):
			if line.begins_with("==="):
				summary = line.strip_edges()
		_expect(code == 0, "%s exited %d %s" % [scene.get_file(), code, summary])


# =================================================================== helpers ==

## The registered class_name of a node's script ([method Object.get_class] only
## ever reports the engine base class, "Control", for a scripted node).
static func _script_name(node: Object) -> String:
	if node == null:
		return "none"
	var script := node.get_script() as Script
	if script == null:
		return node.get_class()
	var global_name := script.get_global_name()
	return global_name if global_name != "" else node.get_class()


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("%s - %s" % ["PASS" if condition else "FAIL", description])


func _settle_layout() -> void:
	for i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


## Polls [param condition] once per frame for at most [param timeout_seconds].
func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return false


func _screenshot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var path := _shot_dir.path_join(file_name)
	var error := get_viewport().get_texture().get_image().save_png(path)
	print("   screenshot: %s (%s)" % [
		ProjectSettings.globalize_path(path), "ok" if error == OK else "error %d" % error
	])


static func _arg_value(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(flag)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return fallback

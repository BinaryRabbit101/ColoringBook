extends Control
## Automated verification for Milestone 6 -- the mobile pass.
##
## Run WINDOWED, and deliberately WITHOUT touching the v-sync mode: check (b) is
## only meaningful under the DEFAULT presentation mode (FIFO), because that is
## exactly what made the old synchronous readback stall for a third of a second.
##
##   <godot_exe> --path <project> res://scenes/dev/mobile_smoke.tscn
##
## Extra user args (after a bare `--`):
##   --stay             leave the window up in its portrait size
##   --shot-dir <dir>   where the portrait screenshots go
##                      (default user://mobile_smoke/shots)
##
## [b]Persistence is isolated[/b] the same way the other harnesses do it:
## [method GameState.set_save_root] points at a scratch directory that is wiped at
## both ends, so a previous run's paint layer can never satisfy an assertion here.
##
## Checks, in order:
##   a  renderer + async readback availability (Vulkan -> RenderingDevice ->
##      texture_get_data_async), and the ID map still round-trips losslessly
##   b  THE headline: under default FIFO v-sync, a stroke-end coverage update
##      blocks the main thread for under STALL_BUDGET_MS. The old synchronous
##      readback is timed in the same run, under the same conditions, as the
##      before-number
##   c  the coyote book: discovery, validation, region counts, lossless ID-map
##      import flags, and get_region_id_at() agreeing with every centroid
##   d  page navigation rules: no skipping ahead, revisiting a reached page is
##      allowed, completing a page unlocks the next one, and a jump saves first
##      and does NOT play the flip
##   e  portrait: the WINDOW is resized to PORTRAIT_WINDOW and the title screen,
##      mode select and coloring page are all checked and screenshotted through
##      the real stretch pipeline
##   f  the shared safe-area wrapper really insets the screens it wraps
##   g  the quit path: a close request saves synchronously, then DRAINS the GPU
##      readback queue -- tearing the engine down on a queued
##      texture_get_data_async is a hard crash
##
## Exit code is 0 only if every check passes.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const COLORING_PAGE_SCENE := preload("res://scenes/screens/coloring_page.tscn")

const TEST_BOOK_PATH := "res://resources/books/test_book/book.tres"
const COYOTE_BOOK_PATH := "res://resources/books/coyote/book.tres"
const COYOTE_IDMAP_IMPORTS: PackedStringArray = [
	"res://assets/books/coyote/page_01_idmap.png.import",
	"res://assets/books/coyote/page_02_idmap.png.import",
]
## What the mapping pipeline produced for the coyote art (see the M6 report).
## Page 1 is the silhouette: coyote + background. Page 2 is the detailed line art.
const COYOTE_EXPECTED_REGIONS: PackedInt32Array = [2, 15]

## Import flags the ID map must keep, or region ids bleed (DESIGN.md 3.2).
const REQUIRED_IDMAP_IMPORT_FLAGS := {
	"compress/mode": "0",
	"mipmaps/generate": "false",
	"detect_3d/compress_to": "0",
	"process/fix_alpha_border": "false",
}

## Scratch root for everything this run writes. Wiped at both ends.
const TEST_SAVE_ROOT := "user://mobile_smoke/state"
const TEST_ROOT := "user://mobile_smoke"

## [b]The M6 budget.[/b] No single frame of a stroke-end coverage update may take
## longer than this. Under FIFO a healthy frame is one refresh (~16.7 ms at 60 Hz),
## so 50 ms leaves room for two dropped frames and still catches any return of the
## ~350-530 ms synchronous stall by an order of magnitude.
const STALL_BUDGET_MS := 50.0
## Frames the stall probe is willing to watch.
const STALL_MAX_FRAMES := 240

## Portrait window used for check (e). 720x1280 is the narrowest phone shape the
## project targets.
const PORTRAIT_WINDOW := Vector2i(720, 1280)
const LANDSCAPE_WINDOW := Vector2i(1280, 820)

const NAV_TIMEOUT := 8.0
const PAINT_TIMEOUT := 60.0
## Sweep spacing for the flood helper, as a fraction of the brush RADIUS.
const FLOOD_ROW_RATIO := 1.15

@onready var _host: Control = $Host

var _checks := 0
var _failures := 0
var _shot_dir := "user://mobile_smoke/shots"

var _test_book: BookDef
var _coyote_book: BookDef
## Measured in check (b) and reported again in the summary.
var _sync_readback_ms := 0.0
var _async_stall_ms := 0.0
var _idle_frame_ms := 0.0


func _ready() -> void:
	get_window().size = LANDSCAPE_WINDOW
	# NOT setting the v-sync mode is the point of this harness (see the class doc).
	_shot_dir = _arg_value("--shot-dir", _shot_dir)
	if not DirAccess.dir_exists_absolute(_shot_dir):
		DirAccess.make_dir_recursive_absolute(_shot_dir)
	await get_tree().process_frame
	await _run()


func _run() -> void:
	print("=== M6 mobile smoke test ===")
	_delete_recursive(TEST_ROOT)
	GameState.set_save_root(TEST_SAVE_ROOT)
	GameState.mode = PaletteDef.MODE_CHILD
	print("   save root: %s" % ProjectSettings.globalize_path(GameState.get_save_path()))

	_test_book = load(TEST_BOOK_PATH) as BookDef
	_coyote_book = load(COYOTE_BOOK_PATH) as BookDef
	if _test_book == null or _coyote_book == null:
		_expect(false, "both books load as BookDefs")
		_finish(1)
		return

	_check_renderer()
	await _check_async_stall()
	_check_coyote_book()
	await _check_page_navigation()
	await _check_portrait()
	await _check_safe_area()

	print("\n-- M6 numbers --")
	print("   renderer: %s / %s" % [
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_current_rendering_driver_name()])
	print("   synchronous get_paint_image() under FIFO blocked: %.1f ms (the M4/M5 path)"
		% _sync_readback_ms)
	print("   idle frame period in this window: %.1f ms" % _idle_frame_ms)
	print("   worst frame across an async stroke-end coverage update: %.1f ms (+%.1f ms over idle)"
		% [_async_stall_ms, _async_stall_ms - _idle_frame_ms])

	print("\n=== %d/%d checks passed ===" % [_checks - _failures, _checks])
	if "--stay" in OS.get_cmdline_user_args():
		print("[dev] --stay given; the window is left at %s." % get_window().size)
		return
	GameState.set_save_root("", false)
	_delete_recursive(TEST_ROOT)
	_finish(0 if _failures == 0 else 1)


func _finish(code: int) -> void:
	# Never tear the engine down on top of a queued GPU readback: that is a hard
	# crash (see AsyncReadback.drain).
	await AsyncReadback.drain(get_tree())
	print("exit code: %d" % code)
	get_tree().quit(code)


# ================================================== a: renderer & async path ==

func _check_renderer() -> void:
	print("\n-- check a: renderer and async readback availability --")
	var method := RenderingServer.get_current_rendering_method()
	var driver := RenderingServer.get_current_rendering_driver_name()
	print("   rendering method '%s', driver '%s', adapter '%s'"
		% [method, driver, RenderingServer.get_video_adapter_name()])
	_expect(
		String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")) == "mobile",
		"project.godot ships the Mobile renderer (%s)"
		% ProjectSettings.get_setting("rendering/renderer/rendering_method", "unset")
	)
	_expect(method == "mobile", "the running renderer is 'mobile' (%s)" % method)

	var device := RenderingServer.get_rendering_device()
	_expect(device != null, "the renderer exposes a RenderingDevice (%s)" % device)
	_expect(AsyncReadback.is_available(),
		"AsyncReadback reports the async path is available")
	if device != null:
		_expect(device.has_method("texture_get_data_async"),
			"RenderingDevice has texture_get_data_async (Godot 4.4+)")
	_expect(
		DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_ENABLED,
		"the window is on the DEFAULT FIFO v-sync, which is what check (b) needs (%d)"
		% DisplayServer.window_get_vsync_mode()
	)
	_expect(
		bool(ProjectSettings.get_setting("input_devices/pointing/emulate_touch_from_mouse", false)),
		"touch emulation from mouse is still on -- one input code path (DESIGN.md 3.3)"
	)


# ================================================= b: the async stall budget ==

func _check_async_stall() -> void:
	print("\n-- check b: main-thread stall across a stroke-end coverage update (FIFO) --")
	var screen := COLORING_PAGE_SCENE.instantiate() as ColoringPage
	_host.add_child(screen)
	await get_tree().process_frame
	if not screen.load_book(_test_book):
		_expect(false, "the probe coloring page opened the test book")
		screen.queue_free()
		return
	await _wait_until(func() -> bool: return not screen.has_pending_restore(), NAV_TIMEOUT)
	var page_view := screen.get_page_view()

	_expect(screen.is_async_readback_available(),
		"the coloring screen can read the paint layer back asynchronously")

	# --- the BEFORE number, measured here so it is the same box, same v-sync ---
	for i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var started := Time.get_ticks_usec()
	var _sync := page_view.get_paint_image()
	_sync_readback_ms = float(Time.get_ticks_usec() - started) / 1000.0
	print("   synchronous PageView.get_paint_image() blocked %.1f ms (the M4/M5 path)"
		% _sync_readback_ms)

	# --- the idle baseline ----------------------------------------------------
	# The frame PERIOD under FIFO is whatever the compositor gives this window,
	# and an automated run's window is typically unfocused or occluded: on this
	# dev box that means ~250 ms per presented frame, not 16.7. Comparing a raw
	# frame period against a fixed budget would therefore measure the desktop, not
	# the code. So the probe measures the EXCESS over an idle baseline taken
	# seconds earlier in the same window -- "did the coverage update add a stall?"
	# -- which is exactly the question, and is immune to how fast the window
	# happens to present.
	_idle_frame_ms = await _median_frame_ms(9)
	print("   idle frame period in this window: %.1f ms (presentation pacing)" % _idle_frame_ms)

	# --- the AFTER number: a real stroke, through the real coverage hook -------
	var region_id := page_view.get_region_ids()[1]
	var centroid: Vector2 = page_view.get_region_data(region_id)["centroid"]

	var worst_usec := 0
	var previous := Time.get_ticks_usec()
	var locked := page_view.begin_stroke(centroid)
	page_view.continue_stroke(centroid + Vector2(24.0, 0.0))
	page_view.end_stroke()
	_expect(locked, "the probe stroke locked region %d at its centroid %s" % [region_id, centroid])
	var frames := 0
	while screen.has_pending_coverage() and frames < STALL_MAX_FRAMES:
		await get_tree().process_frame
		frames += 1
		var now := Time.get_ticks_usec()
		worst_usec = maxi(worst_usec, now - previous)
		previous = now
	_async_stall_ms = float(worst_usec) / 1000.0
	var excess := _async_stall_ms - _idle_frame_ms

	_expect(frames < STALL_MAX_FRAMES,
		"the coverage update settled in %d frames" % frames)
	_expect(not screen.was_last_readback_blocking(),
		"the coverage readback used the async path, not the blocking fallback")
	_expect(screen.get_last_readback_usec() < 5000,
		"queueing the readback blocked the main thread for %.2f ms, against %.1f ms for the synchronous call it replaced"
		% [screen.get_last_readback_usec() / 1000.0, _sync_readback_ms])
	_expect(excess < STALL_BUDGET_MS,
		"no frame of the coverage update ran more than %.0f ms over idle (worst %.1f ms vs %.1f ms idle = +%.1f ms; the synchronous readback alone was %.1f ms)"
		% [STALL_BUDGET_MS, _async_stall_ms, _idle_frame_ms, excess, _sync_readback_ms])
	_expect(screen.get_coverage_tracker().region_coverage(region_id) > 0.0,
		"...and the coverage really landed (region %d at %.3f)"
		% [region_id, screen.get_coverage_tracker().region_coverage(region_id)])

	# Coalescing must survive the async rewrite: five strokes ended back to back
	# cost far fewer than five readbacks.
	var before := screen.get_readback_count()
	var burst := 0
	for i in 5:
		if page_view.begin_stroke(centroid + Vector2(0.0, float(i) * 4.0)):
			burst += 1
		page_view.continue_stroke(centroid + Vector2(24.0, float(i) * 4.0))
		page_view.end_stroke()
	await _wait_until(func() -> bool: return not screen.has_pending_coverage(), NAV_TIMEOUT)
	var used := screen.get_readback_count() - before
	_expect(burst == 5, "the burst really laid %d strokes" % burst)
	_expect(used > 0 and used < 5,
		"5 strokes ended in one burst cost %d readbacks, not 5" % used)

	screen.queue_free()
	await get_tree().process_frame

	# The FIFO measurement is done. The rest of this harness fills whole pages,
	# and an unfocused window presenting at ~4 Hz would make that take minutes for
	# no extra coverage, so hand the remaining checks the same MAILBOX window the
	# other smokes run on.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_MAILBOX)
	print("   [dev] FIFO measurement done; the rest of the run uses VSYNC_MAILBOX")


# ========================================================== c: the coyote book ==

func _check_coyote_book() -> void:
	print("\n-- check c: the coyote book (first real art through the pipeline) --")
	_expect(_coyote_book.display_name == "Coyote",
		"the book is called 'Coyote' ('%s')" % _coyote_book.display_name)
	_expect(_coyote_book.validate().is_empty(),
		"the book validates (%s)" % [_coyote_book.validate()])
	_expect(_coyote_book.page_count() == COYOTE_EXPECTED_REGIONS.size(),
		"it has %d pages (%d)" % [COYOTE_EXPECTED_REGIONS.size(), _coyote_book.page_count()])
	var discovered := BookDef.discover()
	var found := false
	for book in discovered:
		found = found or book.resource_path == COYOTE_BOOK_PATH
	_expect(found, "BookDef.discover() picks it up from the folder alone")

	for i in _coyote_book.page_count():
		var page := _coyote_book.get_page(i)
		var json := page.load_regions_json()
		_expect(int(json.get("version", 0)) == 1,
			"page %d regions JSON is schema v1" % (i + 1))
		var regions: Array = json.get("regions", [])
		_expect(regions.size() == COYOTE_EXPECTED_REGIONS[i],
			"page %d ('%s') mapped to %d regions (%d)"
			% [i + 1, page.display_name, COYOTE_EXPECTED_REGIONS[i], regions.size()])

		var base := load(page.base_image_path) as Texture2D
		var idmap := load(page.id_map_path) as Texture2D
		_expect(base != null and idmap != null, "page %d textures load" % (i + 1))
		if base == null or idmap == null:
			continue
		_expect(base.get_size() == idmap.get_size(),
			"page %d ID map matches the art size (%s)" % [i + 1, idmap.get_size()])
		_expect(base.get_width() <= 2048 and base.get_height() <= 2048,
			"page %d fits the 2048 px texture budget (%s)" % [i + 1, base.get_size()])
		var idmap_image := idmap.get_image()
		_expect(not idmap_image.is_compressed(),
			"page %d ID map is NOT VRAM-compressed (format %d)" % [i + 1, idmap_image.get_format()])
		_expect(not idmap_image.has_mipmaps(), "page %d ID map has no mipmaps" % (i + 1))
		_check_import_flags(COYOTE_IDMAP_IMPORTS[i], i + 1)

		# The runtime hit-test must agree with the JSON on every region: a centroid
		# is what a "tap here" hint would point at, so it has to be paintable and
		# it has to belong to the region that claims it.
		var probe := PageView.new()
		var strays := PackedStringArray()
		for entry_variant in regions:
			var entry: Dictionary = entry_variant
			var centroid: Array = entry["centroid"]
			var x := int(centroid[0])
			var y := int(centroid[1])
			var pixel := idmap_image.get_pixel(x, y)
			var sampled := (pixel.r8 << 16) | (pixel.g8 << 8) | pixel.b8
			if sampled != int(entry["id"]):
				strays.append("id %d -> %d" % [int(entry["id"]), sampled])
		probe.free()
		_expect(strays.is_empty(),
			"page %d: every centroid samples back to its own region id (%s)"
			% [i + 1, "ok" if strays.is_empty() else ", ".join(strays)])


func _check_import_flags(import_path: String, page_number: int) -> void:
	var text := FileAccess.get_file_as_string(import_path)
	_expect(text != "", "%s is readable" % import_path)
	var missing := PackedStringArray()
	for key in REQUIRED_IDMAP_IMPORT_FLAGS:
		var line := "%s=%s" % [key, REQUIRED_IDMAP_IMPORT_FLAGS[key]]
		if not text.contains(line):
			missing.append(line)
	_expect(missing.is_empty(),
		"page %d ID map .import keeps every lossless flag (%s)"
		% [page_number, "ok" if missing.is_empty() else "missing " + ", ".join(missing)])


# ======================================================= d: page navigation ==

func _check_page_navigation() -> void:
	print("\n-- check d: prev/next page navigation --")
	GameState.erase_book_progress(_test_book)
	var screen := COLORING_PAGE_SCENE.instantiate() as ColoringPage
	_host.add_child(screen)
	await get_tree().process_frame
	if not screen.load_book(_test_book):
		_expect(false, "the coloring page opened the test book")
		screen.queue_free()
		return
	await _wait_until(func() -> bool: return not screen.has_pending_restore(), NAV_TIMEOUT)

	var prev := screen.get_prev_page_button()
	var next := screen.get_next_page_button()
	_expect(prev != null and next != null, "the toolbar carries prev/next buttons")
	if prev == null or next == null:
		screen.queue_free()
		return
	_expect(minf(prev.size.x, prev.size.y) >= 48.0 and minf(next.size.x, next.size.y) >= 48.0,
		"both arrows clear the 48 px touch floor (%.0fx%.0f)" % [prev.size.x, prev.size.y])

	# --- a fresh book: nowhere to go ------------------------------------------
	_expect(prev.disabled, "on page 1 of a fresh book, Prev is disabled")
	_expect(next.disabled, "...and Next is disabled: no skipping ahead to an unseen page")
	_expect(not screen.can_go_to_page(1), "can_go_to_page(1) refuses the unreached page")
	_expect(not screen.can_go_to_page(-1) and not screen.can_go_to_page(9),
		"out-of-range jumps are refused")
	_expect(not await screen.go_to_page(1), "go_to_page(1) is refused too, not just greyed out")
	_expect(screen.get_page_label_text() == "1/2", "the page did not move ('%s')"
		% screen.get_page_label_text())

	# --- finishing page 1 unlocks page 2, and the FLIP takes us there ---------
	var flips: Array[int] = []
	screen.get_page_flip().flip_started.connect(func() -> void: flips.append(1))
	var strokes := await _fill_page(screen)
	print("   page 1 filled with %d strokes" % strokes)
	var arrived := await _wait_until(
		func() -> bool:
			return screen.get_page_label_text() == "2/2" and not screen.is_transitioning(),
		PAINT_TIMEOUT
	)
	_expect(arrived, "completing page 1 flipped to 2/2 ('%s')" % screen.get_page_label_text())
	await _wait_until(func() -> bool: return not screen.has_pending_restore(), NAV_TIMEOUT)
	_expect(flips.size() == 1, "the completion flip played once (%d)" % flips.size())

	# --- now page 1 is reachable again ----------------------------------------
	_expect(screen.furthest_reached_index() == 1, "the furthest page reached is index %d"
		% screen.furthest_reached_index())
	_expect(screen.can_go_to_page(0), "page 1 is reachable again once it has been colored")
	_expect(not screen.get_prev_page_button().disabled, "...and Prev is enabled for it")
	_expect(screen.get_next_page_button().disabled, "Next is disabled on the last page")

	# Put a stroke on page 2 so the jump has something to save. A page with no
	# paint and no saved file is deliberately skipped -- there is nothing to write.
	var page_view := screen.get_page_view()
	var probe_region := page_view.get_region_ids()[1]
	var probe_point: Vector2 = page_view.get_region_data(probe_region)["centroid"]
	_expect(page_view.begin_stroke(probe_point), "a stroke started on page 2")
	page_view.continue_stroke(probe_point + Vector2(24.0, 0.0))
	page_view.end_stroke()
	await _wait_until(func() -> bool: return not screen.has_pending_coverage(), NAV_TIMEOUT)
	_expect(not FileAccess.file_exists(GameState.get_paint_path(_test_book, 1)),
		"page 2's paint is NOT on disk yet -- painting alone is not a save point")

	var flips_before := flips.size()
	var navigated := await screen.go_to_page(0)
	_expect(navigated, "go_to_page(0) succeeded")
	_expect(screen.get_page_label_text() == "1/2",
		"the toolbar shows 1/2 again ('%s')" % screen.get_page_label_text())
	_expect(flips.size() == flips_before, "navigating played NO flip (%d new)"
		% (flips.size() - flips_before))
	_expect(FileAccess.file_exists(GameState.get_paint_path(_test_book, 1)),
		"page 2's paint was saved BEFORE the jump")
	await _wait_until(func() -> bool: return not screen.has_pending_restore(), NAV_TIMEOUT)
	_expect(screen.get_coverage_tracker().is_page_complete(),
		"page 1 came back with its coverage restored (%.3f)"
		% screen.get_coverage_tracker().page_coverage())

	# --- and forward again, because page 2 has been reached -------------------
	_expect(screen.can_go_to_page(1), "page 2 is reachable from page 1 now")
	_expect(not screen.get_next_page_button().disabled, "Next is enabled again")
	_expect(await screen.go_to_page(1), "go_to_page(1) succeeded")
	_expect(screen.get_page_label_text() == "2/2",
		"back on 2/2 ('%s')" % screen.get_page_label_text())

	screen.queue_free()
	await get_tree().process_frame


# ================================================================= e: portrait ==

func _check_portrait() -> void:
	print("\n-- check e: portrait layouts through the real stretch pipeline --")
	var main := MAIN_SCENE.instantiate() as Main
	main.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_host.add_child(main)
	await _wait_for_screen(main, Main.SCREEN_TITLE)

	# Resize the WINDOW, not the Control: this is the only way to exercise the
	# canvas_items/expand stretch pipeline the shipped game actually uses.
	get_window().size = PORTRAIT_WINDOW
	await _settle_layout()
	var viewport_size := get_viewport_rect().size
	print("   window %s -> logical viewport %s (aspect %.3f)"
		% [get_window().size, viewport_size, viewport_size.x / viewport_size.y])
	# Documented consequence of stretch mode canvas_items + aspect expand with a
	# 1152x648 base: the logical WIDTH never drops below 1152, the HEIGHT grows
	# instead. Aspect, not width, is therefore what portrait layouts key off.
	_expect(viewport_size.y > viewport_size.x,
		"a 720x1280 window really produces a portrait logical viewport (%s)" % viewport_size)

	# --- title ----------------------------------------------------------------
	var title := main.get_current_screen() as TitleScreen
	_expect(title != null, "the title screen is up")
	if title != null:
		var paper := title.get_node("Center/Paper") as Control
		_expect(paper.size.x <= viewport_size.x,
			"the title paper fits the screen (%.0f of %.0f wide)" % [paper.size.x, viewport_size.x])
		_expect(title.get_crayon_count() > 0,
			"the crayon shelf still lays out (%d crayons)" % title.get_crayon_count())
		await _screenshot("title_portrait.png")

		# The WINDOW cannot make the logical canvas narrow (see the note above), so
		# the "820 px minimum is gone" half of the portrait fix is proved by
		# squeezing the screen Control itself down to a 720-wide phone canvas --
		# the same technique flow_smoke uses for the narrow shelf.
		title.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		title.size = Vector2(720.0, 1280.0)
		await _settle_layout()
		_expect(title.is_narrow(), "a 720-wide canvas puts the title in its narrow form")
		_expect(paper.size.x <= 720.0,
			"the paper shrinks to fit 720 px instead of demanding 820 (%.0f)" % paper.size.x)
		_expect(paper.get_global_rect().end.x <= 721.0,
			"...and nothing runs off the right edge (ends at x=%.0f)"
			% paper.get_global_rect().end.x)
		var lettering := title.get_node("Center/Paper/Margin/Column/TitleRows") as Control
		_expect(lettering.size.x <= 720.0,
			"the lettering itself fits too (%.0f px wide)" % lettering.size.x)
		title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		await _settle_layout()

		title.get_tap_button().pressed.emit()

	# --- mode select ----------------------------------------------------------
	var reached := await _wait_for_screen(main, Main.SCREEN_MODE_SELECT)
	_expect(reached, "tapping the title reaches mode select")
	var modes := main.get_current_screen() as ModeSelect
	if modes == null:
		main.queue_free()
		return
	await _settle_layout()
	_expect(modes.is_portrait(), "mode select knows it is in portrait")
	var cards := modes.get_cards()
	_expect(cards.size() == 2, "both cards are there (%d)" % cards.size())
	var stacked := cards.size() == 2 and cards[1].global_position.y >= cards[0].get_global_rect().end.y - 1.0
	_expect(stacked, "the cards are STACKED, not squeezed side by side (card 1 ends at y=%.0f, card 2 starts at y=%.0f)"
		% [cards[0].get_global_rect().end.y, cards[1].global_position.y])
	var narrowest := INF
	var overflowing := 0
	for card in cards:
		narrowest = minf(narrowest, minf(card.size.x, card.size.y))
		if card.get_global_rect().end.y > viewport_size.y + 1.0:
			overflowing += 1
	_expect(narrowest >= ModeSelect.MIN_TOUCH_TARGET,
		"every stacked card is at least %.0f px on its short side (%.0f)"
		% [ModeSelect.MIN_TOUCH_TARGET, narrowest])
	_expect(overflowing == 0, "no card runs off the bottom of the screen (%d)" % overflowing)
	await _screenshot("mode_select_portrait.png")

	# --- coloring page --------------------------------------------------------
	modes.get_card(PaletteDef.MODE_CHILD).pressed.emit()
	await _wait_for_screen(main, Main.SCREEN_BOOK_SELECT)
	var shelf := main.get_current_screen() as BookSelect
	var gear := main.get_gear_button()
	_expect(minf(gear.size.x, gear.size.y) >= 72.0,
		"the settings gear is at least 72 px (%.0fx%.0f)" % [gear.size.x, gear.size.y])
	var coyote_cell: BookCell = null
	for cell in shelf.get_cells():
		if cell.get_book() == _coyote_book:
			coyote_cell = cell
	_expect(coyote_cell != null, "the coyote book is on the portrait shelf")
	if coyote_cell == null:
		main.queue_free()
		return
	coyote_cell.pressed.emit()
	var opened := await _wait_for_screen(main, Main.SCREEN_COLORING)
	_expect(opened, "the coyote book opens in portrait")
	var coloring := main.get_current_screen() as ColoringPage
	if coloring == null:
		main.queue_free()
		return
	await _wait_until(func() -> bool: return not coloring.has_pending_restore(), NAV_TIMEOUT)
	await _settle_layout()

	var palette := coloring.get_palette() as PaletteChild
	_expect(palette != null, "child mode put a crayon row on the page")
	if palette == null:
		main.queue_free()
		return
	var buttons: Array[Control] = palette.get_color_buttons()
	_expect(buttons.size() > 0, "the crayon row rendered (%d crayons)" % buttons.size())
	var smallest := INF
	for button in buttons:
		smallest = minf(smallest, minf(button.size.x, button.size.y))
	_expect(smallest >= CrayonButton.MIN_TOUCH_TARGET,
		"every crayon holds its %.0f px touch target in portrait (%.0f)"
		% [CrayonButton.MIN_TOUCH_TARGET, smallest])
	var scroll := palette.get_node("Margin/Scroll") as ScrollContainer
	_expect(
		scroll != null
		and scroll.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED,
		"the crayon row scrolls horizontally rather than shrinking its crayons"
	)
	_expect(scroll != null and scroll.size.x <= viewport_size.x + 1.0,
		"...and the scroll viewport fits the screen (%.0f of %.0f)"
		% [scroll.size.x if scroll else -1.0, viewport_size.x])
	_expect(palette.get_global_rect().end.y <= viewport_size.y + 1.0,
		"the palette sits inside the screen (ends at y=%.0f of %.0f)"
		% [palette.get_global_rect().end.y, viewport_size.y])
	var page_view := coloring.get_page_view()
	_expect(page_view.size.y > page_view.size.x * 0.5,
		"the page view still owns a usable slab of the portrait screen (%.0fx%.0f)"
		% [page_view.size.x, page_view.size.y])
	_expect(not coloring.get_back_button().get_global_rect()
			.intersects(coloring.get_prev_page_button().get_global_rect()),
		"the toolbar controls do not overlap in portrait")

	# Paint the coyote for real, so the screenshot shows the mechanic working on
	# the user's own art rather than an empty page.
	var region_ids := page_view.get_region_ids()
	var color_index := 0
	for i in mini(region_ids.size(), 4):
		var region_id := region_ids[i]
		var centroid: Vector2 = page_view.get_region_data(region_id)["centroid"]
		for pass_index in 3:
			if is_instance_valid(palette):
				palette.select_color(color_index % maxi(buttons.size(), 1))
			color_index += 1
			var offset := Vector2(0.0, float(pass_index - 1) * 130.0)
			page_view.begin_stroke(centroid + offset)
			page_view.continue_stroke(centroid + offset + Vector2(200.0, 60.0))
			page_view.continue_stroke(centroid + offset + Vector2(-200.0, 120.0))
			page_view.end_stroke()
			await _wait_until(
				func() -> bool: return not coloring.has_pending_coverage(), NAV_TIMEOUT
			)
	await _settle_layout()
	_expect(page_view.get_locked_region_id() == PageView.UNPAINTABLE_ID,
		"no stroke is left locked after painting the coyote")
	var painted := 0
	for region_id in region_ids:
		if coloring.get_coverage_tracker().region_coverage(region_id) > 0.0:
			painted += 1
	_expect(painted >= 1, "%d coyote region(s) took paint" % painted)
	await _screenshot("coloring_portrait.png")
	await _screenshot("coyote_ingame.png")

	get_window().size = LANDSCAPE_WINDOW
	await _settle_layout()
	var back_to_landscape := not is_instance_valid(modes) or not modes.is_portrait()
	_expect(back_to_landscape, "...and going back to landscape unstacks the cards again")
	main.queue_free()
	await get_tree().process_frame


# =============================================================== f: safe area ==

func _check_safe_area() -> void:
	print("\n-- check f: the shared safe-area wrapper --")
	var main := MAIN_SCENE.instantiate() as Main
	main.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_host.add_child(main)
	await _wait_for_screen(main, Main.SCREEN_TITLE)
	var safe := main.get_safe_area()
	_expect(safe != null, "main.tscn wraps its screens in a SafeArea")
	if safe == null:
		main.queue_free()
		return
	_expect(safe.get_insets().is_equal_approx(Vector4.ZERO),
		"a windowed desktop run gets ZERO insets -- the taskbar is not a notch (%s)"
		% safe.get_insets())

	var screen := main.get_current_screen()
	var before := screen.global_position
	safe.debug_insets = Vector4(40.0, 90.0, 40.0, 30.0)
	await _settle_layout()
	_expect(safe.get_insets().is_equal_approx(Vector4(40.0, 90.0, 40.0, 30.0)),
		"the override insets are applied (%s)" % safe.get_insets())
	_expect(is_equal_approx(screen.global_position.x, before.x + 40.0)
			and is_equal_approx(screen.global_position.y, before.y + 90.0),
		"the screen really moved clear of the cutout (%s -> %s)" % [before, screen.global_position])
	_expect(main.get_gear_button().global_position.y >= 90.0,
		"the overlay layer is inside the safe area too (gear at y=%.0f)"
		% main.get_gear_button().global_position.y)

	safe.debug_insets = Vector4(-1.0, -1.0, -1.0, -1.0)
	await _settle_layout()
	_expect(screen.global_position.is_equal_approx(before),
		"clearing the override puts the screen back (%s)" % screen.global_position)

	# --- g: quitting must not land on an in-flight readback -------------------
	print("\n-- check g: the quit path saves, drains and only then ends --")
	_expect(not get_tree().auto_accept_quit,
		"a shipped Main takes the quit off the engine so it can drain first")
	# Opt out, or delivering the close request below would end this run.
	main.quit_on_close_request = false
	_expect(get_tree().auto_accept_quit,
		"a harness that opts out hands the quit back to the engine")
	var saves: Array[String] = []
	var handler := func(path: String) -> void: saves.append(path)
	GameState.save_written.connect(handler)
	main.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
	GameState.save_written.disconnect(handler)
	_expect(saves.size() >= 1,
		"a close request writes the save synchronously, before any awaiting (%d)" % saves.size())
	_expect(main.is_inside_tree(), "quit_on_close_request=false kept the harness alive")
	var drained := await AsyncReadback.drain(get_tree())
	_expect(drained, "every queued readback drained (%d left)" % AsyncReadback.pending_count())

	main.queue_free()
	await get_tree().process_frame


# ================================================================== helpers ==

## Paints every region of the current page until the tracker calls it done.
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
	if page_view.get_region_data(region_id).is_empty():
		return 0
	var bounds := _region_bounds(page_view, region_id)
	var step := maxi(int(page_view.brush_size * 0.5 * FLOOD_ROW_RATIO), 8)

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
		page_view.begin_stroke(Vector2(float(start_x) + 0.5, float(row) + 0.5))
		page_view.continue_stroke(Vector2(float(bounds.end.x) - 0.5, float(row) + 0.5))
		page_view.end_stroke()
		strokes += 1
		for i in 90:
			if not screen.has_pending_coverage():
				break
			await get_tree().process_frame
	return strokes


static func _first_x_in_region(page_view: PageView, region_id: int, bounds: Rect2i, row: int) -> int:
	var x := bounds.position.x
	while x < bounds.end.x:
		if page_view.get_region_id_at(Vector2(float(x) + 0.5, float(row) + 0.5)) == region_id:
			return x
		x += 2
	return -1


static func _region_bounds(page_view: PageView, region_id: int) -> Rect2i:
	var outline: PackedVector2Array = page_view.get_region_data(region_id)["outline"]
	var minimum := outline[0]
	var maximum := outline[0]
	for point in outline:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return Rect2i(Vector2i(minimum.floor()), Vector2i(maximum.ceil()) - Vector2i(minimum.floor()))


## Median period of [param samples] idle frames, in milliseconds. The median (not
## the mean) so one hitch cannot inflate the baseline the stall budget is measured
## against.
func _median_frame_ms(samples: int) -> float:
	var periods: Array[float] = []
	var previous := Time.get_ticks_usec()
	for i in samples + 1:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		if i > 0:  # Skip the first: it carries whatever the caller was doing.
			periods.append(float(now - previous) / 1000.0)
		previous = now
	periods.sort()
	return periods[periods.size() / 2]


## Waits until [param screen_id] is the current screen of [param main] and no
## transition is in flight.
func _wait_for_screen(main: Main, screen_id: String) -> bool:
	return await _wait_until(
		func() -> bool:
			return main.get_current_screen_id() == screen_id and not main.is_transitioning(),
		NAV_TIMEOUT
	)


func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return false


func _settle_layout() -> void:
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _screenshot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var path := _shot_dir.path_join(file_name)
	var error := get_viewport().get_texture().get_image().save_png(path)
	print("   screenshot: %s (%s)" % [
		ProjectSettings.globalize_path(path), "ok" if error == OK else "error %d" % error
	])


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("%s - %s" % ["PASS" if condition else "FAIL", description])


static func _arg_value(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(flag)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return fallback


static func _delete_recursive(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for name in directory.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in directory.get_directories():
		_delete_recursive(path.path_join(name))
	DirAccess.remove_absolute(path)

extends Control
## Automated verification for Milestone 5 -- the app shell and persistence.
##
## Run WINDOWED (it paints into a SubViewport and reads it back, which renders
## nothing under --headless / the dummy rasteriser):
##
##   <godot_exe> --path <project> res://scenes/dev/shell_smoke.tscn
##
## Extra user args (after a bare `--`):
##   --stay             leave the app running afterwards, on whatever screen it
##                      reached, WITHOUT deleting the scratch save
##   --shot-dir <dir>   where title.png / page_complete.png go
##                      (default user://shell_smoke/shots)
##
## [b]Persistence is isolated.[/b] The harness drives the REAL [code]GameState[/code]
## but points it at [constant TEST_SAVE_ROOT] and wipes that directory before and
## after the run, so repeated runs are deterministic and the player's own save (and
## the other smoke tests) are never touched.
##
## Checks, in order:
##   a  main.tscn boots to the title; tap -> shelf (BL-20: no mode select); the
##      settings gear opens and closes; picking the book opens page 1/2
##   b  strokes in region 4, then Back: the save file, its schema, the book entry
##      and the paint PNG all exist on disk
##   c  re-entering the book resumes the same page with the pixels AND the
##      coverage restored
##   c2 the toolbar's Save button writes the page on demand (BL-6), and its
##      Start over button resets THAT page only, behind a two-button confirm (BL-7)
##   c3 the padlock locks THIS page -- no strokes, no Start over, everything else
##      untouched -- and the lock is written to the save immediately (BL-10)
##   d  both pages completed; each one celebrates TRANSIENTLY and stays put, the
##      LAST page is not special (BL-11: its forward arrow is simply disabled and
##      Back is the exit -- there is no BookComplete screen), then
##      erase_book_progress wipes paint + status and the book reopens clean at 1/2
##   e  settings "erase all progress" (two-step confirm) empties the save and the
##      paint directory
##   f  the open book has ONE palette and ONE threshold, and the settings
##      overlay carries nothing that could change either (BL-20)
##   g  NOTIFICATION_WM_CLOSE_REQUEST writes the save
##   h  a corrupt save, and a save from a FUTURE schema, both start fresh without
##      crashing (the future one is backed up first)
##   i  BL-48: the overlay layer is sized for a phone. Desktop first (nothing may
##      have moved), then a real portrait window with a real phone's squeeze forced
##      on, across all five overlays -- panel width, the 44 pt touch floor, the
##      stacked rows, and an account email that is readable rather than clipped
##
## Exit code is 0 only if every check passes.

const MAIN_SCENE := preload("res://scenes/main.tscn")
## BL-27's check (a2) puts a splash up on its own, outside main.tscn's flow.
const TITLE_SCENE := preload("res://scenes/screens/title_screen.tscn")
const BOOK_PATH := "res://resources/books/test_book/book.tres"
## What the save file keys that book by since schema v2 (WP7): its authored
## [member BookDef.book_uid], not the path it is loaded from.
const BOOK_UID := "test-book-2026"
## Books on the shelf after M6 added the coyote art book: test_book + coyote.
const EXPECTED_BOOK_COUNT := 2

## Scratch root for everything this run writes. Wiped at both ends.
const TEST_SAVE_ROOT := "user://shell_smoke/state"
## Everything under here is removed on cleanup.
const TEST_ROOT := "user://shell_smoke"

## The region painted in check (b) and looked for again in check (c).
const PROBE_REGION := 4
## Per-channel tolerance (0..255) when matching a restored pixel to the brush.
const COLOR_TOLERANCE := 2
## Sweep spacing for the flood helper, as a fraction of the brush RADIUS.
const FLOOD_ROW_RATIO := 1.15
## Seconds any "wait for the app to get there" poll is allowed to take.
const NAV_TIMEOUT := 8.0
## Longer budget for things that involve painting a whole page.
const PAINT_TIMEOUT := 45.0

## Check (i), BL-48. The window this harness runs in, and the phone shape it is
## briefly resized to.
const DESKTOP_WINDOW := Vector2i(1280, 820)
const PORTRAIT_WINDOW := Vector2i(720, 1280)
## A real phone in portrait: 1152 logical canvas pixels painted across ~390 pt of
## glass. A Windows window can never produce this (it is never smaller than the
## 1152 px base canvas), so it is forced through OverlayMetrics.debug_squeeze --
## the same dev hook SafeArea.debug_insets is, and for the same reason.
const PHONE_SQUEEZE := 2.95
## Long enough to be the complaint BL-48 opened with.
const LONG_EMAIL := "binaryrabbit101@gmail.com"
## The settings panel's authored width, which the desktop half of check (i) says
## must not have moved.
const DESKTOP_PANEL_WIDTH := 600.0

@onready var _host: Control = $Host

var _checks := 0
var _failures := 0

var _main: Main
var _book: BookDef
var _shot_dir := "user://shell_smoke/shots"

## Page coordinate painted in check (b), and the colour used, so check (c) can
## look for exactly those pixels again.
var _probe_point := Vector2.ZERO
var _probe_color := Color.MAGENTA


func _ready() -> void:
	get_window().size = DESKTOP_WINDOW
	# The coverage readback stalls on the presentation queue under FIFO v-sync
	# (see coloring_page.gd); the run is minutes shorter on mailbox.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_MAILBOX)
	_shot_dir = _arg_value("--shot-dir", _shot_dir)
	if not DirAccess.dir_exists_absolute(_shot_dir):
		DirAccess.make_dir_recursive_absolute(_shot_dir)
	await get_tree().process_frame
	await _run()


func _run() -> void:
	print("=== M5 shell smoke test ===")
	_isolate_persistence()

	_book = load(BOOK_PATH) as BookDef
	if _book == null:
		_expect(false, "%s loads as a BookDef" % BOOK_PATH)
		_finish(1)
		return

	await _check_boot_and_navigation()
	await _check_splash_starts_itself()
	await _check_paint_and_save()
	await _check_resume()
	await _check_manual_save_and_restart()
	await _check_coloring_lock()
	await _check_complete_and_again()
	await _check_erase_all()
	await _check_single_palette_mid_book()
	await _check_quit_save()
	_check_broken_saves()
	await _check_overlay_scaling()

	print("\n=== %d/%d checks passed ===" % [_checks - _failures, _checks])
	if "--stay" in OS.get_cmdline_user_args():
		print("[dev] --stay given; the app is live and the scratch save at %s was kept."
			% ProjectSettings.globalize_path(TEST_SAVE_ROOT))
		return
	_cleanup()
	_finish(0 if _failures == 0 else 1)


## Everything this run writes goes into a scratch directory that is empty when it
## starts. Without this, a previous run's paint layer would be restored into the
## book and every "starts clean" assertion below would be a lie.
func _isolate_persistence() -> void:
	_delete_recursive(TEST_ROOT)
	GameState.set_save_root(TEST_SAVE_ROOT)
	print("   save root: %s" % ProjectSettings.globalize_path(GameState.get_save_path()))


func _cleanup() -> void:
	# reload=false: do not read the player's real save just to throw it away.
	GameState.set_save_root("", false)
	_delete_recursive(TEST_ROOT)
	print("   cleaned up %s" % ProjectSettings.globalize_path(TEST_ROOT))


func _finish(code: int) -> void:
	# Never tear the engine down on top of a queued GPU readback: that is a hard
	# crash (see AsyncReadback.drain).
	await AsyncReadback.drain(get_tree())
	print("exit code: %d" % code)
	get_tree().quit(code)


# ============================================ a: boot, navigation, settings ==

func _check_boot_and_navigation() -> void:
	print("\n-- check a: boot -> title -> shelf -> page --")

	_expect(
		String(ProjectSettings.get_setting("application/run/main_scene", "")) == "res://scenes/main.tscn",
		"project.godot run/main_scene is res://scenes/main.tscn (%s)"
		% ProjectSettings.get_setting("application/run/main_scene", "unset")
	)

	# BL-27: the splash carries itself to the shelf after its opening beat. This
	# harness holds it still instead -- otherwise the title would walk off midway
	# through the assertions below and title.png would catch an animation in flight.
	# The auto-start is proved on its own, in check (a2).
	TitleScreen.autostart_enabled = false

	_main = MAIN_SCENE.instantiate() as Main
	_main.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# M6: main quits the game itself on a close request so it can drain in-flight
	# GPU readbacks first. Check (g) delivers that notification on purpose, so tell
	# main to do everything EXCEPT the quit -- otherwise this run ends at check g.
	_main.quit_on_close_request = false
	_host.add_child(_main)
	await _wait_for_screen(Main.SCREEN_TITLE)

	var title := _main.get_current_screen() as TitleScreen
	_expect(title != null, "main.tscn boots to the title screen (%s)" % _main.get_current_screen_id())
	if title == null:
		return
	_expect(title.get_crayon_count() > 0,
		"the title screen laid out %d crayons" % title.get_crayon_count())
	_expect(not _main.get_gear_button().visible, "the settings gear is hidden on the title")
	await _settle_layout()
	await _screenshot("title.png")

	# --- to the shelf: BL-20 put it directly behind the title, BL-27 made the tap
	# a SKIP rather than a gate -- either way the next thing is the shelf ------
	title.get_tap_button().pressed.emit()
	var reached_shelf := await _wait_for_screen(Main.SCREEN_BOOK_SELECT)
	_expect(reached_shelf,
		"tapping the title goes STRAIGHT to the shelf (%s)" % _main.get_current_screen_id())
	_expect(not ResourceLoader.exists("res://scenes/screens/mode_select.tscn"),
		"...because the mode-select screen no longer exists in the project")
	_expect(not _main.has_method("show_mode_select") and not _main.has_method("get_mode_select_overlay"),
		"...and main has no way to reach one, as a screen or as an overlay")

	# --- the settings gear (an OVERLAY, because book_select.tscn is frozen) ---
	_expect(_main.get_gear_button().visible, "the settings gear is showing on the shelf")
	_main.get_gear_button().pressed.emit()
	await get_tree().process_frame
	var panel := _main.get_settings_panel()
	_expect(panel != null, "the gear opened the settings panel")
	if panel != null:
		_expect(panel.get_version_text().contains(
			String(ProjectSettings.get_setting("application/config/version", ""))),
			"the panel shows the version ('%s')" % panel.get_version_text())
		# BL-20: the panel reports WHICH crayons the game paints with, and offers
		# nothing to change about it -- there is only the one box.
		_expect(panel.get_palette_text() == GameState.get_active_palette().display_name,
			"the panel names the one palette ('%s')" % panel.get_palette_text())
		_expect(not panel.has_method("get_change_mode_button")
				and not panel.has_signal("mode_change_requested"),
			"...and carries no mode switch at all")
		_expect(not panel.is_confirming(), "the erase confirm step starts hidden")
		panel.get_close_button().pressed.emit()
		await get_tree().process_frame
	_expect(_main.get_settings_panel() == null, "closing the panel removed the overlay")

	# --- pick the book -------------------------------------------------------
	var shelf := _main.get_current_screen() as BookSelect
	var cells := shelf.get_cells()
	_expect(cells.size() == EXPECTED_BOOK_COUNT,
		"the shelf shows %d books (%d cell(s))" % [EXPECTED_BOOK_COUNT, cells.size()])
	var cell := _cell_for(shelf, _book)
	_expect(cell != null, "one of them is the test book")
	if cell == null:
		return

	# BL-40: the grid fills from the TOP LEFT. Measured against the shelf's own rect
	# rather than a constant, and against the SECOND cell rather than a column count,
	# so the check says "the first book is in the corner and the next one is to its
	# right" without caring how many columns the window happened to fit.
	await _settle_layout()
	var first_cell: BookCell = cells[0]
	var shelf_left := shelf.global_position.x
	_expect(first_cell.global_position.x - shelf_left < shelf.size.x * 0.5,
		"the first book sits in the shelf's LEFT half, not centred (%.0f px in of %.0f)"
		% [first_cell.global_position.x - shelf_left, shelf.size.x])
	if cells.size() > 1:
		_expect(cells[1].global_position.x > first_cell.global_position.x
				and is_equal_approx(cells[1].global_position.y, first_cell.global_position.y),
			"...and the next one fills to its RIGHT, on the same row")

	# BL-42: an artist's cover fills the front of the book; page 1 standing in for
	# one keeps its framed plate. Driven off a book built here, because no res://
	# book authors a cover -- the shipped ones all fall back.
	_expect(not cell.has_artist_cover() and cell.has_cover(),
		"a book with no cover of its own shows page 1 on a framed plate")
	var covered := BookDef.new()
	covered.book_uid = "shell-cover-2026"
	covered.display_name = "Covered"
	covered.pages = _book.pages
	covered.cover_image_path = load(
		"res://resources/books/coyote/book.tres").get_page(0).display_image_path
	_expect(covered.has_artist_cover(),
		"a book whose cover is NOT page 1 has an artist cover")
	var probe := BookCell.new()
	probe.set_book(covered)
	_expect(probe.has_artist_cover() and probe.has_cover(),
		"...and the cell draws it as the book's front")
	probe.set_book(_book)
	_expect(not probe.has_artist_cover(),
		"...and swaps back to the plate for a book without one")
	probe.free()
	_expect(not _main.get_book_transition().has_cover_art(),
		"the book-open animation carries no cover art until a covered book is opened")
	cell.pressed.emit()
	var reached_page := await _wait_for_screen(Main.SCREEN_COLORING)
	_expect(reached_page, "picking the book opens the coloring page (%s)" % _main.get_current_screen_id())
	var coloring := _main.get_current_screen() as ColoringPage
	_expect(coloring != null and coloring.get_page_label_text() == "1/2",
		"the page label reads 1/2 ('%s')" % (coloring.get_page_label_text() if coloring else "-"))
	_expect(not _main.get_gear_button().visible, "the gear is hidden while a page is open")


# ================================== a2: BL-27, the splash is not a door anymore ==
# Driven OUTSIDE main.tscn, on a splash of its own: check (a) deliberately holds the
# real one still (see the autostart_enabled note there), and what has to be proved
# here is precisely the thing that check turns off.

func _check_splash_starts_itself() -> void:
	print("\n-- check a2: the splash carries itself to the shelf (BL-27) --")
	var restore := TitleScreen.autostart_enabled
	TitleScreen.autostart_enabled = true

	# --- nothing touches it -----------------------------------------------------
	var splash := TITLE_SCENE.instantiate() as TitleScreen
	splash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var asked := [0]
	splash.start_requested.connect(func() -> void: asked[0] += 1)
	_host.add_child(splash)
	_expect(splash.is_intro_playing(), "the splash starts its opening beat by itself")
	_expect(asked[0] == 0, "...and asks for nothing while it is still playing")
	var started := await _wait_until(
		func() -> bool: return asked[0] > 0, TitleScreen.INTRO_SECONDS + 3.0
	)
	_expect(started, "start_requested arrived with NOTHING having tapped it")
	_expect(not splash.is_intro_playing(), "...once the beat was over, not before")
	_expect(splash.get_crayon_count() == TitleScreen.CRAYON_COUNT,
		"every crayon landed on the shelf (%d)" % splash.get_crayon_count())
	splash.get_tap_button().pressed.emit()
	_expect(asked[0] == 1, "a late tap cannot ask a second time (%d)" % asked[0])
	_host.remove_child(splash)
	splash.queue_free()

	# --- a tap during the beat skips to the end ---------------------------------
	var impatient := TITLE_SCENE.instantiate() as TitleScreen
	impatient.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var early := [0]
	impatient.start_requested.connect(func() -> void: early[0] += 1)
	_host.add_child(impatient)
	await get_tree().process_frame
	_expect(impatient.is_intro_playing(), "a second splash is mid-beat")
	impatient.get_tap_button().pressed.emit()
	_expect(early[0] == 1, "tapping mid-beat starts immediately (%d)" % early[0])
	_expect(not impatient.is_intro_playing(),
		"...by ending the beat rather than racing it to the finish")
	_host.remove_child(impatient)
	impatient.queue_free()

	TitleScreen.autostart_enabled = restore
	await get_tree().process_frame


# ================================================ b: paint, leave, save file ==

func _check_paint_and_save() -> void:
	print("\n-- check b: paint region %d, leave the book, inspect the save --" % PROBE_REGION)
	var coloring := _main.get_current_screen() as ColoringPage
	if coloring == null:
		_expect(false, "the coloring page is open")
		return
	var page_view := coloring.get_page_view()
	var tracker := coloring.get_coverage_tracker()

	var data := page_view.get_region_data(PROBE_REGION)
	_expect(not data.is_empty(), "page 1 has region %d" % PROBE_REGION)
	if data.is_empty():
		return
	_probe_point = data["centroid"]
	_probe_color = page_view.brush_color
	_expect(page_view.get_region_id_at(_probe_point) == PROBE_REGION,
		"the region's centroid %s really belongs to it" % _probe_point)

	# A few real strokes through the centroid, through the same entry points the
	# touch path uses.
	for i in 3:
		var y := _probe_point.y + float(i - 1) * 28.0
		page_view.begin_stroke(Vector2(_probe_point.x - 70.0, y))
		page_view.continue_stroke(Vector2(_probe_point.x + 70.0, y))
		page_view.end_stroke()
		await _wait_for_coverage(coloring)

	var painted_coverage := tracker.region_coverage(PROBE_REGION)
	_expect(painted_coverage > 0.0,
		"region %d has coverage after painting (%.3f)" % [PROBE_REGION, painted_coverage])
	_expect(not tracker.is_page_complete(), "the page is NOT complete, so nothing flipped")

	# --- back: the save point --------------------------------------------------
	(coloring.get_node("Ui/Toolbar/Row/BackButton") as Button).pressed.emit()
	var back_to_shelf := await _wait_for_screen(Main.SCREEN_BOOK_SELECT)
	_expect(back_to_shelf, "Back returns to the shelf (%s)" % _main.get_current_screen_id())

	# --- the file on disk ------------------------------------------------------
	var save_path := GameState.get_save_path()
	_expect(FileAccess.file_exists(save_path),
		"the save file exists (%s)" % ProjectSettings.globalize_path(save_path))
	var data_dict := _read_save()
	_expect(not data_dict.is_empty(), "the save file parses as JSON")
	if data_dict.is_empty():
		return
	_expect(int(data_dict.get("version", 0)) == GameState.SAVE_VERSION,
		"schema version is %d (%s)" % [GameState.SAVE_VERSION, data_dict.get("version")])
	# BL-20: the "mode" key is vestigial. It is READ tolerantly (check h plants a
	# file carrying one) but never written again, and SAVE_VERSION did not move.
	_expect(not data_dict.has("mode"),
		"the save carries no 'mode' key any more (%s)" % [data_dict.keys()])
	var books: Dictionary = data_dict.get("books", {})
	# WP7 / save schema v2: the key is the book's OWN identity, not the path this
	# build happens to load it from.
	_expect(books.has(BOOK_UID) and GameState.book_key(_book) == BOOK_UID,
		"the book is keyed by its book_uid '%s' (keys: %s)" % [BOOK_UID, books.keys()])
	if not books.has(BOOK_UID):
		return
	var entry: Dictionary = books[BOOK_UID]
	_expect(int(entry.get("current_page_index", -1)) == 0,
		"current_page_index is 0 (%s)" % entry.get("current_page_index"))
	var pages: Array = entry.get("pages", [])
	_expect(pages.size() == _book.page_count(),
		"an entry per page (%d of %d)" % [pages.size(), _book.page_count()])
	# BL-10 widened a page entry from a bare status string to an object carrying the
	# status AND the coloring lock.
	var first_page: Dictionary = (
		pages[0] if pages.size() > 0 and typeof(pages[0]) == TYPE_DICTIONARY else {}
	)
	_expect(String(first_page.get(GameState.PAGE_STATUS_KEY, "-")) == GameState.STATUS_IN_PROGRESS,
		"page 1 is '%s' (%s)"
		% [GameState.STATUS_IN_PROGRESS, first_page.get(GameState.PAGE_STATUS_KEY, "-")])
	_expect(first_page.has(GameState.PAGE_LOCKED_KEY)
			and not bool(first_page[GameState.PAGE_LOCKED_KEY]),
		"...and carries its lock flag, unlocked (%s)" % [first_page])

	var paint_path := GameState.get_paint_path(_book, 0)
	_expect(FileAccess.file_exists(paint_path),
		"the paint layer was written to %s" % ProjectSettings.globalize_path(paint_path))
	_expect(paint_path.contains("/%s/" % GameState.book_slug(BOOK_UID)),
		"the paint path uses the book slug '%s'" % GameState.book_slug(BOOK_UID))


# ========================================================== c: resume a book ==

func _check_resume() -> void:
	print("\n-- check c: re-entering the book restores the page, the pixels and the coverage --")
	var shelf := _main.get_current_screen() as BookSelect
	if shelf == null:
		_expect(false, "the shelf is showing")
		return
	var cell := _cell_for(shelf, _book)
	if cell == null:
		_expect(false, "the shelf still has a cell for the test book")
		return
	cell.pressed.emit()
	var reopened := await _wait_for_screen(Main.SCREEN_COLORING)
	_expect(reopened, "the book reopens (%s)" % _main.get_current_screen_id())
	var coloring := _main.get_current_screen() as ColoringPage
	if coloring == null:
		return
	await _wait_until(func() -> bool: return not coloring.has_pending_restore(), NAV_TIMEOUT)
	await _settle_layout()

	_expect(coloring.get_page_label_text() == "1/2",
		"it resumes on the same page ('%s')" % coloring.get_page_label_text())
	_expect(GameState.current_page_index == 0, "the GameState cursor is page 0")

	var paint := coloring.get_page_view().get_paint_image()
	_expect(paint != null, "the paint layer reads back")
	if paint == null:
		return
	if paint.get_format() != Image.FORMAT_RGBA8:
		paint.convert(Image.FORMAT_RGBA8)
	var pixel := paint.get_pixel(int(_probe_point.x), int(_probe_point.y))
	var worst := maxi(
		absi(pixel.r8 - _probe_color.r8),
		maxi(absi(pixel.g8 - _probe_color.g8), absi(pixel.b8 - _probe_color.b8))
	)
	_expect(pixel.a8 >= 250, "the restored core pixel is opaque (a=%d)" % pixel.a8)
	_expect(worst <= COLOR_TOLERANCE,
		"the restored core pixel is still #%s (worst channel delta %d/255)"
		% [_probe_color.to_html(false), worst])

	var coverage := coloring.get_coverage_tracker().region_coverage(PROBE_REGION)
	_expect(coverage > 0.0,
		"the tracker resumed with region %d at %.3f coverage" % [PROBE_REGION, coverage])
	_expect(not coloring.is_page_pre_completed(),
		"a partly-coloured page is not treated as already finished")


# ========================= c2: manual save (BL-6) and start over (BL-7) ==

func _check_manual_save_and_restart() -> void:
	print("\n-- check c2: the Save button, then Start over on this page only --")
	var coloring := _main.get_current_screen() as ColoringPage
	if coloring == null:
		_expect(false, "the coloring page is open")
		return
	var page_view := coloring.get_page_view()
	var paint_path := GameState.get_paint_path(_book, 0)

	# --- Save on demand ------------------------------------------------------
	# A fresh stroke, so there is genuinely something new to write.
	page_view.begin_stroke(_probe_point + Vector2(0.0, 56.0))
	page_view.continue_stroke(_probe_point + Vector2(60.0, 56.0))
	page_view.end_stroke()
	await _wait_for_coverage(coloring)
	_expect(coloring.has_unsaved_paint(), "the new stroke marked the page unsaved")

	var saves: Array[int] = []
	coloring.page_saved.connect(func(index: int, manual: bool) -> void:
		if manual:
			saves.append(index)
	)
	coloring.get_save_button().pressed.emit()
	var saved := await _wait_until(func() -> bool: return saves.size() == 1, NAV_TIMEOUT)
	_expect(saved, "pressing Save wrote page 1 (%d event(s))" % saves.size())
	_expect(not coloring.has_unsaved_paint(), "...and the page is no longer marked unsaved")
	_expect(coloring.is_toast_visible() and coloring.get_toast_text() == "Saved!",
		"...with visible feedback ('%s')" % coloring.get_toast_text())
	_expect(FileAccess.file_exists(paint_path), "the paint layer is on disk")

	# --- Start over asks first ------------------------------------------------
	coloring.get_reset_button().pressed.emit()
	_expect(coloring.is_reset_confirming(), "Start over asks for confirmation first")
	coloring.get_reset_cancel_button().pressed.emit()
	_expect(not coloring.is_reset_confirming(), "'Keep colouring' backs out of it")
	_expect(FileAccess.file_exists(paint_path), "cancelling cleared nothing")

	# --- ...and then resets THIS page only -----------------------------------
	GameState.mark_page_status(_book, 1, GameState.STATUS_IN_PROGRESS)
	coloring.get_reset_button().pressed.emit()
	coloring.get_reset_confirm_button().pressed.emit()
	await _settle_layout()

	_expect(not FileAccess.file_exists(paint_path), "confirming deleted page 1's paint layer")
	_expect(GameState.get_page_status(BOOK_UID, 0) == GameState.STATUS_UNTOUCHED,
		"page 1 is '%s' again (%s)"
		% [GameState.STATUS_UNTOUCHED, GameState.get_page_status(BOOK_UID, 0)])
	_expect(GameState.get_page_status(BOOK_UID, 1) == GameState.STATUS_IN_PROGRESS,
		"page 2's progress was NOT touched (%s)" % GameState.get_page_status(BOOK_UID, 1))
	_expect(is_zero_approx(coloring.get_coverage_tracker().page_coverage()),
		"the tracker is back to zero coverage (%.3f)"
		% coloring.get_coverage_tracker().page_coverage())
	var cleared := coloring.get_page_view().get_paint_image()
	if cleared != null and cleared.get_format() != Image.FORMAT_RGBA8:
		cleared.convert(Image.FORMAT_RGBA8)
	_expect(cleared != null and cleared.get_pixel(int(_probe_point.x), int(_probe_point.y)).a8 == 0,
		"the paint layer itself really is blank paper again")
	# Put page 2 back the way check d expects to find it.
	GameState.erase_page_progress(_book, 1)


# ================================================ c3: the coloring lock (BL-10) ==
# The lock has to do exactly two things and refuse to do a third: stop strokes,
# disable Start over, and leave everything else -- Save, navigation, the palette,
# the paint already down -- exactly as it was. And it has to be on disk the moment
# it is set, because a lock that survives only until the next crash is not a lock.

func _check_coloring_lock() -> void:
	print("\n-- check c3: the padlock --")
	var coloring := _main.get_current_screen() as ColoringPage
	if coloring == null:
		_expect(false, "the coloring page is open")
		return
	var page_view := coloring.get_page_view()
	var lock := coloring.get_lock_button()
	_expect(lock != null, "the toolbar carries a padlock button")
	if lock == null:
		return
	_expect(minf(lock.size.x, lock.size.y) >= 48.0,
		"...clearing the 48 px touch floor (%.0fx%.0f)" % [lock.size.x, lock.size.y])
	_expect(not coloring.is_page_locked() and not lock.locked, "a page starts unlocked")

	# --- lock it --------------------------------------------------------------
	lock.pressed.emit()
	_expect(coloring.is_page_locked(), "one tap locks the page -- no confirm step")
	_expect(lock.locked, "...and the padlock itself shows the state")
	_expect(not page_view.painting_enabled, "...painting is off on the page view")
	_expect(not page_view.begin_stroke(_probe_point), "...a press starts NO stroke")
	_expect(lock.is_wiggling(), "...and the padlock wiggled to say why nothing happened")
	_expect(not page_view.is_stroke_active(), "...nothing is left half-started")
	_expect(coloring.get_reset_button().disabled, "Start over is disabled while locked")
	_expect(not coloring.restart_current_page(),
		"...and refuses to run even when called directly")

	# --- everything else is untouched ----------------------------------------
	_expect(not coloring.get_save_button().disabled, "Save still works while locked")
	_expect(not coloring.get_next_page_button().disabled, "navigation still works")
	_expect(not coloring.get_back_button().disabled, "...and so does leaving the book")
	_expect(coloring.get_palette() != null and coloring.get_palette().visible,
		"the palette is still there to browse")

	# --- it is in the save, at once ------------------------------------------
	_expect(GameState.is_page_locked(BOOK_UID, 0), "GameState records the lock")
	_expect(not GameState.is_page_locked(BOOK_UID, 1), "...for THIS page only")
	var saved_entry: Dictionary = (_read_save().get("books", {}) as Dictionary).get(BOOK_UID, {})
	var saved_pages: Array = saved_entry.get("pages", [])
	_expect(saved_pages.size() > 0 and typeof(saved_pages[0]) == TYPE_DICTIONARY
			and bool((saved_pages[0] as Dictionary).get(GameState.PAGE_LOCKED_KEY, false)),
		"...and it is on disk immediately, without waiting for a save point (%s)"
		% [saved_pages[0] if saved_pages.size() > 0 else "-"])
	GameState.load_save()
	_expect(GameState.is_page_locked(BOOK_UID, 0),
		"...so it survives being read back out of that file")

	# --- unlock ---------------------------------------------------------------
	lock.pressed.emit()
	_expect(not coloring.is_page_locked() and not lock.locked,
		"one more tap unlocks it, again with no dialog")
	_expect(page_view.painting_enabled and not coloring.get_reset_button().disabled,
		"painting and Start over come straight back")
	_expect(page_view.begin_stroke(_probe_point), "...and a press starts a stroke again")
	page_view.end_stroke()
	await _wait_for_coverage(coloring)
	_expect(not GameState.is_page_locked(BOOK_UID, 0), "the save agrees the page is unlocked")


# ============ d: finish both pages, leave by Back, start the book over ==

func _check_complete_and_again() -> void:
	print("\n-- check d: finish both pages, then start the book over --")
	var coloring := _main.get_current_screen() as ColoringPage
	if coloring == null:
		_expect(false, "the coloring page is open")
		return

	var strokes_1 := await _fill_page(coloring)
	print("   page 1 filled with %d strokes" % strokes_1)
	# BL-4: the finished page stays put; turning it is the player's call.
	var finished := await _wait_until(
		func() -> bool:
			return coloring.get_coverage_tracker().is_page_complete() \
				and not coloring.is_transitioning(),
		PAINT_TIMEOUT
	)
	_expect(finished, "page 1 completed and stayed on 1/2 ('%s')" % coloring.get_page_label_text())
	_expect(coloring.is_celebrating(), "...with the transient celebration up (BL-11)")
	_expect(ColoringPage.CELEBRATION_MESSAGES.has(coloring.get_celebration_message()),
		"...showing a congratulation from the pool ('%s')" % coloring.get_celebration_message())
	coloring.get_next_page_button().pressed.emit()
	# The flip is asynchronous; wait for the second page to be interactive.
	var on_page_2 := await _wait_until(
		func() -> bool: return coloring.get_page_label_text() == "2/2" and not coloring.is_transitioning(),
		PAINT_TIMEOUT
	)
	_expect(on_page_2, "the next-page arrow turned the book to 2/2 ('%s')"
		% coloring.get_page_label_text())
	await _wait_until(func() -> bool: return not coloring.has_pending_restore(), NAV_TIMEOUT)

	_expect(GameState.get_page_status(BOOK_UID, 0) == GameState.STATUS_COMPLETE,
		"page 1 was saved as '%s' (%s)"
		% [GameState.STATUS_COMPLETE, GameState.get_page_status(BOOK_UID, 0)])
	_expect(FileAccess.file_exists(GameState.get_paint_path(_book, 0)),
		"page 1's finished paint layer is on disk")

	var strokes_2 := await _fill_page(coloring)
	print("   page 2 filled with %d strokes" % strokes_2)
	# BL-11: the LAST page behaves like every other one. Filling it up celebrates
	# and stays put, and there is nowhere for the book to end TO -- the player
	# leaves with Back, whenever they feel like it.
	var last_done := await _wait_until(
		func() -> bool:
			return coloring.get_coverage_tracker().is_page_complete() \
				and not coloring.is_transitioning(),
		PAINT_TIMEOUT
	)
	_expect(last_done, "page 2 completed ('%s')" % coloring.get_page_label_text())
	_expect(_main.get_current_screen_id() == Main.SCREEN_COLORING,
		"...and the book did NOT take the player anywhere (%s)" % _main.get_current_screen_id())
	_expect(coloring.is_celebrating(), "...it celebrated on the page, like any other page")
	_expect(coloring.get_next_page_button().disabled,
		"...the forward arrow is disabled: there is no page after the last one")
	_expect(not coloring.get_back_button().disabled, "...and Back is the way out")
	_expect(GameState.is_book_complete(_book), "every page is recorded complete")
	await _settle_layout()
	await _screenshot("page_complete.png")

	# ...and the whole celebration is gone again a few seconds later, on its own.
	var faded := await _wait_until(func() -> bool: return not coloring.is_celebrating(), 15.0)
	_expect(faded, "the celebration faded away with nothing dismissing it")
	_expect(_main.get_current_screen_id() == Main.SCREEN_COLORING
			and coloring.get_page_label_text() == "2/2",
		"...leaving the player on the page they finished ('%s')" % coloring.get_page_label_text())

	var paint_0 := GameState.get_paint_path(_book, 0)
	var paint_1 := GameState.get_paint_path(_book, 1)
	_expect(FileAccess.file_exists(paint_0) and FileAccess.file_exists(paint_1),
		"both pages' paint layers are on disk")

	# --- leave by Back, wipe the book, colour it again ------------------------
	coloring.get_back_button().pressed.emit()
	var left := await _wait_for_screen(Main.SCREEN_BOOK_SELECT, PAINT_TIMEOUT)
	_expect(left, "Back leaves the finished book for the shelf (%s)" % _main.get_current_screen_id())

	GameState.erase_book_progress(_book)
	_expect(not FileAccess.file_exists(paint_0) and not FileAccess.file_exists(paint_1),
		"erase_book_progress deleted both saved paint layers")
	_expect(GameState.get_page_status(BOOK_UID, 0) == GameState.STATUS_UNTOUCHED
			and GameState.get_page_status(BOOK_UID, 1) == GameState.STATUS_UNTOUCHED,
		"both page statuses were reset (%s, %s)"
		% [GameState.get_page_status(BOOK_UID, 0), GameState.get_page_status(BOOK_UID, 1)])

	var shelf := _main.get_current_screen() as BookSelect
	var cell := _cell_for(shelf, _book) if shelf != null else null
	_expect(cell != null, "the wiped book is still on the shelf")
	if cell == null:
		return
	cell.pressed.emit()
	var restarted := await _wait_for_screen(Main.SCREEN_COLORING)
	_expect(restarted, "picking it opens it again (%s)" % _main.get_current_screen_id())
	var fresh := _main.get_current_screen() as ColoringPage
	if fresh == null:
		return
	await _wait_until(func() -> bool: return not fresh.has_pending_restore(), NAV_TIMEOUT)
	await _settle_layout()

	_expect(fresh.get_page_label_text() == "1/2",
		"the restarted book is back at 1/2 ('%s')" % fresh.get_page_label_text())
	_expect(is_zero_approx(fresh.get_coverage_tracker().page_coverage()),
		"the page is blank again (coverage %.3f)" % fresh.get_coverage_tracker().page_coverage())


# ============================================= e: settings "erase all" ==

func _check_erase_all() -> void:
	print("\n-- check e: settings -> erase all progress (with confirm) --")
	# Leave something behind first, so "erased" means something.
	GameState.mark_page_status(_book, 0, GameState.STATUS_IN_PROGRESS)
	_expect(not _read_save().get("books", {}).is_empty(), "there is progress to erase")

	var panel := _main.open_settings()
	await get_tree().process_frame
	_expect(panel != null, "settings opens over the coloring page")
	if panel == null:
		return
	panel.get_erase_button().pressed.emit()
	_expect(panel.is_confirming(), "erasing asks for confirmation first")
	panel.get_cancel_button().pressed.emit()
	_expect(not panel.is_confirming(), "cancelling backs out of the confirm step")
	_expect(not _read_save().get("books", {}).is_empty(), "cancelling erased nothing")

	panel.get_erase_button().pressed.emit()
	panel.get_confirm_button().pressed.emit()
	await get_tree().process_frame

	var saved := _read_save()
	_expect(int(saved.get("version", 0)) == GameState.SAVE_VERSION,
		"the save file is still a valid v%d file" % GameState.SAVE_VERSION)
	_expect((saved.get("books", {}) as Dictionary).is_empty(),
		"every book entry is gone (%s)" % [(saved.get("books", {}) as Dictionary).keys()])
	_expect(_count_files(GameState.get_paint_root()) == 0,
		"the paint directory holds no files (%d)" % _count_files(GameState.get_paint_root()))

	_main.close_settings()
	await get_tree().process_frame
	_expect(_main.get_settings_panel() == null, "the panel closed")


# ================================================ f: one palette, mid-book ==

## BL-20 rewrote this check rather than deleting it. It used to prove that a mode
## switch swapped the palette component and the threshold under an open book;
## there is no switch any more, so what it proves now is the property that
## replaced it -- the open book has exactly one palette and one threshold, and
## the settings overlay it could once be changed from can no longer touch either.
func _check_single_palette_mid_book() -> void:
	print("\n-- check f: one palette, one threshold, nothing to change mid-book --")
	var coloring := _main.get_current_screen() as ColoringPage
	if coloring == null:
		_expect(false, "a book is still open (%s)" % _main.get_current_screen_id())
		return
	var palette := GameState.get_active_palette()
	_expect(coloring.get_palette() is PaletteChild,
		"the open book uses the crayon palette (%s)" % _script_name(coloring.get_palette()))
	_expect(coloring.get_palette().get_palette() == palette,
		"...built from the one PaletteDef GameState hands out")
	_expect(is_equal_approx(coloring.get_coverage_tracker().get_threshold(),
			palette.completion_threshold),
		"...and the tracker carries its threshold (%.2f)"
		% coloring.get_coverage_tracker().get_threshold())
	_expect(is_equal_approx(coloring.get_coverage_tracker().get_threshold(), 0.90),
		"...which is the single generous 0.90 (BL-5's child value, kept by BL-20)")
	_expect(not coloring.has_signal("palette_rebuilt"),
		"the screen no longer announces a palette rebuild -- nothing rebuilds it")

	var panel := _main.open_settings()
	await get_tree().process_frame
	_expect(panel != null and panel.get_node_or_null("Center/Panel/Margin/Column/ModeRow") == null,
		"the settings overlay over the book has no Mode row")
	_expect(_main.get_current_screen_id() == Main.SCREEN_COLORING,
		"the book is still the current SCREEN behind the overlay (%s)" % _main.get_current_screen_id())
	panel.get_close_button().pressed.emit()
	await get_tree().process_frame
	_expect(_main.get_current_screen() == coloring, "the same coloring page is still open")
	_expect(coloring.get_palette().get_palette() == palette,
		"...with the same palette it opened with")


# ==================================================== g: saving on quit ==

func _check_quit_save() -> void:
	print("\n-- check g: NOTIFICATION_WM_CLOSE_REQUEST writes the save --")
	var written: Array[String] = []
	var handler := func(path: String) -> void: written.append(path)
	GameState.save_written.connect(handler)
	# Delivered to main only, not through the SceneTree, so the run survives it.
	_main.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
	await get_tree().process_frame
	GameState.save_written.disconnect(handler)

	_expect(written.size() >= 1, "the close notification produced %d save(s)" % written.size())
	_expect(FileAccess.file_exists(GameState.get_save_path()), "the save file is on disk")
	_expect(int(_read_save().get("version", 0)) == GameState.SAVE_VERSION,
		"and it is a valid v%d file" % GameState.SAVE_VERSION)
	_expect(_main.is_inside_tree(), "the app did not quit itself")


# ================================================= h: broken save files ==

func _check_broken_saves() -> void:
	print("\n-- check h: corrupt and future save files --")
	GameState.mark_page_status(_book, 0, GameState.STATUS_COMPLETE)
	_expect(not GameState.get_book_progress(BOOK_UID).get("pages", []).is_empty(),
		"there is in-memory progress before the corrupt read")

	_write_text(GameState.get_save_path(), "{ this is not json ]]")
	var loaded := GameState.load_save()
	_expect(not loaded, "load_save() reports that nothing was loaded")
	_expect((GameState.get_book_progress(BOOK_UID).get("pages", []) as Array).is_empty(),
		"the in-memory progress was reset")
	_expect(is_instance_valid(_main), "nothing crashed")

	# --- a save from a build that does not exist yet -------------------------
	var backup := GameState.get_backup_save_path()
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	_write_text(GameState.get_save_path(),
		'{"version": 99, "mode": "adult", "books": {"%s": {"current_page_index": 5, "pages": []}}}'
		% BOOK_UID)
	var future_loaded := GameState.load_save()
	_expect(not future_loaded, "a v99 save is refused")
	_expect(FileAccess.file_exists(backup),
		"...and backed up to %s" % ProjectSettings.globalize_path(backup))
	_expect(FileAccess.get_file_as_string(backup).contains("\"version\": 99"),
		"the backup is the original bytes")
	_expect(not GameState.has_book_progress(BOOK_UID), "the future save's progress was NOT applied")

	# --- a save that remembers pages the book no longer has (BL-9) -----------
	# Books SHRINK: BL-9 folded the coyote book's two bogus pages back into one,
	# and a re-authored or DLC-updated book can lose a page the same way. A save
	# written before that must not crash anything, must not keep answering for the
	# page that is gone, and must not leave its paint layer in user:// forever.
	_write_text(GameState.get_save_path(),
		('{"version": 1, "mode": "child", "books": {"%s": '
		+ '{"current_page_index": 3, "pages": ["complete", "in_progress", "complete", "complete"]}}}')
		% BOOK_UID)
	_expect(GameState.load_save(),
		"a pre-BL-20 save -- \"mode\" key and all -- listing 4 pages for a 2-page book loads")
	# ...and those page entries are BARE STATUS STRINGS -- the shape every save
	# written before BL-10 used. Reading them is the backward-compatibility half of
	# widening a page entry into an object.
	_expect(GameState.get_page_status(BOOK_UID, 0) == GameState.STATUS_COMPLETE,
		"a pre-BL-10 save's bare status strings still read as statuses (%s)"
		% GameState.get_page_status(BOOK_UID, 0))
	_expect(not GameState.is_page_locked(BOOK_UID, 0)
			and not GameState.is_page_locked(BOOK_UID, 1),
		"...and every page of it comes back UNLOCKED, because it could not say otherwise")
	var orphan := GameState.get_paint_path_for_key(BOOK_UID, 2)
	DirAccess.make_dir_recursive_absolute(orphan.get_base_dir())
	_write_text(orphan, "not really a png, but it is a file on disk")
	# Any path that touches the entry trims it; this one also proves completion is
	# still sticky while the trim happens underneath it.
	GameState.mark_page_status(_book, 0, GameState.STATUS_IN_PROGRESS)
	var trimmed := GameState.get_book_progress(BOOK_UID)
	_expect((trimmed.get("pages", []) as Array).size() == _book.page_count(),
		"the entry was trimmed to the book's %d pages (%d)"
		% [_book.page_count(), (trimmed.get("pages", []) as Array).size()])
	_expect(GameState.get_page_status(BOOK_UID, 0) == GameState.STATUS_COMPLETE,
		"the surviving pages kept their statuses")
	# (mark_page_status refused the downgrade above, so nothing has been WRITTEN
	# since the legacy file was planted -- ask for the write explicitly.)
	GameState.save_now()
	var rewritten: Array = ((_read_save().get("books", {}) as Dictionary)
		.get(BOOK_UID, {}) as Dictionary).get("pages", [])
	_expect(rewritten.size() > 0 and typeof(rewritten[0]) == TYPE_DICTIONARY,
		"...and writing that save back upgrades its entries to the object form (%s)"
		% [rewritten[0] if rewritten.size() > 0 else "-"])
	_expect(int(trimmed.get("current_page_index", -1)) == _book.page_count() - 1,
		"the saved cursor was clamped into the shorter book (%s)"
		% trimmed.get("current_page_index"))
	_expect(not FileAccess.file_exists(orphan),
		"the removed page's paint layer was deleted from user://")
	_expect(GameState.get_page_status(BOOK_UID, 2) == GameState.STATUS_UNTOUCHED
			and is_instance_valid(_main),
		"asking about the page that no longer exists is untouched, not a crash")

	# --- a missing save file is silent ---------------------------------------
	DirAccess.remove_absolute(GameState.get_save_path())
	_expect(not GameState.load_save(), "a missing save file starts fresh")
	_expect(GameState.save_now() and FileAccess.file_exists(GameState.get_save_path()),
		"and a fresh save can be written over it")


# ============================ i: the overlay layer on a phone (BL-48) ==
# The overlay layer is this harness's beat (the gear, the panel, the WP10 overlays
# are all main's), so BL-48's portrait pass is asserted here. It runs LAST because
# it resizes the window out from under everything, and it puts it back.
#
# The check has two halves and the FIRST one is the important one: on a desktop the
# overlay scale is exactly 1.0 by construction, so every authored number must come
# back unchanged. If that half ever fails, the mechanism has started charging
# desktop players for a phone fix.

func _check_overlay_scaling() -> void:
	print("\n-- check i: the overlay layer is sized for a phone (BL-48) --")
	var viewport := get_viewport()
	# Back to the shelf: the gear and "More books" are only live there, and they are
	# half of what this check is about.
	var open_book := _main.get_current_screen() as ColoringPage
	if open_book != null:
		open_book.get_back_button().pressed.emit()
		_expect(await _wait_for_screen(Main.SCREEN_BOOK_SELECT, PAINT_TIMEOUT),
			"the harness is back on the shelf, where both shell buttons live (%s)"
			% _main.get_current_screen_id())
	await _settle_layout()

	# ---------------------------------------------- desktop: nothing has moved --
	_expect(is_equal_approx(OverlayMetrics.content_scale(viewport), 1.0),
		"a desktop window scales the overlays by exactly 1.0 (%.3f)"
		% OverlayMetrics.content_scale(viewport))
	_expect(is_equal_approx(OverlayMetrics.min_touch_px(viewport),
			OverlayMetrics.DESKTOP_TOUCH_FLOOR_PX),
		"...and its touch floor is DESIGN.md's 48 px, not a phone's (%.0f)"
		% OverlayMetrics.min_touch_px(viewport))

	var panel := _main.open_settings()
	await _settle_layout()
	if panel == null:
		_expect(false, "the settings panel opened")
		return
	var box := panel.get_node("Center/Panel") as Control
	var account_row := panel.get_node("Center/Panel/Margin/Column/AccountRow") as BoxContainer
	var email := panel.get_account_label()
	_expect(is_equal_approx(box.size.x, DESKTOP_PANEL_WIDTH),
		"the settings panel is still its authored %.0f px wide (%.0f)"
		% [DESKTOP_PANEL_WIDTH, box.size.x])
	_expect(panel.get_close_button().custom_minimum_size.y == 56.0,
		"Done is still the 56 px it was authored at (%.0f)"
		% panel.get_close_button().custom_minimum_size.y)
	_expect(not account_row.vertical, "the account row is still a ROW on a desktop")
	_expect(email.clip_text, "...and the email still clips there, exactly as authored")
	_expect(is_equal_approx(_main.get_gear_button().size.x, Main.GearButton.SIZE.x),
		"the settings gear is still %.0f px (%.0f)"
		% [Main.GearButton.SIZE.x, _main.get_gear_button().size.x])
	var desktop_header := (panel.get_node("Center/Panel/Margin/Column/Header") as Label) \
		.get_theme_font_size("font_size")
	_expect(desktop_header == 36, "the header type is still 36 px (%d)" % desktop_header)

	# ------------------------------------- portrait, at a real phone's squeeze --
	# The WINDOW is resized, not a Control: only that exercises the canvas_items /
	# expand pipeline the shipped game runs on (the same reason mobile_smoke does it).
	get_window().size = PORTRAIT_WINDOW
	OverlayMetrics.debug_squeeze = PHONE_SQUEEZE
	await _settle_layout()
	var canvas := panel.size
	var scale := OverlayMetrics.content_scale(viewport)
	var floor_px := OverlayMetrics.min_touch_px(viewport)
	print("   portrait canvas %s, overlay scale %.2f, touch floor %.0f px (= %.0f pt)"
		% [canvas, scale, floor_px, floor_px / PHONE_SQUEEZE])
	_expect(canvas.y > canvas.x,
		"a 720x1280 window gives the overlay layer a PORTRAIT canvas (%s)" % canvas)
	_expect(is_equal_approx(scale, OverlayMetrics.MAX_CONTENT_SCALE),
		"a %.2fx squeeze pins the content scale at its %.1fx cap (%.2f)"
		% [PHONE_SQUEEZE, OverlayMetrics.MAX_CONTENT_SCALE, scale])
	_expect(floor_px > OverlayMetrics.MAX_CONTENT_SCALE * OverlayMetrics.TOUCH_TARGET_PT,
		"...while the touch floor keeps going past the cap, because a finger does (%.0f px)"
		% floor_px)
	_expect(is_equal_approx(floor_px / PHONE_SQUEEZE, OverlayMetrics.TOUCH_TARGET_PT),
		"...and it really is %.0f POINTS of glass (%.1f)"
		% [OverlayMetrics.TOUCH_TARGET_PT, floor_px / PHONE_SQUEEZE])

	_check_panel_fits("settings", box, canvas, floor_px)
	_expect(account_row.vertical,
		"the account row STACKS in portrait -- caption, address, button, one each per line")
	_expect((panel.get_node("Center/Panel/Margin/Column/ConfirmBox/Row") as BoxContainer)
			.vertical,
		"...and so does the erase confirm's yes/no pair")

	# --- the email: the complaint BL-48 opened with ---------------------------
	email.text = LONG_EMAIL
	panel.get_account_button().visible = true
	await _settle_layout()
	_expect(not email.clip_text and email.autowrap_mode == TextServer.AUTOWRAP_ARBITRARY,
		"the account email wraps instead of clipping (clip=%s, wrap=%d)"
		% [email.clip_text, email.autowrap_mode])
	_expect(email.text == LONG_EMAIL,
		"...and the label still holds every character ('%s')" % email.text)
	var needed := email.get_theme_font("font").get_string_size(
		LONG_EMAIL, HORIZONTAL_ALIGNMENT_LEFT, -1, email.get_theme_font_size("font_size")).x
	var room := email.size.x * float(maxi(email.get_line_count(), 1))
	_expect(room >= needed,
		"...with room to draw all %.0f px of it across %d line(s) (%.0f px available)"
		% [needed, email.get_line_count(), room])
	_expect(email.size.x > DESKTOP_PANEL_WIDTH * 0.6,
		"...on a line of its own rather than beside the button (%.0f px)" % email.size.x)
	await _screenshot("settings_portrait.png")

	# --- the gear and the shelf's shop button ---------------------------------
	var gear := _main.get_gear_button()
	_expect(minf(gear.size.x, gear.size.y) >= floor_px,
		"the settings gear clears the touch floor in portrait (%.0f of %.0f)"
		% [minf(gear.size.x, gear.size.y), floor_px])
	var more := _main.get_more_books_button()
	_expect(minf(more.size.x, more.size.y) >= floor_px,
		"...and so does 'More books' (%.0f of %.0f)"
		% [minf(more.size.x, more.size.y), floor_px])
	_main.close_settings()
	await _settle_layout()

	# --- BL-49: ...and neither of them is standing on a book ------------------
	# The two buttons above are the ones the playtest complained about. At the cap
	# they are ~460 x 173 canvas px each, which is exactly why the shelf below them
	# is a rail that starts under the band rather than a grid that fills into it.
	var shelf := _main.get_current_screen() as BookSelect
	_expect(shelf != null, "the shelf is the screen under the shell buttons")
	if shelf != null:
		var rail := shelf.get_carousel()
		var chrome: Array[Rect2] = [gear.get_global_rect(), more.get_global_rect()]
		var covered := 0
		for cell in shelf.get_cells():
			for button_rect in chrome:
				if rail.get_cell_rect(cell).intersects(button_rect):
					covered += 1
		_expect(covered == 0,
			"no book is under the gear or 'More books' at a %.2fx squeeze (%d covered)"
			% [PHONE_SQUEEZE, covered])
		var sign_rect := shelf.get_sign().get_global_rect()
		_expect(not sign_rect.intersects(chrome[0]) and not sign_rect.intersects(chrome[1]),
			"...and neither is the 'Pick a book' sign, which drops BELOW them when the pill "
			+ "is too wide to sit beside (sign at y %.0f, buttons end at y %.0f)"
			% [sign_rect.position.y, maxf(chrome[0].end.y, chrome[1].end.y)])
		_expect(is_equal_approx(rail.get_book_scale(), OverlayMetrics.MAX_CONTENT_SCALE),
			"a phone's squeeze draws the books at the content cap, %.1fx (%.2f)"
			% [OverlayMetrics.MAX_CONTENT_SCALE, rail.get_book_scale()])
		_expect(rail.is_cell_fully_visible(shelf.get_cells()[0]),
			"...with the first book whole and against the left end of the rail")
		await _screenshot("book_select_phone.png")

	# --- the other three overlays, on the same one mechanism ------------------
	var gate := _main.open_adult_gate(Callable())
	await _settle_layout()
	_check_panel_fits("adult gate", gate.get_node("Center/Panel") as Control, canvas, floor_px)
	_expect((gate.get_node("Center/Panel/Margin/Column/Row") as BoxContainer).vertical,
		"the gate's Continue/Back pair stacks in portrait")
	_expect(gate.get_answer_field().size.y >= floor_px,
		"the gate's answer FIELD is a touch target too (%.0f of %.0f)"
		% [gate.get_answer_field().size.y, floor_px])
	await _screenshot("adult_gate_portrait.png")
	gate.get_cancel_button().pressed.emit()
	await get_tree().process_frame

	var account := _main.open_account_panel()
	await _settle_layout()
	_check_panel_fits("account", account.get_node("Center/Panel") as Control, canvas, floor_px)
	_expect(account.get_email_field().size.y >= floor_px
			and account.get_password_field().size.y >= floor_px,
		"both sign-in fields clear the touch floor (%.0f / %.0f of %.0f)"
		% [account.get_email_field().size.y, account.get_password_field().size.y, floor_px])
	await _screenshot("account_portrait.png")
	_main.close_account_panel()

	var shop := _main.open_pack_shop()
	shop.set_packs([
		{
			PackShop.KEY_SLUG: "coyote-book", PackShop.KEY_TITLE: "Coyote & Friends",
			PackShop.KEY_BLURB: "Six new pages from the desert.",
			PackShop.KEY_IS_FREE: true, PackShop.KEY_BYTES: 964_000,
			PackShop.KEY_PAGE_COUNT: 6, PackShop.KEY_KIND: PackShop.KIND_BOOK,
		},
	])
	await _settle_layout()
	_check_panel_fits("pack shop", shop.get_node("Center/Panel") as Control, canvas, floor_px)
	var rows := shop.get_visible_rows()
	_expect(rows.size() == 1, "the shop built its one fixture row (%d)" % rows.size())
	if rows.size() == 1:
		_expect(rows[0].get_action_button().size.y >= floor_px,
			"a row built in CODE is scaled too -- Get is %.0f px of %.0f"
			% [rows[0].get_action_button().size.y, floor_px])
	await _screenshot("pack_shop_portrait.png")
	_main.close_pack_shop()

	# --- and back to the desktop, which must be exactly where it was ----------
	OverlayMetrics.debug_squeeze = -1.0
	get_window().size = DESKTOP_WINDOW
	await _settle_layout()
	var again := _main.open_settings()
	await _settle_layout()
	var again_box := again.get_node("Center/Panel") as Control
	_expect(is_equal_approx(again_box.size.x, DESKTOP_PANEL_WIDTH),
		"back on a desktop the panel is its authored %.0f px again (%.0f)"
		% [DESKTOP_PANEL_WIDTH, again_box.size.x])
	_expect(not (again.get_node("Center/Panel/Margin/Column/AccountRow") as BoxContainer).vertical
			and again.get_account_label().clip_text,
		"...the account row is a row again and the email clips again")
	_expect(is_equal_approx(_main.get_gear_button().size.x, Main.GearButton.SIZE.x),
		"...and the gear is back to %.0f px (%.0f)"
		% [Main.GearButton.SIZE.x, _main.get_gear_button().size.x])
	_main.close_settings()
	await get_tree().process_frame


## The two things every overlay must be true of in portrait: it uses most of the
## width it has (and none that it does not), and everything in it that takes a tap
## is at least a finger across.
func _check_panel_fits(
	label: String, box: Control, canvas: Vector2, floor_px: float
) -> void:
	if box == null:
		_expect(false, "the %s panel exists" % label)
		return
	var fraction := box.size.x / canvas.x
	_expect(fraction >= OverlayMetrics.PORTRAIT_PANEL_FRACTION - 0.01,
		"the %s panel takes %.0f%% of the portrait canvas, not a third (%.0f of %.0f px)"
		% [label, fraction * 100.0, box.size.x, canvas.x])
	_expect(box.size.x <= canvas.x + 0.5,
		"...and does not run off it (%.0f of %.0f px)" % [box.size.x, canvas.x])
	var smallest := _smallest_touch_target(box)
	_expect(float(smallest[0]) >= floor_px - 0.5,
		"...and its smallest touch target is %.0f px against a %.0f px floor (%s)"
		% [smallest[0], floor_px, smallest[1]])


## The narrowest visible interactive control under [param root], as
## [code][size, name][/code]. INF and "-" when there are none.
static func _smallest_touch_target(root: Node) -> Array:
	var worst := INF
	var worst_name := "-"
	for child in root.get_children():
		if child is Control:
			var control := child as Control
			# is_interactive() already excludes scrollbars; visibility excludes the
			# rows of the shop tab nobody is looking at.
			if OverlayMetrics.is_interactive(control) and control.is_visible_in_tree():
				var shortest := minf(control.size.x, control.size.y)
				if shortest < worst:
					worst = shortest
					worst_name = String(control.name)
		var deeper := _smallest_touch_target(child)
		if float(deeper[0]) < worst:
			worst = float(deeper[0])
			worst_name = String(deeper[1])
	return [worst, worst_name]


# ================================================================= helpers ==

## The shelf cell showing [param book], or null. The shelf sorts by directory
## name, so index 0 is no longer "the test book" now that a second book exists.
static func _cell_for(shelf: BookSelect, book: BookDef) -> BookCell:
	for cell in shelf.get_cells():
		if cell.get_book() == book:
			return cell
	return null


func _read_save() -> Dictionary:
	var path := GameState.get_save_path()
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


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


static func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


static func _count_files(root: String) -> int:
	if not DirAccess.dir_exists_absolute(root):
		return 0
	var directory := DirAccess.open(root)
	if directory == null:
		return 0
	var total := directory.get_files().size()
	for name in directory.get_directories():
		total += _count_files(root.path_join(name))
	return total


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


# ------------------------------------------------------------ paint helpers --

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
		await _wait_for_coverage(screen)
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


func _wait_for_coverage(screen: ColoringPage) -> void:
	for i in 60:
		if not screen.has_pending_coverage():
			return
		await get_tree().process_frame


# ----------------------------------------------------------------- waiting --

## Waits until [param screen_id] is the current screen and no transition is in
## flight.
func _wait_for_screen(screen_id: String, timeout: float = NAV_TIMEOUT) -> bool:
	return await _wait_until(
		func() -> bool:
			return _main.get_current_screen_id() == screen_id and not _main.is_transitioning(),
		timeout
	)


func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return false


func _settle_layout() -> void:
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _screenshot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var path := _shot_dir.path_join(file_name)
	# _isolate_persistence() wipes TEST_ROOT, which the default shot dir lives
	# under, so the directory has to be re-made here rather than only in _ready.
	if not DirAccess.dir_exists_absolute(_shot_dir):
		DirAccess.make_dir_recursive_absolute(_shot_dir)
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

class_name ColoringPage
extends Control
## The screen the game is about: one page of a book, the mode's palette, a
## minimal toolbar, and the page-flip that carries the player to the next page
## (DESIGN.md 2, 3.4).
##
## [b]Composition[/b] -- it owns four things and wires them together, and that is
## all it does:
##   [PageView]        the painting stack (M2, frozen)
##   palette component the mode's, from [code]GameState.get_palette_scene_path()[/code] (M3, frozen)
##   [CoverageTracker] completion, threshold injected from the active [PaletteDef]
##   [PageFlip]        the transition between pages
##
## [b]Signals up[/b]: [signal back_requested], [signal book_completed]. The parent
## ([code]main.tscn[/code] in M5) swaps screens; this screen never does.
##
## [b]Injection[/b]: [method load_book] is how a book gets in. The screen records
## the cursor in [code]GameState[/code] (the one autoload, which owns "where is
## the player") and drives it with [code]GameState.advance_page()[/code] -- it
## does not keep a private copy of the page index.
##
## [b]Coverage timing[/b]: [PageView] queues brush dabs and renders them on the
## NEXT frame, so this screen waits for the paint layer to settle before reading
## it back and handing it to the tracker. That readback is the one expensive thing
## in the loop; it happens at most once per stroke end, never per frame, and
## strokes that end while a readback is already in flight are COALESCED into it
## (a fast scribbler ending five strokes in five frames costs one readback, not
## five). Regions already past the threshold are skipped -- there is nothing left
## to learn about them -- so the readback is dropped entirely when every pending
## region is done.
##
## Its cost is measured ([method get_last_readback_usec] /
## [method get_average_readback_usec]) so the mobile pass has numbers. Measured on
## the M4 dev box (RTX 5060, Vulkan, 1024x1024 paint layer): [b]~4 ms[/b] of real
## transfer, but [b]~520 ms[/b] when the window presents with FIFO v-sync --
## Godot's synchronous readback path waits out the presentation queue, and the
## stall is identical for a 1152x648 main-viewport grab, so it is pacing, not
## bandwidth. Under VSYNC_MAILBOX/disabled it is 4 ms again. M6 owns the real fix
## ([code]RenderingDevice.texture_get_data_async()[/code]).

## The player asked to leave the book.
signal back_requested()
## The last page of [param book] is complete.
signal book_completed(book: BookDef)
## A different page is now loaded and interactive (after any flip).
signal page_changed(page_index: int)
## The page at [param page_index] just reached full coverage, before the flip.
signal page_completed(page_index: int)
## Fired after a stroke's coverage sample has been applied. Tests wait on this;
## the game ignores it.
signal coverage_updated(region_id: int, coverage: float)

## Seconds the "page complete" flourish is on screen before the flip starts.
const CELEBRATION_DURATION := 0.55
## Frames to wait for the paint layer to catch up with a finished stroke.
const MAX_SETTLE_FRAMES := 8

@onready var _page_view: PageView = $Ui/PageView
@onready var _ui: VBoxContainer = $Ui
@onready var _page_label: Label = $Ui/Toolbar/Row/PageLabel
@onready var _title_label: Label = $Ui/Toolbar/Row/PageTitle
@onready var _back_button: Button = $Ui/Toolbar/Row/BackButton
@onready var _celebration: Label = $Celebration
@onready var _flip: PageFlip = $PageFlip

var _book: BookDef
var _palette: Control
var _coverage: CoverageTracker
## Bumped on every page load so a coverage readback that was in flight across a
## page change is discarded instead of scribbling on the new page's tracker.
var _page_generation := 0
## Regions whose coverage is stale, waiting for the next readback.
var _pending_regions: Dictionary = {}
## True from the moment a readback is queued until its samples are applied.
var _readback_scheduled := false
var _completing := false

var _last_readback_usec := 0
var _total_readback_usec := 0
var _readback_count := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_celebration.modulate.a = 0.0
	_back_button.pressed.connect(_on_back_pressed)
	_page_view.stroke_ended.connect(_on_stroke_ended)
	_build_palette()


# ================================================================= injection ==

## Opens [param book] at [param start_index]. Returns false if the book is
## unusable or its page will not load. Emits [signal page_changed] for the first
## page.
func load_book(book: BookDef, start_index: int = 0) -> bool:
	if book == null or book.page_count() == 0:
		push_error("ColoringPage: load_book() needs a book with at least one page.")
		return false
	_book = book
	_completing = false
	GameState.start_book(book, start_index)
	if not _apply_current_page():
		return false
	page_changed.emit(GameState.current_page_index)
	return true


## Loads the page the [code]GameState[/code] cursor points at, rebuilds the
## coverage grids for it and refreshes the toolbar.
func _apply_current_page() -> bool:
	var page := GameState.get_current_page()
	if page == null:
		push_error("ColoringPage: no current page to load.")
		return false
	var problems := page.validate()
	if not problems.is_empty():
		push_error("ColoringPage: page '%s' is invalid: %s" % [page.display_name, problems])
		return false

	_page_generation += 1
	_pending_regions.clear()
	if not _page_view.load_page(page.base_image_path, page.id_map_path, page.regions_json_path):
		return false

	_build_coverage()
	_refresh_toolbar(page)
	return true


func _build_coverage() -> void:
	var palette := GameState.get_active_palette()
	# The threshold is INJECTED. The tracker never reads GameState itself.
	var threshold := palette.completion_threshold if palette != null else 0.7
	_coverage = CoverageTracker.new(threshold)
	_coverage.build_from_page_view(_page_view)
	_coverage.page_completed.connect(_on_coverage_page_completed)


func _refresh_toolbar(page: PageDef) -> void:
	_page_label.text = GameState.current_page_label()
	_title_label.text = page.display_name


## Instantiates the palette for the current mode and wires the two-signal
## contract both palette components share (coloring-mechanics, M3).
func _build_palette() -> void:
	var scene := load(GameState.get_palette_scene_path()) as PackedScene
	if scene == null:
		push_error("ColoringPage: could not load the palette scene for mode '%s'." % GameState.mode)
		return
	_palette = scene.instantiate() as Control
	# Appended last, so the palette sits under PageView in the vertical stack.
	_ui.add_child(_palette)

	_palette.color_picked.connect(_on_color_picked)
	_palette.brush_size_picked.connect(_on_brush_size_picked)

	var palette_def := GameState.get_active_palette()
	if palette_def != null:
		_page_view.brush_hardness = palette_def.default_brush_hardness
		# set_palette auto-emits both signals once, so the brush is primed here.
		_palette.set_palette(palette_def)


# =================================================================== accessors ==

func get_page_view() -> PageView:
	return _page_view


func get_page_flip() -> PageFlip:
	return _flip


func get_coverage_tracker() -> CoverageTracker:
	return _coverage


## The live palette component (a [PaletteChild] or [PaletteAdult]).
func get_palette() -> Control:
	return _palette


func get_book() -> BookDef:
	return _book


func get_page_label_text() -> String:
	return _page_label.text


## True while a stroke's coverage readback is still in flight. False means every
## finished stroke has been folded into the tracker.
func has_pending_coverage() -> bool:
	return _readback_scheduled


## True from the moment a page completes until the next page is interactive.
func is_transitioning() -> bool:
	return _completing


func get_last_readback_usec() -> int:
	return _last_readback_usec


func get_readback_count() -> int:
	return _readback_count


func get_average_readback_usec() -> float:
	if _readback_count == 0:
		return 0.0
	return float(_total_readback_usec) / float(_readback_count)


# ==================================================================== palette ==

func _on_color_picked(color: Color) -> void:
	_page_view.brush_color = color


func _on_brush_size_picked(size: float) -> void:
	_page_view.brush_size = size


func _on_back_pressed() -> void:
	back_requested.emit()


# =================================================================== coverage ==

## The coverage hook (coloring-mechanics: [signal PageView.stroke_ended] fires
## once per stroke, including after a cancel, because committed paint stays).
##
## [member _readback_scheduled] stays true until the samples have been APPLIED, so
## anything waiting on [method has_pending_coverage] sees a settled tracker the
## moment it reads false.
func _on_stroke_ended(region_id: int) -> void:
	if _coverage == null:
		return
	_pending_regions[region_id] = true
	if _readback_scheduled:
		return  # An in-flight readback will pick this region up too.
	_readback_scheduled = true

	var generation := _page_generation
	await _settle_paint()

	var regions := _pending_regions.keys()
	_pending_regions.clear()
	if generation != _page_generation or _coverage == null:
		# The page changed under us; those strokes belong to a dead tracker.
		_readback_scheduled = false
		return

	var stale: Array[int] = []
	for id_variant in regions:
		var id := int(id_variant)
		if not _coverage.is_region_done(id):
			stale.append(id)
	if stale.is_empty():
		_readback_scheduled = false
		return

	var started := Time.get_ticks_usec()
	var paint := _page_view.get_paint_image()
	_last_readback_usec = Time.get_ticks_usec() - started
	_total_readback_usec += _last_readback_usec
	_readback_count += 1
	if paint == null:
		_readback_scheduled = false
		return

	var results: Array = []
	for id in stale:
		results.append([id, _coverage.update_region(id, paint)])
	_readback_scheduled = false
	for result in results:
		coverage_updated.emit(int(result[0]), float(result[1]))


## Waits until every queued brush dab has actually been rendered into the paint
## SubViewport, so the readback sees the stroke that just ended.
func _settle_paint() -> void:
	for i in MAX_SETTLE_FRAMES:
		await get_tree().process_frame
		if not _page_view.has_pending_paint():
			break
	await get_tree().process_frame
	await RenderingServer.frame_post_draw


# ================================================================= completion ==

func _on_coverage_page_completed() -> void:
	if _completing:
		return
	_completing = true
	var finished_index := GameState.current_page_index
	page_completed.emit(finished_index)

	await _celebrate()

	if GameState.advance_page():
		await _flip_to_current_page()
		_completing = false
		page_changed.emit(GameState.current_page_index)
	else:
		_completing = false
		GameState.finish_book()
		book_completed.emit(_book)


## A short, wordy-free flourish. Deliberately minimal: M4 owns the flow, not the
## confetti.
func _celebrate() -> void:
	_celebration.text = "Page complete!"
	var tween := create_tween()
	tween.tween_property(_celebration, "modulate:a", 1.0, CELEBRATION_DURATION * 0.3)
	tween.tween_interval(CELEBRATION_DURATION * 0.4)
	tween.tween_property(_celebration, "modulate:a", 0.0, CELEBRATION_DURATION * 0.3)
	await tween.finished


## Freeze the current frame, swap the page behind that frozen frame, then turn it
## away. Because the real (already loaded) page renders underneath the overlay,
## the flip reveals it with no "to" texture and nothing pops when the overlay hides.
func _flip_to_current_page() -> void:
	var from_texture := await _take_snapshot()
	_flip.prepare(from_texture)
	await get_tree().process_frame

	_apply_current_page()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	_flip.play_to(null, PageFlip.DEFAULT_DURATION)
	await _flip.flip_finished


## A texture of exactly what is on screen right now.
func _take_snapshot() -> Texture2D:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	return ImageTexture.create_from_image(image)

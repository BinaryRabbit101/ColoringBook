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
##
## [b]M5 additions[/b] -- the two hooks M4's handoff called for, and nothing else:
##
## 1. [b]Live mode changes[/b]. [method _build_palette] used to run once in
##    [method _ready]; it now also runs on [signal GameState.mode_changed], and the
##    new mode's [member PaletteDef.completion_threshold] is re-injected into the
##    live [CoverageTracker]. Regions already done stay done (coverage is
##    monotonic and completion sticky), so lowering the bar can finish more
##    regions but raising it can never un-finish one.
## 2. [b]Paint save / restore[/b]. The screen is the only thing that can reach the
##    paint layer, so it owns the TIMING; [code]GameState[/code] owns the FILES.
##    Paint is handed to [code]GameState.save_page_paint()[/code] at exactly the
##    three moments the design allows a full readback: a page completing (before
##    the flip advances), leaving the book, and app quit. On page load, a saved
##    layer is composited back in and replayed through
##    [method CoverageTracker.update_all] so the tracker resumes where it was.
##
## [b]Why the restore needs an addition here at all[/b]: [PageView] is frozen and
## its public API is write-only-by-brush ([method PageView.begin_stroke] and
## friends) -- there is no "load a paint image" entry point, and replaying a saved
## layer as brush strokes is impossible. So this screen composites the image
## itself with [PaintRestoreQuad] below: a one-shot canvas item parented to the
## paint SubViewport for a single frame. It uses PREMULTIPLIED-ALPHA blending onto
## the freshly cleared (all-zero) render target, which makes the restore
## bit-exact -- with normal MIX blending every save/restore cycle would darken
## soft brush edges by another factor of alpha. M6 or a later unfreeze should move
## this into [PageView] as a proper [code]set_paint_image()[/code].

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
## Fired once the saved paint layer for [param page_index] has been composited and
## replayed into the tracker. [param restored] is false when there was nothing
## saved. Tests wait on this; the game ignores it.
signal paint_restored(page_index: int, restored: bool)
## Fired after the palette component has been rebuilt for a new mode.
signal palette_rebuilt(mode: String)

## Seconds the "page complete" flourish is on screen before the flip starts.
const CELEBRATION_DURATION := 0.55
## Frames to wait for the paint layer to catch up with a finished stroke.
const MAX_SETTLE_FRAMES := 8
## Node name of the paint SubViewport inside the frozen [PageView] scene. Named
## here because the restore path has to parent a canvas item into it -- see the
## class doc for why that is unavoidable while PageView is frozen.
const PAINT_VIEWPORT_NODE := "PaintViewport"


## One-shot full-page quad used to composite a saved paint layer back into the
## paint SubViewport.
##
## It must draw EXACTLY once. [CanvasItem] only redraws when it is asked to, so a
## plain [method _draw] with no [method CanvasItem.queue_redraw] loop does that --
## unlike [PaintCanvas], which re-queues every frame on purpose. Drawing twice
## would not be harmless: premultiplied blending is idempotent only for fully
## opaque pixels, and would brighten the feathered edge of every dab.
class PaintRestoreQuad extends Node2D:
	var texture: Texture2D
	var page_size: Vector2

	func _init(paint_texture: Texture2D, size: Vector2) -> void:
		texture = paint_texture
		page_size = size
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		var canvas_material := CanvasItemMaterial.new()
		# The render target is transparent black at this point, so
		# out = src + dst * (1 - src.a) reproduces the saved image exactly.
		canvas_material.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
		material = canvas_material

	func _draw() -> void:
		if texture == null:
			return
		draw_texture_rect(texture, Rect2(Vector2.ZERO, page_size), false)

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

## True while a saved paint layer is being composited back into the page.
var _restoring := false
## Set when the RESTORED paint alone already completed the page. The completion
## cascade (celebrate -> flip) is then suppressed: fireworks belong to the stroke
## the player just made, not to re-opening a book they already finished.
var _pre_completed := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_celebration.modulate.a = 0.0
	_back_button.pressed.connect(_on_back_pressed)
	_page_view.stroke_ended.connect(_on_stroke_ended)
	# M5: the mode is changeable mid-book, so the palette is rebuilt on demand
	# rather than only here.
	GameState.mode_changed.connect(_on_mode_changed)
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
	_pre_completed = false
	if not _page_view.load_page(page.base_image_path, page.id_map_path, page.regions_json_path):
		return false

	_build_coverage()
	_refresh_toolbar(page)
	# Deliberately NOT awaited: load_book() and the flip both call this and both
	# need a plain bool back. The restore runs over the next few frames; anything
	# that needs it settled waits on `paint_restored` / has_pending_restore().
	_restore_saved_paint(GameState.current_page_index)
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


# ================================================== paint restore (M5 hook) ==

## Composites this page's saved paint layer (if any) back into the paint
## SubViewport and replays it through the tracker, so a resumed page comes back
## with both its pixels AND its coverage.
##
## The tracker is fed the IMAGE WE ALREADY HAVE rather than a fresh
## [method PageView.get_paint_image] readback: it is the same data, it costs
## nothing, and it cannot race the compositing frame.
func _restore_saved_paint(page_index: int) -> void:
	if _book == null:
		paint_restored.emit(page_index, false)
		return
	var image := GameState.load_page_paint(_book, page_index)
	if image == null:
		paint_restored.emit(page_index, false)
		return

	var generation := _page_generation
	_restoring = true
	var page_size := _page_view.get_page_size()
	if image.get_width() != page_size.x or image.get_height() != page_size.y:
		push_warning(
			"ColoringPage: saved paint for page %d is %dx%d but the page is %s; ignoring it."
			% [page_index + 1, image.get_width(), image.get_height(), page_size]
		)
		_restoring = false
		paint_restored.emit(page_index, false)
		return

	# One frame so PageView's CLEAR_MODE_ONCE has actually cleared the target
	# before we draw the saved pixels onto it.
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	# The screen can be swapped out from under a restore (the parent frees it, or
	# a flip loads the next page); either way this restore is for a dead page.
	if generation != _page_generation or not is_inside_tree() or not is_instance_valid(_page_view):
		_restoring = false
		return

	var viewport := _page_view.get_node_or_null(PAINT_VIEWPORT_NODE) as SubViewport
	if viewport == null:
		push_error("ColoringPage: PageView has no %s; cannot restore paint." % PAINT_VIEWPORT_NODE)
		_restoring = false
		paint_restored.emit(page_index, false)
		return

	var quad := PaintRestoreQuad.new(ImageTexture.create_from_image(image), Vector2(page_size))
	quad.name = "PaintRestoreQuad"
	viewport.add_child(quad)
	if is_inside_tree():
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	viewport.remove_child(quad)
	quad.queue_free()

	if generation != _page_generation or _coverage == null:
		_restoring = false
		return
	_coverage.update_all(image)
	_restoring = false
	paint_restored.emit(page_index, true)


## True while a saved paint layer is still being composited back in.
func has_pending_restore() -> bool:
	return _restoring


## True when the restored paint alone already completed this page, so the
## completion cascade was suppressed (see [member _pre_completed]).
func is_page_pre_completed() -> bool:
	return _pre_completed


# ================================================== paint persistence (M5) ==

## Writes the current page's paint layer and records its status. Synchronous: it
## reads the paint layer back exactly once, so callers must only reach here at a
## save point (leaving the book, quitting). Returns false when there is nothing
## worth writing.
func persist_current_page() -> bool:
	return _persist_page(GameState.current_page_index)


## Same, but waits for queued dabs to render first. Use it when an [code]await[/code]
## is available -- a stroke that ended this frame is not in the SubViewport yet.
func persist_current_page_settled() -> bool:
	if _book == null or not _page_view.is_page_loaded():
		return false
	await _settle_paint()
	return _persist_page(GameState.current_page_index)


func _persist_page(page_index: int) -> bool:
	if _book == null or page_index < 0 or not _page_view.is_page_loaded():
		return false
	# Nothing painted and nothing saved before: skip the readback entirely rather
	# than write a megabyte of transparent pixels.
	if _status_for_page(page_index) == GameState.STATUS_UNTOUCHED \
			and not GameState.has_page_paint(_book, page_index):
		return false
	var image := _page_view.get_paint_image()
	if image == null:
		return false
	var saved := GameState.save_page_paint(_book, page_index, image)
	GameState.mark_page_status(_book, page_index, _status_for_page(page_index))
	return saved


## A page with any coverage at all is "in_progress"; the tracker decides
## "complete". Statuses only ever move forward (GameState refuses downgrades).
func _status_for_page(page_index: int) -> String:
	if _coverage == null:
		return GameState.STATUS_UNTOUCHED
	if _coverage.is_page_complete():
		return GameState.STATUS_COMPLETE
	if _coverage.page_coverage() > 0.0:
		return GameState.STATUS_IN_PROGRESS
	return GameState.STATUS_UNTOUCHED


# ================================================================ mode swap ==

## The mode changed while this screen is alive (settings -> mode select). Swap the
## palette component and re-inject the new completion threshold, without touching
## the page or the paint already on it.
func _on_mode_changed(new_mode: String) -> void:
	if is_instance_valid(_palette):
		_ui.remove_child(_palette)
		_palette.queue_free()
		_palette = null
	_build_palette()

	var palette_def := GameState.get_active_palette()
	if _coverage != null and palette_def != null:
		_coverage.set_threshold(palette_def.completion_threshold)
		# Re-settle: a LOWER threshold can finish regions that were already past
		# it. update_all is monotonic, so a higher threshold changes nothing.
		if _page_view.is_page_loaded():
			var image := _page_view.get_paint_image()
			if image != null:
				_coverage.update_all(image)
	palette_rebuilt.emit(new_mode)


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


## Leaving the book is one of the three save points: flush the paint layer before
## the parent frees this screen.
func _on_back_pressed() -> void:
	persist_current_page()
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
	if _restoring:
		# The page was ALREADY finished when it was saved. Restoring it must not
		# celebrate and flip the player past a page they only came back to look at.
		_pre_completed = true
		GameState.mark_page_status(_book, GameState.current_page_index, GameState.STATUS_COMPLETE)
		return
	if _completing:
		return
	_completing = true
	var finished_index := GameState.current_page_index
	page_completed.emit(finished_index)

	# Save point: the finished page's pixels are written BEFORE the cursor moves,
	# so the file always describes the page it is named after.
	await _settle_paint()
	_persist_page(finished_index)

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

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
## [b]M6: that readback is now asynchronous.[/b] The synchronous
## [method PageView.get_paint_image] blocked the main thread for ~350-530 ms per
## call under the default FIFO v-sync (presentation pacing, not bandwidth -- the
## transfer itself is ~1.5 ms), which made every stroke end a visible hitch.
## [method PageView.request_paint_image] queues the copy through
## [method RenderingDevice.texture_get_data_async] instead: the call returns in
## well under a millisecond and the [Image] arrives on the main thread a couple of
## frames later ([AsyncReadback] has the details). Coalescing and
## skip-when-every-pending-region-is-done are unchanged; the only behavioural
## difference is that a region can now finish a few frames after the stroke that
## finished it, which the completion cascade already tolerated. On a renderer with
## no [RenderingDevice] (Compatibility/OpenGL) the code silently falls back to the
## blocking readback. [method get_last_readback_usec] reports the BLOCKING part of
## the last readback, which is what the mobile pass cares about.
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
## soft brush edges by another factor of alpha. A later unfreeze should move this
## into [PageView] as a proper [code]set_paint_image()[/code].
##
## [b]M6 additions[/b] -- the mobile pass, on top of the async readback above:
##
## 1. [b]Page navigation[/b] (the gap M5 flagged). The toolbar carries prev/next
##    arrows, enabled only for pages the player has ALREADY reached -- see
##    [method can_go_to_page]. Navigating saves the current page's paint first and
##    then swaps INSTANTLY: the flip is the reward for finishing a page, not a
##    tax on flicking back to look at one.
## 2. [b]Portrait[/b]. The toolbar drops its centred page title below
##    [constant NARROW_TOOLBAR_WIDTH] so five controls still fit across a 720 px
##    phone; the palette component already scrolls horizontally. Nothing else
##    needed changing -- the screen was already one vertical box.
##
## [b]Backlog additions (BL-4, BL-6, BL-7)[/b]:
##
## 1. [b]No auto-flip.[/b] Completing a page used to celebrate for half a second
##    and then turn the page for the player. It now STAYS on the finished page
##    with a persistent "page complete" state up, and unlocks the next-page arrow
##    ([method can_go_to_page] already allowed exactly one page forward off a
##    completed page). Pressing it plays the flip -- see [method go_to_page]: a
##    forward step off a finished page is the one navigation that gets the
##    ceremony, every other jump still swaps instantly. Finishing the LAST page
##    still reports [signal book_completed] straight away; there is no next page
##    to choose to turn to, and the celebration screen is the reward.
## 2. [b]Autosave and a Save button.[/b] The screen owns the paint layer, so it
##    owns the timing: it listens to [signal GameState.autosave_due] and flushes
##    the page, DEFERRING past a stroke in progress (never read the paint layer
##    mid-stroke -- the reader would race the stamp batch and the save would land
##    half a stroke in). [member _paint_dirty] means an idle page costs nothing.
##    The toolbar's Save button runs the same path and puts "Saved!" on screen.
## 3. [b]Start over.[/b] The toolbar's second new button resets THIS page only:
##    [method PageView.clear_paint], a fresh [CoverageTracker], and
##    [method GameState.erase_page_progress] to make the reset stick on disk. It
##    is guarded by an in-game two-button confirm overlay (never an OS/JS modal --
##    this ships to the web, and those do not exist there).

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
## The page's paint layer was written. [param manual] is true when the player
## asked for it rather than a timer or a save point. Tests wait on this.
signal page_saved(page_index: int, manual: bool)
## [param page_index] was reset to blank by the player (BL-7).
signal page_restarted(page_index: int)

## Seconds the "page complete" state takes to pop in. It then STAYS up: BL-4
## turned the flourish into a state the player leaves when they choose, not a
## countdown to an automatic flip.
const CELEBRATION_DURATION := 0.55
## Frames to wait for the paint layer to catch up with a finished stroke.
const MAX_SETTLE_FRAMES := 8
## Frames an async readback is given to come back before it is written off. The
## driver delivers in ~2; this only exists so a lost callback can never leave
## [method has_pending_coverage] stuck true forever.
const MAX_READBACK_FRAMES := 30
## Below this screen width the toolbar drops its centred page title, so the back
## button, the page counter and the two nav arrows still fit (M6, portrait).
const NARROW_TOOLBAR_WIDTH := 620.0
## Node name of the paint SubViewport inside the frozen [PageView] scene. Named
## here because the restore path has to parent a canvas item into it -- see the
## class doc for why that is unavoidable while PageView is frozen.
const PAINT_VIEWPORT_NODE := "PaintViewport"
## Seconds the "Saved!" / "Page cleared" toast stays readable before it fades.
const TOAST_SECONDS := 1.6


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
@onready var _prev_button: Button = $Ui/Toolbar/Row/PrevButton
@onready var _next_button: Button = $Ui/Toolbar/Row/NextButton
@onready var _save_button: Button = $Ui/Toolbar/Row/SaveButton
@onready var _reset_button: Button = $Ui/Toolbar/Row/ResetButton
@onready var _celebration: Control = $Celebration
@onready var _celebration_title: Label = $Celebration/Center/Column/Title
@onready var _celebration_hint: Label = $Celebration/Center/Column/Hint
@onready var _toast: PanelContainer = $Toast
@onready var _toast_label: Label = $Toast/Label
@onready var _reset_confirm: Control = $ResetConfirm
@onready var _reset_scrim: Button = $ResetConfirm/Scrim
@onready var _reset_confirm_button: Button = $ResetConfirm/Center/Panel/Margin/Column/Row/ConfirmButton
@onready var _reset_cancel_button: Button = $ResetConfirm/Center/Panel/Margin/Column/Row/CancelButton
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
## Set when a readback had to use the blocking path (no RenderingDevice).
var _last_readback_was_blocking := false
## True while [method go_to_page] is saving and swapping pages.
var _navigating := false

## True while a saved paint layer is being composited back into the page.
var _restoring := false
## Set when the RESTORED paint alone already completed the page. The completion
## cascade is then suppressed: fireworks belong to the stroke the player just
## made, not to re-opening a book they already finished.
var _pre_completed := false

## True once a stroke has landed paint that has not been written to disk yet.
## Cleared by every successful write. The interval autosave skips a clean page --
## an idle book must not cost a readback and a megabyte of PNG every 45 s.
var _paint_dirty := false
## Set when a save was asked for while a stroke was still down. Never read the
## paint layer mid-stroke: the save would capture half a stroke and the readback
## would race the stamp batch. [method _on_stroke_ended] picks this up instead.
var _save_deferred := false
## True when the deferred save should announce itself as a manual one.
var _deferred_save_manual := false
## True while a save started by [method save_page_now] is in flight.
var _saving := false
## True while the page is showing its persistent "complete" state (BL-4).
var _celebrating := false
var _celebration_tween: Tween
var _toast_tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_celebration.modulate.a = 0.0
	_celebration.visible = false
	_toast.modulate.a = 0.0
	_toast.visible = false
	_reset_confirm.visible = false
	_back_button.pressed.connect(_on_back_pressed)
	_prev_button.pressed.connect(_on_prev_pressed)
	_next_button.pressed.connect(_on_next_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_reset_button.pressed.connect(_on_reset_pressed)
	_reset_scrim.pressed.connect(_on_reset_cancelled)
	_reset_cancel_button.pressed.connect(_on_reset_cancelled)
	_reset_confirm_button.pressed.connect(_on_reset_confirmed)
	_page_view.stroke_ended.connect(_on_stroke_ended)
	# Touching the page dismisses the finished-page state: the player has decided
	# to keep colouring, and the headline must not sit over their work.
	_page_view.region_locked.connect(_on_region_locked)
	# M5: the mode is changeable mid-book, so the palette is rebuilt on demand
	# rather than only here.
	GameState.mode_changed.connect(_on_mode_changed)
	# BL-6: the interval autosave announces the moment; this screen is what can
	# actually reach the pixels.
	GameState.autosave_due.connect(_on_autosave_due)
	# M6: portrait windows get a leaner toolbar.
	resized.connect(_apply_toolbar_layout)
	_apply_toolbar_layout()
	_refresh_nav()
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
	_paint_dirty = false
	_save_deferred = false
	_hide_celebration()
	_set_reset_confirming(false)
	# The DISPLAY image is what the player sees; a page mapped from a separate
	# masking image (BL-9) still only ever renders this one.
	if not _page_view.load_page(page.display_image_path, page.id_map_path, page.regions_json_path):
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
	var threshold := (
		palette.completion_threshold if palette != null else CoverageTracker.DEFAULT_THRESHOLD
	)
	_coverage = CoverageTracker.new(threshold)
	_coverage.build_from_page_view(_page_view)
	_coverage.page_completed.connect(_on_coverage_page_completed)


func _refresh_toolbar(page: PageDef) -> void:
	_page_label.text = GameState.current_page_label()
	_title_label.text = page.display_name
	_refresh_nav()


# ========================================================= page navigation ==
# The gap M5 flagged: a finished book was a one-way street. The rule is "you may
# revisit, you may not skip ahead": any page the player has ALREADY reached is
# reachable again, plus the one page after a page they just finished.

## Highest page index the player has reached in this book. The maximum of: the
## page they are on, the cursor recorded in the save, and the last page with a
## status other than "untouched". Taking the maximum of all three means neither a
## save written mid-book nor an in-memory jump can hide a page that was reached.
func furthest_reached_index() -> int:
	if _book == null or _book.page_count() == 0:
		return 0
	var furthest := GameState.current_page_index
	var progress := GameState.get_book_progress(GameState.book_key(_book))
	furthest = maxi(furthest, int(progress.get("current_page_index", 0)))
	var pages: Array = progress.get("pages", [])
	for i in pages.size():
		if String(pages[i]) != GameState.STATUS_UNTOUCHED:
			furthest = maxi(furthest, i)
	return clampi(furthest, 0, _book.page_count() - 1)


## True when [method go_to_page] would accept [param page_index]: it is a real
## page, it is not the current one, and it has either been reached before or is
## the very next page after a page that is now complete.
func can_go_to_page(page_index: int) -> bool:
	if _book == null or not _book.has_page(page_index):
		return false
	if page_index == GameState.current_page_index:
		return false
	if page_index <= furthest_reached_index():
		return true
	# Forward by exactly one, only because the page in hand is finished.
	return (
		page_index == GameState.current_page_index + 1
		and _coverage != null
		and _coverage.is_page_complete()
	)


## Saves the open page and swaps to [param page_index].
## Returns false when the jump is not allowed or the page fails to load.
##
## [b]One jump gets the flip[/b] (BL-4): stepping FORWARD off a page the player
## has just finished. That is the moment the page turn belongs to -- it is the
## reward for completing the page, now taken when the player asks for it instead
## of being pushed on them the instant the last region filled. Every other jump
## (back to an earlier page, forward to a page already reached) still swaps
## instantly: flicking back to look at something must not cost a second of
## ceremony.
func go_to_page(page_index: int) -> bool:
	if _completing or _navigating or not can_go_to_page(page_index):
		return false
	_navigating = true
	_set_nav_enabled(false)
	var with_flip := (
		page_index == GameState.current_page_index + 1
		and _coverage != null
		and _coverage.is_page_complete()
	)
	# Save first: the file must always describe the page it is named after.
	await persist_current_page_settled()
	if not is_inside_tree():
		_navigating = false
		return false

	var loaded := true
	if with_flip:
		_hide_celebration()
		loaded = await _flip_to_page(page_index)
	else:
		GameState.set_page_index(page_index)
		loaded = _apply_current_page()
	_navigating = false
	_refresh_nav()
	if loaded:
		page_changed.emit(GameState.current_page_index)
	return loaded


func _on_prev_pressed() -> void:
	await go_to_page(GameState.current_page_index - 1)


func _on_next_pressed() -> void:
	await go_to_page(GameState.current_page_index + 1)


func _refresh_nav() -> void:
	if not is_instance_valid(_prev_button):
		return
	var busy := _completing or _navigating
	_prev_button.disabled = busy or not can_go_to_page(GameState.current_page_index - 1)
	_next_button.disabled = busy or not can_go_to_page(GameState.current_page_index + 1)
	_save_button.disabled = busy or _saving
	_reset_button.disabled = busy


func _set_nav_enabled(enabled: bool) -> void:
	_prev_button.disabled = not enabled
	_next_button.disabled = not enabled
	_save_button.disabled = not enabled
	_reset_button.disabled = not enabled


## Portrait toolbar: five controls do not fit across a 720 px phone, and the page
## title is the one that carries no action, so it is what goes.
func _apply_toolbar_layout() -> void:
	if not is_instance_valid(_title_label):
		return
	_title_label.visible = size.x >= NARROW_TOOLBAR_WIDTH


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
	# A page that comes back already finished re-enables the next-page arrow.
	_refresh_nav()
	paint_restored.emit(page_index, true)


## True while a saved paint layer is still being composited back in.
func has_pending_restore() -> bool:
	return _restoring


## True when the restored paint alone already completed this page, so the
## completion cascade was suppressed (see [member _pre_completed]).
func is_page_pre_completed() -> bool:
	return _pre_completed


# ================================================== paint persistence (M5) ==

## Writes the current page's paint layer and records its status, BLOCKING.
##
## [b]This is the app-quit path and only that.[/b] On
## [code]NOTIFICATION_WM_CLOSE_REQUEST[/code] there is no next frame to wait for --
## the window is going away -- so the async readback has nowhere to deliver. A
## bounded synchronous readback (one call, hundreds of milliseconds at worst, on a
## frame the player will never see) is the right trade there: losing the last
## strokes of a page would be a real bug, a stall during teardown is not.
## Everywhere the app keeps running, use [method persist_current_page_settled].
func persist_current_page() -> bool:
	return _persist_page(GameState.current_page_index)


## Non-blocking save: waits for queued dabs to render, then reads the paint layer
## back asynchronously. This is the save path for every moment the app keeps
## running -- leaving the book, finishing a page, navigating between pages.
func persist_current_page_settled() -> bool:
	if _book == null or not _page_view.is_page_loaded():
		return false
	return await _persist_page_async(GameState.current_page_index)


## True when there is nothing worth writing for [param page_index]: nothing
## painted and nothing saved before, so a save would only cost a readback and a
## megabyte of transparent pixels.
func _has_nothing_to_persist(page_index: int) -> bool:
	return (
		_status_for_page(page_index) == GameState.STATUS_UNTOUCHED
		and not GameState.has_page_paint(_book, page_index)
	)


func _persist_page(page_index: int) -> bool:
	if _book == null or page_index < 0 or not _page_view.is_page_loaded():
		return false
	if _has_nothing_to_persist(page_index):
		return false
	var image := _page_view.get_paint_image()
	return _write_paint(page_index, image)


func _persist_page_async(page_index: int) -> bool:
	if _book == null or page_index < 0 or not _page_view.is_page_loaded():
		return false
	if _has_nothing_to_persist(page_index):
		return false
	var generation := _page_generation
	await _settle_paint()
	if generation != _page_generation or not is_inside_tree():
		return false
	var image := await _read_paint_async()
	if generation != _page_generation or not is_inside_tree():
		return false
	return _write_paint(page_index, image)


func _write_paint(page_index: int, image: Image) -> bool:
	if image == null:
		return false
	var saved := GameState.save_page_paint(_book, page_index, image)
	GameState.mark_page_status(_book, page_index, _status_for_page(page_index))
	if saved and page_index == GameState.current_page_index:
		_paint_dirty = false
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


# ============================================= autosave & manual save (BL-6) ==
# The event-driven save points (page complete, leaving the book, navigating,
# quitting) are unchanged. What is new is the safety net under them: an interval
# tick from GameState, and a button the player can press.
#
# Both land on the same method, and both obey the same rule: NEVER read the paint
# layer while a stroke is down. A readback taken mid-stroke races the stamp batch
# and writes half a stroke to disk; worse, the coverage cycle is already using the
# readback queue. So a save asked for mid-stroke is REMEMBERED and runs from
# stroke_ended instead, which is exactly where the paint layer is known settled.

## Writes this page's paint layer and progress, unless a stroke is in progress
## (then it is deferred until that stroke ends) or nothing has changed since the
## last write. [param manual] only affects the on-screen feedback.
## Returns true when a write actually happened.
func save_page_now(manual: bool = false) -> bool:
	if _book == null or not _page_view.is_page_loaded():
		return false
	if _page_view.is_stroke_active() or _readback_scheduled:
		_save_deferred = true
		_deferred_save_manual = _deferred_save_manual or manual
		if manual:
			_show_toast("Saving…")
		return false
	if not _paint_dirty:
		# Nothing new on the page. Still write the small progress JSON on a manual
		# press, so "Save" is never a no-op the player cannot see.
		if manual:
			GameState.save_now()
			_show_toast("Saved!")
			page_saved.emit(GameState.current_page_index, true)
		return false

	_saving = true
	_refresh_nav()
	var page_index := GameState.current_page_index
	var written := await _persist_page_async(page_index)
	_saving = false
	if not is_inside_tree():
		return written
	_refresh_nav()
	if written:
		GameState.save_now()
		page_saved.emit(page_index, manual)
	if manual:
		_show_toast("Saved!" if written else "Nothing to save")
	return written


func _on_save_pressed() -> void:
	await save_page_now(true)


## The interval tick. Silent by design -- an autosave the player notices is a
## stutter, not a feature.
func _on_autosave_due() -> void:
	await save_page_now(false)


## True while a save is waiting for the stroke in progress to end.
func has_deferred_save() -> bool:
	return _save_deferred


## True when the page has strokes that are not on disk yet.
func has_unsaved_paint() -> bool:
	return _paint_dirty


# =========================================================== start over (BL-7) ==
# Resets THIS page and nothing else: the paint layer, the coverage tracker, the
# saved PNG and the saved status. Guarded by a two-button in-game overlay -- never
# an OS or JavaScript modal, because this ships to the web where those either do
# not exist or block the whole canvas.

func _on_reset_pressed() -> void:
	_set_reset_confirming(true)


func _on_reset_cancelled() -> void:
	_set_reset_confirming(false)


func _on_reset_confirmed() -> void:
	_set_reset_confirming(false)
	restart_current_page()


## Shows or hides the confirm overlay. Public so a parent can reset the screen and
## tests can assert the guard.
func _set_reset_confirming(confirming: bool) -> void:
	if is_instance_valid(_reset_confirm):
		_reset_confirm.visible = confirming


func is_reset_confirming() -> bool:
	return is_instance_valid(_reset_confirm) and _reset_confirm.visible


## Clears the current page back to blank paper: the paint SubViewport, the
## coverage tracker, the saved PNG and the saved status. Other pages, and the
## rest of the book's progress, are untouched. Returns false when there is no page.
func restart_current_page() -> bool:
	if _book == null or not _page_view.is_page_loaded():
		return false
	var page_index := GameState.current_page_index
	# Bump the generation FIRST: a coverage readback already in flight was taken
	# from the paint layer we are about to wipe, and must not be folded into the
	# fresh tracker.
	_page_generation += 1
	_pending_regions.clear()
	_paint_dirty = false
	_save_deferred = false
	_pre_completed = false
	_completing = false
	_hide_celebration()

	_page_view.clear_paint()
	GameState.erase_page_progress(_book, page_index)
	_build_coverage()
	_refresh_nav()
	_show_toast("Page cleared")
	page_restarted.emit(page_index)
	return true


# ==================================================================== feedback ==

## A small, short-lived message over the page ("Saved!", "Page cleared"). The
## whole of the UI feedback this screen owns -- everything else is the page.
func _show_toast(text: String) -> void:
	if not is_instance_valid(_toast):
		return
	_toast_label.text = text
	_toast.visible = true
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast.modulate.a = 0.0
	_toast_tween = create_tween()
	_toast_tween.tween_property(_toast, "modulate:a", 1.0, 0.15)
	_toast_tween.tween_interval(TOAST_SECONDS)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.35)
	_toast_tween.tween_callback(func() -> void:
		if is_instance_valid(_toast):
			_toast.visible = false
	)


func get_toast_text() -> String:
	return _toast_label.text


## True from the moment a toast is put up until its fade-out has finished. The
## fade-IN is not waited on: the node is shown synchronously, and a caller that
## just triggered the message must not have to wait out an animation to see it.
func is_toast_visible() -> bool:
	return is_instance_valid(_toast) and _toast.visible


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
	# Emitted BEFORE the re-settle: the palette and the threshold are already the
	# new mode's, and callers must not have to wait out a readback to see that.
	palette_rebuilt.emit(new_mode)

	# Re-settle: a LOWER threshold can finish regions that were already past it.
	# update_all is monotonic, so a higher threshold changes nothing. M6: async,
	# so changing mode never stalls the frame it happens on.
	if _coverage == null or palette_def == null or not _page_view.is_page_loaded():
		return
	var generation := _page_generation
	var image := await _read_paint_async()
	if image == null or generation != _page_generation or _coverage == null:
		return
	_coverage.update_all(image)


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


## True from the moment a page completes until the next page is interactive, and
## while a [method go_to_page] jump is saving and swapping.
func is_transitioning() -> bool:
	return _completing or _navigating


## True only while a prev/next jump is in flight.
func is_navigating() -> bool:
	return _navigating


## Microseconds the main thread was BLOCKED by the last paint readback. With the
## async path this is the cost of queueing the request (tens of microseconds);
## it is the full transfer only on the synchronous fallback.
func get_last_readback_usec() -> int:
	return _last_readback_usec


## True when the last readback had to use the blocking fallback because the
## renderer exposes no [RenderingDevice].
func was_last_readback_blocking() -> bool:
	return _last_readback_was_blocking


## Whether this build can read the paint layer back without blocking at all.
func is_async_readback_available() -> bool:
	return _page_view.is_async_paint_readback_available()


func get_prev_page_button() -> Button:
	return _prev_button


func get_next_page_button() -> Button:
	return _next_button


func get_back_button() -> Button:
	return _back_button


func get_save_button() -> Button:
	return _save_button


func get_reset_button() -> Button:
	return _reset_button


func get_reset_confirm_button() -> Button:
	return _reset_confirm_button


func get_reset_cancel_button() -> Button:
	return _reset_cancel_button


## True while the toolbar is in its narrow (portrait) form.
func is_toolbar_narrow() -> bool:
	return not _title_label.visible


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


## Leaving the book is one of the save points: flush the paint layer before the
## parent frees this screen.
##
## The save is AWAITED before [signal back_requested] goes out, and that ordering
## is load-bearing now that the readback is async: the parent frees this screen at
## the end of its fade-out, and a callback delivered to a freed screen would lose
## the page. Three or four frames of latency before the fade starts is invisible;
## losing a page is not.
func _on_back_pressed() -> void:
	_back_button.disabled = true
	_set_nav_enabled(false)
	await persist_current_page_settled()
	back_requested.emit()


# =================================================================== coverage ==

## The coverage hook (coloring-mechanics: [signal PageView.stroke_ended] fires
## once per stroke, including after a cancel, because committed paint stays).
##
## [member _readback_scheduled] stays true until the samples have been APPLIED, so
## anything waiting on [method has_pending_coverage] sees a settled tracker the
## moment it reads false.
func _on_stroke_ended(region_id: int) -> void:
	# BL-6: the page now has paint that is not on disk, whatever the coverage
	# cycle below decides to do about it.
	_paint_dirty = true
	if _coverage == null:
		await _run_deferred_save()
		return
	_pending_regions[region_id] = true
	if _readback_scheduled:
		return  # An in-flight readback will pick this region up too.
	_readback_scheduled = true
	await _run_coverage_cycles()
	_readback_scheduled = false
	await _run_deferred_save()


## Runs a save that was asked for while the player was mid-stroke (BL-6). By the
## time this is reached the stroke has ended AND its coverage has settled, so the
## image written is a whole number of strokes.
func _run_deferred_save() -> void:
	if not _save_deferred or not is_inside_tree():
		return
	_save_deferred = false
	var manual := _deferred_save_manual
	_deferred_save_manual = false
	await save_page_now(manual)


## A stroke started: the player is colouring again, so the finished-page state
## gets out of their way.
func _on_region_locked(_region_id: int) -> void:
	if _celebrating:
		_hide_celebration()


## Drains [member _pending_regions], one readback per pass.
##
## The loop is what makes coalescing correct now that the readback is ASYNC: a
## stroke that ends during the two-frame flight lands in [member _pending_regions]
## after this pass has already taken its batch, and would simply be forgotten if
## the cycle just stopped -- [member _readback_scheduled] was true, so it never
## started a cycle of its own. Looping until the pending set is empty means a fast
## scribbler still costs one readback per batch, never one per stroke, and never
## loses a region.
func _run_coverage_cycles() -> void:
	while not _pending_regions.is_empty():
		var generation := _page_generation
		await _settle_paint()
		if not is_inside_tree():
			return

		var regions := _pending_regions.keys()
		_pending_regions.clear()
		if generation != _page_generation or _coverage == null:
			return  # The page changed under us; those strokes belong to a dead tracker.

		# Regions already past the threshold have nothing left to teach us.
		var stale: Array[int] = []
		for id_variant in regions:
			var id := int(id_variant)
			if not _coverage.is_region_done(id):
				stale.append(id)
		if stale.is_empty():
			continue

		var paint := await _read_paint_async()
		if generation != _page_generation or _coverage == null or not is_inside_tree():
			return
		if paint == null:
			continue

		var results: Array = []
		for id in stale:
			results.append([id, _coverage.update_region(id, paint)])
		# Completing the page unlocks the next-page arrow.
		_refresh_nav()
		for result in results:
			coverage_updated.emit(int(result[0]), float(result[1]))


## The paint layer, read back WITHOUT blocking the main thread (M6).
##
## [method PageView.request_paint_image] queues the copy and returns immediately;
## the image arrives a couple of frames later, which the [code]await[/code] loop
## below waits out at zero cost -- those are frames the game renders normally.
## Only when the renderer has no [RenderingDevice] does this fall back to the old
## blocking call. [member _last_readback_usec] therefore records the time the main
## thread was actually STUCK, which is the number the mobile pass is about.
func _read_paint_async() -> Image:
	var delivery: Array[Image] = []
	var started := Time.get_ticks_usec()
	var queued := _page_view.request_paint_image(func(image: Image) -> void:
		# Arrays are reference types, so the lambda's by-value capture still
		# reaches the caller's cell (the M4 lambda gotcha, used deliberately).
		delivery.append(image)
	)
	_last_readback_usec = Time.get_ticks_usec() - started
	_last_readback_was_blocking = not queued

	if not queued:
		started = Time.get_ticks_usec()
		var image := _page_view.get_paint_image()
		_last_readback_usec = Time.get_ticks_usec() - started
		_record_readback()
		return image

	var frames := 0
	while delivery.is_empty() and frames < MAX_READBACK_FRAMES and is_inside_tree():
		frames += 1
		await get_tree().process_frame
	_record_readback()
	if delivery.is_empty():
		push_warning(
			"ColoringPage: the async paint readback did not arrive within %d frames."
			% MAX_READBACK_FRAMES
		)
		return null
	return delivery[0]


func _record_readback() -> void:
	_total_readback_usec += _last_readback_usec
	_readback_count += 1


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

## The page just filled up.
##
## [b]BL-4: this no longer turns the page.[/b] It saves, then puts the page into a
## persistent "complete" state and stops. The next-page arrow is now enabled (the
## "exactly one page forward off a finished page" rule in [method can_go_to_page]
## was always there), and pressing it is what plays the flip. The one exception is
## the LAST page: there is nothing to turn to, so the book's own celebration
## screen still follows immediately.
func _on_coverage_page_completed() -> void:
	if _restoring:
		# The page was ALREADY finished when it was saved. Restoring it must not
		# celebrate the player through a page they only came back to look at.
		_pre_completed = true
		GameState.mark_page_status(_book, GameState.current_page_index, GameState.STATUS_COMPLETE)
		return
	if _completing:
		return
	_completing = true
	_refresh_nav()
	var finished_index := GameState.current_page_index
	page_completed.emit(finished_index)

	# Save point: the finished page's pixels are written while the cursor still
	# points at it, so the file always describes the page it is named after.
	# Async (M6) -- the app is very much still running here.
	await _persist_page_async(finished_index)
	if finished_index != GameState.current_page_index or not is_inside_tree():
		_completing = false
		return

	if GameState.is_on_last_page():
		_completing = false
		_refresh_nav()
		GameState.finish_book()
		book_completed.emit(_book)
		return

	_completing = false
	_show_celebration()
	_refresh_nav()


## The persistent "page complete" state (BL-4). It pops in and STAYS: it is the
## page's new state, not a countdown to anything, and the hint under it names the
## control that turns the page.
func _show_celebration() -> void:
	_celebrating = true
	_celebration_title.text = "Page complete!"
	_celebration_hint.text = "Tap  ›  when you want the next page"
	_celebration.visible = true
	_kill_celebration_tween()
	_celebration_tween = create_tween()
	_celebration_tween.tween_property(_celebration, "modulate:a", 1.0, CELEBRATION_DURATION * 0.45)


func _hide_celebration() -> void:
	_celebrating = false
	_kill_celebration_tween()
	if is_instance_valid(_celebration):
		_celebration.modulate.a = 0.0
		_celebration.visible = false


func _kill_celebration_tween() -> void:
	if _celebration_tween != null and _celebration_tween.is_valid():
		_celebration_tween.kill()
	_celebration_tween = null


## True while the finished-page state is on screen.
func is_celebrating() -> bool:
	return _celebrating


## Freeze the current frame, load [param page_index] behind that frozen frame,
## then turn it away. Because the real (already loaded) page renders underneath
## the overlay, the flip reveals it with no "to" texture and nothing pops when the
## overlay hides.
func _flip_to_page(page_index: int) -> bool:
	var from_texture := await _take_snapshot()
	if not is_inside_tree():
		return false
	_flip.prepare(from_texture)
	await get_tree().process_frame

	GameState.set_page_index(page_index)
	var loaded := _apply_current_page()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	_flip.play_to(null, PageFlip.DEFAULT_DURATION)
	await _flip.flip_finished
	return loaded


## A texture of exactly what is on screen right now.
##
## Async where it can be (M6): a blocking main-viewport grab costs the same
## presentation stall as the paint-layer one did, and it would land right on the
## beat where the flip is supposed to start moving. Nothing on screen changes
## during the couple of frames the transfer takes -- the celebration tween has
## already faded out -- so the snapshot is the same picture either way.
func _take_snapshot() -> Texture2D:
	await RenderingServer.frame_post_draw
	var delivery: Array[Image] = []
	var queued := AsyncReadback.request(get_viewport(), func(image: Image) -> void:
		delivery.append(image)
	)
	if queued:
		var frames := 0
		while delivery.is_empty() and frames < MAX_READBACK_FRAMES and is_inside_tree():
			frames += 1
			await get_tree().process_frame
	if not delivery.is_empty() and delivery[0] != null:
		return ImageTexture.create_from_image(delivery[0])
	return ImageTexture.create_from_image(get_viewport().get_texture().get_image())

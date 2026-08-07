class_name ColoringPage
extends Control
## The screen the game is about: one page of a book, the crayon palette, a
## minimal toolbar, and the page-flip that carries the player to the next page
## (DESIGN.md 2, 3.4).
##
## [b]Composition[/b] -- it owns four things and wires them together, and that is
## all it does:
##   [PageView]        the painting stack (M2, frozen)
##   palette component the crayon row, from [code]GameState.get_palette_scene_path()[/code] (M3, frozen)
##   [CoverageTracker] completion, threshold injected from the active [PaletteDef]
##   [PageFlip]        the transition between pages
##
## [b]Signals up[/b]: [signal back_requested] -- the one and only way out of a
## book (BL-11). The parent ([code]main.tscn[/code] in M5) swaps screens; this
## screen never does.
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
## [b]M5 addition[/b] -- the hook M4's handoff called for, and nothing else.
## (M5 also carried a live mode swap that rebuilt the palette and re-injected the
## threshold; [b]BL-20 deleted it with the modes[/b] -- there is one palette and
## one threshold, fixed for the whole visit.)
##
## 1. [b]Paint save / restore[/b]. The screen is the only thing that can reach the
##    paint layer, so it owns the TIMING; [code]GameState[/code] owns the FILES.
##    Paint is handed to [code]GameState.save_page_paint()[/code] at exactly the
##    three moments the design allows a full readback: a page completing (before
##    the flip advances), leaving the book, and app quit. On page load, a saved
##    layer is composited back in and replayed through
##    [method CoverageTracker.update_all] so the tracker resumes where it was.
##
## [b]How the restore gets the pixels in[/b]: [method PageView.composite_image]
## draws the saved image into the paint SubViewport for exactly one frame with
## PREMULTIPLIED-ALPHA blending, onto the freshly cleared (all-zero) render target
## -- which is what makes the restore bit-exact, where normal MIX blending would
## darken soft brush edges by another factor of alpha on every save/restore cycle.
## M5 built that quad here, because [PageView] had no way to take an image at all;
## BL-17 moved it into the component, where the undo rebuild needs the same
## one-frame premult composite for the same reason. This screen still owns the
## TIMING and the generation checks around it.
##
## [b]M6 additions[/b] -- the mobile pass, on top of the async readback above:
##
## 1. [b]Page navigation[/b] (the gap M5 flagged). The toolbar carries prev/next
##    arrows -- see [method can_go_to_page]. Navigating saves the current page's
##    paint first and then swaps INSTANTLY: the flip is the reward for finishing a
##    page, not a tax on flicking back to look at one. (M6 gated the arrows behind
##    pages the player had already reached; BL-10 removed that gate entirely.)
## 2. [b]Portrait[/b]. The toolbar drops its centred page title below
##    [constant NARROW_TOOLBAR_WIDTH] so five controls still fit across a 720 px
##    phone; the palette component already scrolls horizontally. Nothing else
##    needed changing -- the screen was already one vertical box.
##
## [b]Backlog additions (BL-4, BL-6, BL-7)[/b]:
##
## 1. [b]No auto-flip.[/b] Completing a page used to celebrate for half a second
##    and then turn the page for the player. It now STAYS on the finished page.
##    Pressing the forward arrow plays the flip -- see [method go_to_page]: a
##    forward step off a page finished during this visit is the one navigation
##    that gets the ceremony, every other jump swaps instantly.
##
## [b]Free play (BL-10, DESIGN.md 2.1)[/b] -- completing a page is never a
## requirement for anything:
##
## 1. [b]Any page, any time.[/b] [method can_go_to_page] is now "is that a page of
##    this book, and not the one already open". No gating on progress at all.
## 2. [b]Colour forever.[/b] A complete page stays fully paintable, in the same
##    sitting and after reopening; coverage, autosave and the manual save all keep
##    working on post-completion strokes, and the celebration cannot re-fire.
## 3. [b]The book ends when the PLAYER says so.[/b] BL-11 took the last remaining
##    special case off the last page: completing it celebrates like any other page
##    and stays put, its forward arrow is simply disabled because there is no next
##    page, and the player leaves the book with Back. There is no book-complete
##    gesture, signal or screen any more.
## 4. [b]The coloring lock.[/b] A per-page padlock in the toolbar that stops
##    strokes and Start over and nothing else -- see the "coloring lock" section.
##
## [b]The celebration (BL-11, DESIGN.md 2.2)[/b] is transient: a random
## congratulation above the page plus a confetti burst, both fading themselves out
## in a few seconds, blocking nothing. See [method _show_celebration].
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
##
## [b]Undo / redo (BL-17)[/b]: two toolbar buttons over a per-visit stroke history.
## See the "stroke history" section below -- the short version is that this screen
## keeps the RECIPE of every stroke [PageView] records, and undo re-draws the page
## without the last one instead of restoring a snapshot of it.
##
## (BL-15's "now painting with" chip lived here between BL-15 and BL-16, which
## deleted it: the bigger pick bubble and the louder selected states in the palette
## do that job, and the chip was a third opinion nobody was looking at.)
##
## [b]Toolbar polish and action feedback (BL-29)[/b] -- presentation only. Nothing
## in this section touches the painting stack, the save timing, the undo stacks or
## the confirm overlay's logic; it hangs animations off signals and button presses
## that were already there.
##
## 1. [b]The toolbar is a box of crayons.[/b] [ToolbarStyle] owns the family look --
##    a fat rounded slab with a darker wax lip and a soft shadow -- and every button
##    up there is that one shape in a different crayon-box hue. The two controls that
##    draw their own faces ([PadlockButton], [HistoryButton]) borrow the same plate,
##    so a drawn glyph and a themed label sit on identical furniture.
## 2. [b]Every press answers[/b] ([PopFeedback]): the slab squashes under the finger
##    and springs back on release, through [member Control.scale] about the control's
##    own centre -- which a [BoxContainer] never touches, so a bouncing button cannot
##    disturb the row or the touch rectangles the harnesses measure.
## 3. [b]Save is a little event[/b]: the button pops and a few sparks drift up out of
##    the "Saved!" toast, which now arrives with a bounce instead of a fade
##    ([method _play_save_flourish]). It is hung on the TOAST, so every path that
##    says "Saved!" -- the button, a deferred manual save, an autosave that announces
##    itself -- gets it, and the silent interval autosave stays silent.
## 4. [b]Start over gets a fresh sheet[/b] ([FreshSheetWipe]): clean paper sweeps
##    across the page area with a shadow running ahead of it, flashes white as it
##    lands and fades to reveal the blank page. It plays from
##    [method restart_current_page], so the confirm overlay is untouched and the
##    wipe follows the clear however it was asked for.
## 5. [b]Undo and redo feel connected to the paint.[/b] The button pops, tips and
##    throws sparks the instant it is pressed (the button's own job, in
##    [method HistoryButton.play_press]), and this screen adds a second, smaller
##    burst on [signal history_applied] -- the moment the stroke has actually gone or
##    come back, a couple of frames later.
##
## All of it is hosted on the [code]Effects[/code] overlay, which is
## [constant Control.MOUSE_FILTER_IGNORE] and empty except while something is
## playing; every effect frees itself and nothing in the screen waits on one.

## The player asked to leave the book. The ONLY way out of a book (BL-11).
signal back_requested()
## A different page is now loaded and interactive (after any flip).
signal page_changed(page_index: int)
## The page at [param page_index] just reached full coverage, before the flip.
signal page_completed(page_index: int)
## Fired after a stroke's coverage sample has been applied. Tests wait on this;
## the game ignores it.
signal coverage_updated(region_id: int, coverage: float)
## An undo (or redo) finished: the paint layer is rebuilt and the tracker has
## re-settled (BL-17). [param undone] is true for undo, false for redo. Tests wait
## on this; the game ignores it.
signal history_applied(undone: bool)
## Fired once the saved paint layer for [param page_index] has been composited and
## replayed into the tracker. [param restored] is false when there was nothing
## saved. Tests wait on this; the game ignores it.
signal paint_restored(page_index: int, restored: bool)
## The page's paint layer was written. [param manual] is true when the player
## asked for it rather than a timer or a save point. Tests wait on this.
signal page_saved(page_index: int, manual: bool)
## [param page_index] was reset to blank by the player (BL-7).
signal page_restarted(page_index: int)

## The congratulation pool (BL-11, DESIGN.md 2.2). Picked from at random so the
## twentieth finished page does not read like the first one again. Authored, not
## generated: this is the game's voice talking to a four-year-old.
const CELEBRATION_MESSAGES: PackedStringArray = [
	"This looks fantastic!",
	"Beautiful work!",
	"So colorful!",
	"Look at those colors!",
	"What a picture!",
	"You finished it!",
	"Lovely coloring!",
	"Wonderful!",
]
## Seconds the celebration takes to arrive, how long it holds, and how long it
## takes to fade away. Nothing dismisses it and nothing waits for it -- the whole
## thing is over in about four seconds whatever the player does underneath it.
const CELEBRATION_FADE_IN := 0.28
const CELEBRATION_HOLD := 2.3
const CELEBRATION_FADE_OUT := 1.2
## Confetti scrap size, in pixels (lifted from the deleted BookComplete screen).
const CONFETTI_SCRAP_SIZE := 14
## Frames to wait for the paint layer to catch up with a finished stroke.
const MAX_SETTLE_FRAMES := 8
## Frames an async readback is given to come back before it is written off. The
## driver delivers in ~2; this only exists so a lost callback can never leave
## [method has_pending_coverage] stuck true forever.
const MAX_READBACK_FRAMES := 30
## Below this screen width the toolbar drops its centred page title, so the back
## button, the page counter and the two nav arrows still fit (M6, portrait).
const NARROW_TOOLBAR_WIDTH := 620.0
## Seconds the "Saved!" / "Page cleared" toast stays readable before it fades.
const TOAST_SECONDS := 1.6
## How many strokes back undo reaches (BL-17). Deep enough that a child never hits
## it in one sitting, shallow enough that a rebuild -- which costs a frame per
## stroke -- stays under a second.
const UNDO_DEPTH := 50
## Frames anything waiting on a rebuild will wait before giving up. A full-depth
## rebuild costs one frame per stroke plus a readback, so this is ~4 s at 60 Hz:
## generous for the deepest legal history, and still a bound rather than a hang.
const MAX_REPLAY_WAIT_FRAMES := 240

# --- BL-29 feedback ---------------------------------------------------------
# Referenced through preloads rather than by global class name: a new class_name
# script is invisible to a CLI run until the project is re-imported, and a screen
# this central must not be the thing that discovers a stale registry.
const TOOLBAR_STYLE := preload("res://scripts/components/toolbar_style.gd")
const POP := preload("res://scripts/components/pop_feedback.gd")
const SPARKLES := preload("res://scripts/components/sparkle_burst.gd")
const FRESH_SHEET := preload("res://scripts/components/fresh_sheet_wipe.gd")

## Seconds the Start-over sweep takes, end to end.
const FRESH_SHEET_SECONDS := 0.72
## Sparks thrown by a save: gold, leaf and paper-white, so they read against both
## the green toast and the dark toolbar. Typed [Array]s, not [PackedColorArray]s --
## only the former can be a [code]const[/code].
const SAVE_SPARKS: Array[Color] = [
	Color(1.0, 0.870588, 0.376471),
	Color(0.615686, 0.933333, 0.596078),
	Color(1.0, 0.996078, 0.945098),
]
## Sparks thrown by undo/redo: the history buttons' own teal, plus cream.
const HISTORY_SPARKS: Array[Color] = [
	Color(0.427451, 0.909804, 0.941176),
	Color(1.0, 0.996078, 0.945098),
]
## Sparks over a freshly cleared page: paper-white and a little gold.
const FRESH_SPARKS: Array[Color] = [
	Color(1.0, 0.996078, 0.949020),
	Color(1.0, 0.913725, 0.607843),
	Color(0.850980, 0.945098, 1.0),
]

@onready var _page_view: PageView = $Ui/Body/PageView
@onready var _ui: VBoxContainer = $Ui
## Page + palette. Vertical in portrait (crayons under the canvas), horizontal in
## landscape (crayons docked beside it) -- see [method _apply_orientation], BL-21.
## A plain [BoxContainer] on purpose: [HBoxContainer]/[VBoxContainer] refuse
## [member BoxContainer.vertical], so a scene that has to flip cannot use them.
@onready var _body: BoxContainer = $Ui/Body
@onready var _page_label: Label = $Ui/Toolbar/Row/PageLabel
@onready var _title_label: Label = $Ui/Toolbar/Row/PageTitle
@onready var _back_button: Button = $Ui/Toolbar/Row/BackButton
@onready var _prev_button: Button = $Ui/Toolbar/Row/PrevButton
@onready var _next_button: Button = $Ui/Toolbar/Row/NextButton
@onready var _save_button: Button = $Ui/Toolbar/Row/SaveButton
@onready var _reset_button: Button = $Ui/Toolbar/Row/ResetButton
@onready var _lock_button: PadlockButton = $Ui/Toolbar/Row/LockButton
@onready var _undo_button: HistoryButton = $Ui/Toolbar/Row/UndoButton
@onready var _redo_button: HistoryButton = $Ui/Toolbar/Row/RedoButton
## Where BL-29's transient effects live: a full-rect, input-transparent overlay a
## [SparkleBurst] or a [FreshSheetWipe] can be parented to. A plain [Control] on
## purpose -- a container would try to lay the effects out as if they were UI.
@onready var _effects: Control = $Effects
@onready var _celebration: Control = $Celebration
@onready var _celebration_message: Label = $Celebration/Message
@onready var _confetti: CPUParticles2D = $Celebration/Confetti
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
## WP7. Decodes a DLC page's PNGs on a worker thread; a no-op for a built-in page,
## which still goes straight through [method PageView.load_page]. The prefetch is
## kicked off at the top of [method go_to_page], so the decode overlaps the save
## and the flip that navigation already costs.
var _page_loader := PageLoader.new()
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
## The page's BASELINE paint (BL-17): the layer as it was when this visit opened,
## i.e. the restored save PNG, or null for a page that opened blank. Never a stroke
## the player made in this sitting -- undo can take the page back to this and no
## further, which is exactly the "the restored PNG is baseline, not an undoable
## stroke" rule. Dropped on page change and on Start over.
var _baseline_paint: Image
## Every stroke committed during this page visit, oldest first (BL-17).
var _stroke_recipes: Array[Dictionary] = []
## Strokes taken back and not yet re-applied, most recent LAST. Cleared by any new
## stroke, as everywhere else in the world.
var _redo_recipes: Array[Dictionary] = []
## Index below which strokes can no longer be undone -- see [constant UNDO_DEPTH].
## Those strokes stay in the list because the rebuild still has to draw them; what
## the cap bounds is how far BACK the player can go, not what the page is made of.
var _undo_floor := 0
## True from the first frame of a rebuild until the tracker has re-settled.
var _replaying := false
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
## True once the page in hand reached full coverage WHILE THE PLAYER WAS ON IT.
## Distinct from "the page is complete", which a restored page can be the moment
## it opens: only this earns the page-turn ceremony (BL-4 + BL-10).
var _completed_this_visit := false
## True while this page carries the coloring lock (BL-10).
var _locked := false
## True while the transient celebration is on screen (BL-11).
var _celebrating := false
## So the pool never hands out the same line twice in a row.
var _last_celebration_message := ""
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
	_lock_button.pressed.connect(_on_lock_pressed)
	_undo_button.pressed.connect(_on_undo_pressed)
	_redo_button.pressed.connect(_on_redo_pressed)
	# BL-29: the crayon-slab look and the press bounce, applied to the whole family
	# in one place. Nothing below this line changes what a button DOES.
	_style_toolbar()
	# ...and the second half of the undo/redo answer: the button reacts to the press
	# itself, this reacts to the stroke having actually gone (or come back).
	history_applied.connect(_on_history_applied_feedback)
	# BL-10: a press the lock refused. The page cannot show why; the padlock can.
	_page_view.paint_blocked.connect(_on_paint_blocked)
	_page_view.stroke_ended.connect(_on_stroke_ended)
	# BL-11: nothing dismisses the celebration and nothing has to -- it is a few
	# seconds of confetti that fades itself, over a page that stays fully live
	# underneath it. (BL-4's persistent state DID have to get out of the way when a
	# stroke started; there is no state to get out of the way any more.)
	_configure_confetti()
	resized.connect(_layout_confetti)
	_layout_confetti()
	# BL-6: the interval autosave announces the moment; this screen is what can
	# actually reach the pixels.
	GameState.autosave_due.connect(_on_autosave_due)
	# M6: portrait windows get a leaner toolbar. BL-21: and landscape ones dock the
	# crayons beside the canvas instead of under it.
	resized.connect(_apply_toolbar_layout)
	resized.connect(_apply_orientation)
	_apply_toolbar_layout()
	_refresh_nav()
	_build_palette()
	_apply_orientation()


## WP7: a worker task must never outlive the thing that started it. Dropping the
## screen with a prefetch in flight would leave the pool holding a [Callable] into
## a freed object -- the same class of shutdown crash [AsyncReadback.drain] guards
## against, for the same reason.
func _exit_tree() -> void:
	_page_loader.discard()


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
	# WP7: start the decode before GameState/coverage work, so a DLC page's PNGs
	# are already in flight while the book is being set up.
	_prefetch_page(start_index)
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
	_completed_this_visit = false
	_paint_dirty = false
	_save_deferred = false
	# BL-17: the history is per page VISIT. Whatever the player did on the page
	# they are leaving cannot be undone onto the page they are arriving at.
	_clear_history()
	_hide_celebration()
	_set_reset_confirming(false)
	# The DISPLAY image is what the player sees. A page mapped from a separate
	# masking image (BL-9) also hands that mask through (BL-12): PageView draws it
	# under the display art so its outlines stay over the paint. Empty for every
	# page that has no mask, which renders exactly as it always did.
	#
	# WP7: a DLC page's files cannot go through the importer, so its textures come
	# from [PageLoader] (decoded on a worker task, prefetched by go_to_page) and go
	# into the PageView primitive instead. A built-in page takes the path it always
	# took -- same call, same importer, same textures.
	if page.is_runtime:
		if not _load_runtime_page(page):
			return false
	elif not _page_view.load_page(
		page.display_image_path, page.id_map_path, page.regions_json_path, page.mask_image_path
	):
		return false

	_build_coverage()
	_refresh_toolbar(page)
	# BL-10: the lock is per PAGE and lives in the save, so it is read fresh on
	# every page load -- including the pages a flip walks through.
	_set_locked(
		GameState.is_page_locked(GameState.book_key(_book), GameState.current_page_index),
		false
	)
	# Deliberately NOT awaited: load_book() and the flip both call this and both
	# need a plain bool back. The restore runs over the next few frames; anything
	# that needs it settled waits on `paint_restored` / has_pending_restore().
	_restore_saved_paint(GameState.current_page_index)
	return true


## Hands a DLC page's decoded textures to [PageView] (WP7). The wait is normally
## zero: [method _prefetch_page] started the decode before the save-and-flip that
## brought us here, so the task has long finished by now.
func _load_runtime_page(page: PageDef) -> bool:
	var bundle := _page_loader.take(page)
	if String(bundle.get(PageLoader.KEY_ERROR, "")) != "":
		push_error("ColoringPage: %s" % bundle[PageLoader.KEY_ERROR])
		return false
	return _page_view.load_page_textures(
		bundle[PageLoader.KEY_DISPLAY],
		bundle[PageLoader.KEY_IDMAP],
		bundle[PageLoader.KEY_REGIONS],
		bundle[PageLoader.KEY_MASK]
	)


## Starts decoding the page at [param page_index] in the background. Does nothing
## for a built-in page (the importer already did the work) and nothing at all when
## the index is not a page of this book -- so it is safe to call speculatively.
func _prefetch_page(page_index: int) -> void:
	if _book == null:
		return
	var page := _book.get_page(page_index)
	if page != null:
		_page_loader.request(page)


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
# BL-10: EVERY page of an open book is reachable, always. M6 shipped a "you may
# revisit, you may not skip ahead" rule (reached pages, plus one forward off a
# finished page); DESIGN.md 2.1 threw it out. Completing a page is never a
# requirement for anything, so a brand-new book offers all of its pages from the
# first frame and the only thing the arrows encode is "is there a page there".
#
# What survived is the BL-4 ceremony: the flip plays for exactly one jump, the
# forward step off a page the player finished DURING THIS VISIT. Every other
# jump -- backwards, forwards into an untouched page, forwards off a page that was
# already complete when it was opened -- swaps instantly, because flicking through
# a book must not cost a second of animation per page.

## True when [method go_to_page] would accept [param page_index]: it is a real
## page of this book and it is not the one already open. That is the whole rule
## (BL-10).
func can_go_to_page(page_index: int) -> bool:
	if _book == null or not _book.has_page(page_index):
		return false
	return page_index != GameState.current_page_index


## Saves the open page and swaps to [param page_index].
## Returns false when the jump is not allowed or the page fails to load.
##
## [b]One jump gets the flip[/b] (BL-4, narrowed by BL-10): stepping FORWARD off a
## page the player finished DURING THIS VISIT. That is the moment the page turn
## belongs to -- it is the reward for completing the page, taken when the player
## asks for it instead of being pushed on them the instant the last region filled.
## Every other jump swaps instantly, and now that every page is reachable that
## matters more, not less: browsing a book must not cost a second of ceremony per
## page, and re-opening a page that was ALREADY complete is browsing, not
## finishing (see [member _completed_this_visit]).
func go_to_page(page_index: int) -> bool:
	if is_transitioning() or not can_go_to_page(page_index):
		return false
	_navigating = true
	_set_nav_enabled(false)
	var with_flip := page_index == GameState.current_page_index + 1 and _completed_this_visit
	# WP7: this is the loading beat DLC pages hide their PNG decode behind. Kicked
	# off BEFORE the save and the flip, so by the time _apply_current_page() asks
	# for the textures the worker task has finished and the wait is zero.
	_prefetch_page(page_index)
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


## Forward. On the LAST page there is simply nothing to turn to, so the arrow is
## disabled and this never fires (BL-11: the last page is not special, and the way
## out of a book is Back).
func _on_next_pressed() -> void:
	await go_to_page(GameState.current_page_index + 1)


func _refresh_nav() -> void:
	if not is_instance_valid(_prev_button):
		return
	var busy := is_transitioning()
	_prev_button.disabled = busy or not can_go_to_page(GameState.current_page_index - 1)
	_next_button.disabled = busy or not can_go_to_page(GameState.current_page_index + 1)
	_save_button.disabled = busy or _saving
	# BL-10: the lock's whole job is preventing accidental damage, and there is
	# nothing more damaging on this screen than Start over.
	_reset_button.disabled = busy or _locked
	# The padlock itself never greys out for the lock -- a lock you cannot undo is
	# a trap -- only while a transition owns the screen.
	_lock_button.disabled = busy
	# BL-17: empty stack, locked page, or a rebuild/transition in flight.
	_undo_button.disabled = not (can_undo() and _can_edit_history())
	_redo_button.disabled = not (can_redo() and _can_edit_history())


func _set_nav_enabled(enabled: bool) -> void:
	_prev_button.disabled = not enabled
	_next_button.disabled = not enabled
	_save_button.disabled = not enabled
	_reset_button.disabled = not enabled
	_lock_button.disabled = not enabled
	_undo_button.disabled = not enabled
	_redo_button.disabled = not enabled


## Portrait toolbar: five controls do not fit across a 720 px phone, and the page
## title is the one that carries no action, so it is what goes.
##
## BL-29 gave the buttons a wax lip and a drop shadow, which want a little air
## around them -- so the row also tightens its gaps when it narrows, rather than
## letting the extra weight push a control off the end. The controls themselves
## never shrink: the 48 px touch floor is not negotiable (DESIGN.md 3.5).
func _apply_toolbar_layout() -> void:
	if not is_instance_valid(_title_label):
		return
	var narrow := size.x < NARROW_TOOLBAR_WIDTH
	_title_label.visible = not narrow
	var row := _title_label.get_parent() as HBoxContainer
	if row != null:
		row.add_theme_constant_override("separation", 8 if narrow else 14)


## True when the screen is wider than it is tall. [b]Aspect, not width[/b]
## (DESIGN.md 3.5): with `canvas_items`/`expand` stretch over a 1152x648 base, a
## portrait WINDOW never narrows the logical canvas below 1152 -- it grows the
## height instead -- so any layout keyed off a pixel width is keyed off nothing.
func is_landscape() -> bool:
	return size.x > size.y


## BL-21. Landscape docks the crayons as a vertical column on the SIDE of the
## canvas; portrait keeps the strip along the bottom, unchanged. Both are the same
## palette scene and the same [BoxContainer] -- only its direction moves.
func _apply_orientation() -> void:
	if not is_instance_valid(_body):
		return
	var landscape := is_landscape()
	_body.vertical = not landscape
	if _palette is PaletteChild:
		(_palette as PaletteChild).set_layout(
			PaletteChild.LAYOUT_COLUMN if landscape else PaletteChild.LAYOUT_ROW
		)


## Instantiates the game's one palette component -- the crayon row (BL-20) -- and
## wires the two-signal contract it exposes (coloring-mechanics, M3).
func _build_palette() -> void:
	var scene := load(GameState.get_palette_scene_path()) as PackedScene
	if scene == null:
		push_error("ColoringPage: could not load '%s'." % GameState.get_palette_scene_path())
		return
	_palette = scene.instantiate() as Control
	# Appended after PageView, so the palette lands under the canvas in portrait
	# and to the RIGHT of it in landscape -- the same child order, read the way the
	# body box happens to be pointing (BL-21).
	_body.add_child(_palette)
	_apply_orientation()

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
	# before we commit to drawing the saved pixels onto it.
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	# The screen can be swapped out from under a restore (the parent frees it, or
	# a flip loads the next page); either way this restore is for a dead page.
	if generation != _page_generation or not is_inside_tree() or not is_instance_valid(_page_view):
		_restoring = false
		return

	await _page_view.composite_image(image)

	if generation != _page_generation or _coverage == null:
		_restoring = false
		return
	# BL-17: this image is the page's baseline. Undo rebuilds from it, so it is kept
	# for as long as the visit lasts -- one page-sized Image, against the ~14 MB per
	# stroke a snapshot-based undo would have needed.
	_baseline_paint = image
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
	# BL-17: the app is quitting and there is no next frame to wait for, so a
	# rebuild in flight cannot be waited out. Half a rebuilt page is worse than the
	# file already on disk -- which the replay was reconstructing from anyway.
	if _replaying:
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
	# BL-6's "never read the paint layer mid-stroke" extends to "never mid-replay"
	# (BL-17): between the clear and the last re-stamp the layer is a page nobody
	# has ever seen. Every caller here has frames left, so it simply waits.
	await _await_replay()
	if not is_inside_tree():
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
	if _page_view.is_stroke_active() or _readback_scheduled or _replaying:
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
			_show_toast("Saved!", true)
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
		_show_toast("Saved!" if written else "Nothing to save", written)
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


# ========================================================= coloring lock (BL-10) ==
# A per-page padlock: a finished page the player wants to protect, or a device
# handed over just to SHOW a page. It is a guard against accidents, not a mode, so
# it is deliberately shallow:
#
#   locked   presses start no stroke ([member PageView.painting_enabled]), and
#            Start over is disabled -- the two ways a page can lose work
#   still on  pan, zoom, two-finger gestures, Save, navigation and palette
#            browsing. The lock stops PAINT, not looking or leaving.
#
# One tap on, one tap off, no confirm dialog: a lock that takes two decisions to
# undo is worse than no lock for a four-year-old. The state persists per page in
# the save file (GameState owns user://), so a protected page is still protected
# tomorrow.

func _on_lock_pressed() -> void:
	_set_locked(not _locked)
	_show_toast("Page locked" if _locked else "Page unlocked")


## Applies the lock to the page and (unless [param persist] is false, which is how
## a page LOAD applies what was already saved) writes it.
func _set_locked(locked: bool, persist: bool = true) -> void:
	_locked = locked
	# The gate itself: one additive flag on the frozen painting component, checked
	# at stroke start. Setting it false also cancels a stroke already down.
	_page_view.painting_enabled = not locked
	if is_instance_valid(_lock_button):
		_lock_button.locked = locked
	if locked:
		# Locking with the Start over confirm open would leave a live "yes, wipe it"
		# button behind the lock that is supposed to have disabled it.
		_set_reset_confirming(false)
	if persist and _book != null:
		GameState.set_page_locked(_book, GameState.current_page_index, locked)
	_refresh_nav()


## The press the lock refused. The padlock shakes: it is the control that caused
## the nothing-happened, so it is the control that has to explain it -- and a
## shake needs no reading age and no modal (this ships to the web).
func _on_paint_blocked(_page_position: Vector2) -> void:
	if is_instance_valid(_lock_button):
		_lock_button.wiggle()


## True while the open page carries the coloring lock.
func is_page_locked() -> bool:
	return _locked


## Locks or unlocks the open page, persisting the change. The toolbar's padlock
## runs this; it is public so a parent (or a test) can drive the same path.
func set_page_locked(locked: bool) -> void:
	if _book == null or locked == _locked:
		return
	_set_locked(locked)


# ======================================================== stroke history (BL-17) ==
# Undo and redo, one stroke at a time, over a history that lives exactly as long as
# the page visit does.
#
# [b]Replay, not snapshots.[/b] A paint-layer snapshot is ~14 MB at page resolution;
# a stack of fifty is not a thing a phone can hold. A stroke RECIPE -- locked
# region, colour, diameter, hardness, and the dab centres PageView actually stamped
# -- is a few kilobytes. So undo does not restore a picture, it draws the page
# again: clear the SubViewport, composite the baseline (the save PNG this visit
# opened with, if any), re-stamp every remaining recipe in order. Redo does not
# rebuild at all -- it re-stamps the popped recipe on top, which is the very draw
# call that made those pixels in the first place, so undo -> redo is pixel-stable.
#
# [b]What the cap caps.[/b] BL-17 asks for a bounded depth, dropping the oldest.
# Dropping a RECIPE would be wrong: the rebuild draws the page from the baseline
# forward, so a forgotten recipe is paint that quietly disappears the next time
# anything is undone. So the cap is on how far back the player may go
# ([constant UNDO_DEPTH]) and the strokes that fall past it are frozen into the
# replay prefix instead of being thrown away. The player experience is identical
# ("undo stops after fifty"), and the page never loses a stroke it is still showing.
#
# [b]Interlocks[/b] ([method _can_edit_history]): empty stack, a locked page
# (same rationale as Start over -- the lock exists to stop the page changing), a
# stroke still down, a flip/navigation in transit, a restore or another rebuild
# already running. A new stroke clears the redo stack.
#
# [b]Coverage[/b] re-settles with [method CoverageTracker.update_all] afterwards,
# and the page generation is bumped FIRST so a readback taken from the pre-undo
# layer cannot be folded into it (the BL-7 trick). Coverage is monotonic, so an
# undo never un-finishes a region and completion stays sticky per BL-10; a redo
# that re-crosses the line cannot re-celebrate either, because the tracker's
# page_completed fires once.

## True when there is a stroke to take back.
func can_undo() -> bool:
	return _stroke_recipes.size() > _undo_floor


## True when a stroke has been taken back and not yet re-applied.
func can_redo() -> bool:
	return not _redo_recipes.is_empty()


## How many strokes deep the player can still undo.
func undo_depth() -> int:
	return maxi(_stroke_recipes.size() - _undo_floor, 0)


func redo_depth() -> int:
	return _redo_recipes.size()


## True while a rebuild (or its coverage re-settle) is running.
func is_replaying() -> bool:
	return _replaying


## Whether undo/redo may run AT ALL right now, regardless of what is on the stacks.
func _can_edit_history() -> bool:
	return (
		_book != null
		and _page_view.is_page_loaded()
		and not _locked
		and not _replaying
		and not _restoring
		and not _page_view.is_stroke_active()
		and not is_transitioning()
	)


## Takes back the last stroke. Returns false if it was refused (see
## [method _can_edit_history]).
func undo() -> bool:
	if not can_undo() or not _can_edit_history():
		return false
	_redo_recipes.append(_stroke_recipes.pop_back())
	return await _apply_history(true)


## Puts back the last undone stroke.
func redo() -> bool:
	if not can_redo() or not _can_edit_history():
		return false
	_stroke_recipes.append(_redo_recipes.pop_back())
	return await _apply_history(false)


func _on_undo_pressed() -> void:
	await undo()


func _on_redo_pressed() -> void:
	await redo()


## Re-draws the page for the stack as it now stands, then re-settles coverage.
##
## [param undone] only picks between the two ways to get there: taking a stroke
## away means the page has to be drawn again from the baseline, while putting one
## back is just that one stroke, stamped on top of what is already there.
func _apply_history(undone: bool) -> bool:
	_replaying = true
	# The BL-7 guard: a coverage readback already in flight was taken from paint we
	# are about to redraw, so retire it before touching a pixel.
	_page_generation += 1
	var generation := _page_generation
	_pending_regions.clear()
	_paint_dirty = true
	_refresh_nav()

	if undone:
		await _page_view.rebuild_paint(_baseline_paint, _stroke_recipes)
	else:
		_page_view.stamp_recipe(_stroke_recipes[_stroke_recipes.size() - 1])
		await _settle_paint()

	if generation != _page_generation or not is_inside_tree():
		_replaying = false
		return false

	# Re-settle from what is actually on the layer now. update_all is monotonic, so
	# this can only ADD coverage: undo never downgrades a finished region (BL-10's
	# sticky completion), it only stops the page claiming coverage it has not got
	# once the player paints over the gap again.
	var image := await _read_paint_async()
	if generation == _page_generation and _coverage != null and image != null:
		_coverage.update_all(image)
	_replaying = false
	if not is_inside_tree():
		return true
	_refresh_nav()
	history_applied.emit(undone)
	# A save that arrived mid-rebuild was deferred; the layer is settled now.
	await _run_deferred_save()
	return true


## Records the stroke [PageView] just finished. The one place the undo stack grows.
func _record_stroke() -> void:
	if _replaying:
		return
	var recipe := _page_view.take_last_stroke_recipe()
	if recipe.is_empty():
		return
	_stroke_recipes.append(recipe)
	# Standard everywhere: drawing something new is a decision, and it ends the
	# branch the player had undone their way into.
	_redo_recipes.clear()
	if _stroke_recipes.size() - _undo_floor > UNDO_DEPTH:
		_undo_floor = _stroke_recipes.size() - UNDO_DEPTH


## Forgets this page's history and its baseline. Page load and Start over only --
## the history is per VISIT and is never persisted.
func _clear_history() -> void:
	_stroke_recipes.clear()
	_redo_recipes.clear()
	_undo_floor = 0
	_baseline_paint = null
	_replaying = false


## Waits out a rebuild in flight. Nothing may read the paint layer while one is
## running -- between the clear and the last re-stamp it shows a page that never
## existed.
func _await_replay() -> void:
	var frames := 0
	while _replaying and is_inside_tree() and frames < MAX_REPLAY_WAIT_FRAMES:
		frames += 1
		await get_tree().process_frame


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
## rest of the book's progress, are untouched. Returns false when there is no
## page, or when the page is LOCKED (BL-10 -- the button is disabled too, but the
## refusal belongs on the method that does the damage, not only on the UI).
func restart_current_page() -> bool:
	if _book == null or not _page_view.is_page_loaded() or _locked:
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
	_completed_this_visit = false
	_completing = false
	_hide_celebration()

	_page_view.clear_paint()
	# After clear_paint(), not before: cancelling a stroke that was still down
	# records its recipe, and that recipe describes paint this button just wiped.
	_clear_history()
	GameState.erase_page_progress(_book, page_index)
	_build_coverage()
	_refresh_nav()
	# BL-29: the sweep goes over the page AFTER it has been wiped, so what the sheet
	# uncovers is the real, already-blank page. It is pure decoration -- nothing here
	# waits for it, and a child who starts colouring mid-sweep paints on the live
	# page underneath.
	_play_fresh_sheet()
	_show_toast("Page cleared")
	page_restarted.emit(page_index)
	return true


# ==================================================================== feedback ==

## A small, short-lived message over the page ("Saved!", "Page cleared"). The
## whole of the UI feedback this screen owns -- everything else is the page.
##
## [param flourish] adds BL-29's save celebration on top: the toast bounces in
## instead of fading, the Save button pops, and a few sparks drift up. It is opt-in
## per call site rather than keyed off the text, so "Page locked" stays a plain
## label and a future message can choose either.
func _show_toast(text: String, flourish: bool = false) -> void:
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
			POP.reset(_toast)
	)
	if flourish:
		_play_save_flourish()


# ------------------------------------------------------- BL-29: action feedback --
# Everything from here to the end of the section is presentation. It reads the
# toolbar and the effects overlay and writes nothing else -- no state, no timing,
# no gate. Each effect frees itself and nothing waits on one.

## Dresses the toolbar (and the confirm overlay's two buttons) in the crayon-slab
## family and gives every one of them the press bounce.
##
## Hues are assigned by JOB, not by position: leaving is blue, saving is green,
## the destructive one is crayon red, the two page arrows share violet and the two
## history arrows share teal -- so a pair always looks like a pair, and the two
## kinds of arrow are never confused for each other.
func _style_toolbar() -> void:
	TOOLBAR_STYLE.apply(_back_button, TOOLBAR_STYLE.BLUE)
	TOOLBAR_STYLE.apply(_save_button, TOOLBAR_STYLE.GREEN)
	TOOLBAR_STYLE.apply(_reset_button, TOOLBAR_STYLE.RED)
	TOOLBAR_STYLE.apply(_prev_button, TOOLBAR_STYLE.VIOLET)
	TOOLBAR_STYLE.apply(_next_button, TOOLBAR_STYLE.VIOLET)
	TOOLBAR_STYLE.apply(_reset_confirm_button, TOOLBAR_STYLE.RED)
	TOOLBAR_STYLE.apply(_reset_cancel_button, TOOLBAR_STYLE.SLATE)
	# The padlock and the two history arrows dress and bounce themselves -- they
	# draw their own faces, so the plate is part of their _draw, not a theme.
	var slabs: Array[Button] = [
		_back_button, _save_button, _reset_button, _prev_button, _next_button,
		_reset_confirm_button, _reset_cancel_button,
	]
	for button in slabs:
		POP.attach(button)


## The save celebration: the button pops, the toast bounces in, and a handful of
## sparks drift up out of it. Deliberately small -- this fires as often as every
## 45 seconds' worth of colouring, and a save that demands attention is a stutter.
func _play_save_flourish() -> void:
	if not is_inside_tree() or not is_instance_valid(_effects):
		return
	if is_instance_valid(_save_button):
		POP.pop(_save_button, 0.18, 0.32)
		SPARKLES.burst(_effects, _effects_point(_save_button), SAVE_SPARKS, 7, 44.0, 34.0, 0.6)
	if is_instance_valid(_toast):
		POP.pop_in(_toast, 0.84, 0.34)
		# From the toast's top edge, so the stars leave the words rather than
		# crossing them.
		var from := _effects_point(_toast) - Vector2(0.0, _toast.size.y * 0.35)
		SPARKLES.burst(_effects, from, SAVE_SPARKS, 9, 66.0, 74.0, 0.85)


## A clean sheet of paper sweeping over the page area (BL-29). Called by
## [method restart_current_page] once the paint is actually gone -- the sheet covers
## the frame the picture disappeared on and leaves a blank page behind it.
func _play_fresh_sheet() -> void:
	if not is_inside_tree() or not is_instance_valid(_effects) or not is_instance_valid(_page_view):
		return
	var rect := _page_view.get_global_rect()
	rect.position -= _effects.get_global_rect().position
	FRESH_SHEET.play(_effects, rect, FRESH_SHEET_SECONDS)
	# Added AFTER the sheet, so they draw on top of it (depth is tree order in the
	# effects overlay) and read as the page being dusted off.
	SPARKLES.burst(
		_effects, rect.get_center(), FRESH_SPARKS, 12, 96.0, minf(rect.size.x * 0.3, 220.0), 0.95
	)


## The stroke has actually vanished (or come back). [HistoryButton] already answered
## the press; this answers the RESULT, a couple of frames later, which is what ties
## the button to the paint instead of to the finger.
func _on_history_applied_feedback(undone: bool) -> void:
	var button: HistoryButton = _undo_button if undone else _redo_button
	if not is_inside_tree() or not is_instance_valid(button) or not is_instance_valid(_effects):
		return
	POP.pop(button, 0.12, 0.26)
	SPARKLES.burst(_effects, _effects_point(button), HISTORY_SPARKS, 6, 40.0, 32.0, 0.55)


## A control's centre, in the effects overlay's coordinates.
func _effects_point(control: Control) -> Vector2:
	return control.get_global_rect().get_center() - _effects.get_global_rect().position


## The overlay BL-29's effects are parented to. Tests assert it cannot take input;
## the game only ever adds self-freeing children to it.
func get_effects_layer() -> Control:
	return _effects


func get_toast_text() -> String:
	return _toast_label.text


## True from the moment a toast is put up until its fade-out has finished. The
## fade-IN is not waited on: the node is shown synchronously, and a caller that
## just triggered the message must not have to wait out an animation to see it.
func is_toast_visible() -> bool:
	return is_instance_valid(_toast) and _toast.visible


# =================================================================== accessors ==

func get_page_view() -> PageView:
	return _page_view


func get_page_flip() -> PageFlip:
	return _flip


func get_coverage_tracker() -> CoverageTracker:
	return _coverage


## The live palette component -- the crayon strip ([PaletteChild]).
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


## True from the moment a page completes until the next page is interactive, while
## a [method go_to_page] jump is saving and swapping, and while an undo/redo is
## rebuilding the layer (BL-17) -- all three are moments when the page in hand is
## not the page on screen.
func is_transitioning() -> bool:
	return _completing or _navigating or _replaying


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


func get_lock_button() -> PadlockButton:
	return _lock_button


## The toolbar's undo button (BL-17).
func get_undo_button() -> HistoryButton:
	return _undo_button


func get_redo_button() -> HistoryButton:
	return _redo_button


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

## The palette's two signals are the whole contract: what the player picked is what
## the brush loads. (BL-15 also mirrored them into a toolbar chip; BL-16 deleted
## it -- the pick bubble and the selected states answer "which one is it" where the
## player is already looking.)
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
	# BL-17, first thing and synchronously: the recipe is only available until the
	# next stroke starts, and this handler is about to await.
	_record_stroke()
	_refresh_nav()
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
## [b]BL-4: this does not turn the page.[/b] It saves, then plays the transient
## celebration and stops; pressing the forward arrow is what plays the flip.
##
## [b]BL-10/BL-11: it does not end the book either.[/b] The last page behaves like
## every other page -- celebrate, stay put, keep painting if you like -- and its
## forward arrow is simply disabled. Nobody is yanked off a page they are still
## enjoying by the pixel that happened to cross a threshold.
##
## Fires at most once per page visit, so no amount of extra colouring on a
## finished page can re-celebrate: [CoverageTracker] emits
## [signal CoverageTracker.page_completed] once, and completion is sticky in both
## the tracker and the save.
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
	_completed_this_visit = true
	_refresh_nav()
	var finished_index := GameState.current_page_index
	page_completed.emit(finished_index)

	# Save point: the finished page's pixels are written while the cursor still
	# points at it, so the file always describes the page it is named after.
	# Async (M6) -- the app is very much still running here.
	await _persist_page_async(finished_index)
	_completing = false
	if finished_index != GameState.current_page_index or not is_inside_tree():
		return

	_show_celebration()
	_refresh_nav()


## The transient on-page celebration (BL-11, DESIGN.md 2.2). A random line from
## [constant CELEBRATION_MESSAGES] above the page plus a burst of palette-coloured
## confetti, both fading away on their own after a few seconds.
##
## [b]It is pure presentation.[/b] The whole overlay is
## [constant Control.MOUSE_FILTER_IGNORE] and nothing here disables anything:
## painting, pan/zoom, the toolbar and the page arrows all keep working
## underneath it, and nothing in the screen waits for it to finish. That is the
## difference from BL-4's persistent "Page complete!" state, which the player had
## to leave -- there is nothing to leave now, and no completion screen behind it
## either (BL-11 deleted BookComplete: the last page celebrates exactly like every
## other page and the way out of a book is Back).
func _show_celebration() -> void:
	_celebrating = true
	_celebration_message.text = _pick_celebration_message()
	_celebration.visible = true
	_celebration.modulate.a = 0.0
	_burst_confetti()
	_kill_celebration_tween()
	_celebration_tween = create_tween()
	_celebration_tween.tween_property(_celebration, "modulate:a", 1.0, CELEBRATION_FADE_IN)
	_celebration_tween.tween_interval(CELEBRATION_HOLD)
	_celebration_tween.tween_property(_celebration, "modulate:a", 0.0, CELEBRATION_FADE_OUT)
	# NOT _hide_celebration(): that kills the tween, and killing a tween from
	# inside its own final step is asking for trouble.
	_celebration_tween.tween_callback(_settle_celebration)


## Random, but never the same line twice running -- a repeat reads like a bug.
func _pick_celebration_message() -> String:
	var pool := CELEBRATION_MESSAGES
	if pool.is_empty():
		return ""
	var choice := pool[randi() % pool.size()]
	if pool.size() > 1 and choice == _last_celebration_message:
		choice = pool[(pool.find(choice) + 1 + randi() % (pool.size() - 1)) % pool.size()]
	_last_celebration_message = choice
	return choice


## End of the fade-out: the overlay is finished with, without touching the tween
## that is running this very callback.
func _settle_celebration() -> void:
	_celebrating = false
	if is_instance_valid(_celebration):
		_celebration.modulate.a = 0.0
		_celebration.visible = false
	if is_instance_valid(_confetti):
		_confetti.emitting = false


## Cuts the celebration short. Not a player action -- only the page changing under
## it (a load, a flip, Start over), where leaving it up would celebrate the wrong
## page.
func _hide_celebration() -> void:
	_kill_celebration_tween()
	_settle_celebration()


func _kill_celebration_tween() -> void:
	if _celebration_tween != null and _celebration_tween.is_valid():
		_celebration_tween.kill()
	_celebration_tween = null


## True while the celebration is on screen (fading in, holding, or fading out).
func is_celebrating() -> bool:
	return _celebrating


# -------------------------------------------------------------------- confetti --
# Lifted from the deleted BookComplete screen, which is where this look was built:
# ONE [CPUParticles2D], no art assets, and its scraps take their colours from the
# crayon palette through a CONSTANT-interpolation [member
# CPUParticles2D.color_initial_ramp], so each scrap is one flat crayon colour
# instead of a muddy blend. The only change is that it is a one-shot BURST here
# rather than a screen that rains forever.

func _configure_confetti() -> void:
	if not is_instance_valid(_confetti):
		return
	_confetti.texture = _make_scrap_texture()
	var palette := GameState.get_active_palette()
	if palette == null or palette.color_count() == 0:
		return
	var gradient := Gradient.new()
	gradient.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	gradient.offsets = PackedFloat32Array()
	gradient.colors = PackedColorArray()
	var count := palette.color_count()
	for i in count:
		gradient.add_point(float(i) / float(count), palette.get_color(i))
	# add_point() cannot remove the two default stops, so drop them afterwards.
	while gradient.get_point_count() > count:
		gradient.remove_point(gradient.get_point_count() - 1)
	_confetti.color_initial_ramp = gradient


static func _make_scrap_texture() -> ImageTexture:
	var image := Image.create(CONFETTI_SCRAP_SIZE, CONFETTI_SCRAP_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)


## The emitter is a [Node2D], so it does not follow Control anchors: keep it a
## screen-wide strip just above the top edge.
func _layout_confetti() -> void:
	if not is_instance_valid(_confetti):
		return
	_confetti.position = Vector2(size.x * 0.5, -30.0)
	_confetti.emission_rect_extents = Vector2(maxf(size.x * 0.5, 1.0), 8.0)


func _burst_confetti() -> void:
	if not is_instance_valid(_confetti):
		return
	_layout_confetti()
	_confetti.emitting = false
	_confetti.restart()
	_confetti.emitting = true


## The live confetti emitter. Tests assert the burst; the game never reads it.
func get_confetti() -> CPUParticles2D:
	return _confetti


## The congratulation currently (or last) shown.
func get_celebration_message() -> String:
	return _celebration_message.text if is_instance_valid(_celebration_message) else ""


## The celebration overlay itself. Tests assert that it never intercepts input;
## the game only ever tweens its alpha.
func get_celebration_overlay() -> Control:
	return _celebration


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

extends Node
## The project's ONE autoload (DESIGN.md 3.4): global state that genuinely has no
## owning scene. Registered as [code]GameState[/code] in project.godot.
##
## M3 scope: the difficulty [member mode] and the [PaletteDef] it selects.
## M4 adds the current [member current_book] / [member current_page_index] and the
## cursor helpers that walk a book ([method start_book], [method advance_page]).
## Save-load of progress arrives in M5 -- NOTHING here is persisted yet.
##
## The structure is deliberate and unchanged: all state is plain instance vars
## (no statics, no hidden globals), every mutation emits a past-tense signal, and
## resource lookup is table-driven.
##
## Screens read [method get_active_palette] and hand the result DOWN to the
## palette component and the coloring screen; nothing reaches back up into here
## from inside a component's subtree. The book cursor lives here rather than in a
## screen because it outlives any one screen: the coloring screen is freed and
## rebuilt between books, and M5's save system needs the same two values.

## Emitted after [member mode] actually changes. Payload is the new mode id.
signal mode_changed(mode: String)
## Emitted by [method start_book] once a book becomes the current one.
signal book_started(book: BookDef)
## Emitted whenever [member current_page_index] changes (including the reset to 0
## in [method start_book]).
signal current_page_changed(page_index: int)
## Emitted by [method finish_book] -- the player colored the last page.
signal book_finished(book: BookDef)

const MODE_CHILD := PaletteDef.MODE_CHILD
const MODE_ADULT := PaletteDef.MODE_ADULT

## mode id -> palette resource. The single place a palette path is written down.
const PALETTE_PATHS := {
	MODE_CHILD: "res://resources/palettes/child_palette.tres",
	MODE_ADULT: "res://resources/palettes/adult_palette.tres",
}

## Current difficulty mode, "child" or "adult" (DESIGN.md 1). Assigning an
## unknown id is refused with an error and leaves the mode untouched; assigning
## the current id is a no-op and emits nothing.
var mode: String = MODE_CHILD:
	set(value):
		var normalized := value.strip_edges().to_lower()
		if not PALETTE_PATHS.has(normalized):
			push_error("GameState: unknown mode '%s'; keeping '%s'." % [value, mode])
			return
		if normalized == mode:
			return
		mode = normalized
		mode_changed.emit(mode)

## The book being colored, or null outside a book (title/mode/book select).
## Assign through [method start_book]; read freely.
var current_book: BookDef = null

## Zero-based index into [code]current_book.pages[/code]. Meaningless while
## [member current_book] is null. Assign through [method start_book] /
## [method advance_page] / [method set_page_index].
var current_page_index: int = 0

## mode id -> loaded PaletteDef. Palettes are immutable authored data, so one
## instance per mode is shared by everything that asks.
var _palette_cache: Dictionary = {}


# ======================================================================= mode ==

## Method form of assigning [member mode], for signal connections and UI callbacks.
func set_mode(new_mode: String) -> void:
	mode = new_mode


func is_child_mode() -> bool:
	return mode == MODE_CHILD


## Every mode id the game knows, in presentation order.
func get_available_modes() -> PackedStringArray:
	return PackedStringArray([MODE_CHILD, MODE_ADULT])


# =================================================================== palettes ==

## The [PaletteDef] for the current [member mode]. Null only if the .tres is
## missing or does not parse as a PaletteDef (an error is pushed either way).
func get_active_palette() -> PaletteDef:
	return get_palette_for_mode(mode)


## The [PaletteDef] for any mode id. Loaded once, then cached.
func get_palette_for_mode(mode_id: String) -> PaletteDef:
	if _palette_cache.has(mode_id):
		return _palette_cache[mode_id]
	if not PALETTE_PATHS.has(mode_id):
		push_error("GameState: no palette registered for mode '%s'." % mode_id)
		return null
	var path: String = PALETTE_PATHS[mode_id]
	var palette := load(path) as PaletteDef
	if palette == null:
		push_error("GameState: '%s' did not load as a PaletteDef." % path)
		return null
	if palette.mode != mode_id:
		push_warning(
			"GameState: '%s' declares mode '%s' but is registered under '%s'."
			% [path, palette.mode, mode_id]
		)
	_palette_cache[mode_id] = palette
	return palette


## The scene path of the palette component for a mode. The coloring screen
## instantiates this blindly -- both components share one contract
## (color_picked / brush_size_picked / set_palette).
func get_palette_scene_path(mode_id: String = "") -> String:
	var resolved := mode_id if mode_id != "" else mode
	return (
		"res://scenes/components/palette_child.tscn"
		if resolved == MODE_CHILD
		else "res://scenes/components/palette_adult.tscn"
	)


## Drops cached palettes so an edited .tres is picked up. Dev/tests only.
func reload_palettes() -> void:
	_palette_cache.clear()


# ============================================================== book cursor ==
# The player's position in a book: which book, which page. M5 persists exactly
# these two values (plus per-page completion) to user://.

## Makes [param book] current and rewinds to [param page_index] (clamped into the
## book). Emits [signal book_started] then [signal current_page_changed].
## Passing null clears the cursor (see [method clear_book]).
func start_book(book: BookDef, page_index: int = 0) -> void:
	if book == null:
		clear_book()
		return
	current_book = book
	current_page_index = clampi(page_index, 0, maxi(book.page_count() - 1, 0))
	book_started.emit(book)
	current_page_changed.emit(current_page_index)


## Steps to the next page. Returns [code]false[/code] when there is no next page
## (the cursor stays on the last one, so the book is still queryable while the
## "book complete" screen shows). Emits [signal current_page_changed] on success.
func advance_page() -> bool:
	if current_book == null:
		return false
	if not current_book.has_page(current_page_index + 1):
		return false
	current_page_index += 1
	current_page_changed.emit(current_page_index)
	return true


## Jumps to an arbitrary page (clamped). Emits [signal current_page_changed] only
## when the index actually moves.
func set_page_index(page_index: int) -> void:
	if current_book == null:
		return
	var clamped := clampi(page_index, 0, maxi(current_book.page_count() - 1, 0))
	if clamped == current_page_index:
		return
	current_page_index = clamped
	current_page_changed.emit(current_page_index)


## The [PageDef] under the cursor, or null when there is no current book.
func get_current_page() -> PageDef:
	if current_book == null:
		return null
	return current_book.get_page(current_page_index)


func has_current_book() -> bool:
	return current_book != null


## Pages in the current book; 0 when there is none.
func current_book_page_count() -> int:
	return current_book.page_count() if current_book != null else 0


## Human-facing "3/12" for the coloring screen's toolbar. Empty without a book.
func current_page_label() -> String:
	if current_book == null:
		return ""
	return "%d/%d" % [current_page_index + 1, current_book.page_count()]


func is_on_last_page() -> bool:
	if current_book == null:
		return false
	return current_page_index >= current_book.page_count() - 1


## Announces that the current book is finished. The cursor is LEFT ALONE so the
## screen that reacts can still read the book; call [method clear_book] when
## leaving for the shelf.
func finish_book() -> void:
	if current_book == null:
		return
	book_finished.emit(current_book)


## Leaves the current book. Emits nothing -- there is no book to talk about.
func clear_book() -> void:
	current_book = null
	current_page_index = 0

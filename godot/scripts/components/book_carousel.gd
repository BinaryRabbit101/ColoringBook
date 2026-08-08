class_name BookCarousel
extends Control
## The books on a rail you slide along, one shelf deep (BL-49).
##
## [b]Why the grid had to go.[/b] The shelf used to be a wrapping [GridContainer]
## that filled from the top left (BL-43) and grew DOWN. The two shell buttons the
## screen is dressed with -- the settings gear and "More books" -- are overlays
## [Main] pins to the top corners, and once BL-48 scaled them for a phone they grew
## to ~460 x 173 canvas pixels each. On a portrait phone that is a pair of slabs
## sitting exactly where the first row of books was: the playtest note for BL-49 is
## "the buttons on mobile are covering up some of the coloring book selections".
## A grid cannot dodge them, because a grid's job is to use the whole width.
##
## A rail can. There is exactly ONE row of books now, it starts below whatever
## [method BookSelect.set_chrome_band] says the shell is using, and it runs off the
## right-hand edge for as long as it needs to -- the books that do not fit are
## reached by SWIPING rather than by being smaller.
##
## [b]The bookcase did not change.[/b] [ShelfBoards] still draws the carcass and one
## plank per row of the grid; the grid is simply one row of N columns now, so it
## draws one long shelf. Nothing in [ShelfBoards], [ShelfBackdrop] or [BookCell]
## knows this node exists.
##
## [b]The whole rail is one scaled [Control].[/b] [code]Track[/code] carries a
## uniform [member Control.scale] and everything -- books, planks, contact shadows,
## lettering -- comes along with it, which is why a phone gets BIG books instead of
## the same 224 px card painted into a third of the glass (BL-48's complaint, one
## layer down). Scaling the node rather than re-authoring the sizes also means
## [BookCell] keeps drawing in the space its constants were written for, so the
## spine, the page lip and the title stay in proportion at every scale.
##
## [codeblock]
## book scale = min(OverlayMetrics.content_scale, the height this band can give)
## [/codeblock]
##
## The first half is BL-48's measured phone squeeze -- exactly 1.0 on a desktop, so
## a desktop book is still the 224 x 300 it was authored at. The second half is what
## stops a landscape phone, whose logical canvas is SHORT, from asking for a book
## taller than the screen.
##
## [b]The gesture[/b] is [InputEventScreenTouch] / [InputEventScreenDrag] with
## "Emulate Touch From Mouse" on -- one code path for finger and mouse, the rule
## [PaletteSlideInput] and [PageView] already follow (DESIGN.md 3.3). It is read in
## [method Node._input], which runs BEFORE the GUI phase, so the rail can watch a
## press that a [BookCell] is also watching and only take it over once the finger
## has travelled [constant DRAG_SLOP]. Until then the press belongs to the book, and
## a tap opens it exactly as it always did.
##
## [b]A swipe must never open a book[/b], and that is defended twice: the cells are
## told to [method BookCell.cancel_press] the moment a drag is claimed (which drops
## the pending press inside [BaseButton] itself), and [method consumed_gesture] stays
## true until the next press so [BookSelect] can ignore a [signal BaseButton.pressed]
## that arrives anyway. The second guard exists because the ORDER of the real mouse
## button event and the touch event emulated from it is the engine's business, not
## ours.

## A book came to rest in front of the reader. Presentational -- nothing in the game
## listens yet; the harnesses do.
signal snapped(index: int)

## How far a finger may travel before the press stops being a tap and becomes a
## swipe. Generous, because a book is a big target and a child's tap wanders.
const DRAG_SLOP := 14.0
## How long the rail takes to settle onto the book it picked.
const SNAP_SECONDS := 0.34
## The flick's momentum, expressed as "where would this be if it kept going for this
## long". The rail then snaps to whatever book is nearest THAT, which is what makes a
## hard flick skip books and a gentle one move by one.
const FLICK_PROJECTION := 0.20
## Runaway guard for the projection above (a single 4 ms drag event can imply an
## absurd speed).
const MAX_FLICK_SPEED := 9000.0
## Room left above and below the bookcase so a hovered book's lift (BookCell tips it
## out of the shelf) is not sliced off by [member Control.clip_contents].
const LIFT_HEADROOM := 26.0
## A book never shrinks below this, however short the band is -- past it the title
## stops being legible and the thing has stopped being a book.
const MIN_BOOK_SCALE := 0.55
## ...and never grows past BL-48's content cap, for BL-48's reason.
const MAX_BOOK_SCALE := OverlayMetrics.MAX_CONTENT_SCALE
## Mouse wheel / trackpad: one book per notch.
const WHEEL_BOOKS := 1

@onready var _track: Control = $Track
@onready var _bookcase: Control = $Track/Bookcase

## The books, in shelf order. Injected by [BookSelect] -- this node never scans
## anything and never builds a cell.
var _cells: Array[BookCell] = []
var _book_scale := 1.0
var _content_size := Vector2.ZERO
var _max_offset := 0.0
var _tween: Tween

## Touch index of the gesture in progress, -1 when idle.
var _touch_index := -1
var _press_position := Vector2.ZERO
## True once the gesture has travelled past the slop. Cleared on the NEXT press, not
## on release -- see the class doc's note about event order.
var _dragged := false
var _velocity := 0.0
var _last_drag_usec := 0

## How far the rail has been slid, in CANVAS pixels. 0 is "the left end of the
## bookcase against the left edge of the band", which is where a fresh shelf sits --
## BL-43's "the first book is always in the same place", kept.
var scroll_offset := 0.0:
	set = set_scroll_offset


func _ready() -> void:
	# The rail runs off both edges by design; without this the books that have been
	# swiped past would be drawn over the room, the header and the shell buttons.
	clip_contents = true
	# PASS, not STOP: the books are children and must get the press first (class doc).
	mouse_filter = Control.MOUSE_FILTER_PASS
	if is_instance_valid(_track):
		_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(relayout)
	var viewport := get_viewport()
	if viewport != null:
		# The band's own rect can stay put while the WINDOW changes shape underneath
		# it, and the book scale is measured off the window (BL-48's squeeze).
		viewport.size_changed.connect(relayout)
	relayout()


# ==================================================================== contents ==

## The books on the rail, in shelf order. [BookSelect] owns them (they are the
## grid's children); this node is only told which they are, so it can work out where
## a swipe should come to rest.
func set_cells(cells: Array[BookCell]) -> void:
	_cells = cells.duplicate()
	_stop_animation()
	_dragged = false
	_touch_index = -1
	# A new shelf starts at its left end, whatever the old one was scrolled to.
	scroll_offset = 0.0
	relayout()


func get_cells() -> Array[BookCell]:
	return _cells.duplicate()


# ====================================================================== layout ==

## Re-measures the bookcase, re-picks the book scale and re-clamps the offset. Safe
## to call at any time and idempotent -- everything it reads is measured.
func relayout() -> void:
	if not is_inside_tree() or not is_instance_valid(_bookcase):
		return
	var band := size
	if band.x < 1.0 or band.y < 1.0:
		return

	# The bookcase is the child of a plain Control, so nothing else is going to size
	# it: it gets exactly what its own contents ask for and the rail scrolls it.
	var wanted := _bookcase.get_combined_minimum_size()
	if not _bookcase.size.is_equal_approx(wanted):
		_bookcase.size = wanted
	_content_size = wanted

	var fits := (band.y - LIFT_HEADROOM * 2.0) / maxf(wanted.y, 1.0)
	_book_scale = clampf(
		minf(OverlayMetrics.content_scale(get_viewport()), fits),
		MIN_BOOK_SCALE, MAX_BOOK_SCALE
	)
	_track.scale = Vector2(_book_scale, _book_scale)

	var scaled := wanted * _book_scale
	_max_offset = maxf(scaled.x - band.x, 0.0)
	# Vertically centred in whatever the band turned out to be, never above it.
	_track.position.y = maxf((band.y - scaled.y) * 0.5, 0.0)
	set_scroll_offset(scroll_offset)


## The uniform scale every book, plank and shadow on the rail is drawn at. 1.0 on a
## desktop by construction (see the class doc).
func get_book_scale() -> float:
	return _book_scale


## Width of the whole bookcase in canvas pixels, scale included.
func get_content_width() -> float:
	return _content_size.x * _book_scale


## The furthest the rail can be slid. Zero means the whole bookcase already fits.
func get_max_offset() -> float:
	return _max_offset


func set_scroll_offset(value: float) -> void:
	scroll_offset = clampf(value, 0.0, _max_offset)
	if not is_instance_valid(_track):
		return
	# Left-aligned, ALWAYS -- a shelf that fits is not centred. That is BL-43's rule
	# ("the grid fills from the top left") surviving the rewrite: a child's eye starts
	# at the left edge, and the first book has to be in the same place whether the
	# shelf holds two books or twenty.
	_track.position.x = -scroll_offset


# ================================================================== the snapping ==

## Where the rail comes to rest with book [param index] at the left of the band.
## Clamped, so the first and last books rest against their ends rather than being
## dragged into the middle of an empty band.
func offset_for_index(index: int) -> float:
	if index < 0 or index >= _cells.size() or not is_instance_valid(_track):
		return 0.0
	var cell := _cells[index]
	if not is_instance_valid(cell) or not cell.is_inside_tree():
		return 0.0
	# Track space: the cell's own left edge, minus the bookcase's carcass, so the
	# rail rests with the upright flush against the band and a book right behind it.
	var local := (cell.global_position.x - _track.global_position.x) / maxf(_book_scale, 0.001)
	return clampf((local - ShelfBoards.SIDE_PAD) * _book_scale, 0.0, _max_offset)


## The book the rail is currently resting on (or nearest to).
func get_focused_index() -> int:
	return _index_nearest(scroll_offset)


## Slides book [param index] into view. [param animate] false is for tests and for a
## rebuild, which must land in one frame.
func snap_to_index(index: int, animate: bool = true) -> void:
	if _cells.is_empty():
		return
	var target := offset_for_index(clampi(index, 0, _cells.size() - 1))
	_stop_animation()
	if not animate or not is_inside_tree() or is_equal_approx(target, scroll_offset):
		set_scroll_offset(target)
		snapped.emit(get_focused_index())
		return
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "scroll_offset", target, SNAP_SECONDS)
	_tween.finished.connect(func() -> void: snapped.emit(get_focused_index()))


## True while the whole of [param cell] is inside the band -- what "reachable by
## swiping" means when a harness asserts it.
func is_cell_fully_visible(cell: BookCell) -> bool:
	if not is_instance_valid(cell) or not cell.is_inside_tree():
		return false
	var rect := get_cell_rect(cell)
	return rect.position.x >= global_position.x - 0.5 \
		and rect.end.x <= global_position.x + size.x + 0.5


## Where [param cell] is actually drawn, in canvas space. [member Control.size] alone
## does not answer that here: the whole rail carries a scale, so a book's rect is its
## authored size times [method get_book_scale]. Anything measuring a book against
## something OUTSIDE the rail -- a harness checking that no book ended up under a
## shell button -- has to ask this rather than [method Control.get_global_rect].
func get_cell_rect(cell: BookCell) -> Rect2:
	if not is_instance_valid(cell) or not cell.is_inside_tree():
		return Rect2()
	return Rect2(cell.global_position, cell.size * _book_scale)


func _index_nearest(offset: float) -> int:
	var best := 0
	var best_distance := INF
	for i in _cells.size():
		var distance := absf(offset_for_index(i) - offset)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


func _stop_animation() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


# ==================================================================== the swipe ==

## True when the gesture that is ending was a SWIPE rather than a tap. Stays true
## until the next press, so a [signal BaseButton.pressed] that arrives after the
## finger lifted can still be ignored (class doc).
func consumed_gesture() -> bool:
	return _dragged


func is_dragging() -> bool:
	return _touch_index >= 0 and _dragged


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _cells.is_empty():
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_begin(touch.index, touch.position)
		elif touch.index == _touch_index:
			var was_swipe := _dragged
			_release()
			if was_swipe:
				get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenDrag and (event as InputEventScreenDrag).index == _touch_index:
		if _drag(event as InputEventScreenDrag):
			get_viewport().set_input_as_handled()
		return
	# The wheel is read here rather than in _gui_input because a BookCell is
	# MOUSE_FILTER_STOP: Godot ends the GUI walk at it, so a wheel notch over a book
	# would never reach this node's _gui_input at all.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var wheel := event as InputEventMouseButton
		if _max_offset <= 0.0 or not _contains(wheel.position):
			return
		match wheel.button_index:
			MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_RIGHT:
				snap_to_index(get_focused_index() + WHEEL_BOOKS)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT:
				snap_to_index(get_focused_index() - WHEEL_BOOKS)
				get_viewport().set_input_as_handled()


func _begin(touch_index: int, position: Vector2) -> void:
	_dragged = false
	_touch_index = -1
	_velocity = 0.0
	if not _contains(position) or not _is_topmost():
		return
	_touch_index = touch_index
	_press_position = position
	_last_drag_usec = Time.get_ticks_usec()
	# The press itself is NOT consumed: the book under the finger owns it until the
	# finger proves otherwise.


## Returns true when the event belongs to a swipe and should be marked handled.
func _drag(event: InputEventScreenDrag) -> bool:
	# The gesture arrives in viewport pixels; the band may sit under any canvas
	# transform, so the travel is converted rather than assumed (PaletteSlideInput's
	# rule, one dimension up).
	var basis := get_global_transform_with_canvas().affine_inverse()
	var relative := basis.basis_xform(event.relative)
	if not _dragged:
		var travel := basis.basis_xform(event.position - _press_position)
		if absf(travel.x) < DRAG_SLOP:
			return false
		_dragged = true
		# The press under the finger is dropped the instant this becomes a swipe, so
		# nothing opens when the finger lifts (class doc).
		for cell in _cells:
			if is_instance_valid(cell):
				cell.cancel_press()
		_stop_animation()

	var now := Time.get_ticks_usec()
	var seconds := float(now - _last_drag_usec) / 1_000_000.0
	_last_drag_usec = now
	if seconds > 0.0:
		# Smoothed: one 4 ms sample is noise, and the flick projection is built on it.
		_velocity = lerpf(_velocity, -relative.x / seconds, 0.55)
	set_scroll_offset(scroll_offset - relative.x)
	return true


func _release() -> void:
	_touch_index = -1
	if not _dragged:
		return
	var speed := clampf(_velocity, -MAX_FLICK_SPEED, MAX_FLICK_SPEED)
	# Momentum and snapping are the same gesture: coast the flick forward on paper,
	# then land on whichever book is nearest where it WOULD have stopped.
	snap_to_index(_index_nearest(scroll_offset + speed * FLICK_PROJECTION))


## An overlay over the shelf (the pack shop's scrim) owns the gesture, not the rail.
## [method Node._input] runs before the GUI phase, so the rect test alone cannot see
## it. Fails open, exactly as [PaletteSlideInput] does.
func _is_topmost() -> bool:
	var viewport := get_viewport()
	if viewport == null:
		return true
	var hovered := viewport.gui_get_hovered_control()
	if hovered == null:
		return true
	return hovered == self or is_ancestor_of(hovered)


## Rect test in this control's own space, so a stretched canvas is handled.
func _contains(viewport_position: Vector2) -> bool:
	if not is_inside_tree():
		return false
	var local := get_global_transform_with_canvas().affine_inverse() * viewport_position
	return Rect2(Vector2.ZERO, size).has_point(local)

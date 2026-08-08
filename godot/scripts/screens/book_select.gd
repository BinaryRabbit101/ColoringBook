class_name BookSelect
extends Control
## The shelf: every coloring book the game ships, as tappable cover cards
## (DESIGN.md 2).
##
## [b]Books are discovered, not listed[/b]. [method load_books] scans
## [code]res://resources/books/[/code] through [method BookDef.discover] -- one
## directory per book, each holding a [code]book.tres[/code]. Dropping a new book
## directory into the project puts it on the shelf with no code change. A
## hardcoded preload list would make every new book a code edit, and would rot the
## moment a book is renamed. Since WP7 the same call also picks up books from
## installed DLC packs under [code]user://dlc/[/code] -- same shelf, same ordering,
## two sources.
##
## [b]In a shipped build the first of those two sources is empty[/b] (BL-25): the
## export presets exclude [code]resources/books/*[/code] and [code]assets/books/*[/code],
## so the [code]res://[/code] scan finds nothing by construction and every card on
## the shelf came from the server. Nothing about discovery changes -- the books are
## excluded from the export, not from the project, so the editor and every dev
## harness still see them. What DOES change is that "no cards" is a normal first-run
## state rather than a bug, which is what [constant EMPTY_WITH_SHOP] is for.
##
## Signals up: [signal book_chosen]. The parent decides what happens next (M5's
## [code]main.tscn[/code] swaps in the coloring screen); this screen never does.
##
## [b]BL-28 gave it a room and a bookcase[/b]: [ShelfBackdrop] paints the wall, the
## light, the floor and the vignette behind everything, and [ShelfBoards] -- the
## grid's SIBLING inside [code]Bookcase[/code], so both get the same rect -- reads
## the cells back out of the grid after every sort and draws a wooden plank under
## each ROW, plus the carcass around them. Nothing here decides how many shelves
## there are; the layout does, and the furniture follows.
##
## [b]BL-49 turned the grid into a rail.[/b] The books used to wrap into a
## responsive grid that filled from the top left (BL-43) and grew DOWN, into exactly
## the corners [Main] pins the settings gear and "More books" to -- which after
## BL-48 scaled those two for a phone was a playtest complaint: "the buttons on
## mobile are covering up some of the coloring book selections". There is one row
## now, inside [BookCarousel], and it is swiped along rather than wrapped. The grid
## did not go away (it is one row of N columns, so [ShelfBoards] draws one long
## plank with no change at all); what went away is the wrapping, and with it any
## chance of a book being laid out under a shell button.
##
## [b]This screen still knows nothing about those buttons.[/b] They are [Main]'s
## overlays and [Main] measures them; it calls [method set_chrome_band] with the two
## numbers that describe the strip they occupy, and the header and the rail are laid
## out under it. Told, never discovered -- the parent injects, exactly as it does
## with the book list itself. With nobody telling it (every dev harness that drives
## this scene on its own) the band is zero and the layout is the desktop one.

## The player picked a book.
signal book_chosen(book: BookDef)

## Gap between books on the rail, and the width the bookcase's own carcass eats on
## each side (BL-28) -- the boards draw into it, so the rail's resting position is
## measured from it (see [method BookCarousel.offset_for_index]).
const CELL_SEPARATION := 24
const SHELF_FRAME_SIDE := ShelfBoards.SIDE_PAD
## Width an EMPTY bookcase asks for -- min, max -- so "no books yet" still shows a
## piece of furniture rather than a hole. Clamped to what the band can give.
const EMPTY_CASE_WIDTH_RANGE := Vector2(240.0, 520.0)

## The empty shelf, with a server in the build: the normal state of a fresh install
## since BL-25, and the reason this string points at something to press. "More
## books" is [code]main.gd[/code]'s overlay button, which is on screen next to this
## label whenever the shelf is up.
const EMPTY_WITH_SHOP := "No coloring books yet.\nA grown-up can tap “More books” to add some."
## The empty shelf with no server configured at all -- a build that can only ever
## show what it was given. Nothing to press, so nothing is promised.
const EMPTY_WITHOUT_SHOP := "No coloring books yet."

@onready var _margin: MarginContainer = $Margin
@onready var _body: VBoxContainer = $Margin/Body
@onready var _header_row: MarginContainer = $Margin/Body/HeaderRow
@onready var _header: PanelContainer = $Margin/Body/HeaderRow/Header
@onready var _title: Label = $Margin/Body/HeaderRow/Header/Title
@onready var _carousel: BookCarousel = $Margin/Body/Carousel
@onready var _bookcase: MarginContainer = $Margin/Body/Carousel/Track/Bookcase
@onready var _boards: ShelfBoards = $Margin/Body/Carousel/Track/Bookcase/Boards
@onready var _grid: GridContainer = $Margin/Body/Carousel/Track/Bookcase/Shelf
@onready var _empty_label: Label = $Margin/Body/EmptyLabel

var _cells: Array[BookCell] = []

## The strip along the top the shell's corner buttons occupy, in canvas pixels, and
## the width a CENTRED sign has between them. Both are told to us by [Main] (see
## [method set_chrome_band]); zero and -1 mean "nobody said", which is the desktop
## layout and every harness that drives this scene alone.
var _chrome_bottom := 0.0
var _chrome_free_width := -1.0
## The sign as authored, captured before anything is scaled so the scaling stays
## idempotent (the BL-48 baseline pattern, one screen down).
var _title_base_font := 0
var _header_base_width := 0.0


func _ready() -> void:
	_empty_label.visible = false
	_title_base_font = _title.get_theme_font_size("font_size")
	_header_base_width = _header.get_combined_minimum_size().x
	_fit_bookcase_frame()
	_boards.set_grid(_grid)
	resized.connect(_relayout)
	var viewport := get_viewport()
	if viewport != null:
		# The screen's own rect does not change when only the WINDOW does -- the
		# logical canvas can stay 1152 wide while the squeeze doubles -- and the sign
		# is sized off that squeeze (BL-48).
		viewport.size_changed.connect(_relayout)
	_relayout()


## The [code]Bookcase[/code] margins ARE the space [ShelfBoards] draws its carcass
## into -- it deliberately paints outside its own rect (Godot does not clip
## [method CanvasItem._draw] to a control's box). Taking the numbers from the
## drawing's own constants rather than trusting the ones saved in the scene keeps
## the two from drifting apart.
func _fit_bookcase_frame() -> void:
	_bookcase.add_theme_constant_override("margin_left", int(ShelfBoards.SIDE_PAD))
	_bookcase.add_theme_constant_override("margin_right", int(ShelfBoards.SIDE_PAD))
	_bookcase.add_theme_constant_override("margin_top", int(ShelfBoards.TOP_PAD))
	_bookcase.add_theme_constant_override("margin_bottom", int(ShelfBoards.BOTTOM_PAD))


# ====================================================================== data ==

## Scans [param root] (built-in books) and [param dlc_root] (installed DLC packs,
## WP7) and fills the shelf. Returns the number of books shown. Passing "" as
## [param dlc_root] shows built-in books only, which is what the dev harnesses that
## assert an exact shelf size do.
func load_books(root: String = BookDef.BOOKS_ROOT, dlc_root: String = BookDef.DLC_ROOT) -> int:
	return set_books(BookDef.discover(root, dlc_root))


## Fills the shelf from an explicit list (dependency injection for tests and for
## a future "recently opened" shelf). Returns the number of books shown.
func set_books(books: Array[BookDef]) -> int:
	_clear()
	for book in books:
		if book == null:
			continue
		var cell := BookCell.new()
		cell.name = "Book_%s" % book.display_name.to_snake_case()
		cell.set_book(book)
		cell.pressed.connect(_on_cell_pressed.bind(book))
		_grid.add_child(cell)
		_cells.append(cell)
	_empty_label.text = EMPTY_WITH_SHOP if Backend.is_enabled() else EMPTY_WITHOUT_SHOP
	_empty_label.visible = _cells.is_empty()
	_relayout()
	_carousel.set_cells(_cells)
	return _cells.size()


func get_cells() -> Array[BookCell]:
	return _cells.duplicate()


func get_book_count() -> int:
	return _cells.size()


## The rail, so a harness can swipe it and measure where the books ended up.
func get_carousel() -> BookCarousel:
	return _carousel


## The "Pick a book" sign. Public so a harness can assert it is clear of the shell's
## corner buttons rather than eyeballing a screenshot (BL-49).
func get_sign() -> Control:
	return _header


# ==================================================================== layout ==

## What [Main] knows and this screen does not: [param bottom] is how far down the
## canvas its corner buttons reach (their inset, their height, and an inset of
## clearance underneath), and [param free_width] is how wide a sign centred on the
## canvas can be before it runs into one of them -- twice the SMALLER of the two
## gaps, because the two buttons are not the same width and the sign is centred.
##
## Passing a negative [param free_width] means "unconstrained".
func set_chrome_band(bottom: float, free_width: float) -> void:
	if is_equal_approx(bottom, _chrome_bottom) and is_equal_approx(free_width, _chrome_free_width):
		return
	_chrome_bottom = maxf(bottom, 0.0)
	_chrome_free_width = free_width
	if is_node_ready():
		_relayout()


## One row, as wide as it needs to be: the grid gets a column per book, so
## [ShelfBoards] draws one long plank under one long row and the rail does the rest.
func _relayout() -> void:
	if not is_instance_valid(_grid) or not is_node_ready():
		return
	_grid.columns = maxi(_cells.size(), 1)
	_lay_out_header()
	_size_empty_case()
	_carousel.relayout()


## The sign, and the room the shell's buttons need above the rail.
##
## The sign grows with BL-48's phone squeeze like everything else -- but only as far
## as it can while still fitting BETWEEN the two corner buttons. When even its
## authored width will not fit between them (a portrait phone, where "More books"
## alone is 40% of the canvas), it goes BELOW the band instead and takes the full
## squeeze, because a sign that overlaps a button is the bug this round is fixing.
func _lay_out_header() -> void:
	var squeeze := OverlayMetrics.content_scale(get_viewport())
	var free := _chrome_free_width
	var unconstrained := free < 0.0 or _header_base_width <= 0.0
	var title_scale := squeeze if unconstrained else clampf(free / _header_base_width, 1.0, squeeze)
	var fits_beside := unconstrained or _header_base_width * title_scale <= free
	if not fits_beside:
		title_scale = squeeze

	_title.add_theme_font_size_override(
		"font_size", maxi(1, int(round(float(_title_base_font) * title_scale)))
	)

	var top := float(_margin.get_theme_constant("margin_top"))
	var separation := float(_body.get_theme_constant("separation"))
	# Beside the buttons: the sign stays at the top and the ROW is what reaches past
	# the band, so the rail below it starts clear. Below them: the sign itself is
	# pushed down and the row is whatever that adds up to.
	_header_row.add_theme_constant_override(
		"margin_top", 0 if fits_beside else int(maxf(_chrome_bottom - top, 0.0))
	)
	_header_row.custom_minimum_size.y = (
		maxf(_chrome_bottom - top - separation, 0.0) if fits_beside else 0.0
	)


## An empty shelf has no cells to size the bookcase, so the drawing is given a
## minimum box of its own -- two bare planks' worth, no wider than the rail can
## show. Zero once there are books: the grid sizes the case from then on.
func _size_empty_case() -> void:
	if not is_instance_valid(_boards):
		return
	if not _cells.is_empty():
		_boards.custom_minimum_size = Vector2.ZERO
		return
	var available := _carousel.size.x - SHELF_FRAME_SIDE * 2.0
	if available <= 0.0:
		available = size.x - 48.0 - SHELF_FRAME_SIDE * 2.0
	_boards.custom_minimum_size = Vector2(
		clampf(available, EMPTY_CASE_WIDTH_RANGE.x, EMPTY_CASE_WIDTH_RANGE.y),
		ShelfBoards.empty_min_size().y
	)


func _clear() -> void:
	_cells.clear()
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()


## A tap opens the book; a SWIPE that happens to end on one does not (BL-49). The
## rail already drops the pending press when it claims the gesture, so this guard is
## the belt to that pair of braces -- the order in which a real mouse release and
## the touch event emulated from it reach us is the engine's business.
func _on_cell_pressed(book: BookDef) -> void:
	if is_instance_valid(_carousel) and _carousel.consumed_gesture():
		return
	book_chosen.emit(book)

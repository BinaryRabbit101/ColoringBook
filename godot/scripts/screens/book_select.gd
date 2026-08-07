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
## [b]BL-28 gave it a room and a bookcase[/b] without moving a single book. The
## grid is still the layout: [ShelfBackdrop] paints the wall, the light, the floor
## and the vignette behind everything, and [ShelfBoards] -- the grid's SIBLING
## inside [code]Bookcase[/code], so both get the same rect -- reads the cells back
## out of the grid after every sort and draws a wooden plank under each ROW, plus
## the carcass around them. Nothing here decides how many shelves there are; the
## column maths does, exactly as before, and the furniture follows.

## The player picked a book.
signal book_chosen(book: BookDef)

## Card footprint used to decide how many columns fit.
const CELL_WIDTH := BookCell.DEFAULT_SIZE.x
## Gap between cards, horizontally and vertically.
const CELL_SEPARATION := 24
## Never more than this many across, however wide the window -- a wall of tiny
## columns is worse than a comfortable grid.
const MAX_COLUMNS := 5
## Width the bookcase's own carcass eats on each side (BL-28). Subtracted from the
## space the columns are fitted into, so adding furniture around the grid can never
## push a book off the edge of a narrow screen.
const SHELF_FRAME_SIDE := ShelfBoards.SIDE_PAD
## Width an EMPTY bookcase asks for -- min, max -- so "no books yet" still shows a
## piece of furniture rather than a hole. Clamped to what the screen can give.
const EMPTY_CASE_WIDTH_RANGE := Vector2(240.0, 520.0)

## The empty shelf, with a server in the build: the normal state of a fresh install
## since BL-25, and the reason this string points at something to press. "More
## books" is [code]main.gd[/code]'s overlay button, which is on screen next to this
## label whenever the shelf is up.
const EMPTY_WITH_SHOP := "No coloring books yet.\nA grown-up can tap “More books” to add some."
## The empty shelf with no server configured at all -- a build that can only ever
## show what it was given. Nothing to press, so nothing is promised.
const EMPTY_WITHOUT_SHOP := "No coloring books yet."

@onready var _bookcase: MarginContainer = $Margin/Body/Scroll/Row/Bookcase
@onready var _boards: ShelfBoards = $Margin/Body/Scroll/Row/Bookcase/Boards
@onready var _grid: GridContainer = $Margin/Body/Scroll/Row/Bookcase/Shelf
@onready var _empty_label: Label = $Margin/Body/EmptyLabel

var _cells: Array[BookCell] = []


func _ready() -> void:
	_empty_label.visible = false
	_fit_bookcase_frame()
	_boards.set_grid(_grid)
	resized.connect(_relayout_columns)
	_relayout_columns()


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
	_relayout_columns()
	return _cells.size()


func get_cells() -> Array[BookCell]:
	return _cells.duplicate()


func get_book_count() -> int:
	return _cells.size()


# ==================================================================== layout ==

## One column per card that fits, clamped to [1, MAX_COLUMNS]. Clamping the floor
## to 1 is what makes a single-book shelf lay out correctly at any window size --
## the grid never asks for zero columns, and the shelf is shrink-centred so that
## one card sits in the middle rather than pinned to the left edge.
func _relayout_columns() -> void:
	if not is_instance_valid(_grid):
		return
	# The Margin container's left+right margins, then the bookcase's own carcass:
	# the books get what is left over.
	var available := size.x - 48.0 - SHELF_FRAME_SIDE * 2.0
	var per_cell := CELL_WIDTH + float(CELL_SEPARATION)
	var fit := int(floor((available + float(CELL_SEPARATION)) / per_cell))
	_grid.columns = clampi(mini(fit, MAX_COLUMNS), 1, MAX_COLUMNS)
	_size_empty_case(available)


## An empty shelf has no cells to size the bookcase, so the drawing is given a
## minimum box of its own -- two bare planks' worth, no wider than the screen can
## hold. Zero once there are books: the grid sizes the case from then on.
func _size_empty_case(available: float) -> void:
	if not is_instance_valid(_boards):
		return
	if not _cells.is_empty():
		_boards.custom_minimum_size = Vector2.ZERO
		return
	_boards.custom_minimum_size = Vector2(
		clampf(available, EMPTY_CASE_WIDTH_RANGE.x, EMPTY_CASE_WIDTH_RANGE.y),
		ShelfBoards.empty_min_size().y
	)


func _clear() -> void:
	_cells.clear()
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()


func _on_cell_pressed(book: BookDef) -> void:
	book_chosen.emit(book)

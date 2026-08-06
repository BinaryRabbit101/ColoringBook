class_name BookDef
extends Resource
## One coloring book: a title, cover art and an ORDERED list of [PageDef]s
## (DESIGN.md 2, 3.4).
##
## Pure data. The book select screen shows [method get_cover_texture] +
## [member display_name] + [method page_count]; the coloring screen walks
## [member pages] in order and hands each one's paths to [code]PageView[/code].
##
## Instances live in [code]res://resources/books/<book_name>/book.tres[/code],
## with their pages in [code].../pages/page_XX.tres[/code].

## Where [method discover] scans. One directory per book, each holding a book file.
const BOOKS_ROOT := "res://resources/books"
## Accepted book file names inside a book directory, in probe order. The second
## entry covers exported builds, where "Convert text resources to binary" can
## rewrite an authored .tres as a .res next to it.
const BOOK_FILE_NAMES: PackedStringArray = ["book.tres", "book.res"]

## Book title as the player sees it.
@export var display_name: String = ""

## Cover art. Leave empty to use page 1's display image, which is what every book
## does so far -- a page's own visible art is a perfectly good cover and avoids
## shipping a second copy of the same drawing. (Page 1's DISPLAY image: a page's
## optional masking image is never shown, cover included.)
@export_file("*.png") var cover_image_path: String = ""

## The pages, in the order they are coloured. Index 0 is page 1.
@export var pages: Array[PageDef] = []


# ==================================================================== lookups ==

func page_count() -> int:
	return pages.size()


## The page at [param index], or null when out of range (callers treat null as
## "past the last page").
func get_page(index: int) -> PageDef:
	if index < 0 or index >= pages.size():
		return null
	return pages[index]


func has_page(index: int) -> bool:
	return index >= 0 and index < pages.size()


## Path of the cover image: the authored one, else page 1's display image, else "".
func get_cover_path() -> String:
	if cover_image_path != "":
		return cover_image_path
	var first := get_page(0)
	return first.display_image_path if first != null else ""


func get_cover_texture() -> Texture2D:
	var path := get_cover_path()
	if path == "" or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


# ================================================================== discovery ==

## Every book under [param root], sorted by directory name so the shelf order is
## stable across platforms.
##
## [b]The pattern[/b]: books are found by SCANNING the filesystem, never by a
## hardcoded preload list -- dropping a new [code]resources/books/<name>/book.tres[/code]
## into the project is all it takes to ship a book. [DirAccess] lists res://
## contents in exported builds too (the PCK keeps a directory index), and
## [ResourceLoader.exists] resolves import remaps, so this works identically in
## the editor and in a packaged game.
##
## Directories without a book file are skipped silently: [code]pages/[/code]
## subfolders, art folders and work-in-progress drafts must not break the shelf.
static func discover(root: String = BOOKS_ROOT) -> Array[BookDef]:
	var books: Array[BookDef] = []
	if not DirAccess.dir_exists_absolute(root):
		push_warning("BookDef: books root '%s' does not exist." % root)
		return books
	var directories := DirAccess.get_directories_at(root)
	var names := Array(directories)
	names.sort()
	for directory_name: String in names:
		var book := load_from_directory(root.path_join(directory_name))
		if book != null:
			books.append(book)
	return books


## Loads the book file inside [param directory], or null when there is none (or
## it is not a [BookDef]).
static func load_from_directory(directory: String) -> BookDef:
	for file_name in BOOK_FILE_NAMES:
		var path := directory.path_join(file_name)
		if not ResourceLoader.exists(path):
			continue
		var book := load(path) as BookDef
		if book == null:
			push_error("BookDef: '%s' exists but did not load as a BookDef." % path)
			return null
		return book
	return null


# ================================================================= validation ==

## Human-readable problems with this book; empty means valid. Rolls up every
## page's own [method PageDef.validate] so one call checks the whole book.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if display_name.strip_edges() == "":
		problems.append("display_name is empty")
	if pages.is_empty():
		problems.append("pages is empty")
	for i in pages.size():
		var page := pages[i]
		if page == null:
			problems.append("pages[%d] is null" % i)
			continue
		for problem in page.validate():
			problems.append("pages[%d] (%s): %s" % [i, page.display_name, problem])
	if cover_image_path != "" and not ResourceLoader.exists(cover_image_path):
		problems.append("cover_image_path '%s' does not exist" % cover_image_path)
	if get_cover_path() == "":
		problems.append("no cover art (no cover_image_path and no page 1 display image)")
	return problems


func is_valid() -> bool:
	return validate().is_empty()

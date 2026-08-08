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
##
## [b]WP7: a book can also come from a DLC pack[/b] (DLC_SERVER.md 7.2/8.1).
## [method discover] scans a SECOND root, [constant DLC_ROOT], where an installed
## pack unpacks to [code]user://dlc/<pack_slug>/books/<book>/book.json[/code]; each
## of those JSON files is turned into a [BookDef]/[PageDef] pair IN MEMORY, with
## [member is_runtime] set and every path resolved to an absolute
## [code]user://[/code] file. Nothing about the [code]res://[/code] scan changed --
## a built-in book loads exactly as it always did -- and the two sets are de-duped
## by [member book_uid] with the BUILT-IN winning, because a pack may legitimately
## ship the same book the build already contains.

## Where [method discover] scans for built-in books. One directory per book, each
## holding a book file.
const BOOKS_ROOT := "res://resources/books"
## Where [method discover] scans for INSTALLED DLC packs (WP7/WP10). One directory
## per pack; its books live in [code]<pack>/books/<book>/book.json[/code].
const DLC_ROOT := "user://dlc"
## File describing one book inside a pack. Same shape as one entry of a pack
## manifest's [code]books[][/code] array (DLC_SERVER.md 7.2), so an installed tree
## is self-describing and can be hand-seeded for development.
const BOOK_JSON_NAME := "book.json"
## The installed pack's manifest. The GAME does not read this file -- that is the
## installer's job and [BookDef] reads [code]book.json[/code] -- with exactly one
## exception since BL-42: the pack-level [code]cover[/code], which is the only
## thing a manifest says that no book.json repeats.
const PACK_MANIFEST_NAME := "manifest.json"
## Accepted book file names inside a book directory, in probe order. The second
## entry covers exported builds, where "Convert text resources to binary" can
## rewrite an authored .tres as a .res next to it.
const BOOK_FILE_NAMES: PackedStringArray = ["book.tres", "book.res"]
## Pack directories [method discover_runtime] must ignore. WP10 downloads into
## [code]<slug>.incoming/[/code] and swaps it into place atomically only once the
## sha256s check out; a half-written pack must never reach the shelf.
const IGNORED_PACK_SUFFIXES: PackedStringArray = [".incoming", ".tmp", ".partial"]

## Stable identity of this book, ACROSS builds, devices and delivery mechanisms
## (DLC_SERVER.md 6.1). Authored here for a built-in book, read from
## [code]book.json[/code] for a DLC one -- and the same book delivered both ways
## carries the same uid on purpose.
##
## This is what the save file is keyed by ([method GameState.book_key]) and what
## the server calls a [code]book_uid[/code]. It must never change once a build has
## shipped with it: changing it orphans every player's progress for this book.
## Convention: lower-case, hyphenated, with the year it was authored
## ([code]coyote-2026[/code]).
@export var book_uid: String = ""

## Book title as the player sees it.
@export var display_name: String = ""

## Cover art. Leave empty to use page 1's display image, which is what a book with
## no artist-drawn cover does -- a page's own visible art is a perfectly good cover
## and avoids shipping a second copy of the same drawing. (Page 1's DISPLAY image:
## a page's optional masking image is never shown, cover included.)
##
## [b]An ARTIST-SUPPLIED cover is a different thing[/b] (BL-42) and
## [method has_artist_cover] is how the shelf and the book-open animation tell them
## apart: a real cover is painted to BE a cover, so it fills the front of the book
## and is what swings open, while the page-1 fallback stays a framed plate on a
## coloured cover because line art on white does not read as one.
@export_file("*.png") var cover_image_path: String = ""

## The pages, in the order they are coloured. Index 0 is page 1.
@export var pages: Array[PageDef] = []

# --------------------------------------------------------------- runtime books --
# Deliberately NOT exported: an authored .tres must never be able to claim it is a
# runtime book. Only [method from_json] sets these, on instances it built itself.

## True when this book was built from a DLC pack's [code]book.json[/code] and its
## files live under [code]user://[/code] rather than in the build.
var is_runtime: bool = false
## Pack this book was installed from ([code]user://dlc/<pack_slug>/[/code]), or ""
## for a built-in book. The entitlement filter (WP10) keys off this -- a book from
## a pack the player no longer owns is dropped by the CALLER, never by
## [method discover] (DLC_SERVER.md 8.1).
var pack_slug: String = ""
## Absolute directory this runtime book was loaded from, or "" for a built-in one.
var source_dir: String = ""


# ==================================================================== lookups ==

## The book's stable identity: its authored [member book_uid] when it has one.
## Falls back to the resource path, then the display name, so a book somebody
## forgot to give a uid still keys a save entry of its own rather than colliding
## with every other uid-less book.
func get_uid() -> String:
	var uid := book_uid.strip_edges()
	if uid != "":
		return uid
	if resource_path != "":
		return resource_path
	return "runtime:%s" % display_name



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
	return PageDef.load_texture(get_cover_path(), is_runtime)


## True when this book has a cover an ARTIST drew, rather than page 1 standing in
## for one (BL-42).
##
## [b]The test is "it is not page 1", not "the field is set"[/b], and that is
## deliberate. A pack manifest has always been allowed to name a cover, and the
## server has always filled that field in with the first page's display image --
## so an occupied [member cover_image_path] proves nothing on its own. Comparing it
## with page 1 answers the question that actually matters ("is there a second,
## different picture to show?") and it answers it the same way for an authored
## [code].tres[/code] book, for a pack written before covers existed, and for one
## written after.
func has_artist_cover() -> bool:
	var cover := cover_image_path.strip_edges()
	if cover == "":
		return false
	var first := get_page(0)
	if first != null and first.display_image_path == cover:
		return false
	return PageDef.file_exists(cover, is_runtime)


## The artist's cover, or null when page 1 is standing in for one. Callers that
## want a picture whatever happens use [method get_cover_texture].
func get_artist_cover_texture() -> Texture2D:
	return PageDef.load_texture(cover_image_path, is_runtime) if has_artist_cover() else null


# ================================================================== discovery ==

## Every book the player has, built-in ones first: [param root] scanned exactly as
## it always was, then the installed DLC packs under [param dlc_root].
##
## [b]De-duped by [member book_uid], and the built-in book WINS.[/b] The first
## published pack deliberately ships the same coyote book the build already
## contains, so that the download path can be exercised end to end; without this
## rule the shelf would show it twice and the two copies would fight over one save
## entry. Passing "" as [param dlc_root] scans built-in books only.
##
## Ordering rules are unchanged and simply extended: built-ins by directory name,
## then DLC books by pack slug and book directory name. Entitlement filtering is
## the CALLER's job (DLC_SERVER.md 8.1) -- this returns everything installed.
static func discover(root: String = BOOKS_ROOT, dlc_root: String = DLC_ROOT) -> Array[BookDef]:
	var books := discover_builtin(root)
	var seen := {}
	for book in books:
		seen[book.get_uid()] = true
	if dlc_root == "":
		return books
	for book in discover_runtime(dlc_root):
		var uid := book.get_uid()
		if seen.has(uid):
			print_verbose(
				"BookDef: DLC book '%s' (pack '%s') is already built in; keeping the built-in one."
				% [uid, book.pack_slug]
			)
			continue
		seen[uid] = true
		books.append(book)
	return books


## Every BUILT-IN book under [param root], sorted by directory name so the shelf
## order is stable across platforms.
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
##
## [b]An absent root is NORMAL since BL-25[/b] and says so quietly. A shipped build
## excludes [code]resources/books/*[/code] from the export, so the PCK has no such
## directory at all and this scan finds nothing by construction -- every book comes
## from the server. The scan itself is unchanged; only the noise is, because a
## warning printed on every shelf build for the designed-for case is a warning
## nobody will read when it means something.
static func discover_builtin(root: String = BOOKS_ROOT) -> Array[BookDef]:
	var books: Array[BookDef] = []
	if not DirAccess.dir_exists_absolute(root):
		print_verbose("BookDef: no built-in books root at '%s'; the shelf is the server's."
			% root)
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


# =========================================================== runtime discovery ==
# DLC packs (DLC_SERVER.md 7.2). A pack is PLAIN DATA -- PNGs, JSON and nothing
# executable -- unpacked to user://dlc/<pack_slug>/, so none of it goes through the
# Godot importer. That is a correctness win as much as a portability one: a runtime
# ImageTexture cannot be VRAM-compressed behind our back, which is the exact way an
# ID map's region ids get corrupted (DESIGN.md 3.2).

## Every book in every installed pack under [param dlc_root], sorted by pack slug
## then by book directory name. A missing root is normal (nothing installed yet)
## and is silent; a broken pack is skipped with a warning rather than taking the
## shelf down with it.
static func discover_runtime(dlc_root: String = DLC_ROOT) -> Array[BookDef]:
	var books: Array[BookDef] = []
	if dlc_root == "" or not DirAccess.dir_exists_absolute(dlc_root):
		return books
	var pack_names := Array(DirAccess.get_directories_at(dlc_root))
	pack_names.sort()
	for pack_name: String in pack_names:
		if _is_ignored_pack(pack_name):
			continue
		var pack_root := dlc_root.path_join(pack_name)
		var books_dir := pack_root.path_join("books")
		if not DirAccess.dir_exists_absolute(books_dir):
			continue
		var pack_cover := _pack_cover(pack_root)
		var book_names := Array(DirAccess.get_directories_at(books_dir))
		book_names.sort()
		for book_name: String in book_names:
			var book_dir := books_dir.path_join(book_name)
			var json_path := book_dir.path_join(BOOK_JSON_NAME)
			if not FileAccess.file_exists(json_path):
				continue
			var book := from_json_file(json_path, pack_root)
			if book == null:
				continue
			book.pack_slug = pack_name
			# BL-42: a pack may carry its cover at the MANIFEST level rather than per
			# book (7.2 has had a pack-level `cover` since the first manifest). A book
			# that named its own real cover keeps it; one that fell back to page 1
			# takes the pack's, which is how a single-book pack's artwork reaches the
			# shelf whichever of the two places the publisher put it.
			if pack_cover != "" and not book.has_artist_cover():
				book.cover_image_path = pack_cover
			books.append(book)
	return books


## The pack-level [code]cover[/code] of the manifest in [param pack_root], resolved
## to an absolute path -- or "" when there is none, the manifest is unreadable, or
## the file it names is not there.
##
## Read once per pack rather than once per book, and never fatal: a pack with no
## manifest still installs its books, exactly as it did before covers existed.
static func _pack_cover(pack_root: String) -> String:
	var manifest_path := pack_root.path_join(PACK_MANIFEST_NAME)
	if not FileAccess.file_exists(manifest_path):
		return ""
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(manifest_path)) != OK \
			or typeof(json.data) != TYPE_DICTIONARY:
		return ""
	var named := String((json.data as Dictionary).get("cover", "")).strip_edges()
	if named == "":
		return ""
	var resolved := PageDef.resolve_pack_path(named, pack_root, pack_root)
	return resolved if PageDef.file_exists(resolved, true) else ""


## True for a directory a download is still writing into, or a hidden one.
static func _is_ignored_pack(pack_name: String) -> bool:
	if pack_name.begins_with("."):
		return true
	for suffix in IGNORED_PACK_SUFFIXES:
		if pack_name.ends_with(suffix):
			return true
	return false


## Builds a runtime book from a pack's [code]book.json[/code].
## [param pack_root] is the pack directory the JSON's relative paths are resolved
## against; it defaults to two levels above the file, which is where an installed
## pack always puts it.
static func from_json_file(json_path: String, pack_root: String = "") -> BookDef:
	if not FileAccess.file_exists(json_path):
		push_warning("BookDef: no book.json at '%s'." % json_path)
		return null
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(json_path)) != OK \
			or typeof(json.data) != TYPE_DICTIONARY:
		push_warning("BookDef: '%s' is not a JSON object (%s)." % [json_path, json.get_error_message()])
		return null
	var book_dir := json_path.get_base_dir()
	var root := pack_root if pack_root != "" else book_dir.get_base_dir().get_base_dir()
	var book := from_json(json.data, root, book_dir)
	if book != null:
		book.source_dir = book_dir
	return book


## Builds a runtime book from one parsed [code]books[][/code] entry
## (DLC_SERVER.md 7.2). Returns null -- with a warning naming what was wrong -- for
## anything this client cannot use, because half a book on the shelf is worse than
## no book.
##
## [b]Required fields[/b]: [code]book_uid[/code], and a non-empty [code]pages[/code]
## array whose entries each carry [code]display[/code], [code]idmap[/code] and
## [code]regions[/code]. [b]Optional[/b]: [code]title[/code] (falls back to the
## uid), [code]cover[/code] (falls back to page 1's display image, exactly as an
## authored book does), and per page [code]page_index[/code] (the sort key; array
## order is the fallback), [code]title[/code] and [code]mask[/code].
## [code]image_size[/code] / [code]region_count[/code] are server-side validation
## data and are ignored here -- [PageView] measures the real files anyway.
##
## Paths are PACK-relative ([code]books/coyote-2026/page_01.png[/code]), as they
## are in the manifest this shape is copied from; an absolute
## [code]user://[/code] / [code]res://[/code] path is taken as-is, and a
## book-directory-relative name is accepted as a convenience for hand-seeded
## development packs.
static func from_json(data: Dictionary, pack_root: String, book_dir: String) -> BookDef:
	var uid := String(data.get("book_uid", "")).strip_edges()
	if uid == "":
		push_warning("BookDef: a book.json in '%s' has no book_uid; skipping it." % book_dir)
		return null
	var raw_pages: Variant = data.get("pages", [])
	if typeof(raw_pages) != TYPE_ARRAY or (raw_pages as Array).is_empty():
		push_warning("BookDef: book '%s' in '%s' has no pages; skipping it." % [uid, book_dir])
		return null

	var book := BookDef.new()
	book.is_runtime = true
	book.book_uid = uid
	book.display_name = String(data.get("title", uid))
	book.cover_image_path = _resolve_pack_path(
		String(data.get("cover", "")), pack_root, book_dir
	)

	# page_index is authoritative when present -- a pack may list pages in any
	# order, and the ORDER is the whole meaning of a book.
	var entries: Array = []
	for i in (raw_pages as Array).size():
		var raw: Variant = (raw_pages as Array)[i]
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		entries.append({"index": int((raw as Dictionary).get("page_index", i)), "order": i, "data": raw})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["index"]) != int(b["index"]):
			return int(a["index"]) < int(b["index"])
		return int(a["order"]) < int(b["order"])
	)

	for entry: Dictionary in entries:
		var page := PageDef.from_pack_entry(entry["data"], pack_root, book_dir, book.pages.size())
		if page == null:
			push_warning("BookDef: book '%s' has an unusable page; skipping the whole book." % uid)
			return null
		book.pages.append(page)
	if book.pages.is_empty():
		push_warning("BookDef: book '%s' in '%s' has no usable pages; skipping it." % [uid, book_dir])
		return null
	return book


## Absolute path for one of a pack's relative paths. Shared with [PageDef], which
## resolves the same way for its own artifacts.
static func _resolve_pack_path(raw: String, pack_root: String, book_dir: String) -> String:
	return PageDef.resolve_pack_path(raw, pack_root, book_dir)


# ================================================================= validation ==

## Human-readable problems with this book; empty means valid. Rolls up every
## page's own [method PageDef.validate] so one call checks the whole book.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if book_uid.strip_edges() == "":
		# WP7: the save file, and every server row, is keyed by this. A book
		# without one still runs, but its progress is keyed by a build-time path
		# that breaks the moment the book moves.
		problems.append("book_uid is empty")
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
	if cover_image_path != "" and not PageDef.file_exists(cover_image_path, is_runtime):
		problems.append("cover_image_path '%s' does not exist" % cover_image_path)
	if get_cover_path() == "":
		problems.append("no cover art (no cover_image_path and no page 1 display image)")
	return problems


func is_valid() -> bool:
	return validate().is_empty()

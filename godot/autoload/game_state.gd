extends Node
## The project's ONE autoload (DESIGN.md 3.4): global state that genuinely has no
## owning scene. Registered as [code]GameState[/code] in project.godot.
##
## M3 scope: the difficulty [member mode] and the [PaletteDef] it selects.
## M4 adds the current [member current_book] / [member current_page_index] and the
## cursor helpers that walk a book ([method start_book], [method advance_page]).
## M5 adds PERSISTENCE -- see the "persistence" section at the bottom. Everything
## that touches [code]user://[/code] lives here and nowhere else (godot-practices:
## "player progress/settings -> user://, written by GameState only"). Screens hand
## it an [Image] or a status; they never open a file.
##
## The structure is deliberate and unchanged: all state is plain instance vars
## (no statics, no hidden globals), every mutation emits a past-tense signal, and
## resource lookup is table-driven.
##
## Screens read [method get_active_palette] and hand the result DOWN to the
## palette component and the coloring screen; nothing reaches back up into here
## from inside a component's subtree. The book cursor lives here rather than in a
## screen because it outlives any one screen: the coloring screen is freed and
## rebuilt between books, and the save system needs the same two values.

## Emitted after [member mode] actually changes. Payload is the new mode id.
signal mode_changed(mode: String)
## Emitted by [method start_book] once a book becomes the current one.
signal book_started(book: BookDef)
## Emitted whenever [member current_page_index] changes (including the reset to 0
## in [method start_book]).
signal current_page_changed(page_index: int)
## Emitted by [method finish_book] -- the player colored the last page.
signal book_finished(book: BookDef)
## Emitted every time the save file is written. Dev/testing hook -- the game
## itself never listens. Payload is the absolute [code]user://[/code] path.
signal save_written(path: String)
## Emitted at the end of every [method load_save]. [param fresh] is true when
## there was nothing usable to load (missing, corrupt or a future schema) and the
## in-memory progress was therefore reset to empty.
signal save_loaded(fresh: bool)
## Emitted after [method erase_all_progress] has wiped the save and the paint
## layers.
signal progress_erased()

const MODE_CHILD := PaletteDef.MODE_CHILD
const MODE_ADULT := PaletteDef.MODE_ADULT

## mode id -> palette resource. The single place a palette path is written down.
const PALETTE_PATHS := {
	MODE_CHILD: "res://resources/palettes/child_palette.tres",
	MODE_ADULT: "res://resources/palettes/adult_palette.tres",
}

# ------------------------------------------------------------- persistence --

## Schema version of the save file. Bumping it means "this build writes a shape
## older builds cannot read"; see [method load_save] for what happens to a file
## from the future.
const SAVE_VERSION := 1
## Save file name, inside [method get_save_root]. The version is in the NAME as
## well as in the payload so a v2 build can ship next to a v1 file untouched.
const SAVE_FILE_NAME := "save_v1.json"
## Where a save from a newer build is moved before this build starts fresh, so
## the player's progress is never silently destroyed by a downgrade.
const SAVE_BACKUP_NAME := "save_v1.json.bak"
## Sub-directory of [method get_save_root] holding the per-page paint layers.
const PAINT_DIR_NAME := "paint"
## Default root: the real one. Only dev harnesses change it.
const DEFAULT_SAVE_ROOT := "user://"
## Mode a fresh install starts in. [method load_save] returns to it whenever
## there is nothing to load, so "no save file" and "first ever run" are the same
## state -- which is what makes the dev smokes deterministic.
const DEFAULT_MODE := MODE_CHILD

## Per-page statuses. "untouched" = never painted, "in_progress" = some paint,
## "complete" = every region passed the mode's coverage threshold.
const STATUS_UNTOUCHED := "untouched"
const STATUS_IN_PROGRESS := "in_progress"
const STATUS_COMPLETE := "complete"

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

## Where the save file and the paint layers live. Overridable so dev harnesses
## can run against a scratch directory (see [method set_save_root]).
var _save_root: String = DEFAULT_SAVE_ROOT

## book resource_path -> {
##     "slug": String, "current_page_index": int, "pages": Array[String] }
## The in-memory mirror of the "books" object in the save file.
var _books: Dictionary = {}

## Guards the cursor signal handlers while a save is being applied, so loading a
## file does not immediately rewrite it.
var _autosave_enabled := true
## One warning per process for a broken save file, not one per read.
var _reported_bad_save := false


func _ready() -> void:
	# The cursor signals ARE the save triggers: anything that moves the player
	# writes progress, so no screen has to remember to call save_now().
	book_started.connect(_on_book_started)
	current_page_changed.connect(_on_current_page_changed)
	book_finished.connect(_on_book_finished)
	load_save()


## Safety net for hosts that are not [code]main.tscn[/code] (dev scenes, a future
## editor tool). [code]main.gd[/code] handles the same notifications itself so it
## can flush the open page's PAINT layer first -- something only a screen can do.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		save_now()


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


# ================================================================ persistence ==
# Everything below owns user://. Nothing else in the project opens a file there.
#
# TWO artifacts, deliberately separate:
#
#   user://save_v1.json              small, structured, human-readable progress
#   user://paint/<slug>/page_NN.png  the actual pixels the player laid down
#
# Progress is tiny and is rewritten on every cursor move (see _ready). Paint
# layers are megabytes and come from a GPU readback, so they are written only at
# the three moments the design allows: a page completing, leaving a book, and the
# app quitting (coloring-mechanics: get_paint_image() is never in the paint loop).
#
# The save is keyed by BookDef.resource_path because that is the only stable
# identity a book has -- display names are localisable and page counts change.

## Root of everything this class writes. Ends with "/" or is a bare scheme.
func get_save_root() -> String:
	return _save_root


## Points persistence at a different directory and reloads from it. DEV/TEST
## ONLY: the shell smoke test uses it so a run cannot see, or clobber, the
## player's real save. Passing "" restores the default.
func set_save_root(root: String, reload: bool = true) -> void:
	_save_root = root if root != "" else DEFAULT_SAVE_ROOT
	_reported_bad_save = false
	if reload:
		load_save()


func get_save_path() -> String:
	return _save_root.path_join(SAVE_FILE_NAME)


func get_backup_save_path() -> String:
	return _save_root.path_join(SAVE_BACKUP_NAME)


## Directory holding every book's paint layers.
func get_paint_root() -> String:
	return _save_root.path_join(PAINT_DIR_NAME)


# ---------------------------------------------------------------- book keys --

## The save key for a book: its [code]resource_path[/code]. A book built at
## runtime (tests) has none, so its display name stands in -- prefixed, so it can
## never collide with a real path.
static func book_key(book: BookDef) -> String:
	if book == null:
		return ""
	if book.resource_path != "":
		return book.resource_path
	return "runtime:%s" % book.display_name


## Filesystem-safe directory name for a book's paint layers.
##
## [b]Derivation[/b] (stable, documented because it names files on the player's
## disk): take the book's OWN directory from its resource_path
## ([code]res://resources/books/test_book/book.tres[/code] ->
## [code]test_book[/code]), lower-case it and replace every character outside
## [code][a-z0-9_-][/code] with [code]_[/code], then append [code]_[/code] and 8
## hex digits of an FNV-1a hash of the FULL resource_path.
##
## The readable half keeps the folder browsable; the hash half guarantees two
## books whose directories happen to share a name (or differ only by case, on a
## case-insensitive filesystem) can never share a paint directory. The hash is
## hand-rolled rather than [method @GlobalScope.hash] precisely because this
## value is written to disk: it must not change when the engine changes.
static func book_slug(book_path: String) -> String:
	var directory := book_path.get_base_dir().get_file().to_lower()
	var safe := ""
	for i in directory.length():
		var character := directory[i]
		safe += character if _is_slug_char(character) else "_"
	if safe.replace("_", "") == "":
		safe = "book"
	return "%s_%08x" % [safe, _stable_hash(book_path)]


static func _is_slug_char(character: String) -> bool:
	return (
		(character >= "a" and character <= "z")
		or (character >= "0" and character <= "9")
		or character == "_"
		or character == "-"
	)


## FNV-1a, 32 bit. Deterministic across platforms and engine versions.
static func _stable_hash(text: String) -> int:
	var value := 2166136261
	for byte in text.to_utf8_buffer():
		value = (value ^ int(byte)) & 0xffffffff
		value = (value * 16777619) & 0xffffffff
	return value


## Absolute path of one page's saved paint layer. Page numbers are 1-based in the
## file name, matching the authored [code]page_01.tres[/code] naming.
func get_paint_path(book: BookDef, page_index: int) -> String:
	return get_paint_path_for_key(book_key(book), page_index)


func get_paint_path_for_key(key: String, page_index: int) -> String:
	if key == "":
		return ""
	return get_paint_root().path_join(book_slug(key)).path_join("page_%02d.png" % (page_index + 1))


# ---------------------------------------------------------------- progress ----

## A COPY of one book's saved state. Always a usable dictionary, even for a book
## that has never been opened:
## [code]{ current_page_index: int, pages: Array[String], slug: String }[/code].
func get_book_progress(book_path: String) -> Dictionary:
	if not _books.has(book_path):
		return {
			"current_page_index": 0,
			"pages": [],
			"slug": book_slug(book_path) if book_path != "" else "",
		}
	return (_books[book_path] as Dictionary).duplicate(true)


func has_book_progress(book_path: String) -> bool:
	return _books.has(book_path)


## Status of one page: one of the STATUS_* constants. Unknown pages are untouched.
func get_page_status(book_path: String, page_index: int) -> String:
	if not _books.has(book_path):
		return STATUS_UNTOUCHED
	var pages: Array = (_books[book_path] as Dictionary)["pages"]
	if page_index < 0 or page_index >= pages.size():
		return STATUS_UNTOUCHED
	return String(pages[page_index])


## Page the player should resume [param book] on: the saved cursor, clamped into
## the book. A book whose pages are ALL complete resumes at page 1 -- finishing a
## book is never a lockout (the shelf keeps opening it, paint and all).
func get_resume_index(book: BookDef) -> int:
	if book == null or book.page_count() == 0:
		return 0
	if is_book_complete(book):
		return 0
	var key := book_key(book)
	if not _books.has(key):
		return 0
	var saved := int((_books[key] as Dictionary)["current_page_index"])
	return clampi(saved, 0, book.page_count() - 1)


## True when every page of [param book] is recorded complete.
func is_book_complete(book: BookDef) -> bool:
	if book == null or book.page_count() == 0:
		return false
	var key := book_key(book)
	if not _books.has(key):
		return false
	var pages: Array = (_books[key] as Dictionary)["pages"]
	if pages.size() < book.page_count():
		return false
	for i in book.page_count():
		if String(pages[i]) != STATUS_COMPLETE:
			return false
	return true


## Records a page's status and saves. A page already recorded COMPLETE is never
## downgraded -- completion is sticky, exactly as it is in [CoverageTracker].
## Wipe a book with [method erase_book_progress] instead.
func mark_page_status(book: BookDef, page_index: int, status: String) -> void:
	if book == null or page_index < 0:
		return
	if status != STATUS_UNTOUCHED and status != STATUS_IN_PROGRESS and status != STATUS_COMPLETE:
		push_error("GameState: unknown page status '%s'." % status)
		return
	var entry := _entry_for(book, true)
	var pages: Array = entry["pages"]
	while pages.size() <= page_index:
		pages.append(STATUS_UNTOUCHED)
	var previous := String(pages[page_index])
	if previous == status or (previous == STATUS_COMPLETE and status != STATUS_COMPLETE):
		return
	pages[page_index] = status
	entry["pages"] = pages
	_autosave()


## Forgets everything about [param book]: its cursor, its page statuses and every
## saved paint layer. This is what "Color again" runs.
func erase_book_progress(book: BookDef) -> void:
	if book == null:
		return
	var key := book_key(book)
	_books.erase(key)
	_delete_recursive(get_paint_root().path_join(book_slug(key)))
	save_now()


## Wipes the save file and every paint layer, for every book. The mode is kept --
## it is a setting, not progress.
func erase_all_progress() -> void:
	_books.clear()
	_delete_recursive(get_paint_root())
	save_now()
	progress_erased.emit()


# ------------------------------------------------------------- paint layers --

## Writes one page's paint layer as a PNG. [param image] comes from
## [method PageView.get_paint_image] -- an expensive readback, so callers must
## only reach a save point (page complete / leaving the book / quitting).
func save_page_paint(book: BookDef, page_index: int, image: Image) -> bool:
	if book == null or image == null or page_index < 0:
		return false
	var path := get_paint_path(book, page_index)
	if path == "":
		return false
	_ensure_dir(path.get_base_dir())
	var error := image.save_png(path)
	if error != OK:
		push_error("GameState: could not write paint layer '%s' (error %d)." % [path, error])
		return false
	return true


## The saved paint layer for a page, or null when there is none (or it is
## unreadable -- a corrupt PNG must start the page blank, never crash).
func load_page_paint(book: BookDef, page_index: int) -> Image:
	if book == null or page_index < 0:
		return null
	var path := get_paint_path(book, page_index)
	if path == "" or not FileAccess.file_exists(path):
		return null
	var image := Image.load_from_file(path)
	if image == null:
		push_warning("GameState: paint layer '%s' did not load; the page starts blank." % path)
		return null
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image


func has_page_paint(book: BookDef, page_index: int) -> bool:
	var path := get_paint_path(book, page_index)
	return path != "" and FileAccess.file_exists(path)


# ------------------------------------------------------------- save / load ----

## Serialised form of everything persisted. Public so tests can compare against
## the file without re-parsing it.
func to_save_dict() -> Dictionary:
	var books := {}
	for key in _books:
		var entry: Dictionary = _books[key]
		books[key] = {
			"slug": entry["slug"],
			"current_page_index": int(entry["current_page_index"]),
			"pages": (entry["pages"] as Array).duplicate(),
		}
	return {
		"version": SAVE_VERSION,
		"mode": mode,
		"books": books,
	}


## Writes the save file now. Cheap (a few hundred bytes) -- it is called on every
## cursor move by design.
func save_now() -> bool:
	_ensure_dir(_save_root)
	var path := get_save_path()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error(
			"GameState: could not open '%s' for writing (error %d)."
			% [path, FileAccess.get_open_error()]
		)
		return false
	file.store_string(JSON.stringify(to_save_dict(), "\t", true))
	file.close()
	save_written.emit(path)
	return true


## Reads the save file into memory. Returns true only when real data was applied.
##
## Failure is never fatal and never noisy: a missing file is silent, a corrupt one
## warns ONCE per process and starts fresh, and a file from a FUTURE schema is
## moved aside to [constant SAVE_BACKUP_NAME] first so a downgrade cannot destroy
## a newer build's progress.
func load_save() -> bool:
	_books.clear()
	var path := get_save_path()
	if not FileAccess.file_exists(path):
		return _fresh_state()

	# A JSON instance rather than JSON.parse_string(): a corrupt save is a HANDLED
	# condition, and the static helper logs an engine-level ERROR for it, which
	# would make a recoverable situation look like a bug in the debug output.
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK \
			or typeof(json.data) != TYPE_DICTIONARY:
		_report_bad_save(
			"'%s' is not a JSON object (%s)" % [path, json.get_error_message()]
		)
		return _fresh_state()

	var data: Dictionary = json.data
	var version := int(data.get("version", 0))
	if version > SAVE_VERSION:
		_backup_save(path)
		_report_bad_save(
			"'%s' is schema v%d, newer than this build's v%d; it was backed up to '%s'"
			% [path, version, SAVE_VERSION, get_backup_save_path()]
		)
		return _fresh_state()
	if version != SAVE_VERSION:
		_report_bad_save("'%s' is schema v%d, which this build cannot read" % [path, version])
		return _fresh_state()

	_autosave_enabled = false
	var saved_mode := String(data.get("mode", mode))
	if PALETTE_PATHS.has(saved_mode):
		mode = saved_mode
	var books: Variant = data.get("books", {})
	if typeof(books) == TYPE_DICTIONARY:
		for key_variant in (books as Dictionary):
			var key := String(key_variant)
			var raw: Variant = (books as Dictionary)[key_variant]
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			var entry: Dictionary = raw
			var pages: Array = []
			var raw_pages: Variant = entry.get("pages", [])
			if typeof(raw_pages) == TYPE_ARRAY:
				for status_variant in (raw_pages as Array):
					var status := String(status_variant)
					pages.append(status if _is_known_status(status) else STATUS_UNTOUCHED)
			_books[key] = {
				"slug": book_slug(key),
				"current_page_index": maxi(int(entry.get("current_page_index", 0)), 0),
				"pages": pages,
			}
	_autosave_enabled = true
	save_loaded.emit(false)
	return true


## Nothing usable on disk: back to the shipped defaults, so a first run and a
## wiped run are indistinguishable.
func _fresh_state() -> bool:
	_books.clear()
	mode = DEFAULT_MODE
	save_loaded.emit(true)
	return false


static func _is_known_status(status: String) -> bool:
	return status == STATUS_UNTOUCHED or status == STATUS_IN_PROGRESS or status == STATUS_COMPLETE


func _report_bad_save(reason: String) -> void:
	if _reported_bad_save:
		return
	_reported_bad_save = true
	push_warning("GameState: %s; starting with fresh progress." % reason)


func _backup_save(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var backup := FileAccess.open(get_backup_save_path(), FileAccess.WRITE)
	if backup == null:
		return
	backup.store_string(text)
	backup.close()


# ------------------------------------------------------- cursor -> autosave ----

func _on_book_started(book: BookDef) -> void:
	_entry_for(book, true)
	_autosave()


func _on_current_page_changed(page_index: int) -> void:
	if current_book == null:
		return
	var entry := _entry_for(current_book, true)
	if int(entry["current_page_index"]) == page_index:
		return
	entry["current_page_index"] = page_index
	_autosave()


func _on_book_finished(_book: BookDef) -> void:
	_autosave()


## The entry for [param book], created (sized to the book) on demand.
func _entry_for(book: BookDef, create: bool) -> Dictionary:
	var key := book_key(book)
	if not _books.has(key):
		if not create:
			return {}
		_books[key] = {
			"slug": book_slug(key),
			"current_page_index": current_page_index if book == current_book else 0,
			"pages": [],
		}
	var entry: Dictionary = _books[key]
	var pages: Array = entry["pages"]
	while pages.size() < book.page_count():
		pages.append(STATUS_UNTOUCHED)
	entry["pages"] = pages
	return entry


func _autosave() -> void:
	if not _autosave_enabled:
		return
	save_now()


# ------------------------------------------------------------ file helpers ----

static func _ensure_dir(path: String) -> void:
	if path == "" or DirAccess.dir_exists_absolute(path):
		return
	DirAccess.make_dir_recursive_absolute(path)


## Removes a directory and everything under it. Missing paths are not an error --
## erasing progress that was never written must be a no-op, not a failure.
static func _delete_recursive(path: String) -> void:
	if path == "" or not DirAccess.dir_exists_absolute(path):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for name in directory.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in directory.get_directories():
		_delete_recursive(path.path_join(name))
	DirAccess.remove_absolute(path)

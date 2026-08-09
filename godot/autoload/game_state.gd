extends Node
## The project's ONE autoload (DESIGN.md 3.4): global state that genuinely has no
## owning scene. Registered as [code]GameState[/code] in project.godot.
##
## M3 scope: the [PaletteDef] the game paints with (one palette since BL-20 --
## there is no mode to select any more).
## M4 adds the current [member current_book] / [member current_page_index] and the
## cursor helpers that walk a book ([method start_book], [method advance_page]).
## M5 adds PERSISTENCE -- see the "persistence" section at the bottom. Everything
## that touches [code]user://[/code] lives here and nowhere else (godot-practices:
## "player progress/settings -> user://, written by GameState only"). Screens hand
## it an [Image] or a status; they never open a file.
##
## [b]The one exception, and its exact edges (WP10).[/b] The [code]Backend[/code]
## autoload owns two paths under [code]user://[/code] and nothing else:
## [codeblock]
## user://auth.json        this device's identity and  (AuthStore)
##                         its bearer token
## user://dlc/             installed DLC packs, and    (PackInstaller,
##                         the entitlement cache        EntitlementsStore)
## [/codeblock]
## Neither is player progress: one is a credential for the device, the other is
## CONTENT that arrived after the build. This class never opens either of them, and
## Backend never opens the save file, the paint layers or anything else in here --
## so there is exactly one writer per file, which is the property the rule was
## protecting.
##
## [b]Nothing outside this class ever writes a drawing.[/b] There is no cloud save
## and no sync: what the child paints is written under [code]user://[/code] by the
## methods below and lives nowhere else. [code]Backend[/code] downloads CONTENT
## (books and stickers to colour in); it never uploads or downloads a picture.
## [method BookDef.discover] READS [code]user://dlc/[/code], and
## [method book_key] keys a DLC book's progress by the same
## [member BookDef.book_uid] as a built-in one, so a book delivered both ways has
## one lot of progress (DLC_SERVER.md 6.1).
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

## Emitted by [method start_book] once a book becomes the current one.
signal book_started(book: BookDef)
## Emitted whenever [member current_page_index] changes (including the reset to 0
## in [method start_book]).
signal current_page_changed(page_index: int)
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
## The interval autosave came round (BL-6). Anything holding state this class
## cannot reach -- in practice the open [ColoringPage]'s paint layer -- flushes it
## in response. [method save_now] runs straight afterwards regardless, so a
## listener that does nothing still gets its progress written.
signal autosave_due()
## Emitted after [method erase_page_progress] has reset ONE page.
signal page_progress_erased(book: BookDef, page_index: int)
## Emitted after ONE page's paint layer has actually reached disk -- the paint
## half of [signal save_written]. Dev/testing hook; the game itself never listens.
##
## [b]It fires AFTER the write[/b], always, so a listener can read the file it
## names without racing the save it is reacting to -- and so the local save is
## never delayed by anything a listener does.
signal page_paint_written(book: BookDef, page_index: int, path: String)
## Emitted after [method set_page_locked] actually changed a page's coloring lock
## (BL-10). Nothing in the game listens today -- the screen that flipped the lock
## already knows -- but the shelf will want it the day a locked page is badged.
signal page_lock_changed(book: BookDef, page_index: int, locked: bool)

## The stickers on a page were written (BL-36). Tests wait on this; the game
## ignores it.
signal page_stickers_changed(book: BookDef, page_index: int, count: int)

## The one palette the game paints with (BL-20 removed the Child/Adult split).
## The single place its path is written down.
const PALETTE_PATH := "res://resources/palettes/child_palette.tres"
## The one palette component: the crayon row.
const PALETTE_SCENE_PATH := "res://scenes/components/palette_child.tscn"
## Save keys this build reads but never writes. [code]"mode"[/code] is the
## Child/Adult id every save written before BL-20 carries; the reader tolerates it
## (and anything else it does not know) so those files still load, which is why
## [constant SAVE_VERSION] did not have to move.
const VESTIGIAL_SAVE_KEYS := ["mode"]

# ------------------------------------------------------------- persistence --

## Schema version of the save file. Bumping it means "this build writes a shape
## older builds cannot read"; see [method load_save] for what happens to a file
## from the future.
##
## [b]v2 (WP7, DLC_SERVER.md 6.1)[/b]: the [code]books[/code] object is keyed by
## [member BookDef.book_uid] instead of by [code]resource_path[/code]. A build-time
## path is meaningless the moment the same book can arrive from
## [code]user://dlc/[/code] or from a server row, so the key had to become the
## book's own identity. Nothing else about the shape moved -- an entry is still
## [code]{slug, current_page_index, pages[]}[/code] with the BL-10 page objects.
const SAVE_VERSION := 2
## Save file name, inside [method get_save_root]. The version is in the NAME as
## well as in the payload so a v2 build can ship next to a v1 file untouched.
const SAVE_FILE_NAME := "save_v2.json"
## Where a save from a newer build is moved before this build starts fresh, so
## the player's progress is never silently destroyed by a downgrade.
const SAVE_BACKUP_NAME := "save_v2.json.bak"
## The schema this build can still MIGRATE from, and the file it lives in.
## [method load_save] reads it only when there is no v2 file, converts it, and
## leaves the original where it is -- a migration that deletes the only copy of the
## player's progress has no second chance if it is wrong.
const LEGACY_SAVE_VERSION := 1
const LEGACY_SAVE_FILE_NAME := "save_v1.json"

## v1 book key ([code]resource_path[/code]) -> v2 book key
## ([member BookDef.book_uid]). Every book this game has ever shipped is in here,
## and entries may never be removed: a save written by any older build has to be
## able to find its way across. Both file names are listed because an exported
## build can convert an authored [code].tres[/code] into a [code].res[/code].
##
## A v1 key that is NOT in this table (a book from a build we do not know, or a
## test's synthetic key) is carried over UNCHANGED, which keeps its progress and
## its paint directory exactly where they were.
const LEGACY_BOOK_UIDS := {
	"res://resources/books/coyote/book.tres": "coyote-2026",
	"res://resources/books/coyote/book.res": "coyote-2026",
	"res://resources/books/test_book/book.tres": "test-book-2026",
	"res://resources/books/test_book/book.res": "test-book-2026",
}
## Sub-directory of [method get_save_root] holding the per-page paint layers.
const PAINT_DIR_NAME := "paint"
## How much of a book uid the readable half of [method book_slug] keeps. Long
## enough for every uid we author, short enough that a hostile pack cannot hand us
## a 4 KB directory name.
const MAX_SLUG_READABLE_LENGTH := 40
## Default root: the real one. Only dev harnesses change it.
const DEFAULT_SAVE_ROOT := "user://"

## Seconds between interval autosaves (BL-6).
##
## Picked at the top of the 30-60 s band the backlog asked for: a page takes a
## child several minutes, so 45 s bounds what a crash or a killed tab can cost to
## under a minute of colouring, while being rare enough that the paint-layer
## readback and PNG write it triggers stay invisible. The tick is SKIPPED
## entirely when nothing has changed since the last save, so an idle page costs
## nothing at all.
const AUTOSAVE_INTERVAL_SECONDS := 45.0

## Per-page statuses. "untouched" = never painted, "in_progress" = some paint,
## "complete" = every region passed the palette's coverage threshold.
const STATUS_UNTOUCHED := "untouched"
const STATUS_IN_PROGRESS := "in_progress"
const STATUS_COMPLETE := "complete"

## Keys inside one [code]pages[][/code] entry.
##
## [b]BL-10 widened that entry[/b] from a bare status string to an object, so a
## page can carry its coloring LOCK next to its status. The schema version did NOT
## move, because the change is additive in both directions: [method _to_page_entry]
## still accepts the old bare string (a save written before BL-10 loads with every
## page unlocked), and a missing [constant PAGE_LOCKED_KEY] means unlocked.
##
## [b]BL-36 widened it once more, the same way and for the same price[/b]: a page
## also carries the STICKERS stuck on it. [constant SAVE_VERSION] did not move
## again -- a save written before BL-36 has no such key and loads with a bare page,
## and a build without BL-36 reads past a key it does not know (the reader has
## tolerated unknown page keys since BL-20's vestigial [code]"mode"[/code]).
## Stickers are not paint and are deliberately NOT in the paint PNG: they are a few
## numbers per sticker, so they belong in the JSON where undo, a resolution change
## and a re-published pack can all be survived exactly.
const PAGE_STATUS_KEY := "status"
const PAGE_LOCKED_KEY := "locked"
const PAGE_STICKERS_KEY := "stickers"

## The book being colored, or null outside a book (title / book select).
## Assign through [method start_book]; read freely.
var current_book: BookDef = null

## Zero-based index into [code]current_book.pages[/code]. Meaningless while
## [member current_book] is null. Assign through [method start_book] /
## [method advance_page] / [method set_page_index].
var current_page_index: int = 0

## The loaded [PaletteDef], or null before the first lookup. Authored data is
## immutable, so the one instance is shared by everything that asks.
var _palette: PaletteDef = null

## Where the save file and the paint layers live. Overridable so dev harnesses
## can run against a scratch directory (see [method set_save_root]).
var _save_root: String = DEFAULT_SAVE_ROOT

## BookDef.book_uid -> {
##     "slug": String, "current_page_index": int, "pages": Array[Dictionary] }
## where each page entry is { "status": String, "locked": bool } (BL-10).
## The in-memory mirror of the "books" object in the save file (schema v2).
var _books: Dictionary = {}

## Guards the cursor signal handlers while a save is being applied, so loading a
## file does not immediately rewrite it.
var _autosave_enabled := true
## One warning per process for a broken save file, not one per read.
var _reported_bad_save := false
## Drives [signal autosave_due]. Created here rather than in a scene because the
## autoload has no scene (godot-practices: autoloads are scripts).
var _autosave_timer: Timer


func _ready() -> void:
	# The cursor signals ARE the save triggers: anything that moves the player
	# writes progress, so no screen has to remember to call save_now().
	book_started.connect(_on_book_started)
	current_page_changed.connect(_on_current_page_changed)
	_start_autosave_timer()
	load_save()


## Safety net for hosts that are not [code]main.tscn[/code] (dev scenes, a future
## editor tool). [code]main.gd[/code] handles the same notifications itself so it
## can flush the open page's PAINT layer first -- something only a screen can do.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		save_now()


# =================================================================== palettes ==

## The game's [PaletteDef]. Loaded once, then cached. Null only if the .tres is
## missing or does not parse as a PaletteDef (an error is pushed either way).
##
## There is exactly one (BL-20): the crayon box. Its colours can be replaced at
## runtime by a [CrayonSetDef] (BL-23), but the brush and the completion threshold
## always come from here.
func get_active_palette() -> PaletteDef:
	if _palette != null:
		return _palette
	var palette := load(PALETTE_PATH) as PaletteDef
	if palette == null:
		push_error("GameState: '%s' did not load as a PaletteDef." % PALETTE_PATH)
		return null
	_palette = palette
	return _palette


## The scene path of the palette component. The coloring screen instantiates this
## blindly -- it only knows the contract (color_picked / brush_size_picked /
## set_palette).
func get_palette_scene_path() -> String:
	return PALETTE_SCENE_PATH


## Drops the cached palette so an edited .tres is picked up. Dev/tests only.
func reload_palettes() -> void:
	_palette = null


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


## Leaves the current book. Emits nothing -- there is no book to talk about.
func clear_book() -> void:
	current_book = null
	current_page_index = 0


# ================================================================ persistence ==
# Everything below owns user://. Nothing else in the project opens a file there.
#
# TWO artifacts, deliberately separate:
#
#   user://save_v2.json              small, structured, human-readable progress
#   user://paint/<slug>/page_NN.png  the actual pixels the player laid down
#
# Progress is tiny and is rewritten on every cursor move (see _ready). Paint
# layers are megabytes and come from a GPU readback, so they are written only at
# save POINTS, never in the paint loop (coloring-mechanics: get_paint_image() is
# never in the paint loop): a page completing, leaving a book, navigating between
# pages, the app quitting or backgrounding, the player pressing Save, and -- BL-6
# -- an AUTOSAVE_INTERVAL_SECONDS tick that finds unsaved strokes.
#
# The save is keyed by BookDef.book_uid (schema v2, WP7): the only identity a book
# keeps whether it is built in or installed from a DLC pack. Display names are
# localisable, page counts change, and paths are build-time facts -- none of the
# three can key progress.

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


## The v1 save file this build migrates from, if it is still there.
func get_legacy_save_path() -> String:
	return _save_root.path_join(LEGACY_SAVE_FILE_NAME)


## Directory holding every book's paint layers.
func get_paint_root() -> String:
	return _save_root.path_join(PAINT_DIR_NAME)


# ---------------------------------------------------------------- book keys --

## The save key for a book: its [member BookDef.book_uid] (save schema v2).
##
## [b]Why not the resource_path any more[/b] (DLC_SERVER.md 6.1): a path is a
## build-time fact. The same book can be built in at
## [code]res://resources/books/coyote/book.tres[/code] and installed from a pack at
## [code]user://dlc/coyote-book/books/coyote-2026/[/code], and it is one book with
## one lot of progress in both cases -- and one row on the server. The uid is the
## only identity that survives all three.
##
## Books with no authored uid fall back to their path, then to their display name
## (see [method BookDef.get_uid]), so a book somebody forgot to name still gets a
## save entry of its own instead of sharing one with every other unnamed book.
static func book_key(book: BookDef) -> String:
	if book == null:
		return ""
	return book.get_uid()


## Filesystem-safe directory name for a book's paint layers.
##
## [b]Derivation[/b] (stable, documented because it names files on the player's
## disk): take the book's uid ([code]coyote-2026[/code]), lower-case it and replace
## every character outside [code][a-z0-9_-][/code] with [code]_[/code], then append
## [code]_[/code] and 8 hex digits of an FNV-1a hash of the FULL key.
##
## The readable half keeps the folder browsable; the hash half guarantees two
## books whose readable halves collide (or differ only by case, on a
## case-insensitive filesystem) can never share a paint directory. The hash is
## hand-rolled rather than [method @GlobalScope.hash] precisely because this
## value is written to disk: it must not change when the engine changes.
##
## [b]v1 keys still work[/b]: a key that looks like a path keeps the v1 derivation
## (its own directory name plus the hash of the whole path), so an unmigrated -- or
## deliberately unmapped -- v1 entry still points at the paint directory it always
## did. That is what makes [method _migrate_paint_dir] able to compute the OLD
## directory name with this same function.
static func book_slug(book_uid: String) -> String:
	var readable := book_uid
	if readable.contains("/"):
		readable = readable.get_base_dir().get_file()
	readable = readable.to_lower().substr(0, MAX_SLUG_READABLE_LENGTH)
	var safe := ""
	for i in readable.length():
		var character := readable[i]
		safe += character if _is_slug_char(character) else "_"
	if safe.replace("_", "") == "":
		safe = "book"
	return "%s_%08x" % [safe, _stable_hash(book_uid)]


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


## Absolute path of one page's saved EFFECT MASK (BL-38), the animated finishes'
## second PNG. Beside the paint layer, in the same directory, with a
## [code]_fx[/code] suffix -- so the two travel together, are erased together, and a
## book whose paint directory is deleted loses both.
##
## [b]Why a second file and not a second channel of the first.[/b] The paint PNG is
## the picture: it is what a coverage restore reads, and what a human would open to
## see what the child drew. Widening it would mean every reader
## of it had to know about animation. A page with no animated wax on it simply has
## no such file, which is also what makes "the four bakeable boxes cost exactly what
## they cost before" true on disk as well as in memory.
func get_effect_path(book: BookDef, page_index: int) -> String:
	return get_effect_path_for_key(book_key(book), page_index)


func get_effect_path_for_key(key: String, page_index: int) -> String:
	if key == "":
		return ""
	return (
		get_paint_root().path_join(book_slug(key)).path_join("page_%02d_fx.png" % (page_index + 1))
	)


# ------------------------------------------------------------- page entries --
# One slot of a book's `pages` array. Kept behind these four helpers so the shape
# is written down in exactly one place -- and so the pre-BL-10 form (a bare status
# string) is normalised on the way in rather than being checked for at every call
# site.

static func _new_page_entry(
	status: String = STATUS_UNTOUCHED, locked: bool = false, stickers: Array = []
) -> Dictionary:
	return {
		PAGE_STATUS_KEY: status,
		PAGE_LOCKED_KEY: locked,
		PAGE_STICKERS_KEY: stickers,
	}


## Whatever a save file put in a page slot, as the current object form. A bare
## string is a save written before BL-10 (status only, never locked); an unknown
## status degrades to untouched rather than propagating garbage; a missing sticker
## list is a save written before BL-36 and means a page with no stickers on it.
static func _to_page_entry(raw: Variant) -> Dictionary:
	if typeof(raw) == TYPE_DICTIONARY:
		var entry: Dictionary = raw
		var status := String(entry.get(PAGE_STATUS_KEY, STATUS_UNTOUCHED))
		return _new_page_entry(
			status if _is_known_status(status) else STATUS_UNTOUCHED,
			bool(entry.get(PAGE_LOCKED_KEY, false)),
			_to_sticker_list(entry.get(PAGE_STICKERS_KEY, []))
		)
	var legacy := String(raw)
	return _new_page_entry(legacy if _is_known_status(legacy) else STATUS_UNTOUCHED, false)


## Whatever a save file put in a page's sticker slot, as a list of placement
## dictionaries. Anything that is not one is dropped rather than propagated: a
## corrupt entry costs one sticker, never the page and never the save.
static func _to_sticker_list(raw: Variant) -> Array:
	if typeof(raw) != TYPE_ARRAY:
		return []
	var out: Array = []
	for entry: Variant in (raw as Array):
		if typeof(entry) == TYPE_DICTIONARY:
			out.append((entry as Dictionary).duplicate())
	return out


## The MUTABLE entry at [param page_index], growing (and normalising) the array as
## needed. Every writer goes through here, so a legacy slot is upgraded in place
## the first time it is touched.
static func _page_slot(pages: Array, page_index: int) -> Dictionary:
	while pages.size() <= page_index:
		pages.append(_new_page_entry())
	if typeof(pages[page_index]) != TYPE_DICTIONARY:
		pages[page_index] = _to_page_entry(pages[page_index])
	return pages[page_index]


## Read-only field lookup that tolerates a short array and a legacy slot.
static func _page_field(pages: Array, page_index: int, key: String, fallback: Variant) -> Variant:
	if page_index < 0 or page_index >= pages.size():
		return fallback
	return _to_page_entry(pages[page_index])[key]


# ---------------------------------------------------------------- progress ----

## A COPY of one book's saved state. Always a usable dictionary, even for a book
## that has never been opened:
## [code]{ current_page_index: int, pages: Array[Dictionary], slug: String }[/code],
## each page entry being [code]{ status: String, locked: bool }[/code].
func get_book_progress(book_uid: String) -> Dictionary:
	if not _books.has(book_uid):
		return {
			"current_page_index": 0,
			"pages": [],
			"slug": book_slug(book_uid) if book_uid != "" else "",
		}
	return (_books[book_uid] as Dictionary).duplicate(true)


func has_book_progress(book_uid: String) -> bool:
	return _books.has(book_uid)


## Status of one page: one of the STATUS_* constants. Unknown pages are untouched.
func get_page_status(book_uid: String, page_index: int) -> String:
	if not _books.has(book_uid):
		return STATUS_UNTOUCHED
	var pages: Array = (_books[book_uid] as Dictionary)["pages"]
	return String(_page_field(pages, page_index, PAGE_STATUS_KEY, STATUS_UNTOUCHED))


## True when the player has put the coloring lock on this page (BL-10). Pages
## nobody has ever locked -- including every page of a save written before BL-10 --
## are unlocked.
func is_page_locked(book_uid: String, page_index: int) -> bool:
	if not _books.has(book_uid):
		return false
	var pages: Array = (_books[book_uid] as Dictionary)["pages"]
	return bool(_page_field(pages, page_index, PAGE_LOCKED_KEY, false))


## Puts the coloring lock on (or takes it off) ONE page and saves immediately.
##
## The lock is the player's guard against accidents, so it must survive a crash,
## a killed browser tab and a battery death the instant it is set -- and it costs a
## few hundred bytes of JSON, not a paint readback. It is deliberately INDEPENDENT
## of the page's status: locking a page changes nothing about how finished it is,
## and [method erase_page_progress] leaves the lock alone.
func set_page_locked(book: BookDef, page_index: int, locked: bool) -> bool:
	if book == null or page_index < 0 or not book.has_page(page_index):
		return false
	var entry := _entry_for(book, true)
	var page := _page_slot(entry["pages"], page_index)
	if bool(page[PAGE_LOCKED_KEY]) == locked:
		return true
	page[PAGE_LOCKED_KEY] = locked
	save_now()
	page_lock_changed.emit(book, page_index, locked)
	return true


## The stickers stuck on one page (BL-36), oldest first -- a COPY, in
## [StickerLayer]'s placement shape. Empty for a page with none, for a book that
## has never been opened, and for every page of a save written before BL-36.
func get_page_stickers(book_uid: String, page_index: int) -> Array:
	if not _books.has(book_uid):
		return []
	var pages: Array = (_books[book_uid] as Dictionary)["pages"]
	var stickers: Variant = _page_field(pages, page_index, PAGE_STICKERS_KEY, [])
	return (stickers as Array).duplicate(true)


## Records the stickers on ONE page and saves immediately.
##
## Written the moment it changes, exactly like [method set_page_locked] and for the
## same reason: it is a few hundred bytes of JSON rather than a paint readback, and
## a sticker a child stuck on has to survive a killed browser tab. Deliberately
## INDEPENDENT of the page's status -- covering a page in stickers finishes nothing
## (BL-36: stickers never count toward coverage).
func set_page_stickers(book: BookDef, page_index: int, placements: Array) -> bool:
	if book == null or page_index < 0 or not book.has_page(page_index):
		return false
	var entry := _entry_for(book, true)
	var page := _page_slot(entry["pages"], page_index)
	var stickers := _to_sticker_list(placements)
	if page[PAGE_STICKERS_KEY] == stickers:
		return true
	page[PAGE_STICKERS_KEY] = stickers
	save_now()
	page_stickers_changed.emit(book, page_index, stickers.size())
	return true


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
		if String(_page_field(pages, i, PAGE_STATUS_KEY, STATUS_UNTOUCHED)) != STATUS_COMPLETE:
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
	var page := _page_slot(entry["pages"], page_index)
	var previous := String(page[PAGE_STATUS_KEY])
	if previous == status or (previous == STATUS_COMPLETE and status != STATUS_COMPLETE):
		return
	page[PAGE_STATUS_KEY] = status
	_autosave()


## Forgets ONE page of [param book]: deletes its saved paint layer and puts its
## status back to untouched. Everything else about the book -- the cursor, the
## other pages -- is left alone. This is what the page's "Start over" button runs
## (BL-7).
##
## [b]The one place a status moves BACKWARDS.[/b] [method mark_page_status]
## refuses to downgrade a completed page on purpose, so that a stale in_progress
## write can never un-finish a page under the player; a deliberate reset is the
## exception, and it writes the entry directly for exactly that reason.
##
## The page's coloring LOCK is not progress and is left exactly as it was (BL-10 --
## in practice this is unreachable while locked, because the lock disables the
## Start over button that leads here).
func erase_page_progress(book: BookDef, page_index: int) -> bool:
	if book == null or page_index < 0 or not book.has_page(page_index):
		return false
	var path := get_paint_path(book, page_index)
	if path != "" and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	# BL-38: blank paper does not shimmer either.
	erase_page_effect(book, page_index)
	var entry := _entry_for(book, true)
	var page := _page_slot(entry["pages"], page_index)
	page[PAGE_STATUS_KEY] = STATUS_UNTOUCHED
	# BL-36: Start over means blank paper, and a sticker is very much on the paper.
	# (The coloring LOCK is still left alone -- it is not progress, BL-10.)
	page[PAGE_STICKERS_KEY] = []
	save_now()
	page_progress_erased.emit(book, page_index)
	return true


## Forgets everything about [param book]: its cursor, its page statuses and every
## saved paint layer. This is what "Color again" runs.
func erase_book_progress(book: BookDef) -> void:
	if book == null:
		return
	var key := book_key(book)
	_books.erase(key)
	_delete_recursive(get_paint_root().path_join(book_slug(key)))
	save_now()


## Wipes the save file and every paint layer, for every book.
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
	page_paint_written.emit(book, page_index, path)
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


# ------------------------------------------------------- effect masks (BL-38) --
# The animated finishes' half of the picture. Same shape as the paint layer above,
# same save POINTS, same "an expensive readback, so only a save point may call it"
# rule -- and one extra rule of its own: [b]a page with no animated wax on it never
# writes one, and deletes the one it had.[/b] Otherwise a child who shimmered a
# page and then coloured over it would keep paying for a megabyte of zeros for ever.

## Writes one page's effect mask as a PNG. [param image] comes from
## [method PageView.get_effect_image] / [method PageView.request_effect_image].
func save_page_effect(book: BookDef, page_index: int, image: Image) -> bool:
	if book == null or image == null or page_index < 0:
		return false
	var path := get_effect_path(book, page_index)
	if path == "":
		return false
	_ensure_dir(path.get_base_dir())
	var error := image.save_png(path)
	if error != OK:
		push_error("GameState: could not write effect mask '%s' (error %d)." % [path, error])
		return false
	return true


## The saved effect mask for a page, or null when there is none. A page whose mask
## will not load starts with its animation off and its colours intact -- the paint
## PNG is a separate file and is unaffected, which is the other half of why they are
## two files.
func load_page_effect(book: BookDef, page_index: int) -> Image:
	if book == null or page_index < 0:
		return null
	var path := get_effect_path(book, page_index)
	if path == "" or not FileAccess.file_exists(path):
		return null
	var image := Image.load_from_file(path)
	if image == null:
		push_warning("GameState: effect mask '%s' did not load; the page comes back still." % path)
		return null
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image


func has_page_effect(book: BookDef, page_index: int) -> bool:
	var path := get_effect_path(book, page_index)
	return path != "" and FileAccess.file_exists(path)


## Deletes one page's effect mask. Called when a page is saved with a dormant
## effect layer (the animation is genuinely gone), and by every erase path.
func erase_page_effect(book: BookDef, page_index: int) -> bool:
	var path := get_effect_path(book, page_index)
	if path == "" or not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(path) == OK


# ------------------------------------------------------------- save / load ----

## Serialised form of everything persisted. Public so tests can compare against
## the file without re-parsing it.
func to_save_dict() -> Dictionary:
	var books := {}
	for key in _books:
		var entry: Dictionary = _books[key]
		# Rebuilt entry by entry rather than duplicate()d: the page slots are
		# dictionaries now (BL-10), and a shallow copy would hand callers -- and
		# JSON.stringify -- the LIVE ones.
		var pages: Array = []
		for raw in (entry["pages"] as Array):
			pages.append(_to_page_entry(raw))
		books[key] = {
			"slug": entry["slug"],
			"current_page_index": int(entry["current_page_index"]),
			"pages": pages,
		}
	# BL-20: the "mode" key an older build wrote is NOT re-emitted. It is read
	# tolerantly (see [method load_save]) so those saves still load, but nothing in
	# the game branches on it any more, and a key nobody reads has no business being
	# written. SAVE_VERSION does not move: dropping a key is additive-tolerant in
	# both directions, the same argument BL-10 made for adding one.
	return {
		"version": SAVE_VERSION,
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
##
## [b]WP7 migration[/b]: when there is no v2 file but a v1 one is sitting there,
## the v1 file is read, converted by [method _migrate_v1_books] (keys rekeyed to
## uids, paint directories renamed) and written back out as v2. The v1 file itself
## is LEFT ALONE -- it costs a few hundred bytes and it is the only copy of the
## progress if the migration ever gets something wrong.
func load_save() -> bool:
	_books.clear()
	var path := get_save_path()
	var source := path
	if not FileAccess.file_exists(path):
		source = get_legacy_save_path()
		if not FileAccess.file_exists(source):
			return _fresh_state()

	# A JSON instance rather than JSON.parse_string(): a corrupt save is a HANDLED
	# condition, and the static helper logs an engine-level ERROR for it, which
	# would make a recoverable situation look like a bug in the debug output.
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(source)) != OK \
			or typeof(json.data) != TYPE_DICTIONARY:
		_report_bad_save(
			"'%s' is not a JSON object (%s)" % [source, json.get_error_message()]
		)
		return _fresh_state()

	var data: Dictionary = json.data
	var version := int(data.get("version", 0))
	if version > SAVE_VERSION:
		_backup_save(source)
		_report_bad_save(
			"'%s' is schema v%d, newer than this build's v%d; it was backed up to '%s'"
			% [source, version, SAVE_VERSION, get_backup_save_path()]
		)
		return _fresh_state()
	var migrated := false
	if version != SAVE_VERSION:
		if version != LEGACY_SAVE_VERSION:
			_report_bad_save("'%s' is schema v%d, which this build cannot read" % [source, version])
			return _fresh_state()
		data = data.duplicate()
		data["books"] = _migrate_v1_books(data.get("books", {}))
		data["version"] = SAVE_VERSION
		migrated = true

	_autosave_enabled = false
	# Keys in [constant VESTIGIAL_SAVE_KEYS] -- "mode", from before BL-20 -- are
	# read past, not honoured and not carried forward. Tolerating them is what lets
	# a pre-BL-20 file load at the same SAVE_VERSION.
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
				for page_variant in (raw_pages as Array):
					# Accepts BOTH shapes: the BL-10 object, and the bare status
					# string every save written before it used.
					pages.append(_to_page_entry(page_variant))
			_books[key] = {
				"slug": book_slug(key),
				"current_page_index": maxi(int(entry.get("current_page_index", 0)), 0),
				"pages": pages,
			}
	_autosave_enabled = true
	if migrated:
		# Write the v2 file straight away: the paint directories have already been
		# renamed, so leaving the conversion in memory would strand them if the
		# process died here.
		save_now()
		print_verbose("GameState: migrated '%s' to save schema v%d at '%s'."
			% [source, SAVE_VERSION, path])
	save_loaded.emit(false)
	return true


# ------------------------------------------------------- v1 -> v2 migration ----
# DLC_SERVER.md 6.1. Two things change and nothing else: the KEY of every books[]
# entry (resource_path -> book_uid) and the NAME of the paint directory that key
# derives (book_slug hashes the key, so a rekeyed book needs its pixels moved).

## The v2 [code]books[/code] object for a v1 one. Keys in
## [constant LEGACY_BOOK_UIDS] are rekeyed and their paint directories renamed;
## every other key is passed through untouched, which leaves its paint exactly
## where it already is.
func _migrate_v1_books(raw_books: Variant) -> Dictionary:
	var migrated := {}
	if typeof(raw_books) != TYPE_DICTIONARY:
		return migrated
	# Sorted so a merge (two v1 keys mapping to one uid, e.g. a .tres and a .res of
	# the same book) always resolves the same way on every device.
	var keys := (raw_books as Dictionary).keys()
	keys.sort()
	for key_variant in keys:
		var old_key := String(key_variant)
		var raw: Variant = (raw_books as Dictionary)[key_variant]
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = (raw as Dictionary).duplicate(true)
		var new_key := String(LEGACY_BOOK_UIDS.get(old_key, old_key))
		if new_key != old_key:
			_migrate_paint_dir(old_key, new_key)
		if migrated.has(new_key):
			migrated[new_key] = _merge_book_entries(migrated[new_key], entry)
		else:
			entry["slug"] = book_slug(new_key)
			migrated[new_key] = entry
	return migrated


## Moves [code]paint/<old slug>/[/code] to [code]paint/<new slug>/[/code].
## [method book_slug] still derives the v1 name from a path-shaped key, so the
## source directory is computed with the same function the v1 build used.
func _migrate_paint_dir(old_key: String, new_key: String) -> void:
	var from := get_paint_root().path_join(book_slug(old_key))
	var to := get_paint_root().path_join(book_slug(new_key))
	if from == to or not DirAccess.dir_exists_absolute(from):
		return
	if not DirAccess.dir_exists_absolute(to):
		_ensure_dir(get_paint_root())
		if DirAccess.rename_absolute(from, to) == OK:
			print_verbose("GameState: moved paint layers '%s' -> '%s'." % [from, to])
			return
	# Rename refused (the target already exists, or the platform would not do it):
	# move the files one at a time and NEVER overwrite. Losing a child's picture is
	# the one failure this whole migration exists to avoid.
	_ensure_dir(to)
	var directory := DirAccess.open(from)
	if directory == null:
		return
	var kept := 0
	for name in directory.get_files():
		if FileAccess.file_exists(to.path_join(name)):
			kept += 1
			continue
		DirAccess.rename_absolute(from.path_join(name), to.path_join(name))
	if kept > 0:
		push_warning(
			"GameState: %d paint layer(s) in '%s' already existed in '%s'; the originals were left in place."
			% [kept, from, to]
		)
	else:
		DirAccess.remove_absolute(from)


## Two v1 entries that migrate onto one uid. Merged the way the server merges two
## devices (DLC_SERVER.md 6.3): the better status wins per page, a lock anywhere
## wins, and the furthest cursor wins. Nothing is ever downgraded.
static func _merge_book_entries(into: Dictionary, other: Dictionary) -> Dictionary:
	var pages: Array = into.get("pages", [])
	var other_pages: Array = other.get("pages", [])
	for i in other_pages.size():
		var incoming := _to_page_entry(other_pages[i])
		var slot := _page_slot(pages, i)
		if _status_rank(String(incoming[PAGE_STATUS_KEY])) > _status_rank(String(slot[PAGE_STATUS_KEY])):
			slot[PAGE_STATUS_KEY] = incoming[PAGE_STATUS_KEY]
		slot[PAGE_LOCKED_KEY] = bool(slot[PAGE_LOCKED_KEY]) or bool(incoming[PAGE_LOCKED_KEY])
	into["pages"] = pages
	into["current_page_index"] = maxi(
		int(into.get("current_page_index", 0)), int(other.get("current_page_index", 0))
	)
	return into


## untouched < in_progress < complete (DLC_SERVER.md 6.3).
static func _status_rank(status: String) -> int:
	match status:
		STATUS_COMPLETE:
			return 2
		STATUS_IN_PROGRESS:
			return 1
		_:
			return 0


## Nothing usable on disk: back to the shipped defaults, so a first run and a
## wiped run are indistinguishable.
func _fresh_state() -> bool:
	_books.clear()
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
		pages.append(_new_page_entry())
	if book.page_count() > 0 and pages.size() > book.page_count():
		_forget_pages_beyond(key, book.page_count(), pages.size())
		pages.resize(book.page_count())
		entry["current_page_index"] = clampi(
			int(entry.get("current_page_index", 0)), 0, book.page_count() - 1
		)
	entry["pages"] = pages
	return entry


## Drops the saved paint layers of pages [param page_count]..[param old_size]-1,
## i.e. pages a save still remembers that the book no longer has.
##
## Books can SHRINK: BL-9 folded the coyote book's two bogus pages back into the
## one page the art always was, and a re-authored (or DLC-updated) book can do the
## same. A save written before that lists statuses -- and leaves PNGs on disk --
## for pages that are gone. Nothing crashes on them (every reader clamps against
## [method BookDef.has_page]), but they would sit in [code]user://[/code] forever
## and could make [method is_book_complete] answer about a page that no longer
## exists, so the entry is trimmed the first time the book is touched after the
## change. Sized to zero pages is NOT trimming material -- that is a broken book,
## not a shorter one, and progress must survive it.
func _forget_pages_beyond(key: String, page_count: int, old_size: int) -> void:
	for index in range(page_count, old_size):
		var path := get_paint_path_for_key(key, index)
		if path != "" and FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		var effect_path := get_effect_path_for_key(key, index)
		if effect_path != "" and FileAccess.file_exists(effect_path):
			DirAccess.remove_absolute(effect_path)
	print_verbose("GameState: trimmed %d stale page entr(ies) from '%s'."
		% [old_size - page_count, key])


func _autosave() -> void:
	if not _autosave_enabled:
		return
	save_now()


# ------------------------------------------------------- interval autosave ----
# BL-6. The event-driven save points (cursor moves, page complete, leaving a book,
# quitting) all still stand; this is the safety net UNDER them, for the player who
# colours one page for twenty minutes and never triggers any of them.
#
# The timer only announces the moment. It does NOT read the paint layer -- this
# class cannot reach a SubViewport, and would not want to on a fixed schedule
# anyway. The open screen listens to `autosave_due`, defers until the stroke in
# progress has ended, and writes its own pixels.

func _start_autosave_timer() -> void:
	_autosave_timer = Timer.new()
	_autosave_timer.name = "AutosaveTimer"
	_autosave_timer.wait_time = AUTOSAVE_INTERVAL_SECONDS
	_autosave_timer.autostart = true
	# Autosaving must survive a paused tree (a settings overlay, a future pause
	# screen): it is bookkeeping, not gameplay.
	_autosave_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_autosave_timer.timeout.connect(_on_autosave_timeout)
	add_child(_autosave_timer)


func _on_autosave_timeout() -> void:
	autosave_due.emit()
	_autosave()


## Seconds between interval autosaves.
func get_autosave_interval() -> float:
	return _autosave_timer.wait_time if is_instance_valid(_autosave_timer) else 0.0


## Retunes the interval and restarts the countdown. DEV/TEST ONLY -- the smoke
## harnesses shorten it so they can watch a tick without waiting 45 s. Passing 0
## or less stops interval autosaving altogether.
func set_autosave_interval(seconds: float) -> void:
	if not is_instance_valid(_autosave_timer):
		return
	if seconds <= 0.0:
		_autosave_timer.stop()
		return
	_autosave_timer.wait_time = seconds
	_autosave_timer.start()


## Runs the interval autosave right now, without waiting for the timer. This is
## what the manual "Save" button ends up calling.
func request_autosave() -> void:
	_on_autosave_timeout()


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

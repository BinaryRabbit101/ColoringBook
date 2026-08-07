extends SceneTree
## Dev tool — the `pack build` CLI (docs/DLC_SERVER.md §10.2).
##
## Walks one or more authored books under `res://resources/books/<book>/`,
## resolves every [PageDef] to its shipped artifacts and writes a §7.2 pack
## DIRECTORY that `php artisan pack:publish` (server/) can import verbatim:
##
##   <out>/manifest.json                              manifest_version 1
##   <out>/books/<book_uid>/book.json                 the manifest's books[] entry
##   <out>/books/<book_uid>/page_01.png               the DISPLAY image
##   <out>/books/<book_uid>/page_01_mask.png          ONLY when the page has a mask
##   <out>/books/<book_uid>/page_01_idmap.png
##   <out>/books/<book_uid>/page_01_regions.json
##
## Usage:
##   <godot_exe> --headless --path <project> --script tools/build_pack.gd -- \
##       --book resources/books/coyote --book-uid coyote-2026 \
##       --slug coyote-book --title "Coyote" --version 1 \
##       --out "C:/.../build/packs/coyote-book"
##
## [b]Why GDScript and not PHP.[/b] The input is a Godot resource graph — a
## `book.tres` holding an ordered `Array[PageDef]`, each page naming its art by
## `res://` path. Only the engine reads that authoritatively (import remaps,
## `.res` variants in exported builds, `PageDef.validate()`), and the artist's
## files live on the dev box beside the mapping pipeline that produced them
## (§10.1). Re-implementing `.tres` parsing server-side would be a second,
## silently-diverging definition of what a book is. This is deliberately the
## same shape as `tools/generate_region_map.gd`: a headless dev-box script that
## reads the project and writes build artifacts, referenced by no game scene.
##
## [b]What it does NOT do.[/b] It writes a directory; it does not zip and does
## not POST. `pack:publish` (and, later, `POST /admin/packs/{slug}/versions`)
## owns the zip, the digests of the shipped archive and the version number —
## §7.3 makes the SERVER assign `pack_version`, so `--version` here is advisory
## and exists only so the manifest is complete and self-describing.
##
## [b]BL-37: it builds STICKER packs too.[/b] `--sticker-set <dir>` walks a
## [StickerSetDef] instead of a book and writes the §7.2 sticker layout:
##
##   <out>/manifest.json                              kind "sticker_set"
##   <out>/stickers/<set_uid>/sticker_set.json        the manifest's sticker_sets[] entry
##   <out>/stickers/<set_uid>/<sticker_id>.png
##
## Files are named after the stable `sticker_id`, never the index: an index moves
## when a set is reordered, and a delta update (BL-26) would then re-download
## every file after the one that moved. A pack is one kind or the other —
## `--book` and `--sticker-set` in the same run is a usage error, because the
## manifest's `kind` is one value and the client branches on it.
##
## Flags:
##   --book <dir>            a book directory (res:// or project-relative).
##                           Repeatable: a pack may hold several books.
##   --sticker-set <dir>     a sticker-set directory (BL-37). Repeatable.
##                           Mutually exclusive with --book.
##   --book-uid <uid>        the AUTHORED, forever-stable uid (§6.1) for the
##                           most recent --book. Optional when the BookDef
##                           carries a `book_uid` property; required otherwise.
##   --out <dir>             output pack directory (absolute OS path).
##   --slug <slug>           pack_slug: lowercase letters, digits, hyphens.
##   --title <text>          pack title as the shop shows it.
##   --blurb <text>          optional one-line description.
##   --version <n>           advisory pack_version (default 1).
##   --min-client-version <v>  default: this project's application/config/version.
##   --cover <path>          pack cover art; default is book 1's cover.
##   --free / --paid         writes `is_free` into the manifest. `pack:publish`
##                           --free/--paid overrides it either way.
##
## Exit codes: 0 built, 1 bad art / unreadable input, 2 bad usage.

## Manifest schema this tool writes (server: coloringbook.packs.manifest_version).
const MANIFEST_VERSION := 1
## Where a bare `--book coyote` is looked up.
const BOOKS_ROOT := "res://resources/books"
## ...and where a bare `--sticker-set starter` is (BL-37).
const STICKERS_ROOT := "res://resources/stickers"
## Manifest `kind` values (server: `Pack::KINDS`). Absent means `book`, which is
## every manifest written before BL-37.
const KIND_BOOK := "book"
const KIND_STICKER_SET := "sticker_set"
## Artifact suffixes appended to `page_NN`, by manifest role.
const ARTIFACT_SUFFIX := {
	"display": ".png",
	"mask": "_mask.png",
	"idmap": "_idmap.png",
	"regions": "_regions.json",
}

# ------------------------------------------------------------ CLI state ------
var _book_dirs: Array[String] = []
var _book_uids: Array[String] = []
var _sticker_set_dirs: Array[String] = []
var _out_dir := ""
var _slug := ""
var _title := ""
var _blurb := ""
var _pack_version := 1
var _min_client_version := ""
var _cover_override := ""
var _is_free: Variant = null

# ------------------------------------------------------- accumulated -------
## Pack-relative path -> {"bytes": int, "sha256": String}. The §7.2 delta map.
var _files: Dictionary = {}
var _errors: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		_usage()
		quit(2)
		return

	if not _parse_flags(args):
		quit(2)
		return

	quit(_build())


func _usage() -> void:
	printerr("Usage: --script tools/build_pack.gd -- --book <dir> [--book-uid <uid>] \\")
	printerr("           --out <dir> --slug <slug> --title <text> [--version <n>] [--free|--paid]")


# ===================================================================== CLI ====

func _parse_flags(args: PackedStringArray) -> bool:
	var i := 0
	while i < args.size():
		var flag := args[i]
		var needs_value := flag not in ["--free", "--paid"]
		if needs_value and i + 1 >= args.size():
			printerr("Missing value for %s." % flag)
			return false
		var value := args[i + 1] if needs_value else ""
		match flag:
			"--book":
				_book_dirs.append(_normalise_book_dir(value))
				_book_uids.append("")
			"--book-uid":
				if _book_uids.is_empty():
					printerr("--book-uid must follow a --book.")
					return false
				_book_uids[_book_uids.size() - 1] = value.strip_edges()
			"--sticker-set":
				_sticker_set_dirs.append(_normalise_dir(value, STICKERS_ROOT))
			"--out":
				_out_dir = value.replace("\\", "/").rstrip("/")
			"--slug":
				_slug = value.strip_edges().to_lower()
			"--title":
				_title = value.strip_edges()
			"--blurb":
				_blurb = value.strip_edges()
			"--version":
				_pack_version = int(value)
			"--min-client-version":
				_min_client_version = value.strip_edges()
			"--cover":
				_cover_override = value.strip_edges()
			"--free":
				_is_free = true
			"--paid":
				_is_free = false
			_:
				printerr("Unknown flag '%s'." % flag)
				_usage()
				return false
		i += 2 if needs_value else 1

	if _book_dirs.is_empty() and _sticker_set_dirs.is_empty():
		printerr("At least one --book or --sticker-set is required.")
		return false
	if not _book_dirs.is_empty() and not _sticker_set_dirs.is_empty():
		# A pack's `kind` is ONE value and the client branches on it (BL-37): a
		# bundle that is half books and half stickers has no honest manifest.
		printerr("--book and --sticker-set cannot be mixed: a pack is one kind of content.")
		return false
	if _out_dir == "":
		printerr("--out is required.")
		return false
	if _slug == "":
		printerr("--slug is required.")
		return false
	if not _is_slug(_slug):
		printerr("--slug '%s' is not a pack slug (lowercase letters, digits, hyphens)." % _slug)
		return false
	if _title == "":
		printerr("--title is required.")
		return false
	if _pack_version < 1:
		printerr("--version must be a positive integer.")
		return false
	if _min_client_version == "":
		_min_client_version = str(ProjectSettings.get_setting("application/config/version", "0.1.0"))
	return true


## `coyote`, `resources/books/coyote` and `res://resources/books/coyote` all
## name the same book — the artist types the short one.
func _normalise_book_dir(raw: String) -> String:
	return _normalise_dir(raw, BOOKS_ROOT)


func _normalise_dir(raw: String, root: String) -> String:
	var value := raw.strip_edges().replace("\\", "/").rstrip("/")
	if value.begins_with("res://"):
		return value
	if value.find("/") == -1:
		return root.path_join(value)
	return "res://" + value.lstrip("/")


func _is_slug(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^[a-z0-9]+(-[a-z0-9]+)*$")
	return regex.search(value) != null


# =================================================================== build ====

func _build() -> int:
	print("== pack build ==")
	print("  slug            : %s" % _slug)
	print("  title           : %s" % _title)
	print("  pack_version    : %d (advisory — the server assigns the real one, §7.3)" % _pack_version)
	print("  min_client_ver  : %s" % _min_client_version)
	print("  out             : %s" % _out_dir)

	if not _prepare_out_dir():
		return 1

	var sticker_pack := not _sticker_set_dirs.is_empty()
	var books: Array[Dictionary] = []
	var sticker_sets: Array[Dictionary] = []
	if sticker_pack:
		for dir in _sticker_set_dirs:
			var set_entry := _build_sticker_set(dir)
			if set_entry.is_empty():
				return _fail()
			sticker_sets.append(set_entry)
	else:
		for i in _book_dirs.size():
			var entry := _build_book(_book_dirs[i], _book_uids[i])
			if entry.is_empty():
				return _fail()
			books.append(entry)

	var cover := _resolve_cover(sticker_sets if sticker_pack else books)
	if _errors.size() > 0:
		return _fail()

	var manifest := {
		"manifest_version": MANIFEST_VERSION,
		# BL-37: written out always, even for a book pack, so a published
		# manifest says what it carries rather than relying on an absent key.
		"kind": KIND_STICKER_SET if sticker_pack else KIND_BOOK,
		"pack_slug": _slug,
		"pack_version": _pack_version,
		"title": _title,
	}
	if _blurb != "":
		manifest["blurb"] = _blurb
	if cover != "":
		manifest["cover"] = cover
	manifest["min_client_version"] = _min_client_version
	if _is_free != null:
		manifest["is_free"] = _is_free
	if sticker_pack:
		manifest["sticker_sets"] = sticker_sets
	else:
		manifest["books"] = books

	# Sorted so two builds of the same art produce byte-identical manifests.
	var paths := _files.keys()
	paths.sort()
	var files := {}
	for path: String in paths:
		files[path] = _files[path]
	manifest["files"] = files

	var manifest_path := _out_dir.path_join("manifest.json")
	if not _write_text(manifest_path, JSON.stringify(manifest, "    ", false) + "\n"):
		return _fail()

	_report(sticker_sets if sticker_pack else books, manifest_path)
	return 0


# ======================================================= sticker sets (BL-37) ==

## One [StickerSetDef] -> the pack's `sticker_sets[]` entry, with every image
## copied in. Deliberately the same shape as [method _build_book]: read the
## authored resource, validate it here (where the artist is) and write the §7.2
## layout plus the self-describing per-set JSON.
func _build_sticker_set(set_dir: String) -> Dictionary:
	var set_def: StickerSetDef = StickerSetDef.load_from_directory(set_dir)
	if set_def == null:
		_errors.append("No sticker_set.tres/.res in '%s'." % set_dir)
		return {}

	for problem in set_def.validate():
		_errors.append("%s: %s" % [set_dir, problem])
	if _errors.size() > 0:
		return {}

	var uid := set_def.set_uid.strip_edges()
	if uid == "":
		_errors.append("%s: no set_uid. It is what every saved sticker placement names." % set_dir)
		return {}

	var set_root := "stickers/" + uid
	if DirAccess.make_dir_recursive_absolute(_out_dir.path_join(set_root)) != OK:
		_errors.append("Could not create '%s'." % _out_dir.path_join(set_root))
		return {}

	var stickers: Array[Dictionary] = []
	for index in set_def.sticker_count():
		var sticker := set_def.get_sticker(index)
		# Named after the STABLE id, never the index: reordering a set must not
		# make a delta update re-fetch every file after the one that moved.
		var target := "%s/%s.png" % [set_root, sticker.sticker_id]
		if not _copy(sticker.image_path, target):
			return {}
		stickers.append({
			"sticker_index": index,
			"sticker_id": sticker.sticker_id,
			"title": sticker.display_name,
			"image": target,
		})

	var entry := {
		"set_uid": uid,
		"title": set_def.display_name,
		"sort_order": set_def.sort_order,
	}
	if not stickers.is_empty():
		entry["cover"] = String(stickers[0]["image"])
	entry["stickers"] = stickers

	# sticker_set.json IS the manifest's sticker_sets[] entry (§7.2), so the
	# installed tree is self-describing and StickerSetDef.discover() never has
	# to open the manifest.
	var set_json := set_root + "/sticker_set.json"
	if not _write_text(_out_dir.path_join(set_json), JSON.stringify(entry, "    ", false) + "\n"):
		return {}
	_record(set_json)

	return entry


func _prepare_out_dir() -> int:
	if DirAccess.dir_exists_absolute(_out_dir):
		if FileAccess.file_exists(_out_dir.path_join("manifest.json")):
			# A pack directory we built before: replace it wholesale, so a page
			# deleted from the book cannot survive as a stale file on disk.
			print("  (replacing the existing pack directory)")
			_remove_tree(_out_dir)
		elif not DirAccess.get_files_at(_out_dir).is_empty() \
				or not DirAccess.get_directories_at(_out_dir).is_empty():
			_errors.append("--out '%s' is not empty and is not a pack directory; refusing to write into it." % _out_dir)
			return false
	if DirAccess.make_dir_recursive_absolute(_out_dir) != OK:
		_errors.append("Could not create --out '%s'." % _out_dir)
		return false
	return true


func _build_book(book_dir: String, uid_override: String) -> Dictionary:
	var book: BookDef = BookDef.load_from_directory(book_dir)
	if book == null:
		_errors.append("No book.tres/book.res in '%s'." % book_dir)
		return {}

	for problem in book.validate():
		_errors.append("%s: %s" % [book_dir, problem])
	if _errors.size() > 0:
		return {}

	var uid := uid_override
	if uid == "":
		# WP7 adds `book_uid` to BookDef; until then --book-uid supplies it.
		# Either way the uid is AUTHORED and stable forever (§6.1) — never
		# derived from the directory name.
		var authored: Variant = book.get("book_uid")
		if typeof(authored) == TYPE_STRING:
			uid = String(authored).strip_edges()
	if uid == "":
		_errors.append("%s: no book_uid. Pass --book-uid after --book, or author one on the BookDef." % book_dir)
		return {}

	var book_root := "books/" + uid
	if DirAccess.make_dir_recursive_absolute(_out_dir.path_join(book_root)) != OK:
		_errors.append("Could not create '%s'." % _out_dir.path_join(book_root))
		return {}

	var pages: Array[Dictionary] = []
	for index in book.page_count():
		var page := _build_page(book.get_page(index), index, book_root)
		if page.is_empty():
			return {}
		pages.append(page)

	var entry := {
		"book_uid": uid,
		"title": book.display_name,
	}

	var cover := _copy_book_cover(book, book_root, pages)
	if cover != "":
		entry["cover"] = cover
	entry["pages"] = pages

	# book.json IS the manifest's books[] entry (§7.2), so the installed tree is
	# self-describing. Shipping it (rather than letting the server synthesise
	# one) means the bytes a device installs are the bytes this box built.
	var book_json := book_root + "/book.json"
	if not _write_text(_out_dir.path_join(book_json), JSON.stringify(entry, "    ", false) + "\n"):
		return {}
	_record(book_json)

	return entry


func _build_page(page: PageDef, index: int, book_root: String) -> Dictionary:
	var label := "page %d (%s)" % [index + 1, page.display_name]
	var stem := "page_%02d" % (index + 1)

	var display := _copy_artifact(page.display_image_path, book_root, stem, "display", label)
	var idmap := _copy_artifact(page.id_map_path, book_root, stem, "idmap", label)
	var regions := _copy_artifact(page.regions_json_path, book_root, stem, "regions", label)
	if display == "" or idmap == "" or regions == "":
		return {}

	# Masks are OPTIONAL per page (§7.2, 2026-08-06): a page with no separate
	# masking image simply has no mask file in the pack.
	var mask := ""
	if page.has_mask():
		mask = _copy_artifact(page.mask_image_path, book_root, stem, "mask", label)
		if mask == "":
			return {}

	var size := _image_size(page.display_image_path)
	if size == Vector2i.ZERO:
		_errors.append("%s: could not read the display image '%s'." % [label, page.display_image_path])
		return {}

	# The three §10.1 checks that are cheap here and expensive to debug on the
	# server: the ID map must be pixel-for-pixel the display art, and the
	# regions JSON must have been produced from the same run.
	var idmap_size := _image_size(page.id_map_path)
	if idmap_size != size:
		_errors.append("%s: the ID map is %dx%d but the display image is %dx%d — re-run generate_region_map.gd."
			% [label, idmap_size.x, idmap_size.y, size.x, size.y])
		return {}

	var region_count := _region_count(page.regions_json_path, size, label)
	if region_count < 1:
		return {}

	var entry := {
		"page_index": index,
		"title": page.display_name,
		"display": display,
	}
	if mask != "":
		entry["mask"] = mask
	entry["idmap"] = idmap
	entry["regions"] = regions
	entry["image_size"] = [size.x, size.y]
	entry["region_count"] = region_count
	return entry


## A book's cover: the authored `cover_image_path` when there is one, else
## page 1's display art, which is already in the pack and is not copied twice.
func _copy_book_cover(book: BookDef, book_root: String, pages: Array[Dictionary]) -> String:
	if book.cover_image_path == "":
		return String(pages[0]["display"]) if not pages.is_empty() else ""
	var first := book.get_page(0)
	if first != null and book.cover_image_path == first.display_image_path:
		return String(pages[0]["display"])
	var target := book_root + "/cover." + book.cover_image_path.get_extension()
	return target if _copy(book.cover_image_path, target) else ""


func _resolve_cover(books: Array[Dictionary]) -> String:
	if _cover_override != "":
		var source := _cover_override
		if not source.begins_with("res://") and not source.contains(":"):
			source = "res://" + source.lstrip("/")
		var target := "cover." + source.get_extension()
		if not _copy(source, target):
			return ""
		return target
	# No pack cover of its own: reuse book 1's, which is already shipped. The
	# server is happy for one blob to wear two `assets.kind` roles.
	for book in books:
		if book.has("cover"):
			return String(book["cover"])
	return ""


func _copy_artifact(source: String, book_root: String, stem: String, role: String, label: String) -> String:
	if source == "":
		_errors.append("%s: no %s path." % [label, role])
		return ""
	var target := "%s/%s%s" % [book_root, stem, ARTIFACT_SUFFIX[role]]
	return target if _copy(source, target) else ""


# ================================================================ plumbing ====

## Copies a `res://` file into the pack and records its digest. The SOURCE png
## is copied, never the imported `.ctex`: a pack is plain data (§7.1) and the
## installing client imports nothing.
func _copy(source: String, target: String) -> bool:
	var from := ProjectSettings.globalize_path(source)
	if not FileAccess.file_exists(from):
		_errors.append("'%s' does not exist on disk." % source)
		return false
	var to := _out_dir.path_join(target)
	if DirAccess.make_dir_recursive_absolute(to.get_base_dir()) != OK:
		_errors.append("Could not create '%s'." % to.get_base_dir())
		return false
	var error := DirAccess.copy_absolute(from, to)
	if error != OK:
		_errors.append("Could not copy '%s' -> '%s' (error %d)." % [source, to, error])
		return false
	return _record(target)


func _record(target: String) -> bool:
	var absolute := _out_dir.path_join(target)
	var file := FileAccess.open(absolute, FileAccess.READ)
	if file == null:
		_errors.append("Could not read back '%s'." % absolute)
		return false
	var bytes := file.get_length()
	file.close()
	_files[target] = {
		"bytes": int(bytes),
		"sha256": FileAccess.get_sha256(absolute),
	}
	return true


func _write_text(absolute: String, contents: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(absolute.get_base_dir()) != OK:
		_errors.append("Could not create '%s'." % absolute.get_base_dir())
		return false
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		_errors.append("Could not write '%s'." % absolute)
		return false
	file.store_string(contents)
	file.close()
	return true


func _image_size(res_path: String) -> Vector2i:
	var image := Image.load_from_file(ProjectSettings.globalize_path(res_path))
	return Vector2i.ZERO if image == null else Vector2i(image.get_width(), image.get_height())


## `regions` length from the schema-v1 JSON, with the same `image_size`
## agreement the server checks (§10.1). Returns 0 on any problem.
func _region_count(res_path: String, size: Vector2i, label: String) -> int:
	var text := FileAccess.get_file_as_string(ProjectSettings.globalize_path(res_path))
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_errors.append("%s: '%s' is not a JSON object." % [label, res_path])
		return 0
	var data: Dictionary = parsed
	if int(data.get("version", 0)) != 1:
		_errors.append("%s: regions JSON is schema version %s, expected 1." % [label, data.get("version", "?")])
		return 0
	var json_size: Array = data.get("image_size", [])
	if json_size.size() != 2 or int(json_size[0]) != size.x or int(json_size[1]) != size.y:
		_errors.append("%s: regions JSON image_size %s does not match the display image %dx%d."
			% [label, str(json_size), size.x, size.y])
		return 0
	var regions: Array = data.get("regions", [])
	if regions.is_empty():
		_errors.append("%s: regions JSON has no regions." % label)
		return 0
	return regions.size()


func _remove_tree(directory: String) -> void:
	for name in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(name))
	for name in DirAccess.get_directories_at(directory):
		_remove_tree(directory.path_join(name))
	DirAccess.remove_absolute(directory)


func _fail() -> int:
	printerr("")
	printerr("pack build FAILED — %d problem(s):" % _errors.size())
	for problem in _errors:
		printerr("  - %s" % problem)
	return 1


func _report(books: Array[Dictionary], manifest_path: String) -> void:
	var total := 0
	for meta: Dictionary in _files.values():
		total += int(meta["bytes"])
	print("")
	for book in books:
		if book.has("set_uid"):
			var stickers: Array = book["stickers"]
			print("  sticker set %s \"%s\": %d sticker(s)"
				% [book["set_uid"], book["title"], stickers.size()])
			for sticker: Dictionary in stickers:
				print("    %d  %-14s %s" % [sticker["sticker_index"], sticker["sticker_id"], sticker["image"]])
			continue
		var pages: Array = book["pages"]
		var masked := 0
		for page: Dictionary in pages:
			if page.has("mask"):
				masked += 1
		print("  book %s \"%s\": %d page(s), %d with a mask" % [book["book_uid"], book["title"], pages.size(), masked])
		for page: Dictionary in pages:
			print("    page_index %d  %dx%d  %d region(s)  %s"
				% [page["page_index"], page["image_size"][0], page["image_size"][1],
					page["region_count"], page["display"]])
	print("")
	print("  %d file(s), %s payload" % [_files.size(), String.humanize_size(total)])
	print("  wrote %s" % manifest_path)
	print("")
	print("  Next: php artisan pack:publish \"%s\"%s" % [_out_dir, " --free" if _is_free == true else ""])

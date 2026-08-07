extends Control
## Automated verification for WP7 -- the client half of DLC (DLC_SERVER.md 6.1,
## 7.2, 8.1) with no server anywhere in sight.
##
## Run WINDOWED (it paints into a SubViewport and reads it back, which renders
## nothing under --headless / the dummy rasteriser):
##
##   <godot_exe> --path <project> res://scenes/dev/dlc_smoke.tscn
##
## Extra user args (after a bare `--`):
##   --stay   leave the app running afterwards, WITHOUT deleting the scratch pack
##            or the scratch save (so the seeded pack can be inspected by hand)
##
## [b]The pack is SYNTHESISED at runtime.[/b] There is no fixture directory: the
## harness copies the built-in books' own artifacts into the 7.2 layout under
## [constant TEST_DLC_ROOT] and writes the [code]book.json[/code] itself. That is
## deliberate -- the pack a real server ships is byte-identical PNGs plus a JSON
## file, so building it here from the same PNGs is what makes "the runtime path
## behaves EXACTLY like the res:// path" a comparison rather than a hope. The
## seeded book carries a DIFFERENT uid from the built-in ones so de-duplication
## cannot hide it, and a second pack claims [code]coyote-2026[/code] on purpose so
## de-duplication can be proved as well.
##
## [b]Everything this run writes is isolated and wiped at both ends[/b]: the packs
## live under [constant TEST_ROOT], persistence is pointed at
## [constant TEST_SAVE_ROOT], and the one check that uses the REAL
## [constant BookDef.DLC_ROOT] removes its pack again immediately -- a pack left
## behind would put a third book on the shelf and break every other harness's
## "there are exactly 2 books" assertion.
##
## Checks, in order:
##   a  a synthesised pack is discovered from user://dlc/*/books/*/book.json,
##      built-in books still come first, a half-downloaded `.incoming` pack is
##      ignored, a pack sharing a book_uid with a built-in book is DE-DUPED with
##      the built-in winning, and discover() can be re-run after an install
##   b  the runtime BookDef/PageDef shape: is_runtime, absolute user:// paths that
##      never went through the importer, page_index ordering, the optional mask,
##      the cover fallback, and the malformed-JSON rejections
##   c  PageLoader decodes a pack page on a WorkerThreadPool task while the main
##      thread keeps running frames, and the resulting textures go into
##      PageView.load_page_textures() -- after which the ID map, the region data,
##      the hit-testing and the SHADER CLIP are identical to the res:// page the
##      pack was built from, pixel for pixel
##   d  the masked page of the pack (BL-12's mask layer, loaded from user://)
##   e  save schema v2: keyed by book_uid, and a v1 file migrates -- keys rekeyed,
##      paint directories renamed, nothing lost, unknown keys passed through,
##      re-runnable, and the v1 file left where it was
##   f  a DLC book and the built-in book that share a uid share one save entry
##
## Exit code is 0 only if every check passes.

const TEST_BOOK_PATH := "res://resources/books/test_book/book.tres"
const COYOTE_BOOK_PATH := "res://resources/books/coyote/book.tres"
const TEST_BOOK_UID := "test-book-2026"
const COYOTE_UID := "coyote-2026"

## Everything this run writes.
const TEST_ROOT := "user://dlc_smoke"
## The scratch DLC root the bulk of the run scans, so a crashed run cannot leave a
## book on the real shelf.
const TEST_DLC_ROOT := "user://dlc_smoke/dlc"
## Scratch save root -- a restored paint layer would break the blank-page checks.
const TEST_SAVE_ROOT := "user://dlc_smoke/state"

## The pack the run is mostly about, and the book inside it.
const PACK_SLUG := "dlc-smoke-pack"
const PACK_BOOK_UID := "dlc-smoke-2026"
## A pack that deliberately claims the built-in coyote book's uid.
const DUPE_PACK_SLUG := "dlc-smoke-dupe"
## A pack installed AFTER the first discovery, to prove a rescan sees it.
const LATE_PACK_SLUG := "dlc-smoke-late"
const LATE_BOOK_UID := "dlc-late-2026"
## A download in flight: WP10 unpacks into `<slug>.incoming/` and only then swaps.
const INCOMING_PACK_SLUG := "dlc-smoke-pack.incoming"

## Region of test_book page 1 the clip comparison locks, and a point in the region
## the stroke deliberately wanders into (the same pair paint_smoke uses).
const CLIP_REGION := 4
const CLIP_START := Vector2(700.5, 250.5)
const CLIP_END := Vector2(1010.5, 250.5)
const CLIP_OUTSIDE_REGION := 1
## Test brush diameter in page pixels.
const BRUSH_DIAMETER := 56.0
## Every Nth pixel is compared when two ID maps are checked point by point.
const ID_SAMPLE_STRIDE := 97
## Milliseconds a PREFETCHED take() may block the main thread. The decode itself is
## tens of ms for a 2048 page; if the prefetch works, take() only has to pick the
## result up.
const PREFETCH_TAKE_BUDGET_MS := 100.0

@onready var _page_view: PageView = $PageView

var _checks := 0
var _failures := 0

var _test_book: BookDef
var _coyote_book: BookDef
## The book discovered out of the synthesised pack.
var _pack_book: BookDef
## Timings printed in the summary.
var _worker_frames := 0
var _prefetched_take_ms := 0.0
var _cold_take_ms := 0.0


func _ready() -> void:
	get_window().size = Vector2i(1280, 820)
	# The paint readback stalls on the presentation queue under FIFO v-sync; the
	# run is much shorter on mailbox and this harness measures nothing that cares.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_MAILBOX)
	await get_tree().process_frame
	await _run()


func _run() -> void:
	print("=== WP7 DLC smoke test ===")
	_delete_recursive(TEST_ROOT)
	_remove_real_pack()
	GameState.set_save_root(TEST_SAVE_ROOT)
	print("   save root: %s" % ProjectSettings.globalize_path(GameState.get_save_path()))
	print("   pack root: %s" % ProjectSettings.globalize_path(TEST_DLC_ROOT))

	_test_book = load(TEST_BOOK_PATH) as BookDef
	_coyote_book = load(COYOTE_BOOK_PATH) as BookDef
	if _test_book == null or _coyote_book == null:
		_expect(false, "the two built-in books load")
		_finish(1)
		return
	_expect(_test_book.book_uid == TEST_BOOK_UID and _coyote_book.book_uid == COYOTE_UID,
		"the built-in books carry their authored uids ('%s', '%s')"
		% [_test_book.book_uid, _coyote_book.book_uid])

	_seed_packs()
	_check_discovery()
	_check_runtime_definitions()
	await _check_runtime_page_load()
	await _check_masked_runtime_page()
	_check_save_migration()
	_check_shared_uid()

	print("\n   worker decode covered %d main-thread frames; take() cost %.1f ms prefetched"
		% [_worker_frames, _prefetched_take_ms]
		+ " / %.1f ms cold" % _cold_take_ms)
	print("\n=== %d/%d checks passed ===" % [_checks - _failures, _checks])
	if "--stay" in OS.get_cmdline_user_args():
		print("[dev] --stay given; the scratch pack at %s was kept."
			% ProjectSettings.globalize_path(TEST_DLC_ROOT))
		return
	_cleanup()
	_finish(0 if _failures == 0 else 1)


func _cleanup() -> void:
	# reload=false: do not read the player's real save just to throw it away.
	GameState.set_save_root("", false)
	_delete_recursive(TEST_ROOT)
	_remove_real_pack()
	print("   cleaned up %s" % ProjectSettings.globalize_path(TEST_ROOT))


func _finish(code: int) -> void:
	# Never tear the engine down on top of a queued GPU readback (AsyncReadback).
	await AsyncReadback.drain(get_tree())
	print("exit code: %d" % code)
	get_tree().quit(code)


# ================================================== the synthesised DLC packs ==
# DLC_SERVER.md 7.2. A pack is a directory of plain data:
#
#   <pack_slug>/manifest.json
#   <pack_slug>/books/<book>/book.json
#   <pack_slug>/books/<book>/page_NN.png            display art
#   <pack_slug>/books/<book>/page_NN_mask.png       only when the page has a mask
#   <pack_slug>/books/<book>/page_NN_idmap.png
#   <pack_slug>/books/<book>/page_NN_regions.json
#
# The client reads book.json ONLY -- the manifest is the server's and the
# installer's business -- but one is written here anyway so the seeded tree is a
# faithful copy of what WP9's pack build produces.

func _seed_packs() -> void:
	print("\n-- seeding synthetic packs under %s --" % TEST_DLC_ROOT)
	var test_page := _test_book.get_page(0)
	var coyote_page := _coyote_book.get_page(0)

	# The main pack: two pages, listed OUT OF ORDER on purpose, one with a mask and
	# one without (the mask is optional per page, DLC_SERVER.md 7.2).
	var pages: Array = [
		_pack_page(coyote_page, 2, 1, "Coyote (from a pack)"),
		_pack_page(test_page, 1, 0, "Shape Sampler (from a pack)"),
	]
	_write_pack(TEST_DLC_ROOT, PACK_SLUG, PACK_BOOK_UID, "DLC Smoke Book", pages,
		[test_page, coyote_page], [1, 2])

	# A pack claiming the built-in coyote book's uid. Its FILES are the test book's
	# -- what matters is the uid it claims, and using the small page keeps the run
	# quick.
	_write_pack(TEST_DLC_ROOT, DUPE_PACK_SLUG, COYOTE_UID, "Coyote (from a pack)",
		[_pack_page(test_page, 1, 0, "Coyote (pack copy)")], [test_page], [1])

	# A download that has not finished yet. Same valid contents; the DIRECTORY NAME
	# is what must keep it off the shelf.
	_write_pack(TEST_DLC_ROOT, INCOMING_PACK_SLUG, "dlc-incoming-2026", "Half A Book",
		[_pack_page(test_page, 1, 0, "Not finished downloading")], [test_page], [1])

	print("   seeded %s, %s and %s" % [PACK_SLUG, DUPE_PACK_SLUG, INCOMING_PACK_SLUG])


## One [code]pages[][/code] entry, plus the file copies it needs, for a page built
## from [param source]. [param number] names the files inside the pack and
## [param index] is the authored [code]page_index[/code].
func _pack_page(source: PageDef, number: int, index: int, title: String) -> Dictionary:
	var entry := {
		"page_index": index,
		"title": title,
		"display": "books/%s/page_%02d.png" % ["BOOK", number],
		"idmap": "books/%s/page_%02d_idmap.png" % ["BOOK", number],
		"regions": "books/%s/page_%02d_regions.json" % ["BOOK", number],
	}
	if source.has_mask():
		entry["mask"] = "books/%s/page_%02d_mask.png" % ["BOOK", number]
	entry["_source"] = source
	entry["_number"] = number
	return entry


## Writes one pack directory: the book.json, a manifest, and a copy of every
## artifact each page names.
func _write_pack(
	dlc_root: String,
	pack_slug: String,
	book_uid: String,
	title: String,
	pages: Array,
	_sources: Array,
	_numbers: Array
) -> void:
	var pack_root := dlc_root.path_join(pack_slug)
	var book_dir := pack_root.path_join("books").path_join(book_uid)
	DirAccess.make_dir_recursive_absolute(book_dir)

	var json_pages: Array = []
	for page: Dictionary in pages:
		var source: PageDef = page["_source"]
		var number: int = page["_number"]
		_copy_file(source.display_image_path, book_dir.path_join("page_%02d.png" % number))
		_copy_file(source.id_map_path, book_dir.path_join("page_%02d_idmap.png" % number))
		_copy_file(source.regions_json_path, book_dir.path_join("page_%02d_regions.json" % number))
		if source.has_mask():
			_copy_file(source.mask_image_path, book_dir.path_join("page_%02d_mask.png" % number))
		var entry := page.duplicate()
		entry.erase("_source")
		entry.erase("_number")
		for key in ["display", "idmap", "regions", "mask"]:
			if entry.has(key):
				entry[key] = String(entry[key]).replace("BOOK", book_uid)
		json_pages.append(entry)

	# The cover a real pack authors is its FIRST page's art, which is the lowest
	# page_index -- not necessarily the first entry in the array.
	var cover_number: int = int(pages[0]["_number"])
	var lowest := 1 << 30
	for page: Dictionary in pages:
		if int(page["page_index"]) < lowest:
			lowest = int(page["page_index"])
			cover_number = int(page["_number"])
	var book_json := {
		"book_uid": book_uid,
		"title": title,
		"cover": "books/%s/page_%02d.png" % [book_uid, cover_number],
		"pages": json_pages,
	}
	_write_text(book_dir.path_join(BookDef.BOOK_JSON_NAME), JSON.stringify(book_json, "\t"))
	# Written for fidelity only: the client never opens it (see the class doc).
	_write_text(pack_root.path_join("manifest.json"), JSON.stringify({
		"manifest_version": 1,
		"pack_slug": pack_slug,
		"pack_version": 1,
		"title": title,
		"books": [book_json],
	}, "\t"))


# =========================================================== a: discovery ==

func _check_discovery() -> void:
	print("\n-- check a: discovering installed packs --")

	var builtin := BookDef.discover(BookDef.BOOKS_ROOT, "")
	_expect(builtin.size() == 2,
		"discover() with no DLC root is the res:// scan, unchanged (%d books)" % builtin.size())

	var found := BookDef.discover(BookDef.BOOKS_ROOT, TEST_DLC_ROOT)
	_expect(found.size() == 3,
		"discover() found the built-ins plus ONE pack book (%d: %s)"
		% [found.size(), _names(found)])
	_expect(found.size() >= 2 and found[0] == _coyote_book and found[1] == _test_book,
		"...with the built-in books still first, still sorted by directory (%s)" % _names(found))

	_pack_book = _book_with_uid(found, PACK_BOOK_UID)
	_expect(_pack_book != null, "the seeded book '%s' is on the shelf" % PACK_BOOK_UID)
	if _pack_book == null:
		return
	_expect(_pack_book.is_runtime and _pack_book.pack_slug == PACK_SLUG,
		"...marked as runtime, from pack '%s'" % _pack_book.pack_slug)
	_expect(_pack_book.source_dir.begins_with(TEST_DLC_ROOT),
		"...and it remembers where it was installed (%s)" % _pack_book.source_dir)
	_expect(_pack_book.display_name == "DLC Smoke Book",
		"...with the title from book.json ('%s')" % _pack_book.display_name)
	_expect(_pack_book.validate().is_empty(),
		"the runtime book validates (%s)" % [_pack_book.validate()])

	# --- the half-downloaded pack --------------------------------------------
	_expect(_book_with_uid(found, "dlc-incoming-2026") == null,
		"a '%s' pack is NOT discovered -- a download in flight is not a book"
		% INCOMING_PACK_SLUG)

	# --- de-duplication, built-in wins ---------------------------------------
	var coyotes := 0
	for book in found:
		if book.get_uid() == COYOTE_UID:
			coyotes += 1
	_expect(coyotes == 1, "the uid the pack shares with a built-in book appears ONCE (%d)" % coyotes)
	var coyote := _book_with_uid(found, COYOTE_UID)
	_expect(coyote == _coyote_book and not coyote.is_runtime,
		"...and the one that survived is the BUILT-IN book, not the pack's copy")

	# --- installing a pack and rescanning (what WP10 does after a download) ---
	_write_pack(TEST_DLC_ROOT, LATE_PACK_SLUG, LATE_BOOK_UID, "Installed Later",
		[_pack_page(_test_book.get_page(0), 1, 0, "Late page")], [_test_book.get_page(0)], [1])
	var rescanned := BookDef.discover(BookDef.BOOKS_ROOT, TEST_DLC_ROOT)
	_expect(rescanned.size() == 4 and _book_with_uid(rescanned, LATE_BOOK_UID) != null,
		"discover() re-run after an install picks the new pack up (%d: %s)"
		% [rescanned.size(), _names(rescanned)])
	_delete_recursive(TEST_DLC_ROOT.path_join(LATE_PACK_SLUG))
	_expect(BookDef.discover(BookDef.BOOKS_ROOT, TEST_DLC_ROOT).size() == 3,
		"...and re-run after an uninstall drops it again")

	# --- the REAL default root, briefly --------------------------------------
	_write_pack(BookDef.DLC_ROOT, PACK_SLUG, "dlc-default-root-2026", "Default Root",
		[_pack_page(_test_book.get_page(0), 1, 0, "Default root page")],
		[_test_book.get_page(0)], [1])
	var default_scan := BookDef.discover()
	_expect(_book_with_uid(default_scan, "dlc-default-root-2026") != null,
		"discover()'s DEFAULT second root really is %s" % BookDef.DLC_ROOT)
	_remove_real_pack()
	_expect(_book_with_uid(BookDef.discover(), "dlc-default-root-2026") == null,
		"...and the shelf is back to normal once it is uninstalled")


# ================================= b: the runtime BookDef / PageDef shape ==

func _check_runtime_definitions() -> void:
	print("\n-- check b: runtime BookDef / PageDef --")
	if _pack_book == null:
		_expect(false, "there is a runtime book to inspect")
		return

	_expect(_pack_book.page_count() == 2,
		"the book has both pages (%d)" % _pack_book.page_count())
	if _pack_book.page_count() != 2:
		return
	var first := _pack_book.get_page(0)
	var second := _pack_book.get_page(1)
	# book.json listed them 1-then-0; page_index is what decides.
	_expect(first.display_name == "Shape Sampler (from a pack)",
		"pages are ordered by page_index, not by their order in the JSON ('%s')"
		% first.display_name)

	for page in [first, second]:
		_expect(page.is_runtime, "'%s' is marked as a runtime page" % page.display_name)
		_expect(page.display_image_path.begins_with(TEST_DLC_ROOT)
				and page.id_map_path.begins_with(TEST_DLC_ROOT)
				and page.regions_json_path.begins_with(TEST_DLC_ROOT),
			"...with its pack-relative paths resolved to absolute user:// files (%s)"
			% page.display_image_path)
		_expect(page.validate().is_empty(),
			"...and it validates against the files on disk (%s)" % [page.validate()])

	# The whole point of a data pack (DLC_SERVER.md 7.1): nothing here has been
	# through the importer, so nothing here can have been VRAM-compressed.
	_expect(not ResourceLoader.exists(first.id_map_path),
		"a pack's ID map is NOT a resource -- it never touches the importer (%s)" % first.id_map_path)
	_expect(not FileAccess.file_exists(first.id_map_path + ".import"),
		"...and there is no .import file next to it to lose its lossless flags")

	# The optional mask (DLC_SERVER.md 7.2, BL-12).
	_expect(not first.has_mask(),
		"the page whose book.json has no 'mask' key has no mask -- masks are per page")
	_expect(second.has_mask() and second.mask_image_path.begins_with(TEST_DLC_ROOT),
		"...and the page that has one resolved it too (%s)" % second.mask_image_path)
	_expect(second.get_mapping_source_path() == second.mask_image_path,
		"...which is still the page's mapping source, exactly as for a built-in page")

	_expect(_pack_book.get_cover_path() == first.display_image_path,
		"the authored cover resolves to page 1's art (%s)" % _pack_book.get_cover_path())
	_expect(_pack_book.get_cover_texture() != null,
		"...and the cover texture loads from user:// for the shelf")
	# ...and a pack that authors no cover falls back to page 1's display image,
	# exactly as an authored book does.
	var coverless := BookDef.from_json(
		{
			"book_uid": "no-cover-2026",
			"title": "No Cover",
			"pages": [{
				"display": first.display_image_path,
				"idmap": first.id_map_path,
				"regions": first.regions_json_path,
			}],
		},
		TEST_DLC_ROOT, _pack_book.source_dir
	)
	_expect(coverless != null and coverless.get_cover_path() == first.display_image_path,
		"a book.json with no 'cover' falls back to page 1's display image")

	# --- what a broken pack does ---------------------------------------------
	var no_uid := BookDef.from_json({"title": "x", "pages": [{}]}, TEST_DLC_ROOT, TEST_DLC_ROOT)
	_expect(no_uid == null, "a book.json with no book_uid is refused")
	var no_pages := BookDef.from_json({"book_uid": "x-2026", "pages": []}, TEST_DLC_ROOT, TEST_DLC_ROOT)
	_expect(no_pages == null, "a book.json with no pages is refused")
	var missing_file := BookDef.from_json(
		{"book_uid": "x-2026", "pages": [{"display": "nope.png", "idmap": "nope_idmap.png",
			"regions": "nope.json"}]},
		TEST_DLC_ROOT, TEST_DLC_ROOT
	)
	_expect(missing_file == null,
		"a book whose page names a file the pack does not contain is refused whole")


# ============================ c: threaded load, and the res:// comparison ==

func _check_runtime_page_load() -> void:
	print("\n-- check c: WorkerThreadPool decode -> PageView.load_page_textures() --")
	if _pack_book == null:
		_expect(false, "there is a runtime book to load")
		return
	var builtin_page := _test_book.get_page(0)
	var pack_page := _pack_book.get_page(0)

	# --- the reference: the res:// page, loaded the way it always was ---------
	_expect(_page_view.load_page(
			builtin_page.display_image_path, builtin_page.id_map_path,
			builtin_page.regions_json_path),
		"the BUILT-IN page still loads through load_page() (the res:// path is untouched)")
	_page_view.brush_size = BRUSH_DIAMETER
	_page_view.brush_color = Color(0.9, 0.2, 0.15, 1.0)
	var reference_size := _page_view.get_page_size()
	var reference_ids := _page_view.get_region_ids()
	var reference_id_bytes := _rgba(_page_view.get_id_map_image()).get_data()
	var reference_samples := _sample_region_ids(_page_view)
	var reference_counts := await _paint_clip_probe(reference_id_bytes, reference_size)

	# --- the decode, on a worker thread --------------------------------------
	_expect(PageLoader.is_threaded(pack_page), "a pack page is decoded on a worker task")
	_expect(not PageLoader.is_threaded(builtin_page),
		"...and a built-in page is not: the importer already did that work")

	var loader := PageLoader.new()
	_expect(loader.request(pack_page), "request() started the decode")
	_worker_frames = 0
	while loader.is_pending() and not loader.is_ready() and _worker_frames < 600:
		# THE point: the main thread is still running frames while the PNG decodes.
		await get_tree().process_frame
		_worker_frames += 1
	_expect(loader.is_ready(),
		"the decode finished on the worker thread after %d main-thread frames" % _worker_frames)
	var started := Time.get_ticks_usec()
	var bundle := loader.take(pack_page)
	_prefetched_take_ms = float(Time.get_ticks_usec() - started) / 1000.0
	_expect(_prefetched_take_ms < PREFETCH_TAKE_BUDGET_MS,
		"taking a PREFETCHED page cost %.1f ms of main thread (budget %.0f)"
		% [_prefetched_take_ms, PREFETCH_TAKE_BUDGET_MS])
	_expect(String(bundle.get(PageLoader.KEY_ERROR, "-")) == "",
		"the bundle came back without an error ('%s')" % bundle.get(PageLoader.KEY_ERROR, "-"))

	var idmap: Texture2D = bundle.get(PageLoader.KEY_IDMAP)
	_expect(idmap is ImageTexture,
		"the ID map is a runtime ImageTexture (%s)" % (idmap.get_class() if idmap else "null"))
	_expect(idmap != null and not idmap.get_image().is_compressed(),
		"...which CANNOT be VRAM-compressed -- the lossless invariant is structural here")
	_expect(idmap != null and not idmap.get_image().has_mipmaps(), "...and has no mipmaps")
	_expect((bundle.get(PageLoader.KEY_REGIONS, {}) as Dictionary).has("regions"),
		"the regions JSON was parsed on the worker task too")

	# A cold take (no prefetch) still works -- the prefetch is an optimisation.
	var cold := PageLoader.new()
	started = Time.get_ticks_usec()
	var cold_bundle := cold.take(pack_page)
	_cold_take_ms = float(Time.get_ticks_usec() - started) / 1000.0
	_expect(cold_bundle.get(PageLoader.KEY_IDMAP) != null,
		"take() without a prefetch loads the page anyway (%.1f ms, blocking)" % _cold_take_ms)

	# --- into the primitive ---------------------------------------------------
	_expect(_page_view.load_page_textures(
			bundle[PageLoader.KEY_DISPLAY], bundle[PageLoader.KEY_IDMAP],
			bundle[PageLoader.KEY_REGIONS], bundle[PageLoader.KEY_MASK]),
		"load_page_textures() took the decoded textures")
	_expect(_page_view.get_page_size() == reference_size,
		"the pack page is the same size as the page it was built from (%s)"
		% _page_view.get_page_size())
	_expect(_page_view.get_region_ids() == reference_ids,
		"...with the same region ids in the same order (%s)" % [_page_view.get_region_ids()])
	_expect(_rgba(_page_view.get_id_map_image()).get_data() == reference_id_bytes,
		"...and an ID map that is BYTE-IDENTICAL to the imported one")
	_expect(not _page_view.get_id_map_image().is_compressed(),
		"...uncompressed, so region ids are exact")
	_expect(_sample_region_ids(_page_view) == reference_samples,
		"get_region_id_at() answers identically at every sampled pixel (%d samples)"
		% reference_samples.size())

	# --- and the shader clips it the same way --------------------------------
	var runtime_counts := await _paint_clip_probe(reference_id_bytes, reference_size)
	_expect(int(runtime_counts.get(CLIP_REGION, 0)) > 2000,
		"a stroke on the pack page paints inside region %d (%d px)"
		% [CLIP_REGION, int(runtime_counts.get(CLIP_REGION, 0))])
	_expect(int(runtime_counts.get(CLIP_OUTSIDE_REGION, 0)) == 0,
		"...and nothing leaked into region %d, which the stroke crossed (%d px)"
		% [CLIP_OUTSIDE_REGION, int(runtime_counts.get(CLIP_OUTSIDE_REGION, 0))])
	_expect(runtime_counts == reference_counts,
		"the SAME stroke clips to the same pixels on both pages (%s vs %s)"
		% [runtime_counts, reference_counts])
	loader.discard()
	cold.discard()


# ================================================= d: the masked pack page ==

func _check_masked_runtime_page() -> void:
	print("\n-- check d: a pack page that ships a mask (BL-12) --")
	if _pack_book == null or _pack_book.page_count() < 2:
		_expect(false, "there is a masked runtime page to load")
		return
	var page := _pack_book.get_page(1)
	var bundle := PageLoader.load_bundle(page)
	_expect(bundle.get(PageLoader.KEY_MASK) != null, "the mask decoded alongside the page")
	_expect(_page_view.load_page_textures(
			bundle[PageLoader.KEY_DISPLAY], bundle[PageLoader.KEY_IDMAP],
			bundle[PageLoader.KEY_REGIONS], bundle[PageLoader.KEY_MASK]),
		"the masked page loads")
	_expect(_page_view.has_mask_layer(),
		"...and PageView draws the mask layer, exactly as for a built-in page")
	_expect(_page_view.get_mask_texture() != null
			and Vector2i(_page_view.get_mask_texture().get_size()) == _page_view.get_page_size(),
		"...at the page's own resolution (%s)"
		% [Vector2i(_page_view.get_mask_texture().get_size()) if _page_view.get_mask_texture() else Vector2i.ZERO])
	var builtin_regions := (load(_coyote_book.get_page(0).id_map_path) as Texture2D) != null
	_expect(builtin_regions and _page_view.get_region_ids().size()
			== _coyote_book.get_page(0).load_regions_json().get("regions", []).size(),
		"...and it carries the same region count as the book it was packed from (%d)"
		% _page_view.get_region_ids().size())


# ====================================== e: save schema v2 and the migration ==

func _check_save_migration() -> void:
	print("\n-- check e: save schema v2, and migrating a v1 file --")

	_expect(GameState.SAVE_VERSION == 2 and GameState.SAVE_FILE_NAME == "save_v2.json",
		"this build writes schema v%d to %s" % [GameState.SAVE_VERSION, GameState.SAVE_FILE_NAME])
	_expect(GameState.book_key(_test_book) == TEST_BOOK_UID,
		"book_key() is the book's uid (%s)" % GameState.book_key(_test_book))
	_expect(GameState.book_slug(TEST_BOOK_UID).begins_with("test-book-2026_"),
		"book_slug() hashes the uid (%s)" % GameState.book_slug(TEST_BOOK_UID))
	_expect(GameState.book_slug(TEST_BOOK_PATH) == _v1_slug(TEST_BOOK_PATH),
		"...while a path-shaped v1 key still derives its v1 directory (%s)"
		% GameState.book_slug(TEST_BOOK_PATH))
	_expect(GameState.book_slug(TEST_BOOK_UID) != _v1_slug(TEST_BOOK_PATH),
		"...which is a DIFFERENT directory, so the migration really has to move it")

	# --- plant a v1 world -----------------------------------------------------
	var unknown_key := "res://resources/books/some_future_book/book.tres"
	_delete_recursive(TEST_SAVE_ROOT)
	DirAccess.make_dir_recursive_absolute(TEST_SAVE_ROOT)
	var v1 := {
		"version": 1,
		"mode": "adult",
		"books": {
			COYOTE_BOOK_PATH: {
				"slug": _v1_slug(COYOTE_BOOK_PATH),
				"current_page_index": 0,
				# The BL-10 object form.
				"pages": [{"status": "complete", "locked": true}],
			},
			TEST_BOOK_PATH: {
				"slug": _v1_slug(TEST_BOOK_PATH),
				"current_page_index": 1,
				# The pre-BL-10 bare-string form, in the same file.
				"pages": ["in_progress", "complete"],
			},
			unknown_key: {
				"slug": _v1_slug(unknown_key),
				"current_page_index": 0,
				"pages": ["in_progress"],
			},
		},
	}
	_write_text(TEST_SAVE_ROOT.path_join(GameState.LEGACY_SAVE_FILE_NAME),
		JSON.stringify(v1, "\t"))
	var paint_root := TEST_SAVE_ROOT.path_join("paint")
	var coyote_paint := paint_root.path_join(_v1_slug(COYOTE_BOOK_PATH)).path_join("page_01.png")
	var test_paint := paint_root.path_join(_v1_slug(TEST_BOOK_PATH)).path_join("page_02.png")
	var unknown_paint := paint_root.path_join(_v1_slug(unknown_key)).path_join("page_01.png")
	for path in [coyote_paint, test_paint, unknown_paint]:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		_write_text(path, "paint bytes for %s" % path.get_file())

	# --- migrate --------------------------------------------------------------
	_expect(GameState.load_save(), "a v1 save loads")
	_expect(GameState.mode == PaletteDef.MODE_ADULT,
		"the saved mode came across (%s)" % GameState.mode)
	_expect(GameState.has_book_progress(COYOTE_UID) and GameState.has_book_progress(TEST_BOOK_UID),
		"both known books are keyed by uid now")
	_expect(not GameState.has_book_progress(COYOTE_BOOK_PATH),
		"...and NOT by the path they were keyed by in v1")
	_expect(GameState.get_page_status(COYOTE_UID, 0) == GameState.STATUS_COMPLETE
			and GameState.is_page_locked(COYOTE_UID, 0),
		"the coyote page kept its status AND its lock (%s, locked=%s)"
		% [GameState.get_page_status(COYOTE_UID, 0), GameState.is_page_locked(COYOTE_UID, 0)])
	_expect(GameState.get_page_status(TEST_BOOK_UID, 0) == GameState.STATUS_IN_PROGRESS
			and GameState.get_page_status(TEST_BOOK_UID, 1) == GameState.STATUS_COMPLETE,
		"the pre-BL-10 bare status strings migrated too (%s, %s)"
		% [GameState.get_page_status(TEST_BOOK_UID, 0),
			GameState.get_page_status(TEST_BOOK_UID, 1)])
	_expect(int(GameState.get_book_progress(TEST_BOOK_UID).get("current_page_index", -1)) == 1,
		"the cursor survived (%s)"
		% GameState.get_book_progress(TEST_BOOK_UID).get("current_page_index"))
	_expect(GameState.has_book_progress(unknown_key),
		"a v1 key this build has never heard of is passed through unchanged")

	# --- the paint layers -----------------------------------------------------
	var new_coyote_paint := GameState.get_paint_path(_coyote_book, 0)
	var new_test_paint := GameState.get_paint_path_for_key(TEST_BOOK_UID, 1)
	_expect(FileAccess.file_exists(new_coyote_paint) and not FileAccess.file_exists(coyote_paint),
		"the coyote paint layer MOVED to its uid directory (%s)" % new_coyote_paint.get_base_dir())
	_expect(FileAccess.get_file_as_string(new_coyote_paint) == "paint bytes for page_01.png",
		"...with its bytes intact")
	_expect(FileAccess.file_exists(new_test_paint) and not FileAccess.file_exists(test_paint),
		"the test book's page 2 paint moved as well (%s)" % new_test_paint)
	_expect(not DirAccess.dir_exists_absolute(coyote_paint.get_base_dir()),
		"...and the empty v1 directory is gone")
	_expect(FileAccess.file_exists(unknown_paint),
		"the unknown book's paint was left exactly where it was")

	# --- the files on disk ----------------------------------------------------
	_expect(FileAccess.file_exists(GameState.get_save_path()),
		"a v2 file was written (%s)" % GameState.get_save_path().get_file())
	var written: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(GameState.get_save_path())
	)
	_expect(int(written.get("version", 0)) == 2, "...declaring schema v2 (%s)" % written.get("version"))
	var keys := (written.get("books", {}) as Dictionary).keys()
	keys.sort()
	_expect(keys.has(COYOTE_UID) and keys.has(TEST_BOOK_UID),
		"...keyed by uid (%s)" % [keys])
	_expect(FileAccess.file_exists(TEST_SAVE_ROOT.path_join(GameState.LEGACY_SAVE_FILE_NAME)),
		"the v1 file is LEFT ALONE -- a migration never destroys the only copy")

	# --- and it is stable ------------------------------------------------------
	_expect(GameState.load_save(), "loading again reads the v2 file")
	_expect(GameState.get_page_status(COYOTE_UID, 0) == GameState.STATUS_COMPLETE
			and GameState.is_page_locked(COYOTE_UID, 0)
			and FileAccess.file_exists(new_coyote_paint),
		"...and nothing moved or changed the second time round")
	_expect(not GameState.has_book_progress(COYOTE_BOOK_PATH),
		"...the v1 keys did not come back")


# ============================== f: one uid, one save entry, two deliveries ==

func _check_shared_uid() -> void:
	print("\n-- check f: a DLC book and its built-in twin are ONE book --")
	var packs := BookDef.discover_runtime(TEST_DLC_ROOT)
	var dupe := _book_with_uid(packs, COYOTE_UID)
	_expect(dupe != null and dupe.is_runtime,
		"the de-duped pack book is still installed and discoverable on its own")
	if dupe == null:
		return
	_expect(GameState.book_key(dupe) == GameState.book_key(_coyote_book),
		"...and keys the same save entry as the built-in book (%s)" % GameState.book_key(dupe))
	_expect(GameState.get_paint_path(dupe, 0) == GameState.get_paint_path(_coyote_book, 0),
		"...and the same paint directory, so a player who buys the pack keeps their picture")
	_expect(GameState.get_page_status(GameState.book_key(dupe), 0) == GameState.STATUS_COMPLETE,
		"...and the same progress (%s)"
		% GameState.get_page_status(GameState.book_key(dupe), 0))


# =================================================================== helpers ==

func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("%s - %s" % ["PASS" if condition else "FAIL", description])


static func _names(books: Array[BookDef]) -> String:
	var parts: PackedStringArray = []
	for book in books:
		parts.append("%s%s" % [book.get_uid(), "*" if book.is_runtime else ""])
	return ", ".join(parts)


static func _book_with_uid(books: Array[BookDef], uid: String) -> BookDef:
	for book in books:
		if book.get_uid() == uid:
			return book
	return null


static func _rgba(image: Image) -> Image:
	if image.get_format() == Image.FORMAT_RGBA8:
		return image
	var copy := image.duplicate()
	copy.convert(Image.FORMAT_RGBA8)
	return copy


## Region ids at a fixed grid of page pixels -- the hit-test path, sampled.
static func _sample_region_ids(view: PageView) -> PackedInt32Array:
	var ids := PackedInt32Array()
	var size := view.get_page_size()
	var y := 0
	while y < size.y:
		var x := 0
		while x < size.x:
			ids.append(view.get_region_id_at(Vector2(float(x) + 0.5, float(y) + 0.5)))
			x += ID_SAMPLE_STRIDE
		y += ID_SAMPLE_STRIDE
	return ids


## Paints the same region-crossing stroke on whatever page is loaded and returns
## region id -> painted pixel count. The comparison this harness is built around:
## the shader clip must not care where the ID map came from.
func _paint_clip_probe(id_bytes: PackedByteArray, size: Vector2i) -> Dictionary:
	_page_view.clear_paint()
	await _settle()
	_page_view.begin_stroke(CLIP_START)
	var x := CLIP_START.x + 20.0
	while x <= CLIP_END.x:
		_page_view.continue_stroke(Vector2(x, CLIP_START.y))
		x += 20.0
	_page_view.end_stroke()
	await _settle()
	var paint := _rgba(_page_view.get_paint_image())
	var paint_bytes := paint.get_data()
	var counts := {}
	for i in size.x * size.y:
		if paint_bytes[i * 4 + 3] == 0:
			continue
		var offset := i * 4
		var region_id := (id_bytes[offset] << 16) | (id_bytes[offset + 1] << 8) | id_bytes[offset + 2]
		counts[region_id] = int(counts.get(region_id, 0)) + 1
	return counts


func _settle() -> void:
	for i in 8:
		await get_tree().process_frame
		if not _page_view.has_pending_paint():
			break
	await get_tree().process_frame
	await RenderingServer.frame_post_draw


## The v1 paint-directory name for a book path, derived the way the v1 build did.
## A deliberate COPY of the old algorithm: if [method GameState.book_slug] ever
## stopped agreeing with it for path-shaped keys, the migration would look for the
## player's pictures in a directory that never existed -- and a harness that reused
## the live function could not see that.
static func _v1_slug(book_path: String) -> String:
	var directory := book_path.get_base_dir().get_file().to_lower()
	var safe := ""
	for i in directory.length():
		var c := directory[i]
		var ok := (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-"
		safe += c if ok else "_"
	if safe.replace("_", "") == "":
		safe = "book"
	var value := 2166136261
	for byte in book_path.to_utf8_buffer():
		value = (value ^ int(byte)) & 0xffffffff
		value = (value * 16777619) & 0xffffffff
	return "%s_%08x" % [safe, value]


static func _copy_file(from: String, to: String) -> void:
	var bytes := FileAccess.get_file_as_bytes(from)
	if bytes.is_empty():
		push_error("dlc_smoke: could not read '%s' to seed the pack." % from)
		return
	var file := FileAccess.open(to, FileAccess.WRITE)
	if file == null:
		push_error("dlc_smoke: could not write '%s'." % to)
		return
	file.store_buffer(bytes)
	file.close()


static func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("dlc_smoke: could not write '%s'." % path)
		return
	file.store_string(text)
	file.close()


## Removes anything this harness put in the REAL user://dlc, and the directory
## itself when it is left empty -- another harness asserting "there are exactly 2
## books" must never trip over a pack this one forgot.
func _remove_real_pack() -> void:
	_delete_recursive(BookDef.DLC_ROOT.path_join(PACK_SLUG))
	if not DirAccess.dir_exists_absolute(BookDef.DLC_ROOT):
		return
	var directory := DirAccess.open(BookDef.DLC_ROOT)
	if directory != null and directory.get_files().is_empty() \
			and directory.get_directories().is_empty():
		DirAccess.remove_absolute(BookDef.DLC_ROOT)


static func _delete_recursive(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for name in directory.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in directory.get_directories():
		_delete_recursive(path.path_join(name))
	DirAccess.remove_absolute(path)

class_name PageLoader
extends RefCounted
## Turns a [PageDef] into the textures [method PageView.load_page_textures] wants,
## decoding a DLC page's files on a [WorkerThreadPool] task (DLC_SERVER.md 7.1/8.1).
##
## [b]Why this exists.[/b] A pack is plain data: its PNGs never go through the
## Godot importer, so nothing has pre-decoded them into a GPU texture the way a
## [code]res://[/code] page's [code].ctex[/code] already is. Somebody has to run
## [method Image.load_from_file] on a 2048x2048 PNG, and that is tens of
## milliseconds -- fine behind a page flip, unacceptable in the middle of a stroke.
## So the decode happens on a worker task and the main thread picks the result up
## when it needs it.
##
## [b]The built-in path is deliberately untouched.[/b] A non-runtime page is
## resolved with plain [method @GDScript.load] on the calling thread, exactly as it
## always was: the resource loader has its own cache, an imported texture is
## already decoded, and threading a cache hit would only add a frame of latency and
## a class of bug. [method is_threaded] answers which of the two a page gets.
##
## [b]Usage[/b] -- prefetch, then take (see [ColoringPage]):
## [codeblock]
## _loader.request(next_page)          # returns immediately; decode starts
## await _flip_and_save()              # the loading beat pays for the decode
## var bundle := _loader.take(next_page)
## _page_view.load_page_textures(bundle["display"], bundle["idmap"],
##     bundle["regions"], bundle["mask"])
## [/codeblock]
## [method take] is safe to call for a page that was never requested (it loads it
## then and there) and for one whose task is still running (it waits) -- so the
## prefetch is an optimisation, never a correctness requirement.
##
## No scene tree, no nodes, no signals: a plain [RefCounted] that is unit-testable
## without a running game (godot-practices: "prefer RefCounted for pure logic").

## Keys of the dictionary [method take] returns. [code]regions[/code] is the parsed
## regions JSON, [code]mask[/code] is null for a page without one, and
## [code]error[/code] is "" on success.
const KEY_DISPLAY := "display"
const KEY_IDMAP := "idmap"
const KEY_REGIONS := "regions"
const KEY_MASK := "mask"
const KEY_ERROR := "error"

## The page the pending task is decoding, or null when idle.
var _page: PageDef = null
## WorkerThreadPool task id, or -1.
var _task_id := -1
## Written by the worker task, read only after the task has been waited on -- which
## is a synchronisation point, so no lock is needed.
var _bundle: Dictionary = {}


## True when [param page] would be decoded on a worker thread (a DLC page) rather
## than resolved through the importer on the calling thread (a built-in one).
static func is_threaded(page: PageDef) -> bool:
	return page != null and page.is_runtime


## Starts decoding [param page] in the background, if it is worth doing. Returns
## true when a task was started (or was already running for this page). Cheap and
## idempotent: calling it for the page already in flight does nothing.
func request(page: PageDef) -> bool:
	if page == null or not is_threaded(page):
		return false
	if _page == page and _task_id != -1:
		return true
	discard()
	_page = page
	_bundle = {}
	_task_id = WorkerThreadPool.add_task(
		_decode_pending, false, "PageLoader: %s" % page.display_name
	)
	return true


## The bundle for [param page]: the prefetched one when it matches, otherwise a
## fresh load. Waits for a task that is still running.
##
## Always returns a dictionary; check [constant KEY_ERROR] (or just the null
## textures) rather than assuming success.
func take(page: PageDef) -> Dictionary:
	if page == null:
		return _failure("no page")
	if _page != page:
		# Whatever is in flight is for a page nobody is asking about any more.
		discard()
		if is_threaded(page):
			request(page)
		else:
			return load_bundle(page)
	if _task_id == -1:
		return load_bundle(page)
	WorkerThreadPool.wait_for_task_completion(_task_id)
	var bundle := _bundle
	_task_id = -1
	_page = null
	_bundle = {}
	return bundle


## True when a prefetch has finished and [method take] will not block.
func is_ready() -> bool:
	return _task_id != -1 and WorkerThreadPool.is_task_completed(_task_id)


func is_pending() -> bool:
	return _task_id != -1


## Abandons a prefetch. It still has to be WAITED for -- a task that outlived the
## pool is a crash, not a leak -- but its result is dropped.
func discard() -> void:
	if _task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	_page = null
	_bundle = {}


func _decode_pending() -> void:
	_bundle = load_bundle(_page)


## Loads everything a page needs, on whatever thread calls it.
##
## Runs on the worker task for a DLC page. Everything it touches is thread-safe by
## construction: [FileAccess], [JSON], [method Image.load_from_file] and
## [method ImageTexture.create_from_image] (resource creation off the main thread is
## exactly what the engine's own threaded loader does). It never reads the scene
## tree, and it never touches [GameState].
static func load_bundle(page: PageDef) -> Dictionary:
	if page == null:
		return _failure("no page")
	var runtime := page.is_runtime
	var display := PageDef.load_texture(page.display_image_path, runtime)
	if display == null:
		return _failure("cannot load display image '%s'" % page.display_image_path)
	var idmap := PageDef.load_texture(page.id_map_path, runtime)
	if idmap == null:
		return _failure("cannot load ID map '%s'" % page.id_map_path)
	var mask: Texture2D = null
	if page.has_mask():
		mask = PageDef.load_texture(page.mask_image_path, runtime)
		if mask == null:
			push_warning(
				"PageLoader: cannot load mask '%s'; the page draws without it."
				% page.mask_image_path
			)
	return {
		KEY_DISPLAY: display,
		KEY_IDMAP: idmap,
		KEY_REGIONS: read_regions(page.regions_json_path),
		KEY_MASK: mask,
		KEY_ERROR: "",
	}


## The page's regions JSON, parsed. Plain file IO in both worlds -- a pack's
## regions file is read exactly the way a built-in one always was.
static func read_regions(regions_path: String) -> Dictionary:
	if regions_path == "" or not FileAccess.file_exists(regions_path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(regions_path)) != OK \
			or typeof(json.data) != TYPE_DICTIONARY:
		push_warning("PageLoader: regions JSON '%s' did not parse." % regions_path)
		return {}
	return json.data


static func _failure(reason: String) -> Dictionary:
	return {
		KEY_DISPLAY: null,
		KEY_IDMAP: null,
		KEY_REGIONS: {},
		KEY_MASK: null,
		KEY_ERROR: reason,
	}

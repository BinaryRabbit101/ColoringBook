class_name PackInstaller
extends RefCounted
## Downloads a DLC pack and puts it on the shelf, atomically (DLC_SERVER.md 7.2,
## 7.3, 7.4).
##
## [b]The user:// boundary.[/b] [code]GameState[/code] owns all of
## [code]user://[/code] except two things, and this class owns one of them:
## [constant BookDef.DLC_ROOT] ([code]user://dlc/[/code]). Nothing here reads or
## writes a save file, a paint layer or any progress -- installing a pack a child
## already has progress in must not disturb one pixel of it, which is exactly why
## the two roots are disjoint. (The other carve-out is
## [code]user://auth.json[/code]; see [AuthStore].)
##
## [b]The install is a directory rename, and that is the whole atomicity story.[/b]
## [method BookDef.discover_runtime] skips any pack directory ending in
## [constant BookDef.IGNORED_PACK_SUFFIXES] ([code].incoming[/code],
## [code].tmp[/code], [code].partial[/code]), so:
## [codeblock]
## download + unzip + verify   ->  user://dlc/<slug>.incoming/   (invisible)
## old install out of the way  ->  user://dlc/<slug>.tmp/        (invisible)
## the swap                    ->  rename .incoming -> <slug>    (visible, whole)
## tidy up                     ->  delete <slug>.tmp
## [/codeblock]
## A crash at ANY point leaves either the old pack or the new one, never half of
## either, and never a book on the shelf whose files are still arriving
## (DLC_SERVER.md 7.3: "a half-downloaded pack must never be discoverable").
##
## [b]Every sha256 in the manifest is checked[/b] before the swap, against the
## bytes actually on disk. A pack whose ID map arrived corrupt would paint into the
## wrong regions -- silently, and only for the child who downloaded it -- so this is
## a hard gate, not a warning.
##
## [b]Getting the bytes takes two requests on native and one in a browser[/b]
## (BL-19). Natively the [code]302[/code] from [code]/packs/<slug>/download[/code] is
## READ rather than followed, so the bearer header never reaches the signed URL
## (7.4). A browser cannot do that -- it follows redirects itself and never shows
## the caller a [code]Location[/code] -- so on web the authorised endpoint is
## downloaded directly and the redirect is the browser's business, which is also
## where [code]Authorization[/code] is handled by the fetch spec's own rules. See
## [method ApiClient.can_read_redirects] for the measurements behind that.
##
## [b]The manifest is the installer's, not the game's.[/b] It is written into the
## installed directory so the pack records its own [code]pack_version[/code] and
## [code]min_client_version[/code] (7.3's update check reads it back), but nothing
## in the GAME ever opens it: [BookDef] reads [code]book.json[/code] only.
##
## [b]An update downloads the DIFFERENCE, a first install downloads the pack[/b]
## (BL-26). The manifest's per-file sha256 map (7.2) and the entitled
## [code]/packs/<slug>/files/<path>[/code] route exist for exactly this: when a
## version of the pack is already installed and a newer one is being fetched, every
## file whose sha256 the installed tree already has is COPIED into
## [code].incoming[/code] and only the rest is asked for, so a one-page fix on an
## 8 MB pack moves the page rather than the pack. A file that has vanished from the
## new manifest is simply never carried over -- deletion falls out of the diff and
## needs no code of its own.
##
## Three properties make that safe to have at all:
## [codeblock]
## nothing downstream changes   every sha256 is still verified against the bytes
##                              on disk, and the swap is still one rename
## the fallback is total        any diff or fetch that goes wrong restarts on the
##                              archive path, and the caller is told nothing
## first installs are unchanged a delta against nothing is the whole pack, and one
##                              zip beats N requests
## [/codeblock]
## The delta is an OPTIMISATION, and an optimisation that can introduce a failure
## mode is not one. [constant KEY_MODE] on the result says which route ran.
##
## Plain [RefCounted] -- it borrows an [ApiClient] and never touches the tree.

## Suffix a download in flight unpacks into.
const INCOMING_SUFFIX := ".incoming"
## Suffix the previous install is moved to during the swap.
const REPLACED_SUFFIX := ".tmp"
## Name of the archive inside the incoming directory while it downloads.
const ARCHIVE_NAME := "pack.zip"
## The manifest, written into the installed pack (see the class doc).
const MANIFEST_NAME := "manifest.json"

## Result keys of [method install]. [code]ok[/code], plus [ApiClient]'s
## [code]code[/code]/[code]message[/code] so a caller branches the same way it does
## on any other backend call.
const KEY_OK := "ok"
const KEY_CODE := "code"
const KEY_MESSAGE := "message"
const KEY_SLUG := "slug"
const KEY_VERSION := "version"
const KEY_BYTES := "bytes"
const KEY_FILES := "files"
## How the bytes actually arrived (BL-26): one of the MODE_* values below, or "" on
## a failure that never got as far as choosing.
const KEY_MODE := "mode"
## Bytes this install pulled over the wire -- the archive's size, or on a delta the
## size of the files it actually fetched. NOT the pack's size: that is
## [constant KEY_BYTES], and the difference between the two is the point of BL-26.
const KEY_FETCHED_BYTES := "fetched_bytes"
## The pack-relative paths a delta fetched, in order. Empty for an archive install.
const KEY_FETCHED_PATHS := "fetched_paths"
## How many files a delta took from the previous install instead of the network.
const KEY_COPIED_FILES := "copied_files"

## [constant KEY_MODE]: the whole published [code]pack.zip[/code].
const MODE_ARCHIVE := "archive"
## [constant KEY_MODE]: per-file, diffed against what was already installed.
const MODE_DELTA := "delta"

## Installer-specific failure codes, in the server's UPPER_SNAKE namespace.
const CODE_BAD_ARCHIVE := "PACK_ARCHIVE_UNREADABLE"
const CODE_CHECKSUM := "PACK_CHECKSUM_MISMATCH"
const CODE_MISSING_FILE := "PACK_FILE_MISSING"
const CODE_WRITE_FAILED := "PACK_WRITE_FAILED"
const CODE_SWAP_FAILED := "PACK_SWAP_FAILED"
const CODE_BAD_MANIFEST := "PACK_MANIFEST_INVALID"
const CODE_CLIENT_TOO_OLD := "PACK_CLIENT_TOO_OLD"
const CODE_BUSY := "PACK_INSTALL_IN_PROGRESS"

var _api: ApiClient
var _dlc_root := BookDef.DLC_ROOT
## Slug currently installing, or "". One download at a time: two concurrent
## installs of the same pack would fight over one .incoming directory, and a child
## queueing five packs on a phone plan is exactly what 8.2 forbids.
var _busy_slug := ""
## Index of the delta fetch to fail on the next update, or -1. See
## [method fail_next_delta_fetch].
var _delta_fetch_probe := -1


func _init(api: ApiClient, dlc_root: String = BookDef.DLC_ROOT) -> void:
	_api = api
	_dlc_root = dlc_root


func get_dlc_root() -> String:
	return _dlc_root


func is_busy() -> bool:
	return _busy_slug != ""


func get_busy_slug() -> String:
	return _busy_slug


## Makes the next delta's [param index]-th per-file fetch fail. [b]DEV/TEST ONLY[/b]
## -- the mirror of [method GameState.set_autosave_interval] and
## [method Backend.use_test_stores], and for the same reason.
##
## BL-26's fallback is the property the whole feature rests on: a delta that goes
## wrong must cost a bigger download and nothing else. That is otherwise only
## reachable by unplugging the network inside a window a few hundred milliseconds
## wide, which is to say it is otherwise never tested and quietly rots. One
## integer, consumed by the next delta attempt and immediately reset, buys a real
## assertion that the archive picks the install up and finishes it.
func fail_next_delta_fetch(index: int = 0) -> void:
	_delta_fetch_probe = index


# =================================================================== installed ==

## Pack directories currently installed (ignoring anything mid-install).
func installed_slugs() -> PackedStringArray:
	var slugs := PackedStringArray()
	if not DirAccess.dir_exists_absolute(_dlc_root):
		return slugs
	var names := Array(DirAccess.get_directories_at(_dlc_root))
	names.sort()
	for name: String in names:
		if name.begins_with(".") or _has_ignored_suffix(name):
			continue
		slugs.append(name)
	return slugs


func is_installed(slug: String) -> bool:
	return DirAccess.dir_exists_absolute(pack_dir(slug))


func pack_dir(slug: String) -> String:
	return _dlc_root.path_join(slug)


## The manifest of an installed pack, or {} when it is not installed.
func installed_manifest(slug: String) -> Dictionary:
	var path := pack_dir(slug).path_join(MANIFEST_NAME)
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return (parsed as Dictionary) if typeof(parsed) == TYPE_DICTIONARY else {}


## Installed [code]pack_version[/code], or 0 when the pack is not installed.
## The client half of DLC_SERVER.md 7.3's update check; the other half is
## [method EntitlementsStore.latest_version].
func installed_version(slug: String) -> int:
	return int(installed_manifest(slug).get("pack_version", 0))


## [code]min_client_version[/code] an installed pack declares, or "".
func installed_min_client_version(slug: String) -> String:
	return String(installed_manifest(slug).get("min_client_version", ""))


## Removes an installed pack. Used by dev harnesses and by an explicit
## "remove this book" in the parent panel -- NEVER by entitlement loss
## (DLC_SERVER.md 7.3: the pixels a child already painted stay on disk).
func uninstall(slug: String) -> bool:
	if slug.strip_edges() == "":
		return false
	var removed := false
	for suffix in ["", INCOMING_SUFFIX, REPLACED_SUFFIX]:
		var path := pack_dir(slug + suffix)
		if DirAccess.dir_exists_absolute(path):
			delete_recursive(path)
			removed = true
	return removed


# ===================================================================== install ==

## Fetches the manifest, downloads the archive, verifies every checksum and swaps
## the pack into place. Returns a result dictionary; never throws, never leaves a
## visible half-install.
##
## [param on_progress] is called with (downloaded_bytes, total_bytes) during the
## download so a caller can drive a progress bar from real numbers
## (DLC_SERVER.md 7.4). [param version] pins a specific pack version; 0 means
## "whatever is newest".
##
## [b]This is only ever called from a user-initiated action[/b] (DLC_SERVER.md 8.2:
## "a pack never starts downloading on its own"). Nothing in this class schedules
## itself.
func install(slug: String, version: int = 0, on_progress: Callable = Callable()) -> Dictionary:
	if slug.strip_edges() == "":
		return _fail(slug, CODE_BAD_MANIFEST, "No pack slug.")
	if _busy_slug != "":
		return _fail(slug, CODE_BUSY, "Already installing '%s'." % _busy_slug)
	_busy_slug = slug
	var result := await _install(slug, version, on_progress)
	_busy_slug = ""
	if not bool(result[KEY_OK]):
		# Whatever we were writing is invisible to the shelf either way; removing it
		# stops a failed attempt from filling a tablet up.
		delete_recursive(pack_dir(slug + INCOMING_SUFFIX))
	return result


func _install(slug: String, version: int, on_progress: Callable) -> Dictionary:
	# --- 1. the manifest (also what auto-grants a free pack, server-side) ------
	var query := {}
	if version > 0:
		query["version"] = str(version)
	var manifest_result: Dictionary = await _api.request_json(
		HTTPClient.METHOD_GET, "/packs/%s/manifest" % slug, null, {"query": query}
	)
	if not bool(manifest_result[ApiClient.KEY_OK]):
		return _from_api(slug, manifest_result)
	var manifest: Variant = manifest_result[ApiClient.KEY_DATA]
	if typeof(manifest) != TYPE_DICTIONARY:
		return _fail(slug, CODE_BAD_MANIFEST, "The manifest was not a JSON object.")
	var files := _manifest_files(manifest as Dictionary)
	if files.is_empty():
		return _fail(slug, CODE_BAD_MANIFEST, "The manifest lists no files.")

	# --- 2. min_client_version, client-side too (DLC_SERVER.md 7.3) -----------
	var required := String((manifest as Dictionary).get("min_client_version", ""))
	if not BackendConfig.satisfies_min_version(required, _api.get_client_version()):
		return _fail(slug, CODE_CLIENT_TOO_OLD,
			"This pack needs app version %s or newer." % required)

	# --- 3. the bytes: the difference if we can, the whole pack otherwise -----
	var pinned := int((manifest as Dictionary).get("pack_version", version))
	var incoming := pack_dir(slug + INCOMING_SUFFIX)
	var arrival := {}
	if _can_delta(slug, installed_version(slug), pinned):
		arrival = await _install_delta(slug, query, files, incoming, on_progress)
		if bool(arrival[KEY_OK]):
			# The hard gate below runs for both routes, but a delta has to face it
			# HERE as well: a tree the new manifest disowns is a delta gone wrong, and
			# "gone wrong" must mean "take the archive", not "this pack failed". The
			# second pass a few lines down is not wasted -- it is the gate every
			# install goes through, and this one is only the fallback's trigger.
			var provisional := verify_files(incoming, files)
			if not bool(provisional[KEY_OK]):
				arrival = _fail(slug, String(provisional[KEY_CODE]),
					String(provisional[KEY_MESSAGE]))
		if not bool(arrival[KEY_OK]):
			# BL-26's whole safety argument: a delta that goes wrong is not a failed
			# install, it is an install that did not get its shortcut. Nobody on screen
			# hears about it; the archive path starts from scratch on the next line.
			print_verbose("PackInstaller: the delta for '%s' fell back to the archive (%s: %s)."
				% [slug, arrival[KEY_CODE], arrival[KEY_MESSAGE]])
			arrival = {}
	if arrival.is_empty():
		arrival = await _install_archive(slug, query, incoming, on_progress)
	if not bool(arrival[KEY_OK]):
		return arrival

	# --- 4. verify EVERY sha256 (the hard gate; see the class doc) ------------
	# Both routes land here, and it is the reason the delta needs no trust of its
	# own: a file copied from the previous install is checked against the NEW
	# manifest exactly as a file off the wire is.
	var verified := verify_files(incoming, files)
	if not bool(verified[KEY_OK]):
		return _fail(slug, String(verified[KEY_CODE]), String(verified[KEY_MESSAGE]))

	# The manifest is not in its own `files` map, so write it after verification.
	var manifest_file := FileAccess.open(incoming.path_join(MANIFEST_NAME), FileAccess.WRITE)
	if manifest_file == null:
		return _fail(slug, CODE_WRITE_FAILED, "Could not write the manifest.")
	manifest_file.store_string(JSON.stringify(manifest, "\t"))
	manifest_file.close()

	# --- 6. the swap ----------------------------------------------------------
	var swapped := _swap(slug)
	if swapped != "":
		return _fail(slug, CODE_SWAP_FAILED, swapped)

	var total := 0
	for path: Variant in files:
		total += int((files[path] as Dictionary).get("bytes", 0))
	return {
		KEY_OK: true, KEY_CODE: "", KEY_MESSAGE: "",
		KEY_SLUG: slug, KEY_VERSION: pinned, KEY_BYTES: total, KEY_FILES: files.size(),
		KEY_MODE: String(arrival[KEY_MODE]),
		KEY_FETCHED_BYTES: int(arrival[KEY_FETCHED_BYTES]),
		KEY_FETCHED_PATHS: arrival[KEY_FETCHED_PATHS],
		KEY_COPIED_FILES: int(arrival[KEY_COPIED_FILES]),
	}


# ================================================================== the routes ==

## Whether this install is an UPDATE the delta applies to (BL-26).
##
## Deliberately narrow. A first install has nothing to diff against, and a
## same-version reinstall -- which is what a repair is -- stays on the archive: the
## entry scoped the delta to updates, and re-fetching a pack somebody asked for
## again is the one case where the extra bytes buy something.
func _can_delta(slug: String, installed: int, pinned: int) -> bool:
	return installed > 0 and pinned > installed and is_installed(slug)


## Fills [param incoming] from the published [code]pack.zip[/code] -- the whole
## pack, unconditionally. First installs, and anything the delta declined or fumbled.
func _install_archive(slug: String, query: Dictionary, incoming: String,
		on_progress: Callable) -> Dictionary:
	var download_url := ""
	if ApiClient.can_read_redirects():
		var redirect: Dictionary = await _api.request_json(
			HTTPClient.METHOD_GET, "/packs/%s/download" % slug, null,
			{"query": query, "follow_redirects": false}
		)
		download_url = String(redirect.get(ApiClient.KEY_LOCATION, ""))
		var status := int(redirect[ApiClient.KEY_STATUS])
		if download_url == "" and not (status >= 200 and status < 300):
			# Neither a redirect we can follow nor a body we were handed: a real error.
			return _from_api(slug, redirect)

	delete_recursive(incoming)
	DirAccess.make_dir_recursive_absolute(incoming)
	var archive := incoming.path_join(ARCHIVE_NAME)

	var download: Dictionary
	if download_url != "":
		# The signed URL authorises itself in its query string and must NOT get a
		# bearer header (DLC_SERVER.md 7.4).
		download = await _api.download(download_url, archive, {"auth": false}, on_progress)
	else:
		# In a browser this is the WHOLE step (BL-19): one authorised request that the
		# browser redirects for us, streamed straight to disk. On native it is the
		# fallback for a server that answered with bytes instead of a 302.
		download = await _api.download(
			"/packs/%s/download" % slug, archive, {"query": query}, on_progress
		)
	if not bool(download[ApiClient.KEY_OK]):
		return _from_api(slug, download)
	if not FileAccess.file_exists(archive):
		return _fail(slug, CODE_WRITE_FAILED, "The archive did not reach disk.")
	var moved := file_size(archive)

	var unpacked := _unzip(archive, incoming)
	if unpacked != "":
		return _fail(slug, CODE_BAD_ARCHIVE, unpacked)
	DirAccess.remove_absolute(archive)
	return _arrived(MODE_ARCHIVE, moved, PackedStringArray(), 0)


## Fills [param incoming] file by file (BL-26): everything the installed pack
## already holds at the sha256 the NEW manifest asks for is copied across, and only
## the remainder is fetched.
##
## [b]The diff is the manifest against the bytes on disk, not manifest against
## manifest.[/b] Comparing the two manifests would trust the installed one -- a file
## a previous crash truncated, or a disk that ate a byte, still has its old entry in
## the old manifest and would be carried into the new install as good. Hashing what
## is actually there costs one read per file and cannot be wrong; and since it is
## the same hash [method verify_files] applies afterwards, a corrupted file simply
## joins the fetch list.
##
## Returns a failure result rather than throwing, and the caller treats ANY failure
## as "take the archive instead" -- so nothing in here has to be careful about
## leaving [param incoming] half built.
func _install_delta(slug: String, query: Dictionary, files: Dictionary, incoming: String,
		on_progress: Callable) -> Dictionary:
	var sabotage := _delta_fetch_probe
	_delta_fetch_probe = -1
	var source := pack_dir(slug)
	var copy_paths := PackedStringArray()
	var fetch_paths := PackedStringArray()
	var fetch_bytes := 0
	for path_variant: Variant in files:
		var path := String(path_variant)
		if not is_safe_entry(path):
			# The same zip-slip shapes the archive path rejects. A manifest is our own
			# server's word, and this is still not a thing to take on trust.
			return _fail(slug, CODE_BAD_MANIFEST,
				"The manifest lists an unsafe path ('%s')." % path)
		var expected := String((files[path_variant] as Dictionary).get("sha256", "")).to_lower()
		var local := source.path_join(path)
		if expected != "" and FileAccess.file_exists(local) \
				and FileAccess.get_sha256(local).to_lower() == expected:
			copy_paths.append(path)
		else:
			fetch_paths.append(path)
			fetch_bytes += int((files[path_variant] as Dictionary).get("bytes", 0))

	delete_recursive(incoming)
	DirAccess.make_dir_recursive_absolute(incoming)
	for path in copy_paths:
		var target := incoming.path_join(path)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var error := DirAccess.copy_absolute(source.path_join(path), target)
		if error != OK:
			return _fail(slug, CODE_WRITE_FAILED,
				"Could not reuse '%s' from the installed pack (%d)." % [path, error])

	var done := 0
	for index in fetch_paths.size():
		var path := fetch_paths[index]
		if index == sabotage:
			return _fail(slug, CODE_WRITE_FAILED,
				"A dev probe failed the fetch of '%s'." % path)
		var target := incoming.path_join(path)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		# Captured per file so the bar counts the whole delta, not each file from zero.
		var already := done
		var fetched: Dictionary = await _download_pack_file(slug, path, query, target,
			func(downloaded: int, _total: int) -> void:
				if on_progress.is_valid():
					on_progress.call(already + maxi(downloaded, 0), fetch_bytes)
		)
		if not bool(fetched[ApiClient.KEY_OK]):
			return _from_api(slug, fetched)
		if not FileAccess.file_exists(target):
			return _fail(slug, CODE_WRITE_FAILED, "'%s' did not reach disk." % path)
		done += file_size(target)
		if on_progress.is_valid():
			on_progress.call(done, fetch_bytes)
	return _arrived(MODE_DELTA, fetch_bytes, fetch_paths, copy_paths.size())


## One file out of a published release, through the same two-shaped hop the archive
## takes (BL-19): native reads the [code]302[/code] and fetches the signed URL with
## no bearer header; web asks the authorised route and lets the browser follow.
func _download_pack_file(slug: String, path: String, query: Dictionary,
		destination: String, on_progress: Callable) -> Dictionary:
	var route := "/packs/%s/files/%s" % [slug, encode_pack_path(path)]
	if ApiClient.can_read_redirects():
		var redirect: Dictionary = await _api.request_json(
			HTTPClient.METHOD_GET, route, null, {"query": query, "follow_redirects": false}
		)
		var url := String(redirect.get(ApiClient.KEY_LOCATION, ""))
		if url != "":
			return await _api.download(url, destination, {"auth": false}, on_progress)
		var status := int(redirect[ApiClient.KEY_STATUS])
		if not (status >= 200 and status < 300):
			return redirect
	return await _api.download(route, destination, {"query": query}, on_progress)


## Percent-encodes a pack-relative path for a URL [b]without touching its
## separators[/b]: the delta route is declared [code]{path}[/code] with
## [code].*[/code] precisely because a pack path has slashes in it
## ([code]books/coyote-2026/page_01.png[/code]), and encoding those would address a
## file that does not exist.
static func encode_pack_path(path: String) -> String:
	var parts := PackedStringArray()
	for part in path.split("/"):
		parts.append(part.uri_encode())
	return "/".join(parts)


## Result of one of the two routes above: how the bytes arrived, and at what cost.
static func _arrived(mode: String, fetched_bytes: int, fetched_paths: PackedStringArray,
		copied_files: int) -> Dictionary:
	return {
		KEY_OK: true, KEY_CODE: "", KEY_MESSAGE: "", KEY_MODE: mode,
		KEY_FETCHED_BYTES: fetched_bytes, KEY_FETCHED_PATHS: fetched_paths,
		KEY_COPIED_FILES: copied_files,
	}


## The manifest's pack-relative path -> {bytes, sha256} map (DLC_SERVER.md 7.2).
static func _manifest_files(manifest: Dictionary) -> Dictionary:
	var raw: Variant = manifest.get("files", {})
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var files := {}
	for path: Variant in (raw as Dictionary):
		var entry: Variant = (raw as Dictionary)[path]
		if typeof(entry) == TYPE_DICTIONARY:
			files[String(path)] = entry
	return files


## Total unpacked bytes a manifest describes -- what a progress bar counts against
## when the server sends no Content-Length.
static func manifest_total_bytes(manifest: Dictionary) -> int:
	var total := 0
	for path: Variant in _manifest_files(manifest):
		total += int((_manifest_files(manifest)[path] as Dictionary).get("bytes", 0))
	return total


# ======================================================================= steps ==

## Extracts [param archive] into [param destination]. Returns "" on success or a
## human-readable reason. One entry at a time, so peak memory is the biggest FILE
## in the pack, not the pack.
static func _unzip(archive: String, destination: String) -> String:
	var reader := ZIPReader.new()
	var error := reader.open(archive)
	if error != OK:
		return "ZIPReader could not open the archive (%d)." % error
	var entries := reader.get_files()
	if entries.is_empty():
		reader.close()
		return "The archive is empty."
	for entry in entries:
		if entry.ends_with("/"):
			continue
		if not is_safe_entry(entry):
			reader.close()
			return "The archive contains an unsafe path ('%s')." % entry
		var target := destination.path_join(entry)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var file := FileAccess.open(target, FileAccess.WRITE)
		if file == null:
			reader.close()
			return "Could not write '%s'." % entry
		file.store_buffer(reader.read_file(entry))
		file.close()
	reader.close()
	return ""


## Rejects the zip-slip shapes: absolute paths, drive letters and any
## [code]..[/code] component. A pack is plain data from our own server, but a
## content bundle that can write outside its own directory is a category of bug we
## simply decline to have (DLC_SERVER.md 7.1 makes the same argument about scripts).
static func is_safe_entry(entry: String) -> bool:
	if entry.begins_with("/") or entry.begins_with("\\") or ":" in entry:
		return false
	for part in entry.replace("\\", "/").split("/"):
		if part == "..":
			return false
	return true


## Checks every file the manifest declares. Returns {ok, code, message}.
static func verify_files(root: String, files: Dictionary) -> Dictionary:
	for path: Variant in files:
		var relative := String(path)
		var absolute := root.path_join(relative)
		if not FileAccess.file_exists(absolute):
			return {KEY_OK: false, KEY_CODE: CODE_MISSING_FILE,
				KEY_MESSAGE: "The pack is missing '%s'." % relative}
		var expected := String((files[path] as Dictionary).get("sha256", "")).to_lower()
		if expected == "":
			continue
		var actual := FileAccess.get_sha256(absolute).to_lower()
		if actual != expected:
			return {KEY_OK: false, KEY_CODE: CODE_CHECKSUM,
				KEY_MESSAGE: "'%s' failed its checksum (%s != %s)."
					% [relative, actual.left(12), expected.left(12)]}
	return {KEY_OK: true, KEY_CODE: "", KEY_MESSAGE: ""}


## The atomic bit. Returns "" on success or a reason. See the class doc for why
## every intermediate name is one the shelf ignores.
func _swap(slug: String) -> String:
	var incoming := pack_dir(slug + INCOMING_SUFFIX)
	var target := pack_dir(slug)
	var replaced := pack_dir(slug + REPLACED_SUFFIX)
	var directory := DirAccess.open(_dlc_root)
	if directory == null:
		return "Could not open %s." % _dlc_root

	delete_recursive(replaced)
	if DirAccess.dir_exists_absolute(target):
		var moved := directory.rename(target, replaced)
		if moved != OK:
			return "Could not move the previous install aside (%d)." % moved
	var error := directory.rename(incoming, target)
	if error != OK:
		# Put the old pack back rather than leaving the player with neither.
		if DirAccess.dir_exists_absolute(replaced):
			directory.rename(replaced, target)
		return "Could not move the new pack into place (%d)." % error
	delete_recursive(replaced)
	return ""


# ===================================================================== helpers ==

static func _has_ignored_suffix(name: String) -> bool:
	for suffix in BookDef.IGNORED_PACK_SUFFIXES:
		if name.ends_with(suffix):
			return true
	return false


func _fail(slug: String, code: String, message: String) -> Dictionary:
	return {KEY_OK: false, KEY_CODE: code, KEY_MESSAGE: message,
		KEY_SLUG: slug, KEY_VERSION: 0, KEY_BYTES: 0, KEY_FILES: 0,
		KEY_MODE: "", KEY_FETCHED_BYTES: 0, KEY_FETCHED_PATHS: PackedStringArray(),
		KEY_COPIED_FILES: 0}


## Size of a file in bytes, or 0. Public because the smoke compares installed trees
## and there is no reason for two copies.
static func file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := int(file.get_length())
	file.close()
	return size


func _from_api(slug: String, result: Dictionary) -> Dictionary:
	return _fail(slug, String(result.get(ApiClient.KEY_CODE, ApiClient.CODE_OFFLINE)),
		String(result.get(ApiClient.KEY_MESSAGE, "")))


## Recursive delete. Public because the smoke and [Backend]'s cleanup both need it
## and there is no reason for two copies.
static func delete_recursive(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for name in directory.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in directory.get_directories():
		delete_recursive(path.path_join(name))
	DirAccess.remove_absolute(path)

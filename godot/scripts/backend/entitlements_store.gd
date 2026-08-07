class_name EntitlementsStore
extends RefCounted
## What the server last said this account owns -- cached, with a TTL and a
## LAST-KNOWN-GOOD fallback (DLC_SERVER.md 9, 8.2).
##
## [b]The client never decides ownership[/b] (DLC_SERVER.md 9). This class is a
## cache of the server's answer and nothing more: every download is authorised
## server-side, and a book that is hidden here is hidden from the SHELF, never
## deleted from disk (7.3: "never delete a pack's files on entitlement loss").
##
## [b]Why a last-known-good fallback is a correctness requirement, not a nicety.[/b]
## A child opening the app on a train has no network. If "no answer" meant "owns
## nothing", every DLC book would vanish from the shelf mid-holiday -- which is the
## single most upsetting failure this system can produce and is entirely avoidable.
## So:
## [codeblock]
## fresh (within TTL)   -> use it
## stale                -> use it ANYWAY, and refresh in the background
## never fetched        -> own nothing yet, but install nothing either
## fetch failed         -> keep whatever we had, forever, until a fetch succeeds
## [/codeblock]
## The only thing that ever shrinks the list is a SUCCESSFUL fetch that omits a
## pack. That is the server revoking it, which is exactly the case where hiding is
## right.
##
## [b]Where it lives.[/b] [constant CACHE_PATH], inside Backend's own
## [code]user://dlc/[/code] root -- see the boundary note in [PackInstaller].
## [method BookDef.discover_runtime] lists DIRECTORIES only, so a JSON file sitting
## in that root is invisible to the shelf.
##
## Plain [RefCounted]: no nodes, no tree.

## Cache file. In [code]user://dlc/[/code] because entitlements are pack state, and
## [code]user://dlc/[/code] is the one part of [code]user://[/code] Backend owns
## besides [code]auth.json[/code].
const CACHE_PATH := "user://dlc/entitlements.json"
const SCHEMA_VERSION := 1

## How long a fetched list counts as FRESH. Short, because a purchase should show
## up on the shelf the same session; staleness past this is not an error, it just
## schedules a refresh (DLC_SERVER.md 9: "a short TTL and a last known good
## fallback").
const TTL_SECONDS := 900.0

## Keys of one cached entitlement -- the server's [code]EntitlementResource[/code]
## shape, verbatim (DLC_SERVER.md 11).
const KEY_SLUG := "pack_slug"
const KEY_LATEST_VERSION := "latest_version"
const KEY_SOURCE := "source"
const KEY_GRANTED_AT := "granted_at"

var _path := CACHE_PATH
var _loaded := false
## pack_slug -> the server's row for it.
var _by_slug: Dictionary = {}
## Unix seconds of the last SUCCESSFUL fetch; 0 = never.
var _fetched_at := 0.0
## Account the cache belongs to, so signing in as somebody else cannot inherit the
## previous account's shelf.
var _account := ""


func _init(path: String = CACHE_PATH) -> void:
	_path = path


# ==================================================================== reading ==

## True when a successful fetch has ever landed for this account.
func has_data() -> bool:
	_ensure_loaded()
	return _fetched_at > 0.0


## True when the cache is inside its TTL. Stale is NOT unusable -- see the class
## doc -- it only means a refresh is worth scheduling.
func is_fresh() -> bool:
	_ensure_loaded()
	return has_data() and (Time.get_unix_time_from_system() - _fetched_at) < TTL_SECONDS


func get_age_seconds() -> float:
	_ensure_loaded()
	return -1.0 if _fetched_at <= 0.0 else float(Time.get_unix_time_from_system()) - _fetched_at


## Every cached row, newest grant first (the order the server sent).
func get_all() -> Array:
	_ensure_loaded()
	return _by_slug.values().duplicate()


func get_slugs() -> PackedStringArray:
	_ensure_loaded()
	var slugs := PackedStringArray()
	for slug: Variant in _by_slug:
		slugs.append(String(slug))
	return slugs


## Does this account own [param pack_slug]?
##
## [b]With no data at all this is FALSE[/b] -- an account that has never
## successfully talked to the server owns nothing it can prove. That is safe
## because it only ever hides books that were downloaded through this same server,
## and [method should_hide_book] is what the shelf actually asks.
func owns(pack_slug: String) -> bool:
	_ensure_loaded()
	return _by_slug.has(pack_slug)


## The shelf's question, and deliberately not the same as [method owns]: hide an
## installed pack's books ONLY when the server has positively told us this account
## no longer owns it. No cache, an expired token, a plane -- none of those are a
## revocation, and none of them may take a child's book away (DLC_SERVER.md 8.2).
func should_hide_book(pack_slug: String) -> bool:
	if pack_slug == "":
		return false
	_ensure_loaded()
	if not has_data():
		return false
	return not _by_slug.has(pack_slug)


## The newest published version of [param pack_slug] this client may run, per the
## last fetch, or 0 when unknown. Folded into the entitlements call precisely so
## the update check costs no extra round trip (DLC_SERVER.md 7.3).
func latest_version(pack_slug: String) -> int:
	_ensure_loaded()
	var row: Variant = _by_slug.get(pack_slug, null)
	if typeof(row) != TYPE_DICTIONARY:
		return 0
	return int((row as Dictionary).get(KEY_LATEST_VERSION, 0))


func get_account() -> String:
	_ensure_loaded()
	return _account


func get_path() -> String:
	return _path


# ==================================================================== writing ==

## Replaces the cache with a successful [code]GET /entitlements[/code] response
## (a BARE JSON array). Rows without a [code]pack_slug[/code] are dropped.
func store(rows: Array, account: String) -> void:
	_ensure_loaded()
	_by_slug = {}
	for raw: Variant in rows:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var row := raw as Dictionary
		var slug := String(row.get(KEY_SLUG, "")).strip_edges()
		if slug == "":
			continue
		_by_slug[slug] = {
			KEY_SLUG: slug,
			KEY_LATEST_VERSION: int(row.get(KEY_LATEST_VERSION, 0)),
			KEY_SOURCE: String(row.get(KEY_SOURCE, "")),
			KEY_GRANTED_AT: String(row.get(KEY_GRANTED_AT, "")),
		}
	_fetched_at = float(Time.get_unix_time_from_system())
	_account = account
	_write()


## Forgets everything. Called on sign-out and whenever the signed-in account
## changes -- one family tablet, two parents, no inherited shelves.
func clear() -> void:
	_loaded = true
	_by_slug = {}
	_fetched_at = 0.0
	_account = ""
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(_path)


## Drops the cache when it belongs to a different account than [param account].
## Returns true when it did. Cheap enough to call on every sign-in.
func reset_if_other_account(account: String) -> bool:
	_ensure_loaded()
	if _account == "" or _account == account:
		return false
	clear()
	return true


# ======================================================================= disk ==

func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("EntitlementsStore: '%s' is not a JSON object; ignoring it." % _path)
		return
	var data := parsed as Dictionary
	if int(data.get("version", 0)) > SCHEMA_VERSION:
		return
	_fetched_at = float(data.get("fetched_at", 0.0))
	_account = String(data.get("account", ""))
	for raw: Variant in data.get("entitlements", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var slug := String((raw as Dictionary).get(KEY_SLUG, ""))
		if slug != "":
			_by_slug[slug] = raw


func _write() -> void:
	var directory := _path.get_base_dir()
	if directory != "" and not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		push_warning("EntitlementsStore: could not write '%s'." % _path)
		return
	file.store_string(JSON.stringify({
		"version": SCHEMA_VERSION,
		"account": _account,
		"fetched_at": _fetched_at,
		"entitlements": _by_slug.values(),
	}, "\t"))
	file.close()

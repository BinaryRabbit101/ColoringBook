class_name StickerSetDef
extends Resource
## One box of stickers -- the thing the crayon strip turns into when the cycle
## ring runs past the last crayon box (BACKLOG BL-36).
##
## [b]It is content, not a palette feature.[/b] A [CrayonSetDef] is authored data
## that ships with the build; a sticker set is CATALOG content delivered by the
## server exactly like a coloring book (BL-37, DLC_SERVER.md §7). The repo keeps a
## dev-fixture set under [constant SETS_ROOT] for the smokes and as the source of
## the free "Starter Stickers" pack, and every export preset excludes it, so a
## released build's sticker sets all come from [code]user://dlc[/code] -- the same
## BL-25 rule the books follow.
##
## [b]Discovery mirrors [BookDef] exactly[/b] ([method discover]): the
## [code]res://[/code] scan finds fixture sets, then the installed packs under
## [constant DLC_ROOT] are scanned for
## [code]<pack>/stickers/<set>/sticker_set.json[/code] and each one is turned into
## a [StickerSetDef]/[StickerDef] pair IN MEMORY with every path resolved to an
## absolute [code]user://[/code] file. The two are de-duped by [member set_uid]
## with the BUILT-IN winning, for the reason books have the same rule: a pack may
## legitimately ship the set the build already contains, and two copies would
## fight over one strip position.
##
## [code]sticker_set.json[/code] is the same shape as one entry of a pack
## manifest's [code]sticker_sets[][/code] array, so an installed tree is
## self-describing and can be hand-seeded during development -- again exactly like
## [code]book.json[/code] (DLC_SERVER.md §7.2).
##
## A set carries stickers and an order. It carries nothing about how the game
## PLAYS -- no brush, no threshold, no placement rules -- for the same reason
## [CrayonSetDef] does not (BL-23's rule, unchanged): a box is content, never a
## difficulty mode.

## Where [method discover] scans for built-in (dev fixture) sets. One directory
## per set, each holding a set file.
const SETS_ROOT := "res://resources/stickers"
## Where [method discover] scans for INSTALLED DLC packs (BL-37). One directory per
## pack; its sets live in [code]<pack>/stickers/<set>/sticker_set.json[/code].
const DLC_ROOT := "user://dlc"
## Sub-directory of a pack holding its sticker sets.
const PACK_STICKERS_DIR := "stickers"
## File describing one set inside a pack.
const SET_JSON_NAME := "sticker_set.json"
## Accepted set file names inside a fixture directory, in probe order. The second
## covers exported builds, where "Convert text resources to binary" can rewrite an
## authored .tres as a .res next to it.
const SET_FILE_NAMES: PackedStringArray = ["sticker_set.tres", "sticker_set.res"]

## Stable identity of this set, ACROSS builds, devices and delivery mechanisms --
## the sticker half of [member BookDef.book_uid]. A saved sticker placement names
## it, so it must never change once a build has shipped with it.
## Convention: lower-case, hyphenated, with the year
## ([code]starter-stickers-2026[/code]).
@export var set_uid: String = ""

## Set name as the player sees it -- what the box-name flash shouts when the cycle
## ring lands on this set.
@export var display_name: String = ""

## Where this set sits in the ring, low first. Ties break on [member display_name],
## so two sets can never swap places between runs.
@export var sort_order: int = 100

## The stickers, in strip order.
@export var stickers: Array[StickerDef] = []

# ---------------------------------------------------------------- runtime sets --
# Deliberately NOT exported (the [BookDef] rule): an authored .tres must never be
# able to claim it is a pack set.

## True when this set was built from a pack's [code]sticker_set.json[/code] and its
## files live under [code]user://[/code] rather than in the build.
var is_runtime: bool = false
## Pack this set was installed from, or "" for a fixture set. The entitlement
## filter keys off this -- a set from a pack the player no longer owns is dropped
## by the CALLER, never by [method discover] (DLC_SERVER.md §8.1).
var pack_slug: String = ""
## Absolute directory a runtime set was loaded from, or "".
var source_dir: String = ""


# ==================================================================== lookups ==

## The set's stable identity: its authored [member set_uid] when it has one, else
## the resource path, else the display name -- so a set somebody forgot to give a
## uid still keys its own save entries rather than colliding with every other one.
func get_uid() -> String:
	var uid := set_uid.strip_edges()
	if uid != "":
		return uid
	if resource_path != "":
		return resource_path
	return "runtime:%s" % display_name


func sticker_count() -> int:
	return stickers.size()


## The sticker at [param index], or null when out of range.
func get_sticker(index: int) -> StickerDef:
	if index < 0 or index >= stickers.size():
		return null
	return stickers[index]


## The sticker with [param sticker_id], or null. This is what a SAVED placement is
## resolved through -- an id the installed set no longer offers comes back null and
## the placement is simply dropped, which is why a save that names a pack the
## player has uninstalled still loads.
func find_sticker(sticker_id: String) -> StickerDef:
	for sticker in stickers:
		if sticker != null and sticker.sticker_id == sticker_id:
			return sticker
	return null


func index_of(sticker_id: String) -> int:
	for i in stickers.size():
		if stickers[i] != null and stickers[i].sticker_id == sticker_id:
			return i
	return -1


# ================================================================== discovery ==

## Every sticker set the player has, fixture sets first: [param root] scanned the
## way [method BookDef.discover_builtin] scans books, then the installed packs
## under [param dlc_root].
##
## De-duped by [member set_uid], BUILT-IN wins. Passing "" as [param dlc_root]
## scans fixture sets only. Entitlement filtering is the CALLER's job.
static func discover(root: String = SETS_ROOT, dlc_root: String = DLC_ROOT) -> Array[StickerSetDef]:
	var sets := discover_builtin(root)
	var seen := {}
	for set_def in sets:
		seen[set_def.get_uid()] = true
	if dlc_root != "":
		for set_def in discover_runtime(dlc_root):
			var uid := set_def.get_uid()
			if seen.has(uid):
				print_verbose(
					"StickerSetDef: pack set '%s' (pack '%s') is already built in; keeping the built-in one."
					% [uid, set_def.pack_slug]
				)
				continue
			seen[uid] = true
			sets.append(set_def)
	sets.sort_custom(_before)
	return sets


## Every FIXTURE set under [param root], one directory each.
##
## [b]An absent root is NORMAL[/b] and says so quietly, for the same reason
## [method BookDef.discover_builtin]'s is: a shipped build excludes
## [code]resources/stickers/*[/code], so this scan finds nothing by construction and
## every set comes from the server.
static func discover_builtin(root: String = SETS_ROOT) -> Array[StickerSetDef]:
	var sets: Array[StickerSetDef] = []
	if not DirAccess.dir_exists_absolute(root):
		print_verbose(
			"StickerSetDef: no built-in sticker sets at '%s'; the strip is the server's." % root
		)
		return sets
	var names := Array(DirAccess.get_directories_at(root))
	names.sort()
	for directory_name: String in names:
		var set_def := load_from_directory(root.path_join(directory_name))
		if set_def != null:
			sets.append(set_def)
	return sets


## Loads the set file inside [param directory], or null when there is none.
static func load_from_directory(directory: String) -> StickerSetDef:
	for file_name in SET_FILE_NAMES:
		var path := directory.path_join(file_name)
		if not ResourceLoader.exists(path):
			continue
		var set_def := load(path) as StickerSetDef
		if set_def == null:
			push_error("StickerSetDef: '%s' exists but did not load as a StickerSetDef." % path)
			return null
		return set_def
	return null


## Every sticker set in every installed pack under [param dlc_root], sorted by pack
## slug then by set directory name (the caller re-sorts by [member sort_order]). A
## missing root is normal; a broken set is skipped with a warning rather than
## taking the strip down with it.
static func discover_runtime(dlc_root: String = DLC_ROOT) -> Array[StickerSetDef]:
	var sets: Array[StickerSetDef] = []
	if dlc_root == "" or not DirAccess.dir_exists_absolute(dlc_root):
		return sets
	var pack_names := Array(DirAccess.get_directories_at(dlc_root))
	pack_names.sort()
	for pack_name: String in pack_names:
		# The same half-install guard the shelf uses: a pack still downloading is
		# named <slug>.incoming and must never be discoverable.
		if _is_ignored_pack(pack_name):
			continue
		var pack_root := dlc_root.path_join(pack_name)
		var stickers_dir := pack_root.path_join(PACK_STICKERS_DIR)
		if not DirAccess.dir_exists_absolute(stickers_dir):
			continue
		var set_names := Array(DirAccess.get_directories_at(stickers_dir))
		set_names.sort()
		for set_name: String in set_names:
			var set_dir := stickers_dir.path_join(set_name)
			var json_path := set_dir.path_join(SET_JSON_NAME)
			if not FileAccess.file_exists(json_path):
				continue
			var set_def := from_json_file(json_path, pack_root)
			if set_def == null:
				continue
			set_def.pack_slug = pack_name
			sets.append(set_def)
	return sets


## Builds a runtime set from a pack's [code]sticker_set.json[/code].
## [param pack_root] is the pack directory the JSON's relative paths resolve
## against; it defaults to two levels above the file, which is where an installed
## pack always puts it.
static func from_json_file(json_path: String, pack_root: String = "") -> StickerSetDef:
	if not FileAccess.file_exists(json_path):
		push_warning("StickerSetDef: no sticker_set.json at '%s'." % json_path)
		return null
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(json_path)) != OK \
			or typeof(json.data) != TYPE_DICTIONARY:
		push_warning("StickerSetDef: '%s' is not a JSON object (%s)."
			% [json_path, json.get_error_message()])
		return null
	var set_dir := json_path.get_base_dir()
	var root := pack_root if pack_root != "" else set_dir.get_base_dir().get_base_dir()
	var set_def := from_json(json.data, root, set_dir)
	if set_def != null:
		set_def.source_dir = set_dir
	return set_def


## Builds a runtime set from one parsed [code]sticker_sets[][/code] entry
## (DLC_SERVER.md §7.2). Returns null -- with a warning naming what was wrong --
## for anything this client cannot use.
##
## [b]Required[/b]: [code]set_uid[/code], and a non-empty [code]stickers[/code]
## array whose entries each carry [code]sticker_id[/code] and [code]image[/code].
## [b]Optional[/b]: [code]title[/code] (falls back to the uid),
## [code]sort_order[/code], and per sticker [code]title[/code] and [code]anim[/code].
##
## [code]anim[/code] (BL-43) is [code]{hframes, vframes, frames, fps}[/code] and
## makes the sticker's image a SPRITE SHEET. Absent means a still sticker, which is
## every sticker published before BL-43, so a pack written against the older
## contract installs and draws exactly as it did.
##
## An individual sticker whose image is missing is DROPPED, and the set survives --
## unlike a book, which is dropped whole when a page is unusable. A book with a
## hole in it is not a book; a sticker box with seven stickers instead of eight is
## still a sticker box, and losing the whole set would take away every sticker a
## child had already stuck down out of it.
static func from_json(data: Dictionary, pack_root: String, set_dir: String) -> StickerSetDef:
	var uid := String(data.get("set_uid", "")).strip_edges()
	if uid == "":
		push_warning("StickerSetDef: a sticker_set.json in '%s' has no set_uid; skipping it." % set_dir)
		return null
	var raw: Variant = data.get("stickers", [])
	if typeof(raw) != TYPE_ARRAY or (raw as Array).is_empty():
		push_warning("StickerSetDef: set '%s' in '%s' has no stickers; skipping it." % [uid, set_dir])
		return null

	var set_def := StickerSetDef.new()
	set_def.is_runtime = true
	set_def.set_uid = uid
	set_def.display_name = String(data.get("title", uid))
	var order: Variant = data.get("sort_order", 100)
	set_def.sort_order = int(order) if typeof(order) == TYPE_FLOAT or typeof(order) == TYPE_INT else 100

	var seen := {}
	for entry: Variant in (raw as Array):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var sticker_data: Dictionary = entry
		var sticker_id := String(sticker_data.get("sticker_id", "")).strip_edges()
		if sticker_id == "" or seen.has(sticker_id):
			push_warning("StickerSetDef: set '%s' has a sticker with no (or a repeated) id; dropping it." % uid)
			continue
		var sticker := StickerDef.new()
		sticker.is_runtime = true
		sticker.sticker_id = sticker_id
		sticker.display_name = String(sticker_data.get("title", sticker_id))
		sticker.image_path = PageDef.resolve_pack_path(
			String(sticker_data.get("image", "")), pack_root, set_dir
		)
		_apply_anim(sticker, sticker_data.get("anim", null))
		if not sticker.exists():
			push_warning("StickerSetDef: set '%s' sticker '%s' has no image at '%s'; dropping it."
				% [uid, sticker_id, sticker.image_path])
			continue
		seen[sticker_id] = true
		set_def.stickers.append(sticker)

	if set_def.stickers.is_empty():
		push_warning("StickerSetDef: set '%s' in '%s' has no usable stickers; skipping it."
			% [uid, set_dir])
		return null
	return set_def


## Copies a pack entry's [code]anim[/code] block onto [param sticker] (BL-43).
##
## [b]Anything unusable is simply not an animation.[/b] A missing block, a block
## that is not an object, or numbers that do not describe a grid all leave the
## sticker still -- which is the behaviour of every client built before BL-43 and
## therefore the only safe reading of a field this build does not understand.
static func _apply_anim(sticker: StickerDef, raw: Variant) -> void:
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var anim: Dictionary = raw
	sticker.anim_hframes = maxi(int(anim.get("hframes", 1)), 1)
	sticker.anim_vframes = maxi(int(anim.get("vframes", 1)), 1)
	sticker.anim_frames = maxi(int(anim.get("frames", 0)), 0)
	sticker.anim_fps = maxf(float(anim.get("fps", 0.0)), 0.0)


## True for a directory a download is still writing into, or a hidden one. Reads
## [BookDef]'s list rather than keeping a second one: "which pack directories are
## invisible" is one rule, and a set and a book must never disagree about it.
static func _is_ignored_pack(pack_name: String) -> bool:
	if pack_name.begins_with("."):
		return true
	for suffix in BookDef.IGNORED_PACK_SUFFIXES:
		if pack_name.ends_with(suffix):
			return true
	return false


static func _before(a: StickerSetDef, b: StickerSetDef) -> bool:
	if a.sort_order != b.sort_order:
		return a.sort_order < b.sort_order
	return a.display_name < b.display_name


# ================================================================= validation ==

## Human-readable problems with this set; empty means valid.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if set_uid.strip_edges() == "":
		problems.append("set_uid is empty")
	if display_name.strip_edges() == "":
		problems.append("display_name is empty")
	if stickers.is_empty():
		problems.append("stickers is empty")
	var seen := {}
	for i in stickers.size():
		var sticker := stickers[i]
		if sticker == null:
			problems.append("stickers[%d] is null" % i)
			continue
		for problem in sticker.validate():
			problems.append("stickers[%d] (%s): %s" % [i, sticker.sticker_id, problem])
		if seen.has(sticker.sticker_id):
			problems.append("sticker_id '%s' appears twice" % sticker.sticker_id)
		seen[sticker.sticker_id] = true
	return problems


func is_valid() -> bool:
	return validate().is_empty()

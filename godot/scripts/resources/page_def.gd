class_name PageDef
extends Resource
## One coloring page: a display name, the art the player SEES, and the two
## artifacts produced by the mapping pipeline (DESIGN.md 3.1 / 4,
## mapping-pipeline skill).
##
## [b]Display vs mask (BL-9, amended by BL-12).[/b] Every page has a required
## DISPLAY image -- the detailed drawing rendered on top of the paint layer. A
## page may also name an OPTIONAL mask image: separate line art that decides
## where paint may go. When a page has no mask (the test book, and any simple
## page), the display image is its own mapping source and nothing changes.
##
## BL-12 reversed BL-9's "the mask is never loaded" rule: a page's mask is now a
## RUNTIME asset, drawn as a permanent layer between the paint and the display
## art so its outlines stay visible over the paint as region guides. What
## [member mask_image_path] names is therefore the pipeline's shipped
## [code]<page>_mask.png[/code] artifact -- the artist's original resampled to the
## display image's resolution -- and not the print-size original, which still
## lives behind the [code]source/[/code] .gdignore and is recorded only in the
## regions JSON's [code]mask_image[/code] field.
##
## Pure data -- no nodes, no logic beyond validation and small lookups. A screen
## hands the display image and the two artifacts straight to
## [code]PageView.load_page()[/code]; the paths are stored as strings (not as
## preloaded [Texture2D]s) so a book can reference dozens of pages without
## dragging every page's art into memory when the [BookDef] loads.
##
## Instances live in [code]res://resources/books/<book>/pages/page_XX.tres[/code].
## The artifacts themselves are build outputs of the mapping source -- regenerate
## them with [code]tools/generate_region_map.gd[/code], never hand-edit.
##
## [b]WP7: a page can also come from a DLC pack[/b] (DLC_SERVER.md 8.1 item 3).
## Such a page is built in memory by [method BookDef.from_json], carries
## [member is_runtime] and stores ABSOLUTE [code]user://[/code] paths in the very
## same four path fields. The difference is only in HOW those paths are opened: a
## built-in page is a [code]res://[/code] resource and goes through
## [method @GDScript.load]; a runtime page is a plain file on disk and goes through
## [method Image.load_from_file] -> [method ImageTexture.create_from_image], which
## never touches the importer -- so a runtime ID map cannot be VRAM-compressed
## behind our back. Everything downstream ([PageView], the shader, the stroke
## lifecycle) sees a [Texture2D] either way and cannot tell the difference.

## Shown in the UI (page picker, "you are colouring ..."). Not a key: order
## inside [BookDef.pages] is what defines page order.
@export var display_name: String = ""

@export_group("Artifacts")
## The VISIBLE page art, drawn on top of the paint layer. Required.
@export_file("*.png") var display_image_path: String = ""
## OPTIONAL line-masking art: the image the ID map was generated FROM when it is
## not the display image (BL-9), at the display page's resolution. Empty means the
## display image was its own mapping source.
##
## [b]BL-12: this is a runtime asset.[/b] It is rendered under the display image
## (see [PageView]'s layer order), so it must be the pipeline's shipped
## [code]<page>_mask.png[/code] -- next to the ID map, inside the build -- and
## [method validate] REQUIRES it to exist whenever it is set. Pointing it at the
## artist's original under [code]assets/books/<book>/source/[/code] (which carries
## a .gdignore and never imports) was correct under BL-9 and is a failure now.
@export_file("*.png") var mask_image_path: String = ""
## Region ID-map PNG (lossless, id = R<<16|G<<8|B, #000000 = lines/unpaintable).
## Its .import file must keep compress/mode=0, mipmaps/generate=false,
## detect_3d/compress_to=0 and process/fix_alpha_border=false.
@export_file("*.png") var id_map_path: String = ""
## Region polygons JSON (schema v1) -- debug overlay, centroids, areas and the
## coverage sample grids ([CoverageTracker]). Never the paint clip.
@export_file("*.json") var regions_json_path: String = ""

# --------------------------------------------------------------- runtime pages --
# Deliberately NOT exported: an authored .tres must never be able to claim its
# artifacts live outside the build. Only [method from_pack_entry] sets this.

## True when the four paths above are absolute [code]user://[/code] files from an
## installed DLC pack rather than [code]res://[/code] resources.
var is_runtime: bool = false


# =============================================================== path handling ==
# The two things that differ between a built-in page and a pack page, in one place
# each, so no caller has to branch on [member is_runtime] itself.

## Loads [param path] as a texture. A runtime path is decoded from the file
## ([b]never[/b] through the importer, so a runtime ID map is always lossless); a
## built-in path goes through the resource loader exactly as it always did.
##
## Safe to call from a [WorkerThreadPool] task -- it touches no scene tree.
static func load_texture(path: String, runtime: bool) -> Texture2D:
	if path == "":
		return null
	if not runtime:
		return load(path) as Texture2D if ResourceLoader.exists(path) else null
	var image := Image.load_from_file(path)
	if image == null:
		return null
	return ImageTexture.create_from_image(image)


## "Is there a file here", asked the way the matching loader would ask it: an
## exported build ships the imported .ctex rather than the source PNG, so a
## built-in path is probed with [ResourceLoader] and a pack file with [FileAccess].
static func file_exists(path: String, runtime: bool) -> bool:
	if path == "":
		return false
	return FileAccess.file_exists(path) if runtime else ResourceLoader.exists(path)


## Absolute path for one of a pack's relative paths (DLC_SERVER.md 7.2).
##
## Pack paths are PACK-relative -- [code]books/coyote-2026/page_01.png[/code] --
## because [code]book.json[/code] is a copy of a manifest [code]books[][/code]
## entry. An already-absolute path is taken as-is, and a name relative to the book
## directory is accepted too, so a hand-seeded development pack does not have to
## repeat the prefix. When nothing exists the PACK-relative form is returned, so
## [method validate] reports the path the pack was supposed to contain.
static func resolve_pack_path(raw: String, pack_root: String, book_dir: String) -> String:
	var path := raw.strip_edges()
	if path == "":
		return ""
	if path.begins_with("res://") or path.begins_with("user://") or path.is_absolute_path():
		return path
	var candidates: PackedStringArray = [
		pack_root.path_join(path), book_dir.path_join(path), book_dir.path_join(path.get_file())
	]
	for candidate in candidates:
		if FileAccess.file_exists(candidate):
			return candidate
	return candidates[0]


## Builds a runtime page from one [code]pages[][/code] entry of a pack's
## [code]book.json[/code]. Returns null when a required artifact is missing --
## [method BookDef.from_json] then drops the whole book, because a book with a hole
## in the middle of it is not a book.
static func from_pack_entry(
	data: Dictionary, pack_root: String, book_dir: String, fallback_index: int
) -> PageDef:
	var page := PageDef.new()
	page.is_runtime = true
	page.display_name = String(data.get("title", "Page %d" % (fallback_index + 1)))
	page.display_image_path = resolve_pack_path(String(data.get("display", "")), pack_root, book_dir)
	page.id_map_path = resolve_pack_path(String(data.get("idmap", "")), pack_root, book_dir)
	page.regions_json_path = resolve_pack_path(String(data.get("regions", "")), pack_root, book_dir)
	page.mask_image_path = resolve_pack_path(String(data.get("mask", "")), pack_root, book_dir)
	var problems := page.validate()
	if not problems.is_empty():
		push_warning("PageDef: pack page '%s' is unusable: %s" % [page.display_name, problems])
		return null
	return page


# ==================================================================== lookups ==

## The visible page texture. Also the sensible default book cover art, so
## [BookDef] falls back to page 1's display image when no cover is authored.
func load_display_texture() -> Texture2D:
	return load_texture(display_image_path, is_runtime)


## True when this page's regions came from a separate masking image.
func has_mask() -> bool:
	return mask_image_path != ""


## The image the mapping pipeline reads for this page: the mask when there is
## one, the display image otherwise.
func get_mapping_source_path() -> String:
	return mask_image_path if has_mask() else display_image_path


## The mask layer's texture, or null when this page has no mask (BL-12). Drawn
## between the paint layer and the display art.
func load_mask_texture() -> Texture2D:
	return load_texture(mask_image_path, is_runtime)


## The parsed regions JSON, or an empty dictionary when it is missing/broken.
## Dev tooling and tests only -- [PageView] does its own parsing at load time.
func load_regions_json() -> Dictionary:
	if regions_json_path == "" or not FileAccess.file_exists(regions_json_path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(regions_json_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


# ================================================================= validation ==

## Human-readable problems with this page; empty means valid. Mirrors
## [method PaletteDef.validate] -- the smoke tests and any defensive loader call
## it before handing the page to [PageView].
##
## Only what the RUNTIME needs is required: display image, ID map, regions JSON --
## and, since BL-12, the mask WHEN THERE IS ONE. Having a mask is still optional;
## naming one that the build does not ship is not, because it is a layer of the
## page now rather than provenance.
##
## Textures are probed with [ResourceLoader] (an exported build ships the
## imported .ctex, not the source PNG); the JSON is a plain file, so it is probed
## with [FileAccess] exactly the way [PageView] probes it.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if display_name.strip_edges() == "":
		problems.append("display_name is empty")

	if display_image_path == "":
		problems.append("display_image_path is empty")
	elif not file_exists(display_image_path, is_runtime):
		problems.append("display_image_path '%s' does not exist" % display_image_path)

	if id_map_path == "":
		problems.append("id_map_path is empty")
	elif not file_exists(id_map_path, is_runtime):
		problems.append("id_map_path '%s' does not exist" % id_map_path)

	if display_image_path != "" and display_image_path == id_map_path:
		problems.append("id_map_path is the same file as display_image_path")

	if has_mask():
		if not file_exists(mask_image_path, is_runtime):
			problems.append("mask_image_path '%s' does not exist" % mask_image_path)
		if mask_image_path == display_image_path:
			problems.append("mask_image_path is the same file as display_image_path")
		if mask_image_path == id_map_path:
			problems.append("mask_image_path is the same file as id_map_path")

	if regions_json_path == "":
		problems.append("regions_json_path is empty")
	elif not FileAccess.file_exists(regions_json_path):
		problems.append("regions_json_path '%s' does not exist" % regions_json_path)

	return problems


func is_valid() -> bool:
	return validate().is_empty()

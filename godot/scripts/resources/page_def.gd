class_name PageDef
extends Resource
## One coloring page: a display name, the art the player SEES, and the two
## artifacts produced by the mapping pipeline (DESIGN.md 3.1 / 4,
## mapping-pipeline skill).
##
## [b]Display vs mask (BL-9).[/b] Every page has a required DISPLAY image -- the
## detailed drawing rendered on top of the paint layer. A page may also name an
## OPTIONAL mask image: line art that exists only to be fed to the mapping
## pipeline, deciding where paint may go, and which is NEVER rendered. When a
## page has no mask (the test book, and any simple page), the display image is
## its own mapping source. Either way the runtime only ever loads
## [member display_image_path] + [member id_map_path]; the mask is build input
## and provenance, which is why it may live under an untracked
## [code]source/[/code] folder that ships with nothing at all.
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

## Shown in the UI (page picker, "you are colouring ..."). Not a key: order
## inside [BookDef.pages] is what defines page order.
@export var display_name: String = ""

@export_group("Artifacts")
## The VISIBLE page art, drawn on top of the paint layer. Required.
@export_file("*.png") var display_image_path: String = ""
## OPTIONAL line-masking art: the image the ID map was generated FROM when it is
## not the display image (BL-9). Never loaded, never rendered -- painting is
## clipped by [member id_map_path] exactly as it always was. Empty means the
## display image was its own mapping source.
##
## It is deliberately fine for this to point outside the shipped asset set (e.g.
## [code]assets/books/<book>/source/[/code], which carries a .gdignore): the mask
## is ~200 KB of pixels the player never sees, so [method validate] records it as
## provenance rather than requiring it to exist in the build (docs/DLC_SERVER.md
## 7.2).
@export_file("*.png") var mask_image_path: String = ""
## Region ID-map PNG (lossless, id = R<<16|G<<8|B, #000000 = lines/unpaintable).
## Its .import file must keep compress/mode=0, mipmaps/generate=false,
## detect_3d/compress_to=0 and process/fix_alpha_border=false.
@export_file("*.png") var id_map_path: String = ""
## Region polygons JSON (schema v1) -- debug overlay, centroids, areas and the
## coverage sample grids ([CoverageTracker]). Never the paint clip.
@export_file("*.json") var regions_json_path: String = ""


# ==================================================================== lookups ==

## The visible page texture. Also the sensible default book cover art, so
## [BookDef] falls back to page 1's display image when no cover is authored.
func load_display_texture() -> Texture2D:
	if display_image_path == "":
		return null
	return load(display_image_path) as Texture2D


## True when this page's regions came from a separate masking image.
func has_mask() -> bool:
	return mask_image_path != ""


## The image the mapping pipeline reads for this page: the mask when there is
## one, the display image otherwise. Dev tooling only -- nothing at runtime opens
## it (see [method load_display_texture]).
func get_mapping_source_path() -> String:
	return mask_image_path if has_mask() else display_image_path


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
## Only what the RUNTIME needs is required: display image, ID map, regions JSON.
## A mask is optional and is never probed for existence, because a page is
## perfectly playable in a build that shipped none of the artist's source art.
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
	elif not ResourceLoader.exists(display_image_path):
		problems.append("display_image_path '%s' does not exist" % display_image_path)

	if id_map_path == "":
		problems.append("id_map_path is empty")
	elif not ResourceLoader.exists(id_map_path):
		problems.append("id_map_path '%s' does not exist" % id_map_path)

	if display_image_path != "" and display_image_path == id_map_path:
		problems.append("id_map_path is the same file as display_image_path")

	if has_mask() and mask_image_path == display_image_path:
		problems.append("mask_image_path is the same file as display_image_path")
	if has_mask() and mask_image_path == id_map_path:
		problems.append("mask_image_path is the same file as id_map_path")

	if regions_json_path == "":
		problems.append("regions_json_path is empty")
	elif not FileAccess.file_exists(regions_json_path):
		problems.append("regions_json_path '%s' does not exist" % regions_json_path)

	return problems


func is_valid() -> bool:
	return validate().is_empty()

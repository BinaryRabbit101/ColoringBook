class_name PageDef
extends Resource
## One coloring page: a display name plus the three per-page artifacts produced
## by the mapping pipeline (DESIGN.md 3.1 / 4, mapping-pipeline skill).
##
## Pure data -- no nodes, no logic beyond validation and small lookups. A screen
## hands the three paths straight to [code]PageView.load_page()[/code]; the paths
## are stored as strings (not as preloaded [Texture2D]s) so a book can reference
## dozens of pages without dragging every page's art into memory when the
## [BookDef] loads.
##
## Instances live in [code]res://resources/books/<book>/pages/page_XX.tres[/code].
## The artifacts themselves are build outputs of the source PNG -- regenerate
## them with [code]tools/generate_region_map.gd[/code], never hand-edit.

## Shown in the UI (page picker, "you are colouring ..."). Not a key: order
## inside [BookDef.pages] is what defines page order.
@export var display_name: String = ""

@export_group("Artifacts")
## Line-art PNG drawn on top of the paint layer.
@export_file("*.png") var base_image_path: String = ""
## Region ID-map PNG (lossless, id = R<<16|G<<8|B, #000000 = lines/unpaintable).
## Its .import file must keep compress/mode=0, mipmaps/generate=false,
## detect_3d/compress_to=0 and process/fix_alpha_border=false.
@export_file("*.png") var id_map_path: String = ""
## Region polygons JSON (schema v1) -- debug overlay, centroids, areas and the
## coverage sample grids ([CoverageTracker]). Never the paint clip.
@export_file("*.json") var regions_json_path: String = ""


# ==================================================================== lookups ==

## The line-art texture. Also the sensible default book cover art, so [BookDef]
## falls back to page 1's base image when no cover is authored.
func load_base_texture() -> Texture2D:
	if base_image_path == "":
		return null
	return load(base_image_path) as Texture2D


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
## Textures are probed with [ResourceLoader] (an exported build ships the
## imported .ctex, not the source PNG); the JSON is a plain file, so it is probed
## with [FileAccess] exactly the way [PageView] probes it.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if display_name.strip_edges() == "":
		problems.append("display_name is empty")

	if base_image_path == "":
		problems.append("base_image_path is empty")
	elif not ResourceLoader.exists(base_image_path):
		problems.append("base_image_path '%s' does not exist" % base_image_path)

	if id_map_path == "":
		problems.append("id_map_path is empty")
	elif not ResourceLoader.exists(id_map_path):
		problems.append("id_map_path '%s' does not exist" % id_map_path)

	if base_image_path != "" and base_image_path == id_map_path:
		problems.append("id_map_path is the same file as base_image_path")

	if regions_json_path == "":
		problems.append("regions_json_path is empty")
	elif not FileAccess.file_exists(regions_json_path):
		problems.append("regions_json_path '%s' does not exist" % regions_json_path)

	return problems


func is_valid() -> bool:
	return validate().is_empty()

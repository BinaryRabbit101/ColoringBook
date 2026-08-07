class_name CrayonSetDef
extends Resource
## One authored box of crayons (BACKLOG BL-23, DESIGN.md 1) -- Pastel, Neon,
## Earth, Candy, Spooky, and whatever comes next.
##
## [b]Colours and nothing else.[/b] A crayon set replaces what the strip offers and
## changes not one other thing about the game: the brush diameter, the hardness and
## the completion threshold all stay on the [PaletteDef], because they are how the
## game PLAYS and a box of crayons is only how it looks. That is also why the
## intensity ladder (BL-22) works on every set for free -- it is computed from a
## base colour by [method PaletteDef.shade_of], so a set that ships nothing but
## colours still ships a light-to-dark range for each of them.
##
## [b]Sets are DISCOVERED, never listed[/b], exactly like books
## ([method BookDef.discover]): dropping a [code].tres[/code] into
## [constant SETS_ROOT] ships a new box. [member sort_order] decides where it lands
## in the cycle, so the authored order does not depend on filenames.
##
## The default box is NOT one of these -- it is the [PaletteDef]'s own
## [member PaletteDef.colors], and [method PaletteDef.get_crayon_set_colors]
## presents both through one index.

## Where authored sets live. Scanned by [method discover].
const SETS_ROOT := "res://resources/palettes/sets"

## Shown on the crayon-box control. Kept short -- it sits on a 92 px tile.
@export var display_name: String = ""

## Where this box sits in the cycle, low first. Ties break on
## [member display_name], so two sets can never swap places between runs.
@export var sort_order: int = 100

## The crayons, in strip order. Any count the strip can scroll; the shipped sets
## carry the same ten the default box does.
@export var colors: PackedColorArray = PackedColorArray()


# ==================================================================== lookups ==

func color_count() -> int:
	return colors.size()


## Colour at [param index], clamped. [code]Color.MAGENTA[/code] for an empty set
## (loud on purpose -- an empty set is authoring error).
func get_color(index: int) -> Color:
	if colors.is_empty():
		return Color.MAGENTA
	return colors[clampi(index, 0, colors.size() - 1)]


# ================================================================== discovery ==

## Every authored set under [param root], in cycle order.
##
## Scanning rather than preloading is the same rule books follow: adding a box is
## adding a file. [DirAccess] lists [code]res://[/code] in exported builds too (the
## PCK keeps a directory index) and [ResourceLoader.exists] resolves import
## remaps, so this behaves identically in the editor and in a packaged game.
## Files that are not [CrayonSetDef]s are skipped silently.
static func discover(root: String = SETS_ROOT) -> Array[CrayonSetDef]:
	var sets: Array[CrayonSetDef] = []
	if not DirAccess.dir_exists_absolute(root):
		return sets
	var names := Array(DirAccess.get_files_at(root))
	names.sort()
	for file_name: String in names:
		# Exported builds see "<name>.tres.remap"; strip it back to the resource.
		var trimmed := file_name.trim_suffix(".remap")
		if not trimmed.ends_with(".tres") and not trimmed.ends_with(".res"):
			continue
		var path := root.path_join(trimmed)
		if not ResourceLoader.exists(path):
			continue
		var set_def := load(path) as CrayonSetDef
		if set_def != null:
			sets.append(set_def)
	sets.sort_custom(_before)
	return sets


static func _before(a: CrayonSetDef, b: CrayonSetDef) -> bool:
	if a.sort_order != b.sort_order:
		return a.sort_order < b.sort_order
	return a.display_name < b.display_name


# ================================================================= validation ==

## Human-readable problems with this set; empty means valid.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if display_name.strip_edges() == "":
		problems.append("display_name is empty")
	if colors.size() < 1:
		problems.append("colors is empty")
	for i in colors.size():
		if colors[i].a <= 0.0:
			problems.append("colors[%d] is fully transparent" % i)
	return problems


func is_valid() -> bool:
	return validate().is_empty()

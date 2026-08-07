class_name CrayonSetDef
extends Resource
## One authored box of crayons (BACKLOG BL-23, reshaped by BL-35; DESIGN.md 1) --
## Neon Glow, Textured Wax, Glitter, and whatever tops those.
##
## [b]Colours and a FINISH, and nothing else.[/b] BL-23 said "colours and nothing
## else"; BL-35 amends that by exactly one field, [member effect], and the reason is
## the line the rule was drawn to protect: a finish is how the paint LOOKS, never
## how the game PLAYS. The brush diameter, the hardness and the completion threshold
## are still forbidden here and still live on the [PaletteDef] -- a box that could
## move those would be a difficulty mode wearing a hat, which is the thing BL-20
## deleted. A box that glows is a box of magic crayons.
##
## [b]Every box carries the same lineup[/b] (BL-35). The playtest verdict on the
## first five sets was "more colour options, not more fun": recolours of the same
## ten crayons read as washed out next to the default box. So a set now leaves
## [member colors] EMPTY and inherits the palette's own crayons, and what makes it a
## different box is the finish it paints them with -- each one louder than the one
## before it. Authoring colours is still allowed (the field is honoured) but nothing
## shipped does it.
##
## The intensity ladder (BL-22) works on every set for free -- it is computed from a
## base colour by [method PaletteDef.shade_of], so a box that ships nothing but a
## finish still ships a light-to-dark range for every crayon in it, in that finish.
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

## The crayons, in strip order. [b]Empty means "the palette's own lineup"[/b]
## (BL-35), which is what every shipped box does: the boxes differ in their finish,
## not their colours, and inheriting is what stops the lineups drifting apart in
## five files. Authoring a list here still works and still replaces the strip.
@export var colors: PackedColorArray = PackedColorArray()

## How this box's paint LOOKS: a [BrushFinish] id -- [constant BrushFinish.CLASSIC],
## [constant BrushFinish.GLOW], [constant BrushFinish.GRAIN],
## [constant BrushFinish.GLITTER] (BL-35).
##
## This is the one field BL-35 added to BL-23's "colours and nothing else", and the
## boundary it must not cross is written into the rule it amends: a finish changes
## the pixels a stroke lays down, never the brush, the hardness, the threshold or
## anything else about how the game plays. It reaches the paint path as an explicit
## palette signal ([code]PaletteChild.brush_effect_picked[/code]) and is baked into
## the stamp by [code]brush.gdshader[/code], so the saved PNG carries it and no
## other system has to know it happened. An unknown id paints classic wax.
@export var effect: StringName = BrushFinish.CLASSIC


# ==================================================================== lookups ==

## True when this box authored its own crayons instead of inheriting the palette's
## lineup (BL-35). Nothing shipped does.
func has_own_colors() -> bool:
	return not colors.is_empty()


## The finish this box paints with, resolved -- an unknown or unset id comes back as
## [constant BrushFinish.CLASSIC] rather than as nothing.
func get_effect() -> StringName:
	return BrushFinish.resolve(effect)


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
	# An empty colour list is NOT a problem since BL-35: it means "the palette's own
	# lineup", which is what every shipped box wants.
	if not BrushFinish.is_known(effect):
		problems.append("effect '%s' is not a finish this build can paint" % effect)
	for i in colors.size():
		if colors[i].a <= 0.0:
			problems.append("colors[%d] is fully transparent" % i)
	return problems


func is_valid() -> bool:
	return validate().is_empty()

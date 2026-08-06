class_name PaletteDef
extends Resource
## Authored palette + brush configuration for one difficulty mode (DESIGN.md 1, 3.4).
##
## Pure data: no nodes, no logic beyond validation and small lookups. The palette
## UI components ([code]palette_child.tscn[/code] / [code]palette_adult.tscn[/code])
## are handed one of these via [code]set_palette()[/code] and build themselves from
## it; the coloring screen reads [member default_brush_size] /
## [member default_brush_hardness] to prime [code]PageView[/code], and M4 reads
## [member completion_threshold] for coverage.
##
## Instances live in [code]res://resources/palettes/*.tres[/code]. Never hardcode
## colours or sizes in scripts.

## Mode id for a child palette.
const MODE_CHILD := "child"
## Mode id for an adult palette.
const MODE_ADULT := "adult"

## Shown in settings / mode select. Not a gameplay key -- [member mode] is.
@export var display_name: String = ""

## Which difficulty mode this palette belongs to: "child" or "adult".
## GameState maps mode -> palette with this, so it must match the file it lives in.
@export_enum("child", "adult") var mode: String = MODE_CHILD

@export_group("Colours")
## Every colour offered, in display order. Child: 8-12 bold, well-separated hues.
## Adult: hue families laid out consecutively, [member shades_per_family] entries
## each (light -> dark), so the swatch grid can group them without extra data.
@export var colors: PackedColorArray = PackedColorArray()

## How many consecutive entries of [member colors] form one shade family, for the
## adult grid's column grouping. 1 (or anything that does not divide the colour
## count) means "no grouping" -- the UI then falls back to a single flat run.
@export_range(1, 16, 1) var shades_per_family: int = 1

@export_group("Brush")
## Brush DIAMETERS in page pixels, ascending. PageView.brush_size is a DIAMETER,
## so these go straight into it with no conversion. Child ships one forgiving
## size; adult ships three.
@export var brush_sizes: PackedFloat32Array = PackedFloat32Array()

## Diameter (page px) selected before the player touches the size control. Should
## be one of [member brush_sizes]; [method get_default_brush_size_index] snaps to
## the nearest entry if it is not.
@export_range(2.0, 512.0, 0.5) var default_brush_size: float = 56.0

## Feathering of the brush dab, 0 = fully soft, 1 = hard. Never affects the
## region clip (that is always hard-edged, see brush.gdshader).
@export_range(0.0, 1.0, 0.01) var default_brush_hardness: float = 0.85

@export_group("Completion")
## Fraction of a region's pixels that must be painted for it to count as done
## (DESIGN.md 1 "Completion", coloring-mechanics "Coverage & completion").
## Read by M4's coverage tracker -- exported here so the value is authored data,
## never a constant in code.
##
## Shipped values (BL-5 tightened both): child [b]0.90[/b] (forgiving -- the
## player may leave a fringe of paper, but not a patch of it), adult [b]0.96[/b]
## (strict -- near-complete fill required). Must be in (0, 1]; child must be lower
## than adult, and both must clear
## [constant CoverageTracker.MIN_REGION_THRESHOLD], which the tracker clamps
## against so no authored value can make a blank-looking page "complete".
@export_range(0.05, 1.0, 0.01) var completion_threshold: float = 0.9


# ==================================================================== lookups ==

func color_count() -> int:
	return colors.size()


## Colour at [param index], clamped to the palette. [code]Color.MAGENTA[/code]
## for an empty palette (loud on purpose -- an empty palette is authoring error).
func get_color(index: int) -> Color:
	if colors.is_empty():
		return Color.MAGENTA
	return colors[clampi(index, 0, colors.size() - 1)]


func brush_size_count() -> int:
	return brush_sizes.size()


## Brush diameter at [param index], clamped. Falls back to
## [member default_brush_size] when no sizes are authored.
func get_brush_size(index: int) -> float:
	if brush_sizes.is_empty():
		return default_brush_size
	return brush_sizes[clampi(index, 0, brush_sizes.size() - 1)]


## Index into [member brush_sizes] of the entry nearest [member default_brush_size].
## 0 when no sizes are authored.
func get_default_brush_size_index() -> int:
	var best := 0
	var best_distance := INF
	for i in brush_sizes.size():
		var distance := absf(brush_sizes[i] - default_brush_size)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


## How many colours each shade family actually holds, after sanity-checking
## [member shades_per_family] against the colour count. 1 = ungrouped.
func effective_shades_per_family() -> int:
	if shades_per_family <= 1 or colors.is_empty():
		return 1
	if colors.size() % shades_per_family != 0:
		return 1
	return shades_per_family


## Number of shade families, i.e. columns of the adult grid. Ungrouped palettes
## report one family per colour, so the grid degrades to a single row of columns.
func family_count() -> int:
	if colors.is_empty():
		return 0
	@warning_ignore("integer_division")
	var count := colors.size() / effective_shades_per_family()
	return count


## The colours of one shade family (a column of the adult grid), light -> dark.
func get_family(family_index: int) -> PackedColorArray:
	var families := family_count()
	if families <= 0:
		return PackedColorArray()
	var per_family := effective_shades_per_family()
	var start := clampi(family_index, 0, families - 1) * per_family
	return colors.slice(start, start + per_family)


# ================================================================= validation ==

## Human-readable problems with this palette; empty means valid. Used by the
## palette smoke test and by anything that loads authored data defensively.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if display_name.strip_edges() == "":
		problems.append("display_name is empty")
	if mode != MODE_CHILD and mode != MODE_ADULT:
		problems.append("mode '%s' is neither '%s' nor '%s'" % [mode, MODE_CHILD, MODE_ADULT])
	if colors.size() < 1:
		problems.append("colors is empty")
	for i in colors.size():
		if colors[i].a <= 0.0:
			problems.append("colors[%d] is fully transparent" % i)
	if brush_sizes.is_empty():
		problems.append("brush_sizes is empty")
	for i in brush_sizes.size():
		if brush_sizes[i] <= 0.0:
			problems.append("brush_sizes[%d] (%.2f) is not positive" % [i, brush_sizes[i]])
		if i > 0 and brush_sizes[i] <= brush_sizes[i - 1]:
			problems.append("brush_sizes[%d] does not ascend" % i)
	if default_brush_size <= 0.0:
		problems.append("default_brush_size (%.2f) is not positive" % default_brush_size)
	if not brush_sizes.is_empty() and not is_equal_approx(get_brush_size(get_default_brush_size_index()), default_brush_size):
		problems.append("default_brush_size %.2f is not one of brush_sizes %s" % [default_brush_size, brush_sizes])
	if default_brush_hardness < 0.0 or default_brush_hardness > 1.0:
		problems.append("default_brush_hardness (%.2f) is outside [0, 1]" % default_brush_hardness)
	if completion_threshold <= 0.0 or completion_threshold > 1.0:
		problems.append("completion_threshold (%.2f) is outside (0, 1]" % completion_threshold)
	elif completion_threshold < CoverageTracker.MIN_REGION_THRESHOLD:
		# The tracker would clamp it anyway; say so here rather than let a palette
		# claim a bar the game will not honour (BL-5).
		problems.append(
			"completion_threshold (%.2f) is below the %.2f floor the coverage tracker enforces"
			% [completion_threshold, CoverageTracker.MIN_REGION_THRESHOLD]
		)
	if shades_per_family > 1 and colors.size() % shades_per_family != 0:
		problems.append(
			"shades_per_family %d does not divide %d colours" % [shades_per_family, colors.size()]
		)
	return problems


func is_valid() -> bool:
	return validate().is_empty()

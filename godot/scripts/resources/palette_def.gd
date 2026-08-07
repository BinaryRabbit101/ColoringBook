class_name PaletteDef
extends Resource
## Authored palette + brush configuration for the game's one palette
## (DESIGN.md 1, 3.4).
##
## Pure data: no nodes, no logic beyond validation and small lookups. The palette
## UI component ([code]palette_child.tscn[/code] -- the crayon row) is handed one
## of these via [code]set_palette()[/code] and builds itself from it; the coloring
## screen reads [member default_brush_size] / [member default_brush_hardness] to
## prime [code]PageView[/code] and [member completion_threshold] for coverage.
##
## [b]BL-20 removed the Child/Adult split[/b]. There is exactly one palette --
## [code]res://resources/palettes/child_palette.tres[/code], the crayon box -- so
## this resource no longer carries a mode id, and the adult grid's
## [code]shades_per_family[/code] grouping went with the swatch grid that read it.
## What is left is what the crayon row actually uses.
##
## [b]The intensity ladder (BL-22) lives here but is not authored[/b] -- see
## [method shade_of]. It is a pure function of a base colour, so every crayon of
## every [CrayonSetDef] gets its light-to-dark range for free and no set can ever
## be missing one.
##
## Instances live in [code]res://resources/palettes/*.tres[/code]. Never hardcode
## colours or sizes in scripts.

## Shown in settings. Not a gameplay key.
@export var display_name: String = ""

@export_group("Colours")
## Every colour offered, in display order: 8-12 bold, well-separated hues.
##
## This is the DEFAULT crayon box, and the one anything outside the palette strip
## uses when it wants "the game's colours" (the title screen, the boot splash, the
## confetti). Additional authored boxes are [CrayonSetDef] resources (BL-23) which
## replace this list on the strip and nothing else -- the brush and the threshold
## below always come from here.
@export var colors: PackedColorArray = PackedColorArray()

@export_group("Brush")
## Brush DIAMETERS in page pixels, ascending. PageView.brush_size is a DIAMETER,
## so these go straight into it with no conversion. The crayon row ships exactly
## one forgiving size (BL-20 deleted the size slider along with the adult palette).
@export var brush_sizes: PackedFloat32Array = PackedFloat32Array()

## Diameter (page px) selected before anything else happens. Should be one of
## [member brush_sizes]; [method get_default_brush_size_index] snaps to the
## nearest entry if it is not.
@export_range(2.0, 512.0, 0.5) var default_brush_size: float = 56.0

## Feathering of the brush dab, 0 = fully soft, 1 = hard. Never affects the
## region clip (that is always hard-edged, see brush.gdshader).
@export_range(0.0, 1.0, 0.01) var default_brush_hardness: float = 0.85

@export_group("Completion")
## Fraction of a region's pixels that must be painted for it to count as done
## (DESIGN.md 1 "Completion", coloring-mechanics "Coverage & completion").
## Read by the coverage tracker -- exported here so the value is authored data,
## never a constant in code.
##
## Shipped value: [b]0.90[/b] (BL-5's forgiving child number, kept as THE
## threshold by BL-20 -- the player may leave a fringe of paper, but not a patch
## of it). Must be in (0, 1] and must clear
## [constant CoverageTracker.MIN_REGION_THRESHOLD], which the tracker clamps
## against so no authored value can make a blank-looking page "complete".
@export_range(0.05, 1.0, 0.01) var completion_threshold: float = 0.9

## Rungs on the intensity ladder (BL-22): pale tint at 0, deep shade at the top.
## Seven is enough that neighbouring rungs are clearly different and few enough
## that the whole ladder fits the crayon strip without scrolling.
const INTENSITY_STEPS := 7
## The rung that IS the crayon's own colour. Picking a new crayon always comes
## back here (DESIGN.md 1: "picking a new base color resets intensity to the
## full/middle step"), so a child who never touches the ladder never notices it.
const INTENSITY_BASE_STEP := 3
## How pale the palest rung gets, and how deep the deepest -- as the [param amount]
## handed to [method Color.lightened] / [method Color.darkened]. Tuned so rung 0
## still reads as the same colour rather than as white, and rung 6 still reads as
## a colour rather than as black.
const MAX_TINT := 0.72
const MAX_SHADE := 0.60


# ======================================================== crayon sets (BL-23) ==
# One index covers both kinds of box: 0 is this palette's own [member colors] --
# the default crayon box, which is authored HERE because everything outside the
# strip reads it -- and 1..n are the [CrayonSetDef]s discovered on disk, in their
# authored cycle order. Callers never have to know which is which.
#
# BL-35 made the boxes differ in FINISH rather than in colour: every box offers the
# same lineup (the sets inherit it), and box i paints it with
# [method get_crayon_set_effect]'s finish -- classic wax, then glow, then grain,
# then glitter, each louder than the last.
#
# Sets are cached after the first look: they are immutable authored data, and the
# strip asks for them every time it cycles.

## Discovered sets, or null before the first lookup. Cleared by
## [method reload_crayon_sets].
var _sets: Array[CrayonSetDef] = []
var _sets_loaded := false


## The authored extra boxes, in cycle order (the default box is not among them).
func crayon_sets() -> Array[CrayonSetDef]:
	if not _sets_loaded:
		_sets = CrayonSetDef.discover()
		_sets_loaded = true
	return _sets


## How many boxes the strip can cycle through: the default one plus every
## discovered set.
func crayon_set_count() -> int:
	return 1 + crayon_sets().size()


## Cycle index wrapped into range, so "next box" is one line at every call site.
func wrap_crayon_set(index: int) -> int:
	return wrapi(index, 0, crayon_set_count())


func get_crayon_set_name(index: int) -> String:
	var wrapped := wrap_crayon_set(index)
	if wrapped == 0:
		return display_name
	return crayon_sets()[wrapped - 1].display_name


## The colours box [param index] puts on the strip.
##
## [b]Normally the same ten every time[/b] (BL-35): a set that authors no colours of
## its own inherits this palette's lineup, because the boxes differ in their FINISH
## and a lineup copied into five files is a lineup that drifts.
func get_crayon_set_colors(index: int) -> PackedColorArray:
	var wrapped := wrap_crayon_set(index)
	if wrapped == 0:
		return colors
	var set_def := crayon_sets()[wrapped - 1]
	return set_def.colors if set_def.has_own_colors() else colors


## The FINISH box [param index] paints with (BL-35). The default box is plain wax;
## every authored set names its own.
func get_crayon_set_effect(index: int) -> StringName:
	var wrapped := wrap_crayon_set(index)
	if wrapped == 0:
		return BrushFinish.CLASSIC
	return crayon_sets()[wrapped - 1].get_effect()


## Drops the discovered sets so an edited or newly added .tres is picked up.
## Dev/tests only -- the shipped game discovers once and never changes.
func reload_crayon_sets() -> void:
	_sets = []
	_sets_loaded = false


# ========================================================= intensity (BL-22) ==

## [param base] at rung [param step] of the intensity ladder, [b]computed[/b].
##
## The ladder is deliberately derived rather than authored: a per-colour table
## would be nine more numbers to get wrong for every crayon of every set, and a
## new set would ship without one. Below [constant INTENSITY_BASE_STEP] the colour
## is lightened towards paper, above it darkened towards ink, linearly across each
## half so the two ends are reached exactly at rungs 0 and
## [code]INTENSITY_STEPS - 1[/code]. Alpha is carried through untouched.
func shade_of(base: Color, step: int) -> Color:
	var rung := clampi(step, 0, INTENSITY_STEPS - 1)
	if rung == INTENSITY_BASE_STEP:
		return base
	if rung < INTENSITY_BASE_STEP:
		var tint := float(INTENSITY_BASE_STEP - rung) / float(INTENSITY_BASE_STEP)
		return base.lightened(MAX_TINT * tint)
	var deepest := float(INTENSITY_STEPS - 1 - INTENSITY_BASE_STEP)
	var shade := float(rung - INTENSITY_BASE_STEP) / deepest
	return base.darkened(MAX_SHADE * shade)


## The whole ladder for [param base], pale first. What the crayon strip renders
## when it is showing intensities.
func shades_of(base: Color) -> PackedColorArray:
	var out := PackedColorArray()
	for step in INTENSITY_STEPS:
		out.append(shade_of(base, step))
	return out


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


# ================================================================= validation ==

## Human-readable problems with this palette; empty means valid. Used by the
## palette smoke test and by anything that loads authored data defensively.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if display_name.strip_edges() == "":
		problems.append("display_name is empty")
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
	return problems


func is_valid() -> bool:
	return validate().is_empty()

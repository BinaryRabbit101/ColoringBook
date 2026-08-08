class_name BrushFinish
extends RefCounted
## The FINISH a crayon box paints with (BACKLOG BL-35) -- the one table that names
## the finishes, their shader modes and their parameters.
##
## [b]A finish is how the paint LOOKS, never how the game PLAYS.[/b] That is the
## whole of BL-35's conscious amendment to BL-23's "a crayon set carries colours and
## nothing else": a [CrayonSetDef] may now name a finish, because a glow or a grain
## changes the pixels a stroke lays down and changes nothing about the mechanic.
## The brush DIAMETER, the HARDNESS and the COMPLETION THRESHOLD are still forbidden
## on a set and still live on the [PaletteDef] -- a box that could move those would
## be a difficulty mode wearing a hat, which is the thing BL-20 deleted.
##
## [b]Phase 1 (BL-35) was BAKEABLE finishes only[/b]: computed inside
## [code]brush.gdshader[/code] at stamp time, flattened into the paint SubViewport
## with the stroke, carried into the saved PNG for free.
##
## [b]Phase 2 (BL-38) added ANIMATED finishes[/b] -- wax that keeps moving after the
## stroke is down -- and [method is_animated] is the seam it arrived through. An
## animated finish still bakes a base into the paint layer (so the page reads right
## with the animation frozen, and so coverage sees exactly what it always saw), and
## additionally stamps a payload into the [b]effect mask[/b]: a second SubViewport
## rendered beside the paint one, region-clipped by the very same shader, sampled by
## [code]paint_display.gdshader[/code] which animates only where the mask says so.
## [method mask_payload] is what a stamp writes there. See BACKLOG_ARCHIVE BL-38 for
## why that beat persisting per-stroke recipes.
##
## [b]Why the effects are functions of PAGE POSITION, not of the dab.[/b] A stroke
## overlaps its own dabs by ~87% ([constant PageView.STAMP_SPACING_RATIO]), so an
## effect that varied per dab would be re-blended eight times over at every pixel
## and average itself flat -- a grain would fill in, a sparkle would smear. A field
## sampled in page space is IDEMPOTENT under that overlap: every dab that covers a
## pixel computes the same value for it, so the eighth dab lays down exactly what
## the first one did. It is also what makes a replay pixel-exact, because the field
## does not depend on the order the dabs arrived in.
##
## [b]The seed[/b] is per STROKE, chosen at press from the press point
## ([method seed_for]) and carried in the BL-17 recipe, so a rebuild re-stamps the
## same grain and the same sparkles. It is what lets each stroke have its own
## crayon-grain angle without the field having to know which dab it is in.

# ------------------------------------------------------------------ the ladder --
# Each box stands out more than the one before it. Ids are StringNames because they
# are authored into .tres files and compared on every stamp.

## Box 1, the default box: today's flat wax. The shader's fast path.
const CLASSIC := &"classic"
## Box 2: the stroke BLOOMS -- a hot saturated core inside a soft halo of its own
## colour, spreading past the dab and clipped by the region like everything else.
const GLOW := &"glow"
## Box 3: visible crayon grain -- stretched streaks of lighter and darker wax at
## the stroke's own angle, as if the paper had a tooth.
const GRAIN := &"grain"
## Box 4: glitter. Grain's tooth, plus a hue that drifts across the page in slow
## rainbow bands, plus bright specks of glitter caught in the wax. The loudest of
## the BAKEABLE finishes, and the last box that stops moving when the stroke does.
const GLITTER := &"glitter"
## Box 5, and the first ANIMATED one (BL-38): satin wax with a sheen that travels
## across the page, over and over. Baked base plus [member mask_sheen] in the effect
## mask's red channel.
const SHIMMER := &"shimmer"
## Box 6, the loudest box in the game: glitter that actually sparkles. Baked glitter
## base plus [member mask_spark] in the effect mask's green channel, which the
## display shader turns into specks that wink in and out.
const TWINKLE := &"twinkle"

## Shader [code]effect_mode[/code] values. Kept next to the ids so the two cannot
## drift; the shader has the same numbers in its own comments.
const MODE_CLASSIC := 0
const MODE_GLOW := 1
const MODE_GRAIN := 2
const MODE_GLITTER := 3
const MODE_SHIMMER := 4
const MODE_TWINKLE := 5

## id -> { mode, quad_scale, strength, display_name, animated, sheen, spark }.
##
## [code]quad_scale[/code] is how much bigger than the dab the stamp QUAD is drawn:
## 1.0 for a finish that stays inside the brush, more for one that spills (the glow
## halo). The shader divides back out, so a dab radius still means the same thing at
## every scale and only the halo gets the extra room.
##
## [code]sheen[/code] / [code]spark[/code] (BL-38) are the EFFECT MASK payload: the
## red and green a stamp of this finish writes into the mask layer, i.e. how much
## travelling sheen and how much winking glitter the display shader gives that wax
## afterwards. Zero for every bakeable finish -- which is exactly why painting
## classic wax over a shimmer stroke takes the shimmer off again: the classic stamp
## writes zeros into the same mask, through the same blend, at the same coverage.
const FINISHES := {
	CLASSIC: {
		"mode": MODE_CLASSIC,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Classic wax",
		"animated": false,
		"sheen": 0.0,
		"spark": 0.0,
	},
	GLOW: {
		"mode": MODE_GLOW,
		# The halo reaches the quad's edge, so this IS the bloom radius.
		"quad_scale": 2.1,
		"strength": 1.0,
		"display_name": "Neon glow",
		"animated": false,
		"sheen": 0.0,
		"spark": 0.0,
	},
	GRAIN: {
		"mode": MODE_GRAIN,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Textured wax",
		"animated": false,
		"sheen": 0.0,
		"spark": 0.0,
	},
	GLITTER: {
		"mode": MODE_GLITTER,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Glitter",
		"animated": false,
		"sheen": 0.0,
		"spark": 0.0,
	},
	SHIMMER: {
		"mode": MODE_SHIMMER,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Shimmer",
		"animated": true,
		"sheen": 1.0,
		"spark": 0.0,
	},
	TWINKLE: {
		"mode": MODE_TWINKLE,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Twinkle",
		"animated": true,
		# The twinkle box carries a little sheen as well: its specks wink over wax
		# that is itself alive, which is what makes it the LOUDER of the two.
		"sheen": 0.35,
		"spark": 1.0,
	},
}

## The finishes in ladder order, dullest first. What an authoring tool would offer
## and what the smoke walks. BL-38's two ANIMATED finishes top it -- a box that
## keeps moving is louder than any box that stops.
const LADDER: Array[StringName] = [CLASSIC, GLOW, GRAIN, GLITTER, SHIMMER, TWINKLE]


## True when [param id] names a finish this build knows how to paint.
static func is_known(id: StringName) -> bool:
	return FINISHES.has(id)


## [param id] if it is known, [constant CLASSIC] otherwise. Every entry point
## resolves through here, so an authored typo paints plain wax instead of nothing.
static func resolve(id: StringName) -> StringName:
	return id if FINISHES.has(id) else CLASSIC


## Shader parameters for [param id], WITHOUT a seed: { mode, quad_scale, strength,
## sheen, spark }. [PageView] adds the per-stroke seed before handing this to
## [PaintCanvas]. The last two are BL-38's effect-mask payload and are read only by
## the mask pass -- the wax pass ignores them, which is why adding them changed no
## pixel of the four bakeable finishes.
static func params_for(id: StringName) -> Dictionary:
	var entry: Dictionary = FINISHES[resolve(id)]
	return {
		"mode": int(entry["mode"]),
		"quad_scale": float(entry["quad_scale"]),
		"strength": float(entry["strength"]),
		"sheen": float(entry["sheen"]),
		"spark": float(entry["spark"]),
	}


## How much bigger than the dab a stamp of [param id] is drawn.
static func quad_scale(id: StringName) -> float:
	return float((FINISHES[resolve(id)] as Dictionary)["quad_scale"])


## Human-readable name, for tooltips and for anything that has to say which box
## this is.
static func display_name(id: StringName) -> String:
	return String((FINISHES[resolve(id)] as Dictionary)["display_name"])


## Whether [param id] needs to keep MOVING after the stroke is down.
##
## False for every BL-35 finish, true for BL-38's [constant SHIMMER] and
## [constant TWINKLE]. This is the ONE thing the painting stack branches on: a page
## that has never held an animated finish never allocates the effect mask, never
## renders a second SubViewport and never writes a second PNG, so the four bakeable
## boxes cost exactly what they cost before phase 2 existed.
static func is_animated(id: StringName) -> bool:
	return bool((FINISHES[resolve(id)] as Dictionary)["animated"])


## The effect-mask payload a stamp of [param id] writes (BL-38): red = travelling
## sheen, green = winking specks, blue is the per-stroke phase and is filled in by
## the caller from the stroke's seed. Alpha is the dab's own coverage and comes from
## the shader, not from here.
##
## [b]Every finish has one, including the bakeable ones[/b], and theirs is zero. A
## mask entry is not "this stroke is animated", it is "this is how alive this wax
## is NOW" -- so ordinary wax painted over a shimmer erases the shimmer through the
## same blend that laid it down, with no bookkeeping anywhere.
static func mask_payload(id: StringName, phase: float = 0.0) -> Color:
	var entry: Dictionary = FINISHES[resolve(id)]
	return Color(float(entry["sheen"]), float(entry["spark"]), clampf(phase, 0.0, 1.0), 1.0)


## The animated finishes, in ladder order. Empty would mean phase 2 was reverted.
static func animated_finishes() -> Array[StringName]:
	var animated: Array[StringName] = []
	for id in LADDER:
		if is_animated(id):
			animated.append(id)
	return animated


## The per-stroke animation PHASE, in [code][0, 1)[/code], derived from the seed a
## stroke was already given ([method seed_for]).
##
## Deriving rather than storing is deliberate: the phase has to survive a save, and
## the thing that survives a save is the mask's blue channel -- but it also has to
## survive an undo, and what survives an undo is the recipe, which already carries
## the seed. One number, two homes, no third field to keep in step.
static func phase_for_seed(seed_value: float) -> float:
	return fposmod(seed_value, TAU) / TAU


## The seed a stroke pressed at [param page_position] paints with.
##
## Deterministic in the press point alone, so it can be chosen at
## [method PageView.begin_stroke] and written into the recipe: a rebuild that
## re-stamps the same recipe re-derives nothing and re-uses the seed it was given,
## and a stroke laid at the same place twice looks the same twice. Returned in
## [code][0, TAU)[/code] because the grain reads it as an angle.
static func seed_for(page_position: Vector2) -> float:
	var x := int(floor(page_position.x))
	var y := int(floor(page_position.y))
	# FNV-1a-ish mix over the two coordinates: cheap, no engine RNG state to depend
	# on, and stable across runs and platforms (GameState hashes its slugs the same
	# way, and for the same reason).
	var h := 2166136261
	h = ((h ^ (x & 0xffff)) * 16777619) & 0xffffffff
	h = ((h ^ ((x >> 16) & 0xffff)) * 16777619) & 0xffffffff
	h = ((h ^ (y & 0xffff)) * 16777619) & 0xffffffff
	h = ((h ^ ((y >> 16) & 0xffff)) * 16777619) & 0xffffffff
	return float(h % 100000) / 100000.0 * TAU

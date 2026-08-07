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
## [b]Phase 1 is BAKEABLE finishes only.[/b] Every finish here is computed inside
## [code]brush.gdshader[/code] at stamp time, so it is flattened into the paint
## SubViewport with the stroke and travels into the saved PNG for free -- no effect
## mask, no per-stroke metadata to persist, nothing for the restore path to know.
## [method is_animated] is the seam a phase-2 live finish arrives through: it is
## false for every finish today, and the day one is true the palette and the paint
## path already carry the finish id that would drive it.
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
## Box 4, the loudest: glitter. Grain's tooth, plus a hue that drifts across the
## page in slow rainbow bands, plus bright specks of glitter caught in the wax.
const GLITTER := &"glitter"

## Shader [code]effect_mode[/code] values. Kept next to the ids so the two cannot
## drift; the shader has the same numbers in its own comments.
const MODE_CLASSIC := 0
const MODE_GLOW := 1
const MODE_GRAIN := 2
const MODE_GLITTER := 3

## id -> { mode, quad_scale, strength, display_name, animated }.
##
## [code]quad_scale[/code] is how much bigger than the dab the stamp QUAD is drawn:
## 1.0 for a finish that stays inside the brush, more for one that spills (the glow
## halo). The shader divides back out, so a dab radius still means the same thing at
## every scale and only the halo gets the extra room.
const FINISHES := {
	CLASSIC: {
		"mode": MODE_CLASSIC,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Classic wax",
		"animated": false,
	},
	GLOW: {
		"mode": MODE_GLOW,
		# The halo reaches the quad's edge, so this IS the bloom radius.
		"quad_scale": 2.1,
		"strength": 1.0,
		"display_name": "Neon glow",
		"animated": false,
	},
	GRAIN: {
		"mode": MODE_GRAIN,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Textured wax",
		"animated": false,
	},
	GLITTER: {
		"mode": MODE_GLITTER,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Glitter",
		"animated": false,
	},
}

## The finishes in ladder order, dullest first. What an authoring tool would offer
## and what the smoke walks.
const LADDER: Array[StringName] = [CLASSIC, GLOW, GRAIN, GLITTER]


## True when [param id] names a finish this build knows how to paint.
static func is_known(id: StringName) -> bool:
	return FINISHES.has(id)


## [param id] if it is known, [constant CLASSIC] otherwise. Every entry point
## resolves through here, so an authored typo paints plain wax instead of nothing.
static func resolve(id: StringName) -> StringName:
	return id if FINISHES.has(id) else CLASSIC


## Shader parameters for [param id], WITHOUT a seed: { mode, quad_scale, strength }.
## [PageView] adds the per-stroke seed before handing this to [PaintCanvas].
static func params_for(id: StringName) -> Dictionary:
	var entry: Dictionary = FINISHES[resolve(id)]
	return {
		"mode": int(entry["mode"]),
		"quad_scale": float(entry["quad_scale"]),
		"strength": float(entry["strength"]),
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
## False for every phase-1 finish, and that is the point: a bakeable finish is
## flattened into the paint layer and the saved PNG carries it, while an animated
## one would need an effect channel or per-stroke metadata that survives save and
## restore (BL-17 recipes are per-visit only). Phase 2 answers that; until it does,
## anything that would have to branch on it can simply ask.
static func is_animated(id: StringName) -> bool:
	return bool((FINISHES[resolve(id)] as Dictionary)["animated"])


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

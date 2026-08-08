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
## [b]Phase 3 (BL-47) added four more animated boxes[/b] -- Embers, Ocean glass,
## Aurora and Firefly dust -- and needed exactly one architectural change to fit
## them: the mask's red and green stopped being raw amounts and became QUANTIZED
## STYLE LEVELS, so each channel carries a whole FAMILY of animations instead of one.
## See the [constant MASK_FIELD_LEVELS] block for the decode and why it is exact.
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
## Box 5 (BL-47 slotted three quieter animated boxes below it), and the FIRST
## animated one by loudness: dark cooled-crust wax whose patches breathe warm, like
## coals being blown on. The subtlest box in the game -- from across the room a page
## of embers looks like ordinary dark wax that will not quite hold still.
const EMBERS := &"embers"
## Box 6: polished glass with sunlight rippling through shallow water over it --
## two drifting noise fields multiplied and sharpened into caustics.
const OCEAN := &"ocean"
## Box 7: a curtain of light crossing the page. It is the only finish that changes
## the wax's HUE rather than adding brightness to it -- the sheen reads as slowly
## changing colour instead of white glare, which is what makes it louder than the
## ocean and quieter than the shimmer.
const AURORA := &"aurora"
## Box 8, the first ANIMATED one BL-38 shipped: satin wax with a sheen that travels
## across the page, over and over. Baked base plus a full-strength white-sheen level
## in the effect mask's red channel.
const SHIMMER := &"shimmer"
## Box 9: faint dust whose specks WANDER instead of winking where they are. Twinkle's
## machinery at half the payload and half the volume -- the specks drift, swell and
## fade rather than blinking, so it reads as a slow drift of light over the wax.
const FIREFLY := &"firefly"
## Box 10, the loudest box in the game: glitter that actually sparkles. Baked glitter
## base plus a full-strength wink level in the effect mask's green channel, which the
## display shader turns into specks that wink in and out where they sit.
const TWINKLE := &"twinkle"

## Shader [code]effect_mode[/code] values. Kept next to the ids so the two cannot
## drift; the shader has the same numbers in its own comments. They are BAKE modes --
## which base a stamp lays into the paint layer -- and are deliberately NOT the same
## axis as the mask style levels below, because two boxes can share a baked base and
## animate differently (aurora and shimmer both bake satin) and one box can bake its
## own base and animate on a level another box also uses.
const MODE_CLASSIC := 0
const MODE_GLOW := 1
const MODE_GRAIN := 2
const MODE_GLITTER := 3
const MODE_SHIMMER := 4
const MODE_TWINKLE := 5
const MODE_EMBERS := 6
const MODE_OCEAN := 7
const MODE_AURORA := 8
const MODE_FIREFLY := 9

## id -> { mode, quad_scale, strength, display_name, animated, sheen, spark }.
##
## [code]quad_scale[/code] is how much bigger than the dab the stamp QUAD is drawn:
## 1.0 for a finish that stays inside the brush, more for one that spills (the glow
## halo). The shader divides back out, so a dab radius still means the same thing at
## every scale and only the halo gets the extra room.
##
## [code]sheen[/code] / [code]spark[/code] (BL-38, re-read by BL-47) are the EFFECT
## MASK payload: the red and green a stamp of this finish writes into the mask layer.
## Until BL-47 they were raw AMOUNTS and the mask hard-coded exactly two animation
## families; now they are [b]STYLE LEVELS[/b] drawn from [constant MASK_FIELD_LEVELS]
## and [constant MASK_SPECK_LEVELS] -- see the block above those tables for why one
## channel can carry a whole family of animations and still be recovered exactly.
## Zero is still zero and still means "not alive", which is exactly why painting
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
	EMBERS: {
		"mode": MODE_EMBERS,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Embers",
		"animated": true,
		# Level 0.15: the warm breathing field. The QUIETEST level of the loudest
		# channel, which is also why it is the lowest number in the table -- the
		# decode's nearest-level rule reads best when the ladder and the numbers
		# climb together.
		"sheen": 0.15,
		"spark": 0.0,
	},
	OCEAN: {
		"mode": MODE_OCEAN,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Ocean glass",
		"animated": true,
		# Level 0.55: caustics.
		"sheen": 0.55,
		"spark": 0.0,
	},
	AURORA: {
		"mode": MODE_AURORA,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Aurora",
		"animated": true,
		# Level 0.80: the hue-shifting curtain. The one field style that does not add
		# white light, so its LEVEL is what tells the display shader to rotate the wax
		# instead of brightening it.
		"sheen": 0.80,
		"spark": 0.0,
	},
	SHIMMER: {
		"mode": MODE_SHIMMER,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Shimmer",
		"animated": true,
		# Level 1.00: the full white sheen. Unmoved from BL-38 on purpose -- every
		# page_NN_fx.png already on a player's disk decodes to exactly this look.
		"sheen": 1.0,
		"spark": 0.0,
	},
	FIREFLY: {
		"mode": MODE_FIREFLY,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Firefly dust",
		"animated": true,
		# Speck level 0.50: specks that WANDER. No field at all -- the dust is the
		# whole finish, and a sheen under it would drown it.
		"sheen": 0.0,
		"spark": 0.5,
	},
	TWINKLE: {
		"mode": MODE_TWINKLE,
		"quad_scale": 1.0,
		"strength": 1.0,
		"display_name": "Twinkle",
		"animated": true,
		# Field level 0.35 -- the SOFT white sheen -- plus speck level 1.00. The
		# twinkle box carries a little sheen as well: its specks wink over wax that is
		# itself alive, which is what makes it the loudest box in the game. 0.35 is
		# also unmoved from BL-38, for the same saved-PNG reason as shimmer's 1.00.
		"sheen": 0.35,
		"spark": 1.0,
	},
}

## The finishes in ladder order, dullest first. What an authoring tool would offer
## and what the smoke walks. The ANIMATED finishes top it -- a box that keeps moving
## is louder than any box that stops -- and BL-47 slotted its four new ones INSIDE
## that animated tail by loudness rather than appending them: embers barely moves,
## twinkle is still the last word.
const LADDER: Array[StringName] = [
	CLASSIC, GLOW, GRAIN, GLITTER, EMBERS, OCEAN, AURORA, SHIMMER, FIREFLY, TWINKLE
]

# ------------------------------------------------- mask style levels (BL-47) --
# THE EXTENSION THAT MADE FOUR MORE ANIMATED BOXES POSSIBLE.
#
# BL-38 read the effect mask's red as "how much travelling white sheen" and its
# green as "how much winking speck": two channels, two hard-coded animations, and
# no room for a fifth idea. BL-47 re-reads the same two channels as QUANTIZED STYLE
# LEVELS -- red names a member of the FIELD family (a page-space light that washes
# over the wax), green names a member of the SPECK family (points of light on a
# page-space cell grid) -- so one channel now carries a whole family and the display
# shader picks the animation from the level rather than from the channel.
#
# [b]Why the payload survives the blend, exactly.[/b] The mask is stamped with
# ordinary alpha blending, so a texel holds `payload * coverage` in rgb and the same
# `coverage` in alpha -- the display shader never reads `mask.a` for anything else,
# and that spare channel is the whole trick. First stamp on a transparent target:
# `dst.rgb = payload * a`, `dst.a = a`, so `dst.rgb / dst.a` is the payload exactly.
# A second stamp of the SAME payload gives `payload * (a + a'(1-a))` over
# `a + a'(1-a)` -- exactly again, at any coverage, however many dabs deep. So the
# normalised value is the authored level even at a feathered dab edge, where the raw
# channel is nearly nothing.
#
# [b]Where two styles overlap-blend, nearest-level picks one of them[/b] -- the
# blend of 0.15 and 0.80 is not a level, and the decode rounds it to whichever is
# closer. That is deliberate, and what makes it free is that the seam is THIN, not
# that it is dim: measured off the GPU (`paint_smoke` check 11c), an embers stroke
# lapping over shimmer wax mis-decodes a band 5 px wide carrying up to 90% of a
# level -- bright, and gone in five pixels, because a stroke's edge is eight
# overlapping dabs deep and crosses the whole ladder of wrong levels at once. The
# check pins that width, because a fifth field level or a softer brush would widen
# it quietly. The ERASE is a different question and comes out cleaner: classic wax
# saturates as fast as it rubs out, so an animated area painted over goes out rather
# than changing style on the way (peak stray, measured: 2/255).
#
# The two tables are the contract with `paint_display.gdshader`, which carries the
# same numbers as decode thresholds at their midpoints. Change one, change both --
# and never change a level that has shipped, because every `page_NN_fx.png` already
# written decodes through this table.

## The RED channel's field styles, ascending. 0.15 embers, 0.35 soft white sheen,
## 0.55 ocean caustics, 0.80 aurora curtain, 1.00 full white sheen.
## Array[float] rather than PackedFloat32Array on purpose: these numbers are
## compared for EQUALITY against authored payloads, and a 32-bit round trip turns
## 0.35 into 0.3499999940395355, which is not the same constant any more.
const MASK_FIELD_LEVELS: Array[float] = [0.15, 0.35, 0.55, 0.80, 1.0]
## The GREEN channel's speck styles, ascending. 0.5 firefly drift, 1.0 wink in place.
const MASK_SPECK_LEVELS: Array[float] = [0.5, 1.0]
## Below this the channel is treated as unwritten -- the same floor the display
## shader gates on, so the two agree about which texels have a style at all.
const MASK_CHANNEL_FLOOR := 0.002
## Guards the divide for a texel with coverage but no payload. Never reached in
## practice: the floor above rejects those texels first.
const MASK_COVERAGE_EPSILON := 0.0001


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
## False for every BL-35 finish, true for the six animated ones -- BL-38's
## [constant SHIMMER] and [constant TWINKLE], and BL-47's [constant EMBERS],
## [constant OCEAN], [constant AURORA] and [constant FIREFLY]. It is the flag on the
## table that answers this, never a list of ids anywhere else, which is why adding
## four boxes moved no code outside this file.
##
## This is the ONE thing the painting stack branches on: a page that has never held
## an animated finish never allocates the effect mask, never renders a second
## SubViewport and never writes a second PNG, so the four bakeable boxes cost exactly
## what they cost before phase 2 existed.
static func is_animated(id: StringName) -> bool:
	return bool((FINISHES[resolve(id)] as Dictionary)["animated"])


## The effect-mask payload a stamp of [param id] writes (BL-38, re-read by BL-47):
## red = the FIELD style level, green = the SPECK style level -- members of
## [constant MASK_FIELD_LEVELS] / [constant MASK_SPECK_LEVELS], not raw amounts --
## and blue is the per-stroke phase, filled in by the caller from the stroke's seed.
## Alpha is the dab's own coverage and comes from the shader, not from here, which is
## what lets the display shader divide it back out and recover the level.
##
## [b]Every finish has one, including the bakeable ones[/b], and theirs is zero. A
## mask entry is not "this stroke is animated", it is "this is how alive this wax
## is NOW" -- so ordinary wax painted over a shimmer erases the shimmer through the
## same blend that laid it down, with no bookkeeping anywhere.
static func mask_payload(id: StringName, phase: float = 0.0) -> Color:
	var entry: Dictionary = FINISHES[resolve(id)]
	return Color(float(entry["sheen"]), float(entry["spark"]), clampf(phase, 0.0, 1.0), 1.0)


## The nearest entry of [param levels] to [param value]. The decode rule, in one
## place, so GDScript and the shader cannot disagree about where a boundary is.
##
## A value sitting EXACTLY on a midpoint takes the higher level, which is what the
## shader's `normalized < threshold` chain does with the same number. The tables are
## ascending and the comparison is [code]<=[/code] for that reason and no other: with
## [code]<[/code] a tie kept the first level it met -- the lower one -- and the two
## decoders disagreed on precisely the 0.25 / 0.45 / 0.675 / 0.90 / 0.75 boundaries
## the whole contract is written in terms of.
static func _nearest_level(levels: Array[float], value: float) -> float:
	var best := levels[0]
	var best_gap := absf(value - best)
	for level in levels:
		var gap := absf(value - level)
		if gap <= best_gap:
			best_gap = gap
			best = level
	return best


## Which FIELD style a normalised red channel names (BL-47). [param normalized] is
## [code]mask.r / mask.a[/code] -- the payload the stamp wrote, recovered.
static func decode_mask_field(normalized: float) -> float:
	return _nearest_level(MASK_FIELD_LEVELS, normalized)


## Which SPECK style a normalised green channel names (BL-47).
static func decode_mask_speck(normalized: float) -> float:
	return _nearest_level(MASK_SPECK_LEVELS, normalized)


## The style levels a mask texel was STAMPED with, recovered from the blended texel:
## { "field": float, "speck": float }, zero for a channel that was never written.
##
## This is the GDScript twin of the decode in [code]paint_display.gdshader[/code],
## and it exists so the smoke can prove the recovery empirically rather than by
## argument -- stamp a stroke, read the mask back, assert the level that comes out is
## the level [method mask_payload] put in.
static func decode_mask_payload(texel: Color) -> Dictionary:
	var coverage := maxf(texel.a, MASK_COVERAGE_EPSILON)
	return {
		"field": decode_mask_field(texel.r / coverage) if texel.r > MASK_CHANNEL_FLOOR else 0.0,
		"speck": decode_mask_speck(texel.g / coverage) if texel.g > MASK_CHANNEL_FLOOR else 0.0,
	}


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

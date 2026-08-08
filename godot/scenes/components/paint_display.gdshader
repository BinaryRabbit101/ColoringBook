shader_type canvas_item;
render_mode blend_mix, unshaded;

// The paint layer's DISPLAY shader (BACKLOG BL-38).
//
// It draws the paint SubViewport's texture, and -- only where the EFFECT MASK says
// so -- animates it. This is the whole of the animated half of the finish ladder:
// six boxes' worth of movement out of two mask channels.
//
// BL-47 IS WHY THERE ARE SIX. BL-38 read mask.r as "how much travelling white
// sheen" and mask.g as "how much winking speck" -- two channels, two animations,
// nowhere to put a third idea. Now each channel names a STYLE LEVEL out of a small
// quantised table (BrushFinish.MASK_FIELD_LEVELS / MASK_SPECK_LEVELS), so red
// carries a FAMILY of page-space light fields and green a FAMILY of page-space
// specks. The level is recovered from the blended texel by dividing out the mask's
// own alpha -- see `decode_field` below for why that is exact rather than
// approximate -- and the LIGHT AMOUNT still comes from the raw, coverage-weighted
// channel exactly as it did before, with a per-style gain making up the difference
// between a quiet level and a loud one.
//
// BL-51 IS WHY FOUR OF THEM ARE LOUD. The ladder is meant to run solid wax ->
// SUBTLE effects -> a top tier of SPECTACLE, and BL-47's four shipped in the middle
// band: a playtest called them "missed the point". Embers, Ocean glass, Aurora and
// Firefly dust were re-aimed here -- bigger amplitude, far more motion, far more of
// the stroke lit at once, and colour that is part of the effect rather than a tint
// on it -- while shimmer and twinkle were deliberately LEFT ALONE as the subtle
// tier they are. Not one byte of the encoding moved: same levels, same thresholds,
// same seam, so every `page_NN_fx.png` already on disk reopens as the same style
// and simply performs it louder.
//
// FIVE THINGS THIS SHADER MUST NEVER DO, and how each is prevented here:
//
//  1. Cross a region boundary. It cannot: the mask was stamped by
//     brush.gdshader, through the same ID-map `discard` as the wax, so a mask
//     texel outside the locked region was never written. Nothing here decides
//     where the animation is allowed -- the mask already did, at stamp time.
//  2. Reach coverage. It cannot: this runs on the SPRITE, not in the paint
//     SubViewport. `CoverageTracker` reads the paint viewport back, and nothing
//     this shader computes is ever in it.
//  3. Paint outside the paint. Every addition below is multiplied by the paint
//     layer's own alpha, so a mask texel with no wax under it lights nothing --
//     and BL-47's aurora, which turns the wax's hue rather than adding to it, is
//     weighted by that same alpha for the same reason: rotating the colour of a
//     transparent texel would put a curtain on the paper.
//  4. Cost per-frame CPU. There is none: the only thing that changes between
//     frames is `TIME`.
//  5. Break where the animation is turned off. `effect_animated = false` freezes
//     the clock at zero rather than branching the maths, so a frozen page is a
//     valid still frame of the animated one -- which is what makes "coverage is
//     identical with the animation on and off" a fact rather than a hope.
//
// With `effect_enabled` false (a page that has never held an animated finish) the
// whole thing is one texture fetch and one multiply -- byte for byte the default
// canvas_item shader the sprite used before BL-38.

// BL-38's effect mask: the second SubViewport, rendered beside the paint one.
//   r = the FIELD style level, g = the SPECK style level (BL-47 -- they were raw
//       amounts before), b = the stroke's own phase,
//   a = the coverage the stamp had (so the animation feathers with the dab, and so
//       the two levels above can be recovered from it).
// hint_default_transparent: a page with no mask yet animates nothing.
uniform sampler2D effect_mask : filter_linear, repeat_disable, hint_default_transparent;

// Page size in pixels, so the effects can be functions of PAGE POSITION -- the
// BL-35 rule, still in force: an effect that moved with the sprite's UV would
// stretch and slide when the player zooms, and two strokes would not agree about
// where the sheen is.
uniform vec2 page_size = vec2(1024.0, 1024.0);

// False until this page has actually stamped something animated. Keeps the cost of
// the four bakeable boxes at exactly what it was.
uniform bool effect_enabled = false;
// False freezes the animation at t = 0 (mobile fallbacks, and the smoke's
// "coverage cannot see the animation" check).
uniform bool effect_animated = true;

// How long the sheen takes to cross the page, in wraps per second.
uniform float shimmer_speed = 0.17;
// Half-width of the sheen band, as a fraction of the page's diagonal.
uniform float shimmer_width = 0.085;
// Peak brightness the sheen adds.
uniform float shimmer_gain = 0.55;
// Winks per second.
uniform float twinkle_speed = 2.3;
// Page-space grid the specks sit on, in pixels. Matches the baked flecks
// brush.gdshader lays down for MODE_TWINKLE, so the wink lands ON the glitter.
uniform float twinkle_cell = 17.0;
uniform float twinkle_gain = 0.95;

// --- BL-47's four styles, RE-AIMED BY BL-51 ----------------------------------
// The playtest verdict on BL-47 was "these missed the point": the ladder is meant
// to run solid wax -> SUBTLE effects (glow/grain/glitter/shimmer/twinkle) -> a top
// tier of SPECTACLE, and the four newest boxes shipped in the subtle band instead.
// Everything below is turned up to the top tier: bigger amplitude, far more motion,
// far more of the stroke lit at once, and colour that is unmistakably part of the
// effect rather than a tint on it.
//
// [b]The one thing that is NOT turned up is the encoding.[/b] The style levels in
// the mask, their decode thresholds and the seam behaviour are all exactly BL-47's,
// because every `page_NN_fx.png` on a player's disk decodes through them. A saved
// page reopens as the same STYLE; it simply performs that style louder.
//
// [b]"Spectacle, not noise" is a coverage rule, not a brightness rule.[/b] Each
// style keeps a shape that leaves the crayon's own colour readable between the
// bright parts: embers cools to dark crust between its coals, the ocean's caustics
// are thin threads over calm glass, the aurora is a moving BAND with unlit page
// either side of it, and the fireflies are points. Turning the coverage up instead
// of the contrast is what would have made a child's drawing disappear.
//
// Each gain is still the per-style make-up for the fact that the light amount is
// the RAW channel value: embers writes 0.15 there and shimmer writes 1.00, so their
// gains are 5.5 and 0.55 to land comparable brightness on screen.

// Embers: live coals. `scale` is how coarse the bed is per page pixel; `period` is
// one blow-on-the-coals breath. The drift is a CIRCLE through noise space, so the
// field genuinely returns to where it started -- a linear drift walks off into
// fresh noise forever and reads as a texture sliding past, not as breathing.
// `flicker` is the fast heat shimmer on top of the breath, and `spark_speed` drifts
// a fine, hard-thresholded second field UPWARD: cinders coming off the coals.
uniform float embers_scale = 0.022;
uniform float embers_period = 2.6;
uniform float embers_gain = 5.5;
uniform float embers_flicker = 0.36;
uniform float embers_spark_scale = 0.085;
uniform float embers_spark_speed = 52.0;
// Ocean glass: two RIDGED fields (1 - |2n-1|, which turns a smooth noise into thin
// bright contour threads) at different scales drifting different ways, multiplied
// into the web sunlight makes on a shallow bottom, plus a finer, faster glint layer
// riding on it. `speed` is the whole thing's drift rate -- BL-47's was ~5x slower
// and read as two clouds sitting still.
uniform float ocean_scale_a = 0.019;
uniform float ocean_scale_b = 0.031;
uniform float ocean_sharpness = 2.3;
uniform float ocean_gain = 1.7;
uniform float ocean_speed = 1.0;
// Aurora: TWO curtains crossing the page, undulating rather than marching as
// straight bars, striped with vertical rays, sweeping ~5x faster than BL-47's and
// carrying their own vivid crimson-green-violet light as well as a hue rotation
// ~3.4x wider. `ripple` is how far the curtain's edge wanders across the page.
uniform float aurora_speed = 0.26;
uniform float aurora_width = 0.20;
uniform float aurora_swing = 2.1;
uniform float aurora_gain = 1.30;
uniform float aurora_ripple = 0.09;
// Firefly dust: bright wandering points with a real glow around them, on the same
// page-space cell grid as the motes brush.gdshader bakes for MODE_FIREFLY.
//
// BL-47 drew ONE cell per fragment, which capped `wander` at 0.17 of a cell (a
// speck straying over its own edge would be sliced by the boundary it crossed) and
// is exactly why the box read as a faint twitch. BL-51 pays the cost BL-47 named
// and declined -- the 3x3 NEIGHBOURHOOD -- so a fly can carry a wide halo and cross
// most of its cell with nothing cut. The loop is only entered on texels the mask
// says are firefly wax, and `present` rejects ~30% of cells before their remaining
// five hashes are computed.
//
// [b]The 3x3 window is what bounds the other two numbers, and the arithmetic is
// worth writing down because getting it wrong is a HARD SEAM, not a soft one.[/b]
// A fragment sits somewhere in cell C; the nearest fly the loop cannot see lives in
// C+2. If a fly may stray to `s` cells outside its own, that fly's centre can come
// within `(2 - s) - 1` cells of the fragment -- and any halo reaching further than
// that is chopped off along a straight cell boundary at full brightness. So the
// centre is kept INSIDE its cell (home 0.5 +/- 0.18 plus wander 0.30 lands in
// 0.02..0.98), which puts the nearest unseen fly 1.02 cells = 24.5 px away, and the
// halo reach (3.5 x a radius that peaks at 7.0 px = 24.6 px) is sized to stop there.
// Coverage is bought with DENSITY and brightness instead of with more travel, which
// is free of that constraint.
uniform float firefly_cell = 24.0;
uniform float firefly_wander = 0.30;
uniform float firefly_gain = 3.3;

// Below this a channel counts as unwritten. Same number as
// BrushFinish.MASK_CHANNEL_FLOOR, and the reason the decode never divides into
// noise: a texel this faint has no style, it has a rounding error.
const float MASK_FLOOR = 0.002;

// The FIELD styles (mask.r) and the SPECK styles (mask.g). These ints are local to
// this shader -- the CONTRACT is the level numbers in the decoders below, which are
// BrushFinish.MASK_FIELD_LEVELS / MASK_SPECK_LEVELS.
const int FIELD_EMBERS = 0;
const int FIELD_SHEEN = 1;
const int FIELD_OCEAN = 2;
const int FIELD_AURORA = 3;
const int SPECK_DRIFT = 0;
const int SPECK_WINK = 1;

// The embers' own level out of BrushFinish.MASK_FIELD_LEVELS, spelled out because
// BL-51's ember TINT needs the dab's coverage back (raw channel / level) and the
// decode above only hands back which style it is. It is the same contract the
// thresholds beside `decode_field` are: change the table, change this. It is
// deliberately NOT mask.a -- that channel is the decode's divisor and the argument
// for the decode being exact rests on nothing else claiming it.
const float LEVEL_EMBERS = 0.15;

// Same hash the brush shader uses, for the same reason: the speck grid has to be a
// function of the page pixel and nothing else, so it is stable under pan, zoom and
// a page reopened tomorrow.
float hash21(vec2 p) {
	vec2 q = fract(p * vec2(123.34, 456.21));
	q += dot(q, q + 45.32);
	return fract(q.x * q.y);
}

// ...and value noise on the same lattice as the tooth baked into the wax underneath
// it, with one difference BL-51 had to make: the interpolant is QUINTIC
// (6t^5 - 15t^4 + 10t^3) rather than the cubic smoothstep brush.gdshader uses.
//
// Cubic value noise is C1 but not C2, and its second derivative jumps at every cell
// boundary. Nothing shows while the field is used gently -- BL-47 used all of these
// gently -- but BL-51's embers threshold the field hard, and thresholding a field
// with a crease in it draws the crease: dead straight, axis-aligned, one noise cell
// apart, right across the child's stroke. The quintic is the standard fix and costs
// two multiplies. The baked tooth keeps the cubic because nothing thresholds it and
// changing it would repaint every saved page.
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// [param p] turned by [param radians_] about the origin (BL-51). Octaves of value
// noise all sit on the SAME axis-aligned lattice, so stacking them un-rotated leaves
// long straight cell edges that any sharp threshold turns into visible seams.
vec2 spun(vec2 p, float radians_) {
	float c = cos(radians_);
	float s = sin(radians_);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// A RIDGE of the noise instead of the noise itself (BL-51): 1 at the field's
// mid-level, 0 at both extremes. Running it over a smooth field turns the field's
// half-height contours into thin bright lines -- which is what a caustic IS, the
// place where the water's surface focuses the light, not a bright blob.
float ridged(float n) {
	return 1.0 - abs(n * 2.0 - 1.0);
}

// One curtain of the aurora (BL-51): .x is the Gaussian envelope across the band,
// .y the signed position within it in half-widths. Two of these are summed, so the
// page usually has some curtain on it rather than long dead waits between sweeps.
vec2 aurora_curtain(float axis, float phase, float width, float speed, float t) {
	float offset = axis - fract(t * speed + phase);
	// Wrap into -0.5..0.5 so the curtain re-enters the page instead of jumping
	// when the clock wraps.
	offset -= floor(offset + 0.5);
	float u = offset / max(width, 1e-6);
	return vec2(exp(-u * u * 0.5), u);
}

// Rotation about the grey axis: a hue shift with no RGB->HSV round trip. Ported
// verbatim from brush.gdshader, because the aurora is the one animated finish that
// changes the wax's colour rather than adding light to it, and glitter's baked
// rainbow bands already proved this is the cheap way to say it.
vec3 hue_shift(vec3 color, float radians_) {
	const vec3 k = vec3(0.57735026919);
	float c = cos(radians_);
	return color * c + cross(k, color) * sin(radians_) + k * dot(k, color) * (1.0 - c);
}

// --- the style-level decode (BL-47) ------------------------------------------
// `normalized` is mask.rgb / mask.a: the payload the STAMP wrote, recovered from
// the blended texel. It is exact, not approximate, and that is worth spelling out.
// The mask is stamped with ordinary alpha blending, so a texel holds
// `payload * coverage` in the channel and `coverage` in alpha -- and nothing else
// in this shader reads mask.a, which is what leaves it free to be the divisor.
// First stamp on a transparent target gives payload * a over a; a second stamp of
// the same payload gives payload * (a + a'(1-a)) over (a + a'(1-a)). Exact at any
// coverage, however many of the ~8 overlapping dabs have been laid down.
//
// The thresholds below are the MIDPOINTS between adjacent levels -- nearest-level
// rounding, written out, because a loop over a const array costs more than four
// compares. A value sitting exactly on one takes the HIGHER level, and
// BrushFinish._nearest_level breaks its ties the same way on purpose.
//
// Where strokes of two DIFFERENT styles overlap-blend the normalised value lands
// between two levels and this picks one of them. Those texels are the seam where one
// stroke's soft edge lies over another, and the seam is free because it is THIN, not
// because it is dim: measured off the GPU (paint_smoke check 11c) an embers stroke
// lapping over shimmer wax mis-decodes a band 5 px wide carrying up to 90% of a
// level. Five pixels, because a stroke's edge is eight overlapping dabs deep and
// crosses the whole ladder of wrong levels at once. The check pins that width, so a
// fifth field level or a softer brush cannot widen it unnoticed.
int decode_field(float normalized) {
	if (normalized < 0.25) {
		return FIELD_EMBERS;   // level 0.15
	}
	if (normalized < 0.45) {
		return FIELD_SHEEN;    // level 0.35 -- twinkle's soft sheen
	}
	if (normalized < 0.675) {
		return FIELD_OCEAN;    // level 0.55
	}
	if (normalized < 0.90) {
		return FIELD_AURORA;   // level 0.80
	}
	return FIELD_SHEEN;        // level 1.00 -- shimmer's full sheen
}

int decode_speck(float normalized) {
	// levels 0.5 (drift) and 1.0 (wink), midpoint 0.75.
	return normalized < 0.75 ? SPECK_DRIFT : SPECK_WINK;
}

void fragment() {
	vec4 wax = texture(TEXTURE, UV);
	if (effect_enabled) {
		vec4 mask = texture(effect_mask, UV);
		if (mask.r > MASK_FLOOR || mask.g > MASK_FLOOR) {
			float t = effect_animated ? TIME : 0.0;
			vec2 page_position = UV * page_size;
			float diagonal = max(page_size.x + page_size.y, 1.0);
			// The divisor of the decode. Guarded, but never actually zero here: a
			// texel with no coverage cannot have got a channel past MASK_FLOOR.
			float coverage = max(mask.a, 1e-4);
			vec3 light = vec3(0.0);
			// The aurora is the one style that ROTATES the wax instead of lighting
			// it, so it hands its answer back out here rather than into `light`.
			float hue_angle = 0.0;
			float hue_weight = 0.0;
			// ...and the embers are the one style that REPLACES the wax's colour
			// where they are hot (BL-51). It has to: `light` is additive, and no
			// amount of warm light ADDED to a blue crayon comes out orange -- the
			// blue channel is already high, so the sum runs to pale mauve and then
			// to white. The first cut of BL-51 did exactly that and read as nothing
			// at all. Fire is a COLOUR, so the fire has to be mixed in, the way the
			// aurora's curtain is. Both are weighted by the wax's own alpha below,
			// and both leave the crayon's own colour alone everywhere they are not:
			// the cold crust between the coals is still the child's blue.
			vec3 tint = vec3(0.0);
			float tint_weight = 0.0;

			// --- the FIELD family (mask.r) ---------------------------------------
			if (mask.r > MASK_FLOOR) {
				int field = decode_field(mask.r / coverage);

				if (field == FIELD_SHEEN) {
					// Shimmer, and twinkle's quieter share of it. A soft band
					// sweeping the page along its diagonal. It is GLOBAL, not per
					// stroke: two shimmer strokes that touch must show one sheen
					// crossing both, or the seam between them becomes the thing you
					// look at.
					float axis = dot(page_position, vec2(0.7071, -0.7071)) / diagonal + 0.5;
					float offset = axis - fract(t * shimmer_speed);
					// Wrap into -0.5..0.5 so the band re-enters the page instead of
					// jumping when the clock wraps.
					offset -= floor(offset + 0.5);
					float band = exp(-(offset * offset) / max(shimmer_width * shimmer_width, 1e-6));
					light += vec3(1.0) * band * shimmer_gain * mask.r;
				} else if (field == FIELD_EMBERS) {
					// LIVE COALS -- BL-51 turned BL-47's ember-coloured breathing into
					// a fire. Three things stacked, each doing a job the other two
					// cannot:
					//
					//  1. THE BED. Two octaves of page-space noise read at a slowly
					//     ORBITING offset, the fine octave counter-orbiting so the
					//     crust churns instead of sliding. The orbit is a circle so
					//     the field genuinely returns -- a linear drift walks off into
					//     fresh noise and reads as texture sliding past. BL-47 orbited
					//     0.85 of a noise cell over 7 s, which is barely a wobble;
					//     this is 2.4 cells over 2.6 s.
					//  2. THE FLICKER. Two fast incommensurate beats, phased per patch
					//     out of a third coarse field so the bed does not pulse in
					//     unison. This is the "live" in live coals.
					//  3. THE SPARKS. A fine field scrolling UPWARD fast and cut hard,
					//     so small near-white cinders stream off the coals. They live
					//     in the FIELD family: the mask's green is untouched and the
					//     encoding is BL-47's to the byte.
					float cycle = t / max(embers_period, 0.001);
					vec2 orbit = vec2(cos(cycle * TAU), sin(cycle * TAU)) * 2.4;
					vec2 bed = page_position * embers_scale;
					// Each octave ROTATED off the one below it. Value noise is built on
					// an axis-aligned lattice, and stacking octaves that share it
					// leaves long straight cell edges that a sharp threshold turns
					// into visible vertical and horizontal seams -- which is exactly
					// what the first cut of this showed on screen.
					float coals = value_noise(spun(bed, 0.37) + orbit) * 0.52
						+ value_noise(spun(bed, 1.24) * 2.1 - orbit * 1.4) * 0.31
						+ value_noise(spun(bed, 2.46) * 4.6 + orbit * 0.7) * 0.17;
					// SHARP, and the gain high behind it. The first cut of BL-51 did
					// the opposite -- a wide smoothstep and a modest gain -- and lit
					// most of the stroke a little, which on a blue crayon came out as
					// pale mauve wash and read as nothing at all. Fire is CONTRAST:
					// mostly dark crust, with coals that genuinely blow out to
					// white-yellow. Because the bed churns a full 2.4 noise cells per
					// breath, a narrow hot band still sweeps the whole stroke over a
					// few seconds -- the coverage is in the MOTION, not in lighting
					// everything at once.
					coals = smoothstep(0.40, 0.76, coals);
					float beat = value_noise(bed * 0.5 + vec2(11.3, 4.7)) * TAU;
					float flicker = 1.0 - embers_flicker + embers_flicker * (
						0.6 * sin(t * 6.4 + beat) + 0.4 * sin(t * 11.9 + beat * 2.7)
					);
					coals *= flicker;
					// THE COLOUR OF THE COAL, mixed into the wax rather than added to
					// it -- see the `tint` declaration at the top of fragment() for
					// why adding could never work. `feather` recovers the dab's own
					// coverage from the raw channel and the level it was stamped with,
					// so the tint fades out at a dab's soft edge exactly as `light`
					// does (which gets it for free by being multiplied by mask.r).
					float feather = clamp(mask.r / LEVEL_EMBERS, 0.0, 1.0);
					tint = vec3(1.0, 0.38, 0.07);
					tint_weight = smoothstep(0.20, 0.75, coals) * 0.92 * feather;
					// ...and the WHITE HEAT on top of it: hotter is yellower, and the
					// hottest blows out. The ramp is what makes this read as heat
					// rather than as an orange lamp left on.
					vec3 heat = mix(
						vec3(1.0, 0.30, 0.05), vec3(1.0, 0.80, 0.45), coals * coals
					);
					vec2 rising = vec2(
						page_position.x, page_position.y + t * embers_spark_speed
					) * embers_spark_scale;
					float sparks = smoothstep(0.86, 0.995, value_noise(rising));
					light += heat * coals * embers_gain * mask.r;
					light += vec3(1.0, 0.80, 0.42) * sparks * embers_gain * 1.25 * mask.r;
				} else if (field == FIELD_OCEAN) {
					// BRIGHT MOVING CAUSTICS (BL-51). BL-47 multiplied two SMOOTH
					// fields and raised the product to a high power, which gives dim
					// round blobs -- but a caustic is not a blob, it is the THREAD
					// where the surface focuses the light. `ridged()` turns each
					// field's half-height contour into such a thread; multiplying two
					// of them, drifting different ways, gives the shifting web on the
					// bottom of a swimming pool. The threads being THIN is the whole
					// licence for making them this bright: the calm glass between them
					// still shows the crayon's own colour.
					vec2 drift_a = vec2(0.62, 0.24) * t * ocean_speed;
					vec2 drift_b = vec2(-0.38, 0.55) * t * ocean_speed;
					// Spun off each other for the embers' reason: two ridged fields on
					// the SAME lattice put their creases on the same lines, and the
					// product of two creases is a visible grid.
					float thread_a = ridged(
						value_noise(spun(page_position, 0.51) * ocean_scale_a + drift_a)
					);
					float thread_b = ridged(
						value_noise(spun(page_position, 1.93) * ocean_scale_b + drift_b)
					);
					float caustic = pow(
						clamp(thread_a * thread_b * 1.75, 0.0, 1.0), ocean_sharpness
					);
					// A finer, faster layer over it: the glints that run along a thread
					// when the surface chops. Cut hard so it stays sparse.
					float glint = ridged(
						value_noise(
							spun(page_position, 2.77) * ocean_scale_b * 2.6
							+ drift_b * 2.2
						)
					);
					caustic = clamp(
						caustic + pow(clamp(glint, 0.0, 1.0), 6.0) * 0.55, 0.0, 1.4
					);
					light += vec3(0.70, 0.93, 1.0) * caustic * ocean_gain * mask.r;
				} else {
					// SWEEPING VIVID CURTAINS (BL-51). BL-47's aurora was one straight
					// Gaussian bar taking 20 s to cross the page, adding a whisper of
					// white and turning the hue about 20 degrees. Four things changed,
					// and all four were needed before it read as an aurora at all:
					//
					//  1. TWO curtains, at different widths and speeds, so there is
					//     nearly always one on the page instead of long dead waits.
					//  2. The curtain UNDULATES -- its axis is displaced by a two-tone
					//     wave running along the perpendicular -- so it hangs and
					//     ripples rather than marching as a bar.
					//  3. Vertical RAYS striping it, which is the shape everyone
					//     recognises an aurora by.
					//  4. It carries its own COLOUR now: a green-to-violet light on
					//     top of a hue rotation ~3.4x wider than BL-47's.
					//
					// Still GLOBAL in page space, for shimmer's reason -- two aurora
					// strokes that touch must show ONE curtain crossing both.
					float axis = dot(page_position, vec2(0.7071, -0.7071)) / diagonal + 0.5;
					float across = dot(page_position, vec2(0.7071, 0.7071)) / diagonal;
					float wave = sin(across * 9.0 + t * 0.8) * 0.55
						+ sin(across * 21.0 - t * 1.3) * 0.45;
					float axis_r = axis + wave * aurora_ripple;
					vec2 near_curtain = aurora_curtain(
						axis_r, 0.0, aurora_width, aurora_speed, t
					);
					vec2 far_curtain = aurora_curtain(
						axis_r, 0.43, aurora_width * 0.55, aurora_speed * 1.7, t
					);
					float rays = 0.62 + 0.38 * (0.5 + 0.5 * sin(across * 34.0 + t * 0.6));
					float weight = near_curtain.x + far_curtain.x * 0.8;
					float envelope = clamp(weight * rays, 0.0, 1.0);
					// The swing is a SINE across each curtain, so its leading edge
					// turns the colour one way and its trailing edge the other and the
					// middle passes through the wax's own hue. A single-signed shift
					// would read as the page changing colour, not as something
					// crossing it. The two curtains' angles are averaged by envelope
					// so neither jumps when the other arrives.
					//
					// The ENVELOPE is the mix WEIGHT, not a second factor on the angle
					// (BL-47's gotcha, still live): damping the rotation by the same
					// curve that already decides how much of it is applied squares it,
					// and the first cut of this shipped a ~5-degree swing where ~20
					// was intended.
					hue_angle = (
						sin(near_curtain.y * 1.6) * near_curtain.x
						+ sin(far_curtain.y * 1.6) * far_curtain.x * 0.8
					) / max(weight, 1e-4) * aurora_swing;
					hue_weight = envelope * mask.r;
					// An aurora's OWN colours across the curtain -- crimson at one edge,
					// green through the middle, violet at the other -- rather than a
					// brightness on the wax's. Three stops, not two, and the choice of
					// stops was measured twice:
					//   * A straight green-to-violet ramp puts a MUDDY MIX of the pair
					//     exactly where the envelope is brightest, so the core came out
					//     grey and the green never reached the screen at all. Green
					//     belongs in the middle -- it is the part everyone has seen.
					//   * Ending the ramp on blue instead of violet cost 15% of the
					//     peak swing (156 -> 133 in check 11d) and failed the tier
					//     floor, because blue is where a blue crayon already is. The
					//     ends of the ramp have to be FAR from ordinary wax, in
					//     opposite directions, or the curtain crossing is a hue nudge.

					float band_pos = clamp(near_curtain.y * 0.5 + 0.5, 0.0, 1.0);
					vec3 curtain = band_pos < 0.5
						? mix(
							vec3(1.0, 0.24, 0.42), vec3(0.18, 1.0, 0.52), band_pos * 2.0
						)
						: mix(
							vec3(0.18, 1.0, 0.52), vec3(0.58, 0.28, 1.0),
							(band_pos - 0.5) * 2.0
						);
					light += curtain * envelope * aurora_gain * mask.r;
				}
			}

			// --- the SPECK family (mask.g) ---------------------------------------
			if (mask.g > MASK_FLOOR) {
				int speck = decode_speck(mask.g / coverage);
				// Both styles share the page-space cell discipline: the cell comes
				// from the page pixel and nothing else, so every dab that covers a
				// speck agrees about where it is, and it is the same speck tomorrow.
				// The per-cell phase is the cell's own PLUS the stroke's, out of the
				// mask's blue, so two strokes do not pulse in lockstep.
				if (speck == SPECK_WINK) {
					vec2 cell = floor(page_position / twinkle_cell);
					vec2 jitter = vec2(hash21(cell + 2.3), hash21(cell + 4.7));
					vec2 centre = (cell + jitter) * twinkle_cell;
					float radius = mix(1.8, 4.4, hash21(cell + 6.1));
					vec2 delta = page_position - centre;
					float core = clamp(1.0 - length(delta) / max(radius, 0.001), 0.0, 1.0);
					// Four-point star: thin arms, faded out well before the next cell.
					float arms = clamp(1.0 - min(abs(delta.x), abs(delta.y)) / max(radius * 0.34, 0.001), 0.0, 1.0)
						* clamp(1.0 - length(delta) / max(radius * 2.6, 0.001), 0.0, 1.0);
					float shape = max(core, arms * 0.75);
					float phase = hash21(cell + 9.1) * 6.2831853 + mask.b * 6.2831853;
					float pulse = pow(max(sin(t * twinkle_speed + phase), 0.0), 6.0);
					light += vec3(1.0) * shape * pulse * twinkle_gain * mask.g;
				} else {
					// BRIGHT WANDERING FIREFLIES (BL-51). The idea is BL-47's -- the
					// speck WANDERS instead of winking where it sits -- and everything
					// that made it read as a twitch is gone:
					//
					//  * It is drawn from the 3x3 NEIGHBOURHOOD of cells, not from the
					//    one cell the fragment is in. BL-47 named this cost and
					//    declined it, which is exactly what pinned `wander` at 0.17 of
					//    a cell and clipped the skirt off the widest specks. Paying it
					//    lets a firefly cross most of a cell and carry a halo several
					//    radii wide with nothing ever cut by a boundary.
					//  * Each speck is a hard CORE inside a wide soft HALO, so it
					//    reads as a light source rather than as a dot.
					//  * Wander, rate, radius and gain are all up, and the specks are
					//    bright enough to blow to white at the core.
					//
					// The loop only runs on texels the mask says are firefly wax, and
					// `present` rejects ~46% of cells before their other five hashes
					// are computed. The cell grid is still a function of the PAGE pixel
					// and nothing else, so every dab agrees where the flies are and
					// they are the same flies tomorrow.
					vec2 base_cell = floor(page_position / firefly_cell);
					float glow = 0.0;
					for (int oy = -1; oy <= 1; oy++) {
						for (int ox = -1; ox <= 1; ox++) {
							vec2 cell = base_cell + vec2(float(ox), float(oy));
							// Not every cell carries one -- a swarm, not a sheet. A
							// cell hash, never the stroke seed: the display shader is
							// not told which stroke a texel came from, only how alive
							// it is.
							if (hash21(cell + 13.9) < 0.30) {
								continue;
							}
							float rate = mix(0.90, 2.20, hash21(cell + 12.7));
							float phase = hash21(cell + 9.1) * TAU + mask.b * TAU;
							// Twinkle puts its wink exactly on the fleck
							// brush.gdshader baked, because a wink that missed its own
							// glitter would read as two effects. A WANDERER must not:
							// it starts near the baked mote and drifts off it, which
							// is the whole idea.
							// 0.36 of a cell of spread, so home + wander keeps the
							// centre inside the cell -- see the uniform block for why
							// that bound is what makes 3x3 enough.
							vec2 home = vec2(0.5) + (
								vec2(hash21(cell + 2.3), hash21(cell + 4.7)) - vec2(0.5)
							) * 0.36;
							vec2 wander = vec2(
								sin(t * rate + phase),
								cos(t * rate * 0.83 + phase * 1.7)
							) * firefly_wander;
							vec2 centre = (cell + home + wander) * firefly_cell;
							// Each fly swells as it drifts and fades again, on its own
							// rate, so the field reads as things moving rather than
							// blinking.
							float swell = 0.28 + 0.72
								* pow(max(sin(t * rate * 1.6 + phase * 0.6), 0.0), 1.15);
							float radius = mix(3.0, 5.2, hash21(cell + 6.1))
								* mix(0.6, 1.35, swell);
							float dist = length(page_position - centre);
							float core = clamp(1.0 - dist / max(radius, 0.001), 0.0, 1.0);
							// The HALO is what makes a firefly a light rather than a
							// dot, and it has to reach the neighbouring cell or the
							// swarm reads as a sprinkle of pinpricks with dead wax
							// between them -- measured, that was 11% of the stroke
							// moving against the field styles' 100%. Wide and shallow
							// (3.5 radii, exponent 1.8), so it fills without flattening
							// into a wash, and sized to die out just inside the 3x3
							// window -- see the uniform block.
							float halo = clamp(
								1.0 - dist / max(radius * 3.5, 0.001), 0.0, 1.0
							);
							glow += (pow(core, 0.6) + pow(halo, 1.8) * 0.9) * swell;
						}
					}
					light += vec3(1.0, 0.94, 0.62)
						* clamp(glow, 0.0, 1.7) * firefly_gain * mask.g;
				}
			}

			// The aurora's rotation, weighted by the WAX's own alpha for the same
			// reason every addition below is: outside the paint there is nothing to
			// turn, and half-covered wax must only be half-turned or the dab's soft
			// edge would come back as a hard colour boundary.
			// The embers' incandescence, mixed in before the light is added on top,
			// and weighted by the WAX's own alpha for the aurora's reason: colouring
			// a transparent texel would put a coal on the paper.
			if (tint_weight > 0.0) {
				wax.rgb = mix(wax.rgb, tint, clamp(tint_weight * wax.a, 0.0, 1.0));
			}
			//
			// CLAMPED since BL-51 widened the swing to ~2.1 rad: a rotation that far
			// about the grey axis can push a saturated crayon's channel negative, and
			// a negative channel is not a dark colour, it is an artefact that comes
			// back as a halo the moment anything multiplies by it.
			if (hue_weight > 0.0) {
				wax.rgb = clamp(
					mix(
						wax.rgb, hue_shift(wax.rgb, hue_angle),
						clamp(hue_weight * wax.a, 0.0, 1.0)
					),
					vec3(0.0), vec3(1.0)
				);
			}
			// Scaled by the WAX's own alpha: the animation can only ever brighten
			// paint that is already there, never the paper beside it.
			wax.rgb += light * wax.a;
		}
	}
	COLOR = wax * COLOR;
}

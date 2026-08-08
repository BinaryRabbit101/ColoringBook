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

// --- BL-47's four new styles -------------------------------------------------
// Each gain is the per-style make-up for the fact that the light amount is still
// the RAW channel value: embers writes 0.15 there, so a gain near 2 gets it to a
// visible quarter-brightness, while shimmer writes 1.0 and needs 0.55.

// Embers: how coarse the breathing field is, per page pixel, and how long one
// blow-on-the-coals cycle takes. The drift is a CIRCLE through noise space, so the
// field genuinely returns to where it started -- a linear drift would wander off
// into fresh noise forever and never read as breathing.
uniform float embers_scale = 0.028;
uniform float embers_period = 7.0;
uniform float embers_gain = 1.9;
// Ocean glass: two fields at different scales drifting different ways, multiplied
// and sharpened into the bright threads sunlight makes on a shallow bottom.
uniform float ocean_scale_a = 0.020;
uniform float ocean_scale_b = 0.033;
uniform float ocean_sharpness = 3.2;
uniform float ocean_gain = 0.85;
// Aurora: shimmer's band, ~3.5x wider and ~3.4x slower, and it turns the wax's HUE
// instead of adding white. `aurora_swing` is the peak rotation in radians at the
// curtain's shoulders; `aurora_gain` is the whisper of brightness that goes with it.
uniform float aurora_speed = 0.05;
uniform float aurora_width = 0.22;
uniform float aurora_swing = 0.62;
uniform float aurora_gain = 0.10;
// Firefly dust: the same page-space cell discipline as twinkle at a sparser grid,
// matching the baked motes brush.gdshader lays down for MODE_FIREFLY. `wander` is
// how far a speck strays from its home, as a fraction of a cell -- small on purpose,
// because only fragments INSIDE a cell draw that cell's speck, so what wanders over
// the edge is not drawn at all. The CENTRE always stays in its own cell (home
// 0.24..0.76 plus wander 0.17 keeps it 1.8 px clear of the boundary at worst); a
// speck's soft skirt does not, and the widest ones -- radius runs to 5.5 px -- lose
// the outer few pixels of it to a straight cut when their drift takes them to the
// edge. That is twinkle's trade inherited, and the alternative is evaluating the
// nine surrounding cells at every fragment.
uniform float firefly_cell = 26.0;
uniform float firefly_wander = 0.17;
uniform float firefly_gain = 1.85;

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

// Same hash the brush shader uses, for the same reason: the speck grid has to be a
// function of the page pixel and nothing else, so it is stable under pan, zoom and
// a page reopened tomorrow.
float hash21(vec2 p) {
	vec2 q = fract(p * vec2(123.34, 456.21));
	q += dot(q, q + 45.32);
	return fract(q.x * q.y);
}

// ...and the same value noise, so a field computed here sits on the same lattice as
// the tooth baked into the wax underneath it.
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
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
					// Coals being blown on. One coarse page-space noise field, read
					// at a slowly ORBITING offset so the patches swell and subside
					// and come back -- a linear drift would walk off into fresh noise
					// and read as a texture sliding past, not as breathing. The tint
					// is the whole reason this is not just a dim shimmer.
					float cycle = t / max(embers_period, 0.001);
					vec2 orbit = vec2(cos(cycle * TAU), sin(cycle * TAU)) * 0.85;
					float coals = value_noise(page_position * embers_scale + orbit);
					// Sharpened, so the wax between the patches genuinely goes cold.
					coals = smoothstep(0.34, 0.92, coals);
					light += vec3(1.0, 0.55, 0.25) * coals * embers_gain * mask.r;
				} else if (field == FIELD_OCEAN) {
					// Caustics: two fields at different scales drifting different
					// ways, multiplied so only where both are bright does anything
					// show, then sharpened into threads. The product is what makes
					// the pattern move like water rather than like two clouds.
					float ripple_a = value_noise(
						page_position * ocean_scale_a + vec2(t * 0.070, t * 0.028)
					);
					float ripple_b = value_noise(
						page_position * ocean_scale_b + vec2(-t * 0.041, t * 0.062)
					);
					float caustic = pow(
						clamp(ripple_a * ripple_b * 2.6, 0.0, 1.0), ocean_sharpness
					);
					light += vec3(0.80, 0.94, 1.0) * caustic * ocean_gain * mask.r;
				} else {
					// Aurora: shimmer's travelling band, much wider and much slower,
					// and it turns the wax's HUE instead of washing it white. Global
					// in page space for exactly shimmer's reason -- two aurora strokes
					// that touch must show ONE curtain crossing both.
					float axis = dot(page_position, vec2(0.7071, -0.7071)) / diagonal + 0.5;
					float offset = axis - fract(t * aurora_speed);
					offset -= floor(offset + 0.5);
					float u = offset / max(aurora_width, 1e-6);
					float envelope = exp(-u * u * 0.5);
					// The swing is a SINE across the curtain, so the leading edge
					// turns the colour one way and the trailing edge the other and
					// the middle passes through the wax's own hue. A single-signed
					// shift would read as the page changing colour, not as something
					// crossing it.
					//
					// The ENVELOPE is the mix weight, not a second factor on the
					// angle: damping the rotation by the same curve that already
					// decides how much of it is applied squares it, and the first
					// cut of this shipped a ~5-degree swing where ~20 was intended.
					// Peak effective rotation is sin(1.6u)*exp(-u^2/2) -- 0.71, at
					// u ~ 0.72 -- times the swing times the level: ~0.35 rad.
					hue_angle = sin(u * 1.6) * aurora_swing;
					hue_weight = envelope * mask.r;
					light += vec3(1.0) * envelope * aurora_gain * mask.r;
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
					// Firefly dust: the speck WANDERS instead of winking where it
					// sits. Its home is kept off the cell's edges and the wander is
					// a fraction of a cell, because only fragments inside the cell
					// draw its speck -- a centre that strayed over the edge would be
					// sliced in half by the boundary it crossed. The skirt of the
					// widest specks still is; see the uniform block above.
					vec2 cell = floor(page_position / firefly_cell);
					float rate = mix(0.30, 0.85, hash21(cell + 12.7));
					float phase = hash21(cell + 9.1) * TAU + mask.b * TAU;
					// Twinkle puts its wink exactly on the fleck brush.gdshader baked,
					// because a wink that missed its own glitter would read as two
					// effects. A WANDERER must not: it starts near the baked mote and
					// drifts off it, which is the whole idea, so its home is the same
					// hash pulled into the middle half of the cell instead.
					vec2 home = vec2(0.24) + vec2(hash21(cell + 2.3), hash21(cell + 4.7)) * 0.52;
					vec2 wander = vec2(
						sin(t * rate + phase),
						cos(t * rate * 0.83 + phase * 1.7)
					) * firefly_wander;
					vec2 centre = (cell + home + wander) * firefly_cell;
					// Not every cell carries one -- dust is sparse or it is glitter.
					// A cell hash, never the stroke seed: the display shader is not
					// told which stroke a texel came from, only how alive it is.
					float present = step(0.34, hash21(cell + 13.9));
					// Each speck swells as it drifts and fades again, on its own
					// rate, so the field reads as things moving rather than blinking.
					float swell = 0.18 + 0.82 * pow(max(sin(t * rate * 1.7 + phase * 0.6), 0.0), 1.6);
					float radius = mix(2.2, 4.2, hash21(cell + 6.1)) * mix(0.65, 1.3, swell);
					float core = clamp(
						1.0 - length(page_position - centre) / max(radius, 0.001), 0.0, 1.0
					);
					light += vec3(1.0, 0.95, 0.72)
						* pow(core, 0.75) * swell * present * firefly_gain * mask.g;
				}
			}

			// The aurora's rotation, weighted by the WAX's own alpha for the same
			// reason every addition below is: outside the paint there is nothing to
			// turn, and half-covered wax must only be half-turned or the dab's soft
			// edge would come back as a hard colour boundary.
			if (hue_weight > 0.0) {
				wax.rgb = mix(
					wax.rgb, hue_shift(wax.rgb, hue_angle), clamp(hue_weight * wax.a, 0.0, 1.0)
				);
			}
			// Scaled by the WAX's own alpha: the animation can only ever brighten
			// paint that is already there, never the paper beside it.
			wax.rgb += light * wax.a;
		}
	}
	COLOR = wax * COLOR;
}

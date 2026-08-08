shader_type canvas_item;
render_mode blend_mix, unshaded;

// Brush stamp shader for the constrained painting stack (DESIGN.md 3.2).
//
// Each stamp is an axis-aligned quad drawn into the paint SubViewport in *page
// pixel* coordinates. The fragment stage does three things:
//   1. shapes the quad into a soft round dab (UV based radial falloff),
//   2. HARD-clips the dab to the locked region by sampling the ID map and
//      discarding every fragment whose ID-map texel differs from the locked
//      region's id_color, and
//   3. applies the crayon box's FINISH (BL-35) -- glow, grain or glitter -- to the
//      colour and alpha the dab lays down.
// The clip is a discard, never a blend, so region boundaries stay hard-edged
// no matter how soft the brush is -- and that includes a glow halo, which is
// clipped fragment by fragment exactly like the core of the dab. A finish can
// never leak across a line.
//
// BL-38 gave the same shader a SECOND JOB: with `effect_target == TARGET_MASK` it
// draws the identical dab into the effect-mask SubViewport, writing the finish's
// animation payload instead of wax. One shader, so the mask cannot cover a pixel
// the wax does not, and the region discard below owns both passes.
//
// FINISHES ARE BAKED HERE (BL-35 phase 1). The paint layer is flattened into the
// SubViewport and saved as a PNG, so an effect computed at stamp time persists for
// free -- no effect channel, no per-stroke metadata for the restore path to keep.
// Every finish is a function of the fragment's PAGE POSITION and the stroke's seed,
// never of which dab it happens to be in: a stroke overlaps its own dabs by ~87%,
// so a per-dab effect would be re-blended eight times over at each pixel and
// average itself flat. A page-space field is idempotent under that overlap, which
// is also what keeps a BL-17 replay pixel-exact.

// Region ID map for the page. `filter_nearest` is set HERE, at the usage site --
// filtering is not an import flag in Godot 4 and the .import file must keep its
// lossless settings untouched. Interpolating this texture would fabricate region
// ids that do not exist and bleed paint across boundaries.
uniform sampler2D id_map : filter_nearest, repeat_disable, hint_default_black;

// Size of the page / ID map in pixels. Used to turn page pixel coordinates into
// ID-map UVs.
uniform vec2 page_size = vec2(1024.0, 1024.0);

// The locked region's id_color, as raw 0..1 texel values (id_byte / 255.0).
// vec3(0.0) is #000000 = line art / unpaintable, which never locks, so the
// default value paints nothing.
uniform vec3 locked_id_color = vec3(0.0);

// Half of one 8-bit step. Anything closer than this is the same quantised byte;
// anything further is a different region. RGB8 ids are exactly 1/255 apart, so
// this can never confuse two neighbouring ids.
uniform float id_epsilon = 0.00196078;

// 0 = fully feathered dab, 1 = hard circular dab. Only affects the brush edge;
// the region clip is unaffected.
uniform float hardness : hint_range(0.0, 1.0) = 0.85;

// ---------------------------------------------------------------- finish (BL-35)
// Which finish this batch paints with. The numbers are BrushFinish.MODE_* and the
// two lists must be read together.
const int MODE_CLASSIC = 0;
const int MODE_GLOW = 1;
const int MODE_GRAIN = 2;
const int MODE_GLITTER = 3;
// BL-38's animated finishes. Their BASE is baked here exactly like the four above --
// so a frozen page still reads as satin wax / glitter, and so the coverage tracker
// sees the same paint layer it has always seen. What keeps moving lives in the
// effect mask, which this same shader writes on a second pass (see TARGET_MASK).
const int MODE_SHIMMER = 4;
const int MODE_TWINKLE = 5;

uniform int effect_mode = 0;

// ---------------------------------------------------- the effect mask (BL-38)
// Which LAYER this batch is drawing into. The two passes are the same dab, the
// same soft edge and above all the SAME region discard -- only the colour written
// at the very end differs. That is the whole reason the animated sheen can never
// cross a region boundary: it is not composited over the page, it is stamped into
// a mask that was clipped by the ID map fragment for fragment.
const int TARGET_WAX = 0;
const int TARGET_MASK = 1;
uniform int effect_target = 0;

// The mask payload for this batch (BrushFinish.mask_payload): red = travelling
// sheen, green = winking specks, blue = the stroke's own phase. Every finish writes
// one, and a bakeable finish's is zero -- which is how ordinary wax painted on top
// of a shimmer takes the shimmer off again, through the ordinary alpha blend.
uniform float effect_sheen = 0.0;
uniform float effect_spark = 0.0;
uniform float effect_phase = 0.0;
// How much bigger than the DAB the quad was drawn (BrushFinish.quad_scale). 1.0
// for every finish that stays inside the brush; the glow spills, so its quad is
// wider and this scales the radial distance back into dab-radius units. A dab
// radius therefore means the same thing at every scale.
uniform float quad_scale = 1.0;
// Per-finish intensity dial, 1.0 as authored. Kept as a uniform so a finish can be
// toned down without a shader edit.
uniform float effect_strength = 1.0;
// Per-STROKE seed (BrushFinish.seed_for), carried in the BL-17 recipe. It picks the
// grain's angle and the glitter's speck layout, so two strokes differ and a replayed
// stroke does not.
uniform float effect_seed = 0.0;

// Stamp position in page pixel space, interpolated across the quad.
varying vec2 page_position;

// Cheap deterministic hash -- same value for the same page pixel in every dab that
// covers it, which is the property the whole finish system rests on.
float hash21(vec2 p) {
	vec2 q = fract(p * vec2(123.34, 456.21));
	q += dot(q, q + 45.32);
	return fract(q.x * q.y);
}

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

// Rotation about the grey axis: a hue shift without an RGB->HSV round trip.
vec3 hue_shift(vec3 color, float radians_) {
	const vec3 k = vec3(0.57735026919);
	float c = cos(radians_);
	return color * c + cross(k, color) * sin(radians_) + k * dot(k, color) * (1.0 - c);
}

// The wax "tooth": stretched streaks along `dir`, plus a fine speckle. 0 = a groove
// the crayon skipped, 1 = a ridge it pressed into.
float wax_grain(vec2 dir) {
	vec2 across = vec2(-dir.y, dir.x);
	vec2 g = vec2(dot(page_position, dir) * 0.042, dot(page_position, across) * 0.40);
	float streak = value_noise(g) * 0.66 + value_noise(g * 2.7) * 0.34;
	float tooth = value_noise(page_position * 0.85);
	return clamp(streak * 0.76 + tooth * 0.24, 0.0, 1.0);
}

// The SATIN tooth (BL-38's shimmer base): the same idea as wax_grain, stretched
// longer and much lower in contrast, so the wax reads as polished rather than
// scratchy and the travelling sheen has something to slide over.
float silk_grain(vec2 dir) {
	vec2 across = vec2(-dir.y, dir.x);
	vec2 g = vec2(dot(page_position, dir) * 0.019, dot(page_position, across) * 0.21);
	return clamp(value_noise(g) * 0.72 + value_noise(g * 3.3) * 0.28, 0.0, 1.0);
}

void vertex() {
	page_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// --- round dab ---------------------------------------------------------
	// Distance from the dab centre in units of the DAB radius: 1.0 is the dab's
	// own edge, and a finish with a wider quad runs out to quad_scale.
	float d = length(UV * 2.0 - 1.0) * quad_scale;
	if (d > quad_scale) {
		discard;
	}

	// --- region clip -------------------------------------------------------
	vec2 id_uv = page_position / page_size;
	if (id_uv.x < 0.0 || id_uv.y < 0.0 || id_uv.x >= 1.0 || id_uv.y >= 1.0) {
		discard;
	}
	vec3 sampled = texture(id_map, id_uv).rgb;
	vec3 delta = abs(sampled - locked_id_color);
	if (max(delta.r, max(delta.g, delta.b)) > id_epsilon) {
		discard;
	}

	// --- soft edge ---------------------------------------------------------
	float falloff = 1.0 - smoothstep(hardness, 1.0, d);
	vec3 wax = COLOR.rgb;
	float alpha = falloff;
	vec2 dir = vec2(cos(effect_seed), sin(effect_seed));

	if (effect_mode == MODE_GLOW) {
		// Neon tube: the dab itself is lit ink -- brightened and lifted towards
		// white UNIFORMLY, never as a gradient across the dab, because the next
		// dab overlaps this one by ~87% and would simply paint its own gradient
		// over the top (the last dab would win and only the final one of a stroke
		// would keep its core). Around it, a halo spilling out to the edge of the
		// widened quad in the crayon's own colour: thin per dab, because a stroke
		// stacks its own halos into the bloom.
		//
		// The halo is the SAME lit colour as the core, not the crayon's darker own:
		// a later dab's halo lands on an earlier dab's core, and any colour
		// difference between the two would show up as a scalloped chain of rings
		// down the stroke instead of a tube.
		float halo = pow(clamp(1.0 - (d - 1.0) / max(quad_scale - 1.0, 0.001), 0.0, 1.0), 2.4);
		wax = mix(wax, clamp(wax * 1.32 + vec3(0.16), vec3(0.0), vec3(1.0)), effect_strength);
		alpha = max(falloff, halo * 0.22 * effect_strength);
	} else if (effect_mode == MODE_GRAIN) {
		if (d > 1.0) {
			discard;
		}
		float grain = wax_grain(dir);
		// The GROOVES are the effect, and they are a colour, not a hole: an alpha
		// hole would be filled in by the next overlapping dab, a colour would not.
		wax = mix(wax * 0.70, clamp(wax * 1.12 + vec3(0.04), vec3(0.0), vec3(1.0)), grain);
		alpha = falloff * mix(0.82, 1.0, grain);
	} else if (effect_mode == MODE_GLITTER) {
		if (d > 1.0) {
			discard;
		}
		// Wax first, so the glitter sits IN something.
		float grain = wax_grain(dir);
		wax = mix(wax * 0.82, clamp(wax * 1.08, vec3(0.0), vec3(1.0)), grain);
		// Slow rainbow bands drifting across the page: the same crayon, shimmering.
		float band = sin(dot(page_position, dir) * 0.011 + effect_seed);
		wax = clamp(hue_shift(wax, band * 0.42 * effect_strength), vec3(0.0), vec3(1.0));
		// Specks of glitter on a jittered page-space grid. Page space, so every dab
		// that covers a speck draws the same speck in the same place.
		const float CELL = 21.0;
		vec2 cell = floor(page_position / CELL);
		vec2 jitter = vec2(hash21(cell + 1.7), hash21(cell + 3.1));
		float speck = 0.0;
		if (hash21(cell + effect_seed) > 0.46) {
			float radius = mix(2.0, 5.0, hash21(cell + 5.3));
			speck = clamp(1.0 - length(page_position - (cell + jitter) * CELL) / radius, 0.0, 1.0);
			speck = pow(speck, 0.55) * effect_strength;
		}
		// Glitter never escapes the dab: it fades out with the brush edge.
		speck *= smoothstep(1.0, 0.72, d);
		wax = mix(wax, vec3(1.0), speck * 0.92);
		alpha = max(falloff, speck);
	} else if (effect_mode == MODE_SHIMMER) {
		if (d > 1.0) {
			discard;
		}
		// Satin wax: a long, low-contrast tooth and a lift towards white, so the
		// BAKED half already reads as something polished. The sheen that travels
		// over it is not here -- it cannot be, it would be flattened the moment it
		// was stamped. It is in the mask, and paint_display.gdshader moves it.
		float silk = silk_grain(dir);
		wax = mix(wax * 0.94, clamp(wax * 1.20 + vec3(0.07), vec3(0.0), vec3(1.0)), silk);
		alpha = falloff;
	} else if (effect_mode == MODE_TWINKLE) {
		if (d > 1.0) {
			discard;
		}
		// The loudest box: glitter that will actually sparkle. The specks are baked
		// so the wax is glittery with the animation frozen (and so a page saved on a
		// device without the display shader still looks like glitter); the WINK is
		// the mask's green channel, driven by TIME in the display shader.
		float twinkle_tooth = wax_grain(dir);
		wax = mix(wax * 0.80, clamp(wax * 1.14, vec3(0.0), vec3(1.0)), twinkle_tooth);
		const float TWINKLE_CELL = 17.0;
		vec2 twinkle_cell = floor(page_position / TWINKLE_CELL);
		vec2 twinkle_jitter = vec2(hash21(twinkle_cell + 2.3), hash21(twinkle_cell + 4.7));
		float fleck = 0.0;
		if (hash21(twinkle_cell + effect_seed) > 0.40) {
			float fleck_radius = mix(1.8, 4.4, hash21(twinkle_cell + 6.1));
			fleck = clamp(
				1.0 - length(page_position - (twinkle_cell + twinkle_jitter) * TWINKLE_CELL)
					/ fleck_radius,
				0.0, 1.0
			);
			fleck = pow(fleck, 0.5) * effect_strength;
		}
		fleck *= smoothstep(1.0, 0.70, d);
		wax = mix(wax, vec3(1.0), fleck * 0.95);
		alpha = max(falloff, fleck);
	}

	// --- the effect mask (BL-38) -------------------------------------------
	// Same dab, same discard, same alpha; only the colour changes. Writing the
	// payload HERE rather than in a shader of its own is what guarantees the mask
	// and the wax cover exactly the same pixels -- a mask that was a fraction of a
	// pixel wider would let a sheen sit on a boundary it must never touch.
	if (effect_target == TARGET_MASK) {
		wax = vec3(effect_sheen, effect_spark, effect_phase);
	}

	if (alpha <= 0.0) {
		discard;
	}
	COLOR.rgb = wax;
	COLOR.a *= alpha;
}

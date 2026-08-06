shader_type canvas_item;
render_mode blend_mix, unshaded;

// Brush stamp shader for the constrained painting stack (DESIGN.md 3.2).
//
// Each stamp is an axis-aligned quad drawn into the paint SubViewport in *page
// pixel* coordinates. The fragment stage does two things:
//   1. shapes the quad into a soft round dab (UV based radial falloff), and
//   2. HARD-clips the dab to the locked region by sampling the ID map and
//      discarding every fragment whose ID-map texel differs from the locked
//      region's id_color.
// The clip is a discard, never a blend, so region boundaries stay hard-edged
// no matter how soft the brush is.

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

// Stamp position in page pixel space, interpolated across the quad.
varying vec2 page_position;

void vertex() {
	page_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// --- round dab ---------------------------------------------------------
	float r = length(UV * 2.0 - 1.0);
	if (r > 1.0) {
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
	float falloff = 1.0 - smoothstep(hardness, 1.0, r);
	if (falloff <= 0.0) {
		discard;
	}
	COLOR.a *= falloff;
}

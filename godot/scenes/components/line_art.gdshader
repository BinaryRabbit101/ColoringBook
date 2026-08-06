shader_type canvas_item;
render_mode blend_mix, unshaded;

// Line-art layer of the page stack (DESIGN.md 3.2: lines are drawn ON TOP of the
// paint layer, transparent everywhere else).
//
// The mapping pipeline accepts source art that is either "dark lines on
// transparent" or "dark lines on white paper". The second form is opaque, so
// blitting it straight on top would hide the paint layer completely. When
// `white_to_alpha` is on, this shader recovers the ink's alpha from its
// luminance and un-premultiplies the colour that the artwork had composited
// over white paper:
//
//     composited = ink_rgb * a + white * (1 - a)   with   a = 1 - luminance
//  => ink_rgb    = (composited - (1 - a)) / a
//
// which reproduces anti-aliased edges exactly instead of washing them out, and
// keeps coloured line work coloured.
uniform bool white_to_alpha = true;

// NOTE: Godot forbids `return` inside fragment(), so this branches by mixing.
void fragment() {
	// COLOR already is texture(TEXTURE, UV) * vertex colour.
	vec4 src = COLOR;
	float ink_alpha = clamp(1.0 - max(src.r, max(src.g, src.b)), 0.0, 1.0);
	vec3 ink_rgb = clamp(
		(src.rgb - (1.0 - ink_alpha)) / max(ink_alpha, 0.0001),
		vec3(0.0),
		vec3(1.0)
	);
	float enabled = white_to_alpha ? 1.0 : 0.0;
	COLOR = vec4(
		mix(src.rgb, ink_rgb, enabled),
		src.a * mix(1.0, ink_alpha, enabled)
	);
}

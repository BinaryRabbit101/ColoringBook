shader_type canvas_item;
render_mode blend_mix, unshaded;

// Page-turn shader for PageFlip (BL-4).
//
// The whole turn is ONE full-screen quad carrying the snapshot of the page being
// turned away. There is no geometry, no render target and no second pass: every
// fragment works out for itself which part of the folding sheet of paper is
// standing over it. Two texture fetches at worst, a handful of ALU ops -- cheap
// enough for the mobile pass and for the web export.
//
// GEOMETRY. The sheet lies flat over UV.x in [0, 1] with the spine at x = 0. A
// fold line at x = `fold` sweeps from past the free edge (progress 0) to the
// spine (progress 1). Everything beyond the fold has been peeled up, wrapped over
// a half cylinder of radius `curl_radius` standing on the fold line, and laid
// back down across the page it came from. So at any moment a column of the screen
// shows one of four things, nearest the eye first:
//
//   x > fold                      nothing -- only the SHADOW the lifted paper
//                                 throws on whatever is rendering underneath
//   fold - r .. fold              the crease: far side of the roll (the BACK of
//                                 the paper), or its near side where the sheet
//                                 ran out before it finished wrapping
//   flap_edge .. fold - r         the flat part of the folded-over flap, again
//                                 the back of the paper
//   0 .. flap_edge                the still-flat page, shaded where the flap's
//                                 free edge shadows it
//
// `fold_tilt` leans the fold line across the page so the turn peels diagonally,
// the way a thumb actually lifts a corner, instead of sliding a vertical bar.
//
// At progress 0 the fold sits off the right edge, so every fragment falls through
// to the "still-flat page" branch and the output is PIXEL-EXACT the snapshot.
// PageFlip.prepare() relies on that: it covers the live screen with this quad
// before anything moves, and the swap must be invisible.

// 0 = flat page, 1 = fully turned away.
uniform float progress : hint_range(0.0, 1.0) = 0.0;
// Radius of the crease cylinder, in UV x units.
uniform float curl_radius : hint_range(0.01, 0.40) = 0.085;
// How far the fold line leans across the page, in UV x per full page height.
uniform float fold_tilt : hint_range(-0.40, 0.40) = 0.10;
// Colour of the reverse of the sheet.
uniform vec4 paper_color : source_color = vec4(0.937255, 0.913725, 0.866667, 1.0);
// How much of the printed side shows through the paper from behind.
uniform float back_bleed : hint_range(0.0, 1.0) = 0.10;
// Peak darkness of the shadow the lifted paper casts.
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.55;
// Falloff distance of that shadow, in UV x units.
uniform float shadow_width : hint_range(0.005, 0.5) = 0.075;

const float PI_F = 3.14159265359;
const float HALF_PI = 1.57079632679;

void fragment() {
	float r = max(curl_radius, 0.001);
	float half_tilt = abs(fold_tilt) * 0.5;
	// Start past the free edge so nothing curls yet; finish past the spine so the
	// last frame is empty however the fold is tilted.
	float fold = mix(1.0 + r + half_tilt, -half_tilt - 0.02, progress)
		+ fold_tilt * (UV.y - 0.5);
	// The cast shadow fades out with the paper itself, so the frame the overlay
	// hides on is not a dark band snapping off screen.
	float shadow = shadow_strength * smoothstep(1.0, 0.80, progress);

	vec3 rgb = vec3(0.0);
	float alpha = 0.0;

	if (UV.x > fold) {
		// The paper has left this column; all that is left of it is its shadow.
		alpha = shadow * exp(-(UV.x - fold) / shadow_width);
	} else {
		float d = fold - UV.x;
		// Where the sheet's free edge lands once it is folded back over.
		float flap_edge = 2.0 * fold - 1.0 + r * (PI_F - 1.0);
		bool drawn = false;

		if (d <= r) {
			// The crease. A point at angle `a` off the fold line projects to
			// x = fold - r * sin(a), so each column of the crease is hit twice:
			// once by the near side rising off the page (a), once by the far side
			// coming back over the top (PI - a). The far side is what the eye sees.
			float a = asin(clamp(d / r, 0.0, 1.0));
			float src_far = fold + r * (PI_F - a);
			float src_near = fold + r * a;
			if (src_far <= 1.0) {
				vec3 ink = texture(TEXTURE, vec2(src_far, UV.y)).rgb;
				// Brightest along the ridge, falling away to the flap plane.
				rgb = mix(paper_color.rgb, ink, back_bleed)
					* mix(0.80, 1.16, (HALF_PI - a) / HALF_PI);
				alpha = 1.0;
				drawn = true;
			} else if (src_near <= 1.0) {
				// The sheet ran out before it wrapped: the printed side is on show,
				// turning away from the light as it rises.
				vec4 ink = texture(TEXTURE, vec2(src_near, UV.y));
				rgb = ink.rgb * mix(1.0, 0.78, a / HALF_PI);
				alpha = ink.a;
				drawn = true;
			}
		} else if (UV.x >= flap_edge) {
			// Flat part of the folded-over flap, lying back across the page. Arc
			// length is mirrored about the fold, plus the r*(PI-1) the crease ate.
			float src = 2.0 * fold - UV.x + r * (PI_F - 1.0);
			if (src <= 1.0) {
				vec3 ink = texture(TEXTURE, vec2(src, UV.y)).rgb;
				rgb = mix(paper_color.rgb, ink, back_bleed)
					* mix(0.68, 0.80, smoothstep(0.0, 0.08, UV.x - flap_edge));
				alpha = 1.0;
				drawn = true;
			}
		}

		if (!drawn) {
			// Still-flat page, darkened where the flap's free edge shadows it.
			vec4 page = texture(TEXTURE, UV);
			float has_flap = step(flap_edge, fold - r) * step(UV.x, flap_edge);
			float under = has_flap * exp(-(flap_edge - UV.x) / shadow_width);
			rgb = page.rgb * (1.0 - clamp(shadow * under, 0.0, 0.8));
			alpha = page.a;
		}
	}

	COLOR = vec4(rgb, alpha);
}

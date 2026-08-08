shader_type canvas_item;
render_mode blend_mix, unshaded;

// The paint layer's DISPLAY shader (BACKLOG BL-38).
//
// It draws the paint SubViewport's texture, and -- only where the EFFECT MASK says
// so -- adds an animated highlight on top of it. This is the whole of the animated
// half of the finish ladder: a sheen that travels across shimmer wax, and specks
// that wink in and out of twinkle wax.
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
//     layer's own alpha, so a mask texel with no wax under it lights nothing.
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
//   r = travelling sheen, g = winking specks, b = the stroke's own phase,
//   a = the coverage the stamp had (so the animation feathers with the dab).
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

// Same hash the brush shader uses, for the same reason: the speck grid has to be a
// function of the page pixel and nothing else, so it is stable under pan, zoom and
// a page reopened tomorrow.
float hash21(vec2 p) {
	vec2 q = fract(p * vec2(123.34, 456.21));
	q += dot(q, q + 45.32);
	return fract(q.x * q.y);
}

void fragment() {
	vec4 wax = texture(TEXTURE, UV);
	if (effect_enabled) {
		vec4 mask = texture(effect_mask, UV);
		if (mask.r > 0.002 || mask.g > 0.002) {
			float t = effect_animated ? TIME : 0.0;
			vec2 page_position = UV * page_size;
			float diagonal = max(page_size.x + page_size.y, 1.0);
			vec3 light = vec3(0.0);

			// --- the travelling sheen (shimmer) ---------------------------------
			// A soft band sweeping the page along its diagonal. It is GLOBAL, not
			// per stroke: two shimmer strokes that touch must show one sheen
			// crossing both, or the seam between them becomes the thing you look at.
			if (mask.r > 0.002) {
				float axis = dot(page_position, vec2(0.7071, -0.7071)) / diagonal + 0.5;
				float offset = axis - fract(t * shimmer_speed);
				// Wrap into -0.5..0.5 so the band re-enters the page instead of
				// jumping when the clock wraps.
				offset -= floor(offset + 0.5);
				float band = exp(-(offset * offset) / max(shimmer_width * shimmer_width, 1e-6));
				light += vec3(1.0) * band * shimmer_gain * mask.r;
			}

			// --- the wink (twinkle) ---------------------------------------------
			// One speck per page-space cell, jittered inside it, pulsing on its own
			// phase. The cell's phase comes from the cell (so it is the same speck
			// tomorrow) PLUS the stroke's phase from the mask's blue channel (so two
			// strokes do not blink in lockstep).
			if (mask.g > 0.002) {
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
			}

			// Scaled by the WAX's own alpha: the animation can only ever brighten
			// paint that is already there, never the paper beside it.
			wax.rgb += light * wax.a;
		}
	}
	COLOR = wax * COLOR;
}

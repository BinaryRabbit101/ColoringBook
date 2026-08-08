shader_type canvas_item;
render_mode blend_mix, unshaded;

// Start over, as a soapy wash over the page (replaces BL-29's sliding sheet).
//
// ONE quad over the page rect, ONE `progress` uniform, and no CPU work at all
// between frames -- the whole effect is this fragment function evaluated with a
// different number in it. It is pure decoration: the paint layer, the tracker, the
// saved PNG and the recorded erase are already gone by the time frame 0 of this
// draws, and nothing anywhere waits for it (see PageWash).
//
// THE SHAPE OF IT, in three acts along `progress`:
//
//   0 .. SWEEP_END   a front of foam runs across the page, wobbling as it goes,
//                    leaving an opaque film of paper-coloured suds behind it. This
//                    is the act that HIDES the clear: the picture is already gone,
//                    and what the eye follows is the flannel, not the vanishing.
//   .. SCRUB_END     the page is covered and scrubbed: bubbles drift up through the
//                    film, wink, and catch an iridescent rim.
//   .. 1             the film breaks up. Holes open where a rising noise field says
//                    so, bubbles pop along their edges, and the blank page comes
//                    through. The film never fades as ONE rectangle -- a global
//                    alpha ramp is exactly the "cheap" look this replaces.
//
// FOUR RULES IT KEEPS:
//
//  1. NO FLASH. The brightest thing here is the paper colour it is handed, which is
//     the page's own paper; the bubble rims add at most ~0.5 over a few pixels of
//     ring. BL-29's white bloom over the whole page (alpha 0.42, peaking on the one
//     frame the effect was loudest) is the thing a playtester called flash-blind,
//     and there is deliberately no uniform here that could bring it back.
//  2. Everything is a function of PAGE PIXELS, not UV. The bubbles have to be ROUND
//     on a page of any aspect, and the same size on a tall page as on a wide one.
//     (The same rule BL-35's finishes follow, for the neighbouring reason.)
//  3. Bubbles are looked up in ONE cell each, never a 3x3 neighbourhood: the jitter
//     is clamped so a bubble cannot cross its cell edge, so a single fetch is exact
//     rather than approximate. Two layers at different scales break up the grid,
//     which costs two lookups instead of nine.
//  4. `reduced` is a real fallback, not a slower version of the same thing: it
//     leaves ONE opaque paper film easing away. Worst case is a quick fade, which
//     is the floor this effect promises and never a flash.

// 0 -> 1 across the whole run. Driven by PageWash; nothing else writes it.
uniform float progress : hint_range(0.0, 1.0) = 0.0;
// Seconds elapsed, for the churn that is not tied to the timeline (bubbles wink and
// drift at their own rate). Passed rather than read from TIME so two washes started
// on the same frame are identical and a screenshot is reproducible.
uniform float elapsed = 0.0;
// The page rect in PIXELS -- rule 2 above.
uniform vec2 rect_size = vec2(512.0, 512.0);
// Rerolled per wash, so the same page cleared twice is not the same animation.
uniform float seed = 0.0;

// The film's body colour: the page's own paper, so full cover reads as a blank
// sheet rather than as a bright panel laid over one.
uniform vec4 paper : source_color = vec4(0.984314, 0.964706, 0.917647, 1.0);
// The soap in it -- a cold tint the warm paper is mixed towards, which is what says
// "wet" without saying "white".
uniform vec4 suds : source_color = vec4(0.803922, 0.905882, 0.976471, 1.0);

// Corner rounding, so the film reads as a sheet of something rather than a screen
// wipe (the one piece of BL-29's sheet worth keeping).
uniform float corner_radius = 16.0;
// Bubble grid pitch in page pixels: the big lazy ones, and the fine foam.
uniform float bubble_cell = 58.0;
uniform float foam_cell = 24.0;
// Reduced motion / low-end: one paper film, eased away. See rule 4.
uniform bool reduced = false;

// Where the sweep ends and the scrub ends, as fractions of `progress`.
// (TAU is a Godot shader built-in -- do not redeclare it, that is a compile error.)
const float SWEEP_END = 0.26;
const float SCRUB_END = 0.52;


float hash21(vec2 p) {
	vec2 q = fract(p * vec2(123.34, 456.21));
	q += dot(q, q + 45.32);
	return fract(q.x * q.y);
}


// Smooth value noise. Two of these are the whole of the wobble and the break-up.
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}


// Two octaves, for the sweep front's wobble. A lattice in a DISPLACEMENT is
// invisible, so the cheap version is the right one here.
float fbm2(vec2 p) {
	return value_noise(p) * 0.65 + value_noise(p * 2.17 + 11.3) * 0.35;
}


// Three octaves, each ROTATED, for the break-up. Thresholding a field is where a
// value-noise lattice shows: axis-aligned octaves put straight horizontal and
// vertical edges on every hole, and the film tears into rectangles instead of
// bubbles. Turning each octave off-axis is what costs one extra fetch and buys the
// round break-up back.
float fbm3(vec2 p) {
	mat2 turn = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	float v = value_noise(p) * 0.55;
	p = turn * p * 2.13 + 11.3;
	v += value_noise(p) * 0.30;
	p = turn * p * 2.07 + 5.71;
	return v + value_noise(p) * 0.15;
}


// Signed distance to a rounded box centred on the origin. Negative inside.
float rounded_box(vec2 p, vec2 half_size, float radius) {
	vec2 q = abs(p) - half_size + radius;
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}


// ONE bubble, in the cell of `cell_size` that `p` falls in (rule 3). Returns the
// rim (x), the little specular highlight (y), the body wash (z) and the angle round
// the rim (w), which is what the iridescence is a function of.
vec4 bubble(vec2 p, float cell_size, float drift, float phase) {
	// Bubbles rise. The drift is along the page, not along UV, so they rise at the
	// same speed whatever shape the page is.
	vec2 grid = (p + vec2(0.0, drift)) / cell_size;
	vec2 id = floor(grid);
	vec2 f = fract(grid);

	float r = mix(0.16, 0.38, hash21(id + seed * 1.7 + phase));
	// Centre kept a full radius inside the cell, which is what makes the one-cell
	// lookup exact instead of clipping bubbles at the cell edge.
	vec2 centre = vec2(
		mix(r, 1.0 - r, hash21(id + 7.31 + phase)),
		mix(r, 1.0 - r, hash21(id + 13.77 + phase))
	);
	vec2 delta = f - centre;
	float dist = length(delta);

	// Each bubble breathes on its own phase, so the foam churns rather than sits.
	float own = hash21(id + 3.19 + phase) * TAU;
	float life = 0.45 + 0.55 * sin(elapsed * 3.1 + own);
	life = clamp(life, 0.0, 1.0);

	float edge = cell_size * 0.012;
	float rim = smoothstep(r, r - 0.055 - edge, dist) - smoothstep(r - 0.075, r - 0.15, dist);
	float body = smoothstep(r, r - 0.04, dist);
	// A single bright dot up and left of centre: the thing that makes a ring read as
	// a sphere rather than a doughnut.
	float spec = smoothstep(r * 0.30, 0.0, length(delta + vec2(r * 0.34, r * 0.34)));

	return vec4(rim * life, spec * life, body * life * 0.22, atan(delta.y, delta.x));
}


// Pastel soap-film iridescence, from the angle round a bubble's rim plus its own
// offset. A cosine palette rather than a texture: three multiply-adds, no fetch.
vec3 iridescence(float angle, float offset) {
	float hue = fract(angle / TAU * 0.55 + offset + elapsed * 0.08);
	return 0.62 + 0.38 * cos(TAU * (hue + vec3(0.0, 0.33, 0.67)));
}


void fragment() {
	vec2 px = UV * rect_size;
	// The sheet's own silhouette. Everything below is multiplied by this, so nothing
	// -- film, foam or a stray bubble -- ever paints a square corner over the page.
	float sheet = clamp(
		0.5 - rounded_box(px - rect_size * 0.5, rect_size * 0.5, corner_radius),
		0.0, 1.0
	);

	if (reduced) {
		// Rule 4: one film, eased off. No noise, no bubbles, no per-pixel break-up --
		// and still never brighter than the paper it is made of.
		float fade = 1.0 - progress * progress;
		COLOR = vec4(paper.rgb, fade * sheet);
	} else {
		// --- act one: the front sweeps across ---------------------------------
		// Mostly left to right, leaning down the page, so it reads as an arm wiping
		// rather than a curtain dropping.
		//
		// The two guards in this branch are on `progress`, which is a UNIFORM: every
		// fragment of the draw takes the same side of them, so they are a coherent
		// branch and really do skip the work rather than execute both halves. The
		// sweep's noise is dead after act one and the break-up's is not alive until
		// act three, so at any instant this shader is paying for one of them, never
		// both.
		float covered = 1.0;
		float band = 0.0;
		if (progress < SWEEP_END) {
			float axis = UV.x * 0.82 + UV.y * 0.18;
			float wobble = (fbm2(px * 0.0075 + seed * 9.0) - 0.5) * 0.13;
			float sweep = clamp(progress / SWEEP_END, 0.0, 1.0);
			// Cubic ease-out: fast entry, gentle arrival.
			float eased = 1.0 - pow(1.0 - sweep, 3.0);
			float front = mix(-0.18, 1.20, eased);
			float here = axis + wobble;
			covered = 1.0 - smoothstep(front - 0.11, front + 0.01, here);
			// The wet edge itself: a narrow band of heavier foam riding the front.
			band = exp(-pow((here - front) / 0.06, 2.0)) * (1.0 - sweep * sweep);
		}

		// --- the foam ----------------------------------------------------------
		// Two layers at different pitches, both rising. Computed BEFORE the break-up,
		// because the break-up is keyed to them: a film full of bubbles should tear
		// where the bubbles are.
		vec4 big = bubble(px, bubble_cell, -elapsed * 26.0, 0.0);
		vec4 fine = bubble(px + vec2(bubble_cell * 0.37, 0.0), foam_cell, -elapsed * 41.0, 5.5);
		float rim = big.x + fine.x * 0.75;
		float spec = big.y + fine.y * 0.6;
		float body = big.z + fine.z;

		// --- act three: the film breaks up ------------------------------------
		float hole = 0.0;
		float breaking = 0.0;
		if (progress > SCRUB_END) {
			float dissolve = clamp((progress - SCRUB_END) / (1.0 - SCRUB_END), 0.0, 1.0);
			// The break-up field RISES, so the holes travel up the page like foam
			// draining off it, and the top goes slightly first.
			vec2 drifted = px + vec2(0.0, dissolve * rect_size.y * 0.22);
			float erode = fbm3(drifted * 0.026 + seed * 4.0) * 0.80 + UV.y * 0.14;
			// A bubble goes first. Subtracting its body from the threshold is what
			// makes the holes come out ROUND -- the film tears at the suds instead of
			// tearing in blobs of noise with bubbles painted over them.
			erode -= clamp(body * 1.7, 0.0, 0.30);
			// Narrow band: a hole opens over ~9% of the run rather than fading in,
			// which is the difference between popping and misting.
			hole = smoothstep(erode, erode + 0.09, dissolve * 1.32 - 0.10);
			// Peaks along the boundary between film and hole -- where the bubbles that
			// are actually popping live.
			breaking = clamp(hole * (1.0 - hole) * 4.0, 0.0, 1.0);
		}

		float film = clamp(covered * (1.0 - hole), 0.0, 1.0);

		// Foam is thickest on the wet front and along the breaking edge; the middle
		// of a settled film is calmer, or the whole page fizzes at once and reads as
		// noise rather than as suds.
		float foam = clamp(0.42 + band * 0.9 + breaking * 0.8, 0.0, 1.4);

		// Warm paper by default, cold only where it is WET -- the running front and
		// the tearing edge. A film that is cold all over reads as grey plastic.
		vec3 tint = mix(paper.rgb, suds.rgb, clamp(0.13 + band * 0.55 + breaking * 0.25, 0.0, 1.0));
		vec3 col = mix(tint, tint * 0.965, body * foam);
		vec3 sheen = mix(vec3(1.0), iridescence(big.w, hash21(floor(px / bubble_cell))), 0.6);
		col += rim * foam * 0.42 * sheen;
		col += spec * foam * 0.5;

		// Two things show OUTSIDE the film proper, and they are what stop each end of
		// the run looking like an alpha ramp: suds thrown ahead of the running front,
		// and bubbles still popping where the film has just torn.
		float fringe = band * (0.30 + rim * 1.6 + spec * 1.4) * (1.0 - covered);
		float loose = (rim + spec) * breaking * 0.85;
		float alpha = clamp(film + loose * covered + fringe, 0.0, 1.0);

		COLOR = vec4(col, alpha * sheet);
	}
}

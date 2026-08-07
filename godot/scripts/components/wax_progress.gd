extends Control
## The download strip in a [PackShop] row (BL-31): a crayon laying a wax stroke
## across the paper while the bytes arrive, and a small burst of confetti when the
## pack lands on the shelf.
##
## [b]Pure presentation.[/b] It is told a ratio and it draws one. It owns nothing
## the shop reasons about -- the row's state machine (available / confirm /
## downloading / installed / failed) drives this widget and never the other way
## round, which is why "it finished" arrives as a [method celebrate] call rather
## than as a state this file has to know about.
##
## [b]Three faces, all from the same real data[/b] (bytes off the wire, via
## [code]PackRow.set_downloading[/code]):
##
## 1. [b]Known size[/b] -- the stroke is exactly [method get_ratio] of the strip.
##    The drawn head EASES toward that ratio so a lumpy chunked download still
##    looks like a hand moving, but [method get_ratio] always answers with the
##    real number, immediately: the animation lags, the data never does.
## 2. [b]Unknown size[/b] (the server sent no content length) -- the crayon
##    scribbles gently back and forth leaving a short smear. It never pretends to
##    be a percentage, which is the whole point of an indeterminate bar.
## 3. [b]Done[/b] -- the stroke snaps full, the crayon hops, confetti flies, and
##    the strip fades itself out.
##
## Everything is drawn from primitives: this project ships no art.
##
## [b]No [code]class_name[/code] on purpose.[/b] [PackShop] preloads it into a
## constant instead, so the type resolves even in a build whose global-class cache
## has not been regenerated since this file appeared.

## Strip height. Tall enough for the crayon to stand on the wax band without
## reaching into the row above it.
const STRIP_HEIGHT := 48.0

## The crayon box. Warm and saturated, so a stroke reads against the shop's dark
## panel; deliberately this file's own list rather than the painting palette's --
## a shop row must not depend on what the coloring page happens to be holding.
const CRAYON_COLORS: Array[Color] = [
	Color(0.929412, 0.352941, 0.278431),
	Color(0.964706, 0.639216, 0.211765),
	Color(0.976471, 0.827451, 0.301961),
	Color(0.454902, 0.752941, 0.372549),
	Color(0.313726, 0.686275, 0.803922),
	Color(0.607843, 0.470588, 0.815686),
	Color(0.937255, 0.501961, 0.647059),
]

## The paper the stroke is laid on, and the guide line waiting to be coloured in.
const PAPER_COLOR := Color(0.933333, 0.909804, 0.847059, 0.14)
const GUIDE_COLOR := Color(0.933333, 0.909804, 0.847059, 0.30)

## How fast the drawn head chases the real ratio (exponential; ~0.3 s to settle).
const CATCH_UP := 9.0
## One there-and-back scribble when the total size is unknown.
const SWEEP_SECONDS := 1.7
## Length of the indeterminate smear, as a fraction of the strip.
const SMEAR_RATIO := 0.26
## The whole celebration, and the fade that ends it.
const CELEBRATION_SECONDS := 1.2
const CELEBRATION_FADE := 0.34
## Wax crumbs shed by the moving tip.
const CRUMB_LIFE := 0.65
const MAX_CRUMBS := 12
const CRUMB_GRAVITY := 220.0
## The finish burst. Slow and low: a few bits arcing over the row, not a firework
## that clears the panel before anyone has seen it.
const CONFETTI_COUNT := 18
const CONFETTI_GRAVITY := 460.0

var _target := 0.0
var _shown := 0.0
var _unknown := false
var _running := false
var _time := 0.0
## Seconds into the celebration, or -1 when there is not one.
var _celebrate_time := -1.0
var _color := CRAYON_COLORS[0]
var _crumbs: Array = []
var _confetti: Array = []
var _rng := RandomNumberGenerator.new()
var _paper := StyleBoxFlat.new()


func _init() -> void:
	custom_minimum_size = Vector2(0, STRIP_HEIGHT)
	# Decoration only: a strip across a row must never swallow a tap meant for the
	# row's button.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_rng.randomize()
	set_process(false)


# ======================================================================== api ==

## Starts a fresh download in [param color] and shows the strip.
func begin(color: Color) -> void:
	_color = color
	_target = 0.0
	_shown = 0.0
	_unknown = false
	_celebrate_time = -1.0
	_time = 0.0
	_crumbs.clear()
	_confetti.clear()
	_running = true
	visible = true
	set_process(true)
	queue_redraw()


## The real progress. A negative [param ratio] means "total unknown", which is the
## indeterminate scribble rather than a zero-length stroke.
func set_progress(ratio: float) -> void:
	if not _running:
		begin(_color)
	_unknown = ratio < 0.0
	if _unknown:
		_target = 0.0
		_shown = 0.0
	else:
		_target = clampf(ratio, 0.0, 1.0)


## The ratio as the caller last set it -- never the eased, drawn one.
func get_ratio() -> float:
	return _target


func is_indeterminate() -> bool:
	return _unknown


## The pack installed. Runs the finish burst, then hides the strip on its own.
func celebrate() -> void:
	_unknown = false
	_target = 1.0
	_running = true
	_celebrate_time = 0.0
	visible = true
	set_process(true)
	_spawn_confetti()
	queue_redraw()


func is_celebrating() -> bool:
	return _celebrate_time >= 0.0


## Hides the strip and drops every particle. The last ratio is kept, exactly as the
## old [ProgressBar] kept its value when it was hidden.
func stop() -> void:
	_running = false
	_celebrate_time = -1.0
	_shown = 0.0
	_unknown = false
	_crumbs.clear()
	_confetti.clear()
	visible = false
	set_process(false)


# ===================================================================== motion ==

func _process(delta: float) -> void:
	# A stalled frame must not teleport the crayon or launch the confetti sideways.
	delta = minf(delta, 0.1)
	_time += delta
	if _celebrate_time >= 0.0:
		_celebrate_time += delta
		_shown = move_toward(_shown, 1.0, delta * 5.0)
		_step_confetti(delta)
		if _celebrate_time >= CELEBRATION_SECONDS:
			stop()
			return
	elif _unknown:
		_shown = 0.0
	else:
		var before := _shown
		_shown += (_target - _shown) * (1.0 - exp(-CATCH_UP * delta))
		if _shown - before > 0.0015:
			_spawn_crumb()
	_step_crumbs(delta)
	queue_redraw()


## Position along the sweep when the size is unknown: x is 0..1 across the strip,
## y is the direction of travel. Eased at both ends so it turns around gently
## instead of bouncing.
func _sweep() -> Vector2:
	var cycle := fposmod(_time / SWEEP_SECONDS, 2.0)
	var linear := cycle if cycle < 1.0 else 2.0 - cycle
	return Vector2(smoothstep(0.0, 1.0, linear), 1.0 if cycle < 1.0 else -1.0)


func _spawn_crumb() -> void:
	if _crumbs.size() >= MAX_CRUMBS:
		return
	_crumbs.append({
		"position": _head_point() + Vector2(_rng.randf_range(-3.0, 4.0),
			_rng.randf_range(-2.0, 4.0)),
		"velocity": Vector2(_rng.randf_range(-16.0, 30.0), _rng.randf_range(-48.0, -12.0)),
		"radius": _rng.randf_range(1.1, 2.4),
		"life": 0.0,
	})


func _step_crumbs(delta: float) -> void:
	var index := _crumbs.size() - 1
	while index >= 0:
		var crumb: Dictionary = _crumbs[index]
		crumb["life"] = float(crumb["life"]) + delta
		if float(crumb["life"]) >= CRUMB_LIFE:
			_crumbs.remove_at(index)
		else:
			var velocity: Vector2 = crumb["velocity"]
			velocity.y += CRUMB_GRAVITY * delta
			crumb["velocity"] = velocity
			crumb["position"] = (crumb["position"] as Vector2) + velocity * delta
		index -= 1


## The burst comes off the FINISH LINE, not off wherever the eased head happens to
## be when the install lands -- the last chunk of a download often arrives with the
## drawn stroke still catching up.
func _spawn_confetti() -> void:
	var band := _band()
	var origin := Vector2(band.position.x + band.size.x,
		band.position.y + band.size.y * 0.5)
	_confetti.clear()
	for i in CONFETTI_COUNT:
		var angle := deg_to_rad(_rng.randf_range(-160.0, -20.0))
		var speed := _rng.randf_range(90.0, 210.0)
		_confetti.append({
			"position": origin + Vector2(_rng.randf_range(-6.0, 6.0), _rng.randf_range(-4.0, 4.0)),
			"velocity": Vector2(cos(angle), sin(angle)) * speed,
			"angle": _rng.randf_range(0.0, TAU),
			"spin": _rng.randf_range(-7.0, 7.0),
			"length": _rng.randf_range(7.0, 12.0),
			"color": CRAYON_COLORS[_rng.randi() % CRAYON_COLORS.size()],
		})


func _step_confetti(delta: float) -> void:
	for bit: Dictionary in _confetti:
		var velocity: Vector2 = bit["velocity"]
		velocity.y += CONFETTI_GRAVITY * delta
		bit["velocity"] = velocity
		bit["position"] = (bit["position"] as Vector2) + velocity * delta
		bit["angle"] = float(bit["angle"]) + float(bit["spin"]) * delta


# ==================================================================== drawing ==

## The wax band: a strip along the bottom of the control, leaving the space above
## it for the crayon that is filling it in.
func _band() -> Rect2:
	var height := clampf(size.y * 0.36, 10.0, 18.0)
	# Inset enough that the crayon standing on the far end of a finished stroke is
	# still inside the row's panel.
	return Rect2(9.0, maxf(size.y - height - 3.0, 0.0), maxf(size.x - 18.0, 1.0), height)


## Where the crayon's tip is right now, in control space. Kept in step with the
## head [method _draw] works out, so crumbs and confetti leave the right place.
func _head_point() -> Vector2:
	var band := _band()
	var cy := band.position.y + band.size.y * 0.5
	if not _unknown:
		return Vector2(band.position.x + band.size.x * _shown, cy)
	var sweep := _sweep()
	var reach := band.size.x * SMEAR_RATIO * 0.5
	var centre := lerpf(band.position.x + reach, band.position.x + band.size.x - reach, sweep.x)
	return Vector2(centre + reach * sweep.y, cy)


func _draw() -> void:
	if size.x <= 1.0 or size.y <= 1.0:
		return
	var fade := _fade()
	var band := _band()
	var cy := band.position.y + band.size.y * 0.5
	var half := band.size.y * 0.5
	var left := band.position.x
	var right := band.position.x + band.size.x

	# --- the paper ------------------------------------------------------------
	_paper.bg_color = Color(PAPER_COLOR, PAPER_COLOR.a * fade)
	_paper.set_corner_radius_all(int(round(half + 2.0)))
	draw_style_box(_paper, band.grow(2.0))

	# --- where the crayon is, and how much wax is behind it -------------------
	var sweep := _sweep()
	var direction := 1.0
	var head := left + band.size.x * _shown
	var tail := left
	if _unknown and _celebrate_time < 0.0:
		# A smear of FIXED length sliding along the strip, rather than a trail that
		# collapses every time the crayon turns around at an edge.
		direction = sweep.y
		var reach := band.size.x * SMEAR_RATIO * 0.5
		var centre := lerpf(left + reach, right - reach, sweep.x)
		head = centre + reach * direction
		tail = centre - reach * direction

	# --- the guide line still waiting to be coloured --------------------------
	_draw_guide(maxf(head, tail) + half, right, cy, fade * (0.45 if _unknown else 1.0))

	# --- the wax --------------------------------------------------------------
	if absf(head - tail) > 1.0:
		var taper := 0.8 if _unknown else 0.06
		var tail_thickness := 0.12 if _unknown else 0.62
		draw_colored_polygon(_stroke_polygon(tail, head, cy, half, taper, tail_thickness),
			Color(_color, fade))
		_draw_grain(tail, head, cy, half, taper, fade)
		# The tip leaves a rounded, slightly heavier end where it is pressing.
		draw_circle(Vector2(head, cy), half * 0.98, Color(_color.darkened(0.07), fade))

	for crumb: Dictionary in _crumbs:
		var crumb_alpha := 1.0 - float(crumb["life"]) / CRUMB_LIFE
		draw_circle(crumb["position"] as Vector2, float(crumb["radius"]),
			Color(_color.darkened(0.15), crumb_alpha * 0.8 * fade))

	# --- the crayon -----------------------------------------------------------
	var bob := 0.0
	var tilt := deg_to_rad(28.0) * direction
	if _celebrate_time >= 0.0:
		# It finished: the crayon hops off the page.
		var hop := clampf(_celebrate_time / 0.55, 0.0, 1.0)
		bob = -26.0 * sin(PI * hop)
		tilt += deg_to_rad(28.0) * hop
	else:
		# Scribbling: a small, unhurried wobble, never a vibration.
		bob = sin(_time * 16.0) * 1.3
		tilt += deg_to_rad(4.5) * sin(_time * 12.0)
	_draw_crayon(Vector2(head, cy - half * 0.3 + bob), tilt, Color(_color, fade))

	# --- the finish -----------------------------------------------------------
	if _celebrate_time >= 0.0:
		var pop := clampf(_celebrate_time / 0.42, 0.0, 1.0)
		if pop < 1.0:
			_draw_star(Vector2(head, cy), 5.0 + 22.0 * pop, _time * 3.0,
				Color(1.0, 0.972549, 0.878431, (1.0 - pop) * 0.85))
		for bit: Dictionary in _confetti:
			_draw_confetti(bit, fade)


## 1 until the celebration's last moments, then out.
func _fade() -> float:
	if _celebrate_time < 0.0:
		return 1.0
	return clampf((CELEBRATION_SECONDS - _celebrate_time) / CELEBRATION_FADE, 0.0, 1.0)


## Short dashes along the middle of the untouched paper -- the line-art the crayon
## has not reached yet.
func _draw_guide(from_x: float, to_x: float, cy: float, fade: float) -> void:
	var color := Color(GUIDE_COLOR, GUIDE_COLOR.a * fade)
	var x := from_x
	while x < to_x - 2.0:
		var end := minf(x + 9.0, to_x)
		draw_line(Vector2(x, cy), Vector2(end, cy), color, 2.0, true)
		x = end + 7.0


## The stroke itself: a ribbon between [param from_x] and [param to_x] whose edges
## wobble a little, because a crayon held by a child does not draw a rectangle. The
## wobble is a function of x, not of time, so the wax sits still on the paper while
## the head moves over it. [param taper] is how much of the trailing end thins out,
## and [param tail_thickness] how thin it gets -- a stroke that STARTED somewhere
## is blunt at the start, while a smear sliding along is soft at both ends.
func _stroke_polygon(from_x: float, to_x: float, cy: float, half: float,
		taper: float, tail_thickness: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var steps := clampi(int(absf(to_x - from_x) / 6.0), 2, 48)
	var top := PackedVector2Array()
	var bottom := PackedVector2Array()
	for i in steps + 1:
		var t := float(i) / float(steps)
		var x := lerpf(from_x, to_x, t)
		var edge := half * lerpf(tail_thickness, 1.0, smoothstep(0.0, maxf(taper, 0.001), t))
		top.append(Vector2(x, cy - edge + _wobble(x, 0.0)))
		bottom.append(Vector2(x, cy + edge + _wobble(x, 11.3)))
	points.append_array(top)
	for i in bottom.size():
		points.append(bottom[bottom.size() - 1 - i])
	return points


## Two sine waves at ~1 px, so the edge reads as hand-drawn rather than noisy.
static func _wobble(x: float, phase: float) -> float:
	return sin(x * 0.55 + phase) * 0.6 + sin(x * 1.7 + phase * 2.0) * 0.35


## Lighter streaks through the wax: crayon does not lay down flat colour.
func _draw_grain(from_x: float, to_x: float, cy: float, half: float, taper: float,
		fade: float) -> void:
	var color := Color(_color.lightened(0.30), 0.16 * fade)
	for lane in 3:
		var offset := (float(lane) - 1.0) * half * 0.46
		var line := PackedVector2Array()
		var steps := clampi(int(absf(to_x - from_x) / 8.0), 2, 32)
		for i in steps + 1:
			var t := float(i) / float(steps)
			var x := lerpf(from_x, to_x, t)
			if smoothstep(0.0, maxf(taper, 0.001), t) < 0.5:
				continue
			line.append(Vector2(x, cy + offset + _wobble(x, 3.0 + float(lane) * 2.0)))
		if line.size() >= 2:
			draw_polyline(line, color, 1.4, true)


## A crayon, tip at [param tip], barrel running up the local -Y axis: a sharpened
## nose, a barrel, and a paper wrap with two stripes. All primitives.
func _draw_crayon(tip: Vector2, angle: float, color: Color) -> void:
	var length := 34.0
	var nose := 8.5
	var half := 6.6
	var to_view := Transform2D(angle, tip)

	var silhouette := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(half * 0.58, -nose),
		Vector2(half, -nose - 1.5),
		Vector2(half, -length + 2.0),
		Vector2(half * 0.6, -length),
		Vector2(-half * 0.6, -length),
		Vector2(-half, -length + 2.0),
		Vector2(-half, -nose - 1.5),
		Vector2(-half * 0.58, -nose),
	])
	var body := _mapped(to_view, silhouette)
	draw_colored_polygon(body, color)
	# A dark keyline so the crayon still reads when its colour is a pale one.
	var outline := body.duplicate()
	outline.append(body[0])
	draw_polyline(outline, Color(0.098039, 0.078431, 0.070588, 0.55 * color.a), 1.6, true)

	# The paper wrap, and the two stripes every crayon has.
	var wrap_near := -nose - 2.5
	var wrap_far := -length + 5.0
	draw_colored_polygon(_mapped(to_view, PackedVector2Array([
		Vector2(-half, wrap_near), Vector2(half, wrap_near),
		Vector2(half, wrap_far), Vector2(-half, wrap_far),
	])), Color(color.lightened(0.38), color.a))
	for stripe in [wrap_near - 2.0, wrap_far + 2.0]:
		draw_colored_polygon(_mapped(to_view, PackedVector2Array([
			Vector2(-half, stripe), Vector2(half, stripe),
			Vector2(half, stripe - 1.8), Vector2(-half, stripe - 1.8),
		])), Color(color.darkened(0.22), color.a))
	# A highlight down one side, which is what makes it look round.
	draw_colored_polygon(_mapped(to_view, PackedVector2Array([
		Vector2(-half * 0.62, -nose - 1.0), Vector2(-half * 0.24, -nose - 1.0),
		Vector2(-half * 0.24, -length + 2.5), Vector2(-half * 0.62, -length + 2.5),
	])), Color(1.0, 1.0, 1.0, 0.20 * color.a))


static func _mapped(to_view: Transform2D, points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for point in points:
		out.append(to_view * point)
	return out


## A five-pointed pop at the moment the pack lands.
func _draw_star(center: Vector2, radius: float, spin: float, color: Color) -> void:
	var points := PackedVector2Array()
	for i in 10:
		var angle := spin + TAU * float(i) / 10.0
		var reach := radius if i % 2 == 0 else radius * 0.42
		points.append(center + Vector2(cos(angle), sin(angle)) * reach)
	draw_colored_polygon(points, color)


func _draw_confetti(bit: Dictionary, fade: float) -> void:
	var to_view := Transform2D(float(bit["angle"]), bit["position"] as Vector2)
	var reach := float(bit["length"]) * 0.5
	draw_colored_polygon(_mapped(to_view, PackedVector2Array([
		Vector2(-1.8, -reach), Vector2(1.8, -reach),
		Vector2(1.8, reach), Vector2(-1.8, reach),
	])), Color(bit["color"] as Color, fade))

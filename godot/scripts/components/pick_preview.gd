class_name PickPreview
extends Control
## The floating "what am I about to pick" bubble (BACKLOG BL-15).
##
## [b]The problem it solves[/b]: while a finger is down it covers the very
## crayon it is choosing -- worst of all during BL-2's slide-to-select,
## where the choice changes under the hand. So the candidate is echoed in a bubble
## offset [b]above[/b] the touch point, the way a phone keyboard previews the key
## under a thumb. It follows the finger, re-draws as the candidate changes, and
## fades out when the finger lifts.
##
## [b]One component, driven from the palette[/b]: [PaletteChild] owns exactly one,
## built with [code]PickPreview.new()[/code] and parented to its own root, and
## drives it through [method show_color] / [method move_to] / [method dismiss].
## [method show_brush] is the size-preview form BL-15 built for the brush-size
## slider; BL-20 deleted that slider with the adult palette, so nothing in the
## game raises a dot bubble today -- the method stays because it is the shape any
## future non-colour pick will want, and it costs one branch in [method _draw].
##
## [b]Purely visual.[/b] [constant Control.MOUSE_FILTER_IGNORE] and no input
## handling of any kind: it can never be hit-tested, can never steal a press, and
## can never disturb the drag-claim [PaletteSlideInput] makes over the crayon
## scroller. It is drawn with an absolute [member CanvasItem.z_index] so it lands
## over the palette's own contents AND over the toolbar above it, which are in
## different branches of the coloring screen.
##
## Drawn from primitives like every other shell control -- no art assets.
##
## [b]BL-16 changed two things[/b], after the BL-15 build was played on a phone:
## the bubble is drawn at [b]twice[/b] the size and floats [b]three times[/b] as far
## above the press point ([constant BUBBLE_RADIUS], [constant FINGER_GAP]) -- the
## first version was legible only if you already knew what it said, and it sat under
## the hand rather than the fingertip. And it now defends its own dismissal: every
## palette-side release path was audited (see [PaletteSlideInput] and the palette's
## [code]_input[/code]), and on top of that this node hides itself when the
## application loses focus, because a web build that never delivers the touch-up --
## the tab is switched, the finger leaves the canvas -- would otherwise leave the
## bubble painted on the screen for good.

## [b]BL-21 gave it a second placement.[/b] "Above the finger" is the right answer
## for the portrait row along the bottom of the canvas; when the crayons dock as a
## COLUMN on the right (landscape), the hand comes in from the right and the room
## is to the left, so the bubble is parked BESIDE the finger instead and its tail
## points back at it sideways. The geometry is one direction vector
## ([method get_tail_direction]) rather than two layouts.

## Nothing is being previewed.
const MODE_NONE := 0
## A palette colour: the bubble holds a chip of that colour.
const MODE_COLOR := 1
## A brush size: the bubble holds a dot of the candidate diameter, inside a faint
## ring standing for the largest diameter the palette offers.
const MODE_SIZE := 2

## The bubble floats ABOVE the touch point, tail pointing down (the portrait row).
const PLACE_ABOVE := 0
## The bubble floats to the LEFT of the touch point, tail pointing right -- the
## landscape column, where the crayons are docked on the right and the hand covers
## everything to the right of the finger (BL-21).
const PLACE_LEFT := 1

## Radius of the round bubble body. [b]BL-16 doubled it[/b] (46 -> 92): at 46 px on
## a phone held at arm's length the chip inside it was smaller than the crayon it
## was previewing, which made the bubble a decoration rather than an answer.
const BUBBLE_RADIUS := 92.0
## Height and half-width of the tail that points back down at the finger. Doubled
## with the body, so the silhouette is the same shape at twice the size.
const TAIL_HEIGHT := 36.0
const TAIL_HALF_WIDTH := 26.0
## Gap left between the touch point and the tail's tip. BL-16 raised it 16 -> 48:
## a fingertip is not the problem, the HAND behind it is, and 16 px put the tail
## squarely under the player's own knuckles.
const FINGER_GAP := 48.0
## Margin kept between the bubble and the edges of the screen.
const SCREEN_MARGIN := 6.0
## Absolute draw order. High enough to clear the whole coloring screen (toolbar,
## page, palette, celebration) without reaching Godot's 4096 ceiling.
const Z_INDEX := 200

const FADE_OUT_SECONDS := 0.18

const PAPER := Color(0.972549, 0.960784, 0.941176)
const EDGE := Color(0.152941, 0.137255, 0.121569)
const SHADOW := Color(0.0, 0.0, 0.0, 0.32)
## Faint ring in size mode marking the palette's largest brush, so a tiny dot has
## something to be tiny against.
const GAUGE := Color(0.152941, 0.137255, 0.121569, 0.22)
## Smallest dot the size preview draws, so the finest brush is still visible.
const MIN_DOT_RADIUS := 6.0
## Gutter between the bubble's rim and the chip/gauge inside it, and the stroke
## weights of the outline work. All doubled with the body (BL-16).
const CONTENT_INSET := 24.0
const RIM_WIDTH := 6.0
const CHIP_EDGE_WIDTH := 4.0
const TAIL_EDGE := 5.0

var _mode := MODE_NONE
var _placement := PLACE_ABOVE
var _color := Color.WHITE
var _diameter := 0.0
var _max_diameter := 1.0
## Where the finger is, in viewport coordinates.
var _anchor := Vector2.ZERO
var _fade: Tween


## Everything is configured here rather than in a scene or by the owner, so a
## palette only ever has to [code]PickPreview.new()[/code] and parent it. The
## parent must not be a [Container]: this positions itself, and a container would
## lay it back out every frame.
func _init() -> void:
	# Never hit-testable: the palette underneath keeps every press and drag.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = _size_for(_placement)
	z_index = Z_INDEX
	# Absolute, not relative: the palette sits in one branch of the coloring screen
	# and the toolbar in another, and the bubble has to beat both.
	z_as_relative = false
	visible = false
	modulate.a = 0.0


## The last line of BL-16's dismiss audit. A gesture that never reports its end --
## the browser tab loses focus mid-slide, the OS takes the window away, the finger
## leaves the canvas of a web build -- would strand the bubble on screen, and a
## stuck bubble covers the palette it was supposed to explain. Losing focus is not
## a pick, so whatever was being previewed is over.
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT, NOTIFICATION_EXIT_TREE:
			hide_now()


# ======================================================================== api ==

## Where the bubble parks relative to the finger (BL-21). The palette sets this
## when its layout flips; nothing else touches it.
func set_placement(placement: int) -> void:
	var resolved := PLACE_LEFT if placement == PLACE_LEFT else PLACE_ABOVE
	if _placement == resolved:
		return
	_placement = resolved
	size = _size_for(_placement)
	_reposition()
	queue_redraw()


func get_placement() -> int:
	return _placement


## Unit vector from the bubble's body towards the finger -- which is the way the
## tail points. Down when the bubble is above the touch point, right when it is
## beside it.
func get_tail_direction() -> Vector2:
	return Vector2.RIGHT if _placement == PLACE_LEFT else Vector2.DOWN


## Previews palette colour [param color] with the bubble clear of
## [param viewport_position].
func show_color(color: Color, viewport_position: Vector2) -> void:
	_mode = MODE_COLOR
	_color = color
	_appear(viewport_position)


## Previews brush [param diameter] (page px) in [param color], sized against
## [param max_diameter] -- the largest stop the palette offers -- so the dot is a
## true fraction of the biggest brush rather than an arbitrary blob.
func show_brush(color: Color, diameter: float, max_diameter: float, viewport_position: Vector2) -> void:
	_mode = MODE_SIZE
	_color = color
	_diameter = maxf(diameter, 0.0)
	_max_diameter = maxf(max_diameter, 1.0)
	_appear(viewport_position)


## Moves the bubble without changing what it shows. Silent when nothing is up.
func move_to(viewport_position: Vector2) -> void:
	if _mode == MODE_NONE:
		return
	_anchor = viewport_position
	_reposition()


## Fades the bubble out. Safe to call when nothing is showing.
func dismiss() -> void:
	if _mode == MODE_NONE and not visible:
		return
	_mode = MODE_NONE
	_kill_fade()
	if not is_inside_tree():
		visible = false
		modulate.a = 0.0
		return
	_fade = create_tween()
	_fade.tween_property(self, "modulate:a", 0.0, FADE_OUT_SECONDS)
	_fade.tween_callback(func() -> void: visible = false)


## Hides the bubble at once, with no fade -- for a palette being rebuilt or torn
## down under a finger that is still down.
func hide_now() -> void:
	_mode = MODE_NONE
	_kill_fade()
	modulate.a = 0.0
	visible = false


## True while the bubble is on screen (including while it fades away).
func is_showing() -> bool:
	return visible and modulate.a > 0.0


## True while a candidate is actively being previewed (false the moment the finger
## lifts, even though the fade is still running).
func is_active() -> bool:
	return _mode != MODE_NONE


func get_mode() -> int:
	return _mode


func get_preview_color() -> Color:
	return _color


## Candidate diameter in page px, or 0.0 outside [constant MODE_SIZE].
func get_preview_diameter() -> float:
	return _diameter if _mode == MODE_SIZE else 0.0


## The touch point the bubble is pointing at, in viewport coordinates.
func get_anchor_position() -> Vector2:
	return _anchor


## The bubble's own rect in viewport coordinates -- what the smoke test measures to
## prove the thing really is above the finger.
func get_viewport_rect_of_bubble() -> Rect2:
	return Rect2(get_global_transform_with_canvas() * Vector2.ZERO, size)


# =================================================================== internal ==

func _appear(viewport_position: Vector2) -> void:
	_anchor = viewport_position
	_kill_fade()
	visible = true
	modulate.a = 1.0
	_reposition()
	queue_redraw()


func _kill_fade() -> void:
	if _fade != null and _fade.is_valid():
		_fade.kill()
	_fade = null


## The box the bubble occupies: a [constant BUBBLE_RADIUS] circle plus the tail,
## which sticks out along whichever axis the tail points down.
static func _size_for(placement: int) -> Vector2:
	var body := BUBBLE_RADIUS * 2.0
	return (
		Vector2(body + TAIL_HEIGHT, body)
		if placement == PLACE_LEFT
		else Vector2(body, body + TAIL_HEIGHT)
	)


## Centre of the bubble's circle, in the node's own space. The circle always sits
## in the top-left of the box; the tail is what makes the box longer on one axis.
static func _body_center() -> Vector2:
	return Vector2(BUBBLE_RADIUS, BUBBLE_RADIUS)


## Parks the bubble so its tail tip is [constant FINGER_GAP] clear of the touch
## point, then keeps the whole thing on screen. Never ON the finger: covering the
## pick is the entire bug this exists to fix.
func _reposition() -> void:
	if not is_inside_tree():
		return
	var direction := get_tail_direction()
	var tip_local := _body_center() + direction * (BUBBLE_RADIUS + TAIL_HEIGHT)
	var canvas := get_canvas_transform()
	var wanted: Vector2 = canvas.affine_inverse() * _anchor
	wanted -= direction * FINGER_GAP + tip_local

	var view := get_viewport_rect()
	var top_left: Vector2 = canvas.affine_inverse() * view.position
	var bottom_right: Vector2 = canvas.affine_inverse() * view.end
	# Clamped on both axes now (BL-21): the tail can point along either one, and a
	# clamp can only ever push the bubble further from the finger on the tail's
	# axis, so it stays clear of the hand whichever way it is parked.
	wanted.x = clampf(
		wanted.x, top_left.x + SCREEN_MARGIN, maxf(bottom_right.x - size.x - SCREEN_MARGIN, top_left.x)
	)
	wanted.y = clampf(
		wanted.y, top_left.y + SCREEN_MARGIN, maxf(bottom_right.y - size.y - SCREEN_MARGIN, top_left.y)
	)
	global_position = wanted


func _draw() -> void:
	if _mode == MODE_NONE:
		return
	var direction := get_tail_direction()
	var center := _body_center()
	var tip := center + direction * (BUBBLE_RADIUS + TAIL_HEIGHT)
	# The tail's base is a chord just inside the circle, so the seam between the
	# two disappears under the body drawn over it.
	var base := center + direction * (BUBBLE_RADIUS - 8.0)

	# Drop shadow first, so the bubble reads as floating over the palette.
	draw_circle(center + Vector2(0.0, 8.0), BUBBLE_RADIUS + 4.0, SHADOW)

	# Tail: an outlined triangle, drawn before the body so the seam disappears
	# under the circle.
	_draw_tail(base, direction, tip, TAIL_HALF_WIDTH + TAIL_EDGE, TAIL_EDGE, EDGE)
	_draw_tail(base, direction, tip, TAIL_HALF_WIDTH, 0.0, PAPER)

	draw_circle(center, BUBBLE_RADIUS, PAPER)
	draw_arc(center, BUBBLE_RADIUS - RIM_WIDTH * 0.5, 0.0, TAU, 96, EDGE, RIM_WIDTH, true)

	if _mode == MODE_COLOR:
		_draw_color_chip(center)
	else:
		_draw_size_dot(center)


func _draw_tail(base: Vector2, direction: Vector2, tip: Vector2, half_width: float, extra: float, color: Color) -> void:
	var across := direction.orthogonal() * half_width
	draw_colored_polygon(
		PackedVector2Array([base - across, base + across, tip + direction * extra]),
		color
	)


func _draw_color_chip(center: Vector2) -> void:
	var radius := BUBBLE_RADIUS - CONTENT_INSET
	draw_circle(center, radius, _color)
	draw_arc(center, radius, 0.0, TAU, 72, _color.darkened(0.4), CHIP_EDGE_WIDTH, true)


func _draw_size_dot(center: Vector2) -> void:
	var gauge_radius := BUBBLE_RADIUS - CONTENT_INSET
	draw_arc(center, gauge_radius, 0.0, TAU, 72, GAUGE, CHIP_EDGE_WIDTH, true)
	var ratio := clampf(_diameter / _max_diameter, 0.0, 1.0)
	var radius := maxf(MIN_DOT_RADIUS, gauge_radius * ratio)
	draw_circle(center, radius, _color)
	draw_arc(center, radius, 0.0, TAU, 72, _color.darkened(0.4), CHIP_EDGE_WIDTH * 0.75, true)

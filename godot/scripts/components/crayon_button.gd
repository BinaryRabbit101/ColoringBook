class_name CrayonButton
extends BaseButton
## One crayon in the child palette row, drawn from primitives -- no art assets.
##
## Extends [BaseButton] so touch and mouse arrive through the engine's single
## button path (DESIGN.md 3.3: no separate mouse/touch branches) while [method
## _draw] owns every pixel. The owning palette sets [member crayon_color] and
## [member selected]; this node only reports [signal pressed] upward.
##
## Silhouette: a tapered tip (trapezoid) on a straight body, a paper wrapper with
## two light bands and a label patch, plus edge shading. Selected crayons lift out
## of the box by [constant LIFT_PX] and gain a glow, so the selection reads at a
## glance from across the room.
##
## [b]BACKLOG BL-15 strengthened that read[/b] rather than redesigning it: the lift
## went from 16 px to [constant LIFT_PX] -- over a third of the crayon's own width,
## so a picked crayon is unmistakably taller than its neighbours -- unselected
## crayons narrow a little further, the halo gained layers and opacity, and the
## selected silhouette is outlined twice, in the crayon's own dark edge and in a
## bright rim outside it. That rim is what survives being looked at from 2-3 ft
## away on a phone.
##
## [b]BL-16 pushed it further still[/b], because on the device it still was not
## obvious: the lift is half the crayon's width now, the selected crayon is nearly
## half again as wide as an unselected one, and picking one plays a [b]settle
## bounce[/b] -- it springs up past its resting height and drops back
## ([constant SELECT_BOUNCE_SCALE]). The bounce is why [constant LIFT_HEADROOM],
## not [constant LIFT_PX], is the space reserved at the top of the box: the row's
## [ScrollContainer] clips vertically, and an overshoot with nowhere to go would be
## sliced off at the peak of the very motion that is supposed to draw the eye.

## Minimum touch target for child mode (DESIGN.md 1 "large touch targets"); the
## global floor is 48 px, child mode is deliberately more generous.
const MIN_TOUCH_TARGET := 64.0
## Default box for one crayon. Width is the touch target; height gives the ~1:2.5
## body proportion that reads as "crayon" rather than "stick".
const DEFAULT_SIZE := Vector2(68.0, 176.0)
## How far a selected crayon rises out of the box (16 -> 26 in BL-15, 26 -> 34 in
## BL-16: half the crayon's own width).
const LIFT_PX := 34.0
## Peak of the settle bounce, as a multiple of [constant LIFT_PX] (BL-16).
const SELECT_BOUNCE_SCALE := 1.18
const SELECT_BOUNCE_SECONDS := 0.42
## Vertical space the box reserves for the lift. The BOUNCE's peak, not the resting
## lift, because the row clips vertically.
const LIFT_HEADROOM := LIFT_PX * SELECT_BOUNCE_SCALE
## Padding kept clear at each end so the lift, the halo and the selection rim have
## somewhere to go without being clipped by the crayon row's [ScrollContainer].
const BOTTOM_PAD := 6.0
const TOP_PAD := 5.0
## Body width, as a fraction of the control's width, when idle / hovered /
## selected. The selected crayon is the widest as well as the tallest, and BL-16
## widened the gap at both ends: the difference between the two is the signal.
const IDLE_WIDTH_SCALE := 0.64
const HOVER_WIDTH_SCALE := 0.74
const SELECTED_WIDTH_SCALE := 0.94
## Halo behind a selected crayon: how many copies, and how opaque each one is.
## The halo spreads mostly SIDEWAYS -- the row's [ScrollContainer] clips vertically
## and a hard-cut glow looks worse than a narrow one.
const GLOW_LAYERS := 8
const GLOW_ALPHA := 0.20
const GLOW_VERTICAL_RATIO := 0.30
## Bright rim under a selected crayon's dark outline: a wide light stroke straddling
## the silhouette edge, so the selection survives against a dark crayon.
const SELECTION_RIM := Color(1.0, 0.972549, 0.874510, 0.92)
const SELECTION_RIM_WIDTH := 9.0
const SELECTION_OUTLINE_WIDTH := 3.0

## The colour this crayon lays down. Also its entire visual identity.
var crayon_color: Color = Color.WHITE:
	set(value):
		crayon_color = value
		queue_redraw()

## Whether this is the palette's active crayon.
var selected: bool = false:
	set(value):
		if selected == value:
			return
		selected = value
		if selected:
			_bounce()
		else:
			_kill_bounce()
			_lift_scale = 1.0
		queue_redraw()

## Index of this crayon in the [PaletteDef]'s colour list.
var color_index: int = 0

## Multiplier on [constant LIFT_PX] while the settle bounce plays (BL-16). 1.0 at
## rest; it starts at [constant SELECT_BOUNCE_SCALE] and springs down to 1.0.
var _lift_scale := 1.0
var _bounce_tween: Tween


func _init() -> void:
	custom_minimum_size = DEFAULT_SIZE
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	# Repaint on hover / press so the crayon feels alive under a finger.
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)


## How far this crayon is currently lifted out of its box, in pixels: 0 when it is
## not the selection, [constant LIFT_PX] at rest, more while the bounce is at its
## peak. Public so the palette smoke can measure the selection instead of trusting
## a constant.
func current_lift() -> float:
	return LIFT_PX * _lift_scale if selected else 0.0


## True while the settle bounce is playing.
func is_bouncing() -> bool:
	return _bounce_tween != null and _bounce_tween.is_valid()


## The spring: up past the resting lift, then back down to it. Runs on the drawn
## LIFT rather than on the control's transform, so the whole thing stays inside the
## headroom the box already reserves and the row's scroller cannot slice the peak.
func _bounce() -> void:
	_kill_bounce()
	_lift_scale = SELECT_BOUNCE_SCALE
	if not is_inside_tree():
		_lift_scale = 1.0
		return
	_bounce_tween = create_tween()
	_bounce_tween.tween_method(
		_set_lift_scale, SELECT_BOUNCE_SCALE, 1.0, SELECT_BOUNCE_SECONDS
	).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _set_lift_scale(value: float) -> void:
	_lift_scale = value
	queue_redraw()


func _kill_bounce() -> void:
	if _bounce_tween != null and _bounce_tween.is_valid():
		_bounce_tween.kill()
	_bounce_tween = null


func _draw() -> void:
	var box := size
	if box.x <= 0.0 or box.y <= 0.0:
		return

	var lift := current_lift()
	var press_sink := 4.0 if is_pressed() else 0.0
	var width_scale := SELECTED_WIDTH_SCALE
	if not selected:
		width_scale = HOVER_WIDTH_SCALE if is_hovered() else IDLE_WIDTH_SCALE

	var body_width := box.x * width_scale
	var center_x := box.x * 0.5
	var top := TOP_PAD + LIFT_HEADROOM - lift + press_sink
	var bottom := box.y - BOTTOM_PAD
	var crayon_height := bottom - top
	if crayon_height <= 0.0 or body_width <= 0.0:
		return

	var tip_height := crayon_height * 0.19
	var tip_width := body_width * 0.34
	var half := body_width * 0.5
	var tip_base := top + tip_height

	var silhouette := PackedVector2Array([
		Vector2(center_x - tip_width * 0.5, top),
		Vector2(center_x + tip_width * 0.5, top),
		Vector2(center_x + half, tip_base),
		Vector2(center_x + half, bottom),
		Vector2(center_x - half, bottom),
		Vector2(center_x - half, tip_base),
	])

	if selected:
		_draw_glow(silhouette, Vector2(center_x, (top + bottom) * 0.5))

	# Body + tip in one silhouette, then shading and wrapper on top of it.
	draw_colored_polygon(silhouette, crayon_color)

	var body_top := tip_base
	var body_height := bottom - body_top
	# Right-hand shading and left-hand highlight give the flat colour volume.
	draw_rect(
		Rect2(center_x + half * 0.42, body_top, half * 0.58, body_height),
		crayon_color.darkened(0.18)
	)
	draw_rect(
		Rect2(center_x - half, body_top, half * 0.42, body_height),
		crayon_color.lightened(0.22)
	)
	# Same treatment on the tip so it does not read as a flat triangle.
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(center_x + tip_width * 0.16, top),
			Vector2(center_x + tip_width * 0.5, top),
			Vector2(center_x + half, tip_base),
			Vector2(center_x + half * 0.42, tip_base),
		]),
		crayon_color.darkened(0.18)
	)

	# Paper wrapper: the body minus a bare band at each end.
	var wrap_top := body_top + body_height * 0.13
	var wrap_bottom := bottom - body_height * 0.10
	draw_rect(Rect2(center_x - half, wrap_top, body_width, wrap_bottom - wrap_top), crayon_color)
	var band := maxf(body_height * 0.035, 3.0)
	var band_color := Color(1.0, 1.0, 1.0, 0.78)
	draw_rect(Rect2(center_x - half, wrap_top, body_width, band), band_color)
	draw_rect(Rect2(center_x - half, wrap_bottom - band, body_width, band), band_color)
	# Label patch in the middle of the wrapper.
	var label_height := body_height * 0.16
	var label_y := (wrap_top + wrap_bottom - label_height) * 0.5
	draw_rect(
		Rect2(center_x - half * 0.72, label_y, body_width * 0.72, label_height),
		Color(1.0, 1.0, 1.0, 0.34)
	)

	# Silhouette outline last, so nothing overdraws it. A selected crayon gets a
	# bright rim just outside it as well (BL-15): the dark edge alone disappears
	# against a dark crayon at arm's length.
	var outline := silhouette.duplicate()
	outline.append(silhouette[0])
	if selected:
		draw_polyline(outline, SELECTION_RIM, SELECTION_RIM_WIDTH, true)
	draw_polyline(
		outline, crayon_color.darkened(0.5),
		SELECTION_OUTLINE_WIDTH if selected else 2.0, true
	)


## Soft halo behind a selected crayon: copies of the silhouette scaled up about
## the crayon's centre, so the glow keeps the tapered shape instead of reading as
## a rectangle behind it.
func _draw_glow(silhouette: PackedVector2Array, center: Vector2) -> void:
	for i in GLOW_LAYERS:
		var spread := 0.05 + float(i) * 0.035
		draw_colored_polygon(
			_scaled(
				silhouette, center,
				Vector2(1.0 + spread, 1.0 + spread * GLOW_VERTICAL_RATIO)
			),
			Color(crayon_color.r, crayon_color.g, crayon_color.b, GLOW_ALPHA)
		)


## [param polygon] scaled about [param center]. Keeps the tapered crayon shape.
static func _scaled(polygon: PackedVector2Array, center: Vector2, scale: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for point in polygon:
		out.append(center + (point - center) * scale)
	return out

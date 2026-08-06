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

## Minimum touch target for child mode (DESIGN.md 1 "large touch targets"); the
## global floor is 48 px, child mode is deliberately more generous.
const MIN_TOUCH_TARGET := 64.0
## Default box for one crayon. Width is the touch target; height gives the ~1:2.5
## body proportion that reads as "crayon" rather than "stick".
const DEFAULT_SIZE := Vector2(68.0, 176.0)
## How far a selected crayon rises out of the box.
const LIFT_PX := 16.0
## Bottom padding kept clear so the lift has somewhere to go without clipping.
const BOTTOM_PAD := 6.0

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
		queue_redraw()

## Index of this crayon in the [PaletteDef]'s colour list.
var color_index: int = 0


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


func _draw() -> void:
	var box := size
	if box.x <= 0.0 or box.y <= 0.0:
		return

	var lift := LIFT_PX if selected else 0.0
	var press_sink := 4.0 if is_pressed() else 0.0
	var width_scale := 1.0 if selected else 0.88
	if is_hovered() and not selected:
		width_scale = 0.94

	var body_width := box.x * 0.82 * width_scale
	var center_x := box.x * 0.5
	var top := LIFT_PX - lift + press_sink
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

	# Silhouette outline last, so nothing overdraws it.
	var outline := silhouette.duplicate()
	outline.append(silhouette[0])
	draw_polyline(outline, crayon_color.darkened(0.5), 2.0, true)


## Soft halo behind a selected crayon: copies of the silhouette scaled up about
## the crayon's centre, so the glow keeps the tapered shape instead of reading as
## a rectangle behind it.
func _draw_glow(silhouette: PackedVector2Array, center: Vector2) -> void:
	for i in 4:
		var scale := 1.05 + float(i) * 0.05
		var halo := PackedVector2Array()
		for point in silhouette:
			halo.append(center + (point - center) * scale)
		draw_colored_polygon(halo, Color(crayon_color.r, crayon_color.g, crayon_color.b, 0.11))

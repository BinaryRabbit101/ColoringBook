class_name BrushSizeDot
extends BaseButton
## One entry of the adult palette's brush-size selector: a dot whose drawn
## diameter is proportional to the brush diameter it selects, so the control is
## its own legend.
##
## [member brush_size] is a DIAMETER in page pixels, matching
## [member PageView.brush_size] -- no unit conversion anywhere in the chain.

## Global minimum touch target (DESIGN.md 3.5); the box is larger so neighbouring
## dots never share a fingertip.
const MIN_TOUCH_TARGET := 48.0
const DEFAULT_SIZE := Vector2(64.0, 64.0)
## Drawn radius for the smallest / largest offered size.
const MIN_DRAWN_RADIUS := 5.0
const MAX_DRAWN_RADIUS := 20.0

## Brush DIAMETER in page pixels that picking this dot selects.
var brush_size: float = 32.0:
	set(value):
		brush_size = value
		queue_redraw()

## This dot's brush size relative to the palette's largest, 0..1. The palette
## sets it so the dots scale against each other, not against an absolute.
var size_ratio: float = 1.0:
	set(value):
		size_ratio = clampf(value, 0.0, 1.0)
		queue_redraw()

var selected: bool = false:
	set(value):
		if selected == value:
			return
		selected = value
		queue_redraw()

## Index of this dot in the [PaletteDef]'s brush size list.
var size_index: int = 0


func _init() -> void:
	custom_minimum_size = DEFAULT_SIZE
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)


## Radius this dot draws at, from its share of the palette's size range.
func drawn_radius() -> float:
	return lerpf(MIN_DRAWN_RADIUS, MAX_DRAWN_RADIUS, size_ratio)


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var center := size * 0.5
	var radius := drawn_radius()
	var fill := Color(0.13, 0.14, 0.16) if not selected else Color(0.10, 0.11, 0.13)
	if is_hovered() and not selected:
		fill = Color(0.24, 0.25, 0.28)
	if is_pressed():
		fill = Color(0.34, 0.35, 0.38)
	draw_circle(center, radius, fill)
	draw_arc(center, radius, 0.0, TAU, 48, Color(1.0, 1.0, 1.0, 0.35), 1.0, true)
	if selected:
		var ring := minf(size.x, size.y) * 0.5 - 4.0
		draw_arc(center, ring, 0.0, TAU, 64, Color(0.98, 0.78, 0.28), 3.0, true)

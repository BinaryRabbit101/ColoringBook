class_name SwatchButton
extends BaseButton
## One colour swatch in the adult palette grid, drawn from primitives.
##
## Same rationale as [CrayonButton]: [BaseButton] for the one touch/mouse input
## path, [method _draw] for the look. Selection is a double ring (a contrasting
## inner ring plus a dark outer ring) so it stays visible on both a pale tint and
## a near-black shade.

## Global minimum touch target (DESIGN.md 3.5).
const MIN_TOUCH_TARGET := 48.0
## Default box for one swatch, comfortably over the floor.
const DEFAULT_SIZE := Vector2(56.0, 56.0)

var swatch_color: Color = Color.WHITE:
	set(value):
		swatch_color = value
		queue_redraw()

var selected: bool = false:
	set(value):
		if selected == value:
			return
		selected = value
		queue_redraw()

## Index of this swatch in the [PaletteDef]'s colour list.
var color_index: int = 0


func _init() -> void:
	custom_minimum_size = DEFAULT_SIZE
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var full := Rect2(Vector2.ZERO, size)
	# Unselected swatches sit inside a gutter; the selection ring grows into it.
	var inset := 3.0 if selected else 6.0
	if is_hovered() and not selected:
		inset = 4.0
	if is_pressed():
		inset += 2.0
	var patch := full.grow(-inset)
	draw_rect(patch, swatch_color)
	draw_rect(patch, swatch_color.darkened(0.35), false, 1.0)

	if not selected:
		return
	# Ring that contrasts with the swatch, plus a dark keyline so a pale ring
	# stays readable against the panel behind it.
	var ring := Color.BLACK if swatch_color.get_luminance() > 0.5 else Color.WHITE
	draw_rect(patch.grow(2.0), ring, false, 3.0)
	draw_rect(patch.grow(4.5), Color(0.0, 0.0, 0.0, 0.45), false, 1.5)

class_name HistoryButton
extends Button
## Undo / redo in the coloring toolbar (BL-17): a curved arrow drawn from
## primitives, mirrored for the two directions.
##
## Drawn rather than textured for the same reason [PadlockButton] is: the shell
## ships no icon assets, and an arc plus a triangle stays crisp at every DPI the
## mobile pass covers. Every state's [StyleBox] is emptied in [method _init] so this
## script owns the whole look -- hover, pressed and, importantly, DISABLED, which
## these two buttons spend most of their life in (an empty stack, or a locked page).
##
## [b]Contract[/b]: the parent sets [member forward] once and drives the inherited
## [member BaseButton.disabled]; the button decides nothing and holds no history.

## Minimum size. Narrower than [PadlockButton] because there are two of these in a
## row that already carries five other controls, but still clear of the 48 px touch
## floor (DESIGN.md 3.5) in both axes.
const MIN_SIZE := Vector2(64.0, 60.0)

## Arc geometry, as fractions of the smaller side, so the glyph scales with the box.
const ARC_RADIUS_RATIO := 0.26
const ARC_WIDTH_RATIO := 0.10
const HEAD_RATIO := 0.19

const PLATE := Color(0.219608, 0.203922, 0.192157)
const PLATE_HOVER := Color(0.301961, 0.278431, 0.262745)
const ARROW := Color(0.972549, 0.94902, 0.905882)
## Matches the toolbar's authored `font_disabled_color`, so a dead undo button
## reads as dead in exactly the same language the page arrows use.
const ARROW_DISABLED := Color(0.407843, 0.380392, 0.356863)
const PLATE_DISABLED := Color(0.164706, 0.156863, 0.152941)

## False draws the undo arrow (curving back to the left), true the redo arrow.
## Purely presentational -- it decides which way the glyph points and nothing else.
@export var forward: bool = false:
	set(value):
		forward = value
		tooltip_text = "Redo the stroke you took back" if forward else "Undo the last stroke"
		queue_redraw()

var _plate := StyleBoxFlat.new()


func _init() -> void:
	custom_minimum_size = MIN_SIZE
	focus_mode = Control.FOCUS_NONE
	flat = true
	# The script draws every state, so the theme must not draw one underneath it.
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	_plate.set_corner_radius_all(12)


func _ready() -> void:
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	_plate.bg_color = PLATE_DISABLED if disabled else (
		PLATE_HOVER if (is_hovered() or button_pressed) else PLATE
	)
	_plate.draw(get_canvas_item(), Rect2(Vector2.ZERO, size))

	var unit := minf(size.x, size.y)
	var tint := ARROW_DISABLED if disabled else ARROW
	var radius := unit * ARC_RADIUS_RATIO
	var width := maxf(unit * ARC_WIDTH_RATIO, 2.0)
	var head := maxf(unit * HEAD_RATIO, 4.0)
	# The arc sits a little low in the box so the head, which hangs below it, stays
	# optically centred rather than the semicircle alone.
	var center := Vector2(size.x * 0.5, size.y * 0.5 - head * 0.22)

	# Top half-circle, drawn from the head end so the two directions are mirror
	# images of each other rather than two hand-tuned shapes.
	draw_arc(center, radius, PI * 0.94, TAU, 32, tint, width, true)

	# Arrow head at the left (undo) or right (redo) end of the arc, pointing down --
	# the direction the stroke of the arc is travelling when it gets there.
	var tip_x := center.x + (radius if forward else -radius)
	var direction := 1.0 if forward else -1.0
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(tip_x + direction * head * 0.45, center.y + head * 0.9),
			Vector2(tip_x - direction * head * 0.72, center.y + head * 0.16),
			Vector2(tip_x + direction * head * 0.68, center.y - head * 0.34),
		]),
		tint
	)

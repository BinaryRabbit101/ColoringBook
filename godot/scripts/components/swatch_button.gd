class_name SwatchButton
extends BaseButton
## One colour swatch in the adult palette grid, drawn from primitives.
##
## Same rationale as [CrayonButton]: [BaseButton] for the one touch/mouse input
## path, [method _draw] for the look. Selection is a double ring (a contrasting
## inner ring plus a dark outer ring) so it stays visible on both a pale tint and
## a near-black shade.
##
## [b]Selection was strengthened by BACKLOG BL-15[/b], which found it unreadable at
## arm's length. Two changes, both inside the existing idea rather than a redesign:
## the selected swatch now [b]grows[/b] -- idle swatches sit further inside their
## box ([constant IDLE_INSET] vs [constant SELECTED_INSET]), so picking one visibly
## pops it out of the grid -- and the contrast ring is nearly twice as thick. Every
## ring is still drawn inside the swatch's own box, so the [ScrollContainer] around
## the grid cannot clip the selection off an edge swatch.
##
## [b]BL-16 turned it up again[/b]: the idle/selected gap is wider (a selected patch
## is now ~1.4x an idle one), the ring is thicker again, and picking a swatch plays
## a [b]settle bounce[/b] -- a brief overshoot of the control's own transform, which
## springs back to 1.0. The bounce is the ONE thing here that draws outside the
## swatch's box, and it is deliberately transient for exactly that reason: what the
## grid's scroller must never clip is the state the swatch RESTS in, and every
## resting pixel is still inside the box.

## Global minimum touch target (DESIGN.md 3.5).
const MIN_TOUCH_TARGET := 48.0
## Default box for one swatch, comfortably over the floor.
const DEFAULT_SIZE := Vector2(56.0, 56.0)
## How far inside its box an unselected / hovered / selected swatch is drawn. The
## gap between idle and selected IS the scale-up, and the selected value is the
## gutter every ring has to fit inside.
const IDLE_INSET := 13.0
const HOVER_INSET := 11.0
const SELECTED_INSET := 8.0
## Extra inset while held, so a press still reads under a finger.
const PRESS_INSET := 2.0
## Thickness of the contrast ring around a selected swatch (3.0 -> 5.0 in BL-15,
## 5.0 -> 6.0 in BL-16). [constant SELECTED_INSET] is the gutter it has to fit in.
const SELECTION_RING_WIDTH := 6.0
## Thickness of the dark keyline outside it, which is what makes a pale ring
## survive against the pale panel behind the grid.
const SELECTION_KEYLINE_WIDTH := 2.0
## Peak of the settle bounce and how long it takes to spring back (BL-16).
const SELECT_BOUNCE_SCALE := 1.14
const SELECT_BOUNCE_SECONDS := 0.38

var swatch_color: Color = Color.WHITE:
	set(value):
		swatch_color = value
		queue_redraw()

var selected: bool = false:
	set(value):
		if selected == value:
			return
		selected = value
		if selected:
			_bounce()
		else:
			_kill_bounce()
			scale = Vector2.ONE
		queue_redraw()

## Index of this swatch in the [PaletteDef]'s colour list.
var color_index: int = 0

var _bounce_tween: Tween


func _init() -> void:
	custom_minimum_size = DEFAULT_SIZE
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)
	resized.connect(_recenter_pivot)
	_recenter_pivot()


func _recenter_pivot() -> void:
	# The bounce scales about the middle of the swatch, not its top-left corner.
	pivot_offset = size * 0.5


## The settle bounce (BL-16): the swatch springs out and settles back. It is the
## control's own transform, so it briefly draws over its neighbours -- which is the
## point, and is why it is over in under half a second.
func _bounce() -> void:
	_kill_bounce()
	_recenter_pivot()
	scale = Vector2.ONE * SELECT_BOUNCE_SCALE
	if not is_inside_tree():
		scale = Vector2.ONE
		return
	_bounce_tween = create_tween()
	_bounce_tween.tween_property(self, "scale", Vector2.ONE, SELECT_BOUNCE_SECONDS).set_trans(
		Tween.TRANS_ELASTIC
	).set_ease(Tween.EASE_OUT)


func _kill_bounce() -> void:
	if _bounce_tween != null and _bounce_tween.is_valid():
		_bounce_tween.kill()
	_bounce_tween = null


## True while the settle bounce is playing.
func is_bouncing() -> bool:
	return _bounce_tween != null and _bounce_tween.is_valid()


## Inset of the colour patch for the current state. Public so the palette smoke can
## assert the scale-up without re-deriving the rule.
func patch_inset() -> float:
	var inset := IDLE_INSET
	if selected:
		inset = SELECTED_INSET
	elif is_hovered():
		inset = HOVER_INSET
	if is_pressed():
		inset += PRESS_INSET
	return inset


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var full := Rect2(Vector2.ZERO, size)
	# Unselected swatches sit deep inside a gutter; a selected one grows out into
	# it, and the rings then fill what is left.
	var patch := full.grow(-patch_inset())
	draw_rect(patch, swatch_color)
	draw_rect(patch, swatch_color.darkened(0.35), false, 1.0)

	if not selected:
		return
	# Ring that contrasts with the swatch, plus a dark keyline so a pale ring
	# stays readable against the panel behind it. Both are centred inside the
	# SELECTED_INSET gutter, so nothing draws outside the swatch's own box.
	var ring := Color.BLACK if swatch_color.get_luminance() > 0.5 else Color.WHITE
	draw_rect(patch.grow(SELECTION_RING_WIDTH * 0.5), ring, false, SELECTION_RING_WIDTH)
	draw_rect(
		patch.grow(SELECTION_RING_WIDTH), Color(0.0, 0.0, 0.0, 0.55), false, SELECTION_KEYLINE_WIDTH
	)

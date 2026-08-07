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
## [b]BL-29 gave it a face and a reaction.[/b] The grey plate became the same
## teal crayon slab the rest of the toolbar wears ([ToolbarStyle.plate] draws it, so
## the corner radius, the wax lip and the drop shadow are the family's and not this
## file's opinion), and pressing one now [i]answers[/i]: the button pops, tips a few
## degrees the way its arrow points, and throws three small sparks off the arc. The
## stroke vanishing (or coming back) happens a frame or two later on the page, so
## without the pop the button felt disconnected from the thing it did. The whole
## reaction is local -- no overlay, no host node, nothing to inject -- which is why
## it still works when the button is dropped into a harness on its own.
##
## [b]Contract[/b]: the parent sets [member forward] once and drives the inherited
## [member BaseButton.disabled]; the button decides nothing and holds no history.

const POP := preload("res://scripts/components/pop_feedback.gd")
const STYLE := preload("res://scripts/components/toolbar_style.gd")

## Minimum size. Narrower than [PadlockButton] because there are two of these in a
## row that already carries five other controls, but still clear of the 48 px touch
## floor (DESIGN.md 3.5) in both axes.
const MIN_SIZE := Vector2(64.0, 60.0)

## Arc geometry, as fractions of the smaller side, so the glyph scales with the box.
const ARC_RADIUS_RATIO := 0.26
const ARC_WIDTH_RATIO := 0.10
const HEAD_RATIO := 0.19

## The press reaction (BL-29): how long the sparks live, how far they fly, and how
## far the button tips towards the direction it undoes in.
const SPARK_SECONDS := 0.46
const SPARK_COUNT := 3
const SPARK_REACH_RATIO := 0.42
const TILT := 0.13

## The slab. Teal, so the two history arrows read as a pair and are never mistaken
## for the violet page arrows two controls along.
const PLATE := Color(0.113725, 0.647059, 0.701961)
const ARROW := Color(1.0, 0.988235, 0.960784)
const SPARK := Color(1.0, 0.945098, 0.729412)
## Matches the toolbar's disabled font colour, so a dead undo button reads as dead
## in exactly the same language the page arrows use.
const ARROW_DISABLED := Color(0.450980, 0.427451, 0.403922)

## False draws the undo arrow (curving back to the left), true the redo arrow.
## Purely presentational -- it decides which way the glyph points and nothing else.
@export var forward: bool = false:
	set(value):
		forward = value
		tooltip_text = "Redo the stroke you took back" if forward else "Undo the last stroke"
		queue_redraw()

## Seconds of spark left to draw. Zero means the button is at rest.
var _spark := 0.0
## The tip. Kept so a second press re-tips from upright instead of fighting the
## first one -- [PopFeedback] owns the scale slot, this owns the rotation one.
var _tilt_tween: Tween
var _plate: StyleBoxFlat = STYLE.plate(PLATE)
var _plate_hover: StyleBoxFlat = STYLE.plate(PLATE.lightened(0.14))
var _plate_pressed: StyleBoxFlat = STYLE.pressed_plate(PLATE)
var _plate_disabled: StyleBoxFlat = STYLE.disabled_plate()


func _init() -> void:
	custom_minimum_size = MIN_SIZE
	focus_mode = Control.FOCUS_NONE
	flat = true
	# The script draws every state, so the theme must not draw one underneath it.
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	set_process(false)


func _ready() -> void:
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)
	POP.attach(self)
	# Self-connected on purpose: the reaction belongs to the button being pressed,
	# not to whatever the parent decides to do about it. A disabled button emits no
	# `pressed`, so a refused undo never animates.
	pressed.connect(play_press)


## The press reaction: pop, tip, spark. Public so the screen can replay it when the
## paint layer has actually finished rebuilding.
func play_press() -> void:
	if not is_inside_tree():
		return
	_spark = SPARK_SECONDS
	set_process(true)
	POP.pop(self, 0.18, 0.30)
	# The tip runs on its own tween: PopFeedback owns the scale slot, and killing
	# one to run the other would cost the pop.
	if _tilt_tween != null and _tilt_tween.is_valid():
		_tilt_tween.kill()
	rotation = 0.0
	pivot_offset = size * 0.5
	_tilt_tween = create_tween()
	_tilt_tween.tween_property(self, "rotation", TILT if forward else -TILT, 0.07)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_tilt_tween.tween_property(self, "rotation", 0.0, 0.23)\
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	queue_redraw()


## True while the press reaction is still playing. Tests can wait on it; the game
## ignores it.
func is_reacting() -> bool:
	return _spark > 0.0


func _process(delta: float) -> void:
	_spark = maxf(_spark - delta, 0.0)
	if is_zero_approx(_spark):
		set_process(false)
	queue_redraw()


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var box := _plate_disabled if disabled else (
		_plate_pressed if button_pressed else (_plate_hover if is_hovered() else _plate)
	)
	box.draw(get_canvas_item(), Rect2(Vector2.ZERO, size))

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

	_draw_sparks(center, radius, unit)


## Three specks thrown off the arc, away from the head -- the direction the stroke
## just went. Drawn here rather than spawned as a [SparkleBurst] so the button needs
## no overlay to live on.
func _draw_sparks(center: Vector2, radius: float, unit: float) -> void:
	if _spark <= 0.0:
		return
	var t := 1.0 - _spark / SPARK_SECONDS
	var fade := 1.0 - t * t
	var reach := unit * SPARK_REACH_RATIO * (0.35 + 0.65 * t)
	var away := -1.0 if forward else 1.0
	for i in SPARK_COUNT:
		var angle := -PI * 0.72 + float(i) * PI * 0.22
		var direction := Vector2(cos(angle) * away, sin(angle))
		var at := center + direction * (radius + reach)
		var tint := SPARK
		tint.a = clampf(fade, 0.0, 1.0)
		draw_circle(at, maxf(unit * 0.045 * (0.4 + fade), 1.0), tint)

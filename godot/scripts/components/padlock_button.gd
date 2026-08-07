class_name PadlockButton
extends Button
## The coloring lock's control (BL-10): a padlock drawn from primitives, open when
## the page can be painted and shut when it cannot.
##
## Drawn rather than textured for the same reason [code]Main.GearButton[/code] is:
## the shell ships no icon assets, and a shape built from a rounded rect and an arc
## stays crisp at every DPI the mobile pass has to cover. Every state's [StyleBox]
## is emptied in [method _init] so this script owns the whole look, hover and
## pressed tint included.
##
## [b]Contract[/b]: the parent sets [member locked] and listens to the inherited
## [signal BaseButton.pressed]; the button decides nothing. [method wiggle] is the
## "you tapped a locked page" feedback -- a short shake, never a dialog, because a
## four-year-old cannot read one and the web export has no modals worth using.

## Minimum size, comfortably over the 48 px touch floor (DESIGN.md 3.5) and
## matching the toolbar's other icon-sized controls.
const MIN_SIZE := Vector2(72.0, 60.0)
## Peak rotation of the shake, in radians (~7 degrees each way).
const WIGGLE_ANGLE := 0.12
## Seconds one whole shake takes.
const WIGGLE_SECONDS := 0.34

const LOCKED_BODY := Color(0.972549, 0.803922, 0.478431)
const OPEN_BODY := Color(0.552941, 0.529412, 0.494118)
const LOCKED_BODY_HOVER := Color(1.0, 0.882353, 0.639216)
const OPEN_BODY_HOVER := Color(0.72549, 0.694118, 0.647059)
const KEYHOLE := Color(0.184314, 0.156863, 0.129412)

## Whether the page this button guards is locked. Purely presentational here --
## the parent owns the state and persists it.
@export var locked: bool = false:
	set(value):
		locked = value
		tooltip_text = (
			"This page is locked — tap to colour it again"
			if locked
			else "Lock this page so it cannot be coloured by accident"
		)
		queue_redraw()

var _wiggle_tween: Tween
## The backplate, drawn by hand so it can change colour with the lock while the
## rest of the toolbar keeps its authored 12 px corners.
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
	resized.connect(_recenter_pivot)
	_recenter_pivot()


func _recenter_pivot() -> void:
	# The shake rotates about the middle of the button, not its top-left corner.
	pivot_offset = size * 0.5


## Shakes the padlock. Called when a press on a locked page was refused, so the
## refusal points at its own cause instead of looking like a dead page.
func wiggle() -> void:
	if not is_inside_tree():
		return
	_recenter_pivot()
	if _wiggle_tween != null and _wiggle_tween.is_valid():
		_wiggle_tween.kill()
	rotation = 0.0
	_wiggle_tween = create_tween()
	var step := WIGGLE_SECONDS * 0.25
	_wiggle_tween.tween_property(self, "rotation", WIGGLE_ANGLE, step)
	_wiggle_tween.tween_property(self, "rotation", -WIGGLE_ANGLE, step)
	_wiggle_tween.tween_property(self, "rotation", WIGGLE_ANGLE * 0.5, step)
	_wiggle_tween.tween_property(self, "rotation", 0.0, step)


## True while the shake is playing. Tests wait on it; the game ignores it.
func is_wiggling() -> bool:
	return _wiggle_tween != null and _wiggle_tween.is_valid()


func _draw() -> void:
	var unit := minf(size.x, size.y)
	var center := size * 0.5
	var body_size := Vector2(unit * 0.62, unit * 0.48)
	var body := Rect2(
		center - Vector2(body_size.x * 0.5, body_size.y * 0.5 - unit * 0.1),
		body_size
	)
	var tint := _body_color()
	if disabled:
		tint = tint.darkened(0.45)

	# Backplate, so the padlock reads as a button of the same family as the rest of
	# the toolbar rather than a floating glyph.
	_plate.bg_color = (
		Color(0.34902, 0.290196, 0.180392) if locked else Color(0.219608, 0.203922, 0.192157)
	)
	_plate.draw(get_canvas_item(), Rect2(Vector2.ZERO, size))

	# Shackle: a half-arc over the body, swung open when the page is unlocked.
	var shackle_radius := body_size.x * 0.34
	var shackle_center := Vector2(center.x, body.position.y - shackle_radius * 0.15)
	var thickness := maxf(unit * 0.075, 2.0)
	if locked:
		draw_arc(shackle_center, shackle_radius, PI, TAU, 24, tint, thickness)
		draw_line(
			shackle_center + Vector2(-shackle_radius, 0.0),
			Vector2(shackle_center.x - shackle_radius, body.position.y),
			tint, thickness
		)
		draw_line(
			shackle_center + Vector2(shackle_radius, 0.0),
			Vector2(shackle_center.x + shackle_radius, body.position.y),
			tint, thickness
		)
	else:
		# Open: the shackle swings up and to the right, off the right-hand post.
		var open_center := shackle_center + Vector2(shackle_radius * 0.9, -shackle_radius * 0.35)
		draw_arc(open_center, shackle_radius, PI, TAU * 0.92, 24, tint, thickness)
		draw_line(
			open_center + Vector2(-shackle_radius, 0.0),
			Vector2(open_center.x - shackle_radius, body.position.y),
			tint, thickness
		)

	draw_rect(body, tint, true)
	draw_circle(Vector2(body.get_center().x, body.get_center().y - body_size.y * 0.06), unit * 0.055, KEYHOLE)
	draw_rect(
		Rect2(
			Vector2(body.get_center().x - unit * 0.022, body.get_center().y - body_size.y * 0.04),
			Vector2(unit * 0.044, body_size.y * 0.3)
		),
		KEYHOLE, true
	)


func _body_color() -> Color:
	if locked:
		return LOCKED_BODY_HOVER if (is_hovered() or button_pressed) else LOCKED_BODY
	return OPEN_BODY_HOVER if (is_hovered() or button_pressed) else OPEN_BODY

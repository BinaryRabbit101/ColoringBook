class_name CrayonBoxFlash
extends Control
## The box's name, shouted once, as the crayons swap (BACKLOG BL-34) -- "Neon!" --
## then gone. Drawn from primitives like every other control in this shell.
##
## [b]Why this exists.[/b] BL-34 deleted the [code]CrayonBoxButton[/code] carton
## tile, and with it the one place the strip said WHICH box was out. The identity
## moved to two cheaper things: the pip row on the [CrayonCycleButton]s (always
## visible, says "box 2 of 6"), and this banner, which says the name out loud at
## the one moment a player is asking the question -- the moment they pressed the
## arrow. A permanent name label would be a permanent slab of text on a strip built
## for a child who cannot read yet; a transient one is a firework.
##
## [b]Transient, and it blocks nothing.[/b] Same shape as the BL-11 celebration:
## pop in ([constant POP_SECONDS], overshooting its size), hold
## ([constant HOLD_SECONDS]), fade out ([constant FADE_OUT_SECONDS]), and it is
## [constant Control.MOUSE_FILTER_IGNORE] throughout, so a finger that is already
## sliding along the crayons never feels it appear.
##
## Anchored over the whole palette and drawn about its own centre, so the palette
## has no placement code to keep in step with [method PaletteChild.set_layout] --
## the banner lands in the middle of the strip in both docks for free, and shrinks
## itself to fit a narrow one.

## The name, and the box's crayons as a row of dots under it.
const HOLD_SECONDS := 0.85
const FADE_OUT_SECONDS := 0.45
const POP_SECONDS := 0.22
## How far past its final size the banner springs on the way in.
const POP_OVERSHOOT := 1.12

const FONT_SIZE := 40
const PAPER := Color(0.996078, 0.972549, 0.921569)
const EDGE := Color(0.415686, 0.360784, 0.301961)
const INK := Color(0.219608, 0.180392, 0.145098)
const PAD := Vector2(26.0, 14.0)
const RADIUS := 20.0
const BORDER_WIDTH := 4.0
const DOT_RADIUS := 5.0
const DOT_GAP := 6.0
## Tilt, in radians -- a banner nailed square to the strip looks like a warning.
const TILT := -0.055

var _title := ""
var _colors: PackedColorArray = PackedColorArray()
var _scale := 1.0
var _alpha := 0.0
var _tween: Tween


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Absolute, like the pick bubble: the banner has to clear the crayons it is
	# announcing, and they are laid out by containers that know nothing about it.
	z_index = 150
	z_as_relative = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false


## Says [param title] over [param colors], from the top. Calling it again while one
## is up restarts the whole beat rather than queueing a second banner -- a child
## hammering the arrow gets the name of the box they landed on, not a backlog.
func flash(title: String, colors: PackedColorArray) -> void:
	_title = title
	_colors = colors
	if title.strip_edges() == "":
		hide_now()
		return
	_kill()
	visible = true
	_alpha = 1.0
	_scale = 0.62
	queue_redraw()
	if not is_inside_tree():
		return
	_tween = create_tween()
	_tween.tween_method(_set_scale, POP_OVERSHOOT * 0.62, POP_OVERSHOOT, POP_SECONDS * 0.5)
	_tween.tween_method(_set_scale, POP_OVERSHOOT, 1.0, POP_SECONDS * 0.5) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_interval(HOLD_SECONDS)
	_tween.tween_method(_set_alpha, 1.0, 0.0, FADE_OUT_SECONDS)
	_tween.tween_callback(hide_now)


func hide_now() -> void:
	_kill()
	_alpha = 0.0
	_scale = 1.0
	visible = false
	queue_redraw()


## True while a banner is on screen (including its fade). The palette smoke's
## "the strip says which box it just fetched" check.
func is_showing() -> bool:
	return visible and _alpha > 0.0


## The name currently being shouted. "" when nothing is up.
func get_title() -> String:
	return _title if is_showing() else ""


func _notification(what: int) -> void:
	# The web tab-switch case, borrowed from PickPreview: no tween runs while the
	# tab is away, so a banner would still be sitting there on the way back.
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT \
			or what == NOTIFICATION_EXIT_TREE:
		hide_now()


func _set_scale(value: float) -> void:
	_scale = value
	queue_redraw()


func _set_alpha(value: float) -> void:
	_alpha = value
	queue_redraw()


func _kill() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


func _draw() -> void:
	if not is_showing() or size.x <= 0.0 or size.y <= 0.0:
		return
	var font := _font()
	if font == null:
		return
	var text_size := font.get_string_size(_title, HORIZONTAL_ALIGNMENT_CENTER, -1.0, FONT_SIZE)
	var dots_width := float(_colors.size()) * (DOT_RADIUS * 2.0 + DOT_GAP) - DOT_GAP
	var banner := Vector2(
		maxf(text_size.x, dots_width) + PAD.x * 2.0,
		text_size.y + DOT_RADIUS * 2.0 + PAD.y * 2.0 + 8.0
	)
	# A long name on a docked column would run off the strip; shrink rather than
	# clip, because the banner is the only place the name is ever written.
	var fit := minf(1.0, (size.x - 12.0) / maxf(banner.x, 1.0))
	draw_set_transform(size * 0.5, TILT, Vector2.ONE * (_scale * fit))

	var box := Rect2(-banner * 0.5, banner)
	_draw_round_rect(box.grow(3.0), Color(0.0, 0.0, 0.0, 0.28 * _alpha))
	_draw_round_rect(box, Color(PAPER.r, PAPER.g, PAPER.b, PAPER.a * _alpha))
	_draw_round_rect_outline(box, Color(EDGE.r, EDGE.g, EDGE.b, EDGE.a * _alpha))

	var baseline := box.position.y + PAD.y + font.get_ascent(FONT_SIZE)
	draw_string(
		font, Vector2(box.position.x + PAD.x, baseline), _title,
		HORIZONTAL_ALIGNMENT_CENTER, banner.x - PAD.x * 2.0, FONT_SIZE,
		Color(INK.r, INK.g, INK.b, _alpha)
	)

	var dots_y := box.end.y - PAD.y - DOT_RADIUS
	var left := -dots_width * 0.5 + DOT_RADIUS
	for i in _colors.size():
		var colour := _colors[i]
		draw_circle(
			Vector2(left + float(i) * (DOT_RADIUS * 2.0 + DOT_GAP), dots_y),
			DOT_RADIUS, Color(colour.r, colour.g, colour.b, colour.a * _alpha)
		)


func _font() -> Font:
	var font := get_theme_default_font()
	return font if font != null else ThemeDB.fallback_font


func _draw_round_rect(box: Rect2, color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(int(RADIUS))
	draw_style_box(style, box)


func _draw_round_rect_outline(box: Rect2, color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	style.draw_center = false
	style.border_color = color
	style.set_border_width_all(int(BORDER_WIDTH))
	style.set_corner_radius_all(int(RADIUS))
	draw_style_box(style, box)

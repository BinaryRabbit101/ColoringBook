class_name IntensityButton
extends BaseButton
## The crayon strip's light-to-dark swap (BACKLOG BL-22), drawn from primitives --
## no art assets, like every other control in this shell.
##
## [b]It answers two questions at once[/b], which is why it is a drawing rather
## than a label:
##
## 1. [b]"Which shade am I painting with?"[/b] The tile holds the whole intensity
##    ladder of the current crayon -- [constant PaletteDef.INTENSITY_STEPS] rungs,
##    palest at the top -- and the ACTIVE rung is drawn wider, inside a bright rim
##    and a dark keyline. That is the same visual grammar a selected [CrayonButton]
##    uses, and it is visible whether or not a finger is on the strip (BL-15's
##    lesson: the state that matters must not live under the hand).
## 2. [b]"What happens if I press it?"[/b] While the strip is showing colours the
##    tile is CLOSED -- the ladder sits small behind a folded corner, with an arrow
##    pointing into it -- and pressing opens the ladder onto the strip. While the
##    strip is showing shades the tile is OPEN: full-bleed ladder, bright border,
##    and the arrow points back out. A child does not read either state; they see
##    that the button changed and that the crayons changed with it.
##
## The owner sets [member base_color] and [member showing_shades] and
## [member active_step]; this node only reports [signal BaseButton.pressed].
## It never resolves a colour itself -- [PaletteChild] owns the pick.

## Touch target. Comfortably past DESIGN.md 3.5's 48 px floor and past the 64 px
## the crayons use, because it is the one control on the strip that is not a
## crayon and has to be findable.
const SIZE := Vector2(88.0, 88.0)

const PAPER := Color(0.996078, 0.972549, 0.921569)
const EDGE := Color(0.415686, 0.360784, 0.301961)
const OPEN_EDGE := Color(0.972549, 0.803922, 0.478431)
const ARROW := Color(0.298039, 0.254902, 0.211765)
## The bright rim + dark keyline that mark the active rung, matched to
## [constant CrayonButton.SELECTION_RIM] so "this one is picked" looks the same
## everywhere on the strip.
const RUNG_RIM := Color(1.0, 0.972549, 0.874510, 0.95)
const RUNG_RIM_WIDTH := 3.0
const RUNG_KEYLINE_WIDTH := 2.0

const TILE_INSET := 5.0
const TILE_RADIUS := 12.0
const BORDER_WIDTH := 3.0
## Gutter between the tile edge and the ladder inside it. Wider when the tile is
## closed, so the ladder reads as tucked away rather than merely smaller.
const LADDER_INSET_OPEN := 8.0
const LADDER_INSET_CLOSED := 15.0
## Extra width the active rung gains, each side, as a fraction of the ladder width.
const ACTIVE_RUNG_BLEED := 0.14
## Room kept clear for the chevron, as a fraction of the tile's short side.
const ARROW_GUTTER := 0.24

## The crayon whose ladder is drawn. Set by the palette on every colour pick.
var base_color: Color = Color.WHITE:
	set(value):
		base_color = value
		queue_redraw()

## True while the strip is showing that ladder instead of the crayon colours.
var showing_shades: bool = false:
	set(value):
		if showing_shades == value:
			return
		showing_shades = value
		queue_redraw()

## Which rung is painting right now, 0..[constant PaletteDef.INTENSITY_STEPS] - 1.
var active_step: int = PaletteDef.INTENSITY_BASE_STEP:
	set(value):
		var clamped := clampi(value, 0, PaletteDef.INTENSITY_STEPS - 1)
		if active_step == clamped:
			return
		active_step = clamped
		queue_redraw()

## The palette the ladder is computed from. Injected rather than reached for, so
## this button stays drawable standalone (it falls back to a bare [PaletteDef]).
var _palette: PaletteDef


func _init() -> void:
	custom_minimum_size = SIZE
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Lighter and darker"


func _ready() -> void:
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)


## The [PaletteDef] whose [method PaletteDef.shade_of] draws the ladder. Null is
## allowed; a throwaway def is used instead, because the ladder is a pure function
## and a button that cannot draw is worse than one drawn from defaults.
func set_palette(def: PaletteDef) -> void:
	_palette = def
	queue_redraw()


## The ladder this button is drawing, pale first. Public so the palette smoke can
## compare it against what the strip actually rendered.
func get_ladder() -> PackedColorArray:
	return _def().shades_of(base_color)


func _def() -> PaletteDef:
	if _palette == null:
		_palette = PaletteDef.new()
	return _palette


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var tile := Rect2(Vector2(TILE_INSET, TILE_INSET), size - Vector2(TILE_INSET, TILE_INSET) * 2.0)
	if tile.size.x <= 0.0 or tile.size.y <= 0.0:
		return
	var sunk := 2.0 if is_pressed() else 0.0
	tile.position.y += sunk

	draw_rect(Rect2(tile.position + Vector2(0.0, 3.0), tile.size), Color(0.0, 0.0, 0.0, 0.22), true)
	_draw_round_rect(tile, PAPER)

	var inset := LADDER_INSET_OPEN if showing_shades else LADDER_INSET_CLOSED
	var ladder := tile.grow(-inset)
	# The arrow gets a gutter of its own at whichever end it points from, so it
	# never lands on top of a rung -- least of all the active one.
	var gutter := minf(tile.size.x, tile.size.y) * ARROW_GUTTER
	if showing_shades:
		ladder.position.y += gutter
	ladder.size.y -= gutter
	if ladder.size.x > 0.0 and ladder.size.y > 0.0:
		_draw_ladder(ladder)
	_draw_arrow(tile)

	var border := OPEN_EDGE if showing_shades else EDGE
	var width := BORDER_WIDTH + (1.0 if showing_shades else 0.0)
	if is_hovered():
		border = OPEN_EDGE
	_draw_round_rect_outline(tile, border, width)


## The whole intensity ladder as stacked bars, palest at the top. The active rung
## is wider and wears the selection rim, so "which shade" is answered without a
## finger being anywhere near the strip.
func _draw_ladder(box: Rect2) -> void:
	var shades := get_ladder()
	if shades.is_empty():
		return
	var rung_height := box.size.y / float(shades.size())
	var bleed := box.size.x * ACTIVE_RUNG_BLEED
	for i in shades.size():
		var active := i == active_step
		var grow := bleed if active else 0.0
		var rung := Rect2(
			Vector2(box.position.x - grow, box.position.y + rung_height * float(i)),
			Vector2(box.size.x + grow * 2.0, rung_height)
		)
		draw_rect(rung, shades[i], true)
		if active:
			draw_rect(rung.grow(RUNG_RIM_WIDTH * 0.5), RUNG_RIM, false, RUNG_RIM_WIDTH)
			draw_rect(rung, base_color.darkened(0.6), false, RUNG_KEYLINE_WIDTH)


## A small chevron in the tile's gutter: pointing INTO the tile while the ladder is
## tucked away, back OUT of it while the ladder is on the strip.
func _draw_arrow(tile: Rect2) -> void:
	var span := minf(tile.size.x, tile.size.y) * 0.16
	var centre := Vector2(tile.position.x + tile.size.x * 0.5, 0.0)
	var tip := 0.0
	var back := 0.0
	if showing_shades:
		centre.y = tile.position.y + span * 1.15
		tip = centre.y - span * 0.6
		back = centre.y + span * 0.4
	else:
		centre.y = tile.end.y - span * 1.15
		tip = centre.y + span * 0.6
		back = centre.y - span * 0.4
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(centre.x - span, back),
			Vector2(centre.x + span, back),
			Vector2(centre.x, tip),
		]),
		ARROW
	)


func _draw_round_rect(box: Rect2, color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(int(TILE_RADIUS))
	draw_style_box(style, box)


func _draw_round_rect_outline(box: Rect2, color: Color, width: float) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	style.draw_center = false
	style.border_color = color
	style.set_border_width_all(int(width))
	style.set_corner_radius_all(int(TILE_RADIUS))
	draw_style_box(style, box)

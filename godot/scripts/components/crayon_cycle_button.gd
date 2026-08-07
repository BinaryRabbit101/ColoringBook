class_name CrayonCycleButton
extends BaseButton
## One end of the crayon-box carousel (BACKLOG BL-34), drawn from primitives --
## no art assets, like every other control in this shell.
##
## [b]It replaced the single forward-only [code]CrayonBoxButton[/code] tile.[/b] The
## strip now has a cycle control at each OUTER END of its long axis: press the one
## at the start for the box before this one, the one at the end for the box after
## it. Two controls instead of one because a carousel a four-year-old can only
## drive forwards is a carousel they get lost in -- overshooting the box they
## wanted meant going all the way round again.
##
## [b]It answers "what happens if I press it", not "where am I".[/b] The chevron
## points the way the strip will move, and the stripe along the tile's outer edge
## is the DESTINATION box's crayons, so a child can see the next box's colours
## before committing to them. Where the strip is right now is the pip row along the
## tile's inner edge (one pip per box, the current one filled) and the
## [CrayonBoxFlash] banner that pops up on every cycle -- the two halves of the job
## the deleted carton tile used to do alone.
##
## [b]No text.[/b] Same reason as the tile it replaced: the box's name is exactly
## what the youngest player cannot read. The name does get said out loud, once, by
## the flash banner -- for the grown-up in the room and the child who is learning.
##
## [b]It is a BAR, not a tile[/b] ([constant THICKNESS] across the strip's long
## axis, stretching along its short one): a bar costs the crayons the least length,
## which is the whole currency of BL-33's no-scroll fit, and it caps the strip's
## end like a lid on the box.
##
## The owner sets [member direction], [member vertical], [member preview_colors]
## and [member set_index] / [member set_count]; this node only reports
## [signal BaseButton.pressed].

## Backwards along the cycle -- the box BEFORE the one on the strip.
const DIR_PREV := -1
## Forwards along the cycle.
const DIR_NEXT := 1

## How thick the bar is across the strip's LONG axis. Past DESIGN.md 3.5's 48 px
## floor and past the crayons' 64 px, while still costing the strip less length
## than the 88 px tool tiles it sits beside (BL-33 spends every pixel of that
## length on crayons).
const THICKNESS := 68.0
## Minimum extent along the strip's SHORT axis. The bar normally stretches past
## this; it is a floor for a standalone/unstretched one.
const MIN_SPAN := 88.0

const PAPER := Color(0.996078, 0.972549, 0.921569)
const EDGE := Color(0.415686, 0.360784, 0.301961)
const HOVER_EDGE := Color(0.972549, 0.803922, 0.478431)
const ARROW := Color(0.298039, 0.254902, 0.211765)

const TILE_INSET := 5.0
const TILE_RADIUS := 12.0
const BORDER_WIDTH := 3.0
## Chevron half-size, as a fraction of the tile's short side.
const CHEVRON_RATIO := 0.30
const CHEVRON_WIDTH := 10.0
## The destination box's crayons, as a segmented stripe hugging the outer edge.
const STRIPE_THICKNESS := 7.0
const STRIPE_SPAN_RATIO := 0.62
## Pip row along the inner edge: one pip per box, the current one filled.
const PIP_RADIUS := 3.4
const PIP_GAP := 5.0

## Which way this control moves the carousel: [constant DIR_PREV] or
## [constant DIR_NEXT].
var direction: int = DIR_NEXT:
	set(value):
		var resolved := DIR_PREV if value < 0 else DIR_NEXT
		if direction == resolved:
			return
		direction = resolved
		_apply_box()
		queue_redraw()

## True while the strip is docked as a COLUMN (BL-21), so the bar caps the top or
## the bottom and the chevron points up or down instead of left or right.
var vertical: bool = false:
	set(value):
		if vertical == value:
			return
		vertical = value
		_apply_box()
		queue_redraw()

## The crayons of the box this control would fetch. Drawn as the outer stripe --
## the destination, never the current box.
var preview_colors: PackedColorArray = PackedColorArray():
	set(value):
		preview_colors = value
		queue_redraw()

## Which box is on the strip, and how many there are. The pip row.
var set_index: int = 0:
	set(value):
		set_index = maxi(value, 0)
		queue_redraw()

var set_count: int = 1:
	set(value):
		set_count = maxi(value, 1)
		queue_redraw()


func _init() -> void:
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_box()


func _ready() -> void:
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)


## The bar's own minimum box for the strip it is capping: thin across the strip's
## long axis, [constant MIN_SPAN] across its short one. Static so the palette can
## budget the strip's length before anything is laid out (BL-33).
static func box_for(is_vertical: bool) -> Vector2:
	return Vector2(MIN_SPAN, THICKNESS) if is_vertical else Vector2(THICKNESS, MIN_SPAN)


func _apply_box() -> void:
	custom_minimum_size = box_for(vertical)
	tooltip_text = (
		"The box of crayons before this one" if direction == DIR_PREV
		else "Another box of crayons"
	)


## Unit vector, in this control's own space, that the chevron points along: OUT of
## the strip, the way the carousel moves. Public so the palette smoke can assert
## the two ends really do point opposite ways.
func point_direction() -> Vector2:
	if vertical:
		return Vector2.UP if direction == DIR_PREV else Vector2.DOWN
	return Vector2.LEFT if direction == DIR_PREV else Vector2.RIGHT


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var tile := Rect2(Vector2(TILE_INSET, TILE_INSET), size - Vector2(TILE_INSET, TILE_INSET) * 2.0)
	if tile.size.x <= 0.0 or tile.size.y <= 0.0:
		return
	if is_pressed():
		tile.position += point_direction() * 2.0

	draw_rect(Rect2(tile.position + Vector2(0.0, 3.0), tile.size), Color(0.0, 0.0, 0.0, 0.22), true)
	_draw_round_rect(tile, PAPER)

	_draw_stripe(tile)
	_draw_pips(tile)
	_draw_chevron(tile)
	_draw_round_rect_outline(tile, HOVER_EDGE if is_hovered() else EDGE, BORDER_WIDTH)


## A point [param along] pixels towards where the chevron points and
## [param across] pixels sideways from the tile's centre. Every piece of the
## drawing is placed through this, so one set of coordinates serves all four
## end/orientation combinations and there is no forked drawing code (the rule
## [CrayonButton] follows for the same reason).
func _at(tile: Rect2, along: float, across: float) -> Vector2:
	var forward := point_direction()
	var sideways := Vector2(-forward.y, forward.x)
	return tile.get_center() + forward * along + sideways * across


## Extent of the tile along the chevron's axis, and across it.
func _extents(tile: Rect2) -> Vector2:
	return Vector2(tile.size.y, tile.size.x) if vertical else Vector2(tile.size.x, tile.size.y)


## The chevron: big, in the outer half, pointing the way the strip will move.
func _draw_chevron(tile: Rect2) -> void:
	var extents := _extents(tile)
	var span := minf(extents.x, extents.y) * CHEVRON_RATIO
	var tip := extents.x * 0.5 - span * 0.75
	draw_polyline(
		PackedVector2Array([
			_at(tile, tip - span, span),
			_at(tile, tip, 0.0),
			_at(tile, tip - span, -span),
		]),
		ARROW, CHEVRON_WIDTH, true
	)


## The DESTINATION box's crayons as a segmented stripe hugging the outer edge:
## "these are the colours you would get", answered before the press.
func _draw_stripe(tile: Rect2) -> void:
	if preview_colors.is_empty():
		return
	var extents := _extents(tile)
	var span := extents.y * STRIPE_SPAN_RATIO
	var along := extents.x * 0.5 - STRIPE_THICKNESS * 0.9
	var segment := span / float(preview_colors.size())
	for i in preview_colors.size():
		var centre := -span * 0.5 + segment * (float(i) + 0.5)
		var a := _at(tile, along, centre - segment * 0.5)
		var b := _at(tile, along, centre + segment * 0.5)
		draw_line(a, b, preview_colors[i], STRIPE_THICKNESS)


## One pip per box along the INNER edge, the current one filled: "there are five
## of these and you are on the second", without a number.
func _draw_pips(tile: Rect2) -> void:
	var extents := _extents(tile)
	var span := float(set_count) * (PIP_RADIUS * 2.0 + PIP_GAP) - PIP_GAP
	var along := -extents.x * 0.5 + PIP_RADIUS + 6.0
	for i in set_count:
		var across := -span * 0.5 + PIP_RADIUS + float(i) * (PIP_RADIUS * 2.0 + PIP_GAP)
		var centre := _at(tile, along, across)
		if i == set_index:
			draw_circle(centre, PIP_RADIUS, EDGE)
		else:
			draw_arc(centre, PIP_RADIUS, 0.0, TAU, 16, EDGE, 1.5, true)


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

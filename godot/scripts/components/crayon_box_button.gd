class_name CrayonBoxButton
extends BaseButton
## Cycles the crayon strip through its boxes (BACKLOG BL-23), drawn from
## primitives -- no art assets, like every other control in this shell.
##
## [b]It shows the box you are holding, not the one you would get.[/b] The tile is
## a little carton with the CURRENT set's crayons standing in it, so a child can
## see at a glance which box is out; the arrow on the carton's lip says there are
## more, and pressing fetches the next one. That is the opposite convention from
## the [IntensityButton] next to it, deliberately: the ladder is a MODE you go into
## and come back out of, so its button previews the destination, while the boxes
## are a carousel with no home, so its button reports the position.
##
## [b]No text.[/b] The set's name would be the obvious label and is exactly what a
## four-year-old cannot use; the crayons in the carton are the name.
##
## The owner sets [member set_colors] and [member set_index] / [member set_count];
## this node only reports [signal BaseButton.pressed].

## Touch target, matched to [constant IntensityButton.SIZE] so the two tools on
## the strip are one pair rather than two decisions.
const SIZE := Vector2(88.0, 88.0)

const PAPER := Color(0.996078, 0.972549, 0.921569)
const EDGE := Color(0.415686, 0.360784, 0.301961)
const HOVER_EDGE := Color(0.972549, 0.803922, 0.478431)
## The carton the crayons stand in. Warm card, so it reads as a box of crayons
## rather than as a chart.
const CARTON := Color(0.752941, 0.470588, 0.286275)
const CARTON_EDGE := Color(0.443137, 0.258824, 0.152941)
const ARROW := Color(0.298039, 0.254902, 0.211765)

const TILE_INSET := 5.0
const TILE_RADIUS := 12.0
const BORDER_WIDTH := 3.0
## The carton's share of the tile height, measured from its bottom.
const CARTON_HEIGHT_RATIO := 0.46
## Most crayons the carton draws, however many the set holds. Past this they stop
## being crayons and start being stripes.
const MAX_CRAYONS_DRAWN := 5
## Gap between drawn crayons, as a fraction of one crayon's width.
const CRAYON_GAP_RATIO := 0.28
## The tip's share of a drawn crayon's height.
const TIP_RATIO := 0.26
## Pip strip along the tile's top edge: one pip per box, the current one filled.
const PIP_RADIUS := 3.4
const PIP_GAP := 5.0

## The colours in the box being held. The first [constant MAX_CRAYONS_DRAWN] are
## what the carton shows.
var set_colors: PackedColorArray = PackedColorArray():
	set(value):
		set_colors = value
		queue_redraw()

## Which box, and how many there are -- drawn as the pip strip, so "there are more
## of these" is visible before anything is pressed.
var set_index: int = 0:
	set(value):
		set_index = maxi(value, 0)
		queue_redraw()

var set_count: int = 1:
	set(value):
		set_count = maxi(value, 1)
		queue_redraw()


func _init() -> void:
	custom_minimum_size = SIZE
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Another box of crayons"


func _ready() -> void:
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var tile := Rect2(Vector2(TILE_INSET, TILE_INSET), size - Vector2(TILE_INSET, TILE_INSET) * 2.0)
	if tile.size.x <= 0.0 or tile.size.y <= 0.0:
		return
	if is_pressed():
		tile.position.y += 2.0

	draw_rect(Rect2(tile.position + Vector2(0.0, 3.0), tile.size), Color(0.0, 0.0, 0.0, 0.22), true)
	_draw_round_rect(tile, PAPER)

	_draw_pips(tile)
	_draw_carton(tile)
	_draw_arrow(tile)
	_draw_round_rect_outline(tile, HOVER_EDGE if is_hovered() else EDGE, BORDER_WIDTH)


## One pip per box along the top edge, the current one filled: the only way the
## control can say "there are five of these" without a number.
func _draw_pips(tile: Rect2) -> void:
	var span := float(set_count) * (PIP_RADIUS * 2.0 + PIP_GAP) - PIP_GAP
	var left := tile.position.x + (tile.size.x - span) * 0.5 + PIP_RADIUS
	var y := tile.position.y + PIP_RADIUS + 5.0
	for i in set_count:
		var centre := Vector2(left + float(i) * (PIP_RADIUS * 2.0 + PIP_GAP), y)
		if i == set_index:
			draw_circle(centre, PIP_RADIUS, EDGE)
		else:
			draw_arc(centre, PIP_RADIUS, 0.0, TAU, 16, EDGE, 1.5, true)


## The carton, with the set's first few crayons standing up out of it.
func _draw_carton(tile: Rect2) -> void:
	var carton_height := tile.size.y * CARTON_HEIGHT_RATIO
	var carton := Rect2(
		Vector2(tile.position.x + 10.0, tile.end.y - carton_height - 8.0),
		Vector2(tile.size.x - 20.0, carton_height)
	)
	if carton.size.x <= 0.0 or carton.size.y <= 0.0:
		return

	var drawn := mini(set_colors.size(), MAX_CRAYONS_DRAWN)
	if drawn > 0:
		# The crayons are drawn FIRST and clipped by the carton drawn over them, so
		# they read as standing in it rather than in front of it.
		var slot := carton.size.x / float(drawn)
		var width := slot / (1.0 + CRAYON_GAP_RATIO)
		var height := tile.size.y * 0.46
		var top := carton.position.y - height * 0.62
		var tip := height * TIP_RATIO
		for i in drawn:
			var x := carton.position.x + slot * float(i) + (slot - width) * 0.5
			var color := set_colors[i]
			draw_colored_polygon(
				PackedVector2Array([
					Vector2(x + width * 0.5, top),
					Vector2(x + width, top + tip),
					Vector2(x + width, top + height),
					Vector2(x, top + height),
					Vector2(x, top + tip),
				]),
				color
			)
			draw_rect(Rect2(x, top + tip + height * 0.22, width, height * 0.16), PAPER)

	draw_rect(carton, CARTON, true)
	draw_rect(carton, CARTON_EDGE, false, 2.0)
	# A lighter front panel, so the carton has a lip the crayons come out of.
	draw_rect(
		Rect2(carton.position + Vector2(0.0, carton.size.y * 0.42),
			Vector2(carton.size.x, carton.size.y * 0.58)),
		CARTON.lightened(0.16), true
	)


## A right-pointing chevron on the carton: press for the next box.
func _draw_arrow(tile: Rect2) -> void:
	var span := minf(tile.size.x, tile.size.y) * 0.15
	var centre := Vector2(tile.end.x - span * 1.5, tile.end.y - span * 1.6)
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(centre.x - span * 0.5, centre.y - span),
			Vector2(centre.x - span * 0.5, centre.y + span),
			Vector2(centre.x + span * 0.8, centre.y),
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

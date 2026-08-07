class_name ShelfBoards
extends Control
## The bookcase the shelf's books stand on (BL-28), drawn from primitives.
##
## [b]The boards follow the layout, they are not the layout.[/b] The screen's
## [GridContainer] still owns where every [BookCell] goes -- responsive columns and
## all. This node is handed that grid via [method set_grid], reads back the rect
## each cell ended up in, groups the cells into ROWS by their y position, and draws
## one wooden plank under each row plus the carcass around them. Add a book, resize
## the window, change the column count: the bookcase re-draws itself to match,
## because it never stores a row count of its own.
##
## It is laid out as the grid's SIBLING inside a shared [MarginContainer], so both
## get the same rect and a cell's position in the grid is its position here too
## (the small difference when the grid shrink-centres is measured, not assumed --
## see [method _row_rects]). The carcass -- uprights, back panel, top rail, plinth
## -- is drawn OUTSIDE that shared rect, into the margins the container reserves;
## Godot does not clip a [Control]'s [method CanvasItem._draw] to its own box, and
## the padding constants below are what those margins must be.
##
## Input-transparent: it is behind the books and must never eat a tap.

## How far the carcass extends past the grid on each side. The owning screen
## reserves exactly this much (see [code]BookSelect.SHELF_FRAME_*[/code]).
const SIDE_PAD := 24.0
const TOP_PAD := 18.0
const BOTTOM_PAD := 30.0

## Wood. Four tones, lightest on the surfaces that face up.
const WOOD_LIT := Color(0.874510, 0.654902, 0.407843)
const WOOD := Color(0.788235, 0.541176, 0.309804)
const WOOD_EDGE := Color(0.639216, 0.396078, 0.203922)
const WOOD_DEEP := Color(0.396078, 0.243137, 0.149020)
const WOOD_BACK := Color(0.505882, 0.325490, 0.203922)
const GRAIN := Color(0.435294, 0.270588, 0.160784, 0.35)

## One plank: a lit top face, a front edge, and a dark line under it.
const BOARD_TOP := 7.0
const BOARD_FRONT := 12.0
const BOARD_UNDERLINE := 3.0
## Shadow the plank throws down the back panel.
const BOARD_SHADOW_HEIGHT := 12.0
const BOARD_SHADOW := Color(0.145098, 0.070588, 0.031373, 0.26)

## Uprights at each end of the carcass.
const UPRIGHT_WIDTH := 15.0
## Shadow the whole bookcase casts on the wall.
const CASE_SHADOW := Color(0.125490, 0.058824, 0.019608, 0.22)
const CASE_SHADOW_OFFSET := Vector2(7.0, 10.0)

## Contact shadow pooled under each book where it meets the plank.
const CONTACT_SHADOW := Color(0.180392, 0.086275, 0.039216, 0.30)
const CONTACT_HEIGHT := 9.0
const CONTACT_INSET := 6.0

## An empty bookcase still has to look like a bookcase, so it draws this many bare
## shelves (BL-25 made "no books yet" a normal first run).
const EMPTY_SHELVES := 2
const EMPTY_SHELF_HEIGHT := 168.0

var _grid: GridContainer
var _panel := StyleBoxFlat.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.set_corner_radius_all(12)


## Injected by the owning screen: the grid whose rows this bookcase draws under.
## Re-draws whenever that grid re-sorts, so column changes and book changes land
## without the screen having to say so.
func set_grid(grid: GridContainer) -> void:
	if _grid == grid:
		return
	_grid = grid
	if _grid != null:
		if not _grid.sort_children.is_connected(queue_redraw):
			_grid.sort_children.connect(queue_redraw)
		if not _grid.resized.is_connected(queue_redraw):
			_grid.resized.connect(queue_redraw)
	queue_redraw()


## Minimum box an EMPTY bookcase asks for, so the "no books yet" screen still
## shows furniture rather than a gap.
static func empty_min_size() -> Vector2:
	return Vector2(0.0, float(EMPTY_SHELVES) * EMPTY_SHELF_HEIGHT)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	if size.x <= 8.0 or size.y <= 8.0:
		return
	var frame := Rect2(
		-SIDE_PAD, -TOP_PAD,
		size.x + SIDE_PAD * 2.0, size.y + TOP_PAD + BOTTOM_PAD
	)
	var inner_left := frame.position.x + UPRIGHT_WIDTH
	var inner_right := frame.end.x - UPRIGHT_WIDTH
	var inner_width := inner_right - inner_left

	_draw_case_shadow(frame)
	_draw_back_panel(Rect2(inner_left, frame.position.y, inner_width, frame.size.y))

	var rows := _row_rects()
	if rows.is_empty():
		_draw_empty_shelves(inner_left, inner_width, frame)
	else:
		for row: Rect2 in rows:
			_draw_board(inner_left, inner_width, row.end.y)
		_draw_contact_shadows(rows)
		# Plinth: the wood below the lowest plank, so the case has a base.
		var lowest: Rect2 = rows[rows.size() - 1]
		var plinth_top := lowest.end.y + BOARD_TOP + BOARD_FRONT + BOARD_UNDERLINE
		if plinth_top < frame.end.y:
			draw_rect(
				Rect2(inner_left, plinth_top, inner_width, frame.end.y - plinth_top),
				WOOD_DEEP
			)

	_draw_top_rail(frame)
	_draw_uprights(frame)
	draw_rect(frame, WOOD_DEEP, false, 2.0)


# ==================================================================== pieces ==

func _draw_case_shadow(frame: Rect2) -> void:
	_panel.bg_color = CASE_SHADOW
	_panel.set_corner_radius_all(16)
	draw_style_box(_panel, Rect2(frame.position + CASE_SHADOW_OFFSET, frame.size))
	_panel.set_corner_radius_all(12)


func _draw_back_panel(panel: Rect2) -> void:
	draw_rect(panel, WOOD_BACK)
	# Vertical grain, and a gradient of shadow down each side so the back reads
	# as recessed rather than as a second flat colour.
	var seams := int(panel.size.x / 46.0)
	for i in seams:
		var x := panel.position.x + float(i + 1) * 46.0
		draw_line(Vector2(x, panel.position.y), Vector2(x, panel.end.y), GRAIN, 1.0)
	var gutter := 22.0
	draw_rect(Rect2(panel.position.x, panel.position.y, gutter, panel.size.y),
		Color(0.145098, 0.070588, 0.031373, 0.18))
	draw_rect(Rect2(panel.end.x - gutter, panel.position.y, gutter, panel.size.y),
		Color(0.145098, 0.070588, 0.031373, 0.18))


## One plank. [param top] is where its upper surface sits -- which is exactly the
## bottom of the row of books standing on it.
func _draw_board(x: float, width: float, top: float) -> void:
	draw_rect(Rect2(x, top, width, BOARD_TOP), WOOD_LIT)
	draw_rect(Rect2(x, top + BOARD_TOP, width, BOARD_FRONT), WOOD)
	draw_rect(
		Rect2(x, top + BOARD_TOP + BOARD_FRONT, width, BOARD_UNDERLINE), WOOD_EDGE
	)
	# A bright line along the very front lip, and the shadow the plank throws.
	draw_line(
		Vector2(x, top + 1.0), Vector2(x + width, top + 1.0),
		Color(1.0, 0.925490, 0.807843, 0.55), 2.0
	)
	var shadow_top := top + BOARD_TOP + BOARD_FRONT + BOARD_UNDERLINE
	for i in 4:
		var alpha := BOARD_SHADOW.a * (1.0 - float(i) / 4.0)
		draw_rect(
			Rect2(x, shadow_top + float(i) * BOARD_SHADOW_HEIGHT * 0.25,
				width, BOARD_SHADOW_HEIGHT * 0.25),
			Color(BOARD_SHADOW.r, BOARD_SHADOW.g, BOARD_SHADOW.b, alpha)
		)


## The pool of dark where a book meets the plank. Drawn AFTER the planks (it lands
## on them) but behind the books, which are this node's siblings further forward.
func _draw_contact_shadows(rows: Array) -> void:
	if _grid == null:
		return
	var offset := _grid_offset()
	for child in _grid.get_children():
		var cell := child as Control
		if cell == null or not cell.visible:
			continue
		var rect := Rect2(cell.position + offset, cell.size)
		var pool := Rect2(
			rect.position.x + CONTACT_INSET, rect.end.y - CONTACT_HEIGHT * 0.5,
			maxf(rect.size.x - CONTACT_INSET * 2.0, 4.0), CONTACT_HEIGHT
		)
		draw_colored_polygon(_ellipse(pool), CONTACT_SHADOW)


func _draw_top_rail(frame: Rect2) -> void:
	draw_rect(Rect2(frame.position.x, frame.position.y, frame.size.x, BOARD_TOP), WOOD_LIT)
	draw_rect(
		Rect2(frame.position.x, frame.position.y + BOARD_TOP, frame.size.x, BOARD_FRONT * 0.6),
		WOOD
	)


## The two end panels. The room's light comes from the upper LEFT (see
## [ShelfBackdrop]), so on both panels the left-hand face is the lit one and the
## right-hand side falls into shade; the 3 px dark line is the crease where the
## panel turns into the case, which is the RIGHT edge of the left panel and the
## LEFT edge of the right one. Getting that pair the same way round is what stops
## the case reading as two flat stripes.
func _draw_uprights(frame: Rect2) -> void:
	var lit_width := UPRIGHT_WIDTH * 0.45
	const CREASE := 3.0
	for side in 2:
		var left_panel := side == 0
		var x := frame.position.x if left_panel else frame.end.x - UPRIGHT_WIDTH
		draw_rect(Rect2(x, frame.position.y, UPRIGHT_WIDTH, frame.size.y), WOOD)
		# The lit face starts past the crease on the right-hand panel, so the two
		# never overdraw each other.
		var lit_x := x if left_panel else x + CREASE
		draw_rect(Rect2(lit_x, frame.position.y, lit_width, frame.size.y), WOOD_LIT)
		var crease_x := x + UPRIGHT_WIDTH - CREASE if left_panel else x
		draw_rect(Rect2(crease_x, frame.position.y, CREASE, frame.size.y), WOOD_EDGE)


## Bare shelves for an empty bookcase, evenly spaced down the frame.
func _draw_empty_shelves(x: float, width: float, frame: Rect2) -> void:
	var span := frame.size.y - TOP_PAD
	for i in EMPTY_SHELVES:
		var top := frame.position.y + span * (float(i + 1) / float(EMPTY_SHELVES))
		_draw_board(x, width, top - BOARD_TOP - BOARD_FRONT)


# =================================================================== geometry ==

## The rect each ROW of the grid occupies, top to bottom. Cells in one row share a
## y, so the y position is the row key; the returned rect spans the row's cells and
## its bottom edge is the line the plank goes under.
func _row_rects() -> Array:
	var rows: Array = []
	if _grid == null:
		return rows
	var offset := _grid_offset()
	var by_top := {}
	var order: Array = []
	for child in _grid.get_children():
		var cell := child as Control
		if cell == null or not cell.visible or cell.size.y <= 0.0:
			continue
		var rect := Rect2(cell.position + offset, cell.size)
		var key := roundi(rect.position.y)
		if by_top.has(key):
			by_top[key] = (by_top[key] as Rect2).merge(rect)
		else:
			by_top[key] = rect
			order.append(key)
	order.sort()
	for key: int in order:
		rows.append(by_top[key])
	return rows


## Grid-space -> this node's space. Normally zero (the shared [MarginContainer]
## hands both children the same rect), but measured rather than assumed so a
## shrink-centred grid still gets its planks in the right place.
func _grid_offset() -> Vector2:
	if _grid == null or not is_inside_tree() or not _grid.is_inside_tree():
		return Vector2.ZERO
	return _grid.global_position - global_position


static func _ellipse(box: Rect2, points: int = 22) -> PackedVector2Array:
	var center := box.get_center()
	var radius := box.size * 0.5
	var polygon := PackedVector2Array()
	for i in points:
		var angle := TAU * float(i) / float(points)
		polygon.append(center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y))
	return polygon

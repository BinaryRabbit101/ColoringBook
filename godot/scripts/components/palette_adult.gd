class_name PaletteAdult
extends Control
## Adult-mode palette: a swatch grid grouped into shade families plus a
## brush-size selector (DESIGN.md 1, coloring-mechanics "Palettes by mode").
##
## Implements the same contract as [PaletteChild] -- see that class's docs for
## the full list; the coloring screen can swap the two without knowing which it
## holds. Differences: many more colours, laid out one column per shade family
## (light at the top, dark at the bottom, driven by
## [member PaletteDef.shades_per_family]), and a working brush-size row whose
## dots are drawn at diameters proportional to the sizes they select.
##
## [method set_palette] auto-selects the palette's default brush size and the
## first colour, emitting [signal brush_size_picked] then [signal color_picked]
## once each.

## The player picked a colour. Also emitted once by [method set_palette].
signal color_picked(color: Color)
## The player picked a brush DIAMETER in page pixels. Also emitted once by
## [method set_palette].
signal brush_size_picked(size: float)

## Global touch target floor (DESIGN.md 3.5).
const MIN_TOUCH_TARGET := SwatchButton.MIN_TOUCH_TARGET

var _palette: PaletteDef
var _swatches: Array[SwatchButton] = []
var _dots: Array[BrushSizeDot] = []
var _selected_index := -1
var _selected_size_index := -1
var _selected_size := 0.0

var _grid: HBoxContainer
var _size_row: HBoxContainer


func _ready() -> void:
	_resolve_nodes()


func _resolve_nodes() -> void:
	if _grid == null:
		_grid = get_node("Margin/Body/Scroll/SwatchGrid") as HBoxContainer
	if _size_row == null:
		_size_row = get_node("Margin/Body/SizeRow") as HBoxContainer


# ================================================== shared palette contract ==

func set_palette(def: PaletteDef) -> void:
	_resolve_nodes()
	_palette = def
	_selected_index = -1
	_selected_size_index = -1
	_clear()
	if def == null:
		return

	_build_grid(def)
	_build_size_row(def)

	select_brush_size(def.get_default_brush_size_index())
	select_color(0)


## Selects colour [param index] (clamped) and emits [signal color_picked].
## A swatch press calls exactly this.
func select_color(index: int) -> void:
	if _palette == null or _swatches.is_empty():
		return
	var clamped := clampi(index, 0, _swatches.size() - 1)
	_selected_index = clamped
	for swatch in _swatches:
		swatch.selected = swatch.color_index == clamped
	color_picked.emit(_palette.get_color(clamped))


## Selects brush size [param index] (clamped) and emits [signal brush_size_picked].
## A size-dot press calls exactly this.
func select_brush_size(index: int) -> void:
	if _palette == null:
		return
	var count := maxi(_palette.brush_size_count(), 1)
	_selected_size_index = clampi(index, 0, count - 1)
	_selected_size = _palette.get_brush_size(_selected_size_index)
	for dot in _dots:
		dot.selected = dot.size_index == _selected_size_index
	brush_size_picked.emit(_selected_size)


func get_palette() -> PaletteDef:
	return _palette


func get_selected_color_index() -> int:
	return _selected_index


func get_selected_color() -> Color:
	if _palette == null or _selected_index < 0:
		return Color.MAGENTA
	return _palette.get_color(_selected_index)


func get_selected_brush_size_index() -> int:
	return _selected_size_index


func get_selected_brush_size() -> float:
	return _selected_size


## Every swatch, in palette order (families laid out consecutively).
func get_color_buttons() -> Array[Control]:
	var buttons: Array[Control] = []
	for swatch in _swatches:
		buttons.append(swatch)
	return buttons


## The brush-size dots, smallest first.
func get_brush_size_buttons() -> Array[Control]:
	var buttons: Array[Control] = []
	for dot in _dots:
		buttons.append(dot)
	return buttons


## Number of shade-family columns currently drawn.
func get_family_column_count() -> int:
	return _grid.get_child_count() if _grid != null else 0


# =================================================================== internal ==

func _build_grid(def: PaletteDef) -> void:
	var per_family := def.effective_shades_per_family()
	var families := def.family_count()
	var index := 0
	for family in families:
		var column := VBoxContainer.new()
		column.name = "Family%d" % family
		column.add_theme_constant_override("separation", 4)
		_grid.add_child(column)
		for shade in per_family:
			if index >= def.color_count():
				break
			var swatch := SwatchButton.new()
			swatch.name = "Swatch%d" % index
			swatch.color_index = index
			swatch.swatch_color = def.get_color(index)
			swatch.tooltip_text = "#" + def.get_color(index).to_html(false)
			swatch.pressed.connect(_on_swatch_pressed.bind(index))
			column.add_child(swatch)
			_swatches.append(swatch)
			index += 1


func _build_size_row(def: PaletteDef) -> void:
	var count := def.brush_size_count()
	if count <= 0:
		return
	var largest := def.get_brush_size(count - 1)
	var smallest := def.get_brush_size(0)
	for i in count:
		var dot := BrushSizeDot.new()
		dot.name = "Size%d" % i
		dot.size_index = i
		dot.brush_size = def.get_brush_size(i)
		# Ratio across the palette's own range, so three close sizes still read
		# as three visibly different dots.
		dot.size_ratio = (
			0.0 if largest <= smallest
			else (def.get_brush_size(i) - smallest) / (largest - smallest)
		)
		dot.tooltip_text = "%d px brush" % int(round(def.get_brush_size(i)))
		dot.pressed.connect(_on_dot_pressed.bind(i))
		_size_row.add_child(dot)
		_dots.append(dot)


func _on_swatch_pressed(index: int) -> void:
	select_color(index)


func _on_dot_pressed(index: int) -> void:
	select_brush_size(index)


func _clear() -> void:
	_swatches.clear()
	_dots.clear()
	for container in [_grid, _size_row]:
		if container == null:
			continue
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()

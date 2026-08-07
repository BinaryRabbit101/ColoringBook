class_name PaletteAdult
extends Control
## Adult-mode palette: a swatch grid grouped into shade families plus a
## brush-size selector (DESIGN.md 1, coloring-mechanics "Palettes by mode").
##
## Implements the same contract as [PaletteChild] -- see that class's docs for
## the full list; the coloring screen can swap the two without knowing which it
## holds. Differences: many more colours, laid out one column per shade family
## (light at the top, dark at the bottom, driven by
## [member PaletteDef.shades_per_family]), and a working brush-size control.
##
## [method set_palette] auto-selects the palette's default brush size and the
## first colour, emitting [signal brush_size_picked] then [signal color_picked]
## once each.
##
## [b]Slide-to-select[/b] (BACKLOG BL-2): a swatch is picked as the finger lands
## on it and the selection then follows the finger across the grid, via the
## [PaletteSlideInput] both palettes share.
##
## [b]Brush size[/b] (BACKLOG BL-3): one [BrushSizeSlider] whose stops are the
## palette's authored diameters, replacing the row of dot buttons. It reports an
## index, which goes through [method select_brush_size] like every other pick, so
## nothing downstream changed. BL-14 widened the shipped range to five stops
## (8..96 px) without touching a line of that chain.
##
## [b]Pick preview[/b] (BACKLOG BL-15): one [PickPreview] bubble serves both halves
## of this palette -- the swatch grid feeds it through [PaletteSlideInput]'s
## candidate hook, the slider through its own [signal BrushSizeSlider.preview_changed],
## and it shows a colour chip or a candidate-diameter dot accordingly.

## The player picked a colour. Also emitted once by [method set_palette].
signal color_picked(color: Color)
## The player picked a brush DIAMETER in page pixels. Also emitted once by
## [method set_palette].
signal brush_size_picked(size: float)

## Global touch target floor (DESIGN.md 3.5).
const MIN_TOUCH_TARGET := SwatchButton.MIN_TOUCH_TARGET

var _palette: PaletteDef
var _swatches: Array[SwatchButton] = []
var _slider: BrushSizeSlider
var _selected_index := -1
var _selected_size_index := -1
var _selected_size := 0.0

var _grid: HBoxContainer
var _scroll: ScrollContainer
var _size_row: HBoxContainer
## Drag half of slide-to-select; the swatches themselves make the first pick.
var _slide := PaletteSlideInput.new()
## BL-15's floating candidate bubble, shared by the grid and the slider.
var _preview: PickPreview


func _ready() -> void:
	_resolve_nodes()


func _resolve_nodes() -> void:
	if _scroll == null:
		_scroll = get_node("Margin/Body/Scroll") as ScrollContainer
	if _grid == null:
		_grid = get_node("Margin/Body/Scroll/SwatchGrid") as HBoxContainer
	if _size_row == null:
		_size_row = get_node("Margin/Body/SizeRow") as HBoxContainer
	if _preview == null:
		# Parented to the palette ROOT, not the scroller or the size row: the bubble
		# floats clear of both, and the root is a plain Control so nothing lays it
		# out. `_clear()` only empties those two containers, so it survives rebuilds.
		_preview = PickPreview.new()
		_preview.name = "PickPreview"
		add_child(_preview)
	# The swatch scroller only: a gesture that starts on the brush-size slider
	# belongs to the slider.
	_slide.configure(self, _scroll)
	_slide.set_candidate_hook(_on_slide_candidate, _on_slide_released)


## Slide-to-select runs BEFORE the GUI phase, like [PageView]'s painting, so one
## touch code path serves mouse and finger alike. Claimed drags are marked handled
## so the swatch grid cannot drag-scroll under the finger mid-slide.
func _input(event: InputEvent) -> void:
	if _slide.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	# BL-16's dismiss audit -- see [PaletteChild._input] for the reasoning. This
	# palette has a second way to strand a bubble: [BrushSizeSlider] hears its
	# release through [method Control._gui_input], which only arrives if the pointer
	# is still over the bar. A finger that slid off the end and lifted there was
	# never told to stop, so it also kept [member BrushSizeSlider._dragging] true.
	# Ending the slider's preview from here fixes both, and is idempotent.
	if _slide.is_release_event(event):
		if is_instance_valid(_slider):
			_slider.end_preview()
		_on_slide_released()


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
## Moving the slider calls exactly this.
func select_brush_size(index: int) -> void:
	if _palette == null:
		return
	var count := maxi(_palette.brush_size_count(), 1)
	_selected_size_index = clampi(index, 0, count - 1)
	_selected_size = _palette.get_brush_size(_selected_size_index)
	if is_instance_valid(_slider):
		_slider.set_selected_index(_selected_size_index)
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


## The brush-size control, as a one-entry list (the shared contract is a list
## because child mode has none). See [method get_brush_size_slider].
func get_brush_size_controls() -> Array[Control]:
	var controls: Array[Control] = []
	if is_instance_valid(_slider):
		controls.append(_slider)
	return controls


## The brush-size slider itself, or null before [method set_palette]. Adult-only.
func get_brush_size_slider() -> BrushSizeSlider:
	return _slider


## The floating pick-preview bubble (BL-15). Never null after [method _ready].
func get_pick_preview() -> PickPreview:
	_resolve_nodes()
	return _preview


# ================================================================ pick preview ==

## The finger is over swatch [param index] ([code]-1[/code] between swatches).
func _on_slide_candidate(index: int, viewport_position: Vector2) -> void:
	if _preview == null or _palette == null:
		return
	if index < 0:
		_preview.move_to(viewport_position)
		return
	_preview.show_color(_palette.get_color(index), viewport_position)


func _on_slide_released() -> void:
	if _preview != null:
		_preview.dismiss()


## The finger is over brush-size stop [param index]. The bubble shows the CANDIDATE
## diameter as a dot in the colour that is actually loaded, so the preview answers
## "how big a mark will this make" rather than showing an abstract circle.
func _on_slider_preview(index: int, viewport_position: Vector2) -> void:
	if _preview == null or _palette == null:
		return
	_preview.show_brush(
		get_selected_color(),
		_palette.get_brush_size(index),
		_palette.get_brush_size(_palette.brush_size_count() - 1),
		viewport_position
	)


func _on_slider_preview_ended() -> void:
	if _preview != null:
		_preview.dismiss()


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
			# Slide-to-select: the pick happens as the finger LANDS, not when it
			# lifts, so the selection can then follow it (see PaletteSlideInput).
			swatch.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
			swatch.pressed.connect(_on_swatch_pressed.bind(index))
			column.add_child(swatch)
			_swatches.append(swatch)
			index += 1

	_slide.set_targets(get_color_buttons(), select_color)


func _build_size_row(def: PaletteDef) -> void:
	if def.brush_size_count() <= 0:
		return
	_slider = BrushSizeSlider.new()
	_slider.name = "SizeSlider"
	_slider.set_sizes(def.brush_sizes)
	_slider.tooltip_text = "Brush size: %d-%d px" % [
		int(round(def.get_brush_size(0))),
		int(round(def.get_brush_size(def.brush_size_count() - 1))),
	]
	_slider.size_selected.connect(select_brush_size)
	# BL-15: the slider is outside the slide helper's hit area, so it reports its
	# own candidate -- into the same one bubble.
	_slider.preview_changed.connect(_on_slider_preview)
	_slider.preview_ended.connect(_on_slider_preview_ended)
	_size_row.add_child(_slider)


func _on_swatch_pressed(index: int) -> void:
	select_color(index)


func _clear() -> void:
	_swatches.clear()
	_slider = null
	if _preview != null:
		_preview.hide_now()
	var no_targets: Array[Control] = []
	_slide.set_targets(no_targets, Callable())
	for container in [_grid, _size_row]:
		if container == null:
			continue
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()

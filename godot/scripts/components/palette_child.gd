class_name PaletteChild
extends Control
## Child-mode palette: a chunky row of crayons (DESIGN.md 1, coloring-mechanics
## "Palettes by mode").
##
## [b]Shared palette contract[/b] -- [PaletteChild] and [PaletteAdult] expose
## exactly this, so the coloring screen instantiates whichever
## [code]GameState.get_palette_scene_path()[/code] names and wires it blindly:
## [codeblock]
## signal color_picked(color: Color)
## signal brush_size_picked(size: float)
## func set_palette(def: PaletteDef) -> void
## func select_color(index: int) -> void
## func select_brush_size(index: int) -> void
## func get_palette() -> PaletteDef
## func get_selected_color_index() -> int
## func get_selected_color() -> Color
## func get_selected_brush_size_index() -> int
## func get_selected_brush_size() -> float
## func get_color_buttons() -> Array[Control]
## func get_brush_size_controls() -> Array[Control]
## func get_pick_preview() -> PickPreview
## [/codeblock]
## [method set_palette] auto-selects the first colour and the palette's default
## brush size, emitting [signal brush_size_picked] then [signal color_picked]
## once each -- the brush is never colourless or sizeless.
##
## Child mode offers a single forgiving brush, so this component has no size
## control and [method get_brush_size_controls] is empty; it still declares and
## emits [signal brush_size_picked] so both palettes are interchangeable.
##
## [b]Slide-to-select[/b] (BACKLOG BL-2): a crayon is picked the moment the finger
## lands on it ([constant BaseButton.ACTION_MODE_BUTTON_PRESS]) and the selection
## then FOLLOWS the finger across the row until it lifts. The drag half lives in
## [PaletteSlideInput], which both palettes share; the press half stays with the
## buttons so hover, tooltips and [signal BaseButton.pressed] keep working.
##
## [b]Pick preview[/b] (BACKLOG BL-15): the finger covers the crayon it is picking,
## so the candidate is echoed in a [PickPreview] bubble floating above the touch
## point. The palette owns the bubble and feeds it from [PaletteSlideInput]'s
## candidate hook -- the same gesture tracking slide-to-select already does, not a
## second copy of it.
##
## Self-contained: it is handed a [PaletteDef] and reaches nothing outside its
## own subtree. Signals up, calls down.

## The player picked a colour. Also emitted once by [method set_palette].
signal color_picked(color: Color)
## The brush diameter (page px) changed. Emitted once by [method set_palette].
signal brush_size_picked(size: float)

## Child-mode touch target floor (DESIGN.md 1: "large touch targets").
const MIN_TOUCH_TARGET := CrayonButton.MIN_TOUCH_TARGET

var _palette: PaletteDef
var _crayons: Array[CrayonButton] = []
var _selected_index := -1
var _selected_size_index := -1
var _selected_size := 0.0

var _row: HBoxContainer
var _scroll: ScrollContainer
## Drag half of slide-to-select; the crayons themselves make the first pick.
var _slide := PaletteSlideInput.new()
## BL-15's floating candidate bubble. Created here, never injected: the palette is
## self-contained and the smoke test drives it standalone.
var _preview: PickPreview


func _ready() -> void:
	_resolve_nodes()


func _resolve_nodes() -> void:
	if _scroll == null:
		_scroll = get_node("Margin/Scroll") as ScrollContainer
	if _row == null:
		_row = get_node("Margin/Scroll/CrayonRow") as HBoxContainer
	if _preview == null:
		# Parented to the palette ROOT, not the scroller: the bubble has to float
		# clear of both, and the root is a plain Control so nothing lays it out.
		_preview = PickPreview.new()
		_preview.name = "PickPreview"
		add_child(_preview)
	_slide.configure(self, _scroll)
	_slide.set_candidate_hook(_on_slide_candidate, _on_slide_released)


## Slide-to-select runs BEFORE the GUI phase, like [PageView]'s painting, so one
## touch code path serves mouse and finger alike. Claimed drags are marked handled
## so the crayon row cannot drag-scroll under the finger mid-slide.
func _input(event: InputEvent) -> void:
	if _slide.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	# BL-16's dismiss audit. [PaletteSlideInput] already fades the bubble when the
	# gesture it is tracking ends, but it only tracks gestures it CLAIMED: a press
	# that started on a crayon the helper refused (outside its hit area, another
	# control hovered) still raised the bubble through the button, and a release
	# whose index it never saw would leave it up. Any pointer release, from anywhere,
	# means no finger is choosing anything.
	if _slide.is_release_event(event):
		_on_slide_released()


# ================================================== shared palette contract ==

## Rebuilds the row from [param def], then auto-selects the default brush size
## and the first colour (emitting both signals once). Passing null empties the row.
func set_palette(def: PaletteDef) -> void:
	_resolve_nodes()
	_palette = def
	_selected_index = -1
	_selected_size_index = -1
	_clear_row()
	if def == null:
		return

	for i in def.color_count():
		var crayon := CrayonButton.new()
		crayon.name = "Crayon%d" % i
		crayon.color_index = i
		crayon.crayon_color = def.get_color(i)
		crayon.tooltip_text = "#" + def.get_color(i).to_html(false)
		# Slide-to-select: the pick happens as the finger LANDS, not when it lifts,
		# so the selection can then follow the finger (see PaletteSlideInput).
		crayon.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		crayon.pressed.connect(_on_crayon_pressed.bind(i))
		_row.add_child(crayon)
		_crayons.append(crayon)

	_slide.set_targets(get_color_buttons(), select_color)

	select_brush_size(def.get_default_brush_size_index())
	select_color(0)


## Selects colour [param index] (clamped) and emits [signal color_picked].
## This is exactly what a crayon press calls -- tests drive the same entry point.
func select_color(index: int) -> void:
	if _palette == null or _crayons.is_empty():
		return
	var clamped := clampi(index, 0, _crayons.size() - 1)
	_selected_index = clamped
	for crayon in _crayons:
		crayon.selected = crayon.color_index == clamped
	color_picked.emit(_palette.get_color(clamped))


## Selects brush size [param index] (clamped) and emits [signal brush_size_picked].
## Child mode has one size, so this normally fires only from [method set_palette].
func select_brush_size(index: int) -> void:
	if _palette == null:
		return
	var count := maxi(_palette.brush_size_count(), 1)
	_selected_size_index = clampi(index, 0, count - 1)
	_selected_size = _palette.get_brush_size(_selected_size_index)
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


## The crayon controls, in palette order. For layout/touch-target verification.
func get_color_buttons() -> Array[Control]:
	var buttons: Array[Control] = []
	for crayon in _crayons:
		buttons.append(crayon)
	return buttons


## Always empty: child mode exposes no size control (see the class docs).
func get_brush_size_controls() -> Array[Control]:
	return []


## The floating pick-preview bubble (BL-15). Never null after [method _ready].
func get_pick_preview() -> PickPreview:
	_resolve_nodes()
	return _preview


# ================================================================ pick preview ==

## The finger is over crayon [param index] ([code]-1[/code] between crayons, where
## the last candidate stands). Presentational only -- the pick itself is
## [method select_color], called by the button and by [PaletteSlideInput].
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


# =================================================================== internal ==

func _on_crayon_pressed(index: int) -> void:
	select_color(index)


func _clear_row() -> void:
	_crayons.clear()
	if _preview != null:
		_preview.hide_now()
	var no_targets: Array[Control] = []
	_slide.set_targets(no_targets, Callable())
	if _row == null:
		return
	for child in _row.get_children():
		_row.remove_child(child)
		child.queue_free()

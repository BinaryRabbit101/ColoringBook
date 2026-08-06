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
## func get_brush_size_buttons() -> Array[Control]
## [/codeblock]
## [method set_palette] auto-selects the first colour and the palette's default
## brush size, emitting [signal brush_size_picked] then [signal color_picked]
## once each -- the brush is never colourless or sizeless.
##
## Child mode offers a single forgiving brush, so this component has no size
## control and [method get_brush_size_buttons] is empty; it still declares and
## emits [signal brush_size_picked] so both palettes are interchangeable.
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


func _ready() -> void:
	_resolve_nodes()


func _resolve_nodes() -> void:
	if _row == null:
		_row = get_node("Margin/Scroll/CrayonRow") as HBoxContainer


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
		crayon.pressed.connect(_on_crayon_pressed.bind(i))
		_row.add_child(crayon)
		_crayons.append(crayon)

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
func get_brush_size_buttons() -> Array[Control]:
	return []


# =================================================================== internal ==

func _on_crayon_pressed(index: int) -> void:
	select_color(index)


func _clear_row() -> void:
	_crayons.clear()
	if _row == null:
		return
	for child in _row.get_children():
		_row.remove_child(child)
		child.queue_free()

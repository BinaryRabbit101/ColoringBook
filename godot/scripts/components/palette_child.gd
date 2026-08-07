class_name PaletteChild
extends Control
## [b]The[/b] palette: a chunky row of crayons (DESIGN.md 1, coloring-mechanics
## "The palette").
##
## [b]BL-20 made this the only one.[/b] The Child/Adult split, the swatch grid and
## the brush-size slider are gone; what survives is the crayon row, its single
## forgiving brush and the generous 0.90 completion threshold. The class keeps its
## [code]PaletteChild[/code] name and its scene path because DESIGN.md 3.4 still
## names them and renaming would churn every reference for nothing.
##
## [b]Palette contract[/b] -- what the coloring screen wires, blindly, to whatever
## [code]GameState.get_palette_scene_path()[/code] names:
## [codeblock]
## signal color_picked(color: Color)
## signal brush_size_picked(size: float)
## signal brush_effect_picked(effect: StringName)
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
##
## [b]Three things grew on the strip after BL-20[/b], and none of them changed
## that contract -- [signal color_picked] still carries one resolved [Color] and
## the paint path never learns any of it happened:
##
## [b]BL-21 layout[/b]: the same scene docks as a bottom ROW or a side COLUMN.
## See [method set_layout]; the parent decides, from its aspect ratio.
##
## [b]BL-22 intensity[/b]: an [IntensityButton] swaps the strip between the crayon
## colours and the light-to-dark ladder of the crayon in hand. See
## [method set_view] / [method select_intensity].
##
## [b]BL-23 crayon sets[/b]: a [CrayonBoxButton] cycles the strip through the
## default box and every authored [CrayonSetDef]. See [method set_crayon_set].
##
## [b]BL-35 finishes[/b]: every box carries the SAME crayons and differs in how its
## paint looks -- classic wax, neon glow, textured wax, glitter, each louder than
## the last. That is one new thing the paint path has to learn, and it learns it
## through its OWN explicit signal, [signal brush_effect_picked], never by reaching
## into the palette: [signal color_picked] still carries exactly one resolved
## [Color] and nothing else travels through it. [method set_palette] primes the
## finish the way it primes the size and the colour, so the brush is never
## finish-less, and cycling a box emits it exactly once beside the colour.
##
## The pick is therefore always "crayon C of box B at rung R", resolved in
## [method get_selected_color] and nowhere else.
## [method set_palette] auto-selects the first colour and the palette's default
## brush size, emitting [signal brush_size_picked] then [signal color_picked]
## once each -- the brush is never colourless or sizeless.
##
## The crayon row offers a single forgiving brush, so this component has no size
## control and [method get_brush_size_controls] is empty; it still declares and
## emits [signal brush_size_picked], because that is what primes
## [code]PageView.brush_size[/code] and the coloring screen has no other source.
##
## [b]Slide-to-select[/b] (BACKLOG BL-2): a crayon is picked the moment the finger
## lands on it ([constant BaseButton.ACTION_MODE_BUTTON_PRESS]) and the selection
## then FOLLOWS the finger across the row until it lifts. The drag half lives in
## [PaletteSlideInput]; the press half stays with the buttons so hover, tooltips
## and [signal BaseButton.pressed] keep working.
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
## The FINISH the strip's crayons paint with changed (BL-35) -- a [BrushFinish] id.
## Emitted once by [method set_palette] and once by every box change, and by nothing
## else: within a box, picking a crayon or a rung changes the colour, not the wax.
signal brush_effect_picked(effect: StringName)

## Crayon-row touch target floor (DESIGN.md 1: "large touch targets").
const MIN_TOUCH_TARGET := CrayonButton.MIN_TOUCH_TARGET

## The crayons run left to right along the BOTTOM of the canvas (portrait).
const LAYOUT_ROW := 0
## The crayons run top to bottom down the SIDE of the canvas (BL-21, landscape).
const LAYOUT_COLUMN := 1

## Thickness of the palette strip across its short axis: the height of the
## portrait row, the width of the landscape column. One number for both, so the
## palette takes the same bite out of the screen whichever way it is docked.
const STRIP_THICKNESS := 212.0

var _palette: PaletteDef
var _crayons: Array[CrayonButton] = []
var _selected_index := -1
var _selected_size_index := -1
var _selected_size := 0.0
var _layout := LAYOUT_ROW
## Which box of crayons is out (BL-23). 0 is the palette's own default box.
var _set_index := 0
## Which face the strip is showing: colours, or the intensity ladder (BL-22).
var _view := VIEW_COLORS
## The rung of the ladder in hand. Reset to the crayon's own colour by every
## colour pick.
var _intensity_step := PaletteDef.INTENSITY_BASE_STEP

var _body: BoxContainer
var _controls: BoxContainer
var _row: BoxContainer
var _scroll: ScrollContainer
## The light-to-dark swap (BL-22) and the crayon-box cycle (BL-23). Built here,
## like the pick bubble, so the palette stays one self-contained scene plus its
## own code.
var _intensity: IntensityButton
var _box: CrayonBoxButton
## Drag half of slide-to-select; the crayons themselves make the first pick.
var _slide := PaletteSlideInput.new()
## BL-15's floating candidate bubble. Created here, never injected: the palette is
## self-contained and the smoke test drives it standalone.
var _preview: PickPreview


func _ready() -> void:
	_resolve_nodes()
	_apply_layout()


func _resolve_nodes() -> void:
	if _body == null:
		_body = get_node("Margin/Body") as BoxContainer
	if _controls == null:
		_controls = get_node("Margin/Body/Controls") as BoxContainer
	if _scroll == null:
		_scroll = get_node("Margin/Body/Scroll") as ScrollContainer
	if _row == null:
		_row = get_node("Margin/Body/Scroll/CrayonRow") as BoxContainer
	if _box == null:
		# First on the strip, because "which crayons" is the bigger question and the
		# ladder is a detail of whichever answer is showing.
		_box = CrayonBoxButton.new()
		_box.name = "CrayonBoxButton"
		_box.pressed.connect(next_crayon_set)
		_controls.add_child(_box)
	if _intensity == null:
		_intensity = IntensityButton.new()
		_intensity.name = "IntensityButton"
		_intensity.pressed.connect(_on_intensity_pressed)
		_controls.add_child(_intensity)
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


# ======================================================== layout (BL-21) ==
# Portrait keeps the crayons in a strip along the bottom of the canvas, which
# reads well and is unchanged. Landscape docks them as a COLUMN beside the canvas
# instead, because the bottom strip eats the height a landscape screen has least
# of. It is the SAME scene either way -- one BoxContainer's direction, one
# ScrollContainer's axis, the crayons' own orientation and the pick bubble's
# placement -- and the parent decides which, from its ASPECT RATIO (never its
# width: DESIGN.md 3.5, a portrait window's logical canvas never gets narrow).

## Docks the crayons as a row or a column. Called by the parent when its aspect
## flips; the palette never measures the screen itself.
func set_layout(layout: int) -> void:
	var resolved := LAYOUT_COLUMN if layout == LAYOUT_COLUMN else LAYOUT_ROW
	if _layout == resolved and _body != null:
		return
	_layout = resolved
	_apply_layout()


func get_layout() -> int:
	return _layout


func is_column() -> bool:
	return _layout == LAYOUT_COLUMN


## The scroller the crayons live in. Exposed so a test can ask which way the strip
## scrolls without knowing the scene's node paths.
func get_scroll() -> ScrollContainer:
	_resolve_nodes()
	return _scroll


func _apply_layout() -> void:
	_resolve_nodes()
	var column := is_column()
	# The strip is thick across its short axis and takes whatever it is given
	# along its long one; the page view beside it is what expands.
	custom_minimum_size = (
		Vector2(STRIP_THICKNESS, 0.0) if column else Vector2(0.0, STRIP_THICKNESS)
	)
	size_flags_horizontal = Control.SIZE_FILL if column else Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL if column else Control.SIZE_FILL

	_body.vertical = column
	_row.vertical = column
	# The tool buttons run ACROSS the strip, perpendicular to the crayons, so they
	# cost the strip its short axis and never eat crayon room along its long one.
	_controls.vertical = not column
	# The strip scrolls ALONG its long axis and clips across the short one -- which
	# is the constraint CrayonButton's lift headroom is sized against, in both
	# orientations.
	_scroll.horizontal_scroll_mode = (
		ScrollContainer.SCROLL_MODE_DISABLED if column else ScrollContainer.SCROLL_MODE_AUTO
	)
	_scroll.vertical_scroll_mode = (
		ScrollContainer.SCROLL_MODE_AUTO if column else ScrollContainer.SCROLL_MODE_DISABLED
	)

	var orientation := CrayonButton.ORIENT_LEFT if column else CrayonButton.ORIENT_UP
	for crayon in _crayons:
		crayon.orientation = orientation

	if _preview != null:
		# The hand comes in from the side the crayons are docked on, so the bubble
		# goes the other way: above the finger for the bottom row, left of it for
		# the right-hand column.
		_preview.set_placement(
			PickPreview.PLACE_LEFT if column else PickPreview.PLACE_ABOVE
		)


# ===================================================== intensity (BL-22) ==
# The strip has two faces. Normally it shows the crayon COLOURS; tapping the
# [IntensityButton] swaps it for the intensity LADDER of whichever colour is in
# hand -- [constant PaletteDef.INTENSITY_STEPS] rungs from a pale tint to a deep
# shade, all of them COMPUTED from the base colour (PaletteDef.shade_of), never
# authored. Tapping again swaps back.
#
# Nothing downstream knows any of this happened. The active pick is always "base
# colour at rung N", it is resolved here, and [signal color_picked] carries the
# resolved colour exactly as it always did -- so the paint path, the shader and
# the stroke lifecycle are untouched (coloring-mechanics: the palette feeds
# color_picked and nothing more).

## The strip is showing the crayon colours.
const VIEW_COLORS := 0
## The strip is showing the intensity ladder of the colour in hand (BL-22).
const VIEW_SHADES := 1


## Swaps the strip between colours and shades. Idempotent.
func set_view(view: int) -> void:
	var resolved := VIEW_SHADES if view == VIEW_SHADES else VIEW_COLORS
	if _view == resolved:
		return
	_view = resolved
	_rebuild_strip()
	# Swapping the VIEW never changes the paint colour -- the same rung of the same
	# crayon is still in hand. Only a pick does.
	_refresh_tools()


func get_view() -> int:
	return _view


func is_showing_shades() -> bool:
	return _view == VIEW_SHADES


## Which rung of the ladder is painting, 0..[constant PaletteDef.INTENSITY_STEPS]-1.
func get_selected_intensity() -> int:
	return _intensity_step


## Picks rung [param step] of the current crayon's ladder and emits
## [signal color_picked] with the RESOLVED colour. This is what a press on a shade
## crayon calls.
func select_intensity(step: int) -> void:
	if _palette == null:
		return
	_intensity_step = clampi(step, 0, PaletteDef.INTENSITY_STEPS - 1)
	if is_showing_shades():
		for crayon in _crayons:
			crayon.selected = crayon.color_index == _intensity_step
	_refresh_tools()
	color_picked.emit(get_selected_color())


## The swap control (BL-22). Never null after [method _resolve_nodes].
func get_intensity_button() -> IntensityButton:
	_resolve_nodes()
	return _intensity


func _on_intensity_pressed() -> void:
	set_view(VIEW_COLORS if is_showing_shades() else VIEW_SHADES)


func _refresh_tools() -> void:
	if _intensity != null:
		_intensity.set_palette(_palette)
		_intensity.base_color = get_base_color()
		_intensity.active_step = _intensity_step
		_intensity.showing_shades = is_showing_shades()
	if _box != null:
		_box.set_colors = _active_colors()
		_box.set_index = _set_index
		_box.set_count = _palette.crayon_set_count() if _palette != null else 1
		_box.visible = _box.set_count > 1
		_box.tooltip_text = (
			"Crayons: %s" % _palette.get_crayon_set_name(_set_index) if _palette != null else ""
		)


# ======================================================= crayon sets (BL-23) ==
# Mario-Paint-style fun: the default box plus every authored [CrayonSetDef] on
# disk, cycled with the [CrayonBoxButton]. A set is COLOURS AND NOTHING ELSE --
# the brush, the hardness and the completion threshold stay on the [PaletteDef]
# -- so swapping boxes swaps the strip and touches nothing about how the game
# plays. The intensity ladder comes along for free, because BL-22 computes it from
# whatever base colour is in hand.

## Puts box [param index] on the strip (wrapping), back on its first crayon, and
## emits [signal brush_effect_picked] then [signal color_picked] for it.
##
## The finish goes out FIRST and the colour second, in the same order
## [method set_palette] primes them, so a listener that reacts to the colour is
## already holding the right wax when it does.
func set_crayon_set(index: int) -> void:
	if _palette == null:
		return
	var wrapped := _palette.wrap_crayon_set(index)
	_set_index = wrapped
	# A new box is a fresh start: first crayon, own colour, colours face. Leaving a
	# child on rung 6 of a colour that no longer exists is the alternative. BL-35:
	# the FINISH resets with it -- the finish belongs to the box, not to the hand.
	_selected_index = 0
	_intensity_step = PaletteDef.INTENSITY_BASE_STEP
	_view = VIEW_COLORS
	_rebuild_strip()
	brush_effect_picked.emit(get_selected_effect())
	color_picked.emit(get_selected_color())


## The next box in the cycle. What the crayon-box control calls.
func next_crayon_set() -> void:
	set_crayon_set(_set_index + 1)


func get_crayon_set_index() -> int:
	return _set_index


## Display name of the box on the strip -- the palette's own for the default box.
func get_crayon_set_name() -> String:
	return _palette.get_crayon_set_name(_set_index) if _palette != null else ""


## [b]The finish that will actually be painted[/b] (BL-35): the box in hand's, and
## the only thing [signal brush_effect_picked] ever carries. Classic wax whenever
## there is no palette to ask, so the brush is never finish-less.
func get_selected_effect() -> StringName:
	if _palette == null:
		return BrushFinish.CLASSIC
	return _palette.get_crayon_set_effect(_set_index)


## The crayon-box cycle control (BL-23). Never null after [method _resolve_nodes];
## hidden when there is only the default box to offer.
func get_crayon_box_button() -> CrayonBoxButton:
	_resolve_nodes()
	return _box


# ================================================== shared palette contract ==

## Rebuilds the strip from [param def], then auto-selects the default brush size
## and the first colour (emitting both signals once). Passing null empties it.
func set_palette(def: PaletteDef) -> void:
	_resolve_nodes()
	_palette = def
	_selected_index = -1
	_selected_size_index = -1
	_intensity_step = PaletteDef.INTENSITY_BASE_STEP
	_set_index = 0
	_view = VIEW_COLORS
	_clear_row()
	if def == null:
		_refresh_tools()
		return

	_selected_index = 0
	_rebuild_strip()
	select_brush_size(def.get_default_brush_size_index())
	# BL-35: prime the finish exactly the way the size is primed, and before the
	# colour, so the first stroke of the visit can never be painted with wax nobody
	# chose. The default box is classic, so this is a no-op for the brush -- but the
	# brush is now told so, rather than left to assume it.
	brush_effect_picked.emit(get_selected_effect())
	select_color(0)


## Builds the crayon controls for whichever face the strip is showing. One place,
## because the two faces differ only in what colours the crayons carry and what
## a press on one means.
func _rebuild_strip() -> void:
	_resolve_nodes()
	_clear_row()
	if _palette == null:
		return

	var shades := is_showing_shades()
	var colors := (
		_palette.shades_of(get_base_color()) if shades else _active_colors()
	)
	var selected := _intensity_step if shades else _selected_index
	# BL-35: every crayon on the strip wears the box's finish, the ladder's rungs
	# included -- a rung is the same wax at a different intensity.
	var finish := get_selected_effect()
	for i in colors.size():
		var crayon := CrayonButton.new()
		crayon.name = ("Shade%d" if shades else "Crayon%d") % i
		crayon.color_index = i
		crayon.finish = finish
		crayon.orientation = (
			CrayonButton.ORIENT_LEFT if is_column() else CrayonButton.ORIENT_UP
		)
		crayon.crayon_color = colors[i]
		crayon.tooltip_text = "#" + colors[i].to_html(false)
		crayon.selected = i == selected
		# Slide-to-select: the pick happens as the finger LANDS, not when it lifts,
		# so the selection can then follow the finger (see PaletteSlideInput).
		crayon.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		crayon.pressed.connect(_pick_at.bind(i))
		_row.add_child(crayon)
		_crayons.append(crayon)

	_slide.set_targets(get_color_buttons(), _pick_at)
	_refresh_tools()


## What a press or a slide onto strip position [param index] means, which depends
## on which face is up. One callback, so [PaletteSlideInput] never has to know.
func _pick_at(index: int) -> void:
	if is_showing_shades():
		select_intensity(index)
	else:
		select_color(index)


## Selects crayon [param index] (clamped) and emits [signal color_picked].
## This is exactly what a crayon press calls -- tests drive the same entry point.
##
## [b]It resets the intensity[/b] (BL-22): a new crayon comes out of the box at
## its own colour, so a child who wandered up the ladder once is not stuck there
## for every colour after it.
func select_color(index: int) -> void:
	if _palette == null:
		return
	var count := _active_colors().size()
	if count <= 0:
		return
	var clamped := clampi(index, 0, count - 1)
	_selected_index = clamped
	_intensity_step = PaletteDef.INTENSITY_BASE_STEP
	if is_showing_shades():
		# Picked from outside the shade face (a test, or a restored selection):
		# the ladder it is showing is the wrong colour's now.
		_rebuild_strip()
	else:
		for crayon in _crayons:
			crayon.selected = crayon.color_index == clamped
	_refresh_tools()
	color_picked.emit(get_selected_color())


## Selects brush size [param index] (clamped) and emits [signal brush_size_picked].
## The crayon row has one size, so this normally fires only from [method set_palette].
func select_brush_size(index: int) -> void:
	if _palette == null:
		return
	var count := maxi(_palette.brush_size_count(), 1)
	_selected_size_index = clampi(index, 0, count - 1)
	_selected_size = _palette.get_brush_size(_selected_size_index)
	brush_size_picked.emit(_selected_size)


func get_palette() -> PaletteDef:
	return _palette


## Which CRAYON is in hand -- the base colour's index, whichever face the strip is
## showing. The rung is [method get_selected_intensity].
func get_selected_color_index() -> int:
	return _selected_index


## The crayon's own colour, before the intensity ladder is applied.
func get_base_color() -> Color:
	var colors := _active_colors()
	if colors.is_empty() or _selected_index < 0:
		return Color.MAGENTA
	return colors[clampi(_selected_index, 0, colors.size() - 1)]


## [b]The colour that will actually be painted[/b]: the crayon in hand, at the
## intensity rung in hand. This is what [signal color_picked] carries, and it is
## the only colour anything outside this component ever sees.
func get_selected_color() -> Color:
	if _palette == null or _selected_index < 0:
		return Color.MAGENTA
	return _palette.shade_of(get_base_color(), _intensity_step)


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


## Always empty: the crayon row exposes no size control (see the class docs).
func get_brush_size_controls() -> Array[Control]:
	return []


## The strip's tool tiles -- the crayon-box cycle and the intensity swap -- in the
## order they sit on it. For layout and touch-target verification; the crayons
## themselves are [method get_color_buttons].
func get_tool_buttons() -> Array[Control]:
	_resolve_nodes()
	var tools: Array[Control] = []
	for control in [_box, _intensity]:
		if control != null and control.visible:
			tools.append(control)
	return tools


## The floating pick-preview bubble (BL-15). Never null after [method _ready].
func get_pick_preview() -> PickPreview:
	_resolve_nodes()
	return _preview


# ================================================================ pick preview ==

## The finger is over strip position [param index] ([code]-1[/code] between
## crayons, where the last candidate stands). Presentational only -- the pick
## itself is [method _pick_at], called by the button and by [PaletteSlideInput].
##
## The bubble shows the colour that would actually be PAINTED, which on the shade
## face is the resolved rung and not the crayon's own colour (BL-22).
func _on_slide_candidate(index: int, viewport_position: Vector2) -> void:
	if _preview == null or _palette == null:
		return
	if index < 0:
		_preview.move_to(viewport_position)
		return
	_preview.show_color(_candidate_color(index), viewport_position)


## What picking strip position [param index] right now would put on the brush.
func _candidate_color(index: int) -> Color:
	if is_showing_shades():
		return _palette.shade_of(get_base_color(), index)
	var colors := _active_colors()
	if colors.is_empty():
		return Color.MAGENTA
	return colors[clampi(index, 0, colors.size() - 1)]


## The colours the strip's COLOUR face offers: whichever crayon box is out (BL-23).
func _active_colors() -> PackedColorArray:
	if _palette == null:
		return PackedColorArray()
	return _palette.get_crayon_set_colors(_set_index)


func _on_slide_released() -> void:
	if _preview != null:
		_preview.dismiss()


# =================================================================== internal ==

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

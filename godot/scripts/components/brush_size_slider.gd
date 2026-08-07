class_name BrushSizeSlider
extends Control
## The adult palette's brush-size control: one slide bar in place of the row of dot
## buttons it replaced (BACKLOG BL-3).
##
## [b]Stepped, not continuous[/b], because the sizes are AUTHORED data: the stops
## are exactly [member PaletteDef.brush_sizes] and the control reports an INDEX
## into that list, so the chain behind it (palette -> coloring screen ->
## [member PageView.brush_size]) keeps working in page-pixel DIAMETERS with no new
## units, no new data and no rounding.
##
## Drawn from primitives like [CrayonButton] and [SwatchButton] -- no art assets.
## The track is a wedge that grows from the smallest brush to the largest and the
## knob grows with the diameter it selects, so the control is its own legend the
## way the dots were.
##
## [b]The knob is a PROXY, not a ruler[/b] (BACKLOG BL-14). Its radius is
## interpolated across [constant MIN_KNOB_RADIUS] .. [constant MAX_KNOB_RADIUS] by
## where the stop sits in the palette's own range, so a 96 px brush draws a 20 px
## knob that fits the toolbar while [method get_selected_size] still reports 96.
## The visual cap is the only thing capped; nothing downstream ever sees it.
##
## Input is one path: [method Control._gui_input] with touch and mouse folded
## together and every pick funnelled through [method pick_at_local_x], which is
## also the entry point the palette smoke test drives. Picks are silent while the
## finger stays inside one stop, so a slow drag across the bar emits one signal per
## stop, not one per frame -- but [signal preview_changed] fires on every one of
## them, because the pick bubble has to follow the finger even when the stop has
## not moved (BACKLOG BL-15).

## The player moved the slider onto stop [param index]. Not emitted by
## [method set_selected_index], which is how the palette pushes state back down.
signal size_selected(index: int)
## The finger is over stop [param index] at [param viewport_position] (BL-15). Fires
## on every pick attempt, changed or not, so the palette's [PickPreview] can track
## the finger. Purely presentational -- nothing downstream listens.
signal preview_changed(index: int, viewport_position: Vector2)
## The finger left the bar; the preview should fade (BL-15).
signal preview_ended()

## Global minimum touch target (DESIGN.md 3.5).
const MIN_TOUCH_TARGET := 48.0
## Default box: wide enough to slide along, tall enough to hit with a thumb.
const DEFAULT_SIZE := Vector2(280.0, 56.0)
## Clearance at each end so the biggest knob -- ring, keyline and all -- cannot
## draw outside the control. Must stay >= [method max_knob_extent].
const SIDE_PADDING := 28.0
## Drawn knob radius for the smallest / largest offered size.
const MIN_KNOB_RADIUS := 8.0
const MAX_KNOB_RADIUS := 20.0
## How far past [constant MAX_KNOB_RADIUS] the selection ring and its stroke reach.
const KNOB_RING_OFFSET := 5.0
const KNOB_RING_WIDTH := 3.0
## Track thickness at the smallest / largest end of the wedge.
const MIN_TRACK_HEIGHT := 6.0
const MAX_TRACK_HEIGHT := 26.0

const TRACK_COLOR := Color(0.24, 0.25, 0.29)
const TRACK_FILLED_COLOR := Color(0.38, 0.41, 0.48)
const TICK_COLOR := Color(1.0, 1.0, 1.0, 0.30)
const KNOB_COLOR := Color(0.97, 0.96, 0.94)
const KNOB_RING_COLOR := Color(0.98, 0.78, 0.28)

## Brush DIAMETERS in page pixels, ascending -- the palette's own list.
var _sizes := PackedFloat32Array()
var _index := 0
var _dragging := false


func _init() -> void:
	custom_minimum_size = DEFAULT_SIZE
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	resized.connect(queue_redraw)


# ====================================================================== state ==

## Sets the stops from a [PaletteDef]'s brush sizes (diameters, ascending) and
## clamps the selection into the new range. Silent: no [signal size_selected].
func set_sizes(sizes: PackedFloat32Array) -> void:
	_sizes = sizes
	_index = clampi(_index, 0, maxi(_sizes.size() - 1, 0))
	queue_redraw()


func stop_count() -> int:
	return _sizes.size()


## Brush diameter at [param index], clamped. 0.0 when nothing is configured.
func get_size_at(index: int) -> float:
	if _sizes.is_empty():
		return 0.0
	return _sizes[clampi(index, 0, _sizes.size() - 1)]


func get_selected_index() -> int:
	return _index


func get_selected_size() -> float:
	return get_size_at(_index)


## Moves the knob without reporting it -- the palette calls this so its
## [code]select_brush_size()[/code] stays the single place a pick is announced.
func set_selected_index(index: int) -> void:
	var clamped := clampi(index, 0, maxi(_sizes.size() - 1, 0))
	if clamped == _index:
		return
	_index = clamped
	queue_redraw()


# ====================================================================== input ==

## Both pointer paths land here: touch and (emulated-to-touch) mouse produce the
## same events, and handling both kinds keeps the control correct whichever the
## engine delivers first. Every branch is idempotent because
## [method pick_at_local_x] ignores a pick that does not move the knob.
func _gui_input(event: InputEvent) -> void:
	if _sizes.is_empty():
		return
	if event is InputEventScreenTouch:
		_set_dragging(event.pressed)
		if event.pressed:
			pick_at_local_x(event.position.x)
		accept_event()
	elif event is InputEventScreenDrag:
		if _dragging:
			pick_at_local_x(event.position.x)
			accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_set_dragging(event.pressed)
		if event.pressed:
			pick_at_local_x(event.position.x)
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		pick_at_local_x(event.position.x)
		accept_event()


## Selects the stop nearest [param x] (the control's own coordinates) and emits
## [signal size_selected] if that moved the knob. The one entry point every pick
## goes through, real or simulated.
##
## [signal preview_changed] is emitted FIRST and unconditionally: the pick may be a
## no-op, but the finger still moved, and the bubble above it has to move with it.
func pick_at_local_x(x: float) -> void:
	if _sizes.is_empty():
		return
	var index := index_at_local_x(x)
	preview_changed.emit(index, get_global_transform_with_canvas() * Vector2(x, size.y * 0.5))
	if index == _index:
		return
	_index = index
	queue_redraw()
	size_selected.emit(index)


## Ends any live preview -- the palette smoke drives this the way a lifting finger
## does. Always announces, never conditionally: the listener's job is to fade a
## bubble, which is idempotent, and a swallowed "ended" would leave one on screen.
func end_preview() -> void:
	_dragging = false
	preview_ended.emit()


func _set_dragging(value: bool) -> void:
	if value:
		_dragging = true
		return
	end_preview()


## Stop nearest [param x]. Snapping is to the NEAREST stop, so the whole bar is
## live: there is no dead zone between stops for a finger to get lost in.
func index_at_local_x(x: float) -> int:
	var last := maxi(_sizes.size() - 1, 0)
	if last == 0:
		return 0
	var span := maxf(size.x - SIDE_PADDING * 2.0, 1.0)
	var ratio := clampf((x - SIDE_PADDING) / span, 0.0, 1.0)
	return clampi(int(round(ratio * float(last))), 0, last)


## Where stop [param index] sits along the bar, in the control's own coordinates.
## The palette smoke test uses it to drive [method pick_at_local_x] at real stops.
func local_x_for_index(index: int) -> float:
	var last := maxi(_sizes.size() - 1, 0)
	var span := maxf(size.x - SIDE_PADDING * 2.0, 1.0)
	if last == 0:
		return SIDE_PADDING + span * 0.5
	return SIDE_PADDING + span * (float(clampi(index, 0, last)) / float(last))


## Drawn knob radius for stop [param index], scaled across the palette's own
## range so three close sizes still read as three visibly different knobs.
func knob_radius_for_index(index: int) -> float:
	return lerpf(MIN_KNOB_RADIUS, MAX_KNOB_RADIUS, _ratio_for_index(index))


## Half-width of the widest thing the control ever draws around a knob centre
## (BL-14): the capped knob plus its ring and that ring's stroke. [constant
## SIDE_PADDING] must clear it or the end stops bleed out of the control.
static func max_knob_extent() -> float:
	return MAX_KNOB_RADIUS + KNOB_RING_OFFSET + KNOB_RING_WIDTH * 0.5


func _ratio_for_index(index: int) -> float:
	var last := maxi(_sizes.size() - 1, 0)
	if last == 0:
		return 1.0
	var smallest := _sizes[0]
	var largest := _sizes[last]
	if largest <= smallest:
		return float(clampi(index, 0, last)) / float(last)
	return (get_size_at(index) - smallest) / (largest - smallest)


# ==================================================================== drawing ==

func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0 or _sizes.is_empty():
		return
	var middle := size.y * 0.5
	var left := SIDE_PADDING
	var right := maxf(size.x - SIDE_PADDING, left + 1.0)
	var knob_x := local_x_for_index(_index)

	# Wedge track: thin at the small end, thick at the large end.
	_draw_wedge(left, right, middle, TRACK_COLOR)
	# The travelled part is lighter, so the bar reads as "filled to here".
	if knob_x > left:
		_draw_wedge(left, knob_x, middle, TRACK_FILLED_COLOR)

	for i in _sizes.size():
		var tick_x := local_x_for_index(i)
		var tick_half := maxf(_track_half_height(tick_x, left, right) + 4.0, 8.0)
		draw_line(
			Vector2(tick_x, middle - tick_half), Vector2(tick_x, middle + tick_half),
			TICK_COLOR, 2.0, true
		)

	var radius := knob_radius_for_index(_index)
	draw_circle(Vector2(knob_x, middle), radius + 3.0, Color(0.0, 0.0, 0.0, 0.35))
	draw_circle(Vector2(knob_x, middle), radius, KNOB_COLOR)
	draw_arc(
		Vector2(knob_x, middle), radius + KNOB_RING_OFFSET, 0.0, TAU, 48,
		KNOB_RING_COLOR, KNOB_RING_WIDTH, true
	)


func _draw_wedge(from_x: float, to_x: float, middle: float, color: Color) -> void:
	var left := SIDE_PADDING
	var right := maxf(size.x - SIDE_PADDING, left + 1.0)
	var start_half := _track_half_height(from_x, left, right)
	var end_half := _track_half_height(to_x, left, right)
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(from_x, middle - start_half),
			Vector2(to_x, middle - end_half),
			Vector2(to_x, middle + end_half),
			Vector2(from_x, middle + start_half),
		]),
		color
	)


func _track_half_height(x: float, left: float, right: float) -> float:
	var ratio := clampf((x - left) / maxf(right - left, 1.0), 0.0, 1.0)
	return lerpf(MIN_TRACK_HEIGHT, MAX_TRACK_HEIGHT, ratio) * 0.5

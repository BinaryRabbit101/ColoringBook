class_name PaletteSlideInput
extends RefCounted
## Slide-to-select for the palette components (BACKLOG BL-2): while a finger is
## down, the selection follows it across the crayons/swatches instead of waiting
## for a release on one of them -- the behaviour every kids' colouring app has.
##
## Pure logic, no nodes: the palette owns one of these, hands it its own
## [method Node._input] events and a callback, and gets back "true" for the events
## it should mark handled.
##
## [b]It only owns the DRAG half of the gesture.[/b] The first pick still comes
## from the control under the finger, whose [member BaseButton.action_mode] the
## palette switches to [constant BaseButton.ACTION_MODE_BUTTON_PRESS] so that
## [signal BaseButton.pressed] fires on press rather than on release. That split is
## deliberate: hover feedback, tooltips and the [signal BaseButton.pressed] contract
## the palette smoke test drives all keep working, and no pick is ever made twice --
## the press index is remembered here as the "already picked" one.
##
## [b]One input code path[/b] (DESIGN.md 3.3, same as [PageView]):
## [InputEventScreenTouch] / [InputEventScreenDrag], with "Emulate Touch From
## Mouse" on. Nothing here reads mouse events.
##
## Drags that belong to a slide are CONSUMED by the palette, so the
## [ScrollContainer] the swatches sit in cannot drag-scroll under the finger at the
## same time. Wheel scrolling is untouched.

## The palette this belongs to. Everything is hit-tested through its subtree.
var _owner: Control
## Where a gesture may START. Anything outside it (the brush-size slider, the panel
## margins) is left alone.
var _hit_area: Control
var _targets: Array[Control] = []
var _on_pick: Callable

## Touch index of the slide in progress, -1 when idle.
var _touch_index := -1
## Target index the gesture last picked, so a drag inside one control is silent.
var _last_index := -1


## [param owner] is the palette component; [param hit_area] is the control a
## gesture must start inside (the swatch scroller). Null falls back to the owner.
func configure(owner: Control, hit_area: Control = null) -> void:
	_owner = owner
	_hit_area = hit_area
	cancel()


## The controls a slide selects between, in the order their indices are reported to
## [param on_pick] (which takes one int).
func set_targets(targets: Array[Control], on_pick: Callable) -> void:
	_targets = targets
	_on_pick = on_pick
	cancel()


## Feeds one input event in. Returns true when the caller should mark it handled.
func handle_input(event: InputEvent) -> bool:
	if _owner == null or not _owner.is_visible_in_tree():
		return false
	if event is InputEventScreenTouch:
		if event.pressed:
			_begin(event.index, event.position)
		elif event.index == _touch_index:
			cancel()
		# Never consumed: the control under the finger makes the first pick.
		return false
	if event is InputEventScreenDrag and event.index == _touch_index:
		var index := _index_at(event.position)
		if index >= 0 and index != _last_index:
			_last_index = index
			_on_pick.call(index)
		return true
	return false


func is_sliding() -> bool:
	return _touch_index >= 0


func cancel() -> void:
	_touch_index = -1
	_last_index = -1


# =================================================================== internal ==

func _begin(touch_index: int, viewport_position: Vector2) -> void:
	cancel()
	if _targets.is_empty() or not _on_pick.is_valid():
		return
	if not _contains(_hit_area if _hit_area != null else _owner, viewport_position):
		return
	if not _is_topmost(viewport_position):
		return
	_touch_index = touch_index
	# Whatever is under the press has just been picked by the control itself.
	_last_index = _index_at(viewport_position)


## An overlay over the palette (the settings scrim) owns the gesture, not us:
## [method Node._input] runs BEFORE the GUI phase, so the rect test alone cannot
## see it. Fails open -- an unknown hover means "go ahead", because on a fresh
## touch there may be nothing hovered yet.
func _is_topmost(_viewport_position: Vector2) -> bool:
	var viewport := _owner.get_viewport()
	if viewport == null:
		return true
	var hovered := viewport.gui_get_hovered_control()
	if hovered == null:
		return true
	return hovered == _owner or _owner.is_ancestor_of(hovered)


## Index of the target under [param viewport_position], or -1 between targets.
func _index_at(viewport_position: Vector2) -> int:
	for i in _targets.size():
		if _contains(_targets[i], viewport_position):
			return i
	return -1


## Rect test in the control's own space, so a scaled UI canvas (stretch mode
## "canvas_items") and any CanvasLayer transform are handled -- exactly how
## [method PageView._contains_viewport_position] does it.
static func _contains(control: Control, viewport_position: Vector2) -> bool:
	if control == null or not is_instance_valid(control) or not control.is_visible_in_tree():
		return false
	var local := control.get_global_transform_with_canvas().affine_inverse() * viewport_position
	return Rect2(Vector2.ZERO, control.size).has_point(local)

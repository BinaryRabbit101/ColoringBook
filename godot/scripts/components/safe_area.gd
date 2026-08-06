class_name SafeArea
extends MarginContainer
## Keeps its children clear of a phone's notch, punch-hole and gesture bar
## (DESIGN.md 3.5: "UI uses anchors/containers for portrait/landscape and
## notch-safe areas").
##
## [b]Where it is used[/b]: [code]main.tscn[/code] wraps BOTH the screen host and
## the overlay layer in one of these, so every shell screen and the settings gear
## inherit the insets without any of them knowing this node exists. That is the
## "shared safe-area wrapper" -- screens stay self-contained and none of them
## reads [DisplayServer].
##
## [b]The desktop trap[/b]: [method DisplayServer.get_display_safe_area] does not
## mean "unobstructed" on a PC -- it reports the screen's WORK AREA, i.e. the
## desktop minus the taskbar. Taking it at face value would inset a windowed game
## by the height of the Windows taskbar for no reason. A notch only ever eats into
## a window that covers the whole screen, so the insets are computed only when the
## window is exactly screen-sized; anywhere else they are zero.
##
## [b]Units[/b]: the safe area is in physical screen pixels, but margins are in
## the root viewport's coordinate space, which the [code]canvas_items[/code]
## stretch mode scales. Every inset is therefore divided by the live
## viewport/window ratio.

## Inset changed. Payload is (left, top, right, bottom) in viewport units.
signal insets_changed(insets: Vector4)

## Dev/test override. When any component is >= 0 these values are used verbatim
## instead of the platform's, which is how the harness proves the wrapper really
## insets its children on a machine that has no notch.
@export var debug_insets := Vector4(-1.0, -1.0, -1.0, -1.0):
	set(value):
		debug_insets = value
		_apply()

## Applied on top of the platform insets, so content never sits flush against a
## rounded screen corner even on a device that reports no cutout at all.
@export var extra_padding := Vector4.ZERO:
	set(value):
		extra_padding = value
		_apply()

var _insets := Vector4.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_tree().root.size_changed.connect(_apply)
	_apply()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_WM_SIZE_CHANGED:
		# An orientation change moves the cutout from the top edge to a side one.
		_apply()


## The insets currently applied, in viewport units: (left, top, right, bottom).
func get_insets() -> Vector4:
	return _insets


## Recomputes and applies the insets. Safe to call at any time.
func _apply() -> void:
	if not is_inside_tree():
		return
	var insets := _platform_insets()
	if debug_insets.x >= 0.0 or debug_insets.y >= 0.0 \
			or debug_insets.z >= 0.0 or debug_insets.w >= 0.0:
		insets = Vector4(
			maxf(debug_insets.x, 0.0), maxf(debug_insets.y, 0.0),
			maxf(debug_insets.z, 0.0), maxf(debug_insets.w, 0.0)
		)
	insets += extra_padding
	if insets.is_equal_approx(_insets):
		return
	_insets = insets
	add_theme_constant_override("margin_left", int(round(insets.x)))
	add_theme_constant_override("margin_top", int(round(insets.y)))
	add_theme_constant_override("margin_right", int(round(insets.z)))
	add_theme_constant_override("margin_bottom", int(round(insets.w)))
	insets_changed.emit(insets)


## Zero on anything that is not a full-screen window (see the class doc).
func _platform_insets() -> Vector4:
	var screen := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	var window := DisplayServer.window_get_size()
	if screen.x <= 0 or screen.y <= 0 or window != screen:
		return Vector4.ZERO
	var safe := DisplayServer.get_display_safe_area()
	if safe.size.x <= 0 or safe.size.y <= 0:
		return Vector4.ZERO

	var left := float(maxi(safe.position.x, 0))
	var top := float(maxi(safe.position.y, 0))
	var right := float(maxi(screen.x - safe.end.x, 0))
	var bottom := float(maxi(screen.y - safe.end.y, 0))

	# Physical pixels -> viewport units (the canvas_items stretch scale).
	var viewport_size := get_viewport_rect().size
	var scale_x := viewport_size.x / float(window.x) if window.x > 0 else 1.0
	var scale_y := viewport_size.y / float(window.y) if window.y > 0 else 1.0
	return Vector4(left * scale_x, top * scale_y, right * scale_x, bottom * scale_y)

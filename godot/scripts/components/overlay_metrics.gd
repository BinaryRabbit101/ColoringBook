class_name OverlayMetrics
extends Node
## ONE scale for the whole overlay layer (BL-48) -- the settings panel, the adult
## gate, the account/sign-in form, the pack shop and the coloring page's Start-over
## confirm.
##
## [b]The problem it exists for.[/b] The game stretches [code]canvas_items[/code]
## with aspect [code]expand[/code] from a 1152x648 base, so the logical canvas
## NEVER gets narrower than 1152: a portrait phone gets a canvas that is 1152 wide
## and very TALL (DESIGN.md 3.5, and the note BL-21/M6 left in the
## [code]coloring-mechanics[/code] skill). Every overlay in this game was authored
## against that width -- a 600 px panel, 22 px type, 56 px buttons -- which is
## comfortable on a desktop and roughly a THIRD of that on a ~390 pt phone screen,
## where 1152 logical pixels are painted into 390 real ones. The gameplay layer had
## its mobile pass in M6/BL-21/BL-33; the overlay layer did not, and a grown-up on a
## phone was left squinting at a panel floating in the middle of the screen with a
## truncated email in it.
##
## [b]The mechanism is deliberately one number, not five panels' worth of tweaks.[/b]
##
## [codeblock]
## squeeze       logical canvas px per POINT  -- how hard the screen is squeezing us
## content_scale min(squeeze, MAX)            -- how much bigger to draw everything
## min_touch_px  44 pt * squeeze              -- what a finger needs, in canvas px
## [/codeblock]
##
## [b]The squeeze is measured, never guessed[/b] ([method squeeze]): the logical
## viewport width over the window width in points. A desktop window is BIGGER than
## the base canvas, so its squeeze is below 1 and is clamped to exactly 1 -- which is
## why a desktop layout comes out byte-identical to the one that was authored, and
## why nothing here needs a "desktop" branch.
##
## [b]Content stops growing; touch targets do not.[/b] [constant MAX_CONTENT_SCALE]
## caps the type and the paddings, because a panel is only 1152 px wide and 3x type
## in it starts wrapping every label to four words. The touch floor is computed from
## the UNCAPPED squeeze, because a finger is a finger no matter what the type is
## doing -- see [method min_touch_px].
##
## [b]Width is a matter of SHAPE, so it keys off the aspect[/b], never off a pixel
## width (the canvas is never narrow, it is tall): in portrait a panel takes
## [constant PORTRAIT_PANEL_FRACTION] of the canvas width, in landscape it keeps the
## width it was authored with, scaled.
##
## [b]A plain [BoxContainer] in an overlay is a row that stacks in portrait.[/b]
## That is the whole convention -- [method _apply_to] flips any exact-class
## [BoxContainer] to vertical in portrait and back in landscape, and an
## [HBoxContainer] is how a scene says "this row is a row at every size" (the two
## shop tabs). It has to be a plain [BoxContainer] because Godot refuses
## [method BoxContainer.set_vertical] on [HBoxContainer]/[VBoxContainer] -- the same
## trap BL-21 hit with the palette body.
##
## [b]Usage[/b] is one line in the overlay's [method Node._ready]:
## [codeblock]
## _metrics = OverlayMetrics.attach(self)          # finds Center/Panel
## _metrics.applied.connect(_on_overlay_scaled)    # only if the panel reflows
## [/codeblock]
## It parents itself to the overlay, so it dies with it and its signal connections
## go with it. Baselines are captured lazily, per control, into node METADATA the
## first time a control is seen -- so [method apply] is idempotent, a panel that
## rebuilds its children (the pack shop) only has to call [method apply] again, and
## nothing has to remember what anything was authored at.

## Recomputed and re-applied. Panels that have to reflow their own content -- an
## email that must not be clipped, a row that becomes a column -- listen for this
## rather than reading the viewport themselves.
signal applied(scale: float, portrait: bool)

## A finger, in POINTS (device-independent pixels). Apple's HIG says 44, Material
## says 48dp; 44 is the smaller of the two and therefore the honest floor. On a
## ~390 pt phone the canvas is squeezed ~2.95x, so this lands at ~130 CANVAS pixels
## -- which is why the number is computed here instead of being written down
## anywhere as a constant.
const TOUCH_TARGET_PT := 44.0
## DESIGN.md 3.5's existing logical floor. A desktop squeeze is 1.0, so this is what
## [method min_touch_px] returns there, and every overlay control already clears it.
const DESKTOP_TOUCH_FLOOR_PX := 48.0
## Where the CONTENT scale stops. The canvas is 1152 px wide whatever the phone is,
## so a panel's inside is about 940 px at [constant PORTRAIT_PANEL_FRACTION] -- and
## the widest single unwrappable string in the overlay layer ("Sync pictures too
## (uses more data)", on a checkbox, which cannot wrap at all) is about 790 px of
## that at 2.4x. Push the cap higher and that checkbox, not the layout, decides how
## wide the panel is. Touch targets deliberately keep growing past this cap (see
## the class doc and [method min_touch_px]).
const MAX_CONTENT_SCALE := 2.4
## A squeeze past this is not a phone, it is a broken measurement (see the
## [member debug_squeeze] note about hiDPI reporting).
const MAX_SQUEEZE := 4.0
## How much of the canvas width a panel takes in portrait. Not 1.0: the scrim has to
## stay tappable down both sides, because tapping outside is how every one of these
## overlays is dismissed.
const PORTRAIT_PANEL_FRACTION := 0.94

## Where a control's authored sizes are parked the first time it is scaled.
const META_BASELINE := "bl48_baseline"
## Ditto for [method fit_long_text]'s two label properties.
const META_LONG_TEXT := "bl48_long_text"

## Test/dev override, the same hook [member SafeArea.debug_insets] is. Negative
## means "measure it". The harnesses set this to a real phone's squeeze so the
## 44 pt guarantee can be asserted on a desktop box, which cannot otherwise produce
## one: a Windows window is never smaller than the base canvas.
static var debug_squeeze := -1.0

var _overlay: Control
var _panel: Control
var _scale := 1.0
var _touch := DESKTOP_TOUCH_FLOOR_PX
var _portrait := false


## Builds a metrics node for [param overlay] and parents it there. [param panel_path]
## is the panel whose width and contents are scaled; every overlay in this game
## shares the same [code]Scrim / Center / Panel[/code] shape, so the default is
## almost always right. The scrim is deliberately OUTSIDE it -- it is a full-rect
## button and has no business being given a minimum size.
static func attach(overlay: Control, panel_path: NodePath = ^"Center/Panel") -> OverlayMetrics:
	var metrics := OverlayMetrics.new()
	metrics.name = "OverlayMetrics"
	metrics._overlay = overlay
	metrics._panel = overlay.get_node_or_null(panel_path) as Control
	overlay.add_child(metrics)
	return metrics


func _ready() -> void:
	if is_instance_valid(_overlay):
		_overlay.resized.connect(apply)
	var viewport := get_viewport()
	if viewport != null:
		# The overlay's own rect does not change when only the WINDOW does (the
		# logical canvas can stay 1152 wide while the squeeze doubles), so the
		# viewport has to be listened to as well.
		viewport.size_changed.connect(apply)
	apply()


# ================================================================ the numbers ==

## Logical canvas pixels per POINT: how hard this screen is squeezing the game.
##
## [code]window_get_size()[/code] is in real device pixels (hiDPI is on by default),
## and [method DisplayServer.screen_get_scale] is the device-pixels-per-point ratio
## on the platforms that have one (Web reports [code]devicePixelRatio[/code]; Windows
## reports 1.0). Dividing gives the window in points, which is the unit a 44 pt
## finger is quoted in.
##
## Clamped to at least 1.0: a desktop window is bigger than the 1152 px base canvas,
## so its "squeeze" is a stretch, and stretching the overlays down is not a thing
## anybody asked for.
static func squeeze(viewport: Viewport) -> float:
	if debug_squeeze >= 0.0:
		return clampf(debug_squeeze, 1.0, MAX_SQUEEZE)
	if viewport == null:
		return 1.0
	var logical := viewport.get_visible_rect().size.x
	var device := float(DisplayServer.window_get_size().x)
	if logical <= 0.0 or device <= 0.0:
		return 1.0
	var per_point := maxf(
		DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen()), 1.0
	)
	return clampf(logical / (device / per_point), 1.0, MAX_SQUEEZE)


## How much bigger than authored everything in an overlay is drawn. 1.0 on a desktop,
## by construction (see [method squeeze]).
static func content_scale(viewport: Viewport) -> float:
	return minf(squeeze(viewport), MAX_CONTENT_SCALE)


## The smallest an interactive control may be, in CANVAS pixels, so that it is at
## least [constant TOUCH_TARGET_PT] points of real glass under a real thumb.
##
## Note it uses the UNCAPPED squeeze while [method content_scale] is capped: at the
## cap a 48 px control would come out 125 canvas px = 42 pt on a 2.95x phone, which
## is under the floor by just enough to matter. Type can stop growing; a finger
## cannot.
static func min_touch_px(viewport: Viewport) -> float:
	return maxf(TOUCH_TARGET_PT * squeeze(viewport), DESKTOP_TOUCH_FLOOR_PX)


# ================================================================== applying ==

## Recomputes the scale and re-applies it to the whole panel subtree. Idempotent --
## every control is measured against the baseline it was authored with, never
## against what it currently is. Cheap enough to call after rebuilding rows.
func apply() -> void:
	if not is_instance_valid(_overlay) or not _overlay.is_inside_tree():
		return
	var canvas := _overlay.size
	if canvas.x < 1.0 or canvas.y < 1.0:
		return
	var viewport := get_viewport()
	_portrait = canvas.y > canvas.x
	_scale = content_scale(viewport)
	_touch = min_touch_px(viewport)

	if is_instance_valid(_panel):
		var base: Vector2 = _baseline(_panel)["min"]
		# Shape decides the width (portrait = use the room), the squeeze decides
		# everything inside it.
		var width := canvas.x * PORTRAIT_PANEL_FRACTION if _portrait else base.x * _scale
		_panel.custom_minimum_size = Vector2(minf(width, canvas.x), base.y * _scale)
		_walk(_panel)
	applied.emit(_scale, _portrait)


## The live content scale (1.0 on a desktop).
func get_scale() -> float:
	return _scale


## The live touch floor in canvas pixels. Harnesses assert against this rather than
## against a number of their own, so the assertion and the code cannot drift.
func get_touch_floor() -> float:
	return _touch


func is_portrait() -> bool:
	return _portrait


## The panel being scaled, so a harness can measure it without knowing the path.
func get_panel() -> Control:
	return _panel if is_instance_valid(_panel) else null


func _walk(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			_apply_to(child as Control)
		_walk(child)


func _apply_to(control: Control) -> void:
	var base := _baseline(control)

	var font: int = base["font"]
	if font > 0:
		control.add_theme_font_size_override("font_size", maxi(1, int(round(font * _scale))))

	var minimum: Vector2 = (base["min"] as Vector2) * _scale
	if is_interactive(control):
		# A control the player has to hit gets the floor whatever it was authored at.
		minimum.y = maxf(minimum.y, _touch)
		if (base["min"] as Vector2).x > 0.0:
			minimum.x = maxf(minimum.x, _touch)
	control.custom_minimum_size = minimum

	if control is MarginContainer:
		var margins: PackedInt32Array = base["margins"]
		for i in MARGIN_CONSTANTS.size():
			control.add_theme_constant_override(
				MARGIN_CONSTANTS[i], int(round(float(margins[i]) * _scale))
			)
	if control is BoxContainer:
		control.add_theme_constant_override(
			"separation", int(round(float(base["separation"]) * _scale))
		)
		# The convention: a PLAIN BoxContainer is a row that stacks in portrait; an
		# HBoxContainer is a row that never does (class doc).
		if control.get_class() == "BoxContainer":
			(control as BoxContainer).vertical = _portrait


const MARGIN_CONSTANTS: PackedStringArray = [
	"margin_left", "margin_top", "margin_right", "margin_bottom",
]


## True for anything the player is expected to hit with a finger.
##
## A [ScrollBar] is explicitly NOT one: it is furniture on a list that is flicked,
## and giving it the touch floor would lay a 130 px slab down the side of the pack
## shop. (Godot keeps a [ScrollContainer]'s bars as INTERNAL children, so the walk
## never reaches them anyway -- this is the belt to that pair of braces.)
static func is_interactive(control: Control) -> bool:
	if control is ScrollBar:
		return false
	return control is BaseButton or control is LineEdit or control is Range


## What [param control] was authored at, captured the first time it is seen and
## parked on the node itself. Metadata rather than a dictionary in this object
## because a node can be freed out from under us (the pack shop rebuilds its rows
## on every refresh) and a stale key would outlive it.
func _baseline(control: Control) -> Dictionary:
	if control.has_meta(META_BASELINE):
		return control.get_meta(META_BASELINE)
	var base := {
		"min": control.custom_minimum_size,
		"font": _authored_font_size(control),
	}
	if control is MarginContainer:
		var margins := PackedInt32Array()
		for name in MARGIN_CONSTANTS:
			margins.append(control.get_theme_constant(name))
		base["margins"] = margins
	if control is BoxContainer:
		base["separation"] = control.get_theme_constant("separation")
	control.set_meta(META_BASELINE, base)
	return base


## The font size a control was authored with, or -1 for controls that have no text.
## An explicit override wins; otherwise the theme's own size is read and then pinned
## as an override, which is what lets a control with no override scale too.
static func _authored_font_size(control: Control) -> int:
	if control.has_theme_font_size_override("font_size"):
		return control.get_theme_font_size("font_size")
	if control is Label or control is Button or control is LineEdit:
		return control.get_theme_font_size("font_size")
	return -1


# ============================================================= long-word text ==

## Makes a label carrying ONE long unbreakable token -- an email address -- readable
## in portrait instead of clipped ("Binaryrabbit101@gmail.c…", the complaint BL-48
## opened with).
##
## [constant TextServer.AUTOWRAP_ARBITRARY] rather than word wrapping on purpose: an
## email has no spaces, so word wrapping would leave a single line whose minimum
## width is the whole address, and at 2.6x type that is wider than the panel -- the
## label would push the panel off the screen instead of clipping, which is not an
## improvement. Breaking mid-address is ugly and shows every character, and showing
## every character is the requirement.
##
## Static, and it restores what it found, so landscape/desktop is untouched.
static func fit_long_text(label: Label, portrait: bool) -> void:
	if not is_instance_valid(label):
		return
	if not label.has_meta(META_LONG_TEXT):
		label.set_meta(META_LONG_TEXT, [label.autowrap_mode, label.clip_text])
	var base: Array = label.get_meta(META_LONG_TEXT)
	label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY if portrait else base[0]
	label.clip_text = false if portrait else bool(base[1])

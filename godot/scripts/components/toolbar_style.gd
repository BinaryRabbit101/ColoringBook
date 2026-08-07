class_name ToolbarStyle
extends RefCounted
## The coloring toolbar's look, in one place (BL-29).
##
## [b]Why a script and not eight [StyleBoxFlat] sub-resources in the scene.[/b]
## Every button across the top of a coloring page is the same object drawn in a
## different colour: a fat rounded slab with a darker [b]wax lip[/b] along its
## bottom edge and a soft drop shadow, so the row reads as a box of crayons rather
## than a strip of OS chrome. Authoring that as scene data meant four sub-resources
## per button per state and no way to keep them consistent; authoring it here means
## the family is one function and a hue, and a control that draws its own face
## ([PadlockButton], [HistoryButton]) can borrow the very same plate.
##
## [b]The hues are the crayon box.[/b] They are the shipped [PaletteDef] colours,
## nudged only where text contrast demanded it, so the toolbar and the crayon strip
## look like they came out of the same tin.
##
## [b]Layout safety.[/b] Every state carries the SAME explicit content margins, so
## a press can change colour and flatten the lip without changing the button's
## minimum size -- a stylebox whose margins move on press re-lays the whole
## [HBoxContainer] out and nudges its neighbours. Touch targets are the caller's
## business: nothing here shrinks a control below the 48 px floor (DESIGN.md 3.5).

## Corner radius of every toolbar slab.
const RADIUS := 20
## Thickness of the darker bottom edge -- the "wax lip" that makes the slab read as
## a chunky physical thing rather than a flat rectangle.
const LIP := 5
## The lip a pressed button keeps: nearly gone, so the slab looks pushed into the
## bar. Content margins do NOT change, so nothing re-flows.
const LIP_PRESSED := 1

const MARGIN_H := 15
const MARGIN_TOP := 8
const MARGIN_BOTTOM := 12

## Crayon hues, from the shipped crayon box (resources/palettes/palette_child.tres).
const BLUE := Color(0.239216, 0.478431, 0.898039)
const GREEN := Color(0.239216, 0.686275, 0.364706)
const RED := Color(0.850980, 0.317647, 0.235294)
const VIOLET := Color(0.545098, 0.325490, 0.847059)
const TEAL := Color(0.113725, 0.647059, 0.701961)
const AMBER := Color(0.949020, 0.705882, 0.258824)
## The warm slate a "no strong opinion" control wears (Keep colouring, an open
## padlock): still part of the family, just not shouting.
const SLATE := Color(0.352941, 0.309804, 0.278431)

const TEXT := Color(1.0, 0.988235, 0.960784)
const TEXT_DARK := Color(0.239216, 0.164706, 0.070588)
const DISABLED_BG := Color(0.203922, 0.192157, 0.180392)
const DISABLED_TEXT := Color(0.450980, 0.427451, 0.403922)

const SHADOW := Color(0.0, 0.0, 0.0, 0.28)
const SHADOW_SIZE := 5


## Dresses [param button] as a toolbar crayon slab in [param base]. Owns every
## state's [StyleBox] and every state's font colour, so the scene only has to say
## what the button SAYS and how big it is.
static func apply(button: Button, base: Color, dark_text: bool = false) -> void:
	if button == null:
		return
	button.add_theme_stylebox_override("normal", plate(base))
	button.add_theme_stylebox_override("hover", plate(base.lightened(0.14)))
	button.add_theme_stylebox_override("pressed", pressed_plate(base))
	button.add_theme_stylebox_override("focus", plate(base))
	button.add_theme_stylebox_override("disabled", disabled_plate())
	var ink := TEXT_DARK if dark_text else TEXT
	button.add_theme_color_override("font_color", ink)
	button.add_theme_color_override("font_hover_color", ink)
	button.add_theme_color_override("font_pressed_color", ink)
	button.add_theme_color_override("font_focus_color", ink)
	button.add_theme_color_override("font_disabled_color", DISABLED_TEXT)


## The slab itself. Public because [PadlockButton] and [HistoryButton] draw their
## own glyphs onto exactly this shape.
static func plate(base: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = base
	box.set_corner_radius_all(RADIUS)
	box.border_width_bottom = LIP
	box.border_color = base.darkened(0.36)
	box.shadow_color = SHADOW
	box.shadow_size = SHADOW_SIZE
	box.shadow_offset = Vector2(0.0, 3.0)
	_set_margins(box)
	return box


static func pressed_plate(base: Color) -> StyleBoxFlat:
	var box := plate(base.darkened(0.12))
	box.border_width_bottom = LIP_PRESSED
	box.shadow_size = 2
	box.shadow_offset = Vector2(0.0, 1.0)
	return box


static func disabled_plate() -> StyleBoxFlat:
	var box := plate(DISABLED_BG)
	box.border_color = DISABLED_BG.darkened(0.3)
	box.shadow_color = Color(0.0, 0.0, 0.0, 0.16)
	return box


## The hue a control should wear once it is disabled, so a drawn glyph greys out
## in the same language a themed button does.
static func dim(base: Color) -> Color:
	return base.lerp(DISABLED_BG, 0.72)


static func _set_margins(box: StyleBoxFlat) -> void:
	# Explicit and identical in every state: see the class docs -- a stylebox whose
	# margins move on press re-flows the toolbar under the finger.
	box.content_margin_left = MARGIN_H
	box.content_margin_right = MARGIN_H
	box.content_margin_top = MARGIN_TOP
	box.content_margin_bottom = MARGIN_BOTTOM

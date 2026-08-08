class_name StickerButton
extends BaseButton
## One sticker on the palette strip (BACKLOG BL-36) -- the thing the strip fills
## with when the cycle ring runs past the last crayon box.
##
## [b]It is a CrayonButton's sibling, not its subclass.[/b] It offers the same
## three properties the strip's fit drives -- [member canonical_size],
## [member orientation], [member selected] -- and the same
## [method box_for] contract, so BL-33's no-scroll fit sizes a row of stickers
## with the code it already had. What it does NOT share is the drawing: a crayon
## is a tapered silhouette in one colour, a sticker is somebody else's artwork on a
## peel-off card, and forcing one [method _draw] to be both would be worse than two
## honest ones.
##
## [b]It does not rotate with the dock.[/b] [CrayonButton] turns a quarter turn in
## the landscape column because a crayon lying on its side is still a crayon;
## artwork on its side is just wrong. [member orientation] therefore only swaps the
## control's BOX (so the fit's pitch/length still mean "along the strip" and
## "across it"); the card is drawn upright either way.
##
## The owning palette sets [member texture] / [member sticker_index] /
## [member selected]; this node only reports [signal BaseButton.pressed].

## Touch floor, shared with the crayons so a strip of either is aimed at the same
## way (DESIGN.md §1).
const MIN_TOUCH_TARGET := CrayonButton.MIN_TOUCH_TARGET
## Default card, in CANONICAL space (x across the strip, y along it). Square,
## because a sticker sheet's cells are.
const DEFAULT_SIZE := Vector2(96.0, 96.0)
## Squarest the card is ever drawn. 1.0: a sticker card that stretches stops
## looking like a sticker sheet and starts looking like a button.
const CANONICAL_ASPECT := 1.0

## Along the strip's long axis (portrait row).
const ORIENT_UP := CrayonButton.ORIENT_UP
## Across it (landscape column).
const ORIENT_LEFT := CrayonButton.ORIENT_LEFT

## How far a selected sticker lifts off the sheet, as a fraction of the card.
const LIFT_RATIO := 0.09
## Peak of the settle bounce, and how long it takes to land. Same shape as the
## crayon's (BL-16), scaled to the card.
const SELECT_BOUNCE_SCALE := 1.12
const SELECT_BOUNCE_SECONDS := 0.36

const CARD := Color(0.996078, 0.980392, 0.945098)
const CARD_EDGE := Color(0.788235, 0.741176, 0.670588)
const CARD_RADIUS := 14.0
const CARD_INSET := 4.0
## The selected card's bright rim, straight out of [CrayonButton]: a dark outline
## alone disappears against dark artwork at arm's length.
const SELECTION_RIM := Color(1.0, 0.784314, 0.290196)
const SELECTION_RIM_WIDTH := 6.0
## Halo layers behind a selected card.
const GLOW_LAYERS := 6
const GLOW_ALPHA := 0.10
const GLOW_COLOR := Color(1.0, 0.847059, 0.443137)
## How much of the card the artwork fills.
const ART_INSET_RATIO := 0.12

## The sticker's artwork.
var texture: Texture2D = null:
	set(value):
		texture = value
		queue_redraw()

## The sprite-sheet spec for an ANIMATED sticker (BL-43), or {} for a still one.
## Same dictionary [StickerLayer] is handed, from the same [StickerDef], so the card
## and the page play the same animation at the same speed -- and a card advertises
## what the child will actually get.
var sheet: Dictionary = {}:
	set(value):
		sheet = value
		_clock = 0.0
		set_process(not sheet.is_empty())
		queue_redraw()

## Index of this sticker in the [StickerSetDef]'s list.
var sticker_index: int = 0

## Stable id of the sticker on this card. Carried so the palette can answer
## "which sticker is in hand" without a second lookup.
var sticker_id: String = ""

## Whether this is the strip's active sticker.
var selected: bool = false:
	set(value):
		if selected == value:
			return
		selected = value
		if selected:
			_bounce()
		else:
			_kill_bounce()
			_lift_scale = 1.0
		queue_redraw()

## Which way the STRIP runs. Only swaps the control's box -- see the class doc.
var orientation: int = ORIENT_UP:
	set(value):
		var resolved := ORIENT_LEFT if value == ORIENT_LEFT else ORIENT_UP
		if orientation == resolved:
			return
		orientation = resolved
		custom_minimum_size = box_for(resolved, canonical_size)
		queue_redraw()

## The box this card asks for, in CANONICAL space. Never below
## [constant MIN_TOUCH_TARGET] on either axis (BL-33's floor, unmoved).
var canonical_size: Vector2 = DEFAULT_SIZE:
	set(value):
		var resolved := Vector2(
			maxf(value.x, MIN_TOUCH_TARGET), maxf(value.y, MIN_TOUCH_TARGET)
		)
		if canonical_size.is_equal_approx(resolved):
			return
		canonical_size = resolved
		custom_minimum_size = box_for(orientation, resolved)
		queue_redraw()

var _lift_scale := 1.0
var _bounce_tween: Tween
## Playback clock for an animated card. Only ever ticking when [member sheet] is
## non-empty -- a strip of still stickers costs no `_process` at all.
var _clock := 0.0


func _init() -> void:
	custom_minimum_size = box_for(orientation, canonical_size)
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(false)


func _process(delta: float) -> void:
	var before := current_frame()
	_clock += delta
	if current_frame() != before:
		queue_redraw()


## Which frame of [member sheet] this card is showing. 0 for a still sticker.
func current_frame() -> int:
	if sheet.is_empty():
		return 0
	var count := int(sheet[StickerLayer.SHEET_FRAMES])
	return int(_clock * float(sheet[StickerLayer.SHEET_FPS])) % count


func is_animated() -> bool:
	return not sheet.is_empty()


func _ready() -> void:
	# Godot turns processing back on for any script that DEFINES _process when the
	# node enters the tree, so the _init call is not the last word: a still card must
	# not tick, and there are a dozen of them on the strip.
	set_process(is_animated())
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)


## The control box one card of [param canonical] needs in [param orientation_id].
## Same contract as [method CrayonButton.box_for], which is what lets one fit size
## either strip.
static func box_for(orientation_id: int, canonical := DEFAULT_SIZE) -> Vector2:
	return (
		Vector2(canonical.y, canonical.x)
		if orientation_id == ORIENT_LEFT
		else canonical
	)


## How far a selected card is currently lifted, in pixels. Public so the smoke can
## measure the selection rather than trusting a constant (the BL-33 rule).
func current_lift() -> float:
	if not selected:
		return 0.0
	return minf(size.x, size.y) * LIFT_RATIO * _lift_scale


func is_bouncing() -> bool:
	return _bounce_tween != null and _bounce_tween.is_valid()


func _bounce() -> void:
	_kill_bounce()
	_lift_scale = SELECT_BOUNCE_SCALE
	if not is_inside_tree():
		_lift_scale = 1.0
		return
	_bounce_tween = create_tween()
	_bounce_tween.tween_method(
		_set_lift_scale, SELECT_BOUNCE_SCALE, 1.0, SELECT_BOUNCE_SECONDS
	).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _set_lift_scale(value: float) -> void:
	_lift_scale = value
	queue_redraw()


func _kill_bounce() -> void:
	if _bounce_tween != null and _bounce_tween.is_valid():
		_bounce_tween.kill()
	_bounce_tween = null


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	# The lift always goes UP the screen, in both docks: the card is artwork and
	# artwork is never sideways, so there is no canonical space to rotate here.
	var card := Rect2(Vector2(CARD_INSET, CARD_INSET), size - Vector2(CARD_INSET, CARD_INSET) * 2.0)
	card.position.y -= current_lift()
	if is_pressed():
		card.position.y += 3.0
	if card.size.x <= 0.0 or card.size.y <= 0.0:
		return

	if selected:
		for i in GLOW_LAYERS:
			var spread := (4.0 + float(i) * 3.0)
			_round_rect(card.grow(spread), Color(GLOW_COLOR.r, GLOW_COLOR.g, GLOW_COLOR.b, GLOW_ALPHA),
				CARD_RADIUS + spread)

	_round_rect(Rect2(card.position + Vector2(0.0, 3.0), card.size), Color(0.0, 0.0, 0.0, 0.18), CARD_RADIUS)
	_round_rect(card, CARD, CARD_RADIUS)

	if texture != null:
		var inset := minf(card.size.x, card.size.y) * ART_INSET_RATIO
		var box := card.grow(-inset)
		# One FRAME of the sheet for an animated sticker; the whole image for a still
		# one, which is the same rect this drew before BL-43.
		var art_size := StickerLayer.frame_size(texture, sheet)
		if art_size.x > 0.0 and art_size.y > 0.0:
			var factor := minf(box.size.x / art_size.x, box.size.y / art_size.y)
			var drawn := art_size * factor
			var target := Rect2(box.get_center() - drawn * 0.5, drawn)
			if sheet.is_empty():
				draw_texture_rect(texture, target, false)
			else:
				draw_texture_rect_region(texture, target, _frame_region(art_size))

	if selected:
		_round_rect_outline(card, SELECTION_RIM, SELECTION_RIM_WIDTH, CARD_RADIUS)
	_round_rect_outline(
		card, CARD_EDGE, 3.0 if is_hovered() or selected else 2.0, CARD_RADIUS
	)


## The source rect of the current frame, in the sheet's own pixels. Row-major from
## the top left, which is how [Sprite2D] numbers its frames -- the page draws the
## same sheet through that node, and the two must not disagree about frame 3.
func _frame_region(cell: Vector2) -> Rect2:
	var columns := int(sheet[StickerLayer.SHEET_HFRAMES])
	var index := current_frame()
	return Rect2(
		Vector2(float(index % columns) * cell.x, float(index / columns) * cell.y), cell
	)


func _round_rect(box: Rect2, color: Color, radius: float) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(int(radius))
	draw_style_box(style, box)


func _round_rect_outline(box: Rect2, color: Color, width: float, radius: float) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	style.draw_center = false
	style.border_color = color
	style.set_border_width_all(int(width))
	style.set_corner_radius_all(int(radius))
	draw_style_box(style, box)

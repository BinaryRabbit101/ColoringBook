class_name ModeSelect
extends Control
## "Child or Adult?" -- two big cards, one per difficulty mode (DESIGN.md 1, 2).
##
## Mode is the one setting that parameterises everything downstream (palette
## component, brush sizes, completion threshold), so this screen exists twice in
## the flow: once after the title, and again as the settings panel's "change mode"
## destination. It is the same scene both times -- the only difference is
## [method set_back_visible], which the parent turns on when the screen is opened
## OVER something the player can return to.
##
## Signals up: [signal mode_chosen], [signal back_requested]. It sets no state; it
## does not call [code]GameState.set_mode()[/code] itself, because the parent may
## want to do other things in the same beat (swap screens, close an overlay) and
## only the parent knows which.
##
## [b]No art assets[/b]: each card's illustration is drawn from primitives in
## [ModeArt], in the REAL colours of that mode's [PaletteDef]. The child card
## shows a fan of crayons, the adult card a graded swatch grid -- so the cards are
## an honest preview of the palette the player is choosing, and they update for
## free when the palette resources are edited.

## The player picked a mode. Payload is a [PaletteDef] mode id.
signal mode_chosen(mode: String)
## The player backed out without choosing (only reachable when the back button is
## shown -- see [method set_back_visible]).
signal back_requested()

## Card footprint. Comfortably past the 64 px child-mode touch floor in both axes.
const CARD_SIZE := Vector2(360.0, 452.0)
## Height reserved for a card's illustration.
const ART_HEIGHT := 216.0

## [b]Portrait (M6)[/b]. Two 360x452 cards side by side need ~800 px of width; a
## phone held upright has less, and a row would just squeeze them until the
## illustrations were slivers. Below this aspect ratio the row becomes a COLUMN
## and the cards trade height for width, illustration included.
##
## The card holder is a plain [BoxContainer], NOT an [HBoxContainer]: Godot
## refuses [code]set_vertical()[/code] on the H/V subclasses ("Can't change
## orientation of HBoxContainer"), and they exist only to preset that one
## property. The base class flips freely, so the same node does both jobs and no
## card is ever rebuilt.
const PORTRAIT_ASPECT := 1.0
## Card height when stacked. Two of these plus the header fit a 720x1280 phone
## with room to spare, and they still grow to fill whatever is left over.
const PORTRAIT_CARD_HEIGHT := 300.0
## Illustration height when stacked.
const PORTRAIT_ART_HEIGHT := 118.0
## Touch-target floor asserted by the smoke test (DESIGN.md 1: child mode is
## deliberately more generous than the global 48 px).
const MIN_TOUCH_TARGET := CrayonButton.MIN_TOUCH_TARGET

const CARD_TITLES := {
	PaletteDef.MODE_CHILD: "Child",
	PaletteDef.MODE_ADULT: "Adult",
}
const CARD_BLURBS := {
	PaletteDef.MODE_CHILD: "Big crayons, big brush,\neasy to finish a page.",
	PaletteDef.MODE_ADULT: "Many shades, finer brushes,\nfill it properly.",
}

const CARD_BG := Color(0.223529, 0.203922, 0.192157)
const CARD_BG_HOVER := Color(0.286275, 0.258824, 0.239216)
const CARD_BORDER := Color(0.415686, 0.360784, 0.301961)
const CARD_BORDER_ACTIVE := Color(0.972549, 0.803922, 0.478431)
const PAPER := Color(0.988235, 0.976471, 0.956863)


## A card's illustration: crayons for child mode, a swatch grid for adult mode.
## Drawn, never imported -- see the class doc.
class ModeArt extends Control:
	const CRAYONS := 5
	const SWATCH_COLUMNS := 6
	const SWATCH_ROWS := 4

	var mode: String
	var colors: PackedColorArray
	var shades_per_family := 1

	func _init(mode_id: String, palette: PaletteDef) -> void:
		mode = mode_id
		colors = palette.colors if palette != null else PackedColorArray()
		shades_per_family = palette.effective_shades_per_family() if palette != null else 1
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(0.0, ART_HEIGHT)

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		if size.x <= 8.0 or size.y <= 8.0 or colors.is_empty():
			return
		# Both illustrations sit on a sheet of paper, so the cards read as two
		# ways of colouring the same book rather than two different apps.
		var sheet := Rect2(Vector2(6.0, 6.0), size - Vector2(12.0, 12.0))
		draw_rect(sheet, PAPER)
		draw_rect(sheet, Color(0.788235, 0.756863, 0.705882), false, 3.0)
		if mode == PaletteDef.MODE_CHILD:
			_draw_crayon_fan(sheet)
		else:
			_draw_swatch_grid(sheet)

	## A row of crayons standing on the sheet, each fanned about its OWN base so
	## the bottoms stay on the shelf line and only the tips spread.
	func _draw_crayon_fan(sheet: Rect2) -> void:
		var base_y := sheet.end.y - sheet.size.y * 0.07
		var length := sheet.size.y * 0.80
		var spacing := sheet.size.x / float(CRAYONS + 1)
		var width := minf(spacing * 0.66, length * 0.24)
		var stride := maxi(colors.size() / CRAYONS, 1)
		for i in CRAYONS:
			var offset := (float(i) - float(CRAYONS - 1) * 0.5) * spacing
			var base := Vector2(sheet.get_center().x + offset, base_y)
			var angle := deg_to_rad((float(i) - float(CRAYONS - 1) * 0.5) * 7.0)
			_draw_crayon(base, angle, length, width, colors[(i * stride) % colors.size()])

	func _draw_crayon(base: Vector2, angle: float, length: float, width: float, color: Color) -> void:
		var up := Vector2.UP.rotated(angle)
		var side := up.orthogonal()
		var half := width * 0.5
		var tip := base + up * length
		var tip_base := base + up * (length * 0.86)
		# Tip, tapered body, flat bottom -- the same silhouette CrayonButton draws.
		var body := PackedVector2Array([
			tip + side * (half * 0.3),
			tip - side * (half * 0.3),
			tip_base - side * half,
			base - side * half,
			base + side * half,
			tip_base + side * half,
		])
		draw_colored_polygon(body, color)
		# Shading down the right-hand edge gives the flat colour volume.
		draw_colored_polygon(
			PackedVector2Array([
				tip_base + side * half,
				base + side * half,
				base + side * (half * 0.25),
				tip_base + side * (half * 0.25),
			]),
			color.darkened(0.18)
		)
		# Paper wrapper, exactly as CrayonButton draws it: the body's own colour
		# flattened back over the shading, edged with two white bands and carrying
		# a pale label patch.
		var wrap_top := base + up * (length * 0.66)
		var wrap_bottom := base + up * (length * 0.14)
		_draw_band(wrap_bottom, wrap_top, side, half, color)
		var band := maxf(length * 0.018, 2.0)
		_draw_band(wrap_top - up * band, wrap_top, side, half, Color(1, 1, 1, 0.82))
		_draw_band(wrap_bottom, wrap_bottom + up * band, side, half, Color(1, 1, 1, 0.82))
		var label_center := (wrap_top + wrap_bottom) * 0.5
		var label_half := length * 0.055
		_draw_band(
			label_center - up * label_half, label_center + up * label_half,
			side, half * 0.72, Color(1, 1, 1, 0.34)
		)
		var outline := body.duplicate()
		outline.append(body[0])
		draw_polyline(outline, color.darkened(0.5), 2.0, true)

	## A quad spanning [param from] to [param to] across the crayon's full width.
	func _draw_band(from: Vector2, to: Vector2, side: Vector2, half: float, color: Color) -> void:
		draw_colored_polygon(
			PackedVector2Array([
				from - side * half, to - side * half, to + side * half, from + side * half
			]),
			color
		)

	## The adult palette's real families, light to dark, as a grid of chips.
	func _draw_swatch_grid(sheet: Rect2) -> void:
		var inset := sheet.grow(-sheet.size.y * 0.11)
		var columns := mini(SWATCH_COLUMNS, maxi(colors.size() / maxi(shades_per_family, 1), 1))
		var rows := mini(SWATCH_ROWS, maxi(shades_per_family, 1))
		var gap := inset.size.x * 0.02
		var chip := Vector2(
			(inset.size.x - gap * float(columns - 1)) / float(columns),
			(inset.size.y - gap * float(rows - 1)) / float(rows)
		)
		for column in columns:
			for row in rows:
				var index := column * maxi(shades_per_family, 1) + row
				if index >= colors.size():
					continue
				var chip_rect := Rect2(
					inset.position + Vector2((chip.x + gap) * column, (chip.y + gap) * row),
					chip
				)
				draw_rect(chip_rect, colors[index])
				draw_rect(chip_rect, Color(0.176471, 0.129412, 0.09, 0.28), false, 1.5)


@onready var _cards_row: BoxContainer = $Margin/Body/Cards
@onready var _back_button: Button = $Margin/Body/Footer/BackButton
@onready var _footer: HBoxContainer = $Margin/Body/Footer

## mode id -> the card Button.
var _cards: Dictionary = {}


func _ready() -> void:
	_back_button.pressed.connect(func() -> void: back_requested.emit())
	set_back_visible(false)
	_build_cards()
	GameState.mode_changed.connect(_on_mode_changed)
	resized.connect(_apply_orientation)
	_apply_orientation()


# =============================================================== orientation ==

## Switches the card row between a row and a column, and reflows each card for
## the orientation it is now in. Driven by the screen's aspect, not by a
## [DisplayServer] orientation query, so it is equally right for a resized desktop
## window and a rotated phone.
func _apply_orientation() -> void:
	if not is_instance_valid(_cards_row):
		return
	var portrait := is_portrait()
	_cards_row.vertical = portrait
	for mode_id in _cards:
		var card: Button = _cards[mode_id]
		card.custom_minimum_size = (
			Vector2(0.0, PORTRAIT_CARD_HEIGHT) if portrait else CARD_SIZE
		)
		card.size_flags_horizontal = (
			Control.SIZE_FILL if portrait else Control.SIZE_EXPAND_FILL
		)
		card.size_flags_vertical = (
			Control.SIZE_EXPAND_FILL if portrait else Control.SIZE_SHRINK_CENTER
		)
		var art := card.get_node_or_null("Margin/Column/Art") as Control
		if art != null:
			art.custom_minimum_size = Vector2(
				0.0, PORTRAIT_ART_HEIGHT if portrait else ART_HEIGHT
			)


## True while the screen is taller than it is wide, i.e. the cards are stacked.
func is_portrait() -> bool:
	return size.y > 0.0 and size.x / size.y < PORTRAIT_ASPECT


# ===================================================================== build ==

func _build_cards() -> void:
	for child in _cards_row.get_children():
		child.queue_free()
	_cards.clear()
	for mode_id in GameState.get_available_modes():
		var card := _make_card(mode_id)
		_cards_row.add_child(card)
		_cards[mode_id] = card
	_refresh_active()
	_apply_orientation()


func _make_card(mode_id: String) -> Button:
	var palette := GameState.get_palette_for_mode(mode_id)

	var card := Button.new()
	card.name = "Card_%s" % mode_id
	card.custom_minimum_size = CARD_SIZE
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	card.focus_mode = Control.FOCUS_NONE
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.clip_contents = true
	card.pressed.connect(_on_card_pressed.bind(mode_id))
	_style_card(card, false)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	card.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var art := ModeArt.new(mode_id, palette)
	art.name = "Art"
	art.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(art)

	var title := Label.new()
	title.name = "Title"
	title.text = String(CARD_TITLES.get(mode_id, mode_id.capitalize()))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color(0.976471, 0.960784, 0.933333))
	column.add_child(title)

	var blurb := Label.new()
	blurb.name = "Blurb"
	blurb.text = String(CARD_BLURBS.get(mode_id, ""))
	blurb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_font_size_override("font_size", 20)
	blurb.add_theme_color_override("font_color", Color(0.729412, 0.678431, 0.6))
	column.add_child(blurb)

	var palette_name := Label.new()
	palette_name.name = "PaletteName"
	palette_name.text = "%s · %d colors" % [
		palette.display_name if palette != null else "?",
		palette.color_count() if palette != null else 0,
	]
	palette_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	palette_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	palette_name.add_theme_font_size_override("font_size", 17)
	palette_name.add_theme_color_override("font_color", Color(0.556863, 0.505882, 0.443137))
	column.add_child(palette_name)

	return card


func _style_card(card: Button, active: bool) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = CARD_BG
	normal.border_color = CARD_BORDER_ACTIVE if active else CARD_BORDER
	normal.set_border_width_all(4 if active else 3)
	normal.set_corner_radius_all(22)
	normal.set_content_margin_all(0.0)

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = CARD_BG_HOVER
	hover.border_color = CARD_BORDER_ACTIVE

	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.34902, 0.301961, 0.243137)

	card.add_theme_stylebox_override("normal", normal)
	card.add_theme_stylebox_override("hover", hover)
	card.add_theme_stylebox_override("pressed", pressed)
	card.add_theme_stylebox_override("disabled", normal)
	card.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


## Marks the mode the game is currently in, so re-opening this screen from
## settings shows the player where they are.
func _refresh_active() -> void:
	for mode_id in _cards:
		_style_card(_cards[mode_id], String(mode_id) == GameState.mode)


func _on_mode_changed(_mode: String) -> void:
	_refresh_active()


# ==================================================================== access ==

## Shows or hides the "Back" footer. On by default only when the parent opens this
## screen over something (settings), off when it is a step in the first-run flow.
func set_back_visible(is_visible: bool) -> void:
	_footer.visible = is_visible


func is_back_visible() -> bool:
	return _footer.visible


## The card [Button] for a mode id, or null. Tests emit its `pressed`.
func get_card(mode_id: String) -> Button:
	return _cards.get(mode_id, null)


func get_cards() -> Array[Button]:
	var cards: Array[Button] = []
	for mode_id in GameState.get_available_modes():
		if _cards.has(mode_id):
			cards.append(_cards[mode_id])
	return cards


func get_back_button() -> Button:
	return _back_button


func _on_card_pressed(mode_id: String) -> void:
	mode_chosen.emit(mode_id)

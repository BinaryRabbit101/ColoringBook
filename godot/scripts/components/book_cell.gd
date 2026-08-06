class_name BookCell
extends Button
## One book on the shelf: cover art, title and page count, in a tappable card.
##
## Built from primitives in [method _init] like the palette's [CrayonButton] and
## [SwatchButton], so the shelf needs no extra scene file and no art assets.
## Extends [Button] so touch and mouse arrive through the engine's single button
## path (DESIGN.md 3.3); the owning screen listens for [signal Button.pressed] and
## maps it back to the [BookDef].
##
## Self-contained: it is handed a [BookDef] via [method set_book] and reaches
## nothing outside its own subtree.

## Global touch-target floor (DESIGN.md 3.5). The card is far larger; the
## constant exists so the shelf can assert against it.
const MIN_TOUCH_TARGET := 48.0
## Card footprint. Portrait-ish, so a row of them reads as books on a shelf.
const DEFAULT_SIZE := Vector2(224.0, 300.0)
## Height reserved for the cover art inside the card.
const COVER_HEIGHT := 190.0

var _cover: TextureRect
var _title: Label
var _subtitle: Label
var _book: BookDef


func _init() -> void:
	custom_minimum_size = DEFAULT_SIZE
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_apply_card_style()
	_build()


func _apply_card_style() -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.223529, 0.203922, 0.192157)
	normal.border_color = Color(0.415686, 0.360784, 0.301961)
	normal.set_border_width_all(3)
	normal.set_corner_radius_all(18)
	normal.content_margin_left = 0.0
	normal.content_margin_right = 0.0
	normal.content_margin_top = 0.0
	normal.content_margin_bottom = 0.0

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.286275, 0.258824, 0.239216)
	hover.border_color = Color(0.972549, 0.803922, 0.478431)

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.34902, 0.301961, 0.243137)
	pressed.border_color = Color(0.972549, 0.803922, 0.478431)

	add_theme_stylebox_override("normal", normal)
	add_theme_stylebox_override("hover", hover)
	add_theme_stylebox_override("pressed", pressed)
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _build() -> void:
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	# The cover sits on its own light "paper" panel: page art is dark lines on
	# white, which would vanish against the card's dark background.
	var frame := PanelContainer.new()
	frame.name = "CoverFrame"
	frame.custom_minimum_size = Vector2(0.0, COVER_HEIGHT)
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var paper := StyleBoxFlat.new()
	paper.bg_color = Color(0.988235, 0.976471, 0.956863)
	paper.set_corner_radius_all(10)
	paper.set_content_margin_all(6.0)
	frame.add_theme_stylebox_override("panel", paper)
	column.add_child(frame)

	_cover = TextureRect.new()
	_cover.name = "Cover"
	_cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(_cover)

	_title = Label.new()
	_title.name = "Title"
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.add_theme_font_size_override("font_size", 24)
	_title.add_theme_color_override("font_color", Color(0.976471, 0.960784, 0.933333))
	column.add_child(_title)

	_subtitle = Label.new()
	_subtitle.name = "Subtitle"
	_subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 18)
	_subtitle.add_theme_color_override("font_color", Color(0.729412, 0.678431, 0.6))
	column.add_child(_subtitle)


# ====================================================================== data ==

## Fills the card from [param book]. Passing null blanks it.
func set_book(book: BookDef) -> void:
	_book = book
	if book == null:
		_cover.texture = null
		_title.text = ""
		_subtitle.text = ""
		tooltip_text = ""
		return
	_cover.texture = book.get_cover_texture()
	_title.text = book.display_name
	var count := book.page_count()
	_subtitle.text = "%d page%s" % [count, "" if count == 1 else "s"]
	tooltip_text = "%s — %s" % [book.display_name, _subtitle.text]


func get_book() -> BookDef:
	return _book


func get_title_text() -> String:
	return _title.text


func get_subtitle_text() -> String:
	return _subtitle.text


func has_cover() -> bool:
	return _cover.texture != null

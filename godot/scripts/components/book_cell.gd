class_name BookCell
extends Button
## One coloring book standing on the shelf: a colourful cover with a spine, the
## page block peeking out of the open edge, the cover art framed on the front and
## the title lettered under it (DESIGN.md 2, BL-28).
##
## Built from primitives in [method _init] like the palette's [CrayonButton], so
## the shelf needs no extra scene file and no art assets.
## Extends [Button] so touch and mouse arrive through the engine's single button
## path (DESIGN.md 3.3); the owning screen listens for [signal Button.pressed] and
## maps it back to the [BookDef].
##
## [b]BL-28 turned the card into a book.[/b] It used to be a rounded dark panel
## made of [StyleBoxFlat]s -- a UI card among UI cards. Now the silhouette is drawn
## by the inner [code]BookArt[/code] control: a drop shadow, the stacked white page
## edges standing proud of the cover's open (right) edge, the cover itself, a
## darker spine band with its hinge crease and ribs down the left, a paper plate
## for the art and a diagonal gloss. The [Button]'s own styleboxes are emptied --
## it contributes the input surface and nothing visible.
##
## [b]Every book is a different colour[/b], picked from [constant COVER_COLORS] by
## hashing the book's stable uid ([method cover_color_for]). Deterministic, so a
## book keeps its colour across sessions and across screenshots, and free -- no
## authoring step and nothing new in [BookDef].
##
## [b]The lift lives on a child[/b], never on this node. Hovering tips the book out
## of the shelf and pressing pushes it back in, but the animation is applied to
## [member _body] -- a [Control] anchored to the full rect -- so this node's
## [member Control.size] and [member Control.global_position] never move. The
## shelf's column maths and the dev harnesses that measure touch targets and
## overflow measure the [Button], and the [Button] holds still.
##
## Self-contained: it is handed a [BookDef] via [method set_book] and reaches
## nothing outside its own subtree.

## Global touch-target floor (DESIGN.md 3.5). The book is far larger; the
## constant exists so the shelf can assert against it.
const MIN_TOUCH_TARGET := 48.0
## Book footprint. Portrait, so a row of them reads as books on a shelf.
const DEFAULT_SIZE := Vector2(224.0, 300.0)
## Height reserved for the cover art plate inside the book.
const COVER_HEIGHT := 148.0

## Lettering: cream with a dark outline, so the title reads on every cover colour.
const TITLE_INK := Color(1.0, 0.988235, 0.945098)
const TITLE_OUTLINE_SIZE := 5
## The little page-count sticker under the title.
const STICKER_PAPER := Color(1.0, 0.972549, 0.901961)
const STICKER_INK := Color(0.325490, 0.207843, 0.121569)

## Cover colours, one per book, chosen by [method cover_color_for]. Crayon-bright,
## and all deep enough that cream lettering reads on them.
const COVER_COLORS: PackedColorArray = [
	Color(0.858824, 0.278431, 0.235294),  # tomato
	Color(0.913725, 0.505882, 0.129412),  # pumpkin
	Color(0.309804, 0.639216, 0.317647),  # leaf
	Color(0.176471, 0.529412, 0.760784),  # sky
	Color(0.494118, 0.352941, 0.717647),  # grape
	Color(0.858824, 0.352941, 0.564706),  # bubblegum
	Color(0.101961, 0.588235, 0.564706),  # lagoon
	Color(0.788235, 0.607843, 0.145098),  # sunflower
]

## Hover: the book tips out of the shelf by this much, at this tilt.
const HOVER_LIFT := 9.0
const HOVER_TILT_DEGREES := 2.2
const HOVER_SCALE := 1.035
const HOVER_SECONDS := 0.16
## Press: it goes back in, and shrinks a hair.
const PRESS_SINK := 3.0
const PRESS_SCALE := 0.975
const PRESS_SECONDS := 0.09


## The book itself, drawn. An inner class (the [TitleScreen] pattern) so the whole
## cell stays one file with no scene of its own, and so the drawing owns the
## geometry constants the surrounding layout has to respect.
class BookArt extends Control:
	## Drawn geometry, in the cell's own space. The book's BOTTOM edge is the
	## cell's bottom edge on purpose: [ShelfBoards] puts a plank directly under the
	## bottom of each row, so anything reserved here would leave the books
	## floating above their shelf.
	const EDGE_INSET := 3.0
	const TOP_INSET := 5.0
	## Width of the spine band down the closed (left) edge.
	const SPINE_WIDTH := 21.0
	## How far the stacked page edges stand proud of the cover's open edge.
	const PAGE_LIP := 9.0
	## Number of visible leaves in that stack.
	const PAGE_LINES := 5
	const CORNER_RADIUS := 9.0
	## Paper the pages are drawn in.
	const PAPER := Color(0.996078, 0.988235, 0.964706)
	const PAPER_EDGE := Color(0.788235, 0.756863, 0.694118)

	var cover: Color = Color(0.858824, 0.278431, 0.235294)
	## Brightened while the pointer is over the book, so the cover warms up before
	## the lift has finished playing.
	var warm := false

	## One [StyleBoxFlat], reused: [method CanvasItem.draw_rect] has no corner
	## radius, and a book draws six rounded pieces per redraw.
	var _box := StyleBoxFlat.new()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)
		_box.anti_aliasing = true

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		if size.x <= 40.0 or size.y <= 40.0:
			return
		var face := cover.lightened(0.06) if warm else cover
		var body := Rect2(
			EDGE_INSET, TOP_INSET,
			size.x - EDGE_INSET * 2.0 - PAGE_LIP, size.y - TOP_INSET
		)
		_draw_shadow(body)
		_draw_pages(body)
		_draw_cover(body, face)
		_draw_spine(body, face)
		_draw_gloss(body)
		# The dark outline last, so nothing overdraws the silhouette.
		_rounded(body, face.darkened(0.52), false, 2.0)

	## Under the book and a little to the right: the room's light comes from the
	## upper left (see [ShelfBackdrop]). It falls onto the plank below, which is
	## what stops the book looking pasted on.
	func _draw_shadow(body: Rect2) -> void:
		_rounded(
			Rect2(body.position + Vector2(6.0, 5.0), body.size + Vector2(PAGE_LIP, 0.0)),
			Color(0.145098, 0.070588, 0.031373, 0.24)
		)

	## The stacked page block, standing proud of the cover's open edge. Drawn
	## before the cover, so only the lip of it shows.
	func _draw_pages(body: Rect2) -> void:
		var pages := Rect2(
			body.position.x + body.size.x * 0.5, body.position.y + 5.0,
			body.size.x * 0.5 + PAGE_LIP, body.size.y - 10.0
		)
		_rounded(pages, PAPER, true, 0.0, 4.0)
		for i in PAGE_LINES:
			var x := pages.end.x - 2.0 - float(i) * (PAGE_LIP / float(PAGE_LINES))
			var pad := 6.0 + float(i) * 1.5
			draw_line(
				Vector2(x, pages.position.y + pad), Vector2(x, pages.end.y - pad),
				PAPER_EDGE, 1.0
			)

	func _draw_cover(body: Rect2, face: Color) -> void:
		_rounded(body, face)
		# Not flat card: the cover darkens where it curves away at the bottom.
		var shade := face.darkened(0.22)
		draw_rect(
			Rect2(body.position.x + 2.0, body.end.y - 14.0, body.size.x - 4.0, 12.0),
			Color(shade.r, shade.g, shade.b, 0.85)
		)

	## The spine: a darker band down the closed edge, a crease where the cover
	## hinges open, and three ribs like a stitched binding.
	func _draw_spine(body: Rect2, face: Color) -> void:
		var spine := Rect2(body.position.x, body.position.y, SPINE_WIDTH, body.size.y)
		_rounded(spine, face.darkened(0.30))
		draw_rect(
			Rect2(spine.position.x, spine.position.y, 4.0, spine.size.y),
			face.darkened(0.46)
		)
		draw_line(
			Vector2(spine.end.x, spine.position.y + 3.0),
			Vector2(spine.end.x, spine.end.y - 3.0),
			face.darkened(0.50), 2.0
		)
		draw_line(
			Vector2(spine.end.x + 2.5, spine.position.y + 3.0),
			Vector2(spine.end.x + 2.5, spine.end.y - 3.0),
			face.lightened(0.28), 1.5
		)
		var rib_x := spine.position.x + 5.0
		var rib_width := SPINE_WIDTH - 9.0
		for i in 3:
			var y := spine.position.y + spine.size.y * (0.16 + float(i) * 0.34)
			draw_rect(Rect2(rib_x, y, rib_width, 4.0), Color(1.0, 0.960784, 0.878431, 0.32))

	## A soft diagonal highlight across the top of the cover.
	func _draw_gloss(body: Rect2) -> void:
		var top := body.position.y + 2.0
		draw_colored_polygon(
			PackedVector2Array([
				Vector2(body.position.x + SPINE_WIDTH, top),
				Vector2(body.end.x - 2.0, top),
				Vector2(body.end.x - 2.0, top + body.size.y * 0.26),
				Vector2(body.position.x + SPINE_WIDTH, top + body.size.y * 0.44),
			]),
			Color(1.0, 1.0, 1.0, 0.10)
		)

	func _rounded(
		box: Rect2, color: Color, filled: bool = true, outline: float = 0.0,
		radius: float = CORNER_RADIUS
	) -> void:
		_box.set_corner_radius_all(int(radius))
		if filled:
			_box.draw_center = true
			_box.bg_color = color
			_box.set_border_width_all(0)
		else:
			_box.draw_center = false
			_box.border_color = color
			_box.set_border_width_all(int(maxf(outline, 1.0)))
		draw_style_box(_box, box)


var _body: Control
var _art: BookArt
var _cover: TextureRect
var _cover_frame: PanelContainer
var _title: Label
var _subtitle: Label
var _book: BookDef
var _cover_color: Color = COVER_COLORS[0]
var _tilt_sign := 1.0
var _tween: Tween


func _init() -> void:
	custom_minimum_size = DEFAULT_SIZE
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	# The book tips out of its box on hover; clipping would slice the lift off.
	clip_contents = false
	_strip_button_styles()
	_build()


func _ready() -> void:
	mouse_entered.connect(_on_hover_changed.bind(true))
	mouse_exited.connect(_on_hover_changed.bind(false))
	button_down.connect(_on_press_changed.bind(true))
	button_up.connect(_on_press_changed.bind(false))


## The [Button] is the input surface only -- every visible pixel comes from
## [code]BookArt[/code]. Left alone, the default theme would draw a grey panel
## behind the book.
func _strip_button_styles() -> void:
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())


func _build() -> void:
	_body = Control.new()
	_body.name = "Body"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Tips about the point where the book meets the plank, so the lift reads as
	# the book being pulled off the shelf rather than floating away from it.
	_body.resized.connect(_recentre_pivot)
	add_child(_body)

	_art = BookArt.new()
	_art.name = "Art"
	_body.add_child(_art)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Inside the cover: clear of the spine on the left and of the page lip on the
	# right, so nothing printed on the cover runs over the binding.
	margin.add_theme_constant_override(
		"margin_left", int(BookArt.EDGE_INSET + BookArt.SPINE_WIDTH + 9.0)
	)
	margin.add_theme_constant_override("margin_right", int(BookArt.PAGE_LIP + 13.0))
	margin.add_theme_constant_override("margin_top", int(BookArt.TOP_INSET + 12.0))
	margin.add_theme_constant_override("margin_bottom", 20)
	_body.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	# The art plate: page art is dark lines on white and would vanish against a
	# saturated cover, so it sits on its own sheet of paper, framed.
	_cover_frame = PanelContainer.new()
	_cover_frame.name = "CoverFrame"
	_cover_frame.custom_minimum_size = Vector2(0.0, COVER_HEIGHT)
	_cover_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_cover_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_cover_frame)

	_cover = TextureRect.new()
	_cover.name = "Cover"
	_cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cover_frame.add_child(_cover)

	_title = Label.new()
	_title.name = "Title"
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.max_lines_visible = 2
	_title.add_theme_font_size_override("font_size", 23)
	_title.add_theme_color_override("font_color", TITLE_INK)
	_title.add_theme_constant_override("outline_size", TITLE_OUTLINE_SIZE)
	column.add_child(_title)

	# The page count as a little sticker slapped on the cover.
	var sticker := PanelContainer.new()
	sticker.name = "Sticker"
	sticker.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	sticker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sticker_style := StyleBoxFlat.new()
	sticker_style.bg_color = STICKER_PAPER
	sticker_style.set_corner_radius_all(11)
	sticker_style.content_margin_left = 12.0
	sticker_style.content_margin_right = 12.0
	sticker_style.content_margin_top = 2.0
	sticker_style.content_margin_bottom = 3.0
	sticker.add_theme_stylebox_override("panel", sticker_style)
	column.add_child(sticker)

	_subtitle = Label.new()
	_subtitle.name = "Subtitle"
	_subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 17)
	_subtitle.add_theme_color_override("font_color", STICKER_INK)
	sticker.add_child(_subtitle)

	_apply_cover_color(_cover_color)


func _recentre_pivot() -> void:
	if is_instance_valid(_body):
		_body.pivot_offset = Vector2(_body.size.x * 0.5, _body.size.y)


# ====================================================================== data ==

## Fills the book from [param book]. Passing null blanks it.
func set_book(book: BookDef) -> void:
	_book = book
	if book == null:
		_cover.texture = null
		_title.text = ""
		_subtitle.text = ""
		tooltip_text = ""
		_apply_cover_color(COVER_COLORS[0])
		return
	_cover.texture = book.get_cover_texture()
	_title.text = book.display_name
	var count := book.page_count()
	_subtitle.text = "%d page%s" % [count, "" if count == 1 else "s"]
	tooltip_text = "%s — %s" % [book.display_name, _subtitle.text]
	_apply_cover_color(cover_color_for(book))
	# Books lean alternate ways when picked up, so a shelf of them is not a rank
	# of identical tilts. Derived from the uid: stable, not random.
	_tilt_sign = 1.0 if absi(book.get_uid().hash()) % 2 == 0 else -1.0


func get_book() -> BookDef:
	return _book


func get_title_text() -> String:
	return _title.text


func get_subtitle_text() -> String:
	return _subtitle.text


func has_cover() -> bool:
	return _cover.texture != null


## The cover colour this book ended up with. Public so a harness can assert the
## shelf is varied instead of eyeballing a screenshot.
func get_cover_color() -> Color:
	return _cover_color


## Which cover colour [param book] gets: its stable uid, hashed into
## [constant COVER_COLORS]. Deterministic, so a book looks the same every run and
## in every screenshot, and it needs nothing new in the authored data.
static func cover_color_for(book: BookDef) -> Color:
	if book == null:
		return COVER_COLORS[0]
	return COVER_COLORS[absi(book.get_uid().hash()) % COVER_COLORS.size()]


func _apply_cover_color(color: Color) -> void:
	_cover_color = color
	_art.cover = color
	_art.queue_redraw()
	# The art plate is framed in a lighter tint of the cover, so the frame belongs
	# to the book rather than sitting on it.
	var plate := StyleBoxFlat.new()
	plate.bg_color = BookArt.PAPER
	plate.border_color = color.lightened(0.42)
	plate.set_border_width_all(3)
	plate.set_corner_radius_all(7)
	plate.set_content_margin_all(5.0)
	plate.shadow_color = Color(0.121569, 0.058824, 0.019608, 0.30)
	plate.shadow_size = 4
	plate.shadow_offset = Vector2(0.0, 2.0)
	_cover_frame.add_theme_stylebox_override("panel", plate)
	_title.add_theme_color_override("font_outline_color", color.darkened(0.62))


# ================================================================== response ==

func _on_hover_changed(inside: bool) -> void:
	_art.warm = inside
	_art.queue_redraw()
	# Drawn in front of its neighbours while it is out of the shelf. z_index is
	# draw order only -- reordering the child would move it to another grid cell.
	z_index = 1 if inside else 0
	if is_pressed():
		return
	_settle(inside)


func _on_press_changed(down: bool) -> void:
	if down:
		_animate(PRESS_SINK, 0.0, PRESS_SCALE, PRESS_SECONDS)
	else:
		_settle(is_hovered())


func _settle(lifted: bool) -> void:
	if lifted:
		_animate(
			-HOVER_LIFT, deg_to_rad(HOVER_TILT_DEGREES) * _tilt_sign,
			HOVER_SCALE, HOVER_SECONDS
		)
	else:
		_animate(0.0, 0.0, 1.0, HOVER_SECONDS)


## Moves the BODY, never this node: the cell's rect is what the shelf lays out and
## what the harnesses measure, and it has to stay exactly where it was put.
func _animate(lift: float, tilt: float, scale_factor: float, seconds: float) -> void:
	if not is_instance_valid(_body):
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if not is_inside_tree():
		_body.position.y = lift
		_body.rotation = tilt
		_body.scale = Vector2(scale_factor, scale_factor)
		return
	_recentre_pivot()
	_tween = create_tween().set_parallel(true)
	_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_body, "position:y", lift, seconds)
	_tween.tween_property(_body, "rotation", tilt, seconds)
	_tween.tween_property(_body, "scale", Vector2(scale_factor, scale_factor), seconds)

class_name TitleScreen
extends Control
## The splash the app opens on (DESIGN.md 2): the book's title on a sheet of
## paper, crayons resting along the bottom edge, and "tap anywhere to start".
##
## One-shot: it reports [signal start_requested] and nothing else. The parent
## ([code]main.tscn[/code]) decides that this means "go to mode select" -- this
## screen never swaps itself (godot-practices: signals up, calls down).
##
## [b]No art assets[/b]. Everything is drawn from primitives, the same way
## [CrayonButton] and [BookCell] are, so the shell ships no PNGs of its own and
## the look follows the palette resources: the title letters and the scribble take
## their colours from [code]child_palette.tres[/code], and the crayons along the
## bottom are literal [CrayonButton]s (disabled, input-transparent) so the title
## screen and the in-game palette can never drift apart.
##
## [b]The tap target[/b] is a full-rect flat [Button] behind the artwork, not an
## [code]_input[/code] handler: [BaseButton] is the project's one path for both
## mouse and touch (DESIGN.md 3.3), and it gives tests a real
## [signal BaseButton.pressed] to emit.

## The player wants to start.
signal start_requested()

## Title text, one entry per line.
const TITLE_LINES: PackedStringArray = ["Coloring", "Book"]
## Per-letter tilt, alternating, so the word looks hand-lettered.
const LETTER_TILT_DEGREES := 5.0
## Crayons laid along the bottom of the screen.
const CRAYON_COUNT := 7
## Angle between neighbouring crayons on the shelf.
const CRAYON_FAN_DEGREES := 6.0
## Palette indices used for the lettering: the bold, high-contrast half of the
## crayon box (the pale yellow would disappear against the paper).
const TITLE_COLOR_INDICES: PackedInt32Array = [0, 1, 3, 4, 5, 6, 7, 8]
## Seconds for one full fade cycle of the "tap to start" hint.
const HINT_PULSE_SECONDS := 1.7

## [b]Portrait (M6)[/b]. The sheet of paper used to carry a hard
## [code]custom_minimum_size.x = 820[/code], which simply did not fit a 720-wide
## phone: the [CenterContainer] handed the paper its minimum size and the
## lettering ran off both edges. The width is now driven by the screen -- capped
## at [constant PAPER_MAX_WIDTH] so it still reads as a sheet on a desktop
## monitor, and never wider than the screen minus [constant PAPER_SIDE_MARGIN].
## The letters shrink with it, because a 96 pt "Coloring" is 8 glyphs wide and no
## amount of container maths makes that fit across 672 px.
const PAPER_MAX_WIDTH := 820.0
const PAPER_SIDE_MARGIN := 48.0
## Screen width at or above which the title keeps its full-size lettering.
const WIDE_SCREEN_WIDTH := 900.0
const TITLE_FONT_SIZE := 96
const TITLE_FONT_SIZE_NARROW := 62
## Paper height, likewise trimmed when the lettering shrinks.
const PAPER_HEIGHT := 452.0
const PAPER_HEIGHT_NARROW := 344.0

## Ink the lettering is outlined with, so every crayon colour reads on paper.
const INK := Color(0.176471, 0.129412, 0.09)


## A [Label] that keeps its rotation pivot at its own centre, so a tilted letter
## turns in place instead of swinging away from its neighbours.
##
## The tilt is re-applied DEFERRED because [method Container.fit_child_in_rect]
## resets a managed child's rotation to zero on every layout pass -- setting it
## once in the builder would be silently undone by the [HBoxContainer].
class TiltedLabel extends Label:
	var tilt := 0.0

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			pivot_offset = size * 0.5
			set_deferred("rotation", tilt)


## The crayon underline beneath the title: three overlapping wax strokes with a
## deterministic wobble, drawn in palette colours.
class Scribble extends Control:
	const LANES := 3
	const STEPS := 30
	## Fixed so the "hand-drawn" line is identical in every screenshot.
	const WOBBLE_SEED := 20250805

	var colors: PackedColorArray

	func _init(palette_colors: PackedColorArray) -> void:
		colors = palette_colors
		custom_minimum_size = Vector2(0.0, 66.0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		if size.x <= 8.0 or colors.is_empty():
			return
		var rng := RandomNumberGenerator.new()
		rng.seed = WOBBLE_SEED
		for lane in LANES:
			var span := size.x * (0.88 - float(lane) * 0.15)
			var start := (size.x - span) * 0.5
			var lane_y := size.y * (0.30 + float(lane) * 0.21)
			var points := PackedVector2Array()
			for i in STEPS + 1:
				var t := float(i) / float(STEPS)
				var wobble := sin(t * PI * (2.0 + float(lane))) * (5.0 + float(lane) * 2.0)
				points.append(
					Vector2(start + span * t, lane_y + wobble + rng.randf_range(-1.4, 1.4))
				)
			draw_polyline(points, colors[lane % colors.size()], 10.0 - float(lane) * 2.0, true)


@onready var _tap_target: Button = $TapTarget
@onready var _paper: PanelContainer = $Center/Paper
@onready var _column: VBoxContainer = $Center/Paper/Margin/Column
@onready var _title_rows: VBoxContainer = $Center/Paper/Margin/Column/TitleRows
@onready var _hint: Label = $Center/Paper/Margin/Column/TapHint
@onready var _crayon_row: Control = $Crayons

var _palette: PaletteDef
## Font size the lettering was last built at, so a resize only rebuilds when the
## size actually changes rather than on every pixel of a window drag.
var _title_font_size := 0


func _ready() -> void:
	_palette = GameState.get_palette_for_mode(GameState.MODE_CHILD)
	_tap_target.pressed.connect(_on_tap_pressed)
	_crayon_row.resized.connect(_layout_crayons)
	resized.connect(_apply_responsive_layout)
	_apply_responsive_layout()
	_build_scribble()
	_build_crayons()
	_pulse_hint()


# ================================================================= responsive ==

## Sizes the paper and the lettering to the screen (see the PAPER_* constants).
## Rebuilds the title only when the font size really changed.
func _apply_responsive_layout() -> void:
	if not is_instance_valid(_paper):
		return
	var narrow := size.x < WIDE_SCREEN_WIDTH
	_paper.custom_minimum_size = Vector2(
		clampf(size.x - PAPER_SIDE_MARGIN, 0.0, PAPER_MAX_WIDTH),
		PAPER_HEIGHT_NARROW if narrow else PAPER_HEIGHT
	)
	var font_size := TITLE_FONT_SIZE_NARROW if narrow else TITLE_FONT_SIZE
	if font_size != _title_font_size:
		_title_font_size = font_size
		_build_title()


## True while the screen is laid out for a narrow (portrait) window.
func is_narrow() -> bool:
	return _title_font_size == TITLE_FONT_SIZE_NARROW


# ===================================================================== build ==

func _build_title() -> void:
	for child in _title_rows.get_children():
		_title_rows.remove_child(child)
		child.queue_free()
	var letter_index := 0
	for line in TITLE_LINES:
		var row := HBoxContainer.new()
		row.name = "Line_%s" % line
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 0)
		_title_rows.add_child(row)
		for i in line.length():
			row.add_child(_make_letter(line[i], letter_index))
			letter_index += 1


func _make_letter(character: String, index: int) -> Label:
	var label := TiltedLabel.new()
	label.text = character
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", _title_font_size)
	label.add_theme_color_override("font_color", _title_color(index))
	label.add_theme_color_override("font_outline_color", INK)
	label.add_theme_constant_override("outline_size", maxi(_title_font_size / 8, 6))
	# Alternating tilt, so the word looks written by hand rather than typeset.
	var direction := 1.0 if index % 2 == 0 else -1.0
	label.tilt = deg_to_rad(LETTER_TILT_DEGREES * direction)
	label.rotation = label.tilt
	return label


func _title_color(index: int) -> Color:
	if _palette == null or _palette.color_count() == 0:
		return Color.WHITE
	return _palette.get_color(TITLE_COLOR_INDICES[index % TITLE_COLOR_INDICES.size()])


func _build_scribble() -> void:
	var colors := PackedColorArray()
	for i in TITLE_COLOR_INDICES.size():
		colors.append(_title_color(i))
	var scribble := Scribble.new(colors)
	scribble.name = "Scribble"
	_column.add_child(scribble)
	# Between the lettering and the "tap to start" hint.
	_column.move_child(scribble, _hint.get_index())


## The crayon shelf is a PLAIN [Control], laid out by hand: a [Container] would
## reset every crayon's rotation on each pass and the fan would collapse into a
## flat row.
func _build_crayons() -> void:
	for child in _crayon_row.get_children():
		_crayon_row.remove_child(child)
		child.queue_free()
	if _palette == null:
		return
	# Spread across the palette rather than taking the first N, so the shelf shows
	# the whole crayon box.
	var stride := maxi(_palette.color_count() / maxi(CRAYON_COUNT, 1), 1)
	for i in CRAYON_COUNT:
		var crayon := CrayonButton.new()
		crayon.name = "Crayon%d" % i
		crayon.crayon_color = _palette.get_color((i * stride) % _palette.color_count())
		crayon.disabled = true
		crayon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_crayon_row.add_child(crayon)
	_layout_crayons()


## Evenly spaced, fanned about each crayon's own base so the bottoms stay on the
## shelf line while the tips spread.
func _layout_crayons() -> void:
	var count := _crayon_row.get_child_count()
	if count == 0 or _crayon_row.size.x <= 0.0:
		return
	var box := CrayonButton.DEFAULT_SIZE
	var gap := 14.0
	var start := (_crayon_row.size.x - (box.x * count + gap * float(count - 1))) * 0.5
	for i in count:
		var crayon := _crayon_row.get_child(i) as Control
		crayon.size = box
		crayon.position = Vector2(start + float(i) * (box.x + gap), _crayon_row.size.y - box.y)
		crayon.pivot_offset = Vector2(box.x * 0.5, box.y)
		crayon.rotation = deg_to_rad((float(i) - float(count - 1) * 0.5) * CRAYON_FAN_DEGREES)


func _pulse_hint() -> void:
	var tween := create_tween().set_loops()
	tween.tween_property(_hint, "modulate:a", 0.35, HINT_PULSE_SECONDS * 0.5)
	tween.tween_property(_hint, "modulate:a", 1.0, HINT_PULSE_SECONDS * 0.5)


# ==================================================================== access ==

## The full-screen tap surface. Tests emit its [signal BaseButton.pressed].
func get_tap_button() -> Button:
	return _tap_target


## Number of crayons actually laid out (the shelf of the title screen).
func get_crayon_count() -> int:
	return _crayon_row.get_child_count()


func get_title_text() -> String:
	return " ".join(TITLE_LINES)


func _on_tap_pressed() -> void:
	start_requested.emit()

class_name TitleScreen
extends Control
## The splash the app opens on (DESIGN.md 2): the book's title on a sheet of
## paper, with crayons fanning onto the shelf along the bottom edge.
##
## One-shot: it reports [signal start_requested] and nothing else. The parent
## ([code]main.tscn[/code]) decides that this means "go to the shelf" -- this
## screen never swaps itself (godot-practices: signals up, calls down).
##
## [b]BL-27: the splash is not a door.[/b] It used to sit on "tap anywhere to
## start", which is a gate with nothing behind it -- the tap added a step, not a
## choice. Now the screen plays a short joyful beat and then emits
## [signal start_requested] BY ITSELF ([constant INTRO_SECONDS] after it is shown):
##
## [codeblock]
## 0.00  the paper springs up from 84%
## 0.20  the title letters pop in one by one, unwinding a little twist as they land
## 0.30  the crayons slide up onto the shelf, centre first, and fan open
## 1.02  the scribble draws itself, lane by lane, like a hand going over its line
## 1.32  the send-off ("let's color!") fades in
## 1.95  start_requested
## [/codeblock]
##
## A tap anywhere still works, and now means "skip" ([method skip_intro]): it
## snaps the beat to its finished frame and emits immediately, so an impatient
## child is never held by an animation. Either way the signal fires exactly once.
##
## [b]The beat is a pure function of one clock[/b] ([member _intro_clock], advanced
## in [method _process]) rather than a pile of tweens. That is not tidiness for its
## own sake: [method _apply_responsive_layout] REBUILDS the lettering whenever the
## font size changes, which is all but guaranteed to happen on the first layout
## pass, and a tween holding a freed [Label] is either a crash or a letter stuck at
## the wrong size. Re-applying "where should this be at t?" to whatever nodes exist
## right now survives any rebuild, and makes [method skip_intro] a one-liner.
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

## The player wants to start -- emitted when the intro beat ends, or as soon as
## the screen is tapped. Fires exactly once per screen.
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

# ------------------------------------------------------------- the intro beat --
# One clock, in seconds. Every _AT is when a part of the picture starts moving and
# every other constant is how long it takes; INTRO_SECONDS is the whole beat,
# including a short hold on the finished frame so the last thing a child sees is
# the picture, not a part of it still arriving.

## Total length of the opening beat, after which [signal start_requested] fires.
const INTRO_SECONDS := 1.95
## The sheet of paper springs up to size.
const INTRO_PAPER_IN := 0.42
const PAPER_IN_SCALE := 0.84
## The lettering, one glyph at a time.
const INTRO_LETTERS_AT := 0.20
const INTRO_LETTER_STAGGER := 0.055
const INTRO_LETTER_POP := 0.30
const LETTER_IN_SCALE := 0.25
## Extra twist (radians) a letter unwinds as it lands, on top of its resting tilt.
const LETTER_IN_SPIN := 0.55
## The crayons slide up onto the shelf, middle one first, and fan open as they go.
const INTRO_CRAYONS_AT := 0.30
const INTRO_CRAYON_STAGGER := 0.06
const INTRO_CRAYON_RISE := 0.44
## How far below its resting spot a crayon starts, past its own length so it comes
## up from off the bottom of the screen rather than sliding out of the paper.
const CRAYON_RISE_CLEARANCE := 48.0
## The wax underline draws itself.
const INTRO_SCRIBBLE_AT := 1.02
const INTRO_SCRIBBLE_DRAW := 0.46
## The send-off line.
const INTRO_HINT_AT := 1.32
const INTRO_HINT_FADE := 0.28
## Overshoot of the spring used by every "pops into place" easing here. Higher than
## the classic 1.70158 because this is a splash for four-year-olds.
const BACK_OVERSHOOT := 1.9

## [b]Dev-harness hook[/b], the same idea as [member Main.quit_on_close_request]:
## with this false the splash builds itself in its FINISHED frame and never emits
## [signal start_requested] on its own, so a harness can hold the title up, take a
## stable screenshot of it and drive the tap itself. The shipped game never touches
## it. Static because the harness has to make the decision BEFORE [Main] exists --
## main.tscn instantiates the title screen inside its own [method Node._ready].
static var autostart_enabled := true


## A [Label] that keeps its rotation pivot at its own centre, so a tilted letter
## turns in place instead of swinging away from its neighbours, and that carries
## its own share of the intro beat ([method set_pop]).
##
## The transform is re-applied DEFERRED because [method Container.fit_child_in_rect]
## resets a managed child's rotation AND scale on every layout pass -- setting
## either one straight would be silently undone by the [HBoxContainer].
class TiltedLabel extends Label:
	var tilt := 0.0
	## 1 = settled. Below 1 during the pop; overshoots just past 1 as it lands.
	var pop := 1.0
	## Extra rotation the letter is still unwinding, in radians.
	var spin := 0.0

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			_apply()

	## Where this letter is at this instant of the intro.
	func set_pop(scale_value: float, alpha: float, twist: float) -> void:
		pop = scale_value
		spin = twist
		modulate.a = alpha
		_apply()

	func _apply() -> void:
		pivot_offset = size * 0.5
		set_deferred("rotation", tilt + spin)
		set_deferred("scale", Vector2(pop, pop))


## The crayon underline beneath the title: three overlapping wax strokes with a
## deterministic wobble, drawn in palette colours.
##
## [b]BL-27[/b]: it draws itself. [member draw_fraction] trims each lane's polyline
## to a fraction of its length -- points are always GENERATED in full (the wobble
## RNG has to advance identically every frame or the line would shiver), then cut,
## with the last point interpolated so the stroke grows smoothly instead of
## stepping. The lanes are staggered so it reads as a hand going back over its own
## line rather than three lines appearing at once.
class Scribble extends Control:
	const LANES := 3
	const STEPS := 30
	## Fixed so the "hand-drawn" line is identical in every screenshot.
	const WOBBLE_SEED := 20250805
	## How much of a head start each lane has on the one below it.
	const LANE_LEAD := 0.18

	var colors: PackedColorArray
	var draw_fraction := 1.0

	func _init(palette_colors: PackedColorArray) -> void:
		colors = palette_colors
		custom_minimum_size = Vector2(0.0, 66.0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func set_draw_fraction(value: float) -> void:
		var clamped := clampf(value, 0.0, 1.0)
		if is_equal_approx(clamped, draw_fraction):
			return
		draw_fraction = clamped
		queue_redraw()

	func _draw() -> void:
		if size.x <= 8.0 or colors.is_empty() or draw_fraction <= 0.0:
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
			var drawn := _trim(points, _lane_fraction(lane))
			if drawn.size() >= 2:
				draw_polyline(drawn, colors[lane % colors.size()], 10.0 - float(lane) * 2.0, true)

	## Lane 0 is already down by the time the last lane starts moving.
	func _lane_fraction(lane: int) -> float:
		var spread := LANE_LEAD * float(LANES - 1)
		return clampf(draw_fraction * (1.0 + spread) - LANE_LEAD * float(lane), 0.0, 1.0)

	static func _trim(points: PackedVector2Array, fraction: float) -> PackedVector2Array:
		if fraction >= 1.0:
			return points
		if fraction <= 0.0 or points.size() < 2:
			return PackedVector2Array()
		var along := float(points.size() - 1) * fraction
		var whole := int(floor(along))
		var cut := points.slice(0, whole + 1)
		if whole < points.size() - 1:
			cut.append(points[whole].lerp(points[whole + 1], along - float(whole)))
		return cut


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

var _scribble: Scribble
## The letters, in reading order -- the order they pop in.
var _letters: Array[TiltedLabel] = []
## Where [method _layout_crayons] parked each crayon, before the intro offsets it.
var _crayon_home := PackedVector2Array()
var _crayon_angle := PackedFloat32Array()
var _crayon_rise := 0.0

## Seconds into the opening beat.
var _intro_clock := 0.0
var _intro_running := false
## [signal start_requested] has already gone out; it never goes out twice.
var _started := false


func _ready() -> void:
	_palette = GameState.get_active_palette()
	_tap_target.pressed.connect(_on_tap_pressed)
	_crayon_row.resized.connect(_layout_crayons)
	resized.connect(_apply_responsive_layout)
	_apply_responsive_layout()
	_build_scribble()
	_build_crayons()
	_begin_intro()


func _process(delta: float) -> void:
	if not _intro_running:
		return
	_intro_clock += delta
	if _intro_clock >= INTRO_SECONDS:
		# Lands on the finished frame and reports up -- the whole point of BL-27.
		_finish_intro()
		return
	_apply_intro(_intro_clock)


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
	_letters.clear()
	var letter_index := 0
	for line in TITLE_LINES:
		var row := HBoxContainer.new()
		row.name = "Line_%s" % line
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 0)
		_title_rows.add_child(row)
		for i in line.length():
			var label := _make_letter(line[i], letter_index)
			row.add_child(label)
			_letters.append(label)
			letter_index += 1
	# A rebuild can land in the middle of the beat (the first layout pass usually
	# does): put the fresh letters wherever the clock says they should be.
	_apply_letters(_intro_clock)


func _make_letter(character: String, index: int) -> TiltedLabel:
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
	_scribble = Scribble.new(colors)
	_scribble.name = "Scribble"
	_column.add_child(_scribble)
	# Between the lettering and the send-off line.
	_column.move_child(_scribble, _hint.get_index())


## The crayon shelf is a PLAIN [Control], laid out by hand: a [Container] would
## reset every crayon's rotation on each pass and the fan would collapse into a
## flat row. That is also what makes the crayons the one part of the intro that can
## be animated straight, without [method Object.set_deferred].
func _build_crayons() -> void:
	for child in _crayon_row.get_children():
		_crayon_row.remove_child(child)
		child.queue_free()
	_crayon_home.clear()
	_crayon_angle.clear()
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
## shelf line while the tips spread. The resting transform is REMEMBERED
## ([member _crayon_home] / [member _crayon_angle]) because the intro offsets it
## and a resize can recompute it mid-beat.
func _layout_crayons() -> void:
	var count := _crayon_row.get_child_count()
	if count == 0 or _crayon_row.size.x <= 0.0:
		return
	var box := CrayonButton.DEFAULT_SIZE
	var gap := 14.0
	var start := (_crayon_row.size.x - (box.x * count + gap * float(count - 1))) * 0.5
	_crayon_home.resize(count)
	_crayon_angle.resize(count)
	_crayon_rise = box.y + CRAYON_RISE_CLEARANCE
	for i in count:
		var crayon := _crayon_row.get_child(i) as Control
		crayon.size = box
		crayon.pivot_offset = Vector2(box.x * 0.5, box.y)
		_crayon_home[i] = Vector2(
			start + float(i) * (box.x + gap), _crayon_row.size.y - box.y
		)
		_crayon_angle[i] = deg_to_rad((float(i) - float(count - 1) * 0.5) * CRAYON_FAN_DEGREES)
	_apply_crayons(_intro_clock)


# ================================================================= the intro ==

## Starts the opening beat -- or, for a harness that turned
## [member autostart_enabled] off, skips straight to its finished frame without
## reporting anything.
func _begin_intro() -> void:
	if not autostart_enabled:
		_intro_clock = INTRO_SECONDS
		_intro_running = false
		set_process(false)
		_apply_intro(INTRO_SECONDS)
		return
	_intro_clock = 0.0
	_intro_running = true
	_apply_intro(0.0)
	set_process(true)


## Snaps the beat to its last frame and reports up immediately. This is what a tap
## does; it is safe to call at any time and does nothing after the first call.
func skip_intro() -> void:
	_finish_intro()


## True while the opening beat is still playing.
func is_intro_playing() -> bool:
	return _intro_running


func _finish_intro() -> void:
	_intro_running = false
	set_process(false)
	_intro_clock = INTRO_SECONDS
	_apply_intro(INTRO_SECONDS)
	if _started:
		return
	_started = true
	start_requested.emit()


## The whole picture as a function of one number: seconds since the beat started.
func _apply_intro(t: float) -> void:
	_apply_paper(t)
	_apply_letters(t)
	_apply_crayons(t)
	if is_instance_valid(_scribble):
		_scribble.set_draw_fraction((t - INTRO_SCRIBBLE_AT) / INTRO_SCRIBBLE_DRAW)
	if is_instance_valid(_hint):
		_hint.modulate.a = clampf((t - INTRO_HINT_AT) / INTRO_HINT_FADE, 0.0, 1.0)


func _apply_paper(t: float) -> void:
	if not is_instance_valid(_paper):
		return
	var raw := clampf(t / INTRO_PAPER_IN, 0.0, 1.0)
	_paper.pivot_offset = _paper.size * 0.5
	# Deferred for the same reason TiltedLabel defers: the CenterContainer resets a
	# managed child's scale on every sort, and a sort is queued for this very frame.
	_paper.set_deferred("scale", Vector2.ONE * lerpf(PAPER_IN_SCALE, 1.0, _spring(raw)))
	_paper.modulate.a = clampf(raw * 2.2, 0.0, 1.0)


func _apply_letters(t: float) -> void:
	for i in _letters.size():
		var label := _letters[i]
		if not is_instance_valid(label):
			continue
		var raw := clampf(
			(t - INTRO_LETTERS_AT - float(i) * INTRO_LETTER_STAGGER) / INTRO_LETTER_POP,
			0.0,
			1.0
		)
		var left := 1.0 - raw
		label.set_pop(
			lerpf(LETTER_IN_SCALE, 1.0, _spring(raw)),
			clampf(raw * 3.0, 0.0, 1.0),
			# Unwinds fastest at the start, so the letter is already nearly straight
			# by the time it stops growing.
			left * left * signf(label.tilt) * LETTER_IN_SPIN
		)


func _apply_crayons(t: float) -> void:
	var count := _crayon_row.get_child_count() if is_instance_valid(_crayon_row) else 0
	if count == 0 or _crayon_home.size() != count:
		return
	var middle := float(count - 1) * 0.5
	for i in count:
		var crayon := _crayon_row.get_child(i) as Control
		# Middle crayon first, then outwards: the fan opens from the centre.
		var order := absf(float(i) - middle)
		var raw := clampf(
			(t - INTRO_CRAYONS_AT - order * INTRO_CRAYON_STAGGER) / INTRO_CRAYON_RISE, 0.0, 1.0
		)
		var eased := _spring(raw)
		crayon.position = _crayon_home[i] + Vector2(0.0, (1.0 - eased) * _crayon_rise)
		# The fan is closed while they are still off screen and spreads as they land.
		crayon.rotation = _crayon_angle[i] * eased
		crayon.modulate.a = clampf(raw * 3.0, 0.0, 1.0)


## Ease-out-back: overshoots the target and settles back onto it. Everything in the
## beat that "pops" uses this one curve, so the whole splash moves as one hand.
static func _spring(x: float) -> float:
	var u := clampf(x, 0.0, 1.0) - 1.0
	return 1.0 + (BACK_OVERSHOOT + 1.0) * u * u * u + BACK_OVERSHOOT * u * u


# ==================================================================== access ==

## The full-screen tap surface. Tests emit its [signal BaseButton.pressed]; in the
## game a tap means "skip the intro", not "start" -- the start happens either way.
func get_tap_button() -> Button:
	return _tap_target


## Number of crayons actually laid out (the shelf of the title screen).
func get_crayon_count() -> int:
	return _crayon_row.get_child_count()


func get_title_text() -> String:
	return " ".join(TITLE_LINES)


func _on_tap_pressed() -> void:
	skip_intro()

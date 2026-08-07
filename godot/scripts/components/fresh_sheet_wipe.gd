class_name FreshSheetWipe
extends Control
## Start over, as a sheet of clean paper sliding over the page (BL-29).
##
## BL-7 made "Start over" correct -- the paint layer, the tracker, the saved PNG
## and the saved status all go back to blank -- but it happened in one frame, so
## the picture simply vanished. This is the ceremony that was missing: a fresh
## sheet sweeps in from the left with a shadow running ahead of its leading edge,
## the page flashes white as it lands, and the sheet fades away leaving the empty
## page underneath. About two thirds of a second, over the page area only.
##
## [b]It is pure presentation and it blocks nothing.[/b]
## [constant Control.MOUSE_FILTER_IGNORE], no input handling, and it frees itself
## when it is done; the clear it covers has already happened underneath it. Nothing
## waits for this and nothing reads it -- a player who starts painting again mid-
## sweep paints on the real (already cleared) page.
##
## Host it on a plain [Control] overlay, never a container (see [SparkleBurst]),
## and reach it through a preload rather than its global class name -- same reason
## [SparkleBurst] does: a class_name added today is invisible to a CLI run until the
## project is re-imported.
const SELF := preload("res://scripts/components/fresh_sheet_wipe.gd")

const DEFAULT_SECONDS := 0.72
## Fraction of the run the sheet spends sliding in, and where the hold ends. What
## is left is the fade that reveals the blank page.
const SLIDE_END := 0.34
const HOLD_END := 0.48
## Corner radius of the sheet, so it reads as paper rather than a screen wipe.
const CORNER := 14

const PAPER := Color(0.984314, 0.964706, 0.917647)
## The bright rim on the sheet's leading edge, and the shadow it casts ahead.
const EDGE := Color(1.0, 1.0, 1.0, 0.85)
const EDGE_WIDTH := 3.0
const SHADE := Color(0.086275, 0.070588, 0.058824, 0.32)
const SHADE_WIDTH := 26.0
## The settle flash, at its brightest the moment the sheet finishes landing.
const FLASH := Color(1.0, 1.0, 1.0, 0.42)
const FLASH_PEAK := 0.9

var _time := 0.0
var _seconds := DEFAULT_SECONDS
var _paper := StyleBoxFlat.new()


## Plays a wipe over [param rect] (in [param host]'s local coordinates). Returns
## the node, which owns its own lifetime -- callers may ignore it.
static func play(host: Control, rect: Rect2, seconds: float = DEFAULT_SECONDS) -> Control:
	if host == null or not is_instance_valid(host) or not host.is_inside_tree():
		return null
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return null
	var node := SELF.new()
	node._seconds = maxf(seconds, 0.1)
	node.position = rect.position
	node.size = rect.size
	host.add_child(node)
	return node


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The sheet starts a full page-width off to the left and its shadow band runs
	# ahead of the edge, so both would paint outside the page area on their way
	# through. Clipping keeps the whole effect inside the rect it was given.
	clip_contents = true
	# Depth is tree order (see [SparkleBurst]): over the page and its celebration,
	# under the confirm overlay and the flip. A caller that wants sparks ON the sheet
	# simply adds them after it.
	_paper.bg_color = Color(PAPER.r, PAPER.g, PAPER.b, 1.0)
	_paper.set_corner_radius_all(CORNER)
	set_process(true)


func _process(delta: float) -> void:
	_time += delta
	if _time >= _seconds:
		queue_free()
		return
	modulate.a = _sheet_alpha(_time / _seconds)
	queue_redraw()


## True while the sweep is still on screen. Nothing in the game reads this; it is
## here so a harness can wait the effect out instead of guessing at frames.
func is_playing() -> bool:
	return _time < _seconds


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var progress := _time / _seconds
	var left := _sheet_left(progress)
	var sheet := Rect2(Vector2(left, 0.0), size)
	_paper.draw(get_canvas_item(), sheet)

	# While the sheet is still travelling, sell the movement: a soft shadow on the
	# page ahead of the edge, and a bright rim on the edge itself.
	var edge_x := left + size.x
	if progress < SLIDE_END and edge_x < size.x:
		draw_rect(Rect2(Vector2(edge_x, 0.0), Vector2(SHADE_WIDTH, size.y)), SHADE, true)
		draw_rect(Rect2(Vector2(edge_x - EDGE_WIDTH, 0.0), Vector2(EDGE_WIDTH, size.y)), EDGE, true)

	# The settle: a white bloom that peaks as the sheet lands and is gone shortly
	# after, which is what makes the clear feel like a NEW page rather than an
	# erased one.
	var flash := _flash_strength(progress)
	if flash > 0.0:
		var tint := FLASH
		tint.a *= flash
		draw_rect(Rect2(Vector2.ZERO, size), tint, true)


## Where the sheet's left edge is: off-screen left, easing to flush.
func _sheet_left(progress: float) -> float:
	if progress >= SLIDE_END:
		return 0.0
	var k := clampf(progress / SLIDE_END, 0.0, 1.0)
	# Cubic ease-out: fast entry, gentle arrival, like a hand laying paper down.
	return -size.x * pow(1.0 - k, 3.0)


func _sheet_alpha(progress: float) -> float:
	if progress <= HOLD_END:
		return 1.0
	var k := clampf((progress - HOLD_END) / maxf(1.0 - HOLD_END, 0.001), 0.0, 1.0)
	return 1.0 - k * k


## The bloom: nothing at first, building sharply as the sheet arrives, then gone.
## Both halves meet at [constant FLASH_PEAK] on purpose -- a discontinuity here is
## a visible pop on the one frame the effect is loudest.
func _flash_strength(progress: float) -> float:
	if progress < SLIDE_END:
		return pow(clampf(progress / SLIDE_END, 0.0, 1.0), 3.0) * FLASH_PEAK
	var k := clampf((progress - SLIDE_END) / 0.34, 0.0, 1.0)
	return FLASH_PEAK * (1.0 - k)

class_name PageFlip
extends Control
## The book page-turn transition (DESIGN.md 2: "PageFlip animation").
##
## Self-contained and content-blind: it is handed a "from" texture and a "to"
## texture and animates between them. It knows nothing about books, pages or the
## coloring screen -- the parent snapshots whatever it wants turned away.
##
## [b]The look (BL-4)[/b]: a real page turn, done in one fragment shader
## ([code]page_curl.gdshader[/code], which carries the geometry in its header).
## The sheet is grabbed at its free edge and peeled toward the spine along a
## LEANING fold line: a lit crease rolls across the page, the paper folds back
## over itself showing its reverse with the printed side faintly bleeding through,
## and a soft shadow travels ahead of the fold onto whatever is revealed
## underneath. M4-M6 shipped a scale/rotate/darken fake of this; it read as a
## slide, which is what BL-4 was raised about.
##
## [b]Why a shader and not a mesh[/b]: one full-screen quad, two texture fetches
## at worst, no render target and no second pass -- the same cost as the old
## TextureRect stack it replaces, and it works identically on the Mobile renderer
## and in the web export. The only animated value is
## [code]progress[/code] (0 -> 1), eased, so the whole transition is one tween on
## one shader parameter.
##
## [b]Pixel-exact hand-off[/b]: at [code]progress == 0[/code] the shader is a
## straight pass-through of the "from" texture, which is what lets
## [method prepare] cover the live screen without a visible seam, and lets
## [method play_to] reveal the real page underneath with no "to" texture at all.
##
## [b]Input[/b]: while playing, the component swallows pointer input so a stray
## finger cannot start a stroke on the half-revealed page. It stops swallowing the
## instant the flip ends (and if it is aborted, and if it is hidden) --
## [code]set_process_input(false)[/code] plus MOUSE_FILTER_IGNORE, so it can never
## permanently steal input.
##
## [b]BL-30 polish -- visuals only[/b]. The turn kept its shape, its API and its
## duration; what changed is that the paper now behaves like paper:
##
## [codeblock]
## the roll SWELLS      curl_radius rises and falls with the lift, so the crease
##                      starts tight, fattens as the flap comes up over the page
##                      and tightens again into the spine
## the fold STRAIGHTENS fold_tilt leans hard at the start (a thumb picking up a
##                      corner) and eases square as the sheet comes over, which is
##                      what turns a straight sweep into an arc
## the light MOVES      the cast shadow widens, deepens and softens with the lift,
##                      and more of the printed side bleeds through the raised
##                      paper -- all three read as the sheet standing further off
##                      the page
## it SETTLES           the last sixth of the duration is not the turn at all: the
##                      sheet has landed, and [SettleShade] paints the shadow it
##                      drops on the revealed page, bouncing once before it lifts
## [/codeblock]
##
## Every one of those is a uniform the shader already exposed and nobody was
## driving; the shader itself is untouched (see [method _apply_progress]).

## The flip finished (or was aborted). The component is hidden and inert again.
signal flip_finished()
## The flip just started. Handy for tests and for parents that want to time a
## sound or a screenshot against the transition.
signal flip_started()

## Default flip duration in seconds -- long enough to read as a page turn, short
## enough that a child colouring twelve pages never waits on it.
const DEFAULT_DURATION := 0.8
## Shader parameter the whole transition rides on.
const PROGRESS_PARAM := "progress"

## How the duration is split between the turn and the settle. They add to 1, so
## BL-30 costs the flip nothing: a flip still takes exactly its [param duration].
const CURL_FRACTION := 0.84
const SETTLE_FRACTION := 0.16

# --- the paper, as a function of how far the turn has got (see _apply_progress) --
## Crease radius, in UV x, with the sheet flat and at the top of the lift.
const CURL_RADIUS_FLAT := 0.055
const CURL_RADIUS_LIFTED := 0.135
## Bias on the lift curve: below 1 the roll fattens early, the way a corner picked
## up by a thumb balloons long before the fold reaches the middle of the page.
const LIFT_BIAS := 0.75
## How far the fold leans, in UV x per page height, at the start and at the spine.
const FOLD_TILT_START := 0.17
const FOLD_TILT_END := 0.05
## Cast shadow, flat -> fully lifted: deeper and much softer as the paper rises.
const SHADOW_STRENGTH_FLAT := 0.34
const SHADOW_STRENGTH_LIFTED := 0.62
const SHADOW_WIDTH_FLAT := 0.042
const SHADOW_WIDTH_LIFTED := 0.130
## How much of the printed side shows through the back of the sheet.
const BACK_BLEED_FLAT := 0.07
const BACK_BLEED_LIFTED := 0.17


## The shadow the sheet that just landed drops across the page it landed on.
##
## Drawn rather than shaded because by this point the curl shader has nothing left
## to draw -- the leaf is fully turned away and transparent. One gradient quad
## (four vertices, four colours) plus the line of the sheet's own edge: darkest at
## the spine, gone by [member spread] across the page.
class SettleShade extends Control:
	## Warm ink rather than black -- this is a shadow on paper, not a fade to void.
	const TINT := Color(0.109804, 0.086275, 0.062745)
	const PEAK_ALPHA := 0.32
	const EDGE_ALPHA := 0.20

	## 0 = nothing, 1 = the sheet is right on top of the page.
	var amount := 0.0
	## How far across the page the shadow reaches, as a fraction of the width.
	var spread := 1.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		visible = false

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func set_shade(shade_amount: float, shade_spread: float) -> void:
		amount = clampf(shade_amount, 0.0, 1.0)
		spread = clampf(shade_spread, 0.0, 1.0)
		visible = amount > 0.002
		queue_redraw()

	func _draw() -> void:
		if amount <= 0.002 or size.x <= 2.0 or size.y <= 2.0:
			return
		var reach := maxf(size.x * spread, 2.0)
		var near := Color(TINT.r, TINT.g, TINT.b, PEAK_ALPHA * amount)
		var far := Color(TINT.r, TINT.g, TINT.b, 0.0)
		draw_polygon(
			PackedVector2Array([
				Vector2(0.0, 0.0),
				Vector2(reach, 0.0),
				Vector2(reach, size.y),
				Vector2(0.0, size.y),
			]),
			PackedColorArray([near, far, far, near])
		)
		draw_line(
			Vector2(reach, 0.0),
			Vector2(reach, size.y),
			Color(TINT.r, TINT.g, TINT.b, EDGE_ALPHA * amount),
			2.0
		)


@onready var _backdrop: TextureRect = $Backdrop
@onready var _leaf: TextureRect = $Leaf

var _material: ShaderMaterial
var _tween: Tween
var _playing := false
var _settle: SettleShade


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_input(false)
	_material = _leaf.material as ShaderMaterial
	if _material == null:
		push_error("PageFlip: the Leaf node is missing its page_curl ShaderMaterial.")
	_build_settle()
	_reset_leaf()


## Added from code, on top of the leaf, so page_flip.tscn keeps its two nodes and
## the settle can never end up UNDER the sheet it belongs to.
func _build_settle() -> void:
	_settle = SettleShade.new()
	_settle.name = "SettleShade"
	add_child(_settle)
	_settle.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


# ====================================================================== play ==

## Covers the screen with [param from_texture] immediately, without animating.
##
## The parent calls this, swaps the page behind it, then calls [method play_to] --
## so the new page is never visible before the flip starts.
func prepare(from_texture: Texture2D) -> void:
	_kill_tween()
	_leaf.texture = from_texture
	_backdrop.texture = null
	_reset_leaf()
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process_input(true)


## Turns the prepared leaf away, revealing [param to_texture].
##
## [param to_texture] may be [code]null[/code], which means "reveal whatever is
## already live behind this overlay". That is what the coloring screen passes: the
## real page is loaded and rendering underneath, so the reveal is pixel-exact and
## nothing pops when the overlay hides.
func play_to(to_texture: Texture2D = null, duration: float = DEFAULT_DURATION) -> void:
	if not visible:
		# play_to without prepare: nothing to turn away, just report done.
		_finish()
		return
	_backdrop.texture = to_texture
	_backdrop.visible = to_texture != null
	_start_tween(maxf(duration, 0.05))


## prepare + play_to in one call, for callers that already hold both textures.
func play(
	from_texture: Texture2D, to_texture: Texture2D = null, duration: float = DEFAULT_DURATION
) -> void:
	prepare(from_texture)
	play_to(to_texture, duration)


## Stops a flip immediately and hands input back. Emits [signal flip_finished].
func abort() -> void:
	if not _playing and not visible:
		return
	_kill_tween()
	_finish()


func is_playing() -> bool:
	return _playing


func get_duration() -> float:
	return DEFAULT_DURATION


## How far through the turn the sheet is, 0 (flat) .. 1 (gone). Tests read it;
## the game does not.
func get_progress() -> float:
	if _material == null:
		return 0.0
	return float(_material.get_shader_parameter(PROGRESS_PARAM))


# =================================================================== internal ==

## Two tweeners, back to back, inside the SAME duration the flip always took.
##
## The turn is CUBIC/IN_OUT because a turned page starts slowly (the paper has to
## be lifted), whips through the middle and settles rather than stopping dead --
## SINE, which the old transform version used, is too even to read as a hand doing
## it. The settle that follows it is LINEAR on purpose: its shape is
## [method _settle_curve], which no built-in easing has, because what it has to do
## is fall, come back once, and go.
func _start_tween(duration: float) -> void:
	_playing = true
	flip_started.emit()
	_settle.set_shade(0.0, 1.0)

	_tween = create_tween()
	_tween.tween_method(_apply_progress, 0.0, 1.0, duration * CURL_FRACTION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(_apply_settle, 0.0, 1.0, duration * SETTLE_FRACTION) \
		.set_trans(Tween.TRANS_LINEAR)
	_tween.finished.connect(_on_tween_finished)


## Everything the sheet does, from one number. [param value] is the shader's own
## [code]progress[/code]; the rest are uniforms the shader already had and nobody
## was driving, which is how BL-30's "paper shading" happens without touching
## [code]page_curl.gdshader[/code].
##
## [b]The hand-off at 0 stays pixel-exact[/b]: at [param value] 0 the fold sits off
## the free edge, so every fragment falls through to the flat-page branch whatever
## these are set to -- [method prepare] can still cover the live screen invisibly.
func _apply_progress(value: float) -> void:
	if _material == null:
		return
	_material.set_shader_parameter(PROGRESS_PARAM, value)
	# 0 flat -> 1 at the top of the arc -> 0 back down at the spine.
	var lift := sin(PI * pow(clampf(value, 0.0, 1.0), LIFT_BIAS))
	_material.set_shader_parameter(
		"curl_radius", lerpf(CURL_RADIUS_FLAT, CURL_RADIUS_LIFTED, lift)
	)
	# Straightens as the sheet comes over, so the fold sweeps an arc, not a bar.
	_material.set_shader_parameter(
		"fold_tilt", lerpf(FOLD_TILT_START, FOLD_TILT_END, smoothstep(0.0, 1.0, value))
	)
	_material.set_shader_parameter(
		"shadow_strength", lerpf(SHADOW_STRENGTH_FLAT, SHADOW_STRENGTH_LIFTED, lift)
	)
	_material.set_shader_parameter(
		"shadow_width", lerpf(SHADOW_WIDTH_FLAT, SHADOW_WIDTH_LIFTED, lift)
	)
	_material.set_shader_parameter(
		"back_bleed", lerpf(BACK_BLEED_FLAT, BACK_BLEED_LIFTED, lift)
	)


## The landing. [param t] runs 0 -> 1 over the last [constant SETTLE_FRACTION] of
## the flip, by which time the sheet is gone and only its shadow is left to place.
func _apply_settle(t: float) -> void:
	# Narrows towards the spine the whole way, so the bounce reads as the sheet
	# rocking flat rather than as the shadow flickering.
	_settle.set_shade(_settle_curve(t), lerpf(1.0, 0.22, t))


## Falls to nothing a third of the way in, comes back to about a third of its
## depth, and is gone: one damped bounce, which is what a dropped sheet of paper
## does. No built-in easing has this shape.
static func _settle_curve(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return (1.0 - x) * absf(cos(x * PI * 1.5))


func _on_tween_finished() -> void:
	_finish()


func _finish() -> void:
	_playing = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_input(false)
	_reset_leaf()
	flip_finished.emit()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	_playing = false


func _reset_leaf() -> void:
	_apply_progress(0.0)
	if is_instance_valid(_settle):
		_settle.set_shade(0.0, 1.0)
	if is_instance_valid(_backdrop):
		_backdrop.visible = false


# While playing, no pointer event reaches anything -- not the GUI, not
# PageView._unhandled_input. _input runs before both, and process_input is only
# ever on during a flip.
func _input(event: InputEvent) -> void:
	if not _playing:
		return
	if (
		event is InputEventScreenTouch
		or event is InputEventScreenDrag
		or event is InputEventMouseButton
		or event is InputEventMouseMotion
	):
		get_viewport().set_input_as_handled()

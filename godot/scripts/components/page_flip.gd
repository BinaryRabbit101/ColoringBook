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

@onready var _backdrop: TextureRect = $Backdrop
@onready var _leaf: TextureRect = $Leaf

var _material: ShaderMaterial
var _tween: Tween
var _playing := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_input(false)
	_material = _leaf.material as ShaderMaterial
	if _material == null:
		push_error("PageFlip: the Leaf node is missing its page_curl ShaderMaterial.")
	_reset_leaf()


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

## One tween on one parameter. CUBIC/IN_OUT because a turned page starts slowly
## (the paper has to be lifted), whips through the middle and settles rather than
## stopping dead -- SINE, which the old transform version used, is too even to
## read as a hand doing it.
func _start_tween(duration: float) -> void:
	_playing = true
	flip_started.emit()

	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(_set_progress, 0.0, 1.0, duration)
	_tween.finished.connect(_on_tween_finished)


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
	_set_progress(0.0)
	if is_instance_valid(_backdrop):
		_backdrop.visible = false


func _set_progress(value: float) -> void:
	if _material != null:
		_material.set_shader_parameter(PROGRESS_PARAM, value)


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

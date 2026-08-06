class_name PageFlip
extends Control
## The book page-turn transition (DESIGN.md 2: "PageFlip animation").
##
## Self-contained and content-blind: it is handed a "from" texture and a "to"
## texture and animates between them. It knows nothing about books, pages or the
## coloring screen -- the parent snapshots whatever it wants turned away.
##
## [b]The look[/b]: the "from" frame becomes a leaf hinged at the LEFT edge of
## the screen (the spine). The leaf's horizontal scale collapses toward the spine
## while it rotates a few degrees and darkens, with a bright curl highlight riding
## its leading edge and a shadow falling on the page underneath -- the read of a
## paper page being lifted and turned. Pure transform + modulate tweens: no
## shader, no render targets, cheap enough for the mobile pass.
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
## Where the leaf ends up: not quite zero width, so the last frame still shows a
## sliver of paper at the spine instead of popping out of existence.
const END_SCALE_X := 0.015
## Radians the leaf rotates about the spine as it turns.
const END_ROTATION := -0.13
## Leaf vertical scale at the end -- a page lifts slightly as it turns.
const END_SCALE_Y := 1.04
## Peak opacity of the shading laid over the turning leaf.
const LEAF_SHADE_ALPHA := 0.42
## Peak opacity of the shadow the leaf casts on the page underneath.
const DROP_SHADOW_ALPHA := 0.30

@onready var _backdrop: TextureRect = $Backdrop
@onready var _drop_shadow: TextureRect = $DropShadow
@onready var _leaf: Control = $Leaf
@onready var _leaf_texture: TextureRect = $Leaf/From
@onready var _leaf_shade: ColorRect = $Leaf/Shade
@onready var _curl: TextureRect = $Leaf/Curl

var _tween: Tween
var _playing := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_input(false)
	resized.connect(_layout_leaf)
	_reset_leaf()


# ====================================================================== play ==

## Covers the screen with [param from_texture] immediately, without animating.
##
## The parent calls this, swaps the page behind it, then calls [method play_to] --
## so the new page is never visible before the flip starts.
func prepare(from_texture: Texture2D) -> void:
	_kill_tween()
	_leaf_texture.texture = from_texture
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


# =================================================================== internal ==

func _start_tween(duration: float) -> void:
	_layout_leaf()
	_playing = true
	flip_started.emit()

	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(_leaf, "scale:x", END_SCALE_X, duration)
	_tween.tween_property(_leaf, "scale:y", END_SCALE_Y, duration)
	_tween.tween_property(_leaf, "rotation", END_ROTATION, duration)
	# Shading ramps in over the first two thirds and holds: the leaf is darkest
	# when it is edge-on to the reader.
	_tween.tween_property(_leaf_shade, "color:a", LEAF_SHADE_ALPHA, duration * 0.66)
	_tween.tween_property(_curl, "modulate:a", 1.0, duration * 0.35)
	_tween.tween_property(_drop_shadow, "modulate:a", DROP_SHADOW_ALPHA, duration * 0.5)
	_tween.chain().tween_property(_drop_shadow, "modulate:a", 0.0, duration * 0.35)
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
	if not is_instance_valid(_leaf):
		return
	_layout_leaf()
	_leaf.scale = Vector2.ONE
	_leaf.rotation = 0.0
	_leaf_shade.color.a = 0.0
	_curl.modulate.a = 0.0
	_drop_shadow.modulate.a = 0.0
	_backdrop.visible = false


## The leaf is hinged at the middle of the LEFT edge -- the spine of the book.
## Its rect comes from its full-rect anchors; only the pivot needs maintaining.
func _layout_leaf() -> void:
	if not is_instance_valid(_leaf):
		return
	_leaf.pivot_offset = Vector2(0.0, _leaf.size.y * 0.5)


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

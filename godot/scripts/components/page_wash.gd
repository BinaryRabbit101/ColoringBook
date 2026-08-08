class_name PageWash
extends ColorRect
## Start over, as a soapy wash over the page -- the GPU replacement for BL-29's
## [code]FreshSheetWipe[/code].
##
## BL-7 made "Start over" correct (the paint layer, the tracker, the saved PNG and
## the saved status all go back to blank) but it happened in one frame, so the
## picture simply vanished. BL-29 covered that frame with a sheet of paper sliding
## in from the left, and a white bloom as it landed. The bloom is what a playtester
## called flash-blind, and the sheet itself was a rectangle sliding and a rectangle
## fading -- correct, and nothing a four-year-old would ask to see again.
##
## [b]This is the same job done in one fragment shader[/b]
## ([code]scenes/components/page_wash.gdshader[/code], which documents the effect
## itself): a front of foam runs across the page leaving a film of soapy paper
## behind it, bubbles drift up through the film and catch an iridescent rim, and
## then the film breaks into popping bubbles and lets the blank page through. About
## a second and a sixth, and never brighter than the page's own paper.
##
## [b]It is pure presentation and it blocks nothing.[/b]
## [constant Control.MOUSE_FILTER_IGNORE], no input handling, and it frees itself
## when it is done; the clear it covers has already happened underneath it. Nothing
## waits for this and nothing reads it -- a player who starts painting again mid-
## wash paints on the real (already blank) page. In particular BL-18's semantics are
## untouched: the erase this decorates was recorded and pushed before frame 0 of it
## ever drew.
##
## [b]Reduced motion / low-end[/b] is [param animated] on [method play], which
## [ColoringPage] feeds from [member PageView.effect_animation_enabled] -- the one
## lever BL-38 already established for "this device should hold still". False gets
## [constant REDUCED_SECONDS] of a single paper film easing away: a quick fade,
## which is the floor this effect promises, and never a flash.
##
## Host it on a plain [Control] overlay, never a container (see [SparkleBurst]),
## and reach it through a preload rather than its global class name -- same reason
## [SparkleBurst] does: a class_name added today is invisible to a CLI run until the
## project is re-imported.
const SELF := preload("res://scripts/components/page_wash.gd")
const SHADER := preload("res://scenes/components/page_wash.gdshader")

## End to end, in seconds. Inside the 0.8-1.5 s a clear has to live in: long enough
## for the sweep, the scrub and the break-up to be three things, short enough that a
## child who pressed the button by accident is not held there.
const DEFAULT_SECONDS := 1.15
## The reduced-motion run: one film, eased off, and done before it is in the way.
const REDUCED_SECONDS := 0.34

## The film's body colour -- the page's own paper. Full cover therefore reads as a
## blank sheet rather than as a panel laid over one, which is the whole reason there
## is no flash to replace the flash with.
const PAPER := Color(0.984314, 0.964706, 0.917647)
## The cold tint the paper is mixed towards where the suds are thickest.
const SUDS := Color(0.803922, 0.905882, 0.976471)

var _time := 0.0
var _seconds := DEFAULT_SECONDS
var _material := ShaderMaterial.new()


## Plays a wash over [param rect] (in [param host]'s local coordinates). Returns
## the node, which owns its own lifetime -- callers may ignore it.
##
## [param animated] false is the reduced-motion path (see the class docs): the run
## shortens to [constant REDUCED_SECONDS] and the shader draws one paper film easing
## away instead of the foam.
static func play(
	host: Control,
	rect: Rect2,
	seconds: float = DEFAULT_SECONDS,
	animated: bool = true
) -> Control:
	if host == null or not is_instance_valid(host) or not host.is_inside_tree():
		return null
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return null
	var node: PageWash = SELF.new()
	node._seconds = maxf(REDUCED_SECONDS if not animated else seconds, 0.1)
	node.position = rect.position
	node.size = rect.size
	node._material.set_shader_parameter("reduced", not animated)
	node._material.set_shader_parameter("rect_size", rect.size)
	# Rerolled per wash: the same page cleared twice must not be the same animation,
	# and a seed is the cheapest way to say so to a shader.
	node._material.set_shader_parameter("seed", randf() * 64.0)
	node._apply_progress()
	host.add_child(node)
	return node


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The shader writes COLOR outright; white here just keeps the modulate it is
	# multiplied into out of the way.
	color = Color.WHITE
	_material.shader = SHADER
	_material.set_shader_parameter("paper", PAPER)
	_material.set_shader_parameter("suds", SUDS)
	material = _material
	# Depth is tree order (see [SparkleBurst]): over the page and its celebration,
	# under the confirm overlay and the flip. A caller that wants sparks ON the wash
	# simply adds them after it.
	set_process(true)


func _process(delta: float) -> void:
	_time += delta
	if _time >= _seconds:
		queue_free()
		return
	_apply_progress()


## True while the wash is still on screen. Nothing in the game reads this; it is
## here so a harness can wait the effect out instead of guessing at frames.
func is_playing() -> bool:
	return _time < _seconds


## How far through the run the shader thinks it is, 0..1. For harnesses -- the game
## only ever lets [method _process] drive it.
func get_progress() -> float:
	return clampf(_time / maxf(_seconds, 0.001), 0.0, 1.0)


## The two numbers that change between frames, and the whole of the per-frame CPU
## cost of this effect.
func _apply_progress() -> void:
	_material.set_shader_parameter("progress", get_progress())
	_material.set_shader_parameter("elapsed", _time)

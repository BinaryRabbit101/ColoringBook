class_name PopFeedback
extends RefCounted
## The "yes, I felt that" answer a control gives when it is pressed (BL-29).
##
## Four static gestures over any [Control] -- a press squash, a release pop, an
## entrance pop and a wiggle -- all of them driven by [member Control.scale] and
## [member Control.rotation] about the control's own centre.
##
## [b]Why scale and rotation are safe inside a container.[/b] A [BoxContainer] owns
## its children's [member Control.position] and [member Control.size] and re-writes
## them on every layout pass, but it never touches scale, rotation or
## [member Control.pivot_offset] -- so a toolbar button can bounce without fighting
## the row it lives in, and [method Control.get_global_rect] (position + size) is
## unchanged, which is what the smoke harnesses measure touch targets and overlap
## with. [PadlockButton] has rotated itself inside that same row since BL-10.
##
## [b]One tween per control.[/b] Each gesture kills the last one through a meta
## slot before it starts, so a child hammering Undo gets a crisp re-pop rather than
## two tweens fighting over one scale.

## Meta keys. Namespaced because they live on nodes this class does not own.
const META_TWEEN := &"pop_feedback_tween"
const META_ATTACHED := &"pop_feedback_attached"

## How far a held button sinks, and how long it takes to get there.
const PRESS_SCALE := 0.94
const PRESS_SECONDS := 0.07
## The release bounce.
const RELEASE_SECONDS := 0.22

const POP_STRENGTH := 0.14
const POP_SECONDS := 0.26


## Wires [param button] so it squashes while held and springs back on release.
## Idempotent -- calling it twice on the same button connects nothing twice.
static func attach(button: BaseButton, press_scale: float = PRESS_SCALE) -> void:
	if button == null or button.has_meta(META_ATTACHED):
		return
	button.set_meta(META_ATTACHED, true)
	button.button_down.connect(func() -> void: press_down(button, press_scale))
	button.button_up.connect(func() -> void: press_up(button))


static func press_down(control: Control, press_scale: float = PRESS_SCALE) -> void:
	var tween := _begin(control)
	if tween == null:
		return
	tween.tween_property(control, "scale", Vector2.ONE * press_scale, PRESS_SECONDS)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


static func press_up(control: Control) -> void:
	var tween := _begin(control)
	if tween == null:
		return
	tween.tween_property(control, "scale", Vector2.ONE, RELEASE_SECONDS)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## A celebratory bounce in place: overshoot, then settle. Used when a control's
## action actually LANDED (the page saved, a stroke came back), which is a
## different moment from the finger going down.
static func pop(
	control: Control, strength: float = POP_STRENGTH, seconds: float = POP_SECONDS
) -> void:
	var tween := _begin(control)
	if tween == null:
		return
	tween.tween_property(control, "scale", Vector2.ONE * (1.0 + strength), seconds * 0.34)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "scale", Vector2.ONE, seconds * 0.66)\
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


## An entrance: arrive small, overshoot a little, settle. For things that appear
## rather than things that were pressed (the "Saved!" toast).
static func pop_in(control: Control, from: float = 0.84, seconds: float = 0.34) -> void:
	var tween := _begin(control)
	if tween == null:
		return
	control.scale = Vector2.ONE * from
	tween.tween_property(control, "scale", Vector2.ONE, seconds)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## A short shake about the centre. [PadlockButton] keeps its own copy of this
## (tests wait on [method PadlockButton.is_wiggling]); this one is for everything
## else that wants the same motion.
static func wiggle(control: Control, angle: float = 0.11, seconds: float = 0.3) -> void:
	var tween := _begin(control)
	if tween == null:
		return
	control.rotation = 0.0
	var step := seconds * 0.25
	tween.tween_property(control, "rotation", angle, step)
	tween.tween_property(control, "rotation", -angle, step)
	tween.tween_property(control, "rotation", angle * 0.5, step)
	tween.tween_property(control, "rotation", 0.0, step)


## Puts a control back the way it was found. Page changes call this so a bounce
## interrupted by a flip cannot leave a button stuck at 1.14.
static func reset(control: Control) -> void:
	if control == null or not is_instance_valid(control):
		return
	_kill(control)
	control.scale = Vector2.ONE
	control.rotation = 0.0


## Centres the pivot and hands back a fresh tween, or null when the control cannot
## animate (freed, or not in the tree yet -- [method Node.create_tween] needs both).
static func _begin(control: Control) -> Tween:
	if control == null or not is_instance_valid(control) or not control.is_inside_tree():
		return null
	# At press time the container has already sized the control, so this is the
	# first moment the centre is actually known.
	control.pivot_offset = control.size * 0.5
	_kill(control)
	var tween := control.create_tween()
	control.set_meta(META_TWEEN, tween)
	return tween


static func _kill(control: Control) -> void:
	var previous: Variant = control.get_meta(META_TWEEN, null)
	if previous is Tween and (previous as Tween).is_valid():
		(previous as Tween).kill()
	control.set_meta(META_TWEEN, null)

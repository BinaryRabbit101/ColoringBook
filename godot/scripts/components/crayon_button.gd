class_name CrayonButton
extends BaseButton
## One crayon in the palette row, drawn from primitives -- no art assets.
##
## Extends [BaseButton] so touch and mouse arrive through the engine's single
## button path (DESIGN.md 3.3: no separate mouse/touch branches) while [method
## _draw] owns every pixel. The owning palette sets [member crayon_color] and
## [member selected]; this node only reports [signal pressed] upward.
##
## Silhouette: a tapered tip (trapezoid) on a straight body, a paper wrapper with
## two light bands and a label patch, plus edge shading. Selected crayons lift out
## of the box by [constant LIFT_PX] and gain a glow, so the selection reads at a
## glance from across the room.
##
## [b]BACKLOG BL-15 strengthened that read[/b] rather than redesigning it: the lift
## went from 16 px to [constant LIFT_PX] -- over a third of the crayon's own width,
## so a picked crayon is unmistakably taller than its neighbours -- unselected
## crayons narrow a little further, the halo gained layers and opacity, and the
## selected silhouette is outlined twice, in the crayon's own dark edge and in a
## bright rim outside it. That rim is what survives being looked at from 2-3 ft
## away on a phone.
##
## [b]BL-16 pushed it further still[/b], because on the device it still was not
## obvious: the lift is half the crayon's width now, the selected crayon is nearly
## half again as wide as an unselected one, and picking one plays a [b]settle
## bounce[/b] -- it springs up past its resting height and drops back
## ([constant SELECT_BOUNCE_SCALE]). The bounce is why [constant LIFT_HEADROOM],
## not [constant LIFT_PX], is the space reserved at the top of the box: the row's
## [ScrollContainer] clips across the crayon's LONG axis, and an overshoot with
## nowhere to go would be sliced off at the peak of the very motion that is
## supposed to draw the eye.
##
## [b]BL-21 gave the crayon a second orientation[/b], for the landscape dock where
## the palette is a vertical column beside the canvas. Rather than a second set of
## drawing code, [method _draw] always works in the crayon's own [b]canonical
## space[/b] -- tip at the top, lift rising -- and [constant ORIENT_LEFT] rotates
## that space a quarter turn anticlockwise before anything is drawn. Canonical UP
## then points screen LEFT, which is where the canvas is when the column is docked
## on the right, so the lift still rises INTO the page. Everything that depends on
## the lift direction -- the headroom, the halo's flattened spread, the paddings --
## is expressed in canonical space and therefore follows for free.

## [b]BL-35 gave the crayon a FINISH to advertise[/b] ([member finish]). Every box
## now carries the same ten crayons and differs in how its paint LOOKS, so the
## crayon has to say which box it came out of before anything is painted: a glow
## crayon blooms and its tip is lit, a textured crayon has visible wax grain, a
## glitter crayon has sparkles caught in it. All of it is drawn in the canonical
## space above, from the same primitives -- the drawing code was not forked.
##
## [b]BL-33 made the crayon resizable[/b], because the docked landscape column is
## shorter than ten crayons at their drawn size and scrolling is off the table. The
## palette hands each crayon a [member canonical_size] it worked out from the room
## it actually has; everything the drawing does in absolute pixels -- the lift, the
## bounce headroom, the end paddings -- is multiplied by [method length_scale], so
## a half-length crayon is the same crayon, half the size, and not a full-size one
## with its head cut off. [constant LIFT_HEADROOM] is still the space the box
## reserves for the bounce peak; it is just reserved proportionally now.

## Minimum touch target for a crayon (DESIGN.md 1 "large touch targets"); the
## global floor is 48 px, the crayon row is deliberately more generous. BL-33 is
## allowed to shrink a crayon to this and no further -- it is the floor the fit
## gives up and wraps to a second rank against.
const MIN_TOUCH_TARGET := 64.0
## Default box for one crayon, in CANONICAL space (tip up). Width is the touch
## target; height gives the ~1:2.5 body proportion that reads as "crayon" rather
## than "stick". [method box_for] turns this into the control's real box for an
## orientation.
const DEFAULT_SIZE := Vector2(68.0, 176.0)
## Longest a crayon is ever drawn relative to its width. A crayon squeezed to a
## square stops reading as a crayon, so [PaletteChild] keeps the ratio at or under
## this when it sizes them (BL-33).
const CANONICAL_ASPECT := DEFAULT_SIZE.y / DEFAULT_SIZE.x

## Drawn tip up; the lift rises. The bottom-of-the-canvas row (portrait).
const ORIENT_UP := 0
## Drawn tip LEFT; the lift moves left. The side-of-the-canvas column (BL-21
## landscape), where "left" is into the page.
const ORIENT_LEFT := 1
## How far a selected crayon rises out of the box (16 -> 26 in BL-15, 26 -> 34 in
## BL-16: half the crayon's own width).
const LIFT_PX := 34.0
## Peak of the settle bounce, as a multiple of [constant LIFT_PX] (BL-16).
const SELECT_BOUNCE_SCALE := 1.18
const SELECT_BOUNCE_SECONDS := 0.42
## Vertical space the box reserves for the lift. The BOUNCE's peak, not the resting
## lift, because the row clips vertically.
const LIFT_HEADROOM := LIFT_PX * SELECT_BOUNCE_SCALE
## Padding kept clear at each end so the lift, the halo and the selection rim have
## somewhere to go without being clipped by the crayon row's [ScrollContainer].
const BOTTOM_PAD := 6.0
const TOP_PAD := 5.0
## Body width, as a fraction of the control's width, when idle / hovered /
## selected. The selected crayon is the widest as well as the tallest, and BL-16
## widened the gap at both ends: the difference between the two is the signal.
const IDLE_WIDTH_SCALE := 0.64
const HOVER_WIDTH_SCALE := 0.74
const SELECTED_WIDTH_SCALE := 0.94
## Halo behind a selected crayon: how many copies, and how opaque each one is.
## The halo spreads mostly SIDEWAYS -- the row's [ScrollContainer] clips vertically
## and a hard-cut glow looks worse than a narrow one.
const GLOW_LAYERS := 8
const GLOW_ALPHA := 0.20
const GLOW_VERTICAL_RATIO := 0.30
## Bright rim under a selected crayon's dark outline: a wide light stroke straddling
## the silhouette edge, so the selection survives against a dark crayon.
const SELECTION_RIM := Color(1.0, 0.972549, 0.874510, 0.92)
const SELECTION_RIM_WIDTH := 9.0
const SELECTION_OUTLINE_WIDTH := 3.0

## The colour this crayon lays down. Also its entire visual identity.
var crayon_color: Color = Color.WHITE:
	set(value):
		crayon_color = value
		queue_redraw()

## Whether this is the palette's active crayon.
var selected: bool = false:
	set(value):
		if selected == value:
			return
		selected = value
		if selected:
			_bounce()
		else:
			_kill_bounce()
			_lift_scale = 1.0
		queue_redraw()

## Index of this crayon in the [PaletteDef]'s colour list.
var color_index: int = 0

## The FINISH this crayon paints with (BL-35): a [BrushFinish] id. It is drawn --
## a glow crayon glows in the box, a glitter crayon sparkles in it -- so a box of
## magic crayons sells itself before the first stroke, which is the whole point of
## having boxes. Drawn in the same CANONICAL space as everything else, so the
## preview follows the crayon round the quarter turn for free (BL-21).
var finish: StringName = BrushFinish.CLASSIC:
	set(value):
		var resolved := BrushFinish.resolve(value)
		if finish == resolved:
			return
		finish = resolved
		queue_redraw()

## Which way this crayon points (BL-21). Setting it also resizes the control's
## box, because a crayon lying on its side needs the long axis horizontal.
var orientation: int = ORIENT_UP:
	set(value):
		var resolved := ORIENT_LEFT if value == ORIENT_LEFT else ORIENT_UP
		if orientation == resolved:
			return
		orientation = resolved
		custom_minimum_size = box_for(resolved, canonical_size)
		queue_redraw()

## The box this crayon asks for, in CANONICAL space (x across the crayon, y along
## it) -- [constant DEFAULT_SIZE] unless [PaletteChild] shrank it to fit the strip
## (BL-33). Never below [constant MIN_TOUCH_TARGET] on either axis.
var canonical_size: Vector2 = DEFAULT_SIZE:
	set(value):
		var resolved := Vector2(
			maxf(value.x, MIN_TOUCH_TARGET), maxf(value.y, MIN_TOUCH_TARGET)
		)
		if canonical_size.is_equal_approx(resolved):
			return
		canonical_size = resolved
		custom_minimum_size = box_for(orientation, resolved)
		queue_redraw()

## Multiplier on [constant LIFT_PX] while the settle bounce plays (BL-16). 1.0 at
## rest; it starts at [constant SELECT_BOUNCE_SCALE] and springs down to 1.0.
var _lift_scale := 1.0
var _bounce_tween: Tween


func _init() -> void:
	custom_minimum_size = box_for(orientation, canonical_size)
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	# Repaint on hover / press so the crayon feels alive under a finger.
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)


## The control box one crayon of [param canonical] needs in [param orientation]:
## the canonical box for [constant ORIENT_UP], the same box on its side for
## [constant ORIENT_LEFT].
static func box_for(orientation_id: int, canonical := DEFAULT_SIZE) -> Vector2:
	return (
		Vector2(canonical.y, canonical.x)
		if orientation_id == ORIENT_LEFT
		else canonical
	)


## Unit vector, in SCREEN space, that a selected crayon lifts along -- up in the
## portrait row, left in the landscape column. Public so the palette smoke can
## assert the lift really points into the canvas rather than trusting the constant.
func lift_direction() -> Vector2:
	return Vector2.LEFT if orientation == ORIENT_LEFT else Vector2.UP


## How much of a full-size crayon this one is drawn at, measured along its LONG
## axis (BL-33). 1.0 for a crayon the palette had room to draw at
## [constant DEFAULT_SIZE]; less when the strip made it share.
func length_scale() -> float:
	var drawn := size.x if orientation == ORIENT_LEFT else size.y
	if drawn <= 0.0:
		drawn = canonical_size.y
	return clampf(drawn / DEFAULT_SIZE.y, 0.1, 1.0)


## How far a selected crayon of THIS size rises out of the box at rest --
## [constant LIFT_PX] scaled to its length, so a shrunken crayon lifts by the same
## fraction of itself and not by half its own body.
func resting_lift() -> float:
	return LIFT_PX * length_scale()


## Space this crayon's box keeps clear at its canonical top for the bounce peak.
## Always at least [method resting_lift] x [constant SELECT_BOUNCE_SCALE], at every
## size -- that is the invariant BL-16 bought and BL-33 had to keep while making
## the box shrink.
func lift_headroom() -> float:
	return LIFT_HEADROOM * length_scale()


## How far this crayon is currently lifted out of its box, in pixels: 0 when it is
## not the selection, [method resting_lift] at rest, more while the bounce is at
## its peak. Public so the palette smoke can measure the selection instead of
## trusting a constant.
func current_lift() -> float:
	return resting_lift() * _lift_scale if selected else 0.0


## True while the settle bounce is playing.
func is_bouncing() -> bool:
	return _bounce_tween != null and _bounce_tween.is_valid()


## The spring: up past the resting lift, then back down to it. Runs on the drawn
## LIFT rather than on the control's transform, so the whole thing stays inside the
## headroom the box already reserves and the row's scroller cannot slice the peak.
func _bounce() -> void:
	_kill_bounce()
	_lift_scale = SELECT_BOUNCE_SCALE
	if not is_inside_tree():
		_lift_scale = 1.0
		return
	_bounce_tween = create_tween()
	_bounce_tween.tween_method(
		_set_lift_scale, SELECT_BOUNCE_SCALE, 1.0, SELECT_BOUNCE_SECONDS
	).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _set_lift_scale(value: float) -> void:
	_lift_scale = value
	queue_redraw()


func _kill_bounce() -> void:
	if _bounce_tween != null and _bounce_tween.is_valid():
		_bounce_tween.kill()
	_bounce_tween = null


## Sets up the canonical drawing space, then draws the crayon in it (BL-21).
##
## [constant ORIENT_LEFT] rotates the canvas item a quarter turn ANTICLOCKWISE and
## slides it back into the box: canonical (x, y) lands at screen
## [code](y, height - x)[/code], so the canonical box (short x long) covers the
## control's real box (long x short) and canonical UP comes out screen LEFT. Every
## pixel below is then written exactly once, for both orientations.
func _draw() -> void:
	var box := size
	if box.x <= 0.0 or box.y <= 0.0:
		return
	if orientation == ORIENT_LEFT:
		draw_set_transform(Vector2(0.0, size.y), -PI * 0.5)
		box = Vector2(size.y, size.x)
	_draw_crayon(box)


func _draw_crayon(box: Vector2) -> void:
	# Every absolute measurement below is a fraction of a full-length crayon
	# (BL-33): shrinking the box shrinks the lift, the headroom and the paddings
	# with it, so the silhouette is identical at every size.
	var scale := clampf(box.y / DEFAULT_SIZE.y, 0.1, 1.0)
	var lift := current_lift()
	var press_sink := (4.0 if is_pressed() else 0.0) * scale
	var width_scale := SELECTED_WIDTH_SCALE
	if not selected:
		width_scale = HOVER_WIDTH_SCALE if is_hovered() else IDLE_WIDTH_SCALE

	var body_width := box.x * width_scale
	var center_x := box.x * 0.5
	var top := (TOP_PAD + LIFT_HEADROOM) * scale - lift + press_sink
	var bottom := box.y - BOTTOM_PAD * scale
	var crayon_height := bottom - top
	if crayon_height <= 0.0 or body_width <= 0.0:
		return

	var tip_height := crayon_height * 0.19
	var tip_width := body_width * 0.34
	var half := body_width * 0.5
	var tip_base := top + tip_height

	var silhouette := PackedVector2Array([
		Vector2(center_x - tip_width * 0.5, top),
		Vector2(center_x + tip_width * 0.5, top),
		Vector2(center_x + half, tip_base),
		Vector2(center_x + half, bottom),
		Vector2(center_x - half, bottom),
		Vector2(center_x - half, tip_base),
	])

	var centre := Vector2(center_x, (top + bottom) * 0.5)
	if selected:
		_draw_glow(silhouette, centre)
	# BL-35: a glow crayon carries its bloom whether or not it is the selection --
	# the finish is what the box IS, not feedback about what was picked.
	if finish == BrushFinish.GLOW:
		_draw_finish_bloom(silhouette, centre)
	# BL-38: an ANIMATED box glows a little too, because "this one is alive" has to
	# be legible in a strip of ten crayons at arm's length.
	if BrushFinish.is_animated(finish):
		_draw_finish_bloom(silhouette, centre)

	# Body + tip in one silhouette, then shading and wrapper on top of it.
	draw_colored_polygon(silhouette, crayon_color)

	var body_top := tip_base
	var body_height := bottom - body_top
	# Right-hand shading and left-hand highlight give the flat colour volume.
	draw_rect(
		Rect2(center_x + half * 0.42, body_top, half * 0.58, body_height),
		crayon_color.darkened(0.18)
	)
	draw_rect(
		Rect2(center_x - half, body_top, half * 0.42, body_height),
		crayon_color.lightened(0.22)
	)
	# Same treatment on the tip so it does not read as a flat triangle.
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(center_x + tip_width * 0.16, top),
			Vector2(center_x + tip_width * 0.5, top),
			Vector2(center_x + half, tip_base),
			Vector2(center_x + half * 0.42, tip_base),
		]),
		crayon_color.darkened(0.18)
	)

	# Paper wrapper: the body minus a bare band at each end.
	var wrap_top := body_top + body_height * 0.13
	var wrap_bottom := bottom - body_height * 0.10
	draw_rect(Rect2(center_x - half, wrap_top, body_width, wrap_bottom - wrap_top), crayon_color)
	var band := maxf(body_height * 0.035, 3.0)
	var band_color := Color(1.0, 1.0, 1.0, 0.78)
	draw_rect(Rect2(center_x - half, wrap_top, body_width, band), band_color)
	draw_rect(Rect2(center_x - half, wrap_bottom - band, body_width, band), band_color)
	# Label patch in the middle of the wrapper.
	var label_height := body_height * 0.16
	var label_y := (wrap_top + wrap_bottom - label_height) * 0.5
	draw_rect(
		Rect2(center_x - half * 0.72, label_y, body_width * 0.72, label_height),
		Color(1.0, 1.0, 1.0, 0.34)
	)

	# BL-35 finish preview, over the wax and under the outline: the grain and the
	# glitter are IN the crayon, the way they will be in the stroke.
	var body_box := Rect2(center_x - half, body_top, body_width, body_height)
	match finish:
		BrushFinish.GRAIN:
			_draw_finish_grain(body_box)
		BrushFinish.GLITTER:
			_draw_finish_glitter(Rect2(center_x - half, top, body_width, bottom - top))
		BrushFinish.GLOW:
			_draw_finish_hot_tip(center_x, top, tip_base, tip_width, half)
		BrushFinish.SHIMMER:
			_draw_finish_sheen(body_box)
		BrushFinish.TWINKLE:
			_draw_finish_sheen(body_box)
			_draw_finish_glitter(Rect2(center_x - half, top, body_width, bottom - top))
		# BL-47's four, previewed from the SAME primitives -- there is still no second
		# drawing path and still no art asset, which is what keeps the landscape dock's
		# quarter turn free. Each shows the finish's SHAPE, never its motion (BL-16: a
		# strip full of moving things reads as noise, not as an invitation).
		BrushFinish.EMBERS:
			_draw_finish_grain(body_box)
		BrushFinish.OCEAN:
			_draw_finish_sheen(body_box)
		BrushFinish.AURORA:
			_draw_finish_sheen(body_box)
		BrushFinish.FIREFLY:
			_draw_finish_glitter(Rect2(center_x - half, top, body_width, bottom - top))

	# Silhouette outline last, so nothing overdraws it. A selected crayon gets a
	# bright rim just outside it as well (BL-15): the dark edge alone disappears
	# against a dark crayon at arm's length.
	var outline := silhouette.duplicate()
	outline.append(silhouette[0])
	if selected:
		draw_polyline(outline, SELECTION_RIM, SELECTION_RIM_WIDTH, true)
	draw_polyline(
		outline, crayon_color.darkened(0.5),
		SELECTION_OUTLINE_WIDTH if selected else 2.0, true
	)


## Soft halo behind a selected crayon: copies of the silhouette scaled up about
## the crayon's centre, so the glow keeps the tapered shape instead of reading as
## a rectangle behind it.
func _draw_glow(silhouette: PackedVector2Array, center: Vector2) -> void:
	for i in GLOW_LAYERS:
		var spread := 0.05 + float(i) * 0.035
		draw_colored_polygon(
			_scaled(
				silhouette, center,
				Vector2(1.0 + spread, 1.0 + spread * GLOW_VERTICAL_RATIO)
			),
			Color(crayon_color.r, crayon_color.g, crayon_color.b, GLOW_ALPHA)
		)


# ======================================================= finish previews (BL-35) ==
# Each of these draws the finish the way the STROKE will look, in canonical space,
# from the same primitives the crayon itself is made of. There is no second drawing
# path and no art asset: a crayon lying on its side in the landscape dock gets its
# bloom and its sparkles rotated with it, because the quarter turn is already
# applied to the canvas item before any of this runs (BL-21).

## Layers of the glow finish's bloom, and how bright the innermost is.
const FINISH_BLOOM_LAYERS := 7
const FINISH_BLOOM_ALPHA := 0.13
## Slanted flecks of the grain finish, and how far each one leans.
const FINISH_GRAIN_FLECKS := 16
const FINISH_GRAIN_SLANT := 0.34
## Sparkles the glitter finish scatters over the crayon.
const FINISH_SPARKLES := 5


## The glow box's bloom: the selection halo's trick (scaled copies of the
## silhouette) in a brighter colour and spreading evenly, so it reads as light
## coming off the crayon rather than as "this one is picked".
func _draw_finish_bloom(silhouette: PackedVector2Array, center: Vector2) -> void:
	var hot := crayon_color.lightened(0.25)
	for i in FINISH_BLOOM_LAYERS:
		var spread := 0.06 + float(i) * 0.055
		draw_colored_polygon(
			_scaled(silhouette, center, Vector2(1.0 + spread, 1.0 + spread * 0.55)),
			Color(hot.r, hot.g, hot.b, FINISH_BLOOM_ALPHA)
		)


## ...and its tip is lit, like the hot core the stroke paints down its middle.
func _draw_finish_hot_tip(
	center_x: float, top: float, tip_base: float, tip_width: float, half: float
) -> void:
	var hot := crayon_color.lightened(0.55)
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(center_x - tip_width * 0.5, top),
			Vector2(center_x + tip_width * 0.5, top),
			Vector2(center_x + half * 0.62, tip_base),
			Vector2(center_x - half * 0.62, tip_base),
		]),
		Color(hot.r, hot.g, hot.b, 0.85)
	)
	draw_circle(Vector2(center_x, top + (tip_base - top) * 0.28), maxf(half * 0.16, 2.0),
		Color(1.0, 1.0, 1.0, 0.7))


## The textured box: slanted flecks of darker and lighter wax across the barrel,
## the crayon-grain the stroke lays down. Deterministic from the fleck index, so a
## crayon does not shimmer every time the row repaints.
func _draw_finish_grain(body: Rect2) -> void:
	if body.size.x <= 0.0 or body.size.y <= 0.0:
		return
	var inset := body.grow(-maxf(body.size.x * 0.10, 2.0))
	if inset.size.x <= 0.0 or inset.size.y <= 0.0:
		return
	var dark := crayon_color.darkened(0.30)
	var light := crayon_color.lightened(0.30)
	for i in FINISH_GRAIN_FLECKS:
		# Golden-ratio walk: even coverage without an RNG and without a table.
		var u := fmod(float(i) * 0.6180339887, 1.0)
		var v := fmod(float(i) * 0.2360679775 + 0.13, 1.0)
		var fleck_width := inset.size.x * (0.22 + 0.30 * u)
		var fleck_height := maxf(inset.size.y * 0.035, 2.0)
		var x := inset.position.x + (inset.size.x - fleck_width) * v
		var y := inset.position.y + (inset.size.y - fleck_height) * u
		var slant := fleck_height * FINISH_GRAIN_SLANT * 3.0
		draw_colored_polygon(
			PackedVector2Array([
				Vector2(x, y + slant),
				Vector2(x + fleck_width, y),
				Vector2(x + fleck_width, y + fleck_height),
				Vector2(x, y + fleck_height + slant),
			]),
			Color(dark.r, dark.g, dark.b, 0.55) if i % 2 == 0 else Color(light.r, light.g, light.b, 0.45)
		)


## The loudest box: sparkles caught in the wax. Four-point stars, because a circle
## reads as a bubble and a five-point star reads as a sticker.
func _draw_finish_glitter(body: Rect2) -> void:
	if body.size.x <= 0.0 or body.size.y <= 0.0:
		return
	for i in FINISH_SPARKLES:
		var u := fmod(float(i) * 0.6180339887 + 0.21, 1.0)
		var v := fmod(float(i) * 0.4142135624 + 0.07, 1.0)
		var centre := body.position + Vector2(body.size.x * (0.18 + 0.64 * u), body.size.y * (0.10 + 0.80 * v))
		var arm := maxf(body.size.x * (0.16 + 0.10 * v), 3.0)
		draw_colored_polygon(
			PackedVector2Array([
				Vector2(centre.x, centre.y - arm),
				Vector2(centre.x + arm * 0.26, centre.y - arm * 0.26),
				Vector2(centre.x + arm, centre.y),
				Vector2(centre.x + arm * 0.26, centre.y + arm * 0.26),
				Vector2(centre.x, centre.y + arm),
				Vector2(centre.x - arm * 0.26, centre.y + arm * 0.26),
				Vector2(centre.x - arm, centre.y),
				Vector2(centre.x - arm * 0.26, centre.y - arm * 0.26),
			]),
			Color(1.0, 1.0, 1.0, 0.92)
		)
		draw_circle(centre, arm * 0.18, Color(1.0, 1.0, 1.0, 1.0))


## BL-38's animated boxes: a bright SHEEN band lying across the barrel, the still
## frame of the highlight that will travel across the stroke.
##
## A band rather than a sparkle because that is what the finish actually does, and a
## still preview of a moving thing has to show its SHAPE -- a crayon that animated
## in the strip would be one more thing moving on a screen that already has a
## bouncing selection, and BL-16's lesson was that a strip full of motion reads as
## noise, not as an invitation.
func _draw_finish_sheen(body: Rect2) -> void:
	if body.size.x <= 0.0 or body.size.y <= 0.0:
		return
	var band_height := maxf(body.size.y * 0.13, 4.0)
	var lean := body.size.x * 0.34
	var y := body.position.y + body.size.y * 0.30
	for i in 3:
		var offset := float(i) * band_height * 0.62
		var thickness := band_height * (1.0 - float(i) * 0.26)
		var alpha := 0.62 - float(i) * 0.17
		draw_colored_polygon(
			PackedVector2Array([
				Vector2(body.position.x, y + offset + lean * 0.5),
				Vector2(body.position.x + body.size.x, y + offset - lean * 0.5),
				Vector2(body.position.x + body.size.x, y + offset - lean * 0.5 + thickness),
				Vector2(body.position.x, y + offset + lean * 0.5 + thickness),
			]),
			Color(1.0, 1.0, 1.0, alpha)
		)


## [param polygon] scaled about [param center]. Keeps the tapered crayon shape.
static func _scaled(polygon: PackedVector2Array, center: Vector2, scale: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for point in polygon:
		out.append(center + (point - center) * scale)
	return out

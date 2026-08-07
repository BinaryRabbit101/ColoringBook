class_name PaletteChild
extends Control
## [b]The[/b] palette: a chunky row of crayons (DESIGN.md 1, coloring-mechanics
## "The palette").
##
## [b]BL-20 made this the only one.[/b] The Child/Adult split, the swatch grid and
## the brush-size slider are gone; what survives is the crayon row, its single
## forgiving brush and the generous 0.90 completion threshold. The class keeps its
## [code]PaletteChild[/code] name and its scene path because DESIGN.md 3.4 still
## names them and renaming would churn every reference for nothing.
##
## [b]Palette contract[/b] -- what the coloring screen wires, blindly, to whatever
## [code]GameState.get_palette_scene_path()[/code] names:
## [codeblock]
## signal color_picked(color: Color)
## signal brush_size_picked(size: float)
## signal brush_effect_picked(effect: StringName)
## signal sticker_picked(sticker: StickerDef)
## signal sticker_mode_changed(active: bool)
## func set_palette(def: PaletteDef) -> void
## func select_color(index: int) -> void
## func select_brush_size(index: int) -> void
## func get_palette() -> PaletteDef
## func get_selected_color_index() -> int
## func get_selected_color() -> Color
## func get_selected_brush_size_index() -> int
## func get_selected_brush_size() -> float
## func get_color_buttons() -> Array[Control]
## func get_brush_size_controls() -> Array[Control]
## func get_pick_preview() -> PickPreview
## [/codeblock]
##
## [b]Three things grew on the strip after BL-20[/b], and none of them changed
## that contract -- [signal color_picked] still carries one resolved [Color] and
## the paint path never learns any of it happened:
##
## [b]BL-21 layout[/b]: the same scene docks as a bottom ROW or a side COLUMN.
## See [method set_layout]; the parent decides, from its aspect ratio.
##
## [b]BL-22 intensity[/b]: an [IntensityButton] swaps the strip between the crayon
## colours and the light-to-dark ladder of the crayon in hand. See
## [method set_view] / [method select_intensity].
##
## [b]BL-23 crayon sets[/b]: the strip cycles through the default box and every
## authored [CrayonSetDef]. See [method set_crayon_set]. [b]BL-34 reshaped the
## control[/b]: the single forward-only carton tile became a [CrayonCycleButton] at
## each OUTER END of the strip's long axis -- back at the start, forward at the end,
## both outside the crayon scroller -- and the box's identity moved to the pip rows
## on those bars plus a transient [CrayonBoxFlash] banner that shouts the name on
## every cycle.
##
## [b]BL-33 no-scroll fit[/b]: every crayon of the active box is visible at once, in
## both docks. The strip works out how much length it has left after the arrows and
## the intensity tile and sizes the crayons to fill it, down to
## [constant CrayonButton.MIN_TOUCH_TARGET] and no further; below that it wraps to a
## second (or third) RANK across the strip instead of scrolling. See
## [method _fit_crayons].
##
## [b]BL-35 finishes[/b]: every box carries the SAME crayons and differs in how its
## paint looks -- classic wax, neon glow, textured wax, glitter, each louder than
## the last. That is one new thing the paint path has to learn, and it learns it
## through its OWN explicit signal, [signal brush_effect_picked], never by reaching
## into the palette: [signal color_picked] still carries exactly one resolved
## [Color] and nothing else travels through it. [method set_palette] primes the
## finish the way it primes the size and the colour, so the brush is never
## finish-less, and cycling a box emits it exactly once beside the colour.
##
## [b]BL-36 stickers[/b]: the cycle ring does not stop at the last crayon box. It
## keeps going into the discovered [StickerSetDef]s -- the strip swaps its crayons
## for a row of sticker cards -- and cycling on past the last sticker set wraps
## home to crayon box 0. See [method set_stage] / [method stage_count]: one ring,
## one index, and the two cycle bars still call
## [method next_crayon_set] / [method prev_crayon_set].
##
## Sticker mode adds exactly two things to the contract and changes none of the
## three that were there:
## [codeblock]
## sticker_mode_changed(active)  the screen turns PageView.painting_enabled off
##                               (BL-10's one gate) and starts placing instead
## sticker_picked(sticker)       which StickerDef a tap would stick down
## [/codeblock]
## [signal color_picked] still carries exactly one resolved [Color] and is NOT
## emitted when the strip turns into stickers -- no colour changed, and there is no
## painting to prime. Neither is [signal brush_effect_picked]: the wax did not
## change either. Cycling BACK onto a crayon box emits the mode signal first, then
## the box's finish and colour in the order they have always gone out, so a
## listener is holding the right wax before the colour lands.
##
## The pick is therefore always "crayon C of box B at rung R", resolved in
## [method get_selected_color] and nowhere else -- or, in sticker mode, "sticker S
## of set T", resolved in [method get_selected_sticker].
## [method set_palette] auto-selects the first colour and the palette's default
## brush size, emitting [signal brush_size_picked] then [signal color_picked]
## once each -- the brush is never colourless or sizeless.
##
## The crayon row offers a single forgiving brush, so this component has no size
## control and [method get_brush_size_controls] is empty; it still declares and
## emits [signal brush_size_picked], because that is what primes
## [code]PageView.brush_size[/code] and the coloring screen has no other source.
##
## [b]Slide-to-select[/b] (BACKLOG BL-2): a crayon is picked the moment the finger
## lands on it ([constant BaseButton.ACTION_MODE_BUTTON_PRESS]) and the selection
## then FOLLOWS the finger across the row until it lifts. The drag half lives in
## [PaletteSlideInput]; the press half stays with the buttons so hover, tooltips
## and [signal BaseButton.pressed] keep working.
##
## [b]Pick preview[/b] (BACKLOG BL-15): the finger covers the crayon it is picking,
## so the candidate is echoed in a [PickPreview] bubble floating above the touch
## point. The palette owns the bubble and feeds it from [PaletteSlideInput]'s
## candidate hook -- the same gesture tracking slide-to-select already does, not a
## second copy of it.
##
## Self-contained: it is handed a [PaletteDef] and reaches nothing outside its
## own subtree. Signals up, calls down.

## The player picked a colour. Also emitted once by [method set_palette].
signal color_picked(color: Color)
## The brush diameter (page px) changed. Emitted once by [method set_palette].
signal brush_size_picked(size: float)
## The FINISH the strip's crayons paint with changed (BL-35) -- a [BrushFinish] id.
## Emitted once by [method set_palette] and once by every box change, and by nothing
## else: within a box, picking a crayon or a rung changes the colour, not the wax.
signal brush_effect_picked(effect: StringName)
## The sticker a tap on the page would stick down (BL-36), or null when the strip
## is showing crayons. Emitted once by every sticker pick and once by every cycle
## that lands on a sticker set.
signal sticker_picked(sticker: StickerDef)
## The strip turned into stickers (or back into crayons) -- BL-36. The screen's cue
## to flip [code]PageView.painting_enabled[/code]: sticker mode places stickers and
## paints nothing. Emitted only on a real change, and always BEFORE the pick that
## goes with it.
signal sticker_mode_changed(active: bool)

## Crayon-row touch target floor (DESIGN.md 1: "large touch targets").
const MIN_TOUCH_TARGET := CrayonButton.MIN_TOUCH_TARGET

## The strip is showing a box of crayons.
const MODE_CRAYONS := 0
## The strip is showing a set of stickers (BL-36).
const MODE_STICKERS := 1

## Colours the box-name flash and the cycle bars use to advertise a STICKER set. A
## sticker set has no crayon lineup to shout over, so it gets the bright confetti
## palette instead -- the same "this is a treat" reading the finish boxes get from
## their own colours. A typed [Array], because only that can be a [code]const[/code];
## [method sticker_accent_colors] is the [PackedColorArray] the controls take.
const STICKER_ACCENTS: Array[Color] = [
	Color(1.0, 0.803922, 0.223529),
	Color(0.929412, 0.294118, 0.372549),
	Color(0.396078, 0.658824, 0.929412),
	Color(0.396078, 0.752941, 0.435294),
	Color(0.945098, 0.462745, 0.686275),
]


## [constant STICKER_ACCENTS] as the [PackedColorArray] the flash banner and the
## cycle bars are fed.
static func sticker_accent_colors() -> PackedColorArray:
	var colors := PackedColorArray()
	for color in STICKER_ACCENTS:
		colors.append(color)
	return colors

## The crayons run left to right along the BOTTOM of the canvas (portrait).
const LAYOUT_ROW := 0
## The crayons run top to bottom down the SIDE of the canvas (BL-21, landscape).
const LAYOUT_COLUMN := 1

## Height of the portrait row -- the strip's short axis when it is docked along the
## bottom, where the canvas has height to spare and the crayons stand up full size.
const STRIP_THICKNESS := 212.0
## Width of the landscape column. WIDER than the row is tall, and deliberately so
## (BL-33): a landscape canvas is short, so the ten crayons have to wrap onto two
## ranks, and two ranks of a 212 px strip are 89 px each -- a crayon that stubby
## stops reading as a crayon. The extra 48 px buys back the silhouette, out of the
## axis a landscape screen has most of. Portrait, which has neither the problem nor
## the room, is untouched.
const COLUMN_THICKNESS := 260.0

## Margins the strip's [MarginContainer] keeps, across and along the strip. Read
## here rather than measured, because [method _fit_crayons] has to budget the
## crayons' room BEFORE the containers have laid anything out.
const STRIP_MARGIN := Vector2(14.0, 12.0)
## Separation between the strip's three sections (tool band, crayons, end arrow).
## Applied to the scene's containers from here rather than authored in the .tscn,
## because [method _crayon_room] budgets against it and a drift between the two
## numbers would be a silently mis-sized strip.
const BODY_SEPARATION := 10.0
## Separation between crayons, and between ranks of them.
const CRAYON_SEPARATION := 6.0
## Most ranks the crayons may wrap onto before the strip gives up and scrolls
## (BL-33). Three is already a wall of crayons; a set that cannot fit in three is
## an authoring decision, not a layout to design for.
const MAX_RANKS := 3

var _palette: PaletteDef
## Whatever is on the strip right now: [CrayonButton]s, or [StickerButton]s in
## sticker mode. One array, because BL-33's fit sizes and ranks the strip's items
## and does not care which kind they are -- both offer [code]canonical_size[/code]
## and [code]orientation[/code] and the same [code]box_for()[/code] contract.
var _items: Array[Control] = []
## Rank containers inside [member _row], one per rank of crayons.
var _ranks: Array[BoxContainer] = []
## True when even [constant MAX_RANKS] ranks of floor-sized crayons do not fit, so
## the strip scrolls after all. Never true for the shipped lineup -- see BL-33.
var _overflowing := false
var _selected_index := -1
var _selected_size_index := -1
var _selected_size := 0.0
var _layout := LAYOUT_ROW
## Which box of crayons is out (BL-23). 0 is the palette's own default box.
var _set_index := 0
## Crayons or stickers (BL-36).
var _mode := MODE_CRAYONS
## The sticker sets on this device, in ring order. Discovered once per
## [method set_palette] -- they are content, and content does not change mid-visit.
var _sticker_sets: Array[StickerSetDef] = []
## Which sticker set is out, and which sticker of it is in hand (BL-36).
var _sticker_index := 0
var _sticker_pick := 0
## Which face the strip is showing: colours, or the intensity ladder (BL-22).
var _view := VIEW_COLORS
## The rung of the ladder in hand. Reset to the crayon's own colour by every
## colour pick.
var _intensity_step := PaletteDef.INTENSITY_BASE_STEP

var _body: BoxContainer
var _controls: BoxContainer
var _row: BoxContainer
var _scroll: ScrollContainer
## The light-to-dark swap (BL-22) and the crayon-box cycle (BL-23/BL-34). Built
## here, like the pick bubble, so the palette stays one self-contained scene plus
## its own code.
var _intensity: IntensityButton
## Cycle bars at the two ends of the strip's long axis (BL-34). [member _prev]
## shares the leading tool band with the intensity tile; [member _next] caps the
## far end on its own. Both are OUTSIDE the crayon scroller, so a slide-to-select
## can never land on one.
var _prev: CrayonCycleButton
var _next: CrayonCycleButton
## The transient "Neon!" banner (BL-34).
var _flash: CrayonBoxFlash
## Drag half of slide-to-select; the crayons themselves make the first pick.
var _slide := PaletteSlideInput.new()
## BL-15's floating candidate bubble. Created here, never injected: the palette is
## self-contained and the smoke test drives it standalone.
var _preview: PickPreview


func _ready() -> void:
	_resolve_nodes()
	_apply_layout()
	# The fit is a function of the room the parent gives the strip, so it has to be
	# redone whenever that changes -- a window resize, an orientation flip, a
	# toolbar growing a button.
	if not resized.is_connected(_fit_crayons):
		resized.connect(_fit_crayons)


func _resolve_nodes() -> void:
	if _body == null:
		_body = get_node("Margin/Body") as BoxContainer
	if _controls == null:
		_controls = get_node("Margin/Body/Controls") as BoxContainer
	if _scroll == null:
		_scroll = get_node("Margin/Body/Scroll") as ScrollContainer
	if _row == null:
		_row = get_node("Margin/Body/Scroll/CrayonRow") as BoxContainer
	if _prev == null:
		# The leading cycle bar shares the tool band with the intensity tile rather
		# than taking a band of its own: the band costs the strip its LENGTH, and
		# length is exactly what BL-33's ten visible crayons are short of.
		_prev = CrayonCycleButton.new()
		_prev.name = "CyclePrev"
		_prev.direction = CrayonCycleButton.DIR_PREV
		_prev.pressed.connect(prev_crayon_set)
		_controls.add_child(_prev)
		_controls.move_child(_prev, 0)
	if _intensity == null:
		_intensity = IntensityButton.new()
		_intensity.name = "IntensityButton"
		_intensity.pressed.connect(_on_intensity_pressed)
		_controls.add_child(_intensity)
	if _next == null:
		# Capping the FAR end of the strip, after the scroller, so the two cycle
		# controls sit at the two outer ends of the crayons and neither is reachable
		# by a slide.
		_next = CrayonCycleButton.new()
		_next.name = "CycleNext"
		_next.direction = CrayonCycleButton.DIR_NEXT
		_next.pressed.connect(next_crayon_set)
		_body.add_child(_next)
	_body.add_theme_constant_override("separation", int(BODY_SEPARATION))
	_row.add_theme_constant_override("separation", int(CRAYON_SEPARATION))
	if _flash == null:
		# Parented to the palette ROOT for the same reason as the bubble: it floats
		# over the crayons and nothing must lay it out.
		_flash = CrayonBoxFlash.new()
		_flash.name = "CrayonBoxFlash"
		add_child(_flash)
	if _preview == null:
		# Parented to the palette ROOT, not the scroller: the bubble has to float
		# clear of both, and the root is a plain Control so nothing lays it out.
		_preview = PickPreview.new()
		_preview.name = "PickPreview"
		add_child(_preview)
	_slide.configure(self, _scroll)
	_slide.set_candidate_hook(_on_slide_candidate, _on_slide_released)


## Slide-to-select runs BEFORE the GUI phase, like [PageView]'s painting, so one
## touch code path serves mouse and finger alike. Claimed drags are marked handled
## so the crayon row cannot drag-scroll under the finger mid-slide.
func _input(event: InputEvent) -> void:
	if _slide.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	# BL-16's dismiss audit. [PaletteSlideInput] already fades the bubble when the
	# gesture it is tracking ends, but it only tracks gestures it CLAIMED: a press
	# that started on a crayon the helper refused (outside its hit area, another
	# control hovered) still raised the bubble through the button, and a release
	# whose index it never saw would leave it up. Any pointer release, from anywhere,
	# means no finger is choosing anything.
	if _slide.is_release_event(event):
		_on_slide_released()


# ======================================================== layout (BL-21) ==
# Portrait keeps the crayons in a strip along the bottom of the canvas, which
# reads well and is unchanged. Landscape docks them as a COLUMN beside the canvas
# instead, because the bottom strip eats the height a landscape screen has least
# of. It is the SAME scene either way -- one BoxContainer's direction, one
# ScrollContainer's axis, the crayons' own orientation and the pick bubble's
# placement -- and the parent decides which, from its ASPECT RATIO (never its
# width: DESIGN.md 3.5, a portrait window's logical canvas never gets narrow).

## Docks the crayons as a row or a column. Called by the parent when its aspect
## flips; the palette never measures the screen itself.
func set_layout(layout: int) -> void:
	var resolved := LAYOUT_COLUMN if layout == LAYOUT_COLUMN else LAYOUT_ROW
	if _layout == resolved and _body != null:
		return
	_layout = resolved
	_apply_layout()


func get_layout() -> int:
	return _layout


func is_column() -> bool:
	return _layout == LAYOUT_COLUMN


## The scroller the crayons live in. Exposed so a test can ask which way the strip
## scrolls without knowing the scene's node paths.
func get_scroll() -> ScrollContainer:
	_resolve_nodes()
	return _scroll


func _apply_layout() -> void:
	_resolve_nodes()
	var column := is_column()
	# The strip is thick across its short axis and takes whatever it is given
	# along its long one; the page view beside it is what expands.
	custom_minimum_size = (
		Vector2(COLUMN_THICKNESS, 0.0) if column else Vector2(0.0, STRIP_THICKNESS)
	)
	size_flags_horizontal = Control.SIZE_FILL if column else Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL if column else Control.SIZE_FILL

	_body.vertical = column
	# RANKS run across the strip; the crayons inside each rank run along it. With
	# one rank (the usual case) this is exactly the single row BL-21 shipped.
	_row.vertical = not column
	for rank in _ranks:
		rank.vertical = column
	# The tool band runs ACROSS the strip, perpendicular to the crayons, and fills
	# it, so the leading cycle bar can stretch into whatever the intensity tile
	# leaves.
	_controls.vertical = not column
	_controls.size_flags_horizontal = Control.SIZE_FILL if column else Control.SIZE_SHRINK_CENTER
	_controls.size_flags_vertical = Control.SIZE_SHRINK_CENTER if column else Control.SIZE_FILL

	for arrow in [_prev, _next]:
		if arrow == null:
			continue
		arrow.vertical = column
		arrow.size_flags_horizontal = Control.SIZE_EXPAND_FILL if column else Control.SIZE_FILL
		arrow.size_flags_vertical = Control.SIZE_FILL if column else Control.SIZE_EXPAND_FILL

	var orientation := CrayonButton.ORIENT_LEFT if column else CrayonButton.ORIENT_UP
	for item in _items:
		_orient_item(item, orientation)
	_fit_crayons()

	if _preview != null:
		# The hand comes in from the side the crayons are docked on, so the bubble
		# goes the other way: above the finger for the bottom row, left of it for
		# the right-hand column.
		_preview.set_placement(
			PickPreview.PLACE_LEFT if column else PickPreview.PLACE_ABOVE
		)


# ================================================ the no-scroll fit (BL-33) ==
# BL-21 docked the crayons as a column on a landscape screen and let the strip
# SCROLL when they did not all fit, which is what a short landscape canvas always
# does: ten crayons at their drawn length need more than a 648 px canvas has left
# once the toolbar has been paid for. Playtest verdict: a crayon a child cannot see
# is a crayon that does not exist. So the strip now sizes the crayons to the room
# it has instead of demanding room for the size it likes.
#
# Three rules, in order:
#   1. Shrink. Length available to the crayons, divided by how many there are.
#   2. Never below [constant CrayonButton.MIN_TOUCH_TARGET] (DESIGN.md 1). That
#      floor is the one number here that is not negotiable.
#   3. When the floor is reached, WRAP to another rank across the strip -- the
#      crayons get shorter, not smaller than a fingertip -- up to
#      [constant MAX_RANKS].
# Scrolling is what happens only if all three run out, which the shipped ten-crayon
# lineup never does in either dock. The strip's own thickness never changes: the
# palette costs the screen exactly what it always did.

## Sizes the crayons and lays them out in as many ranks as it takes for all of them
## to be visible at once. Cheap and idempotent -- called on every rebuild, every
## layout flip and every resize.
func _fit_crayons() -> void:
	_resolve_nodes()
	var count := _items.size()
	if count <= 0:
		_apply_scroll_mode()
		return
	var column := is_column()
	var room := _crayon_room()
	# BL-36: a sticker card is square and a crayon is long, so the two clamps below
	# come from whichever kind is on the strip. The FLOOR does not move -- 64 px is
	# a fingertip either way, and that is the number that is not negotiable.
	var default_size := (
		StickerButton.DEFAULT_SIZE if is_sticker_mode() else CrayonButton.DEFAULT_SIZE
	)
	var aspect := (
		StickerButton.CANONICAL_ASPECT if is_sticker_mode() else CrayonButton.CANONICAL_ASPECT
	)
	var ranks := 1
	var pitch := 0.0
	var length := 0.0
	var best := -INF
	_overflowing = true
	for candidate in range(1, MAX_RANKS + 1):
		var per_rank := ceili(float(count) / float(candidate))
		var candidate_pitch := (
			(room.x - float(per_rank - 1) * CRAYON_SEPARATION) / float(per_rank)
		)
		var candidate_length := (
			(room.y - float(candidate - 1) * CRAYON_SEPARATION) / float(candidate)
		)
		if candidate_pitch >= CrayonButton.MIN_TOUCH_TARGET \
				and candidate_length >= CrayonButton.MIN_TOUCH_TARGET:
			# The FEWEST ranks that fit wins: one long rank of crayons reads better
			# than two short ones, so extra ranks are a concession, not a goal.
			ranks = candidate
			pitch = candidate_pitch
			length = candidate_length
			_overflowing = false
			break
		# Nothing has fitted yet. Remember the least-bad shape rather than whichever
		# happened to be tried last: a strip one pixel too short should end up a
		# hair under the floor and scrolling by a hair, not fall off a cliff into
		# three ranks of slivers.
		var worst := minf(candidate_pitch, candidate_length)
		if worst > best:
			best = worst
			ranks = candidate
			pitch = candidate_pitch
			length = candidate_length

	# A crayon is never drawn bigger than its canonical box, never thinner than a
	# fingertip, and never squeezed into a square: past CANONICAL_ASPECT it stops
	# reading as a crayon, so a rank with room to spare draws a full-size one and
	# leaves the slack as air.
	pitch = clampf(pitch, CrayonButton.MIN_TOUCH_TARGET, default_size.x)
	length = clampf(
		length,
		CrayonButton.MIN_TOUCH_TARGET,
		minf(default_size.y, pitch * aspect)
	)

	_build_ranks(ranks)
	# Crayons fill each rank in palette order before starting the next, so the
	# colours read down (or along) one rank at a time -- a grid filled the other way
	# would zig-zag the order a child is learning.
	var per_rank := maxi(ceili(float(count) / float(ranks)), 1)
	var canonical := Vector2(pitch, length)
	var orientation := CrayonButton.ORIENT_LEFT if column else CrayonButton.ORIENT_UP
	for i in count:
		var item := _items[i]
		_orient_item(item, orientation)
		_size_item(item, canonical)
		var rank := _ranks[mini(i / per_rank, ranks - 1)]
		if item.get_parent() != rank:
			if item.get_parent() != null:
				item.get_parent().remove_child(item)
			rank.add_child(item)
	_apply_scroll_mode()


## The two properties the fit drives, applied to whichever kind of item is on the
## strip. A typed branch rather than a duck-typed assignment: both classes really
## do declare these, and spelling it out is what keeps a third kind of strip item
## honest about the contract it is joining.
static func _orient_item(item: Control, orientation: int) -> void:
	if item is CrayonButton:
		(item as CrayonButton).orientation = orientation
	elif item is StickerButton:
		(item as StickerButton).orientation = orientation


static func _size_item(item: Control, canonical: Vector2) -> void:
	if item is CrayonButton:
		(item as CrayonButton).canonical_size = canonical
	elif item is StickerButton:
		(item as StickerButton).canonical_size = canonical


## Length available to the crayons along the strip (x), and across it (y).
##
## Budgeted from the strip's own rect and the KNOWN minimum sizes of the two
## sections that flank the crayons, never from measured child rects: the fit runs
## before the containers have sorted, and a fit that read a stale rect would
## oscillate.
func _crayon_room() -> Vector2:
	var column := is_column()
	var inner := size - Vector2(STRIP_MARGIN.x * 2.0, STRIP_MARGIN.y * 2.0)
	if inner.x <= 0.0 or inner.y <= 0.0:
		# Before the first layout the strip has no size; fall back to its docked
		# thickness so a standalone palette still builds something sane.
		var thickness := COLUMN_THICKNESS if column else STRIP_THICKNESS
		inner = Vector2(
			thickness - STRIP_MARGIN.x * 2.0, thickness - STRIP_MARGIN.y * 2.0
		)
	var along := inner.y if column else inner.x
	var across := inner.x if column else inner.y
	# A hidden section costs nothing -- neither its size nor its separation -- which
	# is how a palette with a single crayon box hands the arrows' length back to the
	# crayons.
	var band := _controls.get_combined_minimum_size()
	along -= band.y if column else band.x
	along -= BODY_SEPARATION
	if _next.visible:
		var cap := _next.get_combined_minimum_size()
		along -= (cap.y if column else cap.x) + BODY_SEPARATION
	return Vector2(maxf(along, CrayonButton.MIN_TOUCH_TARGET), maxf(across, CrayonButton.MIN_TOUCH_TARGET))


## Makes [param count] rank containers exist inside the crayon host, reusing the
## ones already there. Crayons are re-parented into them by [method _fit_crayons].
func _build_ranks(count: int) -> void:
	while _ranks.size() > count:
		var extra: BoxContainer = _ranks.pop_back()
		_row.remove_child(extra)
		extra.queue_free()
	while _ranks.size() < count:
		var rank := BoxContainer.new()
		rank.name = "Rank%d" % _ranks.size()
		rank.vertical = is_column()
		rank.alignment = BoxContainer.ALIGNMENT_CENTER
		rank.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rank.add_theme_constant_override("separation", int(CRAYON_SEPARATION))
		rank.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		rank.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_row.add_child(rank)
		_ranks.append(rank)
	for rank in _ranks:
		rank.vertical = is_column()


## The strip scrolls only when the fit gave up -- which the shipped lineup never
## makes it do. A disabled scroller still hosts the crayons and still serves as
## slide-to-select's hit area; it simply has nothing to scroll.
func _apply_scroll_mode() -> void:
	var column := is_column()
	var mode := (
		ScrollContainer.SCROLL_MODE_AUTO if _overflowing else ScrollContainer.SCROLL_MODE_DISABLED
	)
	_scroll.horizontal_scroll_mode = (
		ScrollContainer.SCROLL_MODE_DISABLED if column else mode
	)
	_scroll.vertical_scroll_mode = (
		mode if column else ScrollContainer.SCROLL_MODE_DISABLED
	)


## True when every crayon of the active box is on screen at once -- the BL-33
## promise. False only if a set is long enough to defeat [constant MAX_RANKS] ranks
## of floor-sized crayons, in which case the strip scrolls rather than clip.
func fits_without_scrolling() -> bool:
	return not _overflowing


## How many ranks the crayons are laid out in (1 in the portrait row, 2 in the
## docked landscape column at the shipped lineup).
func get_rank_count() -> int:
	return maxi(_ranks.size(), 1)


# ===================================================== intensity (BL-22) ==
# The strip has two faces. Normally it shows the crayon COLOURS; tapping the
# [IntensityButton] swaps it for the intensity LADDER of whichever colour is in
# hand -- [constant PaletteDef.INTENSITY_STEPS] rungs from a pale tint to a deep
# shade, all of them COMPUTED from the base colour (PaletteDef.shade_of), never
# authored. Tapping again swaps back.
#
# Nothing downstream knows any of this happened. The active pick is always "base
# colour at rung N", it is resolved here, and [signal color_picked] carries the
# resolved colour exactly as it always did -- so the paint path, the shader and
# the stroke lifecycle are untouched (coloring-mechanics: the palette feeds
# color_picked and nothing more).

## The strip is showing the crayon colours.
const VIEW_COLORS := 0
## The strip is showing the intensity ladder of the colour in hand (BL-22).
const VIEW_SHADES := 1


## Swaps the strip between colours and shades. Idempotent.
func set_view(view: int) -> void:
	var resolved := VIEW_SHADES if view == VIEW_SHADES else VIEW_COLORS
	if _view == resolved:
		return
	_view = resolved
	_rebuild_strip()
	# Swapping the VIEW never changes the paint colour -- the same rung of the same
	# crayon is still in hand. Only a pick does.
	_refresh_tools()


func get_view() -> int:
	return _view


func is_showing_shades() -> bool:
	return _view == VIEW_SHADES


## Which rung of the ladder is painting, 0..[constant PaletteDef.INTENSITY_STEPS]-1.
func get_selected_intensity() -> int:
	return _intensity_step


## Picks rung [param step] of the current crayon's ladder and emits
## [signal color_picked] with the RESOLVED colour. This is what a press on a shade
## crayon calls.
func select_intensity(step: int) -> void:
	if _palette == null:
		return
	_intensity_step = clampi(step, 0, PaletteDef.INTENSITY_STEPS - 1)
	if is_showing_shades():
		for crayon in get_crayon_buttons():
			crayon.selected = crayon.color_index == _intensity_step
	_refresh_tools()
	color_picked.emit(get_selected_color())


## The swap control (BL-22). Never null after [method _resolve_nodes].
func get_intensity_button() -> IntensityButton:
	_resolve_nodes()
	return _intensity


func _on_intensity_pressed() -> void:
	set_view(VIEW_COLORS if is_showing_shades() else VIEW_SHADES)


func _refresh_tools() -> void:
	if _intensity != null:
		_intensity.set_palette(_palette)
		_intensity.base_color = get_base_color()
		_intensity.active_step = _intensity_step
		_intensity.showing_shades = is_showing_shades()
		# BL-36: a sticker has no intensity ladder, so the swap tile is not offered
		# in sticker mode -- and the strip gets its 88 px back for sticker cards.
		_intensity.visible = not is_sticker_mode()
	var stages := stage_count()
	var here := get_stage_index()
	for arrow in [_prev, _next]:
		if arrow == null:
			continue
		arrow.set_index = here
		arrow.set_count = stages
		# Each bar previews the STAGE it would fetch, so the two ends of the strip
		# answer "what happens if I press this" rather than repeating where we are.
		var step := -1 if arrow.direction == CrayonCycleButton.DIR_PREV else 1
		var destination := wrapi(here + step, 0, maxi(stages, 1))
		arrow.preview_stickers = is_sticker_stage(destination)
		arrow.preview_colors = (
			sticker_accent_colors() if is_sticker_stage(destination)
			else _crayon_stage_colors(destination)
		)
		# One stage means no carousel: two arrows that always land back here would
		# be a lie, and the strip gets their length back for crayons.
		arrow.visible = stages > 1


# ================================================ crayon sets (BL-23, BL-34) ==
# Mario-Paint-style fun: the default box plus every authored [CrayonSetDef] on
# disk. A set is COLOURS AND NOTHING ELSE -- the brush, the hardness and the
# completion threshold stay on the [PaletteDef] -- so swapping boxes swaps the
# strip and touches nothing about how the game plays. The intensity ladder comes
# along for free, because BL-22 computes it from whatever base colour is in hand.
#
# BL-34 turned the one forward-only tile into a CAROUSEL WITH TWO ENDS. Both
# [CrayonCycleButton]s live outside the crayon [ScrollContainer] (the BL-2 rule: a
# slide-to-select must never be able to land on a tool), at the two outer ends of
# the strip's long axis, and a cycle in either direction is exactly the same event
# it always was: first crayon, own colour, colours face, ONE resolved
# [signal color_picked], and the brush never moves.

## Puts box [param index] on the strip (wrapping, in both directions), back on its
## first crayon, and emits [signal brush_effect_picked] then [signal color_picked]
## for it.
##
## The finish goes out FIRST and the colour second, in the same order
## [method set_palette] primes them, so a listener that reacts to the colour is
## already holding the right wax when it does.
func set_crayon_set(index: int) -> void:
	if _palette == null:
		return
	var wrapped := _palette.wrap_crayon_set(index)
	var was_stickers := is_sticker_mode()
	_mode = MODE_CRAYONS
	_set_index = wrapped
	# A new box is a fresh start: first crayon, own colour, colours face. Leaving a
	# child on rung 6 of a colour that no longer exists is the alternative. BL-35:
	# the FINISH resets with it -- the finish belongs to the box, not to the hand.
	_selected_index = 0
	_intensity_step = PaletteDef.INTENSITY_BASE_STEP
	_view = VIEW_COLORS
	_rebuild_strip()
	# BL-36: painting comes back FIRST, so a listener has re-enabled the brush
	# before it is told which wax and which colour to load it with.
	if was_stickers:
		sticker_picked.emit(null)
		sticker_mode_changed.emit(false)
	brush_effect_picked.emit(get_selected_effect())
	_announce_stage()
	color_picked.emit(get_selected_color())


# =============================================================== the ring (BL-36) ==
# The carousel does not stop at the last crayon box. Past it come the sticker sets
# this device has -- the strip swaps its crayons for a row of sticker cards -- and
# past the last of those it wraps home to crayon box 0. One ring, one index:
#
#   stage 0 .. crayon_set_count()-1        the crayon boxes (BL-23/BL-34/BL-35)
#   stage crayon_set_count() ..            the discovered [StickerSetDef]s (BL-36)
#
# The two [CrayonCycleButton]s still call [method next_crayon_set] /
# [method prev_crayon_set] and know nothing about any of this: their pips count
# STAGES, and each previews whatever the stage it would fetch looks like.


## How many stages the cycle ring has: every crayon box, then every sticker set.
func stage_count() -> int:
	var boxes := _palette.crayon_set_count() if _palette != null else 1
	return boxes + _sticker_sets.size()


## Where the strip is on the ring, 0..[method stage_count]-1.
func get_stage_index() -> int:
	if not is_sticker_mode():
		return _set_index
	var boxes := _palette.crayon_set_count() if _palette != null else 1
	return boxes + _sticker_index


## True when stage [param index] is a sticker set rather than a crayon box.
func is_sticker_stage(index: int) -> bool:
	var boxes := _palette.crayon_set_count() if _palette != null else 1
	return index >= boxes and index < stage_count()


## Puts stage [param index] on the strip, wrapping in BOTH directions. The one
## entry point for the ring; [method set_crayon_set] and [method set_sticker_set]
## are what it dispatches to, and they stay public because a test (and a future
## "jump straight to my stickers" gesture) wants to name a stage directly.
func set_stage(index: int) -> void:
	var stages := stage_count()
	if stages <= 0:
		return
	var wrapped := wrapi(index, 0, stages)
	if is_sticker_stage(wrapped):
		var boxes := _palette.crayon_set_count() if _palette != null else 1
		set_sticker_set(wrapped - boxes)
	else:
		set_crayon_set(wrapped)


## The next stage in the ring. What the trailing [CrayonCycleButton] calls.
##
## [b]The name is BL-34's and is deliberately kept[/b]: this is the strip's one
## forward gesture, and it has walked past the crayon boxes into the sticker sets
## since BL-36. Renaming it would churn every call site to say the same thing.
func next_crayon_set() -> void:
	set_stage(get_stage_index() + 1)


## The stage BEFORE this one (BL-34); from stage 0 it wraps round to the last one,
## which since BL-36 is the last sticker set.
func prev_crayon_set() -> void:
	set_stage(get_stage_index() - 1)


func get_crayon_set_index() -> int:
	return _set_index


## Display name of whatever is on the strip -- the crayon box's, or the sticker
## set's. What the box-name flash shouts.
func get_crayon_set_name() -> String:
	if is_sticker_mode():
		var set_def := get_sticker_set()
		return set_def.display_name if set_def != null else ""
	return _palette.get_crayon_set_name(_set_index) if _palette != null else ""


# ------------------------------------------------------------ sticker sets (BL-36) --

## True while the strip is showing stickers instead of crayons. [b]This is the
## whole of the mode[/b] as far as anything outside the palette is concerned: the
## screen turns painting off while it holds and places stickers instead.
func is_sticker_mode() -> bool:
	return _mode == MODE_STICKERS


## The sticker sets this device has, in ring order. Empty on a build with no
## fixture sets and no installed sticker packs, which is the shipped release's
## normal state until the player downloads one (BL-25's rule, BL-37's packs).
func get_sticker_sets() -> Array[StickerSetDef]:
	return _sticker_sets


func sticker_set_count() -> int:
	return _sticker_sets.size()


## The set on the strip, or null in crayon mode.
func get_sticker_set() -> StickerSetDef:
	if not is_sticker_mode() or _sticker_index < 0 or _sticker_index >= _sticker_sets.size():
		return null
	return _sticker_sets[_sticker_index]


func get_sticker_set_index() -> int:
	return _sticker_index


## [b]The sticker that would actually be stuck down[/b] -- the one thing
## [signal sticker_picked] ever carries, and null whenever the strip is showing
## crayons.
func get_selected_sticker() -> StickerDef:
	var set_def := get_sticker_set()
	if set_def == null:
		return null
	return set_def.get_sticker(_sticker_pick)


func get_selected_sticker_index() -> int:
	return _sticker_pick if is_sticker_mode() else -1


## Puts sticker set [param index] on the strip (wrapping), on its first sticker,
## and emits [signal sticker_mode_changed] (on entry) then
## [signal sticker_picked].
##
## Emits NO [signal color_picked] and NO [signal brush_effect_picked]: no colour
## and no wax changed, and there is no painting to prime -- the screen has just
## been told to stop painting.
func set_sticker_set(index: int) -> void:
	if _sticker_sets.is_empty():
		return
	var wrapped := wrapi(index, 0, _sticker_sets.size())
	var was_stickers := is_sticker_mode()
	_mode = MODE_STICKERS
	_sticker_index = wrapped
	# A new set is a fresh start, exactly like a new crayon box: first sticker.
	_sticker_pick = 0
	_view = VIEW_COLORS
	_rebuild_strip()
	if not was_stickers:
		sticker_mode_changed.emit(true)
	_announce_stage()
	sticker_picked.emit(get_selected_sticker())


## Selects sticker [param index] of the set on the strip (clamped) and emits
## [signal sticker_picked]. Exactly what a card press calls.
func select_sticker(index: int) -> void:
	var set_def := get_sticker_set()
	if set_def == null or set_def.sticker_count() <= 0:
		return
	_sticker_pick = clampi(index, 0, set_def.sticker_count() - 1)
	for card in get_sticker_buttons():
		card.selected = card.sticker_index == _sticker_pick
	_refresh_tools()
	sticker_picked.emit(get_selected_sticker())


## Drops and re-scans the sticker sets. Dev/tests only -- the shipped game
## discovers once per visit, when [method set_palette] builds the strip, because a
## pack cannot install itself while a page is open (DLC_SERVER.md §7.3).
func reload_sticker_sets() -> void:
	_sticker_sets = StickerSetDef.discover()
	_sticker_index = clampi(_sticker_index, 0, maxi(_sticker_sets.size() - 1, 0))
	_refresh_tools()


## The colours crayon stage [param index] would put on the strip. Only ever asked
## about a crayon stage -- a sticker stage has no lineup.
func _crayon_stage_colors(index: int) -> PackedColorArray:
	if _palette == null:
		return PackedColorArray()
	return _palette.get_crayon_set_colors(index)


## [b]The finish that will actually be painted[/b] (BL-35): the box in hand's, and
## the only thing [signal brush_effect_picked] ever carries. Classic wax whenever
## there is no palette to ask, so the brush is never finish-less.
func get_selected_effect() -> StringName:
	if _palette == null:
		return BrushFinish.CLASSIC
	return _palette.get_crayon_set_effect(_set_index)


## The two cycle bars, leading end first (BL-34). Never null after
## [method _resolve_nodes]; both hidden when there is only the default box.
func get_cycle_buttons() -> Array[CrayonCycleButton]:
	_resolve_nodes()
	return [_prev, _next]


## The transient box-name banner (BL-34). Never null after [method _resolve_nodes].
func get_box_flash() -> CrayonBoxFlash:
	_resolve_nodes()
	return _flash


## Says the new stage's name over the strip, once, and lets it fade. The whole of
## the box's identity that is not the pip rows -- and the only place its name is
## ever written (BL-34). A sticker set announces itself exactly like a crayon box
## (BL-36): landing on the stickers is the same event as landing on Neon.
func _announce_stage() -> void:
	if _flash == null or stage_count() <= 1:
		return
	_flash.flash(
		"%s!" % get_crayon_set_name(),
		sticker_accent_colors() if is_sticker_mode() else _active_colors()
	)


# ================================================== shared palette contract ==

## Rebuilds the strip from [param def], then auto-selects the default brush size
## and the first colour (emitting both signals once). Passing null empties it.
func set_palette(def: PaletteDef) -> void:
	_resolve_nodes()
	_palette = def
	_selected_index = -1
	_selected_size_index = -1
	_intensity_step = PaletteDef.INTENSITY_BASE_STEP
	_set_index = 0
	_view = VIEW_COLORS
	# BL-36: the ring is as long as this device's content, so the sticker sets are
	# discovered here -- once per visit, beside the palette that is being installed.
	# A pack cannot install itself while a page is open, so re-scanning per cycle
	# would buy nothing and cost a directory walk on every press.
	_mode = MODE_CRAYONS
	_sticker_index = 0
	_sticker_pick = 0
	_sticker_sets = StickerSetDef.discover()
	_clear_row()
	if _flash != null:
		_flash.hide_now()
	if def == null:
		_refresh_tools()
		return

	_selected_index = 0
	_rebuild_strip()
	select_brush_size(def.get_default_brush_size_index())
	# BL-35: prime the finish exactly the way the size is primed, and before the
	# colour, so the first stroke of the visit can never be painted with wax nobody
	# chose. The default box is classic, so this is a no-op for the brush -- but the
	# brush is now told so, rather than left to assume it.
	brush_effect_picked.emit(get_selected_effect())
	select_color(0)


## Builds the crayon controls for whichever face the strip is showing. One place,
## because the two faces differ only in what colours the crayons carry and what
## a press on one means.
func _rebuild_strip() -> void:
	_resolve_nodes()
	_clear_row()
	if _palette == null:
		return
	if is_sticker_mode():
		_rebuild_sticker_strip()
		return

	var shades := is_showing_shades()
	var colors := (
		_palette.shades_of(get_base_color()) if shades else _active_colors()
	)
	var selected := _intensity_step if shades else _selected_index
	# BL-35: every crayon on the strip wears the box's finish, the ladder's rungs
	# included -- a rung is the same wax at a different intensity.
	var finish := get_selected_effect()
	for i in colors.size():
		var crayon := CrayonButton.new()
		crayon.name = ("Shade%d" if shades else "Crayon%d") % i
		crayon.color_index = i
		crayon.finish = finish
		crayon.orientation = (
			CrayonButton.ORIENT_LEFT if is_column() else CrayonButton.ORIENT_UP
		)
		crayon.crayon_color = colors[i]
		crayon.tooltip_text = "#" + colors[i].to_html(false)
		crayon.selected = i == selected
		# Slide-to-select: the pick happens as the finger LANDS, not when it lifts,
		# so the selection can then follow the finger (see PaletteSlideInput).
		crayon.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		crayon.pressed.connect(_pick_at.bind(i))
		_items.append(crayon)

	# Sizing and ranking is one job and it belongs to the fit, which is also what
	# parents each crayon into a rank (BL-33).
	_refresh_tools()
	_fit_crayons()
	_slide.set_targets(get_strip_buttons(), _pick_at)


## The same strip, filled with sticker cards instead of crayons (BL-36). Same
## fit, same ranks, same slide-to-select, same scroller -- one press means
## "stick this one down next" instead of "paint with this colour".
func _rebuild_sticker_strip() -> void:
	var set_def := get_sticker_set()
	if set_def == null:
		_refresh_tools()
		_fit_crayons()
		return
	for i in set_def.sticker_count():
		var sticker := set_def.get_sticker(i)
		if sticker == null:
			continue
		var card := StickerButton.new()
		card.name = "Sticker%d" % i
		card.sticker_index = i
		card.sticker_id = sticker.sticker_id
		card.texture = sticker.load_texture()
		card.tooltip_text = sticker.display_name
		card.orientation = (
			StickerButton.ORIENT_LEFT if is_column() else StickerButton.ORIENT_UP
		)
		card.selected = i == _sticker_pick
		card.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		card.pressed.connect(_pick_at.bind(i))
		_items.append(card)

	_refresh_tools()
	_fit_crayons()
	_slide.set_targets(get_strip_buttons(), _pick_at)


## What a press or a slide onto strip position [param index] means, which depends
## on which face is up. One callback, so [PaletteSlideInput] never has to know.
func _pick_at(index: int) -> void:
	if is_sticker_mode():
		select_sticker(index)
	elif is_showing_shades():
		select_intensity(index)
	else:
		select_color(index)


## Selects crayon [param index] (clamped) and emits [signal color_picked].
## This is exactly what a crayon press calls -- tests drive the same entry point.
##
## [b]It resets the intensity[/b] (BL-22): a new crayon comes out of the box at
## its own colour, so a child who wandered up the ladder once is not stuck there
## for every colour after it.
func select_color(index: int) -> void:
	if _palette == null:
		return
	var count := _active_colors().size()
	if count <= 0:
		return
	var clamped := clampi(index, 0, count - 1)
	_selected_index = clamped
	_intensity_step = PaletteDef.INTENSITY_BASE_STEP
	if is_showing_shades():
		# Picked from outside the shade face (a test, or a restored selection):
		# the ladder it is showing is the wrong colour's now.
		_rebuild_strip()
	else:
		for crayon in get_crayon_buttons():
			crayon.selected = crayon.color_index == clamped
	_refresh_tools()
	color_picked.emit(get_selected_color())


## Selects brush size [param index] (clamped) and emits [signal brush_size_picked].
## The crayon row has one size, so this normally fires only from [method set_palette].
func select_brush_size(index: int) -> void:
	if _palette == null:
		return
	var count := maxi(_palette.brush_size_count(), 1)
	_selected_size_index = clampi(index, 0, count - 1)
	_selected_size = _palette.get_brush_size(_selected_size_index)
	brush_size_picked.emit(_selected_size)


func get_palette() -> PaletteDef:
	return _palette


## Which CRAYON is in hand -- the base colour's index, whichever face the strip is
## showing. The rung is [method get_selected_intensity].
func get_selected_color_index() -> int:
	return _selected_index


## The crayon's own colour, before the intensity ladder is applied.
func get_base_color() -> Color:
	var colors := _active_colors()
	if colors.is_empty() or _selected_index < 0:
		return Color.MAGENTA
	return colors[clampi(_selected_index, 0, colors.size() - 1)]


## [b]The colour that will actually be painted[/b]: the crayon in hand, at the
## intensity rung in hand. This is what [signal color_picked] carries, and it is
## the only colour anything outside this component ever sees.
func get_selected_color() -> Color:
	if _palette == null or _selected_index < 0:
		return Color.MAGENTA
	return _palette.shade_of(get_base_color(), _intensity_step)


func get_selected_brush_size_index() -> int:
	return _selected_size_index


func get_selected_brush_size() -> float:
	return _selected_size


## The crayon controls, in palette order. For layout/touch-target verification.
## [b]Empty in sticker mode[/b] -- a sticker card is not a colour button, and the
## whole point of the split is that nothing asking for colours gets handed one.
## Whatever is actually on the strip is [method get_strip_buttons].
func get_color_buttons() -> Array[Control]:
	var buttons: Array[Control] = []
	for crayon in get_crayon_buttons():
		buttons.append(crayon)
	return buttons


## The crayons on the strip, typed. Empty in sticker mode.
func get_crayon_buttons() -> Array[CrayonButton]:
	var buttons: Array[CrayonButton] = []
	for item in _items:
		if item is CrayonButton:
			buttons.append(item as CrayonButton)
	return buttons


## The sticker cards on the strip, in set order (BL-36). Empty in crayon mode.
func get_sticker_buttons() -> Array[StickerButton]:
	var buttons: Array[StickerButton] = []
	for item in _items:
		if item is StickerButton:
			buttons.append(item as StickerButton)
	return buttons


## Everything the strip is offering right now, crayons OR sticker cards, in strip
## order. This is what the no-scroll fit (BL-33) is measured against, because the
## promise is about the STRIP, not about crayons specifically.
func get_strip_buttons() -> Array[Control]:
	var buttons: Array[Control] = []
	for item in _items:
		buttons.append(item)
	return buttons


## Always empty: the crayon row exposes no size control (see the class docs).
func get_brush_size_controls() -> Array[Control]:
	return []


## Everything on the strip that is not a crayon -- the two cycle bars and the
## intensity swap -- in the order they sit along it. For layout and touch-target
## verification; the crayons themselves are [method get_color_buttons].
func get_tool_buttons() -> Array[Control]:
	_resolve_nodes()
	var tools: Array[Control] = []
	for control in [_prev, _intensity, _next]:
		if control != null and control.visible:
			tools.append(control)
	return tools


## The floating pick-preview bubble (BL-15). Never null after [method _ready].
func get_pick_preview() -> PickPreview:
	_resolve_nodes()
	return _preview


# ================================================================ pick preview ==

## The finger is over strip position [param index] ([code]-1[/code] between
## crayons, where the last candidate stands). Presentational only -- the pick
## itself is [method _pick_at], called by the button and by [PaletteSlideInput].
##
## The bubble shows the colour that would actually be PAINTED, which on the shade
## face is the resolved rung and not the crayon's own colour (BL-22).
func _on_slide_candidate(index: int, viewport_position: Vector2) -> void:
	if _preview == null or _palette == null:
		return
	# BL-36: the bubble exists because a finger covers the COLOUR it is picking. A
	# sticker card is bigger than a fingertip and its art reads round the finger, so
	# sticker mode raises no bubble rather than raising a meaningless colour.
	if is_sticker_mode():
		_preview.hide_now()
		return
	if index < 0:
		_preview.move_to(viewport_position)
		return
	_preview.show_color(_candidate_color(index), viewport_position)


## What picking strip position [param index] right now would put on the brush.
func _candidate_color(index: int) -> Color:
	if is_showing_shades():
		return _palette.shade_of(get_base_color(), index)
	var colors := _active_colors()
	if colors.is_empty():
		return Color.MAGENTA
	return colors[clampi(index, 0, colors.size() - 1)]


## The colours the strip's COLOUR face offers: whichever crayon box is out (BL-23).
func _active_colors() -> PackedColorArray:
	if _palette == null:
		return PackedColorArray()
	return _palette.get_crayon_set_colors(_set_index)


func _on_slide_released() -> void:
	if _preview != null:
		_preview.dismiss()


# =================================================================== internal ==

func _clear_row() -> void:
	_items.clear()
	if _preview != null:
		_preview.hide_now()
	var no_targets: Array[Control] = []
	_slide.set_targets(no_targets, Callable())
	if _row == null:
		return
	# The ranks themselves are kept -- [method _fit_crayons] decides how many there
	# should be -- but every crayon in them goes.
	for rank in _ranks:
		for child in rank.get_children():
			rank.remove_child(child)
			child.queue_free()

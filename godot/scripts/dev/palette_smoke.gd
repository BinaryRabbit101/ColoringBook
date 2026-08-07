extends Control
## Automated verification for the palette: the crayon row, its [PaletteDef], and
## the [code]GameState[/code] surface around them.
##
## Run WINDOWED (the integration check paints into a SubViewport, which renders
## nothing under --headless / the dummy rasteriser):
##
##   <godot_exe> --path <project> res://scenes/dev/palette_smoke.tscn
##
## Extra user args (after a bare `--`):
##   --stay          leave the window open with the palette over the page
##   --shot <path>   save a PNG of the viewport to <path> before quitting
##
## Every pick goes through the same entry points the touch path uses: a real
## BaseButton `pressed` emission, or the `select_color` / `select_brush_size`
## handlers those call. The BL-15/16 selection-feedback checks go further and
## synthesise real InputEventScreenTouch / InputEventScreenDrag events at real
## on-screen coordinates, because the pick-preview bubble is driven by the
## gesture, not by the pick.
##
## [b]BL-20[/b] removed the Child/Adult split. The checks that used to assert the
## split were REWRITTEN rather than dropped: check 1 now asserts the adult palette
## and everything only it used are gone from the project, and check 8 asserts
## GameState has no mode surface left and that a save carrying the old "mode" key
## still loads (and is written back without it).
## Exit code is 0 only if every check passes.

const PALETTE := "res://resources/palettes/child_palette.tres"

const BASE_IMAGE := "res://assets/books/test_book/page_01.png"
const ID_MAP := "res://assets/books/test_book/page_01_idmap.png"
const REGIONS_JSON := "res://assets/books/test_book/page_01_regions.json"

## Expected authored shape of the shipped palette.
const CRAYON_COUNT := 10
## BL-20: the crayon row keeps its one forgiving brush, and that brush is 96 px.
const FORGIVING_BRUSH := 96.0
## BL-5's child threshold, which BL-20 made THE threshold.
const COMPLETION_THRESHOLD := 0.9

## Everything BL-20 deleted with the adult half. A file still on disk here means
## the split grew a second life.
const REMOVED_FILES: PackedStringArray = [
	"res://resources/palettes/adult_palette.tres",
	"res://scenes/components/palette_adult.tscn",
	"res://scripts/components/palette_adult.gd",
	"res://scripts/components/swatch_button.gd",
	"res://scripts/components/brush_size_slider.gd",
	"res://scenes/screens/mode_select.tscn",
	"res://scripts/screens/mode_select.gd",
]

## Minimum perceptual separation between two crayons, as an RGB distance
## (0..sqrt(3)). Kids must never confuse two crayons.
const MIN_COLOR_DISTANCE := 0.25
## Authored crayon sets that ship: BL-35 replaced BL-23's five recolours (Pastel,
## Neon, Earth, Candy, Spooky -- "more colour options, not more fun") with three
## boxes of the SAME crayons in escalating finishes.
const EXPECTED_EXTRA_SETS := 3
## The finish ladder the shipped boxes walk, dullest first: box 0 is the default
## crayon box in plain wax, then one box per authored set.
const FINISH_LADDER: Array[StringName] = [
	BrushFinish.CLASSIC, BrushFinish.GLOW, BrushFinish.GRAIN, BrushFinish.GLITTER
]
const SET_NAMES: PackedStringArray = ["Neon Glow", "Textured Wax", "Glitter"]

## Per-channel tolerance (0..255) when checking painted pixels against the picked
## palette colour.
const COLOR_TOLERANCE := 2
## Alpha byte at/above which a painted pixel counts as "core" (not soft edge).
const CORE_ALPHA := 250

## Page pixels inside region 4 (the big circle) used by the integration stroke.
const STROKE_FROM := Vector2(700.5, 250.5)
const STROKE_TO := Vector2(840.5, 250.5)
const CORE_SAMPLES: Array[Vector2i] = [Vector2i(700, 250), Vector2i(770, 250), Vector2i(840, 250)]

## Scratch save root for check 8, so the player's own save is never read or written.
const TEST_SAVE_ROOT := "user://palette_smoke/state"

## Selection left on screen for the human-eyeball / screenshot pass.
const SHOWCASE_INDEX := 4

@onready var _page_view: PageView = $PageView
@onready var _palette: PaletteChild = $Stack/PaletteChild

var _def: PaletteDef

var _colors: Array[Color] = []
var _sizes: Array[float] = []
## BL-35: every finish the palette handed the paint path, in order.
var _effects: Array[StringName] = []

var _checks := 0
var _failures := 0


func _ready() -> void:
	# The palette plus a usable page need vertical room; the dev scene sizes its
	# own window so the layout is not judged against Godot's default 1152x648.
	get_window().size = Vector2i(1280, 940)
	await get_tree().process_frame
	_run()


func _run() -> void:
	print("=== palette smoke test ===")

	_check_palette_resources()
	_check_component_built()
	await _check_touch_targets()
	_check_auto_selection()
	_check_simulated_picks()
	await _check_landscape_dock()
	await _check_intensity()
	await _check_crayon_sets()
	await _check_page_view_integration()
	await _check_selection_feedback()
	_check_game_state()

	await _showcase()

	print("\n=== %d/%d checks passed ===" % [_checks - _failures, _checks])
	var shot_path := _shot_path()
	if shot_path != "":
		await _settle()
		var error := get_viewport().get_texture().get_image().save_png(shot_path)
		print("screenshot: %s (%s)" % [shot_path, "ok" if error == OK else "error %d" % error])
	if "--stay" in OS.get_cmdline_user_args():
		print("[dev] --stay given; not quitting.")
		return
	_finish(0 if _failures == 0 else 1)


func _finish(code: int) -> void:
	print("exit code: %d" % code)
	get_tree().quit(code)


# ==================================================================== checks ==

## (a) The authored .tres loads and holds sane data -- and the adult half really
## is gone (BL-20).
func _check_palette_resources() -> void:
	print("\n-- check 1: the one PaletteDef, and the adult half's absence --")
	_def = load(PALETTE) as PaletteDef
	_expect(_def != null, "%s loads as a PaletteDef" % PALETTE)
	if _def == null:
		return

	_expect(_def.validate().is_empty(), "the palette validates (%s)" % [_def.validate()])

	# BL-20: one palette, and no way to ask for a second.
	var still_there := PackedStringArray()
	for path in REMOVED_FILES:
		if ResourceLoader.exists(path) or FileAccess.file_exists(path):
			still_there.append(path)
	_expect(still_there.is_empty(),
		"every file the Child/Adult split needed is deleted (%s)"
		% ("none left" if still_there.is_empty() else str(still_there)))
	_expect(not _has_property(_def, "mode"),
		"PaletteDef carries no mode id any more")
	_expect(not _has_property(_def, "shades_per_family"),
		"...and no shades_per_family, which only the deleted swatch grid read")

	_expect(_def.color_count() == CRAYON_COUNT,
		"the palette has %d colours (%d)" % [CRAYON_COUNT, _def.color_count()])

	var closest := _closest_color_pair()
	_expect(float(closest["distance"]) >= MIN_COLOR_DISTANCE,
		"the colours are well differentiated (closest pair %d/%d, distance %.3f >= %.2f)"
		% [int(closest["a"]), int(closest["b"]), float(closest["distance"]), MIN_COLOR_DISTANCE])

	_expect(_def.brush_size_count() == 1,
		"it offers ONE forgiving brush size (%s)" % [_def.brush_sizes])
	_expect(is_equal_approx(_def.get_brush_size(0), FORGIVING_BRUSH),
		"...which is the %.0f px crayon brush (%.0f)" % [FORGIVING_BRUSH, _def.get_brush_size(0)])
	_expect(is_equal_approx(_def.default_brush_size, FORGIVING_BRUSH),
		"...and it is also the default, so there is nothing to pick")
	_expect(_all_positive(_def.brush_sizes), "every brush size (diameter, page px) is positive")

	_expect(is_equal_approx(_def.completion_threshold, COMPLETION_THRESHOLD),
		"the completion threshold is the single %.2f (%.2f)"
		% [COMPLETION_THRESHOLD, _def.completion_threshold])
	_expect(_def.completion_threshold >= CoverageTracker.MIN_REGION_THRESHOLD,
		"...which clears the tracker's %.2f floor" % CoverageTracker.MIN_REGION_THRESHOLD)


## (b) The component builds the expected controls from its def.
func _check_component_built() -> void:
	print("\n-- check 2: the crayon row builds from the def --")
	# Recorders go on BEFORE set_palette so the auto-selection emission is caught.
	_palette.color_picked.connect(func(c: Color) -> void: _colors.append(c))
	_palette.brush_size_picked.connect(func(s: float) -> void: _sizes.append(s))
	_palette.brush_effect_picked.connect(func(e: StringName) -> void: _effects.append(e))

	_palette.set_palette(_def)

	var crayons := _palette.get_color_buttons()
	_expect(crayons.size() == CRAYON_COUNT,
		"the row renders %d crayon controls (%d)" % [CRAYON_COUNT, crayons.size()])
	var all_crayons := true
	var colors_match := true
	for i in crayons.size():
		all_crayons = all_crayons and crayons[i] is CrayonButton
		colors_match = colors_match and (crayons[i] as CrayonButton).crayon_color == _def.get_color(i)
	_expect(all_crayons, "every control is a CrayonButton")
	_expect(colors_match, "every crayon carries its def colour, in palette order")
	_expect(_palette.get_brush_size_controls().is_empty(),
		"the palette exposes NO size control -- one forgiving brush (BL-20)")


## (b cont.) Touch targets, measured after layout, in both orientations.
func _check_touch_targets() -> void:
	print("\n-- check 3: touch targets and orientation --")
	await _settle()
	_measure_targets("landscape 1280x940")

	# Portrait: the row must survive a narrow window (it scrolls).
	get_window().size = Vector2i(720, 1180)
	await _settle()
	_measure_targets("portrait 720x1180")
	var row_fits := true
	for control in _palette.get_color_buttons():
		row_fits = row_fits and control.global_position.y >= 0.0
	_expect(row_fits, "the row still lays out inside the panel when narrow")

	get_window().size = Vector2i(1280, 940)
	await _settle()


func _measure_targets(label: String) -> void:
	var smallest := _smallest_target(_palette.get_color_buttons())
	_expect(smallest >= PaletteChild.MIN_TOUCH_TARGET,
		"[%s] every crayon target >= %.0f px (smallest %.1f px)"
		% [label, PaletteChild.MIN_TOUCH_TARGET, smallest])
	# The BL-22/BL-23 tool tiles share the strip's short axis with its margins, so
	# growing one of them is exactly how they would start hanging out of it.
	var tools := _palette.get_tool_buttons()
	var tool_smallest := _smallest_target(tools)
	_expect(tools.size() >= 2 and tool_smallest >= PaletteChild.MIN_TOUCH_TARGET,
		"[%s] the %d tool tiles are >= %.0f px too (smallest %.1f px)"
		% [label, tools.size(), PaletteChild.MIN_TOUCH_TARGET, tool_smallest])
	var strip := _palette.get_global_rect()
	var overflowing := 0
	for tool in tools:
		if not strip.encloses(tool.get_global_rect()):
			overflowing += 1
	_expect(overflowing == 0,
		"[%s] ...and all of them fit inside the strip (%d hanging out)" % [label, overflowing])


## (d cont.) BL-21: the same scene, docked as a COLUMN beside the canvas.
##
## What has to survive the flip is everything the row carries -- the touch targets,
## slide-to-select's hit area, the pick bubble and the crayon's lift -- so this
## check flips the layout, measures all four, and flips back. The lift is the
## subtle one: it has to point INTO the canvas, which is LEFT once the crayons are
## docked on the right, and its bounce overshoot still has to fit in the headroom
## the box reserves (BL-16's gotcha, now in canonical space).
func _check_landscape_dock() -> void:
	print("\n-- check 5b: the landscape dock (BL-21) --")
	var row_minimum := _palette.custom_minimum_size
	_expect(_palette.get_layout() == PaletteChild.LAYOUT_ROW,
		"the palette starts as a row along the bottom")
	_expect(is_equal_approx(row_minimum.y, PaletteChild.STRIP_THICKNESS)
			and is_equal_approx(row_minimum.x, 0.0),
		"...a %.0f px strip across its short axis (%s)"
		% [PaletteChild.STRIP_THICKNESS, row_minimum])

	_palette.set_layout(PaletteChild.LAYOUT_COLUMN)
	await _settle()
	_expect(_palette.is_column(), "set_layout(COLUMN) docks it on the side")
	_expect(is_equal_approx(_palette.custom_minimum_size.x, PaletteChild.STRIP_THICKNESS)
			and is_equal_approx(_palette.custom_minimum_size.y, 0.0),
		"...the strip's thickness moved to its WIDTH (%s)" % _palette.custom_minimum_size)
	_expect(_palette.size_flags_vertical == Control.SIZE_EXPAND_FILL
			and _palette.size_flags_horizontal == Control.SIZE_FILL,
		"...and it expands ALONG the canvas, not into it")

	var scroll := _palette.get_scroll()
	_expect(scroll != null
			and scroll.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED
			and scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED,
		"the strip now scrolls VERTICALLY and clips across its width")

	var crayons := _palette.get_color_buttons()
	var sideways := true
	var stacked := true
	var smallest := INF
	for i in crayons.size():
		var crayon := crayons[i] as CrayonButton
		sideways = sideways and crayon.orientation == CrayonButton.ORIENT_LEFT \
			and crayon.size.x > crayon.size.y
		smallest = minf(smallest, minf(crayon.size.x, crayon.size.y))
		if i > 0:
			stacked = stacked \
				and crayon.global_position.y >= crayons[i - 1].get_global_rect().end.y - 1.0
	_expect(sideways, "every crayon is drawn lying on its side, long axis horizontal")
	_expect(stacked, "...stacked top to bottom, not squeezed side by side")
	_expect(smallest >= PaletteChild.MIN_TOUCH_TARGET,
		"...and each one still holds its %.0f px touch target (%.1f)"
		% [PaletteChild.MIN_TOUCH_TARGET, smallest])
	_measure_targets("docked column")

	_palette.select_color(3)
	var selected := crayons[3] as CrayonButton
	_expect(selected.lift_direction() == Vector2.LEFT,
		"the selected crayon lifts LEFT -- into the canvas, not out of the screen (%s)"
		% selected.lift_direction())
	_expect(selected.current_lift() > CrayonButton.LIFT_PX,
		"...springing past its resting lift, as in the row (%.0f px)" % selected.current_lift())
	_expect(CrayonButton.box_for(CrayonButton.ORIENT_LEFT).x
			>= CrayonButton.LIFT_HEADROOM + CrayonButton.LIFT_PX,
		"...into headroom the sideways box reserves too, so the bounce peak is not clipped")
	await _wait(CrayonButton.SELECT_BOUNCE_SECONDS + 0.2)

	# The bubble: the hand now comes in from the RIGHT, so it parks to the LEFT.
	var preview := _palette.get_pick_preview()
	_expect(preview.get_placement() == PickPreview.PLACE_LEFT,
		"the pick bubble moved to the side of the finger")
	_expect(preview.get_tail_direction() == Vector2.RIGHT,
		"...with its tail pointing back at the hand (%s)" % preview.get_tail_direction())
	var point := _center_of(crayons[3])
	_send_touch(_palette, point, true)
	_expect(preview.is_showing(), "a press on a docked crayon still raises it")
	var bubble := preview.get_viewport_rect_of_bubble()
	_expect(bubble.end.x <= point.x,
		"...entirely to the LEFT of the touch point (right edge %.0f <= finger %.0f)"
		% [bubble.end.x, point.x])
	_expect(not bubble.has_point(point), "...so the hand cannot be covering it")
	_expect(point.x - bubble.end.x >= PickPreview.FINGER_GAP - 1.0,
		"...and %.0f px clear of it, the same gap the row leaves"
		% (point.x - bubble.end.x))
	_send_touch(_palette, point, false)
	preview.hide_now()

	# Back to portrait: nothing the flip changed is one-way.
	_palette.set_layout(PaletteChild.LAYOUT_ROW)
	await _settle()
	_expect(not _palette.is_column() and _palette.custom_minimum_size == row_minimum,
		"flipping back restores the bottom row exactly (%s)" % _palette.custom_minimum_size)
	_expect((crayons[0] as CrayonButton).orientation == CrayonButton.ORIENT_UP
			and _palette.get_pick_preview().get_placement() == PickPreview.PLACE_ABOVE,
		"...crayons upright again, bubble back above the finger")
	_palette.select_color(0)


## (c) set_palette auto-selects the first colour and the default brush size,
## emitting each signal exactly once, so the brush is never colourless.
func _check_auto_selection() -> void:
	print("\n-- check 4: auto-selection on set_palette --")
	_expect(_colors.size() == 1,
		"color_picked fired exactly once on set_palette (%d)" % _colors.size())
	_expect(_colors.size() == 1 and _colors[0] == _def.get_color(0),
		"...with the FIRST colour (%s vs %s)"
		% [_colors[0] if _colors.size() > 0 else "none", _def.get_color(0)])
	_expect(_sizes.size() == 1 and is_equal_approx(_sizes[0], _def.default_brush_size),
		"brush_size_picked fired once with the default %.0f px (%s)"
		% [_def.default_brush_size, _sizes])
	_expect(_palette.get_selected_color_index() == 0, "the palette reports selected index 0")


## (d) Picks made through the real button path carry the def's own values.
func _check_simulated_picks() -> void:
	print("\n-- check 5: simulated picks --")
	var crayons := _palette.get_color_buttons()
	var expected: Array[Color] = []
	for index in [3, 7, 0, 9]:
		expected.append(_def.get_color(index))
		# The real input path: BaseButton reports `pressed`, which is wired to
		# PaletteChild.select_color(index).
		(crayons[index] as CrayonButton).pressed.emit()
	var got := _colors.slice(1)
	_expect(got == expected,
		"crayon presses emitted the def's colours in order (%s)" % [_hex_list(got)])
	_expect((crayons[9] as CrayonButton).selected and not (crayons[0] as CrayonButton).selected,
		"only the last-pressed crayon is marked selected")
	_expect(_palette.get_selected_color() == _def.get_color(9),
		"the palette reports the last picked colour (%s)" % _palette.get_selected_color().to_html(false))
	_expect(_sizes.size() == 1,
		"...and picking colours never re-emits a brush size (%d emission)" % _sizes.size())


## (d cont.) BL-22: the intensity ladder, and the swap control that reveals it.
##
## The load-bearing claim is that NOTHING downstream of the palette changed: a
## shade pick is still one [signal PaletteChild.color_picked] carrying one
## resolved colour. So this drives the swap the way a finger would, then checks
## the emissions -- not the internals.
func _check_intensity() -> void:
	print("\n-- check 5c: the intensity ladder (BL-22) --")
	var swap := _palette.get_intensity_button()
	_expect(swap != null, "the strip carries a swap control")
	if swap == null:
		return
	_expect(minf(swap.size.x, swap.size.y) >= PaletteChild.MIN_TOUCH_TARGET,
		"...at least %.0f px to aim at (%.0fx%.0f)"
		% [PaletteChild.MIN_TOUCH_TARGET, swap.size.x, swap.size.y])
	_expect(not _palette.get_scroll().is_ancestor_of(swap),
		"...outside the crayon scroller, so a slide can never land on it")

	# --- the ladder is DERIVED, not authored ---------------------------------
	_expect(PaletteDef.INTENSITY_STEPS == 7,
		"the ladder has %d rungs (%d)" % [7, PaletteDef.INTENSITY_STEPS])
	_expect(not _has_property(_def, "intensity_colors")
			and not _has_property(_def, "shades"),
		"PaletteDef authors no shade table -- the ladder is computed")
	var derived_everywhere := true
	var base_is_base := true
	for i in _def.color_count():
		var base := _def.get_color(i)
		var ladder := _def.shades_of(base)
		base_is_base = base_is_base and ladder[PaletteDef.INTENSITY_BASE_STEP] == base
		for step in range(1, ladder.size()):
			# Pale to deep: every rung is darker than the one before it.
			derived_everywhere = derived_everywhere \
				and ladder[step].get_luminance() < ladder[step - 1].get_luminance()
	_expect(base_is_base,
		"rung %d of every crayon's ladder IS that crayon's colour"
		% PaletteDef.INTENSITY_BASE_STEP)
	_expect(derived_everywhere,
		"...and all %d ladders run pale to deep without a break" % _def.color_count())

	# --- swapping the strip ---------------------------------------------------
	_palette.select_color(5)
	var base_color := _def.get_color(5)
	var emitted_before := _colors.size()
	swap.pressed.emit()
	await _settle()
	_expect(_palette.is_showing_shades(), "pressing the swap shows the shades")
	_expect(_colors.size() == emitted_before,
		"...without changing the paint colour -- swapping a VIEW is not a pick (%d new emission(s))"
		% (_colors.size() - emitted_before))
	var shades := _palette.get_color_buttons()
	_expect(shades.size() == PaletteDef.INTENSITY_STEPS,
		"the strip now holds %d shade crayons (%d)"
		% [PaletteDef.INTENSITY_STEPS, shades.size()])
	var ladder := _def.shades_of(base_color)
	var rendered := true
	for i in shades.size():
		rendered = rendered and (shades[i] as CrayonButton).crayon_color == ladder[i]
	_expect(rendered, "...which are exactly the computed ladder of the crayon in hand")
	_expect((shades[PaletteDef.INTENSITY_BASE_STEP] as CrayonButton).selected,
		"...with the crayon's own rung marked as the one in hand")
	_expect(swap.showing_shades and swap.active_step == PaletteDef.INTENSITY_BASE_STEP
			and swap.base_color == base_color,
		"the swap control shows which ladder, and which rung of it, is live")

	# --- picking a shade goes through the unchanged colour chain --------------
	var deep_step := PaletteDef.INTENSITY_STEPS - 1
	(shades[deep_step] as CrayonButton).pressed.emit()
	_expect(_colors.size() == emitted_before + 1,
		"picking a shade emits color_picked ONCE (%d)" % (_colors.size() - emitted_before))
	var resolved := _def.shade_of(base_color, deep_step)
	_expect(_colors.size() > 0 and _colors[-1] == resolved,
		"...carrying the RESOLVED colour #%s, not the crayon's own #%s"
		% [resolved.to_html(false), base_color.to_html(false)])
	_expect(_palette.get_selected_color() == resolved
			and _palette.get_selected_intensity() == deep_step,
		"...and the palette reports that shade as what is painting")
	_expect(_palette.get_selected_color_index() == 5,
		"...while the CRAYON in hand is still the one that was picked (index %d)"
		% _palette.get_selected_color_index())
	_expect(swap.active_step == deep_step,
		"the swap control followed the rung (%d)" % swap.active_step)

	# The bubble previews what will be PAINTED, which on this face is the shade.
	var preview := _palette.get_pick_preview()
	var pale_point := _center_of(shades[0])
	_send_touch(_palette, pale_point, true)
	_expect(preview.get_preview_color() == _def.shade_of(base_color, 0),
		"the pick bubble previews the resolved shade (#%s)"
		% preview.get_preview_color().to_html(false))
	_send_touch(_palette, pale_point, false)
	preview.hide_now()

	# --- swapping back, and a new crayon resetting the rung -------------------
	var before_swap_back := _palette.get_selected_color()
	swap.pressed.emit()
	await _settle()
	_expect(not _palette.is_showing_shades(), "pressing it again shows the colours")
	_expect(_palette.get_color_buttons().size() == CRAYON_COUNT,
		"...all %d of them (%d)" % [CRAYON_COUNT, _palette.get_color_buttons().size()])
	_expect(_palette.get_selected_color() == before_swap_back,
		"...with the deep shade still on the brush -- swapping back is not a pick either")
	_expect((_palette.get_color_buttons()[5] as CrayonButton).selected,
		"...and the crayon it came from still marked")

	_palette.select_color(2)
	_expect(_palette.get_selected_intensity() == PaletteDef.INTENSITY_BASE_STEP,
		"picking a NEW crayon resets the ladder to its own colour (rung %d)"
		% _palette.get_selected_intensity())
	_expect(_colors[-1] == _def.get_color(2),
		"...so the emitted colour is that crayon, plain (#%s)" % _colors[-1].to_html(false))
	_palette.select_color(0)


## (d cont.) BL-23's fun crayon boxes, rebuilt by BL-35 around FINISHES.
##
## Three claims to hold down. First, every box carries the SAME lineup -- the
## playtest verdict on five recoloured boxes was "more colour options, not more
## fun", so what makes a box a different box is now the finish it paints with.
## Second, a set carries colours and a FINISH and nothing else: a brush size or a
## threshold on a box would be a difficulty mode again, which is the thing BL-20
## deleted, and BL-35's amendment is exactly one field wide. Third, the finish
## reaches the paint path through its OWN signal -- once per box change, never
## through `color_picked` -- and the intensity ladder still works on every box
## without any box saying anything about it.
func _check_crayon_sets() -> void:
	print("\n-- check 5d: crayon boxes and their finishes (BL-23, BL-35) --")
	var sets := CrayonSetDef.discover()
	_expect(sets.size() == EXPECTED_EXTRA_SETS,
		"%d authored crayon set(s) were discovered on disk (%d)"
		% [EXPECTED_EXTRA_SETS, sets.size()])
	var names := PackedStringArray()
	for set_def in sets:
		names.append(set_def.display_name)
	var shipped := true
	for expected_name in SET_NAMES:
		shipped = shipped and names.has(expected_name)
	_expect(shipped, "...the shipped ladder of boxes (%s)" % [names])

	var orders_ascend := true
	var all_valid := true
	var carry_only_colors_and_finish := true
	var share_the_lineup := true
	var known_finishes := true
	for i in sets.size():
		var set_def := sets[i]
		all_valid = all_valid and set_def.validate().is_empty()
		if i > 0:
			orders_ascend = orders_ascend and sets[i - 1].sort_order <= set_def.sort_order
		# A set that could set a brush size or a threshold would be a difficulty
		# mode wearing a hat. The property list is the check, not a promise -- and
		# the list is unchanged by BL-35, which added `effect` and nothing else.
		for banned in ["brush_sizes", "default_brush_size", "completion_threshold",
				"default_brush_hardness", "mode"]:
			carry_only_colors_and_finish = (
				carry_only_colors_and_finish and not _has_property(set_def, banned)
			)
		known_finishes = known_finishes and BrushFinish.is_known(set_def.get_effect())
		share_the_lineup = share_the_lineup and _def.get_crayon_set_colors(i + 1) == _def.colors
	_expect(all_valid, "every set validates")
	_expect(orders_ascend, "...and they come back in authored sort_order, not filesystem order")
	_expect(carry_only_colors_and_finish,
		"a CrayonSetDef carries colours and a FINISH -- no brush, no threshold, no mode")
	_expect(known_finishes, "...and every box names a finish this build can paint")
	_expect(share_the_lineup,
		"EVERY box offers the default box's lineup -- what changes is the finish (BL-35)")

	# --- the palette presents the default box and the sets through one index ---
	_expect(_def.crayon_set_count() == sets.size() + 1,
		"the palette offers %d boxes: its own plus every set (%d)"
		% [sets.size() + 1, _def.crayon_set_count()])
	_expect(_def.get_crayon_set_colors(0) == _def.colors
			and _def.get_crayon_set_name(0) == _def.display_name,
		"box 0 IS the palette's own crayons ('%s')" % _def.get_crayon_set_name(0))
	_expect(_def.wrap_crayon_set(_def.crayon_set_count()) == 0,
		"the cycle wraps back to the default box")

	# --- the ladder: each box louder than the one before it -------------------
	var ladder: Array[StringName] = []
	for i in _def.crayon_set_count():
		ladder.append(_def.get_crayon_set_effect(i))
	_expect(ladder == FINISH_LADDER,
		"the boxes escalate: %s" % [", ".join(_finish_names(ladder))])
	_expect(_def.get_crayon_set_effect(0) == BrushFinish.CLASSIC,
		"...starting with today's plain wax, which the default box keeps untouched")
	var animated := PackedStringArray()
	for finish in ladder:
		if BrushFinish.is_animated(finish):
			animated.append(String(finish))
	_expect(animated.is_empty(),
		"every shipped finish is BAKEABLE, so the saved PNG carries it (phase 2 is"
		+ " animated finishes) -- live ones found: %s" % [animated])

	# --- set_palette primes the finish, like the size and the colour ----------
	_expect(_effects.size() == 1 and _effects[0] == BrushFinish.CLASSIC,
		"set_palette() primed the brush with exactly one finish, '%s' -- never finish-less"
		% [_effects[-1] if not _effects.is_empty() else &"<none>"])
	_expect(_palette.get_selected_effect() == BrushFinish.CLASSIC,
		"...and the palette agrees that is what is in hand")

	# --- cycling it, the way the button does ---------------------------------
	var box := _palette.get_crayon_box_button()
	_expect(box != null, "the strip carries a crayon-box control")
	if box == null:
		return
	_expect(minf(box.size.x, box.size.y) >= PaletteChild.MIN_TOUCH_TARGET,
		"...at least %.0f px to aim at (%.0fx%.0f)"
		% [PaletteChild.MIN_TOUCH_TARGET, box.size.x, box.size.y])
	_expect(box.visible and box.set_count == _def.crayon_set_count(),
		"...showing all %d boxes as pips (%d)" % [_def.crayon_set_count(), box.set_count])
	_expect(_palette.get_crayon_set_index() == 0,
		"the strip starts on the default box ('%s')" % _palette.get_crayon_set_name())

	var brush_before := _palette.get_selected_brush_size()
	var emitted_before := _colors.size()
	var effects_before := _effects.size()
	box.pressed.emit()
	await _settle()
	_expect(_palette.get_crayon_set_index() == 1,
		"pressing it fetches the next box ('%s')" % _palette.get_crayon_set_name())
	var next_colors := _def.get_crayon_set_colors(1)
	var strip := _palette.get_color_buttons()
	var swapped := strip.size() == next_colors.size()
	for i in mini(strip.size(), next_colors.size()):
		swapped = swapped and (strip[i] as CrayonButton).crayon_color == next_colors[i]
	_expect(swapped, "...and the strip is now that box's crayons, in order")
	_expect(_colors.size() == emitted_before + 1 and _colors[-1] == next_colors[0],
		"...with its first crayon in hand (#%s)" % _colors[-1].to_html(false))
	# BL-35: the finish travels on its own signal, exactly once per box change. If
	# it ever rode inside color_picked the paint path would be reaching into the
	# palette, which is the thing the contract exists to prevent.
	_expect(_effects.size() == effects_before + 1
			and _effects[-1] == _def.get_crayon_set_effect(1),
		"...and ONE brush_effect_picked, carrying the box's finish ('%s')" % [_effects[-1]])
	_expect(_palette.get_selected_effect() == _def.get_crayon_set_effect(1),
		"...which is the finish the palette says is in hand")
	var previewing := true
	for control in strip:
		previewing = previewing and (control as CrayonButton).finish == _effects[-1]
	_expect(previewing,
		"every crayon on the strip PREVIEWS that finish, so the box sells itself first")
	_expect(is_equal_approx(_palette.get_selected_brush_size(), brush_before)
			and _sizes.size() == 1,
		"the brush never moved -- a finish is how the paint looks, not how the game plays (%.0f px)"
		% _palette.get_selected_brush_size())
	_expect(_palette.get_selected_intensity() == PaletteDef.INTENSITY_BASE_STEP
			and not _palette.is_showing_shades(),
		"...and the new box opens on its own colours, not halfway up a ladder")

	# Picking a crayon or a rung inside a box is a COLOUR change and nothing else.
	var quiet := _effects.size()
	_palette.select_color(2)
	_palette.select_intensity(PaletteDef.INTENSITY_STEPS - 1)
	_expect(_effects.size() == quiet,
		"picking crayons and rungs inside a box emits no finish -- the wax did not change")
	_palette.select_color(0)

	# --- intensity on a set, for free ----------------------------------------
	var swap := _palette.get_intensity_button()
	swap.pressed.emit()
	await _settle()
	var set_base := next_colors[0]
	var set_ladder := _def.shades_of(set_base)
	var shades := _palette.get_color_buttons()
	var laddered := shades.size() == PaletteDef.INTENSITY_STEPS
	for i in mini(shades.size(), set_ladder.size()):
		laddered = laddered and (shades[i] as CrayonButton).crayon_color == set_ladder[i]
	_expect(laddered,
		"the ladder works on a SET crayon too, with nothing authored for it (BL-22 x BL-23)")
	var rungs_finished := true
	for control in shades:
		rungs_finished = rungs_finished and (control as CrayonButton).finish == _palette.get_selected_effect()
	_expect(rungs_finished,
		"...and every rung of it wears the box's finish -- same wax, different intensity")
	(shades[0] as CrayonButton).pressed.emit()
	_expect(_colors[-1] == _def.shade_of(set_base, 0),
		"...and picking its palest rung emits that resolved colour (#%s)"
		% _colors[-1].to_html(false))
	swap.pressed.emit()
	await _settle()

	# --- all the way round ----------------------------------------------------
	var walked: Array[StringName] = []
	for i in range(_palette.get_crayon_set_index(), _def.crayon_set_count()):
		box.pressed.emit()
		walked.append(_palette.get_selected_effect())
	await _settle()
	_expect(_palette.get_crayon_set_index() == 0,
		"cycling past the last box comes back to the default one ('%s')"
		% _palette.get_crayon_set_name())
	_expect(_palette.get_color_buttons().size() == CRAYON_COUNT,
		"...with its %d crayons back on the strip (%d)"
		% [CRAYON_COUNT, _palette.get_color_buttons().size()])
	_expect(walked[-1] == BrushFinish.CLASSIC and _effects[-1] == BrushFinish.CLASSIC,
		"...and the FINISH resets with the crayon and the rung -- back to plain wax")
	var strip_reset := true
	for control in _palette.get_color_buttons():
		strip_reset = strip_reset and (control as CrayonButton).finish == BrushFinish.CLASSIC
	_expect(strip_reset, "...on every crayon of it")
	_palette.select_color(0)


## Finish ids as the names a human would read them by.
static func _finish_names(ladder: Array[StringName]) -> PackedStringArray:
	var names := PackedStringArray()
	for finish in ladder:
		names.append(BrushFinish.display_name(finish))
	return names


## (e) Palette -> PageView: wiring the two signals is all the coloring screen has
## to do, and a stroke then lands in exactly the picked colour.
func _check_page_view_integration() -> void:
	print("\n-- check 6: palette -> PageView integration --")
	_expect(_page_view.load_page(BASE_IMAGE, ID_MAP, REGIONS_JSON), "page loaded into PageView")
	if not _page_view.is_page_loaded():
		return

	# Exactly the wiring the coloring screen does -- calls DOWN into PageView.
	_palette.color_picked.connect(func(c: Color) -> void: _page_view.brush_color = c)
	_palette.brush_size_picked.connect(func(s: float) -> void: _page_view.brush_size = s)
	_palette.brush_effect_picked.connect(func(e: StringName) -> void: _page_view.brush_effect = e)
	_page_view.brush_hardness = _def.default_brush_hardness

	# BL-35's third wire, and the whole of it: cycle a box, the brush is holding
	# that box's wax. Nothing in the palette reaches into the paint path to do it.
	_palette.next_crayon_set()
	_expect(_page_view.brush_effect == _def.get_crayon_set_effect(1),
		"PageView.brush_effect follows brush_effect_picked ('%s')" % _page_view.brush_effect)
	_palette.set_crayon_set(0)
	_expect(_page_view.brush_effect == BrushFinish.CLASSIC,
		"...and back to the default box puts plain wax back on the brush")

	var picked_index := 3
	_palette.select_brush_size(0)
	_palette.select_color(picked_index)
	var expected := _def.get_color(picked_index)

	_expect(_page_view.brush_color == expected,
		"PageView.brush_color follows color_picked (%s)" % _page_view.brush_color.to_html(false))
	_expect(is_equal_approx(_page_view.brush_size, _def.get_brush_size(0)),
		"PageView.brush_size (DIAMETER) follows brush_size_picked (%.0f px)" % _page_view.brush_size)

	_page_view.clear_paint()
	await _settle()
	_page_view.begin_stroke(STROKE_FROM)
	for x in range(int(STROKE_FROM.x) + 20, int(STROKE_TO.x) + 1, 20):
		_page_view.continue_stroke(Vector2(x + 0.5, STROKE_TO.y))
	_page_view.end_stroke()
	await _settle()

	var paint := _page_view.get_paint_image()
	if paint.get_format() != Image.FORMAT_RGBA8:
		paint.convert(Image.FORMAT_RGBA8)

	var worst := 0
	var soft := 0
	for sample in CORE_SAMPLES:
		var pixel := paint.get_pixel(sample.x, sample.y)
		if pixel.a8 < CORE_ALPHA:
			soft += 1
		worst = maxi(worst, absi(pixel.r8 - expected.r8))
		worst = maxi(worst, absi(pixel.g8 - expected.g8))
		worst = maxi(worst, absi(pixel.b8 - expected.b8))
	_expect(soft == 0, "all %d core samples are fully opaque (%d soft)" % [CORE_SAMPLES.size(), soft])
	_expect(worst <= COLOR_TOLERANCE,
		"core painted pixels are the picked palette colour %s (worst channel delta %d/255)"
		% [expected.to_html(false), worst])


## (f) BL-15/16: selection feedback the finger does not hide -- the floating pick
## preview and the strengthened per-item states.
##
## The bubble is driven by the GESTURE, not by the pick, so this is the one check
## that synthesises real touch events at real on-screen coordinates and feeds them
## to the palette's own `_input` -- exactly what the engine does with a finger.
func _check_selection_feedback() -> void:
	print("\n-- check 7: selection feedback (BL-15, round 2 in BL-16) --")
	# PaletteSlideInput refuses a gesture when something else is hovered (that is
	# how the settings scrim wins over the palette). In a windowed harness the real
	# cursor may be sitting anywhere, so take the two full-screen controls that are
	# not the palette out of the hover picture and let the test be deterministic.
	_page_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	($Stack as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	await _settle()

	var preview := _palette.get_pick_preview()
	_expect(preview != null, "the palette owns a PickPreview bubble")
	if preview == null:
		return
	_expect(
		preview.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"the bubble is MOUSE_FILTER_IGNORE -- it can never be hit-tested"
	)
	_expect(not preview.z_as_relative and preview.z_index > 0,
		"...and draws at an absolute z (%d), so it clears the palette AND the toolbar"
		% preview.z_index)
	_expect(not preview.is_showing(), "nothing is previewed before a finger lands")

	# --- it appears clear of the finger, follows it, and fades on release -----
	var crayons := _palette.get_color_buttons()
	var from_index := 2
	var to_index := 6
	var from_point := _center_of(crayons[from_index])
	var to_point := _center_of(crayons[to_index])

	_send_touch(_palette, from_point, true)
	_expect(preview.is_showing(), "a press on a crayon raises the bubble")
	_expect(preview.get_mode() == PickPreview.MODE_COLOR
		and preview.get_preview_color() == _def.get_color(from_index),
		"...showing the candidate colour #%s" % preview.get_preview_color().to_html(false))
	var bubble := preview.get_viewport_rect_of_bubble()
	_expect(bubble.end.y <= from_point.y,
		"the bubble sits entirely ABOVE the touch point (bottom %.0f <= finger %.0f)"
		% [bubble.end.y, from_point.y])
	_expect(not bubble.has_point(from_point), "...so the finger cannot be covering it")
	# BL-16 part 3: twice the size, floated higher. The numbers are asserted rather
	# than eyeballed because "make it bigger" is exactly the kind of change that
	# quietly gets tuned back down.
	_expect(PickPreview.BUBBLE_RADIUS >= 92.0 and bubble.size.x >= 184.0,
		"the bubble is drawn at DOUBLE the BL-15 size (radius %.0f px, %.0f px across)"
		% [PickPreview.BUBBLE_RADIUS, bubble.size.x])
	_expect(from_point.y - bubble.end.y >= PickPreview.FINGER_GAP - 1.0,
		"...and floats %.0f px clear of the press point, above the hand and not just the fingertip"
		% (from_point.y - bubble.end.y))

	_send_drag(_palette, from_point, to_point)
	_expect(preview.get_preview_color() == _def.get_color(to_index),
		"sliding to another crayon updates the candidate (#%s)"
		% preview.get_preview_color().to_html(false))
	_expect(_palette.get_selected_color_index() == to_index,
		"...and slide-to-select still commits the pick underneath it (index %d)"
		% _palette.get_selected_color_index())
	var moved := preview.get_viewport_rect_of_bubble()
	_expect(moved.position.x > bubble.position.x,
		"the bubble travelled with the finger (%.0f -> %.0f px)"
		% [bubble.position.x, moved.position.x])
	_expect(moved.end.y <= to_point.y, "...staying above it the whole way")

	_send_touch(_palette, to_point, false)
	_expect(not preview.is_active(), "lifting the finger ends the preview")
	await _wait(PickPreview.FADE_OUT_SECONDS + 0.15)
	_expect(not preview.is_showing(), "...and it has faded away")

	# --- BL-16 part 2: every way a gesture can end fades the bubble -----------
	# The bug this is guarding: a bubble left painted over the palette because the
	# release took a path nobody had walked. The claimed-slide path is covered
	# above; these are the ones that BYPASS PaletteSlideInput's own bookkeeping.
	preview.show_color(_def.get_color(1), from_point)
	_expect(preview.is_showing(), "precondition: a bubble is up")
	# A release the slide helper never saw the press for -- a press it refused
	# (outside its hit area, another control hovered) still raised this through the
	# crayon button itself.
	_send_touch(_palette, Vector2(4.0, 4.0), false)
	_expect(not preview.is_active(),
		"a release the slide helper never claimed still ends the preview")

	preview.show_color(_def.get_color(1), from_point)
	_send_mouse_release(_palette, from_point)
	_expect(not preview.is_active(),
		"...and so does a plain mouse release, for a build without touch emulation")

	# Focus loss: the web build's finger that leaves the canvas, the tab that goes
	# away. No release event is ever delivered, so the bubble has to save itself.
	preview.show_color(_def.get_color(1), from_point)
	preview.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_expect(not preview.is_showing(),
		"losing application focus mid-slide hides the bubble at once")

	# A palette rebuilt under a finger takes its bubble down with it rather than
	# leaving one floating over the new row.
	preview.show_color(_def.get_color(1), from_point)
	_palette.set_palette(_def)
	_expect(not _palette.get_pick_preview().is_showing(),
		"rebuilding the palette clears the bubble")
	_palette.select_color(0)

	# --- BL-16 part 4: per-item selected states, louder again ----------------
	var crayons_now := _palette.get_color_buttons()
	_palette.select_color(3)
	var selected_crayon := crayons_now[3] as CrayonButton
	_expect(CrayonButton.LIFT_PX >= CrayonButton.DEFAULT_SIZE.x * 0.45,
		"a selected crayon lifts %.0f px, half its own width" % CrayonButton.LIFT_PX)
	_expect(
		CrayonButton.SELECTED_WIDTH_SCALE > CrayonButton.HOVER_WIDTH_SCALE
		and CrayonButton.HOVER_WIDTH_SCALE > CrayonButton.IDLE_WIDTH_SCALE
		and CrayonButton.SELECTED_WIDTH_SCALE >= CrayonButton.IDLE_WIDTH_SCALE * 1.4,
		"...and is %.2fx the width of an unselected one"
		% (CrayonButton.SELECTED_WIDTH_SCALE / CrayonButton.IDLE_WIDTH_SCALE)
	)
	_expect(CrayonButton.GLOW_LAYERS >= 8 and CrayonButton.GLOW_ALPHA >= 0.20,
		"the halo behind it gained layers (%d) and opacity (%.2f)"
		% [CrayonButton.GLOW_LAYERS, CrayonButton.GLOW_ALPHA])
	_expect(selected_crayon.is_bouncing()
		and selected_crayon.current_lift() > CrayonButton.LIFT_PX,
		"picking a crayon springs it past its resting lift (%.0f px of %.0f)"
		% [selected_crayon.current_lift(), CrayonButton.LIFT_PX])
	_expect(CrayonButton.LIFT_HEADROOM >= CrayonButton.LIFT_PX * CrayonButton.SELECT_BOUNCE_SCALE,
		"...into headroom the box already reserved, so the row's scroller cannot clip the peak")
	await _wait(CrayonButton.SELECT_BOUNCE_SECONDS + 0.2)
	_expect(is_equal_approx(selected_crayon.current_lift(), CrayonButton.LIFT_PX),
		"...and settles at exactly the resting lift (%.1f px)" % selected_crayon.current_lift())
	_expect((crayons_now[4] as CrayonButton).current_lift() == 0.0,
		"an unselected crayon does not lift at all")


## (g) GameState: one palette, no mode surface, and a save that still tolerates
## the vestigial "mode" key without ever writing one (BL-20).
func _check_game_state() -> void:
	print("\n-- check 8: GameState after BL-20 --")
	GameState.reload_palettes()
	# Point saves at an empty scratch root: this check writes files, and the
	# player's own save must never be touched by a smoke run.
	GameState.set_save_root(TEST_SAVE_ROOT)
	_delete_recursive(TEST_SAVE_ROOT)
	DirAccess.make_dir_recursive_absolute(TEST_SAVE_ROOT)

	var active := GameState.get_active_palette()
	_expect(active != null and active.resource_path == PALETTE,
		"get_active_palette() returns the one crayon palette (%s)"
		% [active.resource_path if active else "null"])
	_expect(active == GameState.get_active_palette(),
		"...cached, so everything shares one instance")
	_expect(GameState.get_palette_scene_path() == "res://scenes/components/palette_child.tscn",
		"get_palette_scene_path() is the crayon row (%s)" % GameState.get_palette_scene_path())

	# The mode API is gone, not merely unused: nothing can put the game back into
	# two halves by accident.
	_expect(not _has_property(GameState, "mode"), "GameState has no 'mode' property")
	_expect(not GameState.has_method("set_mode"), "...no set_mode()")
	_expect(not GameState.has_method("get_palette_for_mode"), "...no get_palette_for_mode()")
	_expect(not GameState.has_signal("mode_changed"), "...and no mode_changed signal")

	# A save written by a pre-BL-20 build still loads at the SAME schema version --
	# which is the whole reason SAVE_VERSION did not have to move.
	_expect(GameState.VESTIGIAL_SAVE_KEYS.has("mode"),
		"'mode' is declared as a key this build reads past (%s)"
		% [GameState.VESTIGIAL_SAVE_KEYS])
	var legacy := '{"version": %d, "mode": "adult", "books": {}}' % GameState.SAVE_VERSION
	var file := FileAccess.open(GameState.get_save_path(), FileAccess.WRITE)
	if file != null:
		file.store_string(legacy)
		file.close()
	_expect(GameState.load_save(), "a save carrying the old \"mode\" key still loads")
	GameState.save_now()
	var written: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(GameState.get_save_path())
	)
	_expect(int(written.get("version", -1)) == GameState.SAVE_VERSION,
		"...and is written back at the same schema v%d (%s)"
		% [GameState.SAVE_VERSION, written.get("version")])
	_expect(not written.has("mode"),
		"...with the vestigial key dropped, because nothing reads it any more")
	_delete_recursive(TEST_SAVE_ROOT)


## Leaves a deliberate, readable selection on screen for the human/screenshot pass.
func _showcase() -> void:
	_palette.select_color(SHOWCASE_INDEX)
	await _settle()
	# BL-15: park a bubble over the showcase crayon so the screenshot shows the
	# thing a still frame otherwise never catches.
	var crayons := _palette.get_color_buttons()
	if SHOWCASE_INDEX < crayons.size():
		_palette.get_pick_preview().show_color(
			_def.get_color(SHOWCASE_INDEX), _center_of(crayons[SHOWCASE_INDEX])
		)
	await _settle()


# =================================================================== helpers ==

func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("%s - %s" % ["PASS" if condition else "FAIL", description])


func _settle() -> void:
	for i in 8:
		await get_tree().process_frame
		if not _page_view.has_pending_paint():
			break
	await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## True when [param object] really exposes a property called [param name]. Used to
## assert that a property is GONE, which `object.name` cannot do without erroring.
static func _has_property(object: Object, name: String) -> bool:
	for entry in object.get_property_list():
		if String(entry.get("name", "")) == name:
			return true
	return false


static func _delete_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := path.path_join(entry)
		if dir.current_is_dir():
			_delete_recursive(child)
		else:
			DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


## Middle of [param control], in viewport coordinates -- where a finger aiming at
## it would actually land.
static func _center_of(control: Control) -> Vector2:
	return control.get_global_transform_with_canvas() * (control.size * 0.5)


## One synthetic finger down/up at a viewport position, fed straight to the
## palette's `_input` the way the engine feeds it real ones.
static func _send_touch(palette: Control, viewport_position: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.position = viewport_position
	event.pressed = pressed
	palette._input(event)


## A mouse button release, for the path a build without touch emulation takes.
static func _send_mouse_release(palette: Control, viewport_position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = viewport_position
	event.pressed = false
	palette._input(event)


static func _send_drag(palette: Control, from_position: Vector2, to_position: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = 0
	event.position = to_position
	event.relative = to_position - from_position
	palette._input(event)


func _smallest_target(controls: Array[Control]) -> float:
	var smallest := INF
	for control in controls:
		smallest = minf(smallest, minf(control.size.x, control.size.y))
	return 0.0 if smallest == INF else smallest


static func _all_positive(sizes: PackedFloat32Array) -> bool:
	for value in sizes:
		if value <= 0.0:
			return false
	return not sizes.is_empty()


## (BL-35 deleted `_closest_pair`, which measured a SET's own colour separation:
## the sets do not author colours any more, so the default lineup's separation --
## `_closest_color_pair` below -- is the only one there is to measure.)
func _closest_color_pair() -> Dictionary:
	var best := {"a": -1, "b": -1, "distance": INF}
	var colors := _def.colors
	for i in colors.size():
		for j in range(i + 1, colors.size()):
			var d := Vector3(colors[i].r, colors[i].g, colors[i].b).distance_to(
				Vector3(colors[j].r, colors[j].g, colors[j].b)
			)
			if d < float(best["distance"]):
				best = {"a": i, "b": j, "distance": d}
	return best


static func _hex_list(colors: Array[Color]) -> PackedStringArray:
	var out := PackedStringArray()
	for color in colors:
		out.append("#" + color.to_html(false))
	return out


## `--shot <path>` from the user args, or "" when not asked for.
static func _shot_path() -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--shot")
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return ""

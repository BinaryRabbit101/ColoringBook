extends Control
## Automated verification for Milestone 3 -- palettes, difficulty modes, GameState.
##
## Run WINDOWED (the integration check paints into a SubViewport, which renders
## nothing under --headless / the dummy rasteriser):
##
##   <godot_exe> --path <project> res://scenes/dev/palette_smoke.tscn
##
## Extra user args (after a bare `--`):
##   --stay          leave the window open with both palettes over the page
##   --shot <path>   save a PNG of the viewport to <path> before quitting
##
## Every pick goes through the same entry points the touch path uses: a real
## BaseButton `pressed` emission, a `BrushSizeSlider.pick_at_local_x()` at a real
## stop position, or the `select_color` / `select_brush_size` handlers those call.
## Exit code is 0 only if every check passes.

const CHILD_PALETTE := "res://resources/palettes/child_palette.tres"
const ADULT_PALETTE := "res://resources/palettes/adult_palette.tres"

const BASE_IMAGE := "res://assets/books/test_book/page_01.png"
const ID_MAP := "res://assets/books/test_book/page_01_idmap.png"
const REGIONS_JSON := "res://assets/books/test_book/page_01_regions.json"

## Expected authored shape of the shipped palettes.
const CHILD_COLOR_COUNT := 10
const MIN_ADULT_COLOR_COUNT := 24
const ADULT_BRUSH_SIZE_COUNT := 3
const ADULT_FAMILY_COUNT := 6

## Minimum perceptual separation between two child crayons, as an RGB distance
## (0..sqrt(3)). Kids must never confuse two crayons.
const MIN_CHILD_COLOR_DISTANCE := 0.25

## Per-channel tolerance (0..255) when checking painted pixels against the picked
## palette colour.
const COLOR_TOLERANCE := 2
## Alpha byte at/above which a painted pixel counts as "core" (not soft edge).
const CORE_ALPHA := 250

## Page pixels inside region 4 (the big circle) used by the integration stroke.
const STROKE_FROM := Vector2(700.5, 250.5)
const STROKE_TO := Vector2(840.5, 250.5)
const CORE_SAMPLES: Array[Vector2i] = [Vector2i(700, 250), Vector2i(770, 250), Vector2i(840, 250)]

## Selection left on screen for the human-eyeball / screenshot pass.
const SHOWCASE_CHILD_INDEX := 4
const SHOWCASE_ADULT_INDEX := 14
const SHOWCASE_ADULT_SIZE_INDEX := 2

@onready var _page_view: PageView = $PageView
@onready var _child_palette: PaletteChild = $Stack/PaletteChild
@onready var _adult_palette: PaletteAdult = $Stack/PaletteAdult

var _child_def: PaletteDef
var _adult_def: PaletteDef

var _child_colors: Array[Color] = []
var _child_sizes: Array[float] = []
var _adult_colors: Array[Color] = []
var _adult_sizes: Array[float] = []
var _mode_events: Array[String] = []

var _checks := 0
var _failures := 0


func _ready() -> void:
	# Both palettes plus a usable page need vertical room; the dev scene sizes its
	# own window so the layout is not judged against Godot's default 1152x648.
	get_window().size = Vector2i(1280, 940)
	await get_tree().process_frame
	_run()


func _run() -> void:
	print("=== M3 palette smoke test ===")

	_check_palette_resources()
	_check_components_built()
	await _check_touch_targets()
	_check_auto_selection()
	_check_simulated_picks()
	await _check_page_view_integration()
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

## (a) The authored .tres files load and hold sane data.
func _check_palette_resources() -> void:
	print("\n-- check 1: PaletteDef resources --")
	_child_def = load(CHILD_PALETTE) as PaletteDef
	_adult_def = load(ADULT_PALETTE) as PaletteDef
	_expect(_child_def != null, "%s loads as a PaletteDef" % CHILD_PALETTE)
	_expect(_adult_def != null, "%s loads as a PaletteDef" % ADULT_PALETTE)
	if _child_def == null or _adult_def == null:
		return

	_expect(_child_def.validate().is_empty(), "child palette validates (%s)" % [_child_def.validate()])
	_expect(_adult_def.validate().is_empty(), "adult palette validates (%s)" % [_adult_def.validate()])

	_expect(_child_def.mode == PaletteDef.MODE_CHILD, "child palette declares mode 'child' (%s)" % _child_def.mode)
	_expect(_adult_def.mode == PaletteDef.MODE_ADULT, "adult palette declares mode 'adult' (%s)" % _adult_def.mode)

	_expect(_child_def.color_count() == CHILD_COLOR_COUNT,
		"child palette has %d colours (%d)" % [CHILD_COLOR_COUNT, _child_def.color_count()])
	_expect(_adult_def.color_count() >= MIN_ADULT_COLOR_COUNT,
		"adult palette has >= %d colours (%d)" % [MIN_ADULT_COLOR_COUNT, _adult_def.color_count()])
	_expect(_adult_def.family_count() == ADULT_FAMILY_COUNT,
		"adult palette groups into %d shade families of %d (%d x %d)"
		% [ADULT_FAMILY_COUNT, _adult_def.effective_shades_per_family(),
			_adult_def.family_count(), _adult_def.effective_shades_per_family()])

	var closest := _closest_child_color_pair()
	_expect(float(closest["distance"]) >= MIN_CHILD_COLOR_DISTANCE,
		"child colours are well differentiated (closest pair %d/%d, distance %.3f >= %.2f)"
		% [int(closest["a"]), int(closest["b"]), float(closest["distance"]), MIN_CHILD_COLOR_DISTANCE])

	_expect(_child_def.brush_size_count() == 1,
		"child palette offers one forgiving brush size (%s)" % [_child_def.brush_sizes])
	_expect(_adult_def.brush_size_count() == ADULT_BRUSH_SIZE_COUNT,
		"adult palette offers %d brush sizes (%s)" % [ADULT_BRUSH_SIZE_COUNT, _adult_def.brush_sizes])
	_expect(_all_positive(_child_def.brush_sizes) and _all_positive(_adult_def.brush_sizes),
		"every brush size (diameter, page px) is positive")
	_expect(_child_def.get_brush_size(0) > _adult_def.get_brush_size(0),
		"child's brush (%.0f px) is larger than the adult's finest (%.0f px)"
		% [_child_def.get_brush_size(0), _adult_def.get_brush_size(0)])

	for def in [_child_def, _adult_def]:
		var threshold: float = def.completion_threshold
		_expect(threshold > 0.0 and threshold <= 1.0,
			"%s completion_threshold %.2f is in (0, 1]" % [def.mode, threshold])
	_expect(_child_def.completion_threshold < _adult_def.completion_threshold,
		"child threshold %.2f is more generous than adult %.2f"
		% [_child_def.completion_threshold, _adult_def.completion_threshold])


## (b) Both components build the expected controls from their def.
func _check_components_built() -> void:
	print("\n-- check 2: components build from the def --")
	# Recorders go on BEFORE set_palette so the auto-selection emission is caught.
	_child_palette.color_picked.connect(func(c: Color) -> void: _child_colors.append(c))
	_child_palette.brush_size_picked.connect(func(s: float) -> void: _child_sizes.append(s))
	_adult_palette.color_picked.connect(func(c: Color) -> void: _adult_colors.append(c))
	_adult_palette.brush_size_picked.connect(func(s: float) -> void: _adult_sizes.append(s))

	_child_palette.set_palette(_child_def)
	_adult_palette.set_palette(_adult_def)

	var crayons := _child_palette.get_color_buttons()
	_expect(crayons.size() == CHILD_COLOR_COUNT,
		"child renders %d crayon controls (%d)" % [CHILD_COLOR_COUNT, crayons.size()])
	var all_crayons := true
	for control in crayons:
		all_crayons = all_crayons and control is CrayonButton
	_expect(all_crayons, "every child control is a CrayonButton")
	_expect(_child_palette.get_brush_size_controls().is_empty(),
		"child exposes no size control (one forgiving brush)")

	var swatches := _adult_palette.get_color_buttons()
	_expect(swatches.size() == _adult_def.color_count(),
		"adult renders all %d swatches (%d)" % [_adult_def.color_count(), swatches.size()])
	_expect(_adult_palette.get_family_column_count() == ADULT_FAMILY_COUNT,
		"adult grid has %d shade-family columns (%d)"
		% [ADULT_FAMILY_COUNT, _adult_palette.get_family_column_count()])
	var slider := _adult_palette.get_brush_size_slider()
	_expect(slider != null and slider.stop_count() == ADULT_BRUSH_SIZE_COUNT,
		"adult renders one brush-size slider with %d stops (%d)"
		% [ADULT_BRUSH_SIZE_COUNT, slider.stop_count() if slider else -1])
	var stops_grow := slider != null
	for i in range(1, slider.stop_count() if slider else 0):
		stops_grow = (
			stops_grow
			and is_equal_approx(slider.get_size_at(i), _adult_def.get_brush_size(i))
			and slider.knob_radius_for_index(i) > slider.knob_radius_for_index(i - 1)
			and slider.local_x_for_index(i) > slider.local_x_for_index(i - 1)
		)
	_expect(stops_grow, "slider stops are the def's diameters, drawn larger left to right")

	var swatch_colors_match := true
	for i in swatches.size():
		swatch_colors_match = swatch_colors_match and (swatches[i] as SwatchButton).swatch_color == _adult_def.get_color(i)
	_expect(swatch_colors_match, "every swatch carries its def colour, in palette order")


## (b cont.) Touch targets, measured after layout, in both orientations.
func _check_touch_targets() -> void:
	print("\n-- check 3: touch targets and orientation --")
	await _settle()
	_measure_targets("landscape 1280x940")

	# Portrait: the row/grid must survive a narrow window (they scroll).
	get_window().size = Vector2i(720, 1180)
	await _settle()
	_measure_targets("portrait 720x1180")
	var row_fits := true
	for control in _child_palette.get_color_buttons():
		row_fits = row_fits and control.global_position.y >= 0.0
	_expect(row_fits, "child row still lays out inside the panel when narrow")

	get_window().size = Vector2i(1280, 940)
	await _settle()


func _measure_targets(label: String) -> void:
	var child_min := _smallest_target(_child_palette.get_color_buttons())
	_expect(child_min >= PaletteChild.MIN_TOUCH_TARGET,
		"[%s] every crayon target >= %.0f px (smallest %.1f px)"
		% [label, PaletteChild.MIN_TOUCH_TARGET, child_min])

	var adult_controls := _adult_palette.get_color_buttons()
	adult_controls.append_array(_adult_palette.get_brush_size_controls())
	var adult_min := _smallest_target(adult_controls)
	_expect(adult_min >= PaletteAdult.MIN_TOUCH_TARGET,
		"[%s] every swatch/size-dot target >= %.0f px (smallest %.1f px)"
		% [label, PaletteAdult.MIN_TOUCH_TARGET, adult_min])


## (c) set_palette auto-selects the first colour and the default brush size,
## emitting each signal exactly once, so the brush is never colourless.
func _check_auto_selection() -> void:
	print("\n-- check 4: auto-selection on set_palette --")
	_expect(_child_colors.size() == 1,
		"child emitted color_picked exactly once on set_palette (%d)" % _child_colors.size())
	_expect(_child_colors.size() == 1 and _child_colors[0] == _child_def.get_color(0),
		"child auto-picked the FIRST colour (%s vs %s)"
		% [_child_colors[0] if _child_colors.size() > 0 else "none", _child_def.get_color(0)])
	_expect(_child_sizes.size() == 1 and is_equal_approx(_child_sizes[0], _child_def.default_brush_size),
		"child auto-picked its default brush size %.0f px (%s)"
		% [_child_def.default_brush_size, _child_sizes])
	_expect(_child_palette.get_selected_color_index() == 0, "child reports selected index 0")

	_expect(_adult_colors.size() == 1,
		"adult emitted color_picked exactly once on set_palette (%d)" % _adult_colors.size())
	_expect(_adult_colors.size() == 1 and _adult_colors[0] == _adult_def.get_color(0),
		"adult auto-picked the FIRST colour")
	_expect(_adult_sizes.size() == 1 and is_equal_approx(_adult_sizes[0], _adult_def.default_brush_size),
		"adult auto-picked its default brush size %.0f px (%s)"
		% [_adult_def.default_brush_size, _adult_sizes])
	var default_size_index := _adult_def.get_default_brush_size_index()
	var slider := _adult_palette.get_brush_size_slider()
	_expect(
		slider != null and slider.get_selected_index() == default_size_index,
		"the slider knob sits on the default size stop (index %d, knob at %d)"
		% [default_size_index, slider.get_selected_index() if slider else -1]
	)


## (d) Picks made through the real button path carry the def's own values.
func _check_simulated_picks() -> void:
	print("\n-- check 5: simulated picks --")
	var crayons := _child_palette.get_color_buttons()
	var expected_child: Array[Color] = []
	for index in [3, 7, 0, 9]:
		expected_child.append(_child_def.get_color(index))
		# The real input path: BaseButton reports `pressed`, which is wired to
		# PaletteChild.select_color(index).
		(crayons[index] as CrayonButton).pressed.emit()
	var got_child := _child_colors.slice(1)
	_expect(got_child == expected_child,
		"child crayon presses emitted the def's colours in order (%s)" % [_hex_list(got_child)])
	_expect((crayons[9] as CrayonButton).selected and not (crayons[0] as CrayonButton).selected,
		"only the last-pressed crayon is marked selected")
	_expect(_child_palette.get_selected_color() == _child_def.get_color(9),
		"child reports the last picked colour (%s)" % _child_palette.get_selected_color().to_html(false))

	var swatches := _adult_palette.get_color_buttons()
	var expected_adult: Array[Color] = []
	for index in [1, 12, 23]:
		expected_adult.append(_adult_def.get_color(index))
		(swatches[index] as SwatchButton).pressed.emit()
	var got_adult := _adult_colors.slice(1)
	_expect(got_adult == expected_adult,
		"adult swatch presses emitted the def's colours in order (%s)" % [_hex_list(got_adult)])

	# The slider's own pick entry point, driven at each stop's real x position --
	# exactly what a finger sliding along the bar produces.
	var slider := _adult_palette.get_brush_size_slider()
	var expected_sizes: Array[float] = []
	for index in slider.stop_count():
		expected_sizes.append(_adult_def.get_brush_size(index))
		slider.pick_at_local_x(slider.local_x_for_index(index))
	var got_sizes := _adult_sizes.slice(1)
	_expect(got_sizes == expected_sizes,
		"sliding across the brush-size bar emitted the def's diameters (%s, expected %s)"
		% [got_sizes, expected_sizes])
	_expect(is_equal_approx(_adult_palette.get_selected_brush_size(), _adult_def.get_brush_size(slider.stop_count() - 1)),
		"adult reports the last picked brush size (%.0f px)" % _adult_palette.get_selected_brush_size())


## (e) Palette -> PageView: wiring the two signals is all the coloring screen has
## to do, and a stroke then lands in exactly the picked colour.
func _check_page_view_integration() -> void:
	print("\n-- check 6: palette -> PageView integration --")
	_expect(_page_view.load_page(BASE_IMAGE, ID_MAP, REGIONS_JSON), "page loaded into PageView")
	if not _page_view.is_page_loaded():
		return

	# Exactly the wiring the coloring screen will do -- calls DOWN into PageView.
	_child_palette.color_picked.connect(func(c: Color) -> void: _page_view.brush_color = c)
	_child_palette.brush_size_picked.connect(func(s: float) -> void: _page_view.brush_size = s)
	_page_view.brush_hardness = _child_def.default_brush_hardness

	var picked_index := 3
	_child_palette.select_brush_size(0)
	_child_palette.select_color(picked_index)
	var expected := _child_def.get_color(picked_index)

	_expect(_page_view.brush_color == expected,
		"PageView.brush_color follows color_picked (%s)" % _page_view.brush_color.to_html(false))
	_expect(is_equal_approx(_page_view.brush_size, _child_def.get_brush_size(0)),
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


## (f) GameState: default mode, palette lookup, mode_changed.
func _check_game_state() -> void:
	print("\n-- check 7: GameState --")
	GameState.reload_palettes()
	# M5: the mode is persisted, so a real save could have put the game in adult
	# mode before this test ran. Point saves at an empty scratch root -- loading
	# nothing restores the shipped defaults, which is exactly what is asserted
	# below.
	GameState.set_save_root("user://palette_smoke/state")
	GameState.mode_changed.connect(_on_mode_changed)

	_expect(GameState.mode == PaletteDef.MODE_CHILD,
		"default mode is 'child' (%s)" % GameState.mode)
	var active := GameState.get_active_palette()
	_expect(active != null and active.mode == PaletteDef.MODE_CHILD,
		"get_active_palette() returns the child palette (%s)" % [active.resource_path if active else "null"])
	_expect(active == _child_def, "it is the same resource instance the test loaded (cached, not re-read)")
	_expect(GameState.get_palette_scene_path() == "res://scenes/components/palette_child.tscn",
		"child mode maps to palette_child.tscn")

	GameState.mode = PaletteDef.MODE_ADULT
	_expect(_mode_events == ["adult"], "mode_changed emitted once with 'adult' (%s)" % [_mode_events])
	var adult_active := GameState.get_active_palette()
	_expect(adult_active == _adult_def, "get_active_palette() now returns the adult palette")
	_expect(adult_active.completion_threshold > _child_def.completion_threshold,
		"the swapped palette carries the stricter adult threshold (%.2f)" % adult_active.completion_threshold)
	_expect(GameState.get_palette_scene_path() == "res://scenes/components/palette_adult.tscn",
		"adult mode maps to palette_adult.tscn")

	GameState.mode = PaletteDef.MODE_ADULT
	_expect(_mode_events == ["adult"], "re-assigning the same mode emits nothing (%s)" % [_mode_events])

	GameState.mode = PaletteDef.MODE_CHILD
	_expect(_mode_events == ["adult", "child"], "switching back emits 'child' (%s)" % [_mode_events])
	GameState.mode_changed.disconnect(_on_mode_changed)


func _on_mode_changed(mode: String) -> void:
	_mode_events.append(mode)


## Leaves a deliberate, readable selection on screen for the human/screenshot pass.
func _showcase() -> void:
	_child_palette.select_color(SHOWCASE_CHILD_INDEX)
	_adult_palette.select_color(SHOWCASE_ADULT_INDEX)
	_adult_palette.select_brush_size(SHOWCASE_ADULT_SIZE_INDEX)
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


func _closest_child_color_pair() -> Dictionary:
	var best := {"a": -1, "b": -1, "distance": INF}
	var colors := _child_def.colors
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

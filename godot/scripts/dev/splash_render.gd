extends Control
## Dev tool (BL-13) -- draws the app's boot splash and writes it to
## [constant OUTPUT_PATH].
##
## Run WINDOWED (it renders through a SubViewport, which produces nothing under
## the headless dummy rasteriser), then re-import:
##
##   <godot_exe> --path <project> res://scenes/dev/splash_render.tscn
##   <godot_exe> --path <project> --headless --import
##
## Extra user args (after a bare `--`):
##   --out <res://path.png>   where to write (default [constant OUTPUT_PATH])
##   --stay                   leave the window up with the splash on screen
##
## [b]Why a generator and not a hand-painted PNG.[/b] The splash has to be the
## title screen at a standstill, and the title screen is drawn from primitives in
## palette colours ([TitleScreen] ships no art assets on purpose). Authoring the
## splash the same way means the two cannot drift: re-run this after a palette
## change and the boot splash follows.
##
## [b]The Godot logo stays on it[/b] (decision 2026-08-06, BL-13): as an
## attribution mark along the bottom edge -- "made with Godot" next to the engine
## icon -- not as the centrepiece. The logo is CC-BY-4.0 and this is exactly the
## use that licence is for.
##
## [b]The background colour is load-bearing[/b]: [constant BACKDROP] is the same
## colour as [code]application/boot_splash/bg_color[/code], the web shell's page
## background and [code]main.tscn[/code]'s own backdrop, so the browser shell, the
## engine splash and the first frame of the game are one continuous colour with no
## flash between them.

## Where the splash is written, and what project.godot points at.
const OUTPUT_PATH := "res://assets/splash/boot_splash.png"
## Square, so the same image frames well in portrait and in landscape (the engine
## scales it to fit and fills the rest with bg_color).
const CANVAS_SIZE := Vector2i(1024, 1024)

## The one colour shared by project.godot's bg_color, the web shell page and
## main.tscn's backdrop.
const BACKDROP := Color(0.121569, 0.109804, 0.101961)
## Warm paper, from title_screen.tscn's panel style.
const PAPER := Color(0.988235, 0.976471, 0.956863)
const PAPER_EDGE := Color(0.85098, 0.815686, 0.760784)
## Ink the lettering is outlined with, so every crayon colour reads on paper.
const INK := Color(0.176471, 0.129412, 0.09)
const ATTRIBUTION := Color(0.560784, 0.521569, 0.478431)

## Palette indices used for the lettering: the bold half of the crayon box (the
## pale yellow would disappear against the paper). Same rule as [TitleScreen].
const TITLE_COLOR_INDICES: PackedInt32Array = [0, 1, 3, 4, 5, 6, 7, 8]
const TITLE_LINES: PackedStringArray = ["Coloring", "Book"]
const LETTER_TILT_DEGREES := 5.0
const TITLE_FONT_SIZE := 104
const TITLE_OUTLINE := 16
const LINE_SPACING := 18.0

const PAPER_RECT := Rect2(96.0, 150.0, 832.0, 566.0)
const PAPER_CORNER := 26.0

## Crayons fanned along the bottom, the same shape [CrayonButton] draws.
const CRAYON_COUNT := 7
const CRAYON_FAN_DEGREES := 6.0
const CRAYON_SIZE := Vector2(74.0, 210.0)
const CRAYON_SHELF_Y := 812.0

## The engine mark, kept as its OWN asset rather than read from
## [code]config/icon[/code]. It used to be the latter, back when the project icon
## was still the stock Godot one -- which made the attribution accidental: point
## [code]config/icon[/code] at the app's own icon (BL-13 follow-up) and the
## "made with Godot" credit would quietly become "made with ColoringBook". This
## file is a copy of Godot's icon and must stay the ENGINE logo forever.
const LOGO_PATH := "res://assets/splash/godot_logo.svg"
const LOGO_SIZE := 46.0
const ATTRIBUTION_TEXT := "made with Godot"
const ATTRIBUTION_FONT_SIZE := 26


## The splash itself: one [Control] that draws the whole picture, so it can be
## rendered to a SubViewport here and looked at in a window during a `--stay` run.
class SplashArt extends Control:
	var palette: PaletteDef
	var logo: Texture2D

	func _init(palette_def: PaletteDef, logo_texture: Texture2D) -> void:
		palette = palette_def
		logo = logo_texture
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), BACKDROP)
		_draw_paper()
		_draw_title()
		_draw_scribble()
		_draw_crayons()
		_draw_attribution()

	# ------------------------------------------------------------------ paper --

	func _draw_paper() -> void:
		var shadow := PAPER_RECT.grow(10.0)
		shadow.position.y += 14.0
		draw_rect_rounded(shadow, Color(0.0, 0.0, 0.0, 0.28), PAPER_CORNER + 6.0)
		draw_rect_rounded(PAPER_RECT, PAPER, PAPER_CORNER)
		draw_rect_rounded(PAPER_RECT, PAPER_EDGE, PAPER_CORNER, 3.0)

	## Rounded rectangle from primitives: filled when [param width] is < 0,
	## outlined otherwise. [method CanvasItem.draw_rect] has no corner radius, and
	## a StyleBox would drag a theme into a picture that has no nodes in it.
	func draw_rect_rounded(rect: Rect2, color: Color, radius: float, width: float = -1.0) -> void:
		var r := minf(radius, minf(rect.size.x, rect.size.y) * 0.5)
		var points := PackedVector2Array()
		var corners: Array[Vector2] = [
			rect.position + Vector2(r, r),
			rect.position + Vector2(rect.size.x - r, r),
			rect.position + Vector2(rect.size.x - r, rect.size.y - r),
			rect.position + Vector2(r, rect.size.y - r),
		]
		for i in 4:
			var start := PI + float(i) * TAU * 0.25
			for step in 9:
				var angle := start + TAU * 0.25 * float(step) / 8.0
				points.append(corners[i] + Vector2(cos(angle), sin(angle)) * r)
		if width < 0.0:
			draw_colored_polygon(points, color)
		else:
			points.append(points[0])
			draw_polyline(points, color, width, true)

	# ------------------------------------------------------------------ title --

	## Per-letter, alternately tilted, each in its own crayon colour with an ink
	## outline -- the hand-lettered look [TitleScreen] builds out of TiltedLabels.
	func _draw_title() -> void:
		var font := get_theme_default_font()
		var colors := _title_colors()
		var line_height := font.get_height(TITLE_FONT_SIZE)
		var block_height := line_height * float(TITLE_LINES.size()) \
			+ LINE_SPACING * float(TITLE_LINES.size() - 1)
		var y := PAPER_RECT.position.y + 74.0 + font.get_ascent(TITLE_FONT_SIZE)
		var letter_index := 0
		for line in TITLE_LINES:
			var widths := PackedFloat32Array()
			var total := 0.0
			for i in line.length():
				var w := font.get_string_size(
					line[i], HORIZONTAL_ALIGNMENT_LEFT, -1, TITLE_FONT_SIZE
				).x
				widths.append(w)
				total += w
			var x := PAPER_RECT.position.x + (PAPER_RECT.size.x - total) * 0.5
			for i in line.length():
				var tilt := deg_to_rad(LETTER_TILT_DEGREES * (1.0 if i % 2 == 0 else -1.0))
				var color := colors[letter_index % colors.size()]
				var center := Vector2(x + widths[i] * 0.5, y - line_height * 0.3)
				draw_set_transform(center, tilt, Vector2.ONE)
				var origin := Vector2(-widths[i] * 0.5, line_height * 0.3)
				font.draw_string_outline(
					get_canvas_item(), origin, line[i], HORIZONTAL_ALIGNMENT_LEFT, -1,
					TITLE_FONT_SIZE, TITLE_OUTLINE, INK
				)
				font.draw_string(
					get_canvas_item(), origin, line[i], HORIZONTAL_ALIGNMENT_LEFT, -1,
					TITLE_FONT_SIZE, color
				)
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
				x += widths[i]
				letter_index += 1
			y += line_height + LINE_SPACING
		# Silence the unused warning while keeping the measurement documented.
		block_height = block_height

	func _title_colors() -> PackedColorArray:
		var colors := PackedColorArray()
		if palette == null:
			return PackedColorArray([Color("ef6f4a")])
		for index in TITLE_COLOR_INDICES:
			if index < palette.color_count():
				colors.append(palette.get_color(index))
		return colors if not colors.is_empty() else PackedColorArray([Color("ef6f4a")])

	## The crayon underline: three overlapping wax strokes with a deterministic
	## wobble, exactly the way [code]TitleScreen.Scribble[/code] draws it.
	func _draw_scribble() -> void:
		var colors := _title_colors()
		var rng := RandomNumberGenerator.new()
		rng.seed = 20250805
		var band := Rect2(
			PAPER_RECT.position.x, PAPER_RECT.end.y - 132.0, PAPER_RECT.size.x, 72.0
		)
		for lane in 3:
			var span := band.size.x * (0.74 - float(lane) * 0.13)
			var start := band.position.x + (band.size.x - span) * 0.5
			var lane_y := band.position.y + band.size.y * (0.30 + float(lane) * 0.21)
			var points := PackedVector2Array()
			for i in 31:
				var t := float(i) / 30.0
				var wobble := sin(t * PI * (2.0 + float(lane))) * (5.0 + float(lane) * 2.0)
				points.append(
					Vector2(start + span * t, lane_y + wobble + rng.randf_range(-1.4, 1.4))
				)
			draw_polyline(points, colors[lane % colors.size()], 10.0 - float(lane) * 2.0, true)

	# ---------------------------------------------------------------- crayons --

	## The crayon shelf under the paper: a fan of wax sticks in palette order,
	## drawn from primitives like [CrayonButton].
	func _draw_crayons() -> void:
		if palette == null or palette.color_count() == 0:
			return
		var spacing := CRAYON_SIZE.x * 1.22
		var total := spacing * float(CRAYON_COUNT - 1)
		var x := size.x * 0.5 - total * 0.5
		for i in CRAYON_COUNT:
			var color := palette.get_color(i % palette.color_count())
			var tilt := deg_to_rad(
				CRAYON_FAN_DEGREES * (float(i) - float(CRAYON_COUNT - 1) * 0.5) * 0.5
			)
			draw_set_transform(Vector2(x, CRAYON_SHELF_Y), tilt, Vector2.ONE)
			_draw_crayon(color)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			x += spacing

	## One crayon, drawn around the origin: a wax body, a paler paper wrap and a
	## sharpened tip.
	func _draw_crayon(color: Color) -> void:
		var half := CRAYON_SIZE.x * 0.5
		var body := Rect2(-half, -CRAYON_SIZE.y * 0.5, CRAYON_SIZE.x, CRAYON_SIZE.y * 0.78)
		draw_rect_rounded(body, color, 12.0)
		var wrap := Rect2(body.position.x, body.position.y + body.size.y * 0.24,
			body.size.x, body.size.y * 0.46)
		draw_rect(wrap, color.lightened(0.28))
		draw_rect(Rect2(wrap.position, Vector2(wrap.size.x, 4.0)), color.darkened(0.25))
		draw_rect(Rect2(wrap.position + Vector2(0.0, wrap.size.y - 4.0),
			Vector2(wrap.size.x, 4.0)), color.darkened(0.25))
		var tip_base := body.end.y
		draw_colored_polygon(
			PackedVector2Array([
				Vector2(-half, tip_base),
				Vector2(half, tip_base),
				Vector2(0.0, tip_base + CRAYON_SIZE.y * 0.24),
			]),
			color.darkened(0.12)
		)

	# ------------------------------------------------------------ attribution --

	## "made with Godot", bottom centre: the engine credit BL-13 keeps on the
	## splash, sized as a credit rather than a centrepiece.
	func _draw_attribution() -> void:
		var font := get_theme_default_font()
		var text_size := font.get_string_size(
			ATTRIBUTION_TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1, ATTRIBUTION_FONT_SIZE
		)
		var gap := 14.0
		var total := LOGO_SIZE + gap + text_size.x
		var x := size.x * 0.5 - total * 0.5
		var baseline_y := size.y - 58.0
		if logo != null:
			draw_texture_rect(
				logo,
				Rect2(Vector2(x, baseline_y - LOGO_SIZE * 0.5), Vector2(LOGO_SIZE, LOGO_SIZE)),
				false
			)
		font.draw_string(
			get_canvas_item(),
			Vector2(x + LOGO_SIZE + gap, baseline_y + text_size.y * 0.32),
			ATTRIBUTION_TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1, ATTRIBUTION_FONT_SIZE, ATTRIBUTION
		)


func _ready() -> void:
	get_window().size = Vector2i(700, 700)
	await get_tree().process_frame
	await _run()


func _run() -> void:
	print("=== BL-13 splash render ===")
	var out_path := _arg_value("--out", OUTPUT_PATH)
	var palette := GameState.get_active_palette()
	var logo := load(LOGO_PATH) as Texture2D
	if logo == null:
		push_warning("splash_render: %s did not load; the splash gets no engine mark." % LOGO_PATH)

	var viewport := SubViewport.new()
	viewport.size = CANVAS_SIZE
	viewport.transparent_bg = false
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)

	var art := SplashArt.new(palette, logo)
	art.size = Vector2(CANVAS_SIZE)
	viewport.add_child(art)

	# A preview at window size, so a `--stay` run shows what was written.
	var preview := TextureRect.new()
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture = viewport.get_texture()
	add_child(preview)

	for i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var image := viewport.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var error := image.save_png(out_path)
	print("   %s %s (%dx%d)" % [
		"wrote" if error == OK else "FAILED to write (error %d)" % error,
		ProjectSettings.globalize_path(out_path), image.get_width(), image.get_height()
	])
	print("   remember: <godot_exe> --path godot --headless --import")

	if "--stay" in OS.get_cmdline_user_args():
		print("[dev] --stay given; the splash is on screen.")
		return
	get_tree().quit(0 if error == OK else 1)


static func _arg_value(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(flag)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return fallback

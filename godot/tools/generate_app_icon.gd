extends SceneTree
## Dev tool (BL-13 follow-up) — draws the app icon and writes it as an SVG.
##
## Usage:
##   <godot_exe> --headless --path godot --script tools/generate_app_icon.gd
##   ... --script tools/generate_app_icon.gd -- --out res://assets/icon/app_icon.svg
##   ... --script tools/generate_app_icon.gd -- --preview C:/tmp/icon_sheet.png
##   <godot_exe> --path godot --headless --import
##
## [b]Why a generator, and why SVG.[/b] Same reasoning as the boot splash
## ([code]scripts/dev/splash_render.gd[/code]): the shell ships no art assets, it
## is drawn from primitives in [code]child_palette.tres[/code] colours, and an
## icon painted by hand would drift away from it the first time the crayon box
## changes. So this reads the palette resource and emits the picture.
##
## It emits SVG rather than rendering a PNG through a SubViewport because an icon
## is looked at from 32 px to 1024 px, and a vector re-rasterises crisply at every
## one of them — which also means this tool needs no window and runs headless,
## unlike the splash generator.
##
## [b]The composition[/b] is the title screen at icon scale: the app's dark
## backdrop as the tile, a warm sheet of paper on it, three wobbling wax strokes
## in the first three title colours, and a crayon resting its tip on the stroke it
## just laid down. Nothing here is an imported asset — every shape is a rectangle,
## a polyline or a polygon, exactly as [TitleScreen] and [CrayonButton] draw them.
##
## [b]This is NOT the engine's attribution mark.[/b] The Godot logo lives at
## [code]assets/splash/godot_logo.svg[/code] and the boot splash reads it from
## there. Nothing generated here may ever end up standing in for it.

# --------------------------------------------------------------- tunables ---

## Where the icon is written, and what `config/icon` points at.
const DEFAULT_OUTPUT_PATH := "res://assets/icon/app_icon.svg"
## Which palette the colours come from.
const PALETTE_PATH := "res://resources/palettes/child_palette.tres"

## Icon side, in SVG user units and in declared pixels — Godot rasterises an SVG
## at its declared size times `svg/scale`, so 512 gives a comfortable source for
## store icons while still being an exact 2x/4x/8x/16x of 256/128/64/32.
const CANVAS := 512.0

## The tile: the app's one backdrop colour (project.godot's boot_splash/bg_color,
## the web shell page, main.tscn) so the icon is cut from the same cloth.
const BACKDROP := Color(0.121569, 0.109804, 0.101961)
## Warm paper and its edge, from title_screen.tscn's panel style.
const PAPER := Color(0.988235, 0.976471, 0.956863)
const PAPER_EDGE := Color(0.85098, 0.815686, 0.760784)

## Squircle-ish corner on the tile, and the sheet's own softer corner.
const TILE_INSET := 4.0
const TILE_CORNER := 112.0
## The sheet of paper: landscape inside the square, like the splash's sheet.
const PAPER_RECT := Rect2(46.0, 70.0, 420.0, 372.0)
const PAPER_CORNER := 30.0
const PAPER_EDGE_WIDTH := 5.0

## Palette indices the lettering and the scribble draw from — the bold half of
## the crayon box. Identical to [TitleScreen] and the splash generator, so the
## icon's colours are the title's colours.
const TITLE_COLOR_INDICES: PackedInt32Array = [0, 1, 3, 4, 5, 6, 7, 8]

## The scribble: three overlapping wax strokes, each shorter than the one above
## and centred on the same axis, with the deterministic wobble
## `TitleScreen.Scribble` draws. Unlike the title screen's, this one CLIMBS to the
## right, so it has a leading end for the crayon to sit on.
const SCRIBBLE_LANES := 3
const SCRIBBLE_STEPS := 30
## Fixed so re-running this reproduces the icon byte for byte.
const WOBBLE_SEED := 20250805
## Longest lane, and the axis every lane is centred on.
const SCRIBBLE_SPAN := 272.0
const SCRIBBLE_CENTER_X := 254.0
## Per-lane height at the LEFT EDGE of the longest lane, and stroke width.
const SCRIBBLE_BASE_Y: PackedFloat32Array = [340.0, 372.0, 400.0]
const SCRIBBLE_WIDTH: PackedFloat32Array = [37.0, 30.0, 24.0]
## Climb per horizontal pixel — applied in absolute x so the shorter lanes stay
## parallel to the long one instead of each rising at its own rate.
const SCRIBBLE_SLOPE := 0.27

## The crayon: [constant CrayonButton.DEFAULT_SIZE]'s 1:2.6 proportion at icon
## scale, drawn around its own centre and then placed by transform.
const CRAYON_SIZE := Vector2(70.0, 182.0)
const CRAYON_TILT_DEGREES := 34.0
## Where the tip lands: on the leading end of the top wax stroke, so the crayon
## reads as having just drawn it.
const CRAYON_TIP := Vector2(376.0, 276.0)
## Silhouette proportions, straight from [CrayonButton]: a blunt tapered tip, not
## a pencil point.
const CRAYON_TIP_HEIGHT := 0.19
const CRAYON_TIP_WIDTH := 0.34
const CRAYON_OUTLINE_WIDTH := 5.0

## Sizes the `--preview` contact sheet rasterises at, to check the icon still
## reads once it is 32 px in a task bar.
const PREVIEW_SIZES: PackedInt32Array = [512, 128, 64, 32]
const PREVIEW_PAD := 24


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path := _arg_value(args, "--out", DEFAULT_OUTPUT_PATH)
	var preview_path := _arg_value(args, "--preview", "")

	print("=== app icon generator ===")
	var palette := load(PALETTE_PATH) as PaletteDef
	if palette == null or palette.color_count() == 0:
		push_error("generate_app_icon: %s did not load as a usable PaletteDef." % PALETTE_PATH)
		quit(1)
		return

	var svg := _build_svg(palette)
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if file == null:
		push_error("generate_app_icon: cannot write %s (error %d)." % [
			out_path, FileAccess.get_open_error()
		])
		quit(1)
		return
	file.store_string(svg)
	file.close()
	print("   wrote %s (%d bytes, %dx%d)" % [
		ProjectSettings.globalize_path(out_path), svg.length(), int(CANVAS), int(CANVAS)
	])

	if preview_path != "":
		_write_preview(svg, preview_path)

	print("   remember: <godot_exe> --path godot --headless --import")
	quit(0)


# ======================================================================= svg ==

func _build_svg(palette: PaletteDef) -> String:
	var colors := _title_colors(palette)
	var parts := PackedStringArray()
	parts.append(
		'<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">'
		% [int(CANVAS), int(CANVAS), int(CANVAS), int(CANVAS)]
	)
	parts.append("  <!-- Generated by tools/generate_app_icon.gd — do not hand-edit. -->")
	parts.append(_tile())
	parts.append(_paper())
	parts.append_array(_scribble(colors))
	parts.append_array(_crayon(colors[0]))
	parts.append("</svg>")
	parts.append("")
	return "\n".join(parts)


## The tile: the whole icon's silhouette, in the app backdrop. Dark on purpose —
## a cream-on-white icon disappears against a light home screen, and the dark
## frame is what the player already sees behind the splash and the shell.
func _tile() -> String:
	var side := CANVAS - TILE_INSET * 2.0
	return '  <rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="%s"/>' % [
		_n(TILE_INSET), _n(TILE_INSET), _n(side), _n(side), _n(TILE_CORNER), _hex(BACKDROP)
	]


## The sheet of paper the colouring happens on.
func _paper() -> String:
	var inset := PAPER_EDGE_WIDTH * 0.5
	var rect := PAPER_RECT.grow(-inset)
	return (
		'  <rect x="%s" y="%s" width="%s" height="%s" rx="%s"'
		+ ' fill="%s" stroke="%s" stroke-width="%s"/>'
	) % [
		_n(rect.position.x), _n(rect.position.y), _n(rect.size.x), _n(rect.size.y),
		_n(PAPER_CORNER), _hex(PAPER), _hex(PAPER_EDGE), _n(PAPER_EDGE_WIDTH)
	]


## Three wax strokes with a deterministic wobble, climbing to the right. Same
## generator as `TitleScreen.Scribble`: a sine whose frequency and amplitude grow
## with the lane, plus a seeded jitter so the line looks drawn by a hand rather
## than plotted.
func _scribble(colors: PackedColorArray) -> PackedStringArray:
	var rng := RandomNumberGenerator.new()
	rng.seed = WOBBLE_SEED
	var left_edge := SCRIBBLE_CENTER_X - SCRIBBLE_SPAN * 0.5
	var out := PackedStringArray()
	for lane in SCRIBBLE_LANES:
		var span := SCRIBBLE_SPAN * (1.0 - float(lane) * 0.13)
		var start := SCRIBBLE_CENTER_X - span * 0.5
		var points := PackedStringArray()
		for i in SCRIBBLE_STEPS + 1:
			var t := float(i) / float(SCRIBBLE_STEPS)
			var wobble := sin(t * PI * (2.0 + float(lane))) * (9.0 + float(lane) * 3.0)
			var x := start + span * t
			var y := SCRIBBLE_BASE_Y[lane] - SCRIBBLE_SLOPE * (x - left_edge) + wobble \
				+ rng.randf_range(-2.2, 2.2)
			points.append("%s,%s" % [_n(x), _n(y)])
		out.append(
			('  <polyline points="%s" fill="none" stroke="%s" stroke-width="%s"'
			+ ' stroke-linecap="round" stroke-linejoin="round"/>') % [
				" ".join(points), _hex(colors[lane % colors.size()]), _n(SCRIBBLE_WIDTH[lane])
			]
		)
	return out


## One crayon, drawn with [CrayonButton]'s anatomy at icon scale: a tapered blunt
## tip on a straight body, side shading that gives the flat colour volume, a paper
## wrapper with two light bands and a label patch, and the silhouette outline last
## so nothing overdraws it.
##
## It is placed by its TIP rather than its centre — the tip is the meaningful
## point (it rests on the stroke it just drew) and everything else follows from
## the tilt.
func _crayon(color: Color) -> PackedStringArray:
	var half := CRAYON_SIZE.x * 0.5
	var apex := CRAYON_SIZE.y * 0.5
	var blunt := -apex
	var tip_height := CRAYON_SIZE.y * CRAYON_TIP_HEIGHT
	var tip_half := half * CRAYON_TIP_WIDTH
	var shoulder := apex - tip_height
	var body_height := shoulder - blunt

	var tilt := deg_to_rad(CRAYON_TILT_DEGREES)
	var origin := CRAYON_TIP - Vector2(sin(tilt), cos(tilt)) * apex

	var silhouette := PackedStringArray([
		"%s,%s" % [_n(-tip_half), _n(apex)],
		"%s,%s" % [_n(tip_half), _n(apex)],
		"%s,%s" % [_n(half), _n(shoulder)],
		"%s,%s" % [_n(half), _n(blunt)],
		"%s,%s" % [_n(-half), _n(blunt)],
		"%s,%s" % [_n(-half), _n(shoulder)],
	])
	var outline := " ".join(silhouette)

	var wrap_top := blunt + body_height * 0.13
	var wrap_bottom := shoulder - body_height * 0.10
	var band := maxf(body_height * 0.045, 4.0)
	var label_height := body_height * 0.16

	var out := PackedStringArray()
	out.append('  <g transform="translate(%s %s) rotate(%s)">' % [
		_n(origin.x), _n(origin.y), _n(CRAYON_TILT_DEGREES)
	])
	out.append('    <polygon points="%s" fill="%s"/>' % [outline, _hex(color)])
	# Right-hand shading and left-hand highlight: the same volume trick the
	# in-app crayons use, so a flat wax colour still reads as a round stick.
	out.append('    <rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>' % [
		_n(half * 0.42), _n(blunt), _n(half * 0.58), _n(body_height), _hex(color.darkened(0.18))
	])
	out.append('    <rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>' % [
		_n(-half), _n(blunt), _n(half * 0.42), _n(body_height), _hex(color.lightened(0.22))
	])
	out.append('    <polygon points="%s,%s %s,%s %s,%s %s,%s" fill="%s"/>' % [
		_n(tip_half * 0.32), _n(apex), _n(tip_half), _n(apex),
		_n(half), _n(shoulder), _n(half * 0.42), _n(shoulder),
		_hex(color.darkened(0.18))
	])
	# Paper wrapper: the body minus a bare band at each end, banded in white.
	out.append('    <rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>' % [
		_n(-half), _n(wrap_top), _n(CRAYON_SIZE.x), _n(wrap_bottom - wrap_top), _hex(color)
	])
	for edge_y in [wrap_top, wrap_bottom - band]:
		out.append(
			'    <rect x="%s" y="%s" width="%s" height="%s" fill="#ffffff" opacity="0.78"/>'
			% [_n(-half), _n(edge_y), _n(CRAYON_SIZE.x), _n(band)]
		)
	out.append(
		'    <rect x="%s" y="%s" width="%s" height="%s" fill="#ffffff" opacity="0.34"/>' % [
			_n(-half * 0.72), _n((wrap_top + wrap_bottom - label_height) * 0.5),
			_n(CRAYON_SIZE.x * 0.72), _n(label_height)
		]
	)
	out.append(
		'    <polygon points="%s" fill="none" stroke="%s" stroke-width="%s"'
		% [outline, _hex(color.darkened(0.5)), _n(CRAYON_OUTLINE_WIDTH)]
		+ ' stroke-linejoin="round"/>'
	)
	out.append("  </g>")
	return out


## The bold half of the crayon box, in [constant TITLE_COLOR_INDICES] order.
func _title_colors(palette: PaletteDef) -> PackedColorArray:
	var colors := PackedColorArray()
	for index in TITLE_COLOR_INDICES:
		if index < palette.color_count():
			colors.append(palette.get_color(index))
	return colors if not colors.is_empty() else PackedColorArray([Color("ef6f4a")])


# =================================================================== preview ==

## A contact sheet at [constant PREVIEW_SIZES], written OUTSIDE the project by
## habit (pass an absolute path): it is a thing to look at, not an asset to ship.
func _write_preview(svg: String, path: String) -> void:
	var tiles: Array[Image] = []
	for target in PREVIEW_SIZES:
		var image := Image.new()
		var error := image.load_svg_from_string(svg, float(target) / CANVAS)
		if error != OK:
			push_error("generate_app_icon: preview rasterise failed (error %d)." % error)
			return
		image.convert(Image.FORMAT_RGBA8)
		tiles.append(image)

	var width := PREVIEW_PAD
	var height := 0
	for tile in tiles:
		width += tile.get_width() + PREVIEW_PAD
		height = maxi(height, tile.get_height())
	var sheet := Image.create_empty(width, height + PREVIEW_PAD * 2, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.55, 0.55, 0.58))
	var x := PREVIEW_PAD
	for tile in tiles:
		sheet.blend_rect(
			tile, Rect2i(Vector2i.ZERO, tile.get_size()), Vector2i(x, PREVIEW_PAD)
		)
		x += tile.get_width() + PREVIEW_PAD
	var error := sheet.save_png(path)
	print("   %s preview %s (%s)" % [
		"wrote" if error == OK else "FAILED to write (error %d)" % error,
		path, ", ".join(PackedStringArray(Array(PREVIEW_SIZES).map(func(s): return "%dpx" % s)))
	])


# ===================================================================== utils ==

## SVG number: trimmed to two decimals so the file diffs cleanly.
static func _n(value: float) -> String:
	return String.num(snappedf(value, 0.01), 2).rstrip("0").rstrip(".")


static func _hex(color: Color) -> String:
	return "#" + color.to_html(false)


static func _arg_value(args: PackedStringArray, flag: String, fallback: String) -> String:
	var index := args.find(flag)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return fallback

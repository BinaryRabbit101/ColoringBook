class_name PageView
extends Control
## Self-contained coloring page: paper + GPU-clipped paint layer + line art,
## with pan/zoom and the region-locked stroke lifecycle (DESIGN.md 3.2/3.3).
##
## The component knows nothing about which page it shows. A parent injects the
## page either by setting the exported paths before it enters the tree, or by
## calling [method load_page] at any time.
##
## [b]WP7 split page loading in two[/b] and changed nothing else:
## [method load_page_textures] is the primitive (textures + parsed regions, already
## in memory), and [method load_page] is a thin wrapper that resolves four
## [code]res://[/code] paths through the importer and calls it. That is what lets a
## DLC page -- plain PNGs under [code]user://dlc/[/code], decoded on a worker thread
## by [PageLoader] because they must never touch the importer -- arrive here as
## ordinary textures. The component cannot tell the two apart, and neither can the
## shader.
##
## Signals go UP (a parent listens), calls come DOWN (a parent sets
## [member brush_color] / [member brush_size] and calls methods). This node never
## reaches out of its own subtree.
##
## Layer order, back to front: paper -> paint SubViewport texture -> mask (only
## when the page has one, BL-12) -> line art -> [b]stickers (BL-36)[/b] -> debug
## overlay.
##
## [b]BL-36 added one node and one accessor[/b] ([method get_sticker_layer]) and
## touched nothing else. Stickers sit ON TOP of the line art because they are
## stickers, not paint: they are never clipped to a region, never reach the paint
## SubViewport and therefore never reach coverage or the saved paint PNG. Placement
## is the parent's business -- this component only hosts the layer inside the page
## transform, so a sticker pans and zooms with the drawing it was stuck on.
##
## [b]BL-10 added one flag[/b], [member painting_enabled]: with it off a press
## starts no stroke and reports [signal paint_blocked] instead. That is the entire
## component-side surface of the per-page coloring lock -- the stroke lifecycle,
## the shader clip and the view are all unchanged.
##
## [b]BL-17 added stroke RECORDING and a rebuild path[/b], and nothing else. Every
## stroke already knows the four uniforms and the list of dab centres it handed to
## [PaintCanvas]; recording keeps that list ([method take_last_stroke_recipe]), and
## [method rebuild_paint] plays a list of recipes back into a freshly cleared paint
## layer over an optional baseline image. The stroke lifecycle, the brush shader and
## the painting stack itself are untouched: a replayed stroke goes through exactly
## the same [method PaintCanvas.queue_stamps] call a live one does, with its OWN
## locked-region colour, so the shader clips a replay the way it clipped the
## original. That is what makes undo -> redo pixel-stable. Who keeps the recipes,
## how deep, and when they are thrown away is the parent's business (see
## [ColoringPage]) -- this component only records and replays.
##
## [b]BL-35 added one more brush property[/b], [member brush_effect]: the FINISH the
## crayon box in hand paints with. It is the same kind of thing as
## [member brush_color] -- set by the parent from a palette signal, read at stamp
## time, baked into the SubViewport by the brush shader and therefore into the saved
## PNG. It reaches the shader as batch uniforms and reaches a rebuild in the recipe,
## and it changes nothing about the mechanic: the lock, the clip and the lifecycle
## are byte-identical for every finish.
##
## [b]BL-38 added a second paint layer[/b], the EFFECT MASK, and it is the only
## structural change the painting stack has taken since BL-17. It is a SubViewport
## beside the paint one, stamped by the same brush shader through the same region
## discard, holding "how alive is this wax" instead of "what colour is this wax";
## [code]paint_display.gdshader[/code] on the PaintSprite animates the paint layer
## wherever the mask is non-zero. Everything the rest of the component does is
## unchanged -- the lock, the clip, the lifecycle, the recipes and above all
## [method get_paint_image], which still returns the wax and only the wax, so
## coverage and completion cannot see the animation. The layer stays DORMANT (two
## pixels, never rendered) until an animated finish is actually in hand, so a page
## coloured out of the four bakeable boxes costs exactly what it always did. See the
## "effect mask" section below.
##
## [b]The "base" image is the page's DISPLAY art[/b] ([member PageDef.display_image_path]):
## the drawing the player sees, with paint appearing beneath its line work. A page
## may also have been MAPPED from a separate masking image (BL-9), and since BL-12
## that mask is DRAWN as well -- one layer below the display art, one above the
## paint -- so its outlines stay visible over the colour as the region guides the
## detail art may lack. It is presentation only: everything this component clips
## against is still the ID map, exactly as before, and a page with no mask renders
## exactly as it always did.

## Emitted once a page's textures and region data are in place.
signal page_loaded(page_size: Vector2i)
## Emitted on press, after a region has been locked for the whole stroke.
signal region_locked(region_id: int)
## Emitted when a stroke finishes (normally or cancelled). M4 hooks per-region
## coverage tracking here; M2 only fires the hook.
signal stroke_ended(region_id: int)
## Emitted, before [signal stroke_ended], when a stroke is aborted rather than
## released -- e.g. a second finger landing mid-stroke. Paint already committed
## stays on the page.
signal stroke_cancelled(region_id: int)
## Emitted instead of starting a stroke when [member painting_enabled] is off
## (BL-10's coloring lock). The parent turns it into feedback -- a page that
## silently ignores a child is a page a child thinks is broken.
signal paint_blocked(page_position: Vector2)

const BRUSH_SHADER: Shader = preload("res://scenes/components/brush.gdshader")
const LINE_ART_SHADER: Shader = preload("res://scenes/components/line_art.gdshader")
## BL-38. Draws the paint layer and, where the effect mask says so, animates it.
## With no mask it is the default canvas_item shader written out longhand.
const PAINT_DISPLAY_SHADER: Shader = preload("res://scenes/components/paint_display.gdshader")
## The effect viewport's size while it is DORMANT. Two pixels rather than the page,
## because a page that never holds an animated finish must not pay for a second
## page-sized render target (BL-38's mobile rule).
const DORMANT_EFFECT_SIZE := Vector2i(2, 2)

## Distance between brush dabs, as a fraction of the brush RADIUS. 0.25 means a
## dab every quarter radius, so consecutive dabs overlap by ~87% of their width:
## fast drags cannot leave gaps.
const STAMP_SPACING_RATIO := 0.25
## Floor for the above, so a hairline brush cannot request thousands of dabs.
const MIN_STAMP_SPACING_PX := 0.75
## Hard cap on dabs generated by a single drag event (a teleporting pointer must
## not stall the frame).
const MAX_STAMPS_PER_EVENT := 512
## Multiplicative zoom per mouse-wheel notch.
const WHEEL_ZOOM_STEP := 1.15
## Reserved ID-map value: line art / not paintable.
const UNPAINTABLE_ID := 0
## Returned by [method get_region_id_at] outside the page.
const OUT_OF_BOUNDS_ID := -1
## Frames a rebuild waits, past the one it needs per queued batch, before it gives
## up on the paint layer settling (BL-17). [PaintCanvas] renders ONE batch per
## frame by design -- one canvas item, one material, one set of uniforms -- so a
## replay of N strokes takes N frames and this is only a stuck-driver guard.
const MAX_REBUILD_SLACK_FRAMES := 12


## One-shot full-page quad that composites a paint image into the paint
## SubViewport (M5's paint restore, reused by BL-17's rebuild).
##
## It must draw EXACTLY once. [CanvasItem] only redraws when it is asked to, so a
## plain [method _draw] with no [method CanvasItem.queue_redraw] loop does that --
## unlike [PaintCanvas], which re-queues every frame on purpose. Drawing twice
## would not be harmless: premultiplied blending is idempotent only for fully
## opaque pixels, and would brighten the feathered edge of every dab.
class PaintRestoreQuad extends Node2D:
	var texture: Texture2D
	var page_size: Vector2

	func _init(paint_texture: Texture2D, size: Vector2) -> void:
		texture = paint_texture
		page_size = size
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		var canvas_material := CanvasItemMaterial.new()
		# The render target is transparent black at this point, so
		# out = src + dst * (1 - src.a) reproduces the saved image exactly.
		canvas_material.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
		material = canvas_material

	func _draw() -> void:
		if texture == null:
			return
		draw_texture_rect(texture, Rect2(Vector2.ZERO, page_size), false)

# ------------------------------------------------------------- page injection --

@export_group("Page")
## The page's visible art (the display image). Injected by the parent; empty in
## the component itself. Never a masking image -- see the class doc.
@export_file("*.png") var base_image_path: String = ""
## OPTIONAL masking art at the page's resolution (BL-12), drawn between the paint
## layer and the display art. Empty for a page that has no mask.
@export_file("*.png") var mask_image_path: String = ""
## Region ID-map PNG (lossless, id = R<<16|G<<8|B, #000000 = lines).
@export_file("*.png") var id_map_path: String = ""
## Region polygons JSON (schema v1).
@export_file("*.json") var regions_json_path: String = ""
## Load the paths above automatically in [method _ready].
@export var auto_load_on_ready: bool = true

@export_group("Brush")
## Colour laid down by the next stroke.
@export var brush_color: Color = Color("ef6f4a")
## Brush DIAMETER in page pixels.
@export_range(2.0, 512.0, 0.5) var brush_size: float = 56.0:
	set(value):
		brush_size = maxf(value, 1.0)
## 0 = fully feathered dab, 1 = hard dab. Never affects the region clip, which is
## always hard-edged.
@export_range(0.0, 1.0, 0.01) var brush_hardness: float = 0.85
## The FINISH the next stroke paints with (BL-35): a [BrushFinish] id -- classic
## wax, neon glow, textured wax, glitter.
##
## Set by the parent from the palette's [code]brush_effect_picked[/code], exactly
## like [member brush_color] follows [code]color_picked[/code]. It changes what a
## stamp LOOKS like and nothing else: the stroke lifecycle, the region lock and the
## ID-map clip are identical for every finish, and a glow halo is discarded outside
## the locked region fragment by fragment like any other paint. An unknown id
## resolves to [constant BrushFinish.CLASSIC] rather than painting nothing.
##
## [b]BL-38: an ANIMATED finish also wakes the effect layer here[/b], the moment the
## palette hands one over -- frames before the player can possibly press. Waking it
## resizes a SubViewport and arms a clear, and neither is a thing to be doing inside
## [method begin_stroke].
@export var brush_effect: StringName = BrushFinish.CLASSIC:
	set(value):
		brush_effect = BrushFinish.resolve(value)
		if BrushFinish.is_animated(brush_effect):
			_activate_effect_layer()
## When false, a press starts NO stroke: [method begin_stroke] refuses and emits
## [signal paint_blocked] instead. Nothing else changes -- pan, zoom, the
## two-finger gestures, and every pixel already on the page are untouched, because
## the lock stops PAINTING, not looking.
##
## This is the whole of BL-10's per-page coloring lock inside this component: the
## parent ([ColoringPage]) owns which page is locked and why; the flag is checked
## at exactly one place, the top of a stroke. Turning it off also cancels a stroke
## in progress, so it is safe to flip at any moment, mid-drag included.
@export var painting_enabled: bool = true:
	set(value):
		painting_enabled = value
		if not painting_enabled:
			cancel_stroke()

@export_group("Appearance")
## Paper shown behind the paint layer.
@export var paper_color: Color = Color.WHITE:
	set(value):
		paper_color = value
		if is_instance_valid(_paper):
			_paper.modulate = value
## Turn white paper in the line-art PNG into transparency so the paint layer
## shows through. Off for art that is already "dark lines on transparent".
@export var line_art_white_to_alpha: bool = true:
	set(value):
		line_art_white_to_alpha = value
		_apply_line_art_material()

@export_group("View")
## How much of the fit-to-view zoom the page OPENS at (BL-1). 1.0 fills the view
## edge to edge, which puts the outermost regions right on the boundary where a
## fingertip cannot comfortably reach them; anything below 1.0 leaves a margin of
## paper all the way round, so edge regions are as easy to colour as middle ones.
## Only the initial framing: pinch/wheel zoom and pan are unaffected, and the zoom
## LIMITS stay relative to the true fit (see [member min_zoom_factor]), so the
## player can still zoom further out than this.
@export_range(0.2, 1.0, 0.01) var default_zoom_factor: float = 0.85
## Smallest zoom, as a multiple of the fit-to-view zoom.
@export_range(0.05, 1.0, 0.01) var min_zoom_factor: float = 0.5
## Largest zoom, as a multiple of the fit-to-view zoom.
@export_range(1.0, 64.0, 0.1) var max_zoom_factor: float = 8.0
## Opacity of the whole debug overlay (see [method set_debug_overlay_visible]).
@export_range(0.0, 1.0, 0.01) var debug_overlay_alpha: float = 0.45
## BL-38. False freezes every animated finish at t = 0 -- the wax keeps the look it
## was stamped with, and stops moving.
##
## It is a DISPLAY switch and nothing else: the paint layer, the effect mask, the
## saved PNGs, the recipes and the coverage tracker are all byte-identical either
## way, which is what the smoke's "coverage cannot see the animation" check proves.
## Kept public because a settings toggle, a reduced-motion preference and a
## low-end fallback would all reach for the same lever.
@export var effect_animation_enabled: bool = true:
	set(value):
		effect_animation_enabled = value
		_apply_display_material()

# ------------------------------------------------------------- node handles --

@onready var _paint_viewport: SubViewport = $PaintViewport
@onready var _paint_canvas: PaintCanvas = $PaintViewport/PaintCanvas
## BL-38's effect mask: a second paint layer, the same size as the first, holding
## "how alive is this wax" instead of "what colour is this wax". Dormant (two
## pixels, never rendered) until an animated finish is actually in hand.
@onready var _effect_viewport: SubViewport = $EffectViewport
@onready var _effect_canvas: PaintCanvas = $EffectViewport/EffectCanvas
@onready var _page_root: Node2D = $PageRoot
@onready var _paper: Sprite2D = $PageRoot/Paper
@onready var _paint_sprite: Sprite2D = $PageRoot/PaintSprite
@onready var _mask_sprite: Sprite2D = $PageRoot/MaskSprite
@onready var _line_art_sprite: Sprite2D = $PageRoot/LineArtSprite
## BL-36's stickers, ABOVE the display art and inside the page transform, so they
## pan and zoom with the drawing. Nothing in the painting stack reads it: a
## sticker is not paint, is not clipped, and never reaches the coverage tracker.
@onready var _sticker_layer: StickerLayer = $PageRoot/StickerLayer
@onready var _debug_overlay: Node2D = $PageRoot/DebugOverlay

# ------------------------------------------------------------ runtime state --

var _loaded := false
var _page_size := Vector2i.ZERO
## CPU copy of the ID map, used for press-time hit-testing (DESIGN.md 3.1).
var _id_image: Image
var _id_texture: Texture2D
## Region records: { id, id_color: Color, outline, holes, centroid, area_px }.
var _regions: Array[Dictionary] = []
var _regions_by_id: Dictionary = {}

var _stroke_active := false
var _locked_region_id := UNPAINTABLE_ID
var _locked_id_color := Vector3.ZERO
var _stroke_touch_index := -1
var _last_stamp_position := Vector2.ZERO
var _last_pointer_position := Vector2.ZERO

## BL-17. Dab centres laid down by the stroke in progress, in page pixels -- the
## same points that went to [PaintCanvas], captured as they are stamped rather
## than re-derived, so a replay cannot drift from what was painted.
var _recipe_points := PackedVector2Array()
## The recipe of the stroke that just ended, until the parent takes it.
var _last_recipe: Dictionary = {}
## BL-35. The finish seed of the stroke in progress, chosen at press from the press
## point and carried in the recipe: the grain angle and the glitter layout are
## functions of it, so a replay that re-uses it re-stamps the same pixels.
var _effect_seed := 0.0
## BL-38. True once this page has woken the effect mask -- i.e. an animated finish
## has been in hand, or a saved mask has been restored. While false the second
## SubViewport is two pixels and never rendered, and the display shader is a
## pass-through, so a page coloured entirely out of the four bakeable boxes costs
## exactly what it cost before phase 2 existed.
var _effect_active := false
## True while [method rebuild_paint] is re-laying a page. Nothing else in the
## component reacts to it; it exists so the parent can refuse to read the paint
## layer (or start another rebuild) half way through one.
var _replaying := false

## index -> position, in viewport coordinates. Drives the two-finger rules.
var _touches: Dictionary = {}
var _pinch_active := false
var _pinch_previous_distance := 0.0
var _pinch_previous_midpoint := Vector2.ZERO
var _middle_panning := false

var _fit_zoom := 1.0
## Set once the player pans/zooms, so a window resize stops re-fitting the page.
var _view_user_adjusted := false


func _ready() -> void:
	# Events must reach _unhandled_input (one touch code path), so the component
	# does not swallow them in the GUI phase.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_debug_overlay.visible = false
	resized.connect(_on_resized)
	if auto_load_on_ready and base_image_path != "" and id_map_path != "":
		load_page(base_image_path, id_map_path, regions_json_path, mask_image_path)


# =============================================================== page loading ==

## Loads a page from PATHS. [param base_path] is the page's DISPLAY image;
## [param idmap_path] is whatever the mapping pipeline produced for it, from the
## mask when the page has one. [param mask_path] is that mask's display-resolution
## artifact (BL-12) or "" for a page without one -- it is drawn under the display
## art and nothing more. Returns false and pushes an error if anything is missing
## or the ID map does not match the display image.
##
## [b]WP7: this is now a thin wrapper[/b] over [method load_page_textures]. It is
## the [code]res://[/code] path and nothing about it changed: every file goes
## through [method @GDScript.load], i.e. the importer, exactly as before. A page
## whose files live in a DLC pack cannot go through the importer at all, so its
## caller decodes the files itself (off the main thread) and calls the primitive.
func load_page(
	base_path: String, idmap_path: String, regions_path: String, mask_path: String = ""
) -> bool:
	var base_texture := load(base_path) as Texture2D
	if base_texture == null:
		push_error("PageView: cannot load base image '%s'." % base_path)
		return false
	var id_texture := load(idmap_path) as Texture2D
	if id_texture == null:
		push_error("PageView: cannot load ID map '%s'." % idmap_path)
		return false
	var mask_texture: Texture2D = null
	if mask_path != "":
		mask_texture = load(mask_path) as Texture2D
		if mask_texture == null:
			push_warning(
				"PageView: cannot load mask image '%s'; drawing the page without it." % mask_path
			)
	return load_page_textures(
		base_texture, id_texture, _read_regions_file(regions_path), mask_texture
	)


## Loads a page from TEXTURES that are already in memory -- the primitive every
## other load path funnels through (DLC_SERVER.md 8.1 item 3).
##
## [param base] is the display art, [param idmap] the region ID map,
## [param regions] the PARSED regions JSON (the whole schema-v1 object; an empty
## dictionary is a page with no polygon data, which only costs the debug overlay
## and the coverage grids), and [param mask] the optional BL-12 mask layer.
##
## Where the textures came from is deliberately none of this component's business:
## an imported [CompressedTexture2D] from [code]res://[/code] and an
## [ImageTexture] decoded from a pack file at runtime behave identically here. The
## ID map is sampled with [code]filter_nearest[/code] at the usage site (the brush
## shader) either way, and a runtime [ImageTexture] additionally CANNOT have been
## VRAM-compressed by the importer -- the check below stays anyway, because the
## imported path can still lose its flags in a diff.
func load_page_textures(
	base: Texture2D, idmap: Texture2D, regions: Dictionary, mask: Texture2D = null
) -> bool:
	_loaded = false
	cancel_stroke()
	_recipe_points = PackedVector2Array()
	_last_recipe = {}
	_replaying = false

	if base == null:
		push_error("PageView: no base image texture.")
		return false
	if idmap == null:
		push_error("PageView: no ID map texture.")
		return false
	_id_texture = idmap

	_id_image = _id_texture.get_image()
	if _id_image == null:
		push_error("PageView: the ID map texture has no readable image data.")
		return false
	if _id_image.is_compressed():
		# Would mean the .import settings lost compress/mode=0 (see DESIGN.md 3.2).
		push_warning("PageView: the ID map is VRAM-compressed; region ids may be corrupt.")
		_id_image = _id_image.duplicate()
		_id_image.decompress()

	_page_size = Vector2i(base.get_width(), base.get_height())
	if Vector2i(_id_image.get_width(), _id_image.get_height()) != _page_size:
		push_error(
			"PageView: ID map size %s does not match base image size %s."
			% [Vector2i(_id_image.get_width(), _id_image.get_height()), _page_size]
		)
		return false

	_regions = _parse_regions(regions)

	var page_size_f := Vector2(_page_size)

	# Paint layer: a SubViewport the size of the page whose render target is
	# never cleared, so strokes persist across frames.
	_paint_viewport.size = _page_size
	_paint_viewport.transparent_bg = true
	_paint_viewport.disable_3d = true
	_paint_viewport.gui_disable_input = true
	_paint_viewport.handle_input_locally = false
	_paint_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_paint_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_paint_canvas.configure(BRUSH_SHADER, _id_texture, page_size_f)

	# BL-38: a new page starts with no animated wax on it, and the mask that belongs
	# to the page we are LEAVING must not survive into it. The screen restores this
	# page's own saved mask afterwards, exactly as it restores the paint layer.
	_reset_effect_layer()

	_paper.texture = _make_white_texture()
	_paper.centered = false
	_paper.scale = page_size_f
	_paper.modulate = paper_color

	_paint_sprite.centered = false
	_paint_sprite.texture = _paint_viewport.get_texture()
	_apply_display_material()

	_line_art_sprite.centered = false
	_line_art_sprite.texture = base
	_apply_line_art_material()

	_apply_mask_layer(mask)

	# BL-36: the stickers of the page we are LEAVING must not be on the page we are
	# arriving at, and the layer measures everything against the page's short side,
	# so it is emptied and re-measured here. The screen restores this page's own
	# saved stickers afterwards, exactly as it restores the paint layer.
	if is_instance_valid(_sticker_layer):
		_sticker_layer.clear()
		_sticker_layer.set_page_size(_page_size)

	_build_debug_overlay()

	_loaded = true
	_view_user_adjusted = false
	fit_page_to_view()
	page_loaded.emit(_page_size)
	return true


## The regions JSON at [param regions_path], parsed. An empty dictionary (missing
## file, unreadable, not an object) is a page without polygon data, which the
## primitive accepts. Works for a [code]user://[/code] pack file too: this has
## always been plain [FileAccess], never the resource loader.
static func _read_regions_file(regions_path: String) -> Dictionary:
	if regions_path == "":
		return {}
	if not FileAccess.file_exists(regions_path):
		push_warning("PageView: regions JSON '%s' not found; overlay/centroids unavailable." % regions_path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(regions_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("PageView: regions JSON '%s' is not an object." % regions_path)
		return {}
	return parsed


func _parse_regions(data: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	_regions_by_id = {}
	if data.is_empty():
		return result
	if int(data.get("version", 0)) != 1:
		push_warning("PageView: regions JSON has unsupported version %s." % data.get("version"))
	for entry_variant in data.get("regions", []):
		var entry: Dictionary = entry_variant
		var record := {
			"id": int(entry.get("id", 0)),
			"id_color": Color(String(entry.get("id_color", "#000000"))),
			"outline": _to_points(entry.get("outline", [])),
			"holes": _to_point_lists(entry.get("holes", [])),
			"centroid": _to_point(entry.get("centroid", [0, 0])),
			"area_px": int(entry.get("area_px", 0)),
		}
		result.append(record)
		_regions_by_id[record["id"]] = record
	return result


static func _to_point(value: Variant) -> Vector2:
	var pair: Array = value
	return Vector2(float(pair[0]), float(pair[1]))


static func _to_points(value: Variant) -> PackedVector2Array:
	var points := PackedVector2Array()
	for pair in value:
		points.append(_to_point(pair))
	return points


static func _to_point_lists(value: Variant) -> Array[PackedVector2Array]:
	var lists: Array[PackedVector2Array] = []
	for entry in value:
		lists.append(_to_points(entry))
	return lists


static func _make_white_texture() -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)


func _apply_line_art_material() -> void:
	_apply_ink_material(_line_art_sprite)
	_apply_ink_material(_mask_sprite)


## Line art and the mask layer are the same KIND of thing -- ink over the paint --
## so they share the shader that recovers ink alpha from white paper.
func _apply_ink_material(sprite: Sprite2D) -> void:
	if not is_instance_valid(sprite):
		return
	var shader_material := sprite.material as ShaderMaterial
	if shader_material == null:
		shader_material = ShaderMaterial.new()
		shader_material.shader = LINE_ART_SHADER
		sprite.material = shader_material
	shader_material.set_shader_parameter("white_to_alpha", line_art_white_to_alpha)


## The BL-12 mask layer. A page without a mask leaves the sprite hidden and
## textureless, which is byte-for-byte the pre-BL-12 render.
##
## A mask that is not the page's size is REFUSED rather than stretched: the
## pipeline resamples it to the display image on purpose, and a mask that does not
## line up would draw guides in the wrong place -- worse than drawing none.
func _apply_mask_layer(mask_texture: Texture2D) -> void:
	if not is_instance_valid(_mask_sprite):
		return
	_mask_sprite.texture = null
	_mask_sprite.visible = false
	if mask_texture == null:
		return
	if Vector2i(mask_texture.get_size()) != _page_size:
		push_warning(
			"PageView: the mask is %s but the page is %s; drawing the page without it."
			% [Vector2i(mask_texture.get_size()), _page_size]
		)
		return
	_mask_sprite.texture = mask_texture
	_mask_sprite.visible = true


# ======================================================= the effect mask (BL-38) ==
# The animated half of the finish ladder, and the answer to BL-38's whole question:
# WHERE DOES A LIVE EFFECT LIVE SO IT SURVIVES A SAVE?
#
# It lives in a second SubViewport, the same size as the paint one, stamped by the
# same brush shader through the same region `discard`, holding a per-pixel payload
# ("how much travelling sheen, how much winking speck, at what phase") instead of a
# colour. `paint_display.gdshader` samples it on the PaintSprite and animates only
# where it is non-zero.
#
# Four consequences, and every one of them is why this beat persisting recipes:
#
#   * The clip is free and exact. The mask cannot mark a pixel the wax did not
#     cover, because the same shader wrote both through the same ID-map test.
#   * Coverage cannot see it. `CoverageTracker` reads the PAINT viewport; this one
#     is a different render target that nothing in the coverage path touches.
#   * Persistence is a PNG. A page-sized RGBA8 image beside the paint PNG, restored
#     by the same premultiplied one-frame composite. No replay, no unbounded
#     metadata, no ordering to reconstruct.
#   * Paint over it and it goes away. A classic stamp writes zeros through the same
#     alpha blend, so ordinary wax over shimmer stops shimmering with no bookkeeping
#     anywhere.
#
# It is DORMANT until it is needed: two pixels, never rendered, display shader in
# pass-through. Waking it costs one resize and one cleared frame, and happens when
# an animated finish reaches [member brush_effect] or a saved mask is restored.

## Wakes the effect mask. Idempotent, and cheap enough to call from a setter.
func _activate_effect_layer() -> void:
	if _effect_active or not _loaded:
		return
	_effect_active = true
	_effect_viewport.size = _page_size
	_effect_viewport.transparent_bg = true
	_effect_viewport.disable_3d = true
	_effect_viewport.gui_disable_input = true
	_effect_viewport.handle_input_locally = false
	_effect_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_effect_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_effect_canvas.configure(
		BRUSH_SHADER, _id_texture, Vector2(_page_size), PaintCanvas.TARGET_MASK
	)
	_apply_display_material()


## Puts the effect mask back to sleep and forgets everything in it. Page load only:
## the mask is per PAGE, exactly like the paint layer and the stickers.
func _reset_effect_layer() -> void:
	_effect_active = false
	if is_instance_valid(_effect_canvas):
		_effect_canvas.discard_pending()
	if is_instance_valid(_effect_viewport):
		_effect_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_effect_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
		_effect_viewport.size = DORMANT_EFFECT_SIZE
	_apply_display_material()


## Keeps the PaintSprite's display shader in step with the layer's state.
##
## The sprite carries this material even on a page with no animated wax on it,
## because a material that appeared and disappeared would be a second render path
## to keep honest. With [code]effect_enabled[/code] false the shader is one texture
## fetch and one multiply -- what the sprite did with no material at all.
func _apply_display_material() -> void:
	if not is_instance_valid(_paint_sprite):
		return
	var display := _paint_sprite.material as ShaderMaterial
	if display == null:
		display = ShaderMaterial.new()
		display.shader = PAINT_DISPLAY_SHADER
		_paint_sprite.material = display
	display.set_shader_parameter("page_size", Vector2(_page_size))
	display.set_shader_parameter("effect_enabled", _effect_active)
	display.set_shader_parameter("effect_animated", effect_animation_enabled)
	if is_instance_valid(_effect_viewport):
		display.set_shader_parameter("effect_mask", _effect_viewport.get_texture())


## True once this page has animated wax on it (or a restored mask that has).
func is_effect_layer_active() -> bool:
	return _effect_active


## The effect mask, read back SYNCHRONOUSLY, or null when the layer is dormant.
## Same rules as [method get_paint_image]: save points and dev harnesses only.
func get_effect_image() -> Image:
	if not _loaded or not _effect_active:
		return null
	return _effect_viewport.get_texture().get_image()


## Non-blocking twin of [method get_effect_image]. Returns false -- without calling
## back -- when the layer is dormant or the async path is unavailable, which is the
## caller's cue to fall back to the blocking read (or to skip it: a dormant layer
## has nothing worth saving).
func request_effect_image(callback: Callable) -> bool:
	if not _loaded or not _effect_active:
		return false
	return AsyncReadback.request(_effect_viewport, callback)


## Composites a saved effect mask back in, waking the layer first. The premultiplied
## one-frame trick from [method composite_image], for exactly the same reason: over a
## freshly cleared target it is bit-exact, and the mask's channels are numbers a
## darkening blend would quietly corrupt.
func composite_effect_image(image: Image) -> bool:
	if not _loaded or image == null or not is_inside_tree():
		return false
	if image.get_width() != _page_size.x or image.get_height() != _page_size.y:
		push_warning(
			"PageView: cannot composite a %dx%d effect mask into a %s page."
			% [image.get_width(), image.get_height(), _page_size]
		)
		return false
	_activate_effect_layer()
	return await _composite_into(_effect_viewport, image)


# ================================================================ region data ==

## Region id at a page pixel. [constant UNPAINTABLE_ID] for line art,
## [constant OUT_OF_BOUNDS_ID] outside the page.
func get_region_id_at(page_position: Vector2) -> int:
	if _id_image == null:
		return OUT_OF_BOUNDS_ID
	var x := int(floor(page_position.x))
	var y := int(floor(page_position.y))
	if x < 0 or y < 0 or x >= _page_size.x or y >= _page_size.y:
		return OUT_OF_BOUNDS_ID
	var pixel := _id_image.get_pixel(x, y)
	return (pixel.r8 << 16) | (pixel.g8 << 8) | pixel.b8


## Ids of every region in the page's JSON, in file order.
func get_region_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for region in _regions:
		ids.append(region["id"])
	return ids


## A copy of one region's record ({ id, id_color, outline, holes, centroid,
## area_px }), or an empty dictionary. For overlays, hint markers and (M4)
## coverage sample grids -- never for the paint clip, which uses the ID map.
func get_region_data(region_id: int) -> Dictionary:
	if not _regions_by_id.has(region_id):
		return {}
	return (_regions_by_id[region_id] as Dictionary).duplicate(true)


func get_page_size() -> Vector2i:
	return _page_size


func is_page_loaded() -> bool:
	return _loaded


## The CPU-side ID map. Treat as read-only.
func get_id_map_image() -> Image:
	return _id_image


## True when this page is drawing a mask layer under its display art (BL-12).
func has_mask_layer() -> bool:
	return is_instance_valid(_mask_sprite) and _mask_sprite.visible and _mask_sprite.texture != null


## The mask layer's texture, or null. Tests use it to prove the layer is the
## page's own mask; nothing in the game reads it.
func get_mask_texture() -> Texture2D:
	return _mask_sprite.texture if is_instance_valid(_mask_sprite) else null


## The layer BL-36's stickers live on -- above the display art, inside the page
## transform. Additive, like [member painting_enabled]: the owning screen drives
## it, and nothing else in this component reads or writes it. Painting, region
## clipping, the recipes and the coverage readback are all exactly what they were.
func get_sticker_layer() -> StickerLayer:
	return _sticker_layer


# =========================================================== stroke lifecycle ==

## Press. Locks the region under [param page_position] for the WHOLE stroke and
## lays the first dab. Returns false (and starts nothing) on line art, outside the
## page, or while [member painting_enabled] is off. The input path and automated
## tests both go through here -- which is why the lock is checked HERE and nowhere
## else: there is one stroke-start in the component, so there is one gate.
func begin_stroke(page_position: Vector2) -> bool:
	if not _loaded:
		return false
	if not painting_enabled:
		paint_blocked.emit(page_position)
		return false
	if _stroke_active:
		end_stroke()
	var region_id := get_region_id_at(page_position)
	if region_id <= UNPAINTABLE_ID:
		return false

	var pixel := _id_image.get_pixel(int(page_position.x), int(page_position.y))
	# Raw texel values, matching exactly what the shader samples from the ID map.
	_locked_id_color = Vector3(pixel.r8 / 255.0, pixel.g8 / 255.0, pixel.b8 / 255.0)
	_locked_region_id = region_id
	_stroke_active = true
	_last_stamp_position = page_position
	_last_pointer_position = page_position
	# BL-17: a new stroke, so a new recipe. Recording starts before the first dab
	# because the press itself lays one. BL-35: and a new finish seed, from the
	# press point alone so it is decided before any dab needs it.
	_recipe_points = PackedVector2Array()
	_effect_seed = BrushFinish.seed_for(page_position)
	_stamp(PackedVector2Array([page_position]))
	region_locked.emit(region_id)
	return true


## Drag. Interpolates dabs from the previous stamp up to [param page_position].
## The locked region is NEVER re-evaluated, so the pointer may wander anywhere.
func continue_stroke(page_position: Vector2) -> void:
	if not _stroke_active:
		return
	_last_pointer_position = page_position
	var spacing := maxf(_brush_radius() * STAMP_SPACING_RATIO, MIN_STAMP_SPACING_PX)
	var travel := _last_stamp_position.distance_to(page_position)
	if travel < spacing:
		return
	var count := mini(int(floor(travel / spacing)), MAX_STAMPS_PER_EVENT)
	var points := PackedVector2Array()
	var direction := (page_position - _last_stamp_position) / travel
	for i in range(1, count + 1):
		points.append(_last_stamp_position + direction * (spacing * i))
	_last_stamp_position = points[points.size() - 1]
	_stamp(points)


## Release. Lays a final dab at the last pointer position, then ends the stroke.
func end_stroke() -> void:
	if not _stroke_active:
		return
	if _last_stamp_position.distance_to(_last_pointer_position) > 0.01:
		_stamp(PackedVector2Array([_last_pointer_position]))
	var region_id := _locked_region_id
	_close_recipe(region_id)
	_stroke_active = false
	_stroke_touch_index = -1
	_locked_region_id = UNPAINTABLE_ID
	stroke_ended.emit(region_id)


## Aborts an in-progress stroke (a second finger landed). Paint already committed
## to the SubViewport stays -- only further painting stops.
func cancel_stroke() -> void:
	if not _stroke_active:
		return
	var region_id := _locked_region_id
	# The paint a cancelled stroke already laid down STAYS, so its recipe is as
	# real as any other -- undo has to be able to take it back off again.
	_close_recipe(region_id)
	_stroke_active = false
	_stroke_touch_index = -1
	_locked_region_id = UNPAINTABLE_ID
	stroke_cancelled.emit(region_id)
	stroke_ended.emit(region_id)


func is_stroke_active() -> bool:
	return _stroke_active


## Region locked by the current stroke, or [constant UNPAINTABLE_ID] when idle.
func get_locked_region_id() -> int:
	return _locked_region_id


func _brush_radius() -> float:
	return maxf(brush_size * 0.5, 0.5)


func _stamp(points: PackedVector2Array) -> void:
	# BL-17: record what we stamp, at the moment we stamp it. Deriving the dab
	# centres again later from the pointer path would be a second implementation of
	# continue_stroke() and would drift from it the day either one changes.
	_recipe_points.append_array(points)
	_queue_stamps(
		points, _brush_radius(), brush_color, _locked_id_color, brush_hardness,
		_effect_params(brush_effect, _effect_seed)
	)


## Hands one batch of dabs to the paint canvas and -- once the effect mask is awake
## -- to the mask canvas as well (BL-38).
##
## [b]Every stamp goes to both, not just the animated ones.[/b] That is the whole
## erase story: classic wax carries a zero payload, so painting it over a shimmer
## stroke writes zeros into the mask through the same alpha blend that wrote ones,
## and the shimmer stops. A mask that only animated finishes wrote to would leave a
## sheen travelling under paint that has covered it.
## [param to_mask] is false only for a REPLAY of a stroke that was laid while the
## mask was still asleep. Live, that stroke touched no mask texel; a rebuild that
## stamped it anyway would leave the mask's alpha channel a little different from
## the layer it is supposed to be reproducing, and BL-17's whole promise is that a
## rebuilt page is the same page. See [method _close_recipe].
func _queue_stamps(
	points: PackedVector2Array,
	radius: float,
	color: Color,
	id_color: Vector3,
	hardness: float,
	effect: Dictionary,
	to_mask: bool = true
) -> void:
	_paint_canvas.queue_stamps(points, radius, color, id_color, hardness, effect)
	if _effect_active and to_mask:
		_effect_canvas.queue_stamps(points, radius, color, id_color, hardness, effect)


## The shader parameters for finish [param effect] at [param seed] (BL-35). One
## place, so a live stamp and a replayed one cannot describe the same finish
## differently. BL-38 added the mask payload (which [method BrushFinish.params_for]
## supplies) plus the stroke's animation PHASE, derived from the same seed rather
## than stored beside it.
static func _effect_params(effect: StringName, seed_value: float) -> Dictionary:
	var params := BrushFinish.params_for(effect)
	params["seed"] = seed_value
	params["phase"] = BrushFinish.phase_for_seed(seed_value)
	return params


# ========================================================= stroke recipes (BL-17) ==
# A recipe is everything a stroke handed to the GPU: the locked region (both its id
# and the raw texel colour the shader compares against), the brush, and the dab
# centres. A few kilobytes, against the ~14 MB a paint-layer snapshot of the same
# stroke would cost -- which is the whole reason undo is replay-based.

## Takes the recipe of the stroke that just ended, and forgets it. Call from a
## [signal stroke_ended] handler; an empty dictionary means that stroke laid no
## dabs (or someone has already taken it).
func take_last_stroke_recipe() -> Dictionary:
	var recipe := _last_recipe
	_last_recipe = {}
	return recipe


func _close_recipe(region_id: int) -> void:
	if _recipe_points.is_empty():
		_last_recipe = {}
		return
	_last_recipe = {
		"region_id": region_id,
		# Raw texel values, exactly as the shader uniform saw them, so a replay
		# clips against the same region even if the ID map were reloaded.
		"id_color": _locked_id_color,
		"color": brush_color,
		"diameter": brush_size,
		"hardness": brush_hardness,
		# BL-35: the FINISH is part of the brush, so it travels with the recipe like
		# the colour does -- with its seed, because the grain and the glitter are
		# functions of it and a rebuild that re-rolled one would not be pixel-exact.
		"effect": brush_effect,
		"effect_seed": _effect_seed,
		# BL-38: whether this stroke reached the EFFECT MASK. It is not the same
		# question as "is the finish animated" -- ordinary wax laid after the mask
		# woke reaches it too, to rub the animation off what it covers -- and it is
		# not derivable later, because it depends on when in the visit the first
		# animated box was picked. One bool, and a rebuild reproduces the mask
		# exactly instead of approximately.
		"effect_masked": _effect_active,
		"points": _recipe_points,
	}
	_recipe_points = PackedVector2Array()


## Re-stamps one recipe. The brush state travels WITH the recipe -- the live
## [member brush_color] / [member brush_size] / [member brush_hardness] are not read
## and not changed -- so replaying an old stroke cannot be disturbed by whatever the
## palette happens to be holding now.
func stamp_recipe(recipe: Dictionary) -> bool:
	if not _loaded or recipe.is_empty():
		return false
	var points: PackedVector2Array = recipe.get("points", PackedVector2Array())
	if points.is_empty():
		return false
	var effect: StringName = recipe.get("effect", BrushFinish.CLASSIC)
	var animated := BrushFinish.is_animated(effect)
	# BL-38: replaying an animated stroke onto a page whose mask went to sleep (a
	# fresh load, then a redo) has to wake it first, or the wax would come back
	# without the thing that made it that box.
	if animated:
		_activate_effect_layer()
	_queue_stamps(
		points,
		maxf(float(recipe.get("diameter", brush_size)) * 0.5, 0.5),
		recipe.get("color", brush_color),
		recipe.get("id_color", Vector3.ZERO),
		float(recipe.get("hardness", brush_hardness)),
		# A recipe with no finish (one recorded before BL-35, or by a test that only
		# cares about geometry) is classic wax at seed 0 -- the shader's default path.
		_effect_params(effect, float(recipe.get("effect_seed", 0.0))),
		animated or bool(recipe.get("effect_masked", false))
	)
	return true


## True while [method rebuild_paint] is running.
func is_replaying() -> bool:
	return _replaying


## Composites [param image] into the paint layer with premultiplied alpha, for
## exactly one frame (M5's restore path, made reusable by BL-17).
##
## Assumes the render target has just been cleared -- it waits a frame first so a
## pending [constant SubViewport.CLEAR_MODE_ONCE] has actually happened, because
## premult over an all-zero target is what makes the composite bit-exact. Over
## existing paint it would OVERWRITE rather than blend, which is why nothing calls
## this except a page load and a rebuild.
func composite_image(image: Image) -> bool:
	if not _loaded or image == null or not is_inside_tree():
		return false
	if image.get_width() != _page_size.x or image.get_height() != _page_size.y:
		push_warning(
			"PageView: cannot composite a %dx%d image into a %s page."
			% [image.get_width(), image.get_height(), _page_size]
		)
		return false
	return await _composite_into(_paint_viewport, image)


## The one-frame premultiplied composite, over whichever render target (BL-38 gave
## it a second caller -- the effect mask -- and the arithmetic must be the same one,
## because a mask restored through a MIX blend would come back with its channels
## multiplied by their own alpha a second time).
func _composite_into(viewport: SubViewport, image: Image) -> bool:
	# One frame so CLEAR_MODE_ONCE has actually cleared the target before we draw.
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	if not is_inside_tree() or not _loaded:
		return false
	var quad := PaintRestoreQuad.new(ImageTexture.create_from_image(image), Vector2(_page_size))
	quad.name = "PaintRestoreQuad"
	viewport.add_child(quad)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	viewport.remove_child(quad)
	quad.queue_free()
	return true


## Rebuilds the whole paint layer from scratch: clear, composite [param baseline]
## (the page's saved PNG, or null for blank paper), then re-stamp [param recipes] in
## order. This is BL-17's undo -- there is no "un-draw", so the page is simply drawn
## again without the stroke that was taken back.
##
## [b]The lifecycle matters.[/b] [method clear_paint] arms
## [constant SubViewport.CLEAR_MODE_ONCE], which the engine turns back into
## CLEAR_MODE_NEVER after exactly one cleared frame; the baseline must land on that
## cleared target and nothing else may be queued while it does, or the premult quad
## would overwrite strokes instead of underpainting them. So the three phases are
## strictly serialised: clear frame, baseline frame, then the stamps.
##
## Replay costs one FRAME per queued batch ([PaintCanvas] flushes one batch per
## frame -- one canvas item, one material), which is why the history depth is
## bounded. Returns false if the page is not loaded, a stroke is down, or another
## rebuild is already running.
## [param effect_baseline] (BL-38) is the saved EFFECT MASK the visit opened with,
## the mask layer's exact counterpart to [param baseline]. Passing null on a page
## that has animated wax on it would rebuild the colours and lose the animation.
func rebuild_paint(baseline: Image, recipes: Array, effect_baseline: Image = null) -> bool:
	if not _loaded or _replaying or _stroke_active or not is_inside_tree():
		return false
	_replaying = true
	clear_paint()
	if effect_baseline != null:
		# Wake it BEFORE the clear frame below, so its CLEAR_MODE_ONCE is armed on
		# the same frame the paint layer's is and the composite lands on a target
		# that is genuinely all-zero.
		_activate_effect_layer()
	if baseline != null:
		await composite_image(baseline)
	else:
		# No baseline: still spend the clear frame, so the first stamps below are
		# never queued into a frame that is about to be wiped.
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	if not is_inside_tree() or not _loaded:
		_replaying = false
		return false
	if effect_baseline != null:
		await composite_effect_image(effect_baseline)
		if not is_inside_tree() or not _loaded:
			_replaying = false
			return false

	var queued := 0
	for recipe in recipes:
		if stamp_recipe(recipe):
			queued += 1
	var budget := queued + MAX_REBUILD_SLACK_FRAMES
	# Both canvases flush one batch per frame, in the same frames, so waiting for
	# the pair costs no more frames than waiting for the paint layer alone.
	while has_pending_paint() and budget > 0 and is_inside_tree():
		budget -= 1
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_replaying = false
	return true


# =============================================================== paint access ==

## Wipes the paint layer (the SubViewport clears itself on the next render).
func clear_paint() -> void:
	cancel_stroke()
	# Whatever a cancelled stroke just recorded describes paint that is about to
	# stop existing. (cancel_stroke() has already handed it to any listener.)
	_recipe_points = PackedVector2Array()
	_last_recipe = {}
	if not _loaded:
		return
	_paint_canvas.discard_pending()
	_paint_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	# BL-38: the animation is part of the picture, so wiping the picture wipes it.
	# The layer stays AWAKE -- the player still has an animated box in hand and the
	# next stroke would only wake it again.
	if _effect_active:
		_effect_canvas.discard_pending()
		_effect_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE


## Reads the paint layer back to the CPU, SYNCHRONOUSLY. Blocks the main thread
## for as long as the presentation queue takes (hundreds of ms under FIFO v-sync)
## -- dev harnesses, and the app-quit save where there is no next frame to wait
## for. Everything in the running game must use [method request_paint_image].
func get_paint_image() -> Image:
	if not _loaded:
		return null
	return _paint_viewport.get_texture().get_image()


## Non-blocking version of [method get_paint_image] (M6).
##
## Queues a GPU readback and returns immediately (well under a millisecond);
## [param callback] receives the [Image] on the main thread a couple of frames
## later. Returns false -- WITHOUT calling back -- when the async path is
## unavailable (Compatibility renderer, unsupported target format) or no page is
## loaded, so the caller can fall back to [method get_paint_image].
##
## The paint layer is not cleared between frames, so a slightly-late image is a
## superset of what the stroke laid down, never a stale one: coverage is
## monotonic and tolerates the delay by design.
func request_paint_image(callback: Callable) -> bool:
	if not _loaded:
		return false
	return AsyncReadback.request(_paint_viewport, callback)


## True when [method request_paint_image] can actually do its job on this build.
func is_async_paint_readback_available() -> bool:
	return AsyncReadback.is_available()


## True while stamps are queued but not yet rendered into the SubViewport -- either
## of them (BL-38): a readback taken while the mask still had a batch pending would
## save a page whose colours and whose animation disagreed.
func has_pending_paint() -> bool:
	if not _loaded:
		return false
	return _paint_canvas.has_pending() or (_effect_active and _effect_canvas.has_pending())


# ============================================================== debug overlay ==

## Region tinting from the JSON polygons (DESIGN.md 4). Off by default.
##
## Holes are handled by the painter's algorithm rather than by cutting polygons:
## regions are drawn largest-area-first with OPAQUE fills, and the whole overlay
## is faded with [member debug_overlay_alpha]. Because every hole in a region is
## filled by a smaller region (or by line art), the smallest region covering a
## pixel is always the last one drawn there, so each pixel shows its own region's
## exact tint -- no blended mixture, no polygon boolean ops. The one case this
## approximates is a hole bounded only by line art with no region inside it: it
## takes the parent's tint. The line art still renders under the faded overlay.
func set_debug_overlay_visible(is_visible: bool) -> void:
	_debug_overlay.visible = is_visible


func is_debug_overlay_visible() -> bool:
	return _debug_overlay.visible


func toggle_debug_overlay() -> bool:
	_debug_overlay.visible = not _debug_overlay.visible
	return _debug_overlay.visible


func _build_debug_overlay() -> void:
	for child in _debug_overlay.get_children():
		_debug_overlay.remove_child(child)
		child.queue_free()
	_debug_overlay.modulate = Color(1.0, 1.0, 1.0, debug_overlay_alpha)
	var ordered := _regions.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["area_px"]) > int(b["area_px"])
	)
	for region in ordered:
		var outline: PackedVector2Array = region["outline"]
		if outline.size() < 3:
			continue
		var polygon := Polygon2D.new()
		polygon.name = "Region%d" % int(region["id"])
		polygon.polygon = outline
		polygon.color = _region_tint(int(region["id"]))
		_debug_overlay.add_child(polygon)


## Deterministic, well-spread hue per id (golden-ratio rotation).
static func _region_tint(region_id: int) -> Color:
	return Color.from_hsv(fmod(float(region_id) * 0.6180339887, 1.0), 0.72, 1.0, 1.0)


# ==================================================================== the view ==

## Page pixel coordinates for a position in viewport (input event) coordinates.
## Correct under any pan/zoom, and under a scaled UI canvas.
func to_page_position(viewport_position: Vector2) -> Vector2:
	return _page_root.get_global_transform_with_canvas().affine_inverse() * viewport_position


## Inverse of [method to_page_position]: viewport coordinates for a page pixel.
## Useful for placing UI on top of the page (hint markers, tooltips).
func to_viewport_position(page_position: Vector2) -> Vector2:
	return _page_root.get_global_transform_with_canvas() * page_position


func get_zoom() -> float:
	return _page_root.scale.x


## Centres the page and scales it to [member default_zoom_factor] of the
## fit-to-view zoom, and resets the zoom limits around the true fit.
func fit_page_to_view() -> void:
	if not _loaded or size.x <= 0.0 or size.y <= 0.0:
		return
	_fit_zoom = minf(size.x / float(_page_size.x), size.y / float(_page_size.y))
	if _fit_zoom <= 0.0:
		_fit_zoom = 1.0
	# The limits are anchored to the true fit; only the framing gets the margin.
	var opening_zoom := clampf(_fit_zoom * default_zoom_factor, _min_zoom(), _max_zoom())
	_page_root.scale = Vector2(opening_zoom, opening_zoom)
	_page_root.position = (size - Vector2(_page_size) * opening_zoom) * 0.5
	_view_user_adjusted = false


func reset_view() -> void:
	fit_page_to_view()


func _on_resized() -> void:
	if not _loaded:
		return
	var previous_fit := _fit_zoom
	_fit_zoom = maxf(minf(size.x / float(_page_size.x), size.y / float(_page_size.y)), 0.0001)
	if _view_user_adjusted:
		# Keep the player's framing, just re-clamp against the new limits.
		if previous_fit > 0.0:
			_apply_zoom(_page_root.scale.x * (_fit_zoom / previous_fit), size * 0.5)
		_clamp_view()
	else:
		fit_page_to_view()


func _min_zoom() -> float:
	return _fit_zoom * min_zoom_factor


func _max_zoom() -> float:
	return _fit_zoom * max_zoom_factor


## Zooms to [param target_zoom] keeping [param anchor] (viewport coordinates)
## over the same page pixel.
func _apply_zoom(target_zoom: float, anchor: Vector2) -> void:
	var clamped := clampf(target_zoom, _min_zoom(), _max_zoom())
	if is_equal_approx(clamped, _page_root.scale.x):
		return
	var page_before := to_page_position(anchor)
	_page_root.scale = Vector2(clamped, clamped)
	var page_after := to_page_position(anchor)
	_page_root.position += (page_after - page_before) * clamped
	_view_user_adjusted = true
	_clamp_view()


func _pan_by(viewport_delta: Vector2) -> void:
	var local_delta := get_global_transform_with_canvas().affine_inverse().basis_xform(viewport_delta)
	_page_root.position += local_delta
	_view_user_adjusted = true
	_clamp_view()


## Keeps the page's centre inside the view so it can never be flung off-screen.
func _clamp_view() -> void:
	var extent := Vector2(_page_size) * _page_root.scale.x
	var page_center := _page_root.position + extent * 0.5
	var clamped := Vector2(
		clampf(page_center.x, 0.0, size.x),
		clampf(page_center.y, 0.0, size.y)
	)
	_page_root.position += clamped - page_center


func _contains_viewport_position(viewport_position: Vector2) -> bool:
	var local := get_global_transform_with_canvas().affine_inverse() * viewport_position
	return Rect2(Vector2.ZERO, size).has_point(local)


# ======================================================================= input ==
# One code path: touch. "Emulate Touch From Mouse" is on in project settings, so
# a left-click drag arrives here as InputEventScreenTouch/Drag. Only wheel-zoom
# and middle-drag pan read mouse events, because those have no touch equivalent.

func _unhandled_input(event: InputEvent) -> void:
	if not _loaded:
		return
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)
	elif event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if not _contains_viewport_position(event.position) and _touches.is_empty():
			return
		_touches[event.index] = event.position
		if _touches.size() >= 2:
			# Second finger: this is a pan/zoom gesture, not a stroke. Abort the
			# accidental one-finger stroke (already-painted pixels stay).
			cancel_stroke()
			_begin_pinch()
			get_viewport().set_input_as_handled()
			return
		if begin_stroke(to_page_position(event.position)):
			_stroke_touch_index = event.index
			get_viewport().set_input_as_handled()
	else:
		_touches.erase(event.index)
		if _touches.size() < 2:
			_pinch_active = false
			_pinch_previous_distance = 0.0
		if _stroke_active and event.index == _stroke_touch_index:
			end_stroke()


func _handle_drag(event: InputEventScreenDrag) -> void:
	_touches[event.index] = event.position
	if _pinch_active and _touches.size() >= 2:
		_update_pinch()
		get_viewport().set_input_as_handled()
		return
	if _stroke_active and event.index == _stroke_touch_index:
		continue_stroke(to_page_position(event.position))
		get_viewport().set_input_as_handled()


func _begin_pinch() -> void:
	var indices := _touches.keys()
	indices.sort()
	if indices.size() < 2:
		return
	var first: Vector2 = _touches[indices[0]]
	var second: Vector2 = _touches[indices[1]]
	_pinch_previous_distance = first.distance_to(second)
	_pinch_previous_midpoint = (first + second) * 0.5
	_pinch_active = true


func _update_pinch() -> void:
	var indices := _touches.keys()
	indices.sort()
	if indices.size() < 2:
		return
	var first: Vector2 = _touches[indices[0]]
	var second: Vector2 = _touches[indices[1]]
	var distance := first.distance_to(second)
	var midpoint := (first + second) * 0.5
	if _pinch_previous_distance > 1.0 and distance > 1.0:
		_apply_zoom(_page_root.scale.x * (distance / _pinch_previous_distance), midpoint)
	_pan_by(midpoint - _pinch_previous_midpoint)
	_pinch_previous_distance = distance
	_pinch_previous_midpoint = midpoint


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed and _contains_viewport_position(event.position):
				_apply_zoom(_page_root.scale.x * WHEEL_ZOOM_STEP, event.position)
				get_viewport().set_input_as_handled()
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed and _contains_viewport_position(event.position):
				_apply_zoom(_page_root.scale.x / WHEEL_ZOOM_STEP, event.position)
				get_viewport().set_input_as_handled()
		MOUSE_BUTTON_MIDDLE:
			if event.pressed and not _contains_viewport_position(event.position):
				return
			_middle_panning = event.pressed
			if event.pressed:
				cancel_stroke()
			get_viewport().set_input_as_handled()


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if _middle_panning:
		_pan_by(event.relative)
		get_viewport().set_input_as_handled()

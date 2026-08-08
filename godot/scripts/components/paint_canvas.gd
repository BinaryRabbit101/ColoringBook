class_name PaintCanvas
extends Node2D
## The only thing that draws into the paint SubViewport.
##
## Owned by [PageView] -- calls come down from it ([method configure],
## [method queue_stamps]); this node never reaches back up.
##
## Persistence model: the SubViewport is configured CLEAR_MODE_NEVER +
## UPDATE_ALWAYS, so its render target keeps whatever was drawn in previous
## frames. That means this canvas item must hold ONLY the stamps that are still
## unrendered -- anything left in the draw list would be composited again on
## every subsequent frame. So [method _draw] draws one pending batch and drops
## it, and [method _process] re-queues a redraw every frame (drawing nothing
## when idle, which leaves the accumulated painting untouched).
##
## Uniforms are per-batch, and a canvas item has a single material, so a batch
## is flushed per frame. Consecutive stamps that share brush/region state are
## merged into one batch, so a normal stroke is one batch per frame.

## Brush stamps are drawn as textured quads (a 1x1 white texture) purely to get
## well-defined 0..1 UVs into the brush shader, which does the round-dab shaping.
var _stamp_texture: ImageTexture

var _material: ShaderMaterial
var _page_size := Vector2.ZERO

## Array of { points: PackedVector2Array, radius: float, color: Color,
##            id_color: Vector3, hardness: float, effect: Dictionary }.
##
## [code]effect[/code] is the BL-35 finish, as [BrushFinish] resolved it plus the
## stroke's seed: { mode, quad_scale, strength, seed, sheen, spark, phase }. It is
## per-batch like every other uniform, so two finishes never merge into one draw.
var _batches: Array[Dictionary] = []

## Which layer this canvas draws into (BL-38): the wax, or the effect mask beside
## it. [PageView] owns one of each, both driven by the same
## [method queue_stamps] calls with the same batches, so the mask can never cover a
## pixel the wax does not -- see [code]brush.gdshader[/code]'s TARGET_MASK.
var _target := TARGET_WAX

## The paint layer proper. The shader's default, and the only value that existed
## before BL-38.
const TARGET_WAX := 0
## BL-38's effect-mask layer: the same dabs, writing the finish's animation payload
## instead of its colour.
const TARGET_MASK := 1


func _ready() -> void:
	# The brush shader maps page pixels to ID-map UVs through MODEL_MATRIX, so
	# this node must sit at the SubViewport origin unscaled: canvas-space == page
	# pixel space.
	transform = Transform2D.IDENTITY
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	_stamp_texture = ImageTexture.create_from_image(image)


## Builds the brush material for a page of [param page_size] pixels.
##
## [param id_map] is the ONLY thing that clips a stroke, and it is the only image
## the page's optional masking art (BL-9) ever reaches: the mask is consumed by
## the mapping pipeline offline, never loaded here and never drawn.
## [param target] is BL-38's layer selector ([constant TARGET_WAX] /
## [constant TARGET_MASK]) and is fixed for the life of the canvas -- a canvas item
## has one material, and mixing the two targets in one would mean re-setting the
## uniform per batch for no gain.
func configure(
	brush_shader: Shader, id_map: Texture2D, page_size: Vector2, target: int = TARGET_WAX
) -> void:
	_page_size = page_size
	_target = target
	_material = ShaderMaterial.new()
	_material.shader = brush_shader
	_material.set_shader_parameter("page_size", page_size)
	_material.set_shader_parameter("id_map", id_map)
	_material.set_shader_parameter("effect_target", target)
	material = _material
	discard_pending()


## Which layer this canvas draws into.
func get_target() -> int:
	return _target


## Queues brush dabs centred on [param points] (page pixel coordinates).
## [param id_color] is the locked region's id_color as raw 0..1 texel values.
## [param effect] is the BL-35 finish's shader parameters ({ mode, quad_scale,
## strength, seed }); an empty dictionary paints classic wax.
func queue_stamps(
	points: PackedVector2Array,
	radius: float,
	color: Color,
	id_color: Vector3,
	hardness: float,
	effect: Dictionary = {}
) -> void:
	if points.is_empty() or _material == null:
		return
	if not _batches.is_empty():
		var last := _batches[-1]
		if (
			is_equal_approx(last["radius"], radius)
			and last["color"] == color
			and last["id_color"] == id_color
			and is_equal_approx(last["hardness"], hardness)
			and last["effect"] == effect
		):
			# Packed arrays are value types: mutate a copy, then store it back.
			var merged: PackedVector2Array = last["points"]
			merged.append_array(points)
			last["points"] = merged
			return
	_batches.append({
		"points": points.duplicate(),
		"radius": radius,
		"color": color,
		"id_color": id_color,
		"hardness": hardness,
		"effect": effect.duplicate(),
	})


## True while stamps are still waiting to be rendered into the SubViewport.
func has_pending() -> bool:
	return not _batches.is_empty()


## Throws away unrendered stamps (used when the page is cleared/reloaded).
func discard_pending() -> void:
	_batches.clear()
	queue_redraw()


func _process(_delta: float) -> void:
	# Always redraw: an empty draw list is what keeps already-painted pixels from
	# being re-composited by the CLEAR_MODE_NEVER render target.
	queue_redraw()


func _draw() -> void:
	if _material == null or _batches.is_empty():
		return
	var batch: Dictionary = _batches.pop_front()
	_material.set_shader_parameter("locked_id_color", batch["id_color"])
	_material.set_shader_parameter("hardness", batch["hardness"])
	# BL-35: the finish. A batch with no effect is classic wax, which is the
	# shader's default path -- so a page painted before finishes existed replays
	# through exactly the arithmetic it was painted with.
	var effect: Dictionary = batch.get("effect", {})
	var quad_scale := float(effect.get("quad_scale", 1.0))
	_material.set_shader_parameter("effect_mode", int(effect.get("mode", BrushFinish.MODE_CLASSIC)))
	_material.set_shader_parameter("quad_scale", quad_scale)
	_material.set_shader_parameter("effect_strength", float(effect.get("strength", 1.0)))
	_material.set_shader_parameter("effect_seed", float(effect.get("seed", 0.0)))
	# BL-38's mask payload. The wax pass never reads these three, so setting them
	# unconditionally costs a uniform write and changes no pixel of the four
	# bakeable finishes.
	_material.set_shader_parameter("effect_sheen", float(effect.get("sheen", 0.0)))
	_material.set_shader_parameter("effect_spark", float(effect.get("spark", 0.0)))
	_material.set_shader_parameter("effect_phase", float(effect.get("phase", 0.0)))
	var radius: float = batch["radius"]
	# The QUAD is what grows for a finish that spills past the dab (the glow halo);
	# the shader divides quad_scale back out, so the dab itself is unchanged.
	var half := radius * quad_scale
	var size := Vector2(half * 2.0, half * 2.0)
	var offset := Vector2(half, half)
	var color: Color = batch["color"]
	var points: PackedVector2Array = batch["points"]
	for point in points:
		draw_texture_rect(_stamp_texture, Rect2(point - offset, size), false, color)

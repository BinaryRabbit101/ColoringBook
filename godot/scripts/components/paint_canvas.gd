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
## stroke's seed: { mode, quad_scale, strength, seed }. It is per-batch like every
## other uniform, so two finishes never merge into one draw.
var _batches: Array[Dictionary] = []


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
func configure(brush_shader: Shader, id_map: Texture2D, page_size: Vector2) -> void:
	_page_size = page_size
	_material = ShaderMaterial.new()
	_material.shader = brush_shader
	_material.set_shader_parameter("page_size", page_size)
	_material.set_shader_parameter("id_map", id_map)
	material = _material
	discard_pending()


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

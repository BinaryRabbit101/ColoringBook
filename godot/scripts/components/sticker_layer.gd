class_name StickerLayer
extends Node2D
## The stickers stuck on the page (BACKLOG BL-36), drawn OVER the line art.
##
## [b]A sticker is not paint, and this layer is where that distinction lives.[/b]
## It hangs inside [PageView]'s page root, after the display art, in PAGE PIXEL
## space -- so stickers pan and zoom with the drawing for free -- and it touches
## nothing in the painting stack:
## [codeblock]
## not clipped   a sticker sits ON TOP of the line art, not inside a region
## not counted   the coverage tracker reads the paint SubViewport; this is not it
## not saved     ...into the paint PNG. A placement is a few numbers in the save.
## [/codeblock]
## That last one is why the layer exists as nodes rather than as pixels: three
## floats and two ids survive a save/restore exactly, at any resolution, and can be
## taken back off one at a time by BL-17's undo.
##
## [b]A placement is a plain dictionary[/b] (see the KEY_* constants), and it is
## the SAME dictionary in three places: the undo entry, the save file, and this
## layer's list. There is no second shape and no conversion step, which is what
## makes "the save round-trips" a property rather than a hope.
##
## [b]Textures are injected.[/b] The layer never discovers a [StickerSetDef] and
## never loads a file -- the owning screen resolves "set X, sticker Y" into a
## [Texture2D] and hands both over. A placement whose set is no longer installed
## therefore simply never reaches this class.
##
## Self-contained: it reaches nothing outside its own subtree. Signals up, calls
## down.

## Keys of a placement dictionary. These names are written to the save file, so
## they are as good as schema -- add, never rename.
##
## [code]SIZE[/code] is a FRACTION of the page's short side, not a pixel count:
## the same save has to look right whether the page is 512 px or 2048 px, and a
## pack can be re-published at a different resolution without moving every sticker
## a child ever stuck down.
const KEY_SET := "set"
const KEY_STICKER := "id"
const KEY_X := "x"
const KEY_Y := "y"
const KEY_ROTATION := "rot"
const KEY_SIZE := "size"

## How big a sticker is drawn, as a fraction of the page's SHORT side. Big enough
## to be a reward and to be tapped accurately at a child's aim; small enough that
## a handful of them decorate a drawing rather than bury it.
const DEFAULT_SIZE_RATIO := 0.17
## How far a placement may tilt, each way, in radians. Deliberately small: a
## sticker put down by hand is never quite straight, and never sideways either.
const MAX_TILT := 0.22

## The plop: the sticker arrives oversized and springs down onto the paper.
const PLOP_SECONDS := 0.34
const PLOP_OVERSHOOT := 1.55
## ...and its shadow settles with it, which is what sells "stuck on top" rather
## than "printed in".
const SHADOW_ALPHA := 0.22
const SHADOW_OFFSET := Vector2(0.0, 0.045)

## A sticker was stuck down (or restored). Presentational hook; the screen owns
## the history and the save.
signal sticker_added(placement: Dictionary)
## The most recent sticker was peeled off (undo).
signal sticker_removed(placement: Dictionary)

## Page size in pixels, injected by [PageView] on every page load. Sticker sizes
## and positions are page-space, so this is the only thing the layer measures
## against.
var _page_size := Vector2i.ZERO
## Placements, oldest first. The list IS the save shape.
var _placements: Array[Dictionary] = []
## One [Sprite2D] per placement, in the same order.
var _sprites: Array[Node2D] = []


func _init() -> void:
	# Node2D has no mouse handling of its own, but say it out loud: the page's
	# input path is PageView's, and a sticker must never intercept a press.
	y_sort_enabled = false


## Tells the layer how big the page it is drawn over is. Called by [PageView] on
## every load; re-lays every sticker that is already down, so a restore that runs
## before the page has measured itself still lands correctly.
func set_page_size(page_size: Vector2i) -> void:
	if _page_size == page_size:
		return
	_page_size = page_size
	for i in _sprites.size():
		_apply_transform(_sprites[i], _placements[i], 1.0)


func get_page_size() -> Vector2i:
	return _page_size


## Page pixels one sticker of [param ratio] is drawn across -- the page's SHORT
## side times the ratio, so a tall page and a wide page get the same sticker.
func sticker_pixels(ratio: float) -> float:
	var short := float(mini(maxi(_page_size.x, 1), maxi(_page_size.y, 1)))
	return maxf(short * maxf(ratio, 0.001), 1.0)


# ==================================================================== the list ==

## Sticks [param placement] down with [param texture].
##
## [param animate] plays the plop; a RESTORE passes false, because a page that
## opens with six stickers popping onto it reads as six things going wrong.
func push(placement: Dictionary, texture: Texture2D, animate: bool = true) -> void:
	if texture == null:
		return
	var sprite := _build_sprite(texture)
	add_child(sprite)
	_placements.append(placement.duplicate())
	_sprites.append(sprite)
	if animate and is_inside_tree():
		_apply_transform(sprite, placement, PLOP_OVERSHOOT)
		sprite.modulate.a = 0.0
		var tween := create_tween()
		tween.set_parallel(true)
		tween.tween_method(
			func(scale: float) -> void:
				if is_instance_valid(sprite):
					_apply_transform(sprite, placement, scale),
			PLOP_OVERSHOOT, 1.0, PLOP_SECONDS
		).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(sprite, "modulate:a", 1.0, PLOP_SECONDS * 0.45)
	else:
		_apply_transform(sprite, placement, 1.0)
	sticker_added.emit(placement)


## Peels the MOST RECENT sticker off and returns its placement ({} when there is
## none).
##
## [b]Last is always the right one[/b] for BL-17's undo: only a placement adds to
## this list, so the newest history entry of kind "sticker" is by construction the
## newest sticker on the page. Stickers restored from a previous visit sit at the
## front of the list and are never reachable this way -- exactly like the baseline
## paint layer undo cannot rub out.
func pop() -> Dictionary:
	if _placements.is_empty():
		return {}
	var sprite: Node2D = _sprites.pop_back()
	if is_instance_valid(sprite):
		sprite.queue_free()
	var placement: Dictionary = _placements.pop_back()
	sticker_removed.emit(placement)
	return placement


## Takes every sticker off. Page change and Start over only.
func clear() -> void:
	for sprite in _sprites:
		if is_instance_valid(sprite):
			sprite.queue_free()
	_sprites.clear()
	_placements.clear()


## The placements, oldest first -- a COPY, so a caller cannot edit the layer by
## editing what it was handed. This is what goes into the save.
func get_placements() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for placement in _placements:
		out.append(placement.duplicate())
	return out


func count() -> int:
	return _placements.size()


## The sprite for placement [param index]. Tests measure it; the game never
## reads it.
func get_sprite(index: int) -> Node2D:
	if index < 0 or index >= _sprites.size():
		return null
	return _sprites[index]


# =================================================================== placements ==

## Builds a placement dictionary for [param sticker] of [param set_def] at
## [param page_position]. The tilt is random, which is the whole charm; everything
## else is a function of the page.
##
## Static and pure, so the screen can build one without a layer in the tree and a
## test can build one to compare against.
static func make_placement(
	set_uid: String,
	sticker_id: String,
	page_position: Vector2,
	rotation: float,
	size_ratio: float = DEFAULT_SIZE_RATIO
) -> Dictionary:
	return {
		KEY_SET: set_uid,
		KEY_STICKER: sticker_id,
		KEY_X: snappedf(page_position.x, 0.01),
		KEY_Y: snappedf(page_position.y, 0.01),
		KEY_ROTATION: snappedf(rotation, 0.0001),
		KEY_SIZE: snappedf(size_ratio, 0.0001),
	}


## A random tilt inside [constant MAX_TILT].
static func random_tilt() -> float:
	return randf_range(-MAX_TILT, MAX_TILT)


## Whatever a save file put in a sticker slot, as a usable placement -- or {} when
## it is not one. Tolerant on purpose: an unreadable entry costs one sticker, never
## the page.
static func to_placement(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var entry: Dictionary = raw
	var set_uid := String(entry.get(KEY_SET, "")).strip_edges()
	var sticker_id := String(entry.get(KEY_STICKER, "")).strip_edges()
	if set_uid == "" or sticker_id == "":
		return {}
	var size_ratio := float(entry.get(KEY_SIZE, DEFAULT_SIZE_RATIO))
	return {
		KEY_SET: set_uid,
		KEY_STICKER: sticker_id,
		KEY_X: float(entry.get(KEY_X, 0.0)),
		KEY_Y: float(entry.get(KEY_Y, 0.0)),
		KEY_ROTATION: float(entry.get(KEY_ROTATION, 0.0)),
		KEY_SIZE: size_ratio if size_ratio > 0.0 else DEFAULT_SIZE_RATIO,
	}


static func placement_position(placement: Dictionary) -> Vector2:
	return Vector2(float(placement.get(KEY_X, 0.0)), float(placement.get(KEY_Y, 0.0)))


# ===================================================================== internal ==

## One sticker: its drop shadow and the art, in a container the plop scales as a
## whole. A [Sprite2D] pair rather than a [method CanvasItem.draw_texture] call
## because the plop is a per-sticker tween and a redraw-per-frame layer would
## re-run every sticker's transform for one that is moving.
func _build_sprite(texture: Texture2D) -> Node2D:
	var root := Node2D.new()
	root.name = "Sticker%d" % _placements.size()

	var shadow := Sprite2D.new()
	shadow.texture = texture
	shadow.centered = true
	shadow.modulate = Color(0.0, 0.0, 0.0, SHADOW_ALPHA)
	shadow.name = "Shadow"
	root.add_child(shadow)

	var art := Sprite2D.new()
	art.texture = texture
	art.centered = true
	art.name = "Art"
	root.add_child(art)
	return root


## Places, tilts and sizes one sticker. [param scale_multiplier] is the plop's
## overshoot; 1.0 is at rest.
func _apply_transform(sprite: Node2D, placement: Dictionary, scale_multiplier: float) -> void:
	if not is_instance_valid(sprite):
		return
	var art := sprite.get_node_or_null("Art") as Sprite2D
	var shadow := sprite.get_node_or_null("Shadow") as Sprite2D
	var texture := art.texture if art != null else null
	if texture == null:
		return
	var drawn := sticker_pixels(float(placement.get(KEY_SIZE, DEFAULT_SIZE_RATIO)))
	var longest := maxf(float(maxi(texture.get_width(), texture.get_height())), 1.0)
	var factor := (drawn / longest) * scale_multiplier
	sprite.position = placement_position(placement)
	sprite.rotation = float(placement.get(KEY_ROTATION, 0.0))
	sprite.scale = Vector2(factor, factor)
	if shadow != null:
		# In the sticker's own space, so the shadow tilts with it.
		shadow.position = SHADOW_OFFSET * longest

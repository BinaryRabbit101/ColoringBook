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

## How big the peel badge is, as a fraction of the sticker it hangs off (BL-39).
## 0.34 of a 0.17-of-the-page sticker is comfortably past the 48 px touch floor at
## every zoom the page opens at, and it is what [method peel_badge_radius] answers.
const PEEL_BADGE_RATIO := 0.34
## Where the badge parks, as a fraction of the sticker's drawn size from its
## centre. Deliberately NOT rotated with the placement: the tilt is at most
## [constant MAX_TILT] and a badge that moved with it would be harder to aim at.
const PEEL_BADGE_OFFSET := Vector2(0.42, -0.42)
## The chosen sticker wiggles, the way a thing you have picked up wiggles. Small
## enough not to move where the badge is, big enough to say "this one".
const WIGGLE_RADIANS := 0.055
const WIGGLE_HZ := 2.6

## A sticker was stuck down (or restored). Presentational hook; the screen owns
## the history and the save.
signal sticker_added(placement: Dictionary)
## A sticker was peeled off -- by an undo, or by the player choosing it and
## pressing its badge (BL-39). Presentational hook; the screen owns the history
## and the save.
signal sticker_removed(placement: Dictionary)

## Page size in pixels, injected by [PageView] on every page load. Sticker sizes
## and positions are page-space, so this is the only thing the layer measures
## against.
var _page_size := Vector2i.ZERO
## Placements, oldest first. The list IS the save shape.
var _placements: Array[Dictionary] = []
## One [Sprite2D] per placement, in the same order.
var _sprites: Array[Node2D] = []
## Per placement, its sprite-sheet spec ({} for a still sticker) -- see
## [method set_sheet]. Index-parallel with [member _placements].
var _sheets: Array[Dictionary] = []
## Which sticker the player has CHOSEN (BL-39), or -1. The chosen one wiggles and
## wears the peel badge; nothing else about it changes.
var _selected := -1
## The badge, drawn by its own child so the layer never redraws every sticker for
## one that is moving.
var _badge: Node2D
var _clock := 0.0


## The peel badge: a red disc with a white cross, drawn from primitives like every
## other affordance in this game. An inner class so the layer stays one file, and a
## [Node2D] of its own so choosing a sticker costs one small redraw rather than a
## redraw of every sticker on the page.
##
## It is drawn in PAGE space, so it pans and zooms with the drawing exactly as the
## stickers do -- and its hit test ([method StickerLayer.peel_badge_hit]) is done in
## page space too, against the same two numbers, so what is drawn and what is
## pressed can never drift apart.
class PeelBadge extends Node2D:
	## The crayon-box red the toolbar's Start over already wears, so "this takes
	## something away" is one colour across the game.
	const FACE := Color(0.858824, 0.278431, 0.235294)
	const RIM := Color(1.0, 0.988235, 0.960784)
	const DROP := Color(0.0, 0.0, 0.0, 0.26)

	var radius := 24.0

	func _init() -> void:
		z_index = 1

	func _draw() -> void:
		if radius <= 0.5:
			return
		draw_circle(Vector2(0.0, radius * 0.10), radius, DROP)
		draw_circle(Vector2.ZERO, radius, FACE)
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 28, RIM, radius * 0.13, true)
		var arm := radius * 0.42
		var thickness := maxf(radius * 0.17, 2.0)
		draw_line(Vector2(-arm, -arm), Vector2(arm, arm), RIM, thickness, true)
		draw_line(Vector2(-arm, arm), Vector2(arm, -arm), RIM, thickness, true)


func _init() -> void:
	# Node2D has no mouse handling of its own, but say it out loud: the page's
	# input path is PageView's, and a sticker must never intercept a press.
	y_sort_enabled = false
	set_process(false)


## Tells the layer how big the page it is drawn over is. Called by [PageView] on
## every load; re-lays every sticker that is already down, so a restore that runs
## before the page has measured itself still lands correctly.
func set_page_size(page_size: Vector2i) -> void:
	if _page_size == page_size:
		return
	_page_size = page_size
	for i in _sprites.size():
		_apply_transform(_sprites[i], _placements[i], 1.0)
	_position_badge()


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
##
## [param sheet] is the sprite-sheet spec for an ANIMATED sticker (BL-43) -- see
## [method sheet_spec]. {} is a still sticker and is what every sticker was before
## BL-43. The layer never discovers it: the owning screen resolves it off the
## [StickerDef] and hands it over with the texture, exactly like the texture.
func push(
	placement: Dictionary, texture: Texture2D, animate: bool = true, sheet: Dictionary = {}
) -> void:
	insert(_placements.size(), placement, texture, animate, sheet)


## Sticks [param placement] down AT [param index], pushing the stickers above it up
## one. Appending is the ordinary case ([method push]); an arbitrary index is what
## BL-39's undo of a peel needs, because a sticker that was peeled out of the
## middle of the stack has to go back where it was or the drawing changes.
func insert(
	index: int,
	placement: Dictionary,
	texture: Texture2D,
	animate: bool = true,
	sheet: Dictionary = {}
) -> void:
	if texture == null:
		return
	var at := clampi(index, 0, _placements.size())
	var resolved := _resolve_sheet(sheet, texture)
	var sprite := _build_sprite(texture, resolved)
	add_child(sprite)
	move_child(sprite, at)
	_placements.insert(at, placement.duplicate())
	_sprites.insert(at, sprite)
	_sheets.insert(at, resolved)
	if _selected >= at:
		_selected += 1
	_position_badge()
	_sync_processing()
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
	return remove_at(_placements.size() - 1)


## Peels the sticker at [param index] off and returns its placement ({} when there
## is no such sticker). [method pop] is this with the last index, which is what
## BL-17's undo of a placement uses; BL-39's peel names the one the player chose.
func remove_at(index: int) -> Dictionary:
	if index < 0 or index >= _placements.size():
		return {}
	# Let go of it BEFORE it stops existing: dropping the selection puts the wiggle
	# back where it belongs, and it must not run against an index that has moved.
	if _selected == index:
		_set_selected(-1)
	var sprite: Node2D = _sprites[index]
	if is_instance_valid(sprite):
		sprite.queue_free()
	_sprites.remove_at(index)
	_sheets.remove_at(index)
	var placement: Dictionary = _placements[index]
	_placements.remove_at(index)
	if _selected > index:
		_selected -= 1
	_position_badge()
	_sync_processing()
	sticker_removed.emit(placement)
	return placement


## Takes every sticker off. Page change and Start over only.
func clear() -> void:
	for sprite in _sprites:
		if is_instance_valid(sprite):
			sprite.queue_free()
	_sprites.clear()
	_placements.clear()
	_sheets.clear()
	_set_selected(-1)
	_sync_processing()


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


## The placement at [param index], or {}.
func get_placement(index: int) -> Dictionary:
	if index < 0 or index >= _placements.size():
		return {}
	return _placements[index].duplicate()


# ===================================================== choosing one to peel (BL-39) ==
# A sticker a child has stuck down has to be removable, and the only input the page
# gets is a TAP with a page position (BL-36's `paint_blocked` hook). So peeling is
# built out of the same tap, twice:
#
#   tap ON a sticker      -> it is CHOSEN: it wiggles and grows a peel badge
#   tap ON the badge      -> it comes off
#   tap anywhere else     -> nothing is chosen any more (and the tap places, as ever)
#
# Two taps, never one, for the same reason the shop asks before a download and the
# settings panel asks before an erase: a destructive action is never one tap away.
# The layer owns the hit-testing and the drawing; the owning screen owns what the
# answers MEAN, the history entry and the save.

## Radius of the peel badge, in page pixels, for a sticker of [param size_ratio].
func peel_badge_radius(size_ratio: float = DEFAULT_SIZE_RATIO) -> float:
	return sticker_pixels(size_ratio) * PEEL_BADGE_RATIO * 0.5


## Centre of the peel badge, in page pixels, for [param placement].
func peel_badge_position(placement: Dictionary) -> Vector2:
	var drawn := sticker_pixels(float(placement.get(KEY_SIZE, DEFAULT_SIZE_RATIO)))
	return placement_position(placement) + PEEL_BADGE_OFFSET * drawn


## Index of the TOPMOST sticker under [param page_position], or -1.
##
## Topmost, because that is the one the finger is pointing at: the list is drawn
## oldest first, so it is searched newest first. The test is the sticker's own box
## with the tilt taken back out -- not its alpha, because a child aiming at the gap
## inside a ring-shaped sticker means that sticker, and a per-pixel test would
## quietly refuse them.
func sticker_at(page_position: Vector2) -> int:
	for i in range(_placements.size() - 1, -1, -1):
		var placement: Dictionary = _placements[i]
		var half := sticker_pixels(float(placement.get(KEY_SIZE, DEFAULT_SIZE_RATIO))) * 0.5
		if half <= 0.0:
			continue
		var local := (page_position - placement_position(placement)).rotated(
			-float(placement.get(KEY_ROTATION, 0.0))
		)
		if absf(local.x) <= half and absf(local.y) <= half:
			return i
	return -1


## True when [param page_position] lands on the CHOSEN sticker's peel badge. False
## whenever nothing is chosen, which is what makes "the badge is the only one-tap
## delete, and it only exists after the first tap" a property of this method.
func peel_badge_hit(page_position: Vector2) -> bool:
	if _selected < 0 or _selected >= _placements.size():
		return false
	var placement: Dictionary = _placements[_selected]
	var radius := peel_badge_radius(float(placement.get(KEY_SIZE, DEFAULT_SIZE_RATIO)))
	return page_position.distance_to(peel_badge_position(placement)) <= radius


## Chooses the sticker at [param index] (or -1 for none). Presentational only --
## nothing is removed and nothing is saved until the badge is pressed.
func select(index: int) -> void:
	_set_selected(index if index >= 0 and index < _placements.size() else -1)


func clear_selection() -> void:
	_set_selected(-1)


## Which sticker is chosen, or -1.
func get_selected_index() -> int:
	return _selected


func has_selection() -> bool:
	return _selected >= 0 and _selected < _placements.size()


func _set_selected(index: int) -> void:
	if _selected == index:
		_position_badge()
		return
	var previous := _selected
	_selected = index
	# The one it was on goes back to lying flat.
	if previous >= 0 and previous < _sprites.size():
		_apply_transform(_sprites[previous], _placements[previous], 1.0)
	_ensure_badge()
	_position_badge()
	_sync_processing()


func _ensure_badge() -> void:
	if is_instance_valid(_badge):
		return
	_badge = PeelBadge.new()
	_badge.name = "PeelBadge"
	add_child(_badge)


func _position_badge() -> void:
	if not is_instance_valid(_badge):
		return
	if not has_selection():
		_badge.visible = false
		return
	var placement: Dictionary = _placements[_selected]
	var badge := _badge as PeelBadge
	badge.radius = peel_badge_radius(float(placement.get(KEY_SIZE, DEFAULT_SIZE_RATIO)))
	badge.position = peel_badge_position(placement)
	badge.visible = true
	# Always in front of every sticker, including ones stuck down after the chosen
	# one: the badge is UI, not a sticker.
	move_child(_badge, get_child_count() - 1)
	badge.queue_redraw()


## The wiggle on the chosen sticker, and the frame clock for animated ones (BL-43).
## Off entirely when there is nothing to move, which is every page that has neither.
func _sync_processing() -> void:
	if _has_animation():
		set_process(true)
		return
	set_process(false)


func _has_animation() -> bool:
	if has_selection():
		return true
	for sheet in _sheets:
		if not sheet.is_empty():
			return true
	return false


func _process(delta: float) -> void:
	_clock += delta
	if has_selection():
		var sprite := _sprites[_selected]
		if is_instance_valid(sprite):
			sprite.rotation = (
				float(_placements[_selected].get(KEY_ROTATION, 0.0))
				+ sin(_clock * TAU * WIGGLE_HZ) * WIGGLE_RADIANS
			)
	_advance_frames()


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


# ============================================== animated stickers (BL-43) ==
# A sticker's image may be a SPRITE SHEET, and its set says so with an `anim` block
# ({hframes, vframes, frames, fps}). Nothing about the placement changes -- the same
# five numbers and two ids are saved -- because the animation is a property of the
# STICKER, not of where a child put it: re-publishing a set as animated must not
# move a sticker already stuck down.
#
# [b]It is Sprite2D's own hframes/vframes[/b], not a shader and not an AtlasTexture
# per frame. The layer already draws each sticker with two Sprite2Ds (art + shadow),
# and Godot's Sprite2D crops to `frame` on the GPU with the texture uploaded once,
# which is exactly the render path a runtime-loaded pack texture needs: no importer,
# no per-frame resource, and the shadow steps with the art for free.

## Keys of a sheet spec. Named here because they are read out of pack JSON.
const SHEET_HFRAMES := "hframes"
const SHEET_VFRAMES := "vframes"
const SHEET_FRAMES := "frames"
const SHEET_FPS := "fps"
## Frames a second when a set gives no (or a silly) number.
const DEFAULT_SHEET_FPS := 12.0
## Bounds on what a pack may ask for. A sheet with 4096 columns is a mistake, and
## an fps of 400 is a strobe pointed at a child.
const MAX_SHEET_AXIS := 64
const MAX_SHEET_FPS := 60.0

## A sheet spec from whatever a set (or a pack's JSON) offered, or {} when the
## sticker is a still one. Static and pure, so [StickerDef] and the picker button
## resolve theirs through the same three lines this layer does.
static func sheet_spec(hframes: int, vframes: int, frames: int, fps: float) -> Dictionary:
	var h := clampi(hframes, 1, MAX_SHEET_AXIS)
	var v := clampi(vframes, 1, MAX_SHEET_AXIS)
	if h * v <= 1:
		return {}
	var count := h * v if frames <= 0 else clampi(frames, 1, h * v)
	if count <= 1:
		return {}
	return {
		SHEET_HFRAMES: h,
		SHEET_VFRAMES: v,
		SHEET_FRAMES: count,
		SHEET_FPS: clampf(fps if fps > 0.0 else DEFAULT_SHEET_FPS, 0.1, MAX_SHEET_FPS),
	}


## The size ONE frame of [param texture] is drawn at under [param sheet]. The whole
## image for a still sticker, which is what keeps every pre-BL-43 sticker's geometry
## byte-for-byte what it was.
static func frame_size(texture: Texture2D, sheet: Dictionary) -> Vector2:
	if texture == null:
		return Vector2.ZERO
	var whole := Vector2(texture.get_size())
	if sheet.is_empty():
		return whole
	return Vector2(
		whole.x / float(int(sheet[SHEET_HFRAMES])), whole.y / float(int(sheet[SHEET_VFRAMES]))
	)


## A sheet a texture cannot actually carry is dropped rather than drawn wrong: a
## 256x256 image that claims 5 columns would crop every frame off centre, and a
## still sticker is a far better failure than a jittering one.
func _resolve_sheet(sheet: Dictionary, texture: Texture2D) -> Dictionary:
	if sheet.is_empty() or texture == null:
		return {}
	var h := int(sheet.get(SHEET_HFRAMES, 1))
	var v := int(sheet.get(SHEET_VFRAMES, 1))
	if h <= 0 or v <= 0:
		return {}
	if texture.get_width() % h != 0 or texture.get_height() % v != 0:
		push_warning(
			"StickerLayer: a %dx%d image cannot be a %dx%d sheet; drawing it still."
			% [texture.get_width(), texture.get_height(), h, v]
		)
		return {}
	return sheet.duplicate()


## Steps every animated sticker to the frame its own clock is on. One pass over the
## list per frame, doing nothing at all when no sticker on the page is animated
## (see [method _sync_processing], which is what stops the layer processing then).
func _advance_frames() -> void:
	for i in _sheets.size():
		var sheet: Dictionary = _sheets[i]
		if sheet.is_empty():
			continue
		var sprite := _sprites[i]
		if not is_instance_valid(sprite):
			continue
		var count := int(sheet[SHEET_FRAMES])
		var frame := int(_clock * float(sheet[SHEET_FPS])) % count
		for child in sprite.get_children():
			var part := child as Sprite2D
			if part != null and part.frame != frame:
				part.frame = frame


# ===================================================================== internal ==

## One sticker: its drop shadow and the art, in a container the plop scales as a
## whole. A [Sprite2D] pair rather than a [method CanvasItem.draw_texture] call
## because the plop is a per-sticker tween and a redraw-per-frame layer would
## re-run every sticker's transform for one that is moving.
func _build_sprite(texture: Texture2D, sheet: Dictionary) -> Node2D:
	var root := Node2D.new()
	root.name = "Sticker%d" % _placements.size()

	var shadow := _build_part(texture, sheet, "Shadow")
	shadow.modulate = Color(0.0, 0.0, 0.0, SHADOW_ALPHA)
	root.add_child(shadow)

	root.add_child(_build_part(texture, sheet, "Art"))
	return root


## One half of a sticker (the art, or its shadow). A sheet becomes Sprite2D's own
## hframes/vframes, so the node crops to one cell and [method Sprite2D.get_rect]
## reports the FRAME -- which is what makes the plop, the tilt and the shadow offset
## all keep working with no arithmetic of their own.
func _build_part(texture: Texture2D, sheet: Dictionary, part_name: String) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.texture = texture
	sprite.centered = true
	sprite.name = part_name
	if not sheet.is_empty():
		sprite.hframes = int(sheet[SHEET_HFRAMES])
		sprite.vframes = int(sheet[SHEET_VFRAMES])
		sprite.frame = 0
	return sprite


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
	# The FRAME, not the sheet: an animated sticker is drawn the size a still one of
	# the same placement would be (BL-43), so publishing a set as animated moves
	# nothing a child already stuck down.
	var cell := frame_size(texture, _sheet_for(sprite))
	var longest := maxf(maxf(cell.x, cell.y), 1.0)
	var factor := (drawn / longest) * scale_multiplier
	sprite.position = placement_position(placement)
	sprite.rotation = float(placement.get(KEY_ROTATION, 0.0))
	sprite.scale = Vector2(factor, factor)
	if shadow != null:
		# In the sticker's own space, so the shadow tilts with it.
		shadow.position = SHADOW_OFFSET * longest


## The sheet [param sprite] was built with ({} for a still sticker). Looked up by
## identity rather than stored on the node, so the index-parallel arrays stay the
## one source of truth.
func _sheet_for(sprite: Node2D) -> Dictionary:
	var index := _sprites.find(sprite)
	return _sheets[index] if index >= 0 and index < _sheets.size() else {}

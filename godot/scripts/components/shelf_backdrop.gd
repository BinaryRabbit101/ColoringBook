class_name ShelfBackdrop
extends Control
## The room the bookshelf stands in (BL-28), drawn entirely from primitives.
##
## The shelf screen used to be a grid of cards on one flat dark rectangle. This
## node is the "cosy playroom corner" half of the fix: a warm wall that graduates
## from sunlit cream at the top to apricot at the bottom, a pool of light behind
## where the bookcase sits, sparse pastel wallpaper dots, a skirting board and a
## wooden floor, and a soft vignette that pushes the corners back so the middle of
## the screen reads as the front of the room.
##
## [b]No art assets[/b] -- the same rule [CrayonButton] and [TitleScreen] follow.
## The two graduated fills are [GradientTexture2D]s built once in [method _init]
## (a gradient stretched over a rect is one draw call and resolution independent);
## everything else is rects, circles and lines.
##
## Self-contained and input-transparent: it is told nothing, reaches nothing, and
## its [member Control.mouse_filter] is IGNORE so every tap lands on the books.

## Wall, top to bottom. Warm rather than white: the covers on the shelf are
## saturated crayon colours and a white wall would fight them.
const WALL_TOP := Color(0.984314, 0.898039, 0.760784)
const WALL_MID := Color(0.976471, 0.823529, 0.647059)
const WALL_BOTTOM := Color(0.933333, 0.717647, 0.541176)
## Corner shading. Warm brown, never grey -- grey in a warm room reads as dirt.
const VIGNETTE := Color(0.372549, 0.203922, 0.101961, 0.34)
## The pool of light the bookcase stands in, centred on the middle of the wall --
## the bookcase is bottom-aligned, so this is roughly where its books end up.
const LIGHT_POOL := Color(1.0, 0.976471, 0.898039, 0.30)
const LIGHT_POOL_CENTER := Vector2(0.5, 0.44)
const LIGHT_POOL_LAYERS := 7

## Floor: a band across the bottom, in planks, with a cream skirting board where
## it meets the wall.
const FLOOR_RATIO := 0.19
const FLOOR_MIN_HEIGHT := 104.0
const FLOOR := Color(0.741176, 0.494118, 0.290196)
const FLOOR_DARK := Color(0.607843, 0.376471, 0.211765)
const FLOOR_SHEEN := Color(1.0, 0.909804, 0.780392, 0.16)
const PLANK_WIDTH := 132.0
const SKIRTING := Color(0.980392, 0.937255, 0.858824)
const SKIRTING_EDGE := Color(0.788235, 0.694118, 0.588235)
const SKIRTING_HEIGHT := 18.0

## Wallpaper dots: a jittered grid of pastel crayon spots, faint enough to read as
## paper rather than as confetti.
const DOT_SPACING := 118.0
const DOT_ALPHA := 0.15
const DOT_SEED := 20260807
const DOT_COLORS: PackedColorArray = [
	Color(0.898039, 0.372549, 0.313726),
	Color(0.960784, 0.635294, 0.223529),
	Color(0.396078, 0.694118, 0.372549),
	Color(0.254902, 0.596078, 0.792157),
	Color(0.576471, 0.427451, 0.756863),
	Color(0.917647, 0.494118, 0.643137),
]

var _wall: GradientTexture2D
var _vignette: GradientTexture2D


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wall = _linear_gradient([0.0, 0.52, 1.0], [WALL_TOP, WALL_MID, WALL_BOTTOM])
	_vignette = _radial_gradient()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	if size.x <= 1.0 or size.y <= 1.0:
		return
	var room := Rect2(Vector2.ZERO, size)
	draw_texture_rect(_wall, room, false)
	_draw_light_pool()
	_draw_dots()
	_draw_floor()
	# Last, over everything: the corners fall away.
	draw_texture_rect(_vignette, room, false)


## Concentric translucent discs behind the bookcase. Stacked alpha gives a soft
## falloff without a shader or a texture.
func _draw_light_pool() -> void:
	var center := Vector2(size.x * LIGHT_POOL_CENTER.x, size.y * LIGHT_POOL_CENTER.y)
	var biggest := maxf(size.x, size.y) * 0.62
	var alpha := LIGHT_POOL.a / float(LIGHT_POOL_LAYERS)
	for i in LIGHT_POOL_LAYERS:
		var t := 1.0 - float(i) / float(LIGHT_POOL_LAYERS)
		draw_circle(
			center, biggest * t,
			Color(LIGHT_POOL.r, LIGHT_POOL.g, LIGHT_POOL.b, alpha)
		)


## Wallpaper spots on a seeded jittered grid, so the pattern is identical in every
## screenshot and every session (the smoke harnesses diff renders).
func _draw_dots() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = DOT_SEED
	var floor_top := size.y - _floor_height()
	var columns := int(ceil(size.x / DOT_SPACING)) + 1
	var rows := int(ceil(floor_top / DOT_SPACING)) + 1
	for row in rows:
		for column in columns:
			var spot := Vector2(
				float(column) * DOT_SPACING + rng.randf_range(-26.0, 26.0),
				float(row) * DOT_SPACING + rng.randf_range(-26.0, 26.0)
			)
			var radius := rng.randf_range(4.0, 9.0)
			if spot.y > floor_top - radius:
				continue
			var base := DOT_COLORS[rng.randi() % DOT_COLORS.size()]
			draw_circle(spot, radius, Color(base.r, base.g, base.b, DOT_ALPHA))


func _floor_height() -> float:
	return maxf(size.y * FLOOR_RATIO, FLOOR_MIN_HEIGHT)


## Floorboards running away from the viewer, plus the skirting board that makes
## the wall and the floor two surfaces instead of two colours.
func _draw_floor() -> void:
	var height := _floor_height()
	var top := size.y - height
	draw_rect(Rect2(0.0, top, size.x, height), FLOOR)
	# Plank seams, fanned very slightly so the floor recedes.
	var seams := int(ceil(size.x / PLANK_WIDTH)) + 2
	var center_x := size.x * 0.5
	for i in seams:
		var x := float(i) * PLANK_WIDTH - PLANK_WIDTH
		var spread := (x - center_x) * 0.10
		draw_line(
			Vector2(x, top), Vector2(x + spread, size.y), FLOOR_DARK, 3.0, true
		)
	# A sheen along the front of the floor: waxed boards catch the light.
	draw_rect(Rect2(0.0, size.y - height * 0.22, size.x, height * 0.22), FLOOR_SHEEN)
	# Skirting board, sitting on the floor line.
	draw_rect(Rect2(0.0, top - SKIRTING_HEIGHT, size.x, SKIRTING_HEIGHT), SKIRTING)
	draw_line(
		Vector2(0.0, top - SKIRTING_HEIGHT), Vector2(size.x, top - SKIRTING_HEIGHT),
		SKIRTING_EDGE, 2.0
	)
	draw_line(Vector2(0.0, top), Vector2(size.x, top), FLOOR_DARK, 3.0)


# ================================================================== textures ==

static func _linear_gradient(offsets: Array, colors: Array) -> GradientTexture2D:
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array(offsets)
	ramp.colors = PackedColorArray(colors)
	var texture := GradientTexture2D.new()
	texture.gradient = ramp
	texture.width = 8
	texture.height = 512
	texture.fill_from = Vector2(0.5, 0.0)
	texture.fill_to = Vector2(0.5, 1.0)
	return texture


## Transparent in the middle, warm brown at the edge. Stretched over a non-square
## screen it becomes an ellipse, which is what a vignette wants anyway.
static func _radial_gradient() -> GradientTexture2D:
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.58, 1.0])
	ramp.colors = PackedColorArray([
		Color(VIGNETTE.r, VIGNETTE.g, VIGNETTE.b, 0.0),
		Color(VIGNETTE.r, VIGNETTE.g, VIGNETTE.b, VIGNETTE.a * 0.22),
		VIGNETTE,
	])
	var texture := GradientTexture2D.new()
	texture.gradient = ramp
	texture.width = 256
	texture.height = 256
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	return texture

class_name BookComplete
extends Control
## The celebration after the last page of a book is finished (DESIGN.md 2:
## "after last page -> BookComplete -> BookSelect").
##
## Two ways out, and the screen picks neither:
##   [signal again_requested] -- colour this book again from page 1
##   [signal books_requested]  -- back to the shelf
## The parent owns what those mean; in particular the parent, not this screen,
## calls [code]GameState.erase_book_progress()[/code] before restarting a book.
## This screen is pure presentation and holds no save logic at all.
##
## [b]The confetti[/b] is a [CPUParticles2D] rather than a tween swarm: one node,
## GPU-free, and it costs nothing on the mobile pass. Its particles take their
## colours from the child palette through [member CPUParticles2D.color_initial_ramp]
## with CONSTANT interpolation, so each scrap is one flat crayon colour instead of
## a muddy blend -- the same "no art assets, palette-driven" rule the rest of the
## shell follows.

## Colour this book again (its saved paint and progress are wiped by the parent).
signal again_requested(book: BookDef)
## Back to the shelf.
signal books_requested()

## Confetti scrap size, in pixels.
const SCRAP_SIZE := 14
## Seconds the headline takes to pop in.
const POP_SECONDS := 0.45


@onready var _confetti: CPUParticles2D = $Confetti
@onready var _headline: Label = $Center/Column/Headline
@onready var _book_label: Label = $Center/Column/BookLabel
@onready var _again_button: Button = $Center/Column/Buttons/AgainButton
@onready var _books_button: Button = $Center/Column/Buttons/BooksButton

var _book: BookDef


func _ready() -> void:
	_again_button.pressed.connect(_on_again_pressed)
	_books_button.pressed.connect(func() -> void: books_requested.emit())
	resized.connect(_layout_confetti)
	# The headline scales about its own centre, and its rect is only known after
	# the first layout pass.
	_headline.resized.connect(func() -> void: _headline.pivot_offset = _headline.size * 0.5)
	_configure_confetti()
	_layout_confetti()
	_pop_headline()


# ================================================================= injection ==

## Names the finished book. Passing null leaves the subtitle blank -- the screen
## still works, it just has nothing to name.
func set_book(book: BookDef) -> void:
	_book = book
	_book_label.text = "" if book == null else "“%s” — all %d pages colored" % [
		book.display_name, book.page_count()
	]


func get_book() -> BookDef:
	return _book


func get_again_button() -> Button:
	return _again_button


func get_books_button() -> Button:
	return _books_button


func get_headline_text() -> String:
	return _headline.text


# ================================================================== confetti ==

func _configure_confetti() -> void:
	_confetti.texture = _make_scrap_texture()
	var palette := GameState.get_palette_for_mode(GameState.MODE_CHILD)
	if palette == null or palette.color_count() == 0:
		return
	var gradient := Gradient.new()
	# Flat, distinct scraps: constant interpolation turns the ramp into a lookup
	# table of crayon colours rather than a blend between them.
	gradient.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	gradient.offsets = PackedFloat32Array()
	gradient.colors = PackedColorArray()
	var count := palette.color_count()
	for i in count:
		gradient.add_point(float(i) / float(count), palette.get_color(i))
	# add_point() cannot remove the two default stops, so drop them afterwards.
	while gradient.get_point_count() > count:
		gradient.remove_point(gradient.get_point_count() - 1)
	_confetti.color_initial_ramp = gradient


static func _make_scrap_texture() -> ImageTexture:
	var image := Image.create(SCRAP_SIZE, SCRAP_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)


## The emitter is a [Node2D], so it does not follow Control anchors: keep it a
## page-wide strip just above the top edge.
func _layout_confetti() -> void:
	if not is_instance_valid(_confetti):
		return
	_confetti.position = Vector2(size.x * 0.5, -30.0)
	_confetti.emission_rect_extents = Vector2(maxf(size.x * 0.5, 1.0), 8.0)


func _pop_headline() -> void:
	_headline.pivot_offset = _headline.size * 0.5
	_headline.scale = Vector2(0.7, 0.7)
	_headline.modulate.a = 0.0
	var tween := create_tween().set_parallel(true)
	tween.tween_property(_headline, "scale", Vector2.ONE, POP_SECONDS) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(_headline, "modulate:a", 1.0, POP_SECONDS * 0.6)


func _on_again_pressed() -> void:
	again_requested.emit(_book)

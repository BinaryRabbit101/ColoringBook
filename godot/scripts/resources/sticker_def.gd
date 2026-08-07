class_name StickerDef
extends Resource
## One sticker: a stable id, a name, and the image that gets stuck on the page
## (BACKLOG BL-36).
##
## Pure data, exactly like [PageDef]: the path is stored as a string rather than
## as a preloaded [Texture2D], so a set can name a dozen stickers without dragging
## every image into memory when the [StickerSetDef] loads.
##
## [b][member sticker_id] is the load-bearing field.[/b] A placed sticker is saved
## as "set X, sticker Y, at this page position" (BL-36's additive save key), so an
## id that changes orphans every sticker a child has already stuck down. It is the
## same promise [member BookDef.book_uid] makes, one level smaller: author it once,
## never rename it.
##
## [b]A sticker can be built-in or come from a pack[/b], and the difference is one
## flag. A repo fixture names a [code]res://[/code] path and goes through the
## resource loader; a sticker from an installed DLC pack (BL-37) names an absolute
## [code]user://[/code] file, carries [member is_runtime] and is decoded with
## [method Image.load_from_file]. Both go through [method PageDef.load_texture],
## which is the one place that difference lives.

## Stable identity of this sticker WITHIN its set. Lower-case, hyphenated
## ([code]paw-print[/code]); unique per set; never reused for different art.
@export var sticker_id: String = ""

## What a grown-up would call it. Never shown to the player today -- the strip
## shows the art -- but it is what the authoring UI (BL-37) edits and what a
## tooltip reads.
@export var display_name: String = ""

## The sticker's PNG. Transparent outside the shape: a sticker is a cut-out laid
## over a drawing, not a tile.
@export_file("*.png") var image_path: String = ""

# --------------------------------------------------------------- pack stickers --
# Deliberately NOT exported, for the reason [PageDef] gives: an authored .tres must
# never be able to claim its art lives outside the build. Only
# [method StickerSetDef.from_json] sets this.

## True when [member image_path] is an absolute [code]user://[/code] file from an
## installed pack rather than a [code]res://[/code] resource.
var is_runtime: bool = false


## The sticker's texture, or null when the file is missing. Never cached here:
## the strip and the page layer each hold their own reference for as long as they
## need one, and a set that is only being enumerated costs nothing.
func load_texture() -> Texture2D:
	return PageDef.load_texture(image_path, is_runtime)


func exists() -> bool:
	return PageDef.file_exists(image_path, is_runtime)


## Human-readable problems with this sticker; empty means valid.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if sticker_id.strip_edges() == "":
		problems.append("sticker_id is empty")
	if image_path == "":
		problems.append("image_path is empty")
	elif not exists():
		problems.append("image_path '%s' does not exist" % image_path)
	return problems


func is_valid() -> bool:
	return validate().is_empty()

class_name AsyncReadback
extends RefCounted
## Non-blocking GPU -> CPU readback of a [Viewport]'s colour texture (M6).
##
## [b]Why this exists.[/b] [code]Viewport.get_texture().get_image()[/code] is
## synchronous: it flushes and waits. On this project's dev box that transfer is
## ~1.5 ms of real bandwidth for a 1024x1024 paint layer, but under the default
## FIFO v-sync the call additionally waits out the presentation queue, and the
## whole main thread stalls for [b]hundreds of milliseconds[/b] (M4/M5 measured
## ~350-530 ms). Coverage updates fire at every stroke end, so that stall was the
## single worst frame-time spike in the game. See [code]coloring_page.gd[/code].
##
## [b]How the async path works.[/b] Godot 4.4 added
## [method RenderingDevice.texture_get_data_async]. The chain is:
## [codeblock]
## viewport.get_texture().get_rid()                  # RenderingServer texture
##   -> RenderingServer.texture_get_rd_texture(rid)  # the RenderingDevice one
##   -> rd.texture_get_data_async(rd_rid, 0, cb)     # queued, returns at once
## [/codeblock]
## The request call returns in well under a millisecond; the driver copies the
## texture into a staging buffer as part of the frame it is submitted with, and
## the callback is invoked [b]on the main thread[/b] (verified on 4.5.1: the
## callback's [method OS.get_thread_caller_id] equals the caller's) about two
## frames later. Callers therefore need no thread guards -- only a
## "did the page change under me?" guard, because two frames is long enough for
## the world to move.
##
## [b]Availability.[/b] [method RenderingServer.get_rendering_device] is null on
## the Compatibility (OpenGL) renderer, so there is no RenderingDevice and no
## async path there. [method request] returns [code]false[/code] in that case
## [i]without[/i] invoking the callback, which is the signal for the caller to
## fall back to the synchronous readback. The project ships on the Mobile
## renderer (Vulkan) precisely so this path is available -- see DESIGN.md 3.5.
##
## [b]Shutting down is not optional[/b] -- see [method drain]. A queued readback
## whose callback has not fired yet is a GDScript [Callable] parked inside the
## RenderingDevice, and tearing the engine down on top of one is a hard crash
## (reproduced on 4.5.1: signal 11 during shutdown, every time, on any renderer).
## Anything that ends the process must drain first.
##
## [b]Not a node[/b] (godot-practices: "not everything is a node"): pure static
## logic over an injected [Viewport].

## The only texture layout this helper decodes. A Godot 2D viewport render target
## is [code]R8G8B8A8_UNORM[/code], which maps 1:1 onto [constant Image.FORMAT_RGBA8]
## -- verified byte-identical against [method Viewport.get_texture]'s image. Any
## other format (an HDR 2D viewport, a future engine change) makes [method request]
## decline rather than hand back mis-decoded pixels.
const SUPPORTED_FORMAT := RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM

## Frames [method drain] will wait. The driver delivers in ~2; this is a ceiling,
## not an expectation, so a lost callback delays a quit by a fraction of a second
## instead of hanging it.
const MAX_DRAIN_FRAMES := 30

## Readbacks queued but not yet delivered, across the whole process. Static
## because the hazard is process-wide: it is the ENGINE that must not be torn
## down while any of them is outstanding, no matter who asked for it.
static var _pending := 0


## True when this build/renderer can do async readbacks at all.
static func is_available() -> bool:
	return RenderingServer.get_rendering_device() != null


## How many readbacks are queued but not yet delivered.
static func pending_count() -> int:
	return _pending


## Waits until every queued readback has been delivered, or [param max_frames]
## have passed. Returns true when the queue really emptied.
##
## [b]Call this before quitting.[/b] The engine destroys the RenderingDevice and
## the GDScript runtime during shutdown; a transfer still holding a script
## [Callable] at that moment segfaults. Two frames of waiting is the whole cost.
static func drain(tree: SceneTree, max_frames: int = MAX_DRAIN_FRAMES) -> bool:
	if tree == null:
		return _pending == 0
	var frames := 0
	while _pending > 0 and frames < max_frames:
		frames += 1
		await tree.process_frame
	if _pending > 0:
		push_warning(
			"AsyncReadback: %d readback(s) still pending after %d frames; quitting anyway."
			% [_pending, max_frames]
		)
	return _pending == 0


## Queues a readback of [param viewport]'s colour texture.
##
## Returns [code]true[/code] when the request was queued -- [param callback] will
## then be called exactly once, on the main thread, with an [Image] (or
## [code]null[/code] if the transfer came back short). Returns [code]false[/code]
## when the async path is unavailable or the texture is not a supported format,
## and in that case the callback is [b]never[/b] called, so the caller must do the
## synchronous readback itself.
##
## The caller owns liveness: by the time the callback runs, the page (or the whole
## screen) may be gone. A [Callable] bound to a freed object reports
## [method Callable.is_valid] false and is skipped, but a caller that keeps living
## still has to check that the data is not stale.
static func request(viewport: Viewport, callback: Callable) -> bool:
	if viewport == null or not callback.is_valid():
		return false
	var device := RenderingServer.get_rendering_device()
	if device == null:
		return false
	var texture := viewport.get_texture()
	if texture == null:
		return false
	var device_texture := RenderingServer.texture_get_rd_texture(texture.get_rid())
	if not device_texture.is_valid():
		return false

	var format := device.texture_get_format(device_texture)
	if format == null or format.format != SUPPORTED_FORMAT:
		return false
	var width := int(format.width)
	var height := int(format.height)
	if width <= 0 or height <= 0:
		return false
	var expected := width * height * 4

	# Counted BEFORE the call, and decremented in every path out of the callback,
	# so pending_count() is never optimistic (see drain()).
	_pending += 1
	var error := device.texture_get_data_async(
		device_texture, 0, func(bytes: PackedByteArray) -> void:
			_pending -= 1
			if not callback.is_valid():
				return
			if bytes.size() < expected:
				push_warning(
					"AsyncReadback: got %d bytes for a %dx%d RGBA8 texture (wanted %d)."
					% [bytes.size(), width, height, expected]
				)
				callback.call(null)
				return
			callback.call(Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, bytes))
	)
	if error != OK:
		# The callback will never run, so nothing would ever undo the increment.
		_pending -= 1
		return false
	return true

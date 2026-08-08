class_name Main
extends Control
## The application entry point (DESIGN.md 3.4: "main.tscn -- entry point: swaps
## screens"). Set as [code]run/main_scene[/code] in project.godot.
##
## [b]This is the only node in the game that knows the flow exists.[/b] Every
## screen is self-contained and reports upward; this script listens, decides, and
## swaps. Nothing ever reaches sideways:
##
## [codeblock]
## TitleScreen.start_requested   -> BookSelect
## BookSelect.book_chosen        -> ColoringPage.load_book(book, resume_index)
## ColoringPage.back_requested   -> BookSelect
## [/codeblock]
##
## [b]BL-20 removed the mode-select screen[/b] along with the Child/Adult split:
## the title now goes straight to the shelf, and there is one palette for everyone
## (DESIGN.md 1).
##
## [b]BL-27 removed the tap on the splash[/b]: [TitleScreen] plays its opening beat
## and emits [signal TitleScreen.start_requested] by itself. Nothing changed here --
## main was never waiting for a tap, it was waiting for the signal.
##
## [b]BL-30 gave the swap layer a second way to dress a swap[/b]. Every screen
## change is still cover / swap / uncover; [enum Transition] only picks what does
## the covering, and [BookOpenTransition] is the one that makes the shelf -> page
## step feel like opening a book instead of a cut. That transition belongs HERE and
## nowhere else: the shelf must not know what is behind a book and the page must not
## know where it was opened from.
##
## [b]There is no completion screen[/b] (BL-11, DESIGN.md 2). Finishing a page --
## including the last one -- is celebrated on the coloring page itself and takes
## the player nowhere; [signal ColoringPage.back_requested] is the only exit from
## a book, so the flow above is the whole flow.
##
## [b]Overlays[/b] are main's too, and they are the reason [BookSelect] could stay
## frozen: the settings gear is not inside the shelf scene, it is an overlay this
## node shows while the shelf is the current screen. The settings panel is an
## overlay for the same reason.
##
## [b]WP10 added three more overlays and one more shelf button[/b], on exactly that
## pattern, so [code]book_select.tscn[/code] is STILL frozen:
## [codeblock]
## Settings -> "Account" -> AdultGate -> AccountPanel   sign in / register / out
## shelf    -> "More books"           -> PackShop       the DLC catalogue
## [/codeblock]
## The "More books" button appears while the shelf is up and this build has a
## server (BL-25 -- see [method _refresh_more_books] for why it no longer waits for
## a sign-in); the gate stands in front of every account screen (DLC_SERVER.md 4.1).
## [b]No kid-facing screen shows network state at all[/b] (DLC_SERVER.md 8.2) --
## the shelf is built from local discovery every time and merely re-filtered when
## an entitlement answer lands.
##
## [b]Save points[/b]: leaving a book, finishing a page and the BL-6 interval
## autosave are handled inside [ColoringPage] (only it can reach the paint layer).
## Quitting, backgrounding and losing focus are handled here, because those
## notifications have to flush the OPEN page's pixels before
## [code]GameState[/code] writes the JSON.
##
## [b]M6: main owns the quit.[/b] It turns off
## [member SceneTree.auto_accept_quit] and calls [method SceneTree.quit] itself,
## because two things have to happen between "the player closed the window" and
## "the process ends", and the engine's automatic quit leaves no frames for
## either:
##
## 1. the open page's paint layer is flushed with the BLOCKING readback -- there
##    is no next frame to deliver an async one to, and a stall on a frame nobody
##    will see is a better trade than losing the page (see
##    [method ColoringPage.persist_current_page]);
## 2. any readback that was already in flight is DRAINED
##    ([method AsyncReadback.drain]). Tearing the engine down on top of a queued
##    [method RenderingDevice.texture_get_data_async] is a hard crash, reproduced
##    on 4.5.1 on every renderer.
##
## [member quit_on_close_request] is the dev-harness hook: with it false the flush
## and the drain still run, but the process survives, which is how the shell smoke
## can deliver a close request without ending its own run.
##
## [b]M6 also owns the safe area[/b]: both [code]ScreenHost[/code] and
## [code]Overlays[/code] live inside one [SafeArea], so every screen and every
## overlay is notch-clear without a single screen knowing about [DisplayServer].
##
## [b]BL-48 sized the overlay layer for a phone.[/b] The gameplay layer had its
## mobile pass in M6/BL-21/BL-33; the overlays kept their desktop numbers, which on
## a ~390 pt phone is a third of their authored size. Every overlay now takes one
## shared scale from [OverlayMetrics] -- including the two buttons built HERE, which
## are the first thing a grown-up has to hit (see [method _apply_overlay_scale]).

## The visible screen changed. Payload is one of the SCREEN_* ids.
signal screen_changed(screen_id: String)
## The settings overlay opened (true) or closed (false).
signal settings_toggled(is_open: bool)

const SCREEN_TITLE := "title"
const SCREEN_BOOK_SELECT := "book_select"
const SCREEN_COLORING := "coloring"

const TITLE_SCENE: PackedScene = preload("res://scenes/screens/title_screen.tscn")
const BOOK_SELECT_SCENE: PackedScene = preload("res://scenes/screens/book_select.tscn")
const COLORING_PAGE_SCENE: PackedScene = preload("res://scenes/screens/coloring_page.tscn")
const SETTINGS_PANEL_SCENE: PackedScene = preload("res://scenes/components/settings_panel.tscn")
## WP10 overlays. All three are grown-up territory and all three live here for the
## same reason the gear does -- see the class doc's "Overlays" note.
const ADULT_GATE_SCENE: PackedScene = preload("res://scenes/components/adult_gate.tscn")
const ACCOUNT_PANEL_SCENE: PackedScene = preload("res://scenes/components/account_panel.tscn")
const PACK_SHOP_SCENE: PackedScene = preload("res://scenes/components/pack_shop.tscn")

## Screen transition: fade the old screen out, swap, fade the new one in. Short
## on purpose -- long enough to hide the swap, short enough that a child tapping
## through the shelf never waits for it.
const FADE_OUT_SECONDS := 0.12
const FADE_IN_SECONDS := 0.13

## How a screen swap is dressed. Every swap is the same three steps -- cover, swap,
## uncover -- and this only picks what does the covering (see [method _cover_screen]).
enum Transition {
	## The default: a short dip through black.
	FADE,
	## BL-30: a book leaps off the shelf, fills the screen and its cover swings open
	## on the page.
	BOOK_OPEN,
	## The same in reverse, for leaving a book: the cover swings shut over the page
	## and the book drops back onto the shelf.
	BOOK_CLOSE,
}

## BL-30 timings. The whole opening runs in a bit over half a second: long enough
## to read as a book being opened, short enough that a child who wants to colour is
## not being shown an animation.
const BOOK_COVER_SECONDS := 0.24
const BOOK_OPEN_SECONDS := 0.34
## Shutting is quicker than opening -- going back is not the moment worth savouring.
const BOOK_SHUT_SECONDS := 0.22
const BOOK_RETURN_SECONDS := 0.24

## The shelf's "More books" pill, as authored. BL-48 multiplies all three by the
## overlay scale, which is 1.0 on a desktop -- so these ARE the desktop numbers.
const MORE_BOOKS_SIZE := Vector2(190.0, 72.0)
const MORE_BOOKS_FONT_SIZE := 22
## Distance from the corner for both shell buttons.
const MORE_BOOKS_INSET := 20.0


## The settings gear, drawn from primitives so the shell ships no icon assets.
## Sits on a dark disc so it reads over both the shelf and a white page.
class GearButton extends Button:
	const TEETH := 8
	## M6 mobile pass: 72 px square, comfortably past the 48 px touch floor
	## (DESIGN.md 3.5) and past the 64 px the child-mode controls use.
	const SIZE := Vector2(72.0, 72.0)

	func _init() -> void:
		custom_minimum_size = SIZE
		focus_mode = Control.FOCUS_NONE
		mouse_filter = Control.MOUSE_FILTER_STOP
		tooltip_text = "Settings"
		flat = true
		for state in ["normal", "hover", "pressed", "focus", "disabled"]:
			add_theme_stylebox_override(state, StyleBoxEmpty.new())

	func _ready() -> void:
		mouse_entered.connect(queue_redraw)
		mouse_exited.connect(queue_redraw)
		button_down.connect(queue_redraw)
		button_up.connect(queue_redraw)

	func _draw() -> void:
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.5
		var tint := Color(0.972549, 0.803922, 0.478431) if is_hovered() \
			else Color(0.827451, 0.788235, 0.717647)
		draw_circle(center, radius, Color(0.156863, 0.141176, 0.129412, 0.92))
		draw_arc(center, radius - 1.5, 0.0, TAU, 48, Color(0.415686, 0.360784, 0.301961), 2.0)

		var body := radius * 0.46
		var tooth_length := radius * 0.24
		var tooth_width := radius * 0.22
		for i in TEETH:
			var angle := TAU * float(i) / float(TEETH)
			var out := Vector2.RIGHT.rotated(angle)
			var side := out.orthogonal() * (tooth_width * 0.5)
			draw_colored_polygon(
				PackedVector2Array([
					center + out * body + side,
					center + out * (body + tooth_length) + side * 0.7,
					center + out * (body + tooth_length) - side * 0.7,
					center + out * body - side,
				]),
				tint
			)
		draw_circle(center, body, tint)
		draw_circle(center, body * 0.42, Color(0.156863, 0.141176, 0.129412))


## The book that opens between the shelf and the page (BL-30).
##
## [b]It lives here, in the swap layer[/b], and not in either screen: the shelf
## must not know what is behind a book and the coloring page must not know what it
## was reached from -- that is the whole reason main exists. It is also why the
## book is a GENERIC book rather than the cover of the one that was tapped: this
## node is handed a [BookDef] and a [PackedScene], never a cell's rectangle.
##
## [b]Drawn from primitives[/b], like [GearButton] and everything else in the
## shell, so the transition ships no art. Two numbers describe the whole thing:
##
## [codeblock]
## closed_amount  0 a small book at the centre of the screen .. 1 it fills the screen
## opened_amount  0 the cover is shut ................ 1 it has swung right open
## [/codeblock]
##
## The two phases hand over SEAMLESSLY at [code]closed_amount == 1[/code] /
## [code]opened_amount == 0[/code]: both draw the same full-screen flat cover, which
## is what lets the screen swap happen invisibly in between them.
class BookOpenTransition extends Control:
	## A warm crayon-box red, in the family the shell already uses.
	const COVER := Color(0.647059, 0.286275, 0.239216)
	const SPINE := Color(0.478431, 0.196078, 0.164706)
	const COVER_EDGE := Color(0.352941, 0.145098, 0.117647)
	## The same paper as the title screen's sheet.
	const PAGE := Color(0.988235, 0.976471, 0.956863)
	## Roughly the size a book takes up on the shelf, so it reads as one leaping out.
	const START_SCALE := 0.22
	const CORNER_RADIUS := 26
	const SHADOW_SIZE := 30
	## How deeply the cover's free edge pinches vertically as it swings, which is
	## what sells the rotation without any 3D.
	const SWING_PINCH := 0.10
	## How far across the uncovered page the standing cover throws its shadow.
	const SWING_SHADOW := 0.14
	## Strokes in the doodle on the cover.
	const DOODLE_LANES := 3
	const DOODLE_STEPS := 12

	var closed_amount := 0.0
	var opened_amount := 0.0

	var _cover_style := StyleBoxFlat.new()
	var _page_style := StyleBoxFlat.new()
	var _doodle_colors := PackedColorArray()
	## The artist's cover of the book being opened, or null (BL-42). When there is
	## one it is PRINTED ON the cover -- both phases -- and the crayon doodle stands
	## down, because a doodle over somebody's artwork is vandalism.
	var _cover_art: Texture2D = null

	func _init() -> void:
		visible = false
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_cover_style.bg_color = COVER
		_cover_style.border_color = COVER_EDGE
		_cover_style.set_border_width_all(3)
		_cover_style.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
		_cover_style.shadow_offset = Vector2(0.0, 10.0)
		_page_style.bg_color = PAGE

	## The crayon scribble on the cover takes its colours from the live palette, the
	## same way the title screen's lettering does. Injected rather than read off the
	## autoload so the class stays a plain drawing.
	func set_doodle_colors(colors: PackedColorArray) -> void:
		_doodle_colors = colors
		queue_redraw()

	## The cover art of the book about to open (BL-42), or null for the generic
	## crayon-doodle cover. Injected per transition -- this class is still handed a
	## picture rather than a shelf cell, so it stays coupled to nothing.
	func set_cover_art(texture: Texture2D) -> void:
		_cover_art = texture
		queue_redraw()

	func has_cover_art() -> bool:
		return _cover_art != null

	func begin(closed: float, opened: float) -> void:
		closed_amount = closed
		opened_amount = opened
		modulate.a = 1.0
		visible = true
		mouse_filter = Control.MOUSE_FILTER_STOP
		queue_redraw()

	func finish() -> void:
		visible = false
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		modulate.a = 1.0
		closed_amount = 0.0
		opened_amount = 0.0

	func set_closed(value: float) -> void:
		closed_amount = value
		queue_redraw()

	func set_opened(value: float) -> void:
		opened_amount = value
		queue_redraw()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		if size.x <= 4.0 or size.y <= 4.0:
			return
		if opened_amount <= 0.0:
			_draw_shut_book()
		else:
			_draw_swinging_cover()

	## Phase 1: a shut book, somewhere between shelf-sized and screen-sized.
	func _draw_shut_book() -> void:
		var box := size * lerpf(START_SCALE, 1.0, closed_amount)
		var rect := Rect2(((size - box) * 0.5).floor(), box)
		# Everything that makes it read as an OBJECT -- rounded corners, its shadow,
		# the page edges down its open side -- is gone by the time it fills the
		# screen, which is what makes the hand-off to phase 2 invisible.
		var object_ness := clampf(1.0 - closed_amount, 0.0, 1.0)
		var lip := maxf(box.x * 0.025, 2.0) * object_ness
		_page_style.set_corner_radius_all(int(CORNER_RADIUS * object_ness * 0.5))
		_page_style.draw(
			get_canvas_item(),
			Rect2(rect.position + Vector2(lip, lip), rect.size - Vector2(0.0, lip * 2.0))
		)
		_cover_style.set_corner_radius_all(int(CORNER_RADIUS * object_ness))
		_cover_style.shadow_size = int(SHADOW_SIZE * object_ness)
		_cover_style.draw(get_canvas_item(), rect)
		_draw_cover_art(rect, 1.0)
		_draw_spine(rect.position.x, rect.size.y * 0.5 + rect.position.y, rect.size,
			CORNER_RADIUS * object_ness, SPINE)
		_draw_doodle(rect.position, rect.size.x, 0.0, rect.size.y, 1.0)

	## Phase 2: the cover swings away to the left on its spine, uncovering a white
	## page spread that then fades into the real screen behind this overlay.
	func _draw_swinging_cover() -> void:
		var o := clampf(opened_amount, 0.0, 1.0)
		draw_rect(
			Rect2(Vector2.ZERO, size),
			Color(PAGE.r, PAGE.g, PAGE.b, 1.0 - smoothstep(0.55, 1.0, o))
		)
		var edge_x := size.x * (1.0 - o)
		if edge_x <= 1.0:
			return
		var pinch := size.y * SWING_PINCH * sin(PI * o)
		# The shadow the standing cover throws across what it has uncovered.
		var reach := minf(size.x * SWING_SHADOW, size.x - edge_x)
		if reach > 1.0:
			var dark := Color(0.117647, 0.086275, 0.070588, 0.38 * sin(PI * o))
			var clear := Color(dark.r, dark.g, dark.b, 0.0)
			draw_polygon(
				PackedVector2Array([
					Vector2(edge_x, 0.0),
					Vector2(edge_x + reach, 0.0),
					Vector2(edge_x + reach, size.y),
					Vector2(edge_x, size.y),
				]),
				PackedColorArray([dark, clear, clear, dark])
			)
		# Lit across its face as it turns: both tints are zero at o == 0, so the
		# first frame of the swing is pixel-identical to the last frame of phase 1.
		var turn := smoothstep(0.0, 0.25, o)
		var hinge_side := COVER.darkened(0.30 * turn + 0.35 * o)
		var free_side := COVER.lightened(0.12 * turn)
		draw_polygon(
			PackedVector2Array([
				Vector2(0.0, 0.0),
				Vector2(edge_x, pinch),
				Vector2(edge_x, size.y - pinch),
				Vector2(0.0, size.y),
			]),
			PackedColorArray([hinge_side, free_side, free_side, hinge_side])
		)
		# The artwork rides the same box the doodle does -- inside the pinch, so it
		# cannot poke out of the turning cover's silhouette, and squashed with it, so
		# it bends as the cover bends. At o == 0 the pinch is zero and the box is the
		# whole screen, which is what keeps the hand-off from phase 1 pixel-exact.
		_draw_cover_art(
			Rect2(0.0, pinch, edge_x, size.y - pinch * 2.0), 1.0 - 0.35 * o
		)
		draw_line(
			Vector2(edge_x, pinch), Vector2(edge_x, size.y - pinch), COVER_EDGE, 4.0, true
		)
		_draw_spine(0.0, size.y * 0.5, Vector2(edge_x, size.y), 0.0, SPINE.darkened(0.25 * o))
		_draw_doodle(Vector2.ZERO, edge_x, pinch, size.y - pinch, 1.0 - turn)

	## The dark strip down the bound edge. Inset by the corner radius so it cannot
	## poke out of the cover's rounded corners while the book is still small.
	func _draw_spine(
		left: float, middle_y: float, box: Vector2, corner: float, tint: Color
	) -> void:
		var width := maxf(box.x * 0.055, 3.0)
		var height := maxf(box.y - corner * 2.0, 0.0)
		if width <= 0.0 or height <= 0.0:
			return
		draw_rect(Rect2(Vector2(left, middle_y - height * 0.5), Vector2(width, height)), tint)

	## The book's own cover art across [param box] (BL-42), centre-cropped to fill it
	## the way the shelf cell fills a book's front. [param shade] darkens it as the
	## cover turns away from the light, which is the same job the vertex tints do for
	## the plain cover.
	func _draw_cover_art(box: Rect2, shade: float) -> void:
		if _cover_art == null or box.size.x <= 2.0 or box.size.y <= 2.0:
			return
		var source := Vector2(_cover_art.get_size())
		if source.x <= 0.0 or source.y <= 0.0:
			return
		# Centre crop: the cover of a book is a shape the artwork has to fill, and
		# letterboxing it would show the flat cover colour in two bands.
		var scale_factor := maxf(box.size.x / source.x, box.size.y / source.y)
		var used := Vector2(box.size.x / scale_factor, box.size.y / scale_factor)
		draw_texture_rect_region(
			_cover_art,
			box,
			Rect2((source - used) * 0.5, used),
			Color(shade, shade, shade, 1.0)
		)

	## Three wax strokes across the cover, in palette colours -- the same crayon
	## language as the title screen's underline, so the book looks like one of ours.
	## Mapped through the caller's box, which is how it swings with the cover.
	##
	## [b]A book with its own cover gets no doodle[/b] (BL-42): the scribble exists
	## to stop a generic cover being a blank slab, and drawing it over an artist's
	## painting would be vandalism.
	func _draw_doodle(
		origin: Vector2, span_x: float, top: float, bottom: float, alpha: float
	) -> void:
		if _cover_art != null:
			return
		if _doodle_colors.is_empty() or alpha <= 0.01 or span_x <= 8.0 or bottom - top <= 8.0:
			return
		var thickness := maxf((bottom - top) * 0.014, 2.0)
		for lane in DOODLE_LANES:
			var points := PackedVector2Array()
			for i in DOODLE_STEPS + 1:
				var u := lerpf(0.22, 0.84, float(i) / float(DOODLE_STEPS))
				var v := 0.34 + float(lane) * 0.15 \
					+ sin(float(i) * 0.9 + float(lane) * 1.7) * 0.03
				points.append(origin + Vector2(u * span_x, lerpf(top, bottom, v)))
			var tint: Color = _doodle_colors[lane % _doodle_colors.size()]
			draw_polyline(points, Color(tint.r, tint.g, tint.b, alpha), thickness, true)


@onready var _safe_area: SafeArea = $SafeArea
@onready var _host: Control = $SafeArea/ScreenHost
@onready var _overlays: Control = $SafeArea/Overlays
@onready var _fade: ColorRect = $Fade

## Whether a close request really ends the process. Dev harnesses set it false so
## they can exercise the quit save path without killing their own run; when it is
## false the engine's own automatic quit is handed back, so the window's close
## button still works during a `--stay` session.
var quit_on_close_request := true:
	set(value):
		quit_on_close_request = value
		if is_inside_tree():
			get_tree().auto_accept_quit = not value

var _gear: GearButton
## BL-48: the pill's rounding has to grow with the pill, or a 187 px tall button
## with a 36 px radius stops being a pill. Kept so it can be re-rounded on a resize.
var _more_books_style: StyleBoxFlat
## BL-30: the book that opens between the shelf and the page. Built here, on top of
## [member _fade], because a transition has to cover the overlays too.
var _book_transition: BookOpenTransition
## WP10: the shelf's DLC entry point. An overlay button, not part of the shelf
## scene, and visible only when the shelf is up AND somebody is signed in.
var _more_books: Button
var _current_screen: Control
var _current_id := ""
var _settings: SettingsPanel
var _adult_gate: AdultGate
var _account_panel: AccountPanel
var _pack_shop: PackShop
var _transitioning := false
## Guards against a second close request arriving while the first is draining.
var _closing := false


func _ready() -> void:
	# Main quits the game itself, so it can flush and drain first (class doc).
	get_tree().auto_accept_quit = not quit_on_close_request
	_build_gear()
	_build_more_books()
	_build_book_transition()
	# BL-48: the two shell buttons are part of the overlay layer and take the same
	# one scale the panels do. They are built in code rather than in a scene, so they
	# are sized here rather than by an OverlayMetrics walk.
	_overlays.resized.connect(_apply_overlay_scale)
	get_viewport().size_changed.connect(_apply_overlay_scale)
	_apply_overlay_scale()
	# The shelf re-filters and rescans when the account or the installed packs
	# change. Nothing here awaits anything (DLC_SERVER.md 8.2) -- these are
	# notifications that arrive, not requests this node makes.
	Backend.auth_changed.connect(_on_backend_auth_changed)
	Backend.entitlements_changed.connect(_on_backend_shelf_changed)
	Backend.installed_packs_changed.connect(_on_backend_shelf_changed)
	# Start under the fade so the first screen arrives the same way every other
	# screen does, instead of popping in.
	_fade.visible = true
	_fade.modulate.a = 1.0
	await show_title()


## Quitting and backgrounding are save points (the others live in [ColoringPage]).
## The open page's paint layer is flushed FIRST, because only the screen can read
## it back; then GameState writes the progress JSON.
##
## A close request additionally drains any in-flight GPU readback and then quits
## (see the class doc). Backgrounding does neither -- the app is expected to come
## back.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		# Backgrounded on mobile: the OS may never give this process another frame,
		# so the blocking flush is the only safe one.
		flush_and_save()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		# BL-6: alt-tabbed, or the browser tab lost focus. The app is still running
		# and still has frames, so this takes the ASYNC path -- and the same
		# "never mid-stroke" rule as every other autosave.
		_autosave_now()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		_close()


## Non-blocking save of whatever the player would lose right now (BL-6). Used by
## the moments where the app keeps running; [method flush_and_save] is for the
## moments where it does not.
func _autosave_now() -> void:
	if _current_screen is ColoringPage:
		await (_current_screen as ColoringPage).save_page_now(false)
	GameState.save_now()


## Writes everything the player would lose right now. Safe to call at any time.
## Synchronous on purpose: its callers are the moments where there is no next
## frame to hand an async readback to.
func flush_and_save() -> void:
	if _current_screen is ColoringPage:
		(_current_screen as ColoringPage).persist_current_page()
	GameState.save_now()


## The full shutdown sequence: save, drain, quit. Idempotent.
func _close() -> void:
	if _closing:
		return
	_closing = true
	flush_and_save()
	await AsyncReadback.drain(get_tree())
	if quit_on_close_request:
		get_tree().quit()
	else:
		_closing = false


# ================================================================ the flow ==

func show_title() -> Control:
	return await _show_screen(TITLE_SCENE, SCREEN_TITLE)


## [param transition] is how the swap is dressed; leaving a book passes
## [constant Transition.BOOK_CLOSE] so the shelf is reached the same way it was
## left (BL-30).
func show_book_select(transition: Transition = Transition.FADE) -> Control:
	# BL-42: the cover that shuts is the one that opened, so it is read BEFORE the
	# book cursor is cleared. A fade needs none, and clearing it is what stops a
	# stale cover riding the next generic transition.
	_book_transition.set_cover_art(
		GameState.current_book.get_artist_cover_texture()
		if transition == Transition.BOOK_CLOSE and GameState.current_book != null
		else null
	)
	GameState.clear_book()
	return await _show_screen(BOOK_SELECT_SCENE, SCREEN_BOOK_SELECT, transition,
		func(screen: Control) -> void:
			_populate_shelf(screen as BookSelect)
	)


## Fills the shelf: discover everything installed, then drop the DLC books this
## account may not see (WP10). [method Backend.discover_visible_books] is a purely
## LOCAL call -- filesystem plus the cached entitlement list -- so the shelf never
## waits for a server and never empties itself when there isn't one
## (DLC_SERVER.md 8.2, 9). With no account it returns exactly what
## [method BookDef.discover] returns.
func _populate_shelf(shelf: BookSelect) -> int:
	if shelf == null:
		return 0
	return shelf.set_books(Backend.discover_visible_books())


## Opens [param book] at its saved page with its saved paint. A finished book
## opens at page 1 -- completing a book is never a lockout (see
## [method GameState.get_resume_index]).
func open_book(book: BookDef) -> Control:
	if book == null:
		return null
	var start_index := GameState.get_resume_index(book)
	# BL-42: the book that flies at the screen wears this book's own cover when the
	# pack shipped one. Still a picture handed over, never a shelf cell -- the
	# transition stays coupled to nothing.
	_book_transition.set_cover_art(book.get_artist_cover_texture())
	# BL-30: tapping a book on the shelf now OPENS it rather than cutting to it.
	return await _show_screen(COLORING_PAGE_SCENE, SCREEN_COLORING, Transition.BOOK_OPEN,
		func(screen: Control) -> void:
			(screen as ColoringPage).load_book(book, start_index)
	)


# --------------------------------------------------------------- screen swap --

## Covers the screen, frees the old one, instantiates and wires the new one, runs
## [param setup] on it, then uncovers. [param setup] runs BEHIND the cover, so a
## page loads out of sight rather than in front of the player.
##
## [param transition] only chooses what does the covering (BL-30): the three steps,
## the transition guard and the overlay bookkeeping are the same whichever it is.
func _show_screen(
	scene: PackedScene,
	id: String,
	transition: Transition = Transition.FADE,
	setup: Callable = Callable()
) -> Control:
	if _transitioning:
		push_warning("Main: ignoring a request for '%s' during a transition." % id)
		return null
	_transitioning = true
	_close_overlays()
	_gear.visible = false
	_more_books.visible = false
	await _cover_screen(transition)

	for child in _host.get_children():
		_host.remove_child(child)
		child.queue_free()

	var screen := scene.instantiate() as Control
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_host.add_child(screen)
	_current_screen = screen
	_current_id = id
	_connect_screen(screen, id)
	if setup.is_valid():
		setup.call(screen)

	await get_tree().process_frame
	await _uncover_screen(transition)
	# The gear is an OVERLAY on the shelf, which is how book_select.tscn stayed
	# frozen while still growing a settings entry point.
	_gear.visible = id == SCREEN_BOOK_SELECT
	_transitioning = false
	# After the flag drops: _refresh_more_books() refuses to show anything mid-swap,
	# which is what keeps a sign-in landing during a transition from painting a
	# button onto the wrong screen.
	_refresh_more_books()
	screen_changed.emit(id)
	return screen


func _connect_screen(screen: Control, id: String) -> void:
	match id:
		SCREEN_TITLE:
			(screen as TitleScreen).start_requested.connect(_on_title_start)
		SCREEN_BOOK_SELECT:
			(screen as BookSelect).book_chosen.connect(_on_book_chosen)
		SCREEN_COLORING:
			(screen as ColoringPage).back_requested.connect(_on_coloring_back)


func _fade_to(target_alpha: float, seconds: float) -> void:
	_fade.visible = true
	# Swallow taps mid-transition, so a fast double-tap cannot start two swaps.
	_fade.mouse_filter = Control.MOUSE_FILTER_STOP
	var tween := create_tween()
	tween.tween_property(_fade, "modulate:a", target_alpha, seconds)
	await tween.finished
	if target_alpha <= 0.0:
		_fade.visible = false
		_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE


# ------------------------------------------------------------ BL-30: the book --

func _build_book_transition() -> void:
	_book_transition = BookOpenTransition.new()
	_book_transition.name = "BookTransition"
	add_child(_book_transition)
	_book_transition.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var palette := GameState.get_active_palette()
	if palette != null:
		var colors := PackedColorArray()
		# Spread across the box rather than the first three, so the cover doodle is
		# three DIFFERENT crayons.
		for lane in BookOpenTransition.DOODLE_LANES:
			colors.append(palette.get_color((lane * 3 + 1) % maxi(palette.color_count(), 1)))
		_book_transition.set_doodle_colors(colors)


## Hides the outgoing screen the way [param transition] asks for.
func _cover_screen(transition: Transition) -> void:
	match transition:
		Transition.BOOK_OPEN:
			await _book_leaps_out()
		Transition.BOOK_CLOSE:
			await _book_shuts()
		_:
			await _fade_to(1.0, FADE_OUT_SECONDS)


## Reveals the incoming screen, undoing whatever [method _cover_screen] did.
func _uncover_screen(transition: Transition) -> void:
	match transition:
		Transition.BOOK_OPEN:
			await _book_cover_opens()
		Transition.BOOK_CLOSE:
			await _book_goes_back_on_the_shelf()
		_:
			await _fade_to(0.0, FADE_IN_SECONDS)


## A book the size of a shelf cell gathers itself and flies at the screen.
## TRANS_BACK/EASE_IN is the anticipation: it dips smaller before it leaps.
func _book_leaps_out() -> void:
	_book_transition.begin(0.0, 0.0)
	var tween := create_tween()
	tween.tween_method(_book_transition.set_closed, 0.0, 1.0, BOOK_COVER_SECONDS) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	await tween.finished


## ...and its cover swings open on the page that loaded behind it.
func _book_cover_opens() -> void:
	var tween := create_tween()
	tween.tween_method(_book_transition.set_opened, 0.0, 1.0, BOOK_OPEN_SECONDS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	await tween.finished
	_book_transition.finish()


## Leaving a book: the cover swings back over the page.
func _book_shuts() -> void:
	_book_transition.begin(1.0, 1.0)
	var tween := create_tween()
	tween.tween_method(_book_transition.set_opened, 1.0, 0.0, BOOK_SHUT_SECONDS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	await tween.finished


## ...and the shut book drops away to the middle of the shelf. It fades out over
## the tail of the shrink, because a book that reached shelf size and then vanished
## would pop -- and this node has no idea which cell it belongs on.
func _book_goes_back_on_the_shelf() -> void:
	var tween := create_tween()
	tween.tween_method(_book_transition.set_closed, 1.0, 0.0, BOOK_RETURN_SECONDS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(
		_book_transition, "modulate:a", 0.0, BOOK_RETURN_SECONDS * 0.65
	).set_delay(BOOK_RETURN_SECONDS * 0.35)
	await tween.finished
	_book_transition.finish()


# =============================================================== screen hooks ==

## BL-20: the title goes straight to the shelf. There is nothing to choose first.
func _on_title_start() -> void:
	await show_book_select()


func _on_book_chosen(book: BookDef) -> void:
	await open_book(book)


## The page already flushed its paint in [method ColoringPage._on_back_pressed];
## all that is left is the screen swap -- shutting the book the player opened.
func _on_coloring_back() -> void:
	await show_book_select(Transition.BOOK_CLOSE)


# ================================================================== overlays ==

func _build_gear() -> void:
	_gear = GearButton.new()
	_gear.name = "GearButton"
	_gear.visible = false
	_gear.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_gear.offset_left = -(GearButton.SIZE.x + 20.0)
	_gear.offset_top = 20.0
	_gear.offset_right = -20.0
	_gear.offset_bottom = 20.0 + GearButton.SIZE.y
	_gear.pressed.connect(open_settings)
	_overlays.add_child(_gear)


## BL-48. The gear and "More books" are the overlay layer's two BUTTONS, and they
## were the two controls a grown-up had to hit before any of the panels could even
## be seen: 72 canvas px is 24 pt of glass on a ~390 pt phone, half a finger.
##
## Everything here is authored-value times [method OverlayMetrics.content_scale],
## which is exactly 1.0 on a desktop -- so this recomputes the numbers the scene
## already had and nothing moves. The floor is applied on top, because a finger does
## not care what the type is doing (see [OverlayMetrics.min_touch_px]).
func _apply_overlay_scale() -> void:
	if not is_instance_valid(_gear) or not is_instance_valid(_more_books):
		return
	var scale := OverlayMetrics.content_scale(get_viewport())
	var floor_px := OverlayMetrics.min_touch_px(get_viewport())
	var pad := MORE_BOOKS_INSET * scale

	var gear := maxf(GearButton.SIZE.x * scale, floor_px)
	_gear.custom_minimum_size = Vector2(gear, gear)
	_gear.offset_left = -(gear + pad)
	_gear.offset_top = pad
	_gear.offset_right = -pad
	_gear.offset_bottom = pad + gear

	var height := maxf(MORE_BOOKS_SIZE.y * scale, floor_px)
	var width := maxf(MORE_BOOKS_SIZE.x * scale, floor_px)
	_more_books.custom_minimum_size = Vector2(width, height)
	_more_books.add_theme_font_size_override(
		"font_size", int(round(MORE_BOOKS_FONT_SIZE * scale))
	)
	if _more_books_style != null:
		_more_books_style.set_corner_radius_all(int(round(height * 0.5)))
	_more_books.offset_left = pad
	_more_books.offset_top = pad
	_more_books.offset_right = pad + width
	_more_books.offset_bottom = pad + height


## Shows the settings overlay over whatever screen is up.
func open_settings() -> SettingsPanel:
	if is_instance_valid(_settings):
		_settings.refresh()
		return _settings
	_settings = SETTINGS_PANEL_SCENE.instantiate() as SettingsPanel
	_settings.name = "SettingsPanel"
	_settings.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings.closed.connect(close_settings)
	_settings.erase_all_confirmed.connect(_on_settings_erase_all)
	_settings.account_requested.connect(_on_settings_account)
	_overlays.add_child(_settings)
	settings_toggled.emit(true)
	return _settings


func close_settings() -> void:
	if not is_instance_valid(_settings):
		return
	_overlays.remove_child(_settings)
	_settings.queue_free()
	_settings = null
	settings_toggled.emit(false)


func _on_settings_erase_all() -> void:
	GameState.erase_all_progress()
	if _current_id == SCREEN_BOOK_SELECT and _current_screen is BookSelect:
		_populate_shelf(_current_screen as BookSelect)


# ============================================================ WP10: the account ==
# DLC_SERVER.md 4.1: "Adult gate in the client before any account UI ... Reuse the
# existing settings-gear overlay placement from main.gd." That is what this block
# is, and the ORDER is the point -- the gate is not a mode of the account panel, it
# is a separate overlay that must be passed before the account panel is ever built.

## "Account" in settings. Closes settings and puts the [AdultGate] up; the account
## panel only exists once the gate is passed.
func _on_settings_account() -> void:
	close_settings()
	open_adult_gate(open_account_panel)


## Shows the arithmetic gate and runs [param on_passed] if it is answered
## correctly. Public because every future grown-up screen should come through here
## rather than growing a second gate.
func open_adult_gate(on_passed: Callable) -> AdultGate:
	_close_adult_gate()
	_adult_gate = ADULT_GATE_SCENE.instantiate() as AdultGate
	_adult_gate.name = "AdultGate"
	_adult_gate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlays.add_child(_adult_gate)
	_adult_gate.cancelled.connect(_close_adult_gate)
	_adult_gate.passed.connect(func() -> void:
		_close_adult_gate()
		if on_passed.is_valid():
			on_passed.call()
	)
	return _adult_gate


func _close_adult_gate() -> void:
	if not is_instance_valid(_adult_gate):
		return
	_overlays.remove_child(_adult_gate)
	_adult_gate.queue_free()
	_adult_gate = null


## The account overlay itself. Reachable ONLY through [method open_adult_gate] in
## the real flow; the harnesses call it directly, which is the same reason
## [method GameState.set_save_root] exists.
func open_account_panel() -> AccountPanel:
	if is_instance_valid(_account_panel):
		_account_panel.refresh()
		return _account_panel
	_account_panel = ACCOUNT_PANEL_SCENE.instantiate() as AccountPanel
	_account_panel.name = "AccountPanel"
	_account_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_account_panel.closed.connect(close_account_panel)
	_account_panel.account_changed.connect(func(_signed_in: bool) -> void:
		_refresh_more_books()
	)
	_overlays.add_child(_account_panel)
	return _account_panel


func close_account_panel() -> void:
	if not is_instance_valid(_account_panel):
		return
	_overlays.remove_child(_account_panel)
	_account_panel.queue_free()
	_account_panel = null


# ============================================================ WP10: more books ==

## The shelf's DLC affordance, built from primitives like the gear so the shell
## still ships no icon assets. Top LEFT, opposite the gear, out of the way of both.
func _build_more_books() -> void:
	_more_books = Button.new()
	_more_books.name = "MoreBooksButton"
	_more_books.visible = false
	_more_books.focus_mode = Control.FOCUS_NONE
	# DESIGN.md 3.5's 48 px floor, matched to the gear's 72 px height. BL-48 scales
	# both from here -- see _apply_overlay_scale().
	_more_books.custom_minimum_size = MORE_BOOKS_SIZE
	_more_books.text = "More books"
	_more_books.add_theme_font_size_override("font_size", MORE_BOOKS_FONT_SIZE)
	_more_books.add_theme_color_override("font_color", Color(0.972549, 0.94902, 0.905882))
	_more_books_style = StyleBoxFlat.new()
	_more_books_style.bg_color = Color(0.156863, 0.141176, 0.129412, 0.92)
	_more_books_style.border_color = Color(0.415686, 0.360784, 0.301961)
	_more_books_style.set_border_width_all(2)
	_more_books_style.set_corner_radius_all(36)
	for state in ["normal", "hover", "pressed"]:
		_more_books.add_theme_stylebox_override(state, _more_books_style)
	_more_books.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_more_books.offset_left = MORE_BOOKS_INSET
	_more_books.offset_top = MORE_BOOKS_INSET
	_more_books.offset_right = MORE_BOOKS_INSET + MORE_BOOKS_SIZE.x
	_more_books.offset_bottom = MORE_BOOKS_INSET + MORE_BOOKS_SIZE.y
	_more_books.pressed.connect(open_pack_shop)
	_overlays.add_child(_more_books)


## Shown on the shelf whenever this build has a server at all -- signed in or not
## (BL-25).
##
## [b]It used to require a signed-in account[/b], on the argument that a shop a
## grown-up cannot use is just confusing. That argument dies with the built-in
## books: a shipped build ships NO books, so the catalogue is the only way a shelf
## ever gets one, and hiding the way in until somebody signs in makes first launch a
## dead end with nothing on screen to press. [code]GET /packs[/code] is optional-auth
## and renders signed out (DLC_SERVER.md 7.4/9), and the first [b]Get[/b] is what
## sends the grown-up to the adult gate -- so the sign-in still happens, at the
## moment it is actually needed, instead of being a precondition for looking.
func _refresh_more_books() -> void:
	if not is_instance_valid(_more_books):
		return
	_more_books.visible = _current_id == SCREEN_BOOK_SELECT \
		and not _transitioning and Backend.is_enabled()


func open_pack_shop() -> PackShop:
	if is_instance_valid(_pack_shop):
		return _pack_shop
	_pack_shop = PACK_SHOP_SCENE.instantiate() as PackShop
	_pack_shop.name = "PackShop"
	_pack_shop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pack_shop.closed.connect(close_pack_shop)
	_pack_shop.pack_installed.connect(func(_slug: String) -> void: _rescan_shelf())
	# BL-25: a Get pressed while signed out leads to the gate rather than failing.
	# The shop stays open underneath, so passing the gate and signing in leaves the
	# grown-up looking at the catalogue they were already looking at.
	_pack_shop.sign_in_requested.connect(func() -> void:
		open_adult_gate(open_account_panel)
	)
	_overlays.add_child(_pack_shop)
	return _pack_shop


func close_pack_shop() -> void:
	if not is_instance_valid(_pack_shop):
		return
	_overlays.remove_child(_pack_shop)
	_pack_shop.queue_free()
	_pack_shop = null


func _on_backend_auth_changed(_signed_in: bool) -> void:
	_refresh_more_books()
	_rescan_shelf()
	if is_instance_valid(_settings):
		_settings.refresh()
	if is_instance_valid(_pack_shop):
		# Signing in from on top of the shop changes every row's `owned` flag and is
		# what makes Get work; re-ask rather than leave a signed-out catalogue up.
		_pack_shop.refresh()


func _on_backend_shelf_changed() -> void:
	_rescan_shelf()


## Rebuilds the shelf in place if it is the current screen. A fresh
## [method BookDef.discover] every time, so an install that just landed appears and
## a revoked pack disappears without any cached list of books anywhere.
func _rescan_shelf() -> void:
	if _current_id == SCREEN_BOOK_SELECT and _current_screen is BookSelect:
		_populate_shelf(_current_screen as BookSelect)


func _close_overlays() -> void:
	close_settings()
	_close_adult_gate()
	close_account_panel()
	close_pack_shop()


# ==================================================================== access ==

func get_current_screen() -> Control:
	return _current_screen


func get_current_screen_id() -> String:
	return _current_id


## True while a screen swap is in flight. Tests wait on it.
func is_transitioning() -> bool:
	return _transitioning


func get_settings_panel() -> SettingsPanel:
	return _settings if is_instance_valid(_settings) else null


func get_gear_button() -> Button:
	return _gear


## BL-48: the one scale the whole overlay layer is drawn at, and the touch floor
## that goes with it. Harnesses assert against these rather than against numbers of
## their own, so the assertions cannot drift from the code.
func get_overlay_scale() -> float:
	return OverlayMetrics.content_scale(get_viewport())


func get_overlay_touch_floor() -> float:
	return OverlayMetrics.min_touch_px(get_viewport())


## WP10 access, for the harnesses and for anything that needs to know whether the
## grown-up overlays are up.
func get_more_books_button() -> Button:
	return _more_books


func get_adult_gate() -> AdultGate:
	return _adult_gate if is_instance_valid(_adult_gate) else null


func get_account_panel() -> AccountPanel:
	return _account_panel if is_instance_valid(_account_panel) else null


func get_pack_shop() -> PackShop:
	return _pack_shop if is_instance_valid(_pack_shop) else null


## BL-30's book-opening overlay. Tests read it to prove the transition is main's
## and that it hands input back when it is done.
func get_book_transition() -> BookOpenTransition:
	return _book_transition


## The notch-safe wrapper both the screen host and the overlays live inside
## (M6). Tests drive its [member SafeArea.debug_insets] to prove the inset really
## reaches the screens on a machine with no cutout.
func get_safe_area() -> SafeArea:
	return _safe_area

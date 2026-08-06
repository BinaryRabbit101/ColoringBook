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
## TitleScreen.start_requested   -> ModeSelect
## ModeSelect.mode_chosen        -> GameState.mode = m -> BookSelect
## BookSelect.book_chosen        -> ColoringPage.load_book(book, resume_index)
## ColoringPage.back_requested   -> BookSelect
## ColoringPage.book_completed   -> BookComplete
## BookComplete.again_requested  -> erase that book -> ColoringPage (page 1)
## BookComplete.books_requested  -> BookSelect
## [/codeblock]
##
## [b]Ordering rule inherited from M4[/b]: [code]GameState.mode[/code] is set
## BEFORE [ColoringPage] is instantiated, because the palette scene and the
## completion threshold are read while that screen builds itself.
##
## [b]Overlays[/b] are main's too, and they are the reason [BookSelect] could stay
## frozen: the settings gear is not inside the shelf scene, it is an overlay this
## node shows while the shelf is the current screen. The settings panel and (when
## a book is open) the mode picker are overlays for the same reason -- changing
## mode must not throw the player out of the book they are colouring.
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

## The visible screen changed. Payload is one of the SCREEN_* ids.
signal screen_changed(screen_id: String)
## The settings overlay opened (true) or closed (false).
signal settings_toggled(is_open: bool)

const SCREEN_TITLE := "title"
const SCREEN_MODE_SELECT := "mode_select"
const SCREEN_BOOK_SELECT := "book_select"
const SCREEN_COLORING := "coloring"
const SCREEN_BOOK_COMPLETE := "book_complete"

const TITLE_SCENE: PackedScene = preload("res://scenes/screens/title_screen.tscn")
const MODE_SELECT_SCENE: PackedScene = preload("res://scenes/screens/mode_select.tscn")
const BOOK_SELECT_SCENE: PackedScene = preload("res://scenes/screens/book_select.tscn")
const COLORING_PAGE_SCENE: PackedScene = preload("res://scenes/screens/coloring_page.tscn")
const BOOK_COMPLETE_SCENE: PackedScene = preload("res://scenes/screens/book_complete.tscn")
const SETTINGS_PANEL_SCENE: PackedScene = preload("res://scenes/components/settings_panel.tscn")

## Screen transition: fade the old screen out, swap, fade the new one in. Short
## on purpose -- long enough to hide the swap, short enough that a child tapping
## through the shelf never waits for it.
const FADE_OUT_SECONDS := 0.12
const FADE_IN_SECONDS := 0.13


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
var _current_screen: Control
var _current_id := ""
var _settings: SettingsPanel
var _mode_overlay: ModeSelect
var _transitioning := false
## Guards against a second close request arriving while the first is draining.
var _closing := false


func _ready() -> void:
	# Main quits the game itself, so it can flush and drain first (class doc).
	get_tree().auto_accept_quit = not quit_on_close_request
	_build_gear()
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


func show_mode_select(from_settings: bool = false) -> Control:
	return await _show_screen(MODE_SELECT_SCENE, SCREEN_MODE_SELECT, func(screen: Control) -> void:
		(screen as ModeSelect).set_back_visible(from_settings)
	)


func show_book_select() -> Control:
	GameState.clear_book()
	return await _show_screen(BOOK_SELECT_SCENE, SCREEN_BOOK_SELECT, func(screen: Control) -> void:
		(screen as BookSelect).load_books()
	)


## Opens [param book] at its saved page with its saved paint. A finished book
## opens at page 1 -- completing a book is never a lockout (see
## [method GameState.get_resume_index]).
func open_book(book: BookDef) -> Control:
	if book == null:
		return null
	var start_index := GameState.get_resume_index(book)
	return await _show_screen(COLORING_PAGE_SCENE, SCREEN_COLORING, func(screen: Control) -> void:
		(screen as ColoringPage).load_book(book, start_index)
	)


func show_book_complete(book: BookDef) -> Control:
	return await _show_screen(BOOK_COMPLETE_SCENE, SCREEN_BOOK_COMPLETE, func(screen: Control) -> void:
		(screen as BookComplete).set_book(book)
	)


# --------------------------------------------------------------- screen swap --

## Fades out, frees the old screen, instantiates and wires the new one, runs
## [param setup] on it, then fades back in. [param setup] runs BEFORE the fade-in
## so a page loads behind the black, not in front of the player.
func _show_screen(scene: PackedScene, id: String, setup: Callable = Callable()) -> Control:
	if _transitioning:
		push_warning("Main: ignoring a request for '%s' during a transition." % id)
		return null
	_transitioning = true
	_close_overlays()
	_gear.visible = false
	await _fade_to(1.0, FADE_OUT_SECONDS)

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
	await _fade_to(0.0, FADE_IN_SECONDS)
	# The gear is an OVERLAY on the shelf, which is how book_select.tscn stayed
	# frozen while still growing a settings entry point.
	_gear.visible = id == SCREEN_BOOK_SELECT
	_transitioning = false
	screen_changed.emit(id)
	return screen


func _connect_screen(screen: Control, id: String) -> void:
	match id:
		SCREEN_TITLE:
			(screen as TitleScreen).start_requested.connect(_on_title_start)
		SCREEN_MODE_SELECT:
			var mode_select := screen as ModeSelect
			mode_select.mode_chosen.connect(_on_mode_chosen)
			mode_select.back_requested.connect(_on_mode_select_cancelled)
		SCREEN_BOOK_SELECT:
			(screen as BookSelect).book_chosen.connect(_on_book_chosen)
		SCREEN_COLORING:
			var coloring := screen as ColoringPage
			coloring.back_requested.connect(_on_coloring_back)
			coloring.book_completed.connect(_on_book_completed)
		SCREEN_BOOK_COMPLETE:
			var complete := screen as BookComplete
			complete.again_requested.connect(_on_again_requested)
			complete.books_requested.connect(_on_books_requested)


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


# =============================================================== screen hooks ==

func _on_title_start() -> void:
	await show_mode_select()


func _on_mode_chosen(mode_id: String) -> void:
	# Before any screen that reads it is built (M4 handoff).
	GameState.set_mode(mode_id)
	await show_book_select()


## Only reachable when the picker was opened from settings, so "cancel" means
## "back to the shelf".
func _on_mode_select_cancelled() -> void:
	await show_book_select()


func _on_book_chosen(book: BookDef) -> void:
	await open_book(book)


## The page already flushed its paint in [method ColoringPage._on_back_pressed];
## all that is left is the screen swap.
func _on_coloring_back() -> void:
	await show_book_select()


func _on_book_completed(book: BookDef) -> void:
	await show_book_complete(book)


## "Color again": the book starts over with nothing saved -- no stale paint layer,
## no stale page statuses.
func _on_again_requested(book: BookDef) -> void:
	GameState.erase_book_progress(book)
	await open_book(book)


func _on_books_requested() -> void:
	await show_book_select()


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


## Shows the settings overlay over whatever screen is up.
func open_settings() -> SettingsPanel:
	if is_instance_valid(_settings):
		_settings.refresh()
		return _settings
	_settings = SETTINGS_PANEL_SCENE.instantiate() as SettingsPanel
	_settings.name = "SettingsPanel"
	_settings.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings.closed.connect(close_settings)
	_settings.mode_change_requested.connect(_on_settings_mode_change)
	_settings.erase_all_confirmed.connect(_on_settings_erase_all)
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


## "Change mode" from settings. With a book open the picker is an OVERLAY, so the
## player returns to the page they were colouring with the new palette already
## swapped in; otherwise it is a normal screen with a way back to the shelf.
func _on_settings_mode_change() -> void:
	var over_a_book := _current_id == SCREEN_COLORING
	close_settings()
	if over_a_book:
		_open_mode_overlay()
	else:
		await show_mode_select(true)


func _on_settings_erase_all() -> void:
	GameState.erase_all_progress()
	if _current_id == SCREEN_BOOK_SELECT and _current_screen is BookSelect:
		(_current_screen as BookSelect).load_books()


func _open_mode_overlay() -> ModeSelect:
	if is_instance_valid(_mode_overlay):
		return _mode_overlay
	_mode_overlay = MODE_SELECT_SCENE.instantiate() as ModeSelect
	_mode_overlay.name = "ModeSelectOverlay"
	_mode_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlays.add_child(_mode_overlay)
	_mode_overlay.set_back_visible(true)
	_mode_overlay.mode_chosen.connect(_on_mode_overlay_chosen)
	_mode_overlay.back_requested.connect(_close_mode_overlay)
	return _mode_overlay


func _on_mode_overlay_chosen(mode_id: String) -> void:
	# The live ColoringPage listens to GameState.mode_changed and rebuilds its
	# palette + threshold itself; main only has to get out of the way.
	GameState.set_mode(mode_id)
	_close_mode_overlay()


func _close_mode_overlay() -> void:
	if not is_instance_valid(_mode_overlay):
		return
	_overlays.remove_child(_mode_overlay)
	_mode_overlay.queue_free()
	_mode_overlay = null


func _close_overlays() -> void:
	close_settings()
	_close_mode_overlay()


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


func get_mode_select_overlay() -> ModeSelect:
	return _mode_overlay if is_instance_valid(_mode_overlay) else null


func get_gear_button() -> Button:
	return _gear


## The notch-safe wrapper both the screen host and the overlays live inside
## (M6). Tests drive its [member SafeArea.debug_insets] to prove the inset really
## reaches the screens on a machine with no cutout.
func get_safe_area() -> SafeArea:
	return _safe_area

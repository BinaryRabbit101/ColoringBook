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
## [/codeblock]
##
## [b]There is no completion screen[/b] (BL-11, DESIGN.md 2). Finishing a page --
## including the last one -- is celebrated on the coloring page itself and takes
## the player nowhere; [signal ColoringPage.back_requested] is the only exit from
## a book, so the flow above is the whole flow.
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
## [b]WP10 added three more overlays and one more shelf button[/b], on exactly that
## pattern, so [code]book_select.tscn[/code] is STILL frozen:
## [codeblock]
## Settings -> "Account" -> AdultGate -> AccountPanel   sign in / register / out
## shelf    -> "More books"           -> PackShop       the DLC catalogue
## [/codeblock]
## The "More books" button appears only while the shelf is up AND a grown-up is
## signed in; the gate stands in front of every account screen (DLC_SERVER.md 4.1).
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

## The visible screen changed. Payload is one of the SCREEN_* ids.
signal screen_changed(screen_id: String)
## The settings overlay opened (true) or closed (false).
signal settings_toggled(is_open: bool)

const SCREEN_TITLE := "title"
const SCREEN_MODE_SELECT := "mode_select"
const SCREEN_BOOK_SELECT := "book_select"
const SCREEN_COLORING := "coloring"

const TITLE_SCENE: PackedScene = preload("res://scenes/screens/title_screen.tscn")
const MODE_SELECT_SCENE: PackedScene = preload("res://scenes/screens/mode_select.tscn")
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
## WP10: the shelf's DLC entry point. An overlay button, not part of the shelf
## scene, and visible only when the shelf is up AND somebody is signed in.
var _more_books: Button
var _current_screen: Control
var _current_id := ""
var _settings: SettingsPanel
var _mode_overlay: ModeSelect
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


func show_mode_select(from_settings: bool = false) -> Control:
	return await _show_screen(MODE_SELECT_SCENE, SCREEN_MODE_SELECT, func(screen: Control) -> void:
		(screen as ModeSelect).set_back_visible(from_settings)
	)


func show_book_select() -> Control:
	GameState.clear_book()
	return await _show_screen(BOOK_SELECT_SCENE, SCREEN_BOOK_SELECT, func(screen: Control) -> void:
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
	return await _show_screen(COLORING_PAGE_SCENE, SCREEN_COLORING, func(screen: Control) -> void:
		(screen as ColoringPage).load_book(book, start_index)
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
	_more_books.visible = false
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
		SCREEN_MODE_SELECT:
			var mode_select := screen as ModeSelect
			mode_select.mode_chosen.connect(_on_mode_chosen)
			mode_select.back_requested.connect(_on_mode_select_cancelled)
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
	# DESIGN.md 3.5's 48 px floor, matched to the gear's 72 px height.
	_more_books.custom_minimum_size = Vector2(190.0, 72.0)
	_more_books.text = "More books"
	_more_books.add_theme_font_size_override("font_size", 22)
	_more_books.add_theme_color_override("font_color", Color(0.972549, 0.94902, 0.905882))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.156863, 0.141176, 0.129412, 0.92)
	style.border_color = Color(0.415686, 0.360784, 0.301961)
	style.set_border_width_all(2)
	style.set_corner_radius_all(36)
	for state in ["normal", "hover", "pressed"]:
		_more_books.add_theme_stylebox_override(state, style)
	_more_books.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_more_books.offset_left = 20.0
	_more_books.offset_top = 20.0
	_more_books.offset_right = 20.0 + 190.0
	_more_books.offset_bottom = 20.0 + 72.0
	_more_books.pressed.connect(open_pack_shop)
	_overlays.add_child(_more_books)


## Shown only on the shelf, only when a grown-up is signed in (DLC_SERVER.md 4.1:
## children never touch an account, and a shop they cannot use is just confusing).
func _refresh_more_books() -> void:
	if not is_instance_valid(_more_books):
		return
	_more_books.visible = _current_id == SCREEN_BOOK_SELECT \
		and not _transitioning and Backend.is_signed_in()


func open_pack_shop() -> PackShop:
	if is_instance_valid(_pack_shop):
		return _pack_shop
	_pack_shop = PACK_SHOP_SCENE.instantiate() as PackShop
	_pack_shop.name = "PackShop"
	_pack_shop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pack_shop.closed.connect(close_pack_shop)
	_pack_shop.pack_installed.connect(func(_slug: String) -> void: _rescan_shelf())
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


func _on_backend_shelf_changed() -> void:
	_rescan_shelf()


## Rebuilds the shelf in place if it is the current screen. A fresh
## [method BookDef.discover] every time, so an install that just landed appears and
## a revoked pack disappears without any cached list of books anywhere.
func _rescan_shelf() -> void:
	if _current_id == SCREEN_BOOK_SELECT and _current_screen is BookSelect:
		_populate_shelf(_current_screen as BookSelect)


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


func get_mode_select_overlay() -> ModeSelect:
	return _mode_overlay if is_instance_valid(_mode_overlay) else null


func get_gear_button() -> Button:
	return _gear


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


## The notch-safe wrapper both the screen host and the overlays live inside
## (M6). Tests drive its [member SafeArea.debug_insets] to prove the inset really
## reaches the screens on a machine with no cutout.
func get_safe_area() -> SafeArea:
	return _safe_area

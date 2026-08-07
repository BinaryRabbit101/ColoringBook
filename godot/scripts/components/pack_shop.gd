class_name PackShop
extends Control
## "More books": the catalogue of DLC packs, and the only place a download can
## start (DLC_SERVER.md 7.4, 8.2, 9).
##
## [b]An overlay on the shelf, shown only when a grown-up is signed in.[/b]
## [code]main.gd[/code] owns it and its entry button, exactly as it owns the
## settings gear -- which is what keeps [code]book_select.tscn[/code] frozen while
## the shelf grows a new affordance.
##
## [b]Two rules from DLC_SERVER.md 8.2 are the whole design of this screen:[/b]
##
## 1. [b]Downloads are user-initiated, and asked about first.[/b] A pack never
##    starts on its own and tapping it does not start it either: the row turns into
##    "Download 0.9 MB?" with a yes and a no. "A kid on a parent's phone plan does
##    not silently pull 8 MB" -- and the number in the question is the real archive
##    size the server reported, not an estimate.
## 2. [b]The catalogue is not a screen the game waits on.[/b] Opening this overlay
##    renders immediately from what is installed; the [code]GET /packs[/code]
##    answer patches it when it lands. If it never lands, the overlay says so and
##    the shelf behind it is completely unaffected.
##
## [b]The client never decides what it owns[/b] (DLC_SERVER.md 9). Every flag on a
## row -- [code]owned[/code], [code]is_free[/code], [code]latest_version[/code] --
## is the server's word, rendered verbatim. This file computes exactly one thing
## locally: whether the pack directory is already on disk, which is a fact about
## the filesystem rather than about entitlement.

## The player closed the overlay.
signal closed()
## A pack finished installing, so the shelf behind should rescan.
signal pack_installed(slug: String)

## Response keys of the server's [code]PackResource[/code] (DLC_SERVER.md 11).
const KEY_SLUG := "slug"
const KEY_TITLE := "title"
const KEY_BLURB := "blurb"
const KEY_IS_FREE := "is_free"
const KEY_OWNED := "owned"
const KEY_BYTES := "bytes"
const KEY_LATEST_VERSION := "latest_version"
const KEY_MIN_CLIENT_VERSION := "min_client_version"
const KEY_PAGE_COUNT := "page_count"

@onready var _scrim: Button = $Scrim
@onready var _list: VBoxContainer = $Center/Panel/Margin/Column/Scroll/List
@onready var _status: Label = $Center/Panel/Margin/Column/Status
@onready var _close_button: Button = $Center/Panel/Margin/Column/CloseButton

var _rows: Array[PackRow] = []
## Slug currently downloading, or "".
var _installing := ""


func _ready() -> void:
	_scrim.pressed.connect(_on_close_pressed)
	_close_button.pressed.connect(_on_close_pressed)
	Backend.pack_install_progress.connect(_on_progress)
	# Render what we already know before anything is asked of the network.
	_show_installed_only()
	refresh()


# ======================================================================= data ==

## Fetches the catalogue and rebuilds the list. Never blocks the shelf: the
## overlay is already on screen and already useful when this starts.
func refresh() -> void:
	if not Backend.is_signed_in():
		_set_status("Sign in from Settings to see extra books.")
		return
	_set_status("Looking for new books…")
	var result: Dictionary = await Backend.fetch_packs()
	if not is_inside_tree():
		return
	if not bool(result.get(Backend.KEY_OK, false)):
		# Grown-up-facing, and only ever inside this overlay (DLC_SERVER.md 8.2).
		_set_status(AccountPanel.describe_error(result))
		return
	var packs: Variant = result.get(Backend.KEY_DATA, [])
	set_packs(packs as Array if typeof(packs) == TYPE_ARRAY else [])


## Fills the list from an explicit array of pack rows -- dependency injection for
## the smoke, and the single place a row is built.
func set_packs(packs: Array) -> void:
	_clear()
	for raw: Variant in packs:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var row := PackRow.new(raw as Dictionary)
		row.download_requested.connect(_on_download_requested.bind(row))
		_list.add_child(row)
		_rows.append(row)
	if _rows.is_empty():
		_set_status("No extra books yet. Check back soon!")
	else:
		_set_status("")


func get_rows() -> Array[PackRow]:
	return _rows.duplicate()


func get_row(slug: String) -> PackRow:
	for row in _rows:
		if row.get_slug() == slug:
			return row
	return null


func get_status_text() -> String:
	return _status.text if _status.visible else ""


func is_installing() -> bool:
	return _installing != ""


## The offline face of this overlay: whatever is on disk, with no server flags.
## Shown for the frame or two before [method refresh] answers, and left in place if
## it never does.
func _show_installed_only() -> void:
	var packs: Array = []
	for slug in Backend.installed_packs():
		var manifest := Backend.get_installer().installed_manifest(slug)
		packs.append({
			KEY_SLUG: slug,
			KEY_TITLE: String(manifest.get("title", slug)),
			KEY_BLURB: String(manifest.get("blurb", "")),
			KEY_IS_FREE: bool(manifest.get("is_free", false)),
			KEY_OWNED: true,
			KEY_LATEST_VERSION: int(manifest.get("pack_version", 0)),
			KEY_MIN_CLIENT_VERSION: String(manifest.get("min_client_version", "")),
		})
	set_packs(packs)


# ================================================================== the install ==

## The confirm has already happened inside the row (see [PackRow]); this is the
## "yes" (DLC_SERVER.md 8.2).
func _on_download_requested(row: PackRow) -> void:
	if _installing != "":
		return
	_installing = row.get_slug()
	row.set_downloading(0, row.get_bytes())
	_set_status("")
	var result: Dictionary = await Backend.install_pack(row.get_slug())
	_installing = ""
	if not is_inside_tree():
		return
	if bool(result.get(PackInstaller.KEY_OK, false)):
		row.set_installed_version(int(result.get(PackInstaller.KEY_VERSION, 0)))
		pack_installed.emit(row.get_slug())
		return
	row.set_failed()
	_set_status(describe_install_error(result))


func _on_progress(slug: String, downloaded: int, total: int) -> void:
	var row := get_row(slug)
	if row != null:
		row.set_downloading(downloaded, total)


## Install failures, branched on [code]code[/code] like every other backend call.
static func describe_install_error(result: Dictionary) -> String:
	var code := String(result.get(PackInstaller.KEY_CODE, ""))
	match code:
		PackInstaller.CODE_CHECKSUM, PackInstaller.CODE_MISSING_FILE, \
		PackInstaller.CODE_BAD_ARCHIVE:
			# A corrupt ID map would paint into the wrong regions, so this is the
			# one failure worth naming plainly: nothing was installed.
			return "That download arrived damaged and was thrown away. Please try again."
		PackInstaller.CODE_CLIENT_TOO_OLD:
			return "This book pack needs a newer version of the app."
		PackInstaller.CODE_WRITE_FAILED, PackInstaller.CODE_SWAP_FAILED:
			return "There was not enough room to install that pack."
		ApiClient.CODE_ENTITLEMENT_REQUIRED:
			return "This account does not own that pack yet."
	return AccountPanel.describe_error(result)


# ===================================================================== display ==

func _set_status(text: String) -> void:
	_status.text = text
	_status.visible = text != ""


func _clear() -> void:
	_rows.clear()
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()


func _on_close_pressed() -> void:
	if _installing != "":
		# Closing mid-download is fine -- the install runs in Backend, not here --
		# but the overlay is where the progress is, so say so rather than vanishing.
		_set_status("Still downloading. You can close this; it carries on.")
	closed.emit()


func get_close_button() -> Button:
	return _close_button


# ======================================================================== rows ==

## One pack in the list: title, size, and a button whose label IS its state.
##
## The confirm step is a mode of the row rather than a dialog -- the same pattern
## [SettingsPanel] uses for erase, and for the same reasons (popups behave badly on
## mobile, and a destructive-or-expensive action should never be one tap away).
class PackRow extends PanelContainer:
	## The grown-up said yes to the download.
	signal download_requested()

	const STATE_AVAILABLE := "available"
	const STATE_CONFIRM := "confirm"
	const STATE_DOWNLOADING := "downloading"
	const STATE_INSTALLED := "installed"
	const STATE_UPDATE := "update"
	const STATE_BLOCKED := "blocked"
	const STATE_FAILED := "failed"

	var _data: Dictionary
	var _state := STATE_AVAILABLE
	var _title: Label
	var _detail: Label
	var _action: Button
	var _cancel: Button
	var _bar: ProgressBar

	func _init(data: Dictionary) -> void:
		_data = data
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.223529, 0.203922, 0.188235)
		style.set_corner_radius_all(14)
		style.set_content_margin_all(14)
		add_theme_stylebox_override("panel", style)

		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 8)
		add_child(column)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		column.add_child(row)

		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.add_theme_constant_override("separation", 2)
		row.add_child(text)

		_title = Label.new()
		_title.text = String(_data.get(KEY_TITLE, _data.get(KEY_SLUG, "?")))
		_title.add_theme_font_size_override("font_size", 24)
		_title.add_theme_color_override("font_color", Color(0.976471, 0.960784, 0.933333))
		text.add_child(_title)

		_detail = Label.new()
		_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_detail.add_theme_font_size_override("font_size", 18)
		_detail.add_theme_color_override("font_color", Color(0.729412, 0.678431, 0.6))
		text.add_child(_detail)

		_cancel = _make_button("Not now", Vector2(120, 56))
		_cancel.name = "CancelButton"
		_cancel.visible = false
		_cancel.pressed.connect(func() -> void: _set_state(STATE_AVAILABLE))
		row.add_child(_cancel)

		# DESIGN.md 3.5's 48 px touch floor, with room to spare.
		_action = _make_button("", Vector2(180, 56))
		_action.name = "ActionButton"
		_action.pressed.connect(_on_action_pressed)
		row.add_child(_action)

		_bar = ProgressBar.new()
		_bar.name = "ProgressBar"
		_bar.custom_minimum_size = Vector2(0, 14)
		_bar.show_percentage = false
		_bar.max_value = 1.0
		_bar.visible = false
		column.add_child(_bar)

		_set_state(_initial_state())

	## The state a freshly-listed pack starts in. Installed-and-current beats
	## everything; a pack this build is too old for can never be downloaded.
	func _initial_state() -> String:
		if not BackendConfig.satisfies_min_version(
				String(_data.get(KEY_MIN_CLIENT_VERSION, ""))):
			return STATE_BLOCKED
		if Backend.is_pack_installed(get_slug()):
			var latest := int(_data.get(KEY_LATEST_VERSION, 0))
			var installed := Backend.installed_pack_version(get_slug())
			return STATE_UPDATE if latest > 0 and latest > installed else STATE_INSTALLED
		return STATE_AVAILABLE

	func get_slug() -> String:
		return String(_data.get(KEY_SLUG, ""))

	func get_bytes() -> int:
		return int(_data.get(KEY_BYTES, 0))

	func get_state() -> String:
		return _state

	func get_action_button() -> Button:
		return _action

	func get_detail_text() -> String:
		return _detail.text

	func get_progress_ratio() -> float:
		return float(_bar.value)

	## Drives the row straight to its confirm step, then to the download. Public so
	## a harness exercises the SAME path a tap does.
	func press_action() -> void:
		_on_action_pressed()

	func _on_action_pressed() -> void:
		match _state:
			STATE_AVAILABLE, STATE_UPDATE, STATE_FAILED:
				_set_state(STATE_CONFIRM)
			STATE_CONFIRM:
				download_requested.emit()

	func set_downloading(downloaded: int, total: int) -> void:
		if _state != STATE_DOWNLOADING:
			_set_state(STATE_DOWNLOADING)
		var known := total if total > 0 else get_bytes()
		_bar.value = clampf(float(downloaded) / float(known), 0.0, 1.0) if known > 0 else 0.0
		_detail.text = "Downloading… %s of %s" % [format_bytes(downloaded), format_bytes(known)]

	func set_installed_version(version: int) -> void:
		if version > 0:
			_data[KEY_LATEST_VERSION] = version
		_data[KEY_OWNED] = true
		_set_state(STATE_INSTALLED)

	func set_failed() -> void:
		_set_state(STATE_FAILED)

	func _set_state(state: String) -> void:
		_state = state
		_bar.visible = state == STATE_DOWNLOADING
		_cancel.visible = state == STATE_CONFIRM
		_action.disabled = state in [STATE_INSTALLED, STATE_DOWNLOADING, STATE_BLOCKED]
		match state:
			STATE_CONFIRM:
				# The size is the point of the question (DLC_SERVER.md 8.2).
				_action.text = "Yes, download"
				_detail.text = "Download %s now?" % format_bytes(get_bytes())
			STATE_DOWNLOADING:
				_action.text = "Downloading…"
			STATE_INSTALLED:
				_action.text = "On the shelf"
				_detail.text = _describe()
			STATE_UPDATE:
				_action.text = "Update"
				_detail.text = "A newer version of this book is ready."
			STATE_BLOCKED:
				_action.text = "Needs an update"
				_detail.text = "This pack needs app version %s or newer." \
					% String(_data.get(KEY_MIN_CLIENT_VERSION, "?"))
			STATE_FAILED:
				_action.text = "Try again"
			_:
				_action.text = "Get" if bool(_data.get(KEY_IS_FREE, false)) else "Get"
				_detail.text = _describe()

	## Blurb, page count and size, in the row's resting state.
	func _describe() -> String:
		var parts := PackedStringArray()
		var blurb := String(_data.get(KEY_BLURB, "")).strip_edges()
		if blurb != "":
			parts.append(blurb)
		var pages := int(_data.get(KEY_PAGE_COUNT, 0))
		if pages > 0:
			parts.append("%d page%s" % [pages, "" if pages == 1 else "s"])
		if get_bytes() > 0:
			parts.append(format_bytes(get_bytes()))
		if bool(_data.get(KEY_IS_FREE, false)):
			parts.append("Free")
		return " · ".join(parts)

	## A row button in the same style the hand-authored overlay scenes use. Built in
	## code because rows are built in code -- a scene per row would be three files
	## for one HBox.
	static func _make_button(text: String, minimum: Vector2) -> Button:
		var button := Button.new()
		button.text = text
		button.custom_minimum_size = minimum
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_font_size_override("font_size", 21)
		button.add_theme_color_override("font_color", Color(0.972549, 0.94902, 0.905882))
		button.add_theme_color_override("font_disabled_color", Color(0.552941, 0.529412, 0.494118))
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.352941, 0.309804, 0.278431)
		style.set_corner_radius_all(12)
		var disabled := style.duplicate() as StyleBoxFlat
		disabled.bg_color = Color(0.278431, 0.254902, 0.235294)
		for state in ["normal", "hover", "pressed"]:
			button.add_theme_stylebox_override(state, style)
		button.add_theme_stylebox_override("disabled", disabled)
		return button


	static func format_bytes(bytes: int) -> String:
		if bytes <= 0:
			return "—"
		if bytes < 1024:
			return "%d B" % bytes
		if bytes < 1024 * 1024:
			return "%.0f KB" % (float(bytes) / 1024.0)
		return "%.1f MB" % (float(bytes) / 1048576.0)

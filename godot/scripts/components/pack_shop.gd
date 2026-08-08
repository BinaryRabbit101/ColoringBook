class_name PackShop
extends Control
## "More books": the catalogue of DLC packs, and the only place a download can
## start (DLC_SERVER.md 7.4, 8.2, 9).
##
## [b]An overlay on the shelf, shown whenever this build has a server.[/b]
## [code]main.gd[/code] owns it and its entry button, exactly as it owns the
## settings gear -- which is what keeps [code]book_select.tscn[/code] frozen while
## the shelf grows a new affordance.
##
## [b]It lists signed out[/b] (BL-25). Since a shipped build contains no coloring
## books at all, this overlay is the only way a shelf ever gets one, so it must not
## require an account merely to be looked at: [code]GET /packs[/code] is
## optional-auth for exactly that reason. What DOES need an account is getting a
## pack -- even a free one, whose entitlement is granted to a signed-in device
## (DLC_SERVER.md 9) -- so a Get pressed signed out raises
## [signal sign_in_requested] and the grown-up meets the adult gate.
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
## [b]Two tabs, one list[/b] (BL-41). Coloring books and sticker sets are different
## products delivered by identical machinery, and a single list of both made a child
## tap the wrong one -- so the catalogue is split by [code]manifest.kind[/code]
## (BL-37) into a Books tab and a Stickers tab. Every row of BOTH is still built,
## and the tab only chooses which are visible: a download in the tab nobody is
## looking at still finds its row, still gets its bytes, and still draws its BL-31
## wax stroke, so switching tabs mid-download shows a strip that is where it should
## be rather than one starting again from zero.
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
## A download was asked for with nobody signed in. [code]main.gd[/code] answers with
## the adult gate; this overlay never opens an account screen itself (BL-25).
signal sign_in_requested()

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
## What the pack CARRIES (BL-37): [constant KIND_BOOK] or
## [constant KIND_STICKER_SET]. Absent means books, which is every pack published
## before BL-37 and every manifest written before it.
const KEY_KIND := "kind"
const KEY_STICKER_COUNT := "sticker_count"

## Pack kinds the shop knows how to describe.
const KIND_BOOK := "book"
const KIND_STICKER_SET := "sticker_set"

## The two tabs (BL-41), in the order they are shown. A tab IS a kind: there is no
## "all" tab, because the whole complaint was that one list of two different
## products makes a child tap the wrong one.
const TABS: PackedStringArray = [KIND_BOOK, KIND_STICKER_SET]
## What each tab is called, and what an empty one says. Indexed by kind.
const TAB_LABELS := {KIND_BOOK: "Books", KIND_STICKER_SET: "Stickers"}
const TAB_EMPTY := {
	KIND_BOOK: "No extra books yet. Check back soon!",
	KIND_STICKER_SET: "No sticker sets yet. Check back soon!",
}

## Shown when the catalogue lists but nobody is signed in, and again if a Get is
## pressed in that state (BL-25). One string, so the shop says the same thing twice
## rather than two things once.
const SIGNED_OUT_HINT := "A grown-up needs to sign in to add a book."

## The crayon that draws a download (BL-31). Preloaded into a constant rather than
## reached through a [code]class_name[/code]: the type then resolves without the
## editor having rebuilt its global-class cache.
const WaxProgress := preload("res://scripts/components/wax_progress.gd")

@onready var _scrim: Button = $Scrim
@onready var _tabs: HBoxContainer = $Center/Panel/Margin/Column/Tabs
@onready var _list: VBoxContainer = $Center/Panel/Margin/Column/Scroll/List
@onready var _status: Label = $Center/Panel/Margin/Column/Status
@onready var _close_button: Button = $Center/Panel/Margin/Column/CloseButton

var _rows: Array[PackRow] = []
## Slug currently downloading, or "".
var _installing := ""
## Which of [constant TABS] is showing.
var _tab := KIND_BOOK
## The tab buttons, in [constant TABS] order.
var _tab_buttons: Array[Button] = []
## BL-48's shared overlay scaler. Held so it is not collected; it parents itself.
##
## This is the one overlay whose contents are BUILT rather than authored, so it is
## also the one that has to re-apply: [method OverlayMetrics.apply] captures a
## control's baseline the first time it sees it, which is why a freshly-built row
## only has to be walked, not registered.
var _metrics: OverlayMetrics


func _ready() -> void:
	_metrics = OverlayMetrics.attach(self)
	_scrim.pressed.connect(_on_close_pressed)
	_close_button.pressed.connect(_on_close_pressed)
	Backend.pack_install_progress.connect(_on_progress)
	_build_tabs()
	# Render what we already know before anything is asked of the network.
	_show_installed_only()
	refresh()


# ======================================================================= data ==

## Fetches the catalogue and rebuilds the list. Never blocks the shelf: the
## overlay is already on screen and already useful when this starts.
func refresh() -> void:
	if not Backend.is_enabled():
		_set_status("This version of the game has no book shop.")
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
	if not _rows.is_empty() and not Backend.is_signed_in():
		# The catalogue lists fine signed out (BL-25); getting one still needs an
		# account, so say so here rather than only at the moment of the tap.
		_set_status(SIGNED_OUT_HINT)


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
	_open_a_tab_with_something_on_it()
	_apply_tab()
	# BL-48: the rows that just appeared were built at their authored sizes.
	if is_instance_valid(_metrics):
		_metrics.apply()


## Lands the player on a tab that has packs on it, when the one they would have
## got is bare. A shop that opens on an empty shelf of books while ten sticker sets
## sit one tap away is a shop that looks broken.
func _open_a_tab_with_something_on_it() -> void:
	if not get_visible_rows().is_empty():
		return
	for kind in TABS:
		for row in _rows:
			if row.get_kind() == kind:
				_tab = kind
				return


## Every row the shop is holding, both tabs. [method get_visible_rows] is the one
## the player can see.
func get_rows() -> Array[PackRow]:
	return _rows.duplicate()


# ======================================================================= tabs ==
# BL-41: coloring books and sticker sets are different products, and one list of
# both made a child tap the wrong thing. They get a tab each.
#
# [b]Both tabs' rows are always BUILT[/b] and the tab only decides which are
# visible. That is what keeps everything else in this file exactly as it was: a
# download in the tab you are not looking at still finds its row through
# [method get_row], still gets its bytes, and still runs its BL-31 wax stroke and
# its confetti -- and switching tabs mid-download shows a strip that is already
# where it should be rather than one starting from zero.

## Which tab is showing: one of [constant TABS].
func get_tab() -> String:
	return _tab


## Shows [param kind]'s tab. Unknown kinds are ignored rather than emptying the
## shop -- a future pack kind this build has never heard of must not be able to
## leave the player looking at nothing.
func set_tab(kind: String) -> void:
	if _tab == kind or not TABS.has(kind):
		return
	_tab = kind
	_apply_tab()


## The tab buttons, in [constant TABS] order. A harness presses these; the game
## does not read them.
func get_tab_buttons() -> Array[Button]:
	return _tab_buttons.duplicate()


## The rows on the tab that is showing.
func get_visible_rows() -> Array[PackRow]:
	var out: Array[PackRow] = []
	for row in _rows:
		if row.get_kind() == _tab:
			out.append(row)
	return out


func _build_tabs() -> void:
	for i in TABS.size():
		var kind := TABS[i]
		var button := PackRow._make_button(String(TAB_LABELS[kind]), Vector2(0, 52))
		button.name = "Tab_%s" % kind
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(set_tab.bind(kind))
		_tabs.add_child(button)
		_tab_buttons.append(button)
	_paint_tabs()


## Hides the rows of the other tab and says something useful when this one is bare.
##
## The status line is shared with the network and the signed-out hint, so an EMPTY
## tab only claims it when there is nothing more important to say -- otherwise
## switching tabs would silently wipe "A grown-up needs to sign in".
func _apply_tab() -> void:
	var shown := 0
	for row in _rows:
		row.visible = row.get_kind() == _tab
		if row.visible:
			shown += 1
	_paint_tabs()
	if shown == 0:
		_set_status(String(TAB_EMPTY[_tab]))
	elif _status.text in TAB_EMPTY.values():
		_set_status("")


## The showing tab is lit; the others are not. Drawn with the row buttons' own
## styleboxes so the shop stays one visual family.
func _paint_tabs() -> void:
	for i in _tab_buttons.size():
		var lit := TABS[i] == _tab
		var style := StyleBoxFlat.new()
		style.bg_color = (
			Color(0.494118, 0.427451, 0.372549) if lit else Color(0.278431, 0.254902, 0.235294)
		)
		style.set_corner_radius_all(12)
		if lit:
			# A lip along the bottom, the way the toolbar's slabs are lipped: the tab
			# that is out reads as a tab rather than as a brighter button.
			style.border_width_bottom = 4
			style.border_color = Color(0.972549, 0.803922, 0.478431)
		for state in ["normal", "hover", "pressed"]:
			_tab_buttons[i].add_theme_stylebox_override(state, style)


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
			# BL-41: which tab it belongs on. The installed manifest says so (BL-37),
			# and an absent key means books -- so a pack installed before either entry
			# lands on the books tab, which is what it is.
			KEY_KIND: String(manifest.get("kind", KIND_BOOK)),
		})
	set_packs(packs)


# ================================================================== the install ==

## The confirm has already happened inside the row (see [PackRow]); this is the
## "yes" (DLC_SERVER.md 8.2).
func _on_download_requested(row: PackRow) -> void:
	if _installing != "":
		return
	if not Backend.is_signed_in():
		# BL-25: even a free pack needs a signed-in device to grant its entitlement
		# (DLC_SERVER.md 9). Route the grown-up to the gate instead of letting the
		# install fail with a code nobody asked to see. The row is left in its confirm
		# state on purpose -- come back from the gate and "Yes, download" is still
		# there, and a refresh after a successful sign-in rebuilds it anyway.
		_set_status(SIGNED_OUT_HINT)
		sign_in_requested.emit()
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


## BL-48's shared scaler, for the harnesses.
func get_overlay_metrics() -> OverlayMetrics:
	return _metrics


# ======================================================================== rows ==

## One pack in the list: title, size, and a button whose label IS its state.
##
## The confirm step is a mode of the row rather than a dialog -- the same pattern
## [SettingsPanel] uses for erase, and for the same reasons (popups behave badly on
## mobile, and a destructive-or-expensive action should never be one tap away).
##
## [b]While it downloads[/b] the row grows a crayon strip ([WaxProgress], BL-31)
## instead of a bare bar. The strip is fed the same bytes the label is -- it is a
## second rendering of [method get_progress_ratio], not a second source of truth --
## and it is driven entirely from [method _set_state], so the state machine above
## is exactly what it was before the animation existed.
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
	var _wax: WaxProgress

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

		# A PLAIN BoxContainer, which is BL-48's convention for "a row that stacks in
		# portrait": title-and-blurb, then Not now, then Get, each the full width of
		# the card, instead of three things fighting over 390 pt of phone.
		var row := BoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		column.add_child(row)

		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.add_theme_constant_override("separation", 2)
		row.add_child(text)

		_title = Label.new()
		# BL-37: the kind reads in the title as well as in the detail line,
		# because the title is the only part a scanning eye actually lands on.
		_title.text = "%s%s" % [
			String(_data.get(KEY_TITLE, _data.get(KEY_SLUG, "?"))),
			"  ★" if is_sticker_set() else "",
		]
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

		_wax = WaxProgress.new()
		_wax.name = "WaxProgress"
		column.add_child(_wax)

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

	## The real ratio, as the last [method set_downloading] computed it -- never the
	## eased one the strip happens to be drawing this frame.
	func get_progress_ratio() -> float:
		return _wax.get_ratio()

	## The download strip, so a harness can look at what the row is showing.
	func get_progress_strip() -> WaxProgress:
		return _wax

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
		# A negative ratio is "nobody told us how big this is": the strip scribbles
		# gently rather than claiming a percentage it does not have.
		_wax.set_progress(
			clampf(float(downloaded) / float(known), 0.0, 1.0) if known > 0 else -1.0)
		_detail.text = "Downloading… %s of %s" % [format_bytes(downloaded), format_bytes(known)]

	func set_installed_version(version: int) -> void:
		if version > 0:
			_data[KEY_LATEST_VERSION] = version
		_data[KEY_OWNED] = true
		_set_state(STATE_INSTALLED)

	func set_failed() -> void:
		_set_state(STATE_FAILED)

	func _set_state(state: String) -> void:
		var previous := _state
		_state = state
		_update_strip(previous, state)
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

	## The animation, hung off the state machine rather than woven into it (BL-31).
	## Three transitions are all it knows: a download starting, a download that
	## ENDED WELL, and everything else, which is the strip going away.
	func _update_strip(previous: String, state: String) -> void:
		if state == STATE_DOWNLOADING:
			_wax.begin(_crayon_color())
		elif previous == STATE_DOWNLOADING and state == STATE_INSTALLED:
			# The one moment in this overlay worth a little noise. The strip hides
			# itself when the confetti has landed.
			_wax.celebrate()
		elif not _wax.is_celebrating():
			_wax.stop()

	## The crayon this pack gets, picked from the slug so a given book always
	## downloads in the same colour.
	func _crayon_color() -> Color:
		var crayons: Array[Color] = WaxProgress.CRAYON_COLORS
		if crayons.is_empty():
			return Color(0.929412, 0.352941, 0.278431)
		return crayons[absi(get_slug().hash()) % crayons.size()]

	## What KIND of pack this row is (BL-37). The server's word, verbatim; an
	## absent key means books, because every pack published before BL-37 is one.
	func get_kind() -> String:
		var kind := String(_data.get(KEY_KIND, KIND_BOOK)).strip_edges()
		return kind if kind != "" else KIND_BOOK

	func is_sticker_set() -> bool:
		return get_kind() == KIND_STICKER_SET

	## Blurb, what is in it, and size, in the row's resting state.
	##
	## [b]The kind is on the card[/b] (BL-37): "8 stickers" and "12 pages" are
	## different products, and a child pointing at one should get the one they
	## pointed at.
	func _describe() -> String:
		var parts := PackedStringArray()
		var blurb := String(_data.get(KEY_BLURB, "")).strip_edges()
		if blurb != "":
			parts.append(blurb)
		if is_sticker_set():
			var stickers := int(_data.get(KEY_STICKER_COUNT, 0))
			parts.append(
				"%d sticker%s" % [stickers, "" if stickers == 1 else "s"] if stickers > 0
				else "Stickers"
			)
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

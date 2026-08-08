class_name AccountPanel
extends Control
## The grown-up's account overlay: sign in, create an account, sign out
## (DLC_SERVER.md 4.1, 4.2).
##
## [b]It is only ever reached through [AdultGate][/b], which [code]main.gd[/code]
## shows first. Nothing on a kid-facing screen links here and nothing here is ever
## drawn over the colouring page: the entry point is the settings gear on the
## shelf, which is where the grown-up already goes.
##
## [b]Three states, one panel[/b] (the same "a mode of this panel, not a second
## dialog" pattern [SettingsPanel] uses for its erase confirm):
## [codeblock]
## STATE_SIGN_IN   email + password            -> POST /auth/token
## STATE_REGISTER  email + password + guardian -> POST /auth/register, then token
## STATE_SIGNED_IN the account, the sync line, sign out
## [/codeblock]
##
## [b]This is the ONE place in the game where a network failure is visible[/b], and
## deliberately so: DLC_SERVER.md 8.2 says failures are silent to the CHILD and
## surfaced "in the parent/settings panel". A grown-up who typed a password needs
## to know it did not work. Everywhere else -- the shelf, the title, the page -- a
## failure is a debug line and nothing more.
##
## [b]It performs the calls itself rather than signalling up[/b], which is the one
## place this file departs from the project's "signals up, calls down" habit, and
## it is worth being explicit about why: the alternative is [code]main.gd[/code]
## growing a sign-in state machine, which is exactly the "networking in the flow
## orchestrator" that [code]Backend[/code] exists to avoid. What it does NOT do is
## touch [code]GameState[/code], the shelf, or any file: it calls the facade and
## renders the answer.
##
## [b]Nothing here blocks[/b]. While a request is in flight the fields are disabled
## and the button says so; the panel is closable throughout, and closing it does
## not cancel anything important -- the token is written by [Backend] whenever the
## response lands.

## The player closed the panel.
signal closed()
## Sign-in or sign-out changed the state. [code]main.gd[/code] listens so the shelf
## can re-filter and the "More books" affordance can appear or vanish.
signal account_changed(signed_in: bool)

const STATE_SIGN_IN := "sign_in"
const STATE_REGISTER := "register"
const STATE_SIGNED_IN := "signed_in"

## Client-side minimum, matching the server's `Password::default()`. Checked here
## only so an obviously-too-short password does not cost a round trip.
const MIN_PASSWORD_LENGTH := 8

@onready var _scrim: Button = $Scrim
@onready var _header: Label = $Center/Panel/Margin/Column/Header
@onready var _form: VBoxContainer = $Center/Panel/Margin/Column/Form
@onready var _email_field: LineEdit = $Center/Panel/Margin/Column/Form/EmailField
@onready var _password_field: LineEdit = $Center/Panel/Margin/Column/Form/PasswordField
@onready var _guardian_check: CheckBox = $Center/Panel/Margin/Column/Form/GuardianCheck
@onready var _submit_button: Button = $Center/Panel/Margin/Column/Form/SubmitButton
@onready var _toggle_button: Button = $Center/Panel/Margin/Column/Form/ToggleButton
@onready var _account_box: VBoxContainer = $Center/Panel/Margin/Column/Account
@onready var _email_label: Label = $Center/Panel/Margin/Column/Account/EmailLabel
@onready var _sync_label: Label = $Center/Panel/Margin/Column/Account/SyncLabel
@onready var _pictures_check: CheckBox = $Center/Panel/Margin/Column/Account/PicturesCheck
@onready var _device_label: Label = $Center/Panel/Margin/Column/Account/DeviceLabel
@onready var _sign_out_button: Button = $Center/Panel/Margin/Column/Account/SignOutButton
@onready var _status: Label = $Center/Panel/Margin/Column/Status
@onready var _server_label: Label = $Center/Panel/Margin/Column/ServerLabel
@onready var _close_button: Button = $Center/Panel/Margin/Column/CloseButton

var _state := STATE_SIGN_IN
var _busy := false
## BL-48's shared overlay scaler. Held so it is not collected; it parents itself.
var _metrics: OverlayMetrics


func _ready() -> void:
	# BL-48: the two [LineEdit]s are the reason this panel needed the pass most --
	# a sign-in form is the one place in the game a grown-up TYPES, and at a 3x
	# squeeze the fields were 19 pt tall. [OverlayMetrics] gives every interactive
	# control the 44 pt floor, fields included.
	_metrics = OverlayMetrics.attach(self)
	_metrics.applied.connect(_on_overlay_scaled)
	# attach() applies as it enters the tree, before that connection exists.
	_metrics.apply()
	_scrim.pressed.connect(_on_close_pressed)
	_close_button.pressed.connect(_on_close_pressed)
	_submit_button.pressed.connect(_on_submit_pressed)
	_toggle_button.pressed.connect(_on_toggle_pressed)
	_sign_out_button.pressed.connect(_on_sign_out_pressed)
	_pictures_check.toggled.connect(_on_pictures_toggled)
	_password_field.text_submitted.connect(func(_t: String) -> void: _on_submit_pressed())
	_email_field.text_submitted.connect(func(_t: String) -> void: _password_field.grab_focus())
	refresh()


## Re-reads everything from [code]Backend[/code]. Called on open, after any call
## lands, and whenever the parent reopens a panel it kept around.
func refresh() -> void:
	_state = STATE_SIGNED_IN if Backend.is_signed_in() else _state
	if not Backend.is_signed_in() and _state == STATE_SIGNED_IN:
		_state = STATE_SIGN_IN
	_apply_state()


func get_state() -> String:
	return _state


## Switches the form between signing in and creating an account. Public so a
## harness can drive the panel without hunting for a button.
func set_state(state: String) -> void:
	if state == STATE_SIGNED_IN and not Backend.is_signed_in():
		return
	_state = state
	_set_status("")
	_apply_state()


func _apply_state() -> void:
	var signed_in := _state == STATE_SIGNED_IN
	_form.visible = not signed_in
	_account_box.visible = signed_in
	_guardian_check.visible = _state == STATE_REGISTER
	_server_label.text = Backend.get_base_url() if Backend.get_base_url() != "" \
		else "No server configured"

	match _state:
		STATE_REGISTER:
			_header.text = "Create an account"
			_submit_button.text = "Create account"
			_toggle_button.text = "I already have an account"
		STATE_SIGNED_IN:
			_header.text = "Account"
			_email_label.text = Backend.get_account_email()
			# The one place sync is ever mentioned to anybody (DLC_SERVER.md 8.2:
			# failures are silent to the CHILD and surface, if at all, here).
			_sync_label.text = Backend.get_sync_status_text()
			_pictures_check.set_pressed_no_signal(Backend.is_picture_sync_enabled())
			_device_label.text = "This device: %s" % Backend.get_auth_store().get_device_name()
		_:
			_header.text = "Sign in"
			_submit_button.text = "Sign in"
			_toggle_button.text = "Create an account"

	if not signed_in and Backend.is_token_expired():
		# The only place the lapsed-token state is ever mentioned (DLC_SERVER.md 4.2).
		_set_status("Signed out — this device's sign-in expired.")
	_set_busy(_busy)


# ==================================================================== the calls ==

func _on_submit_pressed() -> void:
	if _busy:
		return
	var email := _email_field.text.strip_edges()
	var password := _password_field.text
	if email == "" or not "@" in email:
		_set_status("Please enter the grown-up's email address.")
		return
	if password.length() < MIN_PASSWORD_LENGTH:
		_set_status("The password needs at least %d characters." % MIN_PASSWORD_LENGTH)
		return
	if _state == STATE_REGISTER and not _guardian_check.button_pressed:
		_set_status("Please confirm you are the parent or guardian.")
		return

	_set_busy(true)
	_set_status("Contacting the server…")
	var result: Dictionary
	if _state == STATE_REGISTER:
		result = await Backend.register(email, password, true)
	else:
		result = await Backend.sign_in(email, password)
	_set_busy(false)
	if not is_inside_tree():
		return

	if bool(result.get(Backend.KEY_OK, false)) and Backend.is_signed_in():
		_password_field.text = ""
		_state = STATE_SIGNED_IN
		_apply_state()
		_set_status("")
		account_changed.emit(true)
		return
	_apply_state()
	_set_status(describe_error(result))


func _on_sign_out_pressed() -> void:
	if _busy:
		return
	_set_busy(true)
	await Backend.sign_out()
	_set_busy(false)
	if not is_inside_tree():
		return
	_state = STATE_SIGN_IN
	_password_field.text = ""
	_apply_state()
	# Signing out always succeeds locally, even offline -- see Backend.sign_out().
	_set_status("Signed out on this device.")
	account_changed.emit(false)


## DLC_SERVER.md 6.2 wants paint uploaded "only on unmetered connections by
## default". Godot cannot tell a metered connection from an unmetered one on any
## platform this game ships to, so the policy is this checkbox -- behind the adult
## gate, where a data-plan decision belongs -- and the caveat is written down in
## [method SyncQueue.is_picture_sync_enabled]. Progress (~200 bytes a book) always
## syncs; this is only the 0.5-2 MB pictures.
func _on_pictures_toggled(enabled: bool) -> void:
	Backend.set_picture_sync_enabled(enabled)


func _on_toggle_pressed() -> void:
	set_state(STATE_SIGN_IN if _state == STATE_REGISTER else STATE_REGISTER)


## Turns a backend result into something a grown-up can act on. Branches on the
## machine-readable [code]code[/code], never on the server's prose
## (DLC_SERVER.md 11) -- the server's own message is the fallback, not the source.
static func describe_error(result: Dictionary) -> String:
	var code := String(result.get(Backend.KEY_CODE, ""))
	var message := String(result.get(Backend.KEY_MESSAGE, ""))
	match code:
		ApiClient.CODE_OFFLINE:
			return "Could not reach the server. The game works fine without it."
		ApiClient.CODE_TIMEOUT:
			return "The server took too long to answer. Try again in a moment."
		ApiClient.CODE_INVALID_CREDENTIALS:
			return "That email and password did not match."
		ApiClient.CODE_UNAUTHENTICATED:
			return "This device's sign-in has expired. Please sign in again."
		ApiClient.CODE_THROTTLED:
			return "Too many tries. Please wait a minute."
		ApiClient.CODE_VALIDATION:
			return message if message != "" else "Please check the details and try again."
		"":
			return "" if bool(result.get(Backend.KEY_OK, false)) else "Accounts are switched off in this build."
	return message if message != "" else "Something went wrong (%s)." % code


# ===================================================================== display ==

func _set_busy(busy: bool) -> void:
	_busy = busy
	_email_field.editable = not busy
	_password_field.editable = not busy
	_submit_button.disabled = busy
	_toggle_button.disabled = busy
	_sign_out_button.disabled = busy
	_guardian_check.disabled = busy
	_pictures_check.disabled = busy


func _set_status(text: String) -> void:
	_status.text = text
	_status.visible = text != ""


## BL-48: the signed-in email is one long unbreakable token, exactly like the
## settings panel's, and gets the same treatment.
func _on_overlay_scaled(_scale: float, portrait: bool) -> void:
	OverlayMetrics.fit_long_text(_email_label, portrait)


func _on_close_pressed() -> void:
	closed.emit()


# ====================================================================== access ==

func get_email_field() -> LineEdit:
	return _email_field


func get_password_field() -> LineEdit:
	return _password_field


func get_guardian_check() -> CheckBox:
	return _guardian_check


func get_submit_button() -> Button:
	return _submit_button


func get_toggle_button() -> Button:
	return _toggle_button


func get_sign_out_button() -> Button:
	return _sign_out_button


func get_close_button() -> Button:
	return _close_button


func get_status_text() -> String:
	return _status.text if _status.visible else ""


func get_sync_text() -> String:
	return _sync_label.text


func get_pictures_check() -> CheckBox:
	return _pictures_check


func is_busy() -> bool:
	return _busy


## The label the signed-in address is written into (BL-48's harness measures it).
func get_email_label() -> Label:
	return _email_label


## BL-48's shared scaler, for the harnesses.
func get_overlay_metrics() -> OverlayMetrics:
	return _metrics

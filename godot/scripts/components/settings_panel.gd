class_name SettingsPanel
extends Control
## The settings overlay: the account, erase progress, read the version.
##
## [b]An overlay, not a screen[/b]. [code]main.tscn[/code] owns it and puts it on
## top of whatever screen is showing, which is why it is in
## [code]scenes/components/[/code]: it composes into a parent rather than
## replacing one.
##
## [b]BL-20 removed the mode row.[/b] There is one palette for everyone now
## (DESIGN.md 1), so the panel shows WHICH palette the game paints with and offers
## nothing to change about it.
##
## [b]It never writes anything.[/b] Erasing progress is a signal
## ([signal erase_all_confirmed]) that the parent turns into a
## [code]GameState.erase_all_progress()[/code] call. Signals up, calls down, no
## exceptions for settings.
##
## [b]The confirm step is a mode of this panel[/b], not a second dialog:
## "Erase all progress" swaps the button for a confirm row and back again. One
## node, no popup windows (which behave badly on mobile), and the destructive
## action is never one tap away.

## The player closed the panel.
signal closed()
## The player confirmed the destructive erase.
signal erase_all_confirmed()
## The grown-up tapped "Account" (WP10). The parent puts the [AdultGate] in front
## of it and only then the [AccountPanel] -- this panel never opens an account
## screen itself, and never speaks to the network.
signal account_requested()

## Where the version string comes from (set in project.godot).
const VERSION_SETTING := "application/config/version"
## Milestone tag shown next to the version, so a build is identifiable on a device.
const BUILD_TAG := "M5"
## Seconds the "erased" acknowledgement stays up.
const ACK_SECONDS := 2.2


@onready var _scrim: Button = $Scrim
@onready var _palette_value: Label = $Center/Panel/Margin/Column/PaletteRow/PaletteValue
@onready var _account_value: Label = $Center/Panel/Margin/Column/AccountRow/AccountValue
@onready var _account_button: Button = $Center/Panel/Margin/Column/AccountRow/AccountButton
@onready var _erase_button: Button = $Center/Panel/Margin/Column/EraseButton
@onready var _confirm_box: VBoxContainer = $Center/Panel/Margin/Column/ConfirmBox
@onready var _confirm_button: Button = $Center/Panel/Margin/Column/ConfirmBox/Row/ConfirmButton
@onready var _cancel_button: Button = $Center/Panel/Margin/Column/ConfirmBox/Row/CancelButton
@onready var _status: Label = $Center/Panel/Margin/Column/Status
@onready var _version_label: Label = $Center/Panel/Margin/Column/VersionLabel
@onready var _close_button: Button = $Center/Panel/Margin/Column/CloseButton


func _ready() -> void:
	_scrim.pressed.connect(_on_close_pressed)
	_close_button.pressed.connect(_on_close_pressed)
	_account_button.pressed.connect(func() -> void: account_requested.emit())
	_erase_button.pressed.connect(_on_erase_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_confirm_button.pressed.connect(_on_confirm_pressed)
	_confirm_box.visible = false
	_status.visible = false
	refresh()


## Re-reads everything the panel displays. Called on open, so a panel that was
## kept around shows current values.
func refresh() -> void:
	var palette := GameState.get_active_palette()
	_palette_value.text = palette.display_name if palette != null else "?"
	# WP10: the account row reads Backend, which is inert (and therefore reads
	# "Not signed in") whenever there is no account or no server configured. This
	# panel still never talks to the network itself.
	var signed_in := Backend.is_signed_in()
	_account_value.text = Backend.get_account_email() if signed_in else "Not signed in"
	_account_button.text = "Manage" if signed_in else "Sign in"
	_account_button.visible = Backend.is_enabled()
	_version_label.text = "ColoringBook %s (%s)" % [
		String(ProjectSettings.get_setting(VERSION_SETTING, "0.0.0")), BUILD_TAG
	]
	set_confirming(false)


# ==================================================================== confirm ==

## Shows or hides the confirm row. Public so the parent can reset the panel
## between openings and tests can assert the two-step guard.
func set_confirming(confirming: bool) -> void:
	_confirm_box.visible = confirming
	_erase_button.visible = not confirming


func is_confirming() -> bool:
	return _confirm_box.visible


func _on_erase_pressed() -> void:
	_status.visible = false
	set_confirming(true)


func _on_cancel_pressed() -> void:
	set_confirming(false)


func _on_confirm_pressed() -> void:
	set_confirming(false)
	erase_all_confirmed.emit()
	_acknowledge("Progress erased.")


func _acknowledge(text: String) -> void:
	_status.text = text
	_status.visible = true
	_status.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(ACK_SECONDS * 0.6)
	tween.tween_property(_status, "modulate:a", 0.0, ACK_SECONDS * 0.4)
	tween.tween_callback(func() -> void: _status.visible = false)


func _on_close_pressed() -> void:
	closed.emit()


# ===================================================================== access ==

func get_account_button() -> Button:
	return _account_button


func get_account_text() -> String:
	return _account_value.text


func get_erase_button() -> Button:
	return _erase_button


func get_confirm_button() -> Button:
	return _confirm_button


func get_cancel_button() -> Button:
	return _cancel_button


func get_close_button() -> Button:
	return _close_button


## The palette the game paints with, as shown. There is exactly one (BL-20).
func get_palette_text() -> String:
	return _palette_value.text


func get_version_text() -> String:
	return _version_label.text

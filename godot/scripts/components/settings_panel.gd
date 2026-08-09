class_name SettingsPanel
extends Control
## The settings overlay: restore purchases, erase progress, read the version.
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
##
## [b]BL-48 sized it for a phone[/b] with [OverlayMetrics], which every overlay in
## the game shares. Two things here are this panel's own business rather than the
## shared mechanism's:
## [codeblock]
## the purchases row  a plain BoxContainer, so portrait stacks caption / value /
##                    button instead of squeezing three things onto 390 pt of phone
## the value          AUTOWRAP_ARBITRARY in portrait, so a long line wraps rather
##                    than clipping to an ellipsis
## [/codeblock]

## The player closed the panel.
signal closed()
## The player confirmed the destructive erase.
signal erase_all_confirmed()
## The grown-up tapped "Restore". The parent puts the [AdultGate] in front of it and
## only then runs the restore -- this panel never speaks to the network itself, for
## the same "signals up, calls down" reason it never writes the save.
signal restore_requested()

## Where the version string comes from (set in project.godot).
const VERSION_SETTING := "application/config/version"
## Milestone tag shown next to the version, so a build is identifiable on a device.
const BUILD_TAG := "M5"
## Seconds the "erased" acknowledgement stays up.
const ACK_SECONDS := 2.2


@onready var _scrim: Button = $Scrim
@onready var _palette_value: Label = $Center/Panel/Margin/Column/PaletteRow/PaletteValue
@onready var _purchases_value: Label = $Center/Panel/Margin/Column/PurchasesRow/PurchasesValue
@onready var _restore_button: Button = $Center/Panel/Margin/Column/PurchasesRow/PurchasesButton
@onready var _erase_button: Button = $Center/Panel/Margin/Column/EraseButton
@onready var _confirm_box: VBoxContainer = $Center/Panel/Margin/Column/ConfirmBox
@onready var _confirm_button: Button = $Center/Panel/Margin/Column/ConfirmBox/Row/ConfirmButton
@onready var _cancel_button: Button = $Center/Panel/Margin/Column/ConfirmBox/Row/CancelButton
@onready var _status: Label = $Center/Panel/Margin/Column/Status
@onready var _version_label: Label = $Center/Panel/Margin/Column/VersionLabel
@onready var _close_button: Button = $Center/Panel/Margin/Column/CloseButton

## BL-48. Held so it is not collected; it parents itself to this node.
var _metrics: OverlayMetrics


func _ready() -> void:
	_metrics = OverlayMetrics.attach(self)
	_metrics.applied.connect(_on_overlay_scaled)
	# attach() applies once as it enters the tree, which is BEFORE the line above
	# could hear it -- so ask again rather than start a frame out of step.
	_metrics.apply()
	_scrim.pressed.connect(_on_close_pressed)
	_close_button.pressed.connect(_on_close_pressed)
	_restore_button.pressed.connect(func() -> void: restore_requested.emit())
	_erase_button.pressed.connect(_on_erase_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_confirm_button.pressed.connect(_on_confirm_pressed)
	_confirm_box.visible = false
	_status.visible = false
	refresh()


## Re-reads everything the panel displays. Called on open, so a panel that was
## kept around shows current values.
##
## [b]The purchases row never mentions an identity[/b], because there is not one a
## grown-up could act on: the app signs this device in by itself and the row's job
## is only to say what the device owns and offer to go and ask the store again.
## The whole row hides in a build with no server, where there is nothing to buy and
## nothing to restore.
func refresh() -> void:
	var palette := GameState.get_active_palette()
	_palette_value.text = palette.display_name if palette != null else "?"
	var owned := Backend.get_entitlements().size()
	_purchases_value.text = "Nothing bought yet" if owned == 0 \
		else "%d pack%s on this device" % [owned, "" if owned == 1 else "s"]
	_restore_button.visible = Backend.is_enabled()
	_purchases_value.get_parent().visible = Backend.is_enabled()
	_version_label.text = "ColoringBook %s (%s)" % [
		String(ProjectSettings.get_setting(VERSION_SETTING, "0.0.0")), BUILD_TAG
	]
	set_confirming(false)


## Reports what a restore did, in the panel's own status line. Called by the parent
## after [signal restore_requested] has been through the adult gate and the network
## -- [b]the one place in the game a backend result is ever shown to anybody[/b]
## outside the pack shop, and only ever to a grown-up who asked for it.
func report_restore(restored: int, ok: bool, message: String = "") -> void:
	refresh()
	if not ok:
		_acknowledge(message if message != "" else "Could not reach the store. Try again later.")
		return
	_acknowledge("Nothing to restore." if restored == 0
		else "Restored %d purchase%s." % [restored, "" if restored == 1 else "s"])


## BL-48: the one thing the shared scaler cannot do for this panel. In portrait the
## purchases row has already been stacked by [OverlayMetrics] (it is a plain
## [BoxContainer]), so its value has the whole panel width to itself and there is
## no reason left to clip it.
func _on_overlay_scaled(_scale: float, portrait: bool) -> void:
	OverlayMetrics.fit_long_text(_purchases_value, portrait)
	# The palette value is pushed to the far margin because it is the RIGHT-HAND end
	# of a row. Stacked, there is no right-hand end, and a right-aligned value above
	# a left-aligned email looks like two different bugs rather than one layout.
	_palette_value.horizontal_alignment = (
		HORIZONTAL_ALIGNMENT_LEFT if portrait else HORIZONTAL_ALIGNMENT_RIGHT
	)


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

func get_restore_button() -> Button:
	return _restore_button


func get_purchases_text() -> String:
	return _purchases_value.text


## The label the purchases line is written into. BL-48's harness measures it, and it
## is the one control on this panel whose CONTENT can be too long for its box.
func get_purchases_label() -> Label:
	return _purchases_value


## BL-48's shared scaler, so a harness can read the live scale and touch floor off
## the same object the panel sized itself from.
func get_overlay_metrics() -> OverlayMetrics:
	return _metrics


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

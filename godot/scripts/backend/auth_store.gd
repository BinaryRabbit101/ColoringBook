class_name AuthStore
extends RefCounted
## The device's identity and its bearer token, on disk at [constant AUTH_PATH].
##
## [b]There is exactly ONE identity, and the player never sees it.[/b] The app has
## no accounts, no sign-in screen and no linking: on startup [Backend] posts this
## installation's [member _device_uid] to [code]/device/register[/code] and is
## handed a token back. A device the server has never met is created on the spot.
## So the only two states this class has are "we have a live token" and "we do not
## have one yet", and the second is not an error -- it is a device that has not
## reached the server since it was installed.
## [codeblock]
## device_uid   a client-generated ULID, minted once and NEVER regenerated.
##              It is the identity: the server's find-or-create keys on it, and
##              re-registering with the same uid answers for the same row, which
##              is what makes a token refresh idempotent and a purchase durable.
## token        entitlements:read + packs:download, and nothing else. There is
##              nothing destructive it can reach, which is what lets it be
##              re-minted silently on any 401.
## [/codeblock]
##
## [b]The [code]user://[/code] boundary.[/b] [code]GameState[/code] owns all of
## [code]user://[/code] with exactly two carve-outs, both of them Backend's:
## [code]user://auth.json[/code] (this class) and [code]user://dlc/[/code]
## ([PackInstaller] and [EntitlementsStore]). Nothing here ever touches the save
## file, the paint layers or any progress -- a token is a property of the DEVICE,
## not of the player's colouring, and the game is fully playable with this file
## absent, deleted or unreadable.
##
## [b]This is not secure storage[/b] on any platform we ship -- assume the token is
## readable. The mitigations are server-side: the token carries only
## [code]entitlements:read[/code] / [code]packs:download[/code], it is scoped to one
## device row, and it expires. Nothing destructive is reachable with it, and the
## worst an attacker earns by stealing a [code]device_uid[/code] is a fresh empty
## identity of their own.
##
## [b]An expired or rejected token is never a screen[/b]: [Backend] re-registers in
## the background and retries, and if that fails the app is simply offline for the
## session (free and already-installed packs keep working).
##
## Plain [RefCounted]: no nodes, no tree, so it is testable on its own.

## Where the credentials live. Backend's, not [code]GameState[/code]'s.
const AUTH_PATH := "user://auth.json"
## Schema version of that file. A file from a NEWER build is ignored rather than
## misread; the cost is one silent re-registration, not a corrupt token.
##
## v2 is the device-only shape. A v1 file (the accounts era) still has its
## [code]device_uid[/code] read out of it -- that uid IS the installation and
## throwing it away would cost the device its purchases -- while its account token,
## its email and its anonymous-tier keys are dropped on the floor, because the
## routes that minted them no longer exist.
const SCHEMA_VERSION := 2

## Crockford base32, the ULID alphabet (no I, L, O or U).
const ULID_ALPHABET := "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

## Treat a token as already expired this many seconds before it really is, so a
## request is not fired at a token that dies in flight.
const EXPIRY_SKEW_SECONDS := 60.0

## Client-generated ULID identifying THIS installation to the server. Generated
## once, on first use, and then never changed: it is what the device's
## entitlements hang off.
var _device_uid := ""
var _device_name := ""
var _token := ""
var _abilities: PackedStringArray = PackedStringArray()
## Unix seconds, or 0 for "the server did not say" (treated as non-expiring).
var _expires_at := 0

var _path := AUTH_PATH
var _loaded := false


func _init(path: String = AUTH_PATH) -> void:
	_path = path


# ================================================================== accessors ==

## True when there is a token on disk at all -- expired or not.
func has_token() -> bool:
	_ensure_loaded()
	return _token != ""


## True when there is a token AND it has not expired. Everything that would put a
## bearer header on a request checks THIS.
func is_signed_in() -> bool:
	return has_token() and not is_expired()


func is_expired() -> bool:
	_ensure_loaded()
	if _token == "" or _expires_at <= 0:
		return _token == ""
	return float(Time.get_unix_time_from_system()) >= float(_expires_at) - EXPIRY_SKEW_SECONDS


func get_token() -> String:
	_ensure_loaded()
	return _token


## The token only when it is usable; "" when there is none or it has expired, so a
## caller cannot accidentally send a dead bearer.
func get_live_token() -> String:
	return _token if is_signed_in() else ""


func get_abilities() -> PackedStringArray:
	_ensure_loaded()
	return _abilities.duplicate()


func has_ability(ability: String) -> bool:
	return ability in get_abilities()


func get_expires_at() -> int:
	_ensure_loaded()
	return _expires_at


## The stable per-installation id sent as [code]device_uid[/code]. Generated and
## PERSISTED on first read, so a device that re-registers a hundred times is still
## one row on the server rather than a hundred.
func get_device_uid() -> String:
	_ensure_loaded()
	if _device_uid == "":
		_device_uid = new_ulid()
		_write()
	return _device_uid


## A human label for the server's device list. Never PII we asked for: it is
## whatever the OS already calls this machine.
func get_device_name() -> String:
	_ensure_loaded()
	if _device_name != "":
		return _device_name
	return default_device_name()


## What [method get_device_name] falls back to: the phone/tablet model on mobile,
## the hostname on desktop, the platform name if neither is available.
static func default_device_name() -> String:
	var model := OS.get_model_name()
	if model != "" and model != "GenericDevice":
		return model
	var host := OS.get_environment("COMPUTERNAME")
	if host == "":
		host = OS.get_environment("HOSTNAME")
	if host != "":
		return host
	return OS.get_name()


# =================================================================== mutation ==

## Records a successful [code]POST /device/register[/code]. [param expires_at] is a
## unix timestamp; 0 means the server did not set one.
func store_token(token: String, abilities: PackedStringArray, expires_at: int,
		device_name: String = "") -> void:
	_ensure_loaded()
	_token = token
	_abilities = abilities.duplicate()
	_expires_at = expires_at
	if device_name != "":
		_device_name = device_name
	if _device_uid == "":
		_device_uid = new_ulid()
	_write()


## Drops the token after the server refused it, [b]keeping the device uid[/b]: the
## installation is the same installation, and re-registering under the same uid is
## precisely what earns the same entitlements back.
func clear_token() -> void:
	_ensure_loaded()
	if _token == "" and _abilities.is_empty() and _expires_at == 0:
		return
	_token = ""
	_abilities = PackedStringArray()
	_expires_at = 0
	_write()


## Removes the file entirely (dev harnesses and "delete my data"). The next read
## starts from nothing, [b]device uid included[/b] -- which means the next
## registration mints a brand new identity that owns nothing.
func erase() -> void:
	_token = ""
	_abilities = PackedStringArray()
	_expires_at = 0
	_device_uid = ""
	_device_name = ""
	_loaded = true
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(_path)


func get_path() -> String:
	return _path


# ======================================================================= disk ==

func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_read()


func _read() -> void:
	if not FileAccess.file_exists(_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("AuthStore: '%s' is not a JSON object; this device will re-register." % _path)
		return
	var data := parsed as Dictionary
	var version := int(data.get("version", 0))
	if version > SCHEMA_VERSION:
		# A downgrade. Read nothing rather than misread a shape we do not know; the
		# file is left alone so the newer build still has its token.
		push_warning("AuthStore: '%s' is schema v%d, newer than v%d; ignoring it."
			% [_path, version, SCHEMA_VERSION])
		return
	# The uid is read from EVERY readable version, including the accounts-era v1:
	# it is the installation's identity and a new one would own nothing.
	_device_uid = String(data.get("device_uid", ""))
	_device_name = String(data.get("device_name", ""))
	if version < SCHEMA_VERSION:
		# A v1 file's token belongs to routes that no longer exist. Leave it behind
		# and let the first /device/register of this run mint the real one.
		return
	_token = String(data.get("token", ""))
	_expires_at = int(data.get("expires_at", 0))
	_abilities = PackedStringArray()
	for ability: Variant in data.get("abilities", []):
		_abilities.append(String(ability))


func _write() -> void:
	var payload := {
		"version": SCHEMA_VERSION,
		"device_uid": _device_uid,
		"device_name": _device_name,
		"token": _token,
		"abilities": Array(_abilities),
		"expires_at": _expires_at,
	}
	var directory := _path.get_base_dir()
	if directory != "" and not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		push_warning("AuthStore: could not write '%s' (%d)." % [_path, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()


# ======================================================================= ULID ==

## A ULID: 10 characters of millisecond timestamp then 16 of randomness, Crockford
## base32, upper case. Sortable, collision-free in practice, and -- unlike a UUID --
## unambiguous next to the server's lower-case slugs.
static func new_ulid() -> String:
	var out := ""
	var time_ms := int(Time.get_unix_time_from_system() * 1000.0)
	for i in 10:
		out = ULID_ALPHABET[time_ms & 31] + out
		time_ms >>= 5
	for i in 16:
		out += ULID_ALPHABET[randi() % 32]
	return out

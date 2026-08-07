class_name AuthStore
extends RefCounted
## The device's account credentials, on disk at [constant AUTH_PATH]
## (DLC_SERVER.md 4.2).
##
## [b]The user:// boundary.[/b] [code]GameState[/code] owns all of
## [code]user://[/code] with exactly two carve-outs, both of them Backend's:
## [code]user://auth.json[/code] (this class) and [code]user://dlc/[/code]
## ([PackInstaller] and [EntitlementsStore]). Nothing here ever touches the save
## file, the paint layers or any progress: an account is a property of the DEVICE,
## not of the player's colouring, and the game is fully playable with this file
## absent.
##
## [b]This is not secure storage[/b] on any platform we ship (DLC_SERVER.md 4.2) --
## assume the token is readable. The mitigations are server-side: the token carries
## only the [code]save:sync[/code] / [code]entitlements:read[/code] /
## [code]packs:download[/code] abilities, it is revocable per device from the parent
## dashboard, and it expires. Nothing destructive is reachable with it.
##
## [b]An expired token means OFFLINE, silently[/b] (DLC_SERVER.md 8.2). It is never
## a modal, never a screen, never anything a child sees: [method is_signed_in] goes
## false, every Backend call that needs a token becomes a no-op, and the grown-up
## finds out the next time they open the account panel.
##
## Plain [RefCounted]: no nodes, no tree, so it is testable on its own.

## Where the credentials live. Backend's, not [code]GameState[/code]'s.
const AUTH_PATH := "user://auth.json"
## Schema version of that file. A file from a newer build is IGNORED (treated as
## signed out) rather than misread -- the cost is one sign-in, not a corrupt token.
const SCHEMA_VERSION := 1

## Crockford base32, the ULID alphabet (no I, L, O or U).
const ULID_ALPHABET := "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

## Treat a token as already expired this many seconds before it really is, so a
## request is not fired at a token that dies in flight.
const EXPIRY_SKEW_SECONDS := 60.0

var _version := SCHEMA_VERSION
## Client-generated ULID identifying THIS installation to the server
## (DLC_SERVER.md 4.2). Generated once, on first use, and then never changes: it
## is what the parent dashboard's "revoke this device" row is.
var _device_uid := ""
var _device_name := ""
var _email := ""
var _token := ""
var _abilities: PackedStringArray = PackedStringArray()
## Unix seconds, or 0 for "the server did not say" (treated as non-expiring).
var _expires_at := 0
## Free-form room for WP11's sync cursor. Written back verbatim so a later build
## adding a field cannot be clobbered by this one.
var _extra: Dictionary = {}

var _path := AUTH_PATH
var _loaded := false


func _init(path: String = AUTH_PATH) -> void:
	_path = path


# ================================================================== accessors ==

## True when there is a token on disk at all -- expired or not. The account panel
## uses this to tell "never signed in" from "signed in, but the token lapsed".
func has_account() -> bool:
	_ensure_loaded()
	return _token != ""


## True when there is a token AND it has not expired. Everything that would put a
## bearer header on a request checks THIS.
func is_signed_in() -> bool:
	return has_account() and not is_expired()


func is_expired() -> bool:
	_ensure_loaded()
	if _token == "" or _expires_at <= 0:
		return _token == ""
	return float(Time.get_unix_time_from_system()) >= float(_expires_at) - EXPIRY_SKEW_SECONDS


func get_token() -> String:
	_ensure_loaded()
	return _token


## The token only when it is usable; "" when signed out or expired, so a caller
## cannot accidentally send a dead bearer.
func get_live_token() -> String:
	return _token if is_signed_in() else ""


func get_email() -> String:
	_ensure_loaded()
	return _email


func get_abilities() -> PackedStringArray:
	_ensure_loaded()
	return _abilities.duplicate()


func has_ability(ability: String) -> bool:
	return ability in get_abilities()


func get_expires_at() -> int:
	_ensure_loaded()
	return _expires_at


## The stable per-installation id sent as [code]device_uid[/code]. Generated and
## PERSISTED on first read, so a device that signs in, out and in again is still
## one row on the server rather than three.
func get_device_uid() -> String:
	_ensure_loaded()
	if _device_uid == "":
		_device_uid = new_ulid()
		_write()
	return _device_uid


## A human label for the parent dashboard's device list. Never PII we asked for:
## it is whatever the OS already calls this machine.
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


func get_extra(key: String, fallback: Variant = null) -> Variant:
	_ensure_loaded()
	return _extra.get(key, fallback)


## WP11's hook: the sync client stores its cursor / "last synced" stamp here so it
## does not need a file of its own.
func set_extra(key: String, value: Variant) -> void:
	_ensure_loaded()
	_extra[key] = value
	_write()


# =================================================================== mutation ==

## Records a successful [code]POST /auth/token[/code]. [param expires_at] is a
## unix timestamp; 0 means the server did not set one.
func store_token(token: String, email: String, abilities: PackedStringArray,
		expires_at: int, device_name: String = "") -> void:
	_ensure_loaded()
	_token = token
	_email = email
	_abilities = abilities.duplicate()
	_expires_at = expires_at
	if device_name != "":
		_device_name = device_name
	if _device_uid == "":
		_device_uid = new_ulid()
	_write()


## Slides the expiry after a successful refresh (DLC_SERVER.md 4.2: 90 days
## sliding, refreshed on any successful call).
func slide_expiry(expires_at: int) -> void:
	_ensure_loaded()
	if expires_at <= 0 or _token == "":
		return
	_expires_at = expires_at
	_write()


## Forgets the account. Keeps [member _device_uid] on purpose -- the installation
## is the same installation, and reusing its id is what stops a family tablet from
## accumulating a dashboard row per sign-in.
func clear() -> void:
	_ensure_loaded()
	_token = ""
	_email = ""
	_abilities = PackedStringArray()
	_expires_at = 0
	_extra.clear()
	_write()


## Removes the file entirely (dev harnesses and "delete my data"). The next read
## starts from nothing, device uid included.
func erase() -> void:
	_token = ""
	_email = ""
	_abilities = PackedStringArray()
	_expires_at = 0
	_device_uid = ""
	_device_name = ""
	_extra.clear()
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
		push_warning("AuthStore: '%s' is not a JSON object; treating this device as signed out." % _path)
		return
	var data := parsed as Dictionary
	var version := int(data.get("version", 0))
	if version > SCHEMA_VERSION:
		# A downgrade. Read nothing rather than misread a shape we do not know;
		# the file is left alone so the newer build still has its token.
		push_warning("AuthStore: '%s' is schema v%d, newer than v%d; ignoring it."
			% [_path, version, SCHEMA_VERSION])
		return
	_version = version
	_device_uid = String(data.get("device_uid", ""))
	_device_name = String(data.get("device_name", ""))
	_email = String(data.get("email", ""))
	_token = String(data.get("token", ""))
	_expires_at = int(data.get("expires_at", 0))
	_abilities = PackedStringArray()
	for ability: Variant in data.get("abilities", []):
		_abilities.append(String(ability))
	var extra: Variant = data.get("extra", {})
	_extra = (extra as Dictionary) if typeof(extra) == TYPE_DICTIONARY else {}


func _write() -> void:
	var payload := {
		"version": SCHEMA_VERSION,
		"device_uid": _device_uid,
		"device_name": _device_name,
		"email": _email,
		"token": _token,
		"abilities": Array(_abilities),
		"expires_at": _expires_at,
		"extra": _extra,
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
## base32, upper case (DLC_SERVER.md 4.2). Sortable, collision-free in practice,
## and -- unlike a UUID -- unambiguous next to the server's lower-case slugs.
static func new_ulid() -> String:
	var out := ""
	var time_ms := int(Time.get_unix_time_from_system() * 1000.0)
	for i in 10:
		out = ULID_ALPHABET[time_ms & 31] + out
		time_ms >>= 5
	for i in 16:
		out += ULID_ALPHABET[randi() % 32]
	return out

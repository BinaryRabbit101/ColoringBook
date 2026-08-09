class_name AuthStore
extends RefCounted
## The device's credentials, on disk at [constant AUTH_PATH] (DLC_SERVER.md 4.2,
## 4.3).
##
## [b]TWO identities live in this one file[/b] (BL-52), and the whole point of the
## class is that they are never confused for each other:
## [codeblock]
## the ACCOUNT token       a grown-up signed in; carries save:sync
## the ANONYMOUS token     POST /device/register minted it for this installation;
##                         carries entitlements:read + packs:download and NEVER
##                         save:sync -- an anonymous device can own packs, it can
##                         never upload a child's artwork
## [/codeblock]
## [method get_live_token] means what it always meant -- the ACCOUNT token -- and
## everything save-sync keys off it, so an anonymous token cannot switch sync on
## (it would 403 forever on an ability it was never issued). Ownership questions
## ask [method get_entitlement_token] instead, which is the account token when
## there is one and the anonymous token otherwise.
##
## [b]One device_uid serves both[/b] ([method get_device_uid]): registering
## anonymously and later signing in are the same installation, which is exactly
## what lets the server ADOPT the anonymous row's entitlements into the account
## instead of leaving a household owning a pack twice.
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
##
## [b]BL-52 added three keys and deliberately did NOT bump this.[/b] The version
## gate is a DOWNGRADE guard, and bumping it would mean an older build finding a v2
## file and treating a perfectly good account as signed out -- a real sign-in the
## grown-up has to redo, traded for nothing. The new keys are purely additive and
## optional: an older build ignores them on read and drops them on write, which
## costs at worst one silent re-registration of a token that was free to mint.
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

## BL-52's second identity: the anonymous device token, or "". Kept in named
## fields rather than in [member _extra] because [method clear] wipes the extras
## and this is not sync bookkeeping -- it is a credential, with its own lifetime.
var _anon_token := ""
var _anon_abilities: PackedStringArray = PackedStringArray()
var _anon_expires_at := 0

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


# ------------------------------------- the anonymous device tier (BL-52) --
# DLC_SERVER.md 4.3. A token minted on the DEVICE ROW rather than on a user, so a
# tablet nobody has signed in on can still own the pack a grown-up paid for.
#
# It is stored beside the account token and is never a substitute for it: the only
# question it answers is "what does this installation own", and the accessor that
# reaches for it ([method get_entitlement_token]) is deliberately a different one
# from [method get_live_token].

## True when this installation has registered anonymously -- expired or not.
func has_anonymous_token() -> bool:
	_ensure_loaded()
	return _anon_token != ""


func is_anonymous_expired() -> bool:
	_ensure_loaded()
	if _anon_token == "" or _anon_expires_at <= 0:
		return _anon_token == ""
	return float(Time.get_unix_time_from_system()) \
		>= float(_anon_expires_at) - EXPIRY_SKEW_SECONDS


## The anonymous token only while it is usable, "" otherwise -- the mirror of
## [method get_live_token], and dead for the same reasons.
func get_live_anonymous_token() -> String:
	return _anon_token if (has_anonymous_token() and not is_anonymous_expired()) else ""


func get_anonymous_abilities() -> PackedStringArray:
	_ensure_loaded()
	return _anon_abilities.duplicate()


func get_anonymous_expires_at() -> int:
	_ensure_loaded()
	return _anon_expires_at


## [b]The ownership accessor[/b] (BL-52): the account token when a grown-up is
## signed in, the anonymous one when they are not, "" when neither is usable.
##
## Catalogue [code]owned[/code] painting, [code]GET /entitlements[/code],
## [code]POST /entitlements/verify[/code] and a PAID pack's download all ask this.
## [b]Nothing save-sync may[/b] -- see [method get_live_token], and the note at the
## top of the class about the ability the anonymous token was never issued.
func get_entitlement_token() -> String:
	var account := get_live_token()
	return account if account != "" else get_live_anonymous_token()


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


## Records a successful [code]POST /device/register[/code] (BL-52,
## DLC_SERVER.md 4.3). [param expires_at] is a unix timestamp; 0 means the server
## did not set one.
func store_anonymous_token(token: String, abilities: PackedStringArray,
		expires_at: int) -> void:
	_ensure_loaded()
	_anon_token = token
	_anon_abilities = abilities.duplicate()
	_anon_expires_at = expires_at
	if _device_uid == "":
		_device_uid = new_ulid()
	_write()


## Forgets the anonymous identity. Called when a grown-up signs in: the server
## ADOPTED this device's entitlements into the account and revoked its tokens in
## the same transaction, so keeping the string locally would only leave a dead
## credential lying about where a later reader might reach for it.
func clear_anonymous_token() -> void:
	_ensure_loaded()
	if _anon_token == "" and _anon_abilities.is_empty() and _anon_expires_at == 0:
		return
	_anon_token = ""
	_anon_abilities = PackedStringArray()
	_anon_expires_at = 0
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
##
## The anonymous token goes too (BL-52). Signing out drops back to the anonymous
## tier, but not to THIS device's old anonymous token: adoption revoked it on the
## way in, so a fresh [code]POST /device/register[/code] is the only thing that
## can put a working one back.
func clear() -> void:
	_ensure_loaded()
	_token = ""
	_email = ""
	_abilities = PackedStringArray()
	_expires_at = 0
	_anon_token = ""
	_anon_abilities = PackedStringArray()
	_anon_expires_at = 0
	_extra.clear()
	_write()


## Removes the file entirely (dev harnesses and "delete my data"). The next read
## starts from nothing, device uid included.
func erase() -> void:
	_token = ""
	_email = ""
	_abilities = PackedStringArray()
	_expires_at = 0
	_anon_token = ""
	_anon_abilities = PackedStringArray()
	_anon_expires_at = 0
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
	_anon_token = String(data.get("anon_token", ""))
	_anon_expires_at = int(data.get("anon_expires_at", 0))
	_anon_abilities = PackedStringArray()
	for ability: Variant in data.get("anon_abilities", []):
		_anon_abilities.append(String(ability))
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
		# BL-52's second identity. Additive keys on the same schema version; see
		# the note on SCHEMA_VERSION for why that is the cheaper trade.
		"anon_token": _anon_token,
		"anon_abilities": Array(_anon_abilities),
		"anon_expires_at": _anon_expires_at,
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

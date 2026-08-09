extends Node
## The project's SECOND autoload, and the only one that talks to a network
## (DLC_SERVER.md 8.1 item 4).
##
## [b]Why a second autoload at all.[/b] DESIGN.md 3.4 and the godot-practices skill
## both say "one autoload", and that rule is right. The justification for breaking
## it is that a device token, a cached entitlement list and an in-flight pack
## download genuinely outlive every screen -- the shelf is freed while a download
## continues -- and the alternative is threading an API client through
## [code]main.gd[/code], which puts networking inside the flow orchestrator.
##
## [b]The mitigations are what make it acceptable, and they are load-bearing:[/b]
##
## 1. [b]It is a THIN FACADE.[/b] Everything real lives in plain [RefCounted]
##    classes under [code]scripts/backend/[/code] -- [ApiClient], [AuthStore],
##    [EntitlementsStore], [PackInstaller], [BackendConfig] -- each testable
##    without the tree, without this node, and without a server. This file is
##    delegation, signals and ordering; it contains no HTTP, no JSON and no file
##    format.
## 2. [b]It owns NO game state.[/b] It never reads or writes progress, paint or the
##    current book. [code]GameState[/code] keeps its monopoly on
##    [code]user://[/code] with exactly two carve-outs, both Backend's and both
##    disjoint from anything the game saves:
##    [codeblock]
##    user://auth.json        this device's identity + token   (AuthStore)
##    user://dlc/             installed packs + the            (PackInstaller,
##                            entitlement cache                 EntitlementsStore)
##    [/codeblock]
##    Nothing else in the project writes those two, and nothing here writes
##    anything else. [b]Nothing in here uploads anything, ever[/b]: the player's
##    colouring is written to [code]user://[/code] by [code]GameState[/code] and
##    stays there.
## 3. [b]With no server reachable, every method is a no-op.[/b] Not an error, not a
##    warning -- a [code]false[/code] or an empty array. The game is fully playable,
##    start to finish, with this autoload inert.
##
## [b]There are no accounts.[/b] No sign-in screen, no registration, no linking, no
## sign-out, no profiles. On startup [method sign_in_device] posts this
## installation's [code]device_uid[/code] to [code]/device/register[/code] and is
## handed a token; a device the server has never met is find-or-created on the spot.
## The player is never told any of this happened, and nothing on screen changes
## whether it worked:
## [codeblock]
## it worked   the catalogue can say what this device OWNS, and a paid pack
##             downloads
## it did not  the app is offline for the session. Free packs, installed packs
##             and every drawing already on disk work exactly as before, and the
##             next launch tries again
## [/codeblock]
##
## [b]A 401 is the ONLY thing that expires a token[/b], and it is answered here
## rather than reported. There is no refresh route: [method _authed] drops the dead
## string, re-registers under the same [code]device_uid[/code] -- which is what
## makes the server hand back the SAME device row, entitlements and all -- and
## replays the request once. See [method _authed] for why exactly once.
##
## [b]Offline-first is not negotiable[/b] (DLC_SERVER.md 8.2). The rules this file
## is built to keep:
## [codeblock]
## no screen ever awaits a request     every caller here is fire-and-forget or
##                                     an overlay the grown-up opened on purpose
## failures are SILENT to the child    push_warning + a signal; never a modal,
##                                     never a kid-facing string
## downloads are user-initiated        install_pack() is called from a button
##                                     and from nowhere else
## a dead token means a new token      silently, in the background, once
## books are never yanked offline      the entitlement filter needs a POSITIVE
##                                     revocation (EntitlementsStore)
## [/codeblock]

## A successful [code]GET /entitlements[/code] landed and the cache moved. The
## shelf listens so a pack the server has revoked -- or one a restore just
## re-granted -- shows up without anything asking.
signal entitlements_changed()
## A pack install began. Payload is the pack slug.
signal pack_install_started(slug: String)
## Download progress. [param total] is -1 until the size is known.
signal pack_install_progress(slug: String, downloaded: int, total: int)
## A pack install ended. [param code] is "" on success, otherwise an
## [ApiClient]/[PackInstaller] code.
signal pack_install_finished(slug: String, ok: bool, code: String)
## The set of installed packs changed, so any visible shelf should rescan. Emitted
## after an install or an uninstall -- never during one.
signal installed_packs_changed()

## Result keys shared by the facade's methods, mirroring [ApiClient]'s so a caller
## has one shape to read.
const KEY_OK := ApiClient.KEY_OK
const KEY_CODE := ApiClient.KEY_CODE
const KEY_MESSAGE := ApiClient.KEY_MESSAGE
const KEY_DATA := ApiClient.KEY_DATA

## The two abilities a device token carries, and the only two it ever will
## (DLC_SERVER.md 4.3). Written down here so a harness can assert the contract
## rather than a copy of it.
const DEVICE_ABILITIES: PackedStringArray = ["entitlements:read", "packs:download"]

## Extra key on [method restore_purchases]' result: how many receipts the store
## reported and this device successfully turned into entitlements.
const KEY_RESTORED := "restored"

## Whether the launch session ([method _start_session]) runs at all. [b]Dev harness
## hook[/b], and the mirror of [member TitleScreen.autostart_enabled]: a smoke sets
## it false from its own [code]_ready[/code] -- which runs in the same frame as this
## autoload's, and the session deliberately waits one frame -- so that a harness
## registers its SCRATCH device rather than the developer's real one.
var autostart_enabled := true

var _api: ApiClient
var _auth: AuthStore
var _entitlements: EntitlementsStore
var _installer: PackInstaller
## Guards the launch-time entitlement refresh so it happens once per session.
var _refreshing := false
## Guards [method sign_in_device] so two callers racing at launch make one request.
var _registering := false


func _ready() -> void:
	# Nothing here may block a boot: the constructors touch no disk (the stores are
	# lazy) and no network.
	_auth = AuthStore.new()
	_entitlements = EntitlementsStore.new()
	_api = ApiClient.new(self, BackendConfig.get_base_url(), BackendConfig.get_client_version())
	_installer = PackInstaller.new(_api)
	_sync_token()
	_start_session()


## The whole of launch: get an identity, then ask what it owns. Fire and forget --
## the title screen is already up and nothing waits on either half (8.2).
##
## DLC_SERVER.md 7.3: the update check is folded into the entitlements call, so one
## background request covers ownership AND "is there a v2 of this pack".
##
## The one-frame wait is not a delay for its own sake: it is what gives the main
## scene a chance to exist before the first request goes out, and what lets a
## harness clear [member autostart_enabled] before this touches anything.
func _start_session() -> void:
	await get_tree().process_frame
	if not autostart_enabled:
		return
	await sign_in_device()
	if is_signed_in():
		await refresh_entitlements()


# =================================================================== the parts ==
# Dependency INJECTION points, not conveniences: the smoke builds its own stores
# against scratch paths.

func get_api() -> ApiClient:
	return _api


func get_auth_store() -> AuthStore:
	return _auth


func get_entitlements_store() -> EntitlementsStore:
	return _entitlements


func get_installer() -> PackInstaller:
	return _installer


## Points the whole facade at scratch state. DEV/TEST ONLY -- the mirror of
## [method GameState.set_save_root], and for the same reason: a harness must never
## read or overwrite the player's real device identity.
func use_test_stores(auth: AuthStore, entitlements: EntitlementsStore,
		dlc_root: String, base_url: String = "") -> void:
	_auth = auth
	_entitlements = entitlements
	if base_url != "":
		_api.set_base_url(base_url)
	_installer = PackInstaller.new(_api, dlc_root)
	_sync_token()


# ======================================================================= state ==

## False turns every method below into a no-op. True does NOT mean "registered".
func is_enabled() -> bool:
	return BackendConfig.is_enabled() and _api != null and _api.get_base_url() != ""


## Whether this device holds a live token -- i.e. whether the server can be asked
## what it owns. [b]Nothing on screen may depend on this[/b]; it is false on a
## first launch with no network and the game is entirely playable in that state.
func is_signed_in() -> bool:
	return is_enabled() and _auth != null and _auth.is_signed_in()


func get_device_uid() -> String:
	return _auth.get_device_uid() if _auth != null else ""


func get_device_name() -> String:
	return _auth.get_device_name() if _auth != null else ""


func get_base_url() -> String:
	return _api.get_base_url() if _api != null else ""


# ================================================================== the device ==
# DLC_SERVER.md 4.3. One route, no credentials, no UI: the identity IS the
# persisted device_uid, and registering with it is find-or-create.

## Makes sure this device has a live token, registering it if it does not. Answers
## a result dictionary; never throws, never blocks a screen, never says anything to
## anybody.
##
## [b]Idempotent twice over.[/b] A device that already holds a live token returns
## immediately without a request, and the route itself is find-or-create for the
## uid we send -- so calling this at launch, after a 401 and from a restore button
## in the same second costs one registration and yields one device row.
##
## [b]The uid is generated on first read and never regenerated[/b]
## ([method AuthStore.get_device_uid]). That is the entire durability story for a
## purchase: the entitlements hang off the device row the uid names.
func sign_in_device(force: bool = false) -> Dictionary:
	if not is_enabled():
		return _disabled()
	if is_signed_in() and not force:
		return _ok()
	if _registering:
		# Two callers raced (launch and a 401 retry is the realistic pair). Wait the
		# first one out rather than minting a second token that would revoke the first.
		while _registering:
			await get_tree().process_frame
		return _ok() if is_signed_in() else _failure(
			ApiClient.CODE_DEVICE_REGISTRATION_FAILED, "The device could not be registered.")
	_registering = true
	var result: Dictionary = await _api.request_json(
		HTTPClient.METHOD_POST, "/device/register", {
			"device_uid": _auth.get_device_uid(),
			"device_name": _auth.get_device_name(),
			"platform": OS.get_name(),
		}, {"auth": false}
	)
	_registering = false
	if not bool(result[KEY_OK]):
		# Offline, throttled, or a server that is not there. Not an error anybody
		# hears about: the app is simply offline until the next launch (8.2).
		print_verbose("Backend: /device/register did not answer (%s: %s); staying offline."
			% [result[KEY_CODE], result[KEY_MESSAGE]])
		return result
	var data: Variant = result[KEY_DATA]
	if typeof(data) != TYPE_DICTIONARY:
		return _failure(ApiClient.CODE_BAD_BODY, "The device registration was not JSON.")
	var payload := data as Dictionary
	var token := String(payload.get("token", ""))
	if token == "":
		return _failure(ApiClient.CODE_BAD_BODY, "The device registration carried no token.")
	var abilities := PackedStringArray()
	for ability: Variant in payload.get("abilities", []):
		abilities.append(String(ability))
	_auth.store_token(token, abilities, parse_timestamp(String(payload.get("expires_at", ""))))
	_sync_token()
	return result


# ================================================================== the wire ==

## Every authenticated call goes through here, and the reason is the [b]401
## retry[/b]: there is no refresh route, so a token the server rejects is replaced
## by registering the device again -- same [code]device_uid[/code], therefore the
## same device row and the same entitlements -- and the request is replayed.
##
## [b]Exactly one retry, and never on the registration itself.[/b] A second 401
## after a token minted seconds ago is not a stale credential, it is a server
## saying no for a reason re-registering cannot fix (a revoked device, a clock
## skew, a proxy eating the header); looping on it would be a request storm behind
## a screen nobody is waiting on.
func _authed(method: int, path: String, body: Variant = null,
		options: Dictionary = {}) -> Dictionary:
	if not is_enabled():
		return _disabled()
	if not is_signed_in():
		# No usable token: get one first, but go ahead either way. A free pack's bytes
		# are public (DLC_SERVER.md 7.4), so a tokenless request is not a lost cause.
		await sign_in_device()
	var result: Dictionary = await _api.request_json(method, path, body, options)
	if String(result[KEY_CODE]) != ApiClient.CODE_UNAUTHENTICATED:
		return result
	print_verbose("Backend: the server rejected this device's token; re-registering.")
	_auth.clear_token()
	_sync_token()
	var registered := await sign_in_device()
	if not bool(registered[KEY_OK]):
		return result
	return await _api.request_json(method, path, body, options)


# =============================================================== entitlements ==

## Refreshes the cached entitlement list, which is ALSO the pack update check
## (DLC_SERVER.md 7.3). Safe to call any time; silently does nothing without a
## token, and never blocks anything.
func refresh_entitlements() -> Dictionary:
	if not is_signed_in() or _refreshing:
		return _disabled()
	_refreshing = true
	var result: Dictionary = await _authed(
		HTTPClient.METHOD_GET, "/entitlements", null,
		{"query": {"client_version": BackendConfig.get_client_version()}}
	)
	_refreshing = false
	if not bool(result[KEY_OK]):
		# Keep the last known good list (DLC_SERVER.md 9). Losing it would blink every
		# DLC book off the shelf the moment a train went into a tunnel.
		return result
	var rows: Variant = result[KEY_DATA]
	if typeof(rows) != TYPE_ARRAY:
		return _failure(ApiClient.CODE_BAD_BODY, "/entitlements did not return an array.")
	_entitlements.store(rows as Array)
	entitlements_changed.emit()
	return result


## Cached rows, last known good. Never triggers a request.
func get_entitlements() -> Array:
	return _entitlements.get_all() if _entitlements != null else []


func owns_pack(slug: String) -> bool:
	return _entitlements != null and _entitlements.owns(slug)


## Installed packs with a newer published version available (DLC_SERVER.md 7.3).
## The answer comes entirely from cached data -- no request, no await -- so a shelf
## can badge them without touching the network.
func packs_needing_update() -> PackedStringArray:
	var out := PackedStringArray()
	if _installer == null or _entitlements == null:
		return out
	for slug in _installer.installed_slugs():
		var latest := _entitlements.latest_version(slug)
		if latest > 0 and latest > _installer.installed_version(slug):
			out.append(slug)
	return out


# =================================================================== purchases ==
# DLC_SERVER.md 9. A pack belongs to the DEVICE that verified its receipt, and the
# platform store is what carries a purchase between devices: Play Billing and
# StoreKit hand back the same purchase tokens on every device signed into the same
# store account, so "I already bought this" is answered by presenting the receipt
# again rather than by an account of ours.

## Turns one store receipt into an entitlement on this device. Registers the device
## first if it has no identity to write the entitlement to.
##
## [b]There is no [code]pack_slug[/code] in the body, and that is a security
## property rather than an omission[/b]: the server resolves the pack from the SKU
## alone, so a client cannot pair a valid receipt with a pack of its choosing.
##
## Always [code]200[/code] on success, [b]including on a re-verify[/b] -- asking
## again is the restore path working, not a conflict.
func verify_purchase(platform: String, purchase_token: String, sku: String) -> Dictionary:
	if not is_enabled():
		return _disabled()
	var registered := await sign_in_device()
	if not bool(registered[KEY_OK]):
		return registered
	var result: Dictionary = await _authed(HTTPClient.METHOD_POST, "/entitlements/verify", {
		"platform": platform,
		"purchase_token": purchase_token,
		"sku": sku,
	}, {"attempts": ApiClient.VERIFY_ATTEMPTS})
	if bool(result[KEY_OK]):
		# The row we were just handed is one entitlement; the cache holds all of them,
		# so take the server's whole answer rather than patching ours.
		await refresh_entitlements()
	return result


## [b]"Restore purchases"[/b], and the one action in the app that replaces account
## linking. Re-verifies every receipt the platform store reports for this
## installation and then re-reads the entitlement list, so a device that has never
## paid for anything itself ends up owning what the store account already bought.
##
## [param receipts] is a list of [code]{platform, purchase_token, sku}[/code]
## dictionaries. Passing none asks [method get_store_receipts], which is the seam
## the billing plugin fills -- until it exists it answers an empty array and this
## degrades to "re-register and re-read what the server already knows", which is
## still the correct behaviour for a device whose token had lapsed.
##
## Never throws and never partially fails: a receipt the store refuses
## ([constant ApiClient.CODE_RECEIPT_INVALID]) is skipped rather than abandoning
## the rest, because one dead purchase must not cost the player the others.
func restore_purchases(receipts: Array = []) -> Dictionary:
	if not is_enabled():
		return _disabled()
	var registered := await sign_in_device()
	if not bool(registered[KEY_OK]):
		var failed := registered.duplicate()
		failed[KEY_RESTORED] = 0
		return failed
	var pending := receipts if not receipts.is_empty() else get_store_receipts()
	var restored := 0
	for raw: Variant in pending:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var receipt := raw as Dictionary
		var one: Dictionary = await verify_purchase(
			String(receipt.get("platform", OS.get_name().to_lower())),
			String(receipt.get("purchase_token", "")),
			String(receipt.get("sku", ""))
		)
		if bool(one[KEY_OK]):
			restored += 1
		else:
			print_verbose("Backend: a receipt did not restore (%s: %s)."
				% [one[KEY_CODE], one[KEY_MESSAGE]])
	# Even with nothing to verify this is the useful half for a device whose token
	# had lapsed: the server is asked, afresh, what this identity owns.
	var listed := await refresh_entitlements()
	var result := listed.duplicate()
	result[KEY_RESTORED] = restored
	return result


## Every purchase the platform store says belongs to whoever is signed into it, as
## [code]{platform, purchase_token, sku}[/code] rows.
##
## [b]The billing plugin's seam, and empty until there is one.[/b] It is a method
## rather than an injected callable so a harness can override it on a subclass, and
## it returns an array rather than awaiting so the shape does not change when a
## real store is plugged in behind it.
func get_store_receipts() -> Array:
	return []


# ======================================================================= shelf ==

## The shelf's filter: everything the player may see right now.
##
## [b]Built-in books always pass.[/b] They shipped in the build; no server has any
## say over them, and a network outage must never empty the shelf.
##
## A DLC book is dropped only when:
## [codeblock]
## the server POSITIVELY revoked its pack  (EntitlementsStore.should_hide_book)
## the pack needs a newer app than this    (min_client_version, equal is fine)
## [/codeblock]
## Both are "hide", never "delete" (DLC_SERVER.md 7.3). Offline, no token, cache
## empty -- in every one of those the book stays on the shelf.
func filter_books(books: Array[BookDef]) -> Array[BookDef]:
	var visible: Array[BookDef] = []
	for book in books:
		if book == null:
			continue
		if book.is_runtime and not is_book_visible(book):
			continue
		visible.append(book)
	return visible


## Whether one installed DLC book may appear. Public so the smoke can assert the
## rule directly rather than by counting cards.
func is_book_visible(book: BookDef) -> bool:
	if book == null:
		return false
	if not book.is_runtime or book.pack_slug == "":
		return true
	if _entitlements != null and _entitlements.should_hide_book(book.pack_slug):
		return false
	if _installer != null:
		var required := _installer.installed_min_client_version(book.pack_slug)
		if not BackendConfig.satisfies_min_version(required):
			return false
	return true


## Every book the player has, entitlement-filtered. The one call
## [code]main.gd[/code] makes when it fills the shelf.
func discover_visible_books(root: String = BookDef.BOOKS_ROOT, dlc_root: String = "") -> Array[BookDef]:
	var installed_root := dlc_root
	if installed_root == "":
		installed_root = _installer.get_dlc_root() if _installer != null else BookDef.DLC_ROOT
	return filter_books(BookDef.discover(root, installed_root))


# ------------------------------------------------------- sticker sets (BL-37) --
# The same filter, one content kind over. A sticker set from a pack the server has
# POSITIVELY revoked stops being offered on the strip; every other reason to be
# unsure -- offline, no token, empty cache -- leaves it there, exactly as it leaves
# a book on the shelf.
#
# Hiding, never deleting (DLC_SERVER.md 7.3), matters more here than it does for
# books: the stickers a child already stuck on a page name the set, and deleting
# it would empty drawings that are already finished.

## Whether one installed sticker set may be offered.
func is_sticker_set_visible(set_def: StickerSetDef) -> bool:
	if set_def == null:
		return false
	if not set_def.is_runtime or set_def.pack_slug == "":
		return true
	if _entitlements != null and _entitlements.should_hide_book(set_def.pack_slug):
		return false
	if _installer != null:
		var required := _installer.installed_min_client_version(set_def.pack_slug)
		if not BackendConfig.satisfies_min_version(required):
			return false
	return true


func filter_sticker_sets(sets: Array[StickerSetDef]) -> Array[StickerSetDef]:
	var visible: Array[StickerSetDef] = []
	for set_def in sets:
		if set_def == null:
			continue
		if set_def.is_runtime and not is_sticker_set_visible(set_def):
			continue
		visible.append(set_def)
	return visible


## Every sticker set the player has, entitlement-filtered. What the palette's
## cycle ring is built from (BL-36).
func discover_visible_sticker_sets(
	root: String = StickerSetDef.SETS_ROOT, dlc_root: String = ""
) -> Array[StickerSetDef]:
	var installed_root := dlc_root
	if installed_root == "":
		installed_root = _installer.get_dlc_root() if _installer != null else StickerSetDef.DLC_ROOT
	return filter_sticker_sets(StickerSetDef.discover(root, installed_root))


# ================================================================== the store ==

## [code]GET /packs[/code], filtered server-side by this build's version. Returns
## the raw pack rows (DLC_SERVER.md 11's [code]PackResource[/code] shape) so the
## catalogue UI can show titles, sizes and the [code]owned[/code] / [code]is_free[/code]
## flags without this file inventing a model of its own.
##
## [b]It needs a server, not a token.[/b] The route is optional-auth by design --
## "the shop window", DLC_SERVER.md 7.4 -- and a build with no books baked in has
## nothing else to show anybody. [code]owned[/code] is painted for whichever device
## the bearer names; with no token every row comes back [code]owned: false[/code],
## which is not the same as "you may not have it": a free pack is downloadable by
## anybody, and the shop offers it.
func fetch_packs() -> Dictionary:
	if not is_enabled():
		return _disabled()
	var result: Dictionary = await _authed(
		HTTPClient.METHOD_GET, "/packs", null,
		{"query": {"client_version": BackendConfig.get_client_version()}}
	)
	if bool(result[KEY_OK]) and typeof(result[KEY_DATA]) == TYPE_DICTIONARY:
		result = result.duplicate()
		result[KEY_DATA] = (result[KEY_DATA] as Dictionary).get("packs", [])
	return result


## Downloads and installs a pack, then tells the shelf to rescan.
##
## [b]Only ever called from a button a grown-up pressed[/b] (DLC_SERVER.md 8.2:
## "a pack never starts downloading on its own -- a kid on a parent's phone plan
## does not silently pull 8 MB"). Nothing in this file schedules it.
##
## [b]It never decides ownership[/b] (DLC_SERVER.md 7.4/9). A free pack's manifest,
## archive and files are PUBLIC, so a device the server has never met downloads one
## with no Authorization header at all; a paid one answers 401 or
## [constant ApiClient.CODE_ENTITLEMENT_REQUIRED] to the same request, which is the
## server saying no in the words the shop already knows how to read.
##
## [b]The download itself does not go through [method _authed][/b], and cannot: it
## is [PackInstaller]'s multi-step dance (manifest, 302, signed URL, per-file
## delta) rather than one request. What this does instead is make sure the token on
## the client is live BEFORE the dance starts, which is the same protection one
## step earlier -- and a token that dies mid-install costs one failed install and a
## fresh one on the retry, not a wrong answer.
func install_pack(slug: String, version: int = 0) -> Dictionary:
	if not is_enabled():
		return _disabled()
	if _installer.is_busy():
		return _failure(PackInstaller.CODE_BUSY,
			"Already downloading '%s'." % _installer.get_busy_slug())
	if not is_signed_in():
		await sign_in_device()
	pack_install_started.emit(slug)
	var result: Dictionary = await _installer.install(slug, version,
		func(downloaded: int, total: int) -> void:
			pack_install_progress.emit(slug, downloaded, total)
	)
	var ok := bool(result[PackInstaller.KEY_OK])
	if not ok and String(result[PackInstaller.KEY_CODE]) == ApiClient.CODE_UNAUTHENTICATED \
			and _auth.has_token():
		# The token died between the check above and the manifest. Re-register and give
		# the install its one retry, for the same reason _authed() gives every other
		# call one: this is a stale credential, not a refusal.
		_auth.clear_token()
		_sync_token()
		var registered := await sign_in_device()
		if bool(registered[KEY_OK]):
			result = await _installer.install(slug, version,
				func(downloaded: int, total: int) -> void:
					pack_install_progress.emit(slug, downloaded, total)
			)
			ok = bool(result[PackInstaller.KEY_OK])
	if ok:
		# Behind a token the install granted a free pack server-side; pull the list so
		# the shelf filter and the update check agree with reality. With NO token there
		# was no grant to pull -- a public fetch writes no row -- and this is already a
		# silent no-op.
		await refresh_entitlements()
		installed_packs_changed.emit()
	else:
		push_warning("Backend: installing '%s' failed (%s: %s)."
			% [slug, result[PackInstaller.KEY_CODE], result[PackInstaller.KEY_MESSAGE]])
	pack_install_finished.emit(slug, ok, String(result[PackInstaller.KEY_CODE]))
	return result


## Removes an installed pack from disk. Explicit user action only -- entitlement
## loss hides, it never deletes (DLC_SERVER.md 7.3).
func uninstall_pack(slug: String) -> bool:
	if _installer == null:
		return false
	var removed := _installer.uninstall(slug)
	if removed:
		installed_packs_changed.emit()
	return removed


func installed_packs() -> PackedStringArray:
	return _installer.installed_slugs() if _installer != null else PackedStringArray()


func installed_pack_version(slug: String) -> int:
	return _installer.installed_version(slug) if _installer != null else 0


func is_pack_installed(slug: String) -> bool:
	return _installer != null and _installer.is_installed(slug)


func is_installing() -> bool:
	return _installer != null and _installer.is_busy()


# ===================================================================== helpers ==

## ISO 8601 (what the API sends) -> unix seconds, or 0.
static func parse_timestamp(text: String) -> int:
	if text.strip_edges() == "":
		return 0
	return int(Time.get_unix_time_from_datetime_string(text))


## Keeps [ApiClient]'s bearer header in step with the store. An EXPIRED token sends
## no header at all, so a lapsed device behaves like a brand new one instead of
## generating 401s -- which is exactly right, because a free pack's bytes never
## needed the header (DLC_SERVER.md 7.4).
func _sync_token() -> void:
	if _api != null and _auth != null:
		_api.set_token(_auth.get_live_token())


static func _ok() -> Dictionary:
	return {KEY_OK: true, KEY_CODE: "", KEY_MESSAGE: "", KEY_DATA: null,
		ApiClient.KEY_STATUS: 0}


static func _disabled() -> Dictionary:
	return {KEY_OK: false, KEY_CODE: "", KEY_MESSAGE: "", KEY_DATA: null,
		ApiClient.KEY_STATUS: 0}


static func _failure(code: String, message: String) -> Dictionary:
	return {KEY_OK: false, KEY_CODE: code, KEY_MESSAGE: message, KEY_DATA: null,
		ApiClient.KEY_STATUS: 0}

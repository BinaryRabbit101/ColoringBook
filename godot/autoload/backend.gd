extends Node
## The project's SECOND autoload, and the only one that talks to a network
## (DLC_SERVER.md 8.1 item 4, answering the design's open question **Q3**).
##
## [b]Why a second autoload at all.[/b] DESIGN.md 3.4 and the godot-practices skill
## both say "one autoload", and that rule is right. The justification for breaking
## it is that an auth token, a cached entitlement list and an in-flight pack
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
## 2. [b]It owns NO game state.[/b] It never reads or writes progress, paint, mode
##    or the current book. [code]GameState[/code] keeps its monopoly on
##    [code]user://[/code] with exactly three carve-outs, all Backend's and all
##    disjoint from anything the game saves:
##    [codeblock]
##    user://auth.json        the device's account token   (AuthStore)
##                            AND its anonymous one (BL-52)
##    user://dlc/             installed packs + the        (PackInstaller,
##                            entitlement cache             EntitlementsStore)
##    user://sync_queue.json  pending pushes, base          (SyncQueue, WP11)
##                            revisions, the pull cursor
##    [/codeblock]
##    Nothing else in the project writes those three, and nothing here writes
##    anything else. The sync queue is the closest call of the three and is still
##    the right side of the line: it holds BOOKKEEPING ABOUT a sync -- what the
##    server was last known to have -- and never a page status, a cursor or a pixel.
##    Every one of those goes into the save through [code]GameState[/code]'s own API
##    ([method GameState.mark_page_status], [method GameState.set_saved_page_index],
##    [method GameState.install_page_paint]), so there is still exactly one writer
##    per file. (The same boundary is documented at the top of
##    [code]game_state.gd[/code].)
## 3. [b]With no account configured, every method is a no-op.[/b] Not an error, not
##    a warning -- a [code]false[/code] or an empty array. The game is fully
##    playable, start to finish, with this autoload inert, which is the state every
##    existing dev smoke runs in.
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
## an expired token means offline      silently; is_signed_in() simply goes false
## books are never yanked offline      the entitlement filter needs a POSITIVE
##                                     revocation (EntitlementsStore)
## [/codeblock]
##
## [b]Sync (WP11)[/b] is a fourth [RefCounted], [SyncQueue], created here and wired
## here -- it subscribes to [signal GameState.save_written],
## [signal GameState.page_paint_written] and [signal GameState.book_started]
## ITSELF, so [code]main.gd[/code] never learns that sync exists. This file adds
## the ordering (pull at launch, drain on sign-in, rescan when a pack lands) and
## the grown-up-facing surface ([method get_sync_status_text],
## [method set_picture_sync_enabled]); everything else lives in the queue.

## The signed-in state changed (sign in, sign out, or a token found expired).
signal auth_changed(signed_in: bool)
## A successful [code]GET /entitlements[/code] landed and the cache moved.
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

## Key under which [SyncQueue] stashes its "last synced" stamp in auth.json's
## extras -- ISO 8601, written after every successful drain.
const EXTRA_LAST_SYNCED := "last_synced_at"
## What the account panel shows whenever nothing has ever synced.
const NEVER_SYNCED_TEXT := "Last synced: —"
## Signed in, but the last drain never reached the server (DLC_SERVER.md 8.2).
const OFFLINE_TEXT := "Offline"
## No account, or no server in this build. Not an error, just a state.
const SYNC_OFF_TEXT := "Sync off"

var _api: ApiClient
var _auth: AuthStore
var _entitlements: EntitlementsStore
var _installer: PackInstaller
var _sync: SyncQueue
## Guards the launch-time entitlement refresh so it happens once per session.
var _refreshing := false


func _ready() -> void:
	# Nothing here may block a boot: the constructors touch no disk (the stores are
	# lazy) and no network.
	_auth = AuthStore.new()
	_entitlements = EntitlementsStore.new()
	_api = ApiClient.new(self, BackendConfig.get_base_url(), BackendConfig.get_client_version())
	_installer = PackInstaller.new(_api)
	_sync = SyncQueue.new(self, _api, _auth)
	# The sync layer listens to GameState directly (DLC_SERVER.md 6.2's save points)
	# rather than being driven from main.gd. Attaching costs nothing and is safe
	# with no account: every method on the queue is inert without a live token.
	_sync.attach()
	# A pack arriving mid-session brings books the merge may need to resolve.
	installed_packs_changed.connect(func() -> void: _sync.invalidate_books())
	_sync_token()
	# DLC_SERVER.md 7.3: the update check is folded into the entitlements call, so
	# one background request at launch covers ownership AND "is there a v2 of this
	# pack". Fire and forget -- no screen is waiting for it (8.2).
	#
	# BL-52: an ENTITLEMENT token is enough for this, so a device that registered
	# anonymously to restore a purchase keeps its shelf current too. A device that
	# has never registered has no token at all and sends nothing, which is the whole
	# point of the tier being lazy (DLC_SERVER.md 4.3).
	if has_entitlement_token():
		refresh_entitlements()
	if is_signed_in():
		# 8.3, the top of the diagram: pull the shelf, merge it, push what is ours.
		# Not awaited by anything; the title screen is already up.
		_sync.on_launch()


# =================================================================== the parts ==
# Dependency INJECTION points, not conveniences: the smoke builds its own stores
# against scratch paths, and WP11's sync queue will take the same ApiClient.

func get_api() -> ApiClient:
	return _api


func get_auth_store() -> AuthStore:
	return _auth


func get_entitlements_store() -> EntitlementsStore:
	return _entitlements


func get_installer() -> PackInstaller:
	return _installer


func get_sync_queue() -> SyncQueue:
	return _sync


## Points the whole facade at scratch state. DEV/TEST ONLY -- the mirror of
## [method GameState.set_save_root], and for the same reason: a harness must never
## read, write or sign out the player's real account.
##
## [param sync_path] is [SyncQueue]'s scratch file; "" derives one beside the
## scratch DLC root, so no harness can ever drain the player's real queue.
func use_test_stores(auth: AuthStore, entitlements: EntitlementsStore,
		dlc_root: String, base_url: String = "", sync_path: String = "") -> void:
	_auth = auth
	_entitlements = entitlements
	if base_url != "":
		_api.set_base_url(base_url)
	_installer = PackInstaller.new(_api, dlc_root)
	if _sync != null:
		_sync.detach()
	var queue_path := sync_path
	if queue_path == "":
		queue_path = dlc_root.get_base_dir().path_join("sync_queue.json") \
			if dlc_root != BookDef.DLC_ROOT else SyncQueue.QUEUE_PATH
	_sync = SyncQueue.new(self, _api, _auth, queue_path, dlc_root)
	_sync.attach()
	_sync_token()


# ======================================================================= state ==

## False turns every method below into a no-op. True does NOT mean "signed in".
func is_enabled() -> bool:
	return BackendConfig.is_enabled() and _api != null and _api.get_base_url() != ""


## A token exists on this device, whether or not it still works.
func has_account() -> bool:
	return _auth != null and _auth.has_account()


## A token exists AND has not expired. Everything that needs the network asks this.
func is_signed_in() -> bool:
	return is_enabled() and _auth != null and _auth.is_signed_in()


## True for the one state the account panel has to explain: a token that lapsed.
## Kid-facing screens never see it (DLC_SERVER.md 4.2).
func is_token_expired() -> bool:
	return _auth != null and _auth.has_account() and _auth.is_expired()


## Whether this device can ask the server what it OWNS -- an account token, or
## BL-52's anonymous device token (DLC_SERVER.md 4.3).
##
## Deliberately not [method is_signed_in], and never a substitute for it: sync,
## [code]/me[/code] and the profiles all still need an account, because the
## anonymous token does not carry [code]save:sync[/code] and never will.
func has_entitlement_token() -> bool:
	return is_enabled() and _auth != null and _auth.get_entitlement_token() != ""


## True when this installation holds a live anonymous device token (BL-52). Read by
## the harnesses and by a future restore button; nothing in normal play asks.
func is_device_registered() -> bool:
	return _auth != null and _auth.get_live_anonymous_token() != ""


func get_account_email() -> String:
	return _auth.get_email() if _auth != null else ""


func get_device_uid() -> String:
	return _auth.get_device_uid() if _auth != null else ""


func get_base_url() -> String:
	return _api.get_base_url() if _api != null else ""


## The account panel's sync line, and the ONLY place sync is ever mentioned to
## anybody (DLC_SERVER.md 8.2: "network errors go to a debug log and a small status
## line in the parent/settings panel"). It is behind the adult gate; no kid-facing
## screen calls it, and nothing in the game changes because of what it says.
##
## Four states, in the order they are checked:
## [codeblock]
## "Sync off"                 no server in this build, or no account on this device
## "Offline"                  signed in, but the last drain never reached the
##                            server -- or the token lapsed (4.2)
## "Last synced: -"           an account, but nothing has ever synced
## "Last synced: 5 minutes ago"  the normal case
## [/codeblock]
func get_sync_status_text() -> String:
	if _auth == null or not is_enabled() or not _auth.has_account():
		return SYNC_OFF_TEXT
	if is_token_expired():
		return OFFLINE_TEXT
	var stamp := String(_auth.get_extra(EXTRA_LAST_SYNCED, ""))
	if _sync != null and _sync.is_offline():
		return OFFLINE_TEXT
	if stamp == "":
		return NEVER_SYNCED_TEXT
	var age := Time.get_unix_time_from_system() - SyncQueue.parse_iso8601(stamp)
	return "Last synced: %s" % SyncQueue.describe_age(maxf(age, 0.0))


# ======================================================================== sync ==
# DLC_SERVER.md 6, 8.2, 8.3. Everything real is in [SyncQueue]; these are the three
# things that belong to the facade -- the grown-up's toggle, a status read, and a
# manual kick for a harness.

## Whether paint layers (0.5-2 MB a page) sync at all, as opposed to progress
## (~200 bytes), which always does. See [method SyncQueue.is_picture_sync_enabled]
## for why DLC_SERVER.md 6.2's "unmetered connections only" is a toggle here rather
## than a probe.
func is_picture_sync_enabled() -> bool:
	return _sync == null or _sync.is_picture_sync_enabled()


func set_picture_sync_enabled(enabled: bool) -> void:
	if _sync != null:
		_sync.set_picture_sync_enabled(enabled)


## True when something is still waiting to reach the server. Read by the smoke and
## by nothing on screen.
func has_pending_sync() -> bool:
	return _sync != null and _sync.is_pending()


## Pushes now instead of at the next save point. Background/dev only -- no screen
## awaits this (8.2); the game's own syncing is entirely signal-driven.
func sync_now(pull: bool = false) -> Dictionary:
	if _sync == null:
		return {KEY_OK: false, KEY_CODE: "", KEY_MESSAGE: ""}
	return await _sync.drain(SyncQueue.REASON_SAVE, pull)


# ======================================================================== auth ==

## Creates a grown-up's account (DLC_SERVER.md 4.1: email, password and an explicit
## guardian confirmation is the WHOLE PII footprint) and then signs in with it, so
## the caller gets one answer for one button.
func register(email: String, password: String, is_guardian: bool) -> Dictionary:
	if not is_enabled():
		return _disabled()
	var result: Dictionary = await _api.request_json(
		HTTPClient.METHOD_POST, "/auth/register",
		{"email": email, "password": password, "is_guardian": is_guardian}
	)
	if not bool(result[KEY_OK]):
		return result
	return await sign_in(email, password)


## Exchanges an email and password for a device-scoped bearer token
## (DLC_SERVER.md 4.2) and stores it in [code]user://auth.json[/code].
func sign_in(email: String, password: String) -> Dictionary:
	if not is_enabled():
		return _disabled()
	var result: Dictionary = await _api.request_json(
		HTTPClient.METHOD_POST, "/auth/token", {
			"email": email,
			"password": password,
			"device_uid": _auth.get_device_uid(),
			"device_name": _auth.get_device_name(),
			"platform": OS.get_name(),
		}
	)
	if not bool(result[KEY_OK]):
		return result
	var data: Variant = result[KEY_DATA]
	if typeof(data) != TYPE_DICTIONARY:
		return _failure(ApiClient.CODE_BAD_BODY, "The sign-in response was not JSON.")
	var payload := data as Dictionary
	var abilities := PackedStringArray()
	for ability: Variant in payload.get("abilities", []):
		abilities.append(String(ability))
	var account := email
	var user: Variant = payload.get("user", null)
	if typeof(user) == TYPE_DICTIONARY:
		account = String((user as Dictionary).get("email", email))
	# A different grown-up on the same tablet must not inherit the last one's shelf.
	# An ANONYMOUS cache is not somebody else's: it belongs to no account
	# ([code]_account == ""[/code]), the server just adopted its rows into this one,
	# and reset_if_other_account leaves it alone for exactly that reason.
	_entitlements.reset_if_other_account(account)
	_auth.store_token(String(payload.get("token", "")), account, abilities,
		parse_timestamp(String(payload.get("expires_at", ""))))
	# BL-52: the sign-in carried this device's uid, so the server ADOPTED the
	# anonymous row's entitlements into the account and revoked its tokens inside the
	# same transaction. Ours is dead; drop it rather than keep a string that would
	# 401 if anything ever reached for it.
	_auth.clear_anonymous_token()
	_sync_token()
	auth_changed.emit(is_signed_in())
	# ...and the account may own MORE than it did a moment ago, because whatever this
	# device bought anonymously is now the account's. One refresh covers both the
	# adoption and the ordinary launch-time update check (7.3).
	refresh_entitlements()
	# 8.3: this device may have been colouring signed out for a week. Reconcile the
	# whole shelf, once. Fire and forget -- the panel that called sign_in() shows
	# its answer immediately and never waits for sync (8.2).
	if _sync != null:
		_sync.on_signed_in()
	return result


## Signs this device out: tells the server to drop the token, then clears the local
## file [b]whatever the server said[/b]. A sign-out that only half-works because the
## wifi dropped is worse than one that always works locally, so the returned
## dictionary is information, never a condition -- no caller should branch on it.
##
## That is not just belt and braces: [code]DELETE /auth/token[/code] answers
## [code]204 No Content[/code], and under PHP's single-process dev server
## ([code]php artisan serve[/code]) the socket closes before Godot's [HTTPClient]
## reads the status line, so a sign-out that genuinely revoked the token reports
## [constant ApiClient.CODE_OFFLINE]. The local clear is what makes that harmless.
##
## [b]Installed packs are NOT removed[/b] (DLC_SERVER.md 7.3). The cached
## entitlement list is, because it belongs to an account nobody is signed into.
func sign_out() -> Dictionary:
	var result := {KEY_OK: true, KEY_CODE: "", KEY_MESSAGE: "", KEY_DATA: null}
	if is_enabled() and _auth.get_live_token() != "":
		result = await _api.request_json(HTTPClient.METHOD_DELETE, "/auth/token")
	_auth.clear()
	_entitlements.clear()
	_sync_token()
	# The queue file is KEPT: the same grown-up signing back in on this tablet
	# resumes from the same base revisions instead of re-pushing the shelf. A
	# DIFFERENT account resets it on sign-in (SyncQueue._adopt_account).
	if _sync != null:
		_sync.on_signed_out()
	auth_changed.emit(false)
	return result


## Slides the 90-day expiry (DLC_SERVER.md 4.2). Background only.
func refresh_token() -> Dictionary:
	if not is_signed_in():
		return _disabled()
	var result: Dictionary = await _api.request_json(HTTPClient.METHOD_POST, "/auth/refresh")
	if bool(result[KEY_OK]) and typeof(result[KEY_DATA]) == TYPE_DICTIONARY:
		_auth.slide_expiry(parse_timestamp(
			String((result[KEY_DATA] as Dictionary).get("expires_at", ""))
		))
	elif String(result[KEY_CODE]) == ApiClient.CODE_UNAUTHENTICATED:
		_expire_silently()
	return result


## [code]GET /me[/code] -- the account panel's "is this token still real" check.
func fetch_me() -> Dictionary:
	return await _authed_get("/me")


# ================================================== the anonymous device tier ==
# DLC_SERVER.md 4.3, BL-52. "Own once, everywhere", without an email address: the
# store account is already the cross-device identity for purchases, so the server
# only has to verify a receipt from whichever device presents it.

## Makes sure this installation can be told what it owns, registering anonymously
## if that is what it takes. Answers a result dictionary; never throws.
##
## [b]NOTHING IN NORMAL PLAY MAY CALL THIS[/b], and that is the entry's whole COPPA
## posture (DLC_SERVER.md 4.3): a device that only ever downloads free packs sends
## the server no identifier at all. The two callers this exists for are a purchase
## about to be verified and a grown-up pressing "restore my purchases" -- both of
## them Phase 6, both of them deliberate acts.
##
## Three outcomes, in the order they are checked:
## [codeblock]
## an account token   nothing to do -- the account IS the identity
## a live anon token  nothing to do -- this device already registered
## neither            POST /device/register with the persisted device_uid
## [/codeblock]
## The uid is [method AuthStore.get_device_uid], the SAME one sign-in sends, which
## is what lets the server adopt this device's packs into an account later.
func ensure_device_registered() -> Dictionary:
	if not is_enabled():
		return _disabled()
	if is_signed_in() or is_device_registered():
		return {KEY_OK: true, KEY_CODE: "", KEY_MESSAGE: "", KEY_DATA: null}
	var result: Dictionary = await _api.request_json(
		HTTPClient.METHOD_POST, "/device/register", {
			"device_uid": _auth.get_device_uid(),
			"device_name": _auth.get_device_name(),
			"platform": OS.get_name(),
		}
	)
	if not bool(result[KEY_OK]):
		return result
	var data: Variant = result[KEY_DATA]
	if typeof(data) != TYPE_DICTIONARY:
		return _failure(ApiClient.CODE_BAD_BODY, "The device registration was not JSON.")
	var payload := data as Dictionary
	var abilities := PackedStringArray()
	for ability: Variant in payload.get("abilities", []):
		abilities.append(String(ability))
	_auth.store_anonymous_token(String(payload.get("token", "")), abilities,
		parse_timestamp(String(payload.get("expires_at", ""))))
	_sync_token()
	return result


## Turns a store receipt into an entitlement (BL-52, DLC_SERVER.md 9) -- the
## restore path, and the seam Phase 6's billing plugin plugs into. Registers this
## device first if there is no identity to write the entitlement to.
##
## [b]No UI calls this yet[/b], because there is no billing plugin to produce a
## [param purchase_token]. When there is, "bought once, owned everywhere" is: ask
## the store what this account owns, then call this once per purchase token.
func verify_purchase(platform: String, purchase_token: String, sku: String) -> Dictionary:
	if not is_enabled():
		return _disabled()
	var registered := await ensure_device_registered()
	if not bool(registered[KEY_OK]):
		return registered
	var result: Dictionary = await _api.verify_receipt(platform, purchase_token, sku)
	if bool(result[KEY_OK]):
		# The row we were just handed is one entitlement; the cache holds all of
		# them, so take the server's whole answer rather than patching ours.
		await refresh_entitlements()
	return result


# =============================================================== entitlements ==

## Refreshes the cached entitlement list, which is ALSO the pack update check
## (DLC_SERVER.md 7.3). Safe to call any time; silently does nothing with no
## entitlement token, and never blocks anything.
##
## BL-52: it keys off [method has_entitlement_token] rather than
## [method is_signed_in], because an anonymous device owns packs too and
## [code]GET /entitlements[/code] answers for either identity.
func refresh_entitlements() -> Dictionary:
	if not has_entitlement_token() or _refreshing:
		return _disabled()
	_refreshing = true
	var result: Dictionary = await _api.request_json(
		HTTPClient.METHOD_GET, "/entitlements", null,
		{"query": {"client_version": BackendConfig.get_client_version()}}
	)
	_refreshing = false
	if not bool(result[KEY_OK]):
		if String(result[KEY_CODE]) == ApiClient.CODE_UNAUTHENTICATED:
			_expire_silently()
		# Anything else: keep the last known good list (DLC_SERVER.md 9).
		return result
	var rows: Variant = result[KEY_DATA]
	if typeof(rows) != TYPE_ARRAY:
		return _failure(ApiClient.CODE_BAD_BODY, "/entitlements did not return an array.")
	_entitlements.store(rows as Array, get_account_email())
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
## Both are "hide", never "delete" (DLC_SERVER.md 7.3). Signed out, offline, token
## expired, cache empty -- in every one of those the book stays on the shelf.
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
# unsure -- signed out, offline, token expired, empty cache -- leaves it there,
# exactly as it leaves a book on the shelf.
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
## [b]It needs a server, not an account[/b] (BL-25). The route is optional-auth by
## design -- "the shop window", DLC_SERVER.md 7.4 -- and a signed-out build with no
## books baked in has nothing else to show anybody.
##
## [code]owned[/code] is painted for whichever identity the bearer names, ACCOUNT
## OR ANONYMOUS DEVICE (BL-52), so a tablet that restored a purchase without ever
## signing in sees the pack it bought marked owned. With no token at all every row
## comes back [code]owned: false[/code] -- which is not the same as "you may not
## have it": a free pack is downloadable by anybody, and the shop offers it.
func fetch_packs() -> Dictionary:
	if not is_enabled():
		return _disabled()
	var result: Dictionary = await _api.request_json(
		HTTPClient.METHOD_GET, "/packs", null,
		{"query": {"client_version": BackendConfig.get_client_version()}}
	)
	if bool(result[KEY_OK]) and typeof(result[KEY_DATA]) == TYPE_DICTIONARY:
		result = result.duplicate()
		result[KEY_DATA] = (result[KEY_DATA] as Dictionary).get("packs", [])
	elif String(result[KEY_CODE]) == ApiClient.CODE_UNAUTHENTICATED:
		_expire_silently()
	return result


## Downloads and installs a pack, then tells the shelf to rescan.
##
## [b]Only ever called from a button a grown-up pressed[/b] (DLC_SERVER.md 8.2:
## "a pack never starts downloading on its own -- a kid on a parent's phone plan
## does not silently pull 8 MB"). Nothing in this file schedules it.
##
## [b]It no longer requires an account, and it never decided ownership anyway[/b]
## (BL-52, DLC_SERVER.md 7.4/9). A free pack's manifest, archive and files are
## PUBLIC, so a signed-out child on a fresh tablet downloads it with no
## Authorization header at all; a paid one answers 401 or
## [constant ApiClient.CODE_ENTITLEMENT_REQUIRED] to the same request, which is the
## server saying no in the words the shop already knows how to read. Putting an
## [method is_signed_in] gate back here would only mean the client guessing at an
## answer it is about to be given.
func install_pack(slug: String, version: int = 0) -> Dictionary:
	if not is_enabled():
		return _disabled()
	if _installer.is_busy():
		return _failure(PackInstaller.CODE_BUSY,
			"Already downloading '%s'." % _installer.get_busy_slug())
	pack_install_started.emit(slug)
	var result: Dictionary = await _installer.install(slug, version,
		func(downloaded: int, total: int) -> void:
			pack_install_progress.emit(slug, downloaded, total)
	)
	var ok := bool(result[PackInstaller.KEY_OK])
	if ok:
		# Behind a token the install granted a free pack server-side; pull the list so
		# the shelf filter and the update check agree with reality. With NO token there
		# was no grant to pull -- a public fetch writes no row (BL-52) -- and this is
		# already a silent no-op, which is the correct amount of network for a device
		# that has told the server nothing about itself.
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


func _authed_get(path: String) -> Dictionary:
	if not is_signed_in():
		return _disabled()
	var result: Dictionary = await _api.request_json(HTTPClient.METHOD_GET, path)
	if String(result[KEY_CODE]) == ApiClient.CODE_UNAUTHENTICATED:
		_expire_silently()
	return result


## The server rejected our token. Drop it and go offline WITHOUT a word to anybody
## on screen (DLC_SERVER.md 4.2 / 8.2); the grown-up sees it next time they open
## the account panel.
##
## BL-52: an ANONYMOUS token can be rejected too -- adoption revokes it, and so
## does a re-registration on another process. That is not a sign-out (there is no
## account to lose and nothing to tell anybody), so it drops the dead string and
## emits nothing; the next deliberate restore registers again.
func _expire_silently() -> void:
	if _auth == null:
		return
	if not _auth.has_account():
		if _auth.has_anonymous_token():
			print_verbose("Backend: the server rejected this device's anonymous token.")
			_auth.clear_anonymous_token()
			_sync_token()
		return
	print_verbose("Backend: the server rejected this device's token; going offline.")
	_auth.clear()
	_sync_token()
	auth_changed.emit(false)


## Keeps [ApiClient]'s bearer header in step with the store. An EXPIRED token sends
## no header at all, so a lapsed device behaves like a signed-out one instead of
## generating 401s.
##
## [b]It is the ENTITLEMENT token[/b] (BL-52): the account's when a grown-up is
## signed in, this device's anonymous one otherwise, nothing at all when neither
## exists -- which is what makes a free pack's download tokenless on a fresh tablet
## (DLC_SERVER.md 7.4). That is safe for sync precisely because
## [method SyncQueue.is_active] keys off [method AuthStore.get_live_token] instead,
## so the queue never fires a request in the state where these two differ.
func _sync_token() -> void:
	if _api != null and _auth != null:
		_api.set_token(_auth.get_entitlement_token())


static func _disabled() -> Dictionary:
	return {KEY_OK: false, KEY_CODE: "", KEY_MESSAGE: "", KEY_DATA: null,
		ApiClient.KEY_STATUS: 0}


static func _failure(code: String, message: String) -> Dictionary:
	return {KEY_OK: false, KEY_CODE: code, KEY_MESSAGE: message, KEY_DATA: null,
		ApiClient.KEY_STATUS: 0}

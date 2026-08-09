extends Node
## Automated verification for WP10 -- the Godot backend client: adult gate, account,
## entitlements and the real pack download/install (DLC_SERVER.md 4, 7, 8, 9, 11).
##
## [b]Run it HEADLESS, against a live local server[/b] -- unlike the other smokes it
## paints nothing, so there is nothing for a rasteriser to do:
##
##   cd server && php artisan serve --port=8123
##   <godot_exe> --headless --path <project> res://scenes/dev/backend_smoke.tscn
##
## Extra user args (after a bare `--`):
##   --base-url <url>   API root (default: whatever BackendConfig resolves,
##                      normally http://127.0.0.1:8123/api/v1)
##   --stay             leave the scratch account, pack and stores in place
##
## [b]What the server has to be holding[/b] before check (n) can run (BL-52). Two
## of these three the delta check already needed; the third is new:
## [codeblock]
## coyote-book v1 and v2   php artisan pack:publish <dir> --free, twice, the
##                         second directory differing in exactly ONE file
## a PAID pack             php artisan pack:publish <dir> --paid, then give it
##                         the SKU below:
##                           Pack::where('slug', 'starter-stickers')->first()
##                             ->update(['sku_google' => 'coloringbook.starter_stickers'])
## the FAKE verifier       .env: COLORINGBOOK_STORE_GOOGLE_VERIFIER=\
##                           App\Services\Stores\FakeStoreReceiptVerifier
##                         (it accepts any purchase token starting 'test-', and
##                         refuses to load at all in production)
## [/codeblock]
##
## [b]It talks to a REAL server and downloads REAL bytes.[/b] That is the whole
## point: sha256 verification, the atomic directory swap and the de-duplication
## rule are all things that only mean something against the actual 950 KB
## `coyote-book` archive the server publishes. There is no mock anywhere in here.
##
## [b]Everything it writes is isolated[/b] -- [constant TEST_ROOT] for the DLC root
## and both Backend stores, via [method Backend.use_test_stores] (the mirror of
## [method GameState.set_save_root], and for the same reason). The player's real
## [code]user://auth.json[/code], [code]user://dlc/[/code] and save are never
## opened. The scratch ACCOUNT it registers lives on the server; its email is
## printed and written to [constant EMAIL_FILE] so a cleanup step can find it.
##
## Checks, in order:
##   a  BackendConfig + ApiClient as pure logic: base URL, version comparison
##      (equal satisfies), the backoff schedule and its cap, header parsing
##   b  with no account every Backend method is a NO-OP, and the shelf is exactly
##      what BookDef.discover() returns -- EXCEPT the shop window (BL-25): the
##      catalogue lists signed out, a FREE pack downloads with NO Authorization
##      header at all and writes no entitlement row (BL-52), and only a PAID row's
##      Get asks for a sign-in
##   n  BL-52's anonymous device tier: lazy registration, a token carrying
##      entitlements:read + packs:download and NEVER save:sync, GET /entitlements
##      answering for a device, the receipt seam granting a PAID pack that then
##      downloads -- all with nobody signed in and sync still off
##   c  register -> token: auth.json written, ULID device uid, expiry parsed, a
##      wrong password is INVALID_CREDENTIALS and does not disturb the stored
##      token -- and BL-52's ADOPTION: what the device bought anonymously is the
##      account's afterwards, and the anonymous token is gone
##   d  GET /packs lists coyote-book with the server's flags; GET /entitlements
##      caches, and is the update check
##   e  the install: manifest, signed URL, 950 KB downloaded with real progress,
##      EVERY sha256 verified, atomic swap, no .incoming left behind
##   m  the BL-26 delta update: v1 -> v2 moves ONLY the file that changed, the
##      result is byte-identical to a full-zip install of v2, and a per-file fetch
##      that fails falls back to the archive and still installs. Needs TWO
##      published versions of the pack -- see [method _check_delta_update]
##   f  discovery -- the installed pack IS a discoverable runtime book, and is
##      nevertheless SHELF-INVISIBLE because the built-in coyote wins de-duplication
##   g  the entitlement filter: a revoked pack is hidden but its FILES STAY, and an
##      offline refresh keeps the last known good list rather than emptying it
##   h  an expired token means offline, silently -- and the DLC book stays visible
##   i  the checksum gate and the zip-slip guard, as pure functions
##   j  the adult gate and the pack-shop row state machine, headless
##   l  the real wiring in main.tscn: gear -> Settings -> Account -> GATE -> account
##      panel, and the shelf's "More books" button, which is there whenever the
##      build has a server at all (BL-25)
##   k  sign out: server told, auth.json cleared, cache dropped, PACK LEFT ON DISK
##
## Exit code is 0 only if every check passes.

const COYOTE_UID := "coyote-2026"
const TEST_BOOK_UID := "test-book-2026"
## The pack the dev server publishes (WP9). FREE, which since BL-52 means its
## bytes are public: no token, no account, no identifier of any kind.
const PACK_SLUG := "coyote-book"
## A PAID pack, and the Play SKU it is sold under (BL-52). See the header for the
## two commands that put it on the dev server; check (n) is the only user.
const PAID_SLUG := "starter-stickers"
const PAID_SKU := "coloringbook.starter_stickers"
## The platform the fake verifier is wired to in .env, and a purchase token it
## accepts -- `FakeStoreReceiptVerifier` says yes to anything starting `test-`
## and uses the token itself as the transaction id, so "verify twice, get one
## row" is a real assertion rather than a lucky one.
const STORE_PLATFORM := "google"
const GOOD_RECEIPT := "test-wp10-smoke-receipt"
## ...and one it refuses, because it does not carry the prefix.
const BAD_RECEIPT := "definitely-not-a-real-purchase-token"
## Built-in books: test_book + coyote.
const BUILTIN_BOOK_COUNT := 2

## Everything this run writes.
const TEST_ROOT := "user://backend_smoke"
const TEST_DLC_ROOT := "user://backend_smoke/dlc"
const TEST_AUTH_PATH := "user://backend_smoke/auth.json"
const TEST_ENTITLEMENTS_PATH := "user://backend_smoke/dlc/entitlements.json"
## Where the scratch account's email is left for the cleanup step.
const EMAIL_FILE := "user://backend_smoke/scratch_account.txt"
## Scratch save root. Needed since WP11: signing in drains the sync queue, and a
## harness must never push the DEVELOPER's real colouring to a scratch account.
const TEST_SAVE_ROOT := "user://backend_smoke/state"

## Password for the scratch account. Mixed case and a digit on purpose: a
## production-config server applies Laravel's [code]Password::defaults()[/code],
## which a long but all-lowercase passphrase does not satisfy.
const SCRATCH_PASSWORD := "Wp10-Smoke-Passphrase-7"
## Seconds to wait out the server's `throttle:6,1` on the auth routes, plus slack.
const THROTTLE_WINDOW_SECONDS := 62.0

const ADULT_GATE_SCENE: PackedScene = preload("res://scenes/components/adult_gate.tscn")
const PACK_SHOP_SCENE: PackedScene = preload("res://scenes/components/pack_shop.tscn")

var _checks := 0
var _failures := 0

var _email := ""
var _auth: AuthStore
var _entitlements: EntitlementsStore
var _base_url := ""
## Progress callbacks seen during the download, as [downloaded, total] pairs.
var _progress: Array = []
var _installed_bytes := 0


func _ready() -> void:
	await get_tree().process_frame
	await _run()


func _run() -> void:
	print("=== WP10 backend smoke test ===")
	_isolate()
	print("   API:        %s" % _base_url)
	print("   DLC root:   %s" % ProjectSettings.globalize_path(TEST_DLC_ROOT))
	print("   auth.json:  %s" % ProjectSettings.globalize_path(TEST_AUTH_PATH))

	# BL-27: check (l) boots main.tscn and then holds the title still while it walks
	# the account route. Left alone the splash would carry itself to the shelf
	# mid-check; shell_smoke's check (a2) is where that behaviour is proved.
	TitleScreen.autostart_enabled = false

	_check_pure_logic()
	await _check_inert_without_account()
	await _check_anonymous_device()
	await _check_auth()
	await _check_catalog()
	await _check_install()
	await _check_delta_update()
	_check_discovery()
	await _check_entitlement_filter()
	_check_expired_token()
	_check_verification_gates()
	await _check_ui()
	await _check_main_flow()
	await _check_sign_out()

	print("\n=== %d/%d checks passed ===" % [_checks - _failures, _checks])
	print("scratch account: %s" % (_email if _email != "" else "(none registered)"))
	if "--stay" in OS.get_cmdline_user_args():
		print("[dev] --stay given; %s was kept."
			% ProjectSettings.globalize_path(TEST_ROOT))
		return
	_cleanup()
	_finish(0 if _failures == 0 else 1)


## Points Backend at scratch stores and a scratch DLC root before anything runs.
func _isolate() -> void:
	_delete_recursive(TEST_ROOT)
	DirAccess.make_dir_recursive_absolute(TEST_DLC_ROOT)
	_base_url = _arg_value("--base-url", BackendConfig.get_base_url())
	GameState.set_save_root(TEST_SAVE_ROOT)
	_auth = AuthStore.new(TEST_AUTH_PATH)
	_entitlements = EntitlementsStore.new(TEST_ENTITLEMENTS_PATH)
	Backend.use_test_stores(_auth, _entitlements, TEST_DLC_ROOT, _base_url)


func _cleanup() -> void:
	Backend.get_installer().uninstall(PACK_SLUG)
	Backend.get_installer().uninstall(PAID_SLUG)
	GameState.set_save_root("")
	_delete_recursive(TEST_ROOT)
	# Hand the real stores back so a --stay-less run leaves the autoload as it found
	# it (this process is about to exit, but a harness that lies about that is a
	# harness nobody trusts).
	Backend.use_test_stores(AuthStore.new(), EntitlementsStore.new(),
		BookDef.DLC_ROOT, BackendConfig.get_base_url(), SyncQueue.QUEUE_PATH)
	print("   cleaned up %s" % ProjectSettings.globalize_path(TEST_ROOT))


func _finish(code: int) -> void:
	print("exit code: %d" % code)
	get_tree().quit(code)


# ================================== a: BackendConfig / ApiClient, pure logic ==

func _check_pure_logic() -> void:
	print("\n-- check a: config and client, with no server in sight --")

	_expect(BackendConfig.get_base_url().begins_with("http"),
		"a base URL resolves from project settings (%s)" % BackendConfig.get_base_url())
	_expect(BackendConfig.get_base_url().ends_with("/v1"),
		"...including the API version prefix, so paths are bare ('/packs')")
	_expect(BackendConfig.for_web_origin("https://game.example/") == "https://game.example/api/v1",
		"the web export's same-origin base URL is a PATH on the game's own host (7.4)")

	# The WEB branch of the resolution, proved from this desktop run: resolve_base_url()
	# takes the platform and the page origin as ARGUMENTS for exactly this reason. It
	# matters because the dev default is a loopback -- in a browser tab 127.0.0.1 is the
	# CHILD's machine, so a web build that used it would fail in a way nothing here
	# would catch.
	_expect(BackendConfig.resolve_base_url("", BackendConfig.DEFAULT_BASE_URL, true,
			"http://192.168.0.164:91") == "http://192.168.0.164:91/api/v1",
		"a web build resolves the API against the PAGE'S OWN ORIGIN, not the dev loopback")
	_expect(BackendConfig.resolve_base_url("", BackendConfig.DEFAULT_BASE_URL, true,
			"https://minipc.example.ts.net:453/") == "https://minipc.example.ts.net:453/api/v1",
		"...whichever of the two URLs the shell landed on -- the origin carries the port")
	_expect(BackendConfig.resolve_base_url("", BackendConfig.DEFAULT_BASE_URL, false,
			"http://192.168.0.164:91") == BackendConfig.DEFAULT_BASE_URL,
		"...and a DESKTOP run is untouched by any of it")
	_expect(BackendConfig.resolve_base_url("http://laptop.lan:8123/api/v1",
			BackendConfig.DEFAULT_BASE_URL, true, "http://192.168.0.164:91")
			== "http://laptop.lan:8123/api/v1",
		"an explicit user://backend.json override still wins, web included")
	_expect(BackendConfig.resolve_base_url("", "https://api.example/api/v1", true,
			"http://192.168.0.164:91") == "https://api.example/api/v1",
		"...as does an export deliberately pointed somewhere other than the dev default")
	_expect(BackendConfig.resolve_base_url("", BackendConfig.DEFAULT_BASE_URL, true, "")
			== BackendConfig.WEB_ORIGIN_PATH,
		"with no readable origin a web build falls back to the same-origin PATH (%s)"
		% BackendConfig.WEB_ORIGIN_PATH)
	_expect(BackendConfig.get_page_origin() == "",
		"there is no page origin outside a browser, so this desktop run is unaffected")

	# min_client_version -- the coyote pack ships 0.6.0 against a 0.6.0 build, so
	# "equal is satisfied" is not a detail, it is the shipping case.
	_expect(BackendConfig.compare_versions("0.6.0", "0.6") == 0,
		"missing version components count as zero ('0.6.0' == '0.6')")
	_expect(BackendConfig.satisfies_min_version("0.6.0", "0.6.0"),
		"a build EQUAL to min_client_version is accepted")
	_expect(BackendConfig.satisfies_min_version("0.6.0", "0.7.1"),
		"...a newer build too")
	_expect(not BackendConfig.satisfies_min_version("0.7.0", "0.6.0"),
		"...and an older build is not")
	_expect(BackendConfig.satisfies_min_version("", "0.1.0"),
		"a pack with no minimum runs anywhere")
	_expect(BackendConfig.satisfies_min_version("0.6.0"),
		"this build (%s) can run the published pack" % BackendConfig.get_client_version())

	# Backoff: exponential, jittered, capped (DLC_SERVER.md 8.2).
	var first := ApiClient.backoff_delay(0)
	_expect(first >= 0.5 and first <= 1.0, "the first backoff is 0.5-1.0 s (%.2f)" % first)
	var third := ApiClient.backoff_delay(2)
	_expect(third >= 2.0 and third <= 4.0, "the third is 2-4 s -- it doubles (%.2f)" % third)
	var far := ApiClient.backoff_delay(40)
	_expect(far <= ApiClient.BACKOFF_CAP_SECONDS,
		"and it is capped at ~5 minutes rather than growing forever (%.0f s)" % far)
	var jitter := {}
	for i in 24:
		jitter[snappedf(ApiClient.backoff_delay(3), 0.001)] = true
	_expect(jitter.size() > 1, "the delay is JITTERED, not a fixed ladder (%d distinct)" % jitter.size())

	_expect(ApiClient.header_value(
			PackedStringArray(["Content-Type: application/zip", "LOCATION: http://x/y"]),
			"location") == "http://x/y",
		"header lookup is case-insensitive -- a 302's Location is how the pack URL arrives")

	# The ULID that identifies this installation to the server (4.2).
	var ulid := AuthStore.new_ulid()
	_expect(ulid.length() == 26, "a device ULID is 26 characters (%s)" % ulid)
	_expect(ulid == ulid.to_upper() and not ("I" in ulid or "L" in ulid or "U" in ulid),
		"...upper-case Crockford base32, so it can never be mistaken for a slug")
	_expect(AuthStore.new_ulid() != ulid, "...and two of them differ")


# ======================== b: no account configured means every method no-ops ==

func _check_inert_without_account() -> void:
	print("\n-- check b: with no account, Backend is inert --")

	_expect(not Backend.has_account(), "a fresh device has no account")
	_expect(not Backend.is_signed_in(), "...and is not signed in")
	_expect(not FileAccess.file_exists(TEST_AUTH_PATH),
		"...and nothing has been written to auth.json yet")
	_expect(Backend.get_account_email() == "", "there is no account email to show")
	# WP11: with no account at all there is nothing to sync and nothing to explain,
	# so the line is "Sync off" rather than a "last synced" that never was.
	_expect(Backend.get_sync_status_text() == Backend.SYNC_OFF_TEXT,
		"the account panel's sync line reads '%s'" % Backend.get_sync_status_text())
	_expect(Backend.get_entitlements().is_empty(), "the entitlement cache is empty")
	_expect(Backend.packs_needing_update().is_empty(), "nothing needs updating")
	_expect(Backend.installed_packs().is_empty(), "no packs are installed")

	# The shelf, unchanged. Every existing dev smoke runs in exactly this state.
	var discovered := BookDef.discover(BookDef.BOOKS_ROOT, TEST_DLC_ROOT)
	var visible := Backend.discover_visible_books(BookDef.BOOKS_ROOT, TEST_DLC_ROOT)
	_expect(discovered.size() == BUILTIN_BOOK_COUNT and visible.size() == discovered.size(),
		"the shelf is exactly what discover() returns (%d books)" % visible.size())
	_expect(Backend.filter_books(discovered).size() == discovered.size(),
		"...the entitlement filter never touches a built-in book")

	# --- the one thing that is NOT inert without an account (BL-25) -----------
	# A shipped build has no books baked in, so a signed-out first launch has
	# nothing but the shop window. GET /packs is optional-auth for exactly that.
	var window: Dictionary = await Backend.fetch_packs()
	_expect(bool(window[Backend.KEY_OK]),
		"GET /packs answers with NO account at all (%s)" % window[Backend.KEY_CODE])
	var offered: Array = window[Backend.KEY_DATA] as Array \
		if typeof(window[Backend.KEY_DATA]) == TYPE_ARRAY else []
	_expect(not offered.is_empty(),
		"...and lists the catalogue signed out (%d pack(s))" % offered.size())
	var owned_signed_out := false
	for raw: Variant in offered:
		if typeof(raw) == TYPE_DICTIONARY and bool((raw as Dictionary).get("owned", false)):
			owned_signed_out = true
	_expect(not owned_signed_out, "...with nothing marked owned, because nobody is signed in")

	var window_shop := PACK_SHOP_SCENE.instantiate() as PackShop
	add_child(window_shop)
	if not await _wait_for(func() -> bool: return not window_shop.get_rows().is_empty()):
		_expect(false, "the pack shop renders the catalogue while signed out")
	_expect(not window_shop.get_rows().is_empty(),
		"the pack shop renders the catalogue while signed out (%d row(s))"
		% window_shop.get_rows().size())

	# --- BL-52: which rows the gate is actually for ---------------------------
	# The hint used to greet every signed-out shopper. It now speaks only when
	# something on the list really is behind the gate, because a free book no
	# longer is.
	var free_row := window_shop.get_row(PACK_SLUG)
	var paid_row := window_shop.get_row(PAID_SLUG)
	_expect(free_row != null and not free_row.needs_account(),
		"a FREE row needs no account (is_free %s, owned %s)"
		% [free_row.is_free() if free_row else "?", free_row.is_owned() if free_row else "?"])
	_expect(paid_row != null and paid_row.needs_account(),
		"...while a PAID one nobody owns still does -- see the header for its seed")
	_expect(window_shop.gated_rows().size() == 1
			and window_shop.get_status_text() == PackShop.SIGNED_OUT_HINT,
		"...so the shop says what is still missing, for %d row(s) ('%s')"
		% [window_shop.gated_rows().size(), window_shop.get_status_text()])

	var asked_to_sign_in := [0]
	window_shop.sign_in_requested.connect(func() -> void: asked_to_sign_in[0] += 1)
	if paid_row != null:
		paid_row.press_action()
		paid_row.press_action()
		await get_tree().process_frame
		_expect(asked_to_sign_in[0] == 1 and not window_shop.is_installing(),
			"a PAID Get asks for a SIGN-IN rather than failing silently (%d)"
			% asked_to_sign_in[0])
		_expect(paid_row.get_state() == PackShop.PackRow.STATE_CONFIRM,
			"...leaving the row's 'Yes, download' where the grown-up left it (%s)"
			% paid_row.get_state())
	if free_row != null:
		# The shop's own handler is taken off first: what is asserted here is the
		# DECISION -- that a free Get goes to the download instead of to the gate --
		# and the real tokenless install is done below, awaited, so it cannot still
		# be in flight underneath the checks that follow.
		for connection: Dictionary in free_row.download_requested.get_connections():
			free_row.download_requested.disconnect(connection["callable"])
		var wanted := [0]
		free_row.download_requested.connect(func() -> void: wanted[0] += 1)
		free_row.press_action()
		free_row.press_action()
		await get_tree().process_frame
		_expect(wanted[0] == 1 and asked_to_sign_in[0] == 1,
			"a FREE Get goes straight to the download, signed out (%d download(s), %d gate(s))"
			% [wanted[0], asked_to_sign_in[0]])
	else:
		_expect(false, "the signed-out catalogue includes '%s'" % PACK_SLUG)
	remove_child(window_shop)
	window_shop.queue_free()

	# --- BL-52: and the bytes really do arrive without a token ----------------
	# DLC_SERVER.md 7.4: a free pack's manifest, archive and files are PUBLIC. This
	# is the whole "free app content available to download without needing to create
	# an account" requirement, proved against a real server.
	_expect(_auth.get_entitlement_token() == "",
		"there is no token of ANY kind on this device -- account or anonymous")
	var public_install: Dictionary = await Backend.install_pack(PACK_SLUG)
	_expect(bool(public_install[PackInstaller.KEY_OK]),
		"install_pack('%s') succeeds with NO Authorization header (%s %s)"
		% [PACK_SLUG, public_install[PackInstaller.KEY_CODE],
			public_install[PackInstaller.KEY_MESSAGE]])
	_expect(Backend.is_pack_installed(PACK_SLUG),
		"...and the pack is on disk, downloaded by a device the server cannot name")
	_expect(not _entitlements.has_data() and Backend.get_entitlements().is_empty(),
		"...having written no entitlement anywhere: a public fetch grants nothing")
	# A paid pack asks the same question and is refused, by the server, in the
	# words the shop already knows how to read.
	var refused: Dictionary = await Backend.install_pack(PAID_SLUG)
	_expect(not bool(refused[PackInstaller.KEY_OK])
			and String(refused[PackInstaller.KEY_CODE]) == ApiClient.CODE_UNAUTHENTICATED,
		"...while a PAID pack is %s to the same tokenless request (%s)"
		% [ApiClient.CODE_UNAUTHENTICATED, refused[PackInstaller.KEY_CODE]])
	# Put the shelf back the way the rest of the run expects to find it.
	Backend.uninstall_pack(PACK_SLUG)
	_expect(not Backend.is_pack_installed(PACK_SLUG),
		"the public install is removed again, so check (e) still starts from nothing")


# ========================================= n: the anonymous device tier (BL-52) ==
# DLC_SERVER.md 4.3 and 9. The claim under test: a household that bought a pack can
# have it on a second tablet without an email address, a password or an account --
# because the store already knows what it bought, and the server only has to verify
# the receipt whichever device presents it.
#
# Everything below happens with NOBODY SIGNED IN. That is the point.

func _check_anonymous_device() -> void:
	print("\n-- check n: registering a device, and restoring a purchase onto it --")

	_expect(not Backend.is_device_registered() and not _auth.has_anonymous_token(),
		"nothing has registered yet -- the tier is LAZY, and free play never triggers it")
	var uid_before := Backend.get_device_uid()

	var registered: Dictionary = await Backend.ensure_device_registered()
	if String(registered[Backend.KEY_CODE]) == ApiClient.CODE_THROTTLED:
		# `throttle:6,1`, and Laravel keys that limiter on (domain, ip) rather than on
		# the route -- so the catalogue traffic check (b) just made shares the bucket
		# with this route and with /auth/*. Being rate-limited is the server working;
		# wait the window out rather than report a red run, exactly as check (c) does.
		print("   the 6-a-minute limiter is full; waiting %d s for the window."
			% THROTTLE_WINDOW_SECONDS)
		await get_tree().create_timer(THROTTLE_WINDOW_SECONDS).timeout
		registered = await Backend.ensure_device_registered()
	_expect(bool(registered[Backend.KEY_OK]),
		"POST /device/register answered with no auth at all (%s %s)"
		% [registered[Backend.KEY_CODE], registered[Backend.KEY_MESSAGE]])
	if not Backend.is_device_registered():
		_expect(false, "the rest of check (n) needs a device token")
		return

	# --- the two identities, and the one ability that separates them ---------
	_expect(Backend.get_device_uid() == uid_before,
		"...for the SAME device_uid sign-in will send, so adoption can find this row")
	_expect(not Backend.has_account() and not Backend.is_signed_in(),
		"...without creating an account (has_account %s)" % Backend.has_account())
	_expect(_auth.get_live_token() == "",
		"...and get_live_token() -- the ACCOUNT accessor -- is still empty")
	_expect(_auth.get_entitlement_token() == _auth.get_live_anonymous_token()
			and _auth.get_entitlement_token() != "",
		"...while get_entitlement_token() is now the anonymous one")
	var abilities := _auth.get_anonymous_abilities()
	_expect(Array(abilities).has("entitlements:read") and Array(abilities).has("packs:download"),
		"the device token carries the two ownership abilities (%s)" % [abilities])
	_expect(not Array(abilities).has("save:sync"),
		"...and NEVER save:sync -- an anonymous device can own packs, never upload a picture")

	# The BL-52 non-negotiable, from the client's side: an anonymous token must not
	# turn save-sync on. It keys off the account accessor, which is still "".
	var queue := Backend.get_sync_queue()
	_expect(queue != null and not queue.is_active(),
		"the sync queue is STILL inert -- an anonymous token does not switch sync on")
	_expect(Backend.get_sync_status_text() == Backend.SYNC_OFF_TEXT,
		"...and the account panel still reads '%s'" % Backend.get_sync_status_text())
	_expect(not Backend.has_pending_sync(), "...with nothing queued to go up")

	# --- GET /entitlements answers for a device, not just for a user ---------
	var listed: Dictionary = await Backend.refresh_entitlements()
	_expect(bool(listed[Backend.KEY_OK]),
		"GET /entitlements works on a device token (%s)" % listed[Backend.KEY_CODE])
	_expect(_entitlements.has_data() and not Backend.owns_pack(PAID_SLUG),
		"...and this device owns nothing yet, because nothing has been verified")

	# --- the receipt seam ----------------------------------------------------
	var rejected: Dictionary = await Backend.verify_purchase(
		STORE_PLATFORM, BAD_RECEIPT, PAID_SKU)
	_expect(not bool(rejected[Backend.KEY_OK])
			and String(rejected[Backend.KEY_CODE]) == ApiClient.CODE_RECEIPT_INVALID,
		"a receipt the store refuses is %s -- final, not worth retrying (%s)"
		% [ApiClient.CODE_RECEIPT_INVALID, rejected[Backend.KEY_CODE]])
	_expect(not ApiClient.is_verify_retryable(rejected),
		"...and the client can tell that from the code alone")

	var unknown: Dictionary = await Backend.verify_purchase(
		STORE_PLATFORM, GOOD_RECEIPT, "coloringbook.no.such.product")
	_expect(not bool(unknown[Backend.KEY_OK])
			and String(unknown[Backend.KEY_CODE]) == ApiClient.CODE_NOT_FOUND,
		"a SKU nobody sells is the house %s, so verify is not a price-list enumerator (%s)"
		% [ApiClient.CODE_NOT_FOUND, unknown[Backend.KEY_CODE]])

	var granted: Dictionary = await Backend.verify_purchase(
		STORE_PLATFORM, GOOD_RECEIPT, PAID_SKU)
	_expect(bool(granted[Backend.KEY_OK]),
		"a good receipt grants the pack (%s %s)"
		% [granted[Backend.KEY_CODE], granted[Backend.KEY_MESSAGE]])
	var row: Variant = granted[Backend.KEY_DATA]
	_expect(typeof(row) == TYPE_DICTIONARY
			and String((row as Dictionary).get("pack_slug", "")) == PAID_SLUG,
		"...answering ONE entitlement row, for the pack the SKU named (%s)"
		% (String((row as Dictionary).get("pack_slug", "?")) if typeof(row) == TYPE_DICTIONARY
			else "not a row"))
	_expect(typeof(row) == TYPE_DICTIONARY
			and String((row as Dictionary).get("source", "")) == "purchase",
		"...recorded as a purchase rather than a free claim")

	var again: Dictionary = await Backend.verify_purchase(
		STORE_PLATFORM, GOOD_RECEIPT, PAID_SKU)
	_expect(bool(again[Backend.KEY_OK]),
		"re-verifying the SAME receipt is another 200, not a conflict (%s)"
		% again[Backend.KEY_CODE])
	_expect(Backend.get_entitlements().size() == 1,
		"...and it is still ONE row: every launch may ask (%d)"
		% Backend.get_entitlements().size())

	# --- what the device owns, everywhere it is asked ------------------------
	_expect(Backend.owns_pack(PAID_SLUG), "the cache says this device owns '%s'" % PAID_SLUG)
	var painted: Dictionary = await Backend.fetch_packs()
	var paid := _row_with_slug(painted[Backend.KEY_DATA], PAID_SLUG)
	_expect(bool(paid.get("owned", false)),
		"...and GET /packs paints owned:true for a DEVICE token too (BL-52)")

	var bought: Dictionary = await Backend.install_pack(PAID_SLUG)
	_expect(bool(bought[PackInstaller.KEY_OK]),
		"a PAID pack downloads onto a device nobody has signed in on (%s %s)"
		% [bought[PackInstaller.KEY_CODE], bought[PackInstaller.KEY_MESSAGE]])
	_expect(Backend.is_pack_installed(PAID_SLUG),
		"...which is 'bought once, owned everywhere' with no email address in it")
	# Off the shelf again: every later check counts what is installed.
	Backend.uninstall_pack(PAID_SLUG)


# ======================================================== c: register + token ==

func _check_auth() -> void:
	print("\n-- check c: register, sign in, and what lands in auth.json --")

	_email = "wp10-smoke-%d-%d@example.test" % [
		int(Time.get_unix_time_from_system()), randi() % 100000
	]
	_write_text(EMAIL_FILE, _email)
	print("   scratch account: %s" % _email)

	var device_uid := Backend.get_device_uid()
	_expect(device_uid.length() == 26,
		"a device uid was generated before any request (%s)" % device_uid)

	var registered: Dictionary = await Backend.register(_email, SCRATCH_PASSWORD, true)
	if String(registered[Backend.KEY_CODE]) == ApiClient.CODE_THROTTLED:
		# The auth routes are throttle:6,1 (DLC_SERVER.md 4.2). Two runs of this
		# smoke inside a minute hit it, which is a property of the SERVER working,
		# not a failure -- so wait the window out rather than reporting a red run.
		print("   auth routes are rate-limited; waiting %d s for the window."
			% THROTTLE_WINDOW_SECONDS)
		await get_tree().create_timer(THROTTLE_WINDOW_SECONDS).timeout
		registered = await Backend.register(_email, SCRATCH_PASSWORD, true)
	_expect(bool(registered[Backend.KEY_OK]),
		"register + sign in succeeded (%s %s)"
		% [registered[Backend.KEY_CODE], registered[Backend.KEY_MESSAGE]])
	if not Backend.is_signed_in():
		_expect(false, "the run cannot continue without a token")
		return

	_expect(Backend.is_signed_in(), "the device is signed in")
	_expect(Backend.get_account_email() == _email,
		"...as the account we registered (%s)" % Backend.get_account_email())
	_expect(Backend.get_device_uid() == device_uid,
		"...still the SAME device uid -- one installation is one dashboard row")
	_expect(FileAccess.file_exists(TEST_AUTH_PATH),
		"auth.json was written (%s)" % TEST_AUTH_PATH.get_file())

	var stored: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_AUTH_PATH))
	_expect(typeof(stored) == TYPE_DICTIONARY
			and String((stored as Dictionary).get("token", "")) != "",
		"...with a bearer token in it")
	_expect(typeof(stored) == TYPE_DICTIONARY
			and int((stored as Dictionary).get("expires_at", 0))
				> int(Time.get_unix_time_from_system()),
		"...and a future expiry parsed out of the ISO-8601 the server sent")
	_expect(_auth.has_ability("packs:download") and _auth.has_ability("entitlements:read")
			and _auth.has_ability("save:sync"),
		"the token carries exactly the three game abilities (%s)" % [_auth.get_abilities()])
	_expect(not _auth.is_expired(), "the token is live")

	# --- BL-52: adoption, which is what makes linking OPTIONAL ---------------
	# The sign-in carried the same device_uid check (n) registered under, so the
	# server moved that device's entitlements onto the account and revoked its
	# tokens, inside the transaction that minted this one.
	_expect(not _auth.has_anonymous_token(),
		"the anonymous token is gone -- the server revoked it, so we do not keep the string")
	_expect(_auth.get_entitlement_token() == _auth.get_live_token(),
		"...and the entitlement accessor is the ACCOUNT token again")
	# sign_in() refreshes the list without anybody awaiting it (8.2), so the shelf
	# catches up on its own; this only has to see it land. Waiting on the ACCOUNT
	# STAMP rather than on the pack matters: the anonymous cache is deliberately
	# carried over rather than cleared (an empty list would blink every DLC book off
	# the shelf for a frame), so "we own it" was already true and would have proved
	# nothing about adoption.
	if not await _wait_for(func() -> bool: return _entitlements.get_account() == _email):
		await Backend.refresh_entitlements()
	_expect(_entitlements.get_account() == _email,
		"the cache now belongs to the grown-up who signed in (%s)"
		% _entitlements.get_account())
	_expect(Backend.owns_pack(PAID_SLUG),
		"...and what the DEVICE bought anonymously is the ACCOUNT's ('%s' adopted)"
		% PAID_SLUG)

	var me: Dictionary = await Backend.fetch_me()
	_expect(bool(me[Backend.KEY_OK]), "GET /me works with the stored bearer")
	var me_data: Variant = me[Backend.KEY_DATA]
	_expect(typeof(me_data) == TYPE_DICTIONARY
			and String(((me_data as Dictionary).get("user", {}) as Dictionary).get("email", ""))
				== _email,
		"...and the server agrees which account this is")

	# A wrong password must not disturb the token we already have.
	var bad: Dictionary = await Backend.sign_in(_email, "not-the-password")
	if String(bad[Backend.KEY_CODE]) == ApiClient.CODE_THROTTLED:
		# Same `throttle:6,1` the register above already waits out (DLC_SERVER.md
		# 4.2): register + token + this one is three of the six, and a second run of
		# this smoke inside the window spends the rest. Being rate-limited is the
		# server working, so wait rather than report a red run.
		print("   auth routes are rate-limited again; waiting %d s for the window."
			% THROTTLE_WINDOW_SECONDS)
		await get_tree().create_timer(THROTTLE_WINDOW_SECONDS).timeout
		bad = await Backend.sign_in(_email, "not-the-password")
	_expect(not bool(bad[Backend.KEY_OK])
			and String(bad[Backend.KEY_CODE]) == ApiClient.CODE_INVALID_CREDENTIALS,
		"a wrong password is %s, branchable without reading prose (%s)"
		% [ApiClient.CODE_INVALID_CREDENTIALS, bad[Backend.KEY_CODE]])
	_expect(Backend.is_signed_in() and Backend.get_account_email() == _email,
		"...and the device is still signed in with the good token")


# ============================================== d: the catalogue and the cache ==

func _check_catalog() -> void:
	print("\n-- check d: GET /packs and GET /entitlements --")
	if not Backend.is_signed_in():
		_expect(false, "signed in, so the catalogue can be read")
		return

	var packs: Dictionary = await Backend.fetch_packs()
	_expect(bool(packs[Backend.KEY_OK]),
		"GET /packs answered (%s)" % packs[Backend.KEY_CODE])
	var rows: Variant = packs[Backend.KEY_DATA]
	_expect(typeof(rows) == TYPE_ARRAY and not (rows as Array).is_empty(),
		"...with at least one published pack")
	var coyote := _row_with_slug(rows, PACK_SLUG)
	_expect(coyote != null, "'%s' is on the shelf-to-be" % PACK_SLUG)
	if coyote == null:
		return
	_expect(bool(coyote.get("is_free", false)),
		"...flagged free by the SERVER, not decided here (DLC_SERVER.md 9)")
	_expect(int(coyote.get("bytes", 0)) > 100000,
		"...with a real archive size for the download question (%d bytes)"
		% int(coyote.get("bytes", 0)))
	_expect(int(coyote.get("latest_version", 0)) >= 1,
		"...and a monotonic pack_version (%d)" % int(coyote.get("latest_version", 0)))
	_expect(BackendConfig.satisfies_min_version(String(coyote.get("min_client_version", ""))),
		"...whose min_client_version (%s) this build satisfies"
		% coyote.get("min_client_version", ""))

	# A free pack is only GRANTED on the first manifest/download hit, so before the
	# install the server correctly says we do not own it yet.
	_expect(not bool(coyote.get("owned", true)),
		"a free pack reads owned:false until it is claimed -- ownership is the server's")

	var entitlements: Dictionary = await Backend.refresh_entitlements()
	_expect(bool(entitlements[Backend.KEY_OK]),
		"GET /entitlements answered (%s)" % entitlements[Backend.KEY_CODE])
	_expect(_entitlements.has_data() and _entitlements.is_fresh(),
		"...and the cache is populated and fresh")
	_expect(not Backend.owns_pack(PACK_SLUG),
		"...not owning '%s', because a public fetch never claimed it" % PACK_SLUG)


# ======================================= e: the download, and the atomic swap ==

func _check_install() -> void:
	print("\n-- check e: downloading and installing a real pack --")
	if not Backend.is_signed_in():
		_expect(false, "signed in, so a pack can be installed")
		return

	_progress.clear()
	var progress_hook := func(slug: String, downloaded: int, total: int) -> void:
		_progress.append([slug, downloaded, total])
	Backend.pack_install_progress.connect(progress_hook)
	var started := Time.get_ticks_msec()
	var result: Dictionary = await Backend.install_pack(PACK_SLUG)
	var elapsed := Time.get_ticks_msec() - started
	Backend.pack_install_progress.disconnect(progress_hook)

	_expect(bool(result[PackInstaller.KEY_OK]),
		"install_pack('%s') succeeded in %d ms (%s %s)"
		% [PACK_SLUG, elapsed, result[PackInstaller.KEY_CODE], result[PackInstaller.KEY_MESSAGE]])
	if not bool(result[PackInstaller.KEY_OK]):
		return
	_installed_bytes = int(result[PackInstaller.KEY_BYTES])
	_expect(int(result[PackInstaller.KEY_FILES]) >= 4,
		"...unpacking %d files, %s" % [int(result[PackInstaller.KEY_FILES]),
			PackShop.PackRow.format_bytes(_installed_bytes)])

	# Real progress from HTTPRequest.get_downloaded_bytes() (DLC_SERVER.md 7.4).
	_expect(_progress.size() >= 2,
		"the download reported progress %d times" % _progress.size())
	var peak := 0
	for entry: Array in _progress:
		peak = maxi(peak, int(entry[1]))
	_expect(peak > 100000,
		"...counting real bytes off the wire, up to %s" % PackShop.PackRow.format_bytes(peak))

	var pack_root := TEST_DLC_ROOT.path_join(PACK_SLUG)
	_expect(DirAccess.dir_exists_absolute(pack_root),
		"the pack is installed at %s" % pack_root)
	_expect(not DirAccess.dir_exists_absolute(pack_root + PackInstaller.INCOMING_SUFFIX),
		"...and the .incoming directory it downloaded into is gone")
	_expect(not DirAccess.dir_exists_absolute(pack_root + PackInstaller.REPLACED_SUFFIX),
		"...as is the .tmp the swap moves an old install to")
	_expect(not FileAccess.file_exists(pack_root.path_join(PackInstaller.ARCHIVE_NAME)),
		"...and the zip was deleted once unpacked")

	# --- verify every sha256 AGAIN, here, from the manifest ------------------
	var manifest := Backend.get_installer().installed_manifest(PACK_SLUG)
	_expect(int(manifest.get("pack_version", 0)) >= 1,
		"the manifest was written into the pack, recording version %s (7.3's update check)"
		% manifest.get("pack_version", "?"))
	_expect(Backend.installed_pack_version(PACK_SLUG) == int(manifest.get("pack_version", 0)),
		"...and installed_pack_version() reads it back (%d)"
		% Backend.installed_pack_version(PACK_SLUG))
	var files: Variant = manifest.get("files", {})
	var checked := 0
	var mismatches := PackedStringArray()
	if typeof(files) == TYPE_DICTIONARY:
		for relative: Variant in (files as Dictionary):
			var absolute := pack_root.path_join(String(relative))
			var expected := String(((files as Dictionary)[relative] as Dictionary).get("sha256", ""))
			var bytes := int(((files as Dictionary)[relative] as Dictionary).get("bytes", 0))
			if not FileAccess.file_exists(absolute):
				mismatches.append("%s missing" % relative)
				continue
			checked += 1
			if FileAccess.get_sha256(absolute).to_lower() != expected.to_lower():
				mismatches.append("%s sha256" % relative)
			elif bytes > 0 and _file_size(absolute) != bytes:
				mismatches.append("%s size" % relative)
	_expect(checked >= 4 and mismatches.is_empty(),
		"every one of the %d manifest files is on disk with the right sha256 and size (%s)"
		% [checked, "clean" if mismatches.is_empty() else ", ".join(mismatches)])

	# The installed pack is a WP7-shaped tree the game can already read.
	var book_json := pack_root.path_join("books").path_join(COYOTE_UID) \
		.path_join(BookDef.BOOK_JSON_NAME)
	_expect(FileAccess.file_exists(book_json),
		"the pack contains the self-describing book.json the game actually reads")
	_expect(not ResourceLoader.exists(pack_root.path_join("books").path_join(COYOTE_UID)
			.path_join("page_01_idmap.png")),
		"...and its ID map is a plain file, never an imported resource (7.1)")

	# Installing claimed the free pack server-side; the cache should now agree.
	_expect(Backend.owns_pack(PACK_SLUG),
		"the free pack auto-granted on the manifest hit and the cache refreshed")
	_expect(_entitlements.latest_version(PACK_SLUG) == Backend.installed_pack_version(PACK_SLUG),
		"latest_version == installed version, so nothing needs updating")
	_expect(Backend.packs_needing_update().is_empty(),
		"...which is what packs_needing_update() says (%s)" % [Backend.packs_needing_update()])


# ================================================ m: the delta update (BL-26) ==

## An update must move the DIFFERENCE, not the pack.
##
## [b]Needs two published versions of the fixture pack on the dev server[/b], the
## second differing from the first in exactly one file. That is not a test fixture,
## it is how a real fix ships -- versions are assigned by the server and immutable
## (DLC_SERVER.md 7.3), so publishing the same directory twice IS the workflow:
## [codeblock]
## php artisan pack:publish build/packs/coyote-book          # v1
## cp -r build/packs/coyote-book /tmp/v2 && edit one file    # rehash it in
## php artisan pack:publish /tmp/v2                            manifest.json
## [/codeblock]
##
## The order below is deliberate: the FALLBACK's archive install is also the
## reference tree, so one full-zip install of v2 proves both halves of "byte
## identical" -- the delta's tree and the fallback's tree are compared against the
## same thing, and the run costs two installs of each version rather than three.
func _check_delta_update() -> void:
	print("\n-- check m: an update downloads the difference, not the pack (BL-26) --")
	if not Backend.is_signed_in():
		_expect(false, "signed in, so a pack can be updated")
		return

	# --- 0. what actually changed, read off the two manifests ----------------
	var first := await _published_files(1)
	var second := await _published_files(2)
	if first.is_empty() or second.is_empty():
		_expect(false, ("the dev server publishes at least TWO versions of '%s'"
			+ " -- see this check's doc comment for the two publish commands") % PACK_SLUG)
		return
	var changed := PackedStringArray()
	var changed_bytes := 0
	for path: Variant in second:
		var before: Variant = first.get(path, null)
		var after := second[path] as Dictionary
		if typeof(before) != TYPE_DICTIONARY \
				or String((before as Dictionary).get("sha256", "")) != String(after.get("sha256", "")):
			changed.append(String(path))
			changed_bytes += int(after.get("bytes", 0))
	_expect(changed.size() == 1 and changed_bytes > 0,
		"v1 -> v2 differs in exactly one file, %s of it (%s)"
		% [PackShop.PackRow.format_bytes(changed_bytes), ", ".join(changed)])
	if changed.size() != 1:
		return
	var pack_root := TEST_DLC_ROOT.path_join(PACK_SLUG)

	# --- 1. v1, from nothing: there is no delta against an empty shelf -------
	Backend.uninstall_pack(PACK_SLUG)
	var one := await _install_version(1)
	_expect(bool(one[PackInstaller.KEY_OK])
			and String(one[PackInstaller.KEY_MODE]) == PackInstaller.MODE_ARCHIVE
			and Backend.installed_pack_version(PACK_SLUG) == 1,
		"a FIRST install takes the archive (%s, v%d)"
		% [one[PackInstaller.KEY_MODE], Backend.installed_pack_version(PACK_SLUG)])

	# --- 2. the fallback, and the reference tree it leaves behind ------------
	Backend.get_installer().fail_next_delta_fetch(0)
	var fell_back := await _install_version(2)
	_expect(bool(fell_back[PackInstaller.KEY_OK])
			and String(fell_back[PackInstaller.KEY_MODE]) == PackInstaller.MODE_ARCHIVE,
		"a delta whose per-file fetch fails falls back to the ARCHIVE and still installs (%s %s, %s)"
		% [fell_back[PackInstaller.KEY_CODE], fell_back[PackInstaller.KEY_MESSAGE],
			fell_back[PackInstaller.KEY_MODE]])
	_expect(Backend.installed_pack_version(PACK_SLUG) == 2,
		"...at the version that was asked for (v%d)" % Backend.installed_pack_version(PACK_SLUG))
	_expect(not DirAccess.dir_exists_absolute(pack_root + PackInstaller.INCOMING_SUFFIX),
		"...leaving no half-built .incoming behind it")
	var reference := _tree_digest(pack_root)
	_expect(reference.size() == second.size() + 1,
		"the full-zip install of v2 holds %d manifest files plus its own manifest.json"
		% second.size())

	# --- 3. back to v1, so there is something to diff against ----------------
	Backend.uninstall_pack(PACK_SLUG)
	var again := await _install_version(1)
	_expect(bool(again[PackInstaller.KEY_OK]) and Backend.installed_pack_version(PACK_SLUG) == 1,
		"v1 is installed again, so the next install is a real update")

	# --- 4. the update, as a delta -------------------------------------------
	var update := await _install_version(2)
	_expect(bool(update[PackInstaller.KEY_OK]),
		"the update to v2 succeeded (%s %s)"
		% [update[PackInstaller.KEY_CODE], update[PackInstaller.KEY_MESSAGE]])
	if not bool(update[PackInstaller.KEY_OK]):
		return
	_expect(String(update[PackInstaller.KEY_MODE]) == PackInstaller.MODE_DELTA,
		"...as a DELTA (%s)" % update[PackInstaller.KEY_MODE])
	var fetched := update[PackInstaller.KEY_FETCHED_PATHS] as PackedStringArray
	_expect(Array(fetched) == Array(changed),
		"...fetching EXACTLY the file that changed (%s)" % ", ".join(fetched))
	_expect(int(update[PackInstaller.KEY_FETCHED_BYTES]) == changed_bytes,
		"...and only its %s -- the pack itself is %s (%.1f%%)"
		% [PackShop.PackRow.format_bytes(int(update[PackInstaller.KEY_FETCHED_BYTES])),
			PackShop.PackRow.format_bytes(int(update[PackInstaller.KEY_BYTES])),
			100.0 * float(update[PackInstaller.KEY_FETCHED_BYTES])
				/ maxf(float(update[PackInstaller.KEY_BYTES]), 1.0)])
	_expect(int(update[PackInstaller.KEY_COPIED_FILES]) == second.size() - changed.size(),
		"...taking the other %d files off the previous install instead of the wire"
		% int(update[PackInstaller.KEY_COPIED_FILES]))
	_expect(Backend.installed_pack_version(PACK_SLUG) == 2,
		"...and the installed version moved to v%d" % Backend.installed_pack_version(PACK_SLUG))

	# The bar must count against what is actually travelling (BL-26), or a 567-byte
	# update would crawl across a 950 KB scale and look broken.
	var reported := 0
	for entry: Array in _progress:
		reported = maxi(reported, int(entry[2]))
	_expect(reported == changed_bytes,
		"the progress total is the DELTA's size, not the pack's (%s)"
		% PackShop.PackRow.format_bytes(reported))

	# --- 5. and the result is the same tree, file for file -------------------
	var difference := _tree_difference(_tree_digest(pack_root), reference)
	_expect(difference.is_empty(),
		"the delta-built install is byte-identical to the full-zip install of v2 (%s)"
		% ("identical" if difference.is_empty() else ", ".join(difference)))


## The `files` map of one published version, or {} when there is no such version.
func _published_files(version: int) -> Dictionary:
	var result: Dictionary = await Backend.get_api().request_json(
		HTTPClient.METHOD_GET, "/packs/%s/manifest" % PACK_SLUG, null,
		{"query": {"version": str(version)}}
	)
	if not bool(result[ApiClient.KEY_OK]) or typeof(result[ApiClient.KEY_DATA]) != TYPE_DICTIONARY:
		return {}
	var files: Variant = (result[ApiClient.KEY_DATA] as Dictionary).get("files", {})
	return files as Dictionary if typeof(files) == TYPE_DICTIONARY else {}


## One install, with [member _progress] refilled from the real progress signal.
func _install_version(version: int) -> Dictionary:
	_progress.clear()
	var hook := func(slug: String, downloaded: int, total: int) -> void:
		_progress.append([slug, downloaded, total])
	Backend.pack_install_progress.connect(hook)
	var result: Dictionary = await Backend.install_pack(PACK_SLUG, version)
	Backend.pack_install_progress.disconnect(hook)
	return result


## pack-relative path -> sha256, for every file in an installed tree. The comparison
## "byte-identical" is made of.
static func _tree_digest(root: String, prefix: String = "") -> Dictionary:
	var digests := {}
	var directory := DirAccess.open(root)
	if directory == null:
		return digests
	for name in directory.get_files():
		digests[prefix + name] = FileAccess.get_sha256(root.path_join(name)).to_lower()
	for name in directory.get_directories():
		digests.merge(_tree_digest(root.path_join(name), prefix + name + "/"))
	return digests


static func _tree_difference(a: Dictionary, b: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for path: Variant in a:
		if not b.has(path):
			out.append("only in the delta: %s" % path)
		elif String(a[path]) != String(b[path]):
			out.append("different bytes: %s" % path)
	for path: Variant in b:
		if not a.has(path):
			out.append("only in the archive: %s" % path)
	return out


# ================================================= f: discovery and de-duping ==

func _check_discovery() -> void:
	print("\n-- check f: the installed pack is discoverable AND shelf-invisible --")

	var runtime := BookDef.discover_runtime(TEST_DLC_ROOT)
	_expect(runtime.size() == 1,
		"discover_runtime() finds exactly one book in the installed pack (%d)" % runtime.size())
	if runtime.is_empty():
		return
	var downloaded := runtime[0]
	_expect(downloaded.get_uid() == COYOTE_UID,
		"...and it is '%s' (%s)" % [COYOTE_UID, downloaded.get_uid()])
	_expect(downloaded.is_runtime and downloaded.pack_slug == PACK_SLUG,
		"...marked runtime, from pack '%s'" % downloaded.pack_slug)
	_expect(downloaded.validate().is_empty(),
		"...and it validates against the bytes on disk (%s)" % [downloaded.validate()])
	_expect(downloaded.page_count() == 1,
		"...with its one page (%d)" % downloaded.page_count())

	# THE assertion this pack exists to make (SERVER_BUILD_PLAN WP7/WP9): the first
	# published pack deliberately ships the book the build already contains, so the
	# download path can be exercised end to end without a second book. It must
	# therefore be invisible on the shelf.
	var shelf := BookDef.discover(BookDef.BOOKS_ROOT, TEST_DLC_ROOT)
	_expect(shelf.size() == BUILTIN_BOOK_COUNT,
		"discover() STILL returns %d books after the install (%d: %s)"
		% [BUILTIN_BOOK_COUNT, shelf.size(), _names(shelf)])
	var coyotes := 0
	var survivor: BookDef = null
	for book in shelf:
		if book.get_uid() == COYOTE_UID:
			coyotes += 1
			survivor = book
	_expect(coyotes == 1, "...'%s' appears exactly ONCE (%d)" % [COYOTE_UID, coyotes])
	_expect(survivor != null and not survivor.is_runtime,
		"...and the copy that survived is the BUILT-IN one -- built-in wins de-duplication")
	_expect(survivor != null and survivor.resource_path.begins_with("res://"),
		"...loaded from the build (%s)" % (survivor.resource_path if survivor else "?"))
	_expect(GameState.book_key(downloaded) == GameState.book_key(survivor),
		"...and both key the same save entry, so a download never orphans progress (%s)"
		% GameState.book_key(downloaded))

	_expect(Backend.discover_visible_books(BookDef.BOOKS_ROOT, TEST_DLC_ROOT).size()
			== BUILTIN_BOOK_COUNT,
		"the shelf main.gd builds is the same %d books" % BUILTIN_BOOK_COUNT)


# ====================================== g: the entitlement filter, and offline ==

func _check_entitlement_filter() -> void:
	print("\n-- check g: hiding a revoked pack without deleting a single byte --")

	var runtime := BookDef.discover_runtime(TEST_DLC_ROOT)
	if runtime.is_empty():
		_expect(false, "there is an installed DLC book to filter")
		return
	var book := runtime[0]
	var pack_root := TEST_DLC_ROOT.path_join(PACK_SLUG)

	_expect(Backend.is_book_visible(book), "an owned pack's book is visible")

	# A successful fetch that OMITS the pack is the server revoking it -- the only
	# thing that may ever hide a book (DLC_SERVER.md 9).
	_entitlements.store([], Backend.get_account_email())
	_expect(_entitlements.should_hide_book(PACK_SLUG),
		"a successful fetch that omits the pack means revoked")
	_expect(not Backend.is_book_visible(book), "...so its book leaves the shelf")
	_expect(Backend.filter_books(BookDef.discover(BookDef.BOOKS_ROOT, TEST_DLC_ROOT)).size()
			== BUILTIN_BOOK_COUNT,
		"...and the shelf is the built-ins only")
	_expect(DirAccess.dir_exists_absolute(pack_root)
			and FileAccess.file_exists(pack_root.path_join("manifest.json")),
		"...but NOT ONE FILE was deleted (7.3: the pixels a child painted stay)")

	# Never fetched at all is NOT a revocation.
	_entitlements.clear()
	_expect(not _entitlements.has_data() and not _entitlements.should_hide_book(PACK_SLUG),
		"an EMPTY cache is not a revocation -- a fresh install hides nothing")
	_expect(Backend.is_book_visible(book), "...so the book is on the shelf again")

	# Neither is being offline. Point the client at a dead port and prove the last
	# known good list survives (DLC_SERVER.md 8.2, 9).
	await Backend.refresh_entitlements()
	_expect(Backend.owns_pack(PACK_SLUG), "a real refresh repopulated the cache")
	var age_before := _entitlements.get_age_seconds()
	Backend.get_api().set_base_url("http://127.0.0.1:1/api/v1")
	var offline: Dictionary = await Backend.refresh_entitlements()
	Backend.get_api().set_base_url(_base_url)
	_expect(not bool(offline[Backend.KEY_OK])
			and String(offline[Backend.KEY_CODE]) in [ApiClient.CODE_OFFLINE, ApiClient.CODE_TIMEOUT],
		"a refresh with no server fails as %s" % offline[Backend.KEY_CODE])
	_expect(Backend.owns_pack(PACK_SLUG),
		"...and the LAST KNOWN GOOD list is untouched, so nothing vanished offline")
	_expect(_entitlements.get_age_seconds() >= age_before,
		"...the cache was not re-stamped by a failure")
	_expect(Backend.is_book_visible(book), "...and the book is still on the shelf")


# ====================================== h: an expired token means offline, quietly ==

func _check_expired_token() -> void:
	print("\n-- check h: an expired token is silent offline mode --")

	var live := _auth.get_token()
	_auth.store_token(live, _auth.get_email(), _auth.get_abilities(),
		int(Time.get_unix_time_from_system()) - 10)
	# Re-inject the store so the facade re-reads it: expiry is a CLIENT-side belief,
	# and the point of the check is that the belief stops the bearer header leaving.
	# Without this the ApiClient would still be holding the (server-side perfectly
	# good) token, and the two "tokenless" requests below would be authorised ones.
	Backend.use_test_stores(_auth, _entitlements, TEST_DLC_ROOT, _base_url)
	_expect(_auth.has_account() and _auth.is_expired(),
		"the stored token is now expired")
	_expect(not Backend.is_signed_in(), "...so the device is not signed in")
	_expect(Backend.is_token_expired(),
		"...and the account panel can tell 'expired' from 'never signed in'")
	_expect(_auth.get_live_token() == "",
		"...no dead bearer is ever sent (get_live_token is empty)")

	var runtime := BookDef.discover_runtime(TEST_DLC_ROOT)
	_expect(not runtime.is_empty() and Backend.is_book_visible(runtime[0]),
		"the DLC book is STILL on the shelf -- an expired token never takes a book away")

	# BL-52 split this in two, and the split IS the entry. A lapsed token sends no
	# bearer header, so both of these are tokenless requests to the same server --
	# and the pack decides the answer, not the player.
	var blocked: Dictionary = await Backend.install_pack(PAID_SLUG)
	_expect(not bool(blocked[Backend.KEY_OK])
			and String(blocked[Backend.KEY_CODE]) == ApiClient.CODE_UNAUTHENTICATED,
		"a PAID pack is refused while the token is expired (%s)" % blocked[Backend.KEY_CODE])
	_expect(not Backend.is_pack_installed(PAID_SLUG),
		"...and did not land on disk")
	var still_free: Dictionary = await Backend.install_pack(PACK_SLUG)
	_expect(bool(still_free[PackInstaller.KEY_OK]),
		"...while the FREE one still installs, because its bytes never needed the token (%s)"
		% still_free[PackInstaller.KEY_CODE])
	_expect(Backend.installed_pack_version(PACK_SLUG) >= 1,
		"...leaving the pack installed either way")

	# Put the live token back for the sign-out check.
	var future := int(Time.get_unix_time_from_system()) + 86400
	_auth.store_token(live, _auth.get_email(), _auth.get_abilities(), future)
	Backend.use_test_stores(_auth, _entitlements, TEST_DLC_ROOT, _base_url)
	_expect(Backend.is_signed_in(), "restoring the expiry signs the device back in")


# ================================== i: the checksum gate and the zip-slip guard ==

func _check_verification_gates() -> void:
	print("\n-- check i: the gates a bad pack has to get past --")

	var pack_root := TEST_DLC_ROOT.path_join(PACK_SLUG)
	var manifest := Backend.get_installer().installed_manifest(PACK_SLUG)
	var files: Variant = manifest.get("files", {})
	if typeof(files) != TYPE_DICTIONARY or (files as Dictionary).is_empty():
		_expect(false, "there is a manifest to verify against")
		return

	_expect(bool(PackInstaller.verify_files(pack_root, files as Dictionary)[PackInstaller.KEY_OK]),
		"the installed pack passes verification")

	# A corrupt ID map would paint into the wrong regions, silently, for one child.
	var tampered := (files as Dictionary).duplicate(true)
	var victim := String((tampered as Dictionary).keys()[0])
	(tampered[victim] as Dictionary)["sha256"] = "0".repeat(64)
	var bad := PackInstaller.verify_files(pack_root, tampered)
	_expect(not bool(bad[PackInstaller.KEY_OK])
			and String(bad[PackInstaller.KEY_CODE]) == PackInstaller.CODE_CHECKSUM,
		"a single wrong sha256 fails the whole pack (%s)" % bad[PackInstaller.KEY_CODE])

	var absent := {"books/nope.png": {"sha256": "", "bytes": 1}}
	var missing := PackInstaller.verify_files(pack_root, absent)
	_expect(not bool(missing[PackInstaller.KEY_OK])
			and String(missing[PackInstaller.KEY_CODE]) == PackInstaller.CODE_MISSING_FILE,
		"a file the archive did not contain fails too (%s)" % missing[PackInstaller.KEY_CODE])

	_expect(PackInstaller.is_safe_entry("books/coyote-2026/page_01.png"),
		"a normal pack path unpacks")
	_expect(not PackInstaller.is_safe_entry("../../save_v2.json"),
		"...but a '..' entry cannot escape the pack directory")
	_expect(not PackInstaller.is_safe_entry("/etc/passwd")
			and not PackInstaller.is_safe_entry("C:/Windows/x"),
		"...nor an absolute path or a drive letter")


# ============================================= j: the grown-up UI, headless ==

func _check_ui() -> void:
	print("\n-- check j: the adult gate and the pack-shop rows --")

	# --- the gate (DLC_SERVER.md 4.1) ----------------------------------------
	_expect(AdultGate.spell(27) == "twenty-seven",
		"the gate spells its numbers out in words ('%s')" % AdultGate.spell(27))
	_expect(AdultGate.spell(14) == "fourteen" and AdultGate.spell(30) == "thirty",
		"...for teens and round tens too")

	var gate := ADULT_GATE_SCENE.instantiate() as AdultGate
	add_child(gate)
	await get_tree().process_frame
	var passed := [false]
	gate.passed.connect(func() -> void: passed[0] = true)
	_expect(gate.get_question_text().begins_with("What is"),
		"the gate asks an arithmetic question ('%s')" % gate.get_question_text())
	gate.set_answer_text(str(gate.get_expected_answer() + 1))
	_expect(not gate.submit() and not passed[0], "a wrong answer does not open the account screen")
	_expect(gate.get_hint_text() != "", "...it says so ('%s')" % gate.get_hint_text())
	gate.set_answer_text(str(gate.get_expected_answer()))
	_expect(gate.submit() and passed[0], "the right answer passes the gate")
	remove_child(gate)
	gate.queue_free()

	# --- the shop's row state machine (DLC_SERVER.md 8.2) --------------------
	var shop := PACK_SHOP_SCENE.instantiate() as PackShop
	add_child(shop)
	await get_tree().process_frame
	shop.set_packs([
		{"slug": PACK_SLUG, "title": "Coyote", "is_free": true, "owned": true,
			"bytes": 950022, "latest_version": Backend.installed_pack_version(PACK_SLUG),
			"min_client_version": "0.6.0", "page_count": 1},
		{"slug": "future-pack", "title": "Future Friends", "is_free": true, "owned": false,
			"bytes": 2500000, "latest_version": 3, "min_client_version": "99.0.0",
			"page_count": 12},
		{"slug": "new-pack", "title": "New Friends", "is_free": true, "owned": false,
			"bytes": 2500000, "latest_version": 1, "min_client_version": "0.1.0",
			"page_count": 12},
	])
	_expect(shop.get_rows().size() == 3, "the shop listed %d packs" % shop.get_rows().size())

	var installed_row := shop.get_row(PACK_SLUG)
	_expect(installed_row != null
			and installed_row.get_state() == PackShop.PackRow.STATE_INSTALLED,
		"an installed, up-to-date pack reads 'on the shelf' (%s)"
		% (installed_row.get_state() if installed_row else "?"))

	var blocked_row := shop.get_row("future-pack")
	_expect(blocked_row != null and blocked_row.get_state() == PackShop.PackRow.STATE_BLOCKED,
		"a pack needing a newer app is BLOCKED client-side too (%s)"
		% (blocked_row.get_state() if blocked_row else "?"))
	_expect(blocked_row != null and blocked_row.get_action_button().disabled,
		"...and cannot be tapped")

	var new_row := shop.get_row("new-pack")
	_expect(new_row != null and new_row.get_state() == PackShop.PackRow.STATE_AVAILABLE,
		"a new pack is available")
	if new_row != null:
		# Take the shop's own handler off first: this check is about the row's
		# confirm step, and "new-pack" does not exist on the server -- letting the
		# real install fire would put a doomed request in flight underneath the
		# checks that follow.
		for connection: Dictionary in new_row.download_requested.get_connections():
			new_row.download_requested.disconnect(connection["callable"])
		var requested := [0]
		new_row.download_requested.connect(func() -> void: requested[0] += 1)
		new_row.press_action()
		_expect(new_row.get_state() == PackShop.PackRow.STATE_CONFIRM and requested[0] == 0,
			"...tapping it ASKS first -- no download starts (8.2)")
		_expect("2.4 MB" in new_row.get_detail_text(),
			"...and the question names the real size ('%s')" % new_row.get_detail_text())
		new_row.press_action()
		_expect(requested[0] == 1, "...a second tap is the one that means yes")
		new_row.set_downloading(1250000, 2500000)
		_expect(absf(new_row.get_progress_ratio() - 0.5) < 0.01,
			"...and the bar tracks real bytes (%.2f)" % new_row.get_progress_ratio())

		# --- BL-31: the crayon strip is a SECOND rendering of those bytes ------
		# It may lag them by a few frames on purpose (the drawn head eases), so
		# what is asserted here is that it never becomes the source of truth.
		var strip := new_row.get_progress_strip()
		_expect(strip.visible and not strip.is_indeterminate(),
			"...drawn by a crayon strip that knows the size")
		for i in 10:
			await get_tree().process_frame
		_expect(absf(new_row.get_progress_ratio() - 0.5) < 0.01,
			"...whose easing never moves the reported ratio (%.2f)"
			% new_row.get_progress_ratio())
		_expect("Downloading" in new_row.get_detail_text(),
			"...nor the byte label ('%s')" % new_row.get_detail_text())

		new_row.set_downloading(4096, -1)
		_expect(absf(new_row.get_progress_ratio() - 0.0016) < 0.001,
			"a total of -1 falls back to the catalogue size (%.4f)"
			% new_row.get_progress_ratio())
		var sizeless := PackShop.PackRow.new({"slug": "sizeless", "title": "No size"})
		add_child(sizeless)
		sizeless.set_downloading(4096, 0)
		_expect(sizeless.get_progress_ratio() == 0.0,
			"a pack with NO known size still reports 0.0, exactly as the bar did (%.2f)"
			% sizeless.get_progress_ratio())
		_expect(sizeless.get_progress_strip().is_indeterminate(),
			"...and its strip scribbles instead of claiming a percentage")
		remove_child(sizeless)
		sizeless.queue_free()

		# --- BL-31: the finish ------------------------------------------------
		new_row.set_installed_version(1)
		_expect(new_row.get_state() == PackShop.PackRow.STATE_INSTALLED
				and strip.is_celebrating(),
			"a finished install gets a little celebration (%s)" % new_row.get_state())
		var waited := 0
		while strip.is_celebrating() and waited < 600:
			await get_tree().process_frame
			waited += 1
		_expect(not strip.is_celebrating() and not strip.visible,
			"...which packs itself away again after %d frames" % waited)
		_expect(new_row.get_detail_text() != "" and "Downloading" not in new_row.get_detail_text(),
			"...leaving the row's resting description ('%s')" % new_row.get_detail_text())

	_expect(PackShop.PackRow.format_bytes(950022) == "928 KB",
		"sizes are human-readable (%s)" % PackShop.PackRow.format_bytes(950022))
	remove_child(shop)
	shop.queue_free()

	# Error prose is derived from the machine-readable code, never the other way.
	_expect(AccountPanel.describe_error({Backend.KEY_CODE: ApiClient.CODE_OFFLINE})
			.contains("works fine without it"),
		"an offline sign-in reassures rather than alarms")
	_expect(AccountPanel.describe_error({Backend.KEY_CODE: ApiClient.CODE_INVALID_CREDENTIALS})
			!= "",
		"...and a bad password says so")


# ========================================= l: the wiring inside main.tscn ==
# The overlays are trivial on their own; what is worth proving is that the ORDER
# main.gd imposes is real -- there is no route from the settings panel to the
# account panel that does not go through the gate (DLC_SERVER.md 4.1) -- and that
# no kid-facing screen sprouts network state (8.2).

func _check_main_flow() -> void:
	print("\n-- check l: the account route through main.tscn --")

	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.quit_on_close_request = false
	add_child(main)
	if not await _wait_for(func() -> bool:
			return main.get_current_screen_id() != "" and not main.is_transitioning()):
		_expect(false, "main.tscn reached its first screen")
		main.free()
		return
	_expect(main.get_current_screen_id() == Main.SCREEN_TITLE,
		"main.tscn boots to the title (%s)" % main.get_current_screen_id())

	await main.show_book_select()
	_expect(main.get_current_screen_id() == Main.SCREEN_BOOK_SELECT, "the shelf is up")
	var shelf := main.get_current_screen() as BookSelect
	_expect(shelf != null and shelf.get_book_count() == BUILTIN_BOOK_COUNT,
		"...with %d books -- the installed pack is de-duped away, invisibly to the child"
		% (shelf.get_book_count() if shelf else -1))
	_expect(main.get_gear_button().visible, "the settings gear is on the shelf")
	_expect(main.get_more_books_button().visible,
		"...and 'More books' is there too, because this build has a server (BL-25)")

	# --- settings -> account, via the gate ------------------------------------
	var settings := main.open_settings()
	_expect(settings.get_account_text() == Backend.get_account_email(),
		"settings shows the signed-in account ('%s')" % settings.get_account_text())
	settings.get_account_button().pressed.emit()
	await get_tree().process_frame
	_expect(main.get_settings_panel() == null, "tapping Account closes settings")
	_expect(main.get_adult_gate() != null,
		"...and puts the ADULT GATE up (DLC_SERVER.md 4.1)")
	_expect(main.get_account_panel() == null,
		"...with no account screen behind it yet -- the gate is not decoration")

	var gate := main.get_adult_gate()
	gate.set_answer_text(str(gate.get_expected_answer() + 3))
	gate.get_submit_button().pressed.emit()
	await get_tree().process_frame
	_expect(main.get_adult_gate() != null and main.get_account_panel() == null,
		"a wrong answer gets no further")

	gate.set_answer_text(str(gate.get_expected_answer()))
	gate.get_submit_button().pressed.emit()
	await get_tree().process_frame
	_expect(main.get_adult_gate() == null, "the right answer dismisses the gate")
	var panel := main.get_account_panel()
	_expect(panel != null, "...and opens the account panel")
	if panel != null:
		_expect(panel.get_state() == AccountPanel.STATE_SIGNED_IN,
			"...in its signed-in state (%s)" % panel.get_state())
		# WP11: signed in, so the line is a real "last synced" (the sign-in itself
		# drains the queue). Its exact wording is sync_smoke's business; here it only
		# has to be the signed-in shape rather than "Sync off" or "Offline".
		_expect(panel.get_sync_text().begins_with("Last synced: "),
			"...showing a real sync line ('%s')" % panel.get_sync_text())
		_expect(panel.get_pictures_check() != null
				and panel.get_pictures_check().button_pressed == Backend.is_picture_sync_enabled(),
			"...and the 'Sync pictures' toggle (DLC_SERVER.md 6.2's metered-connection policy)")
		panel.get_close_button().pressed.emit()
		await get_tree().process_frame
		_expect(main.get_account_panel() == null, "and Done closes it")

	# --- the shelf's own affordance -------------------------------------------
	main.get_more_books_button().pressed.emit()
	await get_tree().process_frame
	var shop := main.get_pack_shop()
	_expect(shop != null, "'More books' opens the catalogue")
	if shop != null:
		shop.get_close_button().pressed.emit()
		await get_tree().process_frame
		_expect(main.get_pack_shop() == null, "...and closes again")

	# Leaving the shelf must take every grown-up overlay with it.
	await main.show_title()
	_expect(not main.get_gear_button().visible and not main.get_more_books_button().visible,
		"neither grown-up button survives a screen change")
	main.get_parent().remove_child(main)
	main.free()


func _wait_for(condition: Callable, seconds: float = 8.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return false


# ============================================================== k: signing out ==

func _check_sign_out() -> void:
	print("\n-- check k: signing out --")
	if not Backend.is_signed_in():
		_expect(false, "signed in, so signing out means something")
		return

	# Kept only long enough to prove the server really revoked it.
	var revoked := _auth.get_token()
	var result: Dictionary = await Backend.sign_out()
	# [b]Deliberately not asserted on `ok`.[/b] Signing out is unconditional
	# locally, and it has to be: DELETE /auth/token answers 204 No Content, and
	# under `php artisan serve` the socket closes before Godot's HTTPClient reads
	# the status line, so a sign-out that DID revoke the token reports a transport
	# error. What matters is the two lines below and the 401 further down -- the
	# state, not the courier.
	print("   sign-out reported: status=%s code=%s"
		% [result[ApiClient.KEY_STATUS], result[Backend.KEY_CODE]])
	_expect(not Backend.is_signed_in() and not Backend.has_account(),
		"the device is signed out whatever the server's answer looked like")
	_expect(_auth.get_token() == "" and _auth.get_email() == "",
		"...auth.json no longer holds a token or an email")
	_expect(_auth.get_device_uid().length() == 26,
		"...but the device uid is KEPT, so signing back in is the same dashboard row")
	_expect(not _entitlements.has_data(),
		"...the entitlement cache is dropped with the account it belonged to")

	# The rule this whole section exists for (DLC_SERVER.md 7.3).
	_expect(Backend.is_pack_installed(PACK_SLUG),
		"...and the downloaded pack is STILL ON DISK")
	var runtime := BookDef.discover_runtime(TEST_DLC_ROOT)
	_expect(runtime.size() == 1 and Backend.is_book_visible(runtime[0]),
		"...and its book is still discoverable and still visible")

	# The token really is dead server-side -- driven through the raw client, because
	# the facade correctly refuses to use a token it no longer has.
	Backend.get_api().set_token(revoked)
	var after: Dictionary = await Backend.get_api().request_json(HTTPClient.METHOD_GET, "/me")
	Backend.get_api().set_token("")
	_expect(not bool(after[ApiClient.KEY_OK])
			and int(after[ApiClient.KEY_STATUS]) == 401,
		"the revoked token is rejected by the server (%d %s)"
		% [int(after[ApiClient.KEY_STATUS]), after[ApiClient.KEY_CODE]])

	_expect(Backend.uninstall_pack(PACK_SLUG), "uninstall_pack() removes it on request")
	_expect(BookDef.discover_runtime(TEST_DLC_ROOT).is_empty(),
		"...and the shelf drops it on the next scan")


# ===================================================================== helpers ==

func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("%s - %s" % ["PASS" if condition else "FAIL", description])


static func _row_with_slug(rows: Variant, slug: String) -> Dictionary:
	if typeof(rows) != TYPE_ARRAY:
		return {}
	for raw: Variant in (rows as Array):
		if typeof(raw) == TYPE_DICTIONARY and String((raw as Dictionary).get("slug", "")) == slug:
			return raw as Dictionary
	return {}


static func _names(books: Array[BookDef]) -> String:
	var parts := PackedStringArray()
	for book in books:
		parts.append("%s%s" % [book.get_uid(), "*" if book.is_runtime else ""])
	return ", ".join(parts)


static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var size := file.get_length()
	file.close()
	return int(size)


func _arg_value(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	for i in args.size() - 1:
		if args[i] == flag:
			return args[i + 1]
	return fallback


static func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


static func _delete_recursive(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for name in directory.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in directory.get_directories():
		_delete_recursive(path.path_join(name))
	DirAccess.remove_absolute(path)

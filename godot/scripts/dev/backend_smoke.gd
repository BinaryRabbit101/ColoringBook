extends Node
## Automated verification for WP10 -- the Godot backend client: the automatic
## device sign-in, entitlements, purchases and the real pack download/install
## (DLC_SERVER.md 4.3, 7, 8, 9, 11).
##
## [b]There are no accounts to test.[/b] The app has no sign-in screen, no
## registration, no linking and no sign-out: [method Backend.sign_in_device] posts
## this installation's [code]device_uid[/code] to [code]/device/register[/code] at
## launch and that is the whole of authentication. What replaces the old account
## checks is (c) -- registration is silent, idempotent and carries exactly two
## abilities -- and (h) -- a token the server rejects is REPLACED and the request
## replayed, with nothing on screen ever hearing about it.
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
##   --stay             leave the scratch device, pack and stores in place
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
## opened, and [member Backend.autostart_enabled] is cleared before the autoload's
## launch session can register the DEVELOPER's real device.
##
## Checks, in order:
##   a  BackendConfig + ApiClient as pure logic: base URL, version comparison
##      (equal satisfies), the backoff schedule and its cap, header parsing
##   b  with no token at all the shelf is exactly what BookDef.discover() returns,
##      and the shop window still works (BL-25): the catalogue lists, a FREE pack
##      downloads with NO Authorization header and writes no entitlement row, and
##      a PAID one is refused by the SERVER rather than guessed at here
##   c  the automatic device sign-in: POST /device/register with no auth, a token
##      carrying exactly entitlements:read + packs:download, the SAME device_uid
##      every time, idempotent re-registration, and GET /entitlements answering
##      for a device
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
##   h  [b]the 401 recovery[/b]: a token the server rejects is dropped, the device
##      re-registers under the same uid and the request is REPLAYED -- silently,
##      with the same entitlements on the other side, and the DLC book never
##      leaves the shelf
##   i  the checksum gate and the zip-slip guard, as pure functions
##   j  the adult gate and the pack-shop row state machine, headless
##   l  the real wiring in main.tscn: gear -> Settings -> Restore -> GATE -> the
##      restore, and the shelf's "More books" button, which is there whenever the
##      build has a server at all (BL-25)
##   k  purchases: a bad receipt is final, a good one grants, re-verifying is
##      another 200 rather than a conflict, and restore_purchases() turns a list
##      of receipts into the packs this device owns
##
## Exit code is 0 only if every check passes.

const COYOTE_UID := "coyote-2026"
const TEST_BOOK_UID := "test-book-2026"
## The pack the dev server publishes (WP9). FREE, which means its bytes are
## public: no token, no identifier of any kind.
const PACK_SLUG := "coyote-book"
## A PAID pack, and the Play SKU it is sold under. See the header for the two
## commands that put it on the dev server; check (k) is the main user.
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

## Seconds to wait out the server's `throttle:6,1` on /device/register, plus slack.
const THROTTLE_WINDOW_SECONDS := 62.0

const ADULT_GATE_SCENE: PackedScene = preload("res://scenes/components/adult_gate.tscn")
const PACK_SHOP_SCENE: PackedScene = preload("res://scenes/components/pack_shop.tscn")

var _checks := 0
var _failures := 0

var _auth: AuthStore
var _entitlements: EntitlementsStore
var _base_url := ""
## Progress callbacks seen during the download, as [downloaded, total] pairs.
var _progress: Array = []
var _installed_bytes := 0


func _ready() -> void:
	# BEFORE the first frame: Backend's launch session waits one frame precisely so a
	# harness can say "not with the developer's real device, you don't".
	Backend.autostart_enabled = false
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
	await _check_without_token()
	await _check_device_registration()
	await _check_catalog()
	await _check_install()
	await _check_delta_update()
	_check_discovery()
	await _check_entitlement_filter()
	await _check_token_recovery()
	_check_verification_gates()
	await _check_ui()
	await _check_main_flow()
	await _check_purchases()

	print("\n=== %d/%d checks passed ===" % [_checks - _failures, _checks])
	print("scratch device: %s" % Backend.get_device_uid())
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
	_auth = AuthStore.new(TEST_AUTH_PATH)
	_entitlements = EntitlementsStore.new(TEST_ENTITLEMENTS_PATH)
	Backend.use_test_stores(_auth, _entitlements, TEST_DLC_ROOT, _base_url)


func _cleanup() -> void:
	Backend.get_installer().uninstall(PACK_SLUG)
	Backend.get_installer().uninstall(PAID_SLUG)
	_delete_recursive(TEST_ROOT)
	# Hand the real stores back so a --stay-less run leaves the autoload as it found
	# it (this process is about to exit, but a harness that lies about that is a
	# harness nobody trusts).
	Backend.use_test_stores(AuthStore.new(), EntitlementsStore.new(),
		BookDef.DLC_ROOT, BackendConfig.get_base_url())
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


# ============================= b: a device that has never reached the server ==

func _check_without_token() -> void:
	print("\n-- check b: with no token at all, the game is whole --")

	_expect(not _auth.has_token(), "a fresh installation holds no token")
	_expect(not Backend.is_signed_in(), "...so Backend reports it is not signed in")
	_expect(not FileAccess.file_exists(TEST_AUTH_PATH),
		"...and nothing has been written to auth.json yet")
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

	# --- the shop window (BL-25) ---------------------------------------------
	# A shipped build has no books baked in, so a first launch has nothing but the
	# shop window. GET /packs is optional-auth for exactly that.
	#
	# fetch_packs() goes through Backend._authed(), which registers the device when
	# it has no token -- so this is asserted through the RAW client, which is the
	# only way to see the genuinely tokenless answer the route promises.
	var window: Dictionary = await Backend.get_api().request_json(
		HTTPClient.METHOD_GET, "/packs", null,
		{"query": {"client_version": BackendConfig.get_client_version()}}
	)
	if bool(window[ApiClient.KEY_OK]) and typeof(window[ApiClient.KEY_DATA]) == TYPE_DICTIONARY:
		window = window.duplicate()
		window[ApiClient.KEY_DATA] = (window[ApiClient.KEY_DATA] as Dictionary).get("packs", [])
	_expect(bool(window[Backend.KEY_OK]),
		"GET /packs answers with NO token at all (%s)" % window[Backend.KEY_CODE])
	var offered: Array = window[Backend.KEY_DATA] as Array \
		if typeof(window[Backend.KEY_DATA]) == TYPE_ARRAY else []
	_expect(not offered.is_empty(),
		"...and lists the catalogue tokenless (%d pack(s))" % offered.size())
	var owned_tokenless := false
	for raw: Variant in offered:
		if typeof(raw) == TYPE_DICTIONARY and bool((raw as Dictionary).get("owned", false)):
			owned_tokenless = true
	_expect(not owned_tokenless,
		"...with nothing marked owned, because the bearer names nobody")

	# --- and the bytes really do arrive without a token -----------------------
	# DLC_SERVER.md 7.4: a free pack's manifest, archive and files are PUBLIC. This
	# is the whole "free content downloads without an identifier" requirement,
	# proved against a real server.
	#
	# Driven through the INSTALLER rather than through Backend.install_pack(), which
	# would register the device first (and rightly: the game wants a token whenever
	# it can have one). What is under test here is the SERVER's promise, so the
	# request has to be made with the header genuinely absent.
	_expect(_auth.get_live_token() == "",
		"there is no token on this device, so none goes on the wire")
	var public_install: Dictionary = await Backend.get_installer().install(PACK_SLUG)
	_expect(bool(public_install[PackInstaller.KEY_OK]),
		"a FREE pack installs with NO Authorization header (%s %s)"
		% [public_install[PackInstaller.KEY_CODE], public_install[PackInstaller.KEY_MESSAGE]])
	_expect(Backend.is_pack_installed(PACK_SLUG),
		"...and the pack is on disk, downloaded by a device the server cannot name")
	_expect(not _entitlements.has_data() and Backend.get_entitlements().is_empty(),
		"...having written no entitlement anywhere: a public fetch grants nothing")
	# A paid pack asks the same question and is refused, by the server, in the
	# words the shop already knows how to read.
	var refused: Dictionary = await Backend.get_installer().install(PAID_SLUG)
	_expect(not bool(refused[PackInstaller.KEY_OK])
			and String(refused[PackInstaller.KEY_CODE]) == ApiClient.CODE_UNAUTHENTICATED,
		"...while a PAID pack is %s to the same tokenless request (%s)"
		% [ApiClient.CODE_UNAUTHENTICATED, refused[PackInstaller.KEY_CODE]])
	# Put the shelf back the way the rest of the run expects to find it.
	Backend.uninstall_pack(PACK_SLUG)
	_expect(not Backend.is_pack_installed(PACK_SLUG),
		"the public install is removed again, so check (e) still starts from nothing")


# ============================ c: the automatic device sign-in (DLC_SERVER 4.3) ==
# The claim under test: the app authenticates itself. No screen, no email address,
# no password, no linking -- one POST with a uid this installation generated for
# itself, and a token that can do exactly two things.
#
# Everything below happens with nobody having typed anything. That is the point.

func _check_device_registration() -> void:
	print("\n-- check c: the device signs itself in --")

	# The uid exists BEFORE any request: it is generated on first read and persisted
	# straight away, so the very first registration already carries the identity
	# every later one will.
	var uid_before := Backend.get_device_uid()
	_expect(uid_before.length() == 26,
		"a device uid was generated before any request (%s)" % uid_before)
	_expect(FileAccess.file_exists(TEST_AUTH_PATH),
		"...and persisted immediately, so a crash cannot cost this device its purchases")

	var registered: Dictionary = await Backend.sign_in_device()
	if String(registered[Backend.KEY_CODE]) == ApiClient.CODE_THROTTLED:
		# `throttle:6,1`, and Laravel keys that limiter on (domain, ip) rather than on
		# the route -- so the catalogue traffic check (b) just made shares the bucket.
		# Being rate-limited is the server working; wait the window out rather than
		# report a red run.
		print("   the 6-a-minute limiter is full; waiting %d s for the window."
			% THROTTLE_WINDOW_SECONDS)
		await get_tree().create_timer(THROTTLE_WINDOW_SECONDS).timeout
		registered = await Backend.sign_in_device()
	_expect(bool(registered[Backend.KEY_OK]),
		"POST /device/register answered with no auth at all (%s %s)"
		% [registered[Backend.KEY_CODE], registered[Backend.KEY_MESSAGE]])
	if not Backend.is_signed_in():
		_expect(false, "the rest of the run needs a device token")
		return

	# --- the identity, and the two things it may do --------------------------
	_expect(Backend.get_device_uid() == uid_before,
		"...for the SAME device_uid, which is what makes a re-registration find this row")
	_expect(_auth.get_live_token() != "", "there is a live token on this device now")
	var stored: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_AUTH_PATH))
	_expect(typeof(stored) == TYPE_DICTIONARY
			and String((stored as Dictionary).get("token", "")) != "",
		"auth.json holds the bearer token (%s)" % TEST_AUTH_PATH.get_file())
	_expect(typeof(stored) == TYPE_DICTIONARY
			and int((stored as Dictionary).get("expires_at", 0))
				> int(Time.get_unix_time_from_system()),
		"...and a future expiry parsed out of the ISO-8601 the server sent")
	_expect(typeof(stored) == TYPE_DICTIONARY
			and not (stored as Dictionary).has("email"),
		"...and NOTHING that identifies a person: no email, no name, no password")
	var abilities := _auth.get_abilities()
	_expect(Array(abilities) == Array(Backend.DEVICE_ABILITIES),
		"the token carries exactly %s (%s)" % [Backend.DEVICE_ABILITIES, abilities])
	_expect(not _auth.is_expired(), "the token is live")

	# --- idempotence, which is the whole reason 401 recovery is safe ---------
	var again: Dictionary = await Backend.sign_in_device()
	_expect(bool(again[Backend.KEY_OK]) and again[Backend.KEY_DATA] == null,
		"calling sign_in_device() again with a live token makes NO request")
	_expect(Backend.get_device_uid() == uid_before,
		"...and certainly no second identity (%s)" % Backend.get_device_uid())

	# --- GET /entitlements answers for a device ------------------------------
	var listed: Dictionary = await Backend.refresh_entitlements()
	_expect(bool(listed[Backend.KEY_OK]),
		"GET /entitlements works on a device token (%s)" % listed[Backend.KEY_CODE])
	_expect(_entitlements.has_data() and not Backend.owns_pack(PAID_SLUG),
		"...and this device owns nothing yet, because nothing has been verified")


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
	_entitlements.store([])
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


# ======================================= h: a rejected token fixes itself, quietly ==
# The single most important behaviour in the file, because it is what replaced the
# refresh route AND the sign-in screen: there is nothing a player could do about a
# dead token, so the client must simply get another one.
#
# Two failure shapes, deliberately separated:
#   an EXPIRED token   the client knows it is dead and never sends it. The next
#                      authed call registers first, so the request goes out
#                      authorised on its FIRST attempt
#   a REJECTED token   the client believes it is good, sends it, and gets a 401.
#                      _authed() drops it, re-registers under the same uid and
#                      REPLAYS the request -- which is only safe because the
#                      re-registration is find-or-create on that uid

func _check_token_recovery() -> void:
	print("\n-- check h: a token the server refuses is replaced, not reported --")

	var runtime := BookDef.discover_runtime(TEST_DLC_ROOT)
	var owned_before := Backend.get_entitlements().size()
	var uid := Backend.get_device_uid()

	# --- the client-side belief: an expired token is never put on the wire ----
	_auth.store_token(_auth.get_token(), _auth.get_abilities(),
		int(Time.get_unix_time_from_system()) - 10)
	Backend.use_test_stores(_auth, _entitlements, TEST_DLC_ROOT, _base_url)
	_expect(_auth.has_token() and _auth.is_expired(), "the stored token is now expired")
	_expect(not Backend.is_signed_in(), "...so the facade reports it is not signed in")
	_expect(_auth.get_live_token() == "", "...and no dead bearer can be sent")
	_expect(not runtime.is_empty() and Backend.is_book_visible(runtime[0]),
		"the DLC book is STILL on the shelf -- a lapsed token never takes a book away")

	var recovered: Dictionary = await Backend.fetch_packs()
	_expect(bool(recovered[Backend.KEY_OK]),
		"an authed call on an expired token registers first and succeeds (%s)"
		% recovered[Backend.KEY_CODE])
	_expect(Backend.is_signed_in() and Backend.get_device_uid() == uid,
		"...leaving a live token on the SAME device (%s)" % Backend.get_device_uid())

	# --- the server-side refusal: a 401 the client did not see coming --------
	# A token that is garbage on the wire but perfectly live as far as this device
	# is concerned. That is exactly the shape of a revoked or rotated credential,
	# and the only shape _authed()'s retry exists for.
	var future := int(Time.get_unix_time_from_system()) + 86400
	_auth.store_token("not-a-real-token-at-all", Backend.DEVICE_ABILITIES, future)
	Backend.use_test_stores(_auth, _entitlements, TEST_DLC_ROOT, _base_url)
	_expect(Backend.is_signed_in(), "the device believes it holds a live token")

	var replayed: Dictionary = await Backend.refresh_entitlements()
	_expect(bool(replayed[Backend.KEY_OK]),
		"a 401 is answered by re-registering and REPLAYING the call (%s %s)"
		% [replayed[Backend.KEY_CODE], replayed[Backend.KEY_MESSAGE]])
	_expect(_auth.get_live_token() != "not-a-real-token-at-all" and Backend.is_signed_in(),
		"...so the dead string is gone and a fresh token is on disk")
	_expect(Backend.get_device_uid() == uid,
		"...under the SAME device_uid, which is why the row is the same row (%s)" % uid)
	_expect(Backend.get_entitlements().size() == owned_before,
		"...and the device owns exactly what it owned before (%d)"
		% Backend.get_entitlements().size())
	_expect(not runtime.is_empty() and Backend.is_book_visible(runtime[0]),
		"...with nothing having left the shelf while any of that happened")


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
	_expect(not gate.submit() and not passed[0], "a wrong answer runs nothing behind the gate")
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
		{"slug": "paid-pack", "title": "Paid Friends", "is_free": false, "owned": false,
			"bytes": 2500000, "latest_version": 1, "min_client_version": "0.1.0",
			"page_count": 12},
	])
	_expect(shop.get_rows().size() == 4, "the shop listed %d packs" % shop.get_rows().size())

	# --- the pack decides, never the player -----------------------------------
	# There is nobody to sign in, so the only question a row asks is whether the
	# SERVER's two flags say this device may simply take the pack.
	var paid_row := shop.get_row("paid-pack")
	_expect(paid_row != null and paid_row.needs_purchase(),
		"a row that is neither free nor owned has to be BOUGHT (is_free %s, owned %s)"
		% [paid_row.is_free() if paid_row else "?", paid_row.is_owned() if paid_row else "?"])
	_expect(paid_row != null and paid_row.get_state() == PackShop.PackRow.STATE_PURCHASE
			and paid_row.get_action_button().disabled,
		"...so it rests in '%s' and cannot start a download the server would refuse"
		% (paid_row.get_state() if paid_row else "?"))
	_expect(shop.purchasable_rows().size() == 1,
		"...and it is the ONE row the shop counts as needing buying (%d)"
		% shop.purchasable_rows().size())
	var free_row := shop.get_row("new-pack")
	_expect(free_row != null and not free_row.needs_purchase(),
		"a FREE row needs nothing from anybody -- its bytes are public")

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
	_expect(ApiClient.describe_error({Backend.KEY_CODE: ApiClient.CODE_OFFLINE})
			.contains("works fine without it"),
		"an offline shop reassures rather than alarms")
	_expect(PackShop.describe_install_error(
			{PackInstaller.KEY_CODE: ApiClient.CODE_ENTITLEMENT_REQUIRED})
			== PackShop.PURCHASE_HINT,
		"...and a pack this device is not entitled to points at the restore path")


# ========================================= l: the wiring inside main.tscn ==
# The overlays are trivial on their own; what is worth proving is that the ORDER
# main.gd imposes is real -- there is no route from the settings panel to the
# restore that does not go through the gate (DLC_SERVER.md 4.1) -- and that no
# kid-facing screen sprouts network state (8.2).

func _check_main_flow() -> void:
	print("\n-- check l: the restore route through main.tscn --")

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

	# --- settings -> restore, via the gate ------------------------------------
	# [b]There is no sign-in anywhere on this route.[/b] The panel names no person,
	# offers no login, and the only thing behind the gate is a call to the store.
	var settings := main.open_settings()
	_expect(settings.get_purchases_text() != ""
			and not settings.get_purchases_text().contains("@"),
		"settings shows what this DEVICE owns and names nobody ('%s')"
		% settings.get_purchases_text())
	settings.get_restore_button().pressed.emit()
	await get_tree().process_frame
	_expect(main.get_settings_panel() != null,
		"the panel stays open behind the gate -- the answer is reported into it")
	_expect(main.get_adult_gate() != null,
		"...and tapping Restore puts the ADULT GATE up (DLC_SERVER.md 4.1)")

	var owned_before := Backend.get_entitlements().size()
	var gate := main.get_adult_gate()
	gate.set_answer_text(str(gate.get_expected_answer() + 3))
	gate.get_submit_button().pressed.emit()
	await get_tree().process_frame
	_expect(main.get_adult_gate() != null,
		"a wrong answer gets no further -- the gate is not decoration")

	gate.set_answer_text(str(gate.get_expected_answer()))
	gate.get_submit_button().pressed.emit()
	await get_tree().process_frame
	_expect(main.get_adult_gate() == null, "the right answer dismisses the gate")
	# The restore is a real round trip. With no billing plugin there are no receipts
	# to present, so what it must do is re-read what the server already knows -- and
	# above all NOT lose anything.
	if not await _wait_for(func() -> bool:
			return not main.get_settings_panel().get_restore_button().disabled):
		_expect(false, "the restore finished and gave the button back")
	_expect(Backend.get_entitlements().size() == owned_before,
		"...and this device still owns exactly what it owned (%d)"
		% Backend.get_entitlements().size())
	main.close_settings()
	await get_tree().process_frame

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


# ============================================================== k: purchases ==
# DLC_SERVER.md 9. The claim under test, and the whole of what replaced account
# linking: a device earns a paid pack by presenting a store receipt, and it can do
# that on a tablet nobody has ever typed anything into.

func _check_purchases() -> void:
	print("\n-- check k: buying a pack, and restoring it onto this device --")
	if not Backend.is_signed_in():
		_expect(false, "the device holds a token, so a purchase has an owner")
		return

	_expect(not Backend.owns_pack(PAID_SLUG),
		"this device does not own '%s' yet" % PAID_SLUG)

	# --- the refusals, which mean OPPOSITE things and so are separate codes ---
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

	# --- the grant ------------------------------------------------------------
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
	_expect(Backend.owns_pack(PAID_SLUG),
		"...and the cache says this device owns '%s'" % PAID_SLUG)

	# --- restore: the same receipt, again, as many times as it likes ---------
	# This is the whole "own once, everywhere" story now. The platform store hands
	# back the same purchase token on a second device; restore_purchases() presents
	# it and the device earns its own entitlement row.
	var restored: Dictionary = await Backend.restore_purchases([
		{"platform": STORE_PLATFORM, "purchase_token": GOOD_RECEIPT, "sku": PAID_SKU},
	])
	_expect(bool(restored[Backend.KEY_OK])
			and int(restored[Backend.KEY_RESTORED]) == 1,
		"restore_purchases() re-verified %d receipt(s) without a conflict (%s)"
		% [int(restored.get(Backend.KEY_RESTORED, -1)), restored[Backend.KEY_CODE]])
	_expect(Backend.get_entitlements().size() == 1,
		"...and it is still ONE row: every launch may ask (%d)"
		% Backend.get_entitlements().size())
	var empty: Dictionary = await Backend.restore_purchases([])
	_expect(bool(empty[Backend.KEY_OK]) and int(empty[Backend.KEY_RESTORED]) == 0,
		"...while a restore with no receipts to present is a plain re-read, not an error")

	# --- and what ownership actually buys -------------------------------------
	var painted: Dictionary = await Backend.fetch_packs()
	var paid := _row_with_slug(painted[Backend.KEY_DATA], PAID_SLUG)
	_expect(bool(paid.get("owned", false)),
		"GET /packs paints owned:true for this device's token")

	var bought: Dictionary = await Backend.install_pack(PAID_SLUG)
	_expect(bool(bought[PackInstaller.KEY_OK]),
		"a PAID pack downloads onto a device nobody has signed in on (%s %s)"
		% [bought[PackInstaller.KEY_CODE], bought[PackInstaller.KEY_MESSAGE]])
	_expect(Backend.is_pack_installed(PAID_SLUG),
		"...which is 'bought once, owned everywhere' with no email address in it")

	# The rule the whole delivery layer exists to keep (DLC_SERVER.md 7.3).
	_expect(Backend.is_pack_installed(PACK_SLUG),
		"the free pack from check (e) is STILL ON DISK through all of that")
	_expect(Backend.uninstall_pack(PACK_SLUG), "uninstall_pack() removes it on request")
	Backend.uninstall_pack(PAID_SLUG)
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

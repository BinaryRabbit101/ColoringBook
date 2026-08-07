extends Control
## Automated verification for WP11 -- the Godot sync client: progress push/pull with
## the DLC_SERVER.md 6.3 merge, and lazy paint with sha-first negotiation, LWW and
## on-demand download (6.2, 8.2, 8.3, 11).
##
## Run WINDOWED, against a live local server. Windowed because it PAINTS: a real
## paint layer comes out of the [PageView] SubViewport, which renders nothing under
## the dummy rasteriser, and a real PNG on disk is the whole point of the paint
## half of this protocol.
##
##   cd server && php artisan serve --port=8123
##   <godot_exe> --path <project> --rendering-driver opengl3 \
##       res://scenes/dev/sync_smoke.tscn
##
## [b]The renderer flag is not decoration on this box.[/b] Under the Vulkan driver
## every [HTTPRequest] this harness makes comes back
## [code]RESULT_CONNECTION_ERROR[/code] (4) before a byte leaves -- the same requests
## succeed headless and under [code]opengl3[/code], and the server never sees them --
## so a windowed Vulkan run fails at "register a scratch account" and proves nothing.
## It is an engine/driver interaction, not a fact about this code; the flag is the
## cheapest way past it.
##
## Extra user args (after a bare `--`):
##   --base-url <url>   API root (default: whatever BackendConfig resolves)
##   --stay             leave the scratch account and local state in place
##
## [b]It talks to a REAL server[/b], and to it TWICE: "device A" is the game (the
## [Backend] autoload, its [SyncQueue], the real [code]GameState[/code]) and
## "device B" is a second bearer token on the same account driven through a raw
## [ApiClient]. Two [code]user://[/code] trees in one process is not possible, and
## faking the second device in-process would only test this harness against itself;
## driving the API directly is what makes A's 409 and A's [code]PAINT_STALE[/code]
## real ones, produced by the server for the reason the protocol says they are.
##
## [b]Everything local is isolated[/b]: [constant TEST_SAVE_ROOT] for the save and
## the paint layers, [constant TEST_ROOT] for the auth store, the DLC root and the
## sync queue. The player's real save, [code]user://auth.json[/code],
## [code]user://dlc/[/code] and [code]user://sync_queue.json[/code] are never
## opened. The scratch ACCOUNT lives on the server; its email is printed and left in
## [constant EMAIL_FILE] for the cleanup step.
##
## Checks, in order:
##   a  the merge mirror as PURE logic -- the 9-cell status grid, padding, the
##      timestamp tie-break, sub-second precision, unknown-status normalisation,
##      and commutativity + idempotence over a grid of states. This is the check
##      that has to match App\Services\ProgressMerge exactly
##   b  ISO 8601: sub-second round trip, the server's second-precision +00:00 form,
##      and the "age" wording of the status line
##   c  with no account the queue is completely inert -- no file, no requests
##   d  register -> sign in; the queue adopts the account and drains
##   e  progress push: the shelf reaches the server, base revisions are recorded,
##      and a re-drain of unchanged state is a genuine no-op
##   f  the 6.3 conflict protocol: device B moves the row underneath, A's push comes
##      back conflict:true, A MERGES and RETRIES ONCE, and both ends converge
##   g  paint upload: a real stroke, a real PNG, sha-first negotiation 202 -> 201,
##      and a second drain that costs no upload at all (204/skip)
##   h  PAINT_STALE: device B uploads a newer picture, A's next upload is refused,
##      A pulls the server's bytes and GameState.load_page_paint (the ColoringPage
##      restore path) returns them
##   i  download on demand: with the local file gone, opening the book fetches it
##   j  the "Sync pictures" toggle gates paint and never progress
##   k  offline: with the server unreachable, entries persist to disk, a FRESH queue
##      reads them back, and the drain converges once the server returns
##   l  the status line's four states
##
## Exit code is 0 only if every check passes.

const BOOK_PATH := "res://resources/books/test_book/book.tres"
const BOOK_UID := "test-book-2026"

## Everything this run writes.
const TEST_ROOT := "user://sync_smoke"
const TEST_SAVE_ROOT := "user://sync_smoke/state"
const TEST_DLC_ROOT := "user://sync_smoke/dlc"
const TEST_AUTH_PATH := "user://sync_smoke/auth.json"
const TEST_ENTITLEMENTS_PATH := "user://sync_smoke/dlc/entitlements.json"
const TEST_QUEUE_PATH := "user://sync_smoke/sync_queue.json"
## Where the scratch account's email is left for the cleanup step.
const EMAIL_FILE := "user://sync_smoke/scratch_account.txt"

## Password for the scratch account. Mixed case and a digit on purpose: a
## production-config server applies Laravel's [code]Password::defaults()[/code],
## which an all-lowercase passphrase does not satisfy -- and a harness that can only
## register against a dev box is a harness that cannot check the real one.
const SCRATCH_PASSWORD := "Wp11-Smoke-Passphrase-7"
## A port nothing is listening on, for the offline check.
const DEAD_URL := "http://127.0.0.1:8199/api/v1"

## Shortened so the harness does not spend five real seconds per save point. The
## real value is asserted separately in check (e).
const TEST_DEBOUNCE := 0.25

## Region of test_book page 1 the strokes lock, and the brush.
const STROKE_START := Vector2(700.5, 250.5)
const STROKE_END := Vector2(880.5, 250.5)
const BRUSH_DIAMETER := 56.0

## Colour device B's synthetic picture is filled with, so a pulled layer is
## identifiable pixel by pixel.
const DEVICE_B_COLOR := Color(0.1, 0.35, 0.85, 1.0)
## Per-channel tolerance when matching a pixel through a PNG round trip (8-bit).
const COLOR_TOLERANCE := 1.5 / 255.0

@onready var _page_view: PageView = $PageView

var _checks := 0
var _failures := 0

var _base_url := ""
var _email := ""
var _auth: AuthStore
var _entitlements: EntitlementsStore
var _book: BookDef
## "Device B": a second token on the same account, driven raw.
var _b: ApiClient
var _b_token := ""


func _ready() -> void:
	get_window().size = Vector2i(1280, 820)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_MAILBOX)
	await get_tree().process_frame
	await _run()


func _run() -> void:
	print("=== WP11 sync smoke test ===")
	_isolate()
	print("   API:         %s" % _base_url)
	print("   save root:   %s" % ProjectSettings.globalize_path(TEST_SAVE_ROOT))
	print("   sync queue:  %s" % ProjectSettings.globalize_path(TEST_QUEUE_PATH))

	_check_merge_mirror()
	_check_time_helpers()
	_check_inert()
	await _check_sign_in()
	if _email == "":
		print("\n!! could not register a scratch account; the rest cannot run.")
		_finish(1)
		return
	await _check_progress_push()
	await _check_conflict_retry()
	await _check_paint_upload()
	await _check_paint_stale_pull()
	await _check_paint_on_demand()
	await _check_picture_toggle()
	await _check_offline_queue()
	_check_status_text()

	print("\n=== %d/%d checks passed ===" % [_checks - _failures, _checks])
	print("scratch account: %s" % _email)
	if "--stay" in OS.get_cmdline_user_args():
		print("[dev] --stay given; %s was kept." % ProjectSettings.globalize_path(TEST_ROOT))
		return
	_cleanup()
	_finish(0 if _failures == 0 else 1)


## Points GameState and every Backend part at scratch state before anything runs.
func _isolate() -> void:
	_delete_recursive(TEST_ROOT)
	DirAccess.make_dir_recursive_absolute(TEST_DLC_ROOT)
	_base_url = _arg_value("--base-url", BackendConfig.get_base_url())
	GameState.set_save_root(TEST_SAVE_ROOT)
	# Never let the interval autosave fire mid-assertion: this harness decides when
	# a save point happens.
	GameState.set_autosave_interval(0.0)
	_auth = AuthStore.new(TEST_AUTH_PATH)
	_entitlements = EntitlementsStore.new(TEST_ENTITLEMENTS_PATH)
	Backend.use_test_stores(_auth, _entitlements, TEST_DLC_ROOT, _base_url, TEST_QUEUE_PATH)
	_book = load(BOOK_PATH) as BookDef


func _cleanup() -> void:
	GameState.clear_book()
	GameState.set_save_root("")
	Backend.use_test_stores(AuthStore.new(), EntitlementsStore.new(),
		BookDef.DLC_ROOT, BackendConfig.get_base_url(), SyncQueue.QUEUE_PATH)
	_delete_recursive(TEST_ROOT)
	print("   cleaned up %s" % ProjectSettings.globalize_path(TEST_ROOT))


func _finish(code: int) -> void:
	print("exit code: %d" % code)
	get_tree().quit(code)


# ============================================= a: the merge mirror, pure logic ==

## The one check that is not about the network at all: does this client's
## [method SyncQueue.merge_states] behave EXACTLY like
## [code]App\Services\ProgressMerge[/code]? Every case below is the client-side twin
## of a named case in [code]server/tests/Unit/ProgressMergeTest.php[/code].
func _check_merge_mirror() -> void:
	print("\n-- check a: the merge rule, mirrored from App\\Services\\ProgressMerge --")
	var t0 := "2026-08-06T12:00:00.000Z"
	var t1 := "2026-08-09T12:00:00.000Z"

	# test_a_page_status_only_ever_climbs -- the full 3x3 provider.
	var grid := {
		"untouched|untouched": "untouched", "untouched|in_progress": "in_progress",
		"untouched|complete": "complete", "in_progress|untouched": "in_progress",
		"in_progress|in_progress": "in_progress", "in_progress|complete": "complete",
		"complete|untouched": "complete", "complete|in_progress": "complete",
		"complete|complete": "complete",
	}
	var climbed := true
	for pair: Variant in grid:
		var sides := String(pair).split("|")
		var merged := SyncQueue.merge_states(
			_state(0, [sides[0]], 0, t0), _state(0, [sides[1]], 0, t0)
		)
		if String((merged[SyncQueue.STATE_STATUSES] as Array)[0]) != String(grid[pair]):
			climbed = false
	_expect(climbed, "a page status only ever climbs, over all 9 pairs")

	# test_a_finished_page_can_never_be_un_finished -- and the loser is the NEWER side.
	var unfinished := SyncQueue.merge_states(
		_state(0, ["complete", "complete"], 1, t0),
		_state(0, ["untouched", "untouched"], 0, t1)
	)
	_expect(_statuses(unfinished) == "complete,complete",
		"a finished page is never un-finished, even by the newer side")

	# test_the_shorter_side_is_padded_and_no_page_is_dropped
	var padded := SyncQueue.merge_states(
		_state(0, ["complete", "in_progress"], 1, t0),
		_state(0, ["untouched", "untouched", "complete", "in_progress"], 3, t0)
	)
	_expect(_statuses(padded) == "complete,in_progress,complete,in_progress"
			and int(padded[SyncQueue.STATE_FURTHEST]) == 3,
		"the shorter side pads with untouched and no page is dropped")

	# test_an_empty_side_is_the_identity
	var held := _state(2, ["complete", "in_progress", "untouched"], 2, t0)
	_expect(_snapshot(SyncQueue.merge_states(held, _state(0, [], 0, t0))) == _snapshot(held),
		"an empty side is the identity")

	# test_furthest_page_index_is_the_maximum
	_expect(int(SyncQueue.merge_states(_state(0, [], 7, t0), _state(0, [], 3, t1))
			[SyncQueue.STATE_FURTHEST]) == 7,
		"furthest_page_index is the maximum, whichever side is newer")

	# test_current_page_index_comes_from_the_newer_side (both argument orders)
	var older := _state(1, ["complete"], 5, "2026-08-06T12:00:00.000Z")
	var newer := _state(4, ["untouched"], 0, "2026-08-06T12:00:01.000Z")
	_expect(int(SyncQueue.merge_states(older, newer)[SyncQueue.STATE_CURRENT]) == 4
			and int(SyncQueue.merge_states(newer, older)[SyncQueue.STATE_CURRENT]) == 4,
		"current_page_index comes from the newer side, in either argument order")

	# test_the_merged_timestamp_is_the_later_of_the_two
	_expect(String(SyncQueue.merge_states(_state(0, [], 0, t0), _state(0, [], 0, t1))
			[SyncQueue.STATE_UPDATED_AT]) == t1,
		"the merged client_updated_at is the later of the two")

	# test_identical_timestamps_break_the_tie_on_the_further_page
	var a_tie := _state(2, [], 0, t0)
	var b_tie := _state(5, [], 0, t0)
	_expect(int(SyncQueue.merge_states(a_tie, b_tie)[SyncQueue.STATE_CURRENT]) == 5
			and int(SyncQueue.merge_states(b_tie, a_tie)[SyncQueue.STATE_CURRENT]) == 5,
		"identical timestamps tie-break on max(current_page_index), commutatively")

	# test_sub_second_differences_still_decide -- the reason this client sends
	# milliseconds and parses them as a float.
	_expect(int(SyncQueue.merge_states(
			_state(1, [], 0, "2026-08-06T12:00:00.100Z"),
			_state(9, [], 0, "2026-08-06T12:00:00.200Z"))[SyncQueue.STATE_CURRENT]) == 9,
		"sub-second differences still decide the cursor")

	# test_an_unrecognised_status_ranks_as_untouched_and_is_normalised
	_expect(_statuses(SyncQueue.merge_states(
			_state(0, ["sparkly", "complete"], 0, t0),
			_state(0, ["untouched", "glittery"], 0, t0))) == "untouched,complete",
		"an unrecognised status ranks as untouched AND is normalised out of the result")

	# test_two_unknown_statuses_still_merge_commutatively
	_expect(_snapshot(SyncQueue.merge_states(
				_state(0, ["sparkly"], 0, t0), _state(0, ["glittery"], 0, t0)))
			== _snapshot(SyncQueue.merge_states(
				_state(0, ["glittery"], 0, t0), _state(0, ["sparkly"], 0, t0))),
		"...and two unknown statuses still merge commutatively")

	# The two properties the whole protocol rests on, over the same kind of grid
	# ProgressMergeTest uses: differing page counts, every status, both orders of
	# current vs furthest, and several states sharing one timestamp.
	var states := [
		_state(0, [], 0, t0),
		_state(0, ["untouched"], 0, t0),
		_state(1, ["complete", "in_progress"], 1, t0),
		_state(0, ["in_progress", "complete", "untouched"], 2, t0),
		_state(3, ["complete", "complete", "complete", "complete"], 3, t1),
		_state(2, ["untouched", "untouched"], 5, "2026-08-06T12:00:00.500Z"),
		_state(5, ["complete"], 0, t1),
	]
	var commutative := true
	var idempotent := true
	for a: Dictionary in states:
		for b: Dictionary in states:
			var ab := SyncQueue.merge_states(a, b)
			if _snapshot(ab) != _snapshot(SyncQueue.merge_states(b, a)):
				commutative = false
			if _snapshot(SyncQueue.merge_states(ab, b)) != _snapshot(ab) \
					or _snapshot(SyncQueue.merge_states(ab, a)) != _snapshot(ab):
				idempotent = false
	_expect(commutative, "merge is COMMUTATIVE over a %d x %d grid" % [states.size(), states.size()])
	_expect(idempotent, "merge is IDEMPOTENT: re-merging the result with either input changes nothing")


# ================================================== b: timestamps and wording ==

func _check_time_helpers() -> void:
	print("\n-- check b: ISO 8601 both ways, and the status wording --")
	var now := Time.get_unix_time_from_system()
	var stamp := SyncQueue.iso_now()
	_expect(stamp.ends_with("Z") and "T" in stamp and "." in stamp,
		"iso_now() is ISO 8601 UTC with sub-second precision (%s)" % stamp)
	_expect(absf(SyncQueue.parse_iso8601(stamp) - now) < 1.5,
		"...and parses back to the same instant")

	# The server writes client_updated_at with toIso8601String(): whole seconds and
	# a +00:00 offset. The merge has to compare that against our milliseconds.
	_expect(absf(SyncQueue.parse_iso8601("2026-08-06T12:00:00+00:00")
			- SyncQueue.parse_iso8601("2026-08-06T12:00:00.000Z")) < 0.001,
		"the server's '+00:00' form and our 'Z' form parse to the same instant")
	_expect(SyncQueue.parse_iso8601("2026-08-06T12:00:00-01:00")
			> SyncQueue.parse_iso8601("2026-08-06T12:00:00+00:00"),
		"a negative offset really is later in absolute time")
	_expect(SyncQueue.parse_iso8601("") == 0.0, "an empty timestamp is 0, never a crash")

	_expect(SyncQueue.describe_age(5.0) == "just now", "under a minute reads 'just now'")
	_expect(SyncQueue.describe_age(60.0) == "1 minute ago", "singular minute")
	_expect(SyncQueue.describe_age(1800.0) == "30 minutes ago", "'30 minutes ago'")
	_expect(SyncQueue.describe_age(7200.0) == "2 hours ago", "'2 hours ago'")
	_expect(SyncQueue.describe_age(200000.0) == "2 days ago", "'2 days ago'")


# ============================================ c: inert with no account at all ==

func _check_inert() -> void:
	print("\n-- check c: with no account, sync does not exist --")
	var queue := Backend.get_sync_queue()
	_expect(queue != null and queue.is_attached(),
		"the queue is wired to GameState's save points from Backend, not from main.gd")
	_expect(not queue.is_active(), "...but it is INACTIVE with no live token")
	_expect(Backend.get_sync_status_text() == Backend.SYNC_OFF_TEXT,
		"the status line reads '%s'" % Backend.SYNC_OFF_TEXT)

	# A save point with no account must write nothing and ask nothing.
	GameState.start_book(_book, 0)
	GameState.mark_page_status(_book, 0, GameState.STATUS_IN_PROGRESS)
	GameState.save_now()
	_expect(not FileAccess.file_exists(TEST_QUEUE_PATH),
		"a save point signed out leaves no sync_queue.json at all")
	_expect(not queue.is_pending(), "...and nothing is pending")


# ======================================================= d: the scratch account ==

func _check_sign_in() -> void:
	print("\n-- check d: register, sign in, and device B --")
	var queue := Backend.get_sync_queue()
	queue.set_debounce_seconds(TEST_DEBOUNCE)
	_email = "wp11-smoke-%d@example.test" % int(Time.get_unix_time_from_system())
	var result: Dictionary = await Backend.register(_email, SCRATCH_PASSWORD, true)
	_expect(bool(result[Backend.KEY_OK]) and Backend.is_signed_in(),
		"registered and signed in as %s (%s %s)"
		% [_email, result[Backend.KEY_CODE], result[Backend.KEY_MESSAGE]])
	if not Backend.is_signed_in():
		_email = ""
		return
	_write_text(EMAIL_FILE, _email)
	_expect(queue.is_active(), "the queue is ACTIVE now there is a live token")
	await _idle()

	# Device B: a second token on the SAME account, so both write the account-level
	# shelf (no ?profile=, per DLC_SERVER.md 11).
	var token: Dictionary = await Backend.get_api().request_json(
		HTTPClient.METHOD_POST, "/auth/token", {
			"email": _email, "password": SCRATCH_PASSWORD,
			"device_uid": AuthStore.new_ulid(), "device_name": "wp11-device-b",
			"platform": OS.get_name(),
		}, {"auth": false}
	)
	if bool(token[Backend.KEY_OK]) and typeof(token[Backend.KEY_DATA]) == TYPE_DICTIONARY:
		_b_token = String((token[Backend.KEY_DATA] as Dictionary).get("token", ""))
	_b = ApiClient.new(self, _base_url, BackendConfig.get_client_version())
	_b.set_token(_b_token)
	_expect(_b_token != "" and _b_token != _auth.get_token(),
		"device B holds a SECOND token on the same account")


# ================================================== e: pushing progress up ==

func _check_progress_push() -> void:
	print("\n-- check e: the shelf reaches the server --")
	var queue := Backend.get_sync_queue()
	_expect(queue.get_debounce_seconds() != SyncQueue.DEBOUNCE_SECONDS
			and SyncQueue.DEBOUNCE_SECONDS == 5.0,
		"the shipped debounce is DLC_SERVER.md 6.2's 5 s (the harness shortens it)")

	GameState.start_book(_book, 0)
	GameState.mark_page_status(_book, 0, GameState.STATUS_IN_PROGRESS)
	await _sync_now()

	var revision := queue.get_base_revision(BOOK_UID)
	_expect(revision >= 1, "the book has a server revision (%d)" % revision)
	var server := await _b_progress(BOOK_UID)
	_expect(not server.is_empty(), "device B can see the row")
	_expect(_server_statuses(server) == "in_progress,untouched",
		"...with page 1 in_progress and page 2 untouched (%s)" % _server_statuses(server))
	_expect(not queue.is_pending(), "nothing is left queued")
	_expect(FileAccess.file_exists(TEST_QUEUE_PATH),
		"the queue is persisted to %s" % TEST_QUEUE_PATH)

	# The no-op rule (server/CLAUDE.md WP2): a push that merges to what is stored
	# leaves the revision alone and does not wake other devices.
	await _sync_now()
	_expect(queue.get_base_revision(BOOK_UID) == revision,
		"re-draining unchanged state does not burn a revision (still %d)" % revision)

	# ...and a real change does move it.
	GameState.mark_page_status(_book, 1, GameState.STATUS_IN_PROGRESS)
	await _sync_now()
	_expect(queue.get_base_revision(BOOK_UID) > revision,
		"a real change bumps it (%d -> %d)" % [revision, queue.get_base_revision(BOOK_UID)])


# ================================== f: the 6.3 conflict protocol, end to end ==

## The check this work package exists for. Device B moves the row while A is not
## looking; A's next push comes back [code]conflict: true[/code] carrying the server
## state; A merges it locally and retries ONCE at the revision the server named; and
## both ends end up holding the same thing.
func _check_conflict_retry() -> void:
	print("\n-- check f: a real 409-shaped conflict, merged and retried once --")
	var queue := Backend.get_sync_queue()
	var before := queue.get_base_revision(BOOK_UID)

	# Device B: finish page 2 and move its cursor there, at the revision it can see.
	var server := await _b_progress(BOOK_UID)
	var b_revision := int(server.get("revision", 0))
	_expect(b_revision == before,
		"precondition: both devices agree the row is at revision %d" % b_revision)
	var pushed: Dictionary = await _b.request_json(
		HTTPClient.METHOD_PUT, "/sync/progress", {"books": [{
			"book_uid": BOOK_UID, "base_revision": b_revision,
			"current_page_index": 1,
			"page_statuses": ["untouched", "complete"],
			"furthest_page_index": 1,
			"client_updated_at": SyncQueue.iso_now(),
		}]}
	)
	_expect(bool(pushed[ApiClient.KEY_OK]) and not _conflicted(pushed),
		"device B's push lands cleanly")
	var moved := int((await _b_progress(BOOK_UID)).get("revision", 0))
	_expect(moved == b_revision + 1,
		"...moving the row to revision %d under device A" % moved)

	# Device A, still on the stale base revision, finishes page 1.
	GameState.mark_page_status(_book, 0, GameState.STATUS_COMPLETE)
	_expect(queue.get_base_revision(BOOK_UID) == before,
		"device A still believes the row is at revision %d (it is stale)" % before)
	await _sync_now()

	# The whole point: A did not overwrite B, and A did not lose its own page.
	var settled := await _b_progress(BOOK_UID)
	_expect(_server_statuses(settled) == "complete,complete",
		"the server holds BOTH devices' work (%s)" % _server_statuses(settled))
	_expect(GameState.get_page_status(BOOK_UID, 1) == GameState.STATUS_COMPLETE,
		"device A merged the server's completed page 2 into its own save")
	_expect(GameState.get_page_status(BOOK_UID, 0) == GameState.STATUS_COMPLETE,
		"...without losing the page it completed itself")
	_expect(int(settled.get("revision", 0)) == moved + 1,
		"exactly ONE retry write happened (%d -> %d), not a ping-pong"
		% [moved, int(settled.get("revision", 0))])
	_expect(queue.get_base_revision(BOOK_UID) == int(settled.get("revision", 0)),
		"...and device A recorded the revision it converged on")
	_expect(not queue.is_pending(), "nothing is left queued after the retry")

	# Convergence, stated as the protocol states it: both ends hold the same value.
	_expect(_server_statuses(settled) == _local_statuses(),
		"device A and the server hold identical page statuses (%s)" % _local_statuses())


# ========================================================= g: painting a page ==

## A real stroke through the real [PageView], saved through the real
## [method GameState.save_page_paint] -- which is the exact call
## [code]ColoringPage._write_paint()[/code] makes, and therefore the exact signal
## the sync layer hooks (6.2: "it never triggers an extra get_paint_image()
## readback of its own").
func _check_paint_upload() -> void:
	print("\n-- check g: a painted page, negotiated sha-first and uploaded --")
	var queue := Backend.get_sync_queue()
	var page := _book.get_page(0)
	if page == null or not _page_view.load_page(
			page.display_image_path, page.id_map_path, page.regions_json_path):
		_expect(false, "the test book's page 1 loads into PageView")
		return
	_page_view.brush_size = BRUSH_DIAMETER
	_page_view.brush_color = Color(0.9, 0.2, 0.15, 1.0)

	var painted := await _paint_stroke()
	_expect(painted != null, "a stroke was painted and read back")
	if painted == null:
		return
	_expect(GameState.save_page_paint(_book, 0, painted),
		"GameState wrote the paint layer (the ColoringPage save path)")
	var path := GameState.get_paint_path(_book, 0)
	var local_sha := FileAccess.get_sha256(path).to_lower()
	_expect(FileAccess.file_exists(path), "the PNG is on disk at %s" % path.get_file())

	var before := await _b_paint_pages(BOOK_UID)
	_expect(before.is_empty(), "precondition: the server has no picture for this book yet")

	await _sync_now()
	var pages := await _b_paint_pages(BOOK_UID)
	_expect(pages.size() == 1, "the server now has exactly one painted page")
	var row: Dictionary = pages[0] if pages.size() == 1 else {}
	_expect(String(row.get("sha256", "")).to_lower() == local_sha,
		"...and it is byte-for-byte the file on this device (%s)" % local_sha.left(12))
	_expect(int(row.get("revision", 0)) == 1,
		"...at revision 1 -- the 202 negotiation turned into a 201 upload")
	_expect(int(row.get("bytes", 0)) == _file_size(path),
		"...with the size the negotiation declared (%d bytes)" % _file_size(path))

	# The sha-first rule: re-syncing an unchanged page must cost nothing.
	GameState.save_now()
	await _sync_now()
	_expect(int((await _b_paint_pages(BOOK_UID))[0].get("revision", 0)) == 1,
		"a second drain of the same picture does not upload or bump anything")
	_expect(not queue.is_pending(), "nothing is left queued")


# ================================================== h: losing last-write-wins ==

## Device B paints over the page with a picture stamped LATER. Device A's next
## upload is refused with [code]409 PAINT_STALE[/code], which per 6.3 means "your
## copy is the old one" -- so A pulls the server's bytes rather than retrying.
func _check_paint_stale_pull() -> void:
	print("\n-- check h: PAINT_STALE means pull, not retry --")
	var queue := Backend.get_sync_queue()
	var size := _page_view.get_page_size()
	var b_png := _solid_png(size, DEVICE_B_COLOR)
	# Half an hour ahead: comfortably later than anything this device will stamp,
	# and comfortably inside the server's 24 h clock-skew window (6.3).
	var b_stamp := SyncQueue.iso_from_unix(Time.get_unix_time_from_system() + 1800.0)
	var b_sha := _sha256_of(b_png)
	var uploaded := await _b_upload_paint(BOOK_UID, 0, b_png, b_stamp)
	_expect(uploaded, "device B uploaded a newer picture for page 1")
	if not uploaded:
		return

	# Device A paints again. Its stamp is NOW, which is older than device B's.
	var repainted := await _paint_stroke(Color(0.2, 0.8, 0.3, 1.0), 60.0)
	_expect(repainted != null and GameState.save_page_paint(_book, 0, repainted),
		"device A painted and saved again, unaware of device B")
	await _sync_now()

	var path := GameState.get_paint_path(_book, 0)
	var after_sha := FileAccess.get_sha256(path).to_lower()
	_expect(after_sha == b_sha,
		"device A's local file is now device B's picture -- it pulled instead of overwriting")
	var restored := GameState.load_page_paint(_book, 0)
	_expect(restored != null and restored.get_size() == size,
		"...and GameState.load_page_paint (the ColoringPage restore path) reads it back")
	if restored != null:
		var pixel := restored.get_pixel(size.x / 2, size.y / 2)
		# Per channel, to 8-bit precision: the PNG round trip quantises, so
		# is_equal_approx would fail on a picture that is pixel-perfect.
		_expect(absf(pixel.r - DEVICE_B_COLOR.r) <= COLOR_TOLERANCE
				and absf(pixel.g - DEVICE_B_COLOR.g) <= COLOR_TOLERANCE
				and absf(pixel.b - DEVICE_B_COLOR.b) <= COLOR_TOLERANCE
				and absf(pixel.a - DEVICE_B_COLOR.a) <= COLOR_TOLERANCE,
			"...as device B's pixels, so the next page open shows them (%s)" % pixel)
	var server := await _b_paint_pages(BOOK_UID)
	_expect(server.size() == 1 and String(server[0].get("sha256", "")).to_lower() == b_sha,
		"the server still holds device B's picture -- the stale upload wrote nothing")
	_expect(not queue.is_pending(),
		"...and device A is no longer trying to push its stale copy")


# ================================================ i: download on demand (6.2) ==

func _check_paint_on_demand() -> void:
	print("\n-- check i: opening a book fetches a picture this device has not got --")
	var path := GameState.get_paint_path(_book, 0)
	var expected := FileAccess.get_sha256(path).to_lower()
	DirAccess.remove_absolute(path)
	_expect(not FileAccess.file_exists(path), "precondition: the local paint layer is gone")

	# The real trigger is GameState.book_started, which the queue subscribes to
	# itself -- so this is exactly what happens when a child taps the book.
	var started := Time.get_ticks_usec()
	GameState.start_book(_book, 0)
	var blocked := float(Time.get_ticks_usec() - started) / 1000.0
	_expect(blocked < 50.0,
		"start_book() returned in %.1f ms -- no screen ever awaits a request (8.2)" % blocked)

	var arrived := await _wait_for(func() -> bool: return FileAccess.file_exists(path), 20.0)
	_expect(arrived, "the picture arrived behind the loading beat")
	_expect(FileAccess.get_sha256(path).to_lower() == expected,
		"...byte-for-byte what the server had")
	await _idle()


# ======================================================= j: the picture toggle ==

func _check_picture_toggle() -> void:
	print("\n-- check j: 'Sync pictures' gates paint and never progress --")
	Backend.set_picture_sync_enabled(false)
	_expect(not Backend.is_picture_sync_enabled(), "pictures are switched off")

	var repainted := await _paint_stroke(Color(0.95, 0.75, 0.1, 1.0), 70.0)
	if repainted == null:
		_expect(false, "a stroke was painted for page 2")
		return
	# Page 2 this time, so the assertion is about a page the server has never seen.
	_expect(GameState.save_page_paint(_book, 1, repainted), "page 2 was painted and saved")
	GameState.mark_page_status(_book, 1, GameState.STATUS_COMPLETE)
	await _sync_now()

	var pages := await _b_paint_pages(BOOK_UID)
	_expect(pages.size() == 1, "the server still has only page 1's picture")
	var server := await _b_progress(BOOK_UID)
	_expect(_server_statuses(server).begins_with("complete,complete"),
		"...but the PROGRESS went up regardless (%s)" % _server_statuses(server))

	Backend.set_picture_sync_enabled(true)
	await _sync_now()
	pages = await _b_paint_pages(BOOK_UID)
	_expect(pages.size() == 2, "switching it back on uploads the page that was held back")


# ============================================= k: offline, and the drain after ==

func _check_offline_queue() -> void:
	print("\n-- check k: offline entries persist and drain when the server returns --")
	var queue := Backend.get_sync_queue()
	Backend.get_api().set_base_url(DEAD_URL)

	# A real save point while there is nothing to talk to.
	GameState.set_page_index(1)
	GameState.mark_page_status(_book, 1, GameState.STATUS_COMPLETE)
	var painted := await _paint_stroke(Color(0.6, 0.2, 0.7, 1.0), 64.0)
	if painted != null:
		GameState.save_page_paint(_book, 1, painted)
	var result: Dictionary = await Backend.sync_now(false)
	# The save point above scheduled its own debounced drain, and a drain that fails
	# offline RESCHEDULES itself with backoff -- so this manual one can land on top of
	# one already in flight and be answered BUSY. That is the harness racing itself,
	# not a fact about the server, so wait the other drain out and ask again.
	var collisions := 0
	while String(result["code"]) == "BUSY" and collisions < 10:
		collisions += 1
		await _idle()
		result = await Backend.sync_now(false)
	# Either transport code is "the server is not there": Windows answers a dead
	# loopback port with a connect refusal on some runs and a stall until
	# HTTPRequest.timeout on others, and both are ApiClient's offline family.
	_expect(not bool(result["ok"])
			and String(result["code"]) in [ApiClient.CODE_OFFLINE, ApiClient.CODE_TIMEOUT],
		"the drain failed with %s and nothing crashed" % result["code"])
	_expect(queue.is_pending(), "the entries are still queued")
	_expect(Backend.get_sync_status_text() == Backend.OFFLINE_TEXT,
		"the grown-up's status line reads '%s'" % Backend.OFFLINE_TEXT)

	# The property the file exists for: a FRESH queue, reading only the JSON, knows
	# there is work outstanding -- which is what makes an offline session drain on
	# the next launch (8.2).
	var reloaded := SyncQueue.new(self, Backend.get_api(), _auth, TEST_QUEUE_PATH, TEST_DLC_ROOT)
	_expect(reloaded.is_pending(),
		"a fresh SyncQueue built from %s alone still knows (%d book(s), %d page(s))"
		% [TEST_QUEUE_PATH.get_file(), reloaded.pending_book_count(), reloaded.pending_paint_count()])
	_expect(reloaded.get_base_revision(BOOK_UID) == queue.get_base_revision(BOOK_UID),
		"...and reads back the same base revision (%d)" % reloaded.get_base_revision(BOOK_UID))

	Backend.get_api().set_base_url(_base_url)
	await _sync_now()
	_expect(not queue.is_pending(), "the server came back and the queue drained")
	var server := await _b_progress(BOOK_UID)
	_expect(_server_statuses(server) == _local_statuses(),
		"...converged again (%s)" % _local_statuses())
	var pages := await _b_paint_pages(BOOK_UID)
	var page_two: Dictionary = _row_for_page(pages, 1)
	_expect(String(page_two.get("sha256", "")).to_lower()
			== FileAccess.get_sha256(GameState.get_paint_path(_book, 1)).to_lower(),
		"...and the picture painted while offline is up too")


# ================================================= l: the four status states ==

func _check_status_text() -> void:
	print("\n-- check l: the account panel's sync line --")
	var text := Backend.get_sync_status_text()
	_expect(text.begins_with("Last synced: ") and not text.ends_with("—"),
		"after a good drain it reads '%s'" % text)
	_expect(String(_auth.get_extra(Backend.EXTRA_LAST_SYNCED, "")) != "",
		"...stamped through AuthStore.set_extra(%s)" % Backend.EXTRA_LAST_SYNCED)

	var never := AuthStore.new(TEST_ROOT.path_join("never.json"))
	never.store_token("t", "someone@example.test", PackedStringArray(["save:sync"]), 0)
	_expect(Backend.NEVER_SYNCED_TEXT == "Last synced: —",
		"a signed-in device that has never synced reads '%s'" % Backend.NEVER_SYNCED_TEXT)
	never.erase()
	# "Sync off" was proved in check c, "Offline" in check k.


# ===================================================== device B, driven raw ==

func _b_progress(uid: String) -> Dictionary:
	var result: Dictionary = await _b.request_json(HTTPClient.METHOD_GET, "/sync/progress")
	if not bool(result[ApiClient.KEY_OK]) or typeof(result[ApiClient.KEY_DATA]) != TYPE_DICTIONARY:
		return {}
	for row: Variant in (result[ApiClient.KEY_DATA] as Dictionary).get("books", []):
		if typeof(row) == TYPE_DICTIONARY and String((row as Dictionary).get("book_uid", "")) == uid:
			return row as Dictionary
	return {}


func _b_paint_pages(uid: String) -> Array:
	var result: Dictionary = await _b.request_json(
		HTTPClient.METHOD_GET, "/sync/paint/%s" % uid
	)
	if not bool(result[ApiClient.KEY_OK]) or typeof(result[ApiClient.KEY_DATA]) != TYPE_DICTIONARY:
		return []
	return (result[ApiClient.KEY_DATA] as Dictionary).get("pages", []) as Array


## Device B's upload, through the same two-step the game uses -- so the 202's
## instructions are proved usable by something other than the code that wrote them.
func _b_upload_paint(uid: String, page_index: int, png: PackedByteArray, stamp: String) -> bool:
	var negotiation: Dictionary = await _b.request_json(
		HTTPClient.METHOD_POST, "/sync/paint/%s/%d" % [uid, page_index],
		{"sha256": _sha256_of(png), "bytes": png.size(), "client_painted_at": stamp}
	)
	if int(negotiation[ApiClient.KEY_STATUS]) == 204:
		return true
	var instructions := SyncQueue.upload_instructions(negotiation)
	if instructions.is_empty():
		print("   device B: no upload instructions (%s %s)"
			% [negotiation[ApiClient.KEY_STATUS], negotiation[ApiClient.KEY_CODE]])
		return false
	var upload: Dictionary = await _b.request_bytes(
		HTTPClient.METHOD_PUT, String(instructions["url"]), png,
		{"headers": instructions["headers"], "timeout": ApiClient.TIMEOUT_PACK}
	)
	if not bool(upload[ApiClient.KEY_OK]):
		print("   device B: upload failed (%s %s)"
			% [upload[ApiClient.KEY_STATUS], upload[ApiClient.KEY_CODE]])
	return bool(upload[ApiClient.KEY_OK])


static func _conflicted(result: Dictionary) -> bool:
	if typeof(result[ApiClient.KEY_DATA]) != TYPE_DICTIONARY:
		return false
	for row: Variant in (result[ApiClient.KEY_DATA] as Dictionary).get("results", []):
		if typeof(row) == TYPE_DICTIONARY and bool((row as Dictionary).get("conflict", false)):
			return true
	return false


# ==================================================================== painting ==

## One region-locked stroke, settled and read back -- the dlc_smoke/paint_smoke
## pattern.
func _paint_stroke(color: Color = Color(0.9, 0.2, 0.15, 1.0), size: float = BRUSH_DIAMETER) -> Image:
	if not _page_view.is_page_loaded():
		return null
	_page_view.brush_color = color
	_page_view.brush_size = size
	_page_view.clear_paint()
	await _settle()
	_page_view.begin_stroke(STROKE_START)
	var x := STROKE_START.x + 20.0
	while x <= STROKE_END.x:
		_page_view.continue_stroke(Vector2(x, STROKE_START.y))
		x += 20.0
	_page_view.end_stroke()
	await _settle()
	return _page_view.get_paint_image()


func _settle() -> void:
	for i in 8:
		await get_tree().process_frame
		if not _page_view.has_pending_paint():
			break
	await get_tree().process_frame
	await RenderingServer.frame_post_draw


## A page-sized solid PNG, standing in for "the picture painted on the other
## device". Page-sized so ColoringPage's restore path would accept it.
static func _solid_png(size: Vector2i, color: Color) -> PackedByteArray:
	var image := Image.create(maxi(size.x, 1), maxi(size.y, 1), false, Image.FORMAT_RGBA8)
	image.fill(color)
	return image.save_png_to_buffer()


static func _sha256_of(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode().to_lower()


# ===================================================================== helpers ==

## Waits for any in-flight or debounced drain, then runs one and waits for it.
## The game never does this -- nothing on screen may await a request (8.2) -- but a
## harness asserting against the server has to know when the push finished.
func _sync_now(pull: bool = false) -> void:
	await _idle()
	await Backend.sync_now(pull)
	await _idle()


func _idle() -> void:
	var queue := Backend.get_sync_queue()
	await _wait_for(func() -> bool: return not queue.is_draining(), 30.0)
	# One debounce window plus slack, so a scheduled drain has fired before the
	# next assertion reads the server.
	await get_tree().create_timer(queue.get_debounce_seconds() + 0.35).timeout
	await _wait_for(func() -> bool: return not queue.is_draining(), 30.0)


func _wait_for(condition: Callable, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return false


func _local_statuses() -> String:
	var progress := GameState.get_book_progress(BOOK_UID)
	var parts := PackedStringArray()
	for raw: Variant in (progress.get("pages", []) as Array):
		parts.append(String((raw as Dictionary).get(GameState.PAGE_STATUS_KEY, "untouched")))
	return ",".join(parts)


static func _server_statuses(row: Dictionary) -> String:
	var parts := PackedStringArray()
	for status: Variant in row.get("page_statuses", []):
		parts.append(String(status))
	return ",".join(parts)


static func _row_for_page(pages: Array, page_index: int) -> Dictionary:
	for row: Variant in pages:
		if typeof(row) == TYPE_DICTIONARY and int((row as Dictionary).get("page_index", -1)) == page_index:
			return row as Dictionary
	return {}


static func _state(current: int, statuses: Array, furthest: int, at: String) -> Dictionary:
	return {
		SyncQueue.STATE_CURRENT: current,
		SyncQueue.STATE_STATUSES: statuses,
		SyncQueue.STATE_FURTHEST: furthest,
		SyncQueue.STATE_UPDATED_AT: at,
	}


static func _statuses(state: Dictionary) -> String:
	var parts := PackedStringArray()
	for status: Variant in (state[SyncQueue.STATE_STATUSES] as Array):
		parts.append(String(status))
	return ",".join(parts)


## A readable, comparable snapshot -- the twin of ProgressMergeTest::snapshot().
static func _snapshot(state: Dictionary) -> String:
	return "%d|%s|%d|%.3f" % [
		int(state[SyncQueue.STATE_CURRENT]), _statuses(state),
		int(state[SyncQueue.STATE_FURTHEST]),
		SyncQueue.parse_iso8601(String(state[SyncQueue.STATE_UPDATED_AT])),
	]


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("%s - %s" % ["PASS" if condition else "FAIL", description])


static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var size := int(file.get_length())
	file.close()
	return size


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

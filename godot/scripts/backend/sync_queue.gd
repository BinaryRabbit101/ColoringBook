class_name SyncQueue
extends RefCounted
## Cloud saves: the client half of DLC_SERVER.md 6 (what syncs, how eagerly, and
## how a conflict resolves), 8.2 (offline-first) and 8.3 (the flow), against the
## server's [code]/sync/progress[/code] and [code]/sync/paint[/code] endpoints (11).
##
## Plain [RefCounted], like every other [Backend] part: it borrows a host [Node] for
## timers, an [ApiClient] for HTTP and an [AuthStore] for the token, and it can be
## built against scratch paths by a harness without the autoload, without a screen
## and without a tree of its own.
##
## [b]The user:// boundary.[/b] [code]GameState[/code] owns all of
## [code]user://[/code] except Backend's three carve-outs; this class owns the
## third, [constant QUEUE_PATH], plus a scratch directory INSIDE the DLC root
## ([constant DOWNLOAD_DIR_NAME], invisible to the shelf because
## [method BookDef.discover_runtime] skips dot-directories). Everything else it
## needs to write, it asks [code]GameState[/code] to write:
## [codeblock]
## progress in   ->  GameState.mark_page_status() / set_saved_page_index()
## paint in      ->  GameState.install_page_paint()
## progress out  <-  GameState.get_book_progress() (a copy, never the live dict)
## paint out     <-  the file at GameState.get_paint_path_for_key()
## [/codeblock]
## So there is still exactly one writer of the save and of every paint layer, which
## is the property DLC_SERVER.md 8.2 asks for by name.
##
## [b]Nothing here is ever awaited by a screen[/b] (8.2). Every entry point is
## fire-and-forget: [method schedule_drain] returns immediately and does its work
## five seconds later, [method on_book_opened] returns immediately, and a failure is
## a [code]print_verbose[/code] plus a backoff, never a modal, never a kid-facing
## string, never a change to what is on screen.
##
## [b]The queue is idempotent by construction[/b] (8.2: "every entry is 'here is my
## current state for book X at revision N', not a delta, so replaying it twice is
## harmless and a stale entry is simply superseded"). The file stores BOOKKEEPING
## only -- the base revision the server was last known to be on, the digest it was
## last known to hold, and when this device last changed the book -- and the state
## itself is read fresh out of [code]GameState[/code] at drain time. A book cannot
## therefore have two queued entries: there is one row per book and it always says
## "here is what I have now".
##
## [b]What is eager and what is lazy[/b] (6.2):
## [codeblock]
## progress  ~200 B   pushed at every save point, DEBOUNCED 5 s; pulled on
##                    launch and on book open
## paint     0.5-2 MB uploaded at save points, only for pages actually touched,
##                    sha256-negotiated first; downloaded ON DEMAND when a book
##                    is opened and the server has a picture this device has not
## [/codeblock]
## The debounce delays the SYNC and never the save: this class hooks
## [signal GameState.save_written] and [signal GameState.page_paint_written], both
## of which fire after the bytes are already on disk.
##
## [b]The merge rule is mirrored, not invented[/b] -- see [method merge_states].

## Emitted after a drain finishes, successfully or not. Dev/status only; no screen
## listens, and nothing about the game changes when it fires.
signal drained(ok: bool, reason: String)

## Backend's third [code]user://[/code] path (see the class doc and the header of
## [code]game_state.gd[/code]).
const QUEUE_PATH := "user://sync_queue.json"
## A file from a newer build is IGNORED rather than misread: the cost is one full
## re-sync, which is free, against corrupting a base revision, which is not.
const SCHEMA_VERSION := 1

## DLC_SERVER.md 6.2: "pushed at the existing save points, debounced 5 s".
const DEBOUNCE_SECONDS := 5.0
## Attempts one background drain makes per request before backing off and being
## rescheduled. Nothing is waiting, so retrying here is free (8.2).
const REQUEST_ATTEMPTS := 3
## How many times a failed drain reschedules itself before giving up until the next
## launch (8.2: "give up quietly after that until the next app launch"). Six steps
## of [method ApiClient.backoff_delay] reach its ~5-minute cap.
const MAX_BACKOFF_STEPS := 6

## Scratch directory for a paint download in flight, under the DLC root. Dotted, so
## [method BookDef.discover_runtime] and [method PackInstaller.installed_slugs] both
## skip it -- a half-downloaded picture must never look like a pack.
const DOWNLOAD_DIR_NAME := ".sync"

## Statuses, ranked. A mirror of [code]GameState[/code]'s constants and of the
## server's [code]App\ProgressMerge::ORDER[/code]; written out here so the merge can
## be read as one thing.
const STATUS_UNTOUCHED := "untouched"
const STATUS_IN_PROGRESS := "in_progress"
const STATUS_COMPLETE := "complete"
const STATUS_ORDER: PackedStringArray = [STATUS_UNTOUCHED, STATUS_IN_PROGRESS, STATUS_COMPLETE]

## Why a drain ran. Logging and the [signal drained] payload only.
const REASON_LAUNCH := "launch"
const REASON_SAVE := "save_point"
const REASON_BOOK_OPEN := "book_open"
const REASON_SIGN_IN := "sign_in"
const REASON_RETRY := "retry"

## Keys of one book's queue entry.
const KEY_BASE_REVISION := "base_revision"
const KEY_CLIENT_UPDATED_AT := "client_updated_at"
const KEY_FURTHEST := "furthest_page_index"
## Fingerprint of the local state as of [constant KEY_CLIENT_UPDATED_AT].
const KEY_FINGERPRINT := "fingerprint"
## Fingerprint the server has acknowledged. Differing from the above IS "dirty".
const KEY_SYNCED_FINGERPRINT := "synced_fingerprint"
const KEY_PAGES := "pages"

## Keys of one page's paint entry, inside [constant KEY_PAGES].
const KEY_SHA256 := "sha256"
const KEY_BYTES := "bytes"
const KEY_PAINTED_AT := "painted_at"
## The digest the server is known to hold. Equal to [constant KEY_SHA256] means
## there is nothing to upload -- re-syncing an unchanged page costs zero requests.
const KEY_SYNCED_SHA256 := "synced_sha256"

## Keys of the state dictionaries [method merge_states] works on.
const STATE_CURRENT := "current_page_index"
const STATE_STATUSES := "page_statuses"
const STATE_FURTHEST := "furthest_page_index"
const STATE_UPDATED_AT := "client_updated_at"

## Server error codes this class branches on (11, and server/CLAUDE.md WP4).
const CODE_PAINT_STALE := "PAINT_STALE"
const CODE_PAINT_CLOCK_SKEW := "PAINT_CLOCK_SKEW"
const CODE_PAINT_NOT_FOUND := "PAINT_NOT_FOUND"
const CODE_PAINT_TOO_LARGE := "PAINT_TOO_LARGE"

var _host: Node
var _api: ApiClient
var _auth: AuthStore
var _path := QUEUE_PATH
var _dlc_root := BookDef.DLC_ROOT

## book_uid -> entry (see the KEY_* constants).
var _books: Dictionary = {}
## The [code]?since=[/code] cursor: the server_time of the last complete pull.
var _cursor := ""
## Which account this bookkeeping belongs to. A different grown-up signing in on
## the same tablet must not inherit the last one's base revisions.
var _account := ""
## DLC_SERVER.md 6.2 wants paint on unmetered connections only. See
## [method is_picture_sync_enabled] for why that is a toggle rather than a probe.
var _sync_pictures := true

var _loaded := false
var _attached := false
var _draining := false
## A drain asked for while one was running; runs once the current one ends.
var _drain_again := false
var _debouncing := false
var _retrying := false
var _pending_reason := REASON_SAVE
## Consecutive failed drains, driving [method ApiClient.backoff_delay].
var _failures := 0
## True while a merge is being written INTO GameState, so the save that causes does
## not restamp [constant KEY_CLIENT_UPDATED_AT] as if the player had done it.
var _applying := false
## True while a pulled picture is being installed, so the resulting
## [signal GameState.page_paint_written] is not mistaken for the player painting.
var _installing := false

## uid -> BookDef, built once per drain batch. Discovery loads resources, so it is
## not something to do per merged page.
var _book_cache: Dictionary = {}
var _book_cache_ready := false

## Last drain's transport verdict, for the status line: "" when the last drain
## reached the server (or none has run), a code when it did not.
var _last_failure_code := ""
## The debounce, overridable by a harness only (see [method set_debounce_seconds]).
var _debounce_seconds := DEBOUNCE_SECONDS


func _init(host: Node, api: ApiClient, auth: AuthStore, path: String = QUEUE_PATH,
		dlc_root: String = BookDef.DLC_ROOT) -> void:
	_host = host
	_api = api
	_auth = auth
	_path = path
	_dlc_root = dlc_root


# ===================================================================== wiring ==

## Subscribes to the two save points (DLC_SERVER.md 6.2). Called by [Backend], not
## by [code]main.gd[/code]: the flow orchestrator has no business knowing sync
## exists.
func attach() -> void:
	if _attached:
		return
	_attached = true
	GameState.save_written.connect(_on_save_written)
	GameState.page_paint_written.connect(_on_page_paint_written)
	GameState.book_started.connect(_on_book_started)


func detach() -> void:
	if not _attached:
		return
	_attached = false
	if GameState.save_written.is_connected(_on_save_written):
		GameState.save_written.disconnect(_on_save_written)
	if GameState.page_paint_written.is_connected(_on_page_paint_written):
		GameState.page_paint_written.disconnect(_on_page_paint_written)
	if GameState.book_started.is_connected(_on_book_started):
		GameState.book_started.disconnect(_on_book_started)


func is_attached() -> bool:
	return _attached


# ============================================================== entry points ==

## App launch with a token present (8.3, top of the diagram): pull the shelf, merge
## it in, push whatever this device has that the server does not. Fire and forget.
func on_launch() -> void:
	if not is_active():
		return
	_reconcile(false)
	await drain(REASON_LAUNCH, true)


## A grown-up just signed in. Everything on this device is potentially unsynced --
## including paint painted while signed out -- so the local state is rescanned from
## scratch before the first drain.
func on_signed_in() -> void:
	_ensure_loaded()
	_adopt_account(_auth.get_email() if _auth != null else "")
	if not is_active():
		return
	_reconcile(true)
	await drain(REASON_SIGN_IN, true)


## Signing out. The bookkeeping is KEPT: the same grown-up signing back in on this
## tablet should resume from the same base revisions rather than re-pushing the
## shelf. A DIFFERENT account resets it (see [method _adopt_account]).
func on_signed_out() -> void:
	_ensure_loaded()
	_last_failure_code = ""


## A book was opened (8.3: "pulled on launch and on book open"). Pulls that book's
## progress and, behind the loading beat, any picture the server has that this
## device has not -- never blocking a stroke, never blocking the page load.
func on_book_opened(book: BookDef) -> void:
	if book == null or not is_active():
		return
	var uid := book.get_uid()
	await _pull_progress()
	if not is_active():
		return
	await _pull_book_paint(uid)
	_save()
	# A pull that merged anything leaves this device holding something the server
	# has not seen (the merge is two-sided). Debounced, so opening three books in a
	# row is still one push.
	if is_pending():
		schedule_drain(REASON_BOOK_OPEN)


## The debounced push (6.2). Returns immediately; the drain happens
## [constant DEBOUNCE_SECONDS] later, and any further save point in that window is
## absorbed into the same one.
func schedule_drain(reason: String = REASON_SAVE) -> void:
	if not is_active():
		return
	_pending_reason = reason
	if _debouncing:
		return
	_debouncing = true
	_debounce()


## One full push: progress first (with the 6.3 conflict protocol), then paint.
## [param pull] adds the 8.3 pull in front of it.
func drain(reason: String = REASON_SAVE, pull: bool = false) -> Dictionary:
	if not is_active():
		return {"ok": false, "code": "", "reason": reason}
	if _draining:
		_drain_again = true
		return {"ok": false, "code": "BUSY", "reason": reason}
	_draining = true
	_book_cache_ready = false
	var result := await _drain(reason, pull)
	_draining = false
	_save()
	drained.emit(bool(result["ok"]), reason)
	if bool(result["ok"]):
		_failures = 0
		_last_failure_code = ""
		if _auth != null:
			_auth.set_extra(Backend.EXTRA_LAST_SYNCED, iso_now())
	else:
		_failures += 1
		_last_failure_code = String(result["code"])
		print_verbose("SyncQueue: drain (%s) failed (%s); backing off."
			% [reason, result["code"]])
		_reschedule()
	if _drain_again:
		_drain_again = false
		schedule_drain(reason)
	return result


# ====================================================================== state ==

## False turns every method above into a silent no-op: no account, an expired token,
## no server configured, or the whole Backend switched off for this build.
## [method AuthStore.get_live_token] returning "" is the one that covers both signed
## out and lapsed (DLC_SERVER.md 4.2, 8.2).
func is_active() -> bool:
	return (
		BackendConfig.is_enabled()
		and _api != null and _api.get_base_url() != ""
		and _auth != null and _auth.get_live_token() != ""
		and _host != null and _host.is_inside_tree()
	)


## True when something is waiting to go up: a book whose local state the server has
## not acknowledged, or a painted page whose digest it does not hold.
func is_pending() -> bool:
	return pending_book_count() > 0 or pending_paint_count() > 0


func pending_book_count() -> int:
	_ensure_loaded()
	var count := 0
	for uid: Variant in _books:
		if _is_progress_dirty(String(uid)):
			count += 1
	return count


func pending_paint_count() -> int:
	_ensure_loaded()
	var count := 0
	for uid: Variant in _books:
		var pages: Dictionary = (_books[uid] as Dictionary)[KEY_PAGES]
		for key: Variant in pages:
			var page: Dictionary = pages[key]
			if String(page[KEY_SHA256]) != "" \
					and String(page[KEY_SHA256]) != String(page[KEY_SYNCED_SHA256]):
				count += 1
	return count


## Whether the last drain reached the server at all. Drives the "Offline" state of
## the account panel's sync line; nothing kid-facing reads it.
func is_offline() -> bool:
	return _last_failure_code in [ApiClient.CODE_OFFLINE, ApiClient.CODE_TIMEOUT]


## True while a drain is in flight. Nothing in the game waits on it; the smoke
## does, so its assertions are not racing a background push.
func is_draining() -> bool:
	return _draining


func get_debounce_seconds() -> float:
	return _debounce_seconds


## Retunes the 6.2 debounce. [b]DEV/TEST ONLY[/b] -- the mirror of
## [method GameState.set_autosave_interval], and for the same reason: a harness
## should not have to wait five real seconds to watch a push it already caused.
func set_debounce_seconds(seconds: float) -> void:
	_debounce_seconds = maxf(seconds, 0.0)


func get_last_failure_code() -> String:
	return _last_failure_code


## The revision the server was last known to be on for a book, or 0 for "never
## synced". Public so the smoke can assert the 6.3 protocol rather than infer it.
func get_base_revision(book_uid: String) -> int:
	_ensure_loaded()
	if not _books.has(book_uid):
		return 0
	return int((_books[book_uid] as Dictionary)[KEY_BASE_REVISION])


func get_cursor() -> String:
	_ensure_loaded()
	return _cursor


func get_path() -> String:
	return _path


## DLC_SERVER.md 6.2 asks for paint uploads "only on unmetered connections by
## default". [b]Godot exposes no portable way to ask that question[/b] -- there is
## no metered-connection API on any of the three platforms this game ships to, and
## guessing from the platform (mobile = metered?) would be wrong on a tablet on
## house wifi and wrong again on a tethered laptop. So the policy is a SETTING the
## grown-up owns, in the account panel behind the adult gate, defaulting to ON.
##
## The caveat that leaves, written down so it is a known gap and not a surprise: a
## child colouring on a phone plan with this on will upload half a megabyte a page.
## If Godot ever grows a metered-connection signal, this is the one place to
## consult it -- everything else already routes through here.
func is_picture_sync_enabled() -> bool:
	_ensure_loaded()
	return _sync_pictures


func set_picture_sync_enabled(enabled: bool) -> void:
	_ensure_loaded()
	if _sync_pictures == enabled:
		return
	_sync_pictures = enabled
	_save()
	if enabled and is_active():
		# Pages painted while this was OFF were never hashed -- [method
		# _on_page_paint_written] returns before touching them, so there is no cheap
		# way to know they moved. Switching the toggle back on therefore has to
		# rescan, exactly as a fresh sign-in does; otherwise a grown-up who turns
		# pictures on after a car journey would sync everything painted afterwards
		# and nothing painted during it.
		_reconcile(true)
		schedule_drain(REASON_SAVE)


# ============================================================== the save hooks ==

## DLC_SERVER.md 6.2's first hook. The save has ALREADY been written when this
## fires, so nothing here can delay it.
##
## The signal does not say WHICH book moved, and it does not need to: every book's
## fingerprint is recomputed and one that changed is restamped. That is also what
## makes the queue idempotent -- there is no delta to lose, only "what this device
## holds now".
func _on_save_written(_path: String) -> void:
	if not is_active():
		return
	if _reconcile(false) and not _applying:
		schedule_drain(REASON_SAVE)


## DLC_SERVER.md 6.2's second hook: paint is lazy, and this is the only moment it
## becomes uploadable. The file is on disk already (that is what the signal means),
## so it is hashed here rather than read back off the GPU -- 6.2's "it never
## triggers an extra get_paint_image() readback of its own", literally.
func _on_page_paint_written(book: BookDef, page_index: int, path: String) -> void:
	if _installing or book == null or not is_active():
		return
	if not is_picture_sync_enabled():
		return
	var uid := book.get_uid()
	var page := _page_entry(uid, page_index)
	var sha := FileAccess.get_sha256(path).to_lower()
	if sha == "":
		return
	page[KEY_SHA256] = sha
	page[KEY_BYTES] = _file_size(path)
	if sha != String(page[KEY_SYNCED_SHA256]):
		page[KEY_PAINTED_AT] = iso_now()
	_save()
	schedule_drain(REASON_SAVE)


## Book open (8.3). Fire and forget -- [method GameState.start_book] returns before
## any of this happens and the screen is built from local state regardless.
func _on_book_started(book: BookDef) -> void:
	if book == null or not is_active():
		return
	on_book_opened(book)


# =================================================================== the merge ==

## The client mirror of DLC_SERVER.md 6.3 -- and of the server's
## [code]App\Services\ProgressMerge[/code], detail for detail, because both ends
## running the IDENTICAL rule is what makes the protocol converge in one retry:
## [codeblock]
## page_statuses[i]   = max(a[i], b[i])  under untouched < in_progress < complete
## furthest_page_index= max(a, b)
## current_page_index = from whichever side has the newer client_updated_at
## [/codeblock]
##
## The four details the design leaves implicit, matched to the server's choices
## (see [code]tests/Unit/ProgressMergeTest.php[/code], which pins each of them):
##
## 1. [b]Unequal page counts pad with untouched[/b], the merge's identity, and the
##    result is as long as the LONGER side -- no page is ever dropped
##    ([code]test_the_shorter_side_is_padded_and_no_page_is_dropped[/code]).
## 2. [b]Equal timestamps tie-break on max(current_page_index)[/b]. "The newer side"
##    has no answer for one instant, and taking the left-hand side would break
##    commutativity outright
##    ([code]test_identical_timestamps_break_the_tie_on_the_further_page[/code]).
## 3. [b]The merged timestamp is the LATER of the two[/b], which is what keeps the
##    rule idempotent when the result is merged again with either input
##    ([code]test_the_merged_timestamp_is_the_later_of_the_two[/code]).
## 4. [b]An unrecognised status ranks as untouched AND the result is normalised[/b]
##    to one of the canonical three -- returning whichever argument won would make
##    merge(a, b) differ from merge(b, a) when both are unknown
##    ([code]test_an_unrecognised_status_ranks_as_untouched_and_is_normalised[/code],
##    [code]test_two_unknown_statuses_still_merge_commutatively[/code]).
##
## Commutative and idempotent, therefore: replaying a sync never changes the result,
## and a conflict is never a question anybody asks a five year old.
static func merge_states(a: Dictionary, b: Dictionary) -> Dictionary:
	var at := parse_iso8601(String(a.get(STATE_UPDATED_AT, "")))
	var bt := parse_iso8601(String(b.get(STATE_UPDATED_AT, "")))
	var current := 0
	if at > bt:
		current = int(a.get(STATE_CURRENT, 0))
	elif bt > at:
		current = int(b.get(STATE_CURRENT, 0))
	else:
		current = maxi(int(a.get(STATE_CURRENT, 0)), int(b.get(STATE_CURRENT, 0)))
	return {
		STATE_CURRENT: current,
		STATE_STATUSES: _merge_statuses(
			a.get(STATE_STATUSES, []) as Array, b.get(STATE_STATUSES, []) as Array
		),
		STATE_FURTHEST: maxi(int(a.get(STATE_FURTHEST, 0)), int(b.get(STATE_FURTHEST, 0))),
		STATE_UPDATED_AT: String(a.get(STATE_UPDATED_AT, "")) if at >= bt \
			else String(b.get(STATE_UPDATED_AT, "")),
	}


static func _merge_statuses(a: Array, b: Array) -> Array:
	var merged: Array = []
	for i in maxi(a.size(), b.size()):
		var left := String(a[i]) if i < a.size() else STATUS_UNTOUCHED
		var right := String(b[i]) if i < b.size() else STATUS_UNTOUCHED
		merged.append(STATUS_ORDER[maxi(status_rank(left), status_rank(right))])
	return merged


## untouched = 0, in_progress = 1, complete = 2; anything else = 0. An unknown
## status must never outrank a finished page.
static func status_rank(status: String) -> int:
	var index := STATUS_ORDER.find(status)
	return index if index >= 0 else 0


# ===================================================================== the pull ==

## [code]GET /sync/progress?since=[/code], merged into [code]GameState[/code]
## through its own API (8.2, 8.3).
func _pull_progress() -> Dictionary:
	var query := {}
	if _cursor != "":
		query["since"] = _cursor
	var result: Dictionary = await _api.request_json(
		HTTPClient.METHOD_GET, "/sync/progress", null,
		{"query": query, "attempts": REQUEST_ATTEMPTS}
	)
	if not bool(result[ApiClient.KEY_OK]):
		return result
	var data: Variant = result[ApiClient.KEY_DATA]
	if typeof(data) != TYPE_DICTIONARY:
		return result
	var body := data as Dictionary
	var complete := true
	for row: Variant in body.get("books", []):
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var server := row as Dictionary
		var uid := String(server.get("book_uid", ""))
		if uid == "":
			continue
		var entry := _entry(uid)
		entry[KEY_BASE_REVISION] = int(server.get("revision", 0))
		if not _apply_server_state(uid, server):
			# A book this device cannot resolve to a BookDef -- a DLC pack it has not
			# installed. Its progress is not lost, it is simply not applicable yet, so
			# the CURSOR IS NOT ADVANCED past it and the next pull sees it again.
			complete = false
	if complete:
		_cursor = String(body.get("server_time", _cursor))
	_save()
	return result


## Merges one server row into the local save. Returns false when the book is not
## installed on this device, which is the one case the caller must not swallow.
func _apply_server_state(uid: String, server: Dictionary) -> bool:
	var book := _book_for_uid(uid)
	if book == null:
		return false
	var entry := _entry(uid)
	var local := _local_state(uid)
	var merged := merge_states(local, _state_from_server(server))
	_applying = true
	var statuses: Array = merged[STATE_STATUSES]
	for i in mini(statuses.size(), book.page_count()):
		# mark_page_status is monotonic and refuses downgrades; the merge has already
		# guaranteed it is never asked for one.
		GameState.mark_page_status(book, i, String(statuses[i]))
	GameState.set_saved_page_index(book, int(merged[STATE_CURRENT]))
	_applying = false
	entry[KEY_FURTHEST] = int(merged[STATE_FURTHEST])
	# The merged state is what this device now holds, AS OF the merged timestamp --
	# not as of now. Restamping it now would let a merge win a tie it did not earn.
	entry[KEY_CLIENT_UPDATED_AT] = _later(
		String(merged[STATE_UPDATED_AT]), String(entry[KEY_CLIENT_UPDATED_AT])
	)
	entry[KEY_FINGERPRINT] = _fingerprint(_local_state(uid))
	return true


# ===================================================================== the push ==

func _drain(reason: String, pull: bool) -> Dictionary:
	if pull:
		var pulled := await _pull_progress()
		if not bool(pulled[ApiClient.KEY_OK]):
			return _result(false, String(pulled[ApiClient.KEY_CODE]), reason)
		if not is_active():
			return _result(false, ApiClient.CODE_CANCELLED, reason)
	var pushed := await _push_progress()
	if not bool(pushed["ok"]):
		return _result(false, String(pushed["code"]), reason)
	if is_picture_sync_enabled():
		var painted := await _push_paint()
		if not bool(painted["ok"]):
			return _result(false, String(painted["code"]), reason)
	return _result(true, "", reason)


## The batched [code]PUT /sync/progress[/code] (11: "one call for the whole shelf"),
## and the 6.3 conflict protocol on top of it.
##
## [b]The server answers 200 with a per-book verdict[/b], never a whole-request 409
## (server/CLAUDE.md, "Conflicts are per book, inside a 200"): a shelf where one
## book conflicted and four synced cleanly has no single HTTP status. A conflicted
## book was NOT written, and its [code]server[/code] block is everything needed to
## merge locally and retry that one book at the revision it names -- ONCE. A second
## conflict means a third device is pushing right now; the entry stays dirty and the
## backoff picks it up.
func _push_progress() -> Dictionary:
	var payload: Array = []
	var sent := {}
	for uid_variant: Variant in _books:
		var uid := String(uid_variant)
		if not _is_progress_dirty(uid):
			continue
		var state := _local_state(uid)
		sent[uid] = _fingerprint(state)
		payload.append(_push_row(uid, state))
	if payload.is_empty():
		return {"ok": true, "code": ""}

	var result: Dictionary = await _api.request_json(
		HTTPClient.METHOD_PUT, "/sync/progress", {"books": payload},
		{"attempts": REQUEST_ATTEMPTS}
	)
	if not bool(result[ApiClient.KEY_OK]):
		return {"ok": false, "code": String(result[ApiClient.KEY_CODE])}

	var conflicted := _absorb_results(result, sent)
	if conflicted.is_empty():
		return {"ok": true, "code": ""}

	# The one retry (6.3: "the client merges and retries once").
	var retry: Array = []
	var resent := {}
	for uid: String in conflicted:
		var state := _local_state(uid)
		resent[uid] = _fingerprint(state)
		retry.append(_push_row(uid, state))
	var second: Dictionary = await _api.request_json(
		HTTPClient.METHOD_PUT, "/sync/progress", {"books": retry},
		{"attempts": REQUEST_ATTEMPTS}
	)
	if not bool(second[ApiClient.KEY_OK]):
		return {"ok": false, "code": String(second[ApiClient.KEY_CODE])}
	var still := _absorb_results(second, resent)
	if not still.is_empty():
		print_verbose("SyncQueue: %d book(s) still conflicting after one retry; leaving them queued."
			% still.size())
	return {"ok": true, "code": ""}


## Reads a [code]PUT /sync/progress[/code] response. Returns the uids that
## conflicted AND were merged locally, i.e. the ones worth retrying.
func _absorb_results(result: Dictionary, sent: Dictionary) -> PackedStringArray:
	var conflicted := PackedStringArray()
	var data: Variant = result[ApiClient.KEY_DATA]
	if typeof(data) != TYPE_DICTIONARY:
		return conflicted
	for row: Variant in (data as Dictionary).get("results", []):
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var verdict := row as Dictionary
		var uid := String(verdict.get("book_uid", ""))
		if uid == "" or not _books.has(uid):
			continue
		var entry := _entry(uid)
		if not bool(verdict.get("conflict", false)):
			entry[KEY_BASE_REVISION] = int(verdict.get("revision", 0))
			# Only what we actually SENT is acknowledged: the player may have painted
			# another page while the request was in flight, and that is still dirty.
			entry[KEY_SYNCED_FINGERPRINT] = String(sent.get(uid, ""))
			continue
		var server: Variant = verdict.get("server", null)
		if typeof(server) != TYPE_DICTIONARY:
			continue
		entry[KEY_BASE_REVISION] = int((server as Dictionary).get("revision",
			entry[KEY_BASE_REVISION]))
		if _apply_server_state(uid, server as Dictionary):
			conflicted.append(uid)
	return conflicted


func _push_row(uid: String, state: Dictionary) -> Dictionary:
	return {
		"book_uid": uid,
		"base_revision": int((_books[uid] as Dictionary)[KEY_BASE_REVISION]),
		"current_page_index": int(state[STATE_CURRENT]),
		"page_statuses": state[STATE_STATUSES],
		"furthest_page_index": int(state[STATE_FURTHEST]),
		"client_updated_at": String(state[STATE_UPDATED_AT]),
	}


# ====================================================================== paint ==

## Uploads every page whose local digest the server is not known to hold. Lazy by
## construction: pages nobody painted have no entry, and a page whose sha256 already
## matches costs zero requests (6.3: "re-syncing an unchanged page is free").
func _push_paint() -> Dictionary:
	for uid_variant: Variant in _books.keys():
		var uid := String(uid_variant)
		var pages: Dictionary = (_books[uid] as Dictionary)[KEY_PAGES]
		for key: Variant in pages.keys():
			var page: Dictionary = pages[key]
			if String(page[KEY_SHA256]) == "" \
					or String(page[KEY_SHA256]) == String(page[KEY_SYNCED_SHA256]):
				continue
			if not is_active():
				return {"ok": false, "code": ApiClient.CODE_CANCELLED}
			var outcome := await _upload_page(uid, int(String(key)), page)
			if not bool(outcome["ok"]):
				return outcome
	return {"ok": true, "code": ""}


## One page, the whole 8.3 negotiation: sha first, then the bytes, then whatever
## last-write-wins decided.
func _upload_page(uid: String, page_index: int, page: Dictionary) -> Dictionary:
	var path := GameState.get_paint_path_for_key(uid, page_index)
	if path == "" or not FileAccess.file_exists(path):
		# The page was reset (BL-7) or the book erased. Nothing to send.
		page[KEY_SHA256] = ""
		return {"ok": true, "code": ""}
	# Re-hashed rather than trusted: the file may have been rewritten since the
	# signal that queued it, and uploading bytes whose digest we only think we know
	# is exactly what the double digest check exists to catch.
	var sha := FileAccess.get_sha256(path).to_lower()
	var size := _file_size(path)
	page[KEY_SHA256] = sha
	page[KEY_BYTES] = size
	if sha == String(page[KEY_SYNCED_SHA256]):
		return {"ok": true, "code": ""}

	var negotiation: Dictionary = await _api.request_json(
		HTTPClient.METHOD_POST, "/sync/paint/%s/%d" % [uid, page_index],
		{
			"sha256": sha,
			"bytes": size,
			"client_painted_at": String(page[KEY_PAINTED_AT]),
		},
		{"attempts": REQUEST_ATTEMPTS}
	)
	var status := int(negotiation[ApiClient.KEY_STATUS])
	if status == 204:
		# The server already holds these exact bytes. No upload at all.
		page[KEY_SYNCED_SHA256] = sha
		return {"ok": true, "code": ""}
	if not bool(negotiation[ApiClient.KEY_OK]):
		return _paint_failure(uid, page_index, negotiation)
	var instructions := upload_instructions(negotiation)
	if instructions.is_empty():
		return {"ok": false, "code": ApiClient.CODE_BAD_BODY}
	if size > int(instructions.get("max_bytes", size)):
		# Nothing will make this succeed, so it is not a transport failure and must
		# not stall every other page behind a backoff.
		push_warning("SyncQueue: page %d of '%s' is %d bytes, over the server's cap; not uploading."
			% [page_index + 1, uid, size])
		return {"ok": true, "code": ""}

	var upload: Dictionary = await _api.request_bytes(
		HTTPClient.METHOD_PUT, String(instructions["url"]),
		FileAccess.get_file_as_bytes(path),
		{"headers": instructions["headers"], "timeout": ApiClient.TIMEOUT_PACK}
	)
	var upload_status := int(upload[ApiClient.KEY_STATUS])
	if upload_status == 201 or upload_status == 204:
		page[KEY_SYNCED_SHA256] = sha
		return {"ok": true, "code": ""}
	if String(upload[ApiClient.KEY_CODE]) == CODE_PAINT_STALE:
		# 6.3: our copy is the older one. `details.server` means PULL, not retry.
		await _pull_page_paint(uid, page_index, stale_server_block(upload))
		return {"ok": true, "code": ""}
	return _paint_failure(uid, page_index, upload)


## The [code]202[/code]'s instructions, taken VERBATIM (server/CLAUDE.md WP4: "the
## client never has to build that header itself -- the 202 hands back the exact URL
## and headers to use"). Building the RFC 9530 [code]Content-Digest[/code] locally
## would be a second implementation of the thing the digest is there to check.
static func upload_instructions(negotiation: Dictionary) -> Dictionary:
	var data: Variant = negotiation[ApiClient.KEY_DATA]
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	var upload: Variant = (data as Dictionary).get("upload", null)
	if typeof(upload) != TYPE_DICTIONARY:
		return {}
	var block := upload as Dictionary
	var url := String(block.get("url", ""))
	if url == "":
		return {}
	var headers := PackedStringArray()
	var raw: Variant = block.get("headers", {})
	if typeof(raw) == TYPE_DICTIONARY:
		for name: Variant in (raw as Dictionary):
			headers.append("%s: %s" % [String(name), String((raw as Dictionary)[name])])
	return {"url": url, "headers": headers, "max_bytes": int(block.get("max_bytes", 0))}


## The [code]details.server[/code] block of a [code]409 PAINT_STALE[/code].
static func stale_server_block(result: Dictionary) -> Dictionary:
	var data: Variant = result[ApiClient.KEY_DATA]
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	var envelope: Variant = (data as Dictionary).get("error", null)
	if typeof(envelope) != TYPE_DICTIONARY:
		return {}
	var details: Variant = (envelope as Dictionary).get("details", null)
	if typeof(details) != TYPE_DICTIONARY:
		return {}
	var server: Variant = (details as Dictionary).get("server", null)
	return (server as Dictionary) if typeof(server) == TYPE_DICTIONARY else {}


## [code]GET /sync/paint/{book_uid}[/code] -- per-page metadata, no pixels. The
## download-on-demand check of 6.2, run on book open, behind the loading beat.
func _pull_book_paint(uid: String) -> void:
	if not is_picture_sync_enabled():
		return
	var result: Dictionary = await _api.request_json(
		HTTPClient.METHOD_GET, "/sync/paint/%s" % uid, null, {"attempts": REQUEST_ATTEMPTS}
	)
	if not bool(result[ApiClient.KEY_OK]) or typeof(result[ApiClient.KEY_DATA]) != TYPE_DICTIONARY:
		return
	for row: Variant in (result[ApiClient.KEY_DATA] as Dictionary).get("pages", []):
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var server := row as Dictionary
		var page_index := int(server.get("page_index", -1))
		if page_index < 0:
			continue
		if not _wants_server_paint(uid, page_index, server):
			continue
		await _pull_page_paint(uid, page_index, server)


## Whether the server's picture for this page should be fetched.
func _wants_server_paint(uid: String, page_index: int, server: Dictionary) -> bool:
	var sha := String(server.get("sha256", "")).to_lower()
	if sha == "":
		return false
	var path := GameState.get_paint_path_for_key(uid, page_index)
	var page := _page_entry(uid, page_index)
	if path == "" or not FileAccess.file_exists(path):
		# 6.2, verbatim: "downloaded on demand when a page is opened on a device that
		# has no local paint".
		return true
	if FileAccess.get_sha256(path).to_lower() == sha:
		page[KEY_SYNCED_SHA256] = sha
		return false
	# Both sides have a picture and they differ: last-write-wins decides, and it is
	# only worth a download when the SERVER is the later one.
	if parse_iso8601(String(server.get("client_painted_at", ""))) \
			<= parse_iso8601(String(page[KEY_PAINTED_AT])):
		return false
	# Never replace the pixels under the page that is open right now: the screen
	# holds its own layer and would overwrite this at the next save point anyway,
	# and swapping the file mid-visit is exactly the "a response yanks a screen"
	# failure 8.2 forbids.
	if GameState.current_book != null and GameState.current_book.get_uid() == uid \
			and GameState.current_page_index == page_index:
		return false
	return true


## [code]GET /sync/paint/{book}/{page}[/code] -> 302 -> the bytes -> GameState.
##
## [b]On native the redirect is READ rather than followed[/b]
## ([code]max_redirects = 0[/code], the same pattern [PackInstaller] uses for a
## pack): Godot reports the redirect limit instead of chasing it, which is what
## stops the bearer header being forwarded to a URL that authorises itself in its
## query string (7.4).
##
## [b]In a browser that is not available[/b] (BL-19): fetch follows the 302 itself
## and never exposes a [code]Location[/code], so the two-step would sit on an empty
## URL and this device would silently never pull a picture. On web the authorised
## endpoint is therefore downloaded directly, in one request, and the redirect --
## bearer header and all -- is the browser's own business. See
## [method ApiClient.can_read_redirects].
func _pull_page_paint(uid: String, page_index: int, server: Dictionary) -> bool:
	var book := _book_for_uid(uid)
	if book == null:
		return false
	var authorised := "/sync/paint/%s/%d" % [uid, page_index]
	var url := ""
	if ApiClient.can_read_redirects():
		var redirect: Dictionary = await _api.request_json(
			HTTPClient.METHOD_GET, authorised, null,
			{"follow_redirects": false, "attempts": REQUEST_ATTEMPTS}
		)
		url = String(redirect.get(ApiClient.KEY_LOCATION, ""))
		if url == "":
			if String(redirect[ApiClient.KEY_CODE]) != CODE_PAINT_NOT_FOUND:
				print_verbose("SyncQueue: no paint URL for %s page %d (%s)."
					% [uid, page_index + 1, redirect[ApiClient.KEY_CODE]])
			return false

	var scratch := _download_dir().path_join("%s_%02d.png" % [uid, page_index + 1])
	# A signed URL carries its own authorisation and must NOT get a bearer header;
	# the authorised endpoint (the web path) is exactly the one that needs it.
	var download: Dictionary = await _api.download(
		url if url != "" else authorised, scratch, {"auth": url == ""}
	)
	if not bool(download[ApiClient.KEY_OK]) or not FileAccess.file_exists(scratch):
		# A refused download still wrote the error body to the scratch path; leaving
		# it there would fill the tablet one failed pull at a time.
		DirAccess.remove_absolute(scratch)
		return false
	var bytes := FileAccess.get_file_as_bytes(scratch)
	var sha := FileAccess.get_sha256(scratch).to_lower()
	DirAccess.remove_absolute(scratch)

	var expected := String(server.get("sha256", "")).to_lower()
	if expected != "" and sha != expected:
		# A signed link resolves to whatever is current when it is redeemed, so
		# another device could have won a race inside its ten minutes. Drop it; the
		# next book open asks again.
		print_verbose("SyncQueue: %s page %d arrived as %s, expected %s; discarded."
			% [uid, page_index + 1, sha.left(12), expected.left(12)])
		return false

	_installing = true
	var installed := GameState.install_page_paint(book, page_index, bytes)
	_installing = false
	if not installed:
		return false
	var page := _page_entry(uid, page_index)
	page[KEY_SHA256] = sha
	page[KEY_SYNCED_SHA256] = sha
	page[KEY_BYTES] = bytes.size()
	page[KEY_PAINTED_AT] = String(server.get("client_painted_at", iso_now()))
	_save()
	print_verbose("SyncQueue: pulled the server's picture for %s page %d."
		% [uid, page_index + 1])
	return true


func _paint_failure(uid: String, page_index: int, result: Dictionary) -> Dictionary:
	var code := String(result[ApiClient.KEY_CODE])
	if code in [CODE_PAINT_CLOCK_SKEW, CODE_PAINT_TOO_LARGE]:
		# The device's own fault and not retryable by hammering: log it and let the
		# rest of the shelf sync. It stays queued for a later, saner attempt.
		push_warning("SyncQueue: the server refused page %d of '%s' (%s: %s)."
			% [page_index + 1, uid, code, result[ApiClient.KEY_MESSAGE]])
		return {"ok": true, "code": ""}
	return {"ok": false, "code": code}


# ================================================================== local state ==

## What this device holds for a book, in the shape [method merge_states] works on.
## Read out of [code]GameState[/code] every time rather than cached in the queue --
## that is what makes an entry "my current state for book X" instead of a delta.
func _local_state(uid: String) -> Dictionary:
	var progress := GameState.get_book_progress(uid)
	var statuses: Array = []
	var highest := -1
	for raw: Variant in (progress.get("pages", []) as Array):
		var status := STATUS_UNTOUCHED
		if typeof(raw) == TYPE_DICTIONARY:
			status = String((raw as Dictionary).get(GameState.PAGE_STATUS_KEY, STATUS_UNTOUCHED))
		if status_rank(status) > 0:
			highest = statuses.size()
		statuses.append(STATUS_ORDER[status_rank(status)])
	var current := int(progress.get("current_page_index", 0))
	var entry := _entry(uid)
	# GameState does not store "furthest": it is derived (the last page with any
	# paint on it, or the cursor) and then kept monotonic by the entry, exactly as
	# the server keeps it monotonic through max().
	var furthest := maxi(maxi(current, highest), int(entry[KEY_FURTHEST]))
	return {
		STATE_CURRENT: current,
		STATE_STATUSES: statuses,
		STATE_FURTHEST: furthest,
		STATE_UPDATED_AT: String(entry[KEY_CLIENT_UPDATED_AT]),
	}


static func _state_from_server(server: Dictionary) -> Dictionary:
	var statuses: Array = []
	for raw: Variant in server.get("page_statuses", []):
		statuses.append(STATUS_ORDER[status_rank(String(raw))])
	return {
		STATE_CURRENT: int(server.get("current_page_index", 0)),
		STATE_STATUSES: statuses,
		STATE_FURTHEST: int(server.get("furthest_page_index", 0)),
		STATE_UPDATED_AT: String(server.get("client_updated_at", "")),
	}


## Everything that identifies a book's state on the wire, as one comparable string.
## Two devices agreeing on this agree on the whole push.
static func _fingerprint(state: Dictionary) -> String:
	var statuses := PackedStringArray()
	for status: Variant in (state[STATE_STATUSES] as Array):
		statuses.append(String(status))
	return "%d|%d|%s" % [
		int(state[STATE_CURRENT]), int(state[STATE_FURTHEST]), ",".join(statuses)
	]


## Recomputes every known book's fingerprint and restamps the ones that moved.
## Returns true when anything changed. [param full] additionally re-hashes paint
## layers on disk, which is what a fresh sign-in needs and a save point does not.
func _reconcile(full: bool) -> bool:
	_ensure_loaded()
	if _applying:
		# The save being reacted to is one a MERGE just caused, not one the player
		# did. Restamping client_updated_at here would let a merge claim it authored
		# the state it only reconciled -- and win a tie against the device that
		# really did. _apply_server_state sets the fingerprint itself, from the
		# merged timestamp.
		return false
	var changed := false
	for uid in GameState.get_book_uids():
		var entry := _entry(uid)
		var fingerprint := _fingerprint(_local_state(uid))
		if fingerprint != String(entry[KEY_FINGERPRINT]):
			entry[KEY_FINGERPRINT] = fingerprint
			# The state moved on THIS device, now. That is precisely what
			# `client_updated_at` asserts (6.3), and it comes from the device clock --
			# the server clamps it if this tablet's date is wildly wrong.
			entry[KEY_CLIENT_UPDATED_AT] = iso_now()
			changed = true
		var state := _local_state(uid)
		entry[KEY_FURTHEST] = int(state[STATE_FURTHEST])
		if fingerprint != String(entry[KEY_SYNCED_FINGERPRINT]):
			changed = true
		if full and is_picture_sync_enabled():
			changed = _rehash_paint(uid) or changed
	if changed:
		_save()
	return changed


## Hashes every paint layer a book has on disk. Only ever run on sign-in: at a save
## point the write itself tells us which page moved.
func _rehash_paint(uid: String) -> bool:
	var changed := false
	var progress := GameState.get_book_progress(uid)
	var pages: Array = progress.get("pages", [])
	for page_index in pages.size():
		var path := GameState.get_paint_path_for_key(uid, page_index)
		if path == "" or not FileAccess.file_exists(path):
			continue
		var page := _page_entry(uid, page_index)
		var sha := FileAccess.get_sha256(path).to_lower()
		if sha == String(page[KEY_SHA256]):
			continue
		page[KEY_SHA256] = sha
		page[KEY_BYTES] = _file_size(path)
		if String(page[KEY_PAINTED_AT]) == "":
			page[KEY_PAINTED_AT] = iso_now()
		changed = true
	return changed


func _is_progress_dirty(uid: String) -> bool:
	if not _books.has(uid):
		return false
	var entry: Dictionary = _books[uid]
	return String(entry[KEY_FINGERPRINT]) != String(entry[KEY_SYNCED_FINGERPRINT])


# ======================================================================= books ==

## uid -> [BookDef], resolved once per drain. Built-in and installed DLC books both,
## because progress is keyed by uid whichever way the book arrived (6.1).
func _book_for_uid(uid: String) -> BookDef:
	if GameState.current_book != null and GameState.current_book.get_uid() == uid:
		return GameState.current_book
	if not _book_cache_ready:
		_book_cache.clear()
		for book in BookDef.discover(BookDef.BOOKS_ROOT, _dlc_root):
			if not _book_cache.has(book.get_uid()):
				_book_cache[book.get_uid()] = book
		_book_cache_ready = true
	return _book_cache.get(uid, null) as BookDef


## Drops the resolved-book cache. Called when the installed packs change, so a book
## that has just arrived is mergeable without waiting for a restart.
func invalidate_books() -> void:
	_book_cache_ready = false
	_book_cache.clear()


# ================================================================== scheduling ==

func _debounce() -> void:
	await _sleep(_debounce_seconds)
	_debouncing = false
	if not is_active():
		return
	await drain(_pending_reason)


func _reschedule() -> void:
	if _retrying or _failures > MAX_BACKOFF_STEPS:
		return
	_retrying = true
	await _sleep(ApiClient.backoff_delay(_failures))
	_retrying = false
	if not is_active():
		return
	await drain(REASON_RETRY)


func _sleep(seconds: float) -> void:
	if _host == null or not _host.is_inside_tree():
		return
	await _host.get_tree().create_timer(seconds).timeout


# ======================================================================== time ==

## Device-clock now, ISO 8601 UTC with milliseconds -- the sub-second precision
## DLC_SERVER.md 6.3's tie-break needs, and what Carbon parses on the other end.
static func iso_now() -> String:
	return iso_from_unix(Time.get_unix_time_from_system())


static func iso_from_unix(unix: float) -> String:
	var whole := int(floor(unix))
	var millis := int(round((unix - float(whole)) * 1000.0))
	if millis >= 1000:
		whole += 1
		millis = 0
	# use_space stays FALSE: the API wants the ISO 8601 'T', not a space.
	return "%s.%03dZ" % [Time.get_datetime_string_from_unix_time(whole, false), millis]


## ISO 8601 -> unix seconds as a FLOAT, keeping the fraction.
##
## [method Time.get_unix_time_from_datetime_string] truncates to whole seconds and
## does not apply an offset, and both matter here: the server writes
## [code]client_updated_at[/code] to the second with a [code]+00:00[/code] suffix
## while this device writes milliseconds with a [code]Z[/code], and the merge's
## "whichever side is newer" has to compare the two honestly.
static func parse_iso8601(text: String) -> float:
	var value := text.strip_edges()
	if value == "":
		return 0.0
	var offset_seconds := 0
	# Trailing timezone: Z, +HH:MM or -HH:MM. Searched from the END so the '-' in
	# the date is never mistaken for a sign.
	if value.ends_with("Z") or value.ends_with("z"):
		value = value.substr(0, value.length() - 1)
	else:
		var sign_at := maxi(value.rfind("+"), value.rfind("-"))
		if sign_at > 10:
			var zone := value.substr(sign_at + 1).replace(":", "")
			while zone.length() < 4:
				zone += "0"
			offset_seconds = int(zone.substr(0, 2)) * 3600 + int(zone.substr(2, 2)) * 60
			if value[sign_at] == "+":
				offset_seconds = -offset_seconds
			value = value.substr(0, sign_at)
	var fraction := 0.0
	var dot := value.find(".")
	if dot >= 0:
		fraction = float("0" + value.substr(dot))
		value = value.substr(0, dot)
	return float(Time.get_unix_time_from_datetime_string(value) + offset_seconds) + fraction


## The later of two ISO 8601 stamps, either of which may be "".
static func _later(a: String, b: String) -> String:
	if a == "":
		return b
	if b == "":
		return a
	return a if parse_iso8601(a) >= parse_iso8601(b) else b


## "just now" / "5 minutes ago" / "2 hours ago" / "3 days ago". Grown-up facing
## only (8.2: the child sees nothing at all).
static func describe_age(seconds: float) -> String:
	if seconds < 60.0:
		return "just now"
	if seconds < 3600.0:
		var minutes := int(seconds / 60.0)
		return "%d minute%s ago" % [minutes, "" if minutes == 1 else "s"]
	if seconds < 86400.0:
		var hours := int(seconds / 3600.0)
		return "%d hour%s ago" % [hours, "" if hours == 1 else "s"]
	var days := int(seconds / 86400.0)
	return "%d day%s ago" % [days, "" if days == 1 else "s"]


# ======================================================================== disk ==

func _entry(uid: String) -> Dictionary:
	_ensure_loaded()
	if not _books.has(uid):
		_books[uid] = {
			KEY_BASE_REVISION: 0,
			KEY_CLIENT_UPDATED_AT: "",
			KEY_FURTHEST: 0,
			KEY_FINGERPRINT: "",
			KEY_SYNCED_FINGERPRINT: "",
			KEY_PAGES: {},
		}
	return _books[uid]


func _page_entry(uid: String, page_index: int) -> Dictionary:
	var pages: Dictionary = _entry(uid)[KEY_PAGES]
	var key := str(page_index)
	if not pages.has(key):
		pages[key] = {
			KEY_SHA256: "", KEY_BYTES: 0, KEY_PAINTED_AT: "", KEY_SYNCED_SHA256: "",
		}
	return pages[key]


## A different grown-up on this tablet starts from nothing: base revisions and a
## cursor belong to an account, and inheriting them would push one family's shelf
## into another's.
func _adopt_account(email: String) -> void:
	if email == "" or email == _account:
		_account = email
		return
	if _account != "":
		print_verbose("SyncQueue: '%s' replaced '%s'; the queue starts fresh."
			% [email, _account])
		_books.clear()
		_cursor = ""
	_account = email
	_save()


func _download_dir() -> String:
	var directory := _dlc_root.path_join(DOWNLOAD_DIR_NAME)
	if not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	return directory


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
		push_warning("SyncQueue: '%s' is not a JSON object; starting with an empty queue." % _path)
		return
	var data := parsed as Dictionary
	if int(data.get("version", 0)) > SCHEMA_VERSION:
		push_warning("SyncQueue: '%s' is newer than v%d; ignoring it." % [_path, SCHEMA_VERSION])
		return
	_account = String(data.get("account", ""))
	_cursor = String(data.get("cursor", ""))
	_sync_pictures = bool(data.get("sync_pictures", true))
	var books: Variant = data.get("books", {})
	if typeof(books) != TYPE_DICTIONARY:
		return
	for uid_variant: Variant in (books as Dictionary):
		var raw: Variant = (books as Dictionary)[uid_variant]
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var stored := raw as Dictionary
		var entry := _entry(String(uid_variant))
		entry[KEY_BASE_REVISION] = int(stored.get(KEY_BASE_REVISION, 0))
		entry[KEY_CLIENT_UPDATED_AT] = String(stored.get(KEY_CLIENT_UPDATED_AT, ""))
		entry[KEY_FURTHEST] = int(stored.get(KEY_FURTHEST, 0))
		entry[KEY_FINGERPRINT] = String(stored.get(KEY_FINGERPRINT, ""))
		entry[KEY_SYNCED_FINGERPRINT] = String(stored.get(KEY_SYNCED_FINGERPRINT, ""))
		var pages: Variant = stored.get(KEY_PAGES, {})
		if typeof(pages) != TYPE_DICTIONARY:
			continue
		for key: Variant in (pages as Dictionary):
			var page_raw: Variant = (pages as Dictionary)[key]
			if typeof(page_raw) != TYPE_DICTIONARY:
				continue
			var page := _page_entry(String(uid_variant), int(String(key)))
			page[KEY_SHA256] = String((page_raw as Dictionary).get(KEY_SHA256, ""))
			page[KEY_BYTES] = int((page_raw as Dictionary).get(KEY_BYTES, 0))
			page[KEY_PAINTED_AT] = String((page_raw as Dictionary).get(KEY_PAINTED_AT, ""))
			page[KEY_SYNCED_SHA256] = String((page_raw as Dictionary).get(KEY_SYNCED_SHA256, ""))


## Writes the queue. Called after every mutation: an offline session's pending
## pushes have to survive the process dying, which is the whole point of the file
## existing (8.2).
func _save() -> void:
	_ensure_loaded()
	var payload := {
		"version": SCHEMA_VERSION,
		"account": _account,
		"cursor": _cursor,
		"sync_pictures": _sync_pictures,
		"books": _books,
	}
	var directory := _path.get_base_dir()
	if directory != "" and not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		push_warning("SyncQueue: could not write '%s' (%d)."
			% [_path, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()


## Forgets everything, file included. Dev harnesses and "delete my data".
func erase() -> void:
	_books.clear()
	_cursor = ""
	_account = ""
	_loaded = true
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(_path)


# ===================================================================== helpers ==

static func _result(ok: bool, code: String, reason: String) -> Dictionary:
	return {"ok": ok, "code": code, "reason": reason}


static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := int(file.get_length())
	file.close()
	return size

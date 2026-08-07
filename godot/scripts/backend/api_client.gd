class_name ApiClient
extends RefCounted
## The one place the game speaks HTTP (DLC_SERVER.md 8.1 item 4, 8.2, 11).
##
## A plain [RefCounted] wrapper around a throw-away [HTTPRequest] node, so the
## networking is testable without the [Backend] autoload and without a screen. It
## borrows a host [Node] (Backend passes itself) purely because [HTTPRequest] has
## to be in the tree to poll; it owns no game state, no credentials and no files.
##
## [b]Everything it returns is a plain Dictionary[/b] of the shape
## [code]{ok, status, data, code, message, headers}[/code] -- never an exception,
## never a crash, never a null. A caller branches on [code]code[/code], which is
## the server's stable machine-readable string (DLC_SERVER.md 11: "the client
## branches on code, never on prose") plus the transport-level codes this class
## adds ([constant CODE_OFFLINE], [constant CODE_TIMEOUT], [constant CODE_BAD_BODY]).
##
## [b]The non-negotiables from DLC_SERVER.md 8.2, implemented here:[/b]
## [codeblock]
## every request has a timeout      10 s for JSON, 120 s for a pack
## exponential backoff with jitter  capped at ~5 minutes, then give up quietly
## failures are silent to the child never a modal; a caller logs and moves on
## [/codeblock]
##
## [b]Retries are OPT IN and default to one attempt.[/b] No screen may await a
## request (8.2), so an interactive call -- sign in, list packs, start a download --
## fires once and reports whatever happened. The backoff schedule exists for
## background work (WP11's sync drain, the launch-time entitlement refresh), which
## nothing is waiting on.
##
## [b]Base URL.[/b] Injected by [Backend] from [BackendConfig]; this class never
## reads a setting or a file.

## Result keys.
const KEY_OK := "ok"
const KEY_STATUS := "status"
const KEY_DATA := "data"
const KEY_CODE := "code"
const KEY_MESSAGE := "message"
const KEY_HEADERS := "headers"
const KEY_BODY := "body"
## The [code]Location[/code] of a 3xx, when [code]follow_redirects[/code] was false.
## This is how the signed pack URL arrives (DLC_SERVER.md 7.4).
const KEY_LOCATION := "location"

## Transport-level [code]code[/code] values. UPPER_SNAKE like the server's own
## (DLC_SERVER.md 11), and in the same namespace, so a caller has exactly one thing
## to branch on and never has to ask "did this come from the wire or the socket".
const CODE_OFFLINE := "NETWORK_UNREACHABLE"
const CODE_TIMEOUT := "NETWORK_TIMEOUT"
const CODE_BAD_BODY := "BAD_RESPONSE_BODY"
const CODE_CANCELLED := "REQUEST_CANCELLED"
const CODE_REDIRECT := "REDIRECT"
## The server's own generic fallback (its STATUS_CODES table).
const CODE_HTTP := "HTTP_ERROR"
## Belt-and-braces: the API renders 422 through the same [code]{error:{}}[/code]
## envelope as everything else, so this is only reached if a proxy or a future
## route ever answers with Laravel's default [code]{message, errors}[/code] shape.
const CODE_VALIDATION := "VALIDATION_FAILED"

## Server codes this client actually branches on (DLC_SERVER.md 9, 11).
const CODE_UNAUTHENTICATED := "UNAUTHENTICATED"
const CODE_INVALID_CREDENTIALS := "INVALID_CREDENTIALS"
const CODE_ENTITLEMENT_REQUIRED := "ENTITLEMENT_REQUIRED"
const CODE_NOT_FOUND := "NOT_FOUND"
const CODE_PACK_VERSION_NOT_FOUND := "PACK_VERSION_NOT_FOUND"
const CODE_DOWNLOAD_LINK_EXPIRED := "DOWNLOAD_LINK_EXPIRED"
const CODE_THROTTLED := "THROTTLED"

## Seconds a JSON request may take (DLC_SERVER.md 8.2).
const TIMEOUT_JSON := 10.0
## Seconds a pack download may take. A 12-page pack is ~8 MB (DLC_SERVER.md 2).
const TIMEOUT_PACK := 120.0

## Backoff: 1 s, 2 s, 4 s ... jittered to 50-100 % of that, capped at ~5 minutes,
## after which the caller gives up until the next app launch (DLC_SERVER.md 8.2).
const BACKOFF_BASE_SECONDS := 1.0
const BACKOFF_CAP_SECONDS := 300.0

## Sent so the server can apply [code]min_client_version[/code] and so a log line
## identifies the build.
const USER_AGENT_PREFIX := "ColoringBook"

var _host: Node
var _base_url := ""
## Bearer token, injected by [Backend] from [AuthStore]. "" means "send no
## Authorization header", which is also what an EXPIRED token becomes.
var _token := ""
var _client_version := ""


func _init(host: Node, base_url: String, client_version: String = "") -> void:
	_host = host
	set_base_url(base_url)
	_client_version = client_version if client_version != "" \
		else String(ProjectSettings.get_setting("application/config/version", "0.0.0"))


func set_base_url(base_url: String) -> void:
	_base_url = base_url.rstrip("/")


func get_base_url() -> String:
	return _base_url


func set_token(token: String) -> void:
	_token = token


func get_client_version() -> String:
	return _client_version


# ==================================================================== requests ==

## Fires one JSON request and returns the result dictionary. [param body] is
## encoded as JSON when it is a Dictionary/Array and omitted when null.
##
## [param options] (all optional):
## [codeblock]
## auth: bool          send the bearer header (default: true when a token is set)
## timeout: float      seconds (default TIMEOUT_JSON)
## attempts: int       total tries, backing off between them (default 1)
## follow_redirects: bool  default true; false to READ a 302's Location yourself
## query: Dictionary   appended as a query string, values url-encoded
## [/codeblock]
func request_json(method: int, path: String, body: Variant = null,
		options: Dictionary = {}) -> Dictionary:
	var attempts := maxi(1, int(options.get("attempts", 1)))
	var result := {}
	for attempt in attempts:
		result = await _request_once(method, path, body, options, "")
		if bool(result[KEY_OK]) or not _is_retryable(result):
			return result
		if attempt < attempts - 1:
			await _sleep(backoff_delay(attempt))
	return result


## Fires one request whose BODY IS RAW BYTES rather than JSON, and reads the answer
## exactly as [method request_json] does.
##
## This is the paint upload (DLC_SERVER.md 11: "PUT /sync/paint/{book_uid}/{page},
## raw PNG body, Content-Digest checked"). It is a separate entry point because
## [method HTTPRequest.request] takes a [String] and would mangle a PNG on the way
## through UTF-8; [method HTTPRequest.request_raw] is the only binary-safe form.
##
## [param headers] is applied VERBATIM -- for paint they are the ones the server's
## own [code]202[/code] handed back, including the RFC 9530 [code]Content-Digest[/code],
## and inventing them locally is exactly the mistake the negotiation exists to
## prevent. No [code]Content-Type: application/json[/code] is added.
func request_bytes(method: int, path: String, body: PackedByteArray,
		options: Dictionary = {}) -> Dictionary:
	var attempts := maxi(1, int(options.get("attempts", 1)))
	var result := {}
	for attempt in attempts:
		result = await _request_once(method, path, body, options, "")
		if bool(result[KEY_OK]) or not _is_retryable(result):
			return result
		if attempt < attempts - 1:
			await _sleep(backoff_delay(attempt))
	return result


## Downloads [param url] straight to [param destination] -- the bytes never sit in
## RAM (DLC_SERVER.md 7.4). [param url] may be absolute (a signed download URL) or
## a path on the API base.
##
## [param on_progress] is called with (downloaded_bytes, total_bytes) roughly every
## frame; total is -1 until the server sends a Content-Length. It is a plain
## Callable rather than a signal because the caller is a coroutine, not a listener.
func download(url: String, destination: String, options: Dictionary = {},
		on_progress: Callable = Callable()) -> Dictionary:
	var directory := destination.get_base_dir()
	if directory != "" and not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var opts := options.duplicate()
	opts["timeout"] = float(opts.get("timeout", TIMEOUT_PACK))
	opts["on_progress"] = on_progress
	return await _request_once(HTTPClient.METHOD_GET, url, null, opts, destination)


## Seconds to wait before retry number [param attempt] (0-based): exponential,
## jittered to 50-100 %, capped at [constant BACKOFF_CAP_SECONDS]. Static and pure
## so the smoke can assert the schedule without making a request.
static func backoff_delay(attempt: int) -> float:
	var base := minf(BACKOFF_BASE_SECONDS * pow(2.0, float(maxi(0, attempt))), BACKOFF_CAP_SECONDS)
	return base * randf_range(0.5, 1.0)


## True for the failures that are worth trying again: nothing reached the server,
## or the server said "later". A 4xx is the client's fault and retrying it is just
## rate-limit fuel -- except 429, which is exactly "later".
static func _is_retryable(result: Dictionary) -> bool:
	var code := String(result.get(KEY_CODE, ""))
	if code in [CODE_OFFLINE, CODE_TIMEOUT]:
		return true
	var status := int(result.get(KEY_STATUS, 0))
	return status == 429 or status >= 500


# ===================================================================== plumbing ==

func _request_once(method: int, path: String, body: Variant, options: Dictionary,
		destination: String) -> Dictionary:
	if _host == null or not _host.is_inside_tree():
		return _failure(CODE_OFFLINE, "ApiClient has no host node in the tree.")
	var url := _resolve_url(path, options.get("query", {}))
	if url == "":
		return _failure(CODE_OFFLINE, "No backend base URL is configured.")

	var http := HTTPRequest.new()
	http.name = "ApiRequest"
	http.timeout = float(options.get("timeout", TIMEOUT_JSON))
	http.use_threads = false
	http.accept_gzip = destination == ""
	if not bool(options.get("follow_redirects", true)):
		http.max_redirects = 0
	if destination != "":
		http.download_file = destination
	_host.add_child(http)

	var headers := _headers(body, options)
	var error := OK
	if body == null:
		error = http.request(url, headers, method)
	elif typeof(body) == TYPE_PACKED_BYTE_ARRAY:
		# Binary-safe: request() would round-trip a PNG through a String.
		error = http.request_raw(url, headers, method, body as PackedByteArray)
	else:
		error = http.request(url, headers, method, JSON.stringify(body))
	if error != OK:
		_dispose(http)
		return _failure(CODE_OFFLINE, "HTTPRequest.request() refused the call (%d)." % error)

	var on_progress: Callable = options.get("on_progress", Callable())
	var completed: Array = []
	http.request_completed.connect(func(r: int, code: int, h: PackedStringArray, b: PackedByteArray) -> void:
		completed.append([r, code, h, b])
	)
	while completed.is_empty():
		if on_progress.is_valid():
			on_progress.call(http.get_downloaded_bytes(), http.get_body_size())
		await _host.get_tree().process_frame
		if not is_instance_valid(http):
			return _failure(CODE_CANCELLED, "The request was cancelled.")
	_dispose(http)

	var result := _interpret(int(completed[0][0]), int(completed[0][1]),
		completed[0][2] as PackedStringArray, completed[0][3] as PackedByteArray,
		destination != "")
	if on_progress.is_valid() and bool(result[KEY_OK]):
		var size := _content_length(result[KEY_HEADERS])
		on_progress.call(size, size)
	return result


func _dispose(http: HTTPRequest) -> void:
	if not is_instance_valid(http):
		return
	if http.get_parent() != null:
		http.get_parent().remove_child(http)
	http.queue_free()


func _resolve_url(path: String, query: Variant) -> String:
	var url := path
	if not (path.begins_with("http://") or path.begins_with("https://")):
		if _base_url == "":
			return ""
		url = _base_url + ("" if path.begins_with("/") else "/") + path
	if typeof(query) == TYPE_DICTIONARY and not (query as Dictionary).is_empty():
		var parts := PackedStringArray()
		for key: Variant in (query as Dictionary):
			parts.append("%s=%s" % [
				String(key).uri_encode(), String((query as Dictionary)[key]).uri_encode()
			])
		url += ("&" if "?" in url else "?") + "&".join(parts)
	return url


func _headers(body: Variant, options: Dictionary) -> PackedStringArray:
	var headers := PackedStringArray([
		"Accept: application/json",
		"User-Agent: %s/%s (%s)" % [USER_AGENT_PREFIX, _client_version, OS.get_name()],
	])
	# A raw-byte body brings its own Content-Type (paint uploads take the server's
	# 202 instructions verbatim), so only a JSON body gets one invented for it.
	if body != null and typeof(body) != TYPE_PACKED_BYTE_ARRAY:
		headers.append("Content-Type: application/json")
	# A signed download URL carries its own authorisation in the query string and
	# must NOT get a bearer header (DLC_SERVER.md 7.4).
	if bool(options.get("auth", true)) and _token != "":
		headers.append("Authorization: Bearer %s" % _token)
	for extra: Variant in options.get("headers", []):
		headers.append(String(extra))
	return headers


func _interpret(request_result: int, status: int, headers: PackedStringArray,
		body: PackedByteArray, is_download: bool) -> Dictionary:
	var location := header_value(headers, "location")
	# [b]A deliberate 3xx is not a transport failure.[/b] With max_redirects = 0 --
	# which is how the signed pack URL is read rather than blindly followed, so the
	# bearer header is never forwarded to it (DLC_SERVER.md 7.4) -- Godot reports
	# RESULT_REDIRECT_LIMIT_REACHED. That is the SUCCESS case for this client, and
	# it has to be recognised before the generic failure branch or the Location is
	# thrown away.
	var deliberate_redirect := request_result == HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED \
		and status >= 300 and status < 400
	if request_result != HTTPRequest.RESULT_SUCCESS and not deliberate_redirect:
		var code := CODE_TIMEOUT if request_result == HTTPRequest.RESULT_TIMEOUT else CODE_OFFLINE
		var failure := _failure(code, "HTTPRequest result %d." % request_result, status, headers)
		failure[KEY_LOCATION] = location
		return failure

	var text := "" if is_download else body.get_string_from_utf8()
	var data: Variant = null
	if text.strip_edges() != "":
		data = JSON.parse_string(text)

	if status >= 200 and status < 300:
		return {
			KEY_OK: true, KEY_STATUS: status, KEY_DATA: data, KEY_CODE: "",
			KEY_MESSAGE: "", KEY_HEADERS: headers, KEY_BODY: text, KEY_LOCATION: location,
		}
	if status >= 300 and status < 400:
		return {
			KEY_OK: false, KEY_STATUS: status, KEY_DATA: data,
			KEY_CODE: CODE_REDIRECT, KEY_MESSAGE: location,
			KEY_HEADERS: headers, KEY_BODY: text, KEY_LOCATION: location,
		}

	var code := CODE_HTTP
	var message := "HTTP %d" % status
	if typeof(data) == TYPE_DICTIONARY:
		var dict := data as Dictionary
		var envelope: Variant = dict.get("error", null)
		if typeof(envelope) == TYPE_DICTIONARY:
			code = String((envelope as Dictionary).get("code", CODE_HTTP))
			message = String((envelope as Dictionary).get("message", message))
			# A 422 carries the field errors in `details`; show the first one,
			# because "The given data was invalid." helps nobody type a password.
			var details: Variant = (envelope as Dictionary).get("details", null)
			if typeof(details) == TYPE_DICTIONARY:
				var first_field := _first_detail(details as Dictionary)
				if first_field != "":
					message = first_field
		elif dict.has("errors"):
			# Laravel's own validation envelope.
			code = CODE_VALIDATION
			message = String(dict.get("message", message))
			var errors: Variant = dict.get("errors", {})
			if typeof(errors) == TYPE_DICTIONARY:
				for field: Variant in (errors as Dictionary):
					var first: Variant = (errors as Dictionary)[field]
					if typeof(first) == TYPE_ARRAY and not (first as Array).is_empty():
						message = String((first as Array)[0])
						break
		elif dict.has("message"):
			message = String(dict.get("message", message))
	elif text.strip_edges() != "" and not is_download:
		code = CODE_BAD_BODY
	return {
		KEY_OK: false, KEY_STATUS: status, KEY_DATA: data, KEY_CODE: code,
		KEY_MESSAGE: message, KEY_HEADERS: headers, KEY_BODY: text, KEY_LOCATION: location,
	}


static func _failure(code: String, message: String, status: int = 0,
		headers: PackedStringArray = PackedStringArray()) -> Dictionary:
	return {
		KEY_OK: false, KEY_STATUS: status, KEY_DATA: null, KEY_CODE: code,
		KEY_MESSAGE: message, KEY_HEADERS: headers, KEY_BODY: "", KEY_LOCATION: "",
	}


## The first field message out of a 422's [code]details[/code] map, or "".
static func _first_detail(details: Dictionary) -> String:
	for field: Variant in details:
		var messages: Variant = details[field]
		if typeof(messages) == TYPE_ARRAY and not (messages as Array).is_empty():
			return String((messages as Array)[0])
		if typeof(messages) == TYPE_STRING:
			return String(messages)
	return ""


## Case-insensitive lookup in a raw header array ("Name: value" strings).
static func header_value(headers: Variant, name: String) -> String:
	var wanted := name.to_lower() + ":"
	for header: Variant in (headers if headers != null else []):
		var line := String(header)
		if line.to_lower().begins_with(wanted):
			return line.substr(wanted.length()).strip_edges()
	return ""


static func _content_length(headers: Variant) -> int:
	var value := header_value(headers, "content-length")
	return int(value) if value != "" else -1


func _sleep(seconds: float) -> void:
	if _host == null or not _host.is_inside_tree():
		return
	await _host.get_tree().create_timer(seconds).timeout

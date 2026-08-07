class_name BackendConfig
extends RefCounted
## Where the API lives, and whether the client is allowed to talk to it at all.
##
## [b]Two layers, and the reason for each.[/b]
##
## 1. [b]A project setting[/b], [constant BASE_URL_SETTING], declared in
##    project.godot. A server address is a BUILD fact, not player data: it differs
##    per export (dev box, staging mini-pc, production), it must be identical for
##    every player of a given build, and godot-practices puts authored,
##    non-progress configuration in the project rather than in
##    [code]user://[/code]. Being a real project setting also means it shows up in
##    the editor's Project Settings and can be overridden per export preset with
##    [code]--set[/code] or a feature-tagged override, which a hardcoded constant
##    could not.
## 2. [b]An optional [constant OVERRIDE_PATH] file[/b], read only when it exists.
##    This is the DEV escape hatch: pointing an already-built binary at a different
##    server (a laptop, a colleague's box, the smoke's port) without re-exporting.
##    It is deliberately not written by any UI -- nothing in the game creates this
##    file, so a shipped build behaves exactly as its project setting says unless
##    somebody deliberately drops a file next to the save.
##
## [b]Web export (DLC_SERVER.md 7.4).[/b] On web, [code]user://[/code] is IndexedDB
## and every request is subject to the browser's same-origin policy: a cross-origin
## API needs CORS on every route AND on the signed download URL. The intended
## topology is therefore to serve the API from a PATH on the game's own vhost
## ([code]https://<game-host>/api[/code]) rather than a second port, at which point
## the base URL for a web build is the relative-to-origin
## [code]/api[/code] -- which is what [method for_web_origin] produces.
##
## So a web build [b]does not use the project setting's dev default[/b]:
## [constant DEFAULT_BASE_URL] is a loopback address, and in a browser tab
## [code]127.0.0.1[/code] is the PLAYER's machine, not the server -- pointing a web
## export at it is never right, merely silently broken. [method get_base_url]
## therefore resolves the page's own origin ([method get_page_origin]) and appends
## [constant WEB_ORIGIN_PATH]. Two escape hatches survive that, in this order:
## [constant OVERRIDE_PATH] still wins outright, and an export whose
## [constant BASE_URL_SETTING] has deliberately been pointed somewhere other than
## the dev default is taken at its word (that is what a feature-tagged override is
## for). The origin substitution only ever replaces the default nobody chose.
##
## [b]Plain [RefCounted] with static methods[/b]: no nodes, no state, trivially
## testable -- and the web branch above is [method resolve_base_url], which takes
## its inputs as arguments precisely so a DESKTOP smoke run can prove it.

## Project setting holding the API root, INCLUDING the version prefix.
const BASE_URL_SETTING := "coloringbook/backend/base_url"
## Project setting: false turns the whole Backend into a no-op regardless of URL.
const ENABLED_SETTING := "coloringbook/backend/enabled"
## Dev-only override file. Backend's, not [code]GameState[/code]'s -- but note that
## it is NOT created by the game and its absence is the normal case.
const OVERRIDE_PATH := "user://backend.json"

## The dev default: the Laravel app from `php artisan serve --port=8123`, on the
## loopback of the machine running the editor. Never correct for a shipped build --
## an export sets [constant BASE_URL_SETTING].
const DEFAULT_BASE_URL := "http://127.0.0.1:8123/api/v1"

## Path appended to a same-origin web deployment (see the class doc).
const WEB_ORIGIN_PATH := "/api/v1"


## The API root this run should use. Override file first, then the project setting,
## then -- on web only -- the page's own origin. Always returned without a trailing
## slash. All three inputs are gathered here and decided in [method resolve_base_url].
static func get_base_url() -> String:
	return resolve_base_url(
		String(_read_override().get("base_url", "")),
		String(ProjectSettings.get_setting(BASE_URL_SETTING, DEFAULT_BASE_URL)),
		OS.has_feature("web"),
		get_page_origin(),
	)


## The decision behind [method get_base_url], with every input passed in: no
## [ProjectSettings], no [FileAccess], no [JavaScriptBridge]. That is what lets a
## DESKTOP smoke run prove the web branch, which is otherwise only observable by
## loading the export in a browser.
##
## [param override] is [constant OVERRIDE_PATH]'s [code]base_url[/code] ("" when the
## file is absent, which is the normal case); [param setting] is
## [constant BASE_URL_SETTING]; [param is_web] is [code]OS.has_feature("web")[/code];
## [param page_origin] is the browser's [code]location.origin[/code] ("" anywhere
## else). See the class doc for why web ignores the dev default but honours an
## export that was deliberately pointed elsewhere.
static func resolve_base_url(override: String, setting: String, is_web: bool,
		page_origin: String) -> String:
	var chosen := override.strip_edges().rstrip("/")
	if chosen != "":
		return chosen
	chosen = setting.strip_edges().rstrip("/")
	if not is_web:
		return chosen
	if chosen != "" and chosen != DEFAULT_BASE_URL:
		return chosen
	var origin := page_origin.strip_edges()
	if origin == "":
		# Nothing readable to be same-origin WITH. The bare path is still the right
		# answer -- it is what a browser resolves against the document anyway -- and
		# it is emphatically better than a loopback that would reach the child's own
		# machine.
		return WEB_ORIGIN_PATH
	return for_web_origin(origin)


## The browser's [code]location.origin[/code], or "" on every other platform (and on
## a page that has none -- a [code]file://[/code] document reports the literal
## "null"). Scheme-checked rather than trusted, so a malformed value degrades to the
## relative fallback instead of being pasted into a URL.
static func get_page_origin() -> String:
	if not OS.has_feature("web"):
		return ""
	var raw: Variant = JavaScriptBridge.eval("window.location.origin", true)
	if typeof(raw) != TYPE_STRING:
		return ""
	var origin := String(raw).strip_edges()
	if not (origin.begins_with("http://") or origin.begins_with("https://")):
		return ""
	return origin


## False turns every [Backend] method into a no-op even when a token is present.
## Exists so an export preset (a store build without a server yet, a kiosk build)
## can ship the networking code inert rather than stripped.
static func is_enabled() -> bool:
	var override := _read_override()
	if override.has("enabled"):
		return bool(override["enabled"])
	return bool(ProjectSettings.get_setting(ENABLED_SETTING, true))


## The base URL a same-origin web build should use, given the page's own origin.
## Kept here rather than in [ApiClient] so the one place that knows about 7.4's
## same-origin rule is the one place that knows about URLs.
static func for_web_origin(origin: String) -> String:
	return origin.rstrip("/") + WEB_ORIGIN_PATH


## The client version string sent as [code]?client_version=[/code] and in the
## User-Agent. The project's own version -- the same value the settings panel
## shows -- so [code]min_client_version[/code] filtering is honest.
static func get_client_version() -> String:
	return String(ProjectSettings.get_setting("application/config/version", "0.0.0"))


## Compares two dotted numeric versions the way the server's
## [code]version_compare[/code] does. Returns -1 / 0 / 1. Missing components count
## as 0, so "0.6" and "0.6.0" are equal.
static func compare_versions(left: String, right: String) -> int:
	var a := left.strip_edges().split(".")
	var b := right.strip_edges().split(".")
	for i in maxi(a.size(), b.size()):
		var x := int(a[i]) if i < a.size() else 0
		var y := int(b[i]) if i < b.size() else 0
		if x != y:
			return -1 if x < y else 1
	return 0


## True when this build satisfies a pack's [code]min_client_version[/code].
## [b]Equal counts as satisfied[/b] (the coyote pack ships min 0.6.0 against a
## 0.6.0 build), and an empty/absent requirement means "any build".
static func satisfies_min_version(min_client_version: String, client_version: String = "") -> bool:
	var required := min_client_version.strip_edges()
	if required == "":
		return true
	var mine := client_version if client_version != "" else get_client_version()
	return compare_versions(mine, required) >= 0


static func _read_override() -> Dictionary:
	if not FileAccess.file_exists(OVERRIDE_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(OVERRIDE_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("BackendConfig: '%s' is not a JSON object; ignoring it." % OVERRIDE_PATH)
		return {}
	return parsed as Dictionary

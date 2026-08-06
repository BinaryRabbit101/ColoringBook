extends Node
## The project's ONE autoload (DESIGN.md 3.4): global state that genuinely has no
## owning scene. Registered as [code]GameState[/code] in project.godot.
##
## M3 scope: the difficulty [member mode] and the [PaletteDef] it selects.
## Current book / page and save-load of progress arrive in M4 / M5 -- this script
## is deliberately structured so they slot in as more named vars + methods here,
## with no rework: all state is plain instance vars (no statics, no hidden
## globals), every mutation goes through a setter that emits a past-tense signal,
## and resource lookup is table-driven.
##
## Screens read [method get_active_palette] and hand the result DOWN to the
## palette component and the coloring screen; nothing reaches back up into here
## from inside a component's subtree.

## Emitted after [member mode] actually changes. Payload is the new mode id.
signal mode_changed(mode: String)

const MODE_CHILD := PaletteDef.MODE_CHILD
const MODE_ADULT := PaletteDef.MODE_ADULT

## mode id -> palette resource. The single place a palette path is written down.
const PALETTE_PATHS := {
	MODE_CHILD: "res://resources/palettes/child_palette.tres",
	MODE_ADULT: "res://resources/palettes/adult_palette.tres",
}

## Current difficulty mode, "child" or "adult" (DESIGN.md 1). Assigning an
## unknown id is refused with an error and leaves the mode untouched; assigning
## the current id is a no-op and emits nothing.
var mode: String = MODE_CHILD:
	set(value):
		var normalized := value.strip_edges().to_lower()
		if not PALETTE_PATHS.has(normalized):
			push_error("GameState: unknown mode '%s'; keeping '%s'." % [value, mode])
			return
		if normalized == mode:
			return
		mode = normalized
		mode_changed.emit(mode)

## mode id -> loaded PaletteDef. Palettes are immutable authored data, so one
## instance per mode is shared by everything that asks.
var _palette_cache: Dictionary = {}


# ======================================================================= mode ==

## Method form of assigning [member mode], for signal connections and UI callbacks.
func set_mode(new_mode: String) -> void:
	mode = new_mode


func is_child_mode() -> bool:
	return mode == MODE_CHILD


## Every mode id the game knows, in presentation order.
func get_available_modes() -> PackedStringArray:
	return PackedStringArray([MODE_CHILD, MODE_ADULT])


# =================================================================== palettes ==

## The [PaletteDef] for the current [member mode]. Null only if the .tres is
## missing or does not parse as a PaletteDef (an error is pushed either way).
func get_active_palette() -> PaletteDef:
	return get_palette_for_mode(mode)


## The [PaletteDef] for any mode id. Loaded once, then cached.
func get_palette_for_mode(mode_id: String) -> PaletteDef:
	if _palette_cache.has(mode_id):
		return _palette_cache[mode_id]
	if not PALETTE_PATHS.has(mode_id):
		push_error("GameState: no palette registered for mode '%s'." % mode_id)
		return null
	var path: String = PALETTE_PATHS[mode_id]
	var palette := load(path) as PaletteDef
	if palette == null:
		push_error("GameState: '%s' did not load as a PaletteDef." % path)
		return null
	if palette.mode != mode_id:
		push_warning(
			"GameState: '%s' declares mode '%s' but is registered under '%s'."
			% [path, palette.mode, mode_id]
		)
	_palette_cache[mode_id] = palette
	return palette


## The scene path of the palette component for a mode. The coloring screen
## instantiates this blindly -- both components share one contract
## (color_picked / brush_size_picked / set_palette).
func get_palette_scene_path(mode_id: String = "") -> String:
	var resolved := mode_id if mode_id != "" else mode
	return (
		"res://scenes/components/palette_child.tscn"
		if resolved == MODE_CHILD
		else "res://scenes/components/palette_adult.tscn"
	)


## Drops cached palettes so an edited .tres is picked up. Dev/tests only.
func reload_palettes() -> void:
	_palette_cache.clear()

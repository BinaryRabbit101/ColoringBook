class_name SparkleBurst
extends Control
## A handful of little four-point stars that drift up and fade out (BL-29).
##
## The garnish on a toolbar action: the page saved, a stroke came back. Drawn from
## primitives like everything else in this game -- the shell ships no art -- and
## short enough (about three quarters of a second) that it never becomes something
## the player has to wait through.
##
## [b]It cannot get in the way.[/b] [constant Control.MOUSE_FILTER_IGNORE], zero
## size, no [method Control._input], and it frees itself the frame its last star
## fades. Nothing in the game holds a reference to one or waits for one.
##
## [b]Host it on a plain [Control][/b], never on a container: a [BoxContainer]
## lays out every [Control] child it has, and a burst parented into the toolbar row
## would be handed a slot between two buttons. The coloring page keeps an
## [code]Effects[/code] overlay for exactly this.
##
## Usage: [code]SparkleBurst.burst(effects_layer, local_point, colors)[/code].
##
## [b]Every reference to this class goes through a preload[/b], including the one
## inside [method burst] and the ones in [code]coloring_page.gd[/code]. A newly
## added [code]class_name[/code] is invisible to a CLI run until the project is
## re-imported, and an effect nobody is waiting for must never be the thing that
## takes the coloring screen down with it.
const SELF := preload("res://scripts/components/sparkle_burst.gd")

const DEFAULT_COUNT := 9
const DEFAULT_SECONDS := 0.72
## How far the swarm travels, in pixels: up, and sideways from the centre.
const DEFAULT_RISE := 58.0
const DEFAULT_SPREAD := 44.0
## Star sizes, in pixels (outer radius).
const SIZE_MIN := 4.0
const SIZE_MAX := 9.0
## A gentle sag so the stars arc instead of shooting off in straight lines.
const GRAVITY := 26.0
## Fallback palette: warm crayon-box highlights. A typed [Array] rather than a
## [PackedColorArray] because only the former can be a [code]const[/code].
const DEFAULT_COLORS: Array[Color] = [
	Color(1.0, 0.905882, 0.556863),
	Color(1.0, 0.984314, 0.917647),
	Color(0.972549, 0.803922, 0.478431),
]

var _stars: Array[Dictionary] = []
var _time := 0.0
var _seconds := DEFAULT_SECONDS


## Spawns a burst at [param at] (in [param host]'s local coordinates) and returns
## it. The node owns its own lifetime; the caller may ignore the return value.
static func burst(
	host: Control,
	at: Vector2,
	colors: Array[Color] = DEFAULT_COLORS,
	count: int = DEFAULT_COUNT,
	rise: float = DEFAULT_RISE,
	spread: float = DEFAULT_SPREAD,
	seconds: float = DEFAULT_SECONDS
) -> Control:
	if host == null or not is_instance_valid(host) or not host.is_inside_tree():
		return null
	var node := SELF.new()
	node.position = at
	node._seconds = maxf(seconds, 0.05)
	node._make_stars(colors, maxi(count, 1), rise, spread)
	host.add_child(node)
	return node


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2.ZERO
	size = Vector2.ZERO
	# Depth is TREE ORDER, deliberately: the effects overlay sits above the toolbar
	# and below the page flip, so a burst is over the button that threw it and under
	# the transition that owns the screen. A z_index here would out-rank the flip.
	set_process(true)


func _make_stars(colors: Array[Color], count: int, rise: float, spread: float) -> void:
	var palette: Array[Color] = colors if colors.size() > 0 else DEFAULT_COLORS
	for i in count:
		# Fan the stars over the upper half-circle so the swarm reads as "up",
		# with a little randomness so no two bursts look stamped from a mould.
		var angle := lerpf(-PI * 0.85, -PI * 0.15, float(i) / float(maxi(count - 1, 1)))
		angle += randf_range(-0.18, 0.18)
		var reach := randf_range(0.55, 1.0)
		_stars.append({
			"velocity": Vector2(cos(angle) * spread, sin(angle) * rise) * reach,
			"origin": Vector2(randf_range(-6.0, 6.0), randf_range(-4.0, 4.0)),
			"size": randf_range(SIZE_MIN, SIZE_MAX),
			"spin": randf_range(-3.4, 3.4),
			"phase": randf_range(0.0, TAU),
			"delay": randf_range(0.0, _seconds * 0.28),
			"color": palette[randi() % palette.size()],
		})


func _process(delta: float) -> void:
	_time += delta
	if _time >= _seconds:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	for star in _stars:
		var life := _seconds - float(star["delay"])
		var t := (_time - float(star["delay"])) / maxf(life, 0.001)
		if t <= 0.0 or t >= 1.0:
			continue
		# Out fast, drifting slow: the eye catches the launch, not the coast.
		var travel := 1.0 - pow(1.0 - t, 2.4)
		var center: Vector2 = star["origin"] + (star["velocity"] as Vector2) * travel
		center.y += GRAVITY * t * t
		# Pop to full size in the first fifth, then shrink away with the alpha.
		var grow := minf(t / 0.2, 1.0)
		var fade := 1.0 - t * t
		var radius := float(star["size"]) * grow * (0.45 + 0.55 * fade)
		var tint: Color = star["color"]
		tint.a = clampf(fade, 0.0, 1.0)
		var spin := float(star["phase"]) + float(star["spin"]) * t
		draw_colored_polygon(_star_points(center, radius, radius * 0.34, spin), tint)


## A four-point sparkle: outer points on the axes, inner waist between them.
static func _star_points(
	center: Vector2, outer: float, inner: float, spin: float
) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in 8:
		var angle := spin + float(i) * PI * 0.25
		var radius := outer if i % 2 == 0 else inner
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return points

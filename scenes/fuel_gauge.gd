extends TextureProgressBar
##
## Fuel gauge. Driven by the ship's `fuel_changed` signal rather than polled
## every frame — fuel only changes when material is actually removed, so there
## is nothing to read on the frames in between.
##
## Expected layout:
##     World
##     └── HUD          CanvasLayer
##         ├── SteerReady   TextureProgressBar
##         └── FuelGauge    TextureProgressBar   <- this script
##

@export var ship_path: NodePath = ^"../../DrillShip"

## Below this fraction the bar shifts toward the warning colour.
@export var low_fuel_fraction: float = 0.25
@export var normal_tint := Color(1, 1, 1)
@export var low_tint := Color(1.0, 0.45, 0.30)
@export var empty_flash_speed: float = 4.0

@onready var _ship: Node = get_node_or_null(ship_path)

var _empty: bool = false
var _flash: float = 0.0


func _ready() -> void:
	min_value = 0.0
	max_value = 100.0

	if _ship == null:
		push_warning("fuel_gauge: ship_path did not resolve")
		return

	# Connecting in code rather than in the editor keeps the wiring next to the
	# thing that depends on it. The editor route is identical in effect: select
	# DrillShip, Node dock -> Signals tab, double-click fuel_changed.
	_ship.fuel_changed.connect(_on_fuel_changed)
	_ship.fuel_empty.connect(_on_fuel_empty)

	# Deferred, NOT called directly. _ready() order between siblings isn't
	# something to rely on: if this node is ready before DrillShip, the ship
	# hasn't run `fuel = max_fuel` yet and we'd latch onto 0 — and its startup
	# fuel_changed would have fired before anything was listening.
	# call_deferred runs after every _ready() in the tree has completed.
	call_deferred("_sync_from_ship")


func _sync_from_ship() -> void:
	if _ship != null:
		_on_fuel_changed(_ship.fuel, _ship.max_fuel)


func _on_fuel_changed(current: float, maximum: float) -> void:
	var frac := current / maxf(maximum, 0.001)
	value = frac * 100.0
	_empty = current <= 0.0
	if not _empty:
		tint_progress = low_tint if frac <= low_fuel_fraction else normal_tint


func _on_fuel_empty() -> void:
	_empty = true


func _process(delta: float) -> void:
	# Pulse the housing when dry, so an empty bar reads as a problem rather
	# than as a bar that happens to be at zero.
	if not _empty:
		modulate = Color(1, 1, 1)
		return
	_flash += delta * empty_flash_speed
	var pulse := 0.6 + 0.4 * sin(_flash)
	modulate = Color(1.0, pulse, pulse)

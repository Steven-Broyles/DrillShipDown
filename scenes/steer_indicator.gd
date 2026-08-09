extends TextureProgressBar
##
## Steering-readiness indicator.
##
## Fills as the drill approaches being able to change angle again. Because the
## forward lock releases on DISTANCE bored (not a timer), this bar stalls when
## the ship stops and races when it's cutting fast — which teaches the actual
## rule without a tutorial line: bore forward to earn your next turn.
##
## Expected layout:
##     World
##     └── HUD          CanvasLayer        <- immune to the Camera2D transform
##         └── SteerReady  TextureProgressBar  <- this script
##

@export var ship_path: NodePath = ^"../../DrillShip"

## Show the bar during the mid-turn STEERING phase too. Off by default: the
## visibly tilted bit on the ship already communicates that phase, and an
## indicator that animates nearly constantly reads as noise.
@export var show_while_steering: bool = false

@export var fade_speed: float = 6.0
@export var ready_linger: float = 0.35   # stay visible briefly after filling

@onready var _ship: Node = get_node_or_null(ship_path)

var _linger: float = 0.0


func _ready() -> void:
	min_value = 0.0
	max_value = 100.0
	modulate.a = 0.0
	if _ship == null:
		push_warning("steer_indicator: ship_path did not resolve — bar will stay hidden")


func _process(delta: float) -> void:
	if _ship == null:
		return

	var charging: bool = _ship.is_recentering() \
			or (show_while_steering and _ship.is_steering())

	if charging:
		# Only read progress while this bar's own condition is the live one.
		value = _ship.steer_progress() * 100.0
		_linger = ready_linger
	else:
		# Not charging means steering is available, so the bar reads FULL. Do
		# not keep polling steer_progress() here: with the input held the ship
		# is already in STEERING, where that function reports turn completion
		# instead of bore distance, and the bar would race to full on a metric
		# this indicator isn't showing.
		value = 100.0
		_linger = maxf(_linger - delta, 0.0)

	# Fade out once steering is available again — no icon means "you can turn".
	var want := 1.0 if (charging or _linger > 0.0) else 0.0
	modulate.a = move_toward(modulate.a, want, fade_speed * delta)

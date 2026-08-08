extends CharacterBody2D

signal drilled(global_pos: Vector2, hardness: float, tier: int)

# --- movement ---
@export var drive_speed: float = 170.0
@export var bore_speed: float = 120.0
@export var bore_accel: float = 200.0
@export var coast_drag: float = 250.0
@export var gravity: float = 900.0
@export var max_fall_speed: float = 600.0
@export var climb_penalty: float = 0.45   # dig rate boring straight up
@export var descent_bonus: float = 1.25   # dig rate boring straight down

# --- drill aim ---
@export var tilt_step_deg: float = 15.0
@export var max_tilt_deg: float = 60.0
@export var tilt_repeat_delay: float = 0.50
@export var pivot_turn_speed: float = 12.0

# --- hull attitude ---
@export var hull_follow_speed: float = 6.0
@export var hull_level_speed: float = 4.0

# --- drilling ---
@export var drill_power: float = 1.0
@export var drill_tier: int = 1
@export var bore_radius: float = 14.0
@export var probe_depth: float = 2.0      # how far past the surface to sample
@export var debug_drill: bool = false

# --- heat (stub) ---
@export var heat: float = 0.0
@export var heat_soft_cap: float = 100.0

@onready var pivot: Node2D = $DrillPivot
@onready var ray: RayCast2D = $DrillPivot/RayCast2D

var tilt_index: int = 0
var _tilt_cd: float = 0.0
var _dig_progress: float = 0.0
var _is_boring: bool = false
var _facing: int = 1


func _ready() -> void:
	ray.add_exception(self)


func heading() -> Vector2:
	return Vector2.RIGHT.rotated(pivot.global_rotation)


func _physics_process(delta: float) -> void:
	_update_tilt(delta)
	_drill(delta)

	if _is_boring:
		# the bit has bitten rock — it pulls the ship in and holds it against gravity
		velocity = velocity.move_toward(heading() * bore_speed, bore_accel * delta)
	else:
		velocity.y += gravity * delta
		velocity.y = minf(velocity.y, max_fall_speed)
		var drive := Input.get_axis("move_left(drive)", "move_right(drive)")
		if drive != 0.0:
			velocity.x = move_toward(velocity.x, drive * drive_speed, bore_accel * delta)
		else:
			velocity.x = move_toward(velocity.x, 0.0, coast_drag * delta)

	move_and_slide()
	if absf(velocity.x) > 20.0:
		_facing = 1 if velocity.x > 0.0 else -1
	# after move_and_slide, velocity is the motion that actually resolved
	if _is_boring:
		rotation = lerp_angle(rotation, heading().angle(), hull_follow_speed * delta)
	else:
		rotation = lerp_angle(rotation, _level_target(), hull_level_speed * delta)


func _level_target() -> float:
	# nearest horizontal, so a leftward bore doesn't spin the hull 180°
	return 0.0 if _facing > 0 else PI


func _update_tilt(delta: float) -> void:
	var limit := int(max_tilt_deg / tilt_step_deg)
	_tilt_cd = maxf(_tilt_cd - delta, 0.0)
	if _tilt_cd == 0.0:
		var step := 0
		if Input.is_action_pressed("tilt_up"):
			step = -1
		elif Input.is_action_pressed("tilt_down"):
			step = 1
		if step != 0:
			tilt_index = clampi(tilt_index + step, -limit, limit)
			_tilt_cd = tilt_repeat_delay
	pivot.rotation = lerp_angle(pivot.rotation, tilt_index * deg_to_rad(tilt_step_deg), pivot_turn_speed * delta)


func _heat_factor() -> float:
	return clampf(1.0 - heat / heat_soft_cap, 0.15, 1.0)

func _gravity_factor() -> float:
	# heading().y is +1 straight down, -1 straight up
	return lerpf(climb_penalty, descent_bonus, (heading().y + 1.0) * 0.5)
#A wall should be built around whether a drill matches the rock that it is boring into
func _dig_rate(rock_tier: int) -> float:
	var base := drill_power * _heat_factor() * _gravity_factor()
	var deficit := rock_tier - drill_tier
	if deficit <= 0:
		return base
	return base * pow(0.25, deficit)


func _drill(delta: float) -> void:
	_is_boring = false

	if not Input.is_action_pressed("drill"):
		_dig_progress = 0.0
		return

	ray.force_raycast_update()
	if not ray.is_colliding():
		_dig_progress = 0.0
		return

	var terrain := ray.get_collider()
	if terrain == null or not terrain.has_method("sample"):
		_dig_progress = 0.0
		return

	# step just past the surface, into the material we hit
	var probe := ray.get_collision_point() - ray.get_collision_normal() * probe_depth
	var info: Dictionary = terrain.sample(probe)
	if info.is_empty():
		_dig_progress = 0.0
		return

	var hardness: float = info["hardness"]
	if hardness < 0.0:
		_dig_progress = 0.0          # gate rock: no bite, so no thrust either
		return

	var rock_tier: int = info["tier"]
	_is_boring = true

	if debug_drill:
		print("probe ", probe, "  hardness ", hardness, "  tier ", rock_tier)

	_dig_progress += _dig_rate(rock_tier) * delta
	if _dig_progress >= hardness:
		terrain.carve(probe, bore_radius)
		drilled.emit(probe, hardness, rock_tier)
		_dig_progress = 0.0

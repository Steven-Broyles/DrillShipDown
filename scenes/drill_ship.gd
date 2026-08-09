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
## Steering is a committed action, not a held aim. One input tilts the bit one
## step, locks it there while the ship carves the bend, then returns it to
## forward and locks it there while the hull straightens into the new tunnel.
## Holding the input through the hold window takes another step, up to the cap.
## Both intervals are upgrade hooks — a better steering rig shortens them.
@export var tilt_step_deg: float = 15.0
@export var max_tilt_deg: float = 60.0
## Steering ends when the HULL HAS ACTUALLY TURNED, and the forward lock ends
## after a DISTANCE bored — not after fixed durations. Time-based intervals give
## different tunnel geometry in soft rock than hard rock, because speed varies
## with hardness. These give the same bend and the same straight run everywhere;
## hard rock just takes longer in wall-clock time.
@export var steer_turn_fraction: float = 0.9   # exit once this much of the turn is done
@export var forward_lock_distance: float = 240.0 # px of straight bore before re-steering
## Safety caps, so a stalled ship can't lock up the drill forever.
@export var steer_hold: float = 4.0       # max seconds in STEERING
@export var forward_lock: float = 8.0     # max seconds in RECENTERING
@export var pivot_turn_speed: float = 12.0

# --- hull attitude ---
@export var hull_follow_speed: float = 6.0
@export var hull_level_speed: float = 4.0
@export var travel_smooth: float = 5.0    # how fast _travel_dir tracks real motion

# --- drilling ---
@export var drill_power: float = 1.0
@export var drill_tier: int = 1
@export var bore_radius: float = 14.0
@export var probe_depth: float = 2.0      # how far past the surface to sample
@export var bore_grace_time: float = 0.25 # keep "boring" this long after contact
@export var bore_axis_lock: float = 14.0  # how hard the hull tracks the bore axis
@export var carve_gain: float = 1.0       # multiplier on continuous rock removal
@export var debug_drill: bool = false

# --- heat (stub) ---
@export var heat: float = 0.0
@export var heat_soft_cap: float = 100.0

@onready var pivot: Node2D = $DrillPivot
@onready var ray: RayCast2D = $DrillPivot/RayCast2D

enum DrillState { CENTERED, STEERING, RECENTERING }

var tilt_index: int = 0
var _drill_state: DrillState = DrillState.CENTERED
var _state_t: float = 0.0
var _state_dist: float = 0.0
var _steer_start_rot: float = 0.0
var _steer_dir: int = 0
var _dig_progress: float = 0.0
var _is_boring: bool = false
var _facing: int = 1
var _travel_dir := Vector2.RIGHT
var _bore_grace: float = 0.0

# Temporary diagnostic. Prints unconditionally, four times a second, reporting
# exactly which branch of _drill was reached. Delete once the bore is behaving.
var _dbg: String = ""
var _dbg_t: float = 0.0


func _ready() -> void:
	ray.add_exception(self)
	# GROUNDED (the default) applies floor/wall/ceiling semantics relative to
	# up_direction: floor snapping, ceiling stops, and wall_min_slide_angle,
	# which HALTS sliding when a surface is too head-on. For a ship that
	# rotates freely and often has no gravity, all of that is wrong and shows
	# up as arbitrary snagging.
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING


func heading() -> Vector2:
	return Vector2.RIGHT.rotated(pivot.global_rotation)


func _physics_process(delta: float) -> void:
	_update_tilt(delta)
	_drill(delta)

	_dbg_t += delta
	if _dbg_t >= 0.25:
		_dbg_t = 0.0
		print(_dbg)

	if _is_boring:
		# the bit has bitten rock — it pulls the ship in and holds it against gravity
		var h := heading()
		velocity = velocity.move_toward(h * bore_speed, bore_accel * delta)
		# Kill drift perpendicular to the bore axis. Without this, every glancing
		# contact adds a sideways slide that accumulates, and the hull wanders
		# off the centreline of its own tunnel until a wall catches it.
		velocity = velocity.lerp(h * velocity.dot(h), clampf(bore_axis_lock * delta, 0.0, 1.0))
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

	# Remember the direction we are actually travelling. Only updated when
	# genuinely moving, so grinding stationary against rock doesn't scramble it.
	if velocity.length() > 8.0:
		_travel_dir = _travel_dir.slerp(velocity.normalized(), clampf(travel_smooth * delta, 0.0, 1.0))

	if _is_boring:
		# The hull conforms to the tunnel it is IN — the direction it has been
		# travelling — NOT to where the drill is pointing. Chasing heading()
		# is a feedback loop: heading is hull rotation plus drill offset, so
		# the hull would rotate forever while any tilt was held.
		#
		# Turn rate is also gated by speed. A drillship can't pirouette inside
		# its own borehole; it steers gradually while advancing. Stationary
		# means no rotation, which stops the hull swinging into uncut rock.
		var turn_allow := clampf(velocity.length() / maxf(bore_speed, 1.0), 0.0, 1.0)
		rotation = lerp_angle(rotation, _travel_dir.angle(), hull_follow_speed * turn_allow * delta)
	else:
		rotation = lerp_angle(rotation, _level_target(), hull_level_speed * delta)


## 0.0 → 1.0 readiness for the next steering input, for a HUD indicator.
## Returns 1.0 when steering is available. Because the lock releases on EITHER
## distance or the time cap, the bar tracks whichever is nearer — otherwise it
## would sit at half-full at the exact moment the drill unlocks.
func steer_progress() -> float:
	match _drill_state:
		DrillState.CENTERED:
			return 1.0
		DrillState.STEERING:
			var turned := absf(angle_difference(_steer_start_rot, rotation))
			var wanted := absf(deg_to_rad(tilt_step_deg)) * steer_turn_fraction
			return clampf(maxf(turned / maxf(wanted, 0.001), _state_t / maxf(steer_hold, 0.001)), 0.0, 1.0)
		DrillState.RECENTERING:
			return clampf(maxf(_state_dist / maxf(forward_lock_distance, 0.001),
					_state_t / maxf(forward_lock, 0.001)), 0.0, 1.0)
	return 1.0


## Which phase the bit is in, so the HUD can colour it differently.
func drill_state() -> DrillState:
	return _drill_state


func _enter_state(s: DrillState) -> void:
	_drill_state = s
	_state_t = 0.0
	_state_dist = 0.0


func _level_target() -> float:
	# nearest horizontal, so a leftward bore doesn't spin the hull 180°
	return 0.0 if _facing > 0 else PI


func _update_tilt(delta: float) -> void:
	var limit := int(max_tilt_deg / tilt_step_deg)
	_state_t += delta
	_state_dist += velocity.length() * delta

	match _drill_state:
		DrillState.CENTERED:
			# Only state that accepts a new steering input.
			var step := 0
			if Input.is_action_pressed("tilt_up"):
				step = -1
			elif Input.is_action_pressed("tilt_down"):
				step = 1
			if step != 0:
				_steer_dir = step
				_steer_start_rot = rotation
				tilt_index = clampi(tilt_index + step, -limit, limit)
				_enter_state(DrillState.STEERING)

		DrillState.STEERING:
			# Hold the bit until the HULL has come round, not for a fixed time.
			# A stalled ship never turns, so the time cap is the escape hatch.
			var turned := absf(angle_difference(_steer_start_rot, rotation))
			var wanted := absf(deg_to_rad(tilt_step_deg)) * steer_turn_fraction
			if turned >= wanted or _state_t >= steer_hold:
				var held := (_steer_dir < 0 and Input.is_action_pressed("tilt_up")) \
						or (_steer_dir > 0 and Input.is_action_pressed("tilt_down"))
				if held and absi(tilt_index) < limit:
					tilt_index = clampi(tilt_index + _steer_dir, -limit, limit)
					_steer_start_rot = rotation
					_enter_state(DrillState.STEERING)   # another step, keep turning
				else:
					tilt_index = 0
					_enter_state(DrillState.RECENTERING)

		DrillState.RECENTERING:
			# Bit locked forward for a set DISTANCE of bore, so every straight
			# run between bends is the same length regardless of rock hardness.
			if _state_dist >= forward_lock_distance or _state_t >= forward_lock:
				_enter_state(DrillState.CENTERED)

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
	# Boring is a STATE with hysteresis, not an instantaneous contact test.
	# The frame after a carve there is a gap ahead, so a per-frame test drops
	# to false, gravity kicks in for a frame, the ship sags, then re-contacts.
	# That flicker is what reads as "gravity is affecting the bore".
	_bore_grace = maxf(_bore_grace - delta, 0.0)
	_is_boring = Input.is_action_pressed("drill") and _bore_grace > 0.0

	if not Input.is_action_pressed("drill"):
		_dbg = "idle — drill not held"
		_dig_progress = 0.0
		_bore_grace = 0.0
		_is_boring = false
		return

	ray.force_raycast_update()
	if not ray.is_colliding():
		_dbg = "NO CONTACT — raycast hits nothing (ship at %s)" % [global_position.round()]
		_dig_progress = 0.0
		return

	var terrain := ray.get_collider()
	if terrain == null or not terrain.has_method("sample"):
		_dbg = "WRONG COLLIDER — hit '%s', it has no sample()" % [terrain]
		_dig_progress = 0.0
		return

	# Step past the surface along the RAY's own direction rather than along the
	# surface normal. The ray always travels from inside the hull into rock, so
	# this is deeper-into-material by construction — it doesn't depend on the
	# terrain reporting a correctly-oriented normal.
	var probe := ray.get_collision_point() + heading() * probe_depth
	var info: Dictionary = terrain.sample(probe)
	if info.is_empty():
		_dbg = "PROBE IN AIR — ray hit at %s but probe %s samples open space" % [
			ray.get_collision_point().round(), probe.round()]
		_dig_progress = 0.0
		return

	var hardness: float = info["hardness"]
	if hardness < 0.0:
		_dbg = "GATE ROCK — un-boreable by design"
		_dig_progress = 0.0
		return

	var rock_tier: int = info["tier"]
	_bore_grace = bore_grace_time     # confirmed contact — refresh the state
	_is_boring = true

	_dbg = "BORING  hard=%.2f tier=%d rate=%.2f strength=%.4f speed=%.0f" % [
		hardness, rock_tier, _dig_rate(rock_tier),
		(_dig_rate(rock_tier) / maxf(hardness, 0.01)) * delta * carve_gain,
		velocity.length()]

	# Continuous wear. Remove a slice of density every frame in proportion to
	# dig rate instead of nothing-then-a-whole-disc. Integrated over
	# hardness/dig_rate seconds this removes the same material as the old
	# single full-strength carve — it just arrives smoothly, so the rock
	# recedes and the ship advances at a steady speed.
	var rate := _dig_rate(rock_tier)
	terrain.carve(probe, bore_radius, (rate / maxf(hardness, 0.01)) * delta * carve_gain)

	# Progress now only exists to fire one "unit drilled" event per hardness
	# worth of material, for fuel burn and ore collection later.
	_dig_progress += rate * delta
	if _dig_progress >= hardness:
		drilled.emit(probe, hardness, rock_tier)
		_dig_progress = 0.0

extends StaticBody2D
##
## A discrete, drillable deposit with hit points.
##
## The key idea: this implements the SAME two-method interface the terrain
## does — sample() and carve(). The ship's raycast hits whichever comes first
## and calls those methods without ever asking what it hit. So a deposit can
## behave completely differently (HP that depletes, a payout on destruction,
## an animation) while the drill code stays untouched.
##
## Node layout:
##     OreDeposit        StaticBody2D   <- this script
##     ├── Sprite2D      deposit_ore.png / deposit_geode.png
##     └── CollisionShape2D  CircleShape2D, radius ~17
##

signal depleted(global_pos: Vector2, material_id: int, amount: int)

## Must match the Mat enum in density_terrain.gd so the HUD picks the right icon.
## NOT named `material` — CanvasItem already has a `material` property for
## shaders, and shadowing it is a parse error.
@export var material_id: int = 10

# --- ore stats ---
## Break time in seconds is roughly `max_hp * hardness / dig_rate`, and dig_rate
## sits near 1.0 with a stock drill. So hp 2.0 at hardness 0.7 is about 1.4s.
@export var max_hp: float = 2.0
@export var hardness: float = 0.7
@export var tier: int = 2
@export var yield_amount: int = 6

# --- geode stats ---
## Applied automatically when material_id matches geode. Keeping both stat sets
## on the deposit means the terrain spawner only has to say WHICH it is — it
## was previously overriding hp and hardness in code, so tuning the scene
## silently did nothing for geodes.
@export var geode_hp: float = 4.0
@export var geode_hardness: float = 1.0
@export var geode_tier: int = 2
@export var geode_yield: int = 3

# --- presentation ---
@export var shake_strength: float = 1.6
@export var pop_time: float = 0.2

## Both art variants live on the deposit so the spawner only has to set
## material_id — the node picks its own appearance.
@export var ore_texture: Texture2D
@export var geode_texture: Texture2D
@export var geode_material_id: int = 11

## Found by TYPE, not by name. `$Sprite2D` matches a node literally called
## "Sprite2D", which makes sensible renames break the script for no reason.
## A deposit only ever has one of each, so searching by class is both safer
## and lets you name the children whatever reads best.
@onready var _sprite: Sprite2D = _first_child_of("Sprite2D")
@onready var _shape: CollisionShape2D = _first_child_of("CollisionShape2D")

var hp: float = 0.0
var _dying: bool = false
var _base_pos := Vector2.ZERO


func _first_child_of(type_name: String) -> Node:
	for c in get_children():
		if c.is_class(type_name):
			return c
	return null


func _ready() -> void:
	# Swap to the geode stat set before anything reads them.
	if material_id == geode_material_id:
		max_hp = geode_hp
		hardness = geode_hardness
		tier = geode_tier
		yield_amount = geode_yield
	hp = max_hp

	if _sprite == null or _shape == null:
		push_error("OreDeposit needs a Sprite2D child and a CollisionShape2D child "
				+ "(any name). Found sprite=%s shape=%s" % [_sprite, _shape])
		return

	_base_pos = _sprite.position
	if material_id == geode_material_id and geode_texture != null:
		_sprite.texture = geode_texture
	elif ore_texture != null:
		_sprite.texture = ore_texture


# --- the terrain interface -------------------------------------------------

func sample(_global_pos: Vector2) -> Dictionary:
	if _dying:
		return {}
	return {
		"hardness": hardness,
		"tier": tier,
		"material": material_id,
		"cargo": 0,          # payout happens on depletion, not per grain
	}


func carve(_center_global: Vector2, _radius: float, strength: float = 1.0) -> Dictionary:
	if _dying:
		return {}

	hp -= strength
	_feedback()

	if hp > 0.0:
		return {}

	_burst()
	return {material_id: float(yield_amount)}


# --- presentation ----------------------------------------------------------

func _feedback() -> void:
	# Jitter and redden as it gives way, so progress is visible on the object
	# itself rather than only in a bar somewhere else on screen.
	var frac := clampf(hp / maxf(max_hp, 0.001), 0.0, 1.0)
	_sprite.position = _base_pos + Vector2(
			randf_range(-shake_strength, shake_strength),
			randf_range(-shake_strength, shake_strength))
	_sprite.modulate = Color(1.0, 0.55 + 0.45 * frac, 0.45 + 0.55 * frac)
	_sprite.scale = Vector2.ONE * (0.88 + 0.12 * frac)


func _burst() -> void:
	_dying = true
	_shape.set_deferred("disabled", true)     # deferred: we're inside a physics query
	depleted.emit(global_position, material_id, yield_amount)

	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(_sprite, "scale", Vector2.ONE * 1.9, pop_time) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(_sprite, "modulate:a", 0.0, pop_time)
	t.tween_property(_sprite, "position", _base_pos, pop_time * 0.4)
	t.chain().tween_callback(queue_free)

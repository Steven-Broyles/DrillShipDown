extends TileMapLayer

# atlas coords — must match terrain_tiles_4.png layout
const TOPSOIL   := Vector2i(0, 0)
const DIRT      := Vector2i(1, 0)
const CLAY      := Vector2i(2, 0)
const SANDSTONE := Vector2i(3, 0)
const SHALE     := Vector2i(4, 0)
const GRANITE   := Vector2i(5, 0)
const BASALT    := Vector2i(0, 1)
const DEEP_ROCK := Vector2i(1, 1)
const GATE_ROCK := Vector2i(2, 1)
const MAGMA     := Vector2i(3, 1)
const ORE       := Vector2i(4, 1)
const GEODE     := Vector2i(5, 1)

@export var width: int = 200          # cells, centred on x=0
@export var depth: int = 400          # cells
@export var sky_cells: int = 8        # open air above the surface
@export var world_seed: int = 20260807
@export var regrow_enabled: bool = true
@export var regrow_delay: float = 3.0      # seconds a cell stays open
@export var regrow_per_second: int = 60    # restore rate cap
@export var ship_path: NodePath            # set to ../DrillShip in world.tscn
@export var ship_clearance: float = 14.0   # never refill this close to the ship

@onready var _ship: Node2D = get_node_or_null(ship_path)

var _source: int = -1
var _scars: Array = []
var _head: int = 0
var _now: float = 0.0
const GATE_DEPTHS := [237, 307, 377]
const GATE_THICKNESS := 3

var _cave := FastNoiseLite.new()
var _vein := FastNoiseLite.new()


func _ready() -> void:
	generate()


func _band_tile(y: int) -> Vector2i:
	if y < 16:  return TOPSOIL
	if y < 56:  return DIRT
	if y < 110: return CLAY
	if y < 170: return SANDSTONE
	if y < 240: return SHALE
	if y < 310: return GRANITE
	if y < 380: return BASALT
	return DEEP_ROCK


func _gate_at(y: int) -> bool:
	for d in GATE_DEPTHS:
		if y >= d and y < d + GATE_THICKNESS:
			return true
	return false


func generate() -> void:
	clear()

	if tile_set == null or tile_set.get_source_count() == 0:
		push_error("terrain_generate: no TileSet source on this layer")
		return
	var source: int = tile_set.get_source_id(0)   # first source, whatever its ID

	_cave.seed = world_seed
	_cave.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_cave.frequency = 0.012

	_vein.seed = world_seed + 991
	_vein.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_vein.frequency = 0.05
	_source = tile_set.get_source_id(0)

	var half := width / 2

	for y in range(depth):
		if y < sky_cells:
			continue
		for x in range(-half, half):

			# gate seams span the full width — no cave punches through them
			if _gate_at(y):
				set_cell(Vector2i(x, y), _source, GATE_ROCK)
				continue

			# caves
			if y > sky_cells + 8 and _cave.get_noise_2d(float(x), float(y)) > 0.42:
				continue

			var tile := _band_tile(y)

			# ore / geode / magma pockets
			var v := _vein.get_noise_2d(float(x) * 1.7, float(y) * 1.7)
			if v > 0.62:
				if y > 300:
					tile = MAGMA
				elif y > 120:
					tile = GEODE if v > 0.72 else ORE
				else:
					tile = ORE

			set_cell(Vector2i(x, y), _source, tile)
func carve(center_global: Vector2, radius: float) -> void:
	var local := to_local(center_global)
	var cell := tile_set.tile_size
	var reach := int(ceil(radius / float(mini(cell.x, cell.y))))
	var origin := local_to_map(local)
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var c := origin + Vector2i(dx, dy)
			if map_to_local(c).distance_to(local) > radius:
				continue
			var td := get_cell_tile_data(c)
			if td == null:
				continue                      # already open — not a new scar
			if float(td.get_custom_data("hardness")) < 0.0:
				continue                      # gate rock survives
			_scars.append({"c": c, "tile": get_cell_atlas_coords(c), "t": _now})
			erase_cell(c)


func _process(delta: float) -> void:
	_now += delta
	if not regrow_enabled:
		return

	var budget := maxi(1, int(regrow_per_second * delta))
	while _head < _scars.size() and budget > 0:
		var s: Dictionary = _scars[_head]
		if _now - s["t"] < regrow_delay:
			break                             # queue is in time order
		_head += 1
		budget -= 1
		_restore(s)

	if _head > 512:                           # compact occasionally
		_scars = _scars.slice(_head)
		_head = 0


func _restore(s: Dictionary) -> void:
	var c: Vector2i = s["c"]
	if get_cell_source_id(c) != -1:
		return                                # something's already there
	if _ship != null and map_to_local(c).distance_to(to_local(_ship.global_position)) < ship_clearance:
		s["t"] = _now                         # ship in the way — retry later
		_scars.append(s)
		return
	set_cell(c, _source, s["tile"])
	
	print("terrain: generated ", get_used_cells().size(), " cells, source ", _source)

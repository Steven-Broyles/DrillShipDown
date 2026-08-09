extends StaticBody2D
##
## Density-field terrain with marching-squares collision.
##
## Replaces the boolean TileMapLayer grid. Rock is stored as a float per SAMPLE
## POINT (0 = open, 1 = solid) and the wall surface is the contour where density
## crosses ISO. Because that contour is found by interpolating BETWEEN samples,
## wall angles are continuous instead of snapping to cell boundaries.
##
## Implements the same two-method interface the ship already uses:
##     sample(global_pos) -> {hardness, tier, material}   ({} if open)
##     carve(center_global, radius)
##
## Node layout expected:
##     DensityTerrain   (StaticBody2D)  <- this script
##     └── TileView     (TileMapLayer)  <- visuals only, collision_enabled = OFF
##
## Collision shapes are created at runtime, one CollisionShape2D per chunk.
##

const ISO := 0.5

# Material indices. Order matches terrain_tiles_4.png, row-major.
enum Mat {
	TOPSOIL, DIRT, CLAY, SANDSTONE, SHALE, GRANITE,
	BASALT, DEEP_ROCK, GATE_ROCK, MAGMA, ORE, GEODE
}

const MAT_ATLAS := [
	Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0), Vector2i(5, 0),
	Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1), Vector2i(4, 1), Vector2i(5, 1),
]

# Moved out of TileSet custom data — a density field has no tiles to hang it on.
# Values carried over from your tuned TileSet.
# Flat fill colours for the smoothed edge cells, matching the tilesheet bases.
const MAT_COLOR := [
	Color(0.41, 0.33, 0.20), Color(0.48, 0.34, 0.21), Color(0.55, 0.31, 0.23),
	Color(0.70, 0.58, 0.40), Color(0.33, 0.36, 0.42), Color(0.49, 0.49, 0.53),
	Color(0.24, 0.23, 0.28), Color(0.19, 0.16, 0.18), Color(0.12, 0.13, 0.17),
	Color(0.77, 0.29, 0.11), Color(0.27, 0.24, 0.23), Color(0.23, 0.20, 0.29),
]

const MAT_HARDNESS := [0.1, 0.2, 0.4, 0.6, 1.0, 1.5, 1.8, 2.3, -1.0, 0.3, 0.6, 0.8]
const MAT_TIER     := [0,   0,   1,   1,   2,   2,   3,   4,   9,    1,   2,   2  ]

# --- world shape ---
@export var cell_size: int = 4
@export var width: int = 200            # cells
@export var depth: int = 400            # cells
@export var sky_cells: int = 8
@export var world_seed: int = 20260807
@export var chunk_cells: int = 32       # collision rebuild granularity

# --- generation feel ---
## Off while tuning drill physics. Cave mouths produce concave corners and
## thin spurs that make contact behaviour hard to read; a uniformly solid
## field isolates boring from that entirely.
@export var caves_enabled: bool = false
@export var cave_sharpness: float = 4.0 # higher = harder cave edges

# --- regrowth ---
@export var regrow_enabled: bool = false  # off by default while isolating carve
@export var regrow_delay: float = 3.0
@export var regrow_rate: float = 0.6    # density per second healed
@export var regrow_budget: int = 400    # samples processed per frame
@export var ship_path: NodePath
@export var ship_clearance: float = 16.0
## Pre-cut cavity at the ship's spawn. With the drill capped at a shallow
## angle, a ship resting on flat ground cannot reach the rock beneath it —
## the ray just skims the surface. Starting inside a pocket gives the bit
## rock on every side from frame one.
@export var start_pocket_radius: float = 22.0

# --- debug ---
## Draws the ACTUAL collision contour. With this on, what you see is exactly
## what the ship touches — the tile view is only ever a coarse approximation
## of a smooth field, so it will always disagree with collision somewhat.
@export var debug_draw_contour: bool = true

# --- refs ---
@export var tile_view_path: NodePath = ^"TileView"

@onready var _ship: Node2D = get_node_or_null(ship_path)
@onready var _tiles: TileMapLayer = get_node_or_null(tile_view_path)

var _density: PackedFloat32Array        # (width+1) * (depth+1) samples
var _target: PackedFloat32Array         # pristine density, for regrowth
var _material: PackedByteArray          # width * depth, one per CELL

var _chunks: Dictionary = {}            # Vector2i -> CollisionShape2D
var _dirty: Dictionary = {}             # Vector2i -> true
var _dirty_tiles: Dictionary = {}       # Vector2i -> true
var _edge_polys: Dictionary = {}        # Vector2i chunk -> Array of [poly, color]
var _damaged: Dictionary = {}           # sample index -> time last carved
var _now: float = 0.0

var _tile_source: int = -1

var _cave := FastNoiseLite.new()
var _vein := FastNoiseLite.new()


# =====================================================================
#  Indexing
# =====================================================================
# Samples sit at cell CORNERS, so a width x depth cell grid needs
# (width+1) x (depth+1) samples. Flat arrays with manual indexing are
# markedly faster than nested arrays in GDScript.

func _sidx(x: int, y: int) -> int:
	return y * (width + 1) + x


func _cidx(x: int, y: int) -> int:
	return y * width + x


func _sample_pos(x: int, y: int) -> Vector2:
	return Vector2(x * cell_size, y * cell_size)


# =====================================================================
#  Setup
# =====================================================================

func _ready() -> void:
	# Centre the field horizontally on the node's parent origin, matching how
	# the old TileMapLayer generated from -width/2 to +width/2.
	position = Vector2(-width * cell_size * 0.5, 0.0)

	if _tiles != null and _tiles.tile_set != null and _tiles.tile_set.get_source_count() > 0:
		_tile_source = _tiles.tile_set.get_source_id(0)
		_tiles.collision_enabled = false     # visuals only; we own collision

	generate()


# =====================================================================
#  Generation
# =====================================================================

func _band_material(y: int) -> int:
	if y < 16:  return Mat.TOPSOIL
	if y < 56:  return Mat.DIRT
	if y < 110: return Mat.CLAY
	if y < 170: return Mat.SANDSTONE
	if y < 240: return Mat.SHALE
	if y < 310: return Mat.GRANITE
	if y < 380: return Mat.BASALT
	return Mat.DEEP_ROCK


const GATE_DEPTHS := [237, 307, 377]
const GATE_THICKNESS := 3

func _gate_at(y: int) -> bool:
	for d in GATE_DEPTHS:
		if y >= d and y < d + GATE_THICKNESS:
			return true
	return false


func generate() -> void:
	_cave.seed = world_seed
	_cave.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_cave.frequency = 0.012

	_vein.seed = world_seed + 991
	_vein.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_vein.frequency = 0.05

	_density.resize((width + 1) * (depth + 1))
	_target.resize((width + 1) * (depth + 1))
	_material.resize(width * depth)

	# --- density, per sample point -----------------------------------
	for y in range(depth + 1):
		for x in range(width + 1):
			_density[_sidx(x, y)] = _gen_density(x, y)
	_target = _density.duplicate()

	# --- material, per cell ------------------------------------------
	for y in range(depth):
		for x in range(width):
			_material[_cidx(x, y)] = _gen_material(x, y)

	# Cut the starting shaft before collision is built, so the ship spawns in
	# open space rather than being ejected out of solid rock.
	if _ship != null and start_pocket_radius > 0.0:
		carve(_ship.global_position, start_pocket_radius, 1.0)
		_damaged.clear()        # the launch pocket is permanent, not a scar

	_rebuild_all_chunks()
	_redraw_all_tiles()
	queue_redraw()
	print("density terrain: %d samples, %d chunks" % [_density.size(), _chunks.size()])


func _gen_density(x: int, y: int) -> float:
	# Gate seams are always fully solid — no cave noise punches through them.
	if _gate_at(y):
		return 1.0

	# Open sky above the surface, with one cell of fade so the top edge
	# isn't a razor line.
	var surface := clampf(float(y - sky_cells), 0.0, 1.0)
	if surface <= 0.0:
		return 0.0

	var d := 1.0

	if caves_enabled:
		# The cave noise field IS a density field — don't threshold it to a
		# boolean, map it smoothly. 0.42 was the old cutoff, so that value
		# becomes the ISO contour and everything else ramps around it.
		var n := _cave.get_noise_2d(float(x), float(y))
		d = clampf((0.42 - n) * cave_sharpness + ISO, 0.0, 1.0)

		# Suppress caves near the surface, as the old generator did.
		if y < sky_cells + 8:
			d = 1.0

	return minf(d, surface)


func _gen_material(x: int, y: int) -> int:
	if _gate_at(y):
		return Mat.GATE_ROCK

	var m := _band_material(y)
	var v := _vein.get_noise_2d(float(x) * 1.7, float(y) * 1.7)
	if v > 0.62:
		if y > 300:
			m = Mat.MAGMA
		elif y > 120:
			m = Mat.GEODE if v > 0.72 else Mat.ORE
		else:
			m = Mat.ORE
	return m


# =====================================================================
#  Terrain interface — the ship only ever calls these two
# =====================================================================

func density_at(local_pos: Vector2) -> float:
	# Bilinear interpolation of the four surrounding samples. This MUST be the
	# definition of "solid" everywhere, because it is the field whose ISO
	# contour marching squares turns into collision. Any coarser test (like a
	# per-cell average) disagrees with the wall the ship actually touches.
	var fx := local_pos.x / cell_size
	var fy := local_pos.y / cell_size
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	if x0 < 0 or y0 < 0 or x0 >= width or y0 >= depth:
		return 0.0
	var tx := fx - x0
	var ty := fy - y0
	var d00 := _density[_sidx(x0,     y0)]
	var d10 := _density[_sidx(x0 + 1, y0)]
	var d01 := _density[_sidx(x0,     y0 + 1)]
	var d11 := _density[_sidx(x0 + 1, y0 + 1)]
	return lerpf(lerpf(d00, d10, tx), lerpf(d01, d11, tx), ty)


func sample(global_pos: Vector2) -> Dictionary:
	var l := to_local(global_pos)
	if density_at(l) < ISO:
		return {}

	var cx := clampi(int(floor(l.x / cell_size)), 0, width - 1)
	var cy := clampi(int(floor(l.y / cell_size)), 0, depth - 1)
	var m := _material[_cidx(cx, cy)]
	return {
		"hardness": MAT_HARDNESS[m],
		"tier": MAT_TIER[m],
		"material": m,
	}


## strength 1.0 removes a full disc in one call (the old behaviour).
## Small per-frame values erode the rock gradually instead, which is what
## makes drilling continuous rather than break-lurch-break.
func carve(center_global: Vector2, radius: float, strength: float = 1.0) -> void:
	var c := to_local(center_global)
	var reach := int(ceil(radius / float(cell_size))) + 1
	var ox := int(floor(c.x / cell_size))
	var oy := int(floor(c.y / cell_size))

	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var sx := ox + dx
			var sy := oy + dy
			if sx < 0 or sy < 0 or sx > width or sy > depth:
				continue

			var dist := _sample_pos(sx, sy).distance_to(c)
			if dist > radius:
				continue

			# Gate rock never yields. Check the cell this sample belongs to.
			var mcx := clampi(sx, 0, width - 1)
			var mcy := clampi(sy, 0, depth - 1)
			if MAT_HARDNESS[_material[_cidx(mcx, mcy)]] < 0.0:
				continue

			# Soft radial falloff: full removal at the centre, tapering to
			# nothing at the rim. This is what makes the contour MOVE rather
			# than jump, and what makes drilling continuous instead of
			# lurching one disc at a time.
			# Linear falloff from the exact centre — deliberately NO flat core.
			# A flat core means every sample inside it crosses the 0.5 threshold
			# on the same frame, so the wall jumps rather than recedes. Varying
			# strength all the way from the centre staggers those crossings and
			# the contour advances a fraction of a cell at a time.
			var falloff := 1.0 - clampf(dist / radius, 0.0, 1.0)
			var i := _sidx(sx, sy)
			var before := _density[i]
			_density[i] = maxf(0.0, before - falloff * strength)

			if not is_equal_approx(before, _density[i]):
				_damaged[i] = _now
				_mark_dirty_sample(sx, sy)
				_dirty_tile_at_sample(sx, sy)     # keep the tile view in sync


# =====================================================================
#  Marching squares
# =====================================================================

func _cross(a: Vector2, b: Vector2, da: float, db: float) -> Vector2:
	# Where along edge a->b does density pass through ISO?
	# This single interpolation is the entire reason walls stop being blocky.
	var denom := db - da
	if absf(denom) < 0.00001:
		return a.lerp(b, 0.5)
	return a.lerp(b, clampf((ISO - da) / denom, 0.0, 1.0))


func _emit_square(x: int, y: int, segs: PackedVector2Array) -> void:
	var tl := _density[_sidx(x,     y)]
	@warning_ignore("shadowed_variable_base_class")
	var tr := _density[_sidx(x + 1, y)]
	var br := _density[_sidx(x + 1, y + 1)]
	var bl := _density[_sidx(x,     y + 1)]

	# One bit per corner: 1=TL, 2=TR, 4=BR, 8=BL
	var ci := 0
	if tl >= ISO: ci |= 1
	if tr >= ISO: ci |= 2
	if br >= ISO: ci |= 4
	if bl >= ISO: ci |= 8

	# 0 = fully open, 15 = fully solid. Neither contains a surface.
	if ci == 0 or ci == 15:
		return

	var p_tl := _sample_pos(x,     y)
	var p_tr := _sample_pos(x + 1, y)
	var p_br := _sample_pos(x + 1, y + 1)
	var p_bl := _sample_pos(x,     y + 1)

	var e_top    := _cross(p_tl, p_tr, tl, tr)
	var e_right  := _cross(p_tr, p_br, tr, br)
	var e_bottom := _cross(p_bl, p_br, bl, br)
	var e_left   := _cross(p_tl, p_bl, tl, bl)

	# ORDER MATTERS. ConcavePolygonShape2D derives surface normals from the
	# direction of each segment, so every segment is emitted such that solid
	# rock is consistently on the same side. Cases that mirror each other
	# (1/14, 2/13, ...) put the wall in the same place but with rock on
	# OPPOSITE sides, so they must be emitted in opposite order.
	match ci:
		1:
			segs.append(e_top);    segs.append(e_left)
		14:
			segs.append(e_left);   segs.append(e_top)
		2:
			segs.append(e_right);  segs.append(e_top)
		13:
			segs.append(e_top);    segs.append(e_right)
		3:
			segs.append(e_right);  segs.append(e_left)
		12:
			segs.append(e_left);   segs.append(e_right)
		4:
			segs.append(e_bottom); segs.append(e_right)
		11:
			segs.append(e_right);  segs.append(e_bottom)
		6:
			segs.append(e_bottom); segs.append(e_top)
		9:
			segs.append(e_top);    segs.append(e_bottom)
		7:
			segs.append(e_bottom); segs.append(e_left)
		8:
			segs.append(e_left);   segs.append(e_bottom)
		5:
			# Saddle: TL and BR solid. Ambiguous — separate each solid corner
			# on its own, using the same winding as the single-corner cases.
			segs.append(e_top);    segs.append(e_left)
			segs.append(e_bottom); segs.append(e_right)
		10:
			# Saddle: TR and BL solid.
			segs.append(e_right);  segs.append(e_top)
			segs.append(e_left);   segs.append(e_bottom)


# =====================================================================
#  Chunked collision
# =====================================================================

func _chunk_of(cell_x: int, cell_y: int) -> Vector2i:
	@warning_ignore("integer_division")
	return Vector2i(cell_x / chunk_cells, cell_y / chunk_cells)


func _mark_dirty_sample(sx: int, sy: int) -> void:
	# A sample sits on the corner of up to four cells, which may fall in
	# different chunks. Dirty the neighbourhood rather than reasoning about it.
	for dy in [-1, 0]:
		for dx in [-1, 0]:
			var cx := clampi(sx + dx, 0, width - 1)
			var cy := clampi(sy + dy, 0, depth - 1)
			_dirty[_chunk_of(cx, cy)] = true


func _rebuild_all_chunks() -> void:
	var cx_count := int(ceil(float(width) / chunk_cells))
	var cy_count := int(ceil(float(depth) / chunk_cells))
	for cy in range(cy_count):
		for cx in range(cx_count):
			_rebuild_chunk(Vector2i(cx, cy))


func _rebuild_chunk(chunk: Vector2i) -> void:
	var x0 := chunk.x * chunk_cells
	var y0 := chunk.y * chunk_cells
	var x1 := mini(x0 + chunk_cells, width)
	var y1 := mini(y0 + chunk_cells, depth)

	var segs := PackedVector2Array()
	var polys: Array = []
	for y in range(y0, y1):
		for x in range(x0, x1):
			_emit_square(x, y, segs)
			_append_solid_poly(x, y, polys)

	if polys.is_empty():
		_edge_polys.erase(chunk)
	else:
		_edge_polys[chunk] = polys

	var node: CollisionShape2D = _chunks.get(chunk)
	if node == null:
		if segs.is_empty():
			return                                  # nothing here, don't allocate
		node = CollisionShape2D.new()
		node.name = "Chunk_%d_%d" % [chunk.x, chunk.y]
		add_child(node)
		_chunks[chunk] = node

	if segs.is_empty():
		node.disabled = true
		return

	# ConcavePolygonShape2D takes a raw soup of segment endpoints — exactly
	# what marching squares produces. No loop-chaining or winding needed.
	var shape := ConcavePolygonShape2D.new()
	shape.segments = segs
	node.shape = shape
	node.disabled = false


func _flush_dirty() -> void:
	if _dirty.is_empty():
		return
	for chunk in _dirty.keys():
		_rebuild_chunk(chunk)
	_dirty.clear()
	queue_redraw()


## For a partially-filled cell, returns the polygon covering the SOLID part —
## the same corners and edge crossings marching squares uses for collision, so
## the drawn rock and the wall you hit are the same shape by construction.
## Fully solid cells (case 15) are left to the TileMapLayer, which is far
## faster and carries the material texture. Only the fringe needs polygons.
func _append_solid_poly(x: int, y: int, out: Array) -> void:
	var tl := _density[_sidx(x,     y)]
	var tr := _density[_sidx(x + 1, y)]
	var br := _density[_sidx(x + 1, y + 1)]
	var bl := _density[_sidx(x,     y + 1)]

	var ci := 0
	if tl >= ISO: ci |= 1
	if tr >= ISO: ci |= 2
	if br >= ISO: ci |= 4
	if bl >= ISO: ci |= 8
	if ci == 0 or ci == 15:
		return

	var p_tl := _sample_pos(x,     y)
	var p_tr := _sample_pos(x + 1, y)
	var p_br := _sample_pos(x + 1, y + 1)
	var p_bl := _sample_pos(x,     y + 1)

	var e_top    := _cross(p_tl, p_tr, tl, tr)
	var e_right  := _cross(p_tr, p_br, tr, br)
	var e_bottom := _cross(p_bl, p_br, bl, br)
	var e_left   := _cross(p_tl, p_bl, tl, bl)

	var col: Color = MAT_COLOR[_material[_cidx(x, y)]]

	match ci:
		1:  _push_poly(out, [p_tl, e_top, e_left], col)
		2:  _push_poly(out, [p_tr, e_right, e_top], col)
		4:  _push_poly(out, [p_br, e_bottom, e_right], col)
		8:  _push_poly(out, [p_bl, e_left, e_bottom], col)
		3:  _push_poly(out, [p_tl, p_tr, e_right, e_left], col)
		6:  _push_poly(out, [p_tr, p_br, e_bottom, e_top], col)
		12: _push_poly(out, [p_br, p_bl, e_left, e_right], col)
		9:  _push_poly(out, [p_tl, e_top, e_bottom, p_bl], col)
		7:  _push_poly(out, [p_tl, p_tr, p_br, e_bottom, e_left], col)
		11: _push_poly(out, [p_tl, p_tr, e_right, e_bottom, p_bl], col)
		13: _push_poly(out, [p_tl, e_top, e_right, p_br, p_bl], col)
		14: _push_poly(out, [e_top, p_tr, p_br, p_bl, e_left], col)
		5:
			_push_poly(out, [p_tl, e_top, e_left], col)
			_push_poly(out, [p_br, e_bottom, e_right], col)
		10:
			_push_poly(out, [p_tr, e_right, e_top], col)
			_push_poly(out, [p_bl, e_left, e_bottom], col)


## Godot cannot triangulate zero-area polygons. When a corner sits almost
## exactly on ISO, the interpolated edge crossings collapse onto that corner
## and the resulting "polygon" is a sliver or a point. Drop duplicates, then
## reject anything without real area, before it ever reaches _draw().
func _push_poly(out: Array, pts: Array, col: Color) -> void:
	var clean := PackedVector2Array()
	for p in pts:
		if clean.is_empty() or clean[clean.size() - 1].distance_squared_to(p) > 0.0001:
			clean.append(p)
	# first and last may also coincide once duplicates are gone
	while clean.size() > 1 and clean[0].distance_squared_to(clean[clean.size() - 1]) <= 0.0001:
		clean.remove_at(clean.size() - 1)
	if clean.size() < 3:
		return

	var area2 := 0.0                       # shoelace, twice the signed area
	for i in clean.size():
		var a := clean[i]
		var b := clean[(i + 1) % clean.size()]
		area2 += a.x * b.y - b.x * a.y
	if absf(area2) < 0.02:
		return

	out.append([clean, col])


func _draw() -> void:
	# Smoothed rock fringe. Interior rock is tiles; only the cut face is drawn
	# as geometry, so this scales with tunnel perimeter rather than world area.
	for chunk in _edge_polys:
		for entry in _edge_polys[chunk]:
			draw_colored_polygon(entry[0], entry[1])

	# Draw the real collision contour, so what you see IS what you hit.
	if not debug_draw_contour:
		return
	for chunk in _chunks:
		var node: CollisionShape2D = _chunks[chunk]
		if node == null or node.disabled or node.shape == null:
			continue
		var segs: PackedVector2Array = (node.shape as ConcavePolygonShape2D).segments
		var i := 0
		while i + 1 < segs.size():
			draw_line(segs[i], segs[i + 1], Color(1.0, 0.55, 0.2), 1.0)
			i += 2


# =====================================================================
#  Regrowth — the field relaxes back toward its generated state
# =====================================================================

func _process(delta: float) -> void:
	_now += delta
	if regrow_enabled:
		_heal(delta)
	_flush_dirty()          # one collision rebuild pass per frame, after all edits
	_flush_dirty_tiles()


func _heal(delta: float) -> void:
	if _damaged.is_empty():
		return

	var ship_local := Vector2.INF
	if _ship != null:
		ship_local = to_local(_ship.global_position)

	var budget := regrow_budget
	var done: Array = []

	for key in _damaged:
		if budget <= 0:
			break
		var i: int = key
		if _now - float(_damaged[i]) < regrow_delay:
			continue
		budget -= 1

		var sx: int = i % (width + 1)
		@warning_ignore("integer_division")
		var sy: int = i / (width + 1)

		# Never heal into the ship — terrain closes in and waits.
		if ship_local != Vector2.INF:
			if _sample_pos(sx, sy).distance_to(ship_local) < ship_clearance:
				_damaged[i] = _now              # push the timer back, retry later
				continue

		var before := _density[i]
		_density[i] = move_toward(before, _target[i], regrow_rate * delta)
		if not is_equal_approx(before, _density[i]):
			_mark_dirty_sample(sx, sy)
			_dirty_tile_at_sample(sx, sy)
		if is_equal_approx(_density[i], _target[i]):
			done.append(i)

	for i in done:
		_damaged.erase(i)


# =====================================================================
#  Tile rendering (temporary — visuals only, no collision)
# =====================================================================

func _redraw_all_tiles() -> void:
	if _tiles == null or _tile_source < 0:
		return
	_tiles.clear()
	for y in range(depth):
		for x in range(width):
			_refresh_tile(x, y)


func _dirty_tile_at_sample(sx: int, sy: int) -> void:
	# Queue rather than redraw immediately. With continuous carving this is hit
	# hundreds of times a frame, and the Dictionary dedupes the overlap.
	for dy in [-1, 0]:
		for dx in [-1, 0]:
			_dirty_tiles[Vector2i(clampi(sx + dx, 0, width - 1), clampi(sy + dy, 0, depth - 1))] = true


func _flush_dirty_tiles() -> void:
	if _dirty_tiles.is_empty():
		return
	for c in _dirty_tiles:
		_refresh_tile(c.x, c.y)
	_dirty_tiles.clear()


func _refresh_tile(cx: int, cy: int) -> void:
	if _tiles == null or _tile_source < 0:
		return
	# Only place a tile where the cell is FULLY solid. Partially-filled cells
	# are drawn as contour-cut polygons instead — a square tile in a half-empty
	# cell is exactly the jagged edge we're getting rid of.
	var full := _density[_sidx(cx, cy)] >= ISO \
			and _density[_sidx(cx + 1, cy)] >= ISO \
			and _density[_sidx(cx, cy + 1)] >= ISO \
			and _density[_sidx(cx + 1, cy + 1)] >= ISO
	var coords := Vector2i(cx, cy)
	if full:
		_tiles.set_cell(coords, _tile_source, MAT_ATLAS[_material[_cidx(cx, cy)]])
	else:
		_tiles.erase_cell(coords)

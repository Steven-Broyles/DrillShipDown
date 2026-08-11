extends Control
##
## Cargo hold readout: icon + count for each valuable, plus capacity.
##
## Everything is drawn in one _draw() rather than assembled from TextureRects
## and Labels, so the whole widget is a single node to place and a single file
## to change.
##
## This is the one layer that legitimately knows what a "geode" is — mapping a
## material index to a picture is presentation, not simulation. The ship and
## the terrain stay ignorant of each other's vocabulary.
##
## Expected layout:
##     World
##     └── HUD           CanvasLayer
##         ├── SteerReady    TextureProgressBar
##         ├── FuelGauge     TextureProgressBar
##         └── CargoReadout  Control            <- this script
##

@export var ship_path: NodePath = ^"../../DrillShip"

@export var ore_icon: Texture2D
@export var geode_icon: Texture2D
## Must match the Mat enum order in density_terrain.gd.
@export var ore_material: int = 10
@export var geode_material: int = 11

@export var icon_scale: int = 2
@export var row_gap: int = 40
@export var text_size: int = 16
@export var full_tint := Color(1.0, 0.5, 0.35)

@onready var _ship: Node = get_node_or_null(ship_path)

var _ore: int = 0
var _geode: int = 0
var _used: int = 0
var _cap: int = 1


func _ready() -> void:
	if _ship == null:
		push_warning("cargo_readout: ship_path did not resolve")
		return
	_ship.cargo_changed.connect(_on_cargo_changed)
	# Deferred for the same reason as the fuel gauge: sibling _ready() order
	# is not something to depend on.
	call_deferred("_sync_from_ship")


func _sync_from_ship() -> void:
	if _ship != null:
		_on_cargo_changed(_ship.cargo, _ship.cargo_used, _ship.max_cargo)


func _on_cargo_changed(hold: Dictionary, used: int, capacity: int) -> void:
	_ore = int(hold.get(ore_material, 0))
	_geode = int(hold.get(geode_material, 0))
	_used = used
	_cap = maxi(capacity, 1)
	queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var col := full_tint if _used >= _cap else Color(1, 1, 1)
	var x := 0.0

	for entry in [[ore_icon, _ore], [geode_icon, _geode]]:
		var tex: Texture2D = entry[0]
		var n: int = entry[1]
		if tex != null:
			var w := tex.get_width() * icon_scale
			var h := tex.get_height() * icon_scale
			draw_texture_rect(tex, Rect2(x, 0, w, h), false)
			x += w + 4
		draw_string(font, Vector2(x, float(text_size) + 6.0), str(n),
				HORIZONTAL_ALIGNMENT_LEFT, -1, text_size, col)
		x += row_gap

	# Capacity. Reads as "how much room is left before I have to haul back".
	draw_string(font, Vector2(0, float(text_size) * 2.0 + 14.0),
			"%d / %d" % [_used, _cap], HORIZONTAL_ALIGNMENT_LEFT, -1,
			text_size - 4, col)

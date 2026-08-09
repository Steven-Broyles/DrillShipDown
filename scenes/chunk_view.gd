extends Node2D
##
## Draws the smoothed rock fringe for ONE terrain chunk.
##
## Why this is its own node rather than part of the terrain's _draw():
## a CanvasItem's draw commands are recorded once and replayed by the engine
## until it is invalidated. With every polygon in one _draw(), a single carved
## cell forced the whole world's fringe to be re-recorded every frame — a cost
## that grew with total tunnel length, which is why drilling got heavier the
## longer a run went on.
##
## One node per chunk means a carve only invalidates the chunks it touched.
## Everything else stays cached and costs nothing.
##

## [Rect2, Color] — solid interior, merged into horizontal runs of one material.
var fills: Array = []
## [PackedVector2Array, Color] — the contour-cut fringe on partial cells.
var polys: Array = []


func _draw() -> void:
	# Interior first, fringe on top: the fringe polygons share edges with the
	# fill rects, and drawing them second hides any seam from rounding.
	for f in fills:
		draw_rect(f[0], f[1])
	for entry in polys:
		draw_colored_polygon(entry[0], entry[1])

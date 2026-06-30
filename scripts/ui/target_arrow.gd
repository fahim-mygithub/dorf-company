extends Node2D
## Hearthstone-style targeting arrow — a dumb renderer.
## combat.gd calls set_arrow(enabled, from, to, locked) each frame; this draws a
## tapered bezier ribbon (red while free, green when locked onto an enemy) + head.
## Drawn in global/canvas coords (node sits at origin under the root Control).

var enabled: bool = false
var from: Vector2 = Vector2.ZERO
var to: Vector2 = Vector2.ZERO
var locked: bool = false

const SEGMENTS: int = 22

func set_arrow(is_on: bool, f: Vector2, t: Vector2, lk: bool) -> void:
	if is_on == enabled and f == from and t == to and lk == locked:
		return   # dirty-check: skip the per-frame rebuild when nothing changed
	enabled = is_on
	from = f
	to = t
	locked = lk
	visible = is_on
	queue_redraw()

func _bezier(s: float) -> Vector2:
	var mid: Vector2 = (from + to) * 0.5
	var dist: float = from.distance_to(to)
	var ctrl: Vector2 = mid - Vector2(0, minf(240.0, dist * 0.3))   # bow upward
	var u: float = 1.0 - s
	return u * u * from + 2.0 * u * s * ctrl + s * s * to

func _draw() -> void:
	if not enabled or from.distance_to(to) < 4.0:
		return
	var col: Color = Color(0.25, 1.0, 0.5, 0.9) if locked else Color(1.0, 0.32, 0.32, 0.85)
	var pts: Array[Vector2] = []
	for i: int in range(SEGMENTS + 1):
		pts.append(_bezier(float(i) / float(SEGMENTS)))
	# Tapered edges (thin at source, thick near the head).
	var left: Array[Vector2] = []
	var right: Array[Vector2] = []
	for i: int in range(pts.size()):
		var s: float = float(i) / float(SEGMENTS)
		var seg: Vector2
		if i < pts.size() - 1:
			seg = (pts[i + 1] - pts[i]).normalized()
		else:
			seg = (pts[i] - pts[i - 1]).normalized()
		var perp: Vector2 = Vector2(-seg.y, seg.x)
		var w: float = lerpf(3.0, 13.0, s)
		left.append(pts[i] + perp * w)
		right.append(pts[i] - perp * w)
	# Convex per-segment quads avoid concave-triangulation artifacts.
	for i: int in range(SEGMENTS):
		draw_colored_polygon(PackedVector2Array([left[i], left[i + 1], right[i + 1], right[i]]), col)
	# Arrowhead — tip at `to`.
	var dir: Vector2 = (pts[pts.size() - 1] - pts[pts.size() - 2]).normalized()
	var perp2: Vector2 = Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([
		to + dir * 4.0,
		to - dir * 22.0 + perp2 * 18.0,
		to - dir * 22.0 - perp2 * 18.0,
	]), col)

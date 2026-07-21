extends Control
## Pointy-top hexagon tile for the overworld expedition map — a Civ-style "board piece":
## a darker side hexagon below (thickness), terrain fill on top, a light rim on the two
## upper edges, a thin dark outline, and an optional pulsing highlight ring (reachable /
## objective affordance). Purely visual; the owner wires input and content labels.

var radius := 50.0
var lift := 8.0                          # bevel thickness below the top face — a chunkier board piece
var flat := false                        # walls: no thickness, sits IN the board
var fill := Color(0.24, 0.26, 0.24)
var side := Color(0.13, 0.08, 0.05)      # walnut edge: the tiles read as carved wooden pieces on felt
var outline := Color(0, 0, 0, 0.60)
var rim := Color(1.0, 0.93, 0.78, 0.16)  # warm light catching the two upper edges
var ring := Color(0, 0, 0, 0)            # ring base color; alpha comes from ring_alpha
var hoverable := false

var ring_alpha := 0.0:
	set(v):
		ring_alpha = v
		queue_redraw()
var hovered := false:
	set(v):
		hovered = v
		queue_redraw()

func _ready() -> void:
	if ring.a > 0.0:
		var tw := create_tween().set_loops()
		tw.tween_property(self, "ring_alpha", ring.a, 0.55).set_trans(Tween.TRANS_SINE)
		tw.tween_property(self, "ring_alpha", ring.a * 0.25, 0.55).set_trans(Tween.TRANS_SINE)
	if hoverable:
		mouse_entered.connect(func() -> void: hovered = true)
		mouse_exited.connect(func() -> void: hovered = false)

func _face_center() -> Vector2:
	# Top face rides up when hovered; the side stays put so the lift reads as height.
	return size * 0.5 + Vector2(0, -4.0 if hovered else 0.0)

func _pts(c: Vector2, r: float) -> PackedVector2Array:
	var p := PackedVector2Array()
	for i in range(6):
		var a := deg_to_rad(60.0 * float(i) - 90.0)   # pointy-top
		p.append(c + Vector2(cos(a), sin(a)) * r)
	return p

func _closed(p: PackedVector2Array) -> PackedVector2Array:
	var q := p.duplicate()
	q.append(p[0])
	return q

func _draw() -> void:
	var c := _face_center()
	if not flat:
		draw_colored_polygon(_pts(c + Vector2(0, lift), radius), side)
	var f := fill
	if hovered:
		f = fill.lightened(0.18)
	var top := _pts(c, radius)
	draw_colored_polygon(top, f)
	if not flat:
		# light-from-above rim on the two upper edges (verts: 5=upper-left, 0=top, 1=upper-right)
		draw_polyline(PackedVector2Array([top[5], top[0], top[1]]), rim, 2.5, true)
	draw_polyline(_closed(top), outline, 1.5, true)
	if ring.a > 0.0 and ring_alpha > 0.01:
		var rc := Color(ring.r, ring.g, ring.b, ring_alpha)
		draw_polyline(_closed(_pts(c, radius - 2.5)), rc, 3.5, true)

## Precise picking: only points inside the hexagon count, so bounding-box corners
## never steal clicks from a neighbouring tile.
func _has_point(point: Vector2) -> bool:
	var d := point - size * 0.5
	var w := radius * sqrt(3.0) * 0.5    # half hex width
	# pointy-top hex: |x| ≤ w, sloped caps: |y| ≤ R − |x|·(R/2)/w
	return absf(d.x) <= w and absf(d.y) <= radius - absf(d.x) * (radius * 0.5) / w

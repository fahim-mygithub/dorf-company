extends Node2D
## A one-shot expanding ring — the flash when a Class Power fires, comes back ready, or a passive
## discharges. Self-animates over ~0.34s and frees itself. Spawn centered on the coin, then call
## go(colour). Cheap enough to fire on every activation on every peer (it is derived from state, so
## a client plays it the same way the host does).

var col := Color.WHITE
var r0 := 20.0
var r1 := 46.0
var _p := 0.0:
	set(v):
		_p = v
		queue_redraw()

func go(c: Color, from_r: float = 20.0, to_r: float = 46.0) -> void:
	col = c
	r0 = from_r
	r1 = to_r
	var tw := create_tween()
	tw.tween_property(self, "_p", 1.0, 0.34).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_callback(queue_free)

func _draw() -> void:
	var r := lerpf(r0, r1, _p)
	var a := (1.0 - _p) * 0.9
	# a second, fainter ring a beat behind gives the pop some depth
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, Color(col.r, col.g, col.b, a), 3.0 * (1.0 - _p) + 1.0, true)
	draw_arc(Vector2.ZERO, r * 0.72, 0.0, TAU, 32, Color(col.r, col.g, col.b, a * 0.5), 2.0 * (1.0 - _p) + 0.5, true)

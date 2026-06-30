extends Node2D
## Draws the enemy->target threat arrows (the telegraph the player reads each turn).
## combat.gd calls set_threats([{from, to}, ...]) in canvas coords; updates live.

var threats: Array = []

func set_threats(pairs: Array) -> void:
	threats = pairs
	queue_redraw()

func _draw() -> void:
	var col := Color(0.95, 0.30, 0.30, 0.65)
	for p: Dictionary in threats:
		var a: Vector2 = p["from"]
		var b: Vector2 = p["to"]
		if a.distance_to(b) < 6.0:
			continue
		var dir := (b - a).normalized()
		var perp := Vector2(-dir.y, dir.x)
		var shaft_end := b - dir * 16.0
		draw_line(a, shaft_end, col, 3.0)
		draw_colored_polygon(PackedVector2Array([
			b, shaft_end + perp * 9.0, shaft_end - perp * 9.0,
		]), col)

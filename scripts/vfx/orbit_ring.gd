extends Node2D
## A themed ring of motes that circles a Class Power coin while a PERSISTENT stance is held —
## the Barbarian's rage embers, the Bard's notes, the Druid's leaves. Purely cosmetic: the coin
## adds one when a stance ignites and frees it when the stance drops. Revolves in _process and
## redraws each frame; place it centered on the coin (position = coin.size * 0.5).

var motes := 6
var col := Color(1, 1, 1)
var orbit_r := 30.0      # revolution radius — sits just OUTSIDE the coin rim, hence "circling around it"
var mote_r := 3.0
var spin := 2.0          # rad/s
var shape := "dot"       # dot | diamond | leaf | note
var flicker := 0.0       # 0..1 per-mote alpha shimmer
var _t := 0.0

## Motion + colour language per stance. Aggression reads fast + hard (embers), the song reads
## slow + soft (notes), the wild shape reads organic + green (leaves).
func setup(preset: String) -> void:
	match preset:
		"rage":
			motes = 7; col = Color(1.0, 0.45, 0.13); orbit_r = 31.0; mote_r = 3.4; spin = 2.7; shape = "diamond"; flicker = 0.55
		"perform":
			motes = 4; col = Color(1.0, 0.86, 0.42); orbit_r = 33.0; mote_r = 3.0; spin = 1.1; shape = "note"; flicker = 0.20
		"shape":
			motes = 5; col = Color(0.52, 0.85, 0.35); orbit_r = 31.0; mote_r = 3.4; spin = 1.6; shape = "leaf"; flicker = 0.28
		_:
			motes = 6; col = Color.WHITE

func tint(c: Color) -> void:
	col = c

func _process(dt: float) -> void:
	_t += dt
	rotation = _t * spin
	queue_redraw()

func _draw() -> void:
	for i in range(motes):
		var a := TAU * float(i) / float(motes)
		var p := Vector2(cos(a), sin(a)) * orbit_r
		var al := 1.0 - flicker * (0.5 + 0.5 * sin(_t * 6.0 + float(i) * 1.7))
		var cc := Color(col.r, col.g, col.b, al)
		# halo behind each mote so the ring glows rather than looking like hard pixels
		draw_circle(p, mote_r * 2.2, Color(col.r, col.g, col.b, 0.18 * al))
		_draw_mote(p, cc)

func _draw_mote(p: Vector2, cc: Color) -> void:
	match shape:
		"diamond":
			draw_colored_polygon(PackedVector2Array([
				p + Vector2(0, -mote_r * 1.5), p + Vector2(mote_r, 0),
				p + Vector2(0, mote_r * 1.5), p + Vector2(-mote_r, 0)]), cc)
		"leaf":
			draw_colored_polygon(PackedVector2Array([
				p + Vector2(0, -mote_r * 1.7), p + Vector2(mote_r * 1.1, mote_r), p + Vector2(-mote_r * 1.1, mote_r)]), cc)
		"note":
			draw_circle(p, mote_r, cc)
			draw_line(p + Vector2(mote_r * 0.8, 0.0), p + Vector2(mote_r * 0.8, -mote_r * 2.6), cc, 1.3)
		_:
			draw_circle(p, mote_r, cc)

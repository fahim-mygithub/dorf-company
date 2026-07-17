extends Control
## A Class Power "coin" — a Hearthstone-style hero-power medallion on each dwarf's portrait, struck
## in its archetype's metal (tank = steel, support = gold, dps = arcane). It FLIPS to a spent face
## when a cooldown starts and flips back when it recovers; a charge/communion power fills a rim arc;
## a held stance (rage / song / wild shape) is ringed by orbiting motes; the Cleric's passive reads a
## 5-segment cast ring. Pure cosmetic + input target — combat.gd routes taps and feeds set_state() a
## derived snapshot each refresh, and the coin diffs that against its last state to fire its own
## flip / burst / orbit. Because the snapshot is what every peer already has, the animations replay
## identically on host and client with no extra networking.

const OrbitRing := preload("res://scripts/vfx/orbit_ring.gd")
const RingPop := preload("res://scripts/vfx/ring_pop.gd")

# Archetype metal: ready-face base, struck highlight, rim, and the accent used for fill arcs / bursts.
const METAL := {
	"tank":    {"base": Color(0.24, 0.26, 0.30), "hi": Color(0.44, 0.48, 0.54), "rim": Color(0.66, 0.70, 0.78), "accent": Color(1.0, 0.50, 0.18)},
	"support": {"base": Color(0.30, 0.24, 0.10), "hi": Color(0.56, 0.46, 0.20), "rim": Color(0.95, 0.82, 0.40), "accent": Color(1.0, 0.93, 0.62)},
	"dps":     {"base": Color(0.20, 0.16, 0.30), "hi": Color(0.38, 0.30, 0.54), "rim": Color(0.72, 0.56, 0.98), "accent": Color(0.52, 0.86, 1.0)},
}
const SPENT_BASE := Color(0.15, 0.15, 0.18)
const SPENT_HI := Color(0.22, 0.22, 0.26)
const SPENT_RIM := Color(0.36, 0.36, 0.42)
const FORM_COL := {
	"bear": Color(0.80, 0.55, 0.28), "hawk": Color(0.50, 0.76, 1.0), "wolf": Color(0.72, 0.74, 0.82),
}

var _archetype := "tank"
var _emoji_s := "•"
var _m: Dictionary = METAL["tank"]

# Drawn state (set by set_state each refresh).
var _kind := "ready"          # ready | locked | cooldown | charge | communion | stance | passive
var _cd := 0
var _cd_max := 1
var _fill := 0
var _fill_max := 1
var _stance := ""             # "" | rage | perform | shape
var _pips := 0
var _pips_max := 5
var _lit := false
var _showing_tails := false
var _have_state := false
var _flipping := false

var _flip_x := 1.0:
	set(v):
		_flip_x = v
		if _emoji: _emoji.scale.x = maxf(v, 0.02)
		if _count: _count.scale.x = maxf(v, 0.02)
		queue_redraw()
var _shine := 0.0:
	set(v):
		_shine = v
		queue_redraw()

var _emoji: Label
var _count: Label
var _orbit: Node2D
var _shine_tw: Tween

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_emoji = _mk_label(int(size.y * 0.42), Color(1, 1, 1))
	_emoji.text = _emoji_s
	_count = _mk_label(int(size.y * 0.5), Color(0.86, 0.90, 1.0))
	_count.visible = false

func _mk_label(fsize: int, col: Color) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size = size
	l.pivot_offset = size * 0.5
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", col)
	add_child(l)
	return l

## Called once, when the coin's owner/class is known.
func configure(archetype: String, emoji: String) -> void:
	_archetype = archetype
	_m = METAL.get(archetype, METAL["tank"])
	_emoji_s = emoji
	if _emoji: _emoji.text = emoji
	queue_redraw()

## Called every refresh with a derived snapshot. The coin diffs it and animates the transitions.
func set_state(st: Dictionary) -> void:
	var kind := str(st.get("kind", "ready"))
	var stance := str(st.get("stance", ""))
	var form := str(st.get("form", ""))
	var cd := int(st.get("cd", 0))
	var pips := int(st.get("pips", 0))
	var lit := bool(st.get("lit", false))
	var em := str(st.get("emoji", _emoji_s))
	if em != _emoji_s:
		_emoji_s = em
		if _emoji: _emoji.text = em

	if _have_state:
		_react(kind, stance, pips)

	_kind = kind
	_stance = stance
	_cd = cd
	_cd_max = maxi(1, int(st.get("cd_max", 1)))
	_fill = int(st.get("fill", 0))
	_fill_max = maxi(1, int(st.get("fill_max", 1)))
	_pips = pips
	_pips_max = maxi(1, int(st.get("pips_max", 5)))
	_lit = lit
	_have_state = true

	_apply_orbit(stance, form)
	_apply_shine(lit)
	if not _flipping:
		_apply_faces()
	queue_redraw()

## Diff the incoming state against the last one and fire the matching animation.
func _react(kind: String, stance: String, pips: int) -> void:
	if kind == "cooldown" and _kind != "cooldown":
		_do_flip()
		_pop(SPENT_RIM)
	elif _kind == "cooldown" and kind != "cooldown":
		_do_flip()
		_pop(_m["accent"])
	elif kind == "ready" and _kind in ["charge", "communion", "locked"]:
		_pop(_m["accent"])          # charged up / paid up — now firable
	if stance != "" and _stance == "":
		_pop(_stance_col(stance))   # a stance just ignited
	if kind == "passive" and pips < _pips:
		_pop(_m["accent"])          # the 5th cast wrapped the ring → discharge

## The signature move: a vertical-axis coin flip. The face swaps at the narrow midpoint so it reads
## as the coin turning over, not cross-fading.
func _do_flip() -> void:
	_flipping = true
	var tw := create_tween()
	tw.tween_property(self, "_flip_x", 0.04, 0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_callback(_apply_faces)
	tw.tween_property(self, "_flip_x", 1.0, 0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func() -> void: _flipping = false)

func _apply_faces() -> void:
	_showing_tails = _kind == "cooldown"
	if _emoji:
		_emoji.visible = not _showing_tails
		_emoji.modulate = Color(0.62, 0.62, 0.68) if _kind == "locked" else Color(1, 1, 1)
	if _count:
		_count.visible = _showing_tails
		_count.text = str(_cd) if _showing_tails else ""
	queue_redraw()

func _apply_orbit(stance: String, form: String) -> void:
	if stance == "":
		if _orbit:
			_orbit.queue_free()
			_orbit = null
		return
	if _orbit and str(_orbit.get_meta("stance", "")) == stance and str(_orbit.get_meta("form", "")) == form:
		return
	if _orbit:
		_orbit.queue_free()
	_orbit = OrbitRing.new()
	_orbit.set_meta("stance", stance)
	_orbit.set_meta("form", form)
	_orbit.setup(stance)
	if form != "" and FORM_COL.has(form):
		_orbit.tint(FORM_COL[form])
	_orbit.position = size * 0.5
	add_child(_orbit)

func _apply_shine(lit: bool) -> void:
	if lit and not _shine_tw:
		_shine_tw = create_tween().set_loops()
		_shine_tw.tween_property(self, "_shine", 1.0, 0.7).set_trans(Tween.TRANS_SINE)
		_shine_tw.tween_property(self, "_shine", 0.25, 0.7).set_trans(Tween.TRANS_SINE)
	elif not lit and _shine_tw:
		_shine_tw.kill()
		_shine_tw = null
		_shine = 0.0
		queue_redraw()

func _pop(c: Color) -> void:
	var rp := RingPop.new()
	rp.position = size * 0.5
	add_child(rp)
	var rr := minf(size.x, size.y)
	rp.go(c, rr * 0.42, rr * 0.86)

func _stance_col(s: String) -> Color:
	match s:
		"rage": return Color(1.0, 0.45, 0.13)
		"perform": return Color(1.0, 0.86, 0.42)
		"shape": return Color(0.52, 0.85, 0.35)
	return _m["accent"]

# ---------------------------------------------------------------- draw
func _draw() -> void:
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.5 - 3.0
	# One transform squashes the WHOLE coin horizontally during a flip; arcs/pips never coincide with
	# a flip (only cooldowns flip, and they carry no arc), so drawing them under it is safe.
	draw_set_transform(c, 0.0, Vector2(maxf(_flip_x, 0.02), 1.0))
	if _showing_tails:
		_draw_spent(r)
	else:
		_draw_face(r)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## A struck-metal disc: dark outline, a soft top-left sheen (fake radial gradient), a bright rim and
## an inner groove that together read as a bevelled coin edge. Shared by the ready and spent faces.
func _disc(r: float, base: Color, hi: Color, rimc: Color) -> void:
	draw_circle(Vector2.ZERO, r + 0.6, Color(0, 0, 0, 0.55))                       # outline / drop
	draw_circle(Vector2.ZERO, r, base)
	var o := Vector2(-r * 0.20, -r * 0.24)                                         # light from top-left
	draw_circle(o, r * 0.66, hi.lerp(base, 0.5))
	draw_circle(o * 1.25, r * 0.42, hi.lerp(base, 0.15))
	draw_circle(o * 1.5, r * 0.22, hi)
	draw_arc(Vector2.ZERO, r - 1.2, 0.0, TAU, 44, rimc, 2.8, true)                 # bright rim
	draw_arc(Vector2.ZERO, r - 3.6, 0.0, TAU, 40, Color(0, 0, 0, 0.22), 1.6, true) # inner groove → bevel

func _draw_face(r: float) -> void:
	var rimc: Color = _m["rim"]
	if _lit:
		rimc = rimc.lerp(Color(1, 1, 1), 0.45 * _shine)
	if _kind == "locked":
		_disc(r, _m["base"].darkened(0.40), _m["hi"].darkened(0.45), SPENT_RIM)
		return
	_disc(r, _m["base"], _m["hi"], rimc)
	if _lit:
		draw_arc(Vector2.ZERO, r - 1.2, 0.0, TAU, 44, Color(1, 1, 1, 0.30 * _shine), 3.4, true)
	if _kind in ["charge", "communion"]:
		_draw_fill_arc(r)
	elif _kind == "passive":
		_draw_pips(r)

func _draw_fill_arc(r: float) -> void:
	var frac := clampf(float(_fill) / float(_fill_max), 0.0, 1.0)
	draw_arc(Vector2.ZERO, r - 4.5, 0.0, TAU, 40, Color(1, 1, 1, 0.10), 3.0, true)
	if frac > 0.0:
		draw_arc(Vector2.ZERO, r - 4.5, -PI * 0.5, -PI * 0.5 + TAU * frac, 40, _m["accent"], 3.6, true)

func _draw_pips(r: float) -> void:
	for i in range(_pips_max):
		var a := -PI * 0.5 + TAU * float(i) / float(_pips_max)
		var p := Vector2(cos(a), sin(a)) * (r - 2.5)
		if i < _pips:
			draw_circle(p, 3.4, Color(_m["accent"].r, _m["accent"].g, _m["accent"].b, 0.28))
			draw_circle(p, 2.4, _m["accent"])
		else:
			draw_circle(p, 2.2, Color(0.30, 0.30, 0.34))

func _draw_spent(r: float) -> void:
	_disc(r, SPENT_BASE, SPENT_HI, SPENT_RIM)
	# recovery arc: the fraction of cooldown STILL to serve, draining clockwise from noon each turn
	var frac := clampf(float(_cd) / float(_cd_max), 0.0, 1.0)
	if frac > 0.0:
		draw_arc(Vector2.ZERO, r - 4.5, -PI * 0.5, -PI * 0.5 + TAU * frac, 36, Color(0.55, 0.72, 0.95, 0.95), 3.2, true)

extends Control
## THE TAVERN, INHABITED — the cheapest possible version of "see the crew hanging out".
##
## No sprites, no pixel art, no purchase decision: the dwarves are the SAME emoji Labels the
## shipped game already draws everywhere (combat.gd `_emoji`, overworld.gd `_mkemoji`), just given
## somewhere to be and permission to walk around in it.
##
## The constraint that shapes everything: an emoji has EXACTLY ONE POSE, forever, and it is
## COLR/CPAL so `modulate` cannot even tint it. The figure can therefore never carry state — which
## is fine, because that is the field standard (7 of 8 surveyed games keep the character a costume
## and put every changing value beside it). State lives in four places, none of them the glyph:
##   1. WHERE they are       — the hearth means wounded, the boards mean fit. Placement is the datum.
##   2. WHAT is next to them — a stool and a blanket under the one who is laid up.
##   3. The PLATE under them — name + HP + Guard segment: the miniature's base, and the surveyed
##                             convention puts the bar UNDER the figure, never over its head.
##   4. WHETHER they move    — the fit ones mill about; the wounded one does not get up. This one
##                             only exists because they animate, and it is the cheapest of the four.

const BAND_TOP := 158.0      # content band starts under the HUD
const BAND_BOT := 1006.0     # ...and ends at the crew bar. Same budget as every shipped screen.
const FLOOR_Y := 596.0       # the horizon: where the back wall meets the boards
const WANDER := Rect2(286, 640, 354, 260)   # the box a fit dwarf may amble inside
const WALK_SPEED := 44.0
const MIN_GAP := 156.0       # keep base plates from colliding — they are 132 wide
const BOX := Vector2(132, 108)

const WALNUT := Color("2b1c0f")
const WALNUT_HI := Color("4a3320")
const WALNUT_LO := Color("1a120a")
const BRASS := Color("b98b3c")
const BRASS_HI := Color("e8c887")
const BRASS_LO := Color("7d5a22")
const PARCH := Color("e3d5b4")
const GINK := Color("2a2118")
const GRED := Color("c25b4a")
const GGREEN := Color("6fae72")
const STEEL := Color("b9c2cb")
const GOLD := Color("d8a93a")
const ARCANE := Color("9c6fd6")

var crew: Array[Dictionary] = []
var bark_i := -1
var bark_t := 2.0
var _t := 0.0

## One bark per class per venue, pre-broken into lines that fit the slip. This is the highest
## feel-per-byte item in the whole design: a dictionary entry buys more "they live here" than any
## amount of art does.
const BARKS := {
	"warrior": ["Third stool I've broken", "this month."],
	"cleric": ["I've blessed this table twice.", "It still cheats at dice."],
	"sorcerer": ["The fire's wrong.", "I can fix the fire."],
}


func _ready() -> void:
	_add("Dorrin Stonebeard", "warrior", "🛡️", STEEL, 31, 36, 5, false)
	_add("Bruni Ashcask", "cleric", "⛑️", GOLD, 9, 28, 0, true)
	_add("Vex Emberhand", "sorcerer", "🔮", ARCANE, 20, 22, 0, false)
	set_process(true)


func _add(nm: String, cls: String, em: String, metal: Color, hp: int, mx: int, guard: int, hurt: bool) -> void:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 64)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.size = BOX
	l.pivot_offset = BOX * 0.5
	l.text = em
	add_child(l)

	# The wounded one is PARKED at the hearth stool and never gets a walk target. Not being able to
	# get up IS the readout — the only cue on this screen that needs no legend at all.
	var home := Vector2(158, 726) if hurt else Vector2(
		randf_range(WANDER.position.x, WANDER.end.x), randf_range(WANDER.position.y, WANDER.end.y))
	crew.append({
		"name": nm, "cls": cls, "metal": metal, "hp": hp, "max_hp": mx, "guard": guard,
		"hurt": hurt, "node": l, "pos": home, "target": home,
		"pause": randf_range(0.4, 2.4), "bob": randf() * TAU, "face": 1.0,
	})


func _pick_target(self_i: int) -> Vector2:
	# Re-roll until the new spot keeps a plate's width from everyone else. Six tries is plenty and
	# bounds the loop; if they all fail the dwarf just stands still a beat longer, which is fine.
	for _try in 6:
		var c := Vector2(randf_range(WANDER.position.x, WANDER.end.x),
						 randf_range(WANDER.position.y, WANDER.end.y))
		var ok := true
		for j in crew.size():
			if j == self_i:
				continue
			var other: Vector2 = crew[j]["target"] if not crew[j]["hurt"] else crew[j]["pos"]
			if absf(other.x - c.x) < MIN_GAP and absf(other.y - c.y) < 96.0:
				ok = false
				break
		if ok:
			return c
	return crew[self_i]["pos"]


func _process(delta: float) -> void:
	_t += delta

	for i in crew.size():
		var d: Dictionary = crew[i]
		var pos: Vector2 = d["pos"]

		if not d["hurt"]:
			# Amble: stand a beat, choose somewhere on the boards, walk there, repeat. The pause is
			# what makes it read as loitering rather than patrolling.
			if pos.distance_to(d["target"]) < 4.0:
				d["pause"] = float(d["pause"]) - delta
				if d["pause"] <= 0.0:
					d["target"] = _pick_target(i)
					d["pause"] = randf_range(1.0, 3.4)
			else:
				var step := pos.direction_to(d["target"]) * WALK_SPEED * delta
				pos += step
				d["pos"] = pos
				if absf(step.x) > 0.01:
					d["face"] = 1.0 if step.x >= 0.0 else -1.0

		d["bob"] = float(d["bob"]) + delta * (7.4 if _walking(d) else 2.0)

		# Depth: nearer the camera is bigger. Cheap, and it stops three same-size glyphs from
		# reading as a row of icons.
		var depth: float = clampf((pos.y - WANDER.position.y) / maxf(WANDER.size.y, 1.0), 0.0, 1.0)
		var sc: float = lerpf(0.86, 1.14, depth)
		var l: Label = d["node"]
		var hop: float = sin(float(d["bob"])) * (5.0 if _walking(d) else 1.6)
		l.scale = Vector2(sc * float(d["face"]), sc)
		l.position = pos - Vector2(BOX.x * 0.5, BOX.y) + Vector2(0, hop)

	# Painter's algorithm: whoever stands nearer the camera draws last.
	var order := crew.duplicate()
	order.sort_custom(func(a, b): return float(a["pos"].y) < float(b["pos"].y))
	for i in order.size():
		move_child(order[i]["node"], get_child_count() - 1)

	# Barks rotate, one at a time, with silence between — the room murmurs instead of shouting.
	bark_t -= delta
	if bark_t <= 0.0:
		bark_i = (bark_i + 1) % (crew.size() * 2)   # odd slots are nobody, i.e. quiet
		bark_t = 3.6 if bark_i < crew.size() else 2.4

	queue_redraw()


func _walking(d: Dictionary) -> bool:
	return not d["hurt"] and Vector2(d["pos"]).distance_to(d["target"]) >= 4.0


# ============================================================================== the room
func _draw() -> void:
	var f := get_theme_default_font()

	draw_rect(Rect2(0, 0, 720, 1280), WALNUT_LO)

	# --- back wall: plank courses, and DARK, so the boards below can read as lit ------------
	for i in 9:
		var y := BAND_TOP + i * 49.0
		draw_rect(Rect2(0, y, 720, 47), Color("1f160d").lerp(Color("33241a"), float(i) / 9.0))
		draw_line(Vector2(0, y + 47), Vector2(720, y + 47), Color(0, 0, 0, 0.45), 2.0)

	# --- floor boards: markedly lighter and warmer than the wall ----------------------------
	for i in 9:
		var y := FLOOR_Y + i * 46.0
		if y > BAND_BOT:
			break
		var h: float = minf(44.0, BAND_BOT - y)
		draw_rect(Rect2(0, y, 720, h), Color("7a5528").lerp(Color("4a331b"), float(i) / 9.0))
		draw_line(Vector2(0, y + h), Vector2(720, y + h), Color(0, 0, 0, 0.35), 2.0)
	# the horizon, hard, so wall and floor never blur into one brown field
	draw_rect(Rect2(0, FLOOR_Y - 6, 720, 6), Color("0f0a06"))
	draw_rect(Rect2(0, FLOOR_Y, 720, 3), Color("9c6f36"))

	# --- the hearth, left: the only warm thing, and the reason the sick one sits there -------
	draw_rect(Rect2(24, 300, 250, 296), Color("3b332c"))
	draw_rect(Rect2(38, 314, 222, 268), Color("241f1b"))
	draw_rect(Rect2(64, 372, 170, 210), Color("100c09"))
	var flick := 0.86 + sin(_t * 5.3) * 0.09 + sin(_t * 11.7) * 0.05
	draw_circle(Vector2(150, 520), 80.0 * flick, Color(0.98, 0.55, 0.16, 0.28))
	draw_circle(Vector2(150, 528), 52.0 * flick, Color(1.0, 0.72, 0.26, 0.46))
	draw_circle(Vector2(150, 536), 27.0 * flick, Color(1.0, 0.88, 0.52, 0.74))
	draw_rect(Rect2(18, 286, 262, 20), WALNUT_HI)
	draw_rect(Rect2(18, 286, 262, 4), Color("6b4d28"))
	_ellipse(Vector2(150, 640), 148.0, 34.0, Color(1.0, 0.62, 0.2, 0.09))

	# --- the bar, right ---------------------------------------------------------------------
	draw_rect(Rect2(468, 452, 252, 144), Color("3d2a16"))
	for i in 5:
		draw_circle(Vector2(496 + i * 48, 496), 12.0, Color("7a6440"))
	draw_rect(Rect2(444, 560, 276, 12), Color("5c4022"))
	draw_rect(Rect2(444, 572, 276, 24), WALNUT_HI)
	draw_rect(Rect2(444, 572, 276, 5), Color("8a6531"))

	# --- a table, centre, drawn BEHIND the crew ---------------------------------------------
	_ellipse(Vector2(372, 706), 96.0, 27.0, Color("38260f"))
	_ellipse(Vector2(372, 699), 96.0, 27.0, Color("6b4d28"))
	draw_rect(Rect2(364, 706, 16, 58), Color("3a2716"))

	# --- hanging sign -----------------------------------------------------------------------
	draw_line(Vector2(360, BAND_TOP), Vector2(360, 196), BRASS_LO, 3.0)
	draw_rect(Rect2(266, 196, 188, 64), WALNUT)
	draw_rect(Rect2(266, 196, 188, 64), BRASS_LO, false, 3.0)
	if f:
		draw_string(f, Vector2(266, 237), "THE RUSTED PICK", HORIZONTAL_ALIGNMENT_CENTER, 188, 20, BRASS_HI)

	# --- the crew ---------------------------------------------------------------------------
	for d in crew:
		_draw_dwarf(d, f)

	if bark_i >= 0 and bark_i < crew.size():
		_draw_bark(crew[bark_i], f)

	# --- the bands this screen would really live inside, so the composition is honest --------
	_draw_chrome(f)


func _draw_dwarf(d: Dictionary, f: Font) -> void:
	var p: Vector2 = d["pos"]
	var depth: float = clampf((p.y - WANDER.position.y) / maxf(WANDER.size.y, 1.0), 0.0, 1.0)
	var sc: float = lerpf(0.86, 1.14, depth)

	# The stool and the blanket are drawn on the ROOM, not on the dwarf — which is the whole trick,
	# because the dwarf itself can never be redrawn.
	if d["hurt"]:
		draw_rect(Rect2(p.x - 36, p.y - 8, 72, 13), WALNUT_HI)
		draw_rect(Rect2(p.x - 30, p.y + 5, 10, 32), Color("3a2716"))
		draw_rect(Rect2(p.x + 20, p.y + 5, 10, 32), Color("3a2716"))
		_ellipse(Vector2(p.x, p.y - 30), 44.0, 24.0, Color("8a785a"))
		_ellipse(Vector2(p.x, p.y - 34), 39.0, 21.0, PARCH)

	_ellipse(Vector2(p.x, p.y + 4), 32.0 * sc, 9.5 * sc, Color(0, 0, 0, 0.44))

	# THE BASE — the miniature's base, and the instrument panel.
	var bw := 132.0
	var bx := p.x - bw * 0.5
	var by := p.y + 12.0
	_ellipse(Vector2(p.x, by + 6), bw * 0.5, 12.0, Color(d["metal"]).darkened(0.42))
	_ellipse(Vector2(p.x, by + 3), bw * 0.5, 12.0, d["metal"])
	draw_rect(Rect2(bx + 8, by + 18, bw - 16, 32), Color(0, 0, 0, 0.66))

	if f:
		draw_string(f, Vector2(bx + 10, by + 32), str(d["name"]).split(" ")[0],
			HORIZONTAL_ALIGNMENT_LEFT, bw - 20, 14, PARCH)
		draw_string(f, Vector2(bx + 10, by + 32), "%d/%d" % [int(d["hp"]), int(d["max_hp"])],
			HORIZONTAL_ALIGNMENT_RIGHT, bw - 20, 13, PARCH)

	# HP track. Guard rides this SAME bar as an overlay segment, never a second bar — which is
	# exactly what the shipped `block` field already is.
	var tw := bw - 20.0
	draw_rect(Rect2(bx + 10, by + 38, tw, 9), Color(0, 0, 0, 0.6))
	var frac: float = float(d["hp"]) / maxf(1.0, float(d["max_hp"]))
	draw_rect(Rect2(bx + 10, by + 38, tw * frac, 9), GRED if frac < 0.5 else GGREEN)
	if int(d["guard"]) > 0:
		var gw: float = tw * (float(d["guard"]) / float(d["max_hp"]))
		draw_rect(Rect2(bx + 10, by + 38, gw, 9), STEEL)
		draw_line(Vector2(bx + 10 + gw, by + 38), Vector2(bx + 10 + gw, by + 47), WALNUT_LO, 2.0)

	if d["hurt"] and f:
		draw_rect(Rect2(bx + 8, by + 54, bw - 16, 20), Color("5a1f18"))
		draw_string(f, Vector2(bx + 8, by + 69), "OUT 2 MONTHS", HORIZONTAL_ALIGNMENT_CENTER, bw - 16, 13, PARCH)


func _draw_bark(d: Dictionary, f: Font) -> void:
	if not f:
		return
	var lines: Array = BARKS.get(d["cls"], ["…"])
	var p: Vector2 = d["pos"]
	var w := 300.0
	var h: float = 26.0 + lines.size() * 20.0
	var x: float = clampf(p.x - w * 0.5, 14.0, 720.0 - w - 14.0)
	var y: float = maxf(p.y - 150.0, BAND_TOP + 112.0)
	# A stem down to the speaker's head. The slip has to clamp inside the screen, so without this the
	# clamp silently reassigns the line to whoever happens to be standing under it.
	var stem_x: float = clampf(p.x, x + 16.0, x + w - 16.0)
	draw_line(Vector2(stem_x, y + h), Vector2(p.x, p.y - 96.0), Color("b7a479"), 2.0)
	draw_circle(Vector2(p.x, p.y - 96.0), 3.5, Color("b7a479"))
	draw_rect(Rect2(x + 3, y + 4, w, h), Color(0, 0, 0, 0.42))
	draw_rect(Rect2(x, y, w, h), PARCH)
	draw_rect(Rect2(x, y, w, h), Color("b7a479"), false, 2.0)
	for i in lines.size():
		draw_string(f, Vector2(x + 10, y + 26 + i * 20), String(lines[i]),
			HORIZONTAL_ALIGNMENT_CENTER, w - 20, 15, GINK)
	draw_circle(Vector2(x + 13, y + 10), 4.0, BRASS_LO)   # a pin: it is a slip of paper, not a bubble


func _draw_chrome(f: Font) -> void:
	# HUD y0-158
	draw_rect(Rect2(0, 0, 720, BAND_TOP), Color("241708"))
	draw_rect(Rect2(0, BAND_TOP - 3, 720, 3), BRASS_LO)
	if f:
		draw_string(f, Vector2(24, 66), "THE HALL -> THE TAVERN", HORIZONTAL_ALIGNMENT_LEFT, 400, 17, Color("c8bb9c"))
		draw_string(f, Vector2(24, 108), "THE TAVERN", HORIZONTAL_ALIGNMENT_LEFT, 400, 30, PARCH)
		draw_string(f, Vector2(400, 100), "TREASURY  248g", HORIZONTAL_ALIGNMENT_RIGHT, 296, 21, BRASS_HI)

	# crew band y1006-1080
	draw_rect(Rect2(0, BAND_BOT, 720, 74), Color("1b1409"))
	draw_rect(Rect2(0, BAND_BOT, 720, 2), BRASS_LO)
	if f:
		var seats := ["SEAT 1 - YOU", "SEAT 2 - MARA", "SEAT 3 - TOBY"]
		for i in 3:
			draw_string(f, Vector2(28 + i * 228, BAND_BOT + 32), seats[i],
				HORIZONTAL_ALIGNMENT_LEFT, 208, 14, Color("a9977a"))
			draw_string(f, Vector2(28 + i * 228, BAND_BOT + 56), str(crew[i]["name"]).split(" ")[0]
				+ (" - wounded" if crew[i]["hurt"] else " - fit"),
				HORIZONTAL_ALIGNMENT_LEFT, 208, 14, BRASS_HI if crew[i]["hurt"] else BRASS)

	# action rail y1086-1214, quiet LEFT / brass RIGHT, per the shipped contract
	draw_rect(Rect2(24, 1110, 300, 76), Color("2e2415"))
	draw_rect(Rect2(24, 1110, 300, 76), Color("4a3b22"), false, 2.0)
	draw_rect(Rect2(396, 1110, 300, 76), BRASS)
	draw_rect(Rect2(396, 1114, 300, 68), BRASS_HI)
	if f:
		draw_string(f, Vector2(24, 1157), "<- THE HALL", HORIZONTAL_ALIGNMENT_CENTER, 300, 20, Color("c3b394"))
		draw_string(f, Vector2(396, 1157), "REST -> 10 DAYS LEFT", HORIZONTAL_ALIGNMENT_CENTER, 300, 20, Color("2a1c07"))
		draw_string(f, Vector2(28, 1244), "Wounds clear over months, not on the job.",
			HORIZONTAL_ALIGNMENT_CENTER, 664, 15, Color("cbbb95"))


func _ellipse(c: Vector2, rx: float, ry: float, col: Color) -> void:
	draw_set_transform(c, 0.0, Vector2(1.0, ry / maxf(rx, 0.001)))
	draw_circle(Vector2.ZERO, rx, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

extends Control
## A ROOM — the full-bleed diegetic venue chassis.
##
## ONE Control renders every venue (and the town map) from a pure-data spec: wall, floorboards, a
## list of primitive draw ops, wandering emoji characters, and tappable PROPS that carry their own
## parchment tag. There is deliberately no data panel — a price hangs on the object that sells it.
##
## Why data and not five bespoke screens: the venue count is going to grow, and the earlier design
## contract was explicit that a chassis serving one venue is set-dressing multiplied by venue count.
## Adding a room is a Dictionary, never a function.
##
## The characters are the SAME emoji Labels the shipped game draws everywhere (combat.gd `_emoji`,
## overworld.gd `_mkemoji`). An emoji has exactly one pose forever and is COLR/CPAL so it cannot
## even be tinted, so state never lives on the figure. It lives in WHERE they are, WHAT is beside
## them, the plate UNDER them, and whether they move at all.

signal prop_tapped(id: String, act: String)
signal dwarf_tapped(idx: int)

const BAND_TOP := 158.0
const BAND_BOT := 1006.0        # the LAYOUT floor: how far down a figure or a tag may be placed
const DRAW_BOT := 1280.0        # the PAINTED floor: full-bleed to the bottom of the screen
const WALK_SPEED := 42.0
const BOX := Vector2(120, 100)
const TAG_W := 200.0
const TAG_H := 64.0
const CHIP_W := 76.0            # the player-dwarf name chip; also what sets the minimum lane width

## The whole legal palette. A spec names a token; it can never invent a colour, which is what keeps
## five independently-authored rooms looking like one game.
const TOK := {
	"walnut": Color("2b1c0f"), "walnut_hi": Color("4a3320"), "walnut_lo": Color("1a120a"),
	"brass": Color("b98b3c"), "brass_hi": Color("e8c887"), "brass_lo": Color("7d5a22"),
	"parch": Color("e3d5b4"), "parch_lo": Color("cbbb95"), "gink": Color("2a2118"),
	"felt": Color("17332a"), "felt_lo": Color("0f241d"),
	"ember": Color("d9752a"), "ember_hi": Color("ffd88a"),
	"shadow": Color(0, 0, 0, 0.45), "ink": Color("efe6d2"),
	# Status inks for a PARCHMENT tag. They are dark on purpose: the screen-side status colours are
	# bright greens and ambers tuned for a near-black HUD, and painting those on cream is unreadable.
	"good": Color("3f6b34"), "warn": Color("9c4a17"), "dim": Color("8a7f68"),
}

var spec: Dictionary = {}
var actors: Array = []          # every character in the room: player dwarves AND npcs
var _t := 0.0
var _hot: Array = []            # [{rect, id, act}] hit targets, rebuilt on configure


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)


func _col(t: Variant, fallback: Color = Color.MAGENTA) -> Color:
	return TOK.get(str(t), fallback)


## `dwarves` are the player's own, drawn with a base plate. `spec.npcs` are the room's people.
func configure(s: Dictionary, dwarves: Array) -> void:
	spec = s
	for a in actors:
		if is_instance_valid(a["node"]):
			a["node"].queue_free()
	actors.clear()
	_hot.clear()

	var w: Array = spec.get("wander", [286, 700, 340, 220])
	var wr := Rect2(float(w[0]), float(w[1]), float(w[2]), float(w[3]))

	for i in range(dwarves.size()):
		var d: Dictionary = dwarves[i]
		# A dwarf who cannot walk does not walk. That is the entire wounded readout, and it is the
		# one cue on this screen that needs no legend. Position is set by the lane pass below —
		# including for the still ones, which used to be parked in a fixed corner and therefore
		# stood on top of whoever owned the first lane.
		var still := str(d.get("status", "ready")) != "ready"
		_spawn(str(d.get("emoji", "🛡️")), 54, wr.position, not still, true, d, i)

	for n in spec.get("npcs", []):
		var at: Array = n.get("at", [360, 800])
		_spawn(str(n.get("t", "🧔")), int(n.get("size", 44)),
			Vector2(float(at[0]), float(at[1])), bool(n.get("wander", false)), false,
			{"name": str(n.get("name", ""))}, -1)

	# LANES. A wander rect is often narrower than the characters standing in it (the town's is 220px
	# for four dwarves), so roamers cannot be left to pick freely — they pile up and their chips
	# stack. Each roamer owns a vertical slice and ambles only inside it, which guarantees separation
	# at any rect width and degrades by narrowing rather than by overlapping.
	# Every PLAYER dwarf gets a lane whether or not it walks — a wounded one stands still IN its lane
	# — plus every wandering NPC. A fixed NPC keeps its authored spot and takes no lane.
	var roamers: int = 0
	for a in actors:
		if a["roams"] or a["pc"]:
			roamers += 1
	var li: int = 0
	for a in actors:
		if not (a["roams"] or a["pc"]):
			continue
		a["lane"] = li
		a["lanes"] = maxi(1, roamers)
		var lw: float = wr.size.x / float(maxi(1, roamers))
		# The chip SHRINKS to its lane rather than overlapping its neighbour. A room's walkable floor
		# is set by its furniture and cannot simply be widened to suit the roster, so when the crew
		# outgrows the space the label gives way — losing a few pixels of name beats losing which
		# name belongs to which dwarf.
		a["chip"] = clampf(lw - 10.0, 44.0, CHIP_W)
		a["pos"] = Vector2(wr.position.x + lw * (float(li) + 0.5),
			randf_range(wr.position.y, wr.end.y))
		a["target"] = a["pos"]
		li += 1

	for p in spec.get("props", []):
		_hot.append({
			"rect": _hit_rect(p),
			"id": str(p.get("id", "")), "act": str(p.get("act", "none")),
		})
	queue_redraw()


## What you can actually touch — and, drawn as a frame, what TELLS you that you can. A prop may
## declare its own footprint (`hit`), which is how a whole BUILDING becomes one tappable object
## rather than just the sign hanging on it. Without one the target is the glyph plus its tag, which
## is the right shape for an object sitting on a counter.
func _hit_rect(p: Dictionary) -> Rect2:
	if p.has("hit"):
		var h: Array = p["hit"]
		return Rect2(float(h[0]), float(h[1]), float(h[2]), float(h[3]))
	var at: Array = p.get("at", [360, 600])
	var cx := float(at[0])
	var cy := float(at[1])
	var sz: float = float(p.get("size", 40))
	var top: float = cy - sz * 0.95
	var bot: float = cy + sz * 0.55 + TAG_H
	return Rect2(cx - TAG_W * 0.5 - 8.0, top, TAG_W + 16.0, bot - top)


func _spawn(glyph: String, font_px: int, home: Vector2, roams: bool, is_pc: bool, data: Dictionary, idx: int) -> void:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_px)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.size = BOX
	l.pivot_offset = BOX * 0.5
	l.text = glyph
	add_child(l)
	actors.append({
		"node": l, "pos": home, "target": home, "roams": roams, "pc": is_pc, "idx": idx,
		"data": data, "size": font_px, "pause": randf_range(0.3, 2.4), "bob": randf() * TAU, "face": 1.0,
		"lane": 0, "lanes": 1, "chip": CHIP_W,
	})


func _process(delta: float) -> void:
	_t += delta
	var w: Array = spec.get("wander", [286, 700, 340, 220])
	var wr := Rect2(float(w[0]), float(w[1]), float(w[2]), float(w[3]))

	for a in actors:
		var pos: Vector2 = a["pos"]
		if a["roams"]:
			if pos.distance_to(a["target"]) < 4.0:
				a["pause"] = float(a["pause"]) - delta
				if a["pause"] <= 0.0:
					var lw: float = wr.size.x / float(maxi(1, int(a["lanes"])))
					var lx: float = wr.position.x + lw * float(a["lane"])
					# The lane bounds the FIGURE'S CENTRE, but what collides is its 76px chip. So
					# inset by half a chip: without this, two neighbours meeting at a lane boundary
					# still overlap completely, and the lanes buy nothing.
					var pad: float = minf(float(a.get("chip", CHIP_W)) * 0.5, lw * 0.42)
					a["target"] = Vector2(randf_range(lx + pad, lx + lw - pad),
										  randf_range(wr.position.y, wr.end.y))
					a["pause"] = randf_range(0.9, 3.2)
			else:
				var step := pos.direction_to(a["target"]) * WALK_SPEED * delta
				pos += step
				a["pos"] = pos
				if absf(step.x) > 0.01:
					a["face"] = 1.0 if step.x >= 0.0 else -1.0
		a["bob"] = float(a["bob"]) + delta * (7.0 if _moving(a) else 1.9)
		var depth: float = clampf((pos.y - wr.position.y) / maxf(wr.size.y, 1.0), 0.0, 1.0)
		var sc: float = lerpf(0.88, 1.10, depth)
		var l: Label = a["node"]
		l.scale = Vector2(sc * float(a["face"]), sc)
		l.position = pos - Vector2(BOX.x * 0.5, BOX.y) + Vector2(0, sin(float(a["bob"])) * (4.5 if _moving(a) else 1.5))

	# Painter's algorithm — whoever stands nearer the camera draws last.
	var order := actors.duplicate()
	order.sort_custom(func(x, y): return float(x["pos"].y) < float(y["pos"].y))
	for i in order.size():
		move_child(order[i]["node"], get_child_count() - 1)
	queue_redraw()


func _moving(a: Dictionary) -> bool:
	return bool(a["roams"]) and Vector2(a["pos"]).distance_to(a["target"]) >= 4.0


# ============================================================================ drawing
func _draw() -> void:
	if spec.is_empty():
		return
	var f := get_theme_default_font()
	var hz: float = float(spec.get("horizon", 596))

	# back wall, in courses so the gradient reads as boards rather than a wash
	var wt: Color = _col(spec.get("wall_top"), Color("241a10"))
	var wb: Color = _col(spec.get("wall_bot"), Color("33241a"))
	var n := 9
	for i in n:
		var y: float = BAND_TOP + (hz - BAND_TOP) * float(i) / float(n)
		var h: float = (hz - BAND_TOP) / float(n) + 1.0
		draw_rect(Rect2(0, y, 720, h), wt.lerp(wb, float(i) / float(n)))

	# floor
	var fn: Color = _col(spec.get("floor_near"), Color("4a331b"))
	var ff: Color = _col(spec.get("floor_far"), Color("7a5528"))
	# The floor runs to the BOTTOM OF THE SCREEN, not to BAND_BOT. BAND_BOT bounds where things may
	# be PLACED (it is where the co-op crew bar starts); painting only that far left a 270px band of
	# dead black under every room, which read as the room ending halfway down a full-bleed screen.
	var m := 11
	for i in m:
		var y: float = hz + (DRAW_BOT - hz) * float(i) / float(m)
		var h: float = (DRAW_BOT - hz) / float(m) + 1.0
		draw_rect(Rect2(0, y, 720, h), ff.lerp(fn, float(i) / float(m)))
		draw_line(Vector2(0, y + h), Vector2(720, y + h), Color(0, 0, 0, 0.28), 2.0)
	# the horizon, hard, so wall and floor never blur into one brown field
	draw_rect(Rect2(0, hz - 5, 720, 5), Color(0, 0, 0, 0.55))

	for op in spec.get("furniture", []):
		_draw_op(op, f)

	# A tappable frame is ARCHITECTURE: it draws with the furniture, BEFORE the characters, so a
	# dwarf walking past a building passes in front of its outline instead of behind it. The tags
	# stay on top of everyone, because a price you cannot read is worse than a dwarf you cannot see.
	for p in spec.get("props", []):
		_draw_hit_frame(p)

	for a in actors:
		_draw_actor(a, f)

	for p in spec.get("props", []):
		_draw_prop(p, f)


## Every tappable thing in every room carries the SAME brass edge. The consistency IS the affordance:
## one rule to learn — brass edge means you can touch it — instead of a per-object guess about
## whether a drawn shape is scenery or a control.
func _draw_hit_frame(p: Dictionary) -> void:
	var r: Rect2 = _hit_rect(p)
	# A dark outer stroke first, so the brass reads against a light wall as well as a dark one.
	draw_rect(r.grow(3.0), Color(0, 0, 0, 0.40), false, 5.0)
	draw_rect(r, TOK["brass"], false, 2.5)
	# Corner fittings. They stop the frame reading as a plain border and make the object look
	# MOUNTED — which is the same struck-metal language as the Class Power coin.
	var k := 16.0
	var corners := [
		[r.position, Vector2(1, 1)],
		[Vector2(r.end.x, r.position.y), Vector2(-1, 1)],
		[Vector2(r.position.x, r.end.y), Vector2(1, -1)],
		[r.end, Vector2(-1, -1)],
	]
	for c in corners:
		var o: Vector2 = c[0]
		var d: Vector2 = c[1]
		draw_line(o, o + Vector2(k * d.x, 0.0), TOK["brass_hi"], 3.0)
		draw_line(o, o + Vector2(0.0, k * d.y), TOK["brass_hi"], 3.0)


func _draw_op(op: Dictionary, f: Font) -> void:
	var c: Color = _col(op.get("c"), Color("4a3320"))
	match str(op.get("op", "")):
		"rect":
			var r: Array = op.get("r", [0, 0, 0, 0])
			draw_rect(Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3])), c)
		"ellipse":
			var at: Array = op.get("at", [0, 0])
			_ellipse(Vector2(float(at[0]), float(at[1])), float(op.get("rx", 10)), float(op.get("ry", 6)), c)
		"glow":
			var g: Array = op.get("at", [0, 0])
			var r0: float = float(op.get("r", 40))
			# A radial gradient is faked with stacked discs — the same trick power_orb uses.
			var k: float = 1.0
			if bool(op.get("flicker", false)):
				k = 0.86 + sin(_t * 5.3) * 0.09 + sin(_t * 11.7) * 0.05
			var ctr := Vector2(float(g[0]), float(g[1]))
			draw_circle(ctr, r0 * k, Color(c.r, c.g, c.b, 0.22))
			draw_circle(ctr, r0 * 0.62 * k, Color(c.r, c.g, c.b, 0.38))
			draw_circle(ctr, r0 * 0.30 * k, Color(c.r, c.g, c.b, 0.70))
		"line":
			var a: Array = op.get("a", [0, 0])
			var b: Array = op.get("b", [0, 0])
			draw_line(Vector2(float(a[0]), float(a[1])), Vector2(float(b[0]), float(b[1])),
				c, float(op.get("w", 2)))
		"emoji":
			if f:
				var e: Array = op.get("at", [0, 0])
				var sz: int = int(op.get("size", 28))
				draw_string(f, Vector2(float(e[0]) - sz, float(e[1]) + sz * 0.36), str(op.get("t", "")),
					HORIZONTAL_ALIGNMENT_CENTER, sz * 2.0, sz, Color.WHITE)
		"text":
			if f:
				var box: Array = op.get("r", [0, 0, 100, 20])
				var sz2: int = int(op.get("size", 15))
				draw_string(f, Vector2(float(box[0]), float(box[1]) + sz2),
					str(op.get("t", "")),
					HORIZONTAL_ALIGNMENT_CENTER if bool(op.get("center", true)) else HORIZONTAL_ALIGNMENT_LEFT,
					float(box[2]), sz2, c)


func _draw_actor(a: Dictionary, f: Font) -> void:
	var p: Vector2 = a["pos"]
	var w: Array = spec.get("wander", [286, 700, 340, 220])
	var depth: float = clampf((p.y - float(w[1])) / maxf(float(w[3]), 1.0), 0.0, 1.0)
	var sc: float = lerpf(0.88, 1.10, depth)
	_ellipse(Vector2(p.x, p.y + 3), 28.0 * sc, 8.5 * sc, Color(0, 0, 0, 0.42))
	if a["pc"]:
		# Your own dwarves are tappable, so they carry the brass edge too — curved into a miniature's
		# base, which is the shipped diorama identity rather than a rectangle drawn round a person.
		# NPCs deliberately get none: nothing happens when you tap them, so nothing should invite it.
		_ellipse_ring(Vector2(p.x, p.y + 3), 28.0 * sc, 8.5 * sc, TOK["brass"], 2.0)

	if not a["pc"]:
		# An NPC gets a name and nothing else — they carry no state, so they get no instrument panel.
		# The name does get a backing plate, because bare text lands on whatever happens to be behind
		# it: a lit window, a floor seam, the edge of a building's frame. One of those turned "Ore
		# Hauler" into "Dre Hauler".
		var nm := str(a["data"].get("name", ""))
		if f and nm != "":
			var w2: float = f.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 10.0
			draw_rect(Rect2(p.x - w2 * 0.5, p.y + 14.0, w2, 18.0), Color(0, 0, 0, 0.5))
			draw_string(f, Vector2(p.x - w2 * 0.5, p.y + 27.0), nm,
				HORIZONTAL_ALIGNMENT_CENTER, w2, 13, Color("c8b494"))
		return

	# The player's dwarf gets a COMPACT CHIP — a name and one HP pip, and nothing else. Four full
	# stat plates in a room is the "room becomes the data" failure every judge of this screen named;
	# the exact numbers live one tap away (`dwarf_tapped`), not underfoot. The bar sits UNDER the
	# figure, never over its head — the convention across every game surveyed.
	var d: Dictionary = a["data"]
	var bw: float = float(a.get("chip", CHIP_W))
	var bx: float = p.x - bw * 0.5
	var by: float = p.y + 9.0
	draw_rect(Rect2(bx, by, bw, 26), Color(0, 0, 0, 0.66))
	if f:
		draw_string(f, Vector2(bx + 3, by + 12), str(d.get("name", "")).split(" ")[0],
			HORIZONTAL_ALIGNMENT_CENTER, bw - 6, 12, Color("e3d5b4"))
	var mx: float = maxf(1.0, float(d.get("max_hp", 1)))
	var frac: float = clampf(float(d.get("hp", 1)) / mx, 0.0, 1.0)
	var tw := bw - 10.0
	draw_rect(Rect2(bx + 5, by + 16, tw, 6), Color(0, 0, 0, 0.55))
	draw_rect(Rect2(bx + 5, by + 16, tw * frac, 6),
		Color("c25b4a") if frac < 0.5 else Color("6fae72"))
	# Guard rides the SAME pip as an overlay segment, never a second bar — which is what the shipped
	# `block` field already is.
	var guard := float(d.get("block", 0))
	if guard > 0.0:
		draw_rect(Rect2(bx + 5, by + 16, tw * clampf(guard / mx, 0.0, 1.0), 6), Color("b9c2cb"))
	# Wounded is a mark on the chip, not a banner: the figure standing still already says it.
	if str(d.get("status", "ready")) == "wounded":
		draw_circle(Vector2(bx + bw - 6, by + 6), 4.5, Color("d9752a"))


## A prop carries its own parchment tag. This is what replaces the data panel: the price is ON the
## thing that sells it, so the room never needs a list beside it.
func _draw_prop(p: Dictionary, f: Font) -> void:
	var at: Array = p.get("at", [360, 600])
	var cx := float(at[0])
	var cy := float(at[1])
	var sz: int = int(p.get("size", 40))

	if f:
		draw_string(f, Vector2(cx - sz, cy + sz * 0.36), str(p.get("t", "")),
			HORIZONTAL_ALIGNMENT_CENTER, sz * 2.0, sz, Color.WHITE)

	var tx: float = cx - TAG_W * 0.5
	var ty: float = cy + sz * 0.55
	draw_rect(Rect2(tx + 3, ty + 4, TAG_W, TAG_H), Color(0, 0, 0, 0.42))
	draw_rect(Rect2(tx, ty, TAG_W, TAG_H), TOK["parch"])
	draw_rect(Rect2(tx, ty, TAG_W, TAG_H), TOK["parch_lo"], false, 2.0)
	draw_circle(Vector2(tx + 12, ty + 10), 4.0, TOK["brass_lo"])
	if not f:
		return
	draw_string(f, Vector2(tx + 8, ty + 22), str(p.get("label", "")),
		HORIZONTAL_ALIGNMENT_CENTER, TAG_W - 16, 16, TOK["gink"])
	draw_string(f, Vector2(tx + 8, ty + 42), str(p.get("sub", "")),
		HORIZONTAL_ALIGNMENT_CENTER, TAG_W - 16, 13, TOK["gink"])
	var price := str(p.get("price", ""))
	if price != "":
		draw_string(f, Vector2(tx + 8, ty + 60), price,
			HORIZONTAL_ALIGNMENT_CENTER, TAG_W - 16, 15, _col(p.get("price_c"), TOK["brass_lo"]))


func _ellipse(c: Vector2, rx: float, ry: float, col: Color) -> void:
	draw_set_transform(c, 0.0, Vector2(1.0, ry / maxf(rx, 0.001)))
	draw_circle(Vector2.ZERO, rx, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _ellipse_ring(c: Vector2, rx: float, ry: float, col: Color, w: float) -> void:
	draw_set_transform(c, 0.0, Vector2(1.0, ry / maxf(rx, 0.001)))
	draw_arc(Vector2.ZERO, rx, 0.0, TAU, 32, col, w)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ============================================================================ input
func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var m: Vector2 = (event as InputEventMouseButton).position
	# Props first: they are the reason the room exists, and their tags sit above the floor.
	for h in _hot:
		if (h["rect"] as Rect2).has_point(m):
			prop_tapped.emit(str(h["id"]), str(h["act"]))
			accept_event()
			return
	# Then a dwarf — tapping a character opens whatever that venue does with one.
	for a in actors:
		if not a["pc"]:
			continue
		var p: Vector2 = a["pos"]
		if Rect2(p.x - 44, p.y - 92, 88, 104).has_point(m):
			dwarf_tapped.emit(int(a["idx"]))
			accept_event()
			return

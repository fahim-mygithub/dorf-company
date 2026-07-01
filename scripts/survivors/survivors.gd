extends Control
## "Demon Lord MBA" — SURVIVORS MODE (zombie survival, StS-node run).
##
## A fourth peer scene (/survivors/). Reuses combat.gd + the seam WHOLESALE; NO fee-clock meta.
## The pressure is a food+water survival clock, not rent. A branching StS map (whole lap visible),
## a run-scoped party you assemble by rescuing survivors, and an endless boss-lap loop.
## Built all-in-code like overworld.gd (bare Control root). Fully separate state from the overworld.

const Db := preload("res://scripts/combat/card_db.gd")
const COMBAT_SCENE := preload("res://scenes/combat/combat.tscn")

# ============================================================ Tunable consts (spec §6)
const START_FOOD := 10
const START_WATER := 10
const FOOD_PER_NODE := 1
const WATER_PER_NODE := 1
const STARVE_DMG := 5              # per node while a meter is at 0
const FORAGE_CACHE := 4            # food OR water gained at a forage node
const COMBAT_SCRAPS := 2          # small refill on a won fight
const BOSS_STASH := 12            # big refill after a boss
const CAMP_HEAL := 6              # hp restored to each survivor at a camp
const CAMP_REFILL := 2
const LAP_SCALE := 0.25           # enemy_scale += LAP_SCALE per lap
const BOSS_BONUS := 0.4          # boss fights are extra tough
const REVIVE_FRAC := 0.25         # a downed survivor comes back at this fraction on a won fight
const MAX_PARTY := 3              # combat has 3 slots
const MAP_ROWS := 5              # row 0 = start, last row = boss
const MAX_METER := 20            # bar scale

# ============================================================ Colors
const COL_BG := Color(0.08, 0.08, 0.10)
const COL_HUD := Color(0.12, 0.12, 0.15)
const C_FOOD := Color(0.85, 0.55, 0.25)
const C_WATER := Color(0.30, 0.60, 0.90)
const C_GREEN := Color(0.30, 0.82, 0.42)
const C_AMBER := Color(0.95, 0.74, 0.20)
const C_RED := Color(0.92, 0.26, 0.26)
const C_COIN := Color(0.96, 0.82, 0.26)
const CLASS_COL := {"brute": Color(0.72, 0.42, 0.32), "medic": Color(0.35, 0.75, 0.55), "engineer": Color(0.55, 0.55, 0.80)}
const NODE_INFO := {
	"start":  {"emoji": "🚪", "name": "Entrance", "col": Color(0.30, 0.42, 0.55)},
	"combat": {"emoji": "🧟", "name": "Zombies",  "col": Color(0.42, 0.20, 0.20)},
	"forage": {"emoji": "🎒", "name": "Forage",   "col": Color(0.30, 0.34, 0.20)},
	"rescue": {"emoji": "🆘", "name": "Survivor",  "col": Color(0.20, 0.34, 0.34)},
	"event":  {"emoji": "❔", "name": "Unknown",   "col": Color(0.30, 0.26, 0.36)},
	"camp":   {"emoji": "🔥", "name": "Camp",      "col": Color(0.20, 0.30, 0.24)},
	"boss":   {"emoji": "💀", "name": "Horde",     "col": Color(0.46, 0.12, 0.12)},
}
const SURVIVOR_NAMES := ["Mara", "Cole", "Rhea", "Dex", "Nadia", "Boone", "Vale", "Iris", "Kruger", "Sana"]

# ============================================================ Run state
var food := 0
var water := 0
var lap := 1
var score := 0
var nodes_cleared := 0
var party: Array = []          # run-scoped survivors
var map: Array = []            # node dicts
var rows: Array = []           # Array of arrays of node indices
var current_node := -1
var state := ""
var run_epoch := 0
var busy := false
var loot: Array = []
var loot_pick := -1
var _next_name := 0

# ============================================================ UI refs
var screen_root: Control
var hud: Control
var overlay: ColorRect
var overlay_label: Label
var overlay_btn: Button
var msg_label: Label
var food_bar: ColorRect
var water_bar: ColorRect
var food_lbl: Label
var water_lbl: Label
var lap_lbl: Label
var party_strip: Control

# ============================================================ Lifecycle
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_chrome()
	_new_run()

# ============================================================ UI helpers
func _mklabel(text: String, pos: Vector2, sz: Vector2, font: int, parent: Node, center: bool = true, col: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font)
	l.add_theme_color_override("font_color", col)
	if center:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.position = pos
	l.size = sz
	parent.add_child(l)
	return l

func _mkemoji(center_pos: Vector2, box: Vector2, font: int, parent: Node) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.size = box
	l.position = center_pos - box * 0.5
	parent.add_child(l)
	return l

func _rect(pos: Vector2, sz: Vector2, col: Color, parent: Node) -> ColorRect:
	var r := ColorRect.new()
	r.color = col
	r.position = pos
	r.size = sz
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)
	return r

func _line(a: Vector2, b: Vector2, col: Color, parent: Node, w: float = 4.0) -> void:
	var r := ColorRect.new()
	r.color = col
	var d := b - a
	r.size = Vector2(d.length(), w)
	r.position = a
	r.pivot_offset = Vector2(0, w * 0.5)
	r.rotation = d.angle()
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)

func _msg(s: String) -> void:
	if is_instance_valid(msg_label):
		msg_label.text = s

func _btn(text: String, pos: Vector2, sz: Vector2, font: int, parent: Node, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font)
	b.position = pos
	b.size = sz
	b.pressed.connect(cb)
	parent.add_child(b)
	return b

# ============================================================ Chrome
func _build_chrome() -> void:
	_rect(Vector2.ZERO, Vector2(720, 1280), COL_BG, self)
	screen_root = Control.new()
	screen_root.size = Vector2(720, 1280)
	screen_root.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(screen_root)
	hud = Control.new()
	hud.size = Vector2(720, 150)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)
	_build_hud()
	msg_label = _mklabel("", Vector2(16, 1236), Vector2(688, 34), 15, self, false)
	overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.85)
	overlay.size = Vector2(720, 1280)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	overlay_label = Label.new()
	overlay_label.add_theme_font_size_override("font_size", 28)
	overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overlay_label.position = Vector2(60, 470)
	overlay_label.size = Vector2(600, 260)
	overlay.add_child(overlay_label)
	overlay_btn = Button.new()
	overlay_btn.text = "New Run"
	overlay_btn.add_theme_font_size_override("font_size", 22)
	overlay_btn.position = Vector2(250, 780)
	overlay_btn.size = Vector2(220, 64)
	overlay_btn.pressed.connect(_new_run)
	overlay.add_child(overlay_btn)
	overlay.visible = false

func _build_hud() -> void:
	_rect(Vector2.ZERO, Vector2(720, 150), COL_HUD, hud)
	_rect(Vector2(0, 148), Vector2(720, 2), Color(1, 1, 1, 0.08), hud)
	_mkemoji(Vector2(40, 44), Vector2(50, 46), 30, hud).text = "🍖"
	_rect(Vector2(70, 32), Vector2(220, 22), Color(0.25, 0.2, 0.15), hud)
	food_bar = _rect(Vector2(70, 32), Vector2(220, 22), C_FOOD, hud)
	food_lbl = _mklabel("", Vector2(70, 32), Vector2(220, 22), 15, hud)
	_mkemoji(Vector2(40, 96), Vector2(50, 46), 30, hud).text = "💧"
	_rect(Vector2(70, 84), Vector2(220, 22), Color(0.15, 0.2, 0.28), hud)
	water_bar = _rect(Vector2(70, 84), Vector2(220, 22), C_WATER, hud)
	water_lbl = _mklabel("", Vector2(70, 84), Vector2(220, 22), 15, hud)
	lap_lbl = _mklabel("", Vector2(360, 30), Vector2(340, 30), 22, hud, false)
	lap_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	party_strip = Control.new()
	party_strip.position = Vector2(320, 74)
	party_strip.size = Vector2(384, 70)
	party_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(party_strip)

func _refresh_hud() -> void:
	if not is_instance_valid(food_bar):
		return
	food_bar.size = Vector2(220.0 * clampf(float(food) / float(MAX_METER), 0.0, 1.0), 22)
	food_bar.color = C_FOOD if food > 3 else C_RED
	food_lbl.text = "%d" % food
	water_bar.size = Vector2(220.0 * clampf(float(water) / float(MAX_METER), 0.0, 1.0), 22)
	water_bar.color = C_WATER if water > 3 else C_RED
	water_lbl.text = "%d" % water
	lap_lbl.text = "Lap %d   ·   %d pts" % [lap, _score_now()]
	for c in party_strip.get_children():
		c.queue_free()
	var living := _living_survivors()
	for i in range(living.size()):
		var s: Dictionary = living[i]
		var cx := 32 + i * 66
		_mkemoji(Vector2(cx, 20), Vector2(52, 42), 26, party_strip).text = Db.CLASSES[s["cls"]]["emoji"]
		var frac := clampf(float(s["hp"]) / float(s["max_hp"]), 0.0, 1.0)
		_rect(Vector2(cx - 24, 44), Vector2(48, 7), Color(0.25, 0.25, 0.3), party_strip)
		_rect(Vector2(cx - 24, 44), Vector2(48 * frac, 7), C_GREEN if frac > 0.5 else C_AMBER, party_strip)

# ============================================================ Run setup / class select
func _new_run() -> void:
	run_epoch += 1
	busy = false
	food = START_FOOD
	water = START_WATER
	lap = 1
	score = 0
	nodes_cleared = 0
	party = []
	_next_name = 0
	overlay.visible = false
	screen_root.visible = true   # a prior combat may have left the board hidden on an epoch-mismatch return
	hud.visible = true
	state = "PICK"
	_clear_screen()
	_build_pick_class()
	_refresh_hud()

func _clear_screen() -> void:
	for c in screen_root.get_children():
		c.queue_free()

func _new_name() -> String:
	var n: String = SURVIVOR_NAMES[_next_name % SURVIVOR_NAMES.size()]
	_next_name += 1
	return n

func _make_survivor(cls: String) -> Dictionary:
	var mh: int = int(Db.CLASSES[cls]["max_hp"])
	return {"name": _new_name(), "cls": cls, "status": "ready", "hp": mh, "max_hp": mh,
		"deck": (Db.CLASSES[cls]["deck"] as Array).duplicate()}

func _build_pick_class() -> void:
	_mklabel("— SURVIVORS —", Vector2(0, 210), Vector2(720, 34), 28, screen_root)
	_mklabel("The dead walk. Pick your first survivor.", Vector2(0, 256), Vector2(720, 22), 15, screen_root, true, Color(0.8, 0.8, 0.85))
	var cls_list := Db.SURVIVOR_ORDER
	var roles := {"brute": "Tank — soak hits, pull the horde", "medic": "Support — heal, patch, revive", "engineer": "DPS — bombs, traps, AoE"}
	for i in range(cls_list.size()):
		var cls: String = cls_list[i]
		var cx := 130 + i * 230
		var card := Control.new()
		card.position = Vector2(cx - 100, 420)
		card.size = Vector2(200, 320)
		card.mouse_filter = Control.MOUSE_FILTER_STOP
		card.gui_input.connect(_on_pick_input.bind(cls))
		screen_root.add_child(card)
		var col: Color = CLASS_COL[cls]
		_rect(Vector2.ZERO, Vector2(200, 320), Color(col.r, col.g, col.b, 0.22), card)
		_mkemoji(Vector2(100, 90), Vector2(140, 100), 58, card).text = Db.CLASSES[cls]["emoji"]
		_mklabel(Db.CLASSES[cls]["name"], Vector2(0, 170), Vector2(200, 26), 20, card)
		_mklabel(roles[cls], Vector2(10, 210), Vector2(180, 90), 13, card, true, Color(0.82, 0.82, 0.88))
		_mklabel("tap to start", Vector2(0, 288), Vector2(200, 20), 13, card, true, C_GREEN)

func _on_pick_input(event: InputEvent, cls: String) -> void:
	if state != "PICK":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		party = [_make_survivor(cls)]
		_start_lap()

# ============================================================ Map generation (StS DAG)
func _start_lap() -> void:
	_gen_map()
	state = "MAP"
	busy = false
	_msg("Lap %d — pick a path. Food and water drop each step." % lap)
	_clear_screen()
	_build_map()
	_refresh_hud()

func _roll_node_type() -> String:
	var r := randf()
	if r < 0.35: return "combat"
	elif r < 0.58: return "forage"
	elif r < 0.72: return "event"
	elif r < 0.85: return "camp"
	return "rescue"

func _gen_map() -> void:
	map = []
	rows = []
	for r in range(MAP_ROWS):
		var n: int = 1 if (r == 0 or r == MAP_ROWS - 1) else (2 + randi() % 2)
		var row_idx: Array = []
		for cc in range(n):
			var ntype := "start"
			if r == MAP_ROWS - 1:
				ntype = "boss"
			elif r > 0:
				ntype = _roll_node_type()
			map.append({"type": ntype, "row": r, "col": cc, "n": n, "links": [], "resolved": r == 0})
			row_idx.append(map.size() - 1)
		rows.append(row_idx)
	# guarantee at least one forage and one rescue among the middle rows
	_guarantee_type("forage")
	_guarantee_type("rescue")
	# edges: connect each row to the next (column-proximity DAG, full coverage)
	for r in range(MAP_ROWS - 1):
		var cur: Array = rows[r]
		var nxt: Array = rows[r + 1]
		for i in range(cur.size()):
			var frac := 0.5 if cur.size() == 1 else float(i) / float(cur.size() - 1)
			var tj := int(round(frac * float(nxt.size() - 1)))
			_link(cur[i], nxt[tj])
			if nxt.size() > 1 and randf() < 0.45:
				var alt := clampi(tj + (1 if randf() < 0.5 else -1), 0, nxt.size() - 1)
				_link(cur[i], nxt[alt])
		for j in range(nxt.size()):     # coverage: every next node needs a parent
			var has_parent := false
			for i in range(cur.size()):
				if map[cur[i]]["links"].has(nxt[j]):
					has_parent = true
			if not has_parent:
				var frac2 := 0.5 if nxt.size() == 1 else float(j) / float(nxt.size() - 1)
				var ci := int(round(frac2 * float(cur.size() - 1)))
				_link(cur[ci], nxt[j])
	current_node = rows[0][0]

func _link(a: int, b: int) -> void:
	if not map[a]["links"].has(b):
		map[a]["links"].append(b)

func _guarantee_type(t: String) -> void:
	for k in map:
		if k["type"] == t:
			return
	# convert a random middle node
	var mids: Array = []
	for r in range(1, MAP_ROWS - 1):
		for idx in rows[r]:
			mids.append(idx)
	if not mids.is_empty():
		mids.shuffle()
		map[mids[0]]["type"] = t

func _node_px(idx: int) -> Vector2:
	var node: Dictionary = map[idx]
	var r: int = int(node["row"])
	var n: int = int(node["n"])
	var col: int = int(node["col"])
	var x := 360.0 + (float(col) - float(n - 1) / 2.0) * 150.0
	var y := 300.0 + float(r) * 148.0
	return Vector2(x, y)

# ============================================================ Map render
func _build_map() -> void:
	_mklabel("— THE MAP —", Vector2(0, 168), Vector2(720, 24), 18, screen_root)
	_mklabel("Whole lap in view. Route toward forage & rescues; the horde 💀 waits below.", Vector2(0, 196), Vector2(720, 18), 12, screen_root, true, Color(0.7, 0.7, 0.75))
	# edges first (behind nodes)
	for i in range(map.size()):
		for j in map[i]["links"]:
			var reachable: bool = i == current_node
			_line(_node_px(i), _node_px(j), C_AMBER if reachable else Color(0.3, 0.3, 0.36), screen_root, 4.0 if reachable else 3.0)
	for i in range(map.size()):
		_build_node(i)
	_mklabel("survivors: %d / %d" % [_living_survivors().size(), MAX_PARTY], Vector2(0, 1194), Vector2(720, 20), 13, screen_root, true, Color(0.8, 0.8, 0.85))

func _build_node(idx: int) -> void:
	var node: Dictionary = map[idx]
	var info: Dictionary = NODE_INFO[node["type"]]
	var px := _node_px(idx)
	var sz := Vector2(74, 74)
	var cur: bool = idx == current_node
	var reachable: bool = map[current_node]["links"].has(idx)
	var node_ctrl := Control.new()
	node_ctrl.position = px - sz * 0.5
	node_ctrl.size = sz
	node_ctrl.mouse_filter = Control.MOUSE_FILTER_STOP if reachable else Control.MOUSE_FILTER_IGNORE
	if reachable:
		node_ctrl.gui_input.connect(_on_node_input.bind(idx))
	screen_root.add_child(node_ctrl)
	if cur:
		_rect(Vector2(-4, -4), sz + Vector2(8, 8), C_GREEN, node_ctrl)
	elif reachable:
		_rect(Vector2(-3, -3), sz + Vector2(6, 6), C_AMBER, node_ctrl)
	var bg: Color = info["col"]
	if bool(node["resolved"]) and not cur:
		bg = Color(bg.r * 0.5, bg.g * 0.5, bg.b * 0.5)
	_rect(Vector2.ZERO, sz, bg, node_ctrl)
	_mkemoji(sz * 0.5, sz, 34, node_ctrl).text = ("🧍" if cur else info["emoji"])

func _on_node_input(event: InputEvent, idx: int) -> void:
	if busy or state != "MAP":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if map[current_node]["links"].has(idx):
			await _enter_node(idx)

# ============================================================ Node entry + survival
func _enter_node(idx: int) -> void:
	busy = true
	var e := run_epoch
	current_node = idx
	var node: Dictionary = map[idx]
	nodes_cleared += 1
	food = maxi(0, food - FOOD_PER_NODE)     # depletion (spec §4)
	water = maxi(0, water - WATER_PER_NODE)
	if food <= 0 or water <= 0:
		_starve()
		_refresh_hud()
		if _living_survivors().is_empty():
			_game_over("starved")
			return
	match node["type"]:
		"boss":
			await _node_boss(e)
			return
		"combat":
			_msg("The dead close in!")
			await _node_combat(e, false)   # handles its own reward / resume / game-over — never fall through
			return
		"forage":
			_open_forage(e)
			return
		"rescue":
			_node_rescue(e)
			return
		"event":
			_open_event(e)
			return
		"camp":
			_node_camp(e)
			return
		_:
			pass
	_resume_map(e)

func _starve() -> void:
	var low := _lowest_hp_survivor()
	if low.is_empty():
		return
	low["hp"] = maxi(0, int(low["hp"]) - STARVE_DMG)
	if int(low["hp"]) <= 0:
		low["status"] = "lost"
		_msg("%s starved. The horde takes them." % low["name"])
	else:
		_msg("Starving! %s loses %d HP — find a cache." % [low["name"], STARVE_DMG])

func _resume_map(e: int) -> void:
	if e != run_epoch:
		return
	if _living_survivors().is_empty():
		_game_over("overrun")
		return
	busy = false
	state = "MAP"
	_clear_screen()
	_build_map()
	_refresh_hud()

func _living_survivors() -> Array:
	var out: Array = []
	for s in party:
		if s["status"] != "lost" and int(s["hp"]) > 0:
			out.append(s)
	return out

func _lowest_hp_survivor() -> Dictionary:
	var best: Dictionary = {}
	for s in party:
		if s["status"] == "lost" or int(s["hp"]) <= 0:
			continue
		if best.is_empty() or int(s["hp"]) < int(best["hp"]):
			best = s
	return best

# ============================================================ Combat via the seam
func _build_combat_units() -> Array:
	var units: Array = []
	for s in _living_survivors():
		if units.size() < MAX_PARTY:
			units.append(s)
	while units.size() < MAX_PARTY:
		units.append(null)   # pad -> a benched slot
	return units

func _node_combat(e: int, is_boss: bool) -> void:
	var units := _build_combat_units()
	var specs: Array = []
	for u in units:
		if u == null:
			specs.append({"cls": "brute", "name": "—", "hp": 0, "max_hp": 1, "deck": []})
		else:
			specs.append({"cls": u["cls"], "name": u["name"], "hp": int(u["hp"]), "max_hp": int(u["max_hp"]), "deck": u["deck"]})
	var fight = COMBAT_SCENE.instantiate()
	var enc: Array = Db.SURVIVOR_BOSS if is_boss else Db.SURVIVOR_ENCOUNTER
	var escale: float = 1.0 + float(lap - 1) * LAP_SCALE + (BOSS_BONUS if is_boss else 0.0)
	fight.request = {"crew": specs, "enemies": enc, "enemy_scale": escale}   # BEFORE add_child
	screen_root.visible = false
	hud.visible = false
	add_child(fight)
	var result: Dictionary = await fight.combat_finished
	if e != run_epoch:
		if is_instance_valid(fight):
			fight.queue_free()
		return
	fight.queue_free()
	screen_root.visible = true
	hud.visible = true
	var crew_results: Array = result["crew_results"]
	for i in range(crew_results.size()):
		if i >= units.size() or units[i] == null:
			continue
		var cr: Dictionary = crew_results[i]
		units[i]["hp"] = maxi(0, int(cr["hp_end"]))
	if not result["success"]:
		_game_over("overrun")
		return
	_revive_downed()            # teammates patch up the fallen after a win
	food += COMBAT_SCRAPS
	water += COMBAT_SCRAPS
	_msg("Cleared! Scraps: +%d food/water." % COMBAT_SCRAPS)
	if randf() < 0.55:
		_open_reward(e)
		return
	_resume_map(e)

func _revive_downed() -> void:
	for s in party:
		if s["status"] != "lost" and int(s["hp"]) <= 0:
			s["hp"] = maxi(1, int(round(float(s["max_hp"]) * REVIVE_FRAC)))

# ============================================================ Boss + lap transition
func _node_boss(e: int) -> void:
	_msg("The horde! Hold the line.")
	await _node_combat_boss(e)

func _node_combat_boss(e: int) -> void:
	var units := _build_combat_units()
	var specs: Array = []
	for u in units:
		if u == null:
			specs.append({"cls": "brute", "name": "—", "hp": 0, "max_hp": 1, "deck": []})
		else:
			specs.append({"cls": u["cls"], "name": u["name"], "hp": int(u["hp"]), "max_hp": int(u["max_hp"]), "deck": u["deck"]})
	var fight = COMBAT_SCENE.instantiate()
	var escale: float = 1.0 + float(lap - 1) * LAP_SCALE + BOSS_BONUS
	fight.request = {"crew": specs, "enemies": Db.SURVIVOR_BOSS, "enemy_scale": escale}
	screen_root.visible = false
	hud.visible = false
	add_child(fight)
	var result: Dictionary = await fight.combat_finished
	if e != run_epoch:
		if is_instance_valid(fight):
			fight.queue_free()
		return
	fight.queue_free()
	screen_root.visible = true
	hud.visible = true
	var crew_results: Array = result["crew_results"]
	for i in range(crew_results.size()):
		if i >= units.size() or units[i] == null:
			continue
		units[i]["hp"] = maxi(0, int(crew_results[i]["hp_end"]))
	if not result["success"]:
		_game_over("overrun")
		return
	_revive_downed()
	food += BOSS_STASH          # BIG STASH — arrive empty, leave topped up
	water += BOSS_STASH
	score += lap * 20
	lap += 1
	_msg("Horde broken! Big stash: +%d food/water. Lap %d awaits." % [BOSS_STASH, lap])
	_open_reward(e)             # guaranteed reward, then the next (harder) lap

# ============================================================ Forage / Camp / Rescue / Event
func _open_forage(_e: int) -> void:
	state = "FORAGE"
	_clear_screen()
	_mklabel("— FORAGE —", Vector2(0, 300), Vector2(720, 28), 24, screen_root)
	_mklabel("A ransacked store. Grab what you can carry.", Vector2(0, 348), Vector2(720, 22), 15, screen_root, true, Color(0.85, 0.85, 0.9))
	_btn("🍖 Food\n+%d" % FORAGE_CACHE, Vector2(90, 560), Vector2(240, 130), 20, screen_root, _on_forage.bind("food"))
	_btn("💧 Water\n+%d" % FORAGE_CACHE, Vector2(390, 560), Vector2(240, 130), 20, screen_root, _on_forage.bind("water"))
	_refresh_hud()

func _on_forage(which: String) -> void:
	if state != "FORAGE":
		return
	var e := run_epoch
	state = "MAP"
	if which == "food":
		food += FORAGE_CACHE
		_msg("Scavenged +%d food." % FORAGE_CACHE)
	else:
		water += FORAGE_CACHE
		_msg("Scavenged +%d water." % FORAGE_CACHE)
	_resume_map(e)

func _node_camp(e: int) -> void:
	for s in _living_survivors():
		s["hp"] = mini(int(s["max_hp"]), int(s["hp"]) + CAMP_HEAL)
	food += CAMP_REFILL
	water += CAMP_REFILL
	_msg("A safe camp. Party heals %d; +%d food/water." % [CAMP_HEAL, CAMP_REFILL])
	_resume_map(e)

func _node_rescue(e: int) -> void:
	if _living_survivors().size() >= MAX_PARTY:
		# party full -> the survivor shares supplies instead
		food += 3
		water += 3
		_msg("A survivor shares their stash (+3 food/water) — your party is full.")
		_resume_map(e)
		return
	# rescue a survivor of a class you're missing (else random)
	var have := {}
	for s in _living_survivors():
		have[s["cls"]] = true
	var pool: Array = []
	for cls in Db.SURVIVOR_ORDER:
		if not have.has(cls):
			pool.append(cls)
	if pool.is_empty():
		pool = Db.SURVIVOR_ORDER.duplicate()
	var pick: String = pool[randi() % pool.size()]
	var newbie := _make_survivor(pick)
	party.append(newbie)
	_msg("%s the %s joins your party!" % [newbie["name"], Db.CLASSES[pick]["name"]])
	_resume_map(e)

func _open_event(_e: int) -> void:
	state = "EVENT"
	_clear_screen()
	_mklabel("— A NOISE —", Vector2(0, 300), Vector2(720, 28), 24, screen_root)
	_mklabel("Something moves in the dark. Investigate?", Vector2(0, 348), Vector2(720, 22), 15, screen_root, true, Color(0.85, 0.85, 0.9))
	_btn("🚶 Move on\n(safe +2 food)", Vector2(90, 560), Vector2(240, 130), 18, screen_root, _on_event.bind(false))
	_btn("🔦 Investigate\n(risk)", Vector2(390, 560), Vector2(240, 130), 18, screen_root, _on_event.bind(true))
	_refresh_hud()

func _on_event(risky: bool) -> void:
	if state != "EVENT":
		return
	var e := run_epoch
	state = "MAP"
	if not risky:
		food += 2
		_msg("You slip past. +2 food.")
		_resume_map(e)
		return
	var roll := randf()
	if roll < 0.5:
		food += 5
		water += 5
		_msg("A stocked bunker! +5 food/water.")
		_resume_map(e)
	elif roll < 0.8:
		_open_reward(e)
	else:
		var low := _lowest_hp_survivor()
		if not low.is_empty():
			var dmg := int(int(low["max_hp"]) * 0.4)
			low["hp"] = maxi(0, int(low["hp"]) - dmg)
			if int(low["hp"]) <= 0:
				low["status"] = "lost"
			_msg("An ambush! %s takes %d." % [low["name"], dmg])
		_resume_map(e)

# ============================================================ Card reward
func _roll_reward() -> Array:
	var pool: Array = Db.SURVIVORS_REWARD_POOL.duplicate()
	var seen := {}
	for s in _living_survivors():
		seen[s["cls"]] = true
	for cls in seen:
		for cid in Db.SURVIVOR_CLASS_REWARDS.get(cls, []):
			pool.append(cid)
	pool.shuffle()
	var out: Array = []
	for cid in pool:
		if not out.has(cid):
			out.append(cid)
		if out.size() >= 3:
			break
	return out

func _open_reward(_e: int) -> void:
	loot = _roll_reward()
	loot_pick = -1
	state = "REWARD"
	_clear_screen()
	_build_reward()
	_refresh_hud()

func _build_reward() -> void:
	_mklabel("— SUPPLIES —", Vector2(0, 190), Vector2(720, 28), 22, screen_root)
	_mklabel("A card for the party — pick it, then who learns it.", Vector2(0, 228), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
	var xs := [40, 268, 496]
	for i in range(loot.size()):
		_build_reward_card(i, xs[i])
	_mklabel("give to:", Vector2(0, 720), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
	var living := _living_survivors()
	var n := living.size()
	var startx := 360 - (n - 1) * 100
	for j in range(n):
		_build_reward_target(living[j], startx + j * 200, 820)
	_btn("Leave it", Vector2(285, 1150), Vector2(150, 62), 18, screen_root, _on_reward_skip)

func _build_reward_card(i: int, x: int) -> void:
	var cid: String = loot[i]
	var def: Dictionary = Db.CARDS[cid]
	var sel: bool = i == loot_pick
	var card := Control.new()
	card.position = Vector2(x, 300 if not sel else 288)
	card.size = Vector2(184, 300)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(_on_reward_card.bind(i))
	screen_root.add_child(card)
	if sel:
		_rect(Vector2(-3, -3), Vector2(190, 306), C_GREEN, card)
	_rect(Vector2.ZERO, Vector2(184, 300), Db.type_tint(def.get("type", "skill")), card)
	_rect(Vector2(8, 8), Vector2(40, 40), C_COIN, card)
	_mklabel(str(int(def["cost"])), Vector2(8, 14), Vector2(40, 28), 22, card, true, Color(0.1, 0.1, 0.1))
	_mkemoji(Vector2(92, 84), Vector2(100, 76), 46, card).text = def.get("emoji", "🃏")
	_mklabel(def["name"], Vector2(4, 138), Vector2(176, 26), 18, card)
	var body: Dictionary = Db.describe(def, null, 0, 0)
	_mklabel(body["text"], Vector2(8, 178), Vector2(168, 114), 13, card, true, Color(0.9, 0.9, 0.92))

func _build_reward_target(d: Dictionary, cx: int, cy: int) -> void:
	var col: Color = CLASS_COL[d["cls"]]
	var tok := Control.new()
	tok.position = Vector2(cx - 70, cy - 60)
	tok.size = Vector2(140, 190)
	tok.mouse_filter = Control.MOUSE_FILTER_STOP
	tok.gui_input.connect(_on_reward_target.bind(d))
	screen_root.add_child(tok)
	_rect(Vector2.ZERO, Vector2(140, 190), Color(col.r, col.g, col.b, 0.18), tok)
	_mkemoji(Vector2(70, 50), Vector2(110, 80), 50, tok).text = Db.CLASSES[d["cls"]]["emoji"]
	_mklabel(d["name"], Vector2(0, 100), Vector2(140, 22), 15, tok)
	_mklabel("🃏 %d cards" % int(d["deck"].size()), Vector2(0, 126), Vector2(140, 16), 11, tok, true, Color(0.82, 0.78, 0.55))

func _on_reward_card(event: InputEvent, i: int) -> void:
	if state != "REWARD":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		loot_pick = i
		_msg("%s — now tap who learns it." % Db.CARDS[loot[i]]["name"])
		_clear_screen()
		_build_reward()

func _on_reward_target(event: InputEvent, d: Dictionary) -> void:
	if state != "REWARD":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if loot_pick < 0:
			_msg("Pick a card first.")
			return
		var cid: String = loot[loot_pick]
		d["deck"].append(cid)
		_msg("%s learned %s." % [d["name"], Db.CARDS[cid]["name"]])
		loot = []
		loot_pick = -1
		_after_reward()

func _on_reward_skip() -> void:
	if state != "REWARD":
		return
	loot = []
	loot_pick = -1
	_msg("Left it behind.")
	_after_reward()

## A reward taken at a boss node advances the lap; otherwise back to the map.
func _after_reward() -> void:
	var e := run_epoch
	if map[current_node]["type"] == "boss":
		_start_lap()
	else:
		_resume_map(e)

# ============================================================ Score / game over
func _score_now() -> int:
	return score + nodes_cleared + _living_survivors().size() * 5

func _game_over(reason: String) -> void:
	busy = false
	state = "OVER"
	score = _score_now()
	_clear_screen()
	var msg := ""
	match reason:
		"starved":
			msg = "STARVED OUT\nThe last of your party succumbed."
		"overrun":
			msg = "OVERRUN\nThe horde took everyone."
		_:
			msg = "RUN OVER"
	msg += "\n\nReached Lap %d\n%d points" % [lap, score]
	overlay_label.text = msg
	overlay_btn.text = "New Run"
	overlay.visible = true
	_refresh_hud()

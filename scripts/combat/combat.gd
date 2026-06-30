extends Control

## "Demon Lord MBA" — mobile party combat (portrait 720x1280).
## Party of 3 dwarves (Warrior/Sorcerer/Paladin), each its own class + deck.
## 1 boss + 4 minions. Unified initiative: every combatant rolls once at start,
## a single interleaved order persists for the whole combat. Data-driven cards via
## card_db.gd (preloaded as Db). Reuses the [op,...] resolver, block-then-hp damage,
## draw/reshuffle, win/lose overlay and Play Again from the original single-dwarf build.

const Db := preload("res://scripts/combat/card_db.gd")
const MOMENTUM_HIT := preload("res://scenes/vfx/momentum_hit.tscn")
const Card := preload("res://scripts/ui/card.gd")

const DWARF_CLASSES := ["warrior", "sorcerer", "paladin"]
const DWARF_HP := 30
const HAND_SIZE := 5
const START_ENERGY := 3

# ---------------------------------------------------------------- State
var combatants: Array = []        # dicts: 0..2 dwarves, 3..7 enemies
var order: Array = []             # combatant indices, initiative DESC
var turn_ptr: int = -1
var round_num: int = 1
var phase: String = ""
var selected_card_index: int = -1
var active_dwarf = null           # the dwarf dict whose turn it is

# ---------------------------------------------------------------- UI refs
var init_box: HBoxContainer

# enemy slots (0 = boss, 1..4 = minions); parallel to combatants[3 + slot]
var enemy_emoji: Array = []
var enemy_hp: Array = []
var enemy_block: Array = []
var enemy_intent: Array = []
var enemy_name: Array = []

# dwarf slots (0..2); parallel to combatants[slot]
var dwarf_emoji: Array = []
var dwarf_hp: Array = []
var dwarf_block: Array = []
var dwarf_res: Array = []
var dwarf_outline: Array = []

var active_name_label: Label
var active_energy_label: Label
var active_res_label: Label

var hand_box: Control
var end_turn_btn: Button
var log_label: Label

var overlay: ColorRect
var overlay_label: Label
var overlay_btn: Button
var reticle_tex: ImageTexture

# ================================================================ Lifecycle
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	reticle_tex = _make_reticle()
	_build_ui()
	_start_combat()

# ================================================================ UI helpers
func _label2(text: String, pos: Vector2, sz: Vector2, font: int = 14, center: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font)
	if center:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.position = pos
	l.size = sz
	add_child(l)
	return l

func _emoji_label(center_pos: Vector2, box: Vector2, font: int, tappable: bool) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_STOP if tappable else Control.MOUSE_FILTER_IGNORE
	l.size = box
	l.position = center_pos - box * 0.5
	l.pivot_offset = box * 0.5
	add_child(l)
	return l

# ================================================================ UI build
func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.10, 0.13)
	bg.position = Vector2.ZERO
	bg.size = Vector2(720, 1280)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# --- Initiative track (top) ---
	init_box = HBoxContainer.new()
	init_box.add_theme_constant_override("separation", 4)
	init_box.position = Vector2(20, 14)
	init_box.size = Vector2(680, 48)
	init_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(init_box)

	# --- Boss (centered) + 4 minions ---
	_build_enemy_slot(Vector2(360, 150), 64, true)    # slot 0 = boss
	_build_enemy_slot(Vector2(110, 300), 40, false)   # slot 1
	_build_enemy_slot(Vector2(260, 300), 40, false)   # slot 2
	_build_enemy_slot(Vector2(460, 300), 40, false)   # slot 3
	_build_enemy_slot(Vector2(610, 300), 40, false)   # slot 4

	# --- 3 dwarves ---
	_build_dwarf_slot(Vector2(170, 720), 52)
	_build_dwarf_slot(Vector2(360, 720), 52)
	_build_dwarf_slot(Vector2(550, 720), 52)

	# --- Active dwarf panel ---
	active_name_label = _label2("", Vector2(20, 838), Vector2(400, 26), 19)
	active_energy_label = _label2("", Vector2(20, 866), Vector2(300, 24), 17)
	active_res_label = _label2("", Vector2(330, 866), Vector2(370, 24), 17)

	# --- Hand (manual arc layout; cards self-fan & hover-lift) ---
	hand_box = Control.new()
	hand_box.position = Vector2(0, 905)
	hand_box.size = Vector2(720, 220)
	hand_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hand_box)

	# --- End Turn ---
	end_turn_btn = Button.new()
	end_turn_btn.text = "End Turn"
	end_turn_btn.add_theme_font_size_override("font_size", 20)
	end_turn_btn.position = Vector2(540, 1180)
	end_turn_btn.size = Vector2(160, 52)
	end_turn_btn.pressed.connect(_on_end_turn)
	add_child(end_turn_btn)

	# --- Log ---
	log_label = _label2("", Vector2(16, 1232), Vector2(688, 36), 15)

	# --- Win/lose overlay ---
	overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.8)
	overlay.position = Vector2.ZERO
	overlay.size = Vector2(720, 1280)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	overlay_label = Label.new()
	overlay_label.add_theme_font_size_override("font_size", 30)
	overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overlay_label.position = Vector2(40, 520)
	overlay_label.size = Vector2(640, 140)
	overlay.add_child(overlay_label)
	overlay_btn = Button.new()
	overlay_btn.text = "Play Again"
	overlay_btn.add_theme_font_size_override("font_size", 22)
	overlay_btn.position = Vector2(260, 690)
	overlay_btn.size = Vector2(200, 60)
	overlay_btn.pressed.connect(_on_overlay_btn)
	overlay.add_child(overlay_btn)
	overlay.visible = false

func _build_enemy_slot(pos: Vector2, font: int, big: bool) -> void:
	var slot: int = enemy_emoji.size()
	var box := Vector2(130 if big else 90, font + 24)
	var e := _emoji_label(pos, box, font, true)
	e.gui_input.connect(_on_enemy_gui_input.bind(slot))
	enemy_emoji.append(e)

	var nm := _label2("", Vector2(pos.x - 70, pos.y - box.y * 0.5 - 48), Vector2(140, 22), 14, true)
	nm.visible = big
	enemy_name.append(nm)
	var intent := _label2("", Vector2(pos.x - 70, pos.y - box.y * 0.5 - 26), Vector2(140, 24), 20 if big else 16, true)
	enemy_intent.append(intent)
	var hp := _label2("", Vector2(pos.x - 70, pos.y + box.y * 0.5 + 2), Vector2(140, 22), 18 if big else 13, true)
	enemy_hp.append(hp)
	var blk := _label2("", Vector2(pos.x - 70, pos.y + box.y * 0.5 + 22), Vector2(140, 20), 15 if big else 12, true)
	enemy_block.append(blk)

func _build_dwarf_slot(pos: Vector2, font: int) -> void:
	var o := ColorRect.new()
	o.color = Color(1.0, 0.85, 0.2, 0.16)
	o.position = pos - Vector2(62, 70)
	o.size = Vector2(124, 160)
	o.mouse_filter = Control.MOUSE_FILTER_IGNORE
	o.visible = false
	add_child(o)
	dwarf_outline.append(o)

	var box := Vector2(110, font + 20)
	var e := _emoji_label(pos, box, font, false)
	dwarf_emoji.append(e)

	var hp := _label2("", Vector2(pos.x - 70, pos.y + box.y * 0.5 + 2), Vector2(140, 22), 16, true)
	dwarf_hp.append(hp)
	var blk := _label2("", Vector2(pos.x - 70, pos.y + box.y * 0.5 + 22), Vector2(140, 20), 14, true)
	dwarf_block.append(blk)
	var res := _label2("", Vector2(pos.x - 75, pos.y + box.y * 0.5 + 42), Vector2(150, 20), 13, true)
	dwarf_res.append(res)

# ================================================================ Combat start
func _start_combat() -> void:
	combatants = []

	# Dwarves (one per class), fixed to slots 0..2.
	for slot: int in range(DWARF_CLASSES.size()):
		var cid: String = DWARF_CLASSES[slot]
		var cls: Dictionary = Db.CLASSES[cid]
		var deck: Array = (cls["deck"] as Array).duplicate()
		deck.shuffle()
		var d := {
			"kind": "dwarf",
			"name": cls["name"],
			"emoji": cls["emoji"],
			"hp": DWARF_HP, "max_hp": DWARF_HP,
			"block": 0, "alive": true, "init": 0,
			"node": dwarf_emoji[slot],
			"slot": slot,
			"class_id": cid,
			"resource": 0, "resource_name": cls["resource"],
			"deck": deck, "hand": [], "discard": [],
			"energy": START_ENERGY, "powers": {}, "statuses": {},
		}
		combatants.append(d)

	# Enemies from ENCOUNTER, fixed to slots 0..4.
	for slot: int in range(Db.ENCOUNTER.size()):
		var eid: String = Db.ENCOUNTER[slot]
		var ed: Dictionary = Db.ENEMIES[eid]
		var intents: Array = ed["intents"]
		var e := {
			"kind": "enemy",
			"name": ed["name"],
			"emoji": ed["emoji"],
			"hp": ed["max_hp"], "max_hp": ed["max_hp"],
			"block": 0, "alive": true, "init": 0,
			"node": enemy_emoji[slot],
			"slot": slot,
			"enemy_id": eid,
			"intent_index": 0,
			"intent": intents[0],
			"statuses": {},
		}
		combatants.append(e)

	# Roll unified initiative once per combat.
	for c: Dictionary in combatants:
		c["init"] = randi_range(1, 20)

	order = []
	for i: int in range(combatants.size()):
		order.append(i)
	order.sort_custom(_init_sort)

	round_num = 1
	turn_ptr = -1
	phase = ""
	selected_card_index = -1
	active_dwarf = null

	# Reset visuals on the persistent slot nodes.
	for c: Dictionary in combatants:
		var n: Label = c["node"]
		n.text = c["emoji"]
		n.visible = true
		n.modulate = Color(1, 1, 1, 1)
		n.scale = Vector2.ONE
	for slot: int in range(enemy_name.size()):
		enemy_name[slot].text = combatants[3 + slot]["name"]

	end_turn_btn.disabled = true
	overlay.visible = false
	_log("Initiative rolled. The quarterly raid begins.")
	_advance_turn()

func _init_sort(a: int, b: int) -> bool:
	var ca: Dictionary = combatants[a]
	var cb: Dictionary = combatants[b]
	if ca["init"] != cb["init"]:
		return ca["init"] > cb["init"]
	var a_dwarf: bool = ca["kind"] == "dwarf"
	var b_dwarf: bool = cb["kind"] == "dwarf"
	if a_dwarf != b_dwarf:
		return a_dwarf            # dwarves before enemies on ties
	return a < b                  # then lower index first

# ================================================================ Turn flow
func _advance_turn() -> void:
	var guard: int = 0
	var limit: int = order.size() * 2 + 4
	while true:
		if phase == "win" or phase == "lose":
			return
		guard += 1
		if guard > limit:
			return
		turn_ptr += 1
		if turn_ptr >= order.size():
			turn_ptr = 0
			round_num += 1
		var c: Dictionary = combatants[order[turn_ptr]]
		if not c["alive"]:
			continue
		if c["kind"] == "dwarf":
			_begin_dwarf_turn(c)
			_refresh()
			return
		else:
			await _enemy_turn(c)
			_refresh()
			if phase == "win" or phase == "lose":
				return
			# fall through to next combatant in the same loop

func _begin_dwarf_turn(d: Dictionary) -> void:
	active_dwarf = d
	d["block"] = 0
	d["energy"] = START_ENERGY
	# Persistent powers (e.g. Aura of Resolve).
	var per_turn: int = d["powers"].get("resource_per_turn", 0)
	if per_turn > 0:
		d["resource"] += per_turn
	_draw_cards(d, HAND_SIZE)
	phase = "playerTurn"
	selected_card_index = -1
	end_turn_btn.disabled = false
	_log("%s steps up. Energy %d/%d." % [d["name"], d["energy"], START_ENERGY])

func _on_end_turn() -> void:
	if phase != "playerTurn" or active_dwarf == null:
		return
	for c: String in active_dwarf["hand"]:
		active_dwarf["discard"].append(c)
	active_dwarf["hand"].clear()
	selected_card_index = -1
	phase = "enemyTurn"
	end_turn_btn.disabled = true
	_refresh()
	_advance_turn()

func _enemy_turn(e: Dictionary) -> void:
	phase = "enemyTurn"
	await get_tree().create_timer(0.4).timeout
	e["block"] = 0
	var it: Dictionary = e["intent"]
	if it["blk"] > 0:
		e["block"] += it["blk"]
		_log("%s braces (+%d block)." % [e["name"], it["blk"]])
		_refresh()
		await get_tree().create_timer(0.4).timeout
	if it["dmg"] > 0:
		var target = _random_living_dwarf()
		if target != null:
			var dealt: int = _apply_damage(target, it["dmg"])
			_flash(target)
			_impact(target, dealt)
			_log("%s uses %s. %s takes %d." % [e["name"], it["label"], target["name"], dealt])
			if not target["alive"]:
				_log("%s is downed!" % target["name"])
	# Telegraph next intent.
	var intents: Array = Db.ENEMIES[e["enemy_id"]]["intents"]
	e["intent_index"] = (e["intent_index"] + 1) % intents.size()
	e["intent"] = intents[e["intent_index"]]
	_refresh()
	_check_end()
	await get_tree().create_timer(0.2).timeout

func _random_living_dwarf():
	var living: Array = []
	for i: int in range(3):
		if combatants[i]["alive"]:
			living.append(combatants[i])
	if living.is_empty():
		return null
	return living[randi() % living.size()]

# ================================================================ Card play
func _on_card_clicked(card) -> void:
	_on_card_pressed(card.index)

func _on_card_pressed(index: int) -> void:
	if phase != "playerTurn" or active_dwarf == null:
		return
	if index < 0 or index >= active_dwarf["hand"].size():
		return
	var cid: String = active_dwarf["hand"][index]
	var def: Dictionary = Db.CARDS[cid]
	if def["cost"] > active_dwarf["energy"]:
		_log("Not enough energy for %s." % def["name"])
		return
	var tgt: String = def["target"]

	if tgt == "self":
		active_dwarf["energy"] -= def["cost"]
		active_dwarf["hand"].remove_at(index)        # remove before resolve so draws land
		_resolve(def["effect"], active_dwarf)
		active_dwarf["discard"].append(cid)
		selected_card_index = -1
		_log("Played %s." % def["name"])
		_refresh()
		_check_end()
		return

	if tgt == "all_enemies":
		active_dwarf["energy"] -= def["cost"]
		active_dwarf["hand"].remove_at(index)
		for i: int in range(3, combatants.size()):
			var en: Dictionary = combatants[i]
			if en["alive"]:
				_resolve(def["effect"], en)
		active_dwarf["discard"].append(cid)
		selected_card_index = -1
		_log("Played %s — it hits every demon." % def["name"])
		_refresh()
		_check_end()
		return

	# enemy-target card: tap to arm, tap same to cancel.
	if selected_card_index == index:
		selected_card_index = -1
		_log("Cancelled %s." % def["name"])
	else:
		selected_card_index = index
		_log("%s armed — tap a demon to strike." % def["name"])
	_refresh()

func _on_enemy_gui_input(event: InputEvent, slot: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_enemy_pressed(3 + slot)

func _on_enemy_pressed(ci: int) -> void:
	if phase != "playerTurn" or active_dwarf == null:
		return
	if selected_card_index < 0:
		return
	if ci < 0 or ci >= combatants.size():
		return
	var target: Dictionary = combatants[ci]
	if not target["alive"] or target["kind"] != "enemy":
		return
	var index: int = selected_card_index
	if index >= active_dwarf["hand"].size():
		selected_card_index = -1
		return
	var cid: String = active_dwarf["hand"][index]
	var def: Dictionary = Db.CARDS[cid]
	if def["cost"] > active_dwarf["energy"]:
		_log("Not enough energy for %s." % def["name"])
		return
	active_dwarf["energy"] -= def["cost"]
	active_dwarf["hand"].remove_at(index)
	selected_card_index = -1
	_resolve(def["effect"], target)
	active_dwarf["discard"].append(cid)
	_log("%s strikes %s." % [def["name"], target["name"]])
	_refresh()
	_check_end()

# ================================================================ Resolver
func _resolve(effect: Array, target: Dictionary) -> void:
	for op: Array in effect:
		match op[0]:
			"damage":
				_attack(target, op[1])
			"block":
				active_dwarf["block"] += op[1]
			"self_damage":
				active_dwarf["hp"] = maxi(0, active_dwarf["hp"] - op[1])
				if active_dwarf["hp"] <= 0:
					active_dwarf["alive"] = false
			"draw":
				_draw_cards(active_dwarf, op[1])
			"resource":
				active_dwarf["resource"] += op[1]
			"damage_per_resource":
				var amt: int = op[1] + op[2] * active_dwarf["resource"]
				active_dwarf["resource"] = 0
				_attack(target, amt)
			"resource_if_bloodied":
				if active_dwarf["hp"] * 2 < active_dwarf["max_hp"]:
					active_dwarf["resource"] += op[1]
			"status":
				target["statuses"][op[1]] = target["statuses"].get(op[1], 0) + op[2]
			"status_per_resource":
				var stacks: int = op[2] + op[3] * active_dwarf["resource"]
				active_dwarf["resource"] = 0
				target["statuses"][op[1]] = target["statuses"].get(op[1], 0) + stacks
			"power":
				active_dwarf["powers"][op[1]] = active_dwarf["powers"].get(op[1], 0) + op[2]

func _attack(target: Dictionary, amount: int) -> void:
	if amount <= 0:
		return
	var total: int = amount + target["statuses"].get("mark", 0)   # Mark amps hits on this enemy
	var dealt: int = _apply_damage(target, total)
	_flash(target)
	_impact(target, dealt)

func _draw_cards(d: Dictionary, n: int) -> void:
	for i: int in range(n):
		if d["deck"].is_empty():
			_reshuffle(d)
		if d["deck"].is_empty():
			break
		d["hand"].append(d["deck"].pop_back())

func _reshuffle(d: Dictionary) -> void:
	d["deck"] = d["discard"].duplicate()
	d["deck"].shuffle()
	d["discard"].clear()

# ================================================================ Combat math
func _apply_damage(target: Dictionary, amount: int) -> int:
	var blocked: int = mini(target["block"], amount)
	target["block"] -= blocked
	var rem: int = amount - blocked
	target["hp"] = maxi(0, target["hp"] - rem)
	if target["hp"] <= 0:
		target["alive"] = false
	return rem

func _living_enemies() -> int:
	var n: int = 0
	for i: int in range(3, combatants.size()):
		if combatants[i]["alive"]:
			n += 1
	return n

func _living_dwarves() -> int:
	var n: int = 0
	for i: int in range(3):
		if combatants[i]["alive"]:
			n += 1
	return n

func _check_end() -> void:
	if phase == "win" or phase == "lose":
		return
	if _living_enemies() == 0:
		_end(true)
	elif _living_dwarves() == 0:
		_end(false)

func _end(won: bool) -> void:
	phase = "win" if won else "lose"
	selected_card_index = -1
	end_turn_btn.disabled = true
	overlay_label.text = "The dwarves delivered.\nQuarterly demon targets met." if won else "Liquidation.\nThe contract is void."
	overlay.visible = true
	_refresh()

func _on_overlay_btn() -> void:
	_start_combat()

# ================================================================ Targeting cursor
## Swap the OS cursor to a red reticle whenever an enemy-target card is armed,
## restoring the default arrow otherwise (Hearthstone-style "now pick a target").
func _update_cursor() -> void:
	var targeting: bool = phase == "playerTurn" and selected_card_index >= 0
	if targeting:
		Input.set_custom_mouse_cursor(reticle_tex, Input.CURSOR_ARROW, Vector2(24, 24))
	else:
		Input.set_custom_mouse_cursor(null)

## Reticle drawn procedurally (two rings + gapped crosshair + center dot).
func _make_reticle() -> ImageTexture:
	var s: int = 48
	var img: Image = Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := Vector2(s * 0.5, s * 0.5)
	var col := Color(1.0, 0.27, 0.27, 1.0)
	for deg: int in range(0, 360):
		var dir := Vector2(cos(deg_to_rad(float(deg))), sin(deg_to_rad(float(deg))))
		for r: float in [21.0, 20.0, 12.0, 11.0]:
			_plot(img, c + dir * r, col)
	for d: int in range(6, 23):
		_plot(img, c + Vector2(d, 0), col)
		_plot(img, c + Vector2(-d, 0), col)
		_plot(img, c + Vector2(0, d), col)
		_plot(img, c + Vector2(0, -d), col)
	for o: Vector2 in [Vector2.ZERO, Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		_plot(img, c + o, col)
	return ImageTexture.create_from_image(img)

func _plot(img: Image, p: Vector2, col: Color) -> void:
	var x: int = int(round(p.x))
	var y: int = int(round(p.y))
	if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
		img.set_pixel(x, y, col)

# ================================================================ VFX
func _flash(c: Dictionary) -> void:
	var n: Label = c.get("node")
	if n == null:
		return
	n.pivot_offset = n.size * 0.5
	n.scale = Vector2.ONE
	var t: Tween = create_tween()
	t.tween_property(n, "scale", Vector2(1.35, 1.35), 0.09)
	t.tween_property(n, "scale", Vector2.ONE, 0.09)
	n.modulate = Color(1.6, 1.6, 1.6, 1)
	var t2: Tween = create_tween()
	t2.tween_property(n, "modulate", Color(1, 1, 1, 1), 0.18)

func _impact(c: Dictionary, mag: int) -> void:
	var n: Label = c.get("node")
	if n == null:
		return
	var pos: Vector2 = n.global_position + n.size * 0.5
	var fx: Node2D = MOMENTUM_HIT.instantiate()
	add_child(fx)
	fx.position = pos
	fx.set_momentum(clampi(int(round(mag / 2.0)), 1, 10))
	fx.burst()
	get_tree().create_timer(1.2).timeout.connect(fx.queue_free)

# ================================================================ Render
func _log(s: String) -> void:
	log_label.text = s

func _refresh() -> void:
	if combatants.is_empty():
		return
	_refresh_track()
	_refresh_enemies()
	_refresh_dwarves()
	_refresh_active_panel()
	_rebuild_hand()
	end_turn_btn.disabled = phase != "playerTurn"
	end_turn_btn.visible = not overlay.visible
	_update_cursor()

func _refresh_track() -> void:
	for child in init_box.get_children():
		child.queue_free()
	for slot: int in range(order.size()):
		var c: Dictionary = combatants[order[slot]]
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 14)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.custom_minimum_size = Vector2(76, 44)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if c["kind"] == "dwarf":
			l.text = "%s\nP%d" % [c["emoji"], c["slot"] + 1]
		else:
			l.text = c["emoji"]
		if not c["alive"]:
			l.modulate = Color(0.4, 0.4, 0.4, 0.7)
		elif slot == turn_ptr:
			l.modulate = Color(1.0, 0.95, 0.35, 1.0)
		else:
			l.modulate = Color(1, 1, 1, 1)
		init_box.add_child(l)

func _refresh_enemies() -> void:
	for slot: int in range(enemy_emoji.size()):
		var c: Dictionary = combatants[3 + slot]
		var emo: Label = enemy_emoji[slot]
		var alive: bool = c["alive"]
		emo.visible = alive
		enemy_hp[slot].visible = alive
		enemy_intent[slot].visible = alive
		enemy_name[slot].visible = alive and enemy_name[slot].text != "" and slot == 0
		enemy_block[slot].visible = alive and c["block"] > 0
		if not alive:
			continue
		enemy_hp[slot].text = "%d/%d" % [c["hp"], c["max_hp"]]
		enemy_block[slot].text = "🛡️%d" % c["block"]
		var it: Dictionary = c["intent"]
		var v: int = it["dmg"] if it["dmg"] > 0 else it["blk"]
		enemy_intent[slot].text = "%s%d" % [it["emoji"], v]
		# Pulse-highlight living enemies while a target is being chosen.
		var targeting: bool = selected_card_index >= 0
		emo.modulate = Color(1.25, 1.05, 0.6, 1.0) if targeting else Color(1, 1, 1, 1)

func _refresh_dwarves() -> void:
	for slot: int in range(dwarf_emoji.size()):
		var c: Dictionary = combatants[slot]
		var emo: Label = dwarf_emoji[slot]
		var alive: bool = c["alive"]
		var is_active: bool = alive and is_same(c, active_dwarf) and phase == "playerTurn"
		dwarf_outline[slot].visible = is_active
		emo.scale = Vector2(1.15, 1.15) if is_active else Vector2.ONE
		if alive:
			emo.modulate = Color(1, 1, 1, 1)
			dwarf_hp[slot].text = "%d/%d" % [c["hp"], c["max_hp"]]
			dwarf_block[slot].text = ("🛡️%d" % c["block"]) if c["block"] > 0 else ""
			dwarf_res[slot].text = "%s: %d" % [c["resource_name"], c["resource"]]
		else:
			emo.modulate = Color(0.35, 0.35, 0.35, 0.8)
			dwarf_hp[slot].text = "DOWNED"
			dwarf_block[slot].text = ""
			dwarf_res[slot].text = ""

func _refresh_active_panel() -> void:
	if active_dwarf != null and phase == "playerTurn":
		active_name_label.text = "%s  %s" % [active_dwarf["emoji"], active_dwarf["name"]]
		active_energy_label.text = "Energy %d/%d" % [active_dwarf["energy"], START_ENERGY]
		active_res_label.text = "%s: %d" % [active_dwarf["resource_name"], active_dwarf["resource"]]
	else:
		active_name_label.text = "Round %d" % round_num
		active_energy_label.text = "Resolving…"
		active_res_label.text = ""

func _rebuild_hand() -> void:
	for child in hand_box.get_children():
		child.queue_free()
	if phase != "playerTurn" or active_dwarf == null:
		return
	var hand: Array = active_dwarf["hand"]
	var n: int = hand.size()
	var cx: float = 360.0
	var spacing: float = minf(116.0, 624.0 / float(maxi(1, n)))
	var base_y: float = 196.0                 # bottom-center y within hand_box
	for i: int in range(n):
		var cid: String = hand[i]
		var def: Dictionary = Db.CARDS[cid]
		var card := Card.new()
		hand_box.add_child(card)
		card.index = i
		var face: Dictionary = Db.describe(def, active_dwarf)
		var armed: bool = (i == selected_card_index)
		card.setup(def, face, def["cost"] <= active_dwarf["energy"], armed)
		card.clicked.connect(_on_card_clicked)
		var t: float = float(i) - float(n - 1) / 2.0
		var rot: float = deg_to_rad(t * 5.0)
		var bottom_center := Vector2(cx + t * spacing, base_y + absf(t) * 9.0)
		card.set_slot(bottom_center - Vector2(Card.SIZE.x * 0.5, Card.SIZE.y), rot)

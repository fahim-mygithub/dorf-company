extends Control
## "Demon Lord MBA" — Slice 2 party puzzle (portrait 720x1280, emoji).
##
## 3 roles (Warrior tank / Cleric support / Sorcerer dps), per-character decks + energy.
## Clean PLAYER phase (act with each character in any order) -> ENEMY phase.
## 3 archetype enemies with PREFERRED TARGETING + live threat arrows + Taunt redirect.
## Data-driven via card_db.gd (Db). Reuses card.gd (Card), threat_arrows.gd, momentum_hit VFX.
## Resolution order (Db op semantics): base -> +flat (Channel/Aura) -> xMark -> block,hp -> Retaliate.

const Db := preload("res://scripts/combat/card_db.gd")
const Card := preload("res://scripts/ui/card.gd")
const Threat := preload("res://scripts/ui/threat_arrows.gd")
const MOMENTUM_HIT := preload("res://scenes/vfx/momentum_hit.tscn")

const HAND_SIZE := 5

## Overworld mesh (Phase 1): a non-empty `request` makes this scene run as a CHILD of the
## overworld — party/enemies come from `request`, and `_end` emits `combat_finished` instead of
## showing Play-Again. An EMPTY request = standalone behaviour, byte-identical to before.
signal combat_finished(result)
var request: Dictionary = {}

# ---------------------------------------------------------------- State
var party: Array = []          # 3 char dicts: 0 warrior, 1 cleric, 2 sorcerer
var enemies: Array = []        # 3 enemy dicts
var phase := ""                # playerTurn / enemyTurn / win / lose
var turn := 0
var active_idx := 0            # selected character
var selected_card := -1        # armed card index in active char's hand
var party_attack_buff := 0     # Aura of Valor (this player phase)
var taunt_last_turn := -99
var attacks_this_turn := 0   # party-wide, this player phase (feeds Arcane Finisher)
var combat_epoch := 0
var _is_touch := false
var reticle_tex: ImageTexture
var _cursor_on := false

# ---------------------------------------------------------------- UI refs
# enemies (parallel to enemies[])
var en_emoji: Array = []
var en_name: Array = []
var en_intent: Array = []
var en_hp: Array = []
var en_block: Array = []
# party (parallel to party[])
var pc_emoji: Array = []
var pc_name: Array = []
var pc_hp: Array = []
var pc_block: Array = []
var pc_energy: Array = []
var pc_outline: Array = []

var threat: Node2D
var active_label: Label
var hint_label: Label
var hand_box: Control
var end_turn_btn: Button
var log_label: Label
var overlay: ColorRect
var overlay_label: Label
var overlay_btn: Button

# enemy slot screen positions / party slot screen positions
const EN_POS := [Vector2(170, 200), Vector2(360, 200), Vector2(550, 200)]
const PC_POS := [Vector2(170, 700), Vector2(360, 700), Vector2(550, 700)]

# ================================================================ Lifecycle
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	reticle_tex = _make_reticle()
	_is_touch = DisplayServer.is_touchscreen_available()
	_build_ui()
	_start_combat()

# ================================================================ UI helpers
func _label(text: String, pos: Vector2, sz: Vector2, font: int, center := true) -> Label:
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

func _emoji(center_pos: Vector2, box: Vector2, font: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_STOP
	l.size = box
	l.position = center_pos - box * 0.5
	l.pivot_offset = box * 0.5
	add_child(l)
	return l

# ================================================================ UI build
func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.09, 0.12)
	bg.size = Vector2(720, 1280)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_label("— THE QUARTERLY RAID —", Vector2(60, 24), Vector2(600, 26), 18)

	for i: int in range(3):
		_build_enemy_slot(i)

	# threat arrows drawn above the board, below cards
	threat = Threat.new()
	threat.z_index = 40
	add_child(threat)

	for i: int in range(3):
		_build_party_slot(i)

	active_label = _label("", Vector2(20, 800), Vector2(680, 26), 20)
	hint_label = _label("", Vector2(20, 830), Vector2(680, 22), 15)

	hand_box = Control.new()
	hand_box.position = Vector2(0, 905)
	hand_box.size = Vector2(720, 220)
	hand_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hand_box)

	end_turn_btn = Button.new()
	end_turn_btn.text = "End Turn"
	end_turn_btn.add_theme_font_size_override("font_size", 20)
	end_turn_btn.position = Vector2(540, 1184)
	end_turn_btn.size = Vector2(165, 52)
	end_turn_btn.pressed.connect(_on_end_turn)
	add_child(end_turn_btn)

	log_label = _label("", Vector2(16, 1244), Vector2(688, 30), 15, false)

	overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.82)
	overlay.size = Vector2(720, 1280)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	overlay_label = Label.new()
	overlay_label.add_theme_font_size_override("font_size", 30)
	overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overlay_label.position = Vector2(40, 520)
	overlay_label.size = Vector2(640, 160)
	overlay.add_child(overlay_label)
	overlay_btn = Button.new()
	overlay_btn.text = "Play Again"
	overlay_btn.add_theme_font_size_override("font_size", 22)
	overlay_btn.position = Vector2(260, 700)
	overlay_btn.size = Vector2(200, 60)
	overlay_btn.pressed.connect(_on_overlay_btn)
	overlay.add_child(overlay_btn)
	overlay.visible = false

func _build_enemy_slot(i: int) -> void:
	var pos: Vector2 = EN_POS[i]
	var e := _emoji(pos, Vector2(96, 76), 50)
	e.gui_input.connect(_on_enemy_input.bind(i))
	en_emoji.append(e)
	en_name.append(_label("", Vector2(pos.x - 80, pos.y - 74), Vector2(160, 20), 14))
	en_intent.append(_label("", Vector2(pos.x - 80, pos.y - 52), Vector2(160, 22), 18))
	en_hp.append(_label("", Vector2(pos.x - 80, pos.y + 40), Vector2(160, 20), 16))
	en_block.append(_label("", Vector2(pos.x - 80, pos.y + 60), Vector2(160, 18), 14))

func _build_party_slot(i: int) -> void:
	var pos: Vector2 = PC_POS[i]
	var o := ColorRect.new()
	o.color = Color(1.0, 0.85, 0.2, 0.16)
	o.position = pos - Vector2(64, 60)
	o.size = Vector2(128, 150)
	o.mouse_filter = Control.MOUSE_FILTER_IGNORE
	o.visible = false
	add_child(o)
	pc_outline.append(o)
	var e := _emoji(pos, Vector2(110, 70), 50)
	e.gui_input.connect(_on_party_input.bind(i))
	pc_emoji.append(e)
	pc_name.append(_label("", Vector2(pos.x - 80, pos.y - 58), Vector2(160, 20), 14))
	pc_hp.append(_label("", Vector2(pos.x - 80, pos.y + 38), Vector2(160, 20), 16))
	pc_block.append(_label("", Vector2(pos.x - 80, pos.y + 58), Vector2(160, 18), 14))
	pc_energy.append(_label("", Vector2(pos.x - 80, pos.y + 76), Vector2(160, 18), 14))

# ================================================================ Combat start
func _start_combat() -> void:
	combat_epoch += 1
	party = []
	var crew_specs: Array = request.get("crew", [])
	if crew_specs.is_empty():
		for cid: String in Db.PARTY_ORDER:
			crew_specs.append({"cls": cid})
	for i: int in range(crew_specs.size()):
		var spec: Dictionary = crew_specs[i]
		var cid: String = spec["cls"]
		var cls: Dictionary = Db.CLASSES[cid]
		var deck: Array = (spec.get("deck", cls["deck"]) as Array).duplicate()
		deck.shuffle()
		party.append({
			"role": cls["role"], "name": spec.get("name", cls["name"]), "emoji": cls["emoji"],
			"hp": int(spec.get("hp", cls["max_hp"])), "max_hp": int(spec.get("max_hp", cls["max_hp"])), "block": 0,
			"energy": cls["energy"], "max_energy": cls["energy"], "alive": true,
			"deck": deck, "hand": [], "discard": [],
			"temp": _fresh_temp(), "shield": 0, "attacks_this_turn": 0,
			"node": pc_emoji[i], "slot": i,
		})

	enemies = []
	var enc: Array = request.get("enemies", Db.ENCOUNTER)
	for i: int in range(enc.size()):
		var eid: String = enc[i]
		var ed: Dictionary = Db.ENEMIES[eid]
		enemies.append({
			"archetype": eid, "name": ed["name"], "emoji": ed["emoji"],
			"hp": ed["max_hp"], "max_hp": ed["max_hp"], "block": 0, "atk": ed["atk"],
			"pref": ed["pref"], "alive": true, "marked": false, "forced": false,
			"intent_target": -1, "node": en_emoji[i], "slot": i,
		})

	turn = 0
	taunt_last_turn = -99
	phase = ""
	overlay.visible = false
	for i: int in range(3):
		en_emoji[i].text = enemies[i]["emoji"]
		en_emoji[i].modulate = Color.WHITE
		en_emoji[i].scale = Vector2.ONE
		pc_emoji[i].text = party[i]["emoji"]
		pc_emoji[i].modulate = Color.WHITE
		pc_emoji[i].scale = Vector2.ONE
	_log("The demon lord convenes the raid. Sequence your dwarves.")
	_start_player_phase()

func _fresh_temp() -> Dictionary:
	# fortify -> Retaliate +2 (persists through enemy phase); fortify_guard -> next Guard +5 (consumed)
	return {"retaliate": 0, "fortify": false, "fortify_guard": false, "channel_charges": 0, "channel_bonus": 0}

# ================================================================ Phase flow
func _start_player_phase() -> void:
	turn += 1
	for a: Dictionary in party:
		if not a["alive"]:
			continue
		a["block"] = 0
		a["energy"] = a["max_energy"]
		a["temp"] = _fresh_temp()
		a["shield"] = 0
		a["attacks_this_turn"] = 0
		_draw_cards(a, HAND_SIZE)
	for e: Dictionary in enemies:
		e["marked"] = false
		e["forced"] = false
	party_attack_buff = 0
	attacks_this_turn = 0
	selected_card = -1
	active_idx = _first_living_party()
	phase = "playerTurn"
	_refresh()

func _on_end_turn() -> void:
	if phase != "playerTurn":
		return
	for a: Dictionary in party:
		for c: String in a["hand"]:
			a["discard"].append(c)
		a["hand"].clear()
	selected_card = -1
	phase = "enemyTurn"
	_refresh()
	await _enemy_phase()

func _enemy_phase() -> void:
	var epoch: int = combat_epoch
	for e: Dictionary in enemies:
		if not e["alive"]:
			continue
		await get_tree().create_timer(0.45).timeout
		if epoch != combat_epoch:
			return
		var t: Dictionary = _enemy_target(e)
		if t.is_empty():
			continue
		_enemy_attack(e, t)
		_refresh()
		if _check_end():
			return
	await get_tree().create_timer(0.25).timeout
	if epoch != combat_epoch:
		return
	_start_player_phase()

# ================================================================ Targeting (enemy preference)
func _enemy_target(e: Dictionary) -> Dictionary:
	if e["forced"] and party[0]["alive"]:
		return party[0]            # Taunt -> Warrior
	match e["pref"]:
		"tankiest":
			return _pick_tankiest()
		"healer_dps":
			if party[1]["alive"]: return party[1]   # Cleric
			if party[2]["alive"]: return party[2]   # Sorcerer
			if party[0]["alive"]: return party[0]
			return {}
		"lowest_hp":
			return _pick_lowest_hp()
		_:
			return _pick_lowest_hp()

func _pick_tankiest() -> Dictionary:
	var best: Dictionary = {}
	for a: Dictionary in party:
		if not a["alive"]:
			continue
		if best.is_empty() or a["block"] > best["block"] or (a["block"] == best["block"] and a["max_hp"] > best["max_hp"]):
			best = a
	return best

func _pick_lowest_hp() -> Dictionary:
	var best: Dictionary = {}
	for a: Dictionary in party:
		if not a["alive"]:
			continue
		if best.is_empty() or a["hp"] < best["hp"]:
			best = a
	return best

# ================================================================ Card play
func _on_party_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_party_clicked(idx)

func _on_enemy_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_enemy_clicked(idx)

func _on_party_clicked(idx: int) -> void:
	if phase != "playerTurn" or not party[idx]["alive"]:
		return
	# If an ally-target card is armed, this tap chooses the ally.
	if selected_card >= 0:
		var def: Dictionary = _armed_def()
		if def.get("target", "") in ["ally", "ally_or_enemy"]:
			_play_on_ally(idx)
			return
	# Otherwise just switch the active character.
	active_idx = idx
	selected_card = -1
	_refresh()

func _on_enemy_clicked(idx: int) -> void:
	if phase != "playerTurn" or not enemies[idx]["alive"]:
		return
	if selected_card < 0:
		return
	var def: Dictionary = _armed_def()
	if def.get("target", "") in ["enemy", "ally_or_enemy"]:
		_play_on_enemy(idx)

func _armed_def() -> Dictionary:
	var a: Dictionary = party[active_idx]
	if selected_card < 0 or selected_card >= a["hand"].size():
		return {}
	return Db.CARDS[a["hand"][selected_card]]

## Self/all-enemies cards have no target to pick, so a single tap plays them right away
## (hover already previews the tooltip on desktop). Target cards still arm on the first
## tap (shows tooltip + reticle) and play on a second tap of the target.
func _on_card_clicked(card) -> void:
	if phase != "playerTurn":
		return
	var a: Dictionary = party[active_idx]
	var idx: int = card.index
	if idx < 0 or idx >= a["hand"].size():
		return
	var cid: String = a["hand"][idx]
	var def: Dictionary = Db.CARDS[cid]
	var tgt: String = def["target"]
	if tgt == "self" or tgt == "all_enemies":
		if not _can_play(a, cid, def):
			return
		_spend(a, idx)
		if tgt == "all_enemies":
			for e: Dictionary in enemies:
				if e["alive"]:
					_resolve(def, a, e)
		else:
			_resolve(def, a, {})
		_finish_play(a, def, cid)
		return
	if selected_card != idx:
		selected_card = idx                      # inspect + arm target card
		_log("%s — %s" % [def["name"], _select_hint(def)])
		_refresh()
	else:
		selected_card = -1                       # deselect a target card
		_refresh()

func _select_hint(def: Dictionary) -> String:
	match def.get("target", ""):
		"enemy": return "tap an enemy to strike"
		"ally": return "tap an ally"
		"ally_or_enemy": return "tap an ally to heal, or an enemy to strike"
		_: return ""

func _can_play(a: Dictionary, cid: String, def: Dictionary) -> bool:
	if def["cost"] > a["energy"]:
		_log("Not enough energy for %s." % def["name"])
		return false
	if cid == "taunt" and turn - taunt_last_turn < 2:
		_log("Taunt is recovering — not two turns in a row.")
		return false
	return true

func _play_on_enemy(e_idx: int) -> void:
	var a: Dictionary = party[active_idx]
	var idx: int = selected_card
	var cid: String = a["hand"][idx]
	var def: Dictionary = Db.CARDS[cid]
	if not _can_play(a, cid, def):
		return
	_spend(a, idx)
	_resolve(def, a, enemies[e_idx])
	_finish_play(a, def, cid)

func _play_on_ally(c_idx: int) -> void:
	var a: Dictionary = party[active_idx]
	var idx: int = selected_card
	var cid: String = a["hand"][idx]
	var def: Dictionary = Db.CARDS[cid]
	if not _can_play(a, cid, def):
		return
	_spend(a, idx)
	_resolve(def, a, party[c_idx])   # target is an ally char
	_finish_play(a, def, cid)

func _spend(a: Dictionary, idx: int) -> void:
	var cid: String = a["hand"][idx]
	a["energy"] -= Db.CARDS[cid]["cost"]
	a["hand"].remove_at(idx)

func _finish_play(a: Dictionary, def: Dictionary, cid: String) -> void:
	a["discard"].append(cid)
	if def.get("is_attack", false):
		attacks_this_turn += 1   # party-wide count for Finisher
	selected_card = -1
	_log("%s played %s." % [a["name"], def["name"]])
	_refresh()
	_check_end()

# ================================================================ Resolver
## a = acting character; target = enemy OR ally char (or {} for self/none).
func _resolve(def: Dictionary, a: Dictionary, target: Dictionary) -> void:
	for op: Array in def["effect"]:
		match op[0]:
			"damage":
				_attack(a, target, op[1], def.get("is_attack", false))
			"block":
				var bonus: int = 0
				if a["temp"]["fortify_guard"] and def.get("fortifiable", false):
					bonus = 5
					a["temp"]["fortify_guard"] = false   # consume the +5; Retaliate +2 persists
				a["block"] += op[1] + bonus
			"self_damage":
				a["hp"] = maxi(0, a["hp"] - op[1])
				if a["hp"] <= 0:
					a["alive"] = false
			"draw":
				_draw_cards(a, op[1])
			"damage_scaling":
				var base: int = op[2] + op[3] * attacks_this_turn
				_attack(a, target, base, true)
			"heal_or_damage":
				if target.get("role", "") != "":     # an ally char
					target["hp"] = mini(target["max_hp"], target["hp"] + op[1])
				else:                                  # an enemy
					_attack(a, target, op[1], false)
			"apply_status":
				if op[1] == "marked":
					target["marked"] = true
			"force_target_all":
				for e: Dictionary in enemies:
					e["forced"] = true
				taunt_last_turn = turn
			"temp":
				match op[1]:
					"retaliate":
						a["temp"]["retaliate"] = op[2]
					"fortify":
						a["temp"]["fortify"] = true
						a["temp"]["fortify_guard"] = true
					"channel":
						a["temp"]["channel_charges"] = op[3]
						a["temp"]["channel_bonus"] = op[2]
			"shield_ally":
				target["shield"] += op[1]
			"party_buff":
				if op[1] == "attack":
					party_attack_buff += op[2]

## Damage to an ENEMY (resolution order: base -> +flat -> xMark -> block,hp).
func _attack(a: Dictionary, enemy: Dictionary, base: int, is_attack: bool) -> void:
	if enemy.is_empty() or not enemy.get("alive", false):
		return
	var amt: int = base
	if is_attack:
		if a["temp"]["channel_charges"] > 0:
			amt += a["temp"]["channel_bonus"]
			a["temp"]["channel_charges"] -= 1
		amt += party_attack_buff
	if enemy["marked"]:
		amt = int(round(amt * Db.MARK_MULT))
	_deal_enemy(enemy, amt)
	_flash(enemy)
	_impact(enemy, amt)

func _deal_enemy(enemy: Dictionary, amt: int) -> void:
	if amt <= 0:
		return
	var blocked: int = mini(enemy["block"], amt)
	enemy["block"] -= blocked
	var rem: int = amt - blocked
	enemy["hp"] = maxi(0, enemy["hp"] - rem)
	if enemy["hp"] <= 0:
		enemy["alive"] = false

## Enemy attacks a party character (shield -> block -> hp), then Retaliate fires.
func _enemy_attack(e: Dictionary, t: Dictionary) -> void:
	var dmg: int = maxi(0, e["atk"] - int(t["shield"]))
	var blocked: int = mini(t["block"], dmg)
	t["block"] -= blocked
	var rem: int = dmg - blocked
	t["hp"] = maxi(0, t["hp"] - rem)
	if t["hp"] <= 0:
		t["alive"] = false
	_flash(t)
	_impact(t, rem)
	_log("%s hits %s for %d." % [e["name"], t["name"], rem])
	# Retaliate triggers on every hit on the holder.
	var refl: int = int(t["temp"]["retaliate"])
	if refl > 0:
		if t["temp"]["fortify"]:
			refl += 2
		_deal_enemy(e, refl)
		_flash(e)
		if not t["alive"]:
			_log("%s is downed!" % t["name"])

# ================================================================ Deck
func _draw_cards(a: Dictionary, n: int) -> void:
	for i: int in range(n):
		if a["deck"].is_empty():
			a["deck"] = a["discard"].duplicate()
			a["deck"].shuffle()
			a["discard"].clear()
		if a["deck"].is_empty():
			break
		a["hand"].append(a["deck"].pop_back())

# ================================================================ Win/Lose
func _check_end() -> bool:
	if phase == "win" or phase == "lose":
		return true
	var en_alive := false
	for e: Dictionary in enemies:
		if e["alive"]:
			en_alive = true
	var pc_alive := false
	for a: Dictionary in party:
		if a["alive"]:
			pc_alive = true
	if not en_alive:
		_end(true)
		return true
	if not pc_alive:
		_end(false)
		return true
	return false

func _end(won: bool) -> void:
	phase = "win" if won else "lose"
	selected_card = -1
	if not request.is_empty():
		var crew_results: Array = []
		for a: Dictionary in party:
			crew_results.append({"name": a["name"], "cls": a["role"], "survived": a["alive"], "hp_end": a["hp"], "max_hp": a["max_hp"]})
		combat_finished.emit({"success": won, "crew_results": crew_results, "payout_won": won})
		return
	overlay_label.text = "The dwarves delivered.\nQuarterly demon targets met." if won else "Liquidation.\nThe contract is void."
	overlay.visible = true
	_refresh()

func _on_overlay_btn() -> void:
	_start_combat()

func _first_living_party() -> int:
	for i: int in range(party.size()):
		if party[i]["alive"]:
			return i
	return 0

# ================================================================ Render
func _log(s: String) -> void:
	log_label.text = s

func _refresh() -> void:
	if party.is_empty():
		return
	_refresh_enemies()
	_refresh_party()
	_refresh_threats()
	_refresh_panel()
	_rebuild_hand()
	end_turn_btn.disabled = phase != "playerTurn"
	end_turn_btn.visible = not overlay.visible
	_update_cursor()

func _refresh_enemies() -> void:
	for i: int in range(3):
		var e: Dictionary = enemies[i]
		var alive: bool = e["alive"]
		en_emoji[i].visible = alive
		en_name[i].visible = alive
		en_intent[i].visible = alive
		en_hp[i].visible = alive
		en_block[i].visible = alive and e["block"] > 0
		if not alive:
			continue
		en_name[i].text = ("🎯 " if e["marked"] else "") + e["name"]
		en_hp[i].text = "%d/%d" % [e["hp"], e["max_hp"]]
		en_block[i].text = "🛡️%d" % e["block"]
		var tname: String = ""
		var t: Dictionary = _enemy_target(e)
		if not t.is_empty():
			tname = t["name"].substr(0, 3)
		en_intent[i].text = "🗡️%d>%s" % [e["atk"], tname]
		# Highlight valid enemy targets while an enemy-target card is armed.
		var arm: Dictionary = _armed_def()
		var can: bool = arm.get("target", "") in ["enemy", "ally_or_enemy"]
		en_emoji[i].modulate = Color(1.3, 1.05, 0.6) if (can and selected_card >= 0) else Color.WHITE

func _refresh_party() -> void:
	var arm: Dictionary = _armed_def()
	var ally_arm: bool = selected_card >= 0 and arm.get("target", "") in ["ally", "ally_or_enemy"]
	for i: int in range(3):
		var a: Dictionary = party[i]
		var alive: bool = a["alive"]
		pc_outline[i].visible = alive and i == active_idx and phase == "playerTurn"
		pc_emoji[i].scale = Vector2(1.12, 1.12) if (alive and i == active_idx) else Vector2.ONE
		pc_name[i].text = a["name"]
		if alive:
			pc_emoji[i].modulate = Color(0.5, 1.0, 0.6) if ally_arm else Color.WHITE
			pc_hp[i].text = "%d/%d" % [a["hp"], a["max_hp"]]
			var st := ""
			if a["block"] > 0:
				st += "🛡️%d " % a["block"]
			if a["shield"] > 0:
				st += "🔰%d " % a["shield"]
			if int(a["temp"]["channel_charges"]) > 0:
				st += "🌀%d " % a["temp"]["channel_charges"]
			if a["temp"]["fortify_guard"] or a["temp"]["fortify"]:
				st += "🔧 "
			if int(a["temp"]["retaliate"]) > 0:
				st += "🔁%d" % a["temp"]["retaliate"]
			pc_block[i].text = st
			pc_energy[i].text = "⚡%d/%d" % [a["energy"], a["max_energy"]]
		else:
			pc_emoji[i].modulate = Color(0.35, 0.35, 0.38)
			pc_hp[i].text = "DOWNED"
			pc_block[i].text = ""
			pc_energy[i].text = ""

func _refresh_threats() -> void:
	var pairs: Array = []
	if phase == "playerTurn":
		for e: Dictionary in enemies:
			if not e["alive"]:
				continue
			var t: Dictionary = _enemy_target(e)
			if t.is_empty():
				continue
			pairs.append({
				"from": EN_POS[e["slot"]] + Vector2(0, 42),
				"to": PC_POS[t["slot"]] + Vector2(0, -42),
			})
	threat.set_threats(pairs)

func _refresh_panel() -> void:
	if phase == "playerTurn":
		var a: Dictionary = party[active_idx]
		var aura: String = "   📣+%d atk" % party_attack_buff if party_attack_buff > 0 else ""
		active_label.text = "%s  %s   ⚡%d/%d%s" % [a["emoji"], a["name"], a["energy"], a["max_energy"], aura]
		hint_label.text = "Tap a dwarf to switch • tap a card to play (target cards: tap a target)"
	elif phase == "enemyTurn":
		active_label.text = "Enemy turn…"
		hint_label.text = ""
	else:
		active_label.text = ""
		hint_label.text = ""

func _rebuild_hand() -> void:
	for c in hand_box.get_children():
		c.queue_free()
	if phase != "playerTurn":
		return
	var a: Dictionary = party[active_idx]
	var hand: Array = a["hand"]
	var n: int = hand.size()
	var spacing: float = minf(116.0, 624.0 / float(maxi(1, n)))
	for i: int in range(n):
		var cid: String = hand[i]
		var def: Dictionary = Db.CARDS[cid]
		var card := Card.new()
		hand_box.add_child(card)
		card.index = i
		var face: Dictionary = Db.describe(def, a, party_attack_buff, attacks_this_turn)
		var cooldown: bool = cid == "taunt" and turn - taunt_last_turn < 2
		var playable: bool = def["cost"] <= a["energy"] and not cooldown
		card.setup(def, face, playable, i == selected_card, def.get("tip", ""), cooldown)
		card.clicked.connect(_on_card_clicked)
		var t: float = float(i) - float(n - 1) / 2.0
		var rot: float = deg_to_rad(t * 5.0)
		var bc := Vector2(360.0 + t * spacing, 196.0 + absf(t) * 9.0)
		card.set_slot(bc - Vector2(Card.SIZE.x * 0.5, Card.SIZE.y), rot)

# ================================================================ Targeting cursor
func _update_cursor() -> void:
	var arm: Dictionary = _armed_def()
	var needs_target: bool = arm.get("target", "") in ["enemy", "ally", "ally_or_enemy"]
	var targeting: bool = phase == "playerTurn" and selected_card >= 0 and needs_target
	if targeting == _cursor_on:
		return
	_cursor_on = targeting
	Input.set_custom_mouse_cursor(reticle_tex if targeting else null, Input.CURSOR_ARROW, Vector2(24, 24))

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
	_plot(img, c, col)
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
	t.tween_property(n, "scale", Vector2(1.32, 1.32), 0.09)
	t.tween_property(n, "scale", Vector2.ONE, 0.09)
	var t2: Tween = create_tween()
	t2.tween_property(n, "modulate", Color.WHITE, 0.18).from(Color(1.6, 1.6, 1.6, 1))

func _impact(c: Dictionary, mag: int) -> void:
	var n: Label = c.get("node")
	if n == null or mag <= 0:
		return
	var fx: Node2D = MOMENTUM_HIT.instantiate()
	add_child(fx)
	fx.position = n.global_position + n.size * 0.5
	fx.set_momentum(clampi(int(round(mag / 2.0)), 1, 10))
	fx.burst()
	get_tree().create_timer(1.2).timeout.connect(fx.queue_free)

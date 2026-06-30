extends Control
## "Demon Lord MBA" — Grid Fire Emblem experiment (portrait 720x1280, emoji).
##
## Forked from combat.gd. Same 3 roles, per-character decks + energy, clean
## PLAYER phase -> ENEMY phase, 3 archetype enemies with PREFERRED TARGETING
## (distance-blind) + Taunt redirect, and all Mark/Channel/Aura/Retaliate/
## Shield/Fortify resolution math UNCHANGED from combat.gd.
##
## NEW for this slice: a 5x5 tile grid. Units occupy tiles, move with a BFS
## flood-fill budget (movement points, separate pool from energy, refreshes
## each player phase), and targeted cards are range-gated by Manhattan
## distance (grid_distance). Enemies path toward their (unchanged) preferred
## target via _enemy_plan(), shared verbatim between the enemy-phase execution
## and the player-phase intent/arrow preview so the preview never lies.
##
## Data-driven via card_db.gd (Db). Reuses card.gd (Card), threat_arrows.gd
## (Threat, instanced twice: solid "will attack" arrows + faded "advancing"
## arrows, since the component itself only knows from/to, not intent), and
## the momentum_hit VFX.

const Db := preload("res://scripts/combat/card_db.gd")
const Card := preload("res://scripts/ui/card.gd")
const Threat := preload("res://scripts/ui/threat_arrows.gd")
const MOMENTUM_HIT := preload("res://scenes/vfx/momentum_hit.tscn")

const HAND_SIZE := 5

# ---------------------------------------------------------------- Grid
const TILE := 110.0
const ORIGIN := Vector2(85, 110)
const GRID_W := 5
const GRID_H := 5

# Token + label layout, relative to a tile's screen-space center (top-left
# corner offsets for Label boxes; _emoji() centers the token box itself).
const TOKEN_BOX := Vector2(88, 60)
const EN_NAME_OFF := Vector2(-52, -64)
const EN_INTENT_OFF := Vector2(-52, -46)
const EN_HP_OFF := Vector2(-52, 28)
const EN_BLOCK_OFF := Vector2(-52, 42)
const PC_NAME_OFF := Vector2(-52, -58)
const PC_HP_OFF := Vector2(-52, 26)
const PC_BLOCK_OFF := Vector2(-52, 39)
const PC_ENERGY_OFF := Vector2(-52, 52)
const OUTLINE_SIZE := Vector2(108, 108)
const OUTLINE_OFF := Vector2(-54, -54)

const TILE_DEFAULT := Color(0.15, 0.15, 0.19)
const TILE_MOVE := Color(0.20, 0.40, 0.62)
const TILE_RANGE := Color(0.46, 0.30, 0.16)   # armed-card reach indicator (warm orange)

# ---------------------------------------------------------------- State
var party: Array = []          # 3 char dicts: 0 warrior, 1 cleric, 2 sorcerer
var enemies: Array = []        # 3 enemy dicts
var phase := ""                # playerTurn / enemyTurn / win / lose
var turn := 0
var active_idx := 0            # selected character
var selected_card := -1        # armed card index in active char's hand
# Aura of Valor is now a radius buff: each ally carries its own attack_buff
# (party[i]["attack_buff"], set when an in-range Aura is cast, reset each player phase).
var taunt_last_turn := -99
var attacks_this_turn := 0   # party-wide, this player phase (feeds Arcane Finisher)
var combat_epoch := 0
var _is_touch := false
var reticle_tex: ImageTexture
var _cursor_on := false

var move_targets: Dictionary = {}   # Vector2i -> int path length; reachable tiles for the active dwarf (empty when none armed/shown)

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

# the 25 tile cells (parallel arrays)
var tile_cells: Array = []
var tile_coords: Array = []

var threat: Node2D          # solid "will attack this turn" arrows
var threat_drift: Node2D    # faded "still closing the distance" arrows
var active_label: Label
var hint_label: Label
var hand_box: Control
var end_turn_btn: Button
var log_label: Label
var overlay: ColorRect
var overlay_label: Label
var overlay_btn: Button

# ================================================================ Lifecycle
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	reticle_tex = _make_reticle()
	_is_touch = DisplayServer.is_touchscreen_available()
	_build_ui()
	_start_combat()

# ================================================================ Grid helpers
func tile_to_screen(tile: Vector2i) -> Vector2:
	return ORIGIN + Vector2(tile.x * TILE + TILE * 0.5, tile.y * TILE + TILE * 0.5)

func grid_distance(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)

## A card's EFFECTIVE reach for a given caster: its base `range` plus the Sorcerer's
## per-class +1 (only on cards that already reach, so pure-self range-0 cards stay self).
## This is the single source of truth for every range check + the reach indicator.
func _card_range(def: Dictionary, caster: Dictionary) -> int:
	var base: int = int(def.get("range", 0))
	if base > 0 and caster.get("role", "") == "sorcerer":
		base += 1
	return base

func _initial_enemy_tile(i: int) -> Vector2i:
	return Vector2i(i + 1, 0)

func _initial_party_tile(i: int) -> Vector2i:
	return Vector2i(i + 1, GRID_H - 1)

## 4-directional BFS flood-fill from `start`, capped at `budget` steps, blocked
## by any tile key present in `blocked`. Returns {Vector2i: int path_length},
## excluding `start` itself.
func _bfs_reachable(start: Vector2i, budget: int, blocked: Dictionary) -> Dictionary:
	var dist: Dictionary = {start: 0}
	var frontier: Array = [start]
	var dirs: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while not frontier.is_empty():
		var next: Array = []
		for cur: Vector2i in frontier:
			var d: int = dist[cur]
			if d >= budget:
				continue
			for dir: Vector2i in dirs:
				var n: Vector2i = cur + dir
				if n.x < 0 or n.x >= GRID_W or n.y < 0 or n.y >= GRID_H:
					continue
				if dist.has(n) or blocked.has(n):
					continue
				dist[n] = d + 1
				next.append(n)
		frontier = next
	dist.erase(start)
	return dist

## Tiles currently occupied by a living unit, as a {Vector2i: true} set.
## Pass the acting unit's own index to exclude it from the set (own tile never
## blocks itself); pass -1 to exclude nothing on that side.
func _occupied_tiles(exclude_party_idx: int, exclude_enemy_idx: int) -> Dictionary:
	var occ: Dictionary = {}
	for i: int in range(party.size()):
		if i == exclude_party_idx:
			continue
		if party[i]["alive"]:
			occ[party[i]["pos"]] = true
	for i: int in range(enemies.size()):
		if i == exclude_enemy_idx:
			continue
		if enemies[i]["alive"]:
			occ[enemies[i]["pos"]] = true
	return occ

## Shared by enemy-phase execution AND the player-phase intent/arrow preview,
## so the preview never lies about what the enemy phase will actually do.
## `occupied` reflects any units (other than `e`) already on the board —
## during execution this accumulates as earlier enemies this phase move.
func _enemy_plan(e: Dictionary, target: Dictionary, occupied: Dictionary) -> Dictionary:
	var e_pos: Vector2i = e["pos"]
	var t_pos: Vector2i = target["pos"]
	var rng: int = int(e["range"])
	if grid_distance(e_pos, t_pos) <= rng:
		return {"will_attack": true, "move_to": e_pos}
	var budget: int = int(e["move"])
	var blocked: Dictionary = occupied.duplicate()
	blocked.erase(e_pos)
	var reachable: Dictionary = _bfs_reachable(e_pos, budget, blocked)
	for tile: Vector2i in reachable:
		if grid_distance(tile, t_pos) <= rng:
			return {"will_attack": true, "move_to": tile}
	var best_tile: Vector2i = e_pos
	var best_dist: int = grid_distance(e_pos, t_pos)
	for tile: Vector2i in reachable:
		var gd: int = grid_distance(tile, t_pos)
		if gd < best_dist:
			best_dist = gd
			best_tile = tile
	return {"will_attack": false, "move_to": best_tile}

## Simulates the same fixed-turn-order, accumulating-occupied-tiles pass that
## _enemy_phase() runs for real, but read-only (no mutation, no animation) —
## this is what makes the player-phase intent labels and threat arrows match
## what the enemy phase will actually do, instead of each enemy planning in
## isolation against the un-simulated board. Returns {enemy index:
## {"plan": <_enemy_plan() result>, "target": <target char dict>}}, omitting
## dead enemies or enemies with no valid target.
func _preview_plans() -> Dictionary:
	var occupied: Dictionary = _occupied_tiles(-1, -1)
	var plans: Dictionary = {}
	for i: int in range(enemies.size()):
		var e: Dictionary = enemies[i]
		if not e["alive"]:
			continue
		var t: Dictionary = _enemy_target(e)
		if t.is_empty():
			continue
		occupied.erase(e["pos"])
		var plan: Dictionary = _enemy_plan(e, t, occupied)
		occupied[plan["move_to"]] = true
		plans[i] = {"plan": plan, "target": t}
	return plans

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

	_label("— THE QUARTERLY RAID: GRID —", Vector2(60, 24), Vector2(600, 26), 18)

	_build_grid()

	for i: int in range(3):
		_build_enemy_slot(i)

	# threat arrows drawn above the board, below cards: solid (will attack)
	# layered over faded (still closing distance).
	threat_drift = Threat.new()
	threat_drift.z_index = 39
	threat_drift.modulate = Color(1, 1, 1, 0.45)
	add_child(threat_drift)
	threat = Threat.new()
	threat.z_index = 40
	add_child(threat)

	for i: int in range(3):
		_build_party_slot(i)

	active_label = _label("", Vector2(20, 680), Vector2(680, 26), 20)
	hint_label = _label("", Vector2(20, 710), Vector2(680, 22), 15)

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

func _build_grid() -> void:
	for y: int in range(GRID_H):
		for x: int in range(GRID_W):
			var coord := Vector2i(x, y)
			var cell := ColorRect.new()
			cell.color = TILE_DEFAULT
			cell.size = Vector2(104, 104)
			cell.position = tile_to_screen(coord) - cell.size * 0.5
			cell.mouse_filter = Control.MOUSE_FILTER_STOP
			cell.gui_input.connect(_on_tile_input.bind(coord))
			add_child(cell)
			tile_cells.append(cell)
			tile_coords.append(coord)

func _build_enemy_slot(i: int) -> void:
	var pos: Vector2 = tile_to_screen(_initial_enemy_tile(i))
	var e := _emoji(pos, TOKEN_BOX, 34)
	e.gui_input.connect(_on_enemy_input.bind(i))
	en_emoji.append(e)
	en_name.append(_label("", pos + EN_NAME_OFF, Vector2(104, 14), 11))
	en_intent.append(_label("", pos + EN_INTENT_OFF, Vector2(104, 16), 13))
	en_hp.append(_label("", pos + EN_HP_OFF, Vector2(104, 14), 12))
	en_block.append(_label("", pos + EN_BLOCK_OFF, Vector2(104, 13), 10))

func _build_party_slot(i: int) -> void:
	var pos: Vector2 = tile_to_screen(_initial_party_tile(i))
	var o := ColorRect.new()
	o.color = Color(1.0, 0.85, 0.2, 0.16)
	o.position = pos + OUTLINE_OFF
	o.size = OUTLINE_SIZE
	o.mouse_filter = Control.MOUSE_FILTER_IGNORE
	o.visible = false
	add_child(o)
	pc_outline.append(o)
	var e := _emoji(pos, TOKEN_BOX, 34)
	e.gui_input.connect(_on_party_input.bind(i))
	pc_emoji.append(e)
	pc_name.append(_label("", pos + PC_NAME_OFF, Vector2(104, 14), 11))
	pc_hp.append(_label("", pos + PC_HP_OFF, Vector2(104, 14), 12))
	pc_block.append(_label("", pos + PC_BLOCK_OFF, Vector2(104, 13), 10))
	pc_energy.append(_label("", pos + PC_ENERGY_OFF, Vector2(104, 13), 10))

# ================================================================ Unit move/snap (tokens + labels)
func _snap_enemy_ui(i: int) -> void:
	var center: Vector2 = tile_to_screen(enemies[i]["pos"])
	en_emoji[i].position = center - TOKEN_BOX * 0.5
	en_name[i].position = center + EN_NAME_OFF
	en_intent[i].position = center + EN_INTENT_OFF
	en_hp[i].position = center + EN_HP_OFF
	en_block[i].position = center + EN_BLOCK_OFF

func _snap_party_ui(i: int) -> void:
	var center: Vector2 = tile_to_screen(party[i]["pos"])
	pc_emoji[i].position = center - TOKEN_BOX * 0.5
	pc_name[i].position = center + PC_NAME_OFF
	pc_hp[i].position = center + PC_HP_OFF
	pc_block[i].position = center + PC_BLOCK_OFF
	pc_energy[i].position = center + PC_ENERGY_OFF
	pc_outline[i].position = center + OUTLINE_OFF

func _animate_enemy_move(i: int, new_tile: Vector2i) -> void:
	var center: Vector2 = tile_to_screen(new_tile)
	var t: Tween = create_tween().set_parallel(true)
	t.tween_property(en_emoji[i], "position", center - TOKEN_BOX * 0.5, 0.25)
	t.tween_property(en_name[i], "position", center + EN_NAME_OFF, 0.25)
	t.tween_property(en_intent[i], "position", center + EN_INTENT_OFF, 0.25)
	t.tween_property(en_hp[i], "position", center + EN_HP_OFF, 0.25)
	t.tween_property(en_block[i], "position", center + EN_BLOCK_OFF, 0.25)

func _animate_party_move(i: int, new_tile: Vector2i) -> void:
	var center: Vector2 = tile_to_screen(new_tile)
	var t: Tween = create_tween().set_parallel(true)
	t.tween_property(pc_emoji[i], "position", center - TOKEN_BOX * 0.5, 0.25)
	t.tween_property(pc_name[i], "position", center + PC_NAME_OFF, 0.25)
	t.tween_property(pc_hp[i], "position", center + PC_HP_OFF, 0.25)
	t.tween_property(pc_block[i], "position", center + PC_BLOCK_OFF, 0.25)
	t.tween_property(pc_energy[i], "position", center + PC_ENERGY_OFF, 0.25)
	t.tween_property(pc_outline[i], "position", center + OUTLINE_OFF, 0.25)

# ================================================================ Combat start
func _start_combat() -> void:
	combat_epoch += 1
	party = []
	for i: int in range(Db.PARTY_ORDER.size()):
		var cid: String = Db.PARTY_ORDER[i]
		var cls: Dictionary = Db.CLASSES[cid]
		var deck: Array = (cls["deck"] as Array).duplicate()
		deck.shuffle()
		var move: int = int(cls["move"])
		party.append({
			"role": cls["role"], "name": cls["name"], "emoji": cls["emoji"],
			"hp": cls["max_hp"], "max_hp": cls["max_hp"], "block": 0,
			"energy": cls["energy"], "max_energy": cls["energy"], "alive": true,
			"deck": deck, "hand": [], "discard": [],
			"temp": _fresh_temp(), "shield": 0, "attacks_this_turn": 0, "attack_buff": 0,
			"node": pc_emoji[i], "slot": i,
			"pos": _initial_party_tile(i), "move": move, "move_left": move,
		})

	enemies = []
	for i: int in range(Db.ENCOUNTER.size()):
		var eid: String = Db.ENCOUNTER[i]
		var ed: Dictionary = Db.ENEMIES[eid]
		var move: int = int(ed["move"])
		var rng: int = int(ed["range"])
		enemies.append({
			"archetype": eid, "name": ed["name"], "emoji": ed["emoji"],
			"hp": ed["max_hp"], "max_hp": ed["max_hp"], "block": 0, "atk": ed["atk"],
			"pref": ed["pref"], "alive": true, "marked": false, "forced": false,
			"intent_target": -1, "node": en_emoji[i], "slot": i,
			"pos": _initial_enemy_tile(i), "move": move, "move_left": move, "range": rng,
		})

	turn = 0
	taunt_last_turn = -99
	phase = ""
	move_targets = {}
	overlay.visible = false
	for i: int in range(3):
		en_emoji[i].text = enemies[i]["emoji"]
		en_emoji[i].modulate = Color.WHITE
		en_emoji[i].scale = Vector2.ONE
		_snap_enemy_ui(i)
		pc_emoji[i].text = party[i]["emoji"]
		pc_emoji[i].modulate = Color.WHITE
		pc_emoji[i].scale = Vector2.ONE
		_snap_party_ui(i)
	_log("The demon lord convenes the raid. Sequence your dwarves across the grid.")
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
		a["attack_buff"] = 0
		a["move_left"] = a["move"]
		_draw_cards(a, HAND_SIZE)
	for e: Dictionary in enemies:
		e["marked"] = false
		e["forced"] = false
	attacks_this_turn = 0
	selected_card = -1
	move_targets = {}
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
	move_targets = {}
	phase = "enemyTurn"
	_refresh()
	await _enemy_phase()

func _enemy_phase() -> void:
	var epoch: int = combat_epoch
	var occupied: Dictionary = _occupied_tiles(-1, -1)   # live snapshot, updated as enemies move this phase
	for i: int in range(enemies.size()):
		var e: Dictionary = enemies[i]
		if not e["alive"]:
			continue
		await get_tree().create_timer(0.45).timeout
		if epoch != combat_epoch:
			return
		var t: Dictionary = _enemy_target(e)
		if t.is_empty():
			continue
		occupied.erase(e["pos"])   # don't block self while planning
		var plan: Dictionary = _enemy_plan(e, t, occupied)
		var moved: bool = plan["move_to"] != e["pos"]
		if moved:
			_animate_enemy_move(i, plan["move_to"])
			e["pos"] = plan["move_to"]
		occupied[e["pos"]] = true   # update snapshot for subsequent enemies this same phase
		if plan["will_attack"]:
			_enemy_attack(e, t)
			# A unit downed mid-phase (the target, or this enemy via Retaliate)
			# frees its tile — don't leave it falsely blocking later BFS paths.
			if not t["alive"]:
				occupied.erase(t["pos"])
			if not e["alive"]:
				occupied.erase(e["pos"])
		elif moved:
			_log("%s advances." % e["name"])
		else:
			_log("%s holds its ground." % e["name"])
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

# ================================================================ Tile / movement input
func _on_tile_input(event: InputEvent, coord: Vector2i) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_tile_clicked(coord)

func _on_tile_clicked(coord: Vector2i) -> void:
	if phase != "playerTurn" or not move_targets.has(coord):
		return
	var a: Dictionary = party[active_idx]
	var cost: int = int(move_targets[coord])
	a["move_left"] = maxi(0, int(a["move_left"]) - cost)
	a["pos"] = coord
	_animate_party_move(active_idx, coord)
	move_targets = {}
	_refresh()

func _show_move_targets(idx: int) -> void:
	var a: Dictionary = party[idx]
	var occupied: Dictionary = _occupied_tiles(idx, -1)
	move_targets = _bfs_reachable(a["pos"], int(a["move_left"]), occupied)
	_refresh()

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
	# If an ally-target card is armed, this tap chooses the ally (range-gated in _play_on_ally).
	if selected_card >= 0:
		var def: Dictionary = _armed_def()
		if def.get("target", "") in ["ally", "ally_or_enemy"]:
			_play_on_ally(idx)
			return
	# Tapping the active dwarf with nothing armed shows its movement range.
	if selected_card < 0 and idx == active_idx:
		_show_move_targets(idx)
		return
	# Otherwise just switch the active character.
	active_idx = idx
	selected_card = -1
	move_targets = {}
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
	# Area self-cast cards (Taunt / Aura of Valor): no single target to tap, but the
	# radius matters — first tap arms + previews the reach indicator, second tap casts.
	if def.get("area", false):
		if selected_card != idx:
			selected_card = idx
			move_targets = {}
			var side: String = "enemies" if def.get("area_affects", "") == "enemy" else "allies"
			_log("%s — tap again to cast (%s in range)" % [def["name"], side])
			_refresh()
		else:
			if not _can_play(a, cid, def):
				return
			_spend(a, idx)
			_resolve(def, a, {})   # radius handled inside the resolve ops
			_finish_play(a, def, cid)
		return
	# Pure-self and Cleave: single tap plays right away (Cleave is range-gated per enemy).
	if tgt == "self" or tgt == "all_enemies":
		if not _can_play(a, cid, def):
			return
		var in_range: Array = []
		if tgt == "all_enemies":
			var rng: int = _card_range(def, a)
			for e: Dictionary in enemies:
				if e["alive"] and grid_distance(a["pos"], e["pos"]) <= rng:
					in_range.append(e)
			if in_range.is_empty():
				_log("Out of range — move closer.")
				return
		_spend(a, idx)
		if tgt == "all_enemies":
			for e: Dictionary in in_range:
				_resolve(def, a, e)
		else:
			_resolve(def, a, {})
		_finish_play(a, def, cid)
		return
	if selected_card != idx:
		selected_card = idx                      # inspect + arm target card
		move_targets = {}                         # stop stale movement tiles from staying clickable
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
	var rng: int = _card_range(def, a)
	if grid_distance(a["pos"], enemies[e_idx]["pos"]) > rng:
		_log("Out of range — move closer.")
		return
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
	var rng: int = _card_range(def, a)
	if grid_distance(a["pos"], party[c_idx]["pos"]) > rng:
		_log("Out of range — move closer.")
		return
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
	move_targets = {}
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
				# Taunt now only grips enemies within the card's radius of the caster.
				var taunt_rng: int = _card_range(def, a)
				for e: Dictionary in enemies:
					if e["alive"] and grid_distance(a["pos"], e["pos"]) <= taunt_rng:
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
				# Aura now blesses only allies within the card's radius of the caster.
				if op[1] == "attack":
					var aura_rng: int = _card_range(def, a)
					for ally: Dictionary in party:
						if ally["alive"] and grid_distance(a["pos"], ally["pos"]) <= aura_rng:
							ally["attack_buff"] += op[2]

## Damage to an ENEMY (resolution order: base -> +flat -> xMark -> block,hp).
func _attack(a: Dictionary, enemy: Dictionary, base: int, is_attack: bool) -> void:
	if enemy.is_empty() or not enemy.get("alive", false):
		return
	var amt: int = base
	if is_attack:
		if a["temp"]["channel_charges"] > 0:
			amt += a["temp"]["channel_bonus"]
			a["temp"]["channel_charges"] -= 1
		amt += int(a["attack_buff"])
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
	_refresh_tiles()
	var preview: Dictionary = _preview_plans()
	_refresh_enemies(preview)
	_refresh_party()
	_refresh_threats(preview)
	_refresh_panel()
	_rebuild_hand()
	end_turn_btn.disabled = phase != "playerTurn"
	end_turn_btn.visible = not overlay.visible
	_update_cursor()

func _refresh_tiles() -> void:
	var rng_tiles: Dictionary = _range_tiles()
	for i: int in range(tile_cells.size()):
		var coord: Vector2i = tile_coords[i]
		if move_targets.has(coord):
			tile_cells[i].color = TILE_MOVE
		elif rng_tiles.has(coord):
			tile_cells[i].color = TILE_RANGE
		else:
			tile_cells[i].color = TILE_DEFAULT

## Tiles within the armed card's effective reach of the active dwarf (Manhattan
## radius, NOT path-constrained). Empty when nothing is armed or the armed card is
## pure-self (range 0). Drives the orange reach indicator + makes range readable.
func _range_tiles() -> Dictionary:
	if phase != "playerTurn" or selected_card < 0:
		return {}
	var rng: int = _card_range(_armed_def(), party[active_idx])
	if rng <= 0:
		return {}
	var center: Vector2i = party[active_idx]["pos"]
	var tiles: Dictionary = {}
	for y: int in range(GRID_H):
		for x: int in range(GRID_W):
			var c := Vector2i(x, y)
			if grid_distance(center, c) <= rng:
				tiles[c] = true
	return tiles

func _refresh_enemies(preview: Dictionary) -> void:
	var arm: Dictionary = _armed_def()
	# Enemy-target cards OR an area card whose radius grips enemies (Taunt) light up
	# the enemies within reach.
	var can: bool = arm.get("target", "") in ["enemy", "ally_or_enemy"] \
		or (arm.get("area", false) and arm.get("area_affects", "") == "enemy")
	var rng: int = _card_range(arm, party[active_idx])
	var a_pos: Vector2i = party[active_idx]["pos"]
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
		if preview.has(i):
			var t: Dictionary = preview[i]["target"]
			var plan: Dictionary = preview[i]["plan"]
			var abbr: String = t["name"].substr(0, 3)
			en_intent[i].text = ("🗡️%d>%s" % [e["atk"], abbr]) if plan["will_attack"] else ("🏃>%s" % abbr)
		else:
			en_intent[i].text = ""
		# Highlight valid enemy targets while an enemy-target card is armed, range-gated.
		var in_range: bool = can and selected_card >= 0 and grid_distance(a_pos, e["pos"]) <= rng
		en_emoji[i].modulate = Color(1.3, 1.05, 0.6) if in_range else Color.WHITE

func _refresh_party() -> void:
	var arm: Dictionary = _armed_def()
	# Ally-target cards OR an area card whose radius blesses allies (Aura) light up
	# the allies within reach.
	var ally_arm: bool = selected_card >= 0 and (arm.get("target", "") in ["ally", "ally_or_enemy"] \
		or (arm.get("area", false) and arm.get("area_affects", "") == "ally"))
	var rng: int = _card_range(arm, party[active_idx])
	var a_pos: Vector2i = party[active_idx]["pos"]
	for i: int in range(3):
		var a: Dictionary = party[i]
		var alive: bool = a["alive"]
		pc_outline[i].visible = alive and i == active_idx and phase == "playerTurn"
		pc_emoji[i].scale = Vector2(1.12, 1.12) if (alive and i == active_idx) else Vector2.ONE
		pc_name[i].text = a["name"]
		if alive:
			var in_range: bool = ally_arm and grid_distance(a_pos, a["pos"]) <= rng
			pc_emoji[i].modulate = Color(0.5, 1.0, 0.6) if in_range else Color.WHITE
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
			pc_energy[i].text = "⚡%d/%d 🏃%d" % [a["energy"], a["max_energy"], a["move_left"]]
		else:
			pc_emoji[i].modulate = Color(0.35, 0.35, 0.38)
			pc_hp[i].text = "DOWNED"
			pc_block[i].text = ""
			pc_energy[i].text = ""

func _refresh_threats(preview: Dictionary) -> void:
	var solid: Array = []
	var drift: Array = []
	if phase == "playerTurn":
		for i: int in range(enemies.size()):
			if not preview.has(i):
				continue
			var e: Dictionary = enemies[i]
			var t: Dictionary = preview[i]["target"]
			var plan: Dictionary = preview[i]["plan"]
			var pair: Dictionary = {"from": tile_to_screen(e["pos"]), "to": tile_to_screen(t["pos"])}
			if plan["will_attack"]:
				solid.append(pair)
			else:
				drift.append(pair)
	threat.set_threats(solid)
	threat_drift.set_threats(drift)

func _refresh_panel() -> void:
	if phase == "playerTurn":
		var a: Dictionary = party[active_idx]
		var ab: int = int(a["attack_buff"])
		var aura: String = "   📣+%d atk" % ab if ab > 0 else ""
		active_label.text = "%s  %s   ⚡%d/%d 🏃%d/%d%s" % [a["emoji"], a["name"], a["energy"], a["max_energy"], a["move_left"], a["move"], aura]
		if not move_targets.is_empty():
			hint_label.text = "Tap a highlighted tile to move"
		else:
			hint_label.text = "Tap your dwarf to move • tap a card to play (target cards: tap a target)"
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
		var face: Dictionary = Db.describe(def, a, int(a["attack_buff"]), attacks_this_turn)
		# Grid-only: surface the card's effective reach on its face (radius for area cards,
		# range for targeted cards; pure-self range-0 cards show nothing).
		var eff_rng: int = _card_range(def, a)
		if def.get("area", false):
			face = {"text": face["text"] + "\n📣 radius %d" % eff_rng, "buffed": face["buffed"]}
		elif eff_rng > 0:
			face = {"text": face["text"] + "\n🎯 range %d" % eff_rng, "buffed": face["buffed"]}
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

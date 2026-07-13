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
const MINI_SIZE := Vector2(34, 48)   # tiny hand-card under a non-active dwarf
const VULN_MULT := 1.5   # Vulnerable enemies take +50% (stacks multiplicatively with Mark's +25%)
# Scaling audit (2026-07-01): HP scales at full enemy_scale (fights get longer/costlier), but
# damage+block scale at this damped rate — pure damage scaling is what makes cells impossible.
const ATK_SCALE_K := 0.65
const RAGE_CAP := 8      # Howl ramp is an enrage clock, not a divergence

## Overworld mesh (Phase 1): a non-empty `request` makes this scene run as a CHILD of the
## overworld — party/enemies come from `request`, and `_end` emits `combat_finished` instead of
## showing Play-Again. An EMPTY request = standalone behaviour, byte-identical to before.
signal combat_finished(result)
var request: Dictionary = {}
## True when a CAMPAIGN scene owns us (we are its child, mid-expedition). Nested combat must hand
## control BACK to that parent — never change_scene to the lobby, which would delete the campaign.
var nested := false
var _match_done := false   # match_over is fire-and-forget and may arrive twice; resolve once

# ---------------------------------------------------------------- State
var party: Array = []          # 3 char dicts: 0 warrior, 1 cleric, 2 sorcerer
var enemies: Array = []        # 3 enemy dicts
var phase := ""                # playerTurn / enemyTurn / win / lose
var turn := 0
var active_idx := 0            # selected character
var selected_uid := ""         # uid of the armed card in the active char's hand ("" = none)
var _card_uid_seq := 0
# --- co-op scaffolding (inert in SOLO) ---
var my_seat := 0
var _seat_count := 1
var _seq := 0
var _last_board_seq := -1
var _action_nonce := 0
var _barrier_open := true
var _ready_seats := {}
var _seat_ready: Array = []
var party_attack_buff := 0     # Aura of Valor (this player phase)
var taunt_last_turn := -99
var attacks_this_turn := 0   # party-wide, this player phase (feeds Arcane Finisher)
var combat_epoch := 0
enum Mode { SOLO, AUTHORITY, CLIENT }   # SOLO = today's local game; AUTHORITY/CLIENT wired in M3
var mode: int = Mode.SOLO
var party_n := 3               # combat party size (2-4); pc_pos is sized to it
var pc_pos: Array = []         # runtime party portrait centers (set in _build_ui)
var _hand_anim := ""       # one-shot on next _refresh: "deal" (phase start) / "switch" (active change)
var _switch_from := -1     # who just went inactive (their mini row animates in on "switch")
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
var pc_minis: Array = []   # per-slot container for the tiny hand row (non-active dwarves)

var threat: Node2D
var intent_panel: Control       # hover/tap explainer for an enemy's telegraphed move
var ip_title: Label
var ip_body: Label
var ip_next: Label
var ip_pref: Label
var intent_open := -1           # enemy index the intent panel is showing, -1 = hidden
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
const PARTY_MAX := 4
# Debug hotseat: force a party size (2/4) when no request.crew is supplied. 0 = off (SOLO 3).
const DEBUG_PARTY_N := 0

# ================================================================ Lifecycle
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Co-op handoff from the lobby (consume-and-clear: a later SOLO run must not inherit it).
	if request.is_empty() and not Net.combat_request.is_empty():
		request = Net.combat_request
		Net.combat_request = {}
	# Parse the net block ONCE. Standalone ({}), and the overworld's child (request without a
	# "net" key), both land on SOLO — so neither ever touches Net.
	var net: Dictionary = request.get("net", {})
	var m: String = str(net.get("mode", ""))
	mode = Mode.AUTHORITY if m == "authority" else (Mode.CLIENT if m == "client" else Mode.SOLO)
	my_seat = int(net.get("seat", 0))
	_seat_count = int(net.get("seat_count", 1))
	nested = bool(request.get("nested", false))
	if mode != Mode.SOLO:
		Net.ensure_peer_id()
		Net.message_received.connect(_on_net_message)
		Net.realtime_joined.connect(_on_net_rejoined)   # a dropped socket re-dials; re-sync on the way back
		Net.resumed_from_sleep.connect(_on_woke_up)
		if mode == Mode.AUTHORITY:
			# Only the host announces the result. A client emits combat_finished for ITS OWN parent
			# (see _client_match_over) and must not echo match_over back onto the wire.
			combat_finished.connect(_on_match_finished_local)
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
	party_n = _effective_crew().size()
	pc_pos = _party_layout(party_n)
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

	# enemy-intent explainer panel (hover/tap an enemy) — lives in the free band above the enemy row
	intent_panel = Control.new()
	intent_panel.visible = false
	intent_panel.z_index = 60
	intent_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(intent_panel)
	var ipbg := ColorRect.new()
	ipbg.color = Color(0.07, 0.07, 0.10, 0.97)
	ipbg.size = Vector2(480, 92)
	ipbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	intent_panel.add_child(ipbg)
	var ipedge := ColorRect.new()
	ipedge.color = Color(1, 1, 1, 0.14)
	ipedge.size = Vector2(480, 1)
	ipedge.position = Vector2(0, 91)
	ipedge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	intent_panel.add_child(ipedge)
	ip_title = _label("", Vector2(10, 4), Vector2(460, 20), 15, false)
	ip_title.reparent(intent_panel, false)
	ip_body = _label("", Vector2(10, 27), Vector2(460, 18), 12, false)
	ip_body.add_theme_color_override("font_color", Color(0.78, 0.78, 0.82))
	ip_body.reparent(intent_panel, false)
	ip_next = _label("", Vector2(10, 47), Vector2(460, 18), 12, false)
	ip_next.add_theme_color_override("font_color", Color(0.95, 0.80, 0.45))
	ip_next.reparent(intent_panel, false)
	ip_pref = _label("", Vector2(10, 68), Vector2(460, 18), 11, false)
	ip_pref.add_theme_color_override("font_color", Color(0.62, 0.70, 0.80))
	ip_pref.reparent(intent_panel, false)

	for i: int in range(party_n):
		_build_party_slot(i)

	# (moved below the mini-hand band at y≈798-846)
	active_label = _label("", Vector2(20, 852), Vector2(680, 26), 20)
	hint_label = _label("", Vector2(20, 880), Vector2(680, 22), 15)

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
	# Intent explainer: hover on desktop; on touch the emulated cursor "enters" on tap and
	# "exits" on the next tap elsewhere, so the same signals give tap-to-inspect for free.
	e.mouse_entered.connect(_open_intent.bind(i))
	e.mouse_exited.connect(_close_intent.bind(i))
	en_emoji.append(e)
	en_name.append(_label("", Vector2(pos.x - 80, pos.y - 74), Vector2(160, 20), 14))
	en_intent.append(_label("", Vector2(pos.x - 80, pos.y - 52), Vector2(160, 22), 18))
	en_hp.append(_label("", Vector2(pos.x - 80, pos.y + 40), Vector2(160, 20), 16))
	en_block.append(_label("", Vector2(pos.x - 80, pos.y + 60), Vector2(160, 18), 14))

func _build_party_slot(i: int) -> void:
	var pos: Vector2 = pc_pos[i]
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
	# Tiny hand row (this dwarf's cards while NOT active) sits right under the stat block.
	var mb := Control.new()
	mb.position = Vector2(pos.x - 89, 798)
	mb.size = Vector2(178, 50)
	mb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(mb)
	pc_minis.append(mb)

# ================================================================ Combat start
## The crew for this combat: request.crew when supplied (2-4), else a synthesized party
## (DEBUG_PARTY_N size for hotseat testing, otherwise the SOLO 3 from PARTY_ORDER).
func _effective_crew() -> Array:
	var crew: Array = request.get("crew", [])
	if crew.size() >= 2 and crew.size() <= PARTY_MAX:
		return crew
	var n: int = DEBUG_PARTY_N if (DEBUG_PARTY_N >= 2 and DEBUG_PARTY_N <= PARTY_MAX) else 3
	var out: Array = []
	for i: int in range(n):
		out.append({"cls": Db.PARTY_ORDER[i % Db.PARTY_ORDER.size()]})
	return out

## Party portrait centers, sized to N. N == 3 keeps the exact original layout (SOLO
## behavior-equivalent); N == 2/4 spread evenly across the 720 width.
func _party_layout(n: int) -> Array:
	if n == 3:
		return PC_POS.duplicate()
	var out: Array = []
	var slot_w: float = 720.0 / float(n)
	for i: int in range(n):
		out.append(Vector2(slot_w * (float(i) + 0.5), 700.0))
	return out

func _next_uid() -> String:
	_card_uid_seq += 1
	return "c%d" % _card_uid_seq

func _next_seq() -> int:
	_seq += 1
	return _seq

func _next_nonce() -> int:
	_action_nonce += 1
	return _action_nonce

func _hand_index_of(a: Dictionary, uid: String) -> int:
	if uid == "":
		return -1
	return (a.get("hand_uids", []) as Array).find(uid)

func _start_combat() -> void:
	combat_epoch += 1
	_card_uid_seq = 0
	party = []
	var crew_specs: Array = _effective_crew()
	for i: int in range(crew_specs.size()):
		var spec: Dictionary = crew_specs[i]
		var cid: String = spec["cls"]
		var cls: Dictionary = Db.CLASSES[cid]
		var deck: Array = (spec.get("deck", cls["deck"]) as Array).duplicate()
		deck.shuffle()
		party.append({
			"role": cls["role"], "name": spec.get("name", cls["name"]), "emoji": cls["emoji"],
			"hp": int(spec.get("hp", cls["max_hp"])), "max_hp": int(spec.get("max_hp", cls["max_hp"])), "block": 0,
			"energy": cls["energy"], "max_energy": cls["energy"],
			# A crew member sent in at 0 HP (a downed dwarf on a hex expedition) starts as a benched slot.
			# Standalone/mesh crews always have hp > 0, so this stays byte-identical for those paths.
			"alive": int(spec.get("hp", cls["max_hp"])) > 0,
			"deck": deck, "hand": [], "hand_uids": [], "discard": [], "played_turn": [],
			"vulnerable": 0,   # enemy Expose/Hex: takes x1.5 from enemy hits, decays 1/player-phase
			"temp": _fresh_temp(), "shield": 0, "attacks_this_turn": 0,
			"momentum": 0, "devotion": 0,   # Warrior/Cleric signature counters (reset each player phase)
			"node": pc_emoji[i], "slot": i,
		})

	enemies = []
	var enc: Array = request.get("enemies", Db.ENCOUNTER)
	var escale: float = float(request.get("enemy_scale", 1.0))
	for i: int in range(enc.size()):
		var eid: String = enc[i]
		var ed: Dictionary = Db.ENEMIES[eid]
		# HP scales at full escale; damage/block at the damped dscale (hard, not impossible).
		var dscale: float = 1.0 + (escale - 1.0) * ATK_SCALE_K
		var ehp: int = int(round(float(ed["max_hp"]) * escale))
		var eatk: int = int(round(float(ed["atk"]) * dscale))
		# Move rotation: damage/block amounts pre-scaled by dscale; rage stays flat (small permanent +).
		var mvs: Array = []
		for m: Dictionary in ed.get("moves", []):
			var mv: Dictionary = m.duplicate()
			if mv.has("dmg"):
				mv["dmg"] = int(round(float(mv["dmg"]) * dscale))
			if mv.has("amt") and mv["kind"] in ["block", "guard_all"]:
				mv["amt"] = int(round(float(mv["amt"]) * dscale))
			if mv.has("ally_amt"):
				mv["ally_amt"] = int(round(float(mv["ally_amt"]) * dscale))
			mvs.append(mv)
		enemies.append({
			"archetype": eid, "name": ed["name"], "emoji": ed["emoji"],
			"hp": ehp, "max_hp": ehp, "block": 0, "atk": eatk,
			"pref": ed["pref"], "alive": true, "marked": false, "forced": false,
			"burn": 0, "vulnerable": 0,   # status debuffs (Kindle / Guard Break)
			"moves": mvs, "move_i": (randi() % mvs.size()) if not mvs.is_empty() else 0,   # random offset desyncs duplicates
			"rage": 0,                    # permanent +atk from Howl (rage_all)
			"intent_target": -1, "node": en_emoji[i], "slot": i,
		})

	turn = 0
	taunt_last_turn = -99
	phase = ""
	overlay.visible = false
	intent_open = -1
	intent_panel.visible = false
	for i: int in range(enemies.size()):
		en_emoji[i].text = enemies[i]["emoji"]
		en_emoji[i].modulate = Color.WHITE
		en_emoji[i].scale = Vector2.ONE
	for i: int in range(party.size()):
		pc_emoji[i].text = party[i]["emoji"]
		pc_emoji[i].modulate = Color.WHITE
		pc_emoji[i].scale = Vector2.ONE
	_seat_ready = []
	for s: int in range(party.size()):
		_seat_ready.append(false)
	_log("The demon lord convenes the raid. Sequence your dwarves.")
	match mode:
		Mode.AUTHORITY:
			# Deal every seat's opening hand up front so the barrier can answer a join instantly.
			_barrier_open = false
			_ready_seats.clear()
			_start_player_phase()
		Mode.CLIENT:
			# No local draw: the board (and this seat's hand) arrive with the authority's snapshot.
			active_idx = my_seat
			phase = ""
			_log("Joining the raid…")
			_refresh()
			_client_hello()
			_start_hello_retry()
		_:
			_start_player_phase()

func _fresh_temp() -> Dictionary:
	# fortify -> Retaliate +2 (persists through enemy phase); fortify_guard -> next Guard +5 (consumed)
	# next_attack_bonus (Whetstone) / double_next (Empower) / retain_block (Bracing Stance) are one-turn flags.
	return {"retaliate": 0, "fortify": false, "fortify_guard": false, "channel_charges": 0, "channel_bonus": 0,
		"next_attack_bonus": 0, "double_next": false, "retain_block": false}

# ================================================================ Phase flow
func _start_player_phase() -> void:
	turn += 1
	for a: Dictionary in party:
		if not a["alive"]:
			continue
		# Bracing Stance: block set to keep through the next turn instead of zeroing.
		if not bool(a["temp"].get("retain_block", false)):
			a["block"] = 0
		a["energy"] = a["max_energy"]
		a["temp"] = _fresh_temp()
		a["shield"] = 0
		a["momentum"] = 0
		a["devotion"] = 0
		a["attacks_this_turn"] = 0
		a["played_turn"] = []
		a["vulnerable"] = maxi(0, int(a.get("vulnerable", 0)) - 1)   # Expose/Hex wears off
		_draw_cards(a, HAND_SIZE)
	for e: Dictionary in enemies:
		e["marked"] = false
		e["forced"] = false
		e["vulnerable"] = maxi(0, int(e.get("vulnerable", 0)) - 1)   # Vulnerable counts down each turn (Burn ticks separately)
	party_attack_buff = 0
	attacks_this_turn = 0
	selected_uid = ""
	# Nobody has called the new turn yet. (SOLO writes this too, and simply never reads it.)
	_seat_ready = []
	for s: int in range(party.size()):
		_seat_ready.append(false)
	# In co-op you always pilot your own dwarf; SOLO/hotseat starts on the first living one.
	active_idx = my_seat if mode != Mode.SOLO else _first_living_party()
	phase = "playerTurn"
	_hand_anim = "deal"   # everyone visibly draws: minis + the active hand fly from the portraits
	_refresh()

func _on_end_turn() -> void:
	if phase != "playerTurn":
		return
	if mode == Mode.SOLO:
		for a: Dictionary in party:
			for c: String in a["hand"]:
				a["discard"].append(c)
			a["hand"].clear()
			a["hand_uids"].clear()
		selected_uid = ""
		phase = "enemyTurn"
		_refresh()
		await _enemy_phase()
		return
	# Co-op: you end YOUR OWN turn. The enemy only moves once every living dwarf has called it.
	if not _barrier_open or _seat_ended(my_seat):
		return
	if mode == Mode.CLIENT:
		Net.send_message("ready", {"seat": my_seat, "peer_id": Net.ensure_peer_id()})
		selected_uid = ""
		_refresh()   # the host's snapshot brings back the marker and the emptied hand
	else:
		_authority_set_ready(my_seat)

func _seat_ended(seat: int) -> bool:
	return seat >= 0 and seat < _seat_ready.size() and bool(_seat_ready[seat])

func _all_alive_ended() -> bool:
	for i: int in range(party.size()):
		if party[i]["alive"] and not _seat_ended(i):
			return false
	return true

func _waiting_on() -> int:
	var n := 0
	for i: int in range(party.size()):
		if party[i]["alive"] and not _seat_ended(i):
			n += 1
	return n

## Authority: a seat has called its turn. Ending discards that seat's hand — exactly what SOLO's
## End Turn does for everyone at once — which is also what stops you playing after you called it.
## The enemy phase runs only once every LIVING dwarf has ended (a downed one can't hold the turn).
func _authority_set_ready(seat: int) -> void:
	if mode != Mode.AUTHORITY or phase != "playerTurn" or not _barrier_open:
		return
	if seat < 0 or seat >= party.size() or not party[seat]["alive"] or _seat_ended(seat):
		return
	_seat_ready[seat] = true
	var a: Dictionary = party[seat]
	for c: String in a["hand"]:
		a["discard"].append(c)
	a["hand"].clear()
	a["hand_uids"].clear()
	if seat == active_idx:
		selected_uid = ""
	if not _all_alive_ended():
		_log("%s ends the turn — waiting on %d more." % [a["name"], _waiting_on()])
		_refresh()
		_net_board()
		return
	selected_uid = ""
	phase = "enemyTurn"
	_refresh()
	_net_board()
	await _enemy_phase()

func _enemy_phase() -> void:
	var epoch: int = combat_epoch
	# Last turn's enemy stances (Ward/Brace/Bulwark) drop as the new enemy turn opens — cleared
	# phase-wide, NOT per action, so a mid-phase Bulwark also shields allies acting after the Warden.
	for e: Dictionary in enemies:
		e["block"] = 0
	# Burn ticks at the start of the enemy turn (status damage — ignores block, then decays by 1).
	var any_burn := false
	for e: Dictionary in enemies:
		if e["alive"] and int(e.get("burn", 0)) > 0:
			any_burn = true
			var b: int = int(e["burn"])
			e["hp"] = maxi(0, e["hp"] - b)
			if e["hp"] <= 0:
				e["alive"] = false
			e["burn"] = maxi(0, b - 1)
			_flash(e)
			_impact(e, b)
	if any_burn:
		_refresh()
		_net_board()
		if _check_end():
			return
		await get_tree().create_timer(0.35).timeout
		if epoch != combat_epoch:
			return
	for e: Dictionary in enemies:
		if not e["alive"]:
			continue
		await get_tree().create_timer(0.45).timeout
		if epoch != combat_epoch:
			return
		_do_enemy_move(e, _enemy_move(e))
		e["move_i"] = int(e["move_i"]) + 1   # rotation advances; the intent label now telegraphs next turn
		_refresh()
		# SOLO: no-op. AUTHORITY (M3a): clients watch the numbers move beat-by-beat.
		# M3b replaces this with the folded event bundle + a VFX replay on every peer.
		_net_board()
		if _check_end():
			return
	await get_tree().create_timer(0.25).timeout
	if epoch != combat_epoch:
		return
	_start_player_phase()
	_net_board()   # fresh hands were just dealt off the authority's RNG

## The move this enemy is committed to (latched by construction: move_i only advances after acting).
## An entry without a rotation falls back to the classic flat attack.
func _enemy_move(e: Dictionary) -> Dictionary:
	var mvs: Array = e.get("moves", [])
	if mvs.is_empty():
		return {"name": "Attack", "emoji": "🗡️", "kind": "attack", "dmg": int(e["atk"]), "tip": "A plain attack."}
	return mvs[int(e["move_i"]) % mvs.size()]

## Per-hit damage of an attack-kind move: move damage + accumulated rage (Howl).
func _move_dmg(e: Dictionary, mv: Dictionary) -> int:
	return int(mv.get("dmg", e["atk"])) + int(e.get("rage", 0))

## What a Howl would actually add (telegraphs stay truthful once rage hits the cap).
func _rage_gain(e: Dictionary, mv: Dictionary) -> int:
	return mini(int(mv["amt"]), RAGE_CAP - int(e.get("rage", 0)))

func _do_enemy_move(e: Dictionary, mv: Dictionary) -> void:
	match mv["kind"]:
		"attack":
			var t: Dictionary = _enemy_target(e)
			if not t.is_empty():
				_enemy_attack(e, t, _move_dmg(e, mv))
		"multi":
			var t: Dictionary = _enemy_target(e)
			for h: int in range(int(mv.get("hits", 1))):
				# Retaliate can kill the attacker mid-flurry — the dead don't finish their swings.
				if t.is_empty() or not t.get("alive", false) or not e.get("alive", false):
					break
				_enemy_attack(e, t, _move_dmg(e, mv))
		"attack_all":
			for a: Dictionary in party:
				if not e.get("alive", false):
					break
				if a["alive"]:
					_enemy_attack(e, a, _move_dmg(e, mv))
			_log("%s's %s rakes the whole party!" % [e["name"], mv["name"]])
		"block":
			e["block"] += int(mv["amt"])
			_flash(e)
			_log("%s braces — %d block." % [e["name"], int(mv["amt"])])
		"guard_all":
			for o: Dictionary in enemies:
				if o["alive"]:
					o["block"] += int(mv["amt"]) if o == e else int(mv.get("ally_amt", 0))
					_flash(o)
			_log("%s walls the enemy line!" % e["name"])
		"rage_all":
			var gain: int = _rage_gain(e, mv)
			for o: Dictionary in enemies:
				if o["alive"]:
					o["rage"] = mini(int(o.get("rage", 0)) + int(mv["amt"]), RAGE_CAP)
					_flash(o)
			if gain > 0:
				_log("%s howls — the pack rages (+%d attack)!" % [e["name"], gain])
			else:
				_log("%s howls, but the pack's fury is already at its peak." % e["name"])
		"expose":
			var t: Dictionary = _enemy_target(e)
			if not t.is_empty():
				t["vulnerable"] = int(t.get("vulnerable", 0)) + int(mv["amt"])
				_flash(t)
				_log("%s exposes %s — x1.5 from enemy hits!" % [e["name"], t["name"]])

# ================================================================ Targeting (enemy preference)
## Role-based (NOT slot-indexed) so a non-canonical crew (e.g. {W,W,S} with no Cleric) targets
## correctly. Byte-identical to the old party[0/1/2] logic for the canonical W/C/S trio.
func _enemy_target(e: Dictionary) -> Dictionary:
	if e["forced"]:
		var w: Dictionary = _first_living_role("warrior")   # Taunt -> a Warrior
		if not w.is_empty():
			return w
	match e["pref"]:
		"tankiest":
			return _pick_tankiest()
		"healer_dps":
			var c: Dictionary = _first_living_role("cleric")     # Healer first
			if not c.is_empty():
				return c
			var nt: Dictionary = _first_living_nontank()         # then any non-tank (DPS)
			if not nt.is_empty():
				return nt
			return _pick_lowest_hp()
		"lowest_hp":
			return _pick_lowest_hp()
		_:
			return _pick_lowest_hp()

func _first_living_role(role: String) -> Dictionary:
	for a: Dictionary in party:
		if a["alive"] and a["role"] == role:
			return a
	return {}

func _first_living_nontank() -> Dictionary:
	for a: Dictionary in party:
		if a["alive"] and a["role"] != "warrior":
			return a
	return {}

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

# ================================================================ Co-op net (M3a)
## Host-authoritative: ONE peer owns the RNG and runs every mutation; the others send action
## intents and render absolute snapshots. Snapshots are MERGED field-by-field into the local
## dicts — never assigned over them, because `node` (the live Label), `deck` and `hand` are
## local-only keys that a wholesale replace would null out.
const _INT_KEYS := ["slot", "hp", "max_hp", "block", "shield", "energy", "max_energy",
	"vulnerable", "momentum", "devotion", "attacks_this_turn",
	"atk", "burn", "move_i", "rage", "intent_target"]
const _INT_KEYS_TEMP := ["retaliate", "channel_charges", "channel_bonus", "next_attack_bonus"]

func _build_snapshot() -> Dictionary:
	var ps: Array = []
	for a: Dictionary in party:
		var c: Dictionary = a.duplicate()   # SHALLOW copy: erasing on the live dict would kill node/deck
		c.erase("node")
		# Hands ride the snapshot: this is co-op WITH friends, so reading each other's cards is
		# the point — you plan the turn together. The draw pile is the only thing held back: it is
		# the authority's RNG state, and nobody should be able to read their future draws off it.
		c.erase("deck")
		ps.append(c)
	var es: Array = []
	for e: Dictionary in enemies:
		var d: Dictionary = e.duplicate()
		d.erase("node")
		d.erase("moves")   # every peer rebuilds identical pre-scaled moves from request.enemy_scale
		es.append(d)
	return {
		"seq": _next_seq(), "party": ps, "enemies": es,
		"globals": {
			"phase": phase, "turn": turn, "party_attack_buff": party_attack_buff,
			"taunt_last_turn": taunt_last_turn, "attacks_this_turn": attacks_this_turn,
			"combat_epoch": combat_epoch,
		},
		"ready": _seat_ready.duplicate(),
	}

## Merge, never replace. `incoming` carries no hand/hand_uids/deck/discard/node, so it
## physically cannot clobber them. JSON hands back floats — coerce the int leaves.
func _merge_into(local: Dictionary, incoming: Dictionary) -> void:
	for k in incoming:
		local[k] = incoming[k]
	for k: String in _INT_KEYS:
		if local.has(k):
			local[k] = int(local[k])
	if local.has("temp") and local["temp"] is Dictionary:
		for k: String in _INT_KEYS_TEMP:
			if (local["temp"] as Dictionary).has(k):
				local["temp"][k] = int(local["temp"][k])

func _apply_snapshot(snap: Dictionary, force := false) -> void:
	if party.is_empty() or enemies.is_empty():
		return
	var seq: int = int(snap.get("seq", 0))
	if not force and seq <= _last_board_seq:
		return
	if _last_board_seq >= 0 and seq > _last_board_seq + 1:
		_request_resync()   # gap — still apply it, absolute snapshots are idempotent
	_last_board_seq = seq
	var g: Dictionary = snap.get("globals", {})
	phase = str(g.get("phase", phase))
	turn = int(g.get("turn", turn))
	party_attack_buff = int(g.get("party_attack_buff", party_attack_buff))
	taunt_last_turn = int(g.get("taunt_last_turn", taunt_last_turn))
	attacks_this_turn = int(g.get("attacks_this_turn", attacks_this_turn))
	combat_epoch = int(g.get("combat_epoch", combat_epoch))
	_seat_ready = (snap.get("ready", _seat_ready) as Array).duplicate()
	for c: Dictionary in (snap.get("enemies", []) as Array):
		var eslot: int = int(c.get("slot", -1))
		if eslot < 0 or eslot >= enemies.size():
			continue
		_merge_into(enemies[eslot], c)
		enemies[eslot]["node"] = en_emoji[eslot]   # rebind the poison key from the slot
	for c: Dictionary in (snap.get("party", []) as Array):
		var cslot: int = int(c.get("slot", -1))
		if cslot < 0 or cslot >= party.size():
			continue
		_merge_into(party[cslot], c)
		party[cslot]["node"] = pc_emoji[cslot]
	_refresh()

func _request_resync() -> void:
	if mode == Mode.CLIENT:
		Net.send_message("resync", {"seat": my_seat})

func _peer_owns_seat(_peer_id: String, _seat: int) -> bool:
	return true   # M4: check against the lobby's peer -> seat map

## Every authority state change ends here. One absolute snapshot, one seq, every hand in it —
## so hand and hand_uids can never arrive out of step with each other.
func _net_board() -> void:
	if mode == Mode.AUTHORITY:
		Net.send_message("apply_snapshot", _build_snapshot())

# ---------------------------------------------------------------- Action plumbing
func _make_action(seat: int, uid: String, hand_index: int, target_kind: String, target_idx: int) -> Dictionary:
	return {"seat": seat, "peer_id": Net.ensure_peer_id(), "card_uid": uid,
		"hand_index": hand_index, "target_kind": target_kind, "target_idx": target_idx,
		"nonce": _next_nonce()}

## The ONE mutation path for a card play. SOLO, the host's own taps, and a client's action
## resolved on the host all funnel through here — a networked play is bit-identical to a local one.
func _apply_play(a: Dictionary, idx: int, cid: String, def: Dictionary, target_kind: String, target_idx: int) -> void:
	_spend(a, idx)
	match target_kind:
		"all":
			for e: Dictionary in enemies:
				if e["alive"]:
					_resolve(def, a, e)
		"enemy":
			_resolve(def, a, enemies[target_idx])
		"ally":
			_resolve(def, a, party[target_idx])
		_:
			_resolve(def, a, {})   # self / party: the ops loop over the party internally
	_finish_play(a, def, cid)

## Every tap routes here. CLIENT sends an intent and mutates nothing; AUTHORITY/SOLO resolve.
func _try_play(seat: int, uid: String, target_kind: String, target_idx: int) -> void:
	if seat < 0 or seat >= party.size():
		return
	var a: Dictionary = party[seat]
	var idx: int = _hand_index_of(a, uid)
	if idx < 0:
		return
	var cid: String = a["hand"][idx]
	var def: Dictionary = Db.CARDS[cid]
	if mode == Mode.CLIENT:
		if def["cost"] > a["energy"]:   # courtesy check only; the authority re-validates everything
			_log("Not enough energy for %s." % def["name"])
			return
		Net.send_message("submit_action", _make_action(seat, uid, idx, target_kind, target_idx))
		selected_uid = ""
		_refresh()   # NO local mutate: the card leaves my hand when the authority's hand msg lands
		return
	# The host waits at the same barrier it holds everyone else at: resolving a card before a
	# teammate has rendered the board would show them a fight already in progress.
	if mode == Mode.AUTHORITY and not _barrier_open:
		_log("Waiting for the other players…")
		return
	if not _can_play(a, cid, def):
		return
	_apply_play(a, idx, cid, def, target_kind, target_idx)
	_net_board()

## Authority: validate a client's action, resolve it, broadcast. Nothing here trusts the client.
func _on_action(act: Dictionary) -> void:
	if not _barrier_open or phase != "playerTurn":
		return
	var seat: int = int(act.get("seat", -1))
	if seat < 0 or seat >= party.size():
		return
	if not _peer_owns_seat(str(act.get("peer_id", "")), seat):
		return
	var a: Dictionary = party[seat]
	if not a["alive"]:
		return
	var idx: int = _hand_index_of(a, str(act.get("card_uid", "")))
	if idx < 0:
		return   # unknown or already-played uid — never slot-substitute
	var cid: String = a["hand"][idx]
	var def: Dictionary = Db.CARDS[cid]
	if not _can_play(a, cid, def):
		return
	var kind: String = str(act.get("target_kind", "self"))
	var t_idx: int = int(act.get("target_idx", -1))
	if not _valid_target(def, kind, t_idx):
		return
	var saved: String = selected_uid     # a teammate's play must not drop the host's own armed card
	_apply_play(a, idx, cid, def, kind, t_idx)
	selected_uid = saved
	_refresh()
	_net_board()

func _valid_target(def: Dictionary, kind: String, t_idx: int) -> bool:
	var want: String = def.get("target", "self")
	match kind:
		"enemy":
			if not (want in ["enemy", "ally_or_enemy"]):
				return false
			return t_idx >= 0 and t_idx < enemies.size() and enemies[t_idx]["alive"]
		"ally":
			if not (want in ["ally", "ally_or_enemy"]):
				return false
			return t_idx >= 0 and t_idx < party.size() and party[t_idx]["alive"]
		"all":
			return want == "all_enemies"
		_:
			return want == "self" or want == "party"

# ---------------------------------------------------------------- Transport
## Broadcast fans every message out to every subscriber; the mode guards drop the ones
## addressed to the other role (a client sees other clients' submit_action and ignores them).
func _on_net_message(event: String, payload: Dictionary) -> void:
	if mode == Mode.AUTHORITY:
		match event:
			"submit_action": _on_action(payload)
			"combat_ready": _authority_on_combat_ready(payload)
			"resync": _authority_on_resync(payload)
			"ready": _authority_set_ready(int(payload.get("seat", -1)))
	elif mode == Mode.CLIENT:
		match event:
			"apply_snapshot": _apply_snapshot(payload)
			"match_over": _client_match_over(payload)

## Combat-start barrier: the host holds play closed until every other seat has checked in, so
## an early host tap cannot resolve against a board its teammates have not rendered yet.
func _authority_on_combat_ready(payload: Dictionary) -> void:
	var seat: int = int(payload.get("seat", -1))
	if seat < 0 or seat >= party.size():
		return
	if not _peer_owns_seat(str(payload.get("peer_id", "")), seat):
		return
	_ready_seats[seat] = true
	_net_board()
	if not _barrier_open and _ready_seats.size() >= _seat_count - 1:
		_barrier_open = true
		_log("Everyone is in. Sequence your dwarves.")
		_refresh()   # the barrier gates End Turn, so the button has to be re-enabled here
		_net_board()

func _authority_on_resync(_payload: Dictionary) -> void:
	_net_board()

func _client_hello() -> void:
	if mode == Mode.CLIENT:
		Net.send_message("combat_ready", {"seat": my_seat, "peer_id": Net.ensure_peer_id()})

## The browser froze this tab and just let it run again. While frozen we were not playing, not
## checking in and not ending our turn — so to our teammates we looked like a player who would not
## move. Say so plainly: this is otherwise indistinguishable from the game being broken.
func _on_woke_up(asleep_ms: int) -> void:
	_log("⚠ This tab was asleep for %ds — browsers freeze background tabs. Keep it in front (two players on one PC: use two side-by-side WINDOWS, not tabs)." % int(asleep_ms / 1000.0))
	if mode == Mode.CLIENT:
		_client_hello()   # tell the host we are back; it answers with a fresh board

## The socket dropped and Net re-dialed (a backgrounded tab stalls the heartbeat). Whatever
## the board did while we were mute, an absolute snapshot repairs in one message.
func _on_net_rejoined() -> void:
	if mode == Mode.AUTHORITY:
		_net_board()
	elif mode == Mode.CLIENT:
		_client_hello()   # the host answers with a fresh snapshot

## Broadcast is fire-and-forget: keep knocking until the first snapshot proves the host heard us.
func _start_hello_retry() -> void:
	var t := Timer.new()
	t.wait_time = 1.5
	t.autostart = true
	add_child(t)
	t.timeout.connect(func() -> void:
		if _last_board_seq >= 0:
			t.queue_free()
		else:
			_client_hello())

## AUTHORITY only. The full result rides the wire, so every peer's parent scene reads the SAME
## crew_results — post-fight HP cannot diverge between host and client.
func _on_match_finished_local(result: Dictionary) -> void:
	_match_done = true
	Net.send_message("match_over", {
		"won": bool(result.get("success", false)),
		"crew_results": result.get("crew_results", []),
	})
	if not nested:
		_to_lobby()

## CLIENT only. Standalone: back to the lobby. Nested: the campaign is our parent and is awaiting
## combat_finished — re-emit the host's verdict verbatim so it can carry HP out of the fight.
func _client_match_over(payload: Dictionary) -> void:
	if _match_done:
		return
	_match_done = true
	if not nested:
		_to_lobby()
		return
	var won: bool = bool(payload.get("won", false))
	phase = "win" if won else "lose"
	combat_finished.emit({"success": won, "crew_results": payload.get("crew_results", []), "payout_won": won})

func _to_lobby() -> void:
	get_tree().change_scene_to_file("res://scenes/menu/lobby.tscn")

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
	if selected_uid != "":
		var def: Dictionary = _armed_def()
		if def.get("target", "") in ["ally", "ally_or_enemy"]:
			_try_play(active_idx, selected_uid, "ally", idx)
			return
	# In co-op you pilot exactly ONE dwarf. Tapping a teammate must never repoint active_idx —
	# that would hand you their hand and let you spend their turn for them.
	if mode != Mode.SOLO:
		return
	# Otherwise just switch the active character.
	if idx != active_idx:
		_hand_anim = "switch"      # new hand pops from the tapped dwarf...
		_switch_from = active_idx  # ...and the old one's mini row animates back in
	active_idx = idx
	selected_uid = ""
	_refresh()

func _on_enemy_clicked(idx: int) -> void:
	if phase != "playerTurn" or not enemies[idx]["alive"]:
		return
	if selected_uid == "":
		return
	var def: Dictionary = _armed_def()
	if def.get("target", "") in ["enemy", "ally_or_enemy"]:
		_try_play(active_idx, selected_uid, "enemy", idx)

func _armed_def() -> Dictionary:
	var a: Dictionary = party[active_idx]
	var idx := _hand_index_of(a, selected_uid)
	if idx < 0:
		return {}
	return Db.CARDS[a["hand"][idx]]

## Self/all-enemies cards have no target to pick, so a single tap plays them right away
## (hover already previews the tooltip on desktop). Target cards still arm on the first
## tap (shows tooltip + reticle) and play on a second tap of the target.
func _on_card_clicked(card) -> void:
	if phase != "playerTurn":
		return
	var a: Dictionary = party[active_idx]
	var idx: int = _hand_index_of(a, card.uid)   # resolve the tapped card by uid, never by index
	if idx < 0:
		return
	var cid: String = a["hand"][idx]
	var def: Dictionary = Db.CARDS[cid]
	var tgt: String = def["target"]
	if tgt == "self" or tgt == "all_enemies" or tgt == "party":
		_try_play(active_idx, card.uid, ("all" if tgt == "all_enemies" else "self"), -1)
		return
	if selected_uid != card.uid:
		selected_uid = card.uid                  # inspect + arm target card
		_log("%s — %s" % [def["name"], _select_hint(def)])
		_refresh()
	else:
		selected_uid = ""                       # deselect a target card
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

func _spend(a: Dictionary, idx: int) -> void:
	var cid: String = a["hand"][idx]
	a["energy"] -= Db.CARDS[cid]["cost"]
	a["hand"].remove_at(idx)
	a["hand_uids"].remove_at(idx)
	a["played_turn"].append(cid)   # ghosted in the mini row until next player phase

func _finish_play(a: Dictionary, def: Dictionary, cid: String) -> void:
	a["discard"].append(cid)
	if def.get("is_attack", false):
		attacks_this_turn += 1                             # party-wide count for Finisher
		a["momentum"] = int(a.get("momentum", 0)) + 1      # Warrior: per-char attacks this turn (Momentum Strike)
	else:
		a["devotion"] = int(a.get("devotion", 0)) + 1      # Cleric: per-char skills this turn (Divine Smite spend)
	selected_uid = ""
	_log("%s played %s." % [a["name"], def["name"]])
	_refresh()
	_check_end()

# ================================================================ Resolver
## a = acting character; target = enemy OR ally char (or {} for self/none).
func _resolve(def: Dictionary, a: Dictionary, target: Dictionary) -> void:
	# Empower: the NEXT card resolved this turn has its numeric ops doubled, then the flag clears.
	var mult := 1
	if bool(a["temp"].get("double_next", false)):
		mult = 2
		a["temp"]["double_next"] = false
	_run_ops(def["effect"], a, target, mult, def.get("is_attack", false), def.get("fortifiable", false))

## Executes a list of [op, ...args]. Recurses for conditional ops (if_bloodied / on_kill / etc.).
## mult = Empower doubling; is_atk = whether damage ops route as attacks (get Channel/Aura/Mark);
## fortifiable = whether a `block` op earns Fortify's +5 (only the top-level Guard, never nested blocks).
func _run_ops(ops: Array, a: Dictionary, target: Dictionary, mult: int, is_atk: bool, fortifiable: bool) -> void:
	for op: Array in ops:
		match op[0]:
			"damage", "dmg":
				_attack(a, target, int(op[1]) * mult, is_atk)
			"dmg_all":
				for e: Dictionary in enemies:
					if e["alive"]:
						_attack(a, e, int(op[1]) * mult, is_atk)
			"dmg_per_momentum":
				_attack(a, target, int(a.get("momentum", 0)) * int(op[1]) * mult, is_atk)
			"damage_scaling":
				var base: int = op[2] + op[3] * attacks_this_turn
				_attack(a, target, base * mult, true)
			"block":
				var bonus: int = 0
				if a["temp"]["fortify_guard"] and fortifiable:
					bonus = 5
					a["temp"]["fortify_guard"] = false   # consume the +5; Retaliate +2 persists
				a["block"] += int(op[1]) * mult + bonus
			"party_block":
				for x: Dictionary in party:
					if x["alive"]:
						x["block"] += int(op[1]) * mult
			"self_damage", "self_dmg":
				a["hp"] = maxi(0, a["hp"] - int(op[1]))     # a cost — ignores block, not doubled by Empower
				if a["hp"] <= 0:
					a["alive"] = false
			"heal_self":
				a["hp"] = mini(a["max_hp"], a["hp"] + int(op[1]) * mult)
			"heal_ally":
				if not target.is_empty() and target.get("role", "") != "":
					target["hp"] = mini(target["max_hp"], target["hp"] + int(op[1]) * mult)
			"draw":
				_draw_cards(a, int(op[1]))
			"gain_energy":
				a["energy"] += int(op[1])
			"heal_or_damage":
				if target.get("role", "") != "":     # an ally char
					target["hp"] = mini(target["max_hp"], target["hp"] + int(op[1]) * mult)
				else:                                  # an enemy
					_attack(a, target, int(op[1]) * mult, false)
			"apply_status":
				if op[1] == "marked":
					target["marked"] = true
			"apply":
				if not target.is_empty() and target.get("alive", false):
					match op[1]:
						"burn":
							target["burn"] = int(target.get("burn", 0)) + int(op[2])
						"vulnerable":
							target["vulnerable"] = int(target.get("vulnerable", 0)) + int(op[2])
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
			"buff_next_attack":
				a["temp"]["next_attack_bonus"] = int(a["temp"].get("next_attack_bonus", 0)) + int(op[1]) * mult
			"retain_block":
				a["temp"]["retain_block"] = true
			"next_card_double":
				a["temp"]["double_next"] = true
			"shield_ally":
				target["shield"] += int(op[1]) * mult
			"party_buff":
				if op[1] == "attack":
					party_attack_buff += int(op[2]) * mult
			"if_bloodied":
				if a["hp"] * 2 <= a["max_hp"]:
					_run_ops(op[1], a, target, mult, is_atk, false)
			"if_target_marked":
				if not target.is_empty() and target.get("marked", false):
					_run_ops(op[1], a, target, mult, is_atk, false)
			"spend_devotion":
				if int(a.get("devotion", 0)) > 0:
					a["devotion"] = int(a["devotion"]) - 1
					_run_ops(op[1], a, target, mult, is_atk, false)
			"on_kill":
				if not target.is_empty() and not target.get("alive", true):
					_run_ops(op[1], a, target, mult, is_atk, false)

## Damage to an ENEMY (resolution order: base -> +flat -> xMark -> xVulnerable -> block,hp).
func _attack(a: Dictionary, enemy: Dictionary, base: int, is_attack: bool) -> void:
	if enemy.is_empty() or not enemy.get("alive", false):
		return
	var amt: int = base
	if is_attack:
		if a["temp"]["channel_charges"] > 0:
			amt += a["temp"]["channel_bonus"]
			a["temp"]["channel_charges"] -= 1
		if int(a["temp"].get("next_attack_bonus", 0)) > 0:   # Whetstone: one-shot flat bonus
			amt += int(a["temp"]["next_attack_bonus"])
			a["temp"]["next_attack_bonus"] = 0
		amt += party_attack_buff
	if enemy["marked"]:
		amt = int(round(amt * Db.MARK_MULT))
	if int(enemy.get("vulnerable", 0)) > 0:
		amt = int(round(amt * VULN_MULT))
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

## Enemy attacks a party character (xVulnerable -> shield -> block -> hp), then Retaliate fires.
func _enemy_attack(e: Dictionary, t: Dictionary, base: int = -1) -> void:
	var raw: int = base if base >= 0 else int(e["atk"])
	if int(t.get("vulnerable", 0)) > 0:
		raw = int(round(raw * VULN_MULT))
	var dmg: int = maxi(0, raw - int(t["shield"]))
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
		a["hand_uids"].append(_next_uid())

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
	selected_uid = ""
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
	_refresh_minis()
	# Co-op: everyone ends their own turn, so every peer gets the button.
	var ended: bool = mode != Mode.SOLO and _seat_ended(my_seat)
	var benched: bool = mode != Mode.SOLO and my_seat < party.size() and not party[my_seat]["alive"]
	end_turn_btn.text = "Waiting…" if ended else "End Turn"
	end_turn_btn.disabled = phase != "playerTurn" or not _barrier_open or ended or benched
	end_turn_btn.visible = not overlay.visible
	_update_cursor()
	_refresh_intent_panel()
	_hand_anim = ""   # one-shot: consumed by _rebuild_hand/_refresh_minis above
	_switch_from = -1

func _refresh_enemies() -> void:
	for i: int in range(3):
		var e: Dictionary = enemies[i]
		var alive: bool = e["alive"]
		en_emoji[i].visible = alive
		en_name[i].visible = alive
		en_intent[i].visible = alive
		en_hp[i].visible = alive
		var has_stat: bool = e["block"] > 0 or int(e.get("burn", 0)) > 0 or int(e.get("vulnerable", 0)) > 0
		en_block[i].visible = alive and has_stat
		if not alive:
			continue
		en_name[i].text = ("🎯 " if e["marked"] else "") + e["name"]
		en_hp[i].text = "%d/%d" % [e["hp"], e["max_hp"]]
		var estat := ""
		if e["block"] > 0:
			estat += "🛡️%d " % e["block"]
		if int(e.get("burn", 0)) > 0:
			estat += "🔥%d " % int(e["burn"])
		if int(e.get("vulnerable", 0)) > 0:
			estat += "💥 "
		en_block[i].text = estat
		en_intent[i].text = _intent_text(e)
		en_intent[i].add_theme_color_override("font_color", _intent_color(_enemy_move(e)["kind"]))
		# Highlight valid enemy targets while an enemy-target card is armed.
		var arm: Dictionary = _armed_def()
		var can: bool = arm.get("target", "") in ["enemy", "ally_or_enemy"]
		en_emoji[i].modulate = Color(1.3, 1.05, 0.6) if (can and selected_uid != "") else Color.WHITE

func _refresh_party() -> void:
	var arm: Dictionary = _armed_def()
	var ally_arm: bool = selected_uid != "" and arm.get("target", "") in ["ally", "ally_or_enemy"]
	for i: int in range(party.size()):
		var a: Dictionary = party[i]
		var alive: bool = a["alive"]
		pc_outline[i].visible = alive and i == active_idx and phase == "playerTurn"
		pc_emoji[i].scale = Vector2(1.12, 1.12) if (alive and i == active_idx) else Vector2.ONE
		# ✅ marks a dwarf whose player has already called their turn.
		pc_name[i].text = ("✅ " if (mode != Mode.SOLO and _seat_ended(i)) else "") + a["name"]
		if alive:
			pc_emoji[i].modulate = Color(0.5, 1.0, 0.6) if ally_arm else Color.WHITE
			pc_hp[i].text = "%d/%d" % [a["hp"], a["max_hp"]]
			var st := ""
			if a["block"] > 0:
				st += "🛡️%d " % a["block"]
			if a["shield"] > 0:
				st += "🔰%d " % a["shield"]
			if int(a.get("vulnerable", 0)) > 0:
				st += "💥%d " % a["vulnerable"]
			if int(a["temp"]["channel_charges"]) > 0:
				st += "🌀%d " % a["temp"]["channel_charges"]
			if a["temp"]["fortify_guard"] or a["temp"]["fortify"]:
				st += "🔧 "
			if int(a["temp"]["retaliate"]) > 0:
				st += "🔁%d" % a["temp"]["retaliate"]
			if int(a.get("momentum", 0)) > 0:
				st += "⚔️%d " % a["momentum"]
			if int(a.get("devotion", 0)) > 0:
				st += "🙏%d " % a["devotion"]
			if int(a["temp"].get("next_attack_bonus", 0)) > 0:
				st += "🪨+%d " % a["temp"]["next_attack_bonus"]
			if bool(a["temp"].get("double_next", false)):
				st += "✨"
			pc_block[i].text = st
			pc_energy[i].text = "⚡%d/%d" % [a["energy"], a["max_energy"]]
		else:
			pc_emoji[i].modulate = Color(0.35, 0.35, 0.38)
			pc_hp[i].text = "DOWNED"
			pc_block[i].text = ""
			pc_energy[i].text = ""

# ---------------------------------------------------------------- Intent telegraph
## Compact always-on readout of the latched move, with LIVE numbers (rage + target Vulnerable).
func _intent_text(e: Dictionary) -> String:
	var mv: Dictionary = _enemy_move(e)
	match mv["kind"]:
		"attack":
			return "%s%d>%s" % [mv["emoji"], _intent_hit(e, mv), _intent_tname(e)]
		"multi":
			return "%s%d×%d>%s" % [mv["emoji"], _intent_hit(e, mv), int(mv.get("hits", 1)), _intent_tname(e)]
		"attack_all":
			return "%s%d×all" % [mv["emoji"], _move_dmg(e, mv)]
		"block", "guard_all":
			return "%s%d" % [mv["emoji"], int(mv["amt"])]
		"rage_all":
			var g: int = _rage_gain(e, mv)
			return ("%s+%d" % [mv["emoji"], g]) if g > 0 else "%smax" % mv["emoji"]
		"expose":
			return "%s>%s" % [mv["emoji"], _intent_tname(e)]
	return str(mv["emoji"])

func _intent_hit(e: Dictionary, mv: Dictionary) -> int:
	var dmg: int = _move_dmg(e, mv)
	var t: Dictionary = _enemy_target(e)
	if not t.is_empty() and int(t.get("vulnerable", 0)) > 0:
		dmg = int(round(dmg * VULN_MULT))
	return dmg

func _intent_tname(e: Dictionary) -> String:
	var t: Dictionary = _enemy_target(e)
	return str(t["name"]).substr(0, 3) if not t.is_empty() else ""

func _intent_color(kind: String) -> Color:
	match kind:
		"attack", "multi", "attack_all":
			return Color(1.0, 0.55, 0.50)
		"block", "guard_all":
			return Color(0.62, 0.85, 1.0)
		"rage_all":
			return Color(0.98, 0.78, 0.35)
		"expose":
			return Color(0.85, 0.62, 1.0)
	return Color.WHITE

func _open_intent(i: int) -> void:
	if not enemies[i].get("alive", false) or overlay.visible:
		return
	intent_open = i
	_refresh_intent_panel()

func _close_intent(i: int) -> void:
	if intent_open == i:
		intent_open = -1
		intent_panel.visible = false

func _refresh_intent_panel() -> void:
	if intent_open < 0:
		return
	var e: Dictionary = enemies[intent_open]
	if not e["alive"] or overlay.visible:
		intent_open = -1
		intent_panel.visible = false
		return
	var mv: Dictionary = _enemy_move(e)
	var mvs: Array = e.get("moves", [])
	ip_title.text = "%s %s — %s" % [e["emoji"], e["name"], _intent_headline(e, mv)]
	ip_body.text = str(mv.get("tip", ""))
	if mvs.size() > 1:
		var nm: Dictionary = mvs[(int(e["move_i"]) + 1) % mvs.size()]
		ip_next.text = "Next: %s %s" % [nm["name"], _intent_brief(e, nm)]
	else:
		ip_next.text = ""
	ip_pref.text = str(Db.ENEMIES[e["archetype"]].get("tip", ""))
	intent_panel.position = Vector2(clampf(EN_POS[intent_open].x - 240.0, 8.0, 720.0 - 8.0 - 480.0), 40.0)
	intent_panel.visible = true

func _intent_headline(e: Dictionary, mv: Dictionary) -> String:
	var t: Dictionary = _enemy_target(e)
	var tn: String = str(t["name"]) if not t.is_empty() else "?"
	match mv["kind"]:
		"attack":
			return "%s: hits %s for %d" % [mv["name"], tn, _intent_hit(e, mv)]
		"multi":
			return "%s: %d hits of %d on %s" % [mv["name"], int(mv.get("hits", 1)), _intent_hit(e, mv), tn]
		"attack_all":
			return "%s: %d to EVERY dwarf" % [mv["name"], _move_dmg(e, mv)]
		"block":
			return "%s: blocks %d" % [mv["name"], int(mv["amt"])]
		"guard_all":
			return "%s: blocks %d, allies +%d" % [mv["name"], int(mv["amt"]), int(mv.get("ally_amt", 0))]
		"rage_all":
			var g: int = _rage_gain(e, mv)
			if g > 0:
				return "%s: ALL enemies +%d attack" % [mv["name"], g]
			return "%s: the pack's fury is at its peak" % mv["name"]
		"expose":
			return "%s: curses %s — x1.5 for a turn" % [mv["name"], tn]
	return str(mv["name"])

func _intent_brief(e: Dictionary, mv: Dictionary) -> String:
	match mv["kind"]:
		"attack":
			return str(_move_dmg(e, mv))
		"multi":
			return "%d×%d" % [_move_dmg(e, mv), int(mv.get("hits", 1))]
		"attack_all":
			return "%d to all" % _move_dmg(e, mv)
		"block":
			return "block %d" % int(mv["amt"])
		"guard_all":
			return "block %d/+%d" % [int(mv["amt"]), int(mv.get("ally_amt", 0))]
		"rage_all":
			var g: int = _rage_gain(e, mv)
			return ("+%d atk to all" % g) if g > 0 else "fury peaked"
		"expose":
			return "curse ×1.5"
	return ""

func _refresh_threats() -> void:
	var pairs: Array = []
	if phase == "playerTurn":
		for e: Dictionary in enemies:
			if not e["alive"]:
				continue
			# Only target-directed intents draw an arrow; block/buff/AoE turns threaten nobody in particular.
			if not _enemy_move(e)["kind"] in ["attack", "multi", "expose"]:
				continue
			var t: Dictionary = _enemy_target(e)
			if t.is_empty():
				continue
			pairs.append({
				"from": EN_POS[e["slot"]] + Vector2(0, 42),
				"to": pc_pos[t["slot"]] + Vector2(0, -42),
			})
	threat.set_threats(pairs)

func _refresh_panel() -> void:
	if phase == "playerTurn":
		var a: Dictionary = party[active_idx]
		var aura: String = "   📣+%d atk" % party_attack_buff if party_attack_buff > 0 else ""
		active_label.text = "%s  %s   ⚡%d/%d%s" % [a["emoji"], a["name"], a["energy"], a["max_energy"], aura]
		if mode == Mode.SOLO:
			hint_label.text = "Tap a dwarf to switch • tap a card to play (target cards: tap a target)"
		elif not Net.is_online():
			hint_label.text = "Reconnecting…"
		elif _seat_ended(my_seat):
			hint_label.text = "Turn ended — waiting on %d more" % _waiting_on()
		else:
			hint_label.text = "You pilot %s • play your cards, then End Turn" % a["name"]
	elif phase == "enemyTurn":
		active_label.text = "Enemy turn…"
		hint_label.text = ""
	else:
		active_label.text = ""
		hint_label.text = "Waiting for the host…" if mode == Mode.CLIENT else ""

func _rebuild_hand() -> void:
	if phase != "playerTurn":
		for c in hand_box.get_children():
			c.queue_free()
		return
	var a: Dictionary = party[active_idx]
	var hand: Array = a["hand"]
	var uids: Array = a.get("hand_uids", [])
	var n: int = hand.size()
	var spacing: float = minf(116.0, 624.0 / float(maxi(1, n)))
	# Reconcile by uid: keep survivor nodes (preserve hover/arm), free departed, add new.
	var existing := {}
	for c in hand_box.get_children():
		existing[c.uid] = c
	var want := {}
	for i in range(n):
		if i < uids.size():
			want[uids[i]] = true
	for u in existing.keys():
		if not want.has(u):
			existing[u].queue_free()
			existing.erase(u)
	for i: int in range(n):
		var cid: String = hand[i]
		var uid: String = uids[i] if i < uids.size() else ""
		var def: Dictionary = Db.CARDS[cid]
		var face: Dictionary = Db.describe(def, a, party_attack_buff, attacks_this_turn)
		var cooldown: bool = cid == "taunt" and turn - taunt_last_turn < 2
		var playable: bool = def["cost"] <= a["energy"] and not cooldown
		var t: float = float(i) - float(n - 1) / 2.0
		var rot: float = deg_to_rad(t * 5.0)
		var bc := Vector2(360.0 + t * spacing, 196.0 + absf(t) * 9.0)
		var slot_pos: Vector2 = bc - Vector2(Card.SIZE.x * 0.5, Card.SIZE.y)
		var survivor: bool = existing.has(uid)
		var card: Card
		if survivor:
			card = existing[uid]
		else:
			card = Card.new()
			card.uid = uid
			hand_box.add_child(card)
			card.clicked.connect(_on_card_clicked)
		card.index = i
		card.setup(def, face, playable, uid == selected_uid, def.get("tip", ""), cooldown)
		card.set_slot(slot_pos, rot)
		if not survivor and _hand_anim != "":
			# Entrance: a NEW card flies out of the active dwarf's portrait into its fan slot.
			card.position = pc_pos[active_idx] - hand_box.position - Vector2(Card.SIZE.x * 0.5, Card.SIZE.y)
			card.rotation = 0.0
			card.scale = Vector2(0.25, 0.25)
			card.modulate.a = 0.0
			card.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var d: float = (0.12 * float(active_idx) + 0.07 * float(i)) if _hand_anim == "deal" else 0.03 * float(i)
			var dur: float = 0.30 if _hand_anim == "deal" else 0.16
			var tw := card.create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.tween_property(card, "position", slot_pos, dur).set_delay(d)
			tw.tween_property(card, "rotation", rot, dur).set_delay(d)
			tw.tween_property(card, "scale", Vector2.ONE, dur).set_delay(d)
			tw.tween_property(card, "modulate:a", 1.0, dur * 0.6).set_delay(d)
			tw.finished.connect(func() -> void:
				if is_instance_valid(card):
					card.mouse_filter = Control.MOUSE_FILTER_STOP)

## Tiny face-up rows under the NON-active dwarves: cards still in hand (bright) plus cards
## already played this turn (ghosted) — party-wide planning at a glance. The active dwarf's
## row is empty (their hand IS the big fan below).
func _refresh_minis() -> void:
	for i: int in range(party.size()):
		var box: Control = pc_minis[i]
		for c in box.get_children():
			c.queue_free()
		if phase != "playerTurn" or i == active_idx or not party[i]["alive"]:
			continue
		var a: Dictionary = party[i]
		var items: Array = []
		for cid: String in a["hand"]:
			items.append({"cid": cid, "played": false})
		# Ghost only cards played this turn that are STILL spent (sitting in discard). A card
		# reshuffled back into hand mid-turn leaves discard, so it shows once (bright) — never
		# both bright and ghosted (which would inflate the row past the dwarf's real card count).
		var disc: Dictionary = {}
		for cid: String in a.get("discard", []):
			disc[cid] = int(disc.get(cid, 0)) + 1
		for cid: String in a.get("played_turn", []):
			if int(disc.get(cid, 0)) > 0:
				disc[cid] = int(disc[cid]) - 1
				items.append({"cid": cid, "played": true})
		var n: int = items.size()
		if n == 0:
			continue
		var step: float = minf(36.0, 178.0 / float(n))
		var animate: bool = _hand_anim == "deal" or (_hand_anim == "switch" and i == _switch_from)
		for k: int in range(n):
			var it: Dictionary = items[k]
			var m := _mk_mini(Db.CARDS[it["cid"]], bool(it["played"]))
			box.add_child(m)
			var target := Vector2(89.0 + (float(k) - float(n - 1) * 0.5) * step - MINI_SIZE.x * 0.5, 0.0)
			if animate and not bool(it["played"]):
				# Drawn from this dwarf's portrait: start centered above the row, fade-scale in.
				m.position = Vector2(89.0 - MINI_SIZE.x * 0.5, -95.0)
				m.scale = Vector2(0.3, 0.3)
				m.modulate.a = 0.0
				var d: float = (0.12 * float(i) + 0.05 * float(k)) if _hand_anim == "deal" else 0.04 * float(k)
				var tw := m.create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
				tw.tween_property(m, "position", target, 0.24).set_delay(d)
				tw.tween_property(m, "scale", Vector2.ONE, 0.24).set_delay(d)
				tw.tween_property(m, "modulate:a", 1.0, 0.16).set_delay(d)
			else:
				m.position = target

func _mk_mini(def: Dictionary, played: bool) -> Control:
	var m := Panel.new()
	m.size = MINI_SIZE
	m.pivot_offset = MINI_SIZE * 0.5
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	var tint: Color = Db.type_tint(def.get("type", "skill"))
	sb.bg_color = tint.darkened(0.55) if played else tint
	sb.set_corner_radius_all(5)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.10 if played else 0.30)
	m.add_theme_stylebox_override("panel", sb)
	var e := Label.new()
	e.text = def["emoji"]
	e.add_theme_font_size_override("font_size", 17)
	e.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	e.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	e.size = MINI_SIZE
	e.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(e)
	var c := Label.new()
	c.text = str(def["cost"])
	c.add_theme_font_size_override("font_size", 10)
	c.add_theme_color_override("font_color", Color(0.96, 0.84, 0.25))
	c.position = Vector2(3, 0)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(c)
	if played:
		m.modulate = Color(0.6, 0.6, 0.66, 0.8)
	return m

# ================================================================ Targeting cursor
func _update_cursor() -> void:
	var arm: Dictionary = _armed_def()
	var needs_target: bool = arm.get("target", "") in ["enemy", "ally", "ally_or_enemy"]
	var targeting: bool = phase == "playerTurn" and selected_uid != "" and needs_target
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

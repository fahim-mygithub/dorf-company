extends Control
## "Demon Lord MBA" — Slice 2 party puzzle (portrait 720x1280, emoji).
##
## 3 roles (Warrior tank / Cleric support / Sorcerer dps), per-character decks + energy.
## Clean PLAYER phase (act with each character in any order) -> ENEMY phase.
## 3 archetype enemies with PREFERRED TARGETING + live threat arrows + Taunt redirect.
## Data-driven via card_db.gd (Db). Reuses card.gd (Card), threat_arrows.gd, momentum_hit VFX.
## Resolution order (Db op semantics): base -> +flat (Channel/Aura) -> xMark -> block,hp -> Retaliate.

const Db := preload("res://scripts/combat/card_db.gd")
const Powers := preload("res://scripts/combat/class_powers.gd")
## The synergy engine — every device that makes one body worth more than its own health bar (aegis,
## chorus, gorge, regalia, molt, twin bond, alone gate, swarm). Same pattern as Powers: a pure rules
## module that owns the numbers, and combat.gd only ROUTES to it. Every device is DERIVED from board
## state that already crosses the wire, so wiring it added nothing to the snapshot and nothing to
## _INT_KEYS.
const Syn := preload("res://scripts/combat/synergies.gd")
## The twelve authored boards. Combat reads exactly ONE thing out of this file — the `design` block
## behind the Feedback popup — and it reads it through get_enc(), which answers {} for an unknown or
## absent id. That is the whole integration: no board is rolled here (overworld.gd owns that), so a
## fight whose encounter is unknown loses a page of designer's notes and nothing else.
const Enc := preload("res://scripts/combat/encounter_db.gd")
## The designer's-notes popup. Purely local, purely cosmetic, never on the wire — see _on_feedback.
const Feedback := preload("res://scripts/ui/feedback_panel.gd")
const PowerOrb := preload("res://scripts/ui/power_orb.gd")
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
var enemy_n := 3               # bodies on the board (1-ENEMY_MAX); en_pos is sized to it
var en_pos: Array = []         # runtime enemy portrait centers (set in _build_ui)
var en_emoji: Array = []
var en_name: Array = []
var en_intent: Array = []
var en_hp: Array = []
var en_block: Array = []
# --- the synergy readout (2026-07-22), parallel to enemies[] as well ---
var en_aura: Array = []       # slab BEHIND the portrait, in the aura source's colour
var en_device: Array = []     # one short line: the devices touching THIS body right now
var en_meter_bg: Array = []   # the crack meter's track (Molt-King)
var en_meter_fg: Array = []   # ...and its fill
## The OVERRIDDEN-RULE badge (2026-07-22). Its own label, at half the nameplate's font, because a
## Taunt that took has to show BOTH facts at once: 😡 (the rule was overridden) sits in the nameplate
## where the pref badge normally lives, and the body's own pref badge is demoted here rather than
## deleted. Deleting it would make a taunted Brute and a taunted Caster look identical, which is the
## one comparison a player needs the turn the Taunt wears off.
var en_rule: Array = []
## ONE collapsed line per contiguous swarm run (Syn.swarm_groups). Not parallel to enemies[] — a run
## can be any length, so these are a small pool sized to the most runs a board can hold, positioned
## over the run they describe at refresh time.
var sw_line: Array = []
# party (parallel to party[])
var pc_emoji: Array = []
var pc_name: Array = []
var pc_hp: Array = []
var pc_block: Array = []
var pc_energy: Array = []
var pc_outline: Array = []
var pc_minis: Array = []   # per-slot container for the tiny hand row (non-active dwarves)
var pc_power: Array = []       # the Class Power orb on each portrait
var pc_power_lbl: Array = []   # its gate readout (cooldown / 📿 / 🧿 charge)
## THE INCOMING FORECAST — one chip per dwarf, mirroring the Class Power coin across the portrait.
## See _incoming_forecast for what the number means and why it is the number it is.
var pc_forecast: Array = []
## A targeted power (Smite / Assassin's Mark / Flurry) is ARMED by tapping the orb, then aimed by
## tapping an enemy — the same two-tap grammar as a target card, so there is nothing new to learn.
var power_armed := false
var choice_box: Control          # the 3-way pick (Metamagic's shapes, Wild Shape's forms)
var choice_btns: Array = []

var threat: Node2D
var intent_panel: Control       # hover/tap explainer for an enemy's telegraphed move
var ip_title: Label
var ip_body: Label
var ip_next: Label
var ip_pref: Label
var ip_dev: Label               # the synergy line: what the REST of the board does to this body
var intent_open := -1           # enemy index the intent panel is showing, -1 = hidden
var power_tip: Control          # hover explainer for a Class Power coin
var pt_title: Label
var pt_gate: Label
var pt_body: Label
var power_tip_open := -1        # party index the power tooltip is showing, -1 = hidden
var active_label: Label
var hint_label: Label
var hand_box: Control
var end_turn_btn: Button
var log_label: Label
var overlay: ColorRect
var overlay_label: Label
var overlay_btn: Button
## THE DESIGNER'S NOTES (2026-07-22) — a playtest instrument, not a hint system. `feedback` is the
## full-screen popup (scripts/ui/feedback_panel.gd, which owns everything inside it); `feedback_btn`
## is the only thing combat.gd puts on screen for it, and it says nothing except that notes exist.
## Spoiler discipline is the entire design constraint here: no badge, no subtitle, no count, no
## preview. Anything that leaked the encounter's intent before the press would turn the fight into a
## tutorial and destroy the measurement the popup exists to take.
var feedback: Control
var feedback_btn: Button

# enemy slot screen positions / party slot screen positions
const EN_POS := [Vector2(170, 200), Vector2(360, 200), Vector2(550, 200)]
const PC_POS := [Vector2(170, 700), Vector2(360, 700), Vector2(550, 700)]
const PARTY_MAX := 4
## 3 stays the normal board. 6 is the ceiling, and it is a readability number, not a taste one: it is
## where "🗡️9>War" still fits at a 120px pitch and a portrait tap target stays around 60dp. A 10-body
## board was built and screenshotted before this cap was set — it renders, but three separate things
## break at once: the intent labels crowd, nothing distinguishes a body worth killing from a body
## worth ignoring, and ten standard statlines put ~34 damage into a 22-HP Sorcerer on turn one.
## Going past 6 needs the elevated BOSS slot (which is exempt, because size separates it
## pre-attentively) — not a second rank of equals.
const ENEMY_MAX := 6
# Debug hotseat: force a party size (2/4) when no request.crew is supplied. 0 = off (SOLO 3).
const DEBUG_PARTY_N := 0

## ---------------------------------------------------------------- the synergy readout
## An aura is caused by ONE body and felt by the others, so the readout has to answer "which body"
## before it answers "how much" — a generic "aegis grey" fails on exactly the boards that matter (a
## Shellback line and a Rune Crystal lattice look identical in grey). So a protected body wears a dim
## wash of ITS SOURCE'S colour and the source wears the same colour solid: one glance links them.
## Keyed by archetype rather than by aura kind for the same reason. Anything unlisted falls back to
## the kind's colour, so a new aura body renders sensibly the day it lands and only looks generic.
const SOURCE_TINT := {
	"warden":       Color(0.72, 0.74, 0.80),   # 🗿 stone
	"shellback":    Color(0.52, 0.82, 0.62),   # 🐢 shell green
	"rune_crystal": Color(0.55, 0.82, 1.00),   # 💎 cold blue
	"caster":       Color(0.80, 0.60, 1.00),   # 🔮 arcane violet
	"sporeling":    Color(0.68, 0.92, 0.48),   # 🍄 spore green
}
const AURA_FALLBACK_TINT := Color(0.85, 0.80, 0.60)
const METER_W := 96.0     # the crack meter's full width; the RIGHT EDGE is the threshold
const METER_H := 6.0

## ---------------------------------------------------------------- the six-body squeeze
## Every enemy label used to be a fixed 160px box centred on the slot. At three bodies the pitch is
## 190px and that is fine; at the ENEMY_MAX six it is 120px, so a 160px box overlaps BOTH neighbours
## by 20px and two adjacent labels render into each other. That is not a nitpick — the entire reason
## the board caps at 6 is that labels stop fitting, so a cap enforced by a number in a const and
## nowhere in the layout is a cap that does not exist.
##
## The fix is one scale factor derived from the pitch, applied to every box width and every font on
## the enemy row. It is CLAMPED at both ends on purpose: 1.0 keeps the three-body board byte-identical
## to the shipped one (no silent restyle of the fight everyone actually plays), and 0.75 is the floor
## because below ~10px the digits in an intent label stop being readable at arm's length on a phone,
## and an unreadable telegraph is worth less than a clipped one.
const SLOT_LABEL_W := 160.0
const SLOT_FONT_FLOOR := 0.75

## Horizontal pitch between enemy slots — the width one body actually owns.
## Read off en_pos rather than recomputed from 720/n so it cannot drift from _enemy_layout.
func _slot_pitch() -> float:
	# A lone body owns the whole width — NOT SLOT_LABEL_W. Returning the label width here would make a
	# one-enemy board (a solo boss, and several test fixtures) squeeze by ~4% for no reason, which is
	# exactly the kind of silent restyle the 1.0 clamp above exists to prevent.
	if en_pos.size() < 2:
		return 720.0
	return absf(float(en_pos[1].x) - float(en_pos[0].x))

## Width of one enemy label box, and the font scale that goes with it. See the block above.
func _slot_label_w() -> float:
	return minf(SLOT_LABEL_W, _slot_pitch() - 6.0)

func _slot_font_scale() -> float:
	return clampf(_slot_label_w() / SLOT_LABEL_W, SLOT_FONT_FLOOR, 1.0)

## A base font size, squeezed for the current board. Rounded, never floored: at the 0.75 floor a
## floor() would cost a whole point on every odd size at once.
func _sf(base: int) -> int:
	return roundi(float(base) * _slot_font_scale())

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

	# The board is sized from the REQUEST, exactly like the party is — and every peer builds it from
	# the same request, so a client lays out the same board the host resolves. (Adding bodies later is
	# a different problem: `slot` is the wire address and _apply_snapshot drops out-of-range slots.)
	enemy_n = clampi((request.get("enemies", Db.ENCOUNTER) as Array).size(), 1, ENEMY_MAX)
	en_pos = _enemy_layout(enemy_n)
	for i: int in range(enemy_n):
		_build_enemy_slot(i)
	# THE SWARM LINE. Four bats telegraphing "🗡️4>Sor" four times is four labels saying one thing, and
	# the cost is not clutter — it is that the player's eye has to VISIT four labels to learn there is
	# nothing to compare. So a contiguous run of identical minions collapses to one line spanning the
	# run, with the summed total in parentheses: one object, one number, one decision.
	# Built as a small POOL rather than per-slot because a run has no fixed home: the pool is sized to
	# the most runs a board can hold (a run is at least Syn.SWARM_MIN bodies, and a board is at most
	# ENEMY_MAX), and each line is positioned over its run at refresh time.
	var max_runs: int = maxi(1, int(ENEMY_MAX / Syn.SWARM_MIN))
	for i: int in range(max_runs):
		var l := _label("", Vector2.ZERO, Vector2(0, 22), _sf(18))
		l.visible = false
		sw_line.append(l)

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
	ipbg.size = Vector2(480, 98)
	ipbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	intent_panel.add_child(ipbg)
	var ipedge := ColorRect.new()
	ipedge.color = Color(1, 1, 1, 0.14)
	ipedge.size = Vector2(480, 1)
	ipedge.position = Vector2(0, 97)
	ipedge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	intent_panel.add_child(ipedge)
	# The five rows are TIGHTENED rather than the panel grown by a full line: the panel sits at y=40
	# and the enemy name row starts at y=126, so every pixel it gains covers the very labels the
	# player opened it to compare against. Labels do not clip to their rect (single line, top-aligned,
	# no autowrap), so a 16px box on a 12px font is safe.
	ip_title = _label("", Vector2(10, 3), Vector2(460, 20), 15, false)
	ip_title.reparent(intent_panel, false)
	ip_body = _label("", Vector2(10, 25), Vector2(460, 17), 12, false)
	ip_body.add_theme_color_override("font_color", Color(0.78, 0.78, 0.82))
	ip_body.reparent(intent_panel, false)
	ip_next = _label("", Vector2(10, 43), Vector2(460, 17), 12, false)
	ip_next.add_theme_color_override("font_color", Color(0.95, 0.80, 0.45))
	ip_next.reparent(intent_panel, false)
	ip_pref = _label("", Vector2(10, 61), Vector2(460, 16), 11, false)
	ip_pref.add_theme_color_override("font_color", Color(0.62, 0.70, 0.80))
	# This row is ordered by decision-relevance (reach, then the badge sentence, then the archetype's
	# prose) precisely because it is the row that overflows: several archetype tips are longer than
	# 460px on their own, and adding the badge sentence in front of them guarantees it. A Label does
	# not clip by default, so the tail used to paint straight over the panel's right edge and onto the
	# board. TRIM_ELLIPSIS makes the truncation deliberate and, more importantly, VISIBLE — a sentence
	# that just stops reads as a bug, and a player cannot tell it from a tip that was written that way.
	ip_pref.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	ip_pref.clip_text = true
	ip_pref.reparent(intent_panel, false)
	# The DEVICE line — what the rest of the board is doing to this one, INCLUDING what it would do
	# under a condition that is not true yet (the cornered Caster). It is greyed because most of what
	# it prints is conditional: a conditional the player cannot see is an unfair number, but a
	# conditional dressed up as a fact is just a different lie.
	ip_dev = _label("", Vector2(10, 78), Vector2(460, 16), 11, false)
	ip_dev.add_theme_color_override("font_color", Color(0.70, 0.66, 0.60))
	ip_dev.reparent(intent_panel, false)

	# Class Power explainer (hover a coin) — lives in the open band between the enemies and the crew.
	power_tip = Control.new()
	power_tip.visible = false
	power_tip.z_index = 61
	power_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(power_tip)
	var ptbg := ColorRect.new()
	ptbg.color = Color(0.07, 0.07, 0.10, 0.97)
	ptbg.size = Vector2(360, 138)
	ptbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	power_tip.add_child(ptbg)
	var ptedge := ColorRect.new()
	ptedge.color = Color(1, 1, 1, 0.14)
	ptedge.size = Vector2(360, 1)
	ptedge.position = Vector2(0, 137)
	ptedge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	power_tip.add_child(ptedge)
	pt_title = _label("", Vector2(10, 5), Vector2(340, 20), 15, false)
	pt_title.reparent(power_tip, false)
	pt_gate = _label("", Vector2(10, 28), Vector2(340, 18), 12, false)
	pt_gate.add_theme_color_override("font_color", Color(0.95, 0.80, 0.45))
	pt_gate.reparent(power_tip, false)
	pt_body = _label("", Vector2(10, 50), Vector2(340, 84), 12, false)
	pt_body.add_theme_color_override("font_color", Color(0.80, 0.80, 0.84))
	pt_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pt_body.reparent(power_tip, false)

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

	# The Class Power 3-way pick. A FULL-SCREEN dim, not a floating panel: MOUSE_FILTER_STOP only
	# catches taps inside the node's own rect, so a panel over the middle of the board would leave the
	# card fan at y≈930 live underneath it — you could "choose" and play a card with the same tap.
	# z_index lifts it over the threat arrows, which are a Node2D drawn across the whole board.
	choice_box = ColorRect.new()
	choice_box.color = Color(0.03, 0.02, 0.05, 0.88)
	choice_box.size = Vector2(720, 1280)
	choice_box.mouse_filter = Control.MOUSE_FILTER_STOP
	choice_box.z_index = 50
	choice_box.visible = false
	add_child(choice_box)
	var ch_panel := ColorRect.new()
	ch_panel.color = Color(0.09, 0.08, 0.13, 1.0)
	ch_panel.position = Vector2(24, 300)
	ch_panel.size = Vector2(672, 344)
	ch_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	choice_box.add_child(ch_panel)
	var ch_lbl := Label.new()
	ch_lbl.text = "Choose"
	ch_lbl.add_theme_font_size_override("font_size", 17)
	ch_lbl.position = Vector2(48, 314)
	ch_lbl.size = Vector2(624, 24)
	ch_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	choice_box.add_child(ch_lbl)

	_build_feedback()

## THE FEEDBACK AFFORDANCE — the button lives here, the popup lives in feedback_panel.gd.
##
## WHERE IT SITS, AND WHY. The 720x1280 board has exactly one empty region left, and it is the
## bottom-LEFT corner. Everything else is spoken for: the header band y 24-50 (the raid title), the
## intent panel y 40-138 (x-clamped to as far left as x=8, so the "obvious" top-left slot collides
## with it the moment you hover the leftmost enemy), the enemy row centred on y=200, the crew row on
## y=700, the mini-hand band y 798-846, the active/hint lines y 852-902, the card fan y 905-1120
## (a fan card's bottom edge is 905+196+18), the log line at y=1244, and End Turn at (540,1184).
## That leaves x 0-540 by y 1125-1240. The button takes the far left of it, which also puts it at the
## opposite end of the bottom row from End Turn — the one button on this screen you must never make
## easier to hit by accident. It is deliberately NOT vertically centred on End Turn's 52px band: it
## is 40px tall and sits inside that band, so it reads as subordinate furniture rather than a peer
## of the button that ends your turn.
##
## WHY IT IS ALWAYS THERE. The user's request was "when the combat scene starts", and the reason is a
## measurement one: a playtester forms the judgement DURING the fight ("I never noticed the aura",
## "turn 3 played itself"), so a notes button that only appears on the win screen samples the wrong
## moment. It is therefore live in every phase, including the enemy phase — the only thing that hides
## it is the win/lose overlay, exactly like intent_panel, power_tip and end_turn_btn.
##
## WHAT THE LABEL SAYS. Flat capitals, no glyph, no encounter name, no "3 notes" count: "DEV NOTES"
## states that a developer wrote something and nothing whatsoever about what. It matches the popup's
## own out-of-fiction eyebrow so the two read as one register, and it cannot be mistaken for an
## in-world affordance the way "Notes" or a scroll emoji could.
func _build_feedback() -> void:
	feedback_btn = Button.new()
	feedback_btn.text = "DEV NOTES"
	feedback_btn.add_theme_font_size_override("font_size", 14)
	feedback_btn.position = Vector2(16, 1190)
	feedback_btn.size = Vector2(118, 40)
	# Quiet on purpose. It is a dev affordance sharing a row with End Turn; at full opacity it competes
	# for the eye with the single most important control on the screen.
	feedback_btn.modulate = Color(1, 1, 1, 0.62)
	feedback_btn.pressed.connect(_on_feedback)
	add_child(feedback_btn)

	# Added LAST so it is the final sibling: the panel is full-screen and z_index 70, but sibling order
	# is this scene's paint order for everything that shares a z, and being last costs nothing.
	# setup() builds the whole widget and leaves it hidden; it is idempotent, so a future UI rebuild
	# cannot double-build it.
	feedback = Feedback.new()
	add_child(feedback)
	feedback.setup()

func _build_enemy_slot(i: int) -> void:
	var pos: Vector2 = en_pos[i]
	# The AURA SLAB, added FIRST so it draws BEHIND the portrait (this scene has no z_index on the
	# board — sibling order is the paint order). It is the at-a-glance half of the aegis readout: the
	# source is washed solid in its own colour, everything it shields wears the same colour faint.
	# MOUSE_FILTER_IGNORE matters — the portrait underneath it owns the tap and the hover that opens
	# the intent panel, and a slab that ate either would break inspection on precisely the boards
	# where inspection is the lesson.
	# Sized to the PORTRAIT and not to the whole slot (it stops just above the HP row): screenshotted at
	# slot height it read as a selection box, and the board already uses a filled highlight to mean
	# "armed, tap me". A plaque behind the body reads as a property OF the body.
	# Everything on this row is sized off the slot PITCH, not off a constant — see the six-body
	# squeeze block near ENEMY_MAX. `lw`/`lx` are the label box; `sc` scales the glyph furniture
	# (slab, meter) that would otherwise reach into the neighbouring body at six.
	var lw: float = _slot_label_w()
	var lx: float = pos.x - lw * 0.5
	var sc: float = _slot_font_scale()
	var slab := ColorRect.new()
	slab.size = Vector2(104.0 * sc, 88)
	slab.position = pos - Vector2(slab.size.x * 0.5, 46)
	slab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slab.visible = false
	add_child(slab)
	en_aura.append(slab)
	var e := _emoji(pos, Vector2(96, 76), _sf(50))
	e.gui_input.connect(_on_enemy_input.bind(i))
	# Intent explainer: hover on desktop; on touch the emulated cursor "enters" on tap and
	# "exits" on the next tap elsewhere, so the same signals give tap-to-inspect for free.
	e.mouse_entered.connect(_open_intent.bind(i))
	e.mouse_exited.connect(_close_intent.bind(i))
	en_emoji.append(e)
	en_name.append(_label("", Vector2(lx, pos.y - 74), Vector2(lw, 20), _sf(14)))
	en_intent.append(_label("", Vector2(lx, pos.y - 52), Vector2(lw, 22), _sf(18)))
	en_hp.append(_label("", Vector2(lx, pos.y + 40), Vector2(lw, 20), _sf(16)))
	en_block.append(_label("", Vector2(lx, pos.y + 60), Vector2(lw, 18), _sf(14)))
	# The DEVICE ROW — its own line under the status row, not more chips inside it. A status is
	# something done TO this body and it wears off; a device is caused by ANOTHER body and vanishes
	# the instant that body dies. Mixing them would teach the player to read a soak as a debuff.
	en_device.append(_label("", Vector2(lx, pos.y + 78), Vector2(lw, 16), _sf(12)))
	# The DEMOTED PREF BADGE — see en_rule. Half the nameplate's font (the contract's word), on its own
	# row directly under it, so 😡 and the rule it overrode read as one two-line statement without
	# needing rich text in a Label the whole board indexes by type.
	var rl := _label("", Vector2(lx, pos.y - 60), Vector2(lw, 12), maxi(7, _sf(7)))
	rl.add_theme_color_override("font_color", Color(0.75, 0.72, 0.70))
	rl.visible = false
	en_rule.append(rl)
	# The CRACK METER — a real bar, because what it shows is a fraction with a THRESHOLD, and the
	# whole promise of the Molt-King is that the threshold is visible instead of a hidden counter.
	# The bar's RIGHT EDGE *is* the half-HP crack: full bar = the shell comes off on the next hit.
	# (A text gauge was the alternative and the web font ships no box-drawing glyphs — see the U+2192
	# tofu that started the glyph gate.)
	var mw: float = METER_W * sc
	var mbg := ColorRect.new()
	mbg.color = Color(1, 1, 1, 0.10)
	mbg.position = Vector2(pos.x - mw * 0.5, pos.y + 96)
	mbg.size = Vector2(mw, METER_H)
	mbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mbg.visible = false
	add_child(mbg)
	en_meter_bg.append(mbg)
	var mfg := ColorRect.new()
	mfg.color = Color(0.95, 0.45, 0.35, 0.90)
	mfg.position = mbg.position
	mfg.size = Vector2(0, METER_H)
	mfg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mfg.visible = false
	add_child(mfg)
	en_meter_fg.append(mfg)

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
	# The CLASS POWER coin — a Hearthstone-style hero power on the portrait, a second lever beside the
	# hand. It sits in the gutter to the RIGHT of the emoji (which spans pos.x±55) and clear of every
	# label: name at y-58, hp/block/energy at y+38/+58/+76, the mini row at y=798. Added AFTER the
	# emoji so it is above it in the tree and wins where the two rects overlap. The widget owns all
	# the visuals (flip / fill / orbit); combat only routes taps and feeds it a state dict.
	var orb := PowerOrb.new()
	orb.size = Vector2(56, 56)
	orb.position = pos + Vector2(32, -32)      # centre ≈ pos+(60,-4), just right of the portrait
	orb.gui_input.connect(_on_orb_input.bind(i))
	orb.mouse_entered.connect(_open_power_tip.bind(i))
	orb.mouse_exited.connect(_close_power_tip.bind(i))
	add_child(orb)
	pc_power.append(orb)
	# The gate readout under the coin — the cooldown, the 📿 it needs, the 🧿 casts it is waiting on.
	pc_power_lbl.append(_label("", Vector2(pos.x + 32, pos.y + 28), Vector2(56, 16), 11, true))
	# THE INCOMING FORECAST — mirrored across the portrait from the Class Power coin, on purpose. The
	# two chips are the dwarf's two halves of one question: the coin is what you can DO, the forecast
	# is what is about to be done TO you. Putting them at the same height on opposite sides makes the
	# pair scannable as a row across the whole crew, which is how the decision is actually made
	# ("who is about to die" is a comparison between dwarves, never a fact about one).
	# The gutter is free: the emoji spans pos.x±55 and every stat label is centred on the slot.
	var fc := _label("", pos + Vector2(-88, -30), Vector2(56, 26), 17, true)
	pc_forecast.append(fc)
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
## Enemy portrait centers for a board of n bodies. The sibling of _party_layout, and deliberately the
## same shape: 3 returns EN_POS byte-identical, so the normal fight is visually untouched.
##
## ⚠ ONE ROW, on purpose — and specifically NOT a zigzag. A staggered second rank was the first thing
## built here, and the readability research refuted it: a cosmetic offset costs positional constancy
## ("the ogre is slot 3") and unambiguous scan order while carrying no meaning of its own. Every
## shipped two-row battler — Wildfrost's lanes, Banners of Ruin's rows, Darkest Dungeon's ranks —
## makes the row SEMANTIC (it gates who can reach whom). We have no such rule, so we get no second
## row: a rank that means nothing is worse than no rank at all. The way past 6 is the elevated boss
## slot, not more equals.
func _enemy_layout(n: int) -> Array:
	if n == 3:
		return EN_POS.duplicate()   # the shipped board, byte-identical
	var out: Array = []
	var w: float = 720.0 / float(n)
	for i: int in range(n):
		out.append(Vector2(w * (float(i) + 0.5), EN_POS[0].y))
	return out

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
		var pc: Dictionary = {
			"role": cls["role"], "cls": cid, "name": spec.get("name", cls["name"]), "emoji": cls["emoji"],
			"hp": int(spec.get("hp", cls["max_hp"])), "max_hp": int(spec.get("max_hp", cls["max_hp"])), "block": 0,
			"energy": cls["energy"], "max_energy": cls["energy"],
			# A crew member sent in at 0 HP (a downed dwarf on a hex expedition) starts as a benched slot.
			# Standalone/mesh crews always have hp > 0, so this stays byte-identical for those paths.
			"alive": int(spec.get("hp", cls["max_hp"])) > 0,
			"deck": deck, "hand": [], "hand_uids": [], "discard": [], "played_turn": [],
			"vulnerable": 0,   # enemy Expose/Hex: takes x1.5 from enemy hits, decays 1/player-phase
			"temp": _fresh_temp(), "shield": 0, "attacks_this_turn": 0,
			"momentum": 0, "devotion": 0,   # Warrior/Cleric signature counters (reset each player phase)
			# side+slot is the entity's WIRE ADDRESS: the pair every fx event is aimed with. Static
			# for the life of the fight, so unlike an event it is safe riding an entity dict.
			"node": pc_emoji[i], "slot": i, "side": "party",
			# The Bard's song is held with this and nothing else: the (kind,idx) address of every play
			# this turn. An AoE carries ONE address, so "AoE counts as 1" needs no code.
			"targets_turn": [], "tithe_pending": false,
		}
		# The Class Power's own state, per class. A dwarf whose class has no power still carries the
		# keys (power == "") so the snapshot shape never varies by class.
		pc.merge(Powers.fresh_state(str(cls.get("power", ""))))
		party.append(pc)

	enemies = []
	var enc: Array = request.get("enemies", Db.ENCOUNTER)
	var escale: float = float(request.get("enemy_scale", 1.0))
	# Bounded by the slots _build_ui actually made, so an oversized comp truncates instead of
	# indexing past en_emoji. enemy_n is itself clamped to ENEMY_MAX from the same request.
	for i: int in range(mini(enc.size(), enemy_n)):
		var eid: String = enc[i]
		var ed: Dictionary = Db.ENEMIES[eid]
		# HP scales at full escale; damage/block at the damped dscale (hard, not impossible).
		var dscale: float = _dscale()
		var ehp: int = int(round(float(ed["max_hp"]) * escale))
		var eatk: int = int(round(float(ed["atk"]) * dscale))
		# Move rotation: damage/block amounts pre-scaled by dscale; rage stays flat (small permanent +).
		var mvs: Array = _scale_moves(ed.get("moves", []), dscale)
		enemies.append({
			"archetype": eid, "name": ed["name"], "emoji": ed["emoji"],
			"hp": ehp, "max_hp": ehp, "block": 0, "atk": eatk,
			"pref": ed["pref"], "alive": true, "marked": false, "forced": false,
			"burn": 0, "vulnerable": 0,   # status debuffs (Kindle / Guard Break)
			"stun": 0,                    # Stunning Strike: loses its next action
			"am_owner": -1, "am_tick": 0, "am_turns": 0,   # the Rogue's Assassin's Mark (owner seat)
			# ROTATION OFFSET — randomised ONLY for a body that appears more than once on this board.
			# The offset exists for exactly one reason: three Cave Bats or two Wolves marching in
			# lockstep read as one metronome instead of three threats. A body that appears ONCE gets no
			# benefit from it and pays a real cost — encounter_db authors a `rhythm` list per board
			# ("turn 1: Vorn coils behind block. Free turn.") and feedback_panel prints those lines to
			# the playtester VERBATIM, so a randomised beat 1 made the feedback instrument lie about the
			# fight the tester just played. Vorn opened on AVALANCHE 25% of the time; the Ogre on
			# stonefists skipped its authored free turn half the time. Wire-safe: move_i is in
			# _INT_KEYS, so the host's roll is the one every peer renders either way.
			# Deliberately gated on DUPLICATE-NESS rather than on tier != "boss": stonefists and gorge
			# are not boss boards and their rhythms were lying too.
			# ⚠ UNSIMMED — singleton bodies now always open on beat 0, which dorf_sim.py has not seen.
			"moves": mvs, "move_i": (randi() % mvs.size()) if (not mvs.is_empty() and enc.count(eid) > 1) else 0,
			# THE SECOND ROTATION (Molt-King). Built here, from the same dscale, for the same reason
			# `moves` is: it must be pre-scaled identically, and both halves of a two-phase boss have
			# to be scaled by ONE piece of code or the cracked half quietly ships at base numbers in
			# every elite fight. Empty for every other body, which is also the swap's gate.
			"moves_molt": _scale_moves(ed.get("moves_molt", []), dscale),
			"rage": 0,                    # permanent +atk from Howl (rage_all)
			"intent_target": -1, "node": en_emoji[i], "slot": i, "side": "enemy",
		})

	turn = 0
	taunt_last_turn = -99
	phase = ""
	power_armed = false
	choice_box.visible = false
	overlay.visible = false
	intent_open = -1
	intent_panel.visible = false
	# Play Again re-enters here without rebuilding the UI, so anything left open from the last fight
	# survives into the new one. The notes in particular would then be describing the fight you just
	# finished while a fresh board sits underneath them.
	if feedback != null:
		feedback.close()
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
	# smite_bonus (Vow of Wrath) / pay_with_guard (Reforge) / x_paid (what an X-cost card really spent).
	return {"retaliate": 0, "fortify": false, "fortify_guard": false, "channel_charges": 0, "channel_bonus": 0,
		"next_attack_bonus": 0, "double_next": false, "retain_block": false,
		"smite_bonus": 0, "pay_with_guard": false, "x_paid": 0}

# ================================================================ Phase flow
## FOUR PASSES, AND THE ORDER OF THEM IS LOAD-BEARING. It used to be one loop, which quietly broke
## three things at once: a Heightened spell resolves INSIDE this function, so anything reset after it
## erased what it just did, and anything a dwarf granted the PARTY was zeroed again by the next
## dwarf's own reset.
func _start_player_phase() -> void:
	turn += 1
	# PASS 1 — every GLOBAL reset, before ANY resolution. A held spell lands in pass 2 and a held Mark
	# must survive it; a held attack must read this turn's buffs, not last turn's.
	for e: Dictionary in enemies:
		e["marked"] = false
		e["forced"] = false
		e["vulnerable"] = maxi(0, int(e.get("vulnerable", 0)) - 1)   # Vulnerable counts down each turn (Burn ticks separately)
	party_attack_buff = 0
	attacks_this_turn = 0
	power_armed = false
	if choice_box != null:
		choice_box.visible = false
	# PASS 2 — per-dwarf reset, then draw.
	for a: Dictionary in party:
		if not a["alive"]:
			a["raging"] = false   # a downed dwarf can't hold a stance, and will never run its upkeep
			continue
		# Bracing Stance: block set to keep through the next turn instead of zeroing.
		if not bool(a["temp"].get("retain_block", false)):
			a["block"] = 0
		a["energy"] = a["max_energy"]
		a["temp"] = _fresh_temp()
		a["shield"] = 0
		a["momentum"] = 0
		# Devotion is NOT zeroed: the Paladin banks it BETWEEN Smites, and a 3-turn cooldown you
		# cannot save across is not a cooldown, it is a tax. (The legacy divine_smite card gets
		# easier to fuel as a result — unsimmed, and recorded in the plan.)
		a["attacks_this_turn"] = 0
		a["played_turn"] = []
		a["vulnerable"] = maxi(0, int(a.get("vulnerable", 0)) - 1)   # Expose/Hex wears off
		# Ticks the cooldown and fires any Heightened spell. Ordering matters exactly once and this is
		# it — a held spell must land before the hand it was meant to set up is dealt.
		Powers.on_phase_start_pre_draw(self, a)
		_draw_cards(a, HAND_SIZE)
	# A Heightened spell can KILL THE LAST ENEMY from inside pass 2 — _resolve_held_spell calls
	# _check_end, which sets phase="win" and (nested) has already emitted combat_finished. Falling
	# through would stamp phase="playerTurn" back over the win and hand the campaign a fight that
	# reported itself finished and then kept running.
	if phase == "win" or phase == "lose":
		return
	# PASS 3 — the Druid's form reads the hand it was just dealt, so it cannot run before pass 2 ends.
	# It also PAYS THE PARTY (🦅 Hawk), which is why it cannot live inside pass 2: a later dwarf's
	# block reset would wipe what an earlier Druid just granted.
	for a: Dictionary in party:
		if a["alive"]:
			Powers.on_phase_start_post_draw(self, a)
	# PASS 4 — party-wide. AFTER party_attack_buff is zeroed: the Bard's song rides that same channel,
	# so it has to be applied on top of the reset rather than wiped by it.
	Powers.on_phase_start_party(self)
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
			if a["alive"]:
				Powers.on_seat_upkeep(self, a)   # rage lapses / the song breaks — before the hand goes
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
	# The stance upkeep is PER SEAT because ending is per seat: co-op has no party-wide end of turn to
	# hang it on, and inventing one would lapse a Barbarian's rage on someone else's clock.
	Powers.on_seat_upkeep(self, a)
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
	# The Assassin's Mark bleeds on the same beat as Burn, and for the same reason it can: status
	# damage writes hp directly and never routes through _deal_enemy, which would subtract block
	# first. That is precisely what "ignores armour completely" means, and Burn is the precedent.
	if Powers.tick_marks(self):
		any_burn = true
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
		# 💫 Stunned: it loses this action. move_i does NOT advance — the move it was telegraphing is
		# the move it still owes, so the intent label stays honest. The beat is broadcast before the
		# skip, or the client renders the stun fused into next turn's board.
		if int(e.get("stun", 0)) > 0:
			e["stun"] = int(e["stun"]) - 1
			_flash(e)
			_log("💫 %s is stunned — it loses its turn." % e["name"])
			_refresh()
			_net_board()
			continue
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

## The damping factor every enemy DAMAGE/BLOCK number is pre-scaled by (HP takes the full escale).
## Derived from `request` rather than stored on an enemy: every peer builds its board from the same
## request, so this is identical everywhere without a byte on the wire. Anything that has to invent a
## move number at RUNTIME (the Overseer's regalia Gaze) has to come through here, or it would be the
## one beat in the game that ignores the encounter's scale.
func _dscale() -> float:
	return 1.0 + (float(request.get("enemy_scale", 1.0)) - 1.0) * ATK_SCALE_K

## Pre-scale one authored rotation. Pulled out of _start_combat the moment a second rotation existed:
## two copies of these four lines is exactly how a two-phase boss ends up with one scaled half.
func _scale_moves(src: Array, dscale: float) -> Array:
	var out: Array = []
	for m: Dictionary in src:
		var mv: Dictionary = m.duplicate()
		if mv.has("dmg"):
			mv["dmg"] = int(round(float(mv["dmg"]) * dscale))
		if mv.has("amt") and mv["kind"] in ["block", "guard_all"]:
			mv["amt"] = int(round(float(mv["amt"]) * dscale))
		if mv.has("ally_amt"):
			mv["ally_amt"] = int(round(float(mv["ally_amt"]) * dscale))
		out.append(mv)
	return out

## THE MOLT — a second rotation, swapped in at half HP and never swapped back. It is its own function
## because the intent panel's "Next:" line reads the rotation directly, and a panel still reading the
## armoured beats after the shell came off would be the exact lie this whole section exists to prevent.
## Gated on the DATA (an authored `moves_molt`) and not on an archetype id, so the next body that
## sheds a shell gets this for free. move_i is deliberately NOT reset: the two arrays are the same
## length by authoring rule, so beat 0 stays beat 0 — the telegraph the player already read still
## resolves, it just resolves as the molted version. Swapping a ROTATION is wire-safe (both halves are
## rebuilt locally on every peer from the same request); adding or removing BODIES would not be.
func _rotation(e: Dictionary) -> Array:
	var molt: Array = e.get("moves_molt", [])
	if not molt.is_empty() and Syn.molted(e):
		return molt
	return e.get("moves", [])

## The move this enemy is committed to (latched by construction: move_i only advances after acting).
## An entry without a rotation falls back to the classic flat attack.
##
## THIS IS THE ONLY PLACE THAT ANSWERS "what is it about to do", and the resolver AND all three
## telegraphs (the latched label, the panel headline, the Next line) read it. That is why every
## SUBSTITUTION lives here rather than in _do_enemy_move: a substitution the resolver made privately
## would be a number the player could not have seen coming.
func _enemy_move(e: Dictionary) -> Dictionary:
	var mvs: Array = _rotation(e)
	if mvs.is_empty():
		return {"name": "Attack", "kind": "attack", "dmg": int(e["atk"]), "tip": "A plain attack."}
	# THE ALONE GATE — the cornered Caster stops warding and only casts its heaviest beat. Substituted
	# here so it is visible in the telegraph the turn it becomes true, and previewed greyed in the
	# intent panel BEFORE it is true (see _device_line).
	var sub: Dictionary = Syn.alone_gate(enemies, e)
	if not sub.is_empty():
		return sub
	# TWIN BOND — the Wolf that lost its Witch howls on every beat. Syn owns the flag but deliberately
	# not the choice of beat: which move is "the howl" is rotation data, so it is matched on KIND here.
	# The rage cap (RAGE_CAP) still applies, so this plateaus instead of diverging, and _rage_gain
	# keeps the label honest ("max") once it does.
	if bool(Syn.twin_bond(enemies, e).get("howl_every_beat", false)):
		for m: Dictionary in mvs:
			if str(m.get("kind", "")) == "rage_all":
				return m
	return mvs[int(e["move_i"]) % mvs.size()]

## The beat AFTER the current one, run through the SAME substitution chain the live beat is.
##
## The intent panel's "Next:" line used to index _rotation() raw, which made it the one telegraph that
## could disagree with the resolver — and it disagreed PERMANENTLY, not for a turn. Both substitutions
## above are one-way: nothing revives, so a Caster that is alone stays alone and a Wolf that lost its
## Witch stays widowed. With move_i % 3 == 0 the panel promised "Next: Ward — block 6" while every
## remaining beat was a 15-damage Bolt, so the player blocked for a ward and ate the bolt. Neither
## backstop covered it: _device_line's alone-gate preview is explicitly gated on the gate NOT yet
## being live (it goes silent exactly when the Next line starts lying), and Syn.active_devices' gate
## sentence only reaches the feedback popup, which _refresh_intent_panel refuses to draw under.
##
## Probing a shallow copy with move_i+1 keeps _enemy_move the only place that answers "what is it
## about to do". Shallow is safe and deliberate: the only key written is move_i (an int), and
## archetype / slot / hp / max_hp / moves_molt — everything Syn matches a body, an aura or a molt on —
## survive duplicate() by value or by shared reference, either of which reads the same.
func _next_move(e: Dictionary) -> Dictionary:
	var probe: Dictionary = e.duplicate()
	probe["move_i"] = int(e["move_i"]) + 1
	return _enemy_move(probe)

## The move's OWN printed damage, before the board's contribution — i.e. what _move_dmg used to read
## straight off the dict. Only the regalia beats differ: a `gaze` move's damage is not authored on the
## move at all, it is 3 + 2 per living Rune Crystal (Syn.regalia), so the Overseer's output falls as
## its lattice does and killing rocks that never attack is visibly the correct play. Scaled by the
## same dscale the builder applied to every other move, or the one runtime-computed number in the game
## would be the one that ignores the encounter scale.
func _move_base(e: Dictionary, mv: Dictionary) -> int:
	if bool(mv.get("gaze", false)):
		return int(round(float(Syn.regalia(enemies)["gaze"]) * _dscale()))
	return int(mv.get("dmg", e["atk"]))

## THE ONE NUMBER. Per-hit damage of an attack-kind move, with every outgoing modifier folded in by
## Syn.effective_dmg — Howl rage, chorus, the Maw's gorge, the molt's fury, the doubled Shriek.
## The resolver and all three telegraphs come through here and nothing else, which is what makes the
## intent label structurally incapable of lying. NEVER add a modifier at a call site: a second path
## is a telegraph that disagrees with the hit, and the whole grammar dies with it.
func _move_dmg(e: Dictionary, mv: Dictionary) -> int:
	return Syn.effective_dmg(enemies, e, mv, _move_base(e, mv))

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
##
## TAUNT IS A BODY BLOCK, AND A BODY CANNOT BLOCK A SPELL (2026-07-21). `forced` used to return the
## tank the instant it was set, BEFORE the pref match ever ran — one energy deleted every targeting
## rule in the game at once. The measured consequence: target selection was worth 0% of a planner
## bot's advantage, and four of the twelve new encounters were unshippable because their whole named
## lesson is "you cannot solve this by taunting". So the redirect now COMPETES with pref instead of
## overriding it: it catches MELEE bodies only. A ranged enemy shoots past the Warrior and keeps its
## own preference.
##
## WHY REACH AND NOT A NUMERIC THREAT SCORE. A score-based pull fails exactly where the player needs
## it: it would refuse to drag a Caster off a dying Sorcerer, which is the one case anybody reaches
## for Taunt. It is also invisible — nothing on screen tells you what your score is, so the rule
## could never be predicted, only discovered after the damage landed. Reach is one sentence, it is
## already in the data, and it hands the ranged roster a permanent identity worth building
## encounters around.
func _enemy_target(e: Dictionary) -> Dictionary:
	if _taunt_catches(e):
		var w: Dictionary = _first_living_role("tank")   # Taunt -> a tank
		if not w.is_empty():
			return w
	match e["pref"]:
		"tankiest":
			return _pick_tankiest()
		"healer_dps":
			var c: Dictionary = _first_living_role("support")    # Healer first
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

## Does the standing Taunt actually redirect THIS body? Melee only — see _enemy_target.
## Every consumer of the redirect goes through here (the resolver, the threat arrows, the latched
## intent label, the intent panel and the portrait badge), so there is exactly one place that can
## answer "did the taunt take" and they cannot disagree. An arrow that shows a pull the resolver
## then ignores is worse than never having changed the rule.
func _taunt_catches(e: Dictionary) -> bool:
	return bool(e.get("forced", false)) and _enemy_range(e) < 2

## Reach of an enemy archetype: 1 = melee, 2 = ranged. The field has been in Db.ENEMIES since the
## removed grid fork and sat inert until Taunt was made to compete; anything missing it is melee,
## which is the safe default (a new enemy is taunt-able until someone says otherwise).
## Read off Db by `archetype` rather than stored on the enemy dict ON PURPOSE: the whole enemy dict
## crosses the wire, so a stored copy would be a second source of truth that also has to be
## int-coerced in _INT_KEYS (JSON hands ints back as floats). `archetype` already crosses, and it is
## static, so every peer derives the same answer with nothing added to the snapshot.
func _enemy_range(e: Dictionary) -> int:
	var ed: Dictionary = Db.ENEMIES.get(str(e.get("archetype", "")), {})
	return int(ed.get("range", 1))

func _first_living_role(role: String) -> Dictionary:
	for a: Dictionary in party:
		if a["alive"] and a["role"] == role:
			return a
	return {}

func _first_living_nontank() -> Dictionary:
	for a: Dictionary in party:
		if a["alive"] and a["role"] != "tank":
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
## Every int leaf that crosses the wire. JSON hands back FLOATS, so a key missing from this list
## arrives as 3.0 where the engine expects 3 — and `3.0 == 3` is true in GDScript, which is exactly
## why the bug hides: it only surfaces on a `%d` format or a match, long after the snapshot landed.
## Class Power state (class_powers.gd fresh_state) must stay mirrored here — see Powers.int_keys(),
## which combat_verify asserts against this list so the two cannot drift.
const _INT_KEYS := ["slot", "hp", "max_hp", "block", "shield", "energy", "max_energy",
	"vulnerable", "momentum", "devotion", "attacks_this_turn",
	"atk", "burn", "move_i", "rage", "intent_target",
	# --- Class Powers (2026-07-17) ---
	"power_cd", "power_turn", "communion", "rage_turn", "streak", "casts",
	"smite_charge", "mercy_charge", "shift_turns", "tithe_owed", "meta_charge",
	"held_idx", "regen",
	# --- enemy-side: the Assassin's Mark + Stun ---
	"am_owner", "am_tick", "am_turns", "stun"]
const _INT_KEYS_TEMP := ["retaliate", "channel_charges", "channel_bonus", "next_attack_bonus",
	"smite_bonus", "x_paid"]

# ---------------------------------------------------------------- The FX rider (M3b)
## Absolute snapshots tell a client WHAT the board is; they cannot tell it what just HAPPENED.
## A hit that lands and a hit that was fully blocked leave the same hp, and a 3-hit flurry collapses
## into one number — so the client saw the enemy phase as digits changing. These are the events.
##
## THE CONTRACT — fx are ADVISORY:
##   * They never mutate state. Nothing a peer reads as truth comes from one.
##   * They ride the board snapshot as a TOP-LEVEL array. Never inside an entity dict: _merge_into
##     (below) copies unknown keys in and never erases them, so an event welded to a dwarf would
##     replay forever.
##   * They are DRAINED on every build, so they ship exactly once. That is what makes the resync /
##     hello / rejoin re-sends — which re-broadcast a whole board with a fresh seq — carry no fx:
##     the beat that filled the buffer already spent it. Without the drain a client waking from a
##     backgrounded tab would replay a beat from a minute ago.
##   * A dropped snapshot loses its fx forever. That is the accepted price: a lost fx is a missed
##     animation, never a desync, because the next absolute snapshot repairs the board anyway.
##
## WHY THIS IS A BUS AND NOT A PATCH: recording happens INSIDE _flash/_impact — the only two VFX
## primitives combat has. So every one of today's call sites, and every future card, class or enemy
## move that flashes anything, is networked the moment it is written. There is no second code path
## to remember. Adding a new KIND of effect is: emit it from a primitive, handle it in _replay_fx.
const FX_MAX := 64      # a bundle that never stops growing is a bug, not a light show
const FX_TAIL := 16
var _fx: Array = []        # AUTHORITY: the pending wire bundle, drained by _build_snapshot
var _fx_seen: Array = []   # EVERY peer: a TAIL of what played here (capped) — for eyeballing kinds
var _fx_played := 0        # EVERY peer: how many played, monotonic — the assertable count

## Record one event. Called from inside the primitives, so it covers every call site by construction.
## No-op unless authoritative: SOLO needs no wire, and a CLIENT replaying through _flash must never
## re-record what it was just told. That one guard closes the loop.
func _fx_push(kind: String, c: Dictionary, mag: int) -> void:
	if mode != Mode.AUTHORITY or _fx.size() >= FX_MAX:
		return
	# side is stamped on the dict at construction (_start_combat), NOT sniffed: _do_enemy_move's
	# "expose" branch flashes a PARTY slot from an enemy's move, and enemy slot 0 and party slot 0
	# both exist — a slot int alone would silently animate the wrong dwarf.
	_fx.append({"k": kind, "s": str(c.get("side", "")), "i": int(c.get("slot", -1)), "m": mag})

## What played on THIS peer. Cosmetics leave no trace in the board state, so without this a test
## cannot tell "the client replayed the host's beat" from "the client did nothing".
## _fx_played is the number to assert on: _fx_seen is a capped ring, so once it is full its size
## stops growing and "did one more play?" cannot be read from it.
func _fx_mark(kind: String) -> void:
	_fx_played += 1
	_fx_seen.append(kind)
	if _fx_seen.size() > FX_TAIL:
		_fx_seen.remove_at(0)

## Aim an event at this peer's live node. Returns {} for an address it cannot resolve, so a
## malformed or future-versioned event is dropped rather than crashing the replay.
func _fx_target(side: String, slot: int) -> Dictionary:
	var pool: Array = party if side == "party" else (enemies if side == "enemy" else [])
	if slot < 0 or slot >= pool.size():
		return {}
	return pool[slot]

## CLIENT: play one event the host recorded. Unknown kinds are ignored on purpose — an older client
## meeting a newer host should miss an animation, not break.
func _replay_fx(f: Variant) -> void:
	if typeof(f) != TYPE_DICTIONARY:
		return
	var d: Dictionary = f
	var c: Dictionary = _fx_target(str(d.get("s", "")), int(d.get("i", -1)))
	if c.is_empty():
		return
	match str(d.get("k", "")):
		"f":
			_flash(c)
		"i":
			_impact(c, int(d.get("m", 0)))

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
		# ...and the same goes for the Molt-King's second rotation. It MUST be erased with its sibling:
		# an array of dicts crossing the wire would come back with float leaves that _INT_KEYS cannot
		# reach (it only coerces top-level keys), so every cracked-half number would arrive as 14.0 and
		# print as "14.0" the first time a "%d" met it.
		d.erase("moves_molt")
		es.append(d)
	# DRAIN, not read: fx are events, so they ship exactly once. Reassigning (rather than clearing)
	# means the dict we hand back can never alias the live buffer.
	# ⚠ This function MUST keep exactly ONE caller (_net_board). A second caller would silently eat
	# a bundle — the next peer's beat would simply never animate. combat_verify asserts the drain.
	var fx: Array = _fx
	_fx = []
	return {
		"seq": _next_seq(), "party": ps, "enemies": es,
		"globals": {
			"phase": phase, "turn": turn, "party_attack_buff": party_attack_buff,
			"taunt_last_turn": taunt_last_turn, "attacks_this_turn": attacks_this_turn,
			"combat_epoch": combat_epoch,
		},
		"ready": _seat_ready.duplicate(),
		"fx": fx,   # top level ONLY — see the FX rider contract above
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
	var was_turn: int = turn
	phase = str(g.get("phase", phase))
	turn = int(g.get("turn", turn))
	# A CLIENT never runs _start_player_phase — that is host-only — so the local UI latches it sets
	# would never reset. Without this an armed power survives the whole enemy phase and hijacks the
	# first enemy tap of the next turn, and an open pick strands the player over a stale board.
	if turn != was_turn:
		power_armed = false
		if choice_box != null:
			choice_box.visible = false
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
	# Replay LAST: _impact reads the node's global_position, which _refresh has just settled.
	# CLIENT-only. _flash/_impact carry no mode guard, so the host ALREADY animated inline inside
	# its own primitives as it resolved the beat — replaying here would double-animate every hit.
	if mode == Mode.CLIENT:
		for f: Variant in (snap.get("fx", []) as Array):
			_replay_fx(f)

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
	# The Bard's song, banked before anything resolves so a kill can't rob you of the target you
	# legitimately touched. (kind,idx) IS the distinct key — an AoE carries one address, so it counts
	# once no matter how many it hits, and nobody had to write that rule.
	Powers.on_target_touched(self, a, target_kind, target_idx)
	# ⏳ Heighten: the spell does NOT fire now. It is held and lands twice at the start of your next
	# turn. Held BEFORE resolving, and after _spend — you pay for it this turn either way.
	if str(a.get("meta_pick", "")) == "heighten" and str(def.get("school", "")) == "spell":
		a["meta_pick"] = ""
		a["held_cid"] = cid
		a["held_idx"] = target_idx if target_kind == "enemy" else -1
		_log("⏳ %s holds %s — it lands twice next turn." % [a["name"], def["name"]])
		_finish_play(a, def, cid)
		return
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
	# 🧿 Twinned: re-run against a SECOND enemy. Gated hard to a single-target enemy spell whose
	# effect fans out nowhere — arc_lightning carries a dmg_all INSIDE its effect, and re-running that
	# would hit the whole board twice off one Twin.
	if str(a.get("meta_pick", "")) == "twin" and str(def.get("school", "")) == "spell":
		a["meta_pick"] = ""
		if target_kind == "enemy" and _twinnable(def):
			var second: int = _second_enemy(target_idx)
			if second >= 0:
				_log("🧿 %s twins %s onto %s." % [a["name"], def["name"], enemies[second]["name"]])
				_resolve(def, a, enemies[second])
	_finish_play(a, def, cid)

## A spell can be Twinned only if every op in it aims at the ONE target it was pointed at. Anything
## that fans out on its own (dmg_all, party_block, party_buff, heal_party) would double-apply.
func _twinnable(def: Dictionary) -> bool:
	for op: Array in def["effect"]:
		if str(op[0]) in ["dmg_all", "party_block", "party_buff", "heal_party", "dmg_x"]:
			return false
	return true

func _second_enemy(not_idx: int) -> int:
	for i: int in range(enemies.size()):
		if i != not_idx and enemies[i]["alive"]:
			return i
	return -1

## The Druid's tithe: this card goes back into the DECK, not the discard, and is NOT replaced. The
## −2 hand IS the price of the form. You choose which two, so it isn't a mulligan — it's a tithe you
## get to aim, and the two you hand back are the two your form was never going to pay for.
func _pay_tithe(a: Dictionary, idx: int) -> void:
	var cid: String = a["hand"][idx]
	a["deck"].append(cid)
	a["deck"].shuffle()
	a["hand"].remove_at(idx)
	a["hand_uids"].remove_at(idx)
	a["tithe_owed"] = maxi(0, int(a["tithe_owed"]) - 1)
	_log("🐾 %s hands %s back to the deck (%d to go)." % [a["name"], Db.CARDS[cid]["name"], int(a["tithe_owed"])])

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
	var owes: bool = int(a.get("tithe_owed", 0)) > 0
	if mode == Mode.CLIENT:
		if not owes and Powers.cost_of(a, def) > _pool_of(a) and not Powers.is_x_cost(def):
			_log("Not enough energy for %s." % def["name"])   # courtesy only; the authority re-validates
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
	if owes:
		_pay_tithe(a, idx)
		_refresh()
		_net_board()
		return
	if not _can_play(a, cid, def):
		return
	_apply_play(a, idx, cid, def, target_kind, target_idx)
	_net_board()

# ---------------------------------------------------------------- Class Powers
## Every power tap routes here — the mirror of _try_play. CLIENT sends an intent and mutates nothing.
func _try_power(seat: int, choice: String, t_idx: int) -> void:
	if seat < 0 or seat >= party.size() or phase != "playerTurn":
		return
	if mode == Mode.CLIENT:
		if not Powers.can_fire(self, party[seat]):   # courtesy only; the authority re-validates all of it
			var why: String = Powers.gate_reason(party[seat])
			if why != "":
				_log(why)
			return
		Net.send_message("submit_power", {"seat": seat, "peer_id": Net.ensure_peer_id(),
			"choice": choice, "target_idx": t_idx, "nonce": _next_nonce()})
		selected_uid = ""
		_refresh()
		return
	if mode == Mode.AUTHORITY and not _barrier_open:
		_log("Waiting for the other players…")
		return
	if _seat_ended(seat):
		return
	if not Powers.fire(self, seat, choice, t_idx):
		var why2: String = Powers.gate_reason(party[seat])
		if why2 != "":
			_log(why2)
		return
	_refresh()
	_net_board()

## Authority: validate a client's power tap. Nothing here trusts the client — same boundary as a card.
##
## ⚠ THE _seat_ended GATE IS LOAD-BEARING, AND _on_action DOES NOT HAVE ONE. _on_action gets away with
## it by ACCIDENT: ending discards your hand, so _hand_index_of returns -1 and the play dies on its
## own. A power has no card, so nothing would stop an ended seat firing one.
func _on_power(act: Dictionary) -> void:
	if not _barrier_open or phase != "playerTurn":
		return
	var seat: int = int(act.get("seat", -1))
	if seat < 0 or seat >= party.size():
		return
	if not _peer_owns_seat(str(act.get("peer_id", "")), seat):
		return
	if not party[seat]["alive"] or _seat_ended(seat):
		return
	var saved: String = selected_uid   # a teammate's power must not drop the host's own armed card
	if not Powers.fire(self, seat, str(act.get("choice", "")), int(act.get("target_idx", -1))):
		return
	selected_uid = saved
	_refresh()
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
	# A Druid owing its form the tithe is PAYING with this tap, not playing. The card uid is already
	# the address, so the tithe needs no modal and no second intent — it reuses this one whole.
	if int(a.get("tithe_owed", 0)) > 0:
		_pay_tithe(a, idx)
		_refresh()
		_net_board()
		return
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
			# Distinct from every other event on the shared Net autoload — including the campaign's
			# camp_* namespace, which a NESTED fight rides alongside.
			"submit_power": _on_power(payload)
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

# ================================================================ Class Power input
## Tapping your own orb. The three shapes a power can take, and they never combine — a power with a
## 3-way pick never also needs a target, which is why one tap is always enough to disambiguate.
func _on_orb_input(event: InputEvent, idx: int) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	get_viewport().set_input_as_handled()   # never fall through to the portrait underneath
	if phase != "playerTurn":
		return
	# You only ever fire your own. In SOLO the active dwarf is the one you are piloting.
	var mine: int = my_seat if mode != Mode.SOLO else active_idx
	if idx != mine:
		# SOLO pilots every dwarf, so the orb of a non-active one is just part of that portrait: tap it
		# to switch, exactly as tapping the emoji does. In co-op you only ever fire your own.
		if mode == Mode.SOLO:
			_on_party_clicked(idx)
		else:
			_log("That's not your dwarf's power.")
		return
	var a: Dictionary = party[idx]
	if not Powers.can_fire(self, a):
		var why: String = Powers.gate_reason(a)
		if why != "":
			_log(why)
		return
	var p: Dictionary = Powers.power_def(a)
	if not (p.get("choices", []) as Array).is_empty():
		_open_choice(idx)
		return
	if str(p.get("target", "")) == "enemy":
		power_armed = true
		selected_uid = ""     # arming a power disarms a card; the reticle can only mean one thing
		_log("%s — tap an enemy." % str(p["name"]))
		_refresh()
		return
	_try_power(idx, "", -1)

## The 3-way pick. Built in code like every other screen here, and shown over the hand — the cards
## underneath are unreachable while it is up, which is the point: the tap is not ambiguous.
func _open_choice(seat: int) -> void:
	var p: Dictionary = Powers.power_def(party[seat])
	var choices: Array = p.get("choices", [])
	for b: Button in choice_btns:
		b.queue_free()
	choice_btns = []
	for i: int in range(choices.size()):
		var o: Dictionary = choices[i]
		var b := Button.new()
		b.text = "%s  %s\n%s" % [str(o["emoji"]), str(o["name"]), str(o["tip"])]
		b.position = Vector2(48, 346 + i * 76)
		b.size = Vector2(624, 68)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.add_theme_font_size_override("font_size", 13)
		b.pressed.connect(_on_choice.bind(seat, str(o["key"])))
		choice_box.add_child(b)
		choice_btns.append(b)
	# A full-screen modal with no way out is a soft-lock: nothing else on the board is reachable while
	# it is open, so opening the pick by accident would end your turn for you.
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.position = Vector2(48, 346 + choices.size() * 76 + 8)
	cancel.size = Vector2(624, 40)
	cancel.add_theme_font_size_override("font_size", 13)
	cancel.pressed.connect(_close_choice)
	choice_box.add_child(cancel)
	choice_btns.append(cancel)
	choice_box.visible = true

func _close_choice() -> void:
	choice_box.visible = false

func _on_choice(seat: int, key: String) -> void:
	choice_box.visible = false
	_try_power(seat, key, -1)

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
	# Disarm BOTH latches, for the same reason: they belonged to the dwarf you just left. An armed
	# power that survives the switch aims the NEW dwarf's power at your next enemy tap.
	selected_uid = ""
	power_armed = false
	_refresh()

func _on_enemy_clicked(idx: int) -> void:
	if phase != "playerTurn" or not enemies[idx]["alive"]:
		return
	# An armed power aims exactly like an armed card.
	if power_armed:
		power_armed = false
		_try_power(my_seat if mode != Mode.SOLO else active_idx, "", idx)
		_refresh()
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
		power_armed = false   # arming a card disarms a power, exactly as an orb tap disarms a card
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

## What this card costs THIS dwarf right now, and out of which pool. Never read def["cost"] directly:
## it can be the string "X", and comparing a String to an int in GDScript is not a bug you find in
## review — it is a runtime error in the middle of a fight.
func _pool_of(a: Dictionary) -> int:
	return int(a["block"]) if bool(a["temp"].get("pay_with_guard", false)) else int(a["energy"])

## Can this dwarf pay for this card right now? The ONE affordability read — _can_play gates on it and
## the hand renders playability with it, so a card can never look playable and then be refused.
## Three things move the answer off the printed number: an X cost (a String), Reforge (which pool
## pays), and Quicken (the price). A Druid owing its form the tithe can "play" anything: the tap
## hands the card back instead.
func _affordable(a: Dictionary, def: Dictionary) -> bool:
	if int(a.get("tithe_owed", 0)) > 0:
		return true
	if Powers.is_x_cost(def):
		return _pool_of(a) > 0
	return Powers.cost_of(a, def) <= _pool_of(a)

func _can_play(a: Dictionary, _cid: String, def: Dictionary) -> bool:
	if not _affordable(a, def):
		if Powers.is_x_cost(def):
			_log("%s needs something to spend." % def["name"])
		else:
			_log("Not enough %s for %s." % ["Guard" if bool(a["temp"].get("pay_with_guard", false)) else "energy", def["name"]])
		return false
	# Was hardcoded to `cid == "taunt"`; the Barbarian's Bellow is the same card in a different kit,
	# so the limiter is read off the data instead of the id.
	if str(def.get("limiter", "")) == "no_repeat" and turn - taunt_last_turn < 2:
		_log("%s is recovering — not two turns in a row." % def["name"])
		return false
	return true

func _spend(a: Dictionary, idx: int) -> void:
	var cid: String = a["hand"][idx]
	var def: Dictionary = Db.CARDS[cid]
	var guard: bool = bool(a["temp"].get("pay_with_guard", false))
	var paid: int = _pool_of(a) if Powers.is_x_cost(def) else Powers.cost_of(a, def)
	# Stamp what was ACTUALLY paid — dmg_x reads this, never the printed cost.
	a["temp"]["x_paid"] = paid
	if guard:
		a["block"] = maxi(0, int(a["block"]) - paid)
		a["temp"]["pay_with_guard"] = false   # Reforge is one card, not a stance
	else:
		a["energy"] = int(a["energy"]) - paid
	# Quicken is consumed on the SCHOOL match, not on a cost delta: `empower` is a live 0-cost spell,
	# and maxi(0, 0-2) == 0 == its printed cost, so a delta check would never fire on it and the pick
	# would survive the very spell it was meant to shape.
	if str(a.get("meta_pick", "")) == "quicken" and str(def.get("school", "")) == "spell":
		a["meta_pick"] = ""
	a["hand"].remove_at(idx)
	a["hand_uids"].remove_at(idx)
	a["played_turn"].append(cid)   # ghosted in the mini row until next player phase

func _finish_play(a: Dictionary, def: Dictionary, cid: String) -> void:
	a["discard"].append(cid)
	if def.get("is_attack", false):
		attacks_this_turn += 1                             # party-wide count for Finisher
		# Momentum counts attacks you played THIS turn. The DPS sheet dropped it as a meter, but that
		# is exactly what the Barbarian's rage upkeep has to read — so it stays as what it measures.
		a["momentum"] = int(a.get("momentum", 0)) + 1
	else:
		a["devotion"] = int(a.get("devotion", 0)) + 1      # banked, spent by the Paladin's Smite
	# The one per-cast hook: charges every Sorcerer's Metamagic off ANY seat's spell, and drives the
	# Cleric's whole passive aura. Fired here because this is where every play — SOLO, host tap, and a
	# client's action resolved on the host — already funnels.
	Powers.on_card_resolved(self, a, def)
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
			# gain_guard is a pure ALIAS of block. Guard IS this field: it already soaks in
			# _enemy_attack and already pulls threat in _pick_tankiest. The alias exists only so the
			# Tank sheet's card text can say "Guard" without a second pool behind it.
			"block", "gain_guard":
				var bonus: int = 0
				if a["temp"]["fortify_guard"] and fortifiable:
					bonus = 5
					a["temp"]["fortify_guard"] = false   # consume the +5; Retaliate +2 persists
				_gain_guard(a, int(op[1]) * mult + bonus)
			"party_block":
				for x: Dictionary in party:
					if x["alive"]:
						_gain_guard(x, int(op[1]) * mult)
			"heal_party":
				for x: Dictionary in party:
					if x["alive"]:
						x["hp"] = mini(int(x["max_hp"]), int(x["hp"]) + int(op[1]) * mult)
			"dmg_per_guard":
				# Cash the wall in: op[1] damage per op[2] Guard held. Modelled on dmg_per_momentum.
				_attack(a, target, int(float(a["block"]) * float(op[1]) / float(op[2])) * mult, is_atk)
			"dmg_x":
				# X-cost. Reads what _spend ACTUALLY paid, never the printed cost. Single-target on
				# purpose: _apply_play already loops the enemies for an all_enemies card, so an op
				# that looped them again would be N-squared.
				_attack(a, target, int(a["temp"].get("x_paid", 0)) * mult, is_atk)
			"pay_with_guard":
				a["temp"]["pay_with_guard"] = true
			"bank_communion":
				# NOT multiplied by mult — Empower doubles numbers, not resource tags.
				a["communion"] = mini(Powers.COMMUNION_MAX, int(a.get("communion", 0)) + int(op[1]))
			"buff_ally_next":
				if not target.is_empty() and target.get("role", "") != "":
					target["temp"]["next_attack_bonus"] = int(target["temp"].get("next_attack_bonus", 0)) + int(op[1]) * mult
			"heal_ally_next":
				if not target.is_empty() and target.get("role", "") != "":
					target["regen"] = int(target.get("regen", 0)) + int(op[1]) * mult
			"shuffle_random_into_deck":
				for i: int in range(int(op[1])):
					if (a["hand"] as Array).is_empty():
						break
					var r: int = randi() % (a["hand"] as Array).size()
					a["deck"].append(a["hand"][r])
					a["hand"].remove_at(r)
					a["hand_uids"].remove_at(r)
				a["deck"].shuffle()
			"bard_free_target":
				# A CONSTANT key, so Refrain can only ever be worth one distinct target no matter how
				# many times it is played.
				Powers.on_target_touched(self, a, "free", -1)
			"if_form":
				if str(a.get("form", "")) == str(op[1]):
					_run_ops(op[2], a, target, mult, is_atk, false)
			"if_assassin_mark":
				if not target.is_empty() and int(target.get("am_turns", 0)) > 0:
					_run_ops(op[1], a, target, mult, is_atk, false)
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
					_apply_enemy_status(target, "marked", 1)
			"apply":
				_apply_enemy_status(target, str(op[1]), int(op[2]) if op.size() > 2 else 1)
			"force_target_all":
				# The flag goes on EVERY body, including the ranged ones it will not move. Whether a
				# taunt takes is decided once, at read time, in _taunt_catches — so the ranged bodies
				# can still wear the 🏹 "it slid off me" badge. Filtering here instead would make a
				# ranged enemy indistinguishable from a board with no Taunt on it at all.
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
					"smite_bonus":
						# Accumulates: the Paladin ships TWO Vows, and swearing both should stack.
						a["temp"]["smite_bonus"] = int(a["temp"].get("smite_bonus", 0)) + int(op[2]) * mult
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

## Guard/block onto a dwarf. THE one write path, so the Barbarian's "rage replaces Guard" is a single
## early-return instead of a rule every caller has to remember — including an ally's Consecrate
## landing on him, which is the correct read of "can no longer gain Guard".
func _gain_guard(a: Dictionary, v: int) -> void:
	if v == 0 or not a.get("alive", false) or Powers.blocks_guard(a):
		return
	a["block"] = int(a["block"]) + v

## THE one place a status lands on an enemy. Every route funnels here — a card's `apply`, Mark, the
## Rogue's bleed — because the Monk's refund reads this and a missed site is a dead refund the player
## cannot see. Guarded: the shipped apply_status wrote `marked` onto anything, corpse or not.
func _apply_enemy_status(e: Dictionary, kind: String, n: int) -> void:
	if e.is_empty() or not e.get("alive", false) or e.get("role", "") != "":
		return   # empty target, a corpse, or an ALLY dict — none of them can carry an enemy status
	match kind:
		"marked":
			e["marked"] = true
		"burn":
			e["burn"] = int(e.get("burn", 0)) + n
		"vulnerable":
			e["vulnerable"] = int(e.get("vulnerable", 0)) + n
		"stun":
			e["stun"] = int(e.get("stun", 0)) + n
		_:
			return   # an unknown status is not a status, and must not refund a Flurry
	Powers.on_status_applied(self, e)

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
		amt += Powers.attack_flat_bonus(a)   # Barbarian: +4 while raging AND Bloodied
	if enemy["marked"]:
		amt = int(round(amt * Db.MARK_MULT))
	if int(enemy.get("vulnerable", 0)) > 0:
		amt = int(round(amt * VULN_MULT))
	# AEGIS (and the two boss-shaped soaks: the Overseer's regalia, the Molt-King's carapace).
	# It goes LAST, after xMark and xVulnerable, because it is a flat shell and a multiplier must
	# never be allowed to amplify a flat soak — 6 soak on a x1.5 hit is 6, not 9.
	#
	# ⚠ IT LIVES IN _attack AND DELIBERATELY NOT IN _deal_enemy. Burn ticks, the Assassin's Mark bleed
	# and Retaliate's reflect all write through _deal_enemy precisely BECAUSE they route around the
	# armour rules (see _enemy_phase's comment on status damage ignoring block) — and aegis IS armour.
	# So a shell soaks swings and does nothing to a fire you already lit, which makes burn the designed
	# way through an aegis line rather than a loophole in it. Nothing on screen contradicts that: every
	# tip and every readout says "less per hit", and a burn tick is not a hit.
	var soak: int = Syn.incoming_reduction(enemies, enemy)
	if soak > 0:
		amt = maxi(0, amt - soak)
	_deal_enemy(enemy, amt)
	# The Assassin's Mark is fed from both ends here: an ally's hit buys it a turn, the owner's hit
	# buys it a tick. May run on an enemy this hit just killed — harmless only because every reader
	# of the mark gates on `alive`, which is the invariant the placement leans on.
	Powers.on_attack_landed(self, a, enemy)
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
	# Barbarian resistance sits between xVulnerable and the shield: base -> xVuln -> xHALF -> shield
	# -> block -> hp. It is a CEIL, so a 1-damage chip can never round down to free.
	raw = Powers.incoming_scale(t, raw)
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
	power_armed = false
	if choice_box != null:
		choice_box.visible = false   # z_index 50 would paint a stale pick over the win screen
	# ...and the notes are z_index 70, i.e. ABOVE the win overlay. Left open they would bury the
	# result and the Play Again button under a full-screen dim with no way back to them.
	if feedback != null:
		feedback.close()
	if not request.is_empty():
		var crew_results: Array = []
		for a: Dictionary in party:
			crew_results.append({"name": a["name"], "cls": a.get("cls", a["role"]), "survived": a["alive"], "hp_end": a["hp"], "max_hp": a["max_hp"]})
		combat_finished.emit({"success": won, "crew_results": crew_results, "payout_won": won})
		return
	overlay_label.text = "The dwarves delivered.\nQuarterly demon targets met." if won else "Liquidation.\nThe contract is void."
	overlay.visible = true
	_refresh()

func _on_overlay_btn() -> void:
	_start_combat()

# ================================================================ The designer's notes
## Open the popup. This is the ONLY thing that ever reveals an encounter's intent, by design.
##
## CO-OP: purely local and purely read-only. It sends nothing (no new wire event, and nothing here
## touches Net), it mutates nothing (both dicts are built fresh and handed over by value), and it
## does not gate the simultaneous-play flow — your seat's End Turn is not blocked for anyone else
## while you read, and the other seats never learn that you opened it. What it DOES do is swallow
## every tap on the board underneath, because the panel's root is a full-screen MOUSE_FILTER_STOP
## Control: this repo's most expensive modal bug was a floating panel that left the card fan live
## beneath it, so you could read a popup and play a card with the same tap.
func _on_feedback() -> void:
	if feedback == null:
		return
	# Close the two hover explainers first. Both are z_index 60/61, i.e. UNDER the popup's 70, so they
	# would sit invisible behind the dim and then reappear on dismiss pointing at a body the player has
	# long since stopped looking at. The panel also blocks the mouse_exited that would normally close
	# them, so nothing else will.
	_close_intent(intent_open)
	_close_power_tip(power_tip_open)
	feedback.show_notes(_encounter(), _live_board())

## Is the popup up? One null-safe predicate rather than `feedback != null and feedback.visible`
## repeated at every guard — _build_ui creates it before _start_combat so it is never actually null
## in play, but combat.gd already guards choice_box the same way and a modal check that can itself
## crash is worse than no modal check.
func _feedback_up() -> bool:
	return feedback != null and feedback.visible

## The authored encounter behind THIS fight, or {} when there is not one.
##
## request["encounter"] is the id the campaign will stamp on a rolled board. It is absent today, it is
## absent forever in a freeform skirmish rolled from Db.ENCOUNTER_POOLS, and it is absent in every
## test harness (powers_verify / combat_verify / the coop harnesses all build request by hand) — so
## the missing case is the COMMON case, not the edge case, and it must be silent. get_enc() answers
## {} for both "" and an unknown id, and the panel has a written fallback for {}: it says outright
## that nobody designed this fight, which is itself a finding worth showing a playtester.
func _encounter() -> Dictionary:
	return Enc.get_enc(str(request.get("encounter", "")))

## The board as it actually is, right now. Intent is only useful next to reality — "the rhythm says
## turn 2 is the squeeze" means nothing until you can see you are ON turn 2 with two bodies up.
func _live_board() -> Dictionary:
	var bodies := 0
	for e: Dictionary in enemies:
		if e.get("alive", false):
			bodies += 1
	return {
		"turn": turn,
		"bodies": bodies,
		"devices": _live_devices(),
		# The scale the fight was BUILT at, read back off the request rather than off _dscale(): the
		# encounter's design block quotes bestiary-contract numbers against escale, so the popup has to
		# print the same axis or the two cannot be compared.
		"scale": float(request.get("enemy_scale", 1.0)),
	}

## The device keys switched on right now, deduped, in board order.
##
## Syn.active_devices returns {"key", "text"} rows — one per device INSTANCE, so a board with two
## molted bodies yields two "molt" rows carrying two different sentences. The panel joins its
## `devices` list with ", " and str()s each entry, so handing it those dicts verbatim would print a
## wall of `{ "key": "molt", "text": "..." }` across the one line whose whole job is to be glanceable.
## The sentences are not lost: every one of them is already ON the board (the per-body device line
## under each portrait, and the intent panel's synergy row). What the popup needs here is "what is
## switched on", not "what does it do" — so this collapses each row to its key.
func _live_devices() -> Array:
	var out: Array = []
	for d: Variant in Syn.active_devices(enemies):
		if not (d is Dictionary):
			continue
		var k: String = str((d as Dictionary).get("key", ""))
		if k != "" and not out.has(k):
			out.append(k)
	return out

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
	# The notes button follows End Turn exactly: it is a live affordance for the WHOLE fight (a
	# playtester forms the judgement mid-fight, not on the win screen) and disappears only under the
	# win/lose overlay, where it would paint over the result. It is never disabled by phase — reading
	# the design during the enemy phase is a legitimate and common thing to want to do.
	if feedback_btn != null:
		feedback_btn.visible = not overlay.visible
	_update_cursor()
	_refresh_intent_panel()
	_refresh_power_tip()
	_hand_anim = ""   # one-shot: consumed by _rebuild_hand/_refresh_minis above
	_switch_from = -1

func _refresh_enemies() -> void:
	# The collapsed swarm lines are resolved FIRST: they decide which bodies must NOT draw their own
	# intent label, and a per-body loop that had already drawn one would leave both on screen.
	var collapsed: Dictionary = _refresh_swarm_lines()
	for i: int in range(enemies.size()):
		var e: Dictionary = enemies[i]
		var alive: bool = e["alive"]
		en_emoji[i].visible = alive
		en_name[i].visible = alive
		en_intent[i].visible = alive and not collapsed.has(i)
		en_hp[i].visible = alive
		# `forced` joins the status row because a Taunt that did NOT take has to be visible: the badge
		# is the only thing on screen that distinguishes "this body ignored your Taunt" from "you
		# never played one". Without it the player just sees an arrow that failed to move.
		var has_stat: bool = e["block"] > 0 or int(e.get("burn", 0)) > 0 or int(e.get("vulnerable", 0)) > 0 \
			or int(e.get("stun", 0)) > 0 or bool(e.get("forced", false))
		en_block[i].visible = alive and has_stat
		# BEFORE the corpse early-out: a dead body must drop its slab, its device row and its meter, or
		# a killed Shellback would leave its aegis wash on the board it no longer protects — a synergy
		# that is visibly still running after you solved it is worse than one you never saw.
		_refresh_devices(i, e)
		# The demoted pref badge is only ever on screen while a Taunt is actually redirecting this body.
		var taunted: bool = _taunt_catches(e)
		en_rule[i].visible = alive and taunted
		if taunted:
			en_rule[i].text = str(Db.PREF_BADGES.get(str(e.get("pref", "")), {}).get("badge", ""))
		if not alive:
			continue
		# NAMEPLATE = [pref badge][mark][name]. The badge is IDENTITY (what this body always does) and
		# lives here rather than in the intent line, which is TRUTH (what it is about to do). Keeping
		# them apart is what lets a player learn a rule instead of re-reading this turn's target.
		en_name[i].text = "%s %s%s" % [_pref_badge(e), ("🎯 " if e["marked"] else ""), e["name"]]
		en_hp[i].text = "%d/%d" % [e["hp"], e["max_hp"]]
		var estat := ""
		if e["block"] > 0:
			estat += "🛡️%d " % e["block"]
		if int(e.get("burn", 0)) > 0:
			estat += "🔥%d " % int(e["burn"])
		if int(e.get("vulnerable", 0)) > 0:
			estat += "💥 "
		# 💫 Stun was LOG-ONLY until 2026-07-22: the enemy skipped its turn and the only trace was a
		# line in the log, so the player could not tell "I stunned it" from "the telegraph was wrong".
		# It is a status, so it wears a status badge like every other one, and the telegraph says so
		# too (see _intent_text) — a skipped beat has to be visible in the slot the beat lives in.
		if int(e.get("stun", 0)) > 0:
			estat += "💫%d " % int(e["stun"])
		# 🏹 = a standing Taunt slid off this body because it is ranged, so its own preference stands.
		# The 😡 case is NOT here any more: an overridden rule belongs on the nameplate beside the rule
		# it overrode (see _pref_badge), not in the status row, where it read as one more wearing-off
		# debuff. What is left here is the NEGATIVE case, which has no home on the nameplate because
		# nothing about the body's rule changed — and it is the case the player most needs told.
		if bool(e.get("forced", false)) and not taunted:
			estat += "🏹 "
		en_block[i].text = estat
		var mv: Dictionary = _enemy_move(e)
		en_intent[i].text = _intent_text(e)
		# CHORUS PRINTS THE TOTAL, NEVER THE ARITHMETIC. The number in the label is ALREADY the buffed
		# one (it comes through _move_dmg -> Syn.effective_dmg), so the only thing left to say is WHO is
		# doing it — and a colour says that without asking the player to do sums mid-fight. Tinted in
		# the SOURCE's colour rather than a generic "buffed" colour, because with two possible singers
		# on the board (🔮 and 🍄) the useful half of the information is which one to kill.
		# Gated on the move KIND, not on the damage: a Ward's base falls back to `atk`, so a
		# damage>0 test would tint a block beat that chorus does not touch.
		en_intent[i].add_theme_color_override("font_color", _intent_tint(e, mv))
		# Highlight valid enemy targets while an enemy-target card is armed.
		var arm: Dictionary = _armed_def()
		var can: bool = arm.get("target", "") in ["enemy", "ally_or_enemy"]
		en_emoji[i].modulate = Color(1.3, 1.05, 0.6) if (can and selected_uid != "") else Color.WHITE

## The intent label's colour: its kind's, unless a chorus is inflating the number — then the SOURCE's,
## so the tint answers "which body do I kill to make this number smaller". Pulled out of the per-body
## loop the moment the collapsed swarm line needed the identical answer for a whole run.
func _intent_tint(e: Dictionary, mv: Dictionary) -> Color:
	if Syn.chorus_bonus(enemies, e) > 0 and str(mv.get("kind", "")) in Syn.DMG_KINDS:
		return _source_tint(Syn.aura_source(enemies, Syn.CHORUS))
	return _intent_color(str(mv.get("kind", "")))

## The nameplate badge — one of the three shipped prefs, or 😡 when a standing Taunt ACTUALLY takes.
## See Db.PREF_BADGES for why the set is closed at three and why 😡 REPLACES rather than hides.
## Everything about "did the redirect take" goes through _taunt_catches, the single answer the
## resolver, the arrows, the label and this badge all read — a badge that promised a pull the
## resolver ignores would be worse than no badge at all, and Taunt is melee-only since 2026-07-21.
func _pref_badge(e: Dictionary) -> String:
	var key: String = "forced" if _taunt_catches(e) else str(e.get("pref", ""))
	return str((Db.PREF_BADGES.get(key, {}) as Dictionary).get("badge", ""))

## The badge's sentence, for the intent panel. Same lookup, same closed set — one table, so the glyph
## on the board and the words in the panel cannot drift.
func _pref_tip(e: Dictionary) -> String:
	var key: String = "forced" if _taunt_catches(e) else str(e.get("pref", ""))
	return str((Db.PREF_BADGES.get(key, {}) as Dictionary).get("tip", ""))

## THE SWARM LINE — one label for a contiguous run of 3+ identical living minions, drawn across the
## run in place of their individual intent labels. Returns the set of slot indices whose own label
## must therefore stay hidden, so the caller cannot forget to hide them.
##
## WHY IT IS WORTH A WHOLE FUNCTION: four Cave Bats telegraphing "🗡️4>Sor" four times is four labels
## that say one thing. The cost is not clutter, it is that the player's eye has to VISIT all four to
## discover there was nothing to compare — on the exact boards (5-6 bodies) where attention is already
## the scarce resource. One line, one number, one decision.
##
## WHY A CONTIGUOUS RUN AND NOT "ALL THE BATS": contiguity is what makes duplicates read as one
## object. Two bats with a Warden standing between them are genuinely two problems (the Warden's aegis
## sits between them), and a bracket drawn over the Warden would claim otherwise. Syn.swarm_groups
## already enforces contiguity; this only draws what it found.
##
## THE COLLAPSE IS GATED ON THE BEATS ACTUALLY MATCHING, and bails to individual labels if they do
## not. Rotations start at a random offset per instance, so two of the same archetype CAN be
## telegraphing different beats. Swarm chaff is authored with a single beat precisely so a swarm stays
## summarisable, which means this gate is nearly always satisfied — it exists for the day someone
## gives a minion a second beat, which is exactly the day a silent collapse would start lying. A
## STUNNED member bails for the same reason: it is not doing what the line says, and one line claiming
## four swings when three are coming is the one failure mode that would make the number untrustworthy.
##
## THE SUMMED TOTAL IN PARENTHESES IS THE POINT. "🗡️3>Sor" four times is a multiplication the player
## has to do; "(12)" against a 22-HP Sorcerer is a decision they can make.
func _refresh_swarm_lines() -> Dictionary:
	var collapsed: Dictionary = {}
	for l: Label in sw_line:
		l.visible = false
	# Only while the intents are LATCHED. Mid enemy-phase the beats resolve one at a time and a
	# summed line would keep claiming swings that have already landed.
	if phase != "playerTurn" or enemies.is_empty():
		return collapsed
	var li: int = 0
	for g: Dictionary in Syn.swarm_groups(enemies):
		if li >= sw_line.size():
			break
		var slots: Array = g.get("slots", [])
		if slots.size() < Syn.SWARM_MIN or int(slots[0]) >= enemies.size():
			continue
		var head: Dictionary = enemies[int(slots[0])]
		var hm: Dictionary = _enemy_move(head)
		var same: bool = true
		var total: int = 0
		for s: int in slots:
			if s >= enemies.size():
				same = false
				break
			var e: Dictionary = enemies[s]
			var mv: Dictionary = _enemy_move(e)
			if int(e.get("stun", 0)) > 0 or str(mv.get("name", "")) != str(hm.get("name", "")) \
				or str(mv.get("kind", "")) != str(hm.get("kind", "")):
				same = false
				break
			total += _body_total(e, mv)
		if not same:
			continue
		# Span the run: from the first body's label box to the last one's, so the bracket visibly
		# BELONGS to those bodies and stops at the edge of the group.
		var lw: float = _slot_label_w()
		var x0: float = float(en_pos[int(slots[0])].x)
		var x1: float = float(en_pos[int(slots[slots.size() - 1])].x)
		var l2: Label = sw_line[li]
		l2.position = Vector2(x0 - lw * 0.5, float(en_pos[int(slots[0])].y) - 52.0)
		l2.size = Vector2((x1 - x0) + lw, 22)
		# The FULL font, never the squeezed one: this line owns the whole run's width, so it is the one
		# label on a six-body board that has room. Collapsing and then shrinking would spend the space
		# the collapse just bought.
		l2.add_theme_font_size_override("font_size", 18)
		l2.add_theme_color_override("font_color", _intent_tint(head, hm))
		l2.text = "%s×%d %s (%d)" % [str(head.get("emoji", "")), slots.size(), _intent_text(head), total]
		l2.visible = true
		for s2: int in slots:
			collapsed[s2] = true
		li += 1
	return collapsed

## Everything ONE body's current move will put into the party this phase, per-hit numbers summed.
## Shared by the swarm line's total and by the forecast's sanity, so the two can never disagree about
## what "a body's output" means. Non-damage beats are 0 by construction (they are not in DMG_KINDS).
func _body_total(e: Dictionary, mv: Dictionary) -> int:
	var kind: String = str(mv.get("kind", ""))
	if not kind in Syn.DMG_KINDS:
		return 0
	if kind == "attack_all":
		var living: int = 0
		for a: Dictionary in party:
			if a.get("alive", false):
				living += 1
		return _move_dmg(e, mv) * living
	var hits: int = int(mv.get("hits", 1)) if kind == "multi" else 1
	return _intent_hit(e, mv) * hits

## The colour that IDENTIFIES an aura source. See SOURCE_TINT — the point is which body, not which
## aura, so an unlisted source falls back to a neutral gold rather than to a per-kind colour that
## would make two different sources look like the same one.
func _source_tint(src: Dictionary) -> Color:
	var c: Variant = SOURCE_TINT.get(str(src.get("archetype", "")), AURA_FALLBACK_TINT)
	return c if c is Color else AURA_FALLBACK_TINT

## THE DEVICE READOUT for one body — the half of this task that is not arithmetic. Every device in
## synergies.gd is worthless if the player cannot see it BEFORE committing a card, so each one gets a
## mark on the board itself and not only a line in a tooltip:
##   aegis  -> a slab behind the portrait in the SOURCE's colour (solid on the source, faint on
##             everything it shields) + a "🪨-N" chip. Colour is the link between them.
##   chorus -> the source is slabbed in its own colour too, and every recipient's intent label is
##             TINTED that colour (see _refresh_enemies). The label already prints the buffed total.
##   gorge  -> 🩸 pips, one per corpse, capped at the 4 that reach Syn.GORGE_CAP.
##   molt   -> a crack meter whose RIGHT EDGE is the half-HP threshold.
## Everything here is derived from the live board every frame; nothing is stored and nothing is
## latched, so a client rebuilding its screen from an absolute snapshot draws exactly what the host
## drew, with no fx event and no wire field.
func _refresh_devices(i: int, e: Dictionary) -> void:
	var slab: ColorRect = en_aura[i]
	var dev: Label = en_device[i]
	var mbg: ColorRect = en_meter_bg[i]
	var mfg: ColorRect = en_meter_fg[i]
	slab.visible = false
	dev.visible = false
	mbg.visible = false
	mfg.visible = false
	if not e.get("alive", false):
		return

	var bits: Array = []
	# --- aegis: the slab, and the chip that says what it is worth ---------------------------------
	# The chip prints incoming_reduction, i.e. what this body ACTUALLY soaks — aegis, the Overseer's
	# regalia and the Molt-King's carapace MAXed into one number. Printing the aura amount instead
	# would tell a shelled Molt-King under a Shellback that it soaks 6, and it soaks 3.
	var soak: int = Syn.incoming_reduction(enemies, e)
	var aegis_src: Dictionary = Syn.aura_source(enemies, Syn.AEGIS)
	var chorus_src: Dictionary = Syn.aura_source(enemies, Syn.CHORUS)
	var is_aegis_src: bool = _is_body(aegis_src, e)
	var is_chorus_src: bool = _is_body(chorus_src, e)
	if is_aegis_src or is_chorus_src:
		# A SOURCE wears its own colour solid — this is the body to kill, and it should read as the
		# thing causing the wash on its neighbours rather than as one more body wearing it.
		slab.color = _source_tint(e)
		slab.color.a = 0.22
		slab.visible = true
		if is_aegis_src:
			bits.append("🪨 aegis -%d" % Syn.aura_amount(enemies, Syn.AEGIS, {}))
		if is_chorus_src:
			bits.append("🎶 +%d all" % Syn.aura_amount(enemies, Syn.CHORUS, {}))
	elif soak > 0:
		# A PROTECTED body wears its protector's colour faintly. If the soak is its own (a carapace),
		# there is no source to point at, so it falls back to the neutral tint.
		slab.color = _source_tint(aegis_src) if not aegis_src.is_empty() else AURA_FALLBACK_TINT
		slab.color.a = 0.11
		slab.visible = true
	if soak > 0 and not is_aegis_src:
		bits.append("🪨-%d" % soak)

	# --- gorge: one pip per corpse, capped where the bonus caps -----------------------------------
	# Pips rather than a bar because what it counts is DISCRETE and small (each pip is a body you
	# killed), and because the cap has to be legible: four pips full = the +12 ceiling, and the fifth
	# corpse changing nothing is then something the player can see rather than discover.
	# The pip count is DERIVED from the bonus rather than counted off the corpses, so a change to
	# GORGE_PER_CORPSE or GORGE_CAP moves the pips with it — a readout that has to be kept in step by
	# hand is a readout that will eventually lie. floori() over `/` because integer division is a
	# warning here and the intent is explicitly "how many whole pips does this bonus buy".
	if str(e.get("archetype", "")) == Syn.ID_MAW:
		var per: float = float(Syn.GORGE_PER_CORPSE)
		var pips: int = mini(floori(float(Syn.GORGE_CAP) / per), floori(float(Syn.gorge_bonus(enemies, e)) / per))
		bits.append("🩸".repeat(pips) if pips > 0 else "🩸x0")

	# --- molt: the crack meter --------------------------------------------------------------------
	if not (e.get("moves_molt", []) as Array).is_empty():
		var cracked: bool = Syn.molted(e)
		# Fills with damage TAKEN and reaches the right edge exactly at half HP, which is the crack.
		# maxf(1.0, ...) keeps a 1-HP body from dividing by zero.
		var half: float = maxf(1.0, float(int(e.get("max_hp", 0))) * 0.5)
		var frac: float = clampf(float(int(e.get("max_hp", 0)) - int(e.get("hp", 0))) / half, 0.0, 1.0)
		mbg.visible = true
		mfg.visible = true
		# The track's OWN width, not METER_W: the meter is squeezed with everything else on a six-body
		# board (see _slot_font_scale), and a fill computed off the unsqueezed constant would overrun
		# its track — the one place on this widget where "full" has to mean exactly the right edge.
		mfg.size = Vector2(round(mbg.size.x * frac), METER_H)
		mfg.color = Color(1.0, 0.72, 0.25, 0.95) if cracked else Color(0.95, 0.45, 0.35, 0.90)
		bits.append("🦂 CRACKED" if cracked else "🦂 shell")

	dev.text = " ".join(bits)
	dev.visible = dev.text != ""

func _refresh_party() -> void:
	var arm: Dictionary = _armed_def()
	var ally_arm: bool = selected_uid != "" and arm.get("target", "") in ["ally", "ally_or_enemy"]
	# ONE pass over the enemy board for the whole crew, not one per dwarf: the forecast is inherently
	# a fold across every enemy's intent, and computing it per-portrait would run _enemy_move and
	# Syn.effective_dmg N x M times on the render path.
	var fc: Array = _incoming_forecast()
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
			# 💫 Stun, PARTY SIDE. Nothing in the shipped content stuns a dwarf — this is the badge for
			# the day something does, written now because the enemy side got one in the same pass and a
			# status whose glyph exists on only one side of the board is exactly how a second, different
			# glyph gets invented for the other side. Costs one guarded line and closes that door.
			if int(a.get("stun", 0)) > 0:
				st += "💫%d " % int(a["stun"])
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
			if int(a.get("communion", 0)) > 0:
				st += "📿%d " % a["communion"]
			if bool(a.get("raging", false)):
				st += "😤 "
			if bool(a.get("performing", false)):
				st += "🎶%d/%d " % [(a.get("targets_turn", []) as Array).size(), Powers.PERFORM_TARGETS]
			if str(a.get("form", "")) != "":
				st += "%s%d " % [Db._form_emoji(str(a["form"])).left(2).strip_edges(), int(a.get("shift_turns", 0))]
			# 🧿 (was 🌀): Metamagic's glyph moved in the 2026-07-22 collision pass so 🌀 means Channel
			# and only Channel — both badges can be lit on the same Sorcerer at the same time, which is
			# what made this the collision worth paying for.
			if str(a.get("meta_pick", "")) != "":
				st += "🧿%s " % str(a["meta_pick"]).left(1).to_upper()
			if str(a.get("held_cid", "")) != "":
				st += "⏳ "
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
		_refresh_orb(i, a, alive)
		_refresh_forecast(i, a, alive, fc[i] if i < fc.size() else {})

## Paint one dwarf's incoming chip. Player phase only, and only when something is actually coming:
## a chip reading "🗡️0" every quiet turn is a chip the eye learns to skip, and it would then be
## skipped on the turn it says 💀. Mid enemy-phase it is hidden outright — the beats resolve one at a
## time there, so a summed total would keep counting swings that have already landed.
func _refresh_forecast(i: int, a: Dictionary, alive: bool, f: Dictionary) -> void:
	var lbl: Label = pc_forecast[i]
	var gross: int = int(f.get("gross", 0))
	if not alive or phase != "playerTurn" or gross <= 0:
		lbl.visible = false
		return
	var net: int = int(f.get("net", 0))
	if net <= 0:
		# Covered. The number stays the GROSS swing, so "how much Guard is this costing me" is
		# readable — a chip that printed 0 would make a 30-damage turn look like a quiet one.
		lbl.text = "🛡️%d" % gross
		lbl.add_theme_color_override("font_color", Color(0.62, 0.85, 1.0))
	elif net >= int(a.get("hp", 0)):
		# The only state that drops the number: at this point the magnitude is irrelevant and the
		# glyph is the whole message. This is the readout the 95%-of-a-planner's-edge heal is aimed by.
		lbl.text = "💀"
		lbl.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	else:
		lbl.text = "🗡️%d" % gross
		lbl.add_theme_color_override("font_color", Color(1.0, 0.72, 0.45))
	lbl.visible = true

## THE INCOMING FORECAST — per dwarf, for the enemy phase that is currently telegraphed. Returns an
## array parallel to party[] of {"gross": int, "net": int}.
##
## WHY THIS IS THE HIGHEST-VALUE READOUT ON THE SCREEN, and it is measured rather than felt:
## scripts/test/skill_gap.gd decomposed a planner bot's advantage over a greedy one and found BLOCKING
## TO THE TELEGRAPH worth 33% and AIMING HEALS worth 95%. Both of those decisions ARE this number.
## Until now the player had to fold it by hand off up to six separate intent labels every single turn
## — and the labels cannot even carry it, because the multipliers that matter live on the VICTIM
## (Vulnerable is on the dwarf, not on the swing) and Guard drains across the whole phase.
##
## WHAT THE TWO NUMBERS MEAN:
##   gross — everything that will SWING at this dwarf, after every modifier that scales the swing
##           (Syn's chorus / rage / gorge / molt-fury / doubled Shriek through _move_dmg, this dwarf's
##           own Vulnerable x1.5, the Barbarian's resistance) and BEFORE anything that absorbs it.
##   net   — what actually reaches HP, i.e. gross put through wards and Guard exactly the way
##           _enemy_attack puts it: xVuln -> resistance -> ward -> Guard -> hp.
## The chip prints gross and lets net choose the glyph, so the NUMBER never changes meaning between
## states — the same one-slot-one-meaning discipline the intent grammar is built on. A chip that
## printed gross when covered and net when not would be the × overload again, on the most important
## label on the board.
##
## IT MUST AGREE WITH WHAT LANDS, so every number here comes from the resolver's own functions:
## _enemy_move (the latched beat, substitutions included), _move_dmg (Syn.effective_dmg — THE one
## number), _enemy_target (the same targeting the arrows draw) and Powers.incoming_scale. There is no
## parallel arithmetic anywhere in this function, on purpose: a forecast with its own copy of the
## damage rules is a forecast that will eventually disagree with the hit, and then it is worse than
## nothing because the player has stopped checking.
##
## WHAT IT DELIBERATELY DOES NOT MODEL, each because modelling it would cost more truth than it buys:
##  * RETARGETING MID-PHASE. Targets are read once off the CURRENT board. If a Cave Bat kills the
##    Sorcerer, the next bat reroutes and this was high. Simulating that would make the chip disagree
##    with the threat arrows drawn directly above it — and a forecast that contradicts the arrows
##    teaches the player to trust neither. The arrows already have this property; the chip inherits it.
##  * RETALIATE killing an attacker mid-flurry. Always in the player's favour, and not knowable
##    without resolving the phase.
##  * A STUNNED body is excluded outright. It loses its action (see _enemy_phase), so counting its
##    telegraph would be the one case where the chip promises damage that cannot land.
##
## WHAT IT DOES MODEL, and why the line is drawn here: the two INTRA-PHASE DEBUFFS, Expose and Howl.
## Unlike retargeting, they cost nothing in truth — every beat in the phase is already latched, the
## enemies resolve in slot order, so an Expose or a Howl landing at slot 0 is fully knowable from the
## telegraphs the player is looking at. And unlike everything in the list above, omitting them made
## the chip UNDERSTATE a lethal turn (Expose then two hits at x1.5 killed a Cleric the chip said would
## end at 6 HP), which is the exact opposite of what this readout exists for. Note the per-BODY intent
## labels are still pre-phase — they describe one body in isolation and have no phase order to walk —
## so a chip that reads higher than the sum of the labels above it is correct, not a bug.
func _incoming_forecast() -> Array:
	var out: Array = []
	for _a: Dictionary in party:
		out.append({"gross": 0, "net": 0})
	if party.is_empty() or enemies.is_empty():
		return out
	# Guard is a POOL that drains across the whole phase, so it is simulated per dwarf in the order
	# the enemies act (slot order — the same order _enemy_phase loops). Wards (`shield`) are NOT
	# drained: they soak every hit, forever, which is exactly what makes a ward worth more than Guard.
	var pool: Array = []
	for a: Dictionary in party:
		pool.append(int(a.get("block", 0)))
	# The two simulation carriers. `vuln` starts from the board (Vulnerable only decays at PLAYER-phase
	# start, so whatever is on a dwarf now is live for this whole enemy phase); `rage_add` is empty
	# because nothing has howled yet this phase.
	var vuln: Array = []
	for a: Dictionary in party:
		vuln.append(int(a.get("vulnerable", 0)) > 0)
	var rage_add: Dictionary = {}   # enemy slot -> rage a Howl banks EARLIER in this same phase
	for e: Dictionary in enemies:
		if not e.get("alive", false) or int(e.get("stun", 0)) > 0:
			continue
		var mv: Dictionary = _enemy_move(e)
		var kind: String = str(mv.get("kind", ""))
		# Expose lands before every body after it in slot order, and _enemy_attack reads
		# t["vulnerable"] live, so from here on that dwarf takes x1.5 for the rest of the phase.
		if kind == "expose":
			var xt: Dictionary = _enemy_target(e)
			var xi: int = int(xt.get("slot", -1)) if not xt.is_empty() else -1
			if xi >= 0 and xi < vuln.size():
				vuln[xi] = true
			continue
		# Howl is permanent +atk on EVERY living body, so a Howl at slot 1 is already in the numbers
		# slots 2+ swing for. Clamped exactly the way _do_enemy_move clamps it — rage plateaus at
		# RAGE_CAP, so two Howls in one phase must plateau here too or the chip over-promises.
		if kind == "rage_all":
			for o: Dictionary in enemies:
				if not o.get("alive", false):
					continue
				var oi: int = int(o.get("slot", -1))
				var headroom: int = maxi(0, RAGE_CAP - int(o.get("rage", 0)))
				rage_add[oi] = mini(int(rage_add.get(oi, 0)) + int(mv.get("amt", 0)), headroom)
			continue
		if not kind in Syn.DMG_KINDS:
			continue
		# Syn.effective_dmg adds e["rage"] as a flat term AFTER the Shriek doubling, so banked rage is
		# a flat adder on top of the resolved per-hit number — the same order the resolver produces it.
		var per: int = _move_dmg(e, mv) + int(rage_add.get(int(e.get("slot", -1)), 0))
		var hits: int = int(mv.get("hits", 1)) if kind == "multi" else 1
		var victims: Array = []
		if kind == "attack_all":
			for a2: Dictionary in party:
				if a2.get("alive", false):
					victims.append(a2)
		else:
			var t: Dictionary = _enemy_target(e)
			if not t.is_empty():
				victims.append(t)
		for v: Dictionary in victims:
			var idx: int = int(v.get("slot", -1))
			if idx < 0 or idx >= out.size():
				continue
			for _h: int in range(hits):
				# This chain is _enemy_attack's, step for step. If that function ever changes, this
				# one has to change with it — which is why they are this close together in shape.
				var raw: int = per
				# The SIMULATED flag, not v["vulnerable"] — an Expose earlier in this phase is already
				# folded into it, and the board's copy will not carry it until the phase resolves.
				if bool(vuln[idx]):
					raw = int(round(raw * VULN_MULT))
				raw = Powers.incoming_scale(v, raw)
				var after_ward: int = maxi(0, raw - int(v.get("shield", 0)))
				var blocked: int = mini(int(pool[idx]), after_ward)
				pool[idx] = int(pool[idx]) - blocked
				out[idx]["gross"] = int(out[idx]["gross"]) + raw
				out[idx]["net"] = int(out[idx]["net"]) + (after_ward - blocked)
	return out

## The Class Power coin. combat derives one plain state dict from the SAME predicate the host
## re-validates the tap with (Powers.can_fire) and hands it to the widget, which owns every visual —
## flip on cooldown, fill arc on charge, orbiting motes on a held stance. What you see and what the
## host allows physically cannot drift apart, because both read can_fire.
func _refresh_orb(i: int, a: Dictionary, alive: bool) -> void:
	var orb: PowerOrb = pc_power[i]
	var p: Dictionary = Powers.power_def(a)
	if p.is_empty() or not alive:
		orb.visible = false
		pc_power_lbl[i].text = ""
		return
	orb.visible = true
	orb.configure(str(a.get("role", "tank")), str(p["emoji"]))
	var mine: int = my_seat if mode != Mode.SOLO else active_idx
	var lit: bool = i == mine and phase == "playerTurn" and Powers.can_fire(self, a)
	var power: String = str(a.get("power", ""))
	var stance := ""
	var form := ""
	if power == "enrage" and bool(a.get("raging", false)):
		stance = "rage"
	elif power == "bardic_performance" and bool(a.get("performing", false)):
		stance = "perform"
	elif power == "wild_shape" and int(a.get("shift_turns", 0)) > 0:
		stance = "shape"
		form = str(a.get("form", ""))
	var st := {"emoji": str(p["emoji"]), "lit": lit}
	if bool(p.get("passive", false)):
		st["kind"] = "passive"
		st["pips"] = int(a.get("casts", 0)) % Powers.CHANNEL_EVERY
		st["pips_max"] = Powers.CHANNEL_EVERY
	elif stance != "":
		st["kind"] = "stance"
		st["stance"] = stance
		st["form"] = form
	elif int(a.get("power_cd", 0)) > 0:
		st["kind"] = "cooldown"
		st["cd"] = int(a["power_cd"])
		st["cd_max"] = Powers.cd_max_of(power)
	elif int(p.get("charge", 0)) > 0 and int(a.get("meta_charge", 0)) < int(p["charge"]):
		st["kind"] = "charge"
		st["fill"] = int(a.get("meta_charge", 0))
		st["fill_max"] = int(p["charge"])
	elif int(p.get("communion", 0)) > 0 and int(a.get("communion", 0)) < int(p["communion"]):
		st["kind"] = "communion"
		st["fill"] = int(a.get("communion", 0))
		st["fill_max"] = int(p["communion"])
	elif lit:
		st["kind"] = "ready"
	else:
		st["kind"] = "locked"
	orb.set_state(st)
	pc_power_lbl[i].text = _orb_label(a, p, lit, stance)

## The short readout under the coin — one line, the fewest characters that still say which thing.
func _orb_label(a: Dictionary, p: Dictionary, lit: bool, stance: String) -> String:
	if bool(p.get("passive", false)):
		return "%d/%d" % [int(a.get("casts", 0)) % Powers.CHANNEL_EVERY, Powers.CHANNEL_EVERY]
	match stance:
		"rage": return "RAGING"
		"perform": return "SONG"
		"shape": return "%s %d" % [str(a.get("form", "")).to_upper(), int(a.get("shift_turns", 0))]
	if lit:
		return "READY"
	return _orb_gate(a, p)

## What the orb's gate is waiting on, in the fewest characters that still say which thing.
func _orb_gate(a: Dictionary, p: Dictionary) -> String:
	if int(a.get("power_cd", 0)) > 0:
		return "⏳%d" % int(a["power_cd"])
	if int(p.get("charge", 0)) > 0:
		return "🧿%d/%d" % [int(a.get("meta_charge", 0)), int(p["charge"])]
	if int(p.get("communion", 0)) > 0 and int(a.get("communion", 0)) < int(p["communion"]):
		return "📿%d/%d" % [int(a.get("communion", 0)), int(p["communion"])]
	return ""

# ---------------------------------------------------------------- Class Power tooltip
func _open_power_tip(i: int) -> void:
	power_tip_open = i
	_refresh_power_tip()

func _close_power_tip(i: int) -> void:
	if power_tip_open == i:
		power_tip_open = -1
		power_tip.visible = false

## The hover explainer: the coin's name, its LIVE status, and what it does. Refreshed every frame it
## is open so the countdown / charge ticks in place while you read it.
func _refresh_power_tip() -> void:
	if power_tip_open < 0:
		return
	var a: Dictionary = party[power_tip_open]
	var p: Dictionary = Powers.power_def(a)
	# The notes join the overlay and the pick as things that force this closed: all three are modals
	# above the tip's z_index, so a tip left open under one is a tip nobody can see or dismiss.
	if p.is_empty() or not a.get("alive", false) or overlay.visible or choice_box.visible or _feedback_up():
		power_tip_open = -1
		power_tip.visible = false
		return
	pt_title.text = "%s %s" % [str(p["emoji"]), str(p["name"])]
	pt_gate.text = _tip_status(a, p)
	pt_body.text = str(p.get("tip", ""))
	var cx: float = pc_pos[power_tip_open].x + 60.0
	power_tip.position = Vector2(clampf(cx - 180.0, 8.0, 720.0 - 8.0 - 360.0), 520.0)
	power_tip.visible = true

## The coin's live status in one short gold line — what it is doing RIGHT NOW, not the rules.
func _tip_status(a: Dictionary, p: Dictionary) -> String:
	var power: String = str(a.get("power", ""))
	if bool(p.get("passive", false)):
		return "streak ×%d · %d/%d to discharge" % [int(a.get("streak", 0)), int(a.get("casts", 0)) % Powers.CHANNEL_EVERY, Powers.CHANNEL_EVERY]
	if power == "enrage" and bool(a.get("raging", false)):
		return "RAGING — attack this turn to hold it"
	if power == "bardic_performance" and bool(a.get("performing", false)):
		return "song playing — reach 3 targets this turn"
	if power == "wild_shape" and int(a.get("shift_turns", 0)) > 0:
		return "%s form · %d turns left" % [str(a.get("form", "")).capitalize(), int(a.get("shift_turns", 0))]
	if int(a.get("power_cd", 0)) > 0:
		return "recovers in %d turns" % int(a["power_cd"])
	if int(p.get("charge", 0)) > 0 and int(a.get("meta_charge", 0)) < int(p["charge"]):
		return "charging 🧿 %d / %d" % [int(a.get("meta_charge", 0)), int(p["charge"])]
	if int(p.get("communion", 0)) > 0 and int(a.get("communion", 0)) < int(p["communion"]):
		return "needs 📿 %d / %d" % [int(a.get("communion", 0)), int(p["communion"])]
	return "READY"

# ---------------------------------------------------------------- Intent telegraph
## Compact always-on readout of the latched move, with LIVE numbers (rage + target Vulnerable).
##
## ALL THREE TELEGRAPHS ARE NOW RENDERED FROM Db.MOVE_KINDS — one row per kind carrying the verb
## glyph, the colour and the three format strings. The per-move "emoji" key it replaced was authored
## on every single move, which meant a new kind was a glyph copied 30 times and a wording change was
## 30 edits; worse, the label/headline/brief were three separate `match` ladders that could (and did)
## drift apart. One substitution dict now feeds all three, so a number cannot differ between them.
func _intent_text(e: Dictionary) -> String:
	# 💫 A stunned body has no intent — it loses this action outright (see _enemy_phase) and its
	# rotation does NOT advance, so the beat it was telegraphing is still the beat it owes. Printing
	# that beat anyway would be the one telegraph in the game that promises damage which cannot land,
	# and it is the readout the player just spent a card to buy. The three-slot grammar does not apply
	# here on purpose: this is the ABSENCE of a move, not a move with an empty target.
	if int(e.get("stun", 0)) > 0:
		return "💫 stunned"
	return _fmt_move(e, _enemy_move(e), "label_fmt")

## Substitutions for a move's format strings. Every key any of the three formats can name is filled,
## every time — cheap, and it means a new format string in card_db needs no code here at all.
##   {hit} is the number that will LAND on the named target (Vulnerable folded in);
##   {dmg} is the per-hit number before the target's own multipliers — the AoE/brief form.
func _move_fmt(e: Dictionary, mv: Dictionary) -> Dictionary:
	var t: Dictionary = _enemy_target(e)
	var kd: Dictionary = Db.MOVE_KINDS.get(str(mv.get("kind", "")), {})
	return {
		"verb": str(kd.get("verb", "?")),
		"name": str(mv.get("name", "")),
		"dmg": _move_dmg(e, mv),
		"hit": _intent_hit(e, mv),
		"hits": int(mv.get("hits", 1)),
		"amt": int(mv.get("amt", 0)),
		"ally": int(mv.get("ally_amt", 0)),
		"gain": _rage_gain(e, mv) if str(mv.get("kind", "")) == "rage_all" else 0,
		"tgt": str(t["name"]).substr(0, 3) if not t.is_empty() else "",
		"target": str(t["name"]) if not t.is_empty() else "?",
	}

## Render one of a kind's three formats. The `*_fmt_zero` variants exist so a capped Howl can say
## "max" instead of "+0" — keyed off {gain} and off the kind ACTUALLY carrying a zero variant, so no
## other kind can accidentally fall into it. An unknown kind degrades to the move's name rather than
## rendering an empty label: a body whose telegraph is blank is worse than one that is merely terse.
func _fmt_move(e: Dictionary, mv: Dictionary, key: String) -> String:
	var kd: Dictionary = Db.MOVE_KINDS.get(str(mv.get("kind", "")), {})
	var f: Dictionary = _move_fmt(e, mv)
	var fmt: String = str(kd.get(key, ""))
	if kd.has(key + "_zero") and int(f["gain"]) <= 0:
		fmt = str(kd[key + "_zero"])
	if fmt == "":
		return str(mv.get("name", ""))
	return fmt.format(f)

func _intent_hit(e: Dictionary, mv: Dictionary) -> int:
	var dmg: int = _move_dmg(e, mv)
	var t: Dictionary = _enemy_target(e)
	if not t.is_empty() and int(t.get("vulnerable", 0)) > 0:
		dmg = int(round(dmg * VULN_MULT))
	return dmg

func _intent_color(kind: String) -> Color:
	var c: Variant = (Db.MOVE_KINDS.get(kind, {}) as Dictionary).get("color", Color.WHITE)
	return c if c is Color else Color.WHITE

func _open_intent(i: int) -> void:
	if not enemies[i].get("alive", false) or overlay.visible or _feedback_up():
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
	if not e["alive"] or overlay.visible or _feedback_up():
		intent_open = -1
		intent_panel.visible = false
		return
	var mv: Dictionary = _enemy_move(e)
	var mvs: Array = _rotation(e)   # the CURRENT rotation — a cracked Molt-King telegraphs its new beats
	ip_title.text = "%s %s — %s" % [e["emoji"], e["name"], _intent_headline(e, mv)]
	ip_body.text = str(mv.get("tip", ""))
	if mvs.size() > 1:
		# Through _next_move, NOT `mvs[move_i + 1]` — see _next_move. The rotation is only the input to
		# the answer; alone_gate and howl_every_beat sit above it and are permanent once true.
		var nm: Dictionary = _next_move(e)
		ip_next.text = "Next: %s %s" % [nm["name"], _intent_brief(e, nm)]
	else:
		ip_next.text = ""
	# Reach is identity now that Taunt only catches melee, so the panel states it for EVERY enemy —
	# a player has to be able to learn which bodies a Taunt can pull BEFORE spending the energy, not
	# after eating the hit. It goes at the FRONT of the line on purpose: ip_pref is a single 460px
	# row and several of the newer tips already run past it, so anything appended would be the part
	# that clips. (Widening the panel is a layout call and another session owns the layout pass.)
	# The BADGE SENTENCE leads, and the archetype's prose tip follows. The badge is on the nameplate
	# every single turn, so this row is the only place it is ever spelled out — a glyph whose meaning
	# is never stated is a glyph the player guesses at, and the three prefs are precisely the rules
	# worth planning around. It comes from the SAME Db.PREF_BADGES row the badge does, so the glyph on
	# the board and the sentence in the panel cannot drift; when a Taunt has actually taken, both flip
	# to the 😡 line together and the panel says the rule was overridden rather than silently dropping
	# it. The archetype tip is appended (not replaced) because it carries the flavour and the
	# body-specific advice the closed badge set deliberately cannot.
	var reach: String = "🏹 Ranged — Taunt can't pull it. " if _enemy_range(e) >= 2 else "⚔️ Melee — Taunt pulls it. "
	ip_pref.text = "%s%s %s  %s" % [reach, _pref_badge(e), _pref_tip(e), str(Db.ENEMIES[e["archetype"]].get("tip", ""))]
	ip_dev.text = _device_line(e)
	intent_panel.position = Vector2(clampf(en_pos[intent_open].x - 240.0, 8.0, 720.0 - 8.0 - 480.0), 40.0)
	intent_panel.visible = true

## The synergy sentence for ONE body: what the rest of the board is doing to it, or through it — and,
## for the alone gate, what it WILL do under a condition that has not happened yet.
##
## Ordered by what changes a decision soonest, and joined with " · " into a single 460px row on
## purpose: the panel is a hover popup over the enemy row and every extra line it grows covers the
## intent labels the player opened it to compare. Anything past the row's width is therefore the
## LEAST decision-relevant clause, by construction rather than by luck.
func _device_line(e: Dictionary) -> String:
	var bits: Array = []
	# 1. What it takes per hit — this is the number that decides whether to swing at it at all.
	var soak: int = Syn.incoming_reduction(enemies, e)
	if soak > 0:
		var src: Dictionary = Syn.aura_source(enemies, Syn.AEGIS)
		var by: String = " (%s %s)" % [str(src.get("emoji", "")), str(src.get("name", ""))] if not src.is_empty() else ""
		bits.append("🪨 takes %d less per hit%s" % [soak, by])
	# 2. What it GIVES the others. A source is worth killing for a reason no health bar shows.
	var chorus: int = Syn.aura_amount(enemies, Syn.CHORUS, {})
	var chorus_src: Dictionary = Syn.aura_source(enemies, Syn.CHORUS)
	if _is_body(chorus_src, e) and chorus > 0:
		bits.append("🎶 every OTHER enemy hits for +%d — kill it and that is gone" % chorus)
	elif chorus > 0 and str(_enemy_move(e).get("kind", "")) in Syn.DMG_KINDS:
		# Recipients get the WHY, never the arithmetic: the label already prints the buffed total.
		bits.append("🎶 its number above already includes %s %s's chorus" % [
			str(chorus_src.get("emoji", "")), str(chorus_src.get("name", ""))])
	var aegis_src: Dictionary = Syn.aura_source(enemies, Syn.AEGIS)
	if _is_body(aegis_src, e):
		bits.append("🪨 every OTHER enemy takes %d less per hit" % Syn.aura_amount(enemies, Syn.AEGIS, {}))
	# 3. The named devices, each phrased as the consequence rather than the mechanic.
	var gorge: int = Syn.gorge_bonus(enemies, e)
	if gorge > 0:
		bits.append("🩸 +%d from the corpses on the board" % gorge)
	if not (e.get("moves_molt", []) as Array).is_empty():
		if Syn.molted(e):
			bits.append("🦂 shell OFF — no soak, +%d damage, new beats" % Syn.MOLT_FURY)
		else:
			bits.append("🦂 the shell comes off at half HP")
	var reg: Dictionary = Syn.regalia(enemies)
	if str(e.get("archetype", "")) == Syn.ID_OVERSEER and int(reg["crystals"]) > 0:
		bits.append("💎 %d standing: Gaze hits for %d" % [int(reg["crystals"]), _move_base(e, {"gaze": true})])
	var bond: Dictionary = Syn.twin_bond(enemies, e)
	if bool(bond.get("shriek_x2", false)):
		bits.append("🐺 it mourns the pack — its Shriek hits TWICE as hard")
	if bool(bond.get("howl_every_beat", false)):
		bits.append("🧿 it lost its witch — it howls every beat")
	# 4. THE UNFAIR-NUMBER GUARD: the cornered Caster, previewed before it is true. Computed by asking
	# Syn the same question against a board of one — no second copy of "which beat is its heaviest".
	var solo: Dictionary = Syn.alone_gate([e], e)
	if not solo.is_empty() and Syn.alone_gate(enemies, e).is_empty():
		bits.append("if it is the LAST one standing, every beat becomes %s %d" % [
			str((Db.MOVE_KINDS.get(str(solo.get("kind", "")), {}) as Dictionary).get("verb", "?")),
			_move_dmg(e, solo)])
	return " · ".join(bits)

## Same-body test over the WIRE ADDRESS (archetype + slot), never `==`: Dictionary equality in Godot 4
## compares contents, so two identical Cave Bats would read as the same body and the aura source would
## appear to shield itself.
func _is_body(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	return str(a.get("archetype", "")) == str(b.get("archetype", "?")) and int(a.get("slot", -1)) == int(b.get("slot", -2))

func _intent_headline(e: Dictionary, mv: Dictionary) -> String:
	return _fmt_move(e, mv, "headline_fmt")

func _intent_brief(e: Dictionary, mv: Dictionary) -> String:
	return _fmt_move(e, mv, "brief_fmt")

func _refresh_threats() -> void:
	var pairs: Array = []
	if phase == "playerTurn":
		for e: Dictionary in enemies:
			if not e["alive"]:
				continue
			# 💫 A stunned body threatens nobody: it loses this action, so an arrow from it would draw a
			# swing that cannot happen. Same reason its label says "stunned" and the forecast skips it —
			# three readouts, one fact, and they have to agree or the stun stops being worth buying.
			if int(e.get("stun", 0)) > 0:
				continue
			# Only target-directed intents draw an arrow; block/buff/AoE turns threaten nobody in particular.
			if not _enemy_move(e)["kind"] in ["attack", "multi", "expose"]:
				continue
			var t: Dictionary = _enemy_target(e)
			if t.is_empty():
				continue
			pairs.append({
				"from": en_pos[e["slot"]] + Vector2(0, 42),
				"to": pc_pos[t["slot"]] + Vector2(0, -42),
			})
	threat.set_threats(pairs)

func _refresh_panel() -> void:
	if phase == "playerTurn":
		var a: Dictionary = party[active_idx]
		var aura: String = "   📣+%d atk" % party_attack_buff if party_attack_buff > 0 else ""
		active_label.text = "%s  %s   ⚡%d/%d%s" % [a["emoji"], a["name"], a["energy"], a["max_energy"], aura]
		# The two states that CHANGE what a tap means get the hint line to themselves — a player
		# holding a reticle or owing a tithe needs to be told, not left to discover it.
		var me: Dictionary = party[my_seat] if mode != Mode.SOLO else a
		if int(me.get("tithe_owed", 0)) > 0:
			hint_label.text = "🐾 Hand %d card(s) back to your deck — tap them" % int(me["tithe_owed"])
		elif power_armed:
			hint_label.text = "%s — tap an enemy to aim it" % str(Powers.power_def(me).get("name", "Power"))
		elif mode == Mode.SOLO:
			hint_label.text = "Tap a dwarf to switch • tap a card to play • tap the orb for its power"
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
		# Read the cost through _pool_of/cost_of, never raw: it can be the string "X", and comparing a
		# String to an int is a runtime error. Reforge also moves which pool pays, and Quicken moves
		# the price — so "can I afford this?" is never just the printed number.
		var cooldown: bool = str(def.get("limiter", "")) == "no_repeat" and turn - taunt_last_turn < 2
		var playable: bool = _affordable(a, def) and not cooldown
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
	# An armed POWER aims with the same reticle as an armed card — it is the same gesture.
	var targeting: bool = phase == "playerTurn" and ((selected_uid != "" and needs_target) or power_armed)
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
## The two primitives below are the WHOLE of combat's visual vocabulary, which is exactly why the
## fx rider taps them here instead of at their ~11 call sites: a new card, class or enemy move gets
## co-op replay for free, and cannot be written in a way that forgets to network itself.
## Recording happens before the null-node guard on purpose — the event is the host's INTENT, not a
## report that the host's own render succeeded.
func _flash(c: Dictionary) -> void:
	_fx_push("f", c, 0)
	_fx_mark("f")
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

## mag is deliberately NOT derivable from the snapshot: on an enemy it is the pre-block damage
## (a fully-blocked hit still sparks), on a dwarf it is the post-mitigation hp lost, and a flurry
## folds several mags into one hp delta. It has to ride the event.
func _impact(c: Dictionary, mag: int) -> void:
	if mag > 0:
		_fx_push("i", c, mag)   # a 0-mag impact draws nothing; don't spend wire on it
		_fx_mark("i")
	var n: Label = c.get("node")
	if n == null or mag <= 0:
		return
	var fx: Node2D = MOMENTUM_HIT.instantiate()
	add_child(fx)
	fx.position = n.global_position + n.size * 0.5
	fx.set_momentum(clampi(int(round(mag / 2.0)), 1, 10))
	fx.burst()
	get_tree().create_timer(1.2).timeout.connect(fx.queue_free)

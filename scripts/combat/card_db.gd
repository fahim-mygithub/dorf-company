extends RefCounted
## (preloaded by combat.gd as Db; no class_name to avoid global-class collision)
##
## DATA-ONLY tables for "Demon Lord MBA" — Slice 2 party puzzle.
## Three roles (Warrior tank / Cleric support / Sorcerer dps), clean player->enemy
## phases, 3 archetype enemies with PREFERRED TARGETING + Taunt redirect, synergy
## cards, and Mark as the single +25% multiplier.
##
## combat.gd::_resolve is the ONLY place ops execute. Card `effect` = list of [op, ...args]:
##   ["damage", v]                                deal v to the target enemy (an attack)
##   ["block", v]                                 active char gains v block (+5 if Fortify pending)
##   ["self_damage", v]                           active char loses v hp
##   ["draw", n]                                  active char draws n
##   ["damage_scaling","attacks_this_turn",b,per] deal b + per*attacksPlayedThisTurn (an attack)
##   ["heal_or_damage", v]                        tap ally -> heal v; tap enemy -> deal v
##   ["apply_status","marked"]                    target enemy takes +25% from all sources this turn
##   ["force_target_all","warrior"]              all enemies target the Warrior next enemy turn
##   ["temp","retaliate", v]                      active char reflects v when hit (through enemy phase)
##   ["temp","fortify"]                           active char: next Guard +5 block, Retaliate +2
##   ["temp","channel", per, charges]            next `charges` attack cards deal +per each
##   ["shield_ally", v]                           target ally: -v damage per hit (flat, through enemy phase)
##   ["party_buff","attack", v]                   all allies' attacks deal +v this turn
##
## `target`: "self" | "enemy" | "all_enemies" | "ally" | "ally_or_enemy"
## `type`: "attack" | "skill" | "power"  (frame tint)
## `is_attack`: true -> gets Channel/Aura bonuses, counts for Finisher, consumes a Channel charge.
##
## VESTIGIAL grid-fork fields: some cards still carry `range`/`area`/`area_affects` keys the removed grid-combat fork read. Nothing reads them now (combat.gd + overworld ignore them); left as inert data.

const CARDS := {
	# --- shared chassis ---
	"strike":  {"name":"Strike",  "cost":1, "emoji":"🗡️", "target":"enemy",       "type":"attack", "is_attack":true, "range":1,
				"effect":[["damage",6]],
				"tip":"Your bread-and-butter swing — the unit everything else is read against."},
	"guard":   {"name":"Guard",   "cost":1, "emoji":"🛡️", "target":"self",        "type":"skill", "fortifiable":true, "range":0,
				"effect":[["block",5]],
				"tip":"Raise your shield. Block soaks the next hits this turn, then it's gone."},
	"cleave":  {"name":"Cleave",  "cost":2, "emoji":"🪓", "target":"all_enemies", "type":"attack", "is_attack":true, "range":1,
				"effect":[["damage",11]],
				"tip":"A heavy swing that catches every enemy at once."},
	"wall":    {"name":"Wall",    "cost":2, "emoji":"🧱", "target":"self",        "type":"skill", "range":0,
				"effect":[["block",12]],
				"tip":"Brace hard — a wall of block to weather a big incoming turn."},
	# --- Warrior signatures ---
	"taunt":   {"name":"Taunt",   "cost":1, "emoji":"😡", "target":"self",        "type":"skill", "limiter":"no_repeat", "range":2, "area":true, "area_affects":"enemy",
				"effect":[["force_target_all","warrior"],["block",8]],
				"tip":"Force enemies within range to swing at you next turn, and gain 8 block to survive it. Can't be played two turns in a row."},
	"retaliate":{"name":"Retaliate","cost":1,"emoji":"⚡", "target":"self",        "type":"skill", "range":0,
				"effect":[["temp","retaliate",4]],
				"tip":"Punish them for taking the bait — every hit you eat this turn hits back for 4."},
	"fortify": {"name":"Fortify", "cost":1, "emoji":"🔧", "target":"self",        "type":"skill", "range":0,
				"effect":[["temp","fortify"]],
				"tip":"Reinforce — your NEXT Guard this turn grants +5 block, and Retaliate deals +2 while active."},
	# --- Cleric signatures ---
	"channel_shield":{"name":"Channel Shield","cost":1,"emoji":"🔰","target":"ally","type":"skill", "range":2,
				"effect":[["shield_ally",3]],
				"tip":"Wrap an ally in protection — every blow against them this turn is softened by 3."},
	"mend_or_smite":{"name":"Mend or Smite","cost":1,"emoji":"⚖️","target":"ally_or_enemy","type":"skill", "range":2,
				"effect":[["heal_or_damage",5]],
				"tip":"Mercy or judgment — tap an ally to heal 5, or an enemy to deal 5."},
	"aura_of_valor":{"name":"Aura of Valor","cost":2,"emoji":"📣","target":"self","type":"power", "range":2, "area":true, "area_affects":"ally",
				"effect":[["party_buff","attack",2]],
				"tip":"Inspire the company — allies within range deal +2 attack this turn. A real commitment (2 energy)."},
	# --- Sorcerer signatures ---
	"mark":    {"name":"Mark",    "cost":1, "emoji":"🎯", "target":"enemy",       "type":"skill", "range":2,
				"effect":[["apply_status","marked"]],
				"tip":"Paint the target — it takes +25% from ALL sources this turn. Your whole party benefits."},
	"channel": {"name":"Channel", "cost":1, "emoji":"🌀", "target":"self",        "type":"power", "range":0,
				"effect":[["temp","channel",3,2]],
				"tip":"Gather power — your next 2 attack cards this turn deal +3 each."},
	"arcane_finisher":{"name":"Arcane Finisher","cost":2,"emoji":"💥","target":"enemy","type":"attack","is_attack":true, "range":2,
				"effect":[["damage_scaling","attacks_this_turn",5,3]],
				"tip":"Unleash everything — deal 5 +3 per attack already played this turn. Play it LAST."},

	# ============================================================ EXPANSION (hex-crawl spec, 2026-07-01)
	# Class cards stay OUT of REWARD_POOL (role-locked); generic cards join it. New ops live in combat.gd.
	# --- Warrior (Momentum) ---
	"reckless_swing": {"name":"Reckless Swing","cost":1,"emoji":"🪓","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",14],["self_dmg",3]],
				"tip":"Deal 14. Take 3. Leans you Bloodied — pairs with cards that reward it."},
	"second_wind": {"name":"Second Wind","cost":1,"emoji":"🛡️","target":"self","type":"skill",
				"effect":[["block",6],["if_bloodied",[["block",6]]]],
				"tip":"Gain 6 Block. +6 more while Bloodied (at or below half HP)."},
	"momentum_strike": {"name":"Momentum Strike","cost":1,"emoji":"⚔️","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",6],["dmg_per_momentum",3]],
				"tip":"Deal 6, +3 per Momentum (attacks you've already played this turn). Play it late."},
	# --- Sorcerer (Surge / Wild Magic) ---
	"arc_lightning": {"name":"Arc Lightning","cost":2,"emoji":"⚡","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",9],["dmg_all",4]],
				"tip":"Deal 9 to the target, then 4 to ALL enemies."},
	"empower": {"name":"Empower","cost":0,"emoji":"✨","target":"self","type":"power",
				"effect":[["next_card_double"]],
				"tip":"Your next card's numbers are doubled. Set up a big hit."},
	"kindle": {"name":"Kindle","cost":1,"emoji":"🔥","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",5],["apply","burn",3]],
				"tip":"Deal 5, then apply 3 Burn (ticks at the start of each enemy turn, ignores block)."},
	# --- Cleric / Paladin (Devotion / Oath) — gated to the cleric role until a Paladin class lands ---
	"lay_on_hands": {"name":"Lay on Hands","cost":1,"emoji":"🙌","target":"ally","type":"skill",
				"effect":[["heal_ally",10]],
				"tip":"Heal a chosen ally 10."},
	"consecrate": {"name":"Consecrate","cost":1,"emoji":"🕯️","target":"party","type":"skill",
				"effect":[["party_block",4]],
				"tip":"All allies gain 4 Block."},
	"divine_smite": {"name":"Divine Smite","cost":2,"emoji":"🌟","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",10],["spend_devotion",[["dmg",8]]]],
				"tip":"Deal 10, +8 more if you spend 1 Devotion (built by playing skills)."},
	# --- Generic (universal chassis; these join REWARD_POOL) ---
	"power_through": {"name":"Power Through","cost":1,"emoji":"💪","target":"self","type":"skill",
				"effect":[["block",8],["draw",1]],
				"tip":"Gain 8 Block. Draw 1."},
	"precise_jab": {"name":"Precise Jab","cost":0,"emoji":"🗡️","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",4],["gain_energy",1]],
				"tip":"Deal 4, then refund 1 Energy — nearly free tempo."},
	"whetstone": {"name":"Whetstone","cost":0,"emoji":"🪨","target":"self","type":"skill",
				"effect":[["buff_next_attack",4]],
				"tip":"Your next attack this turn deals +4."},
	"guard_break": {"name":"Guard Break","cost":1,"emoji":"💥","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",7],["apply","vulnerable",1]],
				"tip":"Deal 7 and apply Vulnerable (target takes +50% for a turn). Applies AFTER this hit."},
	"field_dressing": {"name":"Field Dressing","cost":1,"emoji":"🩹","target":"self","type":"skill",
				"effect":[["heal_self",7]],
				"tip":"Heal yourself 7."},
	"bracing_stance": {"name":"Bracing Stance","cost":1,"emoji":"🧱","target":"self","type":"skill",
				"effect":[["block",10],["retain_block"]],
				"tip":"Gain 10 Block that does NOT expire on your next turn."},
	"opportunist": {"name":"Opportunist","cost":1,"emoji":"🎯","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",6],["if_target_marked",[["dmg",6]]]],
				"tip":"Deal 6, +6 more if the target is Marked."},
	"rally": {"name":"Rally","cost":1,"emoji":"📣","target":"party","type":"skill",
				"effect":[["party_block",3],["draw",1]],
				"tip":"All allies gain 3 Block. Draw 1."},
	"trophy_hunter": {"name":"Trophy Hunter","cost":2,"emoji":"🏆","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",12],["on_kill",[["gain_energy",2]]]],
				"tip":"Deal 12. If it kills the target, gain 2 Energy."},
}

## Role-skewed decks (~10-12 cards each); the strike/guard split encodes the role.
const CLASSES := {
	"warrior": {"name":"Warrior", "emoji":"🛡️", "role":"warrior", "max_hp":36, "energy":3, "move":1,
		"deck":["strike","strike","strike","strike","guard","guard","guard","guard","guard","taunt","retaliate","fortify"]},
	"cleric":  {"name":"Cleric",  "emoji":"⛑️", "role":"cleric",  "max_hp":28, "energy":3, "move":2,
		"deck":["strike","strike","strike","guard","guard","guard","guard","channel_shield","mend_or_smite","aura_of_valor"]},
	"sorcerer":{"name":"Sorcerer","emoji":"🧙", "role":"sorcerer","max_hp":22, "energy":3, "move":3,
		"deck":["strike","strike","strike","strike","strike","guard","guard","guard","mark","channel","arcane_finisher"]},
}
const PARTY_ORDER := ["warrior", "cleric", "sorcerer"]

## Enemies: each picks its highest-priority valid target and telegraphs it.
## pref: "tankiest" | "healer_dps" | "lowest_hp".
## `moves` (2026-07-01): a fixed ROTATION of telegraphed intents, started at a random offset per
## instance (duplicates desync). Move kinds (executed by combat.gd::_do_enemy_move):
##   attack {dmg} · multi {dmg,hits} · attack_all {dmg} · block {amt} (self, clears at its next
##   action) · guard_all {amt, ally_amt} · rage_all {amt} (permanent +atk, all enemies) ·
##   expose {amt} (Vulnerable 💥 on its preferred target: takes x1.5 from enemy hits, decays 1/turn).
## `atk` stays as the fallback for an entry without moves (old flat-attack behavior).
const ENEMIES := {
	"brute":    {"name":"Brute",    "emoji":"👹", "max_hp":45, "atk":9, "pref":"tankiest", "range":1, "move":1,
				"tip":"Wants a worthy fight — hits your tankiest (block, then max HP). Easy to bait with Taunt.",
				"moves": [
					{"name":"Smash", "emoji":"🗡️", "kind":"attack", "dmg":9,  "tip":"A heavy swing at its chosen target."},
					{"name":"Smash", "emoji":"🗡️", "kind":"attack", "dmg":9,  "tip":"A heavy swing at its chosen target."},
					{"name":"CRUSH", "emoji":"💢", "kind":"attack", "dmg":14, "tip":"An overhead blow — block it or eat it."},
				]},
	"assassin": {"name":"Assassin", "emoji":"🥷", "max_hp":30, "atk":6, "pref":"healer_dps", "range":1, "move":3,
				"tip":"Dives the backline — Healer first, then DPS. Skips the tank unless forced.",
				"moves": [
					{"name":"Stab",   "emoji":"🗡️", "kind":"attack", "dmg":6,          "tip":"A quick blade to the back."},
					{"name":"Expose", "emoji":"💥", "kind":"expose", "amt":2,          "tip":"Marks a weak point: the victim takes x1.5 from enemies for a turn."},
					{"name":"Flurry", "emoji":"🗡️", "kind":"multi",  "dmg":3, "hits":3, "tip":"Three fast cuts — each one triggers Retaliate."},
				]},
	"caster":   {"name":"Caster",   "emoji":"🔮", "max_hp":28, "atk":5, "pref":"lowest_hp", "range":2, "move":2,
				"tip":"Snipes the weakest — targets whoever has the lowest current HP.",
				"moves": [
					{"name":"Zap",  "emoji":"🗡️", "kind":"attack", "dmg":5,  "tip":"A crackle of hostile magic."},
					{"name":"Ward", "emoji":"🛡️", "kind":"block",  "amt":6,  "tip":"Shields itself — the ward soaks your next hits."},
					{"name":"Bolt", "emoji":"💢", "kind":"attack", "dmg":10, "tip":"A charged bolt at the weakest dwarf."},
				]},
	"wolf":     {"name":"Wolf",     "emoji":"🐺", "max_hp":22, "atk":5, "pref":"lowest_hp", "range":1, "move":3,
				"tip":"Pack hunter — worries the weakest, and its Howl whips the whole pack into a frenzy.",
				"moves": [
					{"name":"Bite", "emoji":"🗡️", "kind":"attack",   "dmg":5, "tip":"Teeth find the weakest dwarf."},
					{"name":"Howl", "emoji":"📣", "kind":"rage_all", "amt":2, "tip":"Every enemy gains +2 attack. Permanently."},
					{"name":"Bite", "emoji":"🗡️", "kind":"attack",   "dmg":5, "tip":"Teeth find the weakest dwarf."},
				]},
	"warden":   {"name":"Warden",   "emoji":"🗿", "max_hp":40, "atk":7, "pref":"tankiest", "range":1, "move":1,
				"tip":"A stone guardian — walls its allies behind it, then trades blows with your tank.",
				"moves": [
					{"name":"Bulwark", "emoji":"🛡️", "kind":"guard_all", "amt":8, "ally_amt":4, "tip":"Walls itself behind stone and shields its allies."},
					{"name":"Slam",    "emoji":"🗡️", "kind":"attack",    "dmg":7,               "tip":"A slab of stone to the face."},
					{"name":"Slam",    "emoji":"🗡️", "kind":"attack",    "dmg":7,               "tip":"A slab of stone to the face."},
				]},
	"witch":    {"name":"Witch",    "emoji":"🧿", "max_hp":26, "atk":6, "pref":"lowest_hp", "range":2, "move":2,
				"tip":"Hexes and screams — curses the weakest, and her Shriek hits every dwarf at once.",
				"moves": [
					{"name":"Shriek", "emoji":"🌀", "kind":"attack_all", "dmg":3, "tip":"A piercing scream — hits EVERY dwarf."},
					{"name":"Hex",    "emoji":"💥", "kind":"expose",     "amt":2, "tip":"A curse: the victim takes x1.5 from enemies for a turn."},
					{"name":"Blast",  "emoji":"💢", "kind":"attack",     "dmg":7, "tip":"A bolt of spite at the weakest dwarf."},
				]},
	"ogre":     {"name":"Ogre",     "emoji":"👺", "max_hp":55, "atk":10, "pref":"tankiest", "range":1, "move":1,
				"tip":"Slow and colossal — braces itself, then delivers a crushing two-beat blow. Time your blocks.",
				"moves": [
					{"name":"Brace", "emoji":"🛡️", "kind":"block",  "amt":5,  "tip":"Plants its feet and guards while it winds up."},
					{"name":"CRUSH", "emoji":"💢", "kind":"attack", "dmg":16, "tip":"The wind-up lands. Block or bleed."},
				]},
}
const ENCOUNTER := ["brute", "assassin", "caster"]

## OVERWORLD Phase 2 (overworld.gd reads this to build the combat `request`; combat.gd ignores
## it). Per danger tier: which enemies to field (max 3 — combat has 3 slots) and a scale multiplier
## on enemy hp/atk. "med" = the canonical balanced trio; "high" = a heavier frontline comp + scale.
const ENCOUNTERS_BY_TIER := {
	"med":  {"enemies": ["brute", "assassin", "caster"], "scale": 1.0},
	"high": {"enemies": ["brute", "witch", "caster"],    "scale": 1.2},
}

## Encounter variety (2026-07-01): per tier, comps rolled at fight time (overworld picks one at
## random; scale still comes from ENCOUNTERS_BY_TIER). Each comp = exactly 3 ids (hard slot rule).
## Missing tier -> overworld falls back to ENCOUNTERS_BY_TIER.enemies.
const ENCOUNTER_POOLS := {
	"med":  [["brute", "assassin", "caster"], ["wolf", "wolf", "witch"],
			["warden", "caster", "wolf"],    ["assassin", "witch", "wolf"]],
	# brute+brute+caster was an 85pp outlier (two tankiest heavies stack the one warrior); the
	# brute+warden replacement was the OPPOSITE outlier (double-tank wall, 0% at the top cell).
	# Witch spreads the pressure instead (scaling audit v2).
	"high": [["brute", "witch", "caster"],   ["ogre", "warden", "witch"],
			["brute", "witch", "assassin"], ["ogre", "wolf", "wolf"]],
}

const MARK_MULT := 1.25

# ================================================================ Display layer
static func type_tint(t: String) -> Color:
	match t:
		"attack": return Color(0.46, 0.14, 0.14)
		"power":  return Color(0.34, 0.17, 0.46)
		_:        return Color(0.13, 0.26, 0.42)

## Preview the flat-buffed value of an attack of `base` for char `ch` (Channel + Aura).
## Does NOT consume charges and does NOT apply Mark (target unknown at display time).
static func attack_preview(base: int, ch, party_buff: int) -> int:
	var amt: int = base
	if ch != null:
		var temp: Dictionary = ch.get("temp", {})
		if int(temp.get("channel_charges", 0)) > 0:
			amt += int(temp.get("channel_bonus", 0))
	amt += party_buff
	return amt

## Build the readable card body with LIVE numbers. Returns {"text","buffed"}.
## ch may be null; party_buff = active Aura; attacks_played = party-wide attacks this turn.
static func describe(def: Dictionary, ch, party_buff: int, attacks_played: int) -> Dictionary:
	var lines: Array = []
	var buffed: bool = false
	var temp: Dictionary = {} if ch == null else ch.get("temp", {})
	var fg: bool = bool(temp.get("fortify_guard", false))   # next-Guard +5
	var fr: bool = bool(temp.get("fortify", false))         # Retaliate +2 while active
	var aoe: bool = def.get("target", "") == "all_enemies"
	var mom: int = 0 if ch == null else int(ch.get("momentum", 0))
	var dev: int = 0 if ch == null else int(ch.get("devotion", 0))
	for op: Array in def["effect"]:
		match op[0]:
			"damage", "dmg":
				var dmg: int = attack_preview(op[1], ch, party_buff)
				if dmg != op[1]:
					buffed = true
				lines.append("Deal %d%s" % [dmg, " to ALL" if aoe else ""])
			"dmg_all":
				var da: int = attack_preview(op[1], ch, party_buff)
				if da != op[1]:
					buffed = true
				lines.append("Deal %d to ALL" % da)
			"dmg_per_momentum":
				if mom > 0:
					lines.append("+%d (%d ⚔️×%d)" % [op[1] * mom, mom, op[1]])
				else:
					lines.append("+%d per ⚔️ Momentum" % op[1])
			"self_dmg":
				lines.append("Lose %d HP" % op[1])
			"heal_self":
				lines.append("Heal yourself %d" % op[1])
			"heal_ally":
				lines.append("Heal ally %d" % op[1])
			"party_block":
				lines.append("All allies +%d block" % op[1])
			"gain_energy":
				lines.append("Gain %d ⚡" % op[1])
			"buff_next_attack":
				lines.append("Next attack +%d" % op[1])
			"retain_block":
				lines.append("Block keeps next turn")
			"next_card_double":
				lines.append("Next card ×2")
			"apply":
				match op[1]:
					"burn":
						lines.append("Apply %d 🔥 Burn" % op[2])
					"vulnerable":
						lines.append("Apply Vulnerable 💥 (+50%)")
			"if_bloodied":
				lines.append("Bloodied: %s" % _nested_text(op[1], ch, party_buff))
			"if_target_marked":
				lines.append("If 🎯 Marked: %s" % _nested_text(op[1], ch, party_buff))
			"spend_devotion":
				lines.append("Spend 🙏 (%d): %s" % [dev, _nested_text(op[1], ch, party_buff)])
			"on_kill":
				lines.append("On kill: %s" % _nested_text(op[1], ch, party_buff))
			"block":
				var blk: int = op[1] + (5 if (fg and def.get("fortifiable", false)) else 0)
				if blk != op[1]:
					buffed = true
				lines.append("Gain %d block" % blk)
			"self_damage":
				lines.append("Lose %d HP" % op[1])
			"draw":
				lines.append("Draw %d" % op[1])
			"damage_scaling":
				var base: int = op[2] + op[3] * attacks_played
				var final: int = attack_preview(base, ch, party_buff)
				if final != op[2]:
					buffed = true
				lines.append("Deal %d" % final)
				lines.append("(+%d per attack · %d so far)" % [op[3], attacks_played])
			"heal_or_damage":
				lines.append("Heal %d ally / Deal %d enemy" % [op[1], op[1]])
			"apply_status":
				if op[1] == "marked":
					lines.append("Mark: +25% dmg taken")
			"force_target_all":
				lines.append("All enemies hit Warrior")
			"temp":
				match op[1]:
					"retaliate":
						var r: int = op[2] + (2 if fr else 0)
						if r != op[2]:
							buffed = true
						lines.append("Reflect %d when hit" % r)
					"fortify":
						lines.append("Next Guard +5; Retaliate +2")
					"channel":
						lines.append("Next %d attacks +%d" % [op[3], op[2]])
			"shield_ally":
				lines.append("Ally: -%d dmg per hit" % op[1])
			"party_buff":
				if op[1] == "attack":
					lines.append("All allies +%d attack" % op[2])
	return {"text": "\n".join(lines), "buffed": buffed}

## Compact one-line description of nested ops (for conditional cards: if_bloodied, on_kill, etc.).
static func _nested_text(ops: Array, ch, party_buff: int) -> String:
	var parts: Array = []
	for o: Array in ops:
		match o[0]:
			"damage", "dmg":
				parts.append("+%d dmg" % attack_preview(o[1], ch, party_buff))
			"block":
				parts.append("+%d block" % o[1])
			"gain_energy":
				parts.append("+%d ⚡" % o[1])
			"heal_self":
				parts.append("heal %d" % o[1])
			"heal_ally":
				parts.append("heal ally %d" % o[1])
			_:
				parts.append(str(o[0]))
	return ", ".join(parts)

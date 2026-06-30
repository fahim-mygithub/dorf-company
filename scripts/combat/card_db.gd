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

const CARDS := {
	# --- shared chassis ---
	"strike":  {"name":"Strike",  "cost":1, "emoji":"🗡️", "target":"enemy",       "type":"attack", "is_attack":true, "range":1,
				"effect":[["damage",6]],
				"tip":"Your bread-and-butter swing — the unit everything else is read against."},
	"guard":   {"name":"Guard",   "cost":1, "emoji":"🛡️", "target":"self",        "type":"skill", "fortifiable":true,
				"effect":[["block",5]],
				"tip":"Raise your shield. Block soaks the next hits this turn, then it's gone."},
	"cleave":  {"name":"Cleave",  "cost":2, "emoji":"🪓", "target":"all_enemies", "type":"attack", "is_attack":true, "range":1,
				"effect":[["damage",11]],
				"tip":"A heavy swing that catches every enemy at once."},
	"wall":    {"name":"Wall",    "cost":2, "emoji":"🧱", "target":"self",        "type":"skill",
				"effect":[["block",12]],
				"tip":"Brace hard — a wall of block to weather a big incoming turn."},
	# --- Warrior signatures ---
	"taunt":   {"name":"Taunt",   "cost":1, "emoji":"😡", "target":"self",        "type":"skill", "limiter":"no_repeat",
				"effect":[["force_target_all","warrior"],["block",8]],
				"tip":"Force EVERY enemy to swing at you next turn, and gain 8 block to survive it. Can't be played two turns in a row."},
	"retaliate":{"name":"Retaliate","cost":1,"emoji":"⚡", "target":"self",        "type":"skill",
				"effect":[["temp","retaliate",4]],
				"tip":"Punish them for taking the bait — every hit you eat this turn hits back for 4."},
	"fortify": {"name":"Fortify", "cost":1, "emoji":"🔧", "target":"self",        "type":"skill",
				"effect":[["temp","fortify"]],
				"tip":"Reinforce — your NEXT Guard this turn grants +5 block, and Retaliate deals +2 while active."},
	# --- Cleric signatures ---
	"channel_shield":{"name":"Channel Shield","cost":1,"emoji":"🔰","target":"ally","type":"skill", "range":2,
				"effect":[["shield_ally",3]],
				"tip":"Wrap an ally in protection — every blow against them this turn is softened by 3."},
	"mend_or_smite":{"name":"Mend or Smite","cost":1,"emoji":"⚖️","target":"ally_or_enemy","type":"skill", "range":2,
				"effect":[["heal_or_damage",5]],
				"tip":"Mercy or judgment — tap an ally to heal 5, or an enemy to deal 5."},
	"aura_of_valor":{"name":"Aura of Valor","cost":2,"emoji":"📣","target":"self","type":"power",
				"effect":[["party_buff","attack",2]],
				"tip":"Inspire the company — every ally's attack deals +2 this turn. A real commitment (2 energy)."},
	# --- Sorcerer signatures ---
	"mark":    {"name":"Mark",    "cost":1, "emoji":"🎯", "target":"enemy",       "type":"skill", "range":2,
				"effect":[["apply_status","marked"]],
				"tip":"Paint the target — it takes +25% from ALL sources this turn. Your whole party benefits."},
	"channel": {"name":"Channel", "cost":1, "emoji":"🌀", "target":"self",        "type":"power",
				"effect":[["temp","channel",3,2]],
				"tip":"Gather power — your next 2 attack cards this turn deal +3 each."},
	"arcane_finisher":{"name":"Arcane Finisher","cost":2,"emoji":"💥","target":"enemy","type":"attack","is_attack":true, "range":2,
				"effect":[["damage_scaling","attacks_this_turn",5,3]],
				"tip":"Unleash everything — deal 5 +3 per attack already played this turn. Play it LAST."},
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
const ENEMIES := {
	"brute":    {"name":"Brute",    "emoji":"👹", "max_hp":45, "atk":9, "pref":"tankiest", "range":1, "move":1,
				"tip":"Wants a worthy fight — hits your tankiest (block, then max HP). Easy to bait with Taunt."},
	"assassin": {"name":"Assassin", "emoji":"🥷", "max_hp":30, "atk":6, "pref":"healer_dps", "range":1, "move":3,
				"tip":"Dives the backline — Healer first, then DPS. Skips the tank unless forced."},
	"caster":   {"name":"Caster",   "emoji":"🔮", "max_hp":28, "atk":5, "pref":"lowest_hp", "range":2, "move":2,
				"tip":"Snipes the weakest — targets whoever has the lowest current HP."},
}
const ENCOUNTER := ["brute", "assassin", "caster"]

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
	for op: Array in def["effect"]:
		match op[0]:
			"damage":
				var dmg: int = attack_preview(op[1], ch, party_buff)
				if dmg != op[1]:
					buffed = true
				lines.append("Deal %d%s" % [dmg, " to ALL" if aoe else ""])
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

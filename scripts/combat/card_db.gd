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
## GRID-MODE ONLY (grid_combat.gd reads these; the non-grid combat.gd ignores them):
## `range`: Manhattan tiles the card can reach from the caster's tile. 0 = self (no reach).
##          grid_combat applies a per-class +1 for the Sorcerer on cards whose base range > 0.
## `area`: true -> a self-cast card that affects an AREA (radius = `range`) around the caster
##          rather than a single tapped target. Armed-to-preview, tap-again-to-cast.
## `area_affects`: "ally" | "enemy" -> which side the area card's radius touches (drives the
##          target-highlight tint while previewing).

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

	# ============================================================ SURVIVORS MODE (zombie survival, 2026-07-01)
	# Class cards stay OUT of the pools (deck / class-gated rescue). Generics -> SURVIVORS_REWARD_POOL.
	# Undead don't bleed -> statuses are Burn 🔥 and Cripple 🦿. New ops live in combat.gd.
	# --- Brute (tank) ---
	"crowbar_swing": {"name":"Crowbar Swing","cost":1,"emoji":"🔨","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",13],["self_dmg",2]],
				"tip":"Deal 13, take 2. A heavy swing that leans you Bloodied."},
	"hold_the_line": {"name":"Hold the Line","cost":1,"emoji":"🛡️","target":"self","type":"skill",
				"effect":[["block",8],["force_target_all","warrior"]],
				"tip":"Gain 8 Block and pull every zombie onto you next turn."},
	"adrenaline": {"name":"Adrenaline","cost":1,"emoji":"💢","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",5],["if_bloodied",[["dmg",9]]]],
				"tip":"Deal 5, +9 more while Bloodied. Fear is fuel."},
	# --- Medic (support) ---
	"patch": {"name":"Patch Up","cost":1,"emoji":"🩹","target":"ally","type":"skill",
				"effect":[["heal_ally",11]],
				"tip":"Heal a chosen ally 11."},
	"triage": {"name":"Triage","cost":1,"emoji":"🚑","target":"party","type":"skill",
				"effect":[["heal_lowest",8],["party_block",2]],
				"tip":"Heal the most-hurt ally 8; all allies gain 2 Block."},
	"stimshot": {"name":"Stim Shot","cost":0,"emoji":"💉","target":"ally","type":"skill",
				"effect":[["heal_ally",3],["ally_gain_energy",1]],
				"tip":"An ally heals 3 and gains 1 Energy. Tempo enabler."},
	# --- Engineer (dps) ---
	"pipe_bomb": {"name":"Pipe Bomb","cost":2,"emoji":"🧨","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",8],["dmg_all",5]],
				"tip":"Deal 8 to the target, then 5 to ALL. AoE burst."},
	"spike_trap": {"name":"Spike Trap","cost":1,"emoji":"🕳️","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",4],["apply","cripple",2]],
				"tip":"Deal 4 and apply 2 Cripple — the target hits softer while it lasts."},
	# --- Survival generics (-> SURVIVORS_REWARD_POOL) ---
	"scavenge": {"name":"Scavenge","cost":0,"emoji":"🔦","target":"self","type":"skill",
				"effect":[["draw",1],["gain_energy",1]],
				"tip":"Draw 1 and refund 1 Energy. Grab what you can."},
	"machete": {"name":"Machete","cost":1,"emoji":"🔪","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",9]],
				"tip":"Deal 9. Reliable steel."},
	"barricade": {"name":"Barricade","cost":1,"emoji":"🧱","target":"self","type":"skill",
				"effect":[["block",10],["retain_block"]],
				"tip":"Gain 10 Block that holds through your next turn."},
	"molotov": {"name":"Molotov","cost":1,"emoji":"🍾","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",4],["apply","burn",4]],
				"tip":"Deal 4 and apply 4 Burn. Watch them cook."},
	"headshot": {"name":"Headshot","cost":2,"emoji":"🔫","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",10],["if_target_marked",[["dmg",10]]]],
				"tip":"Deal 10, +10 more if the target is Marked."},
	"ration": {"name":"Ration","cost":0,"emoji":"🥫","target":"self","type":"skill",
				"effect":[["heal_self",6]],
				"tip":"Heal yourself 6. A cold can of beans."},
	"suppressing_fire": {"name":"Suppressing Fire","cost":1,"emoji":"💥","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg_all",4],["apply_all","cripple",1]],
				"tip":"Deal 4 to ALL and Cripple ALL by 1. Crowd control."},
	"second_wind_s": {"name":"Second Wind","cost":1,"emoji":"🌬️","target":"self","type":"skill",
				"effect":[["block",6],["draw",1]],
				"tip":"Gain 6 Block and draw 1. Catch your breath."},
	"last_stand": {"name":"Last Stand","cost":2,"emoji":"⚰️","target":"enemy","type":"attack","is_attack":true,
				"effect":[["dmg",8],["dmg_per_bloodied_ally",4]],
				"tip":"Deal 8, +4 per bloodied ally. Nothing left to lose."},
}

## Role-skewed decks (~10-12 cards each); the strike/guard split encodes the role.
const CLASSES := {
	"warrior": {"name":"Warrior", "emoji":"🛡️", "role":"warrior", "max_hp":36, "energy":3, "move":1,
		"deck":["strike","strike","strike","strike","guard","guard","guard","guard","guard","taunt","retaliate","fortify"]},
	"cleric":  {"name":"Cleric",  "emoji":"⛑️", "role":"cleric",  "max_hp":28, "energy":3, "move":2,
		"deck":["strike","strike","strike","guard","guard","guard","guard","channel_shield","mend_or_smite","aura_of_valor"]},
	"sorcerer":{"name":"Sorcerer","emoji":"🧙", "role":"sorcerer","max_hp":22, "energy":3, "move":3,
		"deck":["strike","strike","strike","strike","strike","guard","guard","guard","mark","channel","arcane_finisher"]},
	# Survivors-mode classes — same combat ROLES as W/C/S (role-based targeting works unchanged),
	# their own zombie-flavoured starting decks. Overworld/standalone ignore these keys.
	"brute":    {"name":"Brute",    "emoji":"🪓", "role":"warrior",  "max_hp":36, "energy":3, "move":1,
		"deck":["strike","strike","strike","machete","guard","guard","guard","crowbar_swing","hold_the_line","adrenaline","barricade"]},
	"medic":    {"name":"Medic",    "emoji":"⚕️", "role":"cleric",   "max_hp":28, "energy":3, "move":2,
		"deck":["strike","strike","machete","guard","guard","patch","patch","triage","stimshot","ration"]},
	"engineer": {"name":"Engineer", "emoji":"🔧", "role":"sorcerer", "max_hp":22, "energy":3, "move":3,
		"deck":["strike","strike","strike","machete","guard","guard","pipe_bomb","spike_trap","molotov","scavenge"]},
}
const PARTY_ORDER := ["warrior", "cleric", "sorcerer"]
const SURVIVOR_ORDER := ["brute", "medic", "engineer"]

## Enemies: each picks its highest-priority valid target and telegraphs it.
## pref: "tankiest" | "healer_dps" | "lowest_hp".
const ENEMIES := {
	"brute":    {"name":"Brute",    "emoji":"👹", "max_hp":45, "atk":9, "pref":"tankiest", "range":1, "move":1,
				"tip":"Wants a worthy fight — hits your tankiest (block, then max HP). Easy to bait with Taunt."},
	"assassin": {"name":"Assassin", "emoji":"🥷", "max_hp":30, "atk":6, "pref":"healer_dps", "range":1, "move":3,
				"tip":"Dives the backline — Healer first, then DPS. Skips the tank unless forced."},
	"caster":   {"name":"Caster",   "emoji":"🔮", "max_hp":28, "atk":5, "pref":"lowest_hp", "range":2, "move":2,
				"tip":"Snipes the weakest — targets whoever has the lowest current HP."},
	# Survivors-mode zombies — same pref archetypes as brute/assassin/caster (targeting unchanged).
	"walker":   {"name":"Walker",   "emoji":"🧟", "max_hp":46, "atk":9, "pref":"tankiest", "range":1, "move":1,
				"tip":"A shambling bruiser — lurches at your toughest survivor."},
	"lurker":   {"name":"Lurker",   "emoji":"👹", "max_hp":30, "atk":6, "pref":"healer_dps", "range":1, "move":3,
				"tip":"Fast and vicious — goes for the Medic, then the dps."},
	"spitter":  {"name":"Spitter",  "emoji":"🤮", "max_hp":28, "atk":5, "pref":"lowest_hp", "range":2, "move":2,
				"tip":"Ranged bile — hits whoever is weakest."},
}
const ENCOUNTER := ["brute", "assassin", "caster"]
const SURVIVOR_ENCOUNTER := ["walker", "lurker", "spitter"]
const SURVIVOR_BOSS := ["walker", "walker", "spitter"]

## OVERWORLD Phase 2 (overworld.gd reads this to build the combat `request`; combat.gd/grid ignore
## it). Per danger tier: which enemies to field (max 3 — combat has 3 slots) and a scale multiplier
## on enemy hp/atk. "med" = the canonical balanced trio; "high" = a heavier comp (two Brutes) + scale.
const ENCOUNTERS_BY_TIER := {
	"med":  {"enemies": ["brute", "assassin", "caster"], "scale": 1.0},
	"high": {"enemies": ["brute", "brute", "caster"],    "scale": 1.2},
}

const MARK_MULT := 1.25

# Survivors-mode reward pools (kept separate so the overworld's REWARD_POOL stays clean).
const SURVIVORS_REWARD_POOL := ["scavenge", "machete", "barricade", "molotov", "headshot",
	"ration", "suppressing_fire", "second_wind_s", "last_stand"]
const SURVIVOR_CLASS_REWARDS := {
	"brute":    ["crowbar_swing", "hold_the_line", "adrenaline"],
	"medic":    ["patch", "triage", "stimshot"],
	"engineer": ["pipe_bomb", "spike_trap"],
}

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
			"heal_lowest":
				lines.append("Heal most-hurt ally %d" % op[1])
			"ally_gain_energy":
				lines.append("Ally +%d energy" % op[1])
			"dmg_per_bloodied_ally":
				lines.append("+%d per bloodied ally" % op[1])
			"apply_all":
				match op[1]:
					"burn":
						lines.append("Apply %d Burn to ALL" % op[2])
					"vulnerable":
						lines.append("Vulnerable ALL")
					"cripple":
						lines.append("Cripple ALL by %d" % op[2])
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
					"cripple":
						lines.append("Apply %d 🦿 Cripple" % op[2])
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

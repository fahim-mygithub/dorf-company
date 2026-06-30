extends RefCounted
## (preloaded by combat.gd as Db; no class_name to avoid global-class collision)
##
## DATA-ONLY card / class / enemy tables for the mobile party-combat rework.
## combat.gd reads these; adding content = a new row here, never a new branch there.
##
## Card `effect` is a list of [op, ...args] the resolver reads:
##   ["damage", v]                              deal v (enemy Mark stacks add on attack)
##   ["block", v]                               active dwarf gains v block
##   ["self_damage", v]                         active dwarf loses v HP (bypasses block)
##   ["draw", n]                                active dwarf draws n cards
##   ["resource", v]                            active dwarf gains v of its resource
##   ["damage_per_resource", base, per]         deal base + per*resource, then spend ALL resource
##   ["resource_if_bloodied", v]                gain v resource if active dwarf below half HP
##   ["status", "mark", n]                      add n Mark stacks to the target enemy
##   ["status_per_resource", "mark", base, per] add base + per*resource Mark, spend ALL resource
##   ["power", "resource_per_turn", v]          persistent power, resolved at turn start
##
## `target` decides how the card is played:
##   "self"        -> resolves immediately on the active dwarf, no tap
##   "enemy"       -> tap card to select, then tap a living enemy
##   "all_enemies" -> resolves immediately on every living enemy

const CARDS := {
	# --- shared chassis: defense (5) ---
	"block":        {"name": "Block",        "cost": 1, "emoji": "🛡️", "target": "self",        "text": "Gain 5 block",                 "effect": [["block", 5]]},
	"bulwark":      {"name": "Bulwark",      "cost": 1, "emoji": "🧱", "target": "self",        "text": "Gain 8 block",                 "effect": [["block", 8]]},
	"steady":       {"name": "Steady",       "cost": 1, "emoji": "🪨", "target": "self",        "text": "Gain 5 block, draw 1",         "effect": [["block", 5], ["draw", 1]]},
	"wall":         {"name": "Wall",         "cost": 2, "emoji": "🏰", "target": "self",        "text": "Gain 12 block",                "effect": [["block", 12]]},
	# --- shared chassis: attack (5) ---
	"strike":       {"name": "Strike",       "cost": 1, "emoji": "🗡️", "target": "enemy",       "text": "Deal 6",                       "effect": [["damage", 6]]},
	"heavy_strike": {"name": "Heavy Strike", "cost": 1, "emoji": "⚔️", "target": "enemy",       "text": "Deal 9",                       "effect": [["damage", 9]]},
	"marking_blow": {"name": "Marking Blow", "cost": 1, "emoji": "🎯", "target": "enemy",       "text": "Deal 6, +1 Mark",              "effect": [["damage", 6], ["status", "mark", 1]]},
	"cleave":       {"name": "Cleave",       "cost": 2, "emoji": "🪓", "target": "all_enemies", "text": "Deal 11 to all enemies",       "effect": [["damage", 11]]},
	# --- Warrior: Momentum ---
	"build_momentum":  {"name": "Build Momentum",  "cost": 1, "emoji": "💢", "target": "self",  "text": "Gain 2 Momentum",              "effect": [["resource", 2]]},
	"combo_strike":    {"name": "Combo Strike",    "cost": 1, "emoji": "👊", "target": "enemy", "text": "Deal 4, +2 per Momentum",      "effect": [["damage_per_resource", 4, 2]]},
	"bloodied_charge": {"name": "Bloodied Charge", "cost": 1, "emoji": "🩸", "target": "enemy", "text": "Deal 8; if <half HP, +2 Mom.", "effect": [["damage", 8], ["resource_if_bloodied", 2]]},
	# --- Sorcerer: Surge ---
	"channel_surge":   {"name": "Channel Surge",   "cost": 1, "emoji": "✨", "target": "self",  "text": "Gain 2 Surge, draw 1",         "effect": [["resource", 2], ["draw", 1]]},
	"wild_bolt":       {"name": "Wild Bolt",       "cost": 1, "emoji": "⚡", "target": "enemy", "text": "Deal 5; +3 per Surge",         "effect": [["damage_per_resource", 5, 3]]},
	"elemental_mark":  {"name": "Elemental Mark",  "cost": 1, "emoji": "🔥", "target": "enemy", "text": "Deal 3, +1 Mark; +1 per Surge", "effect": [["damage", 3], ["status_per_resource", "mark", 1, 1]]},
	# --- Paladin: Devotion ---
	"take_oath":       {"name": "Take Oath",       "cost": 1, "emoji": "🙏", "target": "self",  "text": "Gain 2 Devotion, 4 block",     "effect": [["resource", 2], ["block", 4]]},
	"smite":           {"name": "Smite",           "cost": 1, "emoji": "🔆", "target": "enemy", "text": "Deal 4, +3 per Devotion",      "effect": [["damage_per_resource", 4, 3]]},
	"aura_of_resolve": {"name": "Aura of Resolve", "cost": 0, "emoji": "😇", "target": "self",  "text": "Each turn: +1 Devotion",       "effect": [["power", "resource_per_turn", 1]]},
}

## 5 defense + 5 attack + 3 class cards = 13 per class.
const CLASSES := {
	"warrior": {
		"name": "Warrior", "emoji": "🪓", "resource": "Momentum",
		"deck": ["block", "block", "bulwark", "steady", "wall",
				 "strike", "strike", "heavy_strike", "marking_blow", "cleave",
				 "build_momentum", "combo_strike", "bloodied_charge"],
	},
	"sorcerer": {
		"name": "Sorcerer", "emoji": "🧙", "resource": "Surge",
		"deck": ["block", "block", "bulwark", "steady", "wall",
				 "strike", "strike", "heavy_strike", "marking_blow", "cleave",
				 "channel_surge", "wild_bolt", "elemental_mark"],
	},
	"paladin": {
		"name": "Paladin", "emoji": "😇", "resource": "Devotion",
		"deck": ["block", "block", "bulwark", "steady", "wall",
				 "strike", "strike", "heavy_strike", "marking_blow", "cleave",
				 "take_oath", "smite", "aura_of_resolve"],
	},
}

## Enemies: telegraphed intents cycle through the list each turn.
## intent = {label, emoji, dmg, blk}.
const ENEMIES := {
	"boss": {
		"name": "Demon Auditor", "emoji": "👹", "max_hp": 60,
		"intents": [
			{"label": "Attack 12",          "emoji": "⚔️", "dmg": 12, "blk": 0},
			{"label": "Defend",             "emoji": "🛡️", "dmg": 0,  "blk": 10},
			{"label": "Attack 8 + Block 6", "emoji": "⚔️", "dmg": 8,  "blk": 6},
		],
	},
	"grunt": {
		"name": "Grunt", "emoji": "👺", "max_hp": 14,
		"intents": [
			{"label": "Attack 5", "emoji": "🗡️", "dmg": 5, "blk": 0},
			{"label": "Defend",   "emoji": "🛡️", "dmg": 0, "blk": 4},
		],
	},
	"imp": {
		"name": "Imp", "emoji": "👻", "max_hp": 10,
		"intents": [
			{"label": "Attack 4", "emoji": "🗡️", "dmg": 4, "blk": 0},
			{"label": "Attack 6", "emoji": "🗡️", "dmg": 6, "blk": 0},
		],
	},
	"skeleton": {
		"name": "Skeleton", "emoji": "💀", "max_hp": 12,
		"intents": [
			{"label": "Attack 5", "emoji": "🗡️", "dmg": 5, "blk": 0},
		],
	},
	"bat": {
		"name": "Bat", "emoji": "🦇", "max_hp": 8,
		"intents": [
			{"label": "Attack 3", "emoji": "🗡️", "dmg": 3, "blk": 0},
			{"label": "Attack 4", "emoji": "🗡️", "dmg": 4, "blk": 0},
		],
	},
}

## The fixed encounter: 1 boss + 4 minions.
const ENCOUNTER := ["boss", "grunt", "imp", "skeleton", "bat"]

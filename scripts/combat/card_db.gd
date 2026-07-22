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
##   ["force_target_all","tank"]                  MELEE enemies target the tank next enemy turn
##                                                (ranged bodies shoot past it — see _taunt_catches)
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
	"strike":  {"name":"Strike",  "cost":1, "emoji":"🗡️", "target":"enemy",       "type":"attack", "school":"physical", "is_attack":true, "range":1,
				"effect":[["damage",6]],
				"tip":"Your bread-and-butter swing — the unit everything else is read against."},
	"guard":   {"name":"Guard",   "cost":1, "emoji":"🛡️", "target":"self",        "type":"skill", "school":"block", "fortifiable":true, "range":0,
				"effect":[["block",5]],
				"tip":"Raise your shield. Block soaks the next hits this turn, then it's gone."},
	# CLEAVE IS A THINNER, NOT A DELETER — 11 was measured and it deleted four of the twelve curated
	# boards outright, at the floor scale each one is authored against (overworld composes threat
	# ADDITIVELY, so a board's own `scale` is the number it actually ships at with no map modifier,
	# danger 1 and the canonical trio). Minion HP at those floors:
	#   spore_nest  0.90 -> pit_adder 6   nest_and_clock 1.20 -> pit_adder 8
	#   shell_flock 1.15 -> cave_bat  7   spore_flight   1.45 -> cave_bat  9
	#   long_swallow 1.60 -> cave_bat 10
	# 11 one-shot EVERY one of those rows, three of them straight through the Shellback's -3 aegis,
	# which is the literal text of shell_flock's and nest_and_clock's own fails_if falsifiers. And the
	# Warrior sees ~10 of its 12 cards by turn 2, so it was not a lottery — it was the default line.
	# 5 is the ONLY value that leaves every one of those rows standing at its floor: 6 still deletes
	# spore_nest's 6 HP adders verbatim. It also gives the aegis teeth for the first time (5 - 3 = 2 a
	# bat, so on shell_flock the correct play becomes "kill the Shellback first", which is that
	# encounter's whole named lesson) while keeping the shape the deck comment below asks for:
	# 20 for 2 energy on a four-body row, 5 for 2 on a lone boss. UNSIMMED — dorf_sim.py has seen
	# neither number. If it proves too weak the lever is 5 -> 6 AND spore_nest's adders off the band
	# floor, not 5 -> 8, which puts two rows back in one-shot range.
	"cleave":  {"name":"Cleave",  "cost":2, "emoji":"🪓", "target":"all_enemies", "type":"attack", "school":"physical", "is_attack":true, "range":1,
				"effect":[["damage",5]],
				"tip":"A wide swing that catches every enemy at once — it thins a row, it does not clear one."},
	"wall":    {"name":"Wall",    "cost":2, "emoji":"🧱", "target":"self",        "type":"skill", "school":"block", "range":0,
				"effect":[["block",12]],
				"tip":"Brace hard — a wall of block to weather a big incoming turn."},
	# --- Warrior signatures ---
	"taunt":   {"name":"Taunt",   "cost":1, "emoji":"😡", "target":"self",        "type":"skill", "school":"block", "limiter":"no_repeat", "range":2, "area":true, "area_affects":"enemy",
				"effect":[["force_target_all","tank"],["block",8]],
				"tip":"MELEE enemies swing at you next turn; ranged ones (🏹) shoot past you and keep their own target. Gain 8 block. Can't be played two turns in a row."},
	"retaliate":{"name":"Retaliate","cost":1,"emoji":"⚡", "target":"self",        "type":"skill", "school":"block", "range":0,
				"effect":[["temp","retaliate",4]],
				"tip":"Punish them for taking the bait — every hit you eat this turn hits back for 4."},
	"fortify": {"name":"Fortify", "cost":1, "emoji":"🔧", "target":"self",        "type":"skill", "school":"block", "range":0,
				"effect":[["temp","fortify"]],
				"tip":"Reinforce — your NEXT Guard this turn grants +5 block, and Retaliate deals +2 while active."},
	# --- Cleric signatures ---
	"channel_shield":{"name":"Channel Shield","cost":1,"emoji":"🔰","target":"ally","type":"skill", "school":"block", "range":2,
				"effect":[["shield_ally",3]],
				"tip":"Wrap an ally in protection — every blow against them this turn is softened by 3."},
	"mend_or_smite":{"name":"Mend or Smite","cost":1,"emoji":"⚖️","target":"ally_or_enemy","type":"skill", "school":"spell", "range":2,
				"effect":[["heal_or_damage",5]],
				"tip":"Mercy or judgment — tap an ally to heal 5, or an enemy to deal 5."},
	"aura_of_valor":{"name":"Aura of Valor","cost":2,"emoji":"📣","target":"self","type":"power", "school":"spell", "range":2, "area":true, "area_affects":"ally",
				"effect":[["party_buff","attack",2]],
				"tip":"Inspire the company — allies within range deal +2 attack this turn. A real commitment (2 energy)."},
	# --- Sorcerer signatures ---
	"mark":    {"name":"Mark",    "cost":1, "emoji":"🎯", "target":"enemy",       "type":"skill", "school":"spell", "range":2,
				"effect":[["apply_status","marked"]],
				"tip":"Paint the target — it takes +25% from ALL sources this turn. Your whole party benefits."},
	"channel": {"name":"Channel", "cost":1, "emoji":"🌀", "target":"self",        "type":"power", "school":"spell", "range":0,
				"effect":[["temp","channel",3,2]],
				"tip":"Gather power — your next 2 attack cards this turn deal +3 each."},
	"arcane_finisher":{"name":"Arcane Finisher","cost":2,"emoji":"💥","target":"enemy","type":"attack", "school":"spell","is_attack":true, "range":2,
				"effect":[["damage_scaling","attacks_this_turn",5,3]],
				"tip":"Unleash everything — deal 5 +3 per attack already played this turn. Play it LAST."},

	# ============================================================ EXPANSION (hex-crawl spec, 2026-07-01)
	# Class cards stay OUT of REWARD_POOL (role-locked); generic cards join it. New ops live in combat.gd.
	# --- Warrior (Momentum) ---
	"reckless_swing": {"name":"Reckless Swing","cost":1,"emoji":"🪓","target":"enemy","type":"attack", "school":"physical","is_attack":true,
				"effect":[["dmg",14],["self_dmg",3]],
				"tip":"Deal 14. Take 3. Leans you Bloodied — pairs with cards that reward it."},
	"second_wind": {"name":"Second Wind","cost":1,"emoji":"🛡️","target":"self","type":"skill", "school":"block",
				"effect":[["block",6],["if_bloodied",[["block",6]]]],
				"tip":"Gain 6 Block. +6 more while Bloodied (at or below half HP)."},
	"momentum_strike": {"name":"Momentum Strike","cost":1,"emoji":"⚔️","target":"enemy","type":"attack", "school":"physical","is_attack":true,
				"effect":[["dmg",6],["dmg_per_momentum",3]],
				"tip":"Deal 6, +3 per Momentum (attacks you've already played this turn). Play it late."},
	# --- Sorcerer (Surge / Wild Magic) ---
	"arc_lightning": {"name":"Arc Lightning","cost":2,"emoji":"⚡","target":"enemy","type":"attack", "school":"spell","is_attack":true,
				"effect":[["dmg",9],["dmg_all",4]],
				"tip":"Deal 9 to the target, then 4 to ALL enemies."},
	"empower": {"name":"Empower","cost":0,"emoji":"✨","target":"self","type":"power", "school":"spell",
				"effect":[["next_card_double"]],
				"tip":"Your next card's numbers are doubled. Set up a big hit."},
	"kindle": {"name":"Kindle","cost":1,"emoji":"🔥","target":"enemy","type":"attack", "school":"spell","is_attack":true,
				"effect":[["dmg",5],["apply","burn",3]],
				"tip":"Deal 5, then apply 3 Burn (ticks at the start of each enemy turn, ignores block)."},
	# --- Cleric / Paladin (Devotion / Oath) — gated to the cleric role until a Paladin class lands ---
	"lay_on_hands": {"name":"Lay on Hands","cost":1,"emoji":"🙌","target":"ally","type":"skill", "school":"spell",
				"effect":[["heal_ally",10]],
				"tip":"Heal a chosen ally 10."},
	"consecrate": {"name":"Consecrate","cost":1,"emoji":"🕯️","target":"party","type":"skill", "school":"block",
				"effect":[["party_block",4]],
				"tip":"All allies gain 4 Block."},
	"divine_smite": {"name":"Divine Smite","cost":2,"emoji":"🌟","target":"enemy","type":"attack", "school":"spell","is_attack":true,
				"effect":[["dmg",10],["spend_devotion",[["dmg",8]]]],
				"tip":"Deal 10, +8 more if you spend 1 Devotion (built by playing skills)."},
	# --- Generic (universal chassis; these join REWARD_POOL) ---
	"power_through": {"name":"Power Through","cost":1,"emoji":"💪","target":"self","type":"skill", "school":"block",
				"effect":[["block",8],["draw",1]],
				"tip":"Gain 8 Block. Draw 1."},
	"precise_jab": {"name":"Precise Jab","cost":0,"emoji":"🗡️","target":"enemy","type":"attack", "school":"physical","is_attack":true,
				"effect":[["dmg",4],["gain_energy",1]],
				"tip":"Deal 4, then refund 1 Energy — nearly free tempo."},
	"whetstone": {"name":"Whetstone","cost":0,"emoji":"🪨","target":"self","type":"skill", "school":"physical",
				"effect":[["buff_next_attack",4]],
				"tip":"Your next attack this turn deals +4."},
	"guard_break": {"name":"Guard Break","cost":1,"emoji":"💥","target":"enemy","type":"attack", "school":"physical","is_attack":true,
				"effect":[["dmg",7],["apply","vulnerable",1]],
				"tip":"Deal 7 and apply Vulnerable (target takes +50% for a turn). Applies AFTER this hit."},
	"field_dressing": {"name":"Field Dressing","cost":1,"emoji":"🩹","target":"self","type":"skill", "school":"spell",
				"effect":[["heal_self",7]],
				"tip":"Heal yourself 7."},
	"bracing_stance": {"name":"Bracing Stance","cost":1,"emoji":"🧱","target":"self","type":"skill", "school":"block",
				"effect":[["block",10],["retain_block"]],
				"tip":"Gain 10 Block that does NOT expire on your next turn."},
	"opportunist": {"name":"Opportunist","cost":1,"emoji":"🎯","target":"enemy","type":"attack", "school":"physical","is_attack":true,
				"effect":[["dmg",6],["if_target_marked",[["dmg",6]]]],
				"tip":"Deal 6, +6 more if the target is Marked."},
	"rally": {"name":"Rally","cost":1,"emoji":"📣","target":"party","type":"skill", "school":"block",
				"effect":[["party_block",3],["draw",1]],
				"tip":"All allies gain 3 Block. Draw 1."},
	"trophy_hunter": {"name":"Trophy Hunter","cost":2,"emoji":"🏆","target":"enemy","type":"attack", "school":"physical","is_attack":true,
				"effect":[["dmg",12],["on_kill",[["gain_energy",2]]]],
				"tip":"Deal 12. If it kills the target, gain 2 Energy."},

	# ============================================================ THE THREE ARCHETYPES (2026-07-17)
	# The three published role sheets, shipped. Every card carries a `school` (block/physical/spell) — a
	# SECOND axis beside `type`, because Strike and Bolt are both attacks and no amount of squinting at
	# the type tells you one is a swing and one is a spell. The Druid's forms and the Sorcerer's
	# Metamagic are the first readers of it.
	# --- Barbarian (Enrage: rage replaces Guard) ---
	"blood_for_blood": {"name":"Blood for Blood","cost":1,"emoji":"🩸","target":"enemy","type":"attack","school":"physical","is_attack":true,
				"effect":[["dmg",7],["if_bloodied",[["dmg",7]]]],
				"tip":"Deal 7 — 14 instead while Bloodied (at or below half HP). The Barbarian is paid for being hurt."},
	"thick_hide": {"name":"Thick Hide","cost":1,"emoji":"🐗","target":"self","type":"skill","school":"block","fortifiable":true,
				"effect":[["gain_guard",6],["if_bloodied",[["gain_guard",6]]]],
				"tip":"Gain 6 Guard, +6 more while Bloodied. Dead weight while you rage — rage replaces Guard."},
	"bellow": {"name":"Bellow","cost":1,"emoji":"📢","target":"self","type":"skill","school":"block","limiter":"no_repeat",
				"effect":[["force_target_all","tank"],["gain_guard",4]],
				# Bellow carries the SAME ["force_target_all","tank"] op as Taunt, so it inherits the
				# melee-only redirect (see combat.gd _taunt_catches) whether this string says so or not.
				# It used to still print the pre-2026-07-21 "every enemy" promise, which put two
				# contradictory rules in one tooltip: describe() keys off the OP, so the generated body
				# already read "Melee enemies hit the tank" directly above this line.
				"tip":"MELEE enemies swing at you next turn; ranged ones (🏹) shoot past you and keep their own target. Gain 4 Guard. Can't be played two turns in a row."},
	"rampage": {"name":"Rampage","cost":2,"emoji":"👊","target":"all_enemies","type":"attack","school":"physical","is_attack":true,
				"effect":[["dmg",8]],
				"tip":"A wild swing that catches every enemy at once."},
	# --- Fighter (Guard is spent, never hoarded) ---
	"shield_up": {"name":"Shield Up","cost":1,"emoji":"🛡️","target":"self","type":"skill","school":"block","fortifiable":true,
				"effect":[["gain_guard",8]],
				"tip":"Raise the wall. Guard soaks the next hits — and pulls the enemy's eye onto you."},
	"sidestep": {"name":"Sidestep","cost":1,"emoji":"↩️","target":"self","type":"skill","school":"block",
				"effect":[["gain_guard",5],["draw",1]],
				"tip":"Gain 5 Guard and draw 1. Keeps the wall moving."},
	"shield_bash": {"name":"Shield Bash","cost":1,"emoji":"🔨","target":"enemy","type":"attack","school":"physical","is_attack":true,
				"effect":[["dmg",6],["dmg_per_guard",1,4]],
				"tip":"Deal 6, +1 per 4 Guard you're holding. Cash the wall in as damage."},
	"reforge": {"name":"Reforge","cost":0,"emoji":"🔋","target":"self","type":"skill","school":"block",
				"effect":[["pay_with_guard"]],
				"tip":"Your next card is paid for with Guard instead of Energy. Pour the wall into a Whirlwind."},
	"whirlwind": {"name":"Whirlwind","cost":"X","emoji":"🌪️","target":"all_enemies","type":"attack","school":"physical","is_attack":true,
				"effect":[["dmg_x"]],
				"tip":"Spend EVERYTHING. Deal that much to every enemy. (After Reforge, X is your Guard, not your Energy.)"},
	"hold_the_line": {"name":"Hold the Line","cost":1,"emoji":"🧱","target":"party","type":"skill","school":"block",
				"effect":[["party_block",4]],
				"tip":"All allies gain 4 Guard. The wall covers the whole company."},
	# --- Paladin (Devotion banks between Smites) ---
	"vow_of_wrath": {"name":"Vow of Wrath","cost":1,"emoji":"⚔️","target":"self","type":"skill","school":"block",
				"effect":[["gain_guard",4],["temp","smite_bonus",4]],
				"tip":"Gain 4 Guard, and your next Divine Smite hits 4 harder. Swear it before you swing."},
	# --- Cleric (Channel Divinity: the aura reads your cast TYPES) ---
	"mend": {"name":"Mend","cost":1,"emoji":"🙌","target":"ally","type":"skill","school":"spell",
				"effect":[["heal_ally",8],["bank_communion",1]],
				"tip":"Heal an ally 8 and bank 📿. A 🙏 mercy cast — it feeds the aura's healing side."},
	"bless": {"name":"Bless","cost":1,"emoji":"✨","target":"party","type":"skill","school":"block",
				"effect":[["party_block",3],["bank_communion",1]],
				"tip":"All allies gain 3 block and you bank 📿. A 🙏 mercy cast."},
	"sanctuary": {"name":"Sanctuary","cost":1,"emoji":"🔰","target":"ally","type":"skill","school":"block",
				"effect":[["shield_ally",3],["bank_communion",1]],
				"tip":"Every blow against an ally is softened by 3 this turn. A 🙏 mercy cast."},
	"censure": {"name":"Censure","cost":1,"emoji":"💥","target":"enemy","type":"attack","school":"spell","is_attack":true,
				"effect":[["dmg",6]],
				"tip":"Deal 6. A 🔥 smite cast — it feeds the aura's damage side."},
	"searing_word": {"name":"Searing Word","cost":1,"emoji":"☀️","target":"enemy","type":"attack","school":"spell","is_attack":true,
				"effect":[["dmg",5],["apply","burn",2]],
				"tip":"Deal 5 and apply 2 🔥 Burn. A 🔥 smite cast — and a status, which hands a Monk its fists back."},
	# --- Bard (the song is held by BREADTH: 3 distinct targets a turn) ---
	"mockery": {"name":"Vicious Mockery","cost":1,"emoji":"🎭","target":"enemy","type":"attack","school":"spell","is_attack":true,
				"effect":[["dmg",4],["apply","vulnerable",1]],
				"tip":"Deal 4 and apply Vulnerable 💥. An insult that lands — and a target for the song."},
	"inspiration": {"name":"Inspiration","cost":1,"emoji":"🎵","target":"ally","type":"skill","school":"spell",
				"effect":[["buff_ally_next",4],["bank_communion",1]],
				"tip":"An ally's next attack this turn deals +4. Bank 📿."},
	"crescendo": {"name":"Crescendo","cost":1,"emoji":"🎶","target":"party","type":"power","school":"spell",
				"effect":[["party_buff","attack",2],["bank_communion",1]],
				"tip":"All allies deal +2 this turn. Bank 📿. The party counts as ONE target for the song."},
	"refrain": {"name":"Refrain","cost":0,"emoji":"🔁","target":"self","type":"skill","school":"spell",
				"effect":[["draw",1],["bard_free_target"]],
				"tip":"Draw 1 — and it counts as a third target all by itself. The song's escape hatch."},
	"ballad": {"name":"Ballad","cost":2,"emoji":"📯","target":"party","type":"skill","school":"spell",
				"effect":[["heal_party",5],["bank_communion",1]],
				"tip":"Heal every ally 5. Bank 📿. An AoE counts as ONE target, no matter how many it hits."},
	# --- Druid (Wild Shape: the form pays for the card SCHOOLS in your hand) ---
	"forage": {"name":"Forage","cost":1,"emoji":"🌰","target":"self","type":"skill","school":"spell",
				"effect":[["shuffle_random_into_deck",1],["draw",2],["bank_communion",1]],
				"tip":"Put a random card back into your deck, draw 2, bank 📿. Re-seed the hand your form reads."},
	"regrowth": {"name":"Regrowth","cost":1,"emoji":"🍃","target":"ally","type":"skill","school":"spell",
				"effect":[["heal_ally",6],["heal_ally_next",4],["bank_communion",1]],
				"tip":"Heal an ally 6 now and 4 more at the start of next turn. Bank 📿."},
	"barkskin": {"name":"Barkskin","cost":1,"emoji":"🌳","target":"party","type":"skill","school":"block",
				"effect":[["party_block",4],["bank_communion",1]],
				"tip":"All allies gain 4 block. Bank 📿. A 🛡️ block card — 🐻 Bear pays you for holding it."},
	"entangle": {"name":"Entangle","cost":1,"emoji":"🕸️","target":"all_enemies","type":"attack","school":"spell","is_attack":true,
				"effect":[["dmg",4],["apply","vulnerable",1]],
				"tip":"Deal 4 to ALL and apply Vulnerable 💥 to each. A 🧿 spell — 🦅 Hawk pays you for holding it."},
	"maul": {"name":"Maul","cost":1,"emoji":"🐻","target":"enemy","type":"attack","school":"physical","is_attack":true,
				"effect":[["dmg",6],["if_form","wolf",[["dmg",4]]]],
				"tip":"Deal 6 — 10 while you're in 🐺 Wolf form."},
	# --- Sorcerer (Metamagic charges on ANYONE's spell) ---
	"bolt": {"name":"Bolt","cost":1,"emoji":"⚡","target":"enemy","type":"attack","school":"spell","is_attack":true,
				"effect":[["dmg",6]],
				"tip":"Deal 6. Same numbers as a Strike — but it's a 🧿 spell, and that is the whole difference."},
	# --- Rogue (the party keeps the mark bleeding) ---
	"backstab": {"name":"Backstab","cost":1,"emoji":"🗡️","target":"enemy","type":"attack","school":"physical","is_attack":true,
				"effect":[["dmg",6],["if_assassin_mark",[["dmg",6]]]],
				"tip":"Deal 6, +6 more if the target carries your 🎯 Assassin's Mark."},
	"shiv": {"name":"Shiv","cost":0,"emoji":"🔪","target":"enemy","type":"attack","school":"physical","is_attack":true,
				"effect":[["dmg",3]],
				"tip":"Deal 3, free. Cheap — and every hit of yours makes your mark tick harder."},
	"shadowstep": {"name":"Shadowstep","cost":0,"emoji":"💨","target":"self","type":"skill","school":"physical",
				"effect":[["gain_energy",1],["buff_next_attack",4]],
				"tip":"Refund 1 ⚡ and your next attack deals +4. Free tempo."},
	"poison_blade": {"name":"Poison Blade","cost":1,"emoji":"🧪","target":"enemy","type":"attack","school":"physical","is_attack":true,
				"effect":[["dmg",4],["apply","burn",3]],
				"tip":"Deal 4 and apply 3 🔥. A status — which refunds a Monk's Flurry this turn."},
	"fan_of_knives": {"name":"Fan of Knives","cost":2,"emoji":"🔪","target":"all_enemies","type":"attack","school":"physical","is_attack":true,
				"effect":[["dmg",8]],
				"tip":"Deal 8 to every enemy."},
	# --- Monk (Flurry is refunded by ANYONE's status) ---
	"jab": {"name":"Jab","cost":0,"emoji":"👊","target":"enemy","type":"attack","school":"physical","is_attack":true,
				"effect":[["dmg",3],["gain_energy",1]],
				"tip":"Deal 3 and refund 1 ⚡. Effectively free."},
	"stunning_strike": {"name":"Stunning Strike","cost":1,"emoji":"💫","target":"enemy","type":"attack","school":"physical","is_attack":true,
				"effect":[["dmg",4],["apply","stun",1]],
				"tip":"Deal 4 and Stun 💫 — it loses its next action. A status, so it hands your Flurry back."},
	"deflect": {"name":"Deflect","cost":1,"emoji":"🌀","target":"self","type":"skill","school":"block","fortifiable":true,
				"effect":[["block",5],["temp","retaliate",4]],
				"tip":"Gain 5 block and reflect 4 on every hit you eat this turn."},
	"chill_touch": {"name":"Chill Touch","cost":1,"emoji":"❄️","target":"enemy","type":"attack","school":"spell","is_attack":true,
				"effect":[["dmg",4],["apply","vulnerable",1]],
				"tip":"Deal 4 and apply Vulnerable 💥. The Monk's one 🧿 spell — it charges a Sorcerer."},
	"quivering_palm": {"name":"Quivering Palm","cost":2,"emoji":"☝️","target":"enemy","type":"attack","school":"physical","is_attack":true,
				"effect":[["dmg",8],["on_kill",[["gain_energy",2]]]],
				"tip":"Deal 8. If it kills, gain 2 ⚡."},
}

## The CLASS POWERS — one per class, fired by tapping your own dwarf's orb (a Hearthstone-style hero
## power, a second lever beside the hand). class_powers.gd resolves them; combat.gd only routes taps.
##   target  = "" (no pick) | "enemy" (tap an enemy to aim it)
##   choices = a 3-way pick the tap must answer first (Metamagic's shapes, Wild Shape's forms)
##   passive = fires ITSELF; the orb is a readout, not a button
## The three archetypes gate their powers on three different things ON PURPOSE: tank spends a
## cooldown, support spends Communion 📿, and dps spends nothing — the party charges it.
const POWERS := {
	# --- tank: a cooldown, and the resource it spends ---
	"action_surge": {"name":"Action Surge", "emoji":"⏱️", "target":"", "choices":[],
		"gate":"4-turn cooldown", "tip":"+2 ⚡ this turn and draw 1. The tempo burst that empties your hand and breaks a stall."},
	"enrage": {"name":"Enrage", "emoji":"😤", "target":"", "choices":[],
		"gate":"stance · attack each turn to hold it", "tip":"Take HALF damage and deal +4 while Bloodied — but you can no longer gain Guard: resistance replaces your block. Skip a turn without attacking and it drops for 4 turns."},
	"smite": {"name":"Divine Smite", "emoji":"🌟", "target":"enemy", "choices":[],
		"gate":"3-turn cooldown · spends banked 🙏", "tip":"Deal 6 +4 per Devotion spent, and the party gains 3 block. Bank hard between casts — the smite you save up hits for more."},
	# --- support: Communion is the IGNITION, never the upkeep ---
	"channel_divinity": {"name":"Channel Divinity", "emoji":"✨", "target":"", "choices":[], "passive":true,
		"gate":"passive · auto-discharges every 5 casts", "tip":"No tap. Every cast charges it by TYPE — attacks feed 🔥 smite, heals and shields feed 🙏 mercy — and a streak of the same type pays more each repeat. Every 5th cast it fires itself. Commit to a line."},
	"bardic_performance": {"name":"Bardic Performance", "emoji":"🎶", "target":"", "choices":[], "communion":3,
		"gate":"stance · 3 distinct targets a turn", "tip":"Allies deal +2 and gain +2 block. Holding it costs no resource — it costs REACH: touch 3 distinct targets each turn, and an AoE counts as ONE. Come up short and the song breaks."},
	"wild_shape": {"name":"Wild Shape", "emoji":"🐾", "target":"", "communion":3,
		"choices":[{"key":"bear","name":"Bear","emoji":"🐻","tip":"Every 🛡️ block card in hand -> +5 Guard, free."},
			{"key":"hawk","name":"Hawk","emoji":"🦅","tip":"Every 🧿 spell card in hand -> +3 block to the whole party, free."},
			{"key":"wolf","name":"Wolf","emoji":"🐺","tip":"Every ⚔️ physical card in hand -> your first attack hits +5 harder."}],
		"gate":"stance · pick a form · costs 2 cards · 3 turns", "tip":"Shift for 3 turns. At the start of your next turn you hand 2 cards back to your DECK and do NOT replace them — that −2 hand is the price. Then every shifted turn your form reads your hand and pays for its school."},
	# --- dps: never a cooldown. The gate reads what the PARTY just did. ---
	# 🧿 and not 🌀 (2026-07-22 glyph-collision pass): 🌀 was the Witch's Shriek, the Sorcerer's Channel
	# charge badge AND this coin, all three legible in one screenshot. The Shriek gave its glyph up to
	# the intent grammar and Channel keeps 🌀 (it is the older, more frequently seen of the two), so
	# Metamagic moves. 🧿 is already the school glyph this power reads off a card, which makes it the
	# one substitution that carries meaning instead of just being a free square.
	"metamagic": {"name":"Metamagic", "emoji":"🧿", "target":"", "charge":3,
		"choices":[{"key":"twin","name":"Twinned","emoji":"🧿","tip":"Your next spell also hits a second target, in full."},
			{"key":"quicken","name":"Quicken","emoji":"⚡","tip":"Your next spell costs 2 less."},
			{"key":"heighten","name":"Heighten","emoji":"⏳","tip":"Your next spell doesn't fire now — at the start of your next turn it fires TWICE."}],
		"gate":"charges +1 per spell cast by ANYONE · ready at 3", "tip":"Never on a cooldown. Your Bolt charges it; so does the Cleric's Mend. At 3, choose a shape for your next spell: wider, cheaper, or later but double."},
	"assassins_mark": {"name":"Assassin's Mark", "emoji":"🎯", "target":"enemy", "choices":[],
		"gate":"no cooldown · one mark at a time", "tip":"It bleeds 4 a turn for 3 turns and IGNORES ARMOUR entirely. Every ally hit on it adds a turn; every hit of YOURS adds 2 tick. The party keeps it alive, you make it hurt."},
	"flurry": {"name":"Flurry of Blows", "emoji":"👊", "target":"enemy", "choices":[],
		"gate":"3-turn cooldown — refunded by every status ANYONE lands", "tip":"Strike for 8. For the rest of this turn every status applied to an enemy — a teammate's Burn, anyone's — hands it straight back. Status -> Flurry -> status -> Flurry."},
}

## Role-skewed decks (~10-12 cards each); the strike/guard split encodes the role.
## `role` is the ARCHETYPE (tank/support/dps) — enemy targeting reads it. `power` is the class's
## signature. Warrior/Cleric/Sorcerer keep their ids: the campaign gates its High job on a fieldable
## canonical trio, and all four harnesses hardcode them.
const CLASSES := {
	# --- TANK ⚔️ — Guard soaks the hit AND pulls the threat (it is the shipped `block` field) ---
	# The shipped Warrior IS the Fighter archetype in its simple form, so it takes Action Surge —
	# which means the default trio ships one power from each of the three archetypes.
	# CLEAVE JOINED THE WARRIOR (2026-07-21), replacing the FIFTH Guard. Still 12 cards.
	# Why the trio needed it: warrior/cleric/sorcerer held ZERO AoE and exactly one party_block, and
	# the bestiary now leans on swarms of 3-6 bodies. A party with no answer to four minions is not
	# being asked a question, it is being taxed — the only line available was "kill them one at a
	# time and eat every hit", which is a dice roll, not a decision.
	# Why the fifth Guard and not a Strike: Guard was the most redundant slot in the deck. Five
	# copies in twelve cards means you draw ~2 every 5-card hand, and this dwarf ALSO carries Taunt
	# (8 block by itself) and Fortify (+5 to a Guard). Four copies keeps Fortify's combo live and
	# keeps block density high, while a Strike cut would have hit the party's single-target floor —
	# the Warrior is the only reliable damage the trio has when the Sorcerer is setting up.
	# Cleave stays in the deck but was RESTATTED 11 -> 5 (see the card, which carries the measurement).
	# It is still deliberately strong on 3+ bodies (20 for 2 energy on a four-body row) and
	# deliberately terrible on one, which is exactly the shape a swarm answer should have — it just no
	# longer ANSWERS a swarm by deleting it before the encounter asks its question. The alternative
	# considered and rejected was pulling Cleave back out of the deck and restoring the fifth Guard:
	# that re-opens the tax this slot was added to close ("kill four minions one at a time and eat
	# every hit"), and the party would once more have no printed answer to a row. UNSIMMED either way.
	"warrior": {"name":"Warrior", "emoji":"🛡️", "role":"tank", "power":"action_surge", "max_hp":36, "energy":3, "move":1,
		"deck":["strike","strike","strike","strike","guard","guard","guard","guard","cleave","taunt","retaliate","fortify"]},
	"barbarian":{"name":"Barbarian","emoji":"🪓", "role":"tank", "power":"enrage", "max_hp":34, "energy":3, "move":1,
		"deck":["strike","strike","strike","guard","guard","reckless_swing","reckless_swing","blood_for_blood","thick_hide","thick_hide","bellow","rampage"]},
	"fighter": {"name":"Fighter", "emoji":"🛡️", "role":"tank", "power":"action_surge", "max_hp":38, "energy":3, "move":1,
		"deck":["strike","strike","strike","shield_up","shield_up","shield_up","sidestep","shield_bash","shield_bash","reforge","whirlwind","hold_the_line"]},
	"paladin": {"name":"Paladin", "emoji":"🌟", "role":"tank", "power":"smite", "max_hp":34, "energy":3, "move":1,
		"deck":["strike","strike","strike","guard","guard","lay_on_hands","consecrate","consecrate","channel_shield","vow_of_wrath","vow_of_wrath","aura_of_valor"]},
	# --- SUPPORT 📿 — Communion buys the stance, then gets out of the way ---
	"cleric":  {"name":"Cleric",  "emoji":"⛑️", "role":"support", "power":"channel_divinity", "max_hp":28, "energy":3, "move":2,
		"deck":["strike","strike","strike","guard","guard","guard","mend","mend","bless","sanctuary","censure","searing_word"]},
	"bard":    {"name":"Bard",    "emoji":"🎻", "role":"support", "power":"bardic_performance", "max_hp":26, "energy":3, "move":2,
		"deck":["strike","strike","strike","guard","guard","mockery","mockery","inspiration","crescendo","refrain","ballad"]},
	"druid":   {"name":"Druid",   "emoji":"🐻", "role":"support", "power":"wild_shape", "max_hp":30, "energy":3, "move":2,
		"deck":["strike","strike","guard","guard","guard","forage","regrowth","barkskin","entangle","maul","maul"]},
	# --- DPS 🗡️ — no personal meter; the party charges every one of these ---
	# Sorcerer does NOT start with arc_lightning: it is already in overworld's CLASS_REWARDS["sorcerer"],
	# and shipping it in the starting deck would make its own reward tile a duplicate.
	"sorcerer":{"name":"Sorcerer","emoji":"🧙", "role":"dps", "power":"metamagic", "max_hp":22, "energy":3, "move":3,
		"deck":["strike","strike","strike","guard","guard","guard","bolt","bolt","mark","channel","arcane_finisher"]},
	"rogue":   {"name":"Rogue",   "emoji":"🗡️", "role":"dps", "power":"assassins_mark", "max_hp":24, "energy":3, "move":3,
		"deck":["strike","strike","guard","guard","guard","shiv","shiv","backstab","backstab","shadowstep","poison_blade","fan_of_knives"]},
	"monk":    {"name":"Monk",    "emoji":"👊", "role":"dps", "power":"flurry", "max_hp":24, "energy":3, "move":3,
		"deck":["strike","strike","guard","guard","guard","jab","jab","jab","stunning_strike","deflect","chill_touch","quivering_palm"]},
}
## The canonical trio — one per archetype. UNCHANGED: the campaign gates its High job on it, the
## Monte-Carlo sim was tuned against it, and every harness hardcodes warrior/sorcerer.
const PARTY_ORDER := ["warrior", "cleric", "sorcerer"]
## The full roster — what a lobby roll or a campaign recruit draws from, where variety is the point.
const ROLL_POOL := ["warrior", "barbarian", "fighter", "paladin", "cleric", "bard", "druid",
	"sorcerer", "rogue", "monk"]

## ================================================================ The intent grammar
## ONE row per move kind. A move kind used to cost FIVE function edits — _do_enemy_move (behaviour,
## which stays code), plus _intent_text, _intent_color, _intent_headline and _intent_brief, which
## are all pure presentation and are now this table. Adding a kind should cost one data row.
##
## The per-move "emoji" field is DELETED (2026-07-21). Author-time emoji is exactly how 🌀 came to
## mean the Witch's Shriek, the Sorcerer's Channel AND a Twinned spell in the same screenshot: three
## authors each picked their own glyph for their own reason and nothing was there to stop them. The
## verb of an intent sentence is a property of the KIND, so it lives here, once, and the Witch can no
## longer spell her scream however she likes.
##
## `verb` is that one canonical glyph. `color` is the intent label's font colour (these are the exact
## Color values lifted out of combat.gd::_intent_color — moved, not retuned). The three *_fmt strings
## are String.format templates over this placeholder vocabulary; a consumer fills only the keys its
## kind actually names, so the caller can hand over one dictionary for every kind:
##   {verb}    this row's glyph                    {name}   the move's own name
##   {hit}     per-hit damage AFTER the target's Vulnerable x1.5 (what the victim will actually feel)
##   {dmg}     per-hit damage BEFORE Vulnerable — for "Next:" briefs, where the target isn't fixed yet
##   {hits}    multi's hit count                   {amt}    block / guard / rage / expose amount
##   {ally}    guard_all's ally share              {gain}   rage actually granted, after RAGE_CAP
##   {tgt}     target name, 3-char (compact label) {target} target name in full (headline)
## `label_fmt` is a fifth key the contract didn't name: _intent_text is one of the five functions this
## table exists to retire, and leaving it behind would have meant a new kind still cost a code edit.
## `*_fmt_zero` are the truthfulness variants, used when {gain} lands on 0 because rage hit its cap —
## a telegraph that promises "+2 attack" and delivers nothing is a lie, and only rage_all can tell it.
##
## ---------------------------------------------------------------- THE THREE-SLOT CONTRACT (2026-07-22)
## Every `label_fmt` below is now exactly [verb][magnitude][target chip], in that order, with no
## exceptions and no optional slots. Two changes make that true, and both are subtractions:
##
##  1. FOUR VERBS, NOT SEVEN. 🗡️ Harm covers attack/multi/attack_all; 🛡️ Guard covers block/guard_all;
##     📈 Empower is rage_all alone; 💥 Weaken is expose. The retired glyphs (🔪 🌊 🧱 📣) were all
##     encoding MAGNITUDE or SHAPE in the verb slot — "🔪 means several hits", "🌊 means everybody" —
##     while a digit sat right next to them doing the same job. A glyph that duplicates the number is
##     a glyph the player has to learn for nothing, and it costs the one thing the verb slot is for:
##     answering "is this coming at me, or is it housekeeping" in a single saccade across six bodies.
##     📣 moving to 📈 is a collision fix as well as a budget cut — 📣 is the PARTY's Aura of Valor
##     readout in the same frame, and one glyph meaning "your buff" and "their buff" is unreadable.
##
##  2. THE TARGET CHIP IS MANDATORY. Every label ends in >Name / >ALL / >self. It is what retires the
##     `×` overload: "🗡️3×3" was three swings and "🌀3×all" was everyone, so × meant two unrelated
##     things in the same row of labels. With a chip on every line, × can only ever mean SEPARATE
##     SWINGS, and >ALL carries the fan-out. `attack_all` therefore prints ">ALL" instead of "×all",
##     and `block`/`guard_all` gained ">self"/">ALL" chips they never had — a defensive beat that ends
##     in a chip is instantly distinguishable from a truncated attack line, which is exactly the
##     confusion a chip-less label invites when it sits under a body six columns wide.
##
## Headlines and briefs keep their prose (they are read one at a time, in a panel, with room) — the
## grammar is a property of the COMPACT label, which is the one that has to survive a six-body board.
const MOVE_KINDS := {
	"attack":     {"verb":"🗡️", "color":Color(1.0, 0.55, 0.50),
					"label_fmt":"{verb}{hit}>{tgt}",
					"headline_fmt":"{name}: hits {target} for {hit}",
					"brief_fmt":"{dmg}"},
	# × is now unambiguous: it separates SWINGS and nothing else. The chip says who eats all of them.
	"multi":      {"verb":"🗡️", "color":Color(1.0, 0.55, 0.50),
					"label_fmt":"{verb}{hit}×{hits}>{tgt}",
					"headline_fmt":"{name}: {hits} hits of {hit} on {target}",
					"brief_fmt":"{dmg}×{hits}"},
	# {dmg} and not {hit}: the number is per-DWARF and each dwarf folds in its own Vulnerable, so a
	# single printed figure can only honestly be the pre-multiplier one. The per-dwarf truth is on the
	# portrait forecast (combat.gd::_incoming_forecast), which is where a per-dwarf number belongs.
	"attack_all": {"verb":"🗡️", "color":Color(1.0, 0.55, 0.50),
					"label_fmt":"{verb}{dmg}>ALL",
					"headline_fmt":"{name}: {dmg} to EVERY dwarf",
					"brief_fmt":"{dmg} to all"},
	"block":      {"verb":"🛡️", "color":Color(0.62, 0.85, 1.0),
					"label_fmt":"{verb}{amt}>self",
					"headline_fmt":"{name}: blocks {amt}",
					"brief_fmt":"block {amt}"},
	"guard_all":  {"verb":"🛡️", "color":Color(0.62, 0.85, 1.0),
					"label_fmt":"{verb}{amt}/+{ally}>ALL",
					"headline_fmt":"{name}: blocks {amt}, allies +{ally}",
					"brief_fmt":"block {amt}/+{ally}"},
	"rage_all":   {"verb":"📈", "color":Color(0.98, 0.78, 0.35),
					"label_fmt":"{verb}+{gain}>ALL",       "label_fmt_zero":"{verb}max>ALL",
					"headline_fmt":"{name}: ALL enemies +{gain} attack",
					"headline_fmt_zero":"{name}: the pack's fury is at its peak",
					"brief_fmt":"+{gain} atk to all",      "brief_fmt_zero":"fury peaked"},
	"expose":     {"verb":"💥", "color":Color(0.85, 0.62, 1.0),
					"label_fmt":"{verb}>{tgt}",
					"headline_fmt":"{name}: curses {target} — x1.5 for a turn",
					"brief_fmt":"curse ×1.5"},
}

## ================================================================ The nameplate badge
## The THIRD slot of the readout, and deliberately NOT part of the intent line: a badge answers "what
## does this body always do" and the intent line answers "what is it about to do". Fusing them was the
## old design and it taught the player nothing — a rule you only ever see restated as this turn's
## target never becomes a rule you can plan against.
##
## CLOSED SET OF THREE, one per shipped `pref`, and it must never grow: three glyphs is a legend a
## player memorises in one fight, and every enemy that lands from here on has to pick one of the three
## rather than mint a fourth. `forced` is the fourth entry and it is not a fourth RULE — it is the
## marker for "the rule above was overridden this turn", which is why combat.gd draws it INSTEAD of
## the pref badge with the pref badge shrunk beside it: a rule that has been overridden has to still
## be visible, or the player cannot tell an override from a body that never had that rule.
##
## ⚠ A BADGE IS IDENTITY, NEVER TRUTH. threat_arrows.gd stays the authority on who is actually being
## hit this turn. combat.gd only ever shows 😡 when _taunt_catches() says the redirect ACTUALLY took
## (Taunt is melee-only since 2026-07-21) — a badge that claims a redirect the resolver then ignores
## is strictly worse than no badge, because it is a promise rather than a decoration.
const PREF_BADGES := {
	"tankiest":   {"badge":"🧲", "tip":"Swings at whoever is holding the most Guard."},
	"healer_dps": {"badge":"🔦", "tip":"Goes past your shields for the healer."},
	"lowest_hp":  {"badge":"🥀", "tip":"Finishes whoever is closest to dropping."},
	"forced":     {"badge":"😡", "tip":"Taunted — it is coming for the tank instead."},
}

## Enemies: each picks its highest-priority valid target and telegraphs it.
## pref: "tankiest" | "healer_dps" | "lowest_hp".
## `moves` (2026-07-01): a fixed ROTATION of telegraphed intents, started at a random offset per
## instance (duplicates desync). Move kinds are the keys of MOVE_KINDS above; their PAYLOADS
## (executed by combat.gd::_do_enemy_move) are:
##   attack {dmg} · multi {dmg,hits} · attack_all {dmg} · block {amt} (self, clears at its next
##   action) · guard_all {amt, ally_amt} · rage_all {amt} (permanent +atk, all enemies) ·
##   expose {amt} (Vulnerable 💥 on its preferred target: takes x1.5 from enemy hits, decays 1/turn).
## `atk` stays as the fallback for an entry without moves (old flat-attack behavior).
##
## `tier` (2026-07-21) — "minion" | "line" | "heavy" | "boss". A body's WEIGHT on the board, kept as
## data so the encounter builder can budget a comp ("one heavy plus two minions") instead of an
## id list that has to be edited every time a new enemy lands.
## `aura` (2026-07-21) — a passive every OTHER enemy on the board enjoys, {"kind":..., "amt":...}:
##   "aegis"  — allies take `amt` less per hit. Never stacks: take the single largest on the board,
##              or three Shellbacks would make the line unkillable.
##   "chorus" — allies' attack damage rises by `amt`.
## Synergy is DATA and never an id list in code: "which enemies buff which" has to survive ten more
## enemies landing, and a hardcoded list is exactly the thing that silently rots when they do.
const ENEMIES := {
	"brute":    {"name":"Brute",    "emoji":"👹", "max_hp":45, "atk":9, "pref":"tankiest", "range":1, "move":1, "tier":"heavy",
				"tip":"Wants a worthy fight — hits your tankiest (block, then max HP). Easy to bait with Taunt.",
				"moves": [
					{"name":"Smash", "kind":"attack", "dmg":9,  "tip":"A heavy swing at its chosen target."},
					{"name":"Smash", "kind":"attack", "dmg":9,  "tip":"A heavy swing at its chosen target."},
					{"name":"CRUSH", "kind":"attack", "dmg":14, "tip":"An overhead blow — block it or eat it."},
				]},
	"assassin": {"name":"Assassin", "emoji":"🥷", "max_hp":30, "atk":6, "pref":"healer_dps", "range":1, "move":3, "tier":"line",
				"tip":"Dives the backline — Healer first, then DPS. Skips the tank unless forced.",
				"moves": [
					{"name":"Stab",   "kind":"attack", "dmg":6,          "tip":"A quick blade to the back."},
					{"name":"Expose", "kind":"expose", "amt":2,          "tip":"Marks a weak point: the victim takes x1.5 from enemies for a turn."},
					{"name":"Flurry", "kind":"multi",  "dmg":3, "hits":3, "tip":"Three fast cuts — each one triggers Retaliate."},
				]},
	# The Caster's chorus is why it reads as a "support" body: three Casters is not three snipers, it
	# is one sniper and +6 attack on everything else. Aura amount is deliberately its own number, not
	# derived from atk — a chorus that scaled with the singer would break the moment one is buffed.
	"caster":   {"name":"Caster",   "emoji":"🔮", "max_hp":28, "atk":5, "pref":"lowest_hp", "range":2, "move":2, "tier":"line",
				"aura": {"kind":"chorus", "amt":3},
				"tip":"Snipes the weakest — targets whoever has the lowest current HP. Its chant drives every OTHER enemy's attacks up by 3.",
				"moves": [
					{"name":"Zap",  "kind":"attack", "dmg":5,  "tip":"A crackle of hostile magic."},
					{"name":"Ward", "kind":"block",  "amt":6,  "tip":"Shields itself — the ward soaks your next hits."},
					{"name":"Bolt", "kind":"attack", "dmg":10, "tip":"A charged bolt at the weakest dwarf."},
				]},
	"wolf":     {"name":"Wolf",     "emoji":"🐺", "max_hp":22, "atk":5, "pref":"lowest_hp", "range":1, "move":3, "tier":"line",
				"tip":"Pack hunter — worries the weakest, and its Howl whips the whole pack into a frenzy.",
				"moves": [
					{"name":"Bite", "kind":"attack",   "dmg":5, "tip":"Teeth find the weakest dwarf."},
					{"name":"Howl", "kind":"rage_all", "amt":2, "tip":"Every enemy gains +2 attack. Permanently."},
					{"name":"Bite", "kind":"attack",   "dmg":5, "tip":"Teeth find the weakest dwarf."},
				]},
	"warden":   {"name":"Warden",   "emoji":"🗿", "max_hp":40, "atk":7, "pref":"tankiest", "range":1, "move":1, "tier":"heavy",
				"aura": {"kind":"aegis", "amt":3},
				"tip":"A stone guardian — walls its allies behind it, then trades blows with your tank. Everything else on the board takes 3 less per hit while it stands.",
				"moves": [
					{"name":"Bulwark", "kind":"guard_all", "amt":8, "ally_amt":4, "tip":"Walls itself behind stone and shields its allies."},
					{"name":"Slam",    "kind":"attack",    "dmg":7,               "tip":"A slab of stone to the face."},
					{"name":"Slam",    "kind":"attack",    "dmg":7,               "tip":"A slab of stone to the face."},
				]},
	"witch":    {"name":"Witch",    "emoji":"🧿", "max_hp":26, "atk":6, "pref":"lowest_hp", "range":2, "move":2, "tier":"line",
				"tip":"Hexes and screams — curses the weakest, and her Shriek hits every dwarf at once.",
				"moves": [
					{"name":"Shriek", "kind":"attack_all", "dmg":3, "tip":"A piercing scream — hits EVERY dwarf."},
					{"name":"Hex",    "kind":"expose",     "amt":2, "tip":"A curse: the victim takes x1.5 from enemies for a turn."},
					{"name":"Blast",  "kind":"attack",     "dmg":7, "tip":"A bolt of spite at the weakest dwarf."},
				]},
	"ogre":     {"name":"Ogre",     "emoji":"👺", "max_hp":55, "atk":10, "pref":"tankiest", "range":1, "move":1, "tier":"heavy",
				"tip":"Slow and colossal — braces itself, then delivers a crushing two-beat blow. Time your blocks.",
				"moves": [
					{"name":"Brace", "kind":"block",  "amt":5,  "tip":"Plants its feet and guards while it winds up."},
					{"name":"CRUSH", "kind":"attack", "dmg":16, "tip":"The wind-up lands. Block or bleed."},
				]},

	# ============================================================ The bestiary (2026-07-21)
	# Ten new bodies, ascending HP. The design rule for every one of them: an enemy has to be
	# READABLE FROM ITS INTENT LABEL ALONE, because a six-body board is six labels and nobody reads
	# six paragraphs. So the chaff gets ONE beat (a swarm collapses to a single summarised line) and
	# the complexity budget is spent on the heavies and the bosses, where there is only one label to
	# read. Damage is sanity-checked against the canonical party — Warrior 36 / Cleric 28 /
	# Sorcerer 22, pool 86 — and specifically against the 22 HP Sorcerer, because a turn-one board
	# that puts 22 into the Sorcerer has decided the fight before the player has made a decision.

	# --- minions: one body, one idea. Cheap enough to field in numbers, which is the whole point. ---
	"cave_bat":     {"name":"Cave Bat",     "emoji":"🦇", "max_hp":6,  "atk":4, "pref":"lowest_hp", "range":1, "move":4, "tier":"minion",
				"tip":"Dies to one unbuffed Strike — and finishes whoever you already let get hurt.",
				"moves": [
					# ONE beat, forever. A four-bat board must read as "🗡️4>Sor ×4" at a glance; give
					# a bat a second beat and the swarm stops being summarisable, which is the only
					# thing that makes swarms shippable at all.
					{"name":"Swoop", "kind":"attack", "dmg":4, "tip":"Dives at whoever is closest to dropping."},
				]},
	"pit_adder":    {"name":"Pit Adder",    "emoji":"🐍", "max_hp":7,  "atk":5, "pref":"healer_dps", "range":1, "move":3, "tier":"minion",
				"tip":"Ignores your front line and goes for the Cleric. The same small body as a bat, aimed somewhere much worse.",
				"moves": [
					# Also one beat. The Adder's whole design is that it is a Cave Bat whose TARGETING
					# is the threat, so anything it did on a second beat would dilute the lesson.
					# 7 HP, not 6: at 6 it fell to Strike, Bolt AND Censure alike, which erased the
					# "which card do I spend on the snake" question the pair exists to ask.
					{"name":"Fang", "kind":"attack", "dmg":5, "tip":"Slips past the shields and bites the healer."},
				]},
	"bone_wretch":  {"name":"Bone Wretch",  "emoji":"💀", "max_hp":11, "atk":4, "pref":"tankiest", "range":1, "move":2, "tier":"minion",
				"tip":"Reassembles itself between swings — killing it properly costs two cards, not one.",
				"moves": [
					# A minion with a block beat. 11 HP is two Strikes; catch it on Reassemble and it
					# is three. That is the whole creature: the first minion whose corpse has a price.
					{"name":"Clatter",    "kind":"attack", "dmg":4, "tip":"A loose swing of old bone."},
					{"name":"Reassemble", "kind":"block",  "amt":5, "tip":"Drags itself back together — 5 block soaks your next hits."},
				]},
	"sporeling":    {"name":"Sporeling",    "emoji":"🍄", "max_hp":11, "atk":2, "pref":"lowest_hp", "range":2, "move":1, "tier":"minion",
				"aura": {"kind":"chorus", "amt":2},
				"tip":"Barely fights. Its spores drive every OTHER enemy's attacks up by 2 — the softest body on the board and almost always the correct first kill.",
				"moves": [
					# Both beats are deliberately pathetic. A Sporeling that could hurt you would be
					# killed for the wrong reason; it has to be obviously harmless AND obviously
					# first, so that "kill the thing that isn't hitting me" is a lesson the board
					# teaches rather than something a tooltip asserts.
					{"name":"Spore Cloud", "kind":"attack_all", "dmg":1, "tip":"A drifting puff — 1 damage to every dwarf. That is genuinely all it does."},
					{"name":"Spore Puff",  "kind":"attack",     "dmg":2, "tip":"A weak burst at the most wounded dwarf."},
				]},
	"rune_crystal": {"name":"Rune Crystal", "emoji":"💎", "max_hp":14, "atk":0, "pref":"lowest_hp", "range":2, "move":0, "tier":"minion",
				"aura": {"kind":"aegis", "amt":3},
				"tip":"Deals NO damage and is still the most urgent thing on the board: everything else takes 3 less per hit while it hums.",
				"moves": [
					# It must NEVER carry an attack-kind beat — "the enemy that cannot hurt you" is a
					# rule the player has to be able to trust completely or the aegis reads as a
					# random tax instead of a puzzle. So its two beats are the two non-damaging
					# kinds that still LOOK like something is happening: it feeds the line, then it
					# paints a target. An inert rock would just be a 14 HP delay.
					{"name":"Refract", "kind":"guard_all", "amt":2, "ally_amt":4, "tip":"Bends the light — a shell of 4 over every other enemy."},
					{"name":"Glare",   "kind":"expose",    "amt":1,               "tip":"Fixes on the weakest dwarf: they take x1.5 from enemy hits for a turn."},
				]},

	# --- line: a body that holds a slot on its own without ending the fight by itself. ---
	"shellback":    {"name":"Shellback",    "emoji":"🐢", "max_hp":26, "atk":3, "pref":"tankiest", "range":1, "move":1, "tier":"line",
				"aura": {"kind":"aegis", "amt":3},
				"tip":"Hits for almost nothing and is still the first thing to kill — its shell covers the whole enemy line. The Warden's lesson at a third of the price.",
				"moves": [
					# Self-block, not guard_all: its aura ALREADY covers the others, and a body that
					# both radiates aegis and hands out block would be two walls in one slot.
					{"name":"Hunker",     "kind":"block",  "amt":6, "tip":"Pulls in behind the shell — 6 block."},
					{"name":"Shell Slam", "kind":"attack", "dmg":3, "tip":"A slow shove at your sturdiest dwarf."},
					{"name":"Shell Slam", "kind":"attack", "dmg":3, "tip":"A slow shove at your sturdiest dwarf."},
				]},

	# --- heavy: the body a comp is built around. ---
	"the_maw":      {"name":"The Maw",      "emoji":"🐙", "max_hp":58, "atk":8, "pref":"lowest_hp", "range":1, "move":1, "tier":"heavy",
				"tip":"Feeds on the dead — every enemy that dies, yours or its own, makes it hit for 3 more. It prices your kills.",
				"moves": [
					# The gorge device (elsewhere) adds +3 per corpse to its damage. The rotation is
					# built so that growth LANDS: Swallow multiplies the gorge by its hit count, so a
					# board you cleared greedily comes due on a beat you can see coming. The third
					# beat is 11, not 14, precisely because the Maw aims at lowest_hp: the Ogre's 16
					# goes into a 36 HP Warrior, this goes into whoever is already nearly dead.
					{"name":"Gulp",          "kind":"attack", "dmg":8,           "tip":"A wet snap at the most wounded dwarf."},
					{"name":"Swallow",       "kind":"multi",  "dmg":4, "hits":2, "tip":"Two bites — and every corpse it has eaten is counted TWICE here."},
					{"name":"Ravening Bite", "kind":"attack", "dmg":11,          "tip":"It opens all the way. Whatever it has fed on comes with it."},
				]},

	# --- bosses: one body, one whole fight. Each is legible and each dares you anyway. ---
	"molt_king":    {"name":"The Molt-King", "emoji":"🦂", "max_hp":88, "atk":9, "pref":"tankiest", "range":1, "move":2, "tier":"boss",
				"tip":"Two fights in one body. Crack the shell (half HP) and the same beats come back faster and meaner.",
				# ARMORED half — slow, shelled, survivable. The beats teach the rhythm you will meet
				# again on the other side of the crack, which is what makes the second half readable
				# on sight instead of a surprise.
				"moves": [
					{"name":"Carapace",   "kind":"block",      "amt":8, "tip":"Plates lock shut — 8 block."},
					{"name":"Claw",       "kind":"attack",     "dmg":9, "tip":"A slow pincer at your sturdiest dwarf."},
					{"name":"Tail Sweep", "kind":"attack_all", "dmg":4, "tip":"The tail comes round — 4 to every dwarf."},
				],
				# CRACKED half, below 50% HP. combat.gd is expected to swap the active rotation to
				# `moves_molt` at the threshold WITHOUT resetting move_i — the two arrays are the same
				# LENGTH on purpose, so beat index 0 stays beat index 0 and the telegraph the player
				# already read stays true, it just resolves as the molted version. (This file only
				# authors the data; the swap itself is not implemented here.)
				"moves_molt": [
					{"name":"Shed",       "kind":"rage_all", "amt":2,           "tip":"It sheds the shell — every enemy gains +2 attack. Permanently."},
					{"name":"Sting Rush", "kind":"multi",    "dmg":5, "hits":2, "tip":"Two strikes where the claw used to be one."},
					{"name":"Venom Lash", "kind":"attack",   "dmg":14,          "tip":"The tail, now naked, comes down on one dwarf instead of all three."},
				]},
	"overseer":     {"name":"The Overseer",  "emoji":"👀", "max_hp":90, "atk":6, "pref":"lowest_hp", "range":2, "move":1, "tier":"boss",
				"tip":"Its lattice of crystals is the fight — it cannot be meaningfully hurt while they hum, and its Gaze burns hotter for each one still alive.",
				"moves": [
					# The regalia device (elsewhere) scales the Gaze beats by the number of living
					# Rune Crystals, and their aegis is what makes the Overseer itself near-immune.
					# `gaze: true` marks which beats scale — a flag, not a name match, because
					# "any move whose name contains Gaze" is a rule that breaks the first time
					# someone renames a move or localises it.
					{"name":"Gaze",         "kind":"attack",     "dmg":6, "gaze":true,   "tip":"A beam through the lattice at the most wounded dwarf. Hotter per living crystal."},
					{"name":"Attune",       "kind":"guard_all",  "amt":4, "ally_amt":6,  "tip":"Pours power into the lattice — 6 shielding over every crystal."},
					{"name":"Baleful Gaze", "kind":"attack_all", "dmg":4, "gaze":true,   "tip":"The whole lattice fires at once — 4 to every dwarf, hotter per living crystal."},
					{"name":"Pinpoint",     "kind":"expose",     "amt":2,                "tip":"The eye settles: that dwarf takes x1.5 from enemy hits."},
				]},
	"vorn":         {"name":"Vorn, the Rockwyrm", "emoji":"🐉", "max_hp":120, "atk":12, "pref":"tankiest", "range":1, "move":2, "tier":"boss",
				"tip":"A four-beat metronome. It tells you exactly what it is about to do, every time, and dares you to be ready.",
				"moves": [
					# Beat 1 is a GIFT and has to stay one: no damage, no debuff, nothing but block.
					# The entire pitch of this fight is "you get one free turn in four, and Vorn is
					# still going to win unless you spend it correctly." Every other beat is
					# therefore allowed to be brutal, because the player was handed the turn to
					# prepare for it and can count the beats to it on one hand.
					{"name":"Coil",      "kind":"block",      "amt":10, "tip":"Draws itself in behind a wall of scale. It does nothing else this turn — this one is yours."},
					{"name":"Rake",      "kind":"attack",     "dmg":12, "tip":"Claws rip into your sturdiest dwarf."},
					{"name":"Tail Sweep","kind":"attack_all", "dmg":6,  "tip":"The tail comes across the whole party — 6 each."},
					{"name":"AVALANCHE", "kind":"attack",     "dmg":20, "tip":"It brings the ceiling down on one dwarf. You had three turns' warning."},
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
			# --- the three archetypes (2026-07-17). EVERY op needs an arm here or its card renders a
			# blank body: describe() is the only thing that writes a card face.
			"dmg_per_guard":
				var g: int = 0 if ch == null else int(ch.get("block", 0))
				if g >= int(op[2]):
					lines.append("+%d (%d 🛡️)" % [int(float(g) * float(op[1]) / float(op[2])), g])
				else:
					lines.append("+%d per %d 🛡️ Guard" % [op[1], op[2]])
			"dmg_x":
				var pool: int = 0 if ch == null else int(ch.get("energy", 0))
				if ch != null and bool((ch.get("temp", {}) as Dictionary).get("pay_with_guard", false)):
					pool = int(ch.get("block", 0))
					lines.append("Deal %d to ALL (X = 🛡️)" % pool)
				else:
					lines.append("Deal X to ALL (X = %d ⚡)" % pool)
			"pay_with_guard":
				lines.append("Next card: pay with 🛡️, not ⚡")
			"gain_guard":
				var gg: int = op[1] + (5 if (fg and def.get("fortifiable", false)) else 0)
				if gg != op[1]:
					buffed = true
				lines.append("Gain %d 🛡️ Guard" % gg)
			"bank_communion":
				lines.append("Bank %d 📿" % op[1])
			"heal_party":
				lines.append("Heal all allies %d" % op[1])
			"buff_ally_next":
				lines.append("Ally's next attack +%d" % op[1])
			"heal_ally_next":
				lines.append("+%d more next turn" % op[1])
			"shuffle_random_into_deck":
				lines.append("Shuffle %d back into deck" % op[1])
			"bard_free_target":
				lines.append("Counts as a 3rd 🎯 target")
			"if_form":
				lines.append("%s: %s" % [_form_emoji(str(op[1])), _nested_text(op[2], ch, party_buff)])
			"if_assassin_mark":
				lines.append("If 🎯 Marked: %s" % _nested_text(op[1], ch, party_buff))
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
					"stun":
						lines.append("Apply Stun 💫 (skips a turn)")
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
				# The body line has to name the exception, not just the rule: a card that promises
				# "all enemies" and then leaves the Caster shooting the Sorcerer reads as a bug.
				lines.append("Melee enemies hit the tank")
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
					"smite_bonus":
						lines.append("Next 🌟 Smite +%d" % op[2])
			"shield_ally":
				lines.append("Ally: -%d dmg per hit" % op[1])
			"party_buff":
				if op[1] == "attack":
					lines.append("All allies +%d attack" % op[2])
	return {"text": "\n".join(lines), "buffed": buffed}

static func _form_emoji(form: String) -> String:
	match form:
		"bear": return "🐻 Bear"
		"hawk": return "🦅 Hawk"
		"wolf": return "🐺 Wolf"
		_: return form

## Compact one-line description of nested ops (for conditional cards: if_bloodied, on_kill, etc.).
static func _nested_text(ops: Array, ch, party_buff: int) -> String:
	var parts: Array = []
	for o: Array in ops:
		match o[0]:
			"damage", "dmg":
				parts.append("+%d dmg" % attack_preview(o[1], ch, party_buff))
			"block":
				parts.append("+%d block" % o[1])
			"gain_guard":
				parts.append("+%d 🛡️" % o[1])
			"gain_energy":
				parts.append("+%d ⚡" % o[1])
			"heal_self":
				parts.append("heal %d" % o[1])
			"heal_ally":
				parts.append("heal ally %d" % o[1])
			_:
				parts.append(str(o[0]))
	return ", ".join(parts)

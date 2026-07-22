extends RefCounted
## (preloaded as Enc; no class_name to avoid global-class collision — same idiom as card_db.gd)
##
## THE TWELVE ENCOUNTERS — curated, named boards that replace the flat comp arrays.
##
## Today the game rolls a bare ["brute","assassin","caster"] out of Db.ENCOUNTER_POOLS. That stays
## as the FALLBACK (a missing band must never crash a run); this table is the new authority.
##
## WHY THIS FILE EXISTS AT ALL. A balance rig (scripts/test/skill_gap.gd) decomposed a planner bot's
## advantage over a greedy one and measured it: aiming heals was worth 95%, blocking to the telegraph
## 33%, and CHOOSING TARGETS 0%. Zero. Three differently sized health bars is a fight where target
## choice cannot matter, because nothing on the board is worth more than its own health bar. Every
## encounter below exists to put a body on the table whose VALUE is not its HP — an aura source, a
## corpse-counter, a thing that gets worse when it is last. That is the whole brief.
##
## THE FIVE THINGS THAT ARE NOT NEGOTIABLE HERE:
##   1. Every device is DERIVED from board state that already crosses the wire (alive flags, hp,
##      archetype id, slot). This file stores no state and adds no wire field. See combat's snapshot
##      contract — an int leaf that crossed the wire would have to join _INT_KEYS or arrive as a float.
##   2. The board only ever SHRINKS. No summons, no splits, no reinforcements — `slot` is the wire
##      address and _apply_snapshot silently DROPS any enemy whose slot exceeds the local array.
##   3. Auras are DATA on the enemy (Db.ENEMIES[*].aura), never an id list in code. This file reads
##      that data to VALIDATE a board; it never re-declares it.
##   4. Every device must be visible BEFORE the player commits. A conditional the player cannot see
##      is just an unfair number. Where a board leans on something the UI does not yet print, that is
##      written down as a falsifiable `assumes` entry, not hand-waved.
##   5. At most 3 distinct types in the row. Effortless enumeration caps at 3-4 items and the board
##      is re-read every single turn; a 4th shape is only affordable when it is the elevated boss.
##
## THE CALLERS: overworld.gd (_hex_combat and _embark_fight) rolls a board; combat.gd reads the
## `design` block for the player-facing feedback popup. Nothing here touches either file.

const Db := preload("res://scripts/combat/card_db.gd")

# ================================================================ Bands

## band -> the encounter ids that live in it. THE ORDER OF TRUTH: BANDS is what roll() draws from,
## ENCOUNTERS is what get_enc() reads, and validate() asserts the two agree in both directions — a
## board that exists but is in no band is dead content, and a band that names a missing board crashes
## a run. Both have happened to this repo before (crew_results["cls"] was dead data for a month).
const BANDS := {
	"easy":  ["shell_line", "spore_nest", "stonefists"],
	"med":   ["quiet_one", "nest_and_clock", "shell_flock"],
	"hard":  ["spore_flight", "gorge", "last_word"],
	"elite": ["overseer_tally", "molt_king", "long_swallow"],
}

## Per-band envelope, asserted by validate(). `scale` is the spec's band range; `row` is the number
## of bodies allowed in the ROW (the boss sits above the row and is exempt from this count).
##
## Why elite's row is the SMALLEST: the boss is itself worth two or three bodies of attention (a
## crack meter, a four-beat metronome, a regalia count). The tracking budget is a fixed size — the
## boss spends most of it, so the row that flanks it has to be short.
const BAND_ENVELOPE := {
	"easy":  {"scale_min": 0.90, "scale_max": 1.00, "row_min": 2, "row_max": 5},
	"med":   {"scale_min": 1.15, "scale_max": 1.25, "row_min": 3, "row_max": 5},
	"hard":  {"scale_min": 1.30, "scale_max": 1.45, "row_min": 3, "row_max": 6},
	"elite": {"scale_min": 1.60, "scale_max": 2.00, "row_min": 2, "row_max": 4},
}

## Hexcrawl tier -> the base rung of the band ladder. The hexcrawl speaks in tiers ("low"/"med"/
## "high", overworld.gd DANGER/PAYOUT/TIER_LABEL) and a per-tile danger int 1-3 that feeds
## DANGER_STEP 0.21. Four bands have to come out of that 3x3 grid, so the two axes are ADDED into a
## 0-4 rung and the rungs are named. Adding (not multiplying) is deliberate and matches the
## 2026-07-01 scaling audit: multiplying tier x danger grew roughly quadratically and produced cells
## that measured 0% winnable.
const TIER_RUNG := {"low": 0, "med": 1, "high": 2}

## rung -> band. rung = TIER_RUNG[tier] + (danger - 1), clamped to 0..4.
##   low/1 easy · low/2 easy · low/3 med
##   med/1 easy · med/2 med  · med/3 hard
##   high/1 med · high/2 hard · high/3 ELITE
## Elite is reachable from exactly ONE cell (high tier, danger 3) and that is the point: a named
## set-piece the player can see coming on the hex map and choose to route around. The Extract button
## is the whole reason a 0%-ish cell is allowed to exist at all.
const RUNG_BAND := ["easy", "easy", "med", "hard", "elite"]

## Composite ceiling for composite_scale(). The 2026-07-01 audit walked the reachable threat space
## and found the worst cell it could actually build was escale 2.12; above that is unsimmed and the
## sim already proved a hard 0% wall lives up there. Elite bosses carry 88-120 raw HP, which IS the
## elite band's content — the band multiplier must not also triple them.
const SCALE_CEILING := 2.2

# ================================================================ The twelve
##
## SHAPE (one entry per encounter):
##   "name"      display name, shown on the board and in the popup header.
##   "band"      easy | med | hard | elite.
##   "scale"     MULTIPLIES onto the hexcrawl's additive threat — see composite_scale() and the loud
##               warning attached to it. Assigned per board against the board's raw HP pool, not
##               copied off the band midpoint; the reasoning is in each entry's comment.
##   "enemies"   the ROW, in slot order. Order is load-bearing: `slot` is the wire address, and the
##               minion-block rule below is about CONTIGUITY on screen.
##   "boss"      archetype id of the ELEVATED body, "" = none. Sits above the row and is exempt from
##               the row count. bodies() puts it at slot 0 so its wire address is stable.
##   "synergies" which devices this board is built around. NOT decoration: validate() checks each
##               named device is actually enabled by the bodies present, so a synergy cannot rot into
##               a lie the way an un-read dictionary key does.
##   "design"    the load-bearing block; it feeds the player-facing feedback popup. See DESIGN BLOCK.
##
## DESIGN BLOCK — written as a designer talking to a playtester, not as marketing:
##   "question"  the ONE decision, in the player's language, one sentence.
##   "assumes"   the design assumptions being tested. Each one must be FALSIFIABLE.
##   "rhythm"    the shape the fight SHOULD have, turn by turn.
##   "asserts"   what should be true if the design landed.
##   "fails_if"  the falsifier. This is the most valuable field in the file — it is what makes the
##               popup a measuring instrument instead of a brag. Concrete: "the player never blocks
##               and wins anyway" beats "the fight is too easy".
##   "teaches"   the one rule this fight puts in the player's hands.
##
## NOTE ON NUMBERS: party is Warrior 36 / Cleric 28 / Sorcerer 22 = 86 HP, 3 energy each. Enemy
## numbers quoted below are the BESTIARY CONTRACT's base values, BEFORE `scale` and before the
## damage softening combat.gd applies (dscale = 1 + (escale-1)*0.65). Quote them as ratios where the
## ratio is the point; the absolute values move with the scale and are not worth chasing here.
const ENCOUNTERS := {

	# ---------------------------------------------------------------- EASY (one idea each)
	# 26 + 22 + 30 = 78 raw HP. Middle of the easy pool, so the middle of the easy scale.
	"shell_line": {
		"name": "The Shell Line",
		"band": "easy",
		"scale": 0.95,
		"enemies": ["shellback", "wolf", "assassin"],
		"boss": "",
		"synergies": ["aegis"],
		"design": {
			"question": "Spend a whole phase killing the turtle that is barely scratching you, or start on the Wolf that howls next turn?",
			"assumes": [
				"A player will not spontaneously attack the thing hurting them least, so the aegis has to be legible enough to make them.",
				"-3 per hit is a big enough number to be felt on a 6-damage Strike: it is a 50% tax, not a rounding error.",
				"The Shellback taking FULL damage itself (aegis protects every OTHER enemy) is the clue that makes it the affordable answer.",
			],
			"rhythm": [
				"turn 1: the player swings at the Wolf, sees 6 become 3, and reads the aegis badge for the first time.",
				"turn 2: commit — either eat the tax and race, or spend the phase on the 26 HP turtle.",
				"turn 3: if the turtle died, every number on the board jumps back up and the fight closes fast.",
				"turn 4-5: cleanup. A player who never killed the turtle is still here and running out of cards.",
			],
			"asserts": [
				"Players who kill the Shellback first finish 1-2 turns sooner than players who ignore it.",
				"The Wolf's Howl lands at most twice; killing the turtle first should not cost so much tempo that Howl lands three times.",
				"Nobody dies here. Easy band: the lesson is tempo, not survival.",
			],
			"fails_if": [
				"Players kill the Shellback last and still win comfortably — then the aegis is not worth its complexity.",
				"Players kill the Shellback first every time WITHOUT reading anything, because it is simply the lowest health bar. That is the old fight wearing a new hat.",
				"The -3 is invisible: the damage number on screen never shows the reduction, so the player learns nothing and just feels weak.",
			],
			"teaches": "Some bodies are worth more dead than their health bar suggests. Read the badge before you pick a target.",
		},
	},

	# 11 + 3x7 = 32 raw HP — the smallest pool in the band, but the highest damage rate.
	#
	# ⚠ THIS BOARD WAS FOUR ADDERS AND THAT WAS LETHAL ON ENEMY PHASE 1. The comment here used to
	# reason that "the rotation means not every fang attacks on every beat, so the practical rate is
	# the ~20 the question quotes" — that premise is simply FALSE for this body: card_db gives
	# pit_adder a `moves` array of exactly ONE entry (Fang), which is its authored identity, so
	# `mvs[move_i % 1]` is Fang forever and every living adder attacks every single phase. At scale
	# 0.90 -> dscale 0.935 a Fang is 5, the Sporeling's chorus adds a flat +2, and `healer_dps`
	# targeting sends every one of them at the same body: 4 x 7 = 28 into a 28 HP Cleric, with no
	# rotation gap to hide in. The rate WAS the ceiling.
	#
	# The lever is the BODY COUNT, not the scale: 0.90 is already BAND_ENVELOPE.easy.scale_min, so
	# validate() rejects anything lower, and the comment's own stated remedy was unavailable. Three
	# adders is 3 x 7 = 21, which is the "roughly 20 a turn" the design question already prints.
	# Still legal: a row of 4 sits inside easy's 2-5, there are 2 distinct types, and pit_adder keeps
	# 3 contiguous copies so `swarm` and the swarm-minions-need-3+ rule both hold.
	# Bottom of the band on purpose: the threat here is arithmetic, and it must not become a one-shot.
	"spore_nest": {
		"name": "The Spore Nest",
		"band": "easy",
		"scale": 0.90,
		"enemies": ["sporeling", "pit_adder", "pit_adder", "pit_adder"],
		"boss": "",
		"synergies": ["chorus", "swarm"],
		"design": {
			"question": "The nest is worth roughly 20 a turn against your 28 HP Cleric — do you kill the mushroom that is adding 2 to every fang, or kill fangs?",
			"assumes": [
				"Three identical bodies read as ONE object, not three, so the board stays inside the 3-4 item tracking budget.",
				"+2 x 3 bodies is obviously worth more than removing one 5-damage body, and a player can do that multiplication in their head at the table.",
				"The adders' healer_dps preference makes the Cleric the visible clock — the player feels the timer without being told about it.",
			],
			"rhythm": [
				"turn 1: the Cleric takes a full round of fangs and the player finds the clock.",
				"turn 2: kill the Sporeling. Every adder label drops by 2 in the same instant — that is the payoff frame.",
				"turn 3-4: mop the adders. 6 HP each at this scale, so this is where the swing cards finally feel good.",
			],
			"asserts": [
				"The Sporeling dies on turn 1 or 2 in the large majority of runs once players have seen the fight once.",
				"Killing the Sporeling visibly changes three labels at once. If only one label moves, chorus is wired wrong.",
				"The Cleric ends the fight wounded but alive.",
			],
			"fails_if": [
				"Players kill adders first and win anyway with HP to spare — the chorus is too small to be a decision.",
				"The Cleric dies on turn 2 before the player gets a second choice. That is not a puzzle, that is a coin flip.",
				"Recipients' intent labels print '5 (+2)' instead of the buffed total '7'. The player should never be doing our arithmetic.",
			],
			"teaches": "Multiply before you subtract: a body that buffs four others is worth more than any one of them.",
		},
	},

	# 55 + 22 = 77 raw HP in only two bodies. Top of the easy scale because two bodies is the lowest
	# tracking load in the whole file and the fight is otherwise short.
	"stonefists": {
		"name": "Stonefist's Count",
		"band": "easy",
		"scale": 1.00,
		"enemies": ["ogre", "wolf"],
		"boss": "",
		"synergies": [],
		"design": {
			"question": "CRUSH lands in two turns on whoever is holding the most Guard — do you stack the Warrior high enough to be chosen, or kill the Wolf that is making CRUSH bigger?",
			"assumes": [
				"Players will discover that `tankiest` sorts by BLOCK first, and that this makes threat something they SET rather than something that happens to them.",
				"A two-beat wind-up (Brace, then CRUSH) is long enough to plan around and short enough to still feel like pressure.",
				"The Wolf's Howl is permanent, so ignoring it has a compounding cost the player can feel by turn 4.",
			],
			"rhythm": [
				"turn 1: Brace. Free turn — the player either builds Guard on the Warrior or opens on the Wolf.",
				"turn 2: CRUSH lands. It hits whoever holds the most Guard, which is exactly whoever the player chose.",
				"turn 3: Brace again, but now with however many Howls have stacked onto the number.",
				"turn 4: second CRUSH. This is where an ignored Wolf collects.",
			],
			"asserts": [
				"CRUSH lands on the Warrior in the clear majority of runs. If it is landing on the Sorcerer, players are not reading the targeting rule.",
				"The Wolf dies before its third Howl in most wins.",
				"Two bodies still produces a real decision. If it does not, the whole 'more bodies = more decisions' assumption behind this file is wrong and we should know that early.",
			],
			"fails_if": [
				"Players never build Guard, eat CRUSH on whoever, and win. Then baiting is a flourish, not a mechanic.",
				"Guard-stacking is strictly correct with no downside — a decision with one right answer is a tutorial, and this is the third easy fight, not the first.",
				"Players cannot tell which dwarf CRUSH is aimed at until it lands. Threat arrows must be live through the wind-up or this fight is a guess.",
			],
			"teaches": "You choose who gets hit. Block is a magnet, not just a shield.",
		},
	},

	# ---------------------------------------------------------------- MED (two ideas each)
	# 28 + 22 + 30 = 80 raw HP. Top of the med scale: three separate bodies, three separate answers.
	"quiet_one": {
		"name": "The Quiet One at the Back",
		"band": "med",
		"scale": 1.25,
		"enemies": ["caster", "wolf", "assassin"],
		"boss": "",
		"synergies": ["chorus", "alone_gate"],
		"design": {
			"question": "The Caster's ward is up NOW and the Assassin's Flurry lands NEXT turn — do you punch through 7 block this turn, or block and eat it?",
			"assumes": [
				"Two telegraphs on different clocks force a real split. Both are visible; neither is affordable.",
				"Block on an enemy is read as a TIMING window (wait it out) rather than a wall (give up), and Ward only lasts until the Caster acts again.",
				"The Caster's +3 chorus makes it the correct target on damage alone, which is what makes hiding behind Ward a genuine defence.",
			],
			"rhythm": [
				"turn 1: read three intents. Ward is up, Flurry is queued, Wolf is chewing on the Sorcerer.",
				"turn 2: the fork. Burst the warded Caster, or block the Flurry and take the Caster next turn when the ward is gone.",
				"turn 3: whichever the player skipped now collects. Both answers are survivable; neither is free.",
				"turn 4-5: the board is down to two bodies and the fight resolves.",
			],
			"asserts": [
				"Both lines (burst-through and block-and-wait) win at roughly comparable rates. If one dominates, this is not a fork.",
				"Killing the Caster drops the Wolf and Assassin labels by 3 each, visibly, in one frame.",
				"The player uses their Class Power here. Two simultaneous telegraphs is exactly the pressure a second lever is for.",
			],
			"fails_if": [
				"Flurry's three small hits are trivially absorbed by any Guard, making the second telegraph fake pressure.",
				"Players ignore Ward entirely and win — then enemy block is decoration.",
				"Killing everything except the Caster becomes the standard line and alone_gate turns a won fight into a loss with no warning. If that shows up, alone_gate needs to be printed on the Caster's intent panel BEFORE it fires, or cut from this board.",
			],
			"teaches": "Enemy block is a clock, not a wall. Read what is on the board this turn against what lands next turn.",
		},
	},

	# 55 + 3x7 = 76 raw HP. Middle of the med scale — the two clocks are the difficulty, not the pool.
	"nest_and_clock": {
		"name": "The Nest and the Clock",
		"band": "med",
		"scale": 1.20,
		"enemies": ["ogre", "pit_adder", "pit_adder", "pit_adder"],
		"boss": "",
		"synergies": ["swarm"],
		"design": {
			"question": "The Ogre's Brace wastes your damage and its CRUSH needs about 20 block on one dwarf, while three adders take your healer apart — which half of the party do you spend?",
			"assumes": [
				"The party genuinely cannot answer both halves at once with 9 total energy, so this is a resource split and not a puzzle with a hidden right answer.",
				"Brace makes the tempo cost of attacking the Ogre visible: hit it on the wrong beat and the damage is simply gone.",
				"Adders bypassing the tank (healer_dps) means Taunt does NOT solve this board, which is the point of pairing them with a tankiest heavy.",
			],
			"rhythm": [
				"turn 1: Ogre Braces. Correct play is to spend everything on adders while its guard is up.",
				"turn 2: CRUSH is coming. Guard the Warrior, or accept the hit and keep killing adders.",
				"turn 3: the surviving half of the board is now the whole fight, and it is the half the player chose to leave.",
				"turn 4-6: grind. The Ogre's 55 HP is the long pole.",
			],
			"asserts": [
				"Players attack adders during Brace and the Ogre during its attack beats. If damage is uniform across beats, the telegraph is not being read.",
				"The Cleric ends below half HP in most runs. The adders should be genuinely frightening.",
				"At least one dwarf is at risk of dropping. Med band should be able to hurt.",
			],
			"fails_if": [
				"One Cleave-shaped card answers the whole adder half, collapsing the split into a single card draw.",
				"Players consistently kill all three adders on turn 1 — then the swarm is not a clock, it is a speed bump, and the body count should go up.",
				"Brace's 5 block is small enough that hitting the Ogre through it is still fine. Then there is no tempo cost and only one clock exists.",
			],
			"teaches": "When two clocks run at once, spend on the one that is faster, not the one that is bigger.",
		},
	},

	# 26 + 4x6 = 50 raw HP, the smallest pool in the band — but the aegis makes every one of those
	# small bodies cost two cards. Bottom of the med scale because the aura is already a multiplier.
	"shell_flock": {
		"name": "Shell and Flock",
		"band": "med",
		"scale": 1.15,
		"enemies": ["shellback", "cave_bat", "cave_bat", "cave_bat", "cave_bat"],
		"boss": "",
		"synergies": ["aegis", "swarm"],
		"design": {
			"question": "The four bodies hurting you cost two cards each; the one you can kill cheaply is barely hurting you at all.",
			"assumes": [
				"A 6 HP bat that takes 3 from a Strike is the clearest possible statement of the aegis — one card should have killed it, and it did not.",
				"Cost-per-kill is a thing players will actually compute once the arithmetic is this blunt.",
				"Four bats hunting lowest_hp converge on the Sorcerer, so the flock has one obvious victim and the player can see the countdown.",
			],
			"rhythm": [
				"turn 1: the player Strikes a bat, sees 3 damage and a survivor, and re-reads the board.",
				"turn 2: kill the Shellback (26 HP, takes full damage) or keep paying double.",
				"turn 3: with the aegis gone every bat is a one-card kill and the flock evaporates in a turn.",
				"turn 4: cleanup, or a much longer fight for anyone who never solved it.",
			],
			"asserts": [
				"Fights where the Shellback dies first are 2+ turns shorter.",
				"The Sorcerer is the target of most bat attacks. If it is not, lowest_hp targeting is not reading correctly.",
				"Multi-hit effects feel visibly bad here. That is intended and is the capability half of the lesson.",
			],
			"fails_if": [
				"Players AoE the four bats down through the aegis and the whole board folds anyway. Then the aura never mattered and the encounter is a swarm fight with extra text.",
				"The Shellback's own 3 damage is so negligible that killing it feels like a free action rather than a spent phase. The tension needs it to cost something.",
				"Players cannot see the -3 applied per hit and conclude their cards are simply weak.",
			],
			"teaches": "Cost-per-kill is the real number, not damage. Sometimes you attack the thing that is not attacking you.",
		},
	},

	# ---------------------------------------------------------------- HARD (capability checks)
	# 11 + 4x6 + 30 = 65 raw HP, the smallest hard pool — and the fastest clock, so the top of the
	# band. Everything on this board wants the 22 HP Sorcerer dead this turn.
	"spore_flight": {
		"name": "The Spore Flight",
		"band": "hard",
		"scale": 1.45,
		"enemies": ["sporeling", "cave_bat", "cave_bat", "cave_bat", "cave_bat", "assassin"],
		"boss": "",
		"synergies": ["chorus", "swarm"],
		"design": {
			"question": "Four bats and a mushroom all want the Sorcerer dead THIS turn — do you kill the thing hitting you, or the thing making it hit harder?",
			"assumes": [
				"Under a one-turn clock the enabler-first rule is HARD to follow, even for a player who knows it. Knowing a rule and being able to afford it are different skills.",
				"4 bats at 4+2 = 6 each is 24 into a 22 HP Sorcerer: the lethality is exact and checkable, not vibes.",
				"The Assassin diving the Cleric means the Sorcerer cannot simply be healed out of the problem.",
			],
			"rhythm": [
				"turn 1: the arithmetic is visible and it is lethal. The Sorcerer dies this turn unless something changes.",
				"turn 1 (the actual decision): kill the Sporeling (bats drop to 4, total 16, survivable) or kill two bats (12 remaining) or block. All three are live.",
				"turn 2: whichever pressure was not answered is now the fight.",
				"turn 3-4: the flock thins fast once the chorus is off; the Assassin is the closer.",
			],
			"asserts": [
				"The Sorcerer survives turn 1 in most runs, but only because the player DID something specific.",
				"Killing the Sporeling is the highest-winrate first action, and it is not the highest-winrate action for a player who is one card short of affording it.",
				"Guard on the Sorcerer is a real competing answer. If blocking is never correct, this fight has one solution.",
			],
			"fails_if": [
				"Players open with the same action every time regardless of hand. Then it is a memorised rule and the hard band has failed at its own job.",
				"The Sorcerer dies on turn 1 in a large fraction of runs — a hand lottery, which is exactly what got the original third hard encounter sent back.",
				"The Assassin is irrelevant and could be removed with no change to outcomes.",
			],
			"teaches": "Knowing the right target is not the same as being able to afford it. Sometimes you buy a turn instead.",
		},
	},

	# 58 + 4x11 = 102 raw HP, the largest non-boss pool. Just under the band top: the Maw's growth is
	# itself an escalating multiplier and it should not compound with the highest scale in the band.
	"gorge": {
		"name": "Gorge",
		"band": "hard",
		"scale": 1.40,
		"enemies": ["the_maw", "bone_wretch", "bone_wretch", "bone_wretch", "bone_wretch"],
		"boss": "",
		"synergies": ["gorge", "swarm"],
		"design": {
			"question": "Four skeletons chip your Warrior, and every one you kill permanently feeds the thing that is actually going to kill you.",
			"assumes": [
				"Players arrive here having learned 'kill the small things first' from the Spore fights. This fight charges 3 permanent damage for that reflex, and the inversion only lands because the reflex was taught first.",
				"The +12 cap makes the price bounded and therefore plannable — an uncapped tax is just a trap.",
				"The wretches' block beat means killing them is already a two-card job, so the corpse cost is the SECOND reason to hesitate, not the only one.",
			],
			"rhythm": [
				"turn 1: read the Maw's gorge counter at 0 and understand the price list before paying anything.",
				"turn 2: kill a wretch, watch the Maw's label go from 8 to 11. This is the frame the whole encounter is built around.",
				"turn 3: commit — race the Maw at 58 HP while four wretches chip, or eat the tax and clear the row first.",
				"turn 4-6: whichever way, the Maw at +12 is the endgame. It should feel like something the player priced in, not an ambush.",
			],
			"asserts": [
				"Players hesitate before the second wretch kill. If corpse count never changes anyone's target, the device is invisible.",
				"Both lines (race the Maw first, or clear and pay the full +12) are winnable.",
				"Players finish the fight able to say what the Maw's damage number is and why.",
			],
			"fails_if": [
				"Killing wretches first is still simply correct — then gorge is flavour and this is a big-body fight.",
				"Racing the Maw first is simply correct — then the wretches are a health bar wall and could be one body.",
				"The corpse counter is not visible on the Maw's portrait. An invisible escalating tax is the single most unfair thing in this document.",
				"The +12 arrives so late that the fight is already decided. Then the price was never really paid.",
			],
			"teaches": "Killing is not free. Ask what a corpse is worth to the other side before you make one.",
		},
	},

	# REPLACEMENT FOR "THE HEXBOUND SHELL" (shellback/wolf/witch), which both hostile reviewers sent
	# back: "the intended line — whittle both, then burst both in one phase — is priced in cards the
	# party does not reliably hold, so it is a hand lottery rather than a plan."
	#
	# THE DIAGNOSIS. That board asked for a specific HAND. A hard encounter is allowed to ask for a
	# specific PLAN; it is not allowed to ask for a specific draw, because the player cannot choose
	# their draw and therefore is not making a decision.
	#
	# THE THIRD LESSON. Spore Flight teaches "kill the small enabler first". Gorge charges you three
	# permanent damage for exactly that reflex. Both are about the FIRST kill. This board is about the
	# LAST one — the only axis of target choice the twelve do not otherwise touch. Every other fight
	# in the file rewards opening correctly; this one punishes TIDYING UP correctly.
	#
	# HOW IT WORKS. The Shellback's aegis makes the 28 HP Caster expensive, so the natural, tidy,
	# obviously-correct order is: turtle first (it takes full damage), then the cheap 11 HP wretches,
	# and leave the awkward warded Caster for last. That order walks the player into alone_gate — the
	# Caster alone resolves every beat as Bolt 12 into whichever dwarf is lowest, with no aegis left
	# to hide behind and no other body to soak a turn. The correct plan is to pay MORE, EARLIER: burst
	# the Caster through the aegis while you still have bodies to spare, and clean up the cheap stuff
	# afterwards when nothing punishes you for taking your time.
	#
	# WHY THE PARTY CAN ACTUALLY EXECUTE IT (this is the part the sent-back board could not answer).
	# The line needs 28 damage through -3 per hit, and the party has THREE independent ways to buy it
	# that do not depend on holding one rare card:
	#   - Mark (Sorcerer, cost 1) is a x1.25 multiplier applied AFTER the flat aegis subtraction, so
	#     it is worth strictly more here than anywhere else in the file. Every Sorcerer starts with it.
	#   - Aura of Valor (+2 per attack, party-wide) and Channel (+3 to the next two attacks) both add
	#     FLAT damage, which is the exact counter to a flat reduction. Two of the three starting decks
	#     carry one of them.
	#   - The Class Powers are a second lever that does not come out of the hand at all: Action Surge
	#     buys the extra energy, Metamagic doubles a spell, Divine Smite is a flat lump.
	# Any ONE of those turns the Caster from a four-card job into a two-card job. The player is never
	# waiting on a specific draw — they are deciding whether to spend the resource they happen to have
	# now, or save it and pay the interest later. That is a plan, not a lottery.
	#
	# 26 + 28 + 3x11 = 87 raw HP. BOTTOM of the hard band on purpose: it is the only board in the file
	# carrying an aegis AND a chorus at once, and two auras is itself a multiplier.
	"last_word": {
		"name": "The Last Word",
		"band": "hard",
		"scale": 1.30,
		"enemies": ["shellback", "caster", "bone_wretch", "bone_wretch", "bone_wretch"],
		"boss": "",
		"synergies": ["aegis", "chorus", "alone_gate", "swarm"],
		"design": {
			"question": "The tidy kill order leaves the Caster for last, and the Caster alone hits harder than the whole board does now — do you pay double to kill it first instead?",
			"assumes": [
				"Players will default to the cheapest-first order, because the previous nine fights rewarded exactly that.",
				"alone_gate is legible BEFORE it fires: Bolt is already in the Caster's visible rotation, so 'this thing's ceiling is 10-12' is knowable from turn 1 without being ambushed.",
				"Flat reduction (aegis -3) and flat addition (Channel/Aura/Smite) are recognisably the same currency, so the counter is discoverable rather than looked up.",
				"Two auras of DIFFERENT kinds on one board is readable. Same-kind stacking would not be, which is why the rule bans it.",
			],
			"rhythm": [
				"turn 1: two badges, five bodies. Wretches hit for 4+3=7 apiece; the board's damage is front-loaded and obvious.",
				"turn 2: the fork. Dump everything into the Caster through the aegis, or start with the turtle like every previous fight taught you.",
				"turn 3: turtle-first players are now cheap and comfortable and have three bodies left, one of which is a problem.",
				"turn 4: the row is clear and the Caster is alone. Every beat is Bolt 12 into the lowest dwarf, and there is nothing left to soak a turn.",
				"turn 5-6: 28 HP of Caster at 12 a turn. Players who killed it on turn 2 finished here comfortably; players who tidied up are counting HP.",
			],
			"asserts": [
				"Killing the Caster in the first two turns has a clearly higher win rate than killing it last, even though it costs more cards.",
				"Players who lose here lose in the LAST two turns, on a board with one enemy left. That failure shape is the whole point and it should be visible in the loss logs.",
				"Mark is played on the Caster far more often here than in any other encounter.",
				"The Shellback is still killed early by most players — it is not a trap, it is a tax. The decision is what you do BEFORE you get around to it.",
			],
			"fails_if": [
				"Players never reach a one-enemy board (they win or lose before the row clears). Then alone_gate never fires and this is just a double-aura fight.",
				"Bolt 12 into a party that has already killed four bodies is not actually dangerous. Then the ending is a formality and the lesson has no teeth — check whether the party is arriving at turn 4 too healthy.",
				"The Caster's intent panel does not warn that being alone changes its behaviour. Then this is an unfair number and the encounter must be cut, not tuned.",
				"Killing the Caster first is affordable with ANY hand — then there is no cost and no decision. It should require spending a multiplier, a Class Power, or a full phase.",
			],
			"teaches": "Kill order has an end as well as a beginning. Ask what the board looks like when only one thing is left.",
		},
	},

	# ---------------------------------------------------------------- ELITE (named set-pieces)
	# 90 + 2x14 = 118 raw HP, but 28 of it is free (the crystals never attack). Smallest effective
	# pool in the band, so the highest scale in the band.
	"overseer_tally": {
		"name": "The Overseer's Tally",
		"band": "elite",
		"scale": 1.85,
		"enemies": ["rune_crystal", "rune_crystal"],
		"boss": "overseer",
		"synergies": ["regalia", "aegis"],
		"design": {
			"question": "Will you spend your whole first turn killing two 14 HP rocks that never attack anyone, while the 90 HP boss stands untouched?",
			"assumes": [
				"A body that deals ZERO damage and is still the most urgent target is the single cleanest statement this game can make about target choice. If any encounter moves the measured 0%, it is this one.",
				"Two crystals rather than one makes it a real spend (a whole phase, ~28 HP through a -3 tax) rather than a single card.",
				"Regalia's scaling — Gaze deals 3 + 2 per crystal to EVERYONE — means the crystals hurt the party without ever attacking, so 'it is not attacking me' is visibly the wrong reason to ignore something.",
			],
			"rhythm": [
				"turn 1: Gaze at 3 + 2 + 2 = 7 to the whole party. The boss takes 3 less per hit. The player's damage on the boss looks pitiful and that is the message.",
				"turn 2: kill the first crystal. Gaze drops to 5. One badge goes out.",
				"turn 3: kill the second. Gaze drops to 3 and the boss's armour is gone. This is the turn the fight actually starts.",
				"turn 4-7: a straight 90 HP boss race at full damage, with the party down whatever the tally cost them.",
			],
			"asserts": [
				"Players who kill both crystals first win substantially more often than players who race the boss.",
				"The Gaze number visibly steps DOWN as crystals die. If it does not move on screen, regalia is invisible and the fight is unfair.",
				"Nobody attacks a crystal by accident. It should be a deliberate, slightly uncomfortable choice.",
				"This encounter shows the largest gap between planner and greedy bots of any board in the file. That gap IS the metric this whole file was written to move.",
			],
			"fails_if": [
				"Racing the boss and ignoring the crystals wins at a similar rate. Then the regalia numbers are too small and this fight has learned nothing from the 0% measurement.",
				"Killing the crystals is so obviously correct that there is no tension — a spend has to hurt to be a decision. If nobody ever hesitates, the crystals need more HP, not less.",
				"14 HP through the crystals' own -3 aegis makes the tally take THREE turns instead of one. Then the fight is a chore, not a choice.",
				"Players cannot tell which enemy the aegis badge belongs to when both crystals carry it.",
			],
			"teaches": "Urgency is not the same as danger. Kill what is making the fight worse, not what is hitting you.",
		},
	},

	# 88 + 28 + 30 = 146 raw HP. Middle of the elite scale: the phase-two flip is the difficulty and
	# it should not have to be paid for twice.
	"molt_king": {
		"name": "The Molt-King",
		"band": "elite",
		"scale": 1.75,
		"enemies": ["caster", "assassin"],
		"boss": "molt_king",
		"synergies": ["molt", "chorus"],
		"design": {
			"question": "The crack meter is nearly at half and phase two's numbers are already in the lookahead — do you finish the shell now, while your Guard is still standing?",
			"assumes": [
				"A threshold the player can SEE approaching turns damage into a decision about WHEN, which is a kind of choice no other board in this file makes.",
				"Showing phase two's beats before the flip is what makes the timing decision fair; hiding them would make it a gotcha.",
				"Players will deliberately hold damage back to control when the flip happens. That behaviour is the entire test.",
				"A boss that is two fights in one body is worth the complexity precisely because it is ONE body — the tracking budget goes to the flanks.",
			],
			"rhythm": [
				"turn 1-2: phase one. Learn the beats, build Guard, watch the crack meter climb, kill or contain the Caster's +3.",
				"turn 3: the meter is near half and the lookahead shows phase two. The decision window opens.",
				"turn 3-4: flip it on YOUR terms with Guard up, or get pushed over the line at the worst moment by your own Cleave.",
				"turn 5-8: phase two at full tilt, with whatever the flanks have left.",
			],
			"asserts": [
				"Players change their card choices in the turn before the flip. If play is identical either side of the threshold, the meter is decoration.",
				"Flipping with Guard up wins measurably more than flipping into an open turn.",
				"Some players deliberately UNDER-damage the boss for a turn. That is the fight working.",
				"The Caster is dead before the flip in most wins — the flanks are a phase-one problem by design.",
			],
			"fails_if": [
				"The flip happens at the same turn regardless of play, because the party's damage curve is that tight. Then there is no timing choice, just a cutscene.",
				"Phase two is not meaningfully different — the same beats with bigger numbers is not two fights, it is one fight with a screen shake.",
				"AoE cards flip the boss accidentally and players feel punished for playing correctly. If that shows up, the meter must exclude splash or the AoE must be warned about.",
				"The crack meter is not readable at a glance from across the board.",
			],
			"teaches": "Some damage is worth holding. Choose the turn the fight changes.",
		},
	},

	# 120 + 11 + 3x6 = 149 raw HP, and Vorn's 12 is the largest single attack number in the set.
	# BOTTOM of the elite band: 120 HP at 2.0 is 240 HP, which is the exact shape the 2026-07-01
	# scaling audit proved unwinnable. The band's ceiling exists for the SMALL bosses.
	"long_swallow": {
		"name": "Vorn, the Long Swallow",
		"band": "elite",
		"scale": 1.60,
		"enemies": ["sporeling", "cave_bat", "cave_bat", "cave_bat"],
		"boss": "vorn",
		"synergies": ["chorus", "swarm"],
		"design": {
			# HOSTILE REVIEW FIX. The reviewer's call was: "two encounters stapled together: turn 1 is
			# the swarm puzzle, turns 2-4 are pure banking. The boss half needs a decision of its own."
			# That was correct about the ORIGINAL flank. The fix is in the flank, not the boss.
			#
			# The banking turns now have a decision because VORN AND THE FLOCK TARGET DIFFERENT DWARVES,
			# and both preferences are already shipped: Vorn is `tankiest` (the Warrior), the bats are
			# `lowest_hp` (whoever Vorn just chewed on, or the 22 HP Sorcerer). So Guard banked on the
			# Warrior does NOTHING about the bats, and cards spent on bats are Guard the Warrior does
			# not have when the swallow lands. Every banking turn is that split, freshly, with the
			# party's HP spread deciding which way it leans.
			#
			# The Sporeling inverts across the fight, which is the part that makes turns 2-4 different
			# from turn 1 rather than a repeat of it. Chorus +2 is worth +2 on ONE swallow that is
			# largely blocked anyway, but +2 on THREE bats that are hunting an unblocked dwarf — 12 a
			# turn becoming 18. The mushroom is a minor nuisance on turn 1 and the biggest number on
			# the board by turn 3. A player who correctly ignored it early has to notice it got worse.
			#
			# HONEST FLAG: this makes the banking turns a real decision at the ENCOUNTER level, which
			# is the lever this file owns. It does NOT give Vorn's own rotation a decision — if the
			# rotation lets a full Guard bank neutralise the swallow every single cycle, the boss half
			# is still a metronome and the fix is a rotation beat that punishes over-banking (the
			# obvious candidate: a beat that hits the party regardless of who holds Guard). That beat
			# is card_db's to author, not this file's, and it is written into fails_if below so the
			# playtest measures it rather than assuming it.
			"question": "Vorn opens by coiling behind block, so the first turn is free — do you break the flock, or bank Guard for the swallow you can already see coming?",
			"assumes": [
				"A free opening turn against a visible four-beat metronome is the cleanest banking decision the game can pose.",
				"Vorn hitting the tankiest and the bats hitting the lowest means Guard can only ever answer HALF the board, so banking is never simply correct.",
				"The Sporeling's value INVERTS over the fight (+2 on one blocked swallow early, +2 x 3 bats on an open dwarf later) and players will notice the inversion by turn 3.",
				"A perfectly telegraphed four-beat boss is more frightening than a random one, not less, because the player cannot blame the dice.",
			],
			"rhythm": [
				"turn 1: Vorn coils behind block. Free turn. Break the flock, or bank.",
				"turn 2: the swallow lands on the Warrior. Guard soaks it; the bats are eating the Sorcerer meanwhile and the Sporeling is making them worse.",
				"turn 3: the split, now with real HP pressure. Bank again for the next swallow, or turn and clear the flock before it kills the dwarf Vorn did not touch.",
				"turn 4: the metronome comes back round. By now the player should be calling the beat out loud before it happens.",
				"turn 5-9: 120 HP of Vorn. Long, and it should feel long — this is the last fight in the file.",
			],
			"asserts": [
				"Turn 1 splits players roughly down the middle between banking and clearing. If it does not, one of the two is dominant and the fight is decided before it starts.",
				"The Sorcerer, not the Warrior, is the dwarf most likely to die here. The boss picks the target; the flock does the killing.",
				"Players kill the Sporeling LATER here than in any other board it appears on, and are right to.",
				"By turn 4 players are pre-announcing Vorn's next beat. Perfect information is the design.",
			],
			"fails_if": [
				"Turns 2-4 look identical: bank, block, repeat. That is the original review finding surviving the fix, and it means Vorn's rotation needs a beat that punishes over-banking.",
				"Guard banked on the Warrior somehow also answers the bats, collapsing the split. Check the targeting preferences are actually resolving to different dwarves.",
				"Players clear the flock on turn 1 and the remaining eight turns are a pure damage race with no decisions at all.",
				"240 HP after scaling makes the fight a twelve-turn slog that players quit rather than lose. Watch the abandon rate, not just the win rate.",
				"The four-beat rotation is not visible far enough ahead to bank against. The whole encounter is built on the lookahead.",
			],
			"teaches": "Perfect information is a resource. Spend the turn the boss gives you on the half of the board it is not covering.",
		},
	},
}

# ================================================================ Lookup API
##
## Every func below is total: a bad tier, a bad band or an unknown id returns something safe. These
## are called from the middle of an expedition, and a crash there costs the player a whole run.

## Hexcrawl tier + tile danger -> band id. NEVER returns "" or an unknown band: the caller uses this
## to roll a fight, so there is no useful failure mode. An unrecognised tier is treated as "med" (the
## middle rung) and danger is clamped to 1..3, matching overworld.gd's own clamp at hex-generation
## time. See TIER_RUNG / RUNG_BAND for the full 3x3 -> 4-band mapping and why it adds rather than
## multiplies.
static func band_for(tier: String, danger: int) -> String:
	var rung: int = int(TIER_RUNG.get(tier, 1)) + clampi(danger, 1, 3) - 1
	return String(RUNG_BAND[clampi(rung, 0, RUNG_BAND.size() - 1)])

## Roll one encounter out of a band. Returns the encounter dict WITH its own id under "id", or {} if
## the band is unknown or empty — the caller (overworld.gd) already has a fallback path to
## Db.ENCOUNTER_POOLS for exactly this, so {} is a supported answer and not an error.
static func roll(band: String) -> Dictionary:
	var ids: Array = BANDS.get(band, [])
	if ids.is_empty():
		return {}
	return get_enc(String(ids[randi() % ids.size()]))

## Fetch one encounter by id, with "id" filled in. {} if unknown.
##
## The returned dict is a SHALLOW duplicate, because ENCOUNTERS is a const and const containers are
## read-only in Godot 4 — writing "id" straight into the table entry would be a runtime error. Shallow
## is deliberate: the nested arrays and the design block stay read-only references, so a caller that
## tries to mutate a rhythm line fails loudly instead of quietly editing the design for the rest of
## the session. Nothing downstream needs to write into them.
static func get_enc(id: String) -> Dictionary:
	if not ENCOUNTERS.has(id):
		return {}
	var out: Dictionary = (ENCOUNTERS[id] as Dictionary).duplicate()
	out["id"] = id
	return out

## The full body list in SLOT ORDER, boss first.
##
## combat.gd builds its board straight from request["enemies"], so a boss only exists if it is IN that
## array — "elevated" is a presentation fact, not a separate field the engine reads. Slot 0 is the
## boss's wire address and it is stable, which is what lets the UI raise slot 0 without any new data
## crossing the wire.
static func bodies(enc: Dictionary) -> Array:
	var row: Array = (enc.get("enemies", []) as Array)
	var boss: String = String(enc.get("boss", ""))
	if boss == "":
		return row.duplicate()
	var out: Array = [boss]
	out.append_array(row)
	return out

## Fold an encounter's `scale` into the hexcrawl's additive threat term.
##
## ⚠ READ THIS BEFORE WIRING IT UP. The encounter scale MULTIPLIES, and multiplying threat factors is
## the exact mistake the 2026-07-01 scaling audit was written to undo: the old tier x mod x danger
## composite reached 2.688 and measured 0% winnable across a 96-cell Monte Carlo, which is why
## overworld.gd composes its own factors ADDITIVELY today. A multiplying band scale re-introduces the
## same growth curve at one remove — elite 2.0 on top of a danger-3 tile is 2.84, and Vorn at 2.84 is
## a 340 HP body. So the product is CLAMPED here, in one place, rather than left for each of the two
## call sites in overworld.gd to remember.
##
## SCALE_CEILING (2.2) is the audit's worst REACHABLE cell (2.12) rounded up. Above it is unsimmed
## territory where the sim already found a hard wall. None of this has been through dorf_sim.py yet
## and the ceiling is a first guess made from an old measurement — treat it as the first number to
## sim, alongside PARTY_STEP.
static func composite_scale(band_scale: float, additive_threat: float) -> float:
	return minf(band_scale * additive_threat, SCALE_CEILING)

# ================================================================ Executable sanity rules
##
## validate() turns the design rules into code so they cannot rot into comments nobody re-reads. It
## returns a list of human-readable violation strings; an empty array means the table is clean.
##
## TWO PLACES THE LITERAL RULE WAS REFINED, both deliberately, both because the literal reading
## contradicts a composition the spec fixes. Written down here rather than silently coded around:
##
## (1) "Minions only ever appear in identical blocks of 3+, contiguous."
##     The Sporeling appears alone on three boards and the Overseer's regalia is exactly TWO crystals.
##     Both are minion-tier. The rule's purpose is to stop the player having to count similar-looking
##     bodies, and it is aimed at SWARM minions — the interchangeable ones (bat, adder, wretch) whose
##     whole job is to read as a single object. An aura-carrying minion is not a swarm member; it is
##     the anchor the swarm is built around, it has its own badge, and it is individually meaningful.
##     So: swarm minions (no aura) need 3+; ANCHOR minions (carrying an aura) may appear 1-2 times.
##     Both must still be CONTIGUOUS, because contiguity is what makes duplicates read as one block.
##
## (2) "Exactly one aura source of each kind per board."
##     The stated reason is that a second invisible source teaches the player the aura is unreliable —
##     kill the Shellback, the -3 stays, because the Warden also had it. That failure needs two
##     DIFFERENT bodies. Two identical Rune Crystals cannot cause it: they look the same, they carry
##     the same badge, and "kill both crystals" is precisely the regalia lesson. So the rule is
##     enforced as at most one DISTINCT aura source id per kind. Shellback + Warden is still banned.
##
## DEPENDENCY NOTE: aura and tier are read from Db.ENEMIES, which is the single source of truth for
## both (the contract is explicit that synergies are DATA, never an id list in code — so this file
## deliberately does NOT keep a local copy that could drift). An id missing from Db.ENEMIES is
## reported as its own violation and the checks that need its fields are skipped for that body, so
## validate() still returns something useful while the bestiary is mid-landing.

const AURA_KINDS := ["aegis", "chorus"]
const ROW_DISTINCT_MAX := 3    # the tracking ceiling: effortless enumeration caps at 3-4 items
const ENEMY_MAX := 6           # combat.gd's ENEMY_MAX. It CLAMPS and silently drops the overflow.

static func _enemy(id: String) -> Dictionary:
	return (Db.ENEMIES.get(id, {}) as Dictionary)

static func _aura_kind(id: String) -> String:
	var a: Dictionary = (_enemy(id).get("aura", {}) as Dictionary)
	return String(a.get("kind", ""))

## Is every synergy this board CLAIMS actually enabled by the bodies on it? This is what stops
## `synergies` becoming decorative text — the same rot that made combat.gd's crew_results["cls"] dead
## data for a month because nothing ever read it.
static func _synergy_enabled(sy: String, row: Array, boss: String) -> bool:
	var all: Array = row.duplicate()
	if boss != "":
		all.append(boss)
	match sy:
		"aegis", "chorus":
			for id: Variant in all:
				if _aura_kind(String(id)) == sy:
					return true
			return false
		"alone_gate":
			return all.has("caster")
		"twin_bond":
			return all.has("wolf") and all.has("witch")
		"gorge":
			# needs the Maw AND at least one other body, or there is never a corpse to eat
			return all.has("the_maw") and all.size() >= 2
		"regalia":
			return boss == "overseer" and row.has("rune_crystal")
		"molt":
			return all.has("molt_king")
		"swarm":
			for id: Variant in all:
				if all.count(id) >= 3:
					return true
			return false
		_:
			return false

## Do the occurrences of `id` in `row` sit next to each other? Duplicates only read as ONE object if
## they are adjacent; scattered copies of the same body are the worst case for board legibility.
static func _contiguous(row: Array, id: String) -> bool:
	var first := -1
	var last := -1
	for i: int in range(row.size()):
		if String(row[i]) == id:
			if first < 0:
				first = i
			last = i
	if first < 0:
		return true
	return (last - first + 1) == row.count(id)

## Check the whole table against the sanity rules. Returns a list of violations (empty = clean).
static func validate() -> Array:
	var out: Array = []

	# --- band bookkeeping: BANDS and ENCOUNTERS must agree in BOTH directions ---
	var listed: Dictionary = {}
	for band: Variant in BANDS.keys():
		if not BAND_ENVELOPE.has(band):
			out.append("band '%s' has no BAND_ENVELOPE entry" % band)
		for id: Variant in (BANDS[band] as Array):
			if listed.has(id):
				out.append("encounter '%s' is listed in more than one band" % id)
			listed[id] = band
			if not ENCOUNTERS.has(id):
				out.append("band '%s' names missing encounter '%s'" % [band, id])
	for id: Variant in ENCOUNTERS.keys():
		if not listed.has(id):
			out.append("encounter '%s' is in no band — dead content, roll() can never reach it" % id)
		elif String(listed[id]) != String((ENCOUNTERS[id] as Dictionary).get("band", "")):
			out.append("encounter '%s' band field disagrees with BANDS" % id)

	# --- per-encounter rules ---
	for eid: Variant in ENCOUNTERS.keys():
		var id := String(eid)
		var e: Dictionary = ENCOUNTERS[id]
		var row: Array = (e.get("enemies", []) as Array)
		var boss := String(e.get("boss", ""))
		var band := String(e.get("band", ""))
		var env: Dictionary = (BAND_ENVELOPE.get(band, {}) as Dictionary)

		# every id must actually exist in the bestiary
		var all: Array = bodies(e)
		for bid: Variant in all:
			if _enemy(String(bid)).is_empty():
				out.append("%s: unknown enemy id '%s' (not in Db.ENEMIES)" % [id, bid])

		# scale + row size inside the band envelope
		if env.is_empty():
			out.append("%s: unknown band '%s'" % [id, band])
		else:
			var sc: float = float(e.get("scale", 0.0))
			if sc < float(env["scale_min"]) - 0.0001 or sc > float(env["scale_max"]) + 0.0001:
				out.append("%s: scale %.2f outside band '%s' range %.2f-%.2f" % [id, sc, band, float(env["scale_min"]), float(env["scale_max"])])
			if row.size() < int(env["row_min"]) or row.size() > int(env["row_max"]):
				out.append("%s: row of %d outside band '%s' range %d-%d" % [id, row.size(), band, int(env["row_min"]), int(env["row_max"])])

		# the tracking ceiling: at most 3 distinct types in the ROW. A 4th shape is only affordable
		# when it is the elevated boss, which is why the boss is counted separately.
		var distinct: Dictionary = {}
		for bid: Variant in row:
			distinct[bid] = true
		if distinct.size() > ROW_DISTINCT_MAX:
			out.append("%s: %d distinct types in the row (max %d)" % [id, distinct.size(), ROW_DISTINCT_MAX])
		if boss != "" and row.has(boss):
			out.append("%s: boss '%s' also appears in the row — then it is not a 4th shape, it is a duplicate" % [id, boss])
		if boss != "" and String(_enemy(boss).get("tier", "boss")) != "boss":
			out.append("%s: '%s' is in the boss slot but is not tier 'boss'" % [id, boss])

		# ⚠ ENEMY_MAX is an ENGINE ceiling and the boss is NOT exempt from it. The "boss is exempt"
		# rule is a DESIGN ceiling about how many bodies a player can track; combat.gd clamps the
		# request array to 6 and silently drops the overflow, so boss + row > 6 loses a body with no
		# error anywhere. Both are checked, separately, because they fail for different reasons.
		if all.size() > ENEMY_MAX:
			out.append("%s: %d total bodies exceeds combat.gd ENEMY_MAX %d — the overflow is SILENTLY DROPPED" % [id, all.size(), ENEMY_MAX])

		# the two red demon faces are the worst pair in the set — never on one board
		if all.has("brute") and all.has("ogre"):
			out.append("%s: Brute 👹 and Ogre 👺 on the same board" % id)

		# minion blocks (see the refinement note above for the anchor exemption)
		for did: Variant in distinct.keys():
			var d := String(did)
			if not _contiguous(row, d):
				out.append("%s: copies of '%s' are not contiguous — duplicates only read as one block when adjacent" % [id, d])
			var ed: Dictionary = _enemy(d)
			if ed.is_empty():
				continue   # already reported as unknown; its tier/aura cannot be checked
			var n: int = row.count(d)
			if String(ed.get("tier", "")) == "minion" and _aura_kind(d) == "" and n < 3:
				out.append("%s: swarm minion '%s' appears %d time(s) — swarm minions need blocks of 3+" % [id, d, n])
			if String(ed.get("tier", "")) == "minion" and _aura_kind(d) != "" and n > 2:
				out.append("%s: anchor minion '%s' appears %d times — an anchor is 1-2 bodies, not a swarm" % [id, d, n])

		# at most ONE DISTINCT aura source per kind (aegis does not stack; a second, differently
		# shaped source teaches the player the aura is unreliable)
		for kind: Variant in AURA_KINDS:
			var srcs: Dictionary = {}
			for bid: Variant in all:
				if _aura_kind(String(bid)) == String(kind):
					srcs[bid] = true
			if srcs.size() > 1:
				out.append("%s: %d distinct '%s' sources %s — that kind allows one" % [id, srcs.size(), kind, str(srcs.keys())])

		# declared synergies must be REAL
		var sys: Array = (e.get("synergies", []) as Array)
		for sy: Variant in sys:
			if not _synergy_enabled(String(sy), row, boss):
				out.append("%s: declares synergy '%s' but no body on the board enables it" % [id, sy])

		# "every board must contain at least one body that is NOT the correct first kill."
		# Executable form: the board has to offer a SECOND axis beside health bars — either a declared
		# device, or at least two different targeting preferences (so the player cannot solve the whole
		# board by protecting one dwarf). Three differently sized health bars with one shared pref is
		# exactly the fight that measured 0% and it is what this check exists to catch.
		var prefs: Dictionary = {}
		for bid: Variant in all:
			var p := String(_enemy(String(bid)).get("pref", ""))
			if p != "":
				prefs[p] = true
		if sys.is_empty() and prefs.size() < 2:
			out.append("%s: no declared device and only one targeting preference — every body is just a health bar" % id)

		# design block completeness — the popup reads these and an empty field is a silent blank panel
		var dsn: Dictionary = (e.get("design", {}) as Dictionary)
		for key: Variant in ["question", "assumes", "rhythm", "asserts", "fails_if", "teaches"]:
			if not dsn.has(key):
				out.append("%s: design block missing '%s'" % [id, key])
				continue
			var v: Variant = dsn[key]
			if v is Array and (v as Array).is_empty():
				out.append("%s: design['%s'] is empty" % [id, key])
			elif v is String and String(v).strip_edges() == "":
				out.append("%s: design['%s'] is blank" % [id, key])

	return out

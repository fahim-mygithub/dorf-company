# Overworld MVP — Assumptions & Test Spec
### Dorf Company — the fee-clock economic layer

This doc does two things: (1) names the **design assumptions** the overworld loop is betting on, and (2) specs the **smallest build that tests them**. The combat layer is already validated in Godot; this MVP deliberately does *not* rebuild combat — it wraps a stub around it to test the meta-loop only.

**The one-sentence bet:** *"Running a monster-company against a monthly fee clock — choosing which jobs to take and which crew to risk — is a tense, replayable decision loop."*

If that sentence is true, the game has a spine most deckbuilders don't. Everything below exists to find out if it's true as cheaply as possible.

---

## PART 1 — THE ASSUMPTIONS LEDGER

Every assumption is phrased so a playtest can prove it **false**. That's the point — we're hunting for the ones that break, not confirming the ones we like. Ranked by risk: the top ones, if false, kill the design; the bottom ones are tuning.

### Core assumptions (if false, rethink the whole layer)

**A1 — The fee clock creates productive tension, not just stress.**
*Bet:* A recurring "make rent" deadline makes job-selection feel meaningful and urgent.
*Fails if:* Players feel harassed/anxious rather than engaged, OR the fee is trivially easy to make and creates no pressure at all. (Both failure directions matter — too soft is as bad as too harsh.)
*How we'll know:* Do players deliberate over which contracts to take, or auto-pick the highest number? Do they ever *sweat* a fee payment?

**A2 — "Which job do I take" is a genuinely interesting choice.**
*Bet:* A short menu of contracts with different payout / danger / duration tradeoffs produces real deliberation.
*Fails if:* There's a dominant pick every time (highest payout always wins), OR the choices feel arbitrary (no basis to prefer one).
*How we'll know:* Track what players pick and whether it varies with their situation (roster health, treasury, fee timing).

**A3 — Crew selection matters and creates attachment.**
*Bet:* Choosing *which dwarves* to send — and risking them — makes the roster feel like yours and the choice feel weighty.
*Fails if:* Players always send the same "best" crew, OR they feel nothing when a dwarf is lost/wounded.
*How we'll know:* Do crew choices vary by contract? Is there hesitation before sending a favorite into danger?

**A4 — The overworld and combat reinforce each other.**
*Bet:* Wrapping fights in an economic frame makes *both* better — fights carry stakes (this payout, these dwarves), and the economy is driven by fight outcomes.
*Fails if:* The overworld feels like a menu you click through to get to the "real game" (combat), OR combat feels like an interruption to the management game.
*How we'll know:* Where do players say the fun is? If they want to skip either layer, the layers aren't reinforcing.

### Secondary assumptions (if false, tune — don't rethink)

**A5 — Attrition is motivating, not just punishing.** Wounded/lost dwarves raise stakes without feeling unfair. (Watch for: bad-luck losses that feel undeserved.)

**A6 — Roster-building is a satisfying progression.** Recruiting/leveling dwarves over months feels like growth. (Watch for: roster feels disposable, or growth too slow to notice.)

**A7 — Runs stay varied.** Different contracts + crew combos generate distinct situations across several months. (Watch for: month 4 feels identical to month 1.)

**A8 — The economy is legible.** Players can reason about income vs. fees well enough to plan. (Watch for: players can't tell if they're winning or losing until they suddenly bankrupt.)

### Explicitly OUT of scope for this MVP
Named to prevent scope creep — these are real features we are *deliberately not testing yet*:
- Territory/hex map visuals (contracts are a text list, not map pins)
- The branching dungeon-delve (combat is stubbed — see Part 2)
- Dwarf gear/equipment systems
- Deep leveling trees
- Multiple regions, acts, or a final boss
- Art, audio, polish

---

## PART 2 — THE MVP SPEC

The MVP is a **text-and-buttons management loop wrapped around a stubbed fight.** No map art, no dungeon branching. If the loop is fun as a spreadsheet, it'll be fun with art. If it's boring as a spreadsheet, art won't save it.

### The core loop (one "month")

```
[Company screen: treasury, fee due, roster]
        ↓
[Contract board: pick 1 of ~3 jobs]
        ↓
[Crew select: assign dwarves to the job]
        ↓
[Resolve the campaign  → (stubbed or real combat)]
        ↓
[Outcome: payout + dwarf status changes (wounded/lost)]
        ↓
[Advance clock → FEE DUE? pay or go bankrupt]
        ↓
   (loop to next month)
```

The whole game in the MVP is: *survive N months without going bankrupt.* That's the testable win condition.

### Visual legibility is a requirement, not polish

The tension we're testing (A1–A3) is *felt*, not calculated. A row of raw numbers forces the player to do arithmetic; a good visual makes the tradeoff land in the gut *before* they consciously reason it. So the MVP is not a button-spreadsheet — it's a **greybox built in Godot (via the MCP pipeline) with an emoji + color visual grammar** that reads at a glance. Graphics don't need to be good; the *decision* needs to be understood in under a second.

**The at-a-glance grammar (use consistently everywhere):**
| Meaning | Visual |
|---|---|
| Treasury / gold | 💰 + number, green when healthy, red when below next fee |
| Fee clock | 📅 + a row of pips ●●○ for months remaining; pips turn 🔴 as it nears |
| Danger: Low / Med / High | 🟢 / 🟡 / 🔴 (skull count 💀 / 💀💀 / 💀💀💀 reinforces) |
| Payout size | 💰 stack height or coin count — bigger = more coins shown |
| Warrior / Cleric / Sorcerer | 🛡️ / ✨ / 🔮 (consistent with combat role colors: grey / gold / violet) |
| Dwarf status: Ready / Wounded / Lost | 🟢 face / 🩹 face / ⚰️ greyed-out |
| Crew-vs-danger odds | a simple bar or 🟢🟢🟡🔴 gauge, not a percentage |

The rule: **every number also has a non-numeric visual cue** (color, count, icon size) so the player can read the board pre-verbally. Numbers are for confirmation; the visual is for the snap judgment.

### Screen 1 — Company Dashboard
The home base. Shows the state the player reasons about — as visuals first, numbers second.
| Element | Visual treatment |
|---|---|
| **Treasury** | 💰 large, color-coded green/amber/red vs. the next fee. The player should *see* "I'm fine / I'm sweating" without reading the digits. |
| **Fee due** | 📅 with month-pips ●●○; the closer the fee, the more pips glow red. A menacing landlord emoji 👹 can anchor it thematically (the demon-lord's own overhead). |
| **Roster** | A row of dwarf tokens: class icon (🛡️/✨/🔮) + status face (🟢/🩹/⚰️). Wounded dwarves visibly greyed with a healing pip count. Reads as "who can I send" at a glance. |
| **Action** | Big "📜 View Contracts" — one clear forward path. |

### Screen 2 — Contract Board
The A2 test. Three job "cards" laid side by side, each readable as a *shape* before you read a word.
| Contract field | Visual treatment |
|---|---|
| **Name / flavor** | Short title + a location emoji (🕳️ warren, 🏰 keep, 🌲 marches) |
| **Payout** | A visible coin stack 💰💰💰 — height = reward, no need to read the number |
| **Danger** | 🟢/🟡/🔴 banner + skulls 💀 — the card's dominant color IS its danger |
| **Crew size** | N empty slots shown (◻️◻️◻️) — you see how much roster it ties up |
| **Duration** | Month-pips 📅● — how much clock it eats |

Because each card's *color and coin-height* encode the core tradeoff, the player compares three cards visually — "the red one pays huge but eats my crew and two months" — in one glance. That glance-comparison IS the A2 test. Offer **3 contracts**, pick **1**.

### Screen 3 — Crew Select
The A3 test. Drag/tap dwarves from the roster into the contract's crew slots.
- Roster shown as tokens (🛡️/✨/🔮 + 🟢/🩹). Only 🟢 Ready dwarves are draggable; wounded ones sit greyed with their recovery countdown.
- As you fill slots, a **live odds gauge** updates (🟢🟢🟡 → shifts toward 🔴 for a weak crew vs. high danger). No percentages — a colored bar the player reads instinctively.
- The emotional beat we're testing: seeing your favorite 🔮 Sorcerer's face slot into a 🔴 High-danger job should give a visible "…do I really want to risk them?" pause. That pause is A3 working.

### Screen 4 — Campaign Resolution (the stub)
**Key MVP shortcut.** Combat is already validated, so we do NOT rebuild the dungeon here. But even the stub gets *visual* resolution — a silent spreadsheet result kills the feel.

- **Stub (fastest, build first):** Resolve as a **dice-roll: crew strength vs. danger.** But *show it* — the crew tokens 🛡️✨🔮 advance against the danger, a die rolls 🎲, result flashes ✅ success / ❌ failure, then attrition plays out token-by-token (a dwarf takes a hit 🩹, or rarely ⚰️). Two seconds of animation, all emoji + tween, no art. This tests the economic loop in isolation *with enough feedback to feel the outcome.* You can still play ~12 months in a few minutes.
- **Real hook (once stub validates):** Swap the dice-roll for your actual Godot combat — the chosen crew *is* the party, danger sets the enemy composition. Now A4 becomes testable for real.

Building the visual stub first is the discipline: it isolates A1/A2/A3 from full combat while still delivering the felt feedback that makes those assumptions testable.

### Screen 5 — Outcome & Clock
Each step is a *visible beat*, not a log line — the player should watch consequences land.
| Step | Visual treatment |
|---|---|
| **Payout** | Coins fly into the 💰 treasury, number ticks up — the reward is seen, not just added. |
| **Attrition** | Surviving crew return 🟢; wounded flip to 🩹 with a recovery timer; a loss ⚰️ gets a beat of weight (brief pause, greyed token). |
| **Advance clock** | Month-pips 📅 tick forward visibly — the fee looming closer is *shown* creeping up. |
| **Fee check** | Fee due: coins drain from 💰 (turning red if it hurts). If treasury < fee → 💥 **bankrupt → run over**, a clear visual end state. |

The drain-the-treasury animation at fee time is doing real work: *seeing* your gold pour out to the landlord 👹 is what makes the fee clock viscerally tense (A1) in a way a decremented number never will.

---

## PART 3 — STARTING NUMBERS (to be tuned by play)

Deliberately rough — these exist to be wrong and get corrected. The point is a *starting economy* legible enough to reason about (assumption A8).

| Value | Start | Notes |
|---|---|---|
| Starting treasury | 100g | ~2 months of buffer |
| Monthly fee | 40g | Due every 2 months (so 20g/month effective) |
| Fee escalation | +10g each time it's paid | Creates the difficulty ramp / eventual failure |
| Starting roster | 4 dwarves | Enough to run a 3-crew job with 1 in reserve |
| Contract payout (Low danger) | 30–40g | Barely beats rent — the "safe" option |
| Contract payout (Med) | 60–70g | Clears a fee cycle with margin |
| Contract payout (High) | 100–120g | Multiple months of runway — but real attrition risk |
| Contract duration | 1–2 months | Longer jobs pay more but eat the clock |
| Wound recovery | 2 months | A wounded star is a medium-term loss |
| Loss chance (High danger) | ~10–15% per dwarf | Rare enough to feel like bad luck is survivable |

**Tuning target:** a careful player should make rent comfortably for ~4–5 months, then feel the escalating fee squeeze force greedier jobs — which raises attrition — which strains the roster. The *death spiral should feel like the consequence of decisions*, not a dice betrayal. Bankruptcy around month 6–10 for a learning player is a healthy first target.

---

## PART 4 — THE TEST PLAN

Build order (each step playable before the next), built as a **Godot greybox with the emoji/color grammar** — via the MCP pipeline, same as combat:
1. **Screens 1, 2, 5 + the visual dice stub** — the bare economic loop, but *visible*: color-coded treasury, month-pips, three contract cards you compare at a glance, animated resolution and fee-drain. Play 10 months. *Does the fee clock create felt tension? Can you read a contract's tradeoff in one glance? (A1, A2, A8)*
2. **Screen 3 crew select + attrition** — add roster stakes with draggable dwarf tokens and the live odds gauge. *Does slotting a favorite into a red job give you pause? (A3, A5, A6)*
3. **Play 3–5 full "runs" to bankruptcy.** *Does it stay varied and tense across months? (A7)*
4. **Only if 1–3 feel good:** hook in real Godot combat at Screen 4. *Do the layers reinforce? (A4)*

**Why Godot, not a paper/text prototype here:** the assumptions are about *felt* tension, and feel is carried by the visual beats — the treasury draining red at fee time, a favorite's face sliding into a 🔴 slot. A spreadsheet can validate the *economy's math* but not whether the decision *lands*. The emoji grammar gets you that felt layer at near-zero art cost.

**Kill criteria (be honest):** If after step 1 the contract choice is always obvious and the fee never sweats, stop and fix the economy before building anything else. If after step 2 nobody cares about their dwarves, the attrition/roster fantasy isn't landing and needs rethinking. Better to learn that in a text prototype than after building the territory map.

**Success signal:** A playtester, unprompted, agonizes over a contract-and-crew decision — "if I send my good crew I'll make rent easy, but if I lose a dwarf on this I'm cooked next month..." That sentence means A1–A3 are all firing at once. That's the whole bet paying off.

---

## Implementation note (2026-06-30, superseded details)

The Step-1 build (`scripts/overworld/overworld.gd`) adopts the built combat party's role
emoji — Warrior 🛡️ / **Cleric ⛑️** / **Sorcerer 🧙** (read from `card_db.gd`) — instead of
the grammar table's ✨ / 🔮. Reason: single source of truth with the combat party (A4), and
🔮 already denotes the Caster *enemy* in combat. All load-bearing signals (danger, treasury
band, odds, fee pips, coin stacks, crew slots) are rendered as tinted `ColorRect`s, not
glyphs, so they survive any web-font emoji gap. See `2026-06-30-overworld-mvp-plan.md` for
the validated, buildable plan.

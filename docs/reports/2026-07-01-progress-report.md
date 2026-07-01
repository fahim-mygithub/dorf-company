# Dorf Company — Progress Report

**Date:** 2026-07-01
**Purpose:** Status snapshot to ground planning of new features.
**Companion doc:** `2026-07-01-implementation-report.md` (architecture + how to extend).

---

## 1. What the project is

**Dorf Company** ("Demon Lord MBA") is a roguelike deckbuilder in **Godot 4.7** (gl_compatibility,
portrait **720×1280**, emoji/greybox presentation, deployed to **GitHub Pages** for mobile playtest).
You run a monster-company: summon a demon lord, hand it an MBA, and manage a party of dwarves against
a monthly rent clock.

The game is built **all-in-code** (each mode is a bare `Control` scene whose script constructs the
entire UI) and driven agentically through the **godot-mcp-pro** MCP loop (build → `play_scene` →
screenshot / `execute_game_script` → adjust).

## 2. Three modes, three live URLs

The repo ships **three self-contained combat/experience modes** from one project. CI sed-patches
`run/main_scene` per export; the committed root main_scene stays combat.

| URL | Mode | Scene / Script | Status |
|---|---|---|---|
| `/` | **Combat** — "Slice 2 party puzzle" (StS-style tactical fight) | `scenes/combat/combat.tscn` · `combat.gd` | Stable, validated |
| `/grid/` | **Grid** — Fire-Emblem experiment (5×5 movement + ranged cards) | `scenes/combat/grid_combat.tscn` · `grid_combat.gd` | Parked experiment |
| `/overworld/` | **Overworld** — the fee-clock economic layer, now **meshed with real combat** | `scenes/overworld/overworld.tscn` · `overworld.gd` | **Active development** |

Pages site: **https://fahim-mygithub.github.io/dorf-company/** (root = combat, `/overworld/` = current game).

## 3. The current game: the meshed Overworld loop

The overworld is the live focus. It began as an MVP with a **dice-roll combat stub**, then was
**meshed with the real combat scene** over Phases 0–5 so the two validated layers became **one
recombining decision loop**. The core design bet (spec assumption **A4**): *wrapping fights in an
economic frame makes both better.*

**The loop today:**
```
Company Dashboard (treasury · monthly rent clock · 4-dwarf roster w/ HP · 3 campaign slots)
   → Contract Board (3 jobs: Low dice lifeline / Med+High REAL fights, ~45% carry a modifier)
   → Crew Select (pick WHICH 3 ready dwarves — HP, decks, role coverage matter)
   → REAL COMBAT (the validated Slice-2 fight; crew = party carrying persistent decks + HP;
                   enemies scaled by danger tier × modifier)
   → Outcome (payout · carried HP · wounds; a WON fight → "Spoils of War": grow a dwarf's deck)
   → after up to 3 campaigns the month ends → rent + escalation + crew mends → repeat
Survive WIN_MONTH (8) months solvent → victory.  Miss rent → bankrupt.  No fieldable dwarves → disband.
```

## 4. Feature inventory (all built + verified in-editor)

**Overworld / meta-layer**
- ✅ Company dashboard: color-banded treasury, monthly rent clock (escalating), roster tokens with HP bars, "jobs left" pips.
- ✅ Contract board: 3 tiers with emoji/color glance-grammar (danger banner, coin-stack payout, crew slots).
- ✅ **3 campaigns per month**: campaigns don't tick the clock; run up to 3, then month-end (auto or "End Month" button) triggers rent.
- ✅ **Crew select**: pick which ready dwarves crew a fight; role-coverage warnings, per-dwarf HP + deck size.
- ✅ **Carried HP**: dwarves persist damage across fights, enter hurt, mend `HP_REGEN_PER_MONTH` (6)/month; downed → benched, return at full HP.
- ✅ **Card-reward engine (Phase 4)**: per-dwarf growable decks; won fight → 1-of-3 chassis card → chosen dwarf's deck grows.
- ✅ **Contract modifiers (Phase 5)**: Elite 👑 / Lucrative 💰 / Grim 💀 reshape payout × and enemy-scale ×.
- ✅ Win / bankrupt / disband end states + New Company reset; re-entrancy-guarded animated beats.

**Combat mesh (the seam)**
- ✅ Combat runs as a **child scene** of the still-alive overworld, returns via `combat_finished` signal.
- ✅ **crew = party**: the chosen dwarves (any composition) become the combat party carrying current HP + persistent decks.
- ✅ **danger tier → enemy composition** (`Db.ENCOUNTERS_BY_TIER`): Med = balanced trio; High = two Brutes + Caster ×1.2; modifiers scale further.
- ✅ **De-indexed combat targeting** (role-based) so non-canonical crews (e.g. no-Cleric {W,W,S}) work.
- ✅ **Backward compatible**: empty `request` = byte-identical standalone combat, so `/` and `/grid/` are untouched.

**Combat (unchanged Slice-2 core)**
- ✅ 3-role party (Warrior tank / Cleric support / Sorcerer dps), per-character decks + energy, clean player→enemy phases.
- ✅ 3 archetype enemies (Brute / Assassin / Caster) with preferred targeting + live threat arrows + Taunt redirect.
- ✅ Synergy cards (Mark / Channel / Aura / Shield / Retaliate / Fortify / Finisher); Mark = the single ×1.25 multiplier.

## 5. Design-assumption status (the spec's ledger)

| # | Assumption | Status |
|---|---|---|
| A1 | Fee clock creates productive tension | Built + sim-gated (safe grind bankrupts); **needs felt-playtest** |
| A2 | "Which job" is an interesting choice | Built (tiers + modifiers + crew cost); **needs playtest** |
| A3 | Crew selection matters + creates attachment | Built (crew-select + carried HP + growing decks); **needs playtest** |
| A4 | Overworld + combat reinforce each other | **Now testable** — the whole mesh exists; **the key open question** |
| A5 | Attrition motivating not punishing | Wounds-only (permanent loss gated off until recruiting exists) |
| A6 | Roster-building satisfying | Partial — decks grow; recruiting/leveling deferred |
| A7 | Runs stay varied | Modifiers + tier comps + deck divergence; more axes deferred |
| A8 | Economy legible | Built (round tens, glance grammar); monthly-rent numbers freshly retuned |

## 6. Economy state (all tunable `const` at the top of `overworld.gd`)

| Knob | Value | Note |
|---|---|---|
| START_TREASURY | 80 | |
| FEE_BASE / FEE_STEP / FEE_PERIOD | 55 / +10 / **monthly** | rent escalates every month |
| WIN_MONTH | 8 | survive 8 months → victory |
| CAMPAIGNS_PER_MONTH | 3 | jobs per month before rent |
| PAYOUT | low 25 / med 80 / high 100 | Low is the "insufficient safe" lifeline |
| DANGER (dice) | low 8 / med 13 / high 15 | dice stub uses crew_strength + 2d6 |
| CREW_SIZE | low 1 / med 3 / high 3 | Med/High are real fights |
| WOUND_RECOVERY / HP_REGEN_PER_MONTH | 2 months / 6 hp | |
| MOD_CHANCE | 0.45 | chance a fight contract carries a modifier |
| ENCOUNTERS_BY_TIER | med trio×1.0 / high 2×Brute+Caster×1.2 | in `card_db.gd` |

**Sim-verified gate:** a safe **3-Low-per-month** grind (75g/mo) still goes **bankrupt at month 8** —
the escalating monthly rent forces the higher-paying fights. *These numbers are deliberately rough and
flagged for playtest tuning.*

## 7. Known limitations / deferred (intentional)

- **`LOSS_ENABLED = false`** — permanent dwarf loss is gated off until **recruiting** exists (a 4-dwarf
  roster with no refill would death-spiral). The ⚰️/lost/disband paths are built and ready.
- **Combat has 3 fixed enemy slots** (`EN_POS` / `en_emoji`) — "+1 enemy" modifiers (Horde) need UI
  work; current modifiers only scale stats, not count.
- **Deferred Phase-5 axes** (design-now, gate-off, per the "recombination-per-content" north star —
  build only if playtest exhausts the cheap ones): parametric danger + enemy-pref roulette,
  location→enemy bias, dwarf traits, recruiting, econ-only company relics.
- **DWARF_STRENGTH is flat** (class drives only emoji/color in the *overworld*; combat is where class
  actually differs). No dwarf leveling/gear.
- **Run length**: with real fights + 3 campaigns/month, a full 8-month run is longer than the stub era.
  Watch in playtest; the `USE_REAL_COMBAT` flag can A/B stub-vs-real.
- **Web cache caveat**: the automation browser stubbornly caches `index.pck`; verify deploys via
  `curl` + no-store fetch, and hard-refresh (Ctrl+Shift+R) real devices.

## 8. Verification & deploy

- **Verification**: everything above verified in the live Godot editor via `play_scene` + screenshots +
  `execute_game_script` state dumps (economy sims, seam round-trips, targeting, deck growth). No
  GDScript test runner exists — verification is the interactive MCP loop.
- **Deploy**: manual `gh workflow run deploy-pages.yml`; **verify the run's `headSha` matches HEAD**
  (a push→dispatch race once shipped a stale commit). Each phase committed + deployed individually.
- **Current HEAD**: `e944e1f` (Phase 5). Docs of record in `docs/plans/` (spec, MVP plan, mesh design).

## 9. Suggested next directions (for the feature-planning this report supports)

Ranked by recombination-per-content (the project's north star — *variety from recombining existing
pieces, not new content*):

1. **Recruiting** — refill/grow the roster (tavern/event). Unlocks safe `LOSS_ENABLED = true`; feeds crew-choice variety. *High value, medium cost.*
2. **Parametric danger + enemy-pref roulette** — vary the existing 3 enemies per fight (scale + which prefs appear) so fights stop feeling identical. *Cheapest anti-rote.*
3. **Location → enemy bias** — the location already on each card (Warrens/Keep/Marches/Deeproads) shapes enemy comp. *Cheap, makes flavor tactical.*
4. **Dwarf traits** — 1–2 passives per dwarf (procedural identity, attachment). *Each is a bespoke combat hook — budget them.*
5. **More modifiers / a 4th enemy slot** — Horde etc. (needs combat UI generalization to N enemies).
6. **Econ-only relics** — cheaper rent / faster recovery / reroll. *Cheap but recombine only with the economy.*

Before any new **content** (cards, enemies, classes): confirm in playtest that the cheap redistribution
axes are exhausted, and that **A4** (the layers reinforce) actually holds.

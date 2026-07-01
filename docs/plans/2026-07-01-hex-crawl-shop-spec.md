# Hex-Crawl Campaign Layer + Shop + Card/Op Expansion — Design of Record

**Date:** 2026-07-01 · **Status:** SHIPPED & verified in-editor, deployed to Pages.
**Companion:** `../reports/2026-07-01-implementation-report.md` (§3 seam, §5 conventions, §9 landmines).
**Extends:** the meshed overworld loop (Phases 0–5).

The core bet: *you run a company of shit-tier dorfs and make the most of them.* Dorfs are expected to
die; rewards are sometimes bad; the fun is squeezing value out of a bad hand under a rent clock. The
hex crawl turns each contract from **one fight** into an **expedition you manage** — a sequence of
push-or-extract decisions where attrition is the point. This is the content that makes assumption **A4**
(do the layers reinforce?) answerable past a single coin-flip fight.

## What shipped

### 1. Combat expansion (`card_db.gd` + `combat.gd`, additive)
18 new cards + a `_run_ops` dispatcher (the only place ops execute) that recurses for conditionals.
- **New systems:** Burn (status, ticks at enemy-turn start, decays −1); Vulnerable (+50%, stacks
  multiplicatively with Mark's +25%); Momentum (per-char attacks this turn → Momentum Strike);
  Devotion (per-char skills this turn → Divine Smite spend); Empower (`next_card_double`); Whetstone
  (`buff_next_attack`); `retain_block`; conditionals `if_bloodied`/`if_target_marked`/`spend_devotion`/
  `on_kill`; plus `dmg_all`, `party_block`, `heal_self`/`heal_ally`, `gain_energy`, `self_dmg`, `apply`.
- Generic 9 join `REWARD_POOL`; class cards stay role-locked (offered on hex reward tiles via
  `CLASS_REWARDS`, gated to a crew member's class).
- `describe()` extended so every new card renders a live-number body; `"party"` target plays like
  `"self"`. A crew member arriving at 0 HP starts benched (`alive = hp>0`) — standalone/mesh combat
  stays byte-identical (their crews are always hp>0).

### 2. Expedition (hex crawl) — new `HEX` state in `overworld.gd`
- Radius-2 fogged axial hex map (~19 hexes); hidden objective at depth ≥ 2; entry + neighbours start
  revealed; entering reveals neighbours. Content is depth-weighted: combat / reward / event / empty /
  objective. Movement = tap a lit (revealed) neighbour.
- **Per-hex combat reuses the seam exactly**: `fight.request` → `add_child` → `await combat_finished`
  → `queue_free`, re-checking `run_epoch` after every await. Enemy scale = `tier × modifier ×
  (1 + depth·HEX_DEPTH_SCALE)`. The fixed 3 crew ride every fight; a downed dwarf enters at 0 HP as a
  benched slot (respects combat's 3-slot constraint). HP carries in and out.
- **Death saves** (`LOSS_ENABLED = true`): a dwarf at 0 HP rolls each tile — 3 successes = stable
  (benched, lives), 3 failures = dead. Extracting brings the fallen home wounded; a wipe resolves
  remaining saves on the way out. Loss is now fair because the shop's Recruit refills the roster.
- **Resolution → the UNCHANGED `{success,payout,pending}` shape**: objective = `depth_pay(deepest) +
  OBJECTIVE_BONUS`, extract = `depth_pay(deepest)`, wipe = 0 (× modifier pay). Feeds the existing
  outcome pipeline; an expedition is **one campaign** (never touches the month counter).

### 3. Shop (H5) — panel on the contract board, re-rolled monthly
Card (from `REWARD_POOL`, assign to a dwarf) / Field Medic (a dwarf → full HP) / Recruit
(`roster.append`). Every buy is pure treasury math and trades against the rent clock. Low contracts
stay the dice lifeline; the safe-grind bankruptcy gate is unchanged (Low path untouched).

## Tuning knobs (all `const` at the top of `overworld.gd`)
`HEX_RADIUS 2` · `OBJECTIVE_MIN_DEPTH 2` · `HEX_DEPTH_SCALE 0.20` · `DEPTH_PAY 15` ·
`OBJECTIVE_BONUS 60` · `DS_SUCCESS_CHANCE 0.55` (3/3 saves) · `SHOP_{CARD 35, HEAL 25, RECRUIT 50}` ·
reward-tile gold chance 0.30, event risky-success 0.55.

## Verification (all via `execute_game_script` state dumps — screenshots lag transient beats)
Combat ops (burn tick/decay, Momentum/Devotion scaling, Empower double, Whetstone, on_kill, dmg_all,
Mark×Vulnerable stacking); map gen (19 hexes, objective depth 2, 7 revealed at start); seam round-trip
(crew=party, `enemy_scale` = tier×mod×depth, HP + downed carried back, chrome hidden/restored);
death-save transitions (stable & lost); extract/objective/wipe payouts into the existing pipeline;
shop card/heal/recruit with affordability guard; all screens render.

## The felt-assumptions this makes testable (answer only by playing)
- **H1** push-or-extract tension · **H2** attrition→attachment (fair deaths) · **H3** a bad reward is
  still a decision · **H4** hex layer meshes with (not replaces) the fee clock · **H5** the shop gives
  the treasury a second job.

## Deviations / notes for next time
- `DS_SUCCESS_CHANCE 0.55` on a full wipe can occasionally kill all 3 (each downed ≈40% death). Feels
  brutal but recoverable via Recruit; raise the chance or cap wipe deaths if playtest says rug-pull.
- Reward tiles are the main deck-growth source (generic pool + crew-class cards). Class cards are only
  reachable here or via the shop card slot — they never enter the universal pool.
- Combat still has 3 fixed enemy slots + 3 fixed party slots; depth scales stats, not counts.

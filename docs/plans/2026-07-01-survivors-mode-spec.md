# Survivors Mode — StS-Node Zombie Survival (Design of Record)

**Date:** 2026-07-01 · **Status:** SHIPPED & verified in-editor, adversarially reviewed, deployed.
**URL:** `/survivors/` (fourth peer scene, alongside `/`, `/grid/`, `/overworld/`).
**Companion:** `../reports/2026-07-01-implementation-report.md` (§3 seam, §5 conventions, §9 landmines).

## The bet
A rival answer to "what is a campaign?" — meant to A/B against the hex crawl. Where the overworld wraps
fights in a **rent clock** (economic, external), Survivors wraps them in a **food+water survival clock**
(internal, self-contained, endless). Tests whether the validated combat engine carries a roguelike run
**without** the economic meta.

## What shipped (reuses combat.gd + the seam wholesale — zero combat forks)
- **Class-select start** — Brute (tank) / Medic (support) / Engineer (dps), mapping onto the existing
  warrior/cleric/sorcerer combat ROLES so role-based targeting works unchanged. Run starts with 1 survivor.
- **StS branching map** (`survivors.gd`) — a connected layered DAG (rows [1, 2–3, 2–3, 2–3, 1]); the whole
  lap is visible; node types telegraphed (🧟 combat / 🎒 forage / 🆘 rescue / ❔ event / 🔥 camp / 💀 boss);
  ≥1 forage and ≥1 rescue guaranteed; column-proximity edges with full reachability (every node reachable,
  boss reachable). Edges drawn as rotated ColorRects; current + reachable neighbours highlighted.
- **Survival meters** — food/water deplete per node step. At 0, the lowest-HP survivor takes `STARVE_DMG`
  (can die → `status="lost"`); everyone dead → RUN OVER. The meters ARE the economy (no treasury/rent).
- **Node resolvers** — combat via the SEAM (crew padded to combat's fixed 3 slots: living survivors +
  benched hp:0 pads; downed revive at 25% on a win; +scraps refill), forage (food/water choice), rescue
  (recruit a missing-class survivor, cap 3), event (safe/risky), camp (heal + refill).
- **Endless boss-lap** — boss = `SURVIVOR_BOSS` scaled by `lap` + boss bonus; win → BIG STASH (+food/water)
  + guaranteed card reward → next lap, `enemy_scale += LAP_SCALE` per lap. Score = laps·20 + nodes +
  survivors·5. No win screen; "furthest lap" is the meta-hook.
- **Run-scoped party** — born and dies inside one run; fully separate state from the overworld (no months
  / roster / treasury). Additive combat foundation: 17 survivor cards, 3 classes, 3 zombie enemies,
  a new **Cripple** status (+ Burn), and the ops `heal_lowest / ally_gain_energy / dmg_per_bloodied_ally /
  apply_all / apply cripple` (the turret was cut per the spec's MVP tightening).

## Tuning knobs (all `const` top of `survivors.gd`)
`START_FOOD/WATER 10` · `FOOD/WATER_PER_NODE 1` · `STARVE_DMG 5` · `FORAGE_CACHE 4` · `COMBAT_SCRAPS 2` ·
`BOSS_STASH 12` · `CAMP_HEAL 6` · `LAP_SCALE 0.25` · `BOSS_BONUS 0.4` · `REVIVE_FRAC 0.25` ·
`MAX_PARTY 3` · `MAP_ROWS 5`.

## Verification (state dumps — screenshots lag transient beats)
Class-select; map gen (11 nodes, all reachable, guaranteed forage/rescue); combat seam (1 survivor + 2
pads vs lap-scaled zombies, carried HP, +scraps); boss (scale 1.4 at lap 1 → +12 stash → lap 2 @ 1.25);
starve (−5); rescue (party 1→2, missing class); camp (+6); game-over score. Passed a 5-dimension
adversarial review (4 findings fixed: New-Run visibility soft-lock, combat→reward clobber, async cleanup).

## Deviations / next
- Combat-downed survivors **revive at 25% on a win** (permanent death is the STARVATION vector, not routine
  fights); a full wipe = RUN OVER. Tunable if playtest wants harsher/softer combat attrition.
- Zombie enemies reuse the brute/assassin/caster pref archetypes (walker/lurker/spitter) — cosmetic
  theming only; combat targeting unchanged. 3 fixed enemy slots; lap scales stats, not count.
- Deferred: the turret entity (`deploy_turret`), per-node animation pacing, richer event variety.

# Enemy damage/HP scaling audit — "hard but not impossible"

**Date:** 2026-07-01 · **Method:** closed-form analysis + Monte Carlo (≥2000 fights/cell,
96-cell grid + 5 expedition-chain mixes, near-optimal bot policy; `dorf_sim.py` in the
session scratchpad, results `full_results{,_v2,_v3}.txt`, `whatif_k050.txt`, `probe.py`).

## Finding (pre-tune)

Tier × modifier × danger multiplied into one composite that scaled enemy HP **and** damage —
difficulty grew ~quadratically against a flat party. The worst reachable cell
(high 1.2 × elite 1.4 × ☠☠☠ 1.6 = **×2.688**) was **0.0% winnable for every comp** (Ogre
CRUSH 43 one-shots any dwarf through full block). High-tier expeditions were 0.0–0.2%
completable at *every* modifier: HP carries between hexes with zero in-run healing, so chains
were pure attrition. Meanwhile `brute+brute+caster` was an 85-point outlier vs sibling comps
(two tankiest-pref heavies stack one 36-HP warrior).

## Changes shipped

| Lever | Before | After | Where |
|---|---|---|---|
| Threat composition | tier × mod × danger | **additive**: 1+(t−1)+(m−1)+(d−1) | `overworld.gd` `_hex_combat`/`_embark_fight` |
| Damage/block scaling | full escale | **damped**: `1+(escale−1)·0.65` (HP stays full) | `combat.gd` `_start_combat` (`ATK_SCALE_K`) |
| Danger step | 0.30 (d3=1.6) | **0.225** (d3=1.45) | `overworld.gd` `DANGER_STEP` |
| Elite modifier | 1.40 | **1.50** (keeps its bite under additive) | `overworld.gd` `MODIFIERS` |
| Howl rage | unbounded | **cap 8**, telegraphs show real gain/"max" | `combat.gd` `RAGE_CAP` |
| High comp | brute+brute+caster | **brute+witch+caster** (brute+warden was the opposite outlier: double-tank 0% wall) | `card_db.gd` |
| Expedition attrition | none | **+5 HP** to living crew after each WON combat hex | `overworld.gd` `HEX_POST_FIGHT_HEAL` |

Worst reachable composite is now **2.15** → damage ×1.75 (Ogre CRUSH 28, +rage ≤36; blockable
by a braced warrior), HP ×2.15 (fights long and costly).

## Post-tune landscape (Monte Carlo v3)

- **No reachable cell at 0%.** Worst opt-in stack (high·elite·☠☠☠): 1.8–27.2% by comp —
  brutal, double-telegraphed (👑 contract + ☠☠☠ tile), and routable-around on the visible
  board; the objective tile never spawns a fight, and Extract is always offered.
- Difficulty ramps cleanly: high·none ☠☠☠ 79–97%, high·grim ☠☠☠ 30–73%, med·elite ☠☠☠ 15–99%
  (brute trio the hard roll).
- Expedition chains (forced d1/d2/d2/d3 route): med·none 96.6%, med·elite 20.4%,
  **high·none 23.5%** (was 0.2%), high·grim 0.1%, high·elite 0.0% *on the forced worst route*
  (players route around d3 and extract).

## Caveats + playtest levers

- The sim's bot is near-optimal: its 100% floor / 96.6% med-chain readings are a bot ceiling,
  not proof of "too easy" — human numbers land lower. Trust the 0% direction, not the 100%.
- If playtests still find the top corner hopeless: `elite 1.50→1.40` or `ATK_SCALE_K
  0.65→0.60` (one line each). If med feels too comfy: `HEX_POST_FIGHT_HEAL 5→3`.
- Known residual (accepted): a warrior-less crew has no Taunt answer to converged lowest-hp
  focus (wolf comps); Recruit does not guarantee role coverage.

# Grid Fire Emblem Experiment — Design

Date: 2026-06-30
Status: Approved, building

## Goal

A second, parallel combat mode that experiments with light Fire-Emblem-style grid
positioning and movement layered onto the existing card-battler (same roles, decks,
energy system). Lives alongside the existing "Quarterly Raid" mode without touching it.

## Scope & Files

- New scene `scenes/combat/grid_combat.tscn` (bare `Control` root, same pattern as
  `combat.tscn`) + new script `scripts/combat/grid_combat.gd`, forked from `combat.gd`
  rather than parameterizing it — the interaction model differs enough (tile-tap
  movement, range-gated targeting) that sharing one script would fight itself.
- `scripts/combat/combat.gd` / `scenes/combat/combat.tscn` stay **untouched** — the
  live "Quarterly Raid" build is unaffected.
- `scripts/combat/card_db.gd` is **shared, not duplicated** — add a `range` field to
  existing card entries (additive; old `combat.gd` never reads it).
- Reused as-is: `scripts/ui/card.gd` (card widget), `scripts/vfx/momentum_hit.gd` (hit
  VFX).
- `scripts/ui/threat_arrows.gd` / `target_arrow.gd` concept carries over but the arrow
  now originates from wherever the enemy currently sits on the grid; `grid_combat.gd`
  can own this logic directly rather than reusing the row-based component as-is.
- No main-menu/router scene needed — local dev plays the new scene directly via
  `play_scene` by path; deployed reachability is a separate exported URL (below), not
  an in-game menu.

## Grid, Movement & Positioning

- 5×5 grid of square tiles, drawn procedurally in code (`ColorRect`/`Polygon2D` per
  cell, ~110px each = 550px square), no `TileMap` needed.
- Enemies start on row 0 (top), dwarves on row 4 (bottom), columns 1/2/3 (columns 0
  and 4 stay open for flanking). Rows 1–3 are open maneuvering space.
- Movement is 4-directional, Manhattan distance, no diagonals. Tiles are blocked by
  occupying units (no stacking). Reachable tiles = BFS flood-fill from the unit's
  current tile capped at its movement points.
- Movement points refresh at the start of the player phase (like energy) and don't
  cost energy — a unit can move, play card(s), then move again later in the same
  activation as long as movement points remain.
- Per-class movement (Fire Emblem's armor/infantry/cavalry hierarchy, scaled down to
  fit a 5-wide board):
  - **Warrior** (armor-coded tank): **1 tile**
  - **Cleric** (standard infantry): **2 tiles**
  - **Sorcerer** (mobile caster): **3 tiles**
  - **Brute** (heavy melee): **1 tile**
  - **Caster** (ranged, standard): **2 tiles**
  - **Assassin** (dives the backline): **3 tiles**
- Tapping the active dwarf with no card armed highlights reachable tiles in blue;
  tapping a highlighted tile moves it there, decrementing remaining movement by path
  length.

## Card Range Rework

Add a `range` field (Manhattan tiles from the active unit's *current* tile) to
targeted cards:

| Card | Range | Why |
|---|---|---|
| Strike, Cleave | 1 | melee — must be adjacent |
| Mark, Arcane Finisher | 2 | Sorcerer's ranged kit |
| Channel Shield, Mend or Smite | 2 | Cleric reaches without melee |

Self-target cards (Guard, Wall, Taunt, Retaliate, Fortify, Channel, Aura of Valor) get
no range field — always usable regardless of position.

**Cleave reinterpreted for the grid**: hits every enemy within range 1 of the
attacker (not literally every enemy on the board as in the original mode) — a wide
melee swing, only in `grid_combat.gd`'s resolver.

Targeting UI: arming a card highlights only enemies/allies within range of the active
unit's current tile (same gold/green tint system as today, gated by
`grid_distance <= card.range`, re-evaluated live as the unit moves). Tapping an
out-of-range unit doesn't consume the card — logs "Out of range — move closer" and
stays armed.

Enemy attack ranges mirror this: **Brute & Assassin are melee (range 1)**, **Caster
is ranged (range 2)**.

## Enemy AI: Pathing & Combat Resolution

Target *selection* is unchanged — `_enemy_target()`'s tankiest / healer-skip-tank /
lowest-HP preference logic stays distance-blind. New execution layer on top, each
enemy in fixed order (Brute → Assassin → Caster):

1. If already within attack range of its chosen target, attack immediately (damage/
   block/shield math unchanged).
2. Otherwise BFS its reachable tiles (capped by movement points) for any tile within
   attack range of the target; walk to the nearest such tile (BFS already explores in
   distance order) and attack.
3. If no reachable tile gets it in range this turn, just advance as far as possible —
   no attack.

Occupied tiles block movement; enemies path around each other in fixed order (no
stacking).

Threat-arrow/intent label upgrade: if the enemy's target is reachable-and-in-range
this turn, show "🗡atk>target" + solid arrow as today. If out of reach, show
"🏃>target" (no atk number) — telegraphs that enemy is safe to ignore this turn.

Movement animates as a ~0.25s position tween per tile stepped, inside the existing
`await create_timer()` enemy-phase pacing.

## UI Layout & Turn Flow

5×5 grid (550px square) in the upper-middle of the 720×1280 viewport: title above,
hand + End Turn button below, same vertical budget as today. Each tile holds a unit's
emoji token + small HP text; full status badges stay in the existing footer
"active unit" panel rather than cluttering 110px tiles.

Interaction: tap a dwarf's token to activate (highlights reachable tiles in blue);
tap a highlighted tile to move. Cards: self/all-enemies cards play on one tap
(matching the just-shipped single-tap fix); enemy/ally-target cards arm on tap-one,
resolve on tap-target, now range-filtered. Tap a different dwarf's token to switch
active unit. Phase structure, energy refresh, and `combat_epoch`-guarded enemy-phase
pacing are unchanged from `combat.gd`.

## Deploy: Separate URL Path

Add a second export preset (`Web Grid`, `export_path="build/web/grid/index.html"`) to
`export_presets.cfg` alongside the existing `Web` preset. Add one more step to the
**same** build job in `deploy-pages.yml` (not a new job) that sed-patches
`project.godot`'s `run/main_scene` to `grid_combat.tscn` (CI checkout only, never
committed) right before running that second export. Both `index.html`s land inside
`build/web/`, so the existing single `upload-pages-artifact` step covers both.

Result:
- `https://fahim-mygithub.github.io/dorf-company/` — unchanged, current game
- `https://fahim-mygithub.github.io/dorf-company/grid/` — new grid experiment

Deployed together on every push, per the standing "deploy every iteration" preference.

## Range update (2026-06-30, iteration 2)

Follow-up so every card carries a range and the Sorcerer reads as the long-range
class. Decisions (confirmed with the user):

- **Every card has a `range`.** Targeted attacks/skills keep their Manhattan range;
  pure-self buffs (Guard, Wall, Retaliate, Fortify, Channel) are `range 0` (self).
  All additive in the shared `card_db.gd`; the non-grid `combat.gd` ignores them.
- **Sorcerer = most range, via a per-class +1.** `grid_combat._card_range(def, caster)`
  adds +1 to any card whose base range > 0 when the caster is the Sorcerer. So its
  Strike is 2 (vs Warrior 1), Mark/Arcane Finisher 3. One rule, applies across its
  whole kit; pure-self range-0 cards stay 0.
- **Auras and Taunt get a radius.** Aura of Valor and Taunt were "self" cards that
  hit *all* allies / *all* enemies regardless of position. They now carry
  `area: true`, `area_affects: "ally" | "enemy"`, and `range: 2`, and only touch
  units within that radius of the caster:
  - Aura of Valor blesses only allies within range. The old global
    `party_attack_buff` became a **per-ally** `attack_buff` (set at cast for in-range
    allies, reset each player phase, read by `_attack` for the acting char). The
    non-grid game keeps its global behavior.
  - Taunt grips only enemies within range (still gives the Warrior +8 block and keeps
    its no-two-turns-in-a-row cooldown).
- **Reach indicator on arming.** Arming any card with range > 0 paints the in-range
  tiles orange (Manhattan radius, not path-constrained; mutually exclusive with the
  blue move highlight) and tints the affected units (gold enemies / green allies).
  Card faces show `🎯 range N` (targeted) or `📣 radius N` (area).
- **Area cards arm-to-preview, tap-again-to-cast.** Since the radius matters (you may
  want to move first to catch more units), area cards no longer single-tap-play: the
  first tap arms + previews, the second tap on the same card casts. Pure-self cards
  (Guard etc.) still play on a single tap.

Verified live in the editor: per-class range values, reach-tile counts, Aura buffing
only in-range allies, Taunt gripping only in-range enemies, the two-tap area cast
spending energy exactly once, and single-tap self cards unchanged.

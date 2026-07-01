# Overworld MVP — Step 1 Implementation Plan (validated)

Date: 2026-06-30
Status: Approved (workflow-validated wf_3b90ca07-ced), building
Source spec: `2026-06-30-overworld-mvp-spec.md`

Validated against the codebase by a 4-dimension workflow (codebase-fit, economy-sanity,
UX-flow, adversarial-gaps) + synthesis. This is the buildable Step-1 plan; combat is
**read-only** (the MVP wraps it with a dice-roll stub, does not call it).

## Decisions locked (open questions resolved)
- **START_TREASURY = 100g** (designer default; drop to 80 only if playtest feels soft).
- **WIN_MONTH = 12** — surviving the month-12 advance = Victory overlay; `Month X/12` HUD readout.
- **Roster emoji = combat's 🛡️/⛑️/🧙** (read from `Db.CLASSES`), NOT spec's ✨/🔮.
  Rationale: single source of truth with the combat party (A4); 🔮 already = Caster *enemy*.
- **LOSS_ENABLED = false** in Step 1 → attrition is **wounds only** (A5: no undeserved
  permanent loss without crew agency). The ⚰️/disbanded paths are built but gated.
- **CREW_SELECT = false** → contracts `_auto_assign_crew()` (first `crew_size` Ready). The
  crew-select screen is the Step-2 seam; RESOLVE/OUTCOME read only `current.crew`.

## Economy finding (flagged, not silently changed)
Simulation: a careful **Low-only** player (Low 30g/1mo, ~0 attrition) reaches month 12 at
~70g — i.e. the escalating fee alone (40 +10/cycle → 40,50,60,70,80,90) does **not** force
greedy jobs inside the 12-month window. Possible A2 ("obvious choice") failure. Ship the
designer's defaults (methodology = tune by play), but the one-line levers if the first
playtest confirms it's too soft: `START_TREASURY 100→80` or `PAYOUT.low 30→25` (both keep
round tens; no logic change). Do NOT buff High (reopens the runaway-war-chest risk).

## Files
- `scenes/overworld/overworld.tscn` — bare `Control` root "Overworld", same shape as combat.tscn.
- `scripts/overworld/overworld.gd` — `extends Control`; `const Db := preload("res://scripts/combat/card_db.gd")`
  (read-only, for role emoji/name). Copies `_label()`/`_emoji()`/`_flash()` idioms from combat.gd.

## State machine
One `state` var: `DASHBOARD → CONTRACTS → RESOLVE → OUTCOME → (loop)`, + `GAMEOVER`
(victory / bankrupt / disbanded). `CREW` defined, gated behind `CREW_SELECT`.
- Chrome built once: full-rect `screen_root` each screen clears+rebuilds (the `_rebuild_hand`
  queue-free idiom); a persistent `hud` on top (y 0–158); a hidden `overlay` (combat's pattern).
- One forward action per screen. `busy` + `run_epoch` guard all await-paced animation
  (direct port of combat's `combat_epoch` + `end_turn_btn.disabled`).

## Economy constants (tunable `const` at top of overworld.gd)
| Constant | Value |
|---|---|
| START_TREASURY | 100 |
| FEE_BASE / FEE_STEP / FEE_PERIOD | 40 / +10 per payment / every 2 months (even months) |
| WIN_MONTH | 12 |
| ROSTER | 4: Thrain(warrior) Bruni(cleric) Vela(sorcerer) Gimli(warrior) |
| DWARF_STRENGTH | 3 |
| DANGER | low 8 / med 13 / high 15 |
| PAYOUT | low 30 / med 80 / high 100 |
| DURATION | low 1 / med 2 / high 1 |
| CREW_SIZE | low 1 / med 3 / high 3 (low = crew_size-1 lifeline) |
| WOUND_CHANCE | low .05 / med .20 / high .35 |
| LOSS_CHANCE | low 0 / med .04 / high .12 (gated off Step 1) |
| FAILURE_PAYOUT_MULT / FAILURE_ATTRITION_MULT | 0.5 / 2.0 |
| Roll | 2d6; success = crew_strength + 2d6 ≥ DANGER[tier] |
| WOUND_RECOVERY | 2 months |

Full-crew (str 9) success: Low 100% / Med ~92% / High ~72%. Understrength (2 dwarves, str 6):
Med ~42% / High ~28% (death-spiral teeth — full effect once crew-select lands).

## Visual grammar → concrete (load-bearing signals are ColorRects, never glyphs)
- Danger tint/banner: Low `Color(0.16,0.34,0.20)`/`(0.30,0.82,0.42)` 💀; Med `(0.40,0.32,0.10)`/`(0.95,0.74,0.20)` 💀💀; High `(0.40,0.13,0.13)`/`(0.92,0.26,0.26)` 💀💀💀.
- Treasury bands (font color, pivot on next fee): RED `(0.92,0.26,0.26)` if `treasury<fee`; AMBER `(0.95,0.74,0.20)` if `fee≤t<2*fee`; GREEN `(0.30,0.82,0.42)` if `≥2*fee`.
- Class colors: Warrior grey `(0.62,0.64,0.68)`, Cleric gold `(0.95,0.80,0.30)`, Sorcerer violet `(0.62,0.40,0.85)`.
- Status: Ready WHITE; Wounded `(0.72,0.66,0.55)` + 🩹 + recovery pips; Lost `(0.35,0.35,0.38)` + ⚰️ (Step 2).
- Coin gold `(0.96,0.82,0.26)`; fee pips + coin stacks = small ColorRects. Die = 🎲 only (never ⚀–⚅).

## Month flow + fee timing (payout first, then advance month-by-month)
1. RESOLVE beats: crew advance → 🎲 roll → ✅/❌ flash → per-dwarf attrition (wounds).
2. OUTCOME: payout coins fly to HUD 💰; treasury ticks up (recompute band each step).
3. Advance `DURATION` months one at a time: `month+=1`; decrement each dwarf `recover` (heal at 0)
   BEFORE applying new wounds; if `month%2==0` fee due → if `treasury<fee` bankrupt (strict, ends run)
   else drain coins→👹, `treasury-=fee`, `fee+=10`.
4. Apply pending wounds AFTER advance (recover=2 → no self-heal). Precedence: victory(≥12) > bankrupt > disbanded.
Every `await` re-checks `run_epoch`.

## Win/lose
- WIN: complete month-12 advance solvent → Victory overlay.
- LOSE bankrupt: `treasury < fee` at a fee check (strict; ==fee pays to 0 and survives).
- LOSE disbanded: 0 ready AND 0 recovering on Dashboard entry (defensive; unreachable in Step 1
  because wounds always heal + `🛌 Rest` valve).

## Deploy (third Pages build at /overworld/, mirrors grid precedent)
- `export_presets.cfg`: append `[preset.2]` "Web Overworld", `export_path="build/web/overworld/index.html"`
  (preset.1 verbatim, name+path changed). Edit with editor CLOSED (repo hard rule).
- `deploy-pages.yml`: new "Export Web Overworld build" step after the grid step — value-agnostic
  `sed -i 's#^run/main_scene=.*#run/main_scene="res://scenes/overworld/overworld.tscn"#' project.godot`
  + `grep -q 'overworld/overworld.tscn' project.godot` guard (fails loud on no-op — the grid step
  already left main_scene = grid_combat.tscn, so a literal-combat.tscn sed would silently ship grid).
  Plus one coi-shim `sed` line for `overworld/index.html` (`../` relative). Root main_scene stays combat.

## Step-2 seam
Flip `CREW_SELECT` true → add one `_build_crew()` screen (tap-to-slot tokens + 4-pip odds gauge via
the already-built `_crew_strength()`/margin) that populates `current.crew`. Flip `LOSS_ENABLED` true.
Zero changes to resolve/outcome. No combat call anywhere in Step 1 (real hook = Step 4).

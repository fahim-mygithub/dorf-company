# Meshing Combat + Overworld — One Recombining Loop (Design Plan)

Date: 2026-06-30 · Status: **Phase 0 + Phase 1 SHIPPED & verified in-editor** (rest awaiting playtest signal)
Source: `combat.gd`, `card_db.gd`, `overworld.gd`, overworld-mvp spec + plan · Workflow wf_de08021a-006

## Build status
- **Phase 0 (done):** `START_TREASURY 100→80`, `PAYOUT.low 30→25`. Sim-verified: a Low-only grind now
  goes **bankrupt at month 12** (was a comfortable win), while Med survives (170g) — the fee forces
  the choice, so the fight actually gets taken. A4 is now testable.
- **Phase 1 (done):** the High "⚔️ REAL FIGHT" contract launches `combat.tscn` as an overworld child
  via the seam below (`USE_REAL_COMBAT`). Verified in-editor: canonical trio → party; win → +100g;
  loss → half payout + all-crew wounded; fee still drains mid-advance; chrome restores; combat child
  frees; **standalone combat (`/`) stays byte-identical** (empty `request` = default party). `USE_REAL_COMBAT`
  toggles the stub-vs-real A/B on identical stakes.
- **Next (Phase 2+):** carried HP + tier→composition, then crew agency, then the card-reward engine —
  gated on the Phase-1 playtest confirming A4 holds.


## The bet this plan tests
Assumption **A4** — wrapping fights in an economic frame makes *both* layers better: fights carry
stakes (this payout, these dwarves), and the economy is driven by real fight outcomes. Today the
two layers are validated **in isolation** and **do not share state**: combat is a sealed scene
(fixed W/C/S party, fixed brute/assassin/caster encounter, self-loops) and the overworld resolves
fights as a `2d6` dice stub. This plan meshes them so their decisions **recombine**.

## Key insight
> The crew you risk **is** the party you fight **is** the per-dwarf deck that grows from that
> fight's rewards. One shared object crosses one seam in both directions — crew+HP+deck IN,
> survivors+end-HP+loot OUT — and the fee clock forces you to churn which developed dwarves you
> dare spend. Replayability = re-distributing the same 14 cards across whichever dwarves survive,
> **not** adding content.

## The one seam (state-handoff contract)
Chosen approach: **combat runs as a sub-scene child of a still-alive overworld**, returning through
a signal — no autoload, no persistence code.

**combat.gd (3 edits, no fork):**
1. `signal combat_finished(result)` + `var request: Dictionary = {}`.
2. `_start_combat` (line 187): build `party` from `request.get("crew", <default trio>)` (spec =
   `{cls,name,hp,max_hp,deck}`; `Db.CLASSES[cls]` still gives role/emoji/energy); enemies from
   `request.get("enemies", Db.ENCOUNTER)`. **Empty request ⇒ byte-identical to today** (standalone
   scene + VFX loop preserved, so the `/` build and grid fork are untouched).
3. `_end` (line 571): if request non-empty, emit
   `combat_finished({success, crew_results:[{name,cls,survived,hp_end,max_hp}], payout_won})`
   instead of the Play-Again overlay.

**overworld.gd:** `const COMBAT_SCENE := preload("res://scenes/combat/combat.tscn")`. In `_embark`
(the seam is where `_resolve_dice` returns): for a `fight` contract, build `request` from
`current.crew`, hide `screen_root`+`hud`, then
```
var c := COMBAT_SCENE.instantiate(); c.request = req; add_child(c)   # request BEFORE add_child
var result := await c.combat_finished
if e != run_epoch: return
c.queue_free()
```
A new `_resolve_from_combat(result, tier)` maps `crew_results` → the **existing**
`{success, payout, pending}` shape and writes `hp_end` back to `roster.hp`. That feeds the
**UNCHANGED** `_build_outcome`/`_outcome_beats`/`_advance_months`/`_drain_fee` pipeline (skip
`_play_resolution`, the dice animation). Non-fight contracts keep `_resolve_dice` behind `USE_REAL_COMBAT`.

**Discipline / landmines:** real-combat contracts are always **crew_size 3** (dodges `CREW_SIZE.low=1`
and combat's fixed 3-slot arrays); set `request` before `add_child` (`_ready`→`_start_combat` fires
on tree-entry); reuse `run_epoch` guard, free child only after `combat_finished`; disable New-Company
while a combat child is alive; `main_scene`→overworld ships one build (dependency scanner auto-packs
combat.tscn because overworld preloads it).

## Build order (each phase playable)
- **Phase 0 — Economy prerequisite (constants only, HARD GATE).** Retune `START_TREASURY 100→80`
  (or `PAYOUT.low 30→25`); sim/play until the safe dice-only path **cannot** reach month 12. Tests
  A1/A2. *Why first:* the plan doc's own sim shows the fee never forces the fight otherwise → A4
  untestable. Zero build risk.
- **Phase 1 — Minimum meshing test.** One size-3 contract launches real combat with the **canonical
  auto-assigned trio vs canonical encounter** (balance identical); end-HP→wounds, win/loss→payout;
  dice for the rest; payout+rent-countdown painted into the combat HUD; A/B via `USE_REAL_COMBAT`.
  Tests A4. *Disproof control:* delete crew-in or HP-out → if both layers still play identically, the
  mesh is bolted-on, not shared-state.
- **Phase 2 — Carried HP + tier→composition.** Roster `{hp,max_hp}`; wounded enter hurt; `hp_end`
  persists; Rest heals. `Db.ENCOUNTERS_BY_TIER` table (→ evolve to parametric scalar+roulette). Tests
  A5/A2/A7. ≤2 real fights/run to hold run length.
- **Phase 3 — Crew agency.** De-index combat's role logic (`_enemy_target` Taunt→first living warrior,
  healer_dps→first cleric else non-tank; `range(party.size())`), flip `CREW_SELECT`. Non-canonical
  crews become distinct puzzles. Tests A3; prerequisite for non-rote repeat fights.
- **Phase 4 — Recombination engine.** Persistent per-dwarf `deck` + post-win 1-of-3 card reward
  (chassis + curated cross-class; **signatures role-locked** so the party puzzle survives). Combat
  needs zero change (seam already carries the deck). Tests A6/A7, compounds A3.
- **Phase 5+ — Gated axes.** Contract modifiers, pref-roulette+parametric danger, location bias,
  traits, recruiting, econ-only relics — designed-now/gated-off (mirroring CREW_SELECT/LOSS_ENABLED).
  Defer combat-hook relics + all new content (north star).

## Recombination stack (recombination-per-content, ranked)
1. **Crew=Party=Deck seam** (high) — the spine; nothing recombines without it.
2. **Per-dwarf growing decks** (high) — reuses engine + 14 cards, compounds the wound clock.
3. **Contract/enemy modifiers** (high) — one data tag enriches A2 and varies the fight.
4. **Parametric danger + pref-roulette** (high) — cheapest anti-rote lever.
5. **Crew composition agency** (medium) — distinct puzzles from the existing roster.
6. **Carried HP** (medium) — fuses layer state into one.
7. **Location→enemy bias** (medium) — makes the printed location tactical.
8. **Dwarf traits** (medium) — cheap procedural identity, but bespoke hooks.
9. **Recruiting/churn** (medium) — parasitic; build after decks+traits.
10. **Company relics** (low) — econ subset cheap; combat-hook relics lowest recomb-per-cost, defer.

## Kill criteria
Safe path still survives month 12 after retune; players want to skip a layer; run balloons past a
few minutes; the disproof test passes (crew-in/HP-out deletable with no change); byte-identical
fights go rote / a solved puzzle takes near-zero attrition; cross-class rewards collapse the party
puzzle (Warrior stacking Mark+Channel+Finisher into a solo nuke); deck-loss × wound clock reads as
an undeserved death spiral (A5 fail).

## Open decisions (resolved with recommendations)
1. **Run length** — hybrid: exactly one real fight (the top size-3 contract), dice the rest; scale
   up only if run length holds. (Over full-fight-per-contract → 30–60 min runs that stop the economy
   iterating.)
2. **Transport** — sub-scene child + signal. (Over autoload + change_scene, which forces
   serialize/rebuild of the whole run across `_new_run` re-init for no benefit.)
3. **Enemy variety** — fixed per-tier table as the Phase-2 stepping stone → parametric
   scalar+pref-roulette as the A7 axis. Author no new enemy archetype until proven insufficient.

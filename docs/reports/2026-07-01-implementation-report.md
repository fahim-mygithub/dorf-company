# Dorf Company — Implementation Report

**Date:** 2026-07-01
**Purpose:** Architecture + extension guide for adding new features.
**Companion:** `2026-07-01-progress-report.md` (status). Design of record: `docs/plans/2026-06-30-mesh-combat-overworld-design.md`.

Read this before touching code. It covers the architecture, the one seam that matters, the coding
conventions, and copy-paste-shaped recipes for the most likely features.

---

## 1. Architecture at a glance

Three modes, one project. Each mode is a **bare `Control` scene** whose attached script builds the
**entire UI in code** (no node trees). They share one data module.

```
scripts/combat/card_db.gd      SHARED data (RefCounted, preloaded as `Db`). Cards, classes, enemies,
                               encounters, tier tables, MARK_MULT. Purely additive — do not remove keys.
scripts/combat/combat.gd       Combat mode (`/`). The validated Slice-2 fight. Also runs as a CHILD of
                               the overworld via the seam (§3). 807 lines.
scripts/combat/grid_combat.gd  Grid experiment (`/grid/`). Forked from combat.gd. Parked; touch only for grid.
scripts/overworld/overworld.gd The meta-game (`/overworld/`). Dashboard→contracts→crew→combat→outcome loop
                               + economy. Owns the mesh. 1024 lines — the active file.
scripts/ui/{card,threat_arrows,target_arrow}.gd   Reusable combat UI widgets.
scripts/vfx/momentum_hit.gd    Hit-burst VFX scene script.
assets/emoji_font.tres         Twemoji COLR/CPAL FontVariation, set project-wide as gui/theme/custom_font.
```

**Key principle:** `overworld.gd` and `combat.gd` are **separate scenes bridged by a runtime signal**,
not a shared class. The overworld *instances combat as a child* and awaits a result. This keeps combat
independently runnable and testable.

## 2. The overworld state machine

One `var state: String` drives everything. `screen_root` (a full-rect Control) is **cleared and
rebuilt** on every screen change; `hud` and `overlay` are persistent.

| State | Builder | Forward action(s) |
|---|---|---|
| `DASHBOARD` | `_build_dashboard()` | "View Contracts" → CONTRACTS · "End Month" → `_end_month()` |
| `CONTRACTS` | `_build_contracts()` | two-tap a card → `_embark()` · Back → dashboard |
| `CREW` | `_build_crew_select()` | tap dwarves → `_on_crewpick_input` · Launch → `_launch_fight()` |
| (combat) | — | combat child runs; overworld hidden; `await combat_finished` |
| `OUTCOME` | `_build_outcome()` | Continue → `_on_continue()` → `_after_campaign()` |
| `SPOILS` | `_build_spoils()` | tap card + dwarf → grow deck → `_after_campaign()` |
| `GAMEOVER` | `_game_over(kind)` | overlay + "New Company" → `_new_run()` |

Flow control lives in: `_embark()` (routes dice vs fight vs crew-select), `_after_campaign()`
(next slot or `_end_month()`), `_end_month()` (advance + rent + reset), `_on_continue()` (spoils gate).

`RESOLVE` (dice animation) is transient inside `_embark`'s dice path (`_play_resolution`), not a
first-class screen.

## 3. THE SEAM — combat ↔ overworld (read this before any mesh work)

This is the single integration point. Combat runs as a child of the overworld and returns a result.

### combat.gd side (3 touch points — all backward-compatible)
```gdscript
signal combat_finished(result)          # emitted only when driven by the overworld
var request: Dictionary = {}            # set by the overworld BEFORE add_child

# _start_combat (line ~190): party + enemies come from `request`, else Db defaults.
#   request.crew    : Array of specs {cls, name, hp, max_hp, deck}   (deck optional)
#   request.enemies : Array of enemy ids (<=3 — combat has 3 slots)  (default Db.ENCOUNTER)
#   request.enemy_scale : float, multiplies enemy hp+atk             (default 1.0)
#   EMPTY request  => builds the default W/C/S party at full HP — byte-identical to standalone.

# _end(won) (line ~605): if request is non-empty, emit instead of the Play-Again overlay:
combat_finished.emit({
    "success": won,
    "crew_results": [ {name, cls, survived, hp_end, max_hp}, ... ],  # party order == request.crew order
    "payout_won": won,
})
```

### overworld.gd side (`_embark_fight`, line ~749) — the canonical pattern
```gdscript
var fight = COMBAT_SCENE.instantiate()          # COMBAT_SCENE = preload(combat.tscn)
fight.request = { "crew": _build_crew_specs(current["crew"]),
                  "enemies": comp.enemies, "enemy_scale": comp.scale * mod_scale }
screen_root.visible = false; hud.visible = false
add_child(fight)                                # request MUST be set BEFORE add_child (_ready fires on entry)
var result: Dictionary = await fight.combat_finished
if e != run_epoch: return                       # re-entrancy guard (see §5)
fight.queue_free()
screen_root.visible = true; hud.visible = true
var shaped := _resolve_from_combat(result, current["tier"])   # -> {success, payout, pending}
# ... build OUTCOME, run _outcome_beats(...)
```

`_resolve_from_combat()` maps combat's `crew_results` into the SAME `{success, payout, pending}` shape
the dice stub produces (`pending` = `[[dwarf_ref, "wounded"/"lost"], ...]`), writes `hp_end` back to
the roster, and applies the Phase-5 modifier's payout multiplier. Downstream (`_outcome_beats`) is
identical for dice and real fights.

**Deploy implication:** the `/overworld/` export includes `combat.tscn` automatically (overworld
`preload`s it + `export_filter="all_resources"`). No pipeline change needed to add combat to the build.

## 4. Data model

**Roster dwarf** (`roster: Array` of Dictionaries, built in `_new_run`):
```gdscript
{ "name": "Thrain", "cls": "warrior", "status": "ready"|"wounded"|"lost",
  "recover": 0, "hp": 36, "max_hp": 36,
  "deck": ["strike","strike",...] }   # persistent, grows via Phase-4 spoils
```

**Contract** (`contracts: Array` of 3, from `_make_contract` + `_regen_contracts`):
```gdscript
{ "tier": "low"|"med"|"high", "title", "loc_emoji", "loc_name",
  "payout", "duration", "danger", "crew_size", "crew": [],
  "fight": true,                 # set on Med/High when >=3 ready (real combat)
  "mod": {key,name,emoji,scale,pay} }   # optional Phase-5 modifier
```

**Run state** (top-level vars): `treasury, fee, month, months_survived, campaigns_left, roster,
contracts, current (accepted contract), crew_pick, pending_spoils, state, run_epoch, busy`.

**Combat data** (`card_db.gd`): `CARDS` (id → {name,cost,emoji,target,type,is_attack,effect,tip,…}),
`CLASSES` (role → {name,emoji,role,max_hp,energy,move,deck}), `PARTY_ORDER`, `ENEMIES`, `ENCOUNTER`,
`ENCOUNTERS_BY_TIER`, `MARK_MULT`. Card `effect` = list of `[op, ...args]` executed ONLY in
`combat.gd::_resolve`/`_attack`.

## 5. Conventions & idioms (match these)

- **All UI in code.** `overworld.gd` helpers add to a parent you pass: `_mklabel(text,pos,sz,font,parent,center,col)`,
  `_mkemoji(center,box,font,parent)`, `_rect(pos,sz,col,parent)`. (`combat.gd` has its own
  `_label`/`_emoji` that add to `self` — different signature; don't cross them.)
- **Screens rebuild, not mutate.** Change data, then `_clear_screen()` + `_build_<state>()`. This is the
  proven queue-free-and-rebuild idiom; it handles count-varying content for free.
- **Load-bearing signals are `ColorRect`s, never glyphs** (danger, treasury band, HP bars, fee/campaign
  pips, coin stacks). Emoji are identity/decoration only — this survives web-font gaps.
- **Async pacing + guards.** Animated beats use `await get_tree().create_timer(t).timeout`. Every await
  re-checks `if e != run_epoch: return` where `e := run_epoch` is captured at the start.
  `run_epoch` is bumped in `_new_run()`; `busy` gates all forward inputs while a sequence runs. This is
  the combat `combat_epoch` pattern — **replicate it in any new animated flow.**
- **Emoji-on-web:** verified glyphs render via Twemoji; new/rare glyphs (VS16, dice faces ⚀–⚅) may tofu —
  screenshot the web build, and never depend on a glyph for a measurement.
- **Economy = `const`.** All numbers are tunable consts at the top of `overworld.gd`; enemy comps in
  `card_db.gd::ENCOUNTERS_BY_TIER`.

## 6. Extension recipes ("how to add X")

### Add a new card
1. Add an entry to `card_db.gd::CARDS` (`effect` = list of ops; add new ops in `combat.gd::_resolve`/`_attack` only).
2. To make it obtainable mid-run, add its id to `overworld.gd::REWARD_POOL` (universal) — **keep
   role-signature cards OUT of the pool** so they stay class-defining. To put it in a starting deck,
   edit the class `deck` in `CLASSES`.
3. The spoils screen renders any card via `Db.describe()` + `Db.type_tint()` — no UI change needed.

### Add a new enemy / change an encounter
- New archetype: add to `card_db.gd::ENEMIES` ({name,emoji,max_hp,atk,pref,…}); `pref` must be
  handled by `combat.gd::_enemy_target` (`tankiest`/`healer_dps`/`lowest_hp` exist — add a case for a new pref).
- Change a fight's composition: edit `card_db.gd::ENCOUNTERS_BY_TIER[tier]` (`enemies` list ≤3, `scale`).
- **Landmine:** combat has **3 fixed enemy slots** (`EN_POS`, `en_emoji`, pervasive `range(3)` in
  `_refresh_enemies`). >3 enemies (Horde) requires generalizing those to N first.

### Add a new contract modifier (Phase-5 pattern — the template for cheap variety)
- Append to `overworld.gd::MODIFIERS` a `{key,name,emoji,scale,pay,tip}`. It auto-rolls (`MOD_CHANCE`)
  on fight contracts, displays a badge + effective payout, scales the fight, and multiplies payout — **all
  wiring already exists.** For effects beyond scale/pay (e.g. "party starts Marked"), add a `request`
  field and handle it in `combat.gd::_start_combat`.

### Add a new dwarf class / role
- Add to `card_db.gd::CLASSES` (+ a color in `overworld.gd::CLASS_COL`, + starting deck).
- **Combat targeting is now role-based** (`_first_living_role`, `_first_living_nontank`), so new roles
  work without slot assumptions — but check `_enemy_target` preferences reference the right roles.
- Add signature cards to `CARDS`; keep them out of `REWARD_POOL`.

### Add a new overworld screen / state
- Add a `state` string + a `_build_<state>()` that populates `screen_root`; route to it by setting
  `state` + `_clear_screen()` + `_build_<state>()` + `_refresh_hud()`. Follow the CREW/SPOILS screens
  as templates (tap handlers via `Control.gui_input` bound to data, rebuild on change).

### Add recruiting (recommended next — also unlocks safe permanent loss)
- New event/screen that `roster.append(<new dwarf dict with hp/max_hp/deck>)`. Gate behind a cost
  (treasury) or a month-end event. Once the roster can refill, flip `LOSS_ENABLED = true` — the
  ⚰️/lost path (`_resolve_from_combat`) and the `disbanded` end-state already exist. Consider making
  loss only fire on a *lost* fight's downed crew (fair-death) rather than any downing.

### Add dwarf traits / relics
- **Traits**: add a `traits: Array` to roster dwarves; pass into `request.crew` specs; apply in
  `combat.gd::_start_combat` (stat mods) or as checks in `_resolve`/`_attack` (each is a bespoke hook —
  budget them). **Econ relics**: a run-level `relics` array read in overworld economy math only (cheapest).

### Tune the economy
- Edit consts at the top of `overworld.gd`. **Always re-run the safe-path sim** (a Low-only grind must
  not reach `WIN_MONTH` solvent) — the pattern is a few lines in `execute_game_script` (see §8).

## 7. Build & deploy pipeline

- **`export_presets.cfg`**: 3 Web presets — `Web` (→`build/web/`), `Web Grid` (→`build/web/grid/`),
  `Web Overworld` (→`build/web/overworld/`). Add presets with the **Godot editor closed** (it overwrites
  the file) or via the Export dialog; verify with MCP `list_export_presets`.
- **`.github/workflows/deploy-pages.yml`** (manual `workflow_dispatch`): strips the paid MCP plugin,
  imports, exports all three (sed-patching `run/main_scene` per export with a **value-agnostic** sed +
  a `grep` guard that fails loud on a no-op), injects the coi-serviceworker shim, uploads one artifact.
- **Deploy checklist** (in order): commit → `git push` → `gh workflow run deploy-pages.yml` →
  **verify `gh run view <id> --json headSha` == `git rev-parse HEAD`** (a push→dispatch race can build
  the *previous* commit — symptom: byte-identical pck) → `gh run watch` → `curl -sI …/index.pck` for
  freshness. Real devices: **hard-refresh (Ctrl+Shift+R)** — `index.pck` (max-age 600) is cached by
  fixed path; a `?v=` query on the page does NOT bust it.

## 8. Testing / verification workflow

No unit-test runner. Verify through the live editor via MCP:
- `play_scene` (main / current / path) → `get_game_screenshot` for layout; `execute_game_script`
  (`_mcp_print(...)`) for numeric state (the reliable check — screenshots lag ~1–2s and miss transient
  beats).
- Drive flows by calling node methods directly (`get_tree().current_scene._on_view_contracts()`), or by
  `simulate_mouse_click` to test the real tap path. To test a fight's return path, grab the child
  (`ch.has_signal("combat_finished")`), set enemy/party HP, call `child._check_end()`.
- **Economy sim pattern** (before shipping any number change):
  ```gdscript
  var t = ow.START_TREASURY; var f = ow.FEE_BASE
  for m in range(1, ow.WIN_MONTH + 1):
      t += ow.CAMPAIGNS_PER_MONTH * int(ow.PAYOUT["low"])   # safe max income
      if t < f: _mcp_print("BANKRUPT m%d" % m); break
      t -= f; f += ow.FEE_STEP
  ```
- `_mcp_error unused variable` warnings from `execute_game_script` are harmless noise — ignore them;
  real issues show as `overworld.gd:<line>` / `combat.gd:<line>`.

## 9. Landmine list (things that will bite when adding features)

1. **3 enemy slots / crew always 3.** Fights are crew_size 3; combat's UI arrays are fixed 3. Varying
   counts needs UI generalization first.
2. **`request` before `add_child`.** `_ready`→`_start_combat` fires on tree entry; set `request` first.
3. **Free the combat child only after `combat_finished`**, and re-check `run_epoch` across the await.
4. **Empty-`request` fallback is sacred.** Any `_start_combat` edit must keep standalone byte-identical
   (it's the `/` and `/grid/`-adjacent guarantee, and the stub-vs-real A/B).
5. **`card_db.gd` is shared** with combat + grid — keep changes **additive** (new keys), never rename/remove.
6. **Campaigns don't advance the clock** — only `_advance_months`/`_end_month` do. Don't reintroduce
   per-contract month advance (`duration` is now cosmetic).
7. **`LOSS_ENABLED` is off on purpose** — don't flip it without a roster-refill mechanic.
8. **Editor overwrites `.tscn`/`.tres`/`project.godot`/`export_presets.cfg`** while open — use MCP tools
   or edit with the editor closed. `.gd` scripts are safe to edit on disk.

# Hexcrawl — the Tabletop Diorama: implementation plan

**Date:** 2026-07-20
**Status:** approved direction, not yet built
**Chosen direction:** the **Tabletop Diorama** (For The King II model) — see the three-prototype artifact
<https://claude.ai/code/artifact/6f985f78-86be-4c2e-8e29-40f3125d90b8> and the research plan
`docs/plans/2026-07-20-hexcrawl-ui-research-plan.md`. This doc turns the chosen mockup into staged
edits against the shipped code.

The board becomes a physical tabletop: hex tiles are carved wooden pieces on a felt playmat, dwarves
are coin-metal **tokens** on the map plus always-visible party cards, and selecting a tile pops
**The Writ** — a plain-language, stakes-first readout — before you commit. The commit control
("PROPOSE THE MARCH") **is** the co-op vote: pips fill steel -> gold -> arcane as seats agree.

> Glyph gate: every user-facing string uses `->`, never `→` (U+2192 fails `check_web_glyphs.py`).

---

## 0. The gap this closes (and what already exists)

The research finding: every captured hex-explorer bakes cost/payout onto the tile and shows a
**consequence readout before you commit**. Dorf does neither. Two nuances the code review turned up:

1. **Co-op is already half-there.** `_on_hex_input` (`overworld.gd:1577`) sends `_intent("hex", key)`
   for a reachable tile; `"hex"` is in `RING_KINDS` (`:197`), so it opens a **ring proposal**
   (`_ring_intent` `:2468`) whose text comes from `_ring_label("hex", …)` (`:2539`) —
   `"push into ⚔ (☠ 2)"` — shown in the crew bar by `_refresh_ring` (`:2610`). That IS a
   consequence-readout-before-commit, just terse and buried in the bar.
2. **SOLO is genuinely blind.** The same handler, when `mode == Mode.SOLO`, calls
   `await _enter_hex(key)` immediately (`:1585`) — no preview at all.

So Stage 0 is **not "add a vote."** It is: introduce a shared *select -> preview* step that works in
BOTH modes, enrich the readout into The Writ, and reuse the existing ring for the co-op commit.

### What no tile carries: gold

`hexes[key]` = `{q, r, kind, danger, resolved, objective, dist}` (built in `_gen_hex_map` `:1364`).
There is **no per-tile payout**. Real stakes by kind:

| kind | win / take | lose / cost | source |
|---|---|---|---|
| combat | crew patches `+HEX_POST_FIGHT_HEAL` (5) | newly-downed dwarf -> wagon, death saves | `_hex_combat :1685`, `_enter_hex :1632` |
| reward | 35% coin cache `HEX_REWARD_GOLD(18)+rand12`, else a class card | — | `_open_hex_reward :1714` |
| event | risky `EVENT_RISK_GOLD(24)` / safe `EVENT_SAFE_GOLD(8)` | risky can hurt | `_do_event_choice :1891` |
| objective | the rescue payout + ends the run | — | `_finish_expedition :1926` |
| empty | quiet passage | — | `_enter_hex :1646` |

**Consequence for the mockup:** The Writ shows *these concrete stakes*, not an invented "+EV". The
mockup's `EV +24g` stamp is **aspirational** — deferred to an optional payout-estimate pass (§7),
not Stage 0. Combat danger already reads from `h["danger"]` (1-3); distance is always 1 (the selected
tile is a neighbour of `hex_cur`), bearing is derivable from the q/r delta.

---

## 1. Current code map (grounding)

All UI is code-drawn (bare `Control` root); the client redraws from snapshots using the SAME
`_build_*` functions (`_render :2659` -> `_build_hexcrawl`), so any change inside a builder networks
for free. Host is the sole mutator; clients send intents.

| concern | function | line |
|---|---|---|
| open expedition, gen map | `_open_expedition` / `_gen_hex_map` | 1303 / 1359 |
| tile pixel pos (odd-r offset) | `_hex_px` | 1438 |
| board + backdrop + labels + Extract btn | `_build_hexcrawl` | 1443 |
| one tile (HexTile + glyph + ☠) | `_build_hex_tile` | 1468 |
| party strip (cards w/ HP/DS) | `_build_exp_crew_strip` / `_build_exp_crew_token` | 1539 / 1546 |
| **tap handler (the blind march)** | `_on_hex_input` | 1577 |
| flag march VFX (cosmetic, awaitable) | `_fx_march` | 1591 |
| resolve a stepped-on tile | `_enter_hex` | 1612 |
| the ring: propose / close / resolve | `_ring_intent` / `_try_close_ring` / `_resolve_ring` | 2468 / 2493 / 2504 |
| **ring readout text** | `_ring_label` | 2534 |
| crew bar (pips + proposal + Agree) | `_refresh_ring` | 2610 |
| snapshot build / apply | `_build_snap` / `_apply_snap` | 2218 / 2270 |
| cosmetic FX rider | `_fx_push` / `_fx_mark` / `_replay_fx` | 2189 / 2196 / 2204 |

The tile piece (`scripts/ui/hex_tile.gd`) is ALREADY a beveled "board piece": side (thickness),
terrain-fill top, light rim on the two upper edges, dark outline, optional pulsing ring. The Diorama
look is mostly re-tuning its `fill`/`side`/`rim`/`outline` + a felt backdrop, not a rewrite.

---

## 2. Stage 0 — select -> preview -> commit (the engine work)

**Goal:** first tap on a reachable tile *selects* it and shows The Writ; committing is a second,
explicit act. Theme-agnostic — valuable even before any Diorama pixels.

**New state (LOCAL, must NOT enter the snapshot):**
- `var hex_sel := ""` — the tile the local player is previewing. Per-seat view state, like a mouse
  hover; it is NOT in `_build_snap`/`_apply_snap`. (Contrast: contract `"select"` IS networked via
  `_apply_free`; hex preview deliberately is not — the *ring* is the shared channel.)

**`_on_hex_input` (:1577) becomes select-first for both modes:**
```
if reachable non-wall neighbour:
    if hex_sel != key:            # first tap: preview only
        hex_sel = key
        _clear_screen(); _build_hexcrawl()   # redraw shows The Writ
        return
    # second tap on the SAME tile == commit
    if mode == Mode.SOLO: await _enter_hex(key)
    else:                 _intent("hex", key)   # opens/【confirms】the ring, unchanged
```
- Tapping a *different* neighbour re-previews (cheap, local).
- Clear `hex_sel` on commit and whenever the board rebuilds after a tile resolves (`_resume_hex`).

**The Writ readout panel** — new helper `_build_writ(key)` called from `_build_hexcrawl` when a tile
should be shown. Precedence:
- if a ring is open on a `"hex"` (`ring["kind"]=="hex"`) -> show `ring["arg"]` (the shared, live plan),
- else if `hex_sel != ""` -> show `hex_sel` (my local preview),
- else -> nothing (default board).
Content = kind headline + bearing + the concrete stakes from the §0 table + `HEX_POST_FIGHT_HEAL`.
Reuse/【extend】`_ring_label` so the bar text and the Writ never drift (CLAUDE.md's standing note:
the stake belongs in `_ring_label`/`_refresh_ring`). Factor the per-kind copy into one
`_hex_stakes(h) -> {headline, stakes[]}` used by BOTH.

**The commit control** lives in the Writ panel:
- SOLO -> `PROPOSE THE MARCH` reads `MARCH` and calls `_enter_hex(hex_sel)`.
- co-op -> `PROPOSE THE MARCH  (aye n/m)`; calls `_intent("hex", hex_sel)`. The `n/m` reads the open
  ring's `ayes/required` (0/ m before proposing). The existing crew-bar `Agree` button
  (`_refresh_ring :2648`) stays as the fallback for the OTHER ring kinds (extract/event/endmonth).

**Netcode checks:**
- `hex_sel` stays out of `_strip_crew`/`_build_snap` — grep both after editing to confirm.
- Host taps still apply locally first (unchanged); a client's second-tap still just sends an intent.
- No new wire event. The ring already networks the shared decision; the Writ is a local render of
  networked state.

**Behaviour change to flag:** co-op used to propose on the FIRST tap; now it proposes on the second.
This is intended (preview before commit) but **`scenes/test/campaign_verify.tscn` may drive
`_on_hex_input` and will need its hex-proposal step double-tapped** (or it may call `_intent`/
`_ring_intent` directly and be unaffected). CHECK before coding; update the harness in the same change.

**Verify:** `campaign_verify` (target 81/81) + `combat_verify` (50/50, timing-flaky — rerun a red
once) run headless against live Supabase:
`Godot_v4.7-stable_win64_console.exe --headless --path . res://scenes/test/campaign_verify.tscn`.
Then the MCP visual loop for the solo preview (`play_scene` -> tap a tile -> `get_game_screenshot`).

**Rollback:** Stage 0 is additive (one new var, one branch, one helper). Reverting the `_on_hex_input`
branch restores the blind march.

---

## 3. Stage 1 — the Diorama board (skin)

**Goal:** the felt-and-wood table. No logic changes; pure `_build_*` + `hex_tile.gd` visuals, so it
networks to clients automatically.

- **Felt playmat:** in `_build_hexcrawl` (:1449-1454) replace the flat dark war-table `_rect` panel
  with a felt-green ground (rounded look via layered `_rect`s or a small `_draw` Control) and keep the
  brass rim rails. The board region is `x0=48,y=240,w=624,h=432`.
- **Carved-wood tiles:** tune `HexTile` defaults per tile in `_build_hex_tile` — warmer walnut `fill`
  for passable, deeper `side`, brighter top `rim`; keep the terrain tint as a *wash* over wood, not a
  flat color. Walls stay recessed (`flat = true`, already `:1479`).
- **Meeple tokens on `hex_cur`:** after the tiles, draw 3 small coin-metal discs clustered at
  `_hex_px(cur)` using `_class_col(cls)` for steel/gold/arcane, plus a faint "ghost" token on
  `hex_sel` to show the proposed move (mirrors the mockup). Keep the `🚩` `hex_flag` for the march VFX
  (`_fx_march` binds to it) — the meeples are additional, the flag still animates.
- **Brass rim chrome:** shrink the treasury/rent labels toward a thin top rail (cosmetic; HUD lives in
  `_build_hud`/`_refresh_hud`, mostly unchanged).

**Verify:** MCP screenshot loop only (no logic). Confirm on a client render too (`_render` calls the
same builder) — but visual-only, so a single-process solo screenshot is the fast check.

---

## 4. Stage 2 — The Writ (dress Stage 0's readout)

Style the Stage-0 panel as the parchment contract: aged-paper `_rect`, a red "THE WRIT" tab, the
`_hex_stakes` headline + body, and the commit button as a wax-stamped control. Optional EV stamp is
**out** unless §7 lands. Pure cosmetic over Stage 0's data.

**Verify:** MCP screenshot; confirm the co-op path shows the SAME Writ when someone else proposes
(the ring-open precedence from Stage 0).

---

## 5. Stage 3 — coin-metal party cards + vote pips

- Restyle `_build_exp_crew_token` (:1546) into the shipped Class-Power coin language: a metal-rimmed
  card per dwarf (steel/gold/arcane via `_class_col`), HP/DS readouts kept. This is the same metal
  vocabulary as `scripts/ui/power_orb.gd` — reference it so the two screens agree.
- Vote pips: in the Writ's commit button (co-op), draw a pip per required seat filling as ayes land,
  reading `ring["ayes"]`/`ring["required"]`. Keep `_refresh_ring`'s crew-bar pips as the canonical
  presence display; the button pips are a focused echo for the hex decision.

**Verify:** `campaign_verify` again (pips read ring state — make sure the restyle didn't touch ring
logic); MCP screenshot for the metals.

---

## 6. Netcode & host-authority summary (the guardrails)

- **One new piece of local state** (`hex_sel`), deliberately not networked. Everything shared already
  flows through the ring + snapshot.
- **No new wire event.** (Combat/campaign wire events must not collide — see CLAUDE.md. We add none.)
- **Clients redraw from the same builders**, so skins network for free; the only host-only logic is
  the commit (`_enter_hex`/`_intent`), unchanged.
- **FX rider:** if any Diorama beat needs to animate on every peer (e.g. a token "place" pulse), emit
  it from a primitive and add a `_replay_fx` case — do NOT invent a second path (M3b contract).
- Host taps apply locally and win ties; a client only ever sends intent. No change to that model.

---

## 7. Deferred / open questions

- **The "+EV" stamp** needs a payout-estimate model (combat pays no gold today). Options: (a) drop it,
  show concrete stakes only [default]; (b) add a light `_hex_expected_gold(h)` for reward/objective
  tiles only. Decide after Stage 2 looks right.
- **Two-tap on touch:** confirm the double-tap-to-commit reads well on mobile (no hover). The Writ's
  explicit button is the safety net — a mis-tap only previews.
- **`campaign_verify` harness** hex-proposal step (see §2) — the one place the behaviour change bites.
- **Sim:** none of this touches balance (`dorf_sim.py` unaffected); danger/heal/scale numbers unchanged.

---

## 8. Sequencing & the editor loop

Build order is the dependency order: **0 -> 1 -> 2 -> 3**. Stage 0 ships value alone (readout before
commit) even if the skin never lands. Suggested commits: one per stage.

Follow the project loop: build with MCP Pro editor tools -> `play_scene` -> `get_game_screenshot` ->
adjust. **Before starting: turn editor auto-reload ON** (`get_open_scripts` to check;
`EditorInterface.get_editor_settings().set_setting("text_editor/behavior/files/auto_reload_scripts_on_external_change", true)`)
and **re-grep your own markers after any `play_scene`** — a green test proves nothing about a file the
editor may have flushed over afterwards (bit hard on 2026-07-17). Never hand-edit `.tscn`/`project.godot`
while Godot is open. Netcode is verified HEADLESSLY (`campaign_verify`), never with two browser tabs
(memory `two-tab-multiplayer-testing-fails`).

**Effort:** Stage 0 = M (real logic + a harness touch), Stage 1 = M, Stage 2 = S, Stage 3 = S.
Overall the "board rebuild" is L, front-loaded into Stage 0's engine change; the rest is skin.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**Dorf Company** is a roguelike deckbuilder (Slay-the-Spire-style combat) where the player summons a demon lord, hands it an MBA, and puts it in charge of a dwarf company. The party is three randomly generated dwarves built from D&D class archetypes mapped onto Spire sub-archetypes:

- **Warrior** — signature resource *Momentum*. Pillars: Vulnerable/Aggression, Momentum/Combo, Bloodied/Endurance.
- **Sorcerer** — signature resource *Surge / Wild Magic*. Pillars: Surge/Burst, Metamagic/Modifiers, Elements/Status.
- **Paladin** — signature resource *Devotion / Oath*. Pillars: Smite/Devotion, Auras/Support, Block/Retribution.

Engine: **Godot 4.7-stable**, `gl_compatibility` renderer, 1280×720 viewport.

**Class model — RESOLVED (2026-07-17):** nine classes across THREE ARCHETYPES (tank/support/dps),
each with one **Class Power** fired from an orb on its portrait. See Current state.

**Party-combat model — RESOLVED (2026-06-30):** per-character decks + per-character energy, a clean player→enemy phase structure, and 3 simultaneous enemies with preferred-target orders + Taunt redirect (the spec's Slice 2). The party is now **Warrior (tank) / Cleric (support) / Sorcerer (dps)** — Paladin was replaced by Cleric, and the Momentum/Surge/Devotion resource system was dropped for synergy temp-effects (Mark/Channel/Aura/Fortify/Retaliate/Shield). See Current state. (The archetype framing below predates this and is aspirational lore, not the built model.)

## The three-source authority split (read this first)

Guidance for working in this repo is intentionally split across three sources. Respect the boundaries — do not let one trample another:

1. **GodotPrompter** owns *generic Godot 4 idioms* — FileAccess, `await`, signals, typed GDScript, "how to write Godot." (Installed as a Claude Code plugin / `.claude/skills/` entry. NOTE: not currently present in this checkout — see Current state.)
2. **MCP Pro's own CLAUDE.md** owns *editor-vs-runtime tool mechanics* — which tools need `play_scene` first, `execute_editor_script` format, batch node syntax, pitfalls. It lives at `godot-mcp-pro-v1.15.0/instructions/CLAUDE.md` and is also injected as the `godot-mcp-pro` MCP server instructions. Follow those rules; do not restate them.
3. **`.claude/skills/dorf-vfx/`** owns the *card-game design layer* — which effect, which class, what it should feel like. It defers everything else to the two sources above.

When GodotPrompter and dorf-vfx both apply: GodotPrompter owns "how to write Godot," dorf-vfx owns "what the effect should be."

## How work gets done: the agentic VFX loop

This project is built primarily by driving the **godot-mcp-pro** MCP server against a live Godot editor, not by hand-editing files:

```
build with MCP Pro editor tools → play_scene → get_game_screenshot → adjust → repeat
```

Treat "looks right" as a screenshot you actually took. The full editor/runtime tool catalog and workflow patterns are in `godot-mcp-pro-v1.15.0/instructions/CLAUDE.md`. The one rule that bites hardest: **runtime tools (`get_game_screenshot`, `simulate_key`, `simulate_*`, `get_game_*`, recording/testing) fail unless you call `play_scene` first.** Editor tools work on the open scene any time.

### Gotchas that will waste your time on VFX (learned 2026-06-29)
1. **`get_game_screenshot`/`capture_frames` capture with ~1–2s lag**, not instantly. A sub-second pulse (the real ~0.15s hit-flash) will be *over* by the time the capture lands, so it reads as "nothing happened" even when the effect fired correctly. To *verify* a transient effect, either (a) latch the effect's param high while an input is held and screenshot during the hold, or (b) read the param numerically via `execute_game_script` right after triggering. Don't trust a single post-trigger screenshot to disprove a transient effect — instrument the value.
2. **`simulate_key` drives the `Input` singleton's key-state (`Input.is_key_pressed`), not engine `_input(event)` delivery, and it sets `keycode` not `physical_keycode`.** Trigger logic that must respond to `simulate_key` should poll `Input.is_key_pressed()` / `Input.is_action_pressed()` (edge-detect in `_process`), not rely on `_input`/`_unhandled_input` events or `physical_keycode`. An explicit hold (`pressed:true` … `pressed:false`) is more deterministic than `duration`.
3. **`set_particle_color_gradient` HANGS Godot on 8-digit `#RRGGBBAA` hex** (froze the editor hard enough to need a restart). For a gradient with an alpha fade-to-transparent, skip that tool and set the color ramp via `execute_editor_script`: build a `Gradient` with `offsets`/`colors` PackedArrays of `Color(r,g,b,a)`, wrap in a `GradientTexture1D`, assign to `process_material.color_ramp`. (This is not a file write, so no `allow_unsafe_editor_io` needed.)
4. **Never reassign `GPUParticles2D.amount` every frame** — each change reallocates the particle buffer and resets emission, so a per-frame `amount = …` (e.g. recomputing it in `_process`) makes nothing render. Set it once on change (edge-detect the trigger), then `restart()`.

## Hard rules / pitfalls specific to this repo

- **Never hand-edit `project.godot` (or any `.tscn`/`.tres`) while Godot is open** — use `set_project_setting` / the MCP Pro scene tools. The editor overwrites the file. Prefer MCP Pro tools over emitting raw scene text in all cases; it mutates through Godot's UndoRedo system.
- **Prefer parametric VFX (particles + shaders) over spritesheets** for combat feedback — they're tunable through MCP Pro params and need no external art. Reserve authored spritesheets for things particles can't express (specific dwarf character art); don't fake those with particles.
- **Each reusable effect = a self-contained scene under `scenes/vfx/`**, instanced via `add_scene_instance` and freed with `queue_free()` after its lifetime.
- **Prefer inspector properties over hardcoded script values** — set visual properties (colors, sizes, transforms) via `update_property` so they stay visible/tweakable in the inspector; use GDScript only when the value must be dynamic.
- **The MCP server is NOT committed** — only the addon (`addons/godot_mcp/`) is. `/server/` and `node_modules/` are gitignored. The server build lives outside the project per its INSTALL.md.
- **⚠ If you edit a `.gd` file OUTSIDE the editor while that script is open in it, TURN AUTO-RELOAD ON
  FIRST** — otherwise the editor holds a stale buffer and **silently flushes it back over your edits**
  the next time you `play_scene`. This bit hard on 2026-07-17: a whole file's worth of changes to
  `overworld.gd` was reverted mid-session, and only a later `grep` caught it (the tests had already
  gone green against the fixed file). It is the `.tscn` rule above, for scripts.
  Check with `get_open_scripts`; fix with
  `EditorInterface.get_editor_settings().set_setting("text_editor/behavior/files/auto_reload_scripts_on_external_change", true)`.
  Then **re-grep for your own markers after any `play_scene`** — a green test proves nothing about a
  file the editor overwrote afterwards.
  (The older advice here said to *disable* auto-reload during agent sessions. That protects a running
  scene from mid-run reloads, and it is exactly what causes this. Prefer reload-on; if you must
  disable it, do not hand-edit `.gd` at the same time.)

## Status-condition visual grammar

Status pulses are class-agnostic and readable on any dwarf — one consistent look per status, driven by a shader param or modulate tween, never bespoke per class:
Burn = orange flicker · Chill = blue desaturate · Poison = green throb · Stun = yellow ring/stars · Bleed = red drip particles · Block = white shield shimmer.

## Repo layout

```
project.godot                 # Godot 4 project (no main scene set yet)
.mcp.json                     # MCP Pro server config (points at the external server build)
addons/godot_mcp/             # MCP Pro plugin (committed) — provides the live editor bridge
.claude/skills/dorf-vfx/      # card-game combat VFX skill (design layer)
  SKILL.md
  references/effect-recipes.md # per-effect MCP Pro call sequences (load on demand)
  references/shaders.md        # shader sources to create via create_shader (canvas_item)
scenes/{combat,vfx}/          # combat scenes; reusable VFX scenes
scripts/{combat,ui,vfx}/     # combat systems; reusable UI (card.gd, threat_arrows.gd); VFX scripts
  combat/class_powers.gd      # the 9 Class Powers + their hooks (combat.gd only routes the tap)
assets/{shaders,sprites}/     # shader sources; sprite art
resources/cards/              # card .tres resources
godot-mcp-pro-v1.15.0/        # the MCP Pro package (server + addon source + instructions); not part of the game
```

## Commands

- **Build / rebuild the MCP server** (run in the package's `server/` dir, requires Node 18+):
  `node build/setup.js install` — verify with `node build/setup.js doctor`.
- **CLI fallback** (when MCP tools aren't loaded, to save context): the same server exposes a CLI —
  `node godot-mcp-pro-v1.15.0/server/build/cli.js --help` (groups: project, scene, node, script, editor, input, runtime). Always start with `--help`.
- There is currently **no GDScript test runner, lint, or build step** wired up — the game is built and verified interactively through the MCP Pro loop, not a CLI test suite.

## Current state (2026-07-17) — THE THREE CLASS ARCHETYPES: 9 classes, 9 Class Powers

The three published design sheets (`design/cards/{class,support,dps}.html`) are **shipped**.
Plan + every design/engine contradiction and its resolution: `docs/plans/2026-07-17-class-archetypes-plan.md`.

- **The Class Power orb is now a HEARTHSTONE-STYLE COIN** (`scripts/ui/power_orb.gd`, a `_draw()`
  Control combat instances per dwarf; helpers `scripts/vfx/orbit_ring.gd` + `ring_pop.gd`). It is
  struck in its archetype's metal (tank=steel, support=gold, dps=arcane), **flips** to a spent face
  on cooldown (countdown + draining recovery ring), fills a rim arc for charge/communion, shows a
  5-segment pip ring for the Cleric's passive, and is ringed by **orbiting themed motes** while a
  stance is held (Enrage embers / Bard notes / Wild-Shape leaves). Hover opens a live tooltip. The
  widget is PURE cosmetic + input target: `combat._refresh_orb` derives one state dict from the SAME
  `Powers.can_fire` predicate the host re-validates the tap with, and the coin **diffs its own state**
  to fire the flip/burst/orbit — so every animation replays identically on host and client with **no
  new wire event** (it rides state the snapshot already carries). ⚠ The web glyph gate
  (`check_web_glyphs.py`) rejects `→` (U+2192, tofu on web) — the form/Flurry tips use `->`.
- **`role` is now the ARCHETYPE** — `tank` / `support` / `dps` (it used to double as the class id). A
  new **`cls`** key carries the class id. ⚠ `combat.gd`'s `crew_results` emitted `{"cls": a["role"]}`;
  the campaign index-matches and never read it, so it was dead data — which is exactly why it would
  have rotted silently. Enemy targeting keys off `role`: `_first_living_role("tank"/"support")`,
  `_first_living_nontank()`.
- **A Class Power is a second lever beside the hand** — `power` + `power_cd` on the party dict, fired
  by tapping your own dwarf's orb. `scripts/combat/class_powers.gd` owns all nine + the hooks;
  `combat.gd` only routes the tap. Co-op adds ONE wire event, **`submit_power`** (distinct from
  `submit_action`/`combat_ready`/`resync`/`ready`/`apply_snapshot`/`match_over` and the campaign's
  `camp_*` on the shared `Net` autoload).
  ⚠ **`_on_power` MUST gate on `_seat_ended`; `_on_action` does not and gets away with it by
  ACCIDENT** — ending discards your hand, so `_hand_index_of` returns -1 and the play dies on its own.
  A power has no card. Both suites assert this.
- **The 10-class roster.** `PARTY_ORDER` (warrior/cleric/sorcerer) is the canonical trio and is
  **unchanged** — the campaign gates its High job on it, the sim was tuned against it, and all four
  harnesses hardcode it. `warrior` takes **Action Surge** (the shipped Warrior *is* the Fighter
  archetype in simple form), so the default trio ships one power from each archetype. New
  **`ROLL_POOL`** (all 10) feeds lobby rolls + campaign recruits.
  - tank ⚔️ Warrior/Fighter (Action Surge) · Barbarian (Enrage) · Paladin (Divine Smite)
  - support 📿 Cleric (Channel Divinity, passive) · Bard (Bardic Performance) · Druid (Wild Shape)
  - dps 🗡️ Sorcerer (Metamagic) · Rogue (Assassin's Mark) · Monk (Flurry of Blows)
- **Guard IS the shipped `block` field** — a rename, never a second pool. It already soaks
  (`_enemy_attack`) and already pulls threat (`_pick_tankiest` sorts by block first). `gain_guard` is
  an alias arm on the `block` op. All party-side Guard writes funnel through **`_gain_guard()`**, so
  the Barbarian's "rage replaces Guard" is one early-return, not a rule every caller must remember.
- **`school`** (`block`/`physical`/`spell`) is on every card — a SECOND axis beside `type`, because
  Strike and Bolt are both attacks. The Druid's forms and the Sorcerer's Metamagic read it.
- **Momentum stays**, and stops pretending to be a DPS meter: it counts "did you attack this turn",
  which is exactly the Barbarian's rage upkeep. (`momentum_strike` is also in `CLASS_REWARDS`.)
- **Devotion is now PERSISTENT** (banked, not zeroed each phase) — a 3-turn cooldown you can't save
  across is a tax, not a cooldown. The legacy `divine_smite` card is easier to fuel as a result.
- **Traps that bite** (each cost a real bug, each is now asserted):
  - **`def["cost"]` can be the STRING `"X"`** (Whirlwind). Comparing String to int is a RUNTIME ERROR,
    not a review finding. Never read it raw — go through `_affordable` / `Powers.cost_of` / `_pool_of`.
  - **An op that loops the enemies inside an `all_enemies` card is N²** — `_apply_play` already loops.
  - **Quicken must consume on SCHOOL match, never a cost delta**: `empower` is a live 0-cost spell, and
    `maxi(0, 0-2) == 0 ==` its printed cost, so a delta check silently never fires.
  - **Twin re-runs the whole effect array**, so it is gated to spells that fan out nowhere
    (`_twinnable`) — `arc_lightning` carries a `dmg_all` INSIDE its effect.
  - **`_start_player_phase` ordering matters exactly once**: a Heightened spell resolves PRE-draw.
  - **`MOUSE_FILTER_STOP` only catches taps in the node's own rect** — a modal must be full-screen or
    the card fan stays live underneath it.
- **Verification — `scenes/test/powers_verify.tscn` is SOLO, deterministic and needs no Supabase**
  (a request with no `net` key never touches `Net`), so prefer it for rules work:
  `Godot_v4.7-stable_win64_console.exe --headless --path . res://scenes/test/powers_verify.tscn`
  **combat_verify 50/50 · campaign_verify 81/81 · powers_verify 103/103.**
  ⚠ `_first_living_role("support")` is **structurally invisible to combat_verify** — its 2-seat crew
  (warrior+sorcerer) has no support dwarf, so the lookup returns `{}` either way. `powers_verify`
  carries the 3-seat case. Fast syntax gate: `--headless --check-only --script <file>` (combat.gd
  errors on `Net` there — that's the autoload missing, not a defect).
- **Unsimmed, and the number to sim first:** every number is a placeholder. **Bear** is the blow-out —
  a 3-block hand is +15 Guard for zero energy, every turn, for 3 turns, and you still play the blocks.
  The Druid tithe (−2 hand) is paid ONCE: hands are discarded and redrawn to a fresh 5 each turn, so
  turns 2–3 pay out free. The sheet already names the lever (cost 2 cards → 3). `dorf_sim.py` has not
  seen any of this.

## Prior state (2026-07-12) — MULTIPLAYER: co-op combat + the co-op CAMPAIGN

- **Entry is the MAIN MENU** (`scenes/menu/main_menu.tscn`, the Pages root): Solo Play · Host Room ·
  Join Room. Host/Join dial **Supabase Realtime Broadcast** (`scripts/net/net.gd` — native
  `WebSocketPeer` speaking Phoenix v2 array frames, so the SAME code runs in the editor and in wasm;
  auto re-dials a dropped socket) and land in a room lobby keyed by a 4-char code. The lobby seats
  2-4 players (seat 0 = host = AUTHORITY), each picks 1 of 4 random dorfs, then either **Start Fight**
  (a skirmish) or **🏰 Start Campaign**.
- **Host-authoritative everywhere.** The host is the sole RNG and sole mutator; it broadcasts
  ABSOLUTE snapshots. Clients send intents and render. Every player pilots exactly ONE dwarf (their
  seat) — in combat AND across the whole campaign. Hands are public (co-op with friends); the draw
  pile is not. Everyone presses their own End Turn (✅ marker per seat).
- **The CAMPAIGN is now co-op** (`scripts/overworld/overworld.gd`, `enum Mode {SOLO,AUTHORITY,CLIENT}`).
  One company: one treasury, one rising rent, one contract board, one shop, one hex expedition.
  Design doc: `docs/plans/2026-07-12-campaign-coop-spec.md` (agent-authored; the SHIPPED build
  deliberately omits its ack ring-buffer, foreman hammer, seat-reclaim panel and autosave).
  - **The ring of ayes** — shared-risk decisions (embark · move to a hex · extract · event choice ·
    end month · a shop buy that dips *below the rent line*) are PROPOSALS that light a ✅ pip per seat
    on the crew bar and fire only when every PRESENT seat agrees. Proposing IS your aye. Everything
    else (navigate, select, claim a loot card, an affordable buy) is instant and yours alone.
    `RING_KINDS` + `_is_ring()` — consequence decides the tier, not the name.
  - **Wire events** (must never collide with combat's `submit_action`/`combat_ready`/`resync`/`ready`/
    `apply_snapshot`/`match_over` — the nested fight shares the one `Net` autoload):
    `camp_snapshot` · `camp_intent` · `camp_hello` · `camp_start`.
  - **Intents carry a per-seat `iseq`**; the host keeps a high-water mark and echoes it back in every
    snapshot. That one table is the dedupe AND the ack, so a fire-and-forget retry can never
    double-apply. Snapshots are ABSOLUTE, so a dropped one needs no resync — the next repairs it.
  - **The nested fight**: the host rolls the encounter, publishes it as `fight` inside the snapshot,
    and every peer instantiates `combat.tscn` as a child with `request.nested = true` + its own net
    block. `nested` makes combat hand control BACK to the campaign instead of `change_scene`-ing to
    the lobby; `match_over` carries `crew_results` so a client's parent scene reads the same HP the
    host does.
  - **The wagon rule (anti-lockout)**: a downed dwarf is hauled onto the wagon (it keeps rolling death
    saves there) and the player pilots an HEIR at the same seat on the NEXT tile — nobody spectates an
    expedition. Stabilise and the original takes its seat back with its deck; bleed out and the deck
    is what you lost. No `wounded` bench and no Recruit slot in co-op (a benched dwarf = a benched
    *player*). `_reseat_fallen()` / `_wagon_home()`.
  - **Party-size scaling**: encounters were sim-tuned for a crew of 3, so `_party_scale()` adds
    `(n-3) * PARTY_STEP` (0.34) **additively** to `enemy_scale`. ⚠️ PARTY_STEP is an unvalidated first
    guess — it has NOT been through `dorf_sim.py`.
  - **AFK escape hatch**: a seat that goes quiet for `ABSENT_SEC` (12s) is marked absent and pruned
    from the open ring, so one friend wandering off can't freeze the company. A seat is only ever
    removed from an open ring, never added to one.
- **Combat play is SIMULTANEOUS, and end-turn is order-free.** There is deliberately NO turn-order
  gate: `_on_action` validates seat/uid/energy/target and never asks "is it your turn". Both players
  act at once; the host resolves plays in the order it receives them (first come, first served — and
  note the host's own taps apply locally, so it wins a genuine tie). Ending is per-seat in any order
  (a client may end before the host); the enemy phase fires only when EVERY living seat has ended
  (`_all_alive_ended()`), and an ended seat can't sneak in another card. Locked down by
  `scenes/test/combat_verify.tscn` (39 checks).
- **M3b — THE FX RIDER: cosmetics replay on every peer** (2026-07-16). Snapshots say what the board
  IS; they cannot say what just HAPPENED (a landed hit and a fully-blocked one leave the same HP; a
  flurry folds into one number; a flag march happens BETWEEN two boards). So transient VFX ride the
  EXISTING snapshot as a top-level `fx` array — no new wire event, no autoload.
  - **The contract: fx are ADVISORY.** They never mutate state; a lost/duplicated/malformed fx costs
    an ANIMATION, never a desync, because the next absolute snapshot repairs the board anyway.
  - **The drain is the load-bearing part.** `_build_snapshot`/`_build_snap` DRAIN the buffer, so a
    beat ships exactly once — which is what makes the resync/hello/rejoin re-sends (a whole board
    with a fresh seq) carry no fx. ⚠ Both builders MUST keep exactly ONE caller (`_net_board` /
    `_push`); a second caller would silently eat a bundle. Both suites assert the drain.
  - **Why it's a bus, not a patch:** recording lives INSIDE the primitives (`_flash`/`_impact` — the
    whole of combat's visual vocabulary), so every existing call site and every FUTURE card, class or
    enemy move is networked the moment it's written. There is no second path to forget. A new *kind*
    of effect = emit it from a primitive + one case in `_replay_fx`. Entities carry a static
    `"side"`+`"slot"` wire address (`side` is load-bearing: Expose flashes a PARTY slot from an
    enemy move). Replay is CLIENT-only — the host already animates inline, so it would double-hit.
  - **Derive state, event only transients.** The treasury counts up on a client from the snapshot
    delta (`_tween_treasury_from`), no event spent. Only what no board can describe gets an fx.
- **VERIFY NETCODE HEADLESSLY — do not use browser tabs.** `scenes/test/campaign_verify.tscn` runs
  BOTH peers in one process against live Supabase, drives a scripted session, and prints PASS/FAIL
  (81 checks, all green as of 2026-07-16):
  `Godot_v4.7-stable_win64_console.exe --headless --path . res://scenes/test/campaign_verify.tscn`
  Sister scenes: `coop_harness.tscn` (combat) · `coop_campaign_harness.tscn` (campaign, visual).
  Chrome only ticks the FOREGROUND tab, so two tabs can never verify a round-trip (see memory
  `two-tab-multiplayer-testing-fails`). One `Net` autoload = one `peer_id`, which is exactly why the
  campaign protocol identifies a sender by its injected **seat int**, never by peer_id.
  ⚠ **`combat_verify` is TIMING-FLAKY against live Supabase** — a single red run is not proof of a
  regression. Re-run before believing one. Cosmetics leave no trace in board state, so the fx checks
  assert on `_fx_played` (a monotonic counter); `_fx_seen` is a capped ring whose size stops growing.
- **Known/deferred**: the client rebuilds its whole screen per snapshot (flicker, lost hover); no
  authority migration — if the HOST backgrounds its tab the company freezes (the 2s re-dial fixes the
  socket, not the frozen resolver); PARTY_STEP unsimmed. Campaign fx currently carry the flag march
  only — the dice cinematic and the coin bursts still don't replay (both fire on host-only paths;
  the coin burst's push lands 0.7s late, so it needs its own beat before it's worth shipping).

## Prior state (2026-07-01) — TWO modes: combat / overworld hex-crawl

- **Enemy variety + telegraphed intent (2026-07-01):** enemies now run MOVE ROTATIONS
  (`Db.ENEMIES[*].moves`, random start offset per instance; kinds attack/multi/attack_all/block/
  guard_all/rage_all/expose — expose = player-side Vulnerable 💥 ×1.5, decays 1/player-phase).
  Roster 3→7 (+Wolf 🐺 Howl-rage · Warden 🗿 Bulwark · Witch 🧿 AoE+Hex · Ogre 👺 2-beat CRUSH);
  `Db.ENCOUNTER_POOLS` rolls one of 4 comps per tier (`_roll_encounter`, falls back to
  ENCOUNTERS_BY_TIER). Intent UI: per-enemy latched move label with LIVE numbers (rage + target
  Vulnerable), kind-colored; threat arrows only for directed moves; hover/tap an enemy opens an
  intent panel (y≈40-132 band, x-clamped) with headline/move tip/Next/targeting tip. Enemy block
  clears phase-wide at enemy-phase start (Bulwark shields allies regardless of act order).
  Design doc: `docs/plans/2026-07-01-enemy-intent-variety-design.md`.
- **Scaling audit (2026-07-01) — "hard but not impossible":** the old tier×mod×danger MULTIPLIED
  composite (worst 2.688) was 0% winnable in a 96-cell Monte Carlo. Now: threat composes
  ADDITIVELY (`overworld.gd` `_hex_combat`/`_embark_fight`), enemy HP scales at full
  `enemy_scale` but damage/block at `dscale = 1+(escale-1)*ATK_SCALE_K(0.65)` (`combat.gd`
  `_start_combat`), Howl rage capped (`RAGE_CAP 8`, telegraphs show real gain / "max"), elite
  mod 1.40→1.50. V2 (sim re-run showed a 0%-win wall at the d3 band + double-tank comp):
  `DANGER_STEP` 0.30→0.21, high comp → brute+witch+caster (brute+brute was one outlier,
  brute+warden the opposite one), and `HEX_POST_FIGHT_HEAL 5` — living crew patch up after
  each WON combat hex (expeditions were pure attrition; long routes uncompletable). Worst
  reachable cell: escale 2.12; every worst-corner comp ≥2%. High·elite FULL-clears stay a
  prestige wall (structural, sim-proven untunable — accepted; the routable board + Extract
  keep the contract playable). Sim: scratchpad `dorf_sim.py` (+full_results/v2/v3/probes).
  Sim's bot policy is near-optimal — treat its 100% floor readings as bot ceiling, not
  "too easy for humans"; the trustworthy signals are the 0% cells.
- **Hex map visual overhaul (2026-07-01):** the expedition board now draws TRUE pointy-top hexes via
  `scripts/ui/hex_tile.gd` (a `_draw()` Control: beveled board-piece look, terrain-tinted fills per
  kind, hexagon-precise `_has_point` picking, pulsing amber/gold rings replacing the old rect frames,
  hover lift) on a framed war-table backdrop; the 🚩 tweens between hexes before a tile resolves
  (`run_epoch`-guarded). Geometry: `HEX_R=50`, board centered via `_hex_px`. Design doc:
  `docs/plans/2026-07-01-hexmap-civ-visual-design.md`. Zero logic changes.

- **Cleanup (2026-07-01):** the **survivors** mode and the **Fire-Emblem grid** fork were REMOVED —
  direction consolidated onto the overworld/contract system. Deleted: `scripts/survivors/` +
  `scenes/survivors/`, `scripts/combat/grid_combat.gd` + `scenes/combat/grid_combat.tscn`, and dead
  scaffolding (`scripts/combat/test_arena.*`, `scenes/_emoji_test.tscn`, the superseded
  `scripts/ui/target_arrow.gd`), plus their two `export_presets.cfg` presets and `deploy-pages.yml`
  export steps. The survivor-only combat content — **Cripple** status, walker/lurker/spitter zombies,
  Brute/Medic/Engineer classes, and the `heal_lowest`/`ally_gain_energy`/`dmg_per_bloodied_ally`/
  `apply_all`/`cripple` ops — was stripped from the shared `card_db.gd` + `combat.gd`; both still
  compile and base combat + the overworld are unaffected (kept Burn/Vulnerable/Mark/Momentum/Devotion
  intact). Grid-only inline card fields (`range`/`area`/`area_affects`/`move`) were left as inert data
  since nothing reads them now (safe to strip later if grid is never revived). The survivors + grid
  design docs under `docs/plans/` are kept as historical record.
- **TWO deployed modes / two Pages URLs:** `/` combat (Slice 2 base combat) · `/overworld/` hex-crawl
  expedition + shop. CI sed-patches `run/main_scene` per export (2 export presets + 2 export steps in
  `deploy-pages.yml`).
- **The hex-crawl was REDESIGNED (2026-07-01) from a fogged crawl into a VISIBLE-BOARD route-planner:**
  the whole 6×5 offset-hex map is shown, perimeter = impassable wall, the objective location is MARKED,
  tiles telegraph KIND + ☠ danger; enemy scale comes from a tile's danger (not depth); "objective pays
  big" (rescue = full PAYOUT[tier] + loot bag, extract = loot only). See the hex-crawl spec (updated).
  Radius-2 fogged axial hex map, hidden objective at depth ≥ 2, push-or-extract after every tile;
  content = combat/reward/event/empty/objective. **Each combat hex reuses the SAME seam** (crew=party,
  `enemy_scale = tier × mod × (1+depth·0.20)`, HP carried in/out, `run_epoch`-guarded across every await).
  The fixed 3 crew ride every fight; a downed dwarf enters at 0 HP as a benched slot (combat's 3-slot
  rule — `alive = hp>0`, standalone stays byte-identical). **Death saves** (`LOSS_ENABLED = true` now):
  0-HP dwarf rolls each tile, 3 succ = stable, 3 fail = dead; extract saves them; **Recruit** (shop)
  refills the roster so loss is fair. Resolution maps to the UNCHANGED `{success,payout,pending}` shape
  (objective = `depth_pay + OBJECTIVE_BONUS`, extract = `depth_pay(deepest)`, wipe = 0). One expedition =
  one campaign (doesn't tick the clock). **Shop** on the contract board (monthly re-roll): Card /
  Field Medic / Recruit — every buy trades against rent. Low stays the dice lifeline (economy gate intact).
- **NEW combat cards/ops (2026-07-01):** 18 additive cards (`card_db.gd`) + a `_run_ops` dispatcher
  (`combat.gd`) with new systems — **Burn** 🔥 (enemy status, ticks at enemy-turn start, decays −1),
  **Vulnerable** 💥 (×1.5, stacks multiplicatively with Mark ×1.25), **Momentum** ⚔️ (per-char attacks →
  Momentum Strike), **Devotion** 🙏 (per-char skills → Divine Smite spend), Empower `next_card_double` ✨,
  Whetstone `buff_next_attack` 🪨, `retain_block`, conditionals `if_bloodied`/`if_target_marked`/
  `spend_devotion`/`on_kill`, `dmg_all`, `party_block`, `heal_self`/`heal_ally`, `gain_energy`.
  9 generic cards joined `REWARD_POOL`; class cards are role-locked (offered on hex reward tiles via
  `CLASS_REWARDS`). `describe()` renders every new card's live body. New op alias: `dmg`==`damage`,
  `self_dmg`==`self_damage`. All verified via `execute_game_script` state dumps.

## Prior state (2026-06-30) — Slice 2 party puzzle

- **Three deployed modes / three Pages URLs** (root `main_scene` stays combat; CI seds per-export):
  `/` = combat (Slice 2, below) · `/grid/` = the Fire-Emblem grid fork (`scenes/combat/grid_combat.gd`) ·
  `/overworld/` = the **Overworld MVP fee-clock economic layer** (the spec's "second layer"). Each is a
  self-contained bare-`Control` scene, all-UI-in-code; each has its own `export_presets.cfg` preset +
  `deploy-pages.yml` export step. The overworld WRAPS combat with a dice-roll STUB (does not call it —
  real combat hook is Step 4). See `docs/plans/2026-06-30-overworld-mvp-{spec,plan}.md`. Step-1 economy
  is tunable `const`s in `overworld.gd`; Step-2 seams (`CREW_SELECT`, `LOSS_ENABLED`) are gated off.
  Known open question flagged to the user: careful Low-only grind wins by month 12 in sim (possible A2
  "obvious choice") — one-line levers `PAYOUT.low 30→25` or `START_TREASURY 100→80` if playtest confirms.
- Renderer gl_compatibility, **portrait 720×1280**, emoji presentation, deployed to GitHub Pages. `application/run/main_scene` = `scenes/combat/combat.tscn`.
- **The combat is the spec's Slice 2 "party puzzle"** (reworked from the earlier mobile prototype). `scripts/combat/combat.gd` (all UI built in code) + `scripts/combat/card_db.gd` (data) + `scripts/ui/{card,threat_arrows}.gd` + the `momentum_hit` VFX.
- **Roles** (replaced the old Warrior/Sorcerer/Paladin + resources): Warrior 🛡️ 36hp (tank), Cleric ⛑️ 28hp (support), Sorcerer 🧙 22hp (dps). Each its own deck + per-character energy (3). No signature-resource system — synergy comes from temp-effects.
- **Clean phases:** PLAYER phase (tap a dwarf to make it active, sequence all three in any order) → ENEMY phase. Block/buffs set in the player phase persist through the following enemy phase, then reset next player phase. `attacks_this_turn` is **party-wide** (feeds Arcane Finisher). Enemy-phase pacing uses `await create_timer` (`combat_epoch` guards Play-Again re-entrancy).
- **3 archetype enemies with PREFERRED TARGETING + live threat arrows** (`threat_arrows.gd`): Brute 👹 45/atk9 → tankiest (block, then maxHP); Assassin 🥷 30/atk6 → Healer→DPS (skips tank); Caster 🔮 28/atk5 → lowest current HP. Arrows draw enemy→target during the player phase and update live (kills reroute; **Taunt** snaps all to the Warrior). Taunt has a no-two-in-a-row cooldown.
- **Cards (data)**: chassis Strike(6)/Guard(5) + Cleave/Wall variants; Warrior Taunt/Retaliate/Fortify; Cleric Channel Shield/Mend-or-Smite/Aura of Valor; Sorcerer Mark(+25%, the ONLY multiplier)/Channel(+3×2)/Arcane Finisher(5+3·attacks). `_resolve()`+`_attack()` are the only place ops execute. Ops: damage, block, self_damage, draw, damage_scaling, heal_or_damage, apply_status(marked), force_target_all, temp(retaliate/fortify/channel), shield_ally, party_buff. **Resolution order** (`_attack`): base → +flat (Channel/Aura) → ×Mark(1.25) → block,hp → Retaliate. Fortify's +5 is gated to Guard via a `fortifiable` data tag; `temp.fortify` (Retaliate +2) and `temp.fortify_guard` (next-Guard +5) are separate flags.
- **Card UI** (`card.gd`): type-tinted frame + cost orb + emoji + generated body with LIVE numbers (`Db.describe(def, ch, party_buff, attacks_played)`), hover-lift + fan rotation, hover/tap tooltip (rules + plain explainer). **Interaction is two-tap** (first tap selects + shows tooltip + arms target cards; second tap plays self/all; target cards play by tapping a target) — works on touch and desktop. Reticle cursor + target highlights while armed; status badges (🛡️ 🔰 🌀 🔧 🔁) + 📣 Aura readout.
- **Verified + hardened**: preferred-target arrows, Taunt redirect, the worked combo math (Mark→Channel→Strike×2 = 14+14 kills the 28-HP Caster; party-wide Finisher 5+3×2=11), Fortify gating + flag split. Passed an adversarial spec-conformance review (21 findings fixed/triaged).
- **Tuning tension to decide:** spec lists Sorcerer energy 3 AND solo 4-energy "worked combos" (Mark+Channel+Strike+Strike) — not castable solo in one turn; the party-wide Finisher line IS reachable, the solo combo is treated as illustrative. Bump Sorcerer energy to 4 only if playtests want the solo line.
- **Deferred/known:** Channel charge consumed per-target on multi-hit attacks (latent — Cleave/Wall defined but in no deck); tooltip can overflow the right edge for the rightmost card; Mark's +25% doesn't apply to Retaliate reflect. No `resources/cards/` .tres. **GodotPrompter (authority source #1) still not installed.** `scripts/validate_tscn.py` (referenced by dorf-vfx) does not exist. Web verification caveat: a hidden/minimized automation tab pauses the rAF loop so timer-paced enemy turns appear frozen — foreground to test (see memory `publish-web-builds-to-pages`).

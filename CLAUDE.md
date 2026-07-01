# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**Dorf Company** is a roguelike deckbuilder (Slay-the-Spire-style combat) where the player summons a demon lord, hands it an MBA, and puts it in charge of a dwarf company. The party is three randomly generated dwarves built from D&D class archetypes mapped onto Spire sub-archetypes:

- **Warrior** — signature resource *Momentum*. Pillars: Vulnerable/Aggression, Momentum/Combo, Bloodied/Endurance.
- **Sorcerer** — signature resource *Surge / Wild Magic*. Pillars: Surge/Burst, Metamagic/Modifiers, Elements/Status.
- **Paladin** — signature resource *Devotion / Oath*. Pillars: Smite/Devotion, Auras/Support, Block/Retribution.

Engine: **Godot 4.7-stable**, `gl_compatibility` renderer, 1280×720 viewport.

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
- **Disable editor script auto-reload during agent sessions.**

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
scripts/{combat,ui,vfx}/     # combat systems; reusable UI (card.gd, target_arrow.gd); VFX scripts
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

## Current state (2026-06-30) — Slice 2 party puzzle

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

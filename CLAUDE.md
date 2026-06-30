# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**Dorf Company** is a roguelike deckbuilder (Slay-the-Spire-style combat) where the player summons a demon lord, hands it an MBA, and puts it in charge of a dwarf company. The party is three randomly generated dwarves built from D&D class archetypes mapped onto Spire sub-archetypes:

- **Warrior** — signature resource *Momentum*. Pillars: Vulnerable/Aggression, Momentum/Combo, Bloodied/Endurance.
- **Sorcerer** — signature resource *Surge / Wild Magic*. Pillars: Surge/Burst, Metamagic/Modifiers, Elements/Status.
- **Paladin** — signature resource *Devotion / Oath*. Pillars: Smite/Devotion, Auras/Support, Block/Retribution.

Engine: **Godot 4.7-stable**, `gl_compatibility` renderer, 1280×720 viewport.

**Open design blocker** (gates deeper class work): the party combat model — shared deck vs per-dwarf decks, targeting, simultaneous enemy count. Paladin auras and Sorcerer status conditions both depend on this decision; don't hardcode assumptions about it.

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

## Current state (2026-06-30)

- Setup verified: addon enabled, server built, `.mcp.json` live (`get_project_info` OK). Renderer gl_compatibility, **portrait 720×1280**.
- **Mobile party prototype is built, verified, and DEPLOYED to the web.** `scenes/combat/combat.tscn` + `scripts/combat/combat.gd` (all UI built in code) + `scripts/combat/card_db.gd` (data). Flow: 3 dwarves (Warrior/Sorcerer/Paladin), **each its own 13-card deck**, vs **1 boss + 4 minions**, on a **unified initiative** track (one d20 roll per combatant → single interleaved order). Win/lose → Play Again. `application/run/main_scene` = combat.tscn.
- **Everything is emoji**, no authored art: dwarves 🪓🧙😇, enemies 👹👺👻💀🦇, cards carry an emoji "art". Web emoji rendering is solved (vector fonts only — see memory `publish-web-builds-to-pages`).
- **Cards are data** (`card_db.gd`): `CARDS` (effect = `[op, ...args]`), `CLASSES` (per-class deck + signature resource), `ENEMIES`/`ENCOUNTER` (telegraphed intents). `combat.gd::_resolve()` + `_attack()` are the ONLY place ops execute — a new card is a new row. Ops: damage, block, self_damage, draw, resource, damage_per_resource, resource_if_bloodied, status, status_per_resource, power.
- **Card-engine clarity layer (Slay-the-Spire / Hearthstone study, 2026-06-30):**
  - `card_db.gd` gained a DISPLAY layer: `card_type()` + `type_tint()` (frame colour: red=attack, blue=skill/defense, violet=power) and `describe(def, dwarf)` which GENERATES the card body text from its ops with **live, recolored numbers** (e.g. Smite shows "Deal 4 (+3/Devotion)", green when buffed). Single source of truth → the card face can't desync from `_resolve()`.
  - `scripts/ui/card.gd` — reusable hand-card Control: tinted frame + cost orb + emoji + generated body; **hover-lift + fanned base rotation**, instanced per hand card by `combat.gd::_rebuild_hand` on a manual arc (NOT a container).
  - **Targeting**: clicking an enemy-target card arms it → OS cursor swaps to a procedural **reticle** (`_make_reticle`/`_update_cursor`) + all enemies highlight gold + a **Hearthstone bezier targeting arrow** (`scripts/ui/target_arrow.gd`, driven each frame by `combat.gd::_process` from the active dwarf to the cursor, snapping green onto a hovered enemy).
- **Web/GitHub Pages pipeline is live** (manual `workflow_dispatch`) — repo + Pages URLs and the deploy/font gotchas are in memory `publish-web-builds-to-pages`.
- **Still open / watch:** Mark is still a placeholder amp — in `_attack` the target's Mark adds to damage but is NOT shown on the card face (a known clarity gap; resolve when Mark is redefined). No `resources/cards/` .tres yet (cards are inline dicts). No numeric balance pass. **GodotPrompter (authority source #1) is still not installed** — be careful with generic Godot idioms. `scripts/validate_tscn.py` (referenced by dorf-vfx) does not exist (fallback only).

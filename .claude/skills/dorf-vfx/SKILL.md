---
name: dorf-vfx
description: >
  Combat VFX and animation conventions for "Dorf Company", a roguelike deckbuilder where
  the player runs a dwarf company for a summoned demon lord. Three D&D-style classes drive
  distinct effects: Warrior (Momentum), Sorcerer (Surge/Wild Magic), Paladin (Devotion/Oath).
  Use this skill whenever the task touches combat visuals: particle effects, shaders, hit
  flashes, smites, auras, status-condition pulses, card-play feedback, screen shake, or
  animation for the dwarf party. It assumes the godot-mcp-pro MCP server is connected and
  drives its tools directly. Trigger it even when the user does not say "VFX" or "Dorf" —
  any mention of smite, surge, aura, momentum, devotion, status effect, card feedback,
  particles, shaders, or combat juice should pull it in. This skill defers all generic
  GDScript/Godot idioms to GodotPrompter and all editor/runtime tool mechanics to the
  godot-mcp-pro CLAUDE.md; it only adds the Dorf-specific design layer on top.
---

# Dorf Company — Combat VFX & Animation

## Scope and what defers elsewhere
- This skill is ONLY the card-game design layer: which effect, which class, which feel.
- Generic Godot 4 idioms (FileAccess, await, signals, typed GDScript) → GodotPrompter skills.
- Tool mechanics (editor vs runtime split, play_scene first, execute_editor_script format) → the godot-mcp-pro `CLAUDE.md` already in this project. Do not restate those rules; follow them.
- When both this skill and GodotPrompter could apply, GodotPrompter owns the "how to write Godot", this skill owns the "what the effect should be".

## Build VFX through MCP Pro tools, not hand-written .tscn
MCP Pro mutates scenes through the editor's UndoRedo system. Prefer its tools over emitting raw `.tscn`/`.tres` text. Concretely:
- Particles: `create_particles`, then `set_particle_material`, `set_particle_color_gradient`, optionally `apply_particle_preset`. Inspect with `get_particle_info`.
- Shaders: `create_shader`, `assign_shader_material`, `set_shader_param`. Read back with `get_shader_params`.
- Animation: `create_animation`, `add_animation_track`, `set_animation_keyframe`; AnimationTree/state machines via the AnimationTree tools.
- Nodes/props: `add_node` / `batch_add_nodes`, then `update_property`. Follow Pro's house rule — prefer inspector properties via `update_property` over hardcoding visual values in script.
- Verify visually: build → `play_scene` → `get_game_screenshot` (or `capture_frames`) → adjust. Treat "looks right" as a screenshot you actually took.

## Core VFX strategy
- Prefer PARAMETRIC effects (particles + shaders) over frame-based spritesheets for combat feedback. They're tunable through MCP Pro params and need no external art — the right call given the agentic pipeline.
- Reserve authored spritesheets for things parametric effects can't express (specific dwarf character art). For those, generate frames externally and import; don't fake them with particles.
- Each reusable effect = a self-contained scene under `scenes/vfx/`, instanced on demand via `add_scene_instance` and freed with `queue_free()` after its lifetime.

## Class VFX identities (keep them mechanically legible)
Each class's signature resource must read instantly on screen. Color + motion language per class:

- **Warrior — Momentum.** Impact-driven, grounded, kinetic. Burst particles on hit (high `explosiveness`, `one_shot`), short hard screen shake, white→orange flash. Momentum stacks → escalate particle `amount` and shake magnitude so a high-Momentum hit visibly hits harder. Palette: steel grey, blood orange, sparks.
- **Sorcerer — Surge / Wild Magic.** Chaotic, airborne, unstable. Floaty particles (gravity 0, turbulence on the process material), color-shifting gradients, arcs between targets. Surge spent → bloom of additive light. Wild Magic randomness → randomize hue/spread per cast so no two surges look identical. Palette: violet, cyan, electric white.
- **Paladin — Devotion / Oath.** Steady, radiant, protective. Persistent orbiting aura particles (tangential accel, looping not one_shot), soft pulsing glow, vertical light shafts for smites. Devotion level → aura radius and brightness. Palette: gold, warm white, pale blue.

## Recurring effect recipes
Reference (load on demand): `references/effect-recipes.md` has the per-effect MCP Pro call sequences for:
hit-flash, smite shaft, surge arc, devotion aura, status pulses (burn/chill/poison/stun), card-play feedback, death dissolve, screen shake.

Shader sources to create via `create_shader`: `references/shaders.md` (hit-flash, dissolve, holographic-rare, aura-glow — all `canvas_item`).

## Status conditions — shared visual grammar
Status pulses must be class-agnostic and readable on any dwarf. One consistent look per status, driven by a shader param or modulate tween, NOT bespoke per class:
- Burn = orange flicker, Chill = blue desaturate, Poison = green throb, Stun = yellow ring/stars, Bleed = red drip particles, Block = white shield shimmer.

## When to stop and ask
- Effect needs authored art frames → surface it; don't approximate with particles.
- Shader needs hand-tuned GPU performance → flag it; defer to profiling tools (`get_performance_monitors`).
- A new class/status is introduced with no defined visual identity → ask for its color+motion language before inventing one, so the legibility stays consistent.

## Offline validation (optional)
If you ever hand-write a `.tscn`/`.tres` outside MCP Pro (rare — avoid it), `scripts/validate_tscn.py <path>` lints headers, duplicate ids, and parent paths. With MCP Pro driving scene writes through UndoRedo this is a fallback, not the main path.

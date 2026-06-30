# Effect recipes — MCP Pro call sequences

Each recipe is the tool order to build the effect. Tool names are godot-mcp-pro's.
Build in editor, then `play_scene` → `get_game_screenshot` to verify.

## Hit flash (any class, on damage)
Shader-driven, cheapest. Reused everywhere.
1. `create_shader` with the hit-flash source (see shaders.md), e.g. `res://assets/shaders/hit_flash.gdshader`.
2. `assign_shader_material` to the target dwarf's Sprite2D.
3. On damage, tween `flash` 0→1→0 over ~0.15s via `set_shader_param` (or an AnimationPlayer value track on `material:shader_parameter/flash`).

## Warrior — Momentum impact burst
1. `create_particles` GPUParticles2D under `scenes/vfx/momentum_hit.tscn`, `one_shot=true`.
2. `set_particle_material`: high `initial_velocity`, `explosiveness=1.0`, gravity (0, 400, 0) for spark fall, short `lifetime` ~0.4.
3. `set_particle_color_gradient`: white → blood-orange → transparent.
4. Scale `amount` and screen-shake magnitude by current Momentum stacks (pass as param).
5. Pair with hit-flash above. Add screen shake (see below).

## Sorcerer — Surge arc + bloom
1. `create_particles` floaty set: gravity 0, turbulence on via `set_particle_material` (turbulence_enabled, noise_strength ~1.0).
2. `set_particle_color_gradient`: violet → cyan → electric-white, additive (`CanvasItemMaterial` blend add via `update_property`).
3. Randomize hue offset + `spread` per cast (Wild Magic identity) — vary the gradient or a shader hue param each call.
4. For target-to-target arc, a Line2D or a stretched particle trail between caster and target.
5. On Surge spend, `apply_particle_preset` a bright one-shot bloom at the target.

## Paladin — Devotion aura (persistent)
1. `create_particles` looping (NOT one_shot) under the dwarf.
2. `set_particle_material`: emission ring, tangential accel for orbit, gravity 0, low velocity.
3. `set_particle_color_gradient`: gold → warm-white, additive.
4. Aura radius + brightness scale with Devotion level (`update_property` on emission radius + a glow shader param).

## Paladin — Smite shaft
1. Vertical light: a tall Sprite2D/Polygon2D with the aura-glow shader, or a one_shot upward particle column.
2. Flash `flash`/intensity param on impact, fade over ~0.3s.
3. Stack with hit-flash + a brief gold screen tint.

## Status pulses (shared grammar)
One reusable scene `scenes/vfx/status_pulse.tscn` parameterized by status:
- Drive a shader hue/modulate param: Burn=orange flicker, Chill=blue desat, Poison=green throb, Stun=yellow ring, Bleed=red drip particles, Block=white shimmer.
- Loop while the status is active; stop on clear. Keep it subtle so it never masks class VFX.

## Card-play feedback
1. On play, a quick scale-punch Tween on the card (`create_tween`, scale 1.0→1.1→1.0 over 0.12s).
2. Trail particles from card to target in the casting class's palette.
3. Brief glow on the target before the main effect lands (telegraph).

## Death dissolve (dwarf or enemy)
1. `create_shader` dissolve (see shaders.md), `assign_shader_material`.
2. Tween `threshold` 0→1 over ~0.6s; spawn a small ember `create_particles` burst at midpoint.

## Screen shake
Keep one reusable Camera2D shake helper (a script in `scripts/combat/`). VFX recipes just call it with a magnitude:
- Warrior hits: hard, short (mag scales with Momentum).
- Smite: medium with a gold tint flash.
- Surge: light, high-frequency jitter.
Verify feel by `capture_frames` across the shake window.

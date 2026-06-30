# Dorf Company

Roguelike deckbuilder. You summon a demon lord to fill a job order, hand it an MBA, and
put it in charge of a dwarf company. Slay-the-Spire-style combat, D&D class archetypes
mapped to Spire sub-archetypes. Party = three randomly generated dwarves.

## Class design (current)
- **Warrior** — signature resource Momentum. Pillars: Vulnerable/Aggression, Momentum/Combo, Bloodied/Endurance.
- **Sorcerer** — signature resource Surge/Wild Magic. Pillars: Surge/Burst, Metamagic/Modifiers, Elements/Status.
- **Paladin** — signature resource Devotion/Oath. Pillars: Smite/Devotion, Auras/Support, Block/Retribution.

Open design question (blocker for deeper class work): the party combat model — shared deck
vs per-dwarf decks, targeting, simultaneous enemy count. Auras (Paladin) and status
conditions (Sorcerer) depend on this.

## Repo layout
```
dorf-company/
├── project.godot                 # open this in Godot 4
├── .mcp.json                     # MCP Pro server config (edit the path — see Setup)
├── addons/godot_mcp/             # ← you copy this in from the MCP Pro zip
├── .claude/skills/dorf-vfx/      # card-game combat VFX skill (design layer)
├── scenes/{combat,vfx}/          # combat scenes and reusable VFX scenes
├── scripts/{classes,combat}/     # class logic and combat systems
├── assets/{shaders,sprites}/     # shader sources, sprite art
└── resources/cards/              # card .tres resources
```

## Setup order
1. **Install GodotPrompter** (base Godot-4 idioms) as a Claude Code plugin or into `.claude/skills/`.
   It owns generic GDScript/Godot knowledge; `dorf-vfx` only adds the card-game layer.
2. **Install MCP Pro addon**: copy `addons/godot_mcp/` from the paid zip into this project,
   then enable it: Project → Project Settings → Plugins → Godot MCP Pro → Enable.
   Look for the green dot in the "MCP Pro" bottom panel.
3. **Build the MCP Pro server** (lives OUTSIDE this project, per its INSTALL.md):
   `cd /path/to/extracted/server && node build/setup.js install`
4. **Point this project at it**: edit `.mcp.json` so the `args` path matches your extracted
   `server/build/index.js`. (Claude Code = Full mode / 172 tools is fine.)
5. Open the project in Godot with the plugin enabled, start Claude Code in this directory.

## Agentic VFX loop
Build effect with MCP Pro editor tools → `play_scene` → `get_game_screenshot` → adjust →
repeat. The `dorf-vfx` skill carries the per-class effect recipes; MCP Pro's own `CLAUDE.md`
carries the editor-vs-runtime tool rules. Disable editor script auto-reload during sessions.

## Notes
- Never hand-edit `project.godot` while Godot is open — use `set_project_setting`.
- The MCP server is NOT committed here (see `.gitignore`); only the addon is.
- Prefer parametric particle/shader VFX over spritesheets for combat feedback.

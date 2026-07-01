# Hex-crawl map: Civ-style visual overhaul — design

**Date:** 2026-07-01 · **Scope:** visual + usability only; zero gameplay/logic changes.
**Chosen depth (user):** Full overhaul + motion (painted beveled hexes, hover lift, pulsing
highlights, animated movement, bigger board).

## Problem

The expedition map is hex-*positioned* (odd-r offset rows) but each tile is a plain
`ColorRect` square. It reads as a misaligned grid of boxes, not a hex map.

## Design

### 1. True pointy-top hexes, drawn in code

New `scripts/ui/hex_tile.gd` — a `Control` subclass with `_draw()`:

- **Pointy-top hexagon** (vertices at −90°, −30°, … — matches the existing odd-r layout,
  same orientation as Civ 5). Radius `R = 50` → hex width ≈ 86.6, row spacing = 75.
- **Faux-3D board-piece bevel:** a darker "side" hexagon offset ~6px down (tile thickness),
  the terrain fill on top, a light polyline along the two upper edges (light-from-above rim),
  and a thin dark outline so tiles read as interlocking pieces. Wall tiles draw **flat**
  (no thickness) so passable tiles pop off the board.
- **Precise picking:** `_has_point()` overridden with a point-in-hexagon test so clicks in
  the bounding-box corners never hit the wrong tile.
- **Highlight ring:** an optional outer polyline ring whose alpha pulses on a looping tween —
  amber for reachable tiles, gold for the objective.
- **Hover (reachable only):** tile lifts 4px and its fill brightens; reverts on exit.

### 2. Terrain-tinted fills (kind → color)

wall = dark slate 🏔️ · current = steel-blue 🚩 · objective = rich gold 🏁 ·
combat = dusty red-brown ⚔️ · reward = mossy green 🎁 · event = murky purple ❔ ·
empty = neutral grey-green · resolved = desaturated of its base. Emoji glyphs and
☠-danger pips are unchanged — they're the established presentation language.

### 3. Board presentation

- Board scales up (R=50, ~563×~400px) and centers; a dark **war-table backdrop** panel with
  a thin border frames it so the map sits *on* something instead of floating.
- The gold/amber `ColorRect` frames (old reachable/objective affordance) are replaced by the
  pulsing rings.

### 4. Motion

- **Animated movement:** clicking a reachable hex hides the current 🚩 glyph, tweens a 🚩
  token from the current hex center to the target (~0.28s quad ease), *then* resolves the
  tile. `busy` + `run_epoch` already guard re-entrancy; the epoch is re-checked after the
  tween await.
- Existing full-rebuild flow (`_clear_screen()` → `_build_hexcrawl()`) is kept; loop tweens
  die with their freed nodes.

## Non-goals (YAGNI)

No fog, no camera pan/zoom, no pathfinding preview (movement is adjacent-only), no texture
assets, no changes to map gen / resolution / economy.

## Verification

MCP-Pro loop: play the overworld scene, force an expedition via `execute_game_script`
(fabricate `current`, call `_open_expedition`), `get_game_screenshot` for the board look,
simulated clicks for movement animation + picking. Transient-pulse caveat applies — read
ring alpha numerically rather than trusting one screenshot.

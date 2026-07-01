# Enemy variety + telegraphed intent — design

**Date:** 2026-07-01 · **Scope:** combat enemies only; request/result seam unchanged.
**Chosen depth (user):** move patterns for every enemy + a bigger roster + StS-style intent
(always-visible glyph + number; hover/tap explains it).

## Audit summary (what exists)

An enemy is a dict `{archetype … atk, pref, block, burn, vulnerable, node, slot}`
(`combat.gd:217-231`) whose entire behavior is one flat attack on a preferred target every
turn (`_enemy_phase` `combat.gd:292-329`). Cheap levers found by the audit: enemy `block` is
fully plumbed but never granted; `Db.ENEMIES[*].tip` strings are authored but never rendered;
`intent_target` is vestigial; the y≈50–126 band above the enemy row is free; `card.gd`'s
tooltip + two-tap pattern and `hex_tile.gd`'s hover pattern are reusable precedents.
Hard constraints: exactly 3 enemy slots; `combat_finished` shape is load-bearing;
`combat_epoch` guard after every await; web-safe emoji only; `card_db.gd` changes additive.

## Move patterns (data, `card_db.gd` — additive)

Each `ENEMIES` entry gains a `moves` array — a fixed **rotation** (legible, learnable),
started at a random offset per enemy instance so duplicate enemies desynchronize.
A move is `{key, name, emoji, kind, dmg/amt, hits?, tip}`. Kinds:

- `attack` — dmg to preferred target (existing pipeline; dmg scales with `enemy_scale`)
- `multi` — `hits` × dmg to preferred target
- `attack_all` — dmg to every living dwarf
- `block` — self block (clears at that enemy's next action; soaks the player phase between)
- `guard_all` — block to self AND both allies (smaller amt)
- `rage_all` — permanent +amt attack to all living enemies (`e.rage`, added to every attack)
- `expose` — apply **Vulnerable 💥** (n stacks) to the preferred target dwarf: they take
  ×1.5 from enemy hits; decays −1 each player-phase start (mirrors the enemy-side status)

## Roster (3 → 7)

| Enemy | HP | pref | rotation |
|---|---|---|---|
| Brute 👹 | 45 | tankiest | Smash 9 → Smash 9 → **CRUSH 14** 💢 |
| Assassin 🥷 | 30 | healer_dps | Stab 6 → Expose 💥2 → **Flurry 3×3** |
| Caster 🔮 | 28 | lowest_hp | Zap 5 → Ward 🛡️6 → **Bolt 10** |
| Wolf 🐺 | 22 | lowest_hp | Bite 5 → **Howl 📣 +2** → Bite 5 |
| Warden 🗿 | 40 | tankiest | **Bulwark 🛡️8/4-allies** → Slam 7 → Slam 7 |
| Witch 🧿 | 26 | lowest_hp | **Shriek 🌀 3-all** → Hex 💥2 → Blast 7 |
| Ogre 👺 | 55 | tankiest | Brace 🛡️5 → **CRUSH 16** (2-beat heavy) |

`atk` stays on every entry as fallback (an entry without `moves` behaves exactly as today).
Encounter variety: new additive `Db.ENCOUNTER_POOLS = {"med": [comp,…], "high": [comp,…]}`
(each comp = 3 ids). Overworld picks a random comp from the pool when present, else falls
back to `ENCOUNTERS_BY_TIER.enemies` — scale still comes from `ENCOUNTERS_BY_TIER`, so the
seam shape and tuning stay untouched.

## Intent = latched move + live numbers

`e.move_i` indexes the rotation; the move it points at is what the enemy WILL do — latched
by construction (advances only after the enemy acts), so intent never flickers mid-phase.
The existing per-enemy intent label upgrades from `🗡️9>War` to the latched move:
`💢14→War` (attack: red), `🛡️6` (block: ice-blue), `📣+2` (buff: amber), `💥→Cle`
(debuff: purple), `🌀3×all` (AoE). Numbers are LIVE: `dmg + rage`, ×1.5 if the current
target is Vulnerable — same philosophy as card bodies. Threat arrows now draw only for
target-directed moves (attack/multi/expose); block/buff/AoE turns draw none.

## Hover / tap explainer

`en_emoji` already has `MOUSE_FILTER_STOP` + `gui_input`. Add `mouse_entered/exited`
(desktop hover) and reuse the dead no-armed-card tap (touch two-tap convention) to toggle an
**intent panel** in the free band y≈50–126: line 1 `CRUSH 💢 — hits Thrain for 14`,
line 2 the move's tip, line 3 `Next: Smash 9`, line 4 the archetype's targeting `tip`
(finally rendering the authored copy). Panel x clamps to the viewport (avoids the known
card-tooltip overflow bug). One panel instance, retargeted per enemy.

## Execution changes (`combat.gd`)

`_enemy_phase` per living enemy: clear own block → execute latched move by kind (attacks
reuse `_enemy_attack`, parameterized `dmg`; multi loops hits; every new await epoch-guarded)
→ `move_i += 1`. Player dicts gain `vulnerable` (badge 💥n, decay at player-phase start,
×1.5 in enemy hit calc). Move damages pre-scaled by `enemy_scale` at spawn (as `atk` is).
Taunt still redirects via `_enemy_target` — unchanged.

## Non-goals (YAGNI)

No heals/summons (validity edge cases), no 4th enemy slot, no per-enemy AI beyond rotation,
no changes to cards/describe(), no low-tier encounters, no enemy-side new statuses.

## Verification

MCP loop: state dumps of latched intents through full turns (rotation advance, rage
accumulation, block grant/clear timing, player-vulnerable decay), screenshot intent labels +
hover panel, seam fight from the overworld, standalone `_ready` fresh-render check, then the
usual Pages deploy checklist.

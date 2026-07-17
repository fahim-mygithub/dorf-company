# Shipping the three class archetypes (2026-07-17)

Implements the three published design sheets — `design/cards/{class,support,dps}.html` — into the
game. Nine classes, nine Class Powers, three archetypes. The sheets are the authority; where a sheet
contradicts the shipped engine, the contradiction is recorded below and resolved explicitly rather
than papered over.

Speccing was fanned out one agent per archetype, then adversarially audited against the engine
(verdicts: tank `needs-work`, support `needs-work`, dps `broken`). Every finding below survived that
audit — the ones that did not are not here.

## The three decisions that shrank the job

**1. Guard IS the shipped `block` field — a rename, not a second pool.**
The design's whole Guard paragraph is already implemented: "soaks like block" is `_enemy_attack`
(block subtracted at `combat.gd:1306`), and "pulls threat" is `_pick_tankiest` (`:676`), which sorts
the living party by `block` first and `max_hp` as tiebreak, and which every `pref:"tankiest"` enemy
already routes through. The sheets prove they are one thing: Fighter's Hold the Line says "All allies
+4 **Guard**" and Paladin's Consecrate says "All allies +4 **block**" — same op, two names, one page.
A second pool would have bought a new mitigation stage, a second threat read, a second badge and a
second `describe()` fork, for zero mechanical difference. `gain_guard` ships as a pure alias arm on
the existing `block` case so the Tank card text can say "Guard".

**2. `role` becomes the archetype (`tank`/`support`/`dps`); a new `cls` key carries the class id.**
Today `role` doubles as the class id, and `combat.gd:1363` emits `{"cls": a["role"]}` into
`crew_results`. The campaign index-matches and never reads that field, so it is dead data — which is
exactly why this would have rotted silently. Three sites keyed off the literal `"warrior"` as a role:
`_first_living_role("warrior")` (Taunt redirect), `_first_living_nontank()` (Assassin backline), and
Taunt's `force_target_all` arg (inert — the op ignores it). All three moved.

**3. Momentum stays, and stops pretending to be a DPS meter.**
The DPS sheet drops Momentum, but `momentum_strike` is in `overworld.gd CLASS_REWARDS["warrior"]`, so
deleting it breaks the campaign reward pool. It survives as what it always measured — "did you attack
this turn" — which is precisely the Barbarian's Enrage upkeep. No new `attacked_this_turn` field.

## The roster

`PARTY_ORDER` (the canonical trio) is **unchanged**: the campaign gates its High job on a fieldable
W/C/S trio, the sim was tuned against it, and all four harnesses hardcode `warrior`/`sorcerer`.
`warrior` therefore stays — and takes **Action Surge**, because the shipped Warrior (Taunt / Retaliate
/ Fortify behind a wall of Guard) *is* the Fighter archetype in its simple form. That single choice
means the default trio ships one power from each of the three archetypes: the first fight a player
loads shows the whole system.

`ROLL_POOL` (new) is the full roster and feeds lobby rolls + campaign recruits, where variety pays.

| archetype | classes |
|---|---|
| tank ⚔️ | **Warrior** (Action Surge) · Barbarian (Enrage) · Fighter (Action Surge) · Paladin (Divine Smite) |
| support 📿 | **Cleric** (Channel Divinity) · Bard (Bardic Performance) · Druid (Wild Shape) |
| dps 🗡️ | **Sorcerer** (Metamagic) · Rogue (Assassin's Mark) · Monk (Flurry of Blows) |

`cleric` and `sorcerer` are upgraded in place — same ids (the harnesses assert on the string), the
sheets' kits. `sorcerer` does **not** start with `arc_lightning`: it is already in
`CLASS_REWARDS["sorcerer"]`, and shipping it in the starting deck would make its own reward tile a
duplicate.

## The Class Power

`power` (id) + `power_cd` (turns) on the party dict, ticked host-side at `_start_player_phase`. Fired
by tapping your own dwarf's orb → `_fire_power(seat, choice)`. In co-op it is a new validated intent,
`submit_power`, modelled on `submit_action` and trusting nothing. Powers live in
`scripts/combat/class_powers.gd`; `combat.gd` keeps a thin integration.

**`submit_power` must gate on `_seat_ended`, and `submit_action` does not.** `_on_action` gets away
with it by accident: ending discards your hand (`_authority_set_ready:514`), so `_hand_index_of`
returns -1 and the play dies. A power has no card, so nothing stops an ended seat firing one. This is
the single highest-value line in the co-op audit.

## Contradictions found, and how each is resolved

| # | Design says | Engine says | Resolution |
|---|---|---|---|
| 1 | Whirlwind deals X to ALL | `_apply_play:882` already loops enemies for an `all_enemies` card, calling `_resolve` **once per enemy** | Op is `dmg_x` (single target). An op that loops enemies *inside* an `all_enemies` card is N². |
| 2 | Twinned spell "hits a second target, in full" | Twin re-runs the whole effect array; `arc_lightning` carries `dmg_all` **inside** its effect | Twin is gated to `target == "enemy"` with no fan-out op, else it double-applies the AoE. |
| 3 | Quicken makes "the next spell cost 2 less" | A cost-delta check can't detect it on a 0-cost spell — and `empower` (cost 0, school spell) is live in the Sorcerer's reward pool | Consume on **school match**, never on a cost delta. |
| 4 | Paladin "banks Devotion between casts" | `_start_player_phase:442` zeroes `devotion` every turn | Devotion becomes **persistent** (banked). The legacy `divine_smite` card gets easier to fuel — unsimmed, flagged. |
| 5 | Heighten fires the held spell at start of next turn | Nothing in `_resolve`'s chain calls `_check_end` — a Heighten kill leaves 0 living enemies in `playerTurn` until someone ends a turn | `_check_end()` after the hold resolves. The held target may also be dead: the hold is dropped. |
| 6 | Monk "wants to end LAST" | `_authority_set_ready` discards your hand — ending is a forfeit | `_refund_flurry` gates on `_seat_ended`. Ending forfeits your own refunds; the tension is real and kept. |
| 7 | Enrage drops "if you don't attack each turn" | No per-dwarf end-of-turn hook exists; seats end independently in co-op | `_upkeep_seat(seat)` at `_authority_set_ready`, plus a `rage_turn == turn` grace so firing Enrage can't fail its own upkeep. |
| 8 | Druid pays "−2 hand" for a 3-turn form | The hand is discarded and redrawn to a fresh 5 **every** turn (`_authority_set_ready:514` + `_start_player_phase:446`) | The tithe costs turn 1 only; turns 2–3 pay out on a full hand. Shipped as designed — **this is the blow-out to sim first**, and the sheet already names the lever (cost 2 → 3). |

## Verification

Baseline before any change: `combat_verify` **39/39**, `campaign_verify` **81/81**. Both must stay
green, plus new assertions for the power system. `--headless --check-only --script <file>` is the fast
syntax gate.

⚠ `_first_living_role("cleric")` → `"support"` **cannot be caught by `combat_verify`**: its 2-seat
crew (warrior + sorcerer) has no support dwarf, so the lookup returns `{}` either way. A 3-seat case
is required, not optional.

Every number here is an unsimmed placeholder, exactly as the sheets say.

I have verified all the seams against the live files (combat.gd 1320 lines, net.gd, card.gd). The plan's anchors are accurate and net.gd exposes `my_peer_id`/`ensure_peer_id()`/`combat_request`/`my_seat`/`is_authority`/`room_code` + generic `send_message`/`message_received` (no `peer_id`). Here is the final ordered build spec.

---

# Dorf Company — M3 Networked Combat: Final Build Order

## 0. Frozen contract (resolves review blockers #1 and #2 — read before cutting any step)

These decisions are locked so the pieces compose. Do not deviate.

- **One function-name set:** `_build_snapshot()`, `_build_hand_msg(seat)`, `_apply_snapshot(snap, force=false)`, `_apply_hand(payload)`. No `_snapshot`/`_hand_payload`/`_client_apply_snapshot` aliases anywhere.
- **Flat envelope (seq lives INSIDE the snapshot):** `_build_snapshot()` returns `{ "seq":int, "party":[...], "enemies":[...], "globals":{...}, "ready":[...], "acks":[...] }`. The wire payload IS this dict: `Net.send_message("apply_snapshot", _build_snapshot())`. There is **no** `{seq,snap,acks}` wrapper. Consequence: M3b's `bundle.snapshot` is a bare `_build_snapshot()` dict, and `_apply_snapshot(bundle.snapshot)` consumes it directly.
- **Two client seq trackers:** `_last_board_seq := -1` guards `apply_snapshot` **and** the M3b `enemy_phase` bundle (its `snapshot.seq` shares the board counter). `_last_hand_seq := -1` guards `hand`. Never a single shared tracker (a shared `<=` guard drops the same-seq hand — proven in Piece 1).
- **Identity/handoff:** use `Net.ensure_peer_id()` everywhere (never `Net.peer_id`). Cross-scene board carrier is the shipped `Net.combat_request` (+ `Net.my_seat`/`Net.is_authority`). No `CoopHandoff`.
- **mode/my_seat/seat_count are parsed exactly once**, in `_ready`, before the Net connect. `_start_combat` consumes the already-set values.

**Verification harness (build once, reuse for every net-path step).** In a throwaway `scenes/test/coop_harness.tscn` + `coop_harness.gd`: `Net.connect_realtime("TESTROOM", true)` (self_echo=true so one Net bounces broadcasts back to all subscribers in-process), then on `realtime_joined` instance **two** `combat.tscn` children — A with `request.net={mode:"authority",seat:0,seat_count:2}`, B with `request.net={mode:"client",seat:1,seat_count:2}` — both sharing the same board dict (crew of 2, fixed `enemy_scale`, same `enemies`). Both subscribe to the one `Net.message_received`; each instance's mode-guarded dispatcher drops the messages meant for the other. This is the "two net nodes in one instance" rig. `get_game_screenshot` shows both boards side by side; `execute_game_script` reads either instance's state. SOLO-only steps skip the harness and verify with a plain `play_scene` of `combat.tscn` (request `{}`).

---

# M3a — Board sync

Goal at end of M3a: two seats in the harness see the same board; a play by either seat resolves once on the authority and both boards converge; neither seat can see the other's hand.

## Checkpoint A — UID refactor (SOLO-only; no net touched; the whole checkpoint is verifiable in a plain SOLO run)

**A1. Add uid + identity scaffolding state.**
`combat.gd` state block, at/around `:35` (`var selected_card := -1`) and `:40-41` (Mode enum).
- Replace `var selected_card := -1` → `var selected_uid := ""` (`""` = nothing armed).
- Add: `var _card_uid_seq := 0`; `func _next_uid() -> String: _card_uid_seq += 1; return "c%d" % _card_uid_seq`.
- Add (used later, inert now): `var my_seat := 0`, `var _seat_count := 1`, `var _seq := 0`, `func _next_seq() -> int: _seq += 1; return _seq`, `var _last_board_seq := -1`, `var _last_hand_seq := -1`, `var _action_nonce := 0`, `func _next_nonce() -> int: _action_nonce += 1; return _action_nonce`, `var _barrier_open := true`, `var _ready_seats := {}`, `var ready: Array = []`.
- **Verify:** `validate_script` clean; `play_scene` SOLO renders and plays as before (screenshot).
- **SOLO-safe:** `selected_uid == ""` is the exact analog of `selected_card < 0`; net vars are never read on the SOLO path. `_barrier_open` defaults true so no SOLO gate ever trips.

**A2. Init `hand_uids` on each char + reset uid counter.**
`_start_combat` `combat.gd:279` (epoch bump) and party dict literal `:295` (`"hand": []`).
- In the party dict add `"hand_uids": []` beside `"hand": []`.
- At `:279`, beside `combat_epoch += 1`, add `_card_uid_seq = 0`.
- **Verify:** `execute_game_script` dumps `party[0]` — has empty `hand_uids`.
- **SOLO-safe:** parallel array only; no read-site changed yet.

**A3. Mint a uid every time a card enters hand.**
`_draw_cards` `combat.gd:855` (the single `a["hand"].append(...)`).
- After the append add `a["hand_uids"].append(_next_uid())`.
- **Verify (invariant):** after `play_scene`, `execute_game_script` asserts `party[i].hand.size() == party[i].hand_uids.size()` for all i (opening deal). Then end turn once and re-assert (covers redraw/reshuffle branch).
- **SOLO-safe:** draw order & cids identical; only a parallel uid array grows.

**A4. Keep the two arrays aligned at the two other mutation sites.**
`_spend` `combat.gd:671` (`a["hand"].remove_at(idx)`) and `_on_end_turn` `:392` (`a["hand"].clear()`).
- In `_spend`, before/after `remove_at(idx)` add `a["hand_uids"].remove_at(idx)`.
- In `_on_end_turn`, after `a["hand"].clear()` add `a["hand_uids"].clear()`.
- **Verify:** play several cards + end turn; `execute_game_script` asserts `hand.size()==hand_uids.size()` after **each** play and after end-turn.
- **SOLO-safe:** invariant `hand.size()==hand_uids.size()` holds after every mutation. This is the load-bearing alignment step.

**A5. Add `_hand_index_of` + rewrite `_armed_def` + swap every `selected_card` site to `selected_uid`.**
Helper is new; sites at `combat.gd:380, 393, 569, 585, 591-595, 622-628, 648, 659, 681, 946, 950, 1155, 1267`.
- Add `func _hand_index_of(a: Dictionary, uid: String) -> int:` → `-1` if `uid==""`, else `(a.get("hand_uids",[]) as Array).find(uid)`.
- Rewrite `_armed_def` (`:591`): `var idx := _hand_index_of(party[active_idx], selected_uid); return {} if idx < 0 else Db.CARDS[party[active_idx]["hand"][idx]]`.
- Clears (`:380, :393, :681`) → `selected_uid = ""`. Guards: `:569 if selected_uid != "":`; `:585 if selected_uid == "": return`; `:946/:950/:1267 selected_uid != ""`. `is_selected` at `:1155` → `card.uid == selected_uid` (card.uid added in A6).
- `_play_on_enemy`/`_play_on_ally` currently read `idx = selected_card` (`:648/:659`) — these collapse in A7; for now make them `_hand_index_of(a, selected_uid)`.
- **Verify:** SOLO arm/deselect/target-play all behave as before (screenshot: armed card shows gold border + reticle; deselect clears).
- **SOLO-safe:** one-for-one int-sentinel → string-sentinel swap; no branch added/removed.

**A6. `card.gd` gets a `uid`; `_rebuild_hand` reconciles by uid with a survivor-animation gate.**
`card.gd:11` (`var index`) and `combat.gd:1137-1183` (`_rebuild_hand`).
- `card.gd`: add `var uid: String = ""` next to `index`.
- `_rebuild_hand`: stop the free-all at `:1138-1139`. Build `want` = aligned `hand`/`hand_uids`; index existing children by `.uid`. Free children whose uid left `want`. For a uid in both (**survivor**): keep the node, update `card.index`, call `card.set_slot(slot_pos, rot)` (no-ops while `_hover`), re-`setup(... is_selected = uid==selected_uid ...)`, do **not** reconnect `clicked`, do **not** replay the entrance tween. For a **new** uid: create node, set `card.uid`, `card.clicked.connect(_on_card_clicked)`, and run the `:1162-1183` entrance tween only when `_hand_anim != ""`.
- **Verify:** SOLO — hover a card, force a `_refresh()` via `execute_game_script`; the hovered card keeps hover (survivor). Play a card: it animates out, the rest stay put. End turn: whole new hand deals in. Screenshot each.
- **SOLO-safe:** cards land at identical index-derived fan slots; the only intended delta is a hovered survivor keeps its hover instead of being freed+recreated. Fallback if reconcile misbehaves: revert to free-all (SOLO byte-identical).

**A6b. (review minor) Don't clobber a hovered survivor's tooltip on re-setup.**
`card.gd:125` (`_tip_panel.visible = is_selected` at end of `setup`).
- Change to `_tip_panel.visible = is_selected or _hover`.
- **Verify:** hover an un-armed survivor across a `_refresh()`; tooltip stays visible under the pointer.
- **SOLO-safe:** only widens tooltip visibility to the already-hovered case; `_on_exit` still hides it.

**Checkpoint A gate (SOLO equivalence — must pass before any net code):** `play_scene` request `{}`, N=3; and a hotseat N=2 / N=4 via `DEBUG_PARTY_N`. Exercise: arm/deselect, target play, self/all play, end-turn draw, mid-turn reshuffle, forced `_rebuild_hand`. After each play assert `hand.size()==hand_uids.size()`. Screenshot-diff vs the pre-refactor build. Nothing downstream ships until this holds.

## Checkpoint B — Snapshot contract (authority build + client apply; verifiable by JSON round-trip on ONE instance, no second peer yet)

**B1. Define the field split (documentation the builder enforces).**
Reference dicts: char `combat.gd:288-300`, enemy `:323-331`, temp `_fresh_temp` `:350-354`.
- **PUBLIC char** (ride the snapshot): `slot, role, name, emoji, hp, max_hp, block, shield, energy, max_energy, alive, vulnerable, momentum, devotion, attacks_this_turn, temp` (whole sub-dict), `played_turn` (array of cids), and derived `hand_count:int`.
- **PRIVATE char** (never in snapshot): `hand`, `hand_uids`. **Authority-only** (never on the wire): `deck`, `discard`, `node`.
- **PUBLIC enemy:** `slot, archetype, name, emoji, hp, max_hp, block, atk, pref, alive, marked, forced, burn, vulnerable, move_i, rage, intent_target`. **Stripped:** `node`. **Omitted:** `moves` (every peer rebuilds identical pre-scaled moves from `request.enemy_scale` at `:313-322`).
- **GLOBALS:** `phase(String), turn, party_attack_buff, taunt_last_turn, attacks_this_turn, combat_epoch`. **Excluded:** `active_idx` (client-local = my_seat), `mode`.

**B2. Add `_build_snapshot() -> Dictionary` (authority).**
New function near `:646`.
- Per char: `var c := a.duplicate()` (SHALLOW copy — never the live dict); `c.erase("node"); c.erase("deck"); c.erase("discard"); c.erase("hand"); c.erase("hand_uids")`; `c["hand_count"] = a["hand"].size()`; append.
- Per enemy: `var d := e.duplicate(); d.erase("node"); d.erase("moves")`; append.
- Return `{ "seq": _next_seq(), "party": [...], "enemies": [...], "globals": {...}, "ready": ready.duplicate(), "acks": [] }`.
- **Verify:** `execute_game_script` calls `_build_snapshot()`, then `JSON.parse_string(JSON.stringify(snap))` and confirms no `node`/`deck`/`hand`/`hand_uids` keys survive and `hand_count` is present; confirm live `party[i]` still has its `node`/`deck`/`hand` intact (duplicate didn't mutate live state).
- **SOLO-safe:** never called in SOLO. **Critical:** operates on `.duplicate()` copies; erasing on a live dict would null the `node` ref `_flash`(`:1299`)/`_impact`(`:1311`) read.

**B3. Add `_build_hand_msg(seat) -> Dictionary` (authority).**
New function.
- Return `{ "seat": seat, "hand": party[seat]["hand"].duplicate(), "uids": party[seat]["hand_uids"].duplicate(), "seq": _seq }` (current `_seq` — the same value as the snapshot it accompanies).
- **Verify:** `execute_game_script` prints it; `hand.size()==uids.size()`; `seq` equals the last `_build_snapshot()` seq.
- **SOLO-safe:** authority-only.

**B4. Add `_merge_into(local, incoming)` (client helper).**
New helper.
- `for k in incoming: local[k] = incoming[k]`, then coerce numeric leaves back to int (JSON.parse returns floats). **Mandatory:** `local["slot"] = int(local["slot"])` (used as raw Array index at `_refresh_threats:1119-1120`). Also int-coerce `hp, max_hp, block, shield, energy, max_energy, vulnerable, momentum, devotion, hand_count` and enemy `hp/max_hp/block/atk/burn/vulnerable/move_i/rage`.
- **Verify:** unit via `execute_game_script`: build a local dict with `hand`/`deck`, merge a float-laden `incoming` lacking those keys; assert `hand`/`deck` survive and `slot`/`hp` are ints.
- **SOLO-safe:** never called in SOLO. Because `incoming` carries no `hand/hand_uids/deck/discard/node`, the merge physically cannot overwrite them (the merge-not-replace rule).

**B5. Add `_apply_snapshot(snap, force := false)` (client).**
New function; ends by calling `_refresh` (`:903`).
- Race guard: `if party.is_empty() or enemies.is_empty(): return`.
- Seq: `var seq := int(snap.get("seq", 0)); if not force and seq <= _last_board_seq: return`; if `_last_board_seq >= 0 and seq > _last_board_seq + 1: _request_resync()` (still apply — absolute snapshots are idempotent); `_last_board_seq = seq`.
- Globals: assign `phase=str(...)`, `turn/party_attack_buff/taunt_last_turn/attacks_this_turn/combat_epoch = int(...)`, `ready = snap.get("ready", [])`. **Do NOT touch `active_idx`.**
- Enemies loop: `var slot := int(c["slot"]); _merge_into(enemies[slot], c); enemies[slot]["node"] = en_emoji[slot]`. Party loop: same with `pc_emoji[slot]`.
- End with `_refresh()`. `_request_resync` M3a stub: `Net.send_message("resync", {"seat": my_seat})`.
- **Verify (one instance, no peer):** `execute_game_script`: snapshot the live board, mutate a copy's `hp`, `_apply_snapshot` it, confirm `party[i].hp` changed but `party[my_seat].hand`/`deck` untouched and `node` rebound (non-null). Then feed the same snap twice → second is a no-op (seq guard).
- **SOLO-safe:** never called in SOLO. Must not call `_check_end`; `_refresh` stays pure.

**B6. Add `_apply_hand(payload)` (client).**
New function.
- `if int(payload["seat"]) != my_seat: return`; `var seq := int(payload["seq"]); if seq <= _last_hand_seq: return`; `_last_hand_seq = seq`; `party[my_seat]["hand"] = (payload["hand"] as Array).duplicate()`; `party[my_seat]["hand_uids"] = (payload["uids"] as Array).duplicate()`; `_refresh()`.
- **Verify:** feed a hand payload for `my_seat` → hand renders; feed one for another seat → ignored; feed stale seq → ignored.
- **SOLO-safe:** client-only; separate tracker from board (this is why B5/B6 use two counters).

## Checkpoint C — Hidden-hand mini-row gate (resolves review blocker #3; required M3a deliverable)

**C1. Gate `_refresh_minis` so non-local seats are count-only (face-down + played ghosts from `played_turn`).**
`_refresh_minis` `combat.gd:1188-1230`; the bright loop `:1197`, the discard de-dup `:1202-1208`.
- Add a branch: `if mode != Mode.SOLO and i != my_seat:` render `int(a.get("hand_count", (a["hand"] as Array).size()))` **face-down back-tiles** (no `Db.CARDS[cid].emoji`) plus `int((a.get("played_turn", []) as Array).size())` ghost tiles; `continue`. Keep the existing face-up path for the SOLO/hotseat case (`mode == SOLO`), unchanged.
- Add a `_mk_mini_back()` (or a `face_down` flag on `_mk_mini`) that draws a blank card back.
- **Verify (harness):** authority board — teammate rows show N face-down backs, never emoji (host cannot read teammate cards). Client board — teammate rows show the right count of backs + ghosts (not blank). Screenshot both.
- **SOLO-safe:** the gate is `mode != Mode.SOLO and i != my_seat`; SOLO/hotseat keeps the full face-up de-dup path byte-for-byte. On the client `hand_count` comes from the merged snapshot; on the authority the `a.get("hand_count", hand.size())` fallback uses the real hand size — both avoid leaking cids.

## Checkpoint D — Action struct + commit gates + authority action handler (the first true two-peer step)

**D1. Extract `_apply_play` + `_try_play`, refactor the three commit points.**
`_on_card_clicked` self/all branch `combat.gd:610-621`, `_play_on_enemy:646`, `_play_on_ally:657`; new fns near `:646`.
- `func _apply_play(a, idx, cid, def, target_kind, target_idx) -> void`: `_spend(a, idx)`; match `target_kind` — `"all"`→loop `_resolve(def,a,e)` over alive enemies; `"enemy"`→`_resolve(def,a,enemies[target_idx])`; `"ally"`→`_resolve(def,a,party[target_idx])`; else→`_resolve(def,a,{})`; then `_finish_play(a,def,cid)` (unchanged — clears `selected_uid`, refreshes, `_check_end`).
- `func _try_play(seat, uid, target_kind, target_idx) -> void`: `var idx := _hand_index_of(party[seat], uid); if idx < 0: return`; `var cid := party[seat]["hand"][idx]`; `var def := Db.CARDS[cid]`. Then: `if mode == Mode.CLIENT:` build+send action, clear `selected_uid`, `_refresh()`, return (D2). `elif mode == Mode.AUTHORITY:` `if not _barrier_open: return`; `if not _can_play(party[seat], cid, def): return`; `_apply_play(...)`; `_broadcast_play(seat)` (D4). `else:` (SOLO) `if not _can_play(...): return`; `_apply_play(...)`.
- Rewire: `_on_enemy_clicked` → `_try_play(active_idx, selected_uid, "enemy", idx)`; `_on_party_clicked` ally branch (`:571-573`) → `_try_play(active_idx, selected_uid, "ally", idx)`; `_on_card_clicked` self/all (`:610-621`) → `_try_play(active_idx, card.uid, ("all" if tgt=="all_enemies" else "self"), -1)`. **Resolve the tapped card by `card.uid`, never `card.index`.**
- **Verify (SOLO):** every play type still resolves identically (screenshot + state dump). SOLO path is `_can_play`→`_apply_play`→`_finish_play`, same order as today.
- **SOLO-safe:** the `else` arm reproduces today's `_spend`→`_resolve`→`_finish_play` exactly; SOLO never references Net.

**D2. Action struct builder + CLIENT gate.**
Inside `_try_play`.
- `func _make_action(seat, uid, hand_index, target_kind, target_idx) -> Dictionary` → `{ "seat": seat, "peer_id": Net.ensure_peer_id(), "card_uid": uid, "hand_index": hand_index, "target_kind": target_kind, "target_idx": target_idx, "nonce": _next_nonce() }`.
- CLIENT branch: optional pre-check `def["cost"] <= party[seat]["energy"]` (no mutate); `Net.send_message("submit_action", _make_action(...))`; `selected_uid = ""`; `_refresh()`; **return with no local mutate.** The played card stays in hand until the authority's next `hand` reconciles it out (M4 adds the pending-lock).
- **Verify (harness):** client taps a card → `submit_action` observed on the wire (log in dispatcher); client's own board does **not** change yet.
- **SOLO-safe:** behind `if mode == Mode.CLIENT`; SOLO/AUTHORITY never enter.

**D3. Gate the CLIENT switch-active branch (resolves review major #5).**
`_on_party_clicked` `combat.gd:565`, before the switch-active branch at `:575`.
- After the ally-target check, add `if mode == Mode.CLIENT: return` (a client controls only its own seat; tapping a teammate portrait must not repoint `active_idx`).
- **Verify (harness):** on the client, tapping a teammate portrait does nothing; own hand stays rendered. On authority/SOLO, tapping still switches active.
- **SOLO-safe:** guard is CLIENT-only; SOLO/authority switch path unchanged.

**D4. Authority `_on_action` (validate → resolve → broadcast) + `_broadcast_play`.**
New fns; dispatch wired in D6.
- `func _on_action(a_dict) -> void` (only when `mode == Mode.AUTHORITY`), validate in order, rejecting on any miss: (1) `phase == "playerTurn"`; (2) `seat in range(party.size())`; (3) `party[seat]["alive"]` (peer_id→seat check is an M3a stub `_peer_owns_seat(peer_id, seat)` returning true); (4) `idx := _hand_index_of(party[seat], a_dict["card_uid"])`, reject if `< 0` — **never slot-substitute**; (5) `def := Db.CARDS[party[seat]["hand"][idx]]`, `_can_play(party[seat], cid, def)`; (6) `target_kind` matches `def["target"]` family and target alive.
- Apply with save/restore of the host's own arm: `var saved := selected_uid; _apply_play(party[seat], idx, cid, def, a_dict["target_kind"], int(a_dict["target_idx"])); selected_uid = saved; _refresh()` (the trailing `_refresh` re-renders the host's restored arm — resolves review minor "host arm dropped"). Then `_broadcast_play(seat)`.
- `func _broadcast_play(seat) -> void`: `Net.send_message("apply_snapshot", _build_snapshot())`; then `Net.send_message("hand", _build_hand_msg(seat))` (actor's hand changed).
- **Verify (harness):** client taps → authority resolves once → both boards converge (enemy hp equal on both screenshots); host's own armed card (if any) stays highlighted after a teammate play; `hand.size()==hand_uids.size()` on the authority for the acting seat.
- **SOLO-safe:** guarded by `mode == Mode.AUTHORITY`; reuses `_apply_play`/`_resolve` unchanged, reads no `active_idx`.

**D5. (review minor, accept or fix) Player-phase match-end ordering.** On a killing blow the authority order is `_apply_play → _finish_play → _check_end → _end → combat_finished → match_over` then `_broadcast_play`. If the final board must render on clients before they change_scene, move the `_broadcast_play` snapshot ahead of the `match_over` emit (mirror M3b's bundle-then-end). Otherwise document as accepted (clients end on `match_over`, snapshot loss tolerated). **Verify:** harness kill — confirm chosen behavior via screenshots. **SOLO-safe:** SOLO has no `match_over`.

## Checkpoint E — Handoff + dispatcher + barrier (wires the transport)

**E1. `_ready`: consume handoff, parse mode once, connect Net (resolves review major #6/#7).**
`_ready` `combat.gd:90-95`, before `_build_ui` at `:94`.
- At the very top: `if request.is_empty() and not Net.combat_request.is_empty(): request = Net.combat_request; Net.combat_request = {}` (consume-and-clear).
- `var net: Dictionary = request.get("net", {})`; `mode = Mode.AUTHORITY if net.get("mode")=="authority" else (Mode.CLIENT if net.get("mode")=="client" else Mode.SOLO)`; `my_seat = int(net.get("seat", 0))`; `_seat_count = int(net.get("seat_count", 1))`.
- `if mode != Mode.SOLO: Net.ensure_peer_id(); Net.message_received.connect(_on_net_message); combat_finished.connect(_on_match_finished_local)`.
- **Remove the mode/my_seat re-parse from `_start_combat`** (A2 must not re-derive mode; keep only `_card_uid_seq = 0` there).
- **Verify:** SOLO `request={}` → mode SOLO, no connect. Overworld child (`request` set, no `net`) → mode SOLO, no connect (its `await fight.combat_finished` still works because we only self-connect when `mode != SOLO`). Harness → correct mode/seat per instance.
- **SOLO-safe:** both existing entry paths (standalone `{}`, overworld) have no `net` key → SOLO → neither connect fires.

**E2. Central dispatcher `_on_net_message(event, payload)`.**
New fn; source is `net.gd:16`.
- `match event:` — AUTHORITY-only (guard `if mode == Mode.AUTHORITY`): `"combat_ready"`→`_authority_on_combat_ready`, `"submit_action"`→`_on_action`, `"resync"`→`_authority_on_resync`, `"ready"`→`_authority_on_ready` (M3b). CLIENT-only (guard `if mode == Mode.CLIENT`): `"apply_snapshot"`→`_apply_snapshot(payload)`, `"hand"`→`_apply_hand(payload)`, `"enemy_phase"`→`_client_on_enemy_phase` (M3b), `"match_over"`→`_client_match_over`.
- Note the fan-out reality: self_echo/broadcast delivers every message to all subscribers; the mode guards silently drop the ones meant for the other role (a CLIENT sees other clients' `combat_ready`/`submit_action`; the authority never gets its own `apply_snapshot` because production self=false).
- **Verify (harness):** log each dispatched event; confirm authority only acts on `submit_action`/`combat_ready`, client only on `apply_snapshot`/`hand`.
- **SOLO-safe:** connected only when `mode != SOLO`.

**E3. Mode-branch the tail of `_start_combat`; add `_authority_on_combat_ready` barrier.**
`_start_combat` tail `combat.gd:348` (the unconditional `_start_player_phase()`); new handler.
- Replace `:348` with `match mode:` — `Mode.SOLO:` `_start_player_phase()` (byte-identical). `Mode.AUTHORITY:` `_barrier_open = false`; `_ready_seats.clear()`; `_start_player_phase()` (draws every seat's opening hand so the barrier can answer). `Mode.CLIENT:` do **not** call `_start_player_phase`; set `active_idx = my_seat`, leave `phase == ""` (so `_rebuild_hand:1140` and `_refresh_minis:1193` early-return — no local draw), `_refresh()`, then `Net.send_message("combat_ready", {"seat": my_seat, "peer_id": Net.ensure_peer_id()})` and start a ~1.5s repeating Timer that re-sends `combat_ready` until the first `apply_snapshot` lands.
- `func _authority_on_combat_ready(payload)`: validate `payload.peer_id` owns `int(payload.seat)` (M3a stub true); `_ready_seats[int(payload.seat)] = true`; reply `Net.send_message("apply_snapshot", _build_snapshot())` (seq will be 0 first) + `Net.send_message("hand", _build_hand_msg(int(payload.seat)))`. When `_ready_seats.size() >= _seat_count - 1`: `_barrier_open = true` and re-broadcast one opening snapshot + each seat's hand.
- **Verify (harness):** start both instances; client shows portraits only until the snapshot arrives, then its hand deals in; authority opens play only after the client's `combat_ready`. Screenshot the converged opening board.
- **SOLO-safe:** the `Mode.SOLO:` arm is the verbatim original `_start_player_phase()`.

**E4. Pin `active_idx` to `my_seat` in co-op.**
`_start_player_phase` `combat.gd:381` (`active_idx = _first_living_party()`).
- Change to `active_idx = my_seat if mode != Mode.SOLO else _first_living_party()`.
- **Verify (harness):** after any player phase, the authority's big fan is still its own seat's hand (not slot 0's).
- **SOLO-safe:** SOLO arm is the original call verbatim.

**E5. Match-end wiring.**
`_end` `combat.gd:877-885`; new `_on_match_finished_local(result)` + `_client_match_over(payload)`.
- No change to `_end` (co-op fills `request`, so it already emits `combat_finished` and returns at `:884`).
- `_on_match_finished_local(result)` (connected only when `mode != SOLO`): `Net.send_message("match_over", {"won": bool(result.get("success", false))})`; `get_tree().change_scene_to_file("res://scenes/menu/lobby.tscn")`.
- `_client_match_over(payload)`: same change_scene.
- **Verify (harness):** kill all enemies on the authority → both instances route to lobby; client never self-ends.
- **SOLO-safe:** `combat_finished` self-connect only when `mode != SOLO`; the overworld's external `await fight.combat_finished` still gets exactly one emit.

**M3a exit gate:** harness two-seat run — barrier opens; either seat plays a card, it resolves once on the authority, both boards converge (screenshot equality of enemy HP + party HP); neither seat sees the other's hand faces; `hand.size()==hand_uids.size()` on both after a full round of plays. Plus the Checkpoint A SOLO/overworld regression screenshots still clean.

---

# M3b — Pure enemy phase, ready gate, full loop, heal guard

Depends on M3a's `_build_snapshot`/`_apply_snapshot`/`_build_hand_msg`/`_apply_hand`/uid/dispatcher/`_barrier_open`/`active_idx` pin.

## Checkpoint F — Heal alive-guards (cheapest; SOLO no-ops; verify first)

**F1. Guard the three heal ops so a dead ally is a no-op, never a revive or a mis-routed attack (resolves review §7d).**
`heal_self` `combat.gd:727-728`, `heal_ally` `:729-731`, `heal_or_damage` `:736-740`.
- `heal_self`: wrap in `if a.get("alive", false):`.
- `heal_ally`: append `and target.get("alive", false)` to the existing guard at `:730`.
- `heal_or_damage`: restructure so the ally branch nests the alive check — `if target.get("role","") != "": if target.get("alive", false): <heal>  # dead ally = no-op` `else: _attack(...)`. A dead ally must **not** fall through to the enemy `_attack` branch.
- **Verify (SOLO):** normal heals unchanged (screenshot). Via `execute_game_script`, force an ally to `alive=false`, resolve a heal_or_damage aimed at it → hp stays 0, no attack math runs.
- **SOLO-safe:** dead allies aren't targetable in SOLO (`_on_party_clicked:566` returns), so guards are true no-ops; only the SOLO-unreachable dead-ally case flips heal→no-op.

## Checkpoint G — Fold plumbing (SOLO-inert; verify SOLO enemy phase unchanged)

**G1. Add `_folding` + `_capture`; make `_log`/`_flash`/`_impact` self-suppress while folding.**
State near `:39`; `_log:900`, `_flash:1298`, `_impact:1310`.
- Add `var _folding := false`, `var _capture: Array = []`, `var _enemy_replay_active := false`, `var _replay_epoch := 0`.
- Prepend `if _folding: return` to `_log`, `_flash`, `_impact`.
- **Verify (SOLO):** a full SOLO enemy phase looks identical (screenshot-diff) — `_folding` stays false.
- **SOLO-safe:** `_folding` set true only inside the authority fold (G3); in SOLO these three behave byte-identically.

**G2. Emit ordered beat-events from the reused mutation helpers under `_folding`.**
`_do_enemy_move:455` (branches `attack:457`/`multi:461`/`attack_all:468`/`block:475`/`guard_all:479`/`rage_all:485`/`expose:495`), `_enemy_attack:822`, `_deal_enemy:811`.
- Add `func _emit(op: Dictionary) -> void: if _folding: _capture.append(op)`.
- In `_enemy_attack` after `rem`/retaliate compute, `_emit({"t":"hit","from":e.slot,"to":t.slot,"amt":rem,"hp_after":t.hp,"block_after":t.block,"shield_after":t.shield,"log":<the :835 string>,"retal":<refl dealt>,"from_hp_after":e.hp,"downed":not t.alive})`.
- In each `_do_enemy_move` branch emit the matching `block`/`guard`/`rage`/`expose` op (slot + amt + its `_log` string + enemy self post-values). Burn ticks emitted in G3.
- Multi/attack_all emit one `hit` op per swing/target in existing loop order (so replay matches SOLO resolution order).
- **Verify (SOLO):** enemy phase still byte-identical (`_emit` is a no-op call when not folding); screenshot-diff.
- **SOLO-safe:** `_emit` appends only under `_folding`; mutation + live `_flash`/`_impact`/`_log` unchanged.

## Checkpoint H — Authority fold + shared replay

**H1. Add `_resolve_enemy_phase() -> Dictionary` (authority, synchronous, no awaits, no `_end`).**
New fn right after `_enemy_phase` `combat.gd:437`; mirrors mutation bodies `:402-433`; end-detect mirrors `_check_end:858` **minus** `_end`.
- Set `_folding = true; _capture = []`. Run: clear enemy block (`:402-403`); burn loop (`:406-415`) emitting `{"t":"burn",...}` per ticking enemy (no `_refresh`/timer); `func _scan_end() -> int` (0 ongoing / 1 win / 2 lose) doing the `:861-868` alive scan without `_end`; if ended, record and stop. Then `for e in enemies` living: `_do_enemy_move(e, _enemy_move(e)); e["move_i"] += 1`; `_scan_end()` after each, break if ended. If not ended, call `_start_player_phase()` once (draws fresh hands off authority RNG, resets, sets `phase="playerTurn"`). Set `_folding = false`.
- Build `hands = {seat: {hand, uids}}` from freshly drawn hands; `var snapshot := _build_snapshot()` (final state, its own seq); return `{ "events": _capture, "snapshot": snapshot, "hands": hands, "ended": ended, "won": won, "seq": snapshot["seq"] }`.
- **Verify (harness authority):** `execute_game_script` calls it once, dumps `events` order and `snapshot`; confirms `_start_player_phase` ran exactly once (hands drawn once — no double draw); `hand.size()==hand_uids.size()` for every seat.
- **SOLO-safe:** brand-new fn, never on the SOLO path (SOLO keeps `_enemy_phase:398`).

**H2. Add `_authority_run_enemy_phase()` driver.**
New fn; co-op replacement for the SOLO-only `await _enemy_phase()` at `:396`.
- `var epoch := combat_epoch`; `phase = "enemyTurn"`; `var bundle := _resolve_enemy_phase()`; `Net.send_message("enemy_phase", _strip_nodes(bundle))` (bundle already node-free — `_build_snapshot` strips, events carry slots); `await _replay_enemy_phase(bundle, epoch)`; `if bundle.ended: _end(bundle.won)` (deferred terminal → drives `combat_finished:884` → `_on_match_finished_local` → `match_over`).
- **Verify (harness):** authority animates its own enemy phase after the fold; final board matches the fold's snapshot.
- **SOLO-safe:** new fn, co-op only; deferred `_end` keeps `match_over` from racing the replay.

**H3. Add `_replay_enemy_phase(bundle, epoch)` (shared cosmetic replay; writes labels + VFX only, never game state).**
New fn. CLIENT entry from dispatcher (`"enemy_phase"`). Uses `_flash`/`_impact`/`_log` (folding false → fire live) and pokes `en_hp`/`en_block`/`pc_hp`/`pc_block` by slot.
- `_replay_epoch += 1; var rtok := _replay_epoch; _enemy_replay_active = true`.
- **CLIENT only:** seq-guard on `_last_board_seq` (`bundle.snapshot.seq`; gap → `_request_resync`); apply `bundle.snapshot` via `_apply_snapshot` (field-level merge, node rebind) + adopt `bundle.hands.get(my_seat, ...)` into `hand`/`hand_uids`; do **not** `_refresh` yet (labels still show pre-values).
- Walk `bundle.events` mirroring current pacing (burn group 0.35s `:420`; per-enemy 0.45s `:426`): per op poke affected label to its `*_after` value, `_flash(node)`, `_impact(node, amt)`, `_log(op.log)`, `await get_tree().create_timer(beat).timeout`, then `if epoch != combat_epoch or rtok != _replay_epoch: return` (dual cancel). Final settle 0.25s (`:434`).
- On finish: `_enemy_replay_active = false`; if not `bundle.ended`: `_hand_anim = "deal"; _refresh()` (reveals next player phase + deals fan). AUTHORITY skips the CLIENT-only merge (its dicts already final).
- **Verify (harness):** both boards play the enemy phase in lockstep; after it, both show the next player phase with fresh (correct, equal-count) hands; client's own hand faces match `bundle.hands[my_seat]`.
- **SOLO-safe:** never called in SOLO (SOLO's `_enemy_phase` is its own sim+replay); `_impact` spawns momentum VFX exactly as SOLO (folding false).

**H4. Input lock during replay.**
`_on_card_clicked:600`, `_on_party_clicked:565`, `_on_enemy_clicked:582`, `_on_end_turn:386`.
- Add `if _enemy_replay_active: return` as the first line of each.
- **Verify (harness):** during the replay animation, taps do nothing on either board.
- **SOLO-safe:** `_enemy_replay_active` set only in `_replay_enemy_phase` (co-op only); stays false in SOLO → all four early-returns inert.

## Checkpoint I — Ready gate + full loop

**I1. Reset `ready` each player phase.**
`_start_player_phase` `combat.gd:357`.
- Add `ready.clear(); ready.resize(party.size())` (fills false).
- **Verify:** state dump — `ready` is `[false,...]` at player-phase start.
- **SOLO-safe:** `ready` is written here (runs in SOLO too) but read only by authority-only fns; behavior-neutral.

**I2. Branch `_on_end_turn` into per-seat Ready (co-op) vs verbatim End (SOLO).**
`_on_end_turn` `combat.gd:386-396`.
- Top: `if mode == Mode.SOLO: <existing :389-396 body>; return`. Else `_local_ready()`.
- `func _local_ready()`: `if mode == Mode.CLIENT: Net.send_message("ready", {"seat": my_seat, "peer_id": Net.ensure_peer_id()})` + mark a local pending pip (no mutation); `elif mode == Mode.AUTHORITY: _authority_set_ready(my_seat)`.
- **Verify:** SOLO end-turn identical (screenshot). Harness: pressing Ready on either seat sends/sets ready, does not advance the phase alone.
- **SOLO-safe:** SOLO body unchanged inside the guard; only the call site branches.

**I3. Button relabel + per-seat ready pips (co-op only).**
`end_turn_btn` created `:184-190`; disabled gate `:912`; render in `_refresh_panel:1124`.
- In `_refresh_panel`, when `mode != SOLO`: label the button "Ready", disable when `ready[my_seat]` or `not party[my_seat]["alive"]`, draw per-seat ready pips. No signal rewiring (same `pressed` connection at `:189`).
- **Verify (harness):** button reads "Ready"; readying disables it and lights that seat's pip. SOLO still reads "End Turn".
- **SOLO-safe:** relabel/pips are `mode != SOLO`-gated.

**I4. Authority ready aggregation + trip (resolves review blocker #4).**
New `_authority_set_ready(seat)` / `_all_alive_ready()`; inbound `"ready"` via dispatcher (E2).
- `_authority_set_ready(seat)`: bounds + `party[seat].alive` check (peer_id ownership is M4); `ready[seat] = true`; **discard that seat's hand AND uids unconditionally:** `for c in party[seat]["hand"]: party[seat]["discard"].append(c)`; `party[seat]["hand"].clear()`; **`party[seat]["hand_uids"].clear()`** (this is the blocker-#4 fix — without it `hand_uids` desyncs to double length after the first enemy phase); do **not** consult `retain_block`. Then `Net.send_message("apply_snapshot", _build_snapshot())` (shows the ready pip + emptied hand); `if _all_alive_ready(): _authority_run_enemy_phase()` else if this is the first ready this phase `_start_ready_deadlock(turn)`.
- `_all_alive_ready()`: every `alive` seat has `ready[seat]`.
- Inbound: `"ready"` when `mode == Mode.AUTHORITY` → `_authority_set_ready(int(payload.seat))`.
- **Verify (harness):** both seats Ready → enemy phase runs on both. **Critical invariant:** after the enemy phase, `execute_game_script` asserts `hand.size()==hand_uids.size()` for every seat (this is the regression the blocker warns about — assert across an enemy phase, not just a single play).
- **SOLO-safe:** `_authority_set_ready`/`_all_alive_ready` unreachable in SOLO; unconditional per-seat discard mirrors SOLO `:389-392` semantics.

**I5. Deadlock-breaker timer.**
New `_start_ready_deadlock(captured_turn)`; const near `:20-21`. Cancellation via `combat_epoch:39` (bumped `:279`) + `turn:358`.
- `const READY_DEADLOCK_SEC := 75.0`. `_start_ready_deadlock(captured_turn: int)`: `var epoch := combat_epoch`; `await get_tree().create_timer(READY_DEADLOCK_SEC).timeout`; `if combat_epoch != epoch or turn != captured_turn or phase != "playerTurn": return`; else for each alive un-ready seat `_authority_set_ready(seat)` (the last trips `_all_alive_ready`). Show an ASCII "waiting on N players…" nudge (glyph-gate safe).
- **Verify (harness):** ready only one seat, wait out a shortened timer (temporarily lower the const) → phase auto-advances; confirm a stale timer from a prior phase self-cancels (bump `turn` first).
- **SOLO-safe:** authority-only; never started in SOLO.

**I6. CLIENT enemy-phase receive.**
Dispatcher `"enemy_phase"` (E2) → `_client_on_enemy_phase(bundle)`.
- Seq-guard on `_last_board_seq` (drop if `int(bundle.seq) <= _last_board_seq`; gap → `_request_resync`), then `_replay_enemy_phase(bundle, combat_epoch)` (H3 sets `_last_board_seq` via its internal `_apply_snapshot`).
- **Verify (harness):** client runs the same enemy phase off the received bundle; boards converge; next-phase hands correct.
- **SOLO-safe:** client-only handler.

**M3b exit gate (full loop, harness):** both seats play a full player phase (each acting on its own hand, teammate rows count-only) → both Ready → one authoritative enemy phase folds, broadcasts, and replays in lockstep on both boards → next player phase deals correct hands to both → assert `hand.size()==hand_uids.size()` for every seat after the enemy phase → repeat until a win and a loss, each routing both instances to the lobby via `match_over`. Plus SOLO/overworld regression screenshots (Checkpoints F, G) still clean.

---

## Cross-references to the resolved review blockers/majors (for the executing engineer)

- **Blocker #1 (name/envelope):** §0 + B2/B5 — one name set, flat seq-inside envelope; M3b H1/H3 consume bare `bundle.snapshot`.
- **Blocker #2 (seq trackers):** A1 declares both; B5 uses `_last_board_seq`, B6 uses `_last_hand_seq`; I6/H3 reuse `_last_board_seq` for the bundle.
- **Blocker #3 (hidden hands):** Checkpoint C1 gates `_refresh_minis`.
- **Blocker #4 (`hand_uids.clear()`):** I4.
- **Major #5 (CLIENT switch-active):** D3.
- **Major #6 (`Net.peer_id`/CoopHandoff):** §0 + E1 use `Net.ensure_peer_id()` and `Net.combat_request`.
- **Major #7 (parse-once):** E1 parses in `_ready`; A2 note removes any re-parse from `_start_combat`.
- **Minors:** host-arm re-render (D4 trailing `_refresh`), tooltip on hovered survivor (A6b), match-end ordering (D5, accept-or-fix).

Relevant files: `C:\Users\fahim\Desktop\Pojects\Dorf Company\scripts\combat\combat.gd`, `C:\Users\fahim\Desktop\Pojects\Dorf Company\scripts\ui\card.gd`, `C:\Users\fahim\Desktop\Pojects\Dorf Company\scripts\net\net.gd`, and the new harness `C:\Users\fahim\Desktop\Pojects\Dorf Company\scenes\test\coop_harness.tscn` (+ `.gd`).
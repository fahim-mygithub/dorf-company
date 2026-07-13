<!-- Produced by the campaign-coop-design workflow (3 architectures -> judge panel -> 4 adversarial reviews).
     This is the FULL agent-authored spec. The SCOPED build plan actually being implemented is in
     the Build plan section of docs/plans/2026-07-12-campaign-coop-BUILD.md — where this doc is
     deliberately trimmed (no ack ring buffer, no foreman hammer, no reclaim panel, no autosave). -->

# Multiplayer Campaign — Final Build Spec (CampaignNet, v2)
**Milestone M5.** Branch `feat/multiplayer-coop` → `feat/campaign-net`.

Architecture: **the combat snapshot pattern, one layer up.** Host-authoritative absolute snapshots, client intents, the fight rides *inside* the snapshot. This revision folds in every legitimate defect from the four adversarial reviews (desync, solo-breaker, reconnect, anti-fun). Where a review and the draft disagreed, the review usually won; the exceptions are listed in the appendix.

**Three rules that generate most of this document:**
1. **The host is the only mutator and the only roller.** A client renders and sends intents. A client never runs a guarded coroutine and never awaits `combat_finished`.
2. **An idempotent *message* is not an idempotent *proposal*** — a proposal's own effect destroys the state that made its retry safe. Therefore every intent carries a **per-seat monotonic `iseq`** and the host keeps a `_seat_last_iseq` table. This single mechanism closes the retry-storm, the self-echo double-apply, the ghost-ring re-open, and the harness's shared-`peer_id` problem.
3. **`assert()` is stripped from release exports.** Every enforcement in this document is a `push_error` + repair, not an assert. Asserts are kept *additionally*, for the harness.

---

## 1. What we're building

Two to four friends dial into a room with a 4-char code and run **one dwarf company** together: one treasury, one rising rent, one contract board, one shop, one hex expedition. Each player **owns exactly one dwarf** — the dorf they picked in the lobby — and pilots it in every fight, exactly as in quick-match co-op combat. That dwarf is theirs for the whole campaign: it earns cards from reward tiles and the shop, it carries its wounds tile to tile, and it can die.

Decisions that risk the company — take this contract, push into that hex, extract, roll the dice on this event, spend below the rent line, end the month — are **proposals** that light a ring of ✅ pips on the crew bar. Decisions that are only yours — which loot card you want, which shop slot you claim, which class your heir is — resolve instantly and touch only your own dwarf.

**Nobody is ever a spectator for more than one fight.** A dwarf that goes down is replaced at its seat by an heir at the next tile; the fallen dwarf keeps rolling death saves in the wagon and, if it stabilises, **comes back to its seat at the end of the expedition**. If it dies, you lose the deck — not the seat, not the evening.

---

## 2. Decision rights

### 2.1 The three tiers

| Tier | Kinds | Gate |
|---|---|---|
| **RING** (shared risk) | `embark`, `hex`, `extract`, `event`, `endmonth`, `shop_checkout` (below-rent only), `continue` (only when `campaigns_left == 1`) | Unanimous among **present** seats. Proposing IS your aye. |
| **CLAIM** (personal, instant, owner-gated, free) | `loot_claim`, `basket`, `heir`, `reclaim_accept` | Absolute per-seat assignment. No vote. |
| **FREE** (instant, any seat) | `select` (contract highlight), `nav`, `continue` (when `campaigns_left > 1`), `shop_checkout` (when `treasury - basket_total >= fee`), `restart`, `cancel`, `hold`, `foreman` | Host mutates + pushes. `nav` is per-seat debounced 1.0 s and **rejected while a ring is open**. |

**Consequence, not name, decides the tier** (`_ring_kinds()` is a function of state, not a constant):
* `continue` is a ring **only** when it will trip `_end_month()` (`campaigns_left == 1`).
* `shop_checkout` is a ring **only** when it would take the treasury below `fee`.
* `restart` (post-GAMEOVER) is FREE — the run is over; there is nothing left to grief.

**Dead in co-op:** `crew_pick` / `_open_crew_select` / `_launch_fight` / `state == "CREW"`. The crew IS the seats, in seat order. These paths stay **verbatim and SOLO-only**.

### 2.2 The ring

```gdscript
var pending: Dictionary = {}    # {} = no open decision
# {"pid": int, "kind": String, "arg": String, "by": int,
#  "required": Array[int], "ayes": Array[int], "holds": Array[int], "opened_ms": int}
```

* **`arg` is ALWAYS a String** — `"2"`, `"3,2"`, `"risky"`, `"cleric"`, or `""`. JSON returns every number as `TYPE_FLOAT` (net.gd:139); a String needs zero kind-aware coercion. Parse at the `_resolve_decision()` match site.
* **Propose = aye.** `ayes = [by]`.
* `propose(same kind, same arg)` → an **aye on the existing pid** (set-add). `propose(different kind/arg)` → **new pid**, `ayes = [by]`, `holds = []`, log `"Vela changes the plan."`
* `hold` removes your aye and adds you to `holds`. **It does not veto** — a pure social signal.
* Host-side **pid CAS**: an inbound aye whose `pid != pending.pid` is dropped (and `rejects`-acked). This is the campaign's `_hand_index_of() < 0`.
* **`camp_vote` does not exist.** An aye is a `camp_intent` with the same `(kind, arg)`.
* **`cancel`** (proposer or host) clears `pending`. Any `nav` that changes `state` also clears `pending` (§2.4, D11/S14).

**`required` is one-directional (fixes the draft's self-contradiction):**
* Frozen against **additions** at open time — a returning peer may aye (recorded in `ayes`) but is **never added** to `required`, so it cannot re-block a ring that was about to close.
* **Always pruned on departure.** When the absence sweep flips `seats[s].present = false`, the host does `pending["required"].erase(s)` and immediately re-evaluates closure. A dropped laptop must never hold the table for 45 seconds, every tile.

### 2.3 Intent delivery: `iseq`, acks, and honest pips

```gdscript
# CLIENT: one counter. A NEW tap increments it. A RETRY re-sends the SAME iseq/nonce.
_iseq += 1
_pending_intent = {"seat": my_seat, "peer_id": Net.ensure_peer_id(),
                   "kind": kind, "arg": arg, "pid": _cur_pid(), "nonce": _next_nonce(), "iseq": _iseq}
Net.send_message("camp_intent", _pending_intent)
```

```gdscript
# HOST, _authority_intent() — FIRST check, before anything else:
if iseq <= int(_seat_last_iseq.get(seat, 0)):
    _ack(nonce)          # re-ack so the client's retry loop can terminate; do NOT re-apply
    return
_seat_last_iseq[seat] = iseq
```

This one table kills: the retry storm (a stale retry of a superseded proposal), the self-echo double-apply in the harness (`self_echo = true` bounces the host's own intent back), the ghost-ring re-open after a lost closing-ack, and the `foreman`-closes-the-*next*-ring case.

**The validator is TOTAL.** Every path out of `_authority_intent` either **acks** or **rejects** the nonce. A silently-dropped intent leaves a phantom ✅ and the table blames the wrong player — the worst failure mode a social game has.

```gdscript
func _ack(n: String)   -> void: _acks   = _ring_push(_acks, n)      # rolling window, cap 32
func _reject(n: String)-> void: _rejects= _ring_push(_rejects, n)   # rolling window, cap 32
```
`_acks`/`_rejects` are **rolling windows, not per-push deltas** — cleared only on `_new_run()`. A client must be able to see its ack in *any* later snapshot, including a keepalive, because the one snapshot carrying it may be the one that dropped.

**Retry rules (client):**
* Re-send `_pending_intent` (same `iseq`, same `nonce`) every `INTENT_RETRY_SEC := 1.2`.
* **A try is not consumed while `not Net.is_online()`** — `send_message` silently no-ops when not JOINED (net.gd:82-83), and the socket is down precisely when messages are lost.
* Re-fire immediately on `Net.realtime_joined`.
* **Termination is nonce-in-`acks`/`rejects` ONLY** — never `pending.ayes.has(my_seat)`, which is a property of the *ring*, not of *your message*.
* Stop also when the target ring closes (`pending == {}` or `pending.pid != my intent's pid`) — with `iseq` this is belt-and-braces, not correctness.
* On `rejects`, or after `INTENT_GIVEUP_SEC := 15.0` offline-excluded seconds: **clear the optimistic pip** and log locally `"⚠ your tap didn't land — tap again."`

**Optimistic pip:** a client renders its own pip as a **dimmed ✅ (alpha 0.45)** on tap, solid once the snapshot confirms. Safe because every intent is idempotent under `iseq`.

### 2.4 The marker UI

**A persistent CREW BAR** — one token per **seat, in seat order** (class emoji, dwarf name, HP bar, `(you)`). It is **co-op chrome**: built into `hud` (a new `Control` sibling of `screen_root`, y ≈ 96–176), gated `if mode != Mode.SOLO`, driven off `seats`. It is **not** `_build_exp_crew_strip` (which draws into `screen_root` at y ≈ 716–880 and collides with the shop panel, the spoils targets and the loot targets). `_build_exp_crew_strip` is left alone for the HEX screen.

| pip | meaning |
|---|---|
| `✅` | aye'd the open ring (dimmed = my tap, unconfirmed) |
| `✋` | HOLD — removed their aye. Signals disagreement; does **not** veto |
| `⏳` | ring open, hasn't answered |
| `💤` | absent — pruned from `required`, token greyed |
| `💀` | dwarf down/dead, heir pending — **still votes, still claims** |
| *(none)* | no ring open |

**Proposal banner** while `pending != {}`: `⚑ Bruni: push into 💀💀 Fight — 2/4 aye` + **AYE** + **✋ Hold** + **✕ Cancel** (proposer/host only). The proposed hex draws its ring in the proposer's seat colour — `hex_tile.gd` gains one param `propose_col: Color`; `SEAT_COL := [amber, blue, green, violet]`.

### 2.5 Anti-AFK — three mechanisms, no overlap

**1. Presence, keyed BY SEAT.** Every peer emits `camp_pulse {seat}` every `PULSE_SEC := 3.0`. Keyed by seat, not `peer_id`, because the only verification harness shares one `Net.my_peer_id`.

```gdscript
func _pulse() -> void:
	if mode == Mode.AUTHORITY:
		_seat_last_pulse[my_seat] = Time.get_ticks_msec()   # production is broadcast.self=false:
	Net.send_message("camp_pulse", {"seat": my_seat})        # I never hear my own pulse.

func _sweep_absence() -> void:                               # host _process
	if mode != Mode.AUTHORITY: return
	if not Net.is_online():
		_online_since_ms = Time.get_ticks_msec()             # deaf: freeze the clock, absent NOBODY
		return
	var now := Time.get_ticks_msec()
	if now - _online_since_ms < int(ABSENT_SEC * 1000.0): return   # grace after every re-join
	var changed := false
	for s in range(seats.size()):
		if s == my_seat: continue                            # I am always present to myself
		var p: bool = (now - int(_seat_last_pulse.get(s, 0))) < int(ABSENT_SEC * 1000.0)
		if p != bool(seats[s]["present"]): changed = true
		seats[s]["present"] = p
		if not p and not pending.is_empty(): pending["required"].erase(s)
	if changed:
		_sync_absent()                                       # push into a live fight child (§6)
		_try_close_ring()
		_camp_push()
```
Without the two guards above, the host absents **itself** after 12 s (its own pulse never comes back) and a 12-second host socket blip absents **everyone**, converting the campaign to single-player with all sockets green. Both were masked by the harness's `self_echo = true`.

Any inbound message from an absent seat un-absents it (`present = true`) and lets it aye the *current* pid — it is **not** re-added to `required`.

**2. 🔨 Foreman's Call** — host-only button, appears after `RING_NAG_SEC := 20.0`, enabled when `ayes.size() * 2 > required.size()`. Force-closes the ring. Loud in the shared log. **Not available for a below-rent-line `shop_checkout`.**

**3. `RING_AUTO_SEC := 45.0`** (host `_process` backstop), dropping to **`RING_LAST_SEC := 12.0`** once `ayes.size() == required.size() - 1` — the last holdout is either tapping or gone. Auto-close requires `ayes.size() >= 2` **or** `required.size() == 1` (never fires on a lone stale aye).
**Below-rent-line `shop_checkout` is exempt:** on expiry the host **clears the basket and closes the ring as a no-op**. Nothing irreversible, no deadlock, and "below the rent line, unanimity is required" survives intact.

### 2.6 Seat reclaim (a crashed friend is not a spectator)

`user://peer.cfg` on web is IndexedDB and is routinely unavailable (incognito, third-party blocking). A new `peer_id` must not mean a 40-minute spectator.

`camp_hello {seat: -1}` from an unknown `peer_id` → the host lists seats with `present == false` for > `ABSENT_SEC` and shows a host-only panel: `"🔁 Grimli's seat is open — let this player take it?"`. On accept (`reclaim_accept`, arg = seat): `seats[s].peer_id = new_pid`, `present = true`, `_camp_push()`. ~15 lines; the single highest-value robustness feature for a Discord session.

### 2.7 Loot — claim + deterministic split, never a race

A reward tile offers 3 cards; **exactly one card leaves the tile** (deck growth must not scale with party size).

```gdscript
var claim: Dictionary = {}   # {} or {"kind":"loot"|"spoils", "cards":[cid×3], "picks":[int per seat], "opened_ms":int}
# picks[seat]: -1 undecided · -2 pass · 0..2 = "I want cards[i] for MY dwarf"
```
One tap = *"claim card i for my dwarf."* Absolute per-seat assignment (idempotent under duplication and reorder).

**Close condition:** every **present** seat has picked-or-passed. **Auto-pass applies only to `present == false` seats** — a present player is never silently timed out of a persistent deck reward for reading three unfamiliar cards. If a present seat stalls, the host's 🔨 button (after `RING_NAG_SEC`) passes non-responders.

**Tie-break is DETERMINISTIC, not a dice slap:** among claimants, order by `(loot_wins asc, last_loot_tile asc, seat asc)`; the first wins. `d["deck"].append(...)`, `d["loot_wins"] += 1`, `d["last_loot_tile"] = _tile_counter`. Losing claimants get a consolation `exp_loot_gold += LOOT_CONSOLATION_GOLD (4)` each. Log `"Vela takes Whetstone — Bruni and Kori split 8g."`

`loot_wins` + `last_loot_tile` are new keys on `_make_dwarf()` and form a **campaign-long fairness ledger**: over four reward tiles, four players each get roughly one, *by construction*. `hex_loot.is_empty()` remains the spent-guard backstop. Same machinery serves `pending_spoils` (`claim.kind = "spoils"`).

### 2.8 Shop — a basket, not a till

```gdscript
var shop_basket: Array = []   # [int per seat], -1 = empty, else index into shop_stock
```
* **`_reroll_shop` emits `maxi(3, seats.size())` slots in co-op** (3 in SOLO). One slot per seat is available by construction — **no ping-race for a persistent reward**, which is exactly the arbitration the loot design rejected. A duplicate `basket` on a taken slot is still `reject`-acked.
* A basket entry applies to **your own dwarf only** (card → your deck; heal → your dwarf; **recruit → the Reserve bench**, §8).
* **Nothing is charged until checkout.** The HUD renders the projected damage live: `💰 140 → 55`, turning **RED** when `treasury - basket_total < fee`. That red number, seen by four people at once, is what stops the blow-out.
* **Checkout is FREE (instant, any seat) while `treasury - basket_total >= fee`.** It becomes a RING only below the rent line — and that ring is not Foreman-Callable and auto-expires by clearing the basket. One idle player can never block all shopping forever.
* Buy button disabled while `basket_total > treasury`.

---

## 3. Authority + state model

```gdscript
enum Mode { SOLO, AUTHORITY, CLIENT }
var mode: int = Mode.SOLO
```

**The host owns** every mutation of `treasury / fee / month / months_survived / campaigns_left / roster / seats / carried / reserve / contracts / selected_contract / current / exp_contract / exp_crew / hexes / hex_cur / exp_loot_gold / hex_loot / claim / shop_stock / shop_basket / pending / outcome_view / fight_block / over_kind`, every `randf/randi/shuffle` (§7), every `await`-paced coroutine and `run_epoch`, every ring, every timer.

**A client may touch, and only touch:** `_last_cseq`, `_run_id`, `_live_fid`, `_fight_node`, `_pending_intent`/`_iseq`, the local deck-inspect overlay, and local cosmetic tweens (`_tween_treasury_to`, the 🚩 hex tween, `_spawn_coins`).

> **A CLIENT NEVER RUNS A GUARDED COROUTINE.** `busy` on a client is a **replicated render flag**, never a control-flow gate. `run_epoch` on a client exists only to abort stale local tweens. **A CLIENT NEVER AWAITS `combat_finished`.**
> *(Write this verbatim as a comment at the `busy` declaration.)*

### 3.1 One funnel — and the host goes through the wire logic too

```gdscript
func _intent(kind: String, arg: String) -> void:
	match mode:
		Mode.SOLO:      _resolve_decision(kind, arg, 0)        # ZERO Net traffic; existing path
		Mode.AUTHORITY: _authority_intent(my_seat, Net.ensure_peer_id(), kind, arg,
		                                  _cur_pid(), _next_nonce(), _bump_iseq())
		Mode.CLIENT:    _send_intent(kind, arg)                # + retry; NO local mutate
```
Host taps take the same door as client intents, so the validator is exercised by a single peer in the harness.

`_authority_intent()` validates in this exact order — **and every early return acks or rejects**:
1. **`iseq` dedup** (§2.3).
2. Seat bounds; `_peer_owns_seat(peer_id, seat)`.
   ```gdscript
   func _peer_owns_seat(pid: String, seat: int) -> bool:
       if seats.is_empty() or _harness: return true          # harness shares ONE Net.my_peer_id
       return str(seats[seat].get("peer_id", "")) == pid
   ```
3. `_camp_barrier_open` (§4, opened by the `camp_start` hello barrier).
4. **Busy gate, per-kind** — `busy` stays `true` across HEXREWARD / HEXEVENT / SPOILS (`_enter_hex` sets it at :1377; only `_resume_hex` clears it at :1427), so a blanket `not busy` check deadlocks every expedition on its first event tile:
   ```gdscript
   const _BUSY_OK := ["event","loot_claim","basket","heir","hold","cancel","foreman","nav","reclaim_accept"]
   if busy and not _BUSY_OK.has(kind): _reject(nonce); return
   ```
   **and** the host clears `busy = false` as the first line of `_open_hex_reward` (card branch), `_open_hex_event` and `_open_spoils` — these are input-accepting screens whose SOLO handlers already gate on `state`, not `busy`; `_resume_hex` re-establishes the guard. Clients' button-disable is correspondingly `busy and not state in ["HEXREWARD","HEXEVENT","SPOILS"]`.
5. `state` matches the kind's expected screen.
6. `pid` CAS (ayes/holds) / legality (`_hex_neighbors(hex_cur).has(arg)`, `treasury >= cost`, `not slot.sold`, seat owns the dwarf, `not hex_loot.is_empty()`, `not _seat_reseated(seat)`).
7. `_ack(nonce)`; mutate (open/aye a ring, or resolve a FREE/CLAIM kind); `_camp_push()`.

### 3.2 The single mutation funnel

```gdscript
func _resolve_decision(kind: String, arg: String, seat: int) -> void:
	if mode == Mode.CLIENT: push_error("client mutation"); return
	if not _state_ok_for(kind): return          # RE-CHECK at CLOSE time, not only at intent time
	match kind:
		"select":         selected_contract = int(arg); _goto("CONTRACTS")
		"embark":         await _embark_idx(int(arg))
		"hex":            await _enter_hex(arg)
		"extract":        await _finish_expedition("extract", run_epoch)
		"event":          await _do_event(arg == "risky")
		"continue":       await _do_continue()
		"endmonth":       await _end_month()
		"shop_checkout":  _checkout_basket()
		"restart":        _new_run()
		"nav":            _do_nav(arg)          # clears `pending` if it changes `state`
		"loot_claim":     _set_pick(seat, int(arg))
		"basket":         _set_basket(seat, int(arg))
		"heir":           _set_heir_class(seat, arg)
		"reclaim_accept": _grant_seat(int(arg))
		"hold":           _do_hold(seat)
		"cancel":         _do_cancel(seat)
		"foreman":        _do_foreman(seat)
	_camp_push()
```

### 3.3 Handler / body split (non-negotiable, and it is what breaks SOLO if skipped)

Today's handlers are **not** pure mutation bodies — they carry branch logic, screen dispatch and re-entrancy guards. Re-entering them from `_resolve_decision` recurses or drops behaviour. **Every RING/FREE handler splits in two:**

| existing handler → becomes the *shim* (guards + `_intent()`) | new *body* called by `_resolve_decision` |
|---|---|
| `_on_contract_input(e,i)` → `if selected_contract != i: _intent("select", str(i)) else: _intent("embark", str(i))` | `_embark_idx(i)` — sets `selected_contract = i`, keeps `_ready_count() >= contracts[i]["crew_size"]` guard, keeps the `selected_contract = -1` reset |
| `_on_event_choice(risky)` → `if state != "HEXEVENT": return; _intent("event", "risky" if risky else "safe")` | `_do_event(risky)` — the current body from :1637 down, **including** the `state = "HEX"` double-tap lock and the rolls |
| `_on_continue()` → `if busy: return; _intent("continue","")` | `_do_continue()` — **`if not pending_spoils.is_empty(): _open_spoils(); return` then `await _after_campaign()`**. Routing straight to `_after_campaign()` silently deletes the SPOILS screen and never clears `pending_spoils` — Phase-4 deckbuilding gone from solo. |
| `_on_rest()` → `_intent("endmonth","")` | `_end_month()` (unchanged) |
| `_on_extract()` → `_intent("extract","")` | `_finish_expedition("extract", run_epoch)` |
| `_on_hex_input(e,key)` → `_intent("hex", key)` | `_enter_hex(key)` (unchanged) |
| `overlay_btn.pressed` → `_intent("restart","")` | `_new_run()` |

**The per-handler `if busy or state != "X": return` guards STAY.** `_authority_intent`'s checks are an *additional* wire-side gate, not a migration target. Removing them costs SOLO its double-tap protection.

**CLAIM kinds (`loot_claim`, `basket`, `heir`, `reclaim_accept`) are CO-OP ONLY.** In SOLO they would index `seats[]` / `shop_basket[]`, which are empty → crash; and they would delete a real solo decision (SOLO *chooses which of the crew* learns the card, :1587-1596, and which roster dwarf gets the shop card/heal, :1860-1883, with the heal-eligibility filter at :1835). So:
* `_on_hexloot_card_input` / `_on_hexloot_target_input` / `_on_hexloot_skip` / `_on_spoil_*` / `_on_shop_input` / `_on_shop_target_input` / `_buy_recruit` keep their **verbatim bodies behind `if mode == Mode.SOLO`**.
* `_open_hex_reward` / `_open_spoils` / `_build_shop_panel` build the **existing two-tap picker in SOLO** and the `claim` / `basket` grid only when `mode != SOLO`.
* `_set_pick` / `_set_basket` / `_set_heir_class` open with `if mode == Mode.SOLO: push_error("co-op only"); return`.

---

## 4. Wire protocol

**Namespace rule (invariant):** every campaign event is prefixed `camp_`. Combat owns `submit_action | combat_ready | resync | ready | apply_snapshot | match_over`; the lobby owns `hello | roster | start`. Both dispatchers `match` on the event name with **no mutating catch-all**, so the campaign and its nested combat child share the one `Net.message_received` bus with zero collision. `Net` gains a debug counter that prints each unhandled event name **once** — a mis-named event currently fails *silently*.

**The campaign dispatcher is mode-branched, exactly like combat's** (combat.gd:876). Without this, the harness's `self_echo = true` makes the host ingest its own snapshot, wholesale-replacing every dict its live coroutines hold references to:

```gdscript
func _on_camp_msg(event: String, payload: Dictionary) -> void:
	if mode == Mode.AUTHORITY:
		match event:
			"camp_intent": _authority_intent(int(payload.get("seat",-1)), str(payload.get("peer_id","")),
			                                 str(payload.get("kind","")), str(payload.get("arg","")),
			                                 int(payload.get("pid",-1)), str(payload.get("nonce","")),
			                                 int(payload.get("iseq",0)))
			"camp_hello":  _authority_on_hello(payload)
			"camp_resync": _authority_on_resync(payload)
			"camp_pulse":  _authority_on_pulse(payload)
	elif mode == Mode.CLIENT:
		match event:
			"camp_snapshot": _apply_camp_snapshot(payload)
			"camp_pulse":    pass
```
plus `if mode != Mode.CLIENT: return` as the first line of `_apply_camp_snapshot` (belt and braces, mirroring `_net_board`'s guard).

| Event | Payload | Dir | Purpose |
|---|---|---|---|
| **`camp_snapshot`** | §5 | HOST → ALL | The one absolute truth. Sent from `_camp_flush()`, the single send point. Clients drop `cseq <= _last_cseq`; on a gap they `camp_resync` **and still apply**. Re-sent **verbatim** every `KEEPALIVE_SEC := 5.0`. |
| **`camp_intent`** | `{seat, peer_id, kind, arg:String, pid:int, nonce:String, iseq:int}` | CLIENT → HOST | The only client→host channel. Retried per §2.3. |
| **`camp_hello`** | `{seat:int, peer_id:String}` (`seat = -1` = unknown peer → reclaim panel, §2.6) | CLIENT → HOST | On entry and on every `Net.realtime_joined`. Host re-binds `peer_id` → its **original** seat (permanent for the campaign's life), sets `present = true`, and answers with a push on **every** hello. **Ack condition:** `_hello_ack_target = _last_cseq` at send; retry on 1.5 s until `_last_cseq > _hello_ack_target`. (`_last_cseq >= 0` is a *tautology* on a re-dial — the draft's condition would have sent the reconnect hello exactly once, fire-and-forget.) |
| **`camp_resync`** | `{seat, peer_id}` | CLIENT → HOST | On a `cseq` gap, or by a client watchdog after `RESYNC_SILENT_SEC := 8.0` of silence while `Net.is_online()`. Host replies with **`_last_snap` verbatim** (never a rebuild — a fresh `cseq` would force a full screen rebuild on every already-current client). |
| **`camp_pulse`** | `{seat:int}` | EVERY PEER → ALL | Presence, every 3 s. Keyed **by seat**. |
| **`camp_start`** | `{run_id:int, order:[peer_id...], seats:[{peer_id,pname,cls,name}], seat_count:int}` | HOST(lobby) → ALL | The lobby's second start button. **Barriered:** the host re-broadcasts every 1.5 s until every seat has sent a `camp_hello`; the lobby scene stays alive until *its own* `camp_start` lands, so a dropped frame is repaired. `_camp_barrier_open` opens when `_hello_seats.size() >= seats.size() - 1` (combat's threshold, combat.gd:897). Each peer computes `seat = order.find(Net.my_peer_id)`, stamps `net{mode,seat,seat_count}`, sets `Net.campaign_request`, `change_scene_to_file("res://scenes/overworld/overworld.tscn")`. |

**NOT added, deliberately:** `camp_fight` / `camp_fight_over` / `camp_vote` / `camp_over` / **`camp_absent`**.
The fight lifetime rides the snapshot's `fight` block; game over rides `state == "GAMEOVER"` + `over`; an aye is a `camp_intent`. **`camp_absent` is deleted outright:** production is `broadcast.self = false` (net.gd:97-99), so the host — *the only peer that runs `_all_alive_ended()`* — would never receive its own absence broadcast, and the enemy phase would hang forever on every tile. It would have passed the harness (`self_echo = true`) and failed in production: the worst shape of bug this document can ship. Absence is **already in the snapshot** (`fight.absent`) and is written into the child by a **direct property call** (§6.3).

**`match_over` is UNCHANGED** (`{won: bool}`). A client never emits `combat_finished`.

---

## 5. The campaign snapshot

```gdscript
func _camp_push() -> void:
	if mode != Mode.AUTHORITY: return          # SOLO + CLIENT no-op — mirrors combat's _net_board()
	_dirty = true
	if not _flush_timer.is_stopped(): return   # a flush is already armed for the rate window
	_flush_timer.start(0.1)                    # -> _camp_flush()   (TRAILING edge, never a drop)

func _camp_flush() -> void:
	if not _dirty or mode != Mode.AUTHORITY: return
	_dirty = false
	_check_seat_invariant()                    # push_error + repair, NOT assert (§9)
	_last_snap = _build_camp_snapshot()        # the keepalive & resync re-send THIS, verbatim
	Net.send_message("camp_snapshot", _last_snap)
```
The rate cap **must be a trailing-edge flush, not a discard.** A naive `if now - _last < 100: return` throws away the *last* push of an animated beat — the one carrying `busy = false` — and the verbatim keepalive then re-broadcasts `busy = true` forever, hard-disabling every client's UI with a green socket and no `cseq` gap for the watchdog to see.

```gdscript
func _build_camp_snapshot() -> Dictionary:
	return {
	  "run_id": _run_id,                       # int, minted at _new_run(). See §5.4.
	  "cseq": _next_cseq(),                    # int, monotonic; NEVER reset for the scene's life
	  "state": state,                          # DASHBOARD|CONTRACTS|RESOLVE|OUTCOME|SPOILS|HEX|HEXREWARD|HEXEVENT|GAMEOVER
	  "busy": busy,                            # RENDER FLAG ONLY on a client
	  "run_epoch": run_epoch,
	  "econ": {"treasury":treasury, "fee":fee, "month":month,
	           "months_survived":months_survived, "campaigns_left":campaigns_left},
	  "roster": _ser_roster(),                 # [{did,name,cls,status,recover,hp,max_hp,deck,downed,stable,
	                                           #   ds_success,ds_fail,loot_wins,last_loot_tile}]
	  "seats": _ser_seats(),                   # [{peer_id,pname,dwarf_did,present,heir_cls}]  index == seat
	  "carried": carried,                      # Array[did] — fallen dwarves still rolling death saves
	  "reserve": reserve,                      # Array[did] — shop Recruits waiting to be an heir
	  "contracts": _ser_contracts(),           # contract minus "crew", plus "crew_dids": Array[String]
	  "selected_contract": selected_contract,
	  "current": _ser_contract(current),
	  "exp": _ser_exp(),                       # {} or {contract, crew_dids:[did per SEAT], tile_counter,
	                                           #        hexes:{"c,r":{q,r,kind,danger,resolved,objective}},
	                                           #        cur:String, loot_gold:int}
	  "hex_loot": hex_loot,                    # Array[String] card ids
	  "claim": claim,                          # {} or {kind, cards:[cid×3], picks:[int per seat], opened_ms}
	  "shop": {"stock": shop_stock, "basket": shop_basket},
	  "pending": pending,
	  "outcome": outcome_view,                 # {} or {view:"dice"|"expedition", success, payout, loot, obj,
	                                           #        roll, strength, ready:bool, pending:[[did,"lost"|"wounded"]]}
	  "fight": fight_block,                    # {} or {fid:int, req:{crew,enemies,enemy_scale}, absent:[int]}
	  "reclaim": _reclaim_req,                 # {} or {peer_id, pname} — an unknown peer asking for a seat
	  "log": _log_tail,                        # last 6 _msg() lines — the shared narration
	  "over": over_kind,                       # "" | "victory" | "bankrupt"
	  "acks": _acks, "rejects": _rejects,      # ROLLING WINDOWS (cap 32), not per-push deltas
	}
```

### 5.1 The poison keys — the campaign's `node` problem

Campaign dicts carry no node refs and no hidden RNG, so the client **wholesale-replaces** — the strongest anti-desync primitive available. Three things still cannot cross the wire and must be **rebound**, in this order, inside `_ingest()`:

| Poison | Why | Rebind |
|---|---|---|
| `contract["crew"]`, `exp_crew`, `carried`, `reserve`, `outcome.pending[i][0]` | These are **references into `roster`** (:698/1098/1476/856). Serialized they become detached copies. | Ship **`did`s**. On apply: rebuild `roster` first, then `exp_crew = exp.crew_dids.map(_dwarf_by_did)`, then `carried`/`reserve`, then contracts, then `current`, then `outcome.pending`. This is the campaign's `dict["node"] = pc_emoji[slot]`. |
| **UI closure bindings** | `gui_input.connect(_on_X_input.bind(d))` at :766, :1569, :1854 binds a **live dwarf dict**; after a wholesale replace it points at a dead dict. | **HARD RULE: every handler binds `d["did"]`, never the dict.** A single surviving `.bind(d)` is a silent, un-debuggable desync. C0's gate greps for it. |
| `hexes[k]["dist"]` | BFS scratch, map-gen only, never rendered. | Stripped from the wire. |

**Stable identity:** `_make_dwarf()` gains `"did": "d%d" % _next_did()`, `"loot_wins": 0`, `"last_loot_tile": -1`. `name` is **not** unique (`RECRUIT_NAMES` collide). Array index is **not** an id. **Roster is append-only** (`lost` dwarves stay as memorials); never `erase()`/`remove_at()`.

### 5.2 Int coercion

`JSON.parse_string` returns **every number as `TYPE_FLOAT`** (net.gd:139). `hexes["3,2"].danger == 2.0` flows into `_danger_scale(danger: int)` and `_hex_px(cc: int, rr: int)` (typed params → runtime error); `"%d" % treasury` on a float **crashes**. Use a **recursive walker with two allowlists**:

```gdscript
const _CAMP_INT_KEYS := ["run_id","cseq","run_epoch","treasury","fee","month","months_survived",
  "campaigns_left","hp","max_hp","recover","ds_success","ds_fail","loot_wins","last_loot_tile","seat",
  "payout","duration","danger","crew_size","cost","q","r","loot_gold","tile_counter",
  "selected_contract","pid","by","opened_ms","fid","seat_count","roll","strength","loot","obj","iseq"]
const _CAMP_INT_ARRAYS := ["required","ayes","holds","picks","basket","absent"]   # coerce ELEMENTS
# NOT coerced (legitimately float): mod.scale, mod.pay, enemy_scale
func _coerce_ints(v: Variant) -> void: ...   # walks Dictionary + Array recursively
```
A key-only walk misses `pending.ayes`, `claim.picks`, `shop.basket`, `fight.absent`. `run_epoch` **must** be in the list — it is compared with `!=` in the client's tween guards, and a float makes `e != run_epoch` true when equal.

### 5.3 Apply

```gdscript
func _apply_camp_snapshot(s: Dictionary) -> void:
	if mode != Mode.CLIENT: return
	_coerce_ints(s)
	var rid: int = int(s.get("run_id", 0))
	if rid != _run_id:                                   # host restarted / _new_run() (§5.4)
		_run_id = rid; _last_cseq = -1; _live_fid = -1
		if is_instance_valid(_fight_node): _teardown_fight()
	var cs: int = int(s.get("cseq", 0))
	if cs <= _last_cseq: return                          # stale / dup / keepalive we already have
	if _last_cseq >= 0 and cs > _last_cseq + 1:
		_request_camp_resync()                           # gap -> ask; STILL APPLY (absolute = idempotent)
	_last_cseq = cs
	_last_snap_ms = Time.get_ticks_msec()
	var prev_tre: int = treasury
	_ingest(s)                                           # wholesale replace + did-rebind (§5.1)
	_sync_absent(s.get("fight", {}))                     # BEFORE the fid early-return (§6.3)
	if _sync_fight(s):
		_tre_shown = treasury                            # no tween under a fight; don't let it drift
		return
	if treasury != prev_tre: _tween_treasury_to(treasury) # cosmetics DERIVED FROM THE DIFF
	_goto(state, true)
```

### 5.4 `run_id` — the counter-reset trap

`_cseq` and `_fid` are **per-process counters and are never reset for the scene instance's life** (matching combat's `_seq` / `_last_board_seq`). But `_new_run()` — and C7's `user://camp.save` resume — restarts the host process/scene. Without `run_id`, a client holding `_last_cseq = 137` **silently drops every snapshot from the new host, forever, on a green socket**, and a client holding `_live_fid = 1` sits in a zombie combat child from the previous run. `run_id` is minted `randi()` at `_new_run()`, checked **before** the cseq guard, and resets `_last_cseq`, `_live_fid` and any live fight.

### 5.5 `_goto()` — builders only, NOT a "pure refactor"

`_goto(new_state, from_snapshot)` **dispatches builders and nothing else**: `_build_dashboard`, `_build_contracts`, `_build_spoils`, `_build_hexcrawl`, `_build_hex_reward`, `_build_hex_event`, `_build_outcome` / `_build_expedition_outcome`, `_build_rolling` (CLIENT-only), overlay for GAMEOVER.

Not one of the ten existing call sites has the shape `state = X; _clear_screen(); _build_X(); _refresh_hud()`. Every one of these **keeps its pre-work and ends with `_goto(...)`**:

| site | pre-work `_goto()` must NOT swallow |
|---|---|
| `_enter_dashboard` :384 | the disbanded gate; `selected_contract = -1`; `overlay.visible = false` |
| `_on_view_contracts` :395 | `if busy: return`; `selected_contract = -1` |
| `_open_expedition` :1096 | mutates `exp_contract`/`exp_crew`, resets `downed/stable/ds_*`, calls **`_gen_hex_map()` (RNG)**, `busy = false`, **`_reseat_fallen()`** (§8) |
| `_open_spoils` :710 | `spoils_pick = -1`; `busy = false` |
| `_open_hex_reward` :1488 | **RNG**, early `await _resume_hex(e)` return, `hex_loot_pick = -1`, `busy = false` |
| `_resume_hex` :1421 | wipe check → `_finish_expedition`; `busy = false` |
| `_game_over` :1073 | builds **no** screen — sets `overlay_label.text` + `overlay.visible = true` |

The **six rebuild sites that do not change `state`** (:531, :692, :779, :815, :1584, :1826 — `_clear_screen(); _build_X()` after a selection tick) are **not** routed through `_goto`.
`state == "RESOLVE"`: `_embark` draws the dice cinematic progressively into `screen_root` from locals. `_build_rolling()` (a static "🎲 Rolling…" card) is gated `if mode == Mode.CLIENT` — otherwise SOLO gets a static card *underneath* its own animation.

### 5.6 Builders must project REPLICATED state, never host-local coroutine state

`_build_outcome` (:941) and `_build_expedition_outcome` (:1740) hardcode `continue_btn.disabled = true`; only `_outcome_beats` (:966) — a host-only coroutine — re-enables it. A client rebuilding OUTCOME from every snapshot would be reborn with a permanently dead Continue and could never even *propose* it.

**Fix:** `outcome_view` gains a replicated **`ready: bool`**. Set `false` at each OUTCOME entry (:564, :837, :1704); set `true` exactly where :966 lives. Both builders read `continue_btn.disabled = not outcome_view.get("ready", false)`. (The naive `disabled = busy` is *not* byte-identical: `_finish_expedition` sets `busy = false` at :1705 *before* building at :1707, so the expedition Continue would go live before `_outcome_beats` banks the payout.)

**Audit every `disabled =` / `mouse_filter` in `overworld.gd` for this pattern before C2's gate** — `_build_shop_slot`'s `afford` (:1770), the Extract button, hex-tile pickability.

### 5.7 Size / rate

~5–8 KB JSON (~15 KB late-campaign). ~1 msg per tap + ~6 per animated transition + 1 / 5 s idle → a 4-player 8-month campaign ≈ 1.5–2.5 k messages. Supabase caps: 256 KB/msg, 2 M/mo. Delta snapshots are explicitly out.

---

## 6. Combat handoff

**The fight is a block in the snapshot. No new events.**
```gdscript
"fight": {} | {"fid": int, "req": {crew, enemies, enemy_scale}, "absent": Array[int]}
```

### 6.1 Host, entering (inside the unchanged `_hex_combat(danger, e)` / `_embark_fight`)

```gdscript
_fid += 1
fight_block = {
  "fid": _fid,
  "req": {
    "crew": _build_crew_specs(exp_crew),                    # index == SEAT, always (§6.5)
    "enemies": _roll_encounter(exp_contract["tier"], comp), # HOST-ONLY randi() — §7
    "enemy_scale": clampf(1.0 + (comp.scale-1.0) + (mscale-1.0) + (_danger_scale(danger)-1.0)
                          + (pscale-1.0), Db.PARTY_SCALE_MIN, Db.ENEMY_SCALE_MAX),
  },
  "absent": _absent_seats(),
}
busy = true
_camp_push()                       # EVERY peer, host included, reacts to the SNAPSHOT
```
`req` is byte-identical on every peer because **the host rolled it**. Non-negotiable: `_build_snapshot()` **erases `moves`** (combat.gd:707) — a client that rolled its own comp from `Db.ENCOUNTER_POOLS` (4 comps/tier → 75 % mismatch) would render a different enemy roster with different move rotations **permanently and un-repairably**, and combat's slot-keyed merge would paste the host's `hp`/`move_i` onto the wrong archetype.

### 6.2 Every peer — one shared code path

```gdscript
func _sync_fight(s: Dictionary) -> bool:
	var f: Dictionary = s.get("fight", {})
	if f.is_empty():
		if is_instance_valid(_fight_node): _teardown_fight()   # SELF-HEAL: a lost match_over cannot strand me
		return false
	if int(f["fid"]) == _live_fid: return true                 # idempotent (absent already synced, §6.3)
	# VALIDATE BEFORE LATCHING — a bad req must be repairable, and _live_fid is the latch.
	if (f["req"]["crew"] as Array).size() != seats.size():
		push_error("fight req crew %d != seats %d — resync" % [(f["req"]["crew"] as Array).size(), seats.size()])
		_request_camp_resync(); return false                   # _live_fid NOT set
	if is_instance_valid(_fight_node): _teardown_fight()
	_live_fid = int(f["fid"])
	var req: Dictionary = (f["req"] as Dictionary).duplicate(true)
	req["net"] = {
	  "mode": ("authority" if mode == Mode.AUTHORITY else "client"),
	  "seat": my_seat, "seat_count": seats.size(),
	  "embedded": true,                            # <- the ONLY new combat concept
	  "absent": f.get("absent", []),
	  "peers": _peer_seat_map(),                   # {peer_id: seat} — closes _peer_owns_seat
	}
	var fight = COMBAT_SCENE.instantiate()
	fight.request = req                            # BEFORE add_child (_ready runs on entry)
	screen_root.visible = false; hud.visible = false
	add_child(fight)
	_fight_node = fight
	if mode == Mode.AUTHORITY: _await_fight(fight, _live_fid)   # ONLY THE HOST AWAITS
	return true

func _teardown_fight() -> void:
	_live_fid = -1
	if is_instance_valid(_fight_node):
		_fight_node.shutdown()                     # SYNCHRONOUS — see §6.4 change 2
		_fight_node.queue_free()
	_fight_node = null
	screen_root.visible = true; hud.visible = true
```

### 6.3 Absence is a property write, not a message

```gdscript
func _sync_absent(f: Dictionary) -> void:
	if not is_instance_valid(_fight_node): return
	_fight_node.set_absent((f.get("absent", []) as Array).duplicate())   # re-evaluates the gates (§6.4)
```
Called from `_apply_camp_snapshot` **above** the `fid` early-return (so a live fight's absent set is refreshed by every snapshot), and directly by the host's `_sweep_absence()`. Zero wire cost, keepalive-repaired for free, and it works in production where a broadcast to yourself does not.

### 6.4 The complete `combat.gd` diff (8 changes, all additive)

```gdscript
# 1. _ready(), replacing line 117 — THE PARENT-KILLER.
#    _on_match_finished_local() -> _to_lobby() -> get_tree().change_scene_to_file(), connected in
#    _ready() (BEFORE the campaign's await registers), fires FIRST and DELETES THE CAMPAIGN SCENE.
_embedded = bool(net.get("embedded", false))
_absent   = (net.get("absent", []) as Array).duplicate()
_peers    = net.get("peers", {})
if mode != Mode.SOLO and not _embedded:
	combat_finished.connect(_on_match_finished_local)

func _to_lobby() -> void:
	if _embedded: return                     # belt AND braces: guard the destructor itself
	get_tree().change_scene_to_file("res://scenes/menu/lobby.tscn")

# ...and in _on_net_message's CLIENT arm:
	"match_over": if not _embedded: _client_match_over(payload)
# NOTE: there is NO "camp_absent" arm. Absence arrives via set_absent().

# 2. NEW — synchronous shutdown. queue_free() is DEFERRED: for the rest of the frame the dead child
#    is still on Net.message_received alongside the new one, and a stale AUTHORITY instance will
#    answer submit_action/resync/combat_ready and _net_board() a snapshot of a DEAD BOARD.
#    Also: the reticle cursor is set PROCESS-WIDE (_update_cursor, :1658) and combat has no
#    _exit_tree today — freeing a fight with a target card armed leaves the campaign wearing it.
func shutdown() -> void:
	combat_epoch += 1                                       # abort any in-flight _enemy_phase coroutine
	if Net.message_received.is_connected(_on_net_message): Net.message_received.disconnect(_on_net_message)
	if Net.realtime_joined.is_connected(_on_net_rejoined):  Net.realtime_joined.disconnect(_on_net_rejoined)
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)

func _exit_tree() -> void:
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)  # standalone/quick-match path too

# 3. _effective_crew() (:283-291) SILENTLY synthesizes a default 3-dwarf SOLO party when
#    crew.size() is outside [2,4] — the nastiest silent-desync generator in the codebase.
func _effective_crew() -> Array:
	var crew: Array = request.get("crew", [])
	if _embedded and crew.size() != _seat_count:
		push_error("embedded fight: crew %d != seat_count %d — REFUSING" % [crew.size(), _seat_count])
		return []
	if crew.size() >= 2 and crew.size() <= PARTY_MAX: return crew
	... (unchanged SOLO fallback)

# ...and the refusal must ACTUALLY bail (an empty party today divides by zero in _party_layout
#    and indexes party[-1] in _first_living_party):
func _start_combat() -> void:
	var crew_specs: Array = _effective_crew()
	if crew_specs.is_empty():
		push_error("combat: empty crew — refusing to start"); _log("Waiting for the host…"); return
	...
func _party_layout(n: int) -> Array:
	if n <= 0: return []                     # tolerate the refusal path

# 4. ABSENT SEATS. _all_alive_ended() (:485) gates ONLY on party[i]["alive"], so an AFK player
#    whose dwarf is alive holds the enemy phase hostage FOREVER, every tile. And a bare assignment
#    to _absent re-evaluates NOTHING — _all_alive_ended() is only ever called from
#    _authority_set_ready(), and nobody is left to press End Turn.
func set_absent(a: Array) -> void:
	_absent = a.duplicate()
	if mode != Mode.AUTHORITY: return
	for s in _absent: _ready_seats[int(s)] = true            # don't hold the START barrier shut either
	if not _barrier_open and _ready_seats.size() >= _seat_count - 1:
		_barrier_open = true; _refresh()
	if phase == "playerTurn" and _barrier_open: _maybe_close_player_phase()
	_net_board()

# _authority_set_ready()'s tail (:508-518, from `if not _all_alive_ended()` down) is EXTRACTED into
# _maybe_close_player_phase() so both a ready and an absence change can drive the fold.
func _all_alive_ended() -> bool:
	for i in range(party.size()):
		if party[i]["alive"] and not _absent.has(i) and not _seat_ended(i): return false
	return true
func _waiting_on() -> int:   # else the log says "waiting on 1 more" forever
	var n := 0
	for i in range(party.size()):
		if party[i]["alive"] and not _absent.has(i) and not _seat_ended(i): n += 1
	return n
# And self-heal on return: _on_action / _authority_set_ready / _authority_on_combat_ready each do
#   _absent.erase(seat)
# on any inbound traffic from that seat — otherwise a player who comes back keeps getting their
# turn auto-ended out from under them while they hold cards.
# In _start_combat(), after _seat_ready is sized:  for s in _absent: _ready_seats[int(s)] = true

# 5. _peer_owns_seat (:767) is literally `return true  # M4`. Any peer can play any seat's cards.
func _peer_owns_seat(pid: String, seat: int) -> bool:
	if _peers.is_empty(): return true        # harness / standalone quick-match bypass
	return int(_peers.get(pid, -1)) == seat

# 6. READY RETRY. _on_end_turn()'s CLIENT arm sends "ready" ONCE, no retry, no ack (survey §3).
#    In quick-match a dropped `ready` costs a re-tap. In the campaign it freezes the entire company
#    on a hex tile, and NONE of §2.5's escape hatches apply (the player is present; the Foreman's
#    Call closes campaign rings, not a stuck combat turn). _authority_set_ready is already
#    idempotent (:497-498), so a blind retry is safe.
_want_ready = true                                          # set in the CLIENT arm of _on_end_turn
# a 1.5s Timer while mode == CLIENT:
if _want_ready and not _seat_ended(my_seat) and phase == "playerTurn" and Net.is_online():
	Net.send_message("ready", {"seat": my_seat, "peer_id": Net.ensure_peer_id()})
# cleared when a snapshot brings back _seat_ready[my_seat] == true, or phase leaves playerTurn.

# 7. SUBMIT_ACTION RETRY. Same shape: re-send while the tapped uid is still in my hand_uids and the
#    phase is still playerTurn. _on_action's `_hand_index_of() < 0` check (:839-841) already makes a
#    duplicate a no-op, so this needs no new dedup.

# 8. NOTHING IS REMOVED. Every change above is inert when _embedded == false and mode == SOLO.
```

### 6.5 Coming out

* **HOST:** `await fight.combat_finished` → `run_epoch` check → the existing write-back into `exp_crew` (`d["hp"] = maxi(0, int(cr["hp_end"]))`, newly-`downed`, `HEX_POST_FIGHT_HEAL`) → `fight_block = {}` → `_teardown_fight()` → `_camp_push()` → `_resume_hex(e)`.
* **CLIENT:** never awaits, never writes back. The next snapshot carries `fight: {}` (→ `_teardown_fight()`) **and** the authoritative post-fight roster HP, atomically. There is exactly one source of truth for post-fight HP and it is `snap.roster`.

### 6.6 The load-bearing invariant

**`exp_crew[i]` is seat `i`'s dwarf, for the entire campaign. Always.** Never removed, never reordered, never filtered. `exp_crew` is *derived* from `seats[i]["dwarf_did"]`; a fallen seat holds the corpse at `hp = 0` (combat benches it: `"alive": hp > 0`, :338) until its heir arrives at the next tile.

```gdscript
func _check_seat_invariant() -> void:              # push_error + REPAIR, not assert (§9)
	if exp_crew.is_empty(): return
	if exp_crew.size() != seats.size():
		push_error("seat invariant: exp_crew %d != seats %d" % [exp_crew.size(), seats.size()])
		exp_crew = seats.map(func(s): return _dwarf_by_did(s["dwarf_did"]))
		return
	for i in exp_crew.size():
		if exp_crew[i]["did"] != seats[i]["dwarf_did"]:
			push_error("seat invariant broken at %d — repairing" % i)
			exp_crew[i] = _dwarf_by_did(seats[i]["dwarf_did"])
```
Called before **every** `_camp_flush()`. Violate it and players silently pilot each other's dwarves — and it will *look* fine.

---

## 7. RNG policy

**The host is the sole roller. There is no seeded RNG and no determinism requirement** — clients never re-derive anything. A `seed` key is deliberately **absent** from the snapshot.

Enforcement is a **runtime guard, not an assert** — `assert()` is stripped from release exports, i.e. from the only build anyone plays:

```gdscript
func _rf() -> float:             if mode == Mode.CLIENT: push_error("RNG on a client"); return 0.0
                                 return randf()
func _ri(n: int) -> int:         if mode == Mode.CLIENT: push_error("RNG on a client"); return 0
                                 return randi() % n
func _rr(a: int, b: int) -> int: if mode == Mode.CLIENT: push_error("RNG on a client"); return a
                                 return randi_range(a, b)
func _shuf(a: Array) -> void:    if mode == Mode.CLIENT: push_error("RNG on a client"); return
                                 a.shuffle()
```
A wrapper call does not perturb the RNG stream ⇒ **SOLO stays byte-identical.**

All 23 sites in `overworld.gd` (verified: 347, 348, 352, 354, 707, 864, 870, 872, 1064, 1181, 1189, 1208, 1220, 1437, 1489, 1490, 1511, 1644, 1653, 1674, 1749, 1752, 1753) move behind the wrappers:

| Line(s) | Function | Now |
|---|---|---|
| 347, 348, 352, 354 | `_regen_contracts`, `_make_contract` | `_rf()`, `_ri()` |
| 707 | `_roll_rewards` | `_shuf()` |
| 864, 870, 872 | `_resolve_dice` | `_rr()`, `_rf()` |
| 1181, 1189, 1208 | `_gen_hex_map`, `_content_bag` | `_shuf()`, `_ri()` |
| 1220 | `_roll_encounter` | `_ri()` — **shipped in `fight.req`, never re-rolled** |
| 1437, 1674 | `_roll_death_saves`, wipe loop | `_rf()` |
| 1489, 1490, 1511 | `_open_hex_reward`, `_roll_hex_loot` | `_rf()`, `_ri()`, `_shuf()` |
| 1644, 1653 | `_do_event` | `_rf()`, `_ri()` |
| 1749, 1752, 1753 | `_reroll_shop` | `_shuf()`, `_ri()` |
| NEW | heir name (class is chosen, §8) | `_ri()` |
| **1064** | **`_spawn_coins`** | **WHITELISTED — cosmetic confetti, stays raw, `# cosmetic-only: NOT authoritative`** |

*(The loot roll-off is gone — §2.7's tie-break is deterministic. There is no RNG on a persistent deck reward.)*

Combat's RNG (`deck.shuffle()` :331, `move_i` :372, `_draw_cards` :1210) is already authority-only *by mode* — and the campaign's `net` block is what finally **makes that true** for a campaign-nested fight, which today runs `Mode.SOLO` on every peer, i.e. three separate games.

---

## 8. Death, lockout, and party-size scaling

### 8.1 The rule: **a human is out of combat for AT MOST ONE fight, ever.**

**(a) The wagon rule + heir — reversible.**

```gdscript
func _reseat_fallen() -> void:                 # AUTHORITY/co-op only; SOLO returns immediately
	if mode == Mode.SOLO: return
	for s in range(seats.size()):
		var d: Dictionary = _dwarf_by_did(seats[s]["dwarf_did"])
		if not (bool(d["downed"]) or bool(d["stable"]) or d["status"] == "lost"): continue
		if _is_heir(d): continue                                   # idempotent — a retry cannot double-pop
		if not carried.has(d["did"]): carried.append(d["did"])     # KEEPS rolling death saves
		var h: Dictionary = _pop_reserve(seats[s].get("heir_cls", d["cls"]))   # a shop Recruit, else…
		if h.is_empty():
			h = _make_dwarf(RECRUIT_NAMES[_ri(RECRUIT_NAMES.size())],
			                str(seats[s].get("heir_cls", d["cls"])))  # default: the fallen dwarf's OWN class
			roster.append(h)                                       # free — a co-op company never disbands
		h["hp"] = maxi(1, int(float(h["max_hp"]) * HEIR_HP_FRAC))  # HEIR_HP_FRAC := 0.5
		seats[s]["dwarf_did"] = h["did"]
		exp_crew[s] = h                                            # SAME INDEX — seat<->party contract held
		_msg("%s takes up the fallen one's axe." % h["name"])
```
**Called from THREE hooks, not one** — the draft's single `_resume_hex` hook left a player benched for a whole fight whenever a dwarf fell on an objective/extract tile or on the Low dice contract:
1. `_resume_hex(e)` — **after** the existing `if _living_up().is_empty(): _finish_expedition("wipe")` check (a total wipe still ends the run).
2. `_open_expedition()` — after `exp_crew` is derived from `seats`, before the first push. A corpse must never ride into the next expedition's first fight.
3. `_outcome_beats()` — immediately after pending statuses are applied (the dice-contract death path).

**Death saves keep running on `carried`** (`_roll_death_saves()` iterates `exp_crew + carried`), so your old dwarf can bleed out — or stabilise — while you are already back in the fight.

**Stabilising must be strictly better than dying.** At `_finish_expedition`, **before** the per-expedition flag reset:
```gdscript
for s in range(seats.size()):
	var orig: Dictionary = _carried_original_for_seat(s)
	if orig.is_empty() or orig["status"] == "lost": continue
	reserve.append(seats[s]["dwarf_did"])            # the heir goes to the bench, not the bin
	seats[s]["dwarf_did"] = orig["did"]              # you get your dwarf — and your DECK — back
	_msg("%s is patched up and back on the roster." % orig["name"])
carried.clear()
```
`_finish_expedition` must iterate **`exp_crew + carried`** in **both** its wipe loop (:1670) and its pending/flag-reset loop (:1683-1700). A carried dwarf that neither died nor stabilised would otherwise exit with `downed = true` / `ds_fail = 2` still set, never reach `outcome.pending`, and never be reset — a permanent roster ghost that starts pre-downed on its next appearance.

**The punishment is the DECK, not the seat — and only on an actual death.** A dead dwarf's heir keeps the seat permanently and carries the class starter deck. Every card that dwarf earned is gone. That fits the game's thesis and feeds the economy instead of a spectator screen.

⇒ `_game_over("disbanded")` is **unreachable in co-op**. Gate it `if mode == Mode.SOLO`. Co-op has two terminal states: `bankrupt`, `victory`.

**(b) The heir's class is CHOSEN, never rolled.** `seats[s]["heir_cls"]` is set by a `heir` CLAIM (⚱️ button on the crew bar, instant, owner-gated, free — `_intent("heir", "cleric")`). It defaults to the **fallen dwarf's own class**, so a player who is looking away is never handed a random Sorcerer and is never benched for failing to press a button. `_call_heir` is not a separate mechanism — the auto-reseat is the mechanism; the button only picks the class.

**(c) The `wounded` lockout — killed in co-op.** `status = "wounded"` benches a dwarf for `WOUND_RECOVERY = 2` **months** = up to 6 campaigns = a human locked out for the rest of the session (reachable via the Low dice contract's `WOUND_CHANCE`). In co-op, `wounded` maps to **low HP + `HP_REGEN_PER_MONTH := 6`**, never to a benched status. Gated `mode != Mode.SOLO`.

**(d) The 2-player campaign has NO FIGHTS.** `if USE_REAL_COMBAT and _ready_count() >= 3:` (:343) is what promotes med/high contracts to real expeditions. With 2 seats: zero expeditions, Low-grind into bankruptcy. Also re-broken at N=4 after one death if the roster gate isn't seat-relative:
```gdscript
func _crew_size() -> int: return 3 if mode == Mode.SOLO else seats.size()
# :343 ->  if USE_REAL_COMBAT and _ready_count() >= _crew_size():
```
(With the wagon rule, `_ready_count()` never drops below `seats.size()` — heirs are always `ready`.)

### 8.2 Party-size scaling — ONE formula, one home

Enemies stay a **hard 3-slot line**. Party size is expressed **purely through `enemy_scale`**, as one more **ADDITIVE** term (the 2026-07-01 audit proved multiplicative composition grows ~quadratically into 0 %-win cells).

Ship it as a **static on `card_db.gd`** so `overworld._hex_combat` (:1459), `overworld._embark_fight` (:823), `lobby.gd` (which today hardcodes a **second, divergent** formula `0.8 + 0.3*seats.size()` at :146) and `scratchpad/dorf_sim.py` all consume ONE function:

```gdscript
# card_db.gd
const PARTY_STEP          := 0.34    # per living dwarf above/below 3
const COMP_ADJ_NO_CLERIC  := -0.12   # a healerless lobby MUST be winnable (settled)
const COMP_ADJ_NO_WARRIOR := -0.06   # no tank -> no Taunt redirect
const PARTY_SCALE_MIN     := 0.55
const ENEMY_SCALE_MAX     := 2.60    # clamp the whole additive stack (3-dwarf worst reachable was 2.12)

# TOLERANT of BOTH shapes: roster dicts {cls,name,status,hp,...} AND lobby dorfs {cls,name} only.
# lobby.gd's _gen_roster() mints {cls,name} — a d["status"]/d["hp"] KeyError here crashes the
# ALREADY-SHIPPED quick-match Start button.
static func party_scale(crew: Array, absent: Array = []) -> float:
	var live := 0; var cleric := false; var warrior := false
	for i in range(crew.size()):
		var d: Dictionary = crew[i]
		if absent.has(i): continue                                         # AFK dwarves are not combatants
		if str(d.get("status", "ready")) == "lost": continue
		if int(d.get("hp", int(CLASSES[d["cls"]]["max_hp"]))) <= 0: continue   # ghost/benched: rides, cannot act
		live += 1
		if d["cls"] == "cleric":  cleric = true
		if d["cls"] == "warrior": warrior = true
	var s: float = 1.0 + PARTY_STEP * float(live - 3)
	if not cleric:  s += COMP_ADJ_NO_CLERIC
	if not warrior: s += COMP_ADJ_NO_WARRIOR
	return maxf(s, PARTY_SCALE_MIN)
```
Call site (both), gated so SOLO is a **literal float no-op**:
```gdscript
var pscale: float = 1.0 if mode == Mode.SOLO else Db.party_scale(exp_crew, _absent_seats())
req["enemy_scale"] = clampf(1.0 + (comp.scale-1.0) + (mscale-1.0) + (_danger_scale(danger)-1.0)
	+ (pscale-1.0), Db.PARTY_SCALE_MIN, Db.ENEMY_SCALE_MAX)
```
Both call sites pass **`exp_crew` (roster dicts)**, never `_build_crew_specs(...)` output (which has no `status`).

Works with the existing damping: HP scales at full `escale`, damage/block at `dscale = 1 + (escale-1)*ATK_SCALE_K(0.65)`. 4 players → 1.34 escale → 134 % HP but only 122 % damage. Sub-linear lethality; friends should win a bit more easily than a solo player. `RAGE_CAP := 8` still caps Howl. A dead seat's ghost (`hp == 0`) and an AFK seat both refund the scale automatically — the scaling rule, the death rule and the absence rule are one mechanism.

**The numbers are a first guess and MUST be simmed** before playtest: re-run `dorf_sim.py` over N ∈ {2,3,4} × comp × danger{1,2,3} × mod{none,elite,lucrative,grim}. **Gate: every reachable cell ≥ 2 % win.** Trust the 0 %-win cells; the bot policy is near-optimal, so its 100 % reads are a bot ceiling. Lever order: `PARTY_STEP` → `ATK_SCALE_K` → `COMP_ADJ_*`.

---

## 9. Solo safety

**Bar: byte-identical.** Verified by instrumentation, not by hope.

```gdscript
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Consume-and-clear: a later SOLO run must not inherit a stale co-op handoff.
	if request.is_empty() and not Net.campaign_request.is_empty():
		request = Net.campaign_request
		Net.campaign_request = {}
	var net: Dictionary = request.get("net", {})
	var m: String = str(net.get("mode", ""))
	mode = Mode.AUTHORITY if m == "authority" else (Mode.CLIENT if m == "client" else Mode.SOLO)
	my_seat = int(net.get("seat", 0))
	if mode != Mode.SOLO:
		Net.ensure_peer_id()
		Net.message_received.connect(_on_camp_msg)
		Net.realtime_joined.connect(_on_camp_rejoined)
		_start_pulse(); _start_keepalive(); _start_flush_timer()
	_build_chrome()
	if mode != Mode.CLIENT: _new_run()          # SOLO + HOST identical; CLIENT waits for snapshot 0

func _on_camp_rejoined() -> void:
	if mode == Mode.AUTHORITY:
		_online_since_ms = Time.get_ticks_msec()     # absence grace window (§2.5)
		_camp_push()
	elif mode == Mode.CLIENT:
		_camp_hello()
		if not _pending_intent.is_empty(): Net.send_message("camp_intent", _pending_intent)
```
Anything not exactly `"authority"`/`"client"` → SOLO. The **only** Net touch in SOLO is a property read of `Net.campaign_request` on an always-present, inert autoload (`Net` does not dial in `_ready`) — precisely what `combat.gd:103-105` already does. **Zero signal connections, zero socket, zero timers.**

| # | Thing | SOLO |
|---|---|---|
| 1 | `_camp_push/_camp_flush/_request_camp_resync/_pulse/_keepalive` | `if mode != Mode.AUTHORITY: return` |
| 2 | The ring | `_intent()` → `Mode.SOLO: _resolve_decision(...)` **immediately**. Existing **two-tap** contract flow (`select` then `embark`), one-tap hex, one-tap event, **two-tap** shop buy — all unchanged, zero extra taps |
| 3 | CLAIM kinds (`loot_claim`/`basket`/`heir`/`reclaim_accept`) | never reached — the SOLO two-tap loot/spoils/shop pickers keep their verbatim bodies (§3.3) |
| 4 | `Db.party_scale` | `pscale = 1.0` → the arithmetic gains `(1.0-1.0)`; `clampf(x,0.55,2.60)` is a no-op on every scale SOLO can reach (max 2.12) |
| 5 | Wagon rule / heir / `carried` / `reserve` | `_reseat_fallen()` returns immediately in SOLO |
| 6 | `wounded` → HP regen | co-op-only branch |
| 7 | Crew select (`crew_pick`, `_open_crew_select`, `_launch_fight`, `state=="CREW"`) | SOLO-only, untouched |
| 8 | `_ready_count() >= _crew_size()` | `_crew_size()` returns **3** in SOLO — identical |
| 9 | Shop Recruit / stock size | SOLO: 3 slots, `roster.append(...)` as today. Co-op: `maxi(3, seats.size())` slots; Recruit → **Reserve bench** (heir insurance priced against rent) |
| 10 | `_game_over("disbanded")` | SOLO-only |
| 11 | Nested combat `request` | SOLO sets no `net` key → the child lands on `Mode.SOLO`, `_embedded == false` — the path that ships today |
| 12 | RNG wrappers | `mode != CLIENT` → straight through; **stream unperturbed** |
| 13 | Crew bar | co-op chrome in `hud`, gated `mode != SOLO` — never enters `screen_root` |
| 14 | `_build_rolling()` | `mode == CLIENT` only — SOLO keeps its dice cinematic |

**Additive changes that DO touch the SOLO path (the entire blast radius):**
* `_make_dwarf()` gains `did`, `loot_wins`, `last_loot_tile` (three unread keys in SOLO).
* Handler/body splits (§3.3) — the shim keeps the guards, the body keeps the behaviour.
* `_goto()` replaces the *builder tail* of ~10 sites (§5.5).
* `outcome_view.ready` replaces the hardcoded `continue_btn.disabled = true` (§5.6) — identical timing on all three paths.
* **`_build_dashboard` pre-existing crash fix:** `var cx := [96, 272, 448, 624]` indexed by `roster.size()` (:409-411) — `_buy_recruit` already appends a 5th dwarf → `cx[4]` out of range. Compute the row from `roster.size()` the way `_build_crew_select` does (`startx = 360 - (n-1)*90`), wrapping past 6. **Land this in C0** or the §9 baseline capture cannot be taken.

**The regression gate (runs at EVERY checkpoint, not once):**
1. `play_scene` the SOLO `/overworld/`; drive a **fixed** tap sequence with `simulate_mouse_click` under a fixed `seed()`; `execute_game_script`-dump `{treasury, fee, month, campaigns_left, roster[*].{hp,status,deck.size()}, hexes, shop_stock, pending_spoils}` at each beat through month 3, **including one Recruit purchase and one spoils pick**. Diff cell-for-cell against the pre-change baseline.
2. Dump `req.enemy_scale` at **both** `_hex_combat` and `_embark_fight` across danger{1,2,3} × mod{none,elite,lucrative,grim} and assert **exact float equality** with baseline.
3. Re-run `dorf_sim.py` at N=3; the win-rate grid must be **cell-for-cell unchanged**.
4. Standalone `/` combat (SOLO, `request.is_empty()`) still shows the Play-Again overlay — proves `_embedded` didn't leak.

---

## 10. Build plan

Every checkpoint is independently verifiable, leaves SOLO working, and is gated in `scenes/test/coop_harness.tscn` (both peers, one process, one `Net` autoload, `self_echo = true`). **Chrome cannot run two tabs** — the harness is the only automated verification path, which is why presence is keyed by SEAT and `_peer_owns_seat` has a harness bypass. **Two production-only bugs (self-pulse, peer→seat) are structurally invisible to the harness**, so C7 additionally requires one manual 2-browser-machine smoke run with `self_echo = false`.

---

**C0 — Foundations (no net code).**
(a) `_make_dwarf()` gains `did`/`loot_wins`/`last_loot_tile`; `_next_did()`. Every `.bind(d)` at :766/:1569/:1854 → `.bind(d["did"])` + a did→dict resolve. Handler/body splits (§3.3). `_goto()` (builders only, §5.5). `outcome_view.ready` (§5.6). RNG `push_error` wrappers at all 23 sites (whitelist `_spawn_coins`). `Db.party_scale()` static (tolerant of both dict shapes); `lobby.gd:146` re-pointed at it. `_crew_size()` + the `>= _crew_size()` fight gate. `_build_dashboard` roster-row fix. `busy = false` at the top of `_open_hex_reward`/`_open_hex_event`/`_open_spoils`.
(b) **Gate:** the §9 SOLO regression suite (all 4) green. `grep -n 'rand\|shuffle' scripts/overworld/overworld.gd` shows **only** the wrappers + `_spawn_coins`. `grep -n '\.bind(d)'` returns nothing. Quick-match Start Fight (lobby → `Db.party_scale`) still works.

---

**C1 — `combat.gd` embedding (8 changes, §6.4).**
(a) `_embedded`/`_absent`/`_peers` parse; gate `_on_match_finished_local` + the CLIENT `match_over` arm + `_to_lobby()` itself; `shutdown()` + `_exit_tree()`; `_effective_crew()` refusal + `_start_combat` bail + `_party_layout(0)`; `set_absent()` + `_maybe_close_player_phase()` + absent-aware `_all_alive_ended`/`_waiting_on` + `_absent.erase(seat)` on inbound traffic; real `_peer_owns_seat`; `ready` + `submit_action` retries.
(b) **Gate:** harness — the **existing** 2-peer quick-match runs end-to-end exactly as today (both peers land in the lobby at match end). Then hand-spawn an embedded fight under a bare `Control` (`net.embedded = true`, `net.peers = {}`): at match end **neither peer changes scene** and the parent survives. Free the fight with a target card armed → the reticle is gone. Free and immediately respawn a fight → the dead child sends **no** `apply_snapshot` (assert `Net.message_received` connection count). Spawn with `crew.size() != seat_count` → `push_error`, no party, no crash. Drop a client's `ready` (net.gd debug flag) → the retry lands and the enemy phase runs. SOLO `/` combat still shows Play-Again.

---

**C2 — Snapshot skeleton, no decisions.** *(Host talks, client renders.)*
(a) `enum Mode` + the `_ready()` parse (§9). `Net.campaign_request`. `_on_camp_msg` (mode-branched). `_build_camp_snapshot` / `_camp_push` / `_camp_flush` (trailing-edge) / `_last_snap` / `_apply_camp_snapshot` / `_ingest` / `_coerce_ints` (recursive, both allowlists) / `_goto` from snapshot. `run_id` + `cseq` guards. `camp_hello` + the `_hello_ack_target` retry. `camp_resync` (host answers with `_last_snap`) + the 8 s client watchdog. `KEEPALIVE_SEC 5.0` verbatim re-send. `camp_pulse` by seat + `_sweep_absence` (self-pulse, offline freeze, grace). Persist `Net.my_peer_id` → `user://peer.cfg`. No `camp_intent` yet — the client is read-only, buttons disabled.
(b) **Gate:** harness, host + 1 client. Host drives a full month solo-style (embark Low → dice → outcome → continue → end month). Dump `{run_id, treasury, fee, month, roster[*].{did,hp,status,deck.size()}, hexes.size(), state, busy}` on **both** after each beat → identical, **and `busy == false` on the client at every rest point** (proves the trailing-edge flush). Then: (i) suppress the client's handler for 3 pushes → it fires `camp_resync` and re-converges; (ii) free and re-add the client mid-month → `camp_hello` → converged within one keepalive; (iii) assert `typeof(hexes["3,2"].danger) == TYPE_INT`, `typeof(run_epoch) == TYPE_INT`, `typeof(contracts[0].mod.scale) == TYPE_FLOAT`; (iv) restart the host scene mid-campaign (`run_id` changes) → the client resets and re-converges instead of dropping every snapshot forever.

---

**C3 — Intents + the ring.**
(a) `_intent()` funnel (host taps go through `_authority_intent`). `camp_intent` with `nonce` + **`iseq`** + `_seat_last_iseq`; **total** validator (every path acks or rejects); rolling `acks`/`rejects` windows; offline-aware retry + rejoin re-fire. `pending`, `pid` CAS, propose=aye, same-arg=aye, diff-arg=new-pid, `hold`, `cancel`. One-directional `required` (prune on departure). Crew bar in `hud`; proposal banner; `hex_tile.gd` `propose_col`. Foreman's Call; `RING_AUTO_SEC`/`RING_LAST_SEC` with the `ayes >= 2` guard. `nav` rejected while a ring is open, 1.0 s per-seat debounce, clears `pending` if it changes `state`. `_state_ok_for(kind)` re-checked at **close** time. Kinds: `select`, `embark`, `hex`, `extract`, `event`, `continue`, `endmonth`, `nav`, `hold`, `cancel`, `foreman`, `restart`.
(b) **Gate:** harness, host + 2 clients. (i) Client A proposes `hex "3,2"`; others show ⏳; host + B aye → tile resolves; all three dump identical `hex_cur`/`hexes`/`treasury`. (ii) A proposes `"3,2"`, B proposes `"2,3"` → pid bumps, `ayes == [B]`, A's pip clears. (iii) **Retry storm:** drop 50 % of `camp_intent` deliveries for 10 s of tapping → the ring converges and **no vote is ever wiped**; no decision executes twice (assert `month`/`campaigns_left` monotonic). (iv) **Lost closing-ack:** drop the snapshot carrying B's closing aye → B's retry is `iseq`-deduped, re-acked, and **does not re-open a ghost ring**. (v) Stop seat 2's pulse **while a ring is open** → `required` prunes to 2 and the ring closes immediately. (vi) Host `self_echo` bounce: the host's own `camp_intent` echo does not double-apply. (vii) `nav` during an open ring → rejected, nonce in `rejects`, pip cleared, local warning logged. (viii) 2-aye-of-3 + 20 s → Foreman's Call appears (host only); press → closes.

---

**C4 — Fight in the snapshot.**
(a) `fight_block`, `_sync_fight()` (validate-before-latch), `_await_fight()` (host only), `_teardown_fight()` (synchronous `shutdown()`), `_sync_absent()` above the fid early-return + on the host's absence sweep. `_check_seat_invariant()` before every flush.
(b) **Gate:** harness, 3 seats, a hex combat tile. (i) All three spawn `combat.tscn`; dump `request.enemies` + `request.enemy_scale` → **byte-identical**; each peer's child `my_seat` == its campaign seat. (ii) Fight to a win; **only the host** resolves `combat_finished`; all three tear down on the `fight: {}` snapshot; identical post-fight `roster[*].hp`. (iii) **Mid-fight reconnect:** free a client's whole overworld node and re-add it mid-fight → snapshot with a live `fight` block → spawns a CLIENT combat → runs combat's `combat_ready` barrier → board restored. (iv) **Drop `match_over`** to one client → torn down by the next `fight: {}` snapshot (≤ 5 s via keepalive). (v) Stop seat 2's pulse mid-fight → `set_absent` lands **on the host's own child** → the enemy phase advances without it, **and this must be verified with the host's Net handler for its own events disabled** (simulating `self_echo = false`). (vi) Seat 2 returns mid-fight → `_absent.erase` → its turn is no longer auto-ended.

---

**C5 — Claims: loot + shop basket + heir + reclaim.**
(a) `claim` dict, one-tap loot claim (co-op only), absent-only auto-pass, deterministic `(loot_wins, last_loot_tile, seat)` tie-break, consolation gold. `shop_basket`, `maxi(3, seats.size())` stock, live projected treasury (red below the rent line), FREE checkout above the line / RING below it (no Foreman's Call; auto-expiry **clears the basket**). Reserve bench for Recruit. `heir` class claim (⚱️). `camp_hello {seat:-1}` → reclaim panel → `reclaim_accept`.
(b) **Gate:** (i) 3 seats all claim card 0 → exactly one card leaves; over 4 reward tiles the ledger spreads (no dwarf ≥ 3 while another is 0); losers get gold. (ii) Duplicate a `loot_claim` 5× → `picks[seat]` unchanged. (iii) A present seat that never picks is **not** auto-passed; the host's 🔨 passes it. (iv) Two seats basket the same slot → the second is `reject`-acked and its pip clears with a local warning. (v) Basket below the rent line → HUD red, Foreman disabled, unanimity required; let it auto-expire → basket cleared, no deadlock, treasury untouched. (vi) Kill a client → 💀 pip, still in `required`, still votes; ⚱️ picks a class; heir appears at the **same seat index**; `_check_seat_invariant()` clean. (vii) Kill a client's `peer_id` (new one) → reclaim panel → host accepts → the player is back on their dwarf.

---

**C6 — Wagon rule, wounds, scaling.**
(a) `_reseat_fallen()` at all three hooks; `carried` rolling death saves; **restore-on-stabilise** at `_finish_expedition` (+ `carried` folded into both of its loops); `wounded` → HP regen in co-op; `_game_over("disbanded")` SOLO-gated; `party_scale` (absent-aware) wired into both `enemy_scale` sites.
(b) **Gate:** (i) Down seat 1 on tile 2 → it pilots an heir on tile 3; the old dwarf is in `carried` and its `ds_*` still tick; force 3 failures → it dies, the heir keeps the seat, the deck is gone; force 3 successes → at expedition end **the original is restored to its seat with its deck**, the heir goes to `reserve`. (ii) A dwarf dies on the objective tile → the next expedition starts with an heir, **not** a corpse (assert `exp_crew[i].hp > 0` at `_open_expedition`). (iii) `Db.party_scale()` returns exactly `1.0` for a 3-dwarf W/C/S crew, and a 3-seat co-op `enemy_scale` **equals** the SOLO baseline float for the same (tier, mod, danger). (iv) An absent seat lowers `live` → the fight is scaled for the players actually playing. (v) `dorf_sim.py` at N ∈ {2,3,4}: every reachable cell ≥ 2 % win.

---

**C7 — Lobby + ship.**
(a) `camp_start` (barriered, re-broadcast until every seat has hello'd; the lobby scene survives until its own `camp_start` lands) + a "Start Campaign" button in `lobby.gd`. Host autosave: `JSON.stringify(_last_snap)` → `user://camp.save` on every ring close (free — the snapshot is already a JSON-safe blob; the resume path re-mints `run_id`). Persistent host banner: `"⚠ you're hosting — keep this tab in front."` Run `scripts/check_web_glyphs.py` over every new glyph (`✋ ⏳ 💤 ⚑ 🔨 ⚱️ 🔁 🎲`) **before** landing — `deploy-pages.yml:32` **fails the build** on an uncovered glyph.
(b) **Gate:** glyph checker green. Export both presets. Full 3-seat harness campaign, month 1 → bankruptcy or month 8, with one mid-campaign client reconnect and one mid-fight reconnect. **One manual 2-machine production run with `self_echo = false`** — the only way to catch the self-pulse / peer→seat class of bug. SOLO regression suite (§9) green one last time.

---

## 11. Known risks / deferred

1. **Backgrounded host — the #1 unfixed risk, ~10× worse than in combat.** Chrome stops ticking a background tab; the sole authority stops resolving and the whole company freezes — 20–60 minutes of shared progress, not one fight. `Net`'s 2 s re-dial papers over the socket; nothing repairs a frozen resolver. Mitigations: the host banner, the absence-sweep offline freeze (so a host blip does not absent the table), and `user://camp.save`. **Authority migration is out of scope**, as it was for combat.
2. **`PARTY_STEP 0.34` / `COMP_ADJ_*` are unvalidated first guesses.** C6's sim gate is a hard stop; do not playtest before it passes.
3. **Full screen rebuild on every snapshot** = flicker + lost hover on clients (~40 Controls). Tolerable because pushes are state-change-driven and coalesced at 10 Hz. **Deferred fix (the right architecture):** split `_goto()` into `_rebuild_screen()` (on `state` change only) + `_refresh_screen()` (in-place projection of HUD, pips, buttons, 🚩, HP bars, `sold` tags) — the `_rebuild_hand()`/`_refresh()` split combat already has.
4. **Shared `state` = screen thrash.** Two players navigating at once flicker each other's screens. The 1.0 s per-seat debounce + the ring-freezes-nav rule + a named log line make it a *social* problem, deliberately. Host-only navigation would make three players spectators.
5. **The RESOLVE dice cinematic** draws into `screen_root` from locals; clients see a static `_build_rolling()` card. Accepted (Low is a ~3 s lifeline). Upgrade path: a `resolve: {roll, strength, beat}` snapshot key — 6 lines, no protocol change.
6. **Mid-campaign join by a *stranger* is still refused** — only a seat that is **absent** can be reclaimed (§2.6), and only with the host's consent. A 5th player cannot join a running company.
7. **Snapshot size** grows with the roster (~5–8 KB → ~15 KB late). Well inside Supabase's caps. **Delta snapshots are explicitly out** — the same call combat made.
8. **Hidden information is soft.** Everything is on the wire; hands are public by design. No per-seat channel.
9. **`combat.gd:_impact()`** (:1697) assigns a **global** position to a **local** `fx.position`. Latent today (the combat child sits at origin under the overworld). Not fixed here; it will misplace hit VFX if the campaign ever offsets or scales the child.
10. **Not doing:** delta replication · seeded RNG · authority migration · host reconnect as authority · accounts/persistence beyond the local autosave · a per-seat private channel · variable enemy counts (the 3-slot line is hard; party size is expressed only through `enemy_scale`) · a per-player turn timer · in-fight revive (see appendix).

---

## Appendix — Rejected findings

* **In-fight revive (R4-S1.3: let `heal_ally` target a downed ally and un-bench them).** *Deferred, not adopted.* It is a genuine combat-rules change (relaxes `_valid_target` :866, changes `alive` semantics, and invalidates every `dorf_sim.py` win-rate cell). The lockout it targets is already closed by the reversible wagon rule (§8.1), which costs nothing in balance. Revisit as a combat balance milestone with its own sim pass.
* **Shop `shop_wins` roll-off ledger (R4-S7b).** Rejected in favour of R4-S7a: `_reroll_shop` emits `maxi(3, seats.size())` slots, so slot contention is structurally impossible and needs no arbitration at all.
* **Keeping `camp_absent` as a wire event, even "for clients only" (R1-D1).** Rejected outright (R3-#6 is right): the fight's absent set is *already* in the snapshot, so a second channel for the same value adds an unretried, un-sequenced message and a second code path with no benefit. Absence is a direct `set_absent()` property call into the child on every peer.
* **"Drop the intent retry cap entirely" (R3-#1).** Rejected as stated. Retries are bounded by the **life of the target ring/claim** and by `INTENT_GIVEUP_SEC` (offline-excluded), not by a try count — an unbounded retry against a permanently unreachable host would spin forever and never surface an error to the player. The `iseq` table makes retries *safe*; it does not make them *free*.
* **"Only reseat on `lost` or `stable`, never on plain `downed`" (R4-S1.1).** Rejected: reseat-on-`downed` **is** the anti-lockout mechanism — a downed dwarf otherwise rides every remaining tile benched at 0 HP. What was wrong was the *irreversibility*, which §8.1's restore-on-stabilise fixes. Reseat is now reversible, so it can safely fire on `downed`.
* **The draft's own `assert()`-based RNG/seat enforcement (§7, §6.5) and the draft's `RING_AUTO_SEC := 75.0`, `LOOT_AUTO_SEC` for present seats, `_ri()` loot roll-off, `camp_absent`, first-intent-wins shop, unanimous `continue`/`restart`, and the no-escape below-rent `shop_checkout`.** All superseded above; listed here so nobody re-derives them from the draft.
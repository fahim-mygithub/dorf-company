---
title: Multiplayer Co-op — Design Doc (final)
date: 2026-07-10
status: proposed
summary: Turn the single-player Slice-2 combat into a lobby-based 2–4 player host-authoritative co-op "quick match" over Supabase Realtime Broadcast, with an explicit combat-start barrier, absolute-state snapshots, merge-apply, hidden hands, and a loss-recovery/resync layer — the overworld stays single-player.
---

# Multiplayer Co-op — Design Doc

> **Scope owner:** combat only ("quick match"). The overworld/expedition stays single-player.
>
> **Line anchors** were re-verified against the live files this session
> (`scripts/combat/combat.gd`, `scripts/combat/card_db.gd`, `scripts/overworld/overworld.gd`,
> `.github/workflows/deploy-pages.yml`, `project.godot`). Code shifts — re-verify before you cut
> against a seam.

---

## 1. Summary & scope

Turn the existing single-player Slice-2 combat (`scenes/combat/combat.tscn` + `scripts/combat/combat.gd`)
into a **lobby-based 2–4 player co-op quick match**: players gather in a lobby, each brings one dwarf,
they fight **one shared combat** against **one fixed line of 3 enemies**, they win or lose, they drop
back to the lobby. Nothing persists.

- **Transport:** Supabase Realtime Broadcast, spoken by Godot's native `WebSocketPeer` over the
  Phoenix protocol. Supabase runs **zero game logic** — it is a dumb pub/sub relay (§2).
- **Authority:** host-authoritative. The room creator's browser runs the sim as a *logical* authority
  and is the **sole roller** of RNG. Clients send intents and render host-confirmed snapshots; they
  never mutate game state.
- **Turn model:** StS-style **live, serialized, atomic per-card** loop reusing the existing
  `_resolve`/`_attack` pipeline (combat.gd:658/:761). The authority serializes its own local taps and
  all inbound client actions in one thread; that single serializer *is* canonical order (§5.5).
- **Delivery reality:** Broadcast is **fire-and-forget** with **no cross-sender ordering** and **no
  replay**. The design is built around that: absolute-state snapshots + a monotonic `seq` + a
  gap-detect **resync** watchdog + a combat-start barrier (§4.7, §5, §9). We do **not** assume any
  message arrives.

**SOLO is behavior-equivalent, not literally byte-identical.** §7a/§7b touch *shared* code (layout,
uid-based arming, reconciling `_rebuild_hand`) that the single-player path also runs, so SOLO changes
form even where it must not change behavior. The bar is: **same resulting state and same on-screen
result, verified by playtest + screenshot diff** (§10.3, M0), not "the bytes of the code path are
untouched."

**In scope**
- Main-menu → lobby → single combat → back to lobby.
- 2–4 seats, one dwarf per seat, personal roster of 4 fully-random dwarves per player (duplicates
  allowed, no guaranteed class coverage).
- Host-authoritative sim; clients send intents, render host-confirmed snapshots.
- Hidden hands (shared board broadcast; each player sees only their own hand).
- Enemy scaling keyed to **party size AND composition** against a **fixed 3-enemy line** (a healerless
  lobby must be beatable).
- New files: `scripts/net/net.gd` (autoload `Net`), `scripts/net/net_config.gd`,
  `scenes/menu/main_menu.tscn`, `scenes/menu/lobby.tscn`; `combat.gd` gains SOLO / AUTHORITY / CLIENT
  modes.

**Out of scope (explicit)**
- Overworld / expedition co-op — stays single-player.
- Persistence of any kind (no accounts, no saved rosters, no meta-progression). A run is disposable.
- Matchmaking / room discovery — room codes shared out-of-band (friends-only).
- Cryptographic hidden-hand secrecy, anti-cheat, private channels + RLS (deferred; see §4, §12).
- Spectators, >4 players, cross-region latency mitigation, rollback netcode.
- **A variable enemy count (M≠3).** The first cut fields a fixed 3-enemy line and scales via
  `enemy_scale` only. M≠3 is a later milestone (§8.3) — it needs new authored comp data **and**
  board-layout work that don't exist today.
- A second export preset or a new CI export step (see §10 — deliberately avoided).

---

## 2. The hard constraint (state it once, for future readers)

GitHub Pages serves **static files only**. A browser cannot open a listening socket; it can only make
*outbound* connections. Therefore no player's browser can be a server the others dial into. "Host" in
this doc never means a listening socket — it means a **logical authority**: one player's browser is
anointed as the single writer of game state, and it reaches the others the only way a browser can, by
connecting *outward* to a shared broker.

That broker is the unavoidable third machine. We do not want to operate a server, so we rent Supabase
Realtime's free tier as a **dumb pub/sub relay**: it fans broadcast messages out to every subscriber
of a channel and runs **zero game logic**. All authority, validation, and enemy AI live in the host's
browser. Supabase is a mailbox, not a referee — and a mailbox that can silently drop a letter (§9).

Consequence: the host is a normal client that happens to hold the authoritative `combat.gd` state. If
the host's tab dies, the room dies (§9). We accept that because a run is disposable.

---

## 3. Architecture overview

### 3.1 Machines & data flow

```
                         +-------------------------------+
                         |      Supabase Realtime         |   the unavoidable 3rd machine
                         |  wss://<ref>.supabase.co/...   |   pub/sub broadcast fan-out ONLY
                         |  topic = realtime:room:<CODE>  |   no game logic; may DROP messages
                         +------^-----------------^-------+
                                |  Phoenix WS      |
             submit_action /    |  (vsn=2.0.0,     |    apply_snapshot / hand / enemy_phase /
             resync / lobby_* ──+  ARRAY frames)   +─── match_over / lobby_*   (self:false)
                                |                  |
        +-----------------------+----+     +-------+------------------------------+
        |  Browser A  (HOST)         |     |  Browser B..D  (CLIENTS)             |
        |  static bundle from Pages  |     |  static bundle from Pages           |
        |  +----------------------+  |     |  +----------------------+           |
        |  | Net (autoload)       |  |     |  | Net (autoload)       |           |
        |  +----------------------+  |     |  +----------------------+           |
        |  combat.tscn AUTHORITY     |     |  combat.tscn CLIENT                 |
        |   - owns sim + AI + RNG     |     |   - sends intents                  |
        |   - _resolve/_attack (truth)|    |   - MERGES snapshots (_refresh)     |
        |   - broadcasts snapshots    |     |   - NEVER mutates game state        |
        +----------------------------+     +-------------------------------------+
```

**How the host applies its *own* plays (settled — resolves review blocker).** The host does **not**
round-trip its own taps and does **not** loop them back through Supabase. On its own tap the AUTHORITY
calls the local resolver (`_resolve`/`_attack`) directly, mutates the authoritative state in place,
`_refresh()`es locally, and *then* broadcasts the resulting snapshot to the others. Broadcast is
configured **`self:false`** (§4.3): the host never receives its own messages back. The shared code
between host and clients is the **resolver** (`_resolve`/`_run_ops`/`_attack`), *not* the apply-snapshot
path. This is the one model; there is no "host waits for its own loopback." (A `self:true` loopback
would let a late echo of an earlier play overwrite a newer one the host already resolved — a real
rollback. We forbid it.)

### 3.2 Scene flow

```
main_menu.tscn ──Solo──────────────► combat.tscn (mode=SOLO, request={})   [today's game]
      |
      ├──Host──► lobby.tscn (create room, share code) ─┐
      |                                                ├─ host Start ─► combat.tscn
      └──Join──► lobby.tscn (enter code) ──────────────┘                 (AUTHORITY on host,
                                                                          CLIENT on the rest,
                                                                          request={crew,enemies,net})
                                            combat-start barrier (§4.7): all peers send combat_ready,
                                            authority replies snapshot + per-seat hand, THEN play opens
                                                                                 |
                                    combat_finished (:854) → wrapper → match_over ┘
                                                  |
                                                  ▼
                                          back to lobby.tscn
```

### 3.3 New files

- `scripts/net/net.gd` — autoload singleton `Net`. Phoenix-over-`WebSocketPeer` client + room session
  state. Pure transport + message routing; holds **no** game state. **Does not auto-connect in
  `_ready`** — it dials only when `connect_realtime()` is called (§4.5), so it stays inert in the
  overworld build (§10). (§4)
- `scripts/net/net_config.gd` — compile-time `<REF>`/`<ANON>` consts (§4.1, §10).
- `scenes/menu/main_menu.tscn` (+ `scripts/menu/main_menu.gd`) — Solo / Host / Join. All-UI-in-code,
  bare `Control` root.
- `scenes/menu/lobby.tscn` (+ `scripts/menu/lobby.gd`) — room-code display/entry, the 4-random-dorf
  roster + pick-one, per-player ready, and (host only) the Start button that assembles the combat
  `request` dict (§8) and tells everyone to `change_scene` into combat.
- `combat.gd` gains a `mode` (SOLO / AUTHORITY / CLIENT) and the seams in §7. **SOLO stays
  behavior-equivalent (§1).**

### 3.4 Entry point / CI decision (see §10 for detail)

The `/` combat build's `run/main_scene` changes from `combat.tscn` (project.godot:19) to
`main_menu.tscn`. **No new export preset, no new deploy sed.** The base preset already ships
`export_filter="all_resources"` (export_presets.cfg:9), so menu, lobby, and combat all travel in one
PCK. Solo `change_scene`s into `combat.tscn`; Host/Join into `lobby.tscn` and thence combat. The
overworld build's existing sed replaces the *whole* `run/main_scene=` line (deploy-pages.yml:73), so it
is unaffected by the new default. The `Net` autoload survives the MCP strip sed (deploy-pages.yml:54
deletes only lines matching `addons/godot_mcp`; `scripts/net/net.gd` does not match).

---

## 4. Transport layer — `scripts/net/net.gd`

`Net` is an autoload. It wraps one `WebSocketPeer`, speaks Phoenix v2 (array frames), tracks one room
channel, and exposes a small signal/method API. It is polled every frame from `_process`. The same code
runs in the editor and in the web export (Godot's `WebSocketPeer` proxies to the browser `WebSocket` on
web), which preserves the MCP screenshot loop (§10).

### 4.1 Connection

- URL: `wss://<REF>.supabase.co/realtime/v1/websocket?apikey=<ANON>&vsn=2.0.0`.
- `<REF>`/`<ANON>` are compile-time consts in `scripts/net/net_config.gd`. They ship in the public PCK.
  **Accepted risk** (settled decision) — friends-only, public channels, room code out-of-band. Harden
  later with private channels + anon-auth + RLS with **no architecture change** (still one channel, still
  Broadcast; you'd add an `access_token` push and per-topic authorization).
- `WebSocketPeer.new()`, `connect_to_url(url)`. Poll with `socket.poll()` at the top of
  `_process(delta)`; branch on `socket.get_ready_state()`. On OPEN edge → emit `connected`. On CLOSED →
  emit `disconnected(code, reason)` + reconnect backoff (§4.6). Inbound: drain
  `while socket.get_available_packet_count() > 0:` → `get_packet().get_string_from_utf8()` →
  `JSON.parse_string` → Array → dispatch (§4.4).

### 4.2 Frame format (vsn=2.0.0 = ARRAY frames)

Every frame is a 5-element JSON array: `[ join_ref, ref, topic, event, payload ]`.

- `join_ref` (String|null): the `ref` used on the channel's `phx_join`; stamped on every subsequent
  message for that channel. `null` on the `phoenix` heartbeat topic.
- `ref` (String|null): a per-message monotonic counter (keep an `int _ref`, stringify). Correlates
  `phx_reply`.
- `topic` (String): `"realtime:room:<CODE>"` for the room; `"phoenix"` for heartbeat.
- `event` (String): Phoenix control events (`phx_join`, `phx_reply`, `phx_close`, `phx_error`,
  `heartbeat`) or `broadcast`.
- `payload` (Object).

### 4.3 The concrete outbound frames

**Join the room** (once, after socket OPEN). `_join_ref = _next_ref()`:

```
[ "<join_ref>", "<ref>", "realtime:room:ABCD", "phx_join", {
    "config": {
      "broadcast": { "self": false, "ack": false },
      "presence":  { "key": "" },
      "postgres_changes": [],
      "private": false
    }
  } ]
```

`broadcast.self` is **false** (settled — see §3.1): the host holds authoritative truth and applies its
own plays locally, so it must **not** receive its own broadcasts back; clients never need their own
messages either. Server replies with a `phx_reply` on the same `ref`: `payload.status=="ok"` → emit
`joined`; `"error"` → emit `join_error(reason)` (surface quota / `too_many_connections` here, §9).

**Heartbeat** (every ~20 s):

```
[ null, "<ref>", "phoenix", "heartbeat", {} ]
```

Keep a `float _hb_accum`; when it crosses the interval, push and reset. 20 s is conservative and sits
**well inside the server idle timeout** (the realtime-js client default heartbeat is ~25 s; the
server-side idle drop is longer — confirm the exact figure in M1 rather than asserting it here). If a
heartbeat's `phx_reply` doesn't arrive within a grace window, treat the socket as dead → reconnect.

**Send an app message** (both directions — everything above transport is a `broadcast` push):

```
[ "<join_ref>", "<ref>", "realtime:room:ABCD", "broadcast", {
    "type": "broadcast",
    "event": "<app_event>",    // submit_action | resync | apply_snapshot | hand | enemy_phase |
                               // match_over | combat_ready | lobby_join | roster | pick | ready | start
    "payload": { ... }         // the app-level struct (§5/§6)
  } ]
```

**Inbound broadcast** arrives as:

```
[ null, null, "realtime:room:ABCD", "broadcast",
  { "type":"broadcast", "event":"<app_event>", "payload": { ... } } ]
```

Dispatch on the inner `event` (§4.4).

### 4.4 Inbound dispatch

`_on_frame(arr)`:
- `event == "phx_reply"` → look up `ref`; resolve join / detect `status=="error"`.
- `event == "phx_error"` / `"phx_close"` → channel dropped → `realtime_error` / rejoin.
- `event == "broadcast"` → read `payload.event` + `payload.payload`, emit the matching high-level signal
  (§4.5). **Net does not interpret game payloads** — hands them up verbatim.
- `event == "system"` → Supabase's post-join subscription-confirmation push. **Swallow it** (log at
  debug only), do not treat as unknown.
- `event == "presence_state"` / `"presence_diff"` → **no-op for the first cut** (we track occupancy from
  `lobby_join`/`ready`/`peer_left`, not presence). Swallow, don't error.
- Anything else → debug-log once; never crash on an unknown event.

### 4.5 Signals & methods (the singleton contract)

Signals:
- `connected()` / `disconnected(code: int, reason: String)`
- `joined(topic: String)` / `join_error(reason: String)`
- `realtime_error(reason: String)` — quota, `too_many_connections`, channel error.
- `lobby_event(kind: String, payload: Dictionary)` — kind ∈ {join, roster, pick, ready, start}.
- `action_received(action: Dictionary)` — **authority handler** consumes this (a client's intent).
- `resync_requested(seat: int, peer_id: String)` — **authority handler**; answer with snapshot + hand.
- `combat_ready_received(seat: int, peer_id: String)` — **authority handler**; the start barrier (§4.7).
- `snapshot_received(snapshot: Dictionary)` — **client handler**.
- `enemy_phase_received(bundle: Dictionary)` — client replays the enemy phase (§7c).
- `hand_received(seat: int, hand: Array, uids: Array, seq: int)` — the private per-seat hand (§6).
- `match_over_received(result: Dictionary)` — everyone returns to lobby together.
- `peer_left(seat: int, peer_id: String)` — from a disconnect app message / socket close.

Methods:
- `connect_realtime()` — dial the URL from `net_config.gd`. **(Not called from `_ready`.)**
- `join_room(code: String, as_host: bool, display_name: String) -> void`
- `leave_room()` / `disconnect_realtime()`
- `submit_action(action: Dictionary)` — client → authority (`event:"submit_action"`).
- `send_combat_ready(seat: int)` — client → authority (§4.7).
- `request_resync(seat: int)` — client → authority (§4.7/§9).
- `broadcast_snapshot(snapshot: Dictionary)` — authority → all (`event:"apply_snapshot"`).
- `broadcast_enemy_phase(bundle: Dictionary)` — authority → all.
- `send_hand(seat: int, hand: Array, uids: Array, seq: int)` — authority → the owning seat
  (`event:"hand"`, self-filtered on receipt).
- `broadcast_match_over(result: Dictionary)`
- `send_lobby(kind: String, payload: Dictionary)` — roster/pick/ready/start plumbing.

**Session fields** (read-only): `is_host: bool`, `my_seat: int`, `room_code: String`,
`seat_count: int`, and **`peer_id: String`** — a random UUID minted at `Net` init (§4.6). The lobby
fills seat assignment (host is seat 0; joiners are assigned the next free seat *by the host, keyed to
their `peer_id`* and echoed in `roster`).

App message types, condensed:
- **submit_action** (client→authority): the action struct (§6.4), carries `peer_id` + `nonce`.
- **combat_ready / resync** (client→authority): `{seat, peer_id}`.
- **apply_snapshot** (authority→all): the shared board snapshot (§6), carries `seq` + `acks`.
- **hand** (authority→seat): `{seat, hand:[cid...], uids:[...], seq}`, self-filtered.
- **enemy_phase** (authority→all): `{seq, events:[...], snapshot:{...}, hands:{seat:{hand,uids}}}` (§7c).
- **match_over** (authority→all): `{won}`.
- **lobby_join / roster / pick / ready / start** (§8).

### 4.6 Peer identity (settled — resolves review major)

A public Broadcast channel is **anonymous** pub/sub: every message reaches everyone and there is **no
per-connection identity**. The design needs stable seats ("host assigns the next free seat," "the same
seat handed back on reconnect"). So each client mints a **`peer_id` UUID at `Net` init** and carries it
in `lobby_join`, in every `submit_action`, and in `combat_ready`/`resync`. The host:
- assigns `peer_id → seat` and echoes the map in `roster` (dedups two joiners racing for "next free
  seat" — first `peer_id` wins the slot);
- on reconnect, hands the **same** seat back to the returning `peer_id`;
- ignores an action whose `peer_id` doesn't own the claimed `seat`.

This is the primitive that makes M2's "both `change_scene` with matching `request`" verifiable.

### 4.7 Reconnect, resync, and the combat-start barrier

Three distinct liveness needs, one mechanism each — deliberately **not** three overlapping host-alive
beats (settled trim):

1. **Socket keepalive:** the Phoenix heartbeat (§4.3). A missed `phx_reply` → reconnect.
2. **Host-gone detection:** socket close / `phx_error` / `peer_left` for seat 0 → clients show
   "Host left — the run ended" and return to menu (§9). (We do **not** add a separate `host_alive` app
   beat or use Realtime presence for this in the first cut.)
3. **Message-loss recovery (resync):** because Broadcast is fire-and-forget, a client runs a
   **watchdog** — if no `apply_snapshot`/`enemy_phase`/`hand` (or heartbeat-snapshot) arrives within
   `T` seconds, **or** it detects a `seq` gap that isn't filled within a short window (§9), it calls
   `request_resync(my_seat)`. The authority answers with the **current absolute snapshot** *and* that
   seat's **current `hand`+`uids`** (it holds the full per-seat state, §6.3). Reconnect reuses the same
   path: re-`connect_to_url`, re-`phx_join`, then `request_resync`. A rejoined/desynced client thus
   recovers **without waiting for the next natural broadcast** (which, between enemy phases, may be a
   long way off).

**Combat-start barrier (initial state).** The very first snapshot is the most fragile message in the
system: the authority `change_scene`s into combat and would broadcast before a slightly-slower client
has finished tearing down the lobby and re-subscribing — Broadcast has no retention, so that first
snapshot is simply lost and the client sits on a blank board. So combat start is an explicit handshake,
not a fire-and-hope:

```
each peer change_scene → combat.tscn
CLIENT: send_combat_ready(my_seat, peer_id)   ; build board from `request`, DO NOT draw / open play
AUTHORITY: on each combat_ready → reply apply_snapshot(seq=0) + send_hand(that seat)
           (and only opens the player phase once every expected seat has been served)
CLIENT: on first snapshot(+hand) → render, THEN accept input
```

Because the authority is the sole roller and clients never draw locally, seeded RNG (§7f) is a genuine
**optional** debugging nicety here, not a hidden correctness dependency.

Mid-combat reconnect of the **host** is not recoverable in the first cut (the host holds the only copy
of authoritative state) — the room ends (§9).

---

## 5. The turn model (StS live-serialized)

### 5.1 One card play, end to end

```
REMOTE CLIENT (seat s taps a card / target)
  │  UI locks the tapped card "pending" (host-confirmed display — no optimistic mutate)
  │  Net.submit_action({seat:s, peer_id, card_uid, hand_index, target_kind, target_idx, nonce})
  ▼
AUTHORITY (host) — on action_received:
  1. phase == "playerTurn"                                    else reject
  2. peer_id owns seat s (§4.6) AND party[s].alive            else reject
  3. card_uid present in party[s].hand (matched by uid)       else reject   (never slot-substitute)
  4. cid,def := that card;  _can_play(party[s], cid, def)     else reject   (energy :608; taunt CD :611)
  5. target valid: target_kind matches def.target AND target enemy/ally alive   else reject
  6. RESOLVE ATOMICALLY on the existing pipeline, actor = party[s] passed EXPLICITLY:
        _spend(party[s], index_of_uid)          (:638)
        _resolve(def, party[s], target)         (:658 → _run_ops :669 → _attack :761)
        _finish_play(party[s], def, cid)        (:644 — party-wide attacks_this_turn++, momentum, etc.)
  7. seq += 1; build snapshot (§6) with seq + acks(+nonce); Net.broadcast_snapshot(snapshot)
     if the actor's hand changed: Net.send_hand(s, hand, uids, seq)
  ▼
ALL CLIENTS — on snapshot_received (seq-guarded, §9):
  MERGE the snapshot's public fields into local party/enemies (§6.1), rebind "node" by slot,
  then _refresh() (:873).  The submitter clears its pending lock when its nonce appears in snapshot.acks.
```

**The host's own tap does not enter this flow.** It calls a shared `_authority_apply_action(action)`
directly (same steps 3–7, actor `= party[my_seat]`), mutates truth in place, `_refresh()`es locally,
then broadcasts. No `submit_action`, no loopback (§3.1).

**Do not "pin" `active_idx` to resolve** (settled — resolves review minor). The resolution pipeline
never reads `active_idx`: `_resolve` (:658), `_run_ops` (:669), `_attack` (:761), `_deal_enemy` (:781),
`_spend` (:638), `_finish_play` (:644) all take the actor `a` as an explicit parameter. `active_idx` is
read only by the **tap-handlers** (:562, :573/:617/:628, :545–550) and the **render**
(`_refresh_party` :924–928, `_refresh_panel` :1096, `_rebuild_hand` :1112). Setting `active_idx` to a
remote seat and refreshing would flip the *host's own* big-hand/highlights to that seat. So: resolve a
remote action by passing `party[seat]` explicitly, and keep the host's `active_idx` bound to its own
`my_seat` (§6.2).

Resolution *is* the existing single-player pipeline, unchanged. `_refresh` (:873) is a **pure
state→UI projection that writes no game state** — the load-bearing property that lets a client drop a
whole snapshot mid-anything and just re-render. (Add a comment at :873 and guard it in review, §12.)

### 5.2 Host-confirmed (non-optimistic) display

A **client** does not mutate on tap. It marks the tapped card *pending* (dim + spinner, input disabled
on that card) and waits for either the `apply_snapshot` whose `acks` contains its `nonce`, or a targeted
`reject` (carrying its `nonce`) that unlocks it. The ~150 ms round-trip is hidden by turn-based pacing.
**There is no client-side rollback because a client never speculatively applies anything.** (This
statement is scoped to clients; the host mutates authoritative truth directly and, being `self:false`,
never re-applies a snapshot to itself, so it has nothing to roll back either.)

### 5.3 The shared board updates live

Every play broadcasts a fresh board snapshot, so coordinated setups work by **watching**: seat A plays
Mark on the Caster → snapshot lands → every client's Caster shows the 🎯 badge (`marked=true`) → seat B,
seeing it, plays a Strike the authority resolves with `Db.MARK_MULT` applied (:773–774).
`attacks_this_turn` is party-wide (:38, incremented :647, read by Arcane Finisher at :681) and rides in
every snapshot, so one player's attacks legitimately grow another player's Finisher — a real co-op
synergy, kept as-is.

### 5.4 Ending a turn — per-player Ready

Today `_on_end_turn` (:356) ends the whole turn: it discards **all** party hands (:359–362), flips
`phase="enemyTurn"`, and `await`s `_enemy_phase`. In co-op that button becomes **Ready**, per seat:

- Client taps Ready → `submit_action` with a `ready` marker (or a dedicated `send_ready`).
- Authority sets `ready[seat]=true` and **discards that seat's hand unconditionally** — mirroring the
  existing all-seats discard at :359–362. (`retain_block` is **not** involved here: it is purely a
  *block*-retention flag consumed at the top of the next player phase — `if not retain_block: a["block"]=0`
  at combat.gd:333 — and never gates hand discard. Following it here would wrongly keep a Bracing-Stance
  seat's hand and diverge from SOLO.) The authority then broadcasts a snapshot showing the seat's ready
  pip.
- When **every alive seat** is ready, the authority runs the enemy phase (§7c) and opens the next player
  phase (drawing fresh hands), shipping the whole thing as one seq-tagged `enemy_phase` bundle. There is
  **no per-player timer** (StS ships none) — only a deadlock-breaker fallback timer (§9).

### 5.5 Canonical order = the authority's single serializer (accepted race)

Two genuinely simultaneous plays (< one round-trip apart) each chose against a board that didn't yet
show the other's play, so a coordinated pair can occasionally surprise each other. That is StS's model
and we accept it. **But be precise about *why* it's well-defined:** the authority merges **two kinds of
source** — its **own local taps** (function calls that never touch the socket) and **N inbound
per-client socket streams**. Supabase gives per-connection (TCP) ordering for *one* sender but **no
cross-sender ordering**. Canonical order is therefore defined by exactly one thing: **the authority's
single-threaded interleave of (local taps) and (drained inbound actions)**. There is not "one socket"
that orders everyone, and the host's own plays aren't on the socket at all. The relay's ordering is
irrelevant to resolution order.

Where relay ordering *does* matter is the **downstream**: clients can receive snapshots out of order or
with gaps. The client-side `seq` guard (§9) is exactly the mechanism that tolerates the relay's lack of
ordering, and it is load-bearing, not speculative.

**Fallback if playtests hate the race:** a *barrier* model — same resolver, the authority buffers a
phase's actions and resolves them in a deterministic committed order on a "resolve" pulse. Same
`_resolve`/`_attack`, a different scheduler, no snapshot-contract change. Not built now.

### 5.6 Hidden hands (shared vs private)

- **Shared** (in `apply_snapshot`, seen by all): enemies (hp/block/statuses/intent/marked/burn/
  vulnerable/rage/move_i), each dwarf's public stats (hp/max_hp/block/shield/energy/alive/role/name/
  emoji/slot + the status badges rendered at :930–950), scene globals (§6.2), each seat's **hand
  count** and its `played_turn` ghost list (shared planning info that never names unplayed cards),
  threat pairs, ready pips, `party_attack_buff` (the 📣 Aura readout).
- **Private** (only to the owning seat, via `hand`): the seat's actual card ids + their uids. Other
  seats' mini-hand rows render **count-only / face-down** — never the card emoji. The current
  `_refresh_minis` (:1158) renders real faces of non-active dwarves; that **must be gated in co-op**
  (§7a), or it leaks hands. **This gate ships in M3** — the first shared-board demo must not leak hands.

---

## 6. The snapshot contract

A snapshot is a JSON-serializable `Dictionary`. Everything in the party/enemy dicts is JSON-safe (ints,
bools, strings, arrays of card-id strings, a `temp` sub-dict of ints/bools) **except the live `node`
Label ref**, which must be stripped on send and rebound on receive. It also carries `seq` and `acks`
(§9).

### 6.1 Apply is a field-level MERGE, never a replace (settled — resolves review blocker)

Every char dict carries `"node": pc_emoji[i]` (:270) and every enemy `"node": en_emoji[i]` (:301) —
live `Label` references, not serializable. Each also carries a safe `"slot"` int (:270, :301).

- **On send** (authority): deep-duplicate each char/enemy dict, `erase("node")`, and **omit `deck`,
  `hand`, `discard`** (§6.3). Keep `slot`, `hand_count`, `played_turn`, and the public fields.
- **On receive** (client only — the host is `self:false` and never re-applies its own state): for each
  incoming entry, **merge its public fields into the *existing* local `party[i]` / `enemies[i]` dict** —
  **never** `party = snapshot.party`. A blind replace would overwrite the client's own `hand`/`uids`
  (delivered separately via `hand`, §6.3) with deck-less dicts and wipe them. After merging, rebind
  `dict["node"] = pc_emoji[dict["slot"]]` / `en_emoji[dict["slot"]]` from the *local* UI slot arrays,
  then `_refresh()`. `_flash`/`_impact` (:1268/:1280) read `c.get("node")` and no-op on null, so a
  momentary null between merge and rebind is harmless — but rebind before `_refresh`.

`slot` is the stable bridge between authoritative data and local Labels.

### 6.2 Scene globals that MUST be in the snapshot

The resolver reads these; omit any and resolution desyncs:
- `phase` (:32), `turn` (:33), `party_attack_buff` (:36), `taunt_last_turn` (:37),
  `attacks_this_turn` (party-wide, :38), `combat_epoch` (:39, for await-guard parity on clients running
  cosmetic timers).
- **Not** `active_idx` (:34) as shared state — in co-op there is no "switch active dwarf." `active_idx`
  degrades to a **client-local** variable that is always the client's own `my_seat` (drives which big
  hand shows). It is derived, not transported, and never reassigned by `_first_living_party()` on a
  client (see §7a, :351).
- `ready: Array[bool]` (length `seat_count`) — the per-seat ready gate.
- `seq: int`, `acks: Array[int]` (§9).
- `mode`/`seat_count`/`enemy_count` are fixed at combat init and need not ride every snapshot.

### 6.3 Hidden-hand filtering (what the split actually buys)

- `apply_snapshot.party[i]` includes `hand_count` (int) and `played_turn` (array) but **omits `hand`,
  `deck`, `discard`** for *every* seat.
- The owning seat's `hand` (+ per-card `uids` + `seq`) is delivered separately by `send_hand(...)` and
  self-filtered on receipt (`if payload.seat == my_seat`).
- **What separating `hand` buys, stated accurately:** it keeps the hand off the **high-frequency
  snapshot payload** (a *size* win — snapshots stay lean). It does **not** reduce fan-out or wire
  visibility: on a shared channel every message is still delivered to (and billed for) all subscribers,
  and a seat-tagged hand is visible on the wire to all of them. Privacy is therefore **soft** (an
  app-level display gate, not secrecy). The thing that would *both* cut fan-out *and* fix privacy is a
  **per-seat channel** (§12) — reference it here, don't over-claim the split.
- Authority keeps the full `deck`/`hand`/`discard` for every seat in its own state (it draws for
  everyone) and can therefore answer a `resync` with any seat's current hand (§4.7); it just never
  *broadcasts* deck/discard.

### 6.4 The action struct

```
{
  "seat":        int,     // the actor's seat
  "peer_id":     String,  // proves seat ownership (§4.6); authority rejects a mismatch
  "card_uid":    String,  // stable per-dealt-card id; authority matches by THIS, never by index
  "hand_index":  int,     // hint only (where the client thinks it is); authority locates by uid
  "target_kind": String,  // "enemy" | "ally" | "self" | "all" | "none"
  "target_idx":  int,     // enemy slot or party seat; -1 for self/all/none
  "nonce":       int      // per-client monotonic; ack (via snapshot.acks) / reject correlation + dedup
}
```

- **card_uid** exists because the armed card is a bare int today (`selected_card`, :35) that play paths
  only bounds-check (`_armed_def` :561), and `_rebuild_hand` (:1107) `queue_free`s and rebuilds every
  card node — so a snapshot landing mid-interaction can silently re-aim a tap onto a different card.
  Fix: stamp each dealt card with a stable uid; arm by uid; the action carries the uid; the authority
  **rejects a spent/absent uid** (never slot-substitutes); `_rebuild_hand` **reconciles by uid** (§7b).
- **nonce** lets the authority ack (echo in `snapshot.acks`) / reject a specific submission and drop
  duplicate retries.

---

## 7. Required `combat.gd` refactors

Each item lists the seam(s) and the reason. **SOLO must be behavior-equivalent** (§1). §7a and §7b
touch *shared* code that SOLO also runs, so they are **not** mode-gated — SOLO changes form, and must be
proven behavior-equivalent by playtest + screenshot diff (M0). Only the §7e commit points and the
enemy-phase split are truly mode-gated ("untouched SOLO path"). §7d's heal guard is a genuine SOLO
no-op.

### (a) Party size 3 → N (2–4); enemy count fixed at M = 3

**Enemies stay a fixed 3-slot line** in the first cut (settled — resolves review major). This sidesteps
both the missing 2-/4-enemy comp data (every comp is exactly-3 ids: ENCOUNTER card_db.gd:206,
ENCOUNTERS_BY_TIER :211, ENCOUNTER_POOLS :219 — the comment at :217 spells out "each comp = exactly 3
ids (hard slot rule)") **and** the 4-wide enemy-label collision. Enemy slots keep building as today
(`for i in range(3): _build_enemy_slot(i)` at :125–126, `EN_POS` :79 unchanged); `_refresh_enemies`
`range(3)` (:890) is fine. `_start_combat` already builds `enc.size()` enemies (:276), so no engine
change is needed to field the 3-line. Party-size scaling rides `enemy_scale` (§8.3), not enemy count.

**The party side goes 2 → 4.** Every hardcoded/coupled site:

- `PC_POS` is a 3-element const (:80). Replace with a computed `pc_pos: Array` sized from `party.size()`,
  laid out by a new `_layout(n_party)` that spreads seats evenly across the 720 width **and derives the
  per-seat label + mini-row widths from the column width `col_w = 720/n_party`** (not the fixed 160 px
  labels at :233–236 and 178 px mini-row at :239 — at 4-wide those overlap regardless). `PC_POS[t.slot]`
  in threat arrows (:1090) repoints to `pc_pos`.
- **Party slot construction moves out of `_build_ui` into a count-driven `_build_board(n_party)` called
  from `_start_combat`** (after `request` is parsed at :246). `_build_ui` runs in `_ready` (:83–88)
  **before** `_start_combat` knows the count, so the party loop `for i in range(3): _build_party_slot(i)`
  (:162–163) can't stay in `_build_ui`. (Enemy slots and all chrome/bg/**overlay** stay in `_build_ui`.)
- **Overlay z-order (do not lose this).** The win/lose `overlay` (:185–189, `z_index` unset = 0) covers
  the board today **only** because the slot Labels are added to `self` *before* the overlay in child
  order. Moving party-slot construction into `_build_board` (which runs **after** `_build_ui`) makes the
  party slots *later* siblings than `overlay` at equal `z_index=0`, so the emoji would draw **on top of**
  the overlay and the dim would no longer cover the board. **Fix explicitly:** give `overlay`
  (+ `overlay_label` / `overlay_btn`) a high `z_index`, **or** `move_child(overlay, -1)` after
  `_build_board`, **or** parent party slots into a dedicated board container created before `overlay`.
- **The latent crash this also fixes:** the build loop stores `"node": pc_emoji[i]` (:270) while
  iterating `crew_specs.size()` (:253) — hand it 4 crew and it indexes `pc_emoji[3]` (only 3 exist) and
  crashes. Building N party slots first removes it.
- `for i in range(3): en_emoji[i]... pc_emoji[i]...` (:310) **couples enemy count to party count** in one
  loop. Split: the enemy half stays `range(3)`; the party half becomes `range(party.size())`.
- `_refresh_party` `range(3)` (:921) → `range(party.size())`.
- `_refresh_minis` `range(3)` (:1159) → `range(party.size())`, **and** gate face rendering: in co-op the
  local seat shows its big hand; every **other** seat's mini row is count-only / face-down (do not render
  `Db.CARDS[cid].emoji` for a seat that isn't `my_seat`), or hands leak (§5.6). **Ships in M3.**
- **`active_idx = _first_living_party()` at :351** (inside `_start_player_phase`, top of every player
  phase) is a co-op seam: it silently resets `active_idx` to slot 0. In co-op, `active_idx` must be
  pinned to `my_seat` and **never** driven by `_first_living_party()`. Since clients don't run
  `_start_player_phase` at all (§7c/§4.7 — only the authority does), the practical rule is: on a CLIENT
  `active_idx` is a constant `= my_seat`; the authority's own `active_idx` likewise stays `= my_seat`
  and is not repointed at slot 0.
- **Active-dwarf semantics change (co-op only):** there is no tap-to-switch-active. `_on_party_clicked`
  (:535) keeps its ally-targeting branch (:539–543) but the "switch active character" branch (:545–550)
  is disabled in co-op — the local player *is* one seat. In SOLO it is unchanged.
- `_check_end` (:828) needs **no** change for N: it **iterates the `enemies`/`party` arrays directly**
  (`for e in enemies` / `for a in party`, :831–838) — size-agnostic. (It does not call `.size()`.)
  `_enemy_target` and the pickers (:475–524) are role-based and size-agnostic — good.

### (b) Card uid instead of `selected_card` int + reconciling `_rebuild_hand`

- Give each dealt card a stable `uid` (monotonic per combat, assigned by the authority in `_draw_cards`
  :817 and shipped in `hand`). Represent a hand as parallel `hand:[cid]` + `hand_uids:[uid]`.
- Arm by uid: `selected_card` (:35) becomes `selected_uid: String`. `_armed_def` (:561),
  `_on_card_clicked` (:570), `_play_on_enemy` (:616), `_play_on_ally` (:627) resolve the armed card by
  uid, not index. (These are shared paths SOLO traverses — hence "behavior-equivalent," not "untouched.")
- The networked action carries `{card_uid,target_...}`; the authority rejects a spent/absent uid and
  **never** substitutes by slot.
- `_rebuild_hand` (:1107) currently `queue_free`s and rebuilds **all** card nodes. Make it **reconcile
  by uid**: free nodes whose uid left the hand, add nodes for new uids, **leave surviving nodes** (and
  their hover/tooltip/armed state) in place. Card nodes get a `uid` field (`scripts/ui/card.gd`).
- **Animation interaction (do not lose this):** today the deal/switch entrance (:1132–1153) assumes
  *every* card node is freshly created each refresh and parks it at the portrait (`PC_POS[active_idx]`,
  :1136) to fly in. A reconciling rebuild that leaves survivors in place must **animate only
  genuinely-new uids** when `_hand_anim != ""`, and leave surviving nodes untouched — mirroring the
  `not played` gate `_refresh_minis` already uses (:1189). Otherwise survivors either don't animate or
  get yanked to the portrait mid-hover.

### (c) `_enemy_phase` as a pure function of (state, seed) — authority only

Today `_enemy_phase` (:368) mutates authoritative state **inside** `await get_tree().create_timer()`
steps (:390, :396, :404), guarded by `combat_epoch` (:369, bumped :247). A backgrounded tab pauses the
rAF loop driving those timers → the host freezes mid-phase → every client stalls.

Refactor (AUTHORITY): `_resolve_enemy_phase(state, rng) -> {events, snapshot, hands}` computed
**synchronously** (no awaits). It folds: enemy block clear (:372–373), Burn ticks (:376–385), each
living enemy's move via `_enemy_move`/`_do_enemy_move` (:399–400), the interleaved `_check_end`, **and**
opening the next player phase (`_start_player_phase` :327, drawing fresh hands off the authority RNG).
Output:
- `events`: ordered `{kind, enemy_slot, target_slot, amount, ...}` for **cosmetic** client replay.
- `snapshot`: the final post-enemy-phase board (start of the next player phase), **seq-tagged**.
- `hands`: `{seat: {hand, uids}}` for the freshly drawn hands (private per seat; delivered via `hand`,
  each seq-tagged).

The authority broadcasts one seq-tagged `enemy_phase` bundle. Each **client** runs `events` on *local*
cosmetic timers (purely visual) then lands on `snapshot`; a backgrounded client just snaps to `snapshot`
on foreground. The authority **never awaits**, so a host that is foreground-but-blipping no longer
propagates a freeze. (A host that stays *persistently* backgrounded still stalls its own
`_process`/socket poll — see §9/§12; the pure function shrinks the window from multi-second await chains
to per-message processing, it does not abolish it.)

**Clients never run `_enemy_phase` or `_start_player_phase`.** They render `enemy_phase` bundles. In
SOLO, keep today's `await`-paced `_enemy_phase` verbatim (it *is* the local cosmetic replay + sim in
one).

### (d) Heal alive-guard (genuine SOLO no-op)

`heal_ally`/`heal_self` (:697–701) have **no** alive-guard. A heal that races a death yields `hp>0` with
`alive=false` — a "healed corpse" the board shows as alive-but-downed and that `_check_end` (:828)
counts as dead. Add the guard: only heal a target with `alive==true` (and if a heal should *revive*, do
it explicitly). This matters more in co-op where more simultaneous plays cross a death. (`heal_or_damage`
at :706 shares the hazard on its heal branch; guard it too.) In SOLO this is a no-op — downed allies
aren't targetable (`_on_party_clicked` returns at :536) and actors are always alive.

### (e) Mode gate at the commit points

Add `enum Mode {SOLO, AUTHORITY, CLIENT}`, `var mode := Mode.SOLO`, `var my_seat := 0`, set from
`request` (§8). Gate the four commit points:
- self/all-enemies branch of `_on_card_clicked` (:580–591), `_play_on_enemy` (:616), `_play_on_ally`
  (:627), and the Ready path (replacing `_on_end_turn` :356).
- **SOLO**: unchanged — mutate locally (**this** is the "untouched SOLO path").
- **CLIENT**: do **not** mutate. Build the action struct (§6.4), `Net.submit_action(action)`, lock the
  card pending. Apply arrives via `snapshot_received`.
- **AUTHORITY** (host's own taps): route through the same `_authority_apply_action(action)` that
  `action_received` uses, then broadcast — host is a local client whose transport is a function call.

Only AUTHORITY runs the enemy-phase resolver and the ready gate; CLIENTs render `enemy_phase` bundles.
**Match end:** `combat_finished` (:26) fires at `_end` (:847) only when `request` is non-empty (:850);
co-op **populates `request`** (§8), so `_end` emits `combat_finished` and returns (:854) — it does
**not** itself broadcast, and the standalone Play-Again overlay (:856–857) is skipped. The chain is
explicit: **authority `_end` → `combat_finished` (:854) → the lobby/combat wrapper → `broadcast_match_over`
→ clients `change_scene` back to lobby.** Clients must **not** locally treat an all-enemies-dead snapshot
as match end (safe because `_refresh` :873 never calls `_check_end`; keep it that way, §12).

### (f) Seeded RNG for the authority (optional debugging nicety)

RNG is unseeded/global at three sites: `deck.shuffle()` (:258), the per-enemy move offset
`randi()%mvs.size()` (:299), the discard reshuffle (:821). Under host-authority with the combat-start
barrier (§4.7), **only the authority ever rolls** and results ship in snapshots — clients never roll, so
this is a **non-issue for correctness**. Seeding an owned `RandomNumberGenerator` (seed in the init
`request`) is therefore **optional**: its only payoff is cheap reproducibility for "why did the board
differ" debugging. It is **not** load-bearing (we rejected lockstep, and no client draws locally), so we
do not justify it with replay determinism. Do it only if the debugging convenience is wanted.

---

## 8. Roster & lobby flow

### 8.1 Four random dorfs from a seed

Each player's roster of 4 is generated locally from a per-player seed via the existing factory
`_make_dwarf(dname, cls)` (overworld.gd:332), which reads `Db.CLASSES[cls]` for `max_hp`/`deck`
(card_db.gd:138). "Random" = seed a `RandomNumberGenerator`, pick `cls` uniformly from `Db.PARTY_ORDER`
(card_db.gd:146, `["warrior","cleric","sorcerer"]`) four times (duplicates allowed, no guaranteed
coverage), pull a name from a pool (reuse `RECRUIT_NAMES`, overworld.gd:84). Two players piloting a
sorcerer is fine — per-char state is fully independent, and combat targeting is role-based
(`_enemy_target` + pickers :475–524 loop `party` by role), so a `{sorcerer, sorcerer}` lobby targets
correctly. Only presentational "no healer" hints (the crew-gauge warnings around overworld.gd:660–679)
must not assume a canonical W/C/S trio.

Lift `_make_dwarf`/roster-gen into a small shared helper (make it a static on `Db`, or duplicate the
~4-line factory into `lobby.gd`) so the lobby doesn't `preload` the whole overworld script for one
function. Keep overworld's copy working.

### 8.2 Lobby → combat `request`

`_start_combat` (:246) already consumes a serializable init contract: `request.get("crew",[])` of
`{cls,name,hp,max_hp,deck}` specs (:249–257) and `request.get("enemies")`/`request.get("enemy_scale")`
(:274–275). The lobby (host) assembles exactly that, plus net metadata:

```
request = {
  "crew":        [ {cls,name,hp,max_hp,deck}, ... ],   // one per seat, in seat order
  "enemies":     [ "brute", "witch", "caster" ],       // a FIXED 3-enemy comp for the size+comp (below)
  "enemy_scale": <float>,                              // additive composite (below)
  "seed":        <int>,                                // authority RNG seed (§7f, optional)
  "net": { "mode": "authority"|"client", "seat": <int>, "seat_count": N, "room": "ABCD" }
}
```

Flow: Host creates room → `Net.join_room(code, true, name)` (host = seat 0). Each joiner
`Net.join_room(code, false, name)`; the host assigns the next seat **keyed to the joiner's `peer_id`**
(§4.6) and broadcasts `roster` (peer_id→seat→name/class-of-chosen-dwarf). Each player picks **one** of
their four dorfs (`pick`: `{seat, peer_id, spec}`). When all connected players have picked and readied,
the host builds `request` (its own `net.mode="authority"`, everyone else `"client"`), broadcasts `start`
carrying the shared fields (`enemies`, `enemy_scale`, `seed`, `seat_count`, and the **full crew list** so
every client renders all portraits) plus each client's own `mode/seat`, and everyone `change_scene`s into
`combat.tscn` with `request` set **before** `add_child`/`_ready` (mirrors overworld.gd:824, "set request
BEFORE add_child"). On a **CLIENT**, `_start_combat` builds the board and portraits from `request` but
does **not** draw cards or open the player phase — it sends `combat_ready` and waits for the authority's
first snapshot + `hand` (§4.7). Only the picking player transmits their chosen dwarf's `deck`; the host
aggregates crew in seat order.

### 8.3 Enemy scaling: party size + composition (against a fixed 3-enemy line)

Reuse the overworld's **additive threat** philosophy, not the old multiplied composite. In the
overworld, threat composes additively (`req["enemy_scale"] = 1.0 + (comp.scale-1) + (mscale-1)`,
overworld.gd:823) and combat damps *damage/block* while HP scales full: `dscale = 1+(escale-1)*ATK_SCALE_K`
with `ATK_SCALE_K=0.65` (combat.gd:20, :280–282), HP at full `escale` (:281). Carry that in:

- **Enemy count is fixed at 3** (§7a). Party size + composition are expressed **purely through
  `enemy_scale`** and through *which* existing 3-id comp we field (reuse `Db.ENCOUNTER` /
  `ENCOUNTER_POOLS`), **not** by fielding more or fewer enemies. (Deriving threat-sized comps of 2/4 is a
  later milestone; it needs new authored comp data + the 4-wide enemy layout.)
- `enemy_scale = 1.0 + PARTY_STEP*(N-2) + COMP_ADJ`, additive. `PARTY_STEP` grows the fight **sub-linearly**
  with players (StS scales enemies non-linearly with party size — more players ≠ proportionally more
  enemy power). `COMP_ADJ` is a small **downward** nudge when the lobby lacks a trivializing role —
  a **healerless** lobby gets a slightly gentler scale (and/or the AoE-heavier comp is avoided) so it
  stays beatable (settled: a healerless lobby must be winnable); a **double-DPS, no-tank** lobby fields a
  comp with fewer `tankiest`-seeking heavies stacking one squishy front.
- Because HP scales full but damage is damped (0.65) and Howl rage is capped (`RAGE_CAP=8`, combat.gd:21),
  the fight gets *longer/costlier*, not *one-shot lethal*, as N grows — the property the scaling audit
  relied on.
- **Tuning method, not guesswork:** the audit's Monte-Carlo bot sim lives in the scratchpad
  (`dorf_sim.py`). Re-run it across N ∈ {2,3,4} and the no-healer / no-tank comps; trust the **0%-win
  cells** as the real signal (the bot policy is near-optimal, so its 100% reads are a bot ceiling, not
  "too easy"). Land `PARTY_STEP`/`COMP_ADJ`/comp choices off that, exactly as single-player `DANGER_STEP`
  was landed (overworld.gd:70). This is a **balance pass, not a code seam** — ship a first-guess formula,
  verify with the sim, then tune.

---

## 9. Failure modes & handling

Broadcast is **fire-and-forget, unordered across senders, and un-replayed**. Absolute-state snapshots
self-heal **only when another message follows** — and between enemy phases there can be a long gap with
no broadcast at all. So loss recovery is a first-class layer (§4.7), not an afterthought.

- **Dropped message / liveness (the core relay risk).** A single lost `apply_snapshot`, `hand`,
  `enemy_phase`, or `match_over` would otherwise wedge a client forever (nothing re-requests it). Guard
  it with (1) a **client watchdog** — no snapshot/hand/enemy-phase (or heartbeat-snapshot) in `T` seconds
  → `request_resync(my_seat)`; (2) the authority answers `resync` with the **current absolute snapshot +
  that seat's `hand`+`uids`** (§4.7, §6.3); (3) **`seq` gap detection** — a client that receives
  `seq > last+1` waits a short window for the in-order fill, then `request_resync`; (4) **`acks` in every
  snapshot** — a small list of recently-acked nonces, so a lost single ack doesn't wedge a pending card
  (the client clears the lock when its nonce appears). This is why `seq` is load-bearing and *not*
  YAGNI: the transport is a fan-out relay with no cross-sender ordering, not a single ordered TCP pipe.
- **`seq` covers ALL board-advancing broadcasts, uniformly** — `apply_snapshot`, `hand`, and the
  `enemy_phase` bundle all carry the same monotonic `seq`. Apply the same rule everywhere: **drop if
  `seq ≤ last applied`; on a gap, resync.** (A stale `hand` from turn N must not overwrite a fresh `hand`
  from turn N+1; a dropped `enemy_phase` must trigger resync, not silence.)
- **Authority (host) disconnects.** Clients detect it via socket close / `phx_error` / `peer_left` for
  seat 0 → show "Host left — the run ended," `change_scene` to menu. The run is disposable; no state
  recovery. (The structural cost of browser-only hosting, §2/§12.)
- **A client disconnects.** Its dwarf must not deadlock the room. The authority marks the seat **absent**
  (keyed by `peer_id`) → excludes it from the all-ready gate (auto-ready each phase) and plays **no**
  cards for it; the dwarf stays on the board (targetable, can be downed via the existing `alive`/downed
  path, combat.gd:263–265). Reconnect (same room, same seat handed back to the same `peer_id`, §4.6)
  restores control; the client recovers via `request_resync` (§4.7).
- **Ready-gate deadlock.** A seat that never readies (AFK / dropped-but-not-yet-detected) stalls the
  enemy phase. Mitigation is a **soft deadlock-breaker**, not a per-player turn timer: once the *first*
  seat readies, the authority starts a generous fallback timer (e.g. 60–90 s); on expiry it auto-readies
  the remaining alive seats and proceeds. A visible "waiting on N players…" nudge accompanies it.
- **Backgrounded authority.** The pure-function enemy phase (§7c) removes the multi-second `await`
  windows. It does **not** save a host whose tab stays backgrounded — a throttled tab throttles
  `_process` (socket poll + resolver), so the room slows/stalls until refocus. First-cut mitigations:
  (1) a prominent "keep this tab in the foreground — you're hosting" banner on the host, (2) the deadlock
  timer keeps *clients'* UI from hanging on a stalled host, (3) document it as a known limit; a
  Web-Worker/AudioContext keep-alive is a later option (§12).
- **Supabase over-quota / `too_many_connections`.** Free tier caps 200 concurrent connections and 2M
  messages/month. On join, over-quota returns a `phx_reply` `status:"error"` (or a `phx_error`) whose
  reason mentions the limit; Net emits `realtime_error(reason)`; the lobby surfaces "Servers busy — try
  again shortly" and drops to menu.
- **Message-budget arithmetic (per-recipient — the honest count).** Broadcast is billed and delivered
  **per recipient**, so multiply by fan-out. With `self:false`, per remote card play the wire carries
  `submit_action` + `apply_snapshot` + `hand`, each delivered to the ~`N-1` other subscribers ≈
  **~3(N-1) delivered messages/play** (the `acks` ride the snapshot, so there is no separate ack
  message). At N=4 that's ~9/play; a ~40-play combat ≈ **~360 from plays**, plus one `enemy_phase` bundle
  per player phase (×~`N-1`), plus a heartbeat every 20 s per client, plus lobby chatter → on the order
  of **~500–1,000 delivered messages per full 4-player combat** (not "a few hundred"). Even so, at
  friends-scale this leaves **well over ~2,000 combats/month** of headroom under 2M — the headline holds;
  only the naive number was wrong. Keep snapshots lean (node stripped, hands out, §6) to stay there.

---

## 10. Build / CI & testing

### 10.1 Build/CI (no new preset, no new sed)

- Change `run/main_scene` (project.godot:19) from `combat.tscn` to `main_menu.tscn`. The overworld
  build's sed replaces the whole `run/main_scene=` line (deploy-pages.yml:73), so it is unaffected.
- The `/` preset already exports `all_resources` (export_presets.cfg:9) → menu, lobby, and combat all
  ship in one PCK; no second preset, no second export step.
- Add the autoload to project.godot `[autoload]` (:22–26): `Net="*res://scripts/net/net.gd"`. It does
  **not** match `addons/godot_mcp`, so it survives the MCP strip sed (deploy-pages.yml:54). The three MCP
  autoloads (:24–26) are still stripped for the web build; `Net` remains. **`Net` must not auto-connect
  in `_ready`** — it dials only via `connect_realtime()` (§4.5), so it ships **inert** in the overworld
  build (:69–78) even though the Supabase config travels in that PCK too (harmless, shipped, unused).
- The Supabase `<REF>`/`<ANON>` in `scripts/net/net_config.gd` ship in the public bundle (accepted, §4).
- **Glyph gate (do not trip it).** The deploy runs a hard glyph-coverage check (`check_web_glyphs.py`,
  deploy-pages.yml:32–35) that fails the build if any UI character falls outside the two shipped fonts.
  All new menu/lobby text — Host/Join buttons, room codes, a "waiting on N players…" nudge, any status
  emoji — must be ASCII-only or font-covered. Run `check_web_glyphs.py` against the new strings before
  deploying (M2).
- Nothing else in `deploy-pages.yml` changes; the coi-serviceworker shim (:80–87) still applies
  (WebSocket isn't SAB-gated).

### 10.2 Testing with the MCP loop

Native `WebSocketPeer` runs **in the editor**, so the MCP `play_scene` → `get_game_screenshot` loop
still works on the authority instance:
- **Two Godot instances** (or editor + exported web build) both pointed at one real Supabase project and
  the same room code = a genuine 2-client test. MCP drives one (the authority) and screenshots it.
- **A local echo/loopback transport** in `net.gd` (a debug flag routing `submit_action` straight into
  `action_received`, `broadcast_*` into local `*_received`, and `combat_ready`/`resync` locally) exercises
  the client/authority split and the snapshot round-trip with **no Supabase** — critical for M1/M3
  iteration speed and single-instance screenshots.
- The Supabase project is created once via the `supabase` MCP tools (`create_project` / `get_project_url`
  / `get_publishable_keys`) or by hand; the dev still operates zero servers.

### 10.3 The falsification test to run FIRST (hotseat)

Before any network code exists, prove the **party-size + uid refactors** in a **hotseat N-player local**
build (M0): `combat.tscn` with `mode=SOLO`, `request.crew` of N (2/3/4) dorfs vs the fixed 3-enemy line,
all seats driven by the existing taps in one instance. Verify: N-seat combat lays out (no 4-wide party
overlap), plays, resolves, and ends; the `pc_emoji[3]` crash (§7a) is gone; card-uid arming survives a
forced `_rebuild_hand` (and survivors still animate correctly per §7b); heal-across-death no longer
leaves a healed corpse; **and single-player (N=3, `request={}`) is behavior-equivalent to today
(playtest + screenshot diff).** If hotseat N-player combat doesn't hold, nothing downstream matters —
this test gates everything.

---

## 11. Milestones (each independently verifiable)

- **M0 — Hotseat N-player local.** Refactors §7a (party 3→N, fixed-3 enemies, layout, overlay z-order),
  §7b (card uid + reconciling `_rebuild_hand` + survivor-animation gate), §7d (heal guard); add `mode`
  enum defaulting SOLO (§7e gates, no net). *Verify:* 2/3/4-seat combat playable in one instance;
  SOLO N=3 behavior-equivalent (playtest + screenshot diff); MCP screenshot of a 4-seat board.
  **Gate for all further work.**
- **M0.5 — Supabase + net_config wired.** Create the Supabase project; wire `<REF>`/`<ANON>` into
  `scripts/net/net_config.gd`; confirm the anon `private:false` Broadcast handshake works with only the
  URL `apikey` (the `access_token` question, §4.3). *Verify:* a raw `phx_join` + a round-tripped
  `broadcast` between two hand-driven clients on the live project. **Hard prerequisite for M1.**
- **M1 — `net.gd` Phoenix client + loopback.** Connect, `phx_join`, heartbeat, `self:false` dispatch
  (swallow `system`/presence, §4.4), `peer_id`; the loopback transport for
  `submit_action`↔`apply_snapshot`. *Verify:* two editor instances join one room and exchange a ping; a
  loopback play round-trips locally.
- **M2 — Lobby.** `main_menu.tscn` (Solo/Host/Join) + `lobby.tscn` (room code, 4-random-dorf roster from
  a seed via `_make_dwarf`, pick-one, ready, host Start builds `request`; `peer_id`-keyed seat
  assignment). Run `check_web_glyphs.py` against all new strings. *Verify:* two clients reach the lobby,
  pick, host starts, both `change_scene` into combat with **matching** `request`.
- **M3a — Board sync (one card type, hidden hands, start barrier).** The `submit_action` → validate →
  `_resolve`/`_attack` → `apply_snapshot` loop for a single card type; §6 snapshot with node
  strip/**merge**-rebind + scene globals + `seq`; the §4.7 **combat-start barrier**; per-seat private
  `hand` delivery + self-filter + other-seat mini rows count-only/face-down (§5.6/§7a). *Verify:* two
  clients see one shared board stay in sync across a few plays; **neither sees the other's card faces**;
  a killed-then-resent snapshot triggers `resync` and recovers.
- **M3b — Full combat loop.** §7c pure-function enemy phase (seq-tagged bundle); per-seat ready gate +
  deadlock timer; the full card set. *Verify:* two clients fight one shared combat to win/lose, driving
  a setup→payoff (seat A Mark → seat B Strike math); the board never wedges across enemy phases.
- **M4 — Robustness.** Host-confirmed pending-lock + `nonce`/`acks` ack/reject; disconnect (host-left →
  menu; client-absent → auto-ready + `peer_id` reclaim on reconnect); resync watchdog + seq-gap recovery;
  quota/`too_many_connections` surfacing; optional §7f seeded RNG. *Verify:* kill a client tab and the
  room continues, then it reconnects into its seat; kill the host tab and clients cleanly return to menu;
  force-drop a broadcast and the watchdog resyncs.

---

## 12. Open questions / risks (ranked)

1. **Persistently backgrounded host stalls the room.** The deepest structural risk (browser-only
   hosting, §2). §7c shrinks the window but cannot abolish it. Ship with a "stay focused" banner +
   deadlock timer, or invest in a keep-alive (Web-Worker heartbeat / silent AudioContext) — and does that
   reliably beat tab throttling on mobile Safari? **Real-device test in M3b.**
2. **Message loss / liveness on a fire-and-forget relay.** Covered by the resync layer (§4.7/§9), but the
   watchdog `T`, the seq-gap window, and the resync round-trip need **measurement under real loss**, not
   just design. **Instrument in M3/M4.**
3. **The `access_token` / anon-Broadcast handshake (§4.3).** Whether public `private:false` Broadcast
   works with only the URL `apikey` is the one protocol fact I can't fully pin from the codebase. For
   public channels the URL `apikey` is the established working path (no `access_token` push) — but it's a
   quick **M0.5/M1 confirmation**, not an architecture-threatening unknown.
4. **Hidden-hand privacy is soft.** Seat-tagged hands ride the shared channel (visible on the wire), so a
   modified client could read them, and the split saves *snapshot size*, not fan-out (§6.3). Accepted for
   friends-only. True privacy **and** reduced fan-out = a **per-seat channel**
   (`realtime:room:<CODE>:seat:<n>`, ≤4 extra cheap conns) or private channels + RLS — an additive
   upgrade, no architecture change. **Ship soft; note the upgrade path.**
5. **Enemy scaling for N + composition is unsolved balance, not code.** §8.3 gives a formula shape and a
   sim method (against the fixed 3-line), not landed numbers. A healerless 4-stack and a no-tank double-DPS
   lobby are the corner cells to prove winnable. **Monte-Carlo pass (`dorf_sim.py` for N and off-comps),
   post-M3b.**
6. **The sub-150 ms simultaneous-play race (§5.5).** Accepted (StS ships it). If a specific interaction
   annoys playtesters, the barrier fallback is same-resolver and drop-in — prototype only if the complaint
   materializes.
7. **`_refresh` purity must be preserved forever.** The client-applies-mid-anything property (§5.1)
   depends on `_refresh` (:873) writing no game state, and clients relying on `match_over` (not their own
   `_check_end`) depends on `_refresh` never calling `_check_end`. Both true today; a future "refresh also
   advances X" edit would silently break clients. **Comment both and guard in review.**
8. **Variable enemy count (M≠3).** Fixed at 3 for the first cut (§7a/§8.3). Supporting 2/4 enemies is a
   later milestone needing new authored comp data **and** enemy-side layout work (label/threat widths).
9. **Reconnect breadth.** Client resync is specced; host reconnect is explicitly out (§4.7/§9). If host
   churn proves common, "migrate authority to another client" (whoever has the freshest snapshot becomes
   host) is a large future feature — **out of first cut.**

---

## Decision log

Settled decisions this doc commits to (deviate only with a new doc):

1. **Supabase Realtime Broadcast as a dumb relay; host-authoritative sim in the room creator's browser.**
   Pages is static-only, so "host" = logical authority, never a listening socket (§2).
2. **`broadcast.self=false`; the host applies its own plays locally and never loops them back.** The
   shared code is the resolver, not the apply path. (Rejects the `self:true` loopback, which would cause
   real rollback of a newer play by a stale echo.) (§3.1/§4.3/§5.2)
3. **Absolute-state snapshots, applied by field-level MERGE (never replace), with node strip/slot-rebind.**
   A blind replace would wipe a client's own hand. (§6.1)
4. **A monotonic `seq` on every board-advancing broadcast (`apply_snapshot`, `hand`, `enemy_phase`), plus
   a resync watchdog + seq-gap recovery + `acks`-in-snapshot.** Load-bearing because the relay is
   fire-and-forget and unordered across senders — not speculative insurance. (§4.7/§9)
5. **An explicit combat-start barrier** (`combat_ready` → authority replies snapshot + hand → open play);
   on a CLIENT, `_start_combat` builds the board but does not draw or advance phase. (§4.7/§8.2)
6. **Client-generated `peer_id` UUID** as the seat-ownership primitive on an anonymous channel (assign,
   dedup, reclaim-on-reconnect, per-action authorization). (§4.6)
7. **Authority is the sole RNG roller;** seeded RNG is an optional debugging nicety, not a correctness or
   replay dependency. (§7f)
8. **Fixed 3-enemy line;** party size + composition scale via additive `enemy_scale` (damped damage, full
   HP), tuned by the Monte-Carlo bot sim. M≠3 deferred. (§7a/§8.3)
9. **Per-seat Ready replaces `_on_end_turn`;** it discards that seat's hand *unconditionally*
   (`retain_block` is a block-only flag at :333, not a hand-discard gate). (§5.4)
10. **Hidden hands are soft** (app-level display gate on a shared channel); true privacy = per-seat
    channel, deferred. (§5.6/§6.3/§12)
11. **Public `<REF>`/`<ANON>` in the shipped PCK; friends-only threat model;** hardening (private channels
    + RLS) is an additive later upgrade. (§4.1/§10)
12. **No new export preset / deploy sed;** `run/main_scene` → `main_menu.tscn`, one PCK, `Net` autoload
    inert unless dialed. (§3.4/§10)
13. **SOLO is behavior-equivalent (same resulting state + screenshot), not literally byte-identical** —
    §7a/§7b touch shared code. Only §7e's mode-gated commit points are an untouched SOLO path. (§1/§7)
14. **The overworld stays single-player;** it shares only the `_make_dwarf` factory. (§1/§8.1)

**Changes from review:** this revision incorporated an adversarial, source-verified review pass (netcode
+ Supabase-Realtime and pragmatic tech-lead lenses, cross-checked against combat.gd / card_db.gd /
overworld.gd / deploy-pages.yml / project.godot). All blockers and majors were applied — the loss-
recovery/resync layer, the `self:false` host-self-apply model, merge-not-replace snapshot apply, the
combat-start barrier, per-seat `peer_id` identity, uniform `seq` scope, the fixed-3 enemy trim, and the
milestone re-cut (M0.5 + M3a/M3b split + hidden hands pulled into M3). Corrected file:line anchors
(taunt cooldown :611 not :607; `_check_end` iterates arrays :831–838 rather than calling `.size()`;
`active_idx = _first_living_party()` at :351 enumerated as a seam), the message-budget arithmetic
(per-recipient ~3(N-1)/play), the heartbeat-timeout claim, and the `retain_block`/hand-discard
description.

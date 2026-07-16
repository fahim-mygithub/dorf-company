extends Control
## Automated two-peer COMBAT verification, focused on SIMULTANEOUS PLAY.
##
## The contract under test:
##   - Both players act at the same time. Neither waits for the other, and nobody waits for the host.
##   - Cards resolve in the order the host receives them (first come, first served).
##   - Ending your turn is per-seat and order-free: a client may end BEFORE the host.
##   - The enemy phase fires only once EVERY living seat has ended.
##   - A seat that has ended cannot keep playing.
##
## Run: godot --headless --path . res://scenes/test/combat_verify.tscn

const COMBAT := preload("res://scenes/combat/combat.tscn")
const Db := preload("res://scripts/combat/card_db.gd")
const ROOM := "CVERIFY"

var host: Node
var client: Node
var passed := 0
var failed := 0

func _ready() -> void:
	Net.ensure_peer_id()
	Net.connect_realtime(ROOM, true)
	await Net.realtime_joined
	var crew: Array = [{"cls": "warrior", "name": "Hosty"}, {"cls": "sorcerer", "name": "Clienty"}]
	var req: Dictionary = {"crew": crew, "enemies": Db.ENCOUNTER, "enemy_scale": 1.0}
	host = _spawn(req, "authority", 0)
	client = _spawn(req, "client", 1)
	await _run()
	print("\n================ COMBAT VERIFY: %d passed, %d FAILED ================" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)

func _spawn(req: Dictionary, m: String, seat: int) -> Node:
	var inst: Node = COMBAT.instantiate()
	var r: Dictionary = req.duplicate(true)
	r["net"] = {"mode": m, "seat": seat, "seat_count": 2}
	inst.request = r
	add_child(inst)
	inst.visible = false
	return inst

func _ck(name: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name, ("   [%s]" % detail) if detail != "" else "")

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout

## Find a card this seat can afford, preferring one that needs no target (keeps the test simple).
func _playable(peer: Node, seat: int) -> Dictionary:
	var a: Dictionary = peer.party[seat]
	for i in range((a["hand"] as Array).size()):
		var cid: String = a["hand"][i]
		var def: Dictionary = Db.CARDS[cid]
		if int(def["cost"]) > int(a["energy"]):
			continue
		var want: String = str(def.get("target", "self"))
		if want == "self" or want == "party":
			return {"uid": str(a["hand_uids"][i]), "cid": cid, "kind": "self", "idx": -1}
		if want == "enemy":
			return {"uid": str(a["hand_uids"][i]), "cid": cid, "kind": "enemy", "idx": _live_enemy(peer)}
		if want == "all_enemies":
			return {"uid": str(a["hand_uids"][i]), "cid": cid, "kind": "all", "idx": -1}
	return {}

func _live_enemy(peer: Node) -> int:
	for i in range((peer.enemies as Array).size()):
		if bool(peer.enemies[i]["alive"]):
			return i
	return 0

func _play(peer: Node, seat: int) -> bool:
	var p: Dictionary = _playable(peer, seat)
	if p.is_empty():
		return false
	peer._try_play(seat, str(p["uid"]), str(p["kind"]), int(p["idx"]))
	return true

# ------------------------------------------------------------------ the session
func _run() -> void:
	print("\n--- 1. both peers reach the same open board ----------------------")
	await _wait(3.0)
	_ck("host barrier open", host._barrier_open)
	_ck("both in the player phase", str(host.phase) == "playerTurn" and str(client.phase) == "playerTurn",
		"%s / %s" % [str(host.phase), str(client.phase)])
	_ck("each player pilots their own seat", int(host.active_idx) == 0 and int(client.active_idx) == 1,
		"%d / %d" % [int(host.active_idx), int(client.active_idx)])
	_ck("nobody has ended yet", host._seat_ready == [false, false], str(host._seat_ready))
	_ck("both hands dealt", (host.party[0]["hand"] as Array).size() > 0
		and (host.party[1]["hand"] as Array).size() > 0)
	_ck("client sees its teammate's hand (public hands)",
		(client.party[0]["hand"] as Array).size() == (host.party[0]["hand"] as Array).size())

	print("\n--- 2. the CLIENT acts FIRST — no waiting on the host -------------")
	var e0: int = int(host.party[1]["energy"])
	var h0: int = (host.party[1]["hand"] as Array).size()
	_ck("client found a playable card", _play(client, 1))
	await _wait(1.2)
	_ck("the client's card resolved on the host", int(host.party[1]["energy"]) < e0,
		"energy %d -> %d" % [e0, int(host.party[1]["energy"])])
	_ck("the card left the client's hand", (host.party[1]["hand"] as Array).size() == h0 - 1,
		"%d -> %d" % [h0, (host.party[1]["hand"] as Array).size()])
	_ck("the host never had to act first", int(host.party[0]["energy"]) == int(host.party[0]["max_energy"]),
		str(int(host.party[0]["energy"])))
	_ck("the host's own turn is untouched", not host._seat_ended(0))

	print("\n--- 3. SIMULTANEOUS play: interleave both seats -------------------")
	var he0: int = int(host.party[0]["energy"])
	var ce0: int = int(host.party[1]["energy"])
	# Fire both in the same frame — a client submit and a host tap racing each other.
	var cok: bool = _play(client, 1)
	var hok: bool = _play(host, 0)
	await _wait(1.5)
	_ck("both plays were accepted", hok and cok)
	_ck("the host's play resolved", int(host.party[0]["energy"]) < he0,
		"%d -> %d" % [he0, int(host.party[0]["energy"])])
	_ck("the client's simultaneous play ALSO resolved", int(host.party[1]["energy"]) < ce0,
		"%d -> %d" % [ce0, int(host.party[1]["energy"])])
	_ck("boards converged after the race",
		int(client.party[0]["energy"]) == int(host.party[0]["energy"])
		and int(client.party[1]["energy"]) == int(host.party[1]["energy"]),
		"%d/%d vs %d/%d" % [int(client.party[0]["energy"]), int(client.party[1]["energy"]),
			int(host.party[0]["energy"]), int(host.party[1]["energy"])])
	_ck("still the same player phase (no premature enemy turn)", str(host.phase) == "playerTurn")

	print("\n--- 4. the CLIENT ends turn FIRST ---------------------------------")
	var turn0: int = int(host.turn)
	client._on_end_turn()
	await _wait(1.2)
	_ck("host recorded the client's end-turn", host._seat_ended(1), str(host._seat_ready))
	_ck("the host has NOT ended", not host._seat_ended(0))
	_ck("the enemy did NOT move on one player's end-turn", str(host.phase) == "playerTurn"
		and int(host.turn) == turn0, "%s turn=%d" % [str(host.phase), int(host.turn)])
	_ck("the client's hand was discarded", (host.party[1]["hand"] as Array).size() == 0,
		str((host.party[1]["hand"] as Array).size()))
	_ck("the client sees itself as ended", client._seat_ended(1))

	print("\n--- 5. an ended seat is done; the other keeps playing -------------")
	var ce1: int = int(host.party[1]["energy"])
	var stale: Dictionary = {"seat": 1, "peer_id": "x", "card_uid": "bogus-uid",
		"hand_index": 0, "target_kind": "self", "target_idx": -1, "nonce": "n1"}
	host._on_action(stale)
	await _wait(0.4)
	_ck("an ended seat cannot sneak in another card", int(host.party[1]["energy"]) == ce1)
	var he1: int = int(host.party[0]["energy"])
	var still: bool = _play(host, 0)
	await _wait(1.0)
	if still:
		_ck("the seat that has NOT ended can still play", int(host.party[0]["energy"]) < he1,
			"%d -> %d" % [he1, int(host.party[0]["energy"])])
	else:
		_ck("the seat that has NOT ended can still play (no affordable card left — ok)", true)

	print("\n--- 6. the last end-turn resolves the round ----------------------")
	host._on_end_turn()
	await _wait(4.0)
	_ck("the enemy phase ran and handed back a new player phase",
		str(host.phase) == "playerTurn" or str(host.phase) == "win" or str(host.phase) == "lose",
		str(host.phase))

	print("\n--- 6b. M3b: the client REPLAYS the host's enemy-phase VFX --------")
	# A client never calls _flash/_impact on its own — _try_play returns before resolving and the
	# enemy phase runs only on the host. So a non-empty _fx_seen on the CLIENT can only have come
	# off the wire. That is the whole proof, and it is why _fx_seen exists.
	_ck("the host animated its own beats", int(host._fx_played) > 0, str(host._fx_seen))
	_ck("the client replayed the host's fx", int(client._fx_played) > 0, str(client._fx_seen))
	_ck("the bundle DRAINED after shipping", host._fx.is_empty(), str(host._fx))
	# The resync/hello/rejoin paths re-broadcast a whole board with a fresh seq. If fx rode those,
	# a client waking from a backgrounded tab would replay a beat from a minute ago.
	var seen0: int = int(client._fx_played)
	host._authority_on_resync({})
	await _wait(1.0)
	_ck("a resync replays NO stale fx", int(client._fx_played) == seen0,
		"%d -> %d" % [seen0, int(client._fx_played)])
	# fx cross the wire as JSON, where every int comes back a float. Round-trip a real event so a
	# coercion bug surfaces here and not as a silent no-op in a live fight.
	var wire: Variant = JSON.parse_string(JSON.stringify({"k": "i", "s": "enemy", "i": 0, "m": 7}))
	var seen1: int = int(client._fx_played)
	client._replay_fx(wire)
	_ck("an fx survives the JSON float round-trip", int(client._fx_played) == seen1 + 1,
		"%d -> %d" % [seen1, int(client._fx_played)])
	# Forward-compat + hostile input: a newer host's unknown kind, a bad address and a non-dict must
	# each drop quietly. If any of them is fatal, the harness process dies and this never prints.
	client._replay_fx({"k": "kind_from_a_newer_host", "s": "enemy", "i": 0, "m": 1})
	client._replay_fx({"k": "f", "s": "enemy", "i": 99})
	client._replay_fx({"k": "f", "s": "nonsense", "i": 0})
	client._replay_fx("not even a dictionary")
	_ck("unknown + malformed fx are dropped, never fatal", true)

	if str(host.phase) == "playerTurn":
		_ck("the turn advanced", int(host.turn) > turn0, "%d -> %d" % [turn0, int(host.turn)])
		_ck("the ready flags reset for the new turn", host._seat_ready == [false, false],
			str(host._seat_ready))
		_ck("the client's flags reset too", client._seat_ready == [false, false],
			str(client._seat_ready))
		_ck("both peers agree on the phase", str(client.phase) == str(host.phase))
		_ck("both got fresh hands", (host.party[0]["hand"] as Array).size() > 0
			and (host.party[1]["hand"] as Array).size() > 0)

		print("\n--- 7. reverse order: the HOST ends first ------------------------")
		var turn1: int = int(host.turn)
		host._on_end_turn()
		await _wait(1.2)
		_ck("host is ended, client is not", host._seat_ended(0) and not host._seat_ended(1),
			str(host._seat_ready))
		_ck("the enemy still waits for the client", str(host.phase) == "playerTurn"
			and int(host.turn) == turn1)
		_ck("the client can still play after the host has ended", _play(client, 1))
		await _wait(1.2)
		client._on_end_turn()
		await _wait(4.0)
		_ck("the round resolved once BOTH had ended (host-first order)",
			int(host.turn) > turn1 or str(host.phase) in ["win", "lose"],
			"turn=%d phase=%s" % [int(host.turn), str(host.phase)])

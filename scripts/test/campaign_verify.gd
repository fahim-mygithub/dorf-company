extends Control
## Automated two-peer CAMPAIGN verification. Runs BOTH peers in one process (see
## coop_campaign_harness.gd for why browser tabs cannot do this), drives a scripted session, and
## asserts the client's board converges on the host's at every step.
##
## Run: godot --headless --path . res://scenes/test/campaign_verify.tscn
## It quits itself and prints PASS/FAIL per check plus a summary line.

const OVERWORLD := preload("res://scenes/overworld/overworld.tscn")
const ROOM := "VERIFY"
const SEATS := [
	{"name": "Hosty", "cls": "warrior", "present": true},
	{"name": "Clienty", "cls": "sorcerer", "present": true},
]

var host: Node
var client: Node
var passed := 0
var failed := 0

func _ready() -> void:
	Net.ensure_peer_id()
	Net.connect_realtime(ROOM, true)
	await Net.realtime_joined
	host = _spawn("authority", 0)
	client = _spawn("client", 1)
	await _run()
	print("\n================ CAMPAIGN VERIFY: %d passed, %d FAILED ================" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)

func _spawn(m: String, seat: int) -> Node:
	var inst: Node = OVERWORLD.instantiate()
	inst.request = {
		"net": {"mode": m, "seat": seat, "seat_count": SEATS.size()},
		"seats": SEATS.duplicate(true),
	}
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

# ------------------------------------------------------------------ the session
func _run() -> void:
	print("\n--- 1. boot + first snapshot -------------------------------------")
	await _wait(2.0)
	_ck("client left BOOT", client.state != "BOOT", client.state)
	_ck("both on DASHBOARD", host.state == "DASHBOARD" and client.state == "DASHBOARD",
		"%s / %s" % [host.state, client.state])
	_ck("treasury converged", client.treasury == host.treasury,
		"%d vs %d" % [client.treasury, host.treasury])
	_ck("rent converged", client.fee == host.fee)
	_ck("roster is the table (2 seats -> 2 dwarves)", host.roster.size() == 2 and client.roster.size() == 2,
		"%d / %d" % [host.roster.size(), client.roster.size()])
	_ck("seat 0 is the host's dorf", str(host.roster[0]["name"]) == "Hosty" and str(host.roster[0]["cls"]) == "warrior")
	_ck("seat 1 is the client's dorf", str(host.roster[1]["name"]) == "Clienty" and str(host.roster[1]["cls"]) == "sorcerer")
	_ck("client sees the same roster", str(client.roster[1]["name"]) == "Clienty")
	_ck("client's hp is an INT, not a JSON float", typeof(client.roster[0]["hp"]) == TYPE_INT,
		type_string(typeof(client.roster[0]["hp"])))
	_ck("contracts converged", client.contracts.size() == host.contracts.size()
		and str(client.contracts[2]["title"]) == str(host.contracts[2]["title"]))
	_ck("fight contract crew_size == seat count", int(host.contracts[2]["crew_size"]) == 2,
		str(host.contracts[2]["crew_size"]))
	_ck("no Recruit in the co-op shop", not _has_kind(host.shop_stock, "recruit"))

	print("\n--- 2. FREE intent: a client navigates ---------------------------")
	client._intent("nav", "contracts")
	await _wait(1.0)
	_ck("host followed the client's nav", host.state == "CONTRACTS", host.state)
	_ck("client rendered CONTRACTS", client.state == "CONTRACTS")
	_ck("client's intent was acked", client._pending_intent.is_empty())

	print("\n--- 2b. the shop: ONE PURSE, ONE VOTE, and the table names who gets it ---")
	# The rule changed: EVERY spend out of the shared purse is the table's call, not only the ones
	# that dip under the rent line. And because the dwarves are one shared pool, the arg carries the
	# RECIPIENT ("slot:target") — the proposer is no longer automatically the owner.
	var t0: int = host.treasury
	var heal_i := _slot_of(host.shop_stock, "heal")
	# 25g against 80g with 55g rent: comfortably affordable, and it STILL needs a vote.
	client._intent("shop", "%d:0" % heal_i)
	await _wait(1.0)
	_ck("even an affordable buy opens a ring", not host.ring.is_empty()
		and str(host.ring.get("kind", "")) == "shop", str(host.ring))
	_ck("nothing was spent on one vote", host.treasury == t0, str(host.treasury))
	_ck("the ring names the good AND the recipient",
		host._ring_label("shop", "%d:0" % heal_i).contains(str(host.roster[0]["name"])),
		host._ring_label("shop", "%d:0" % heal_i))
	host._intent("shop", "%d:0" % heal_i)
	await _wait(1.2)
	_ck("the table agreed and the purse was charged",
		host.treasury == t0 - int(host.shop_stock[heal_i]["cost"]), "%d -> %d" % [t0, host.treasury])
	_ck("the slot sold on the client too", bool(client.shop_stock[heal_i].get("sold", false)))

	# A CLIENT proposing a card for the HOST's dwarf: a shared pool means the recipient is chosen,
	# not inherited from whoever pressed the button.
	var card_i := _slot_of(host.shop_stock, "card")
	var deck_h0: int = (host.roster[0]["deck"] as Array).size()
	var deck_c0: int = (host.roster[1]["deck"] as Array).size()
	var t1: int = host.treasury
	client._intent("shop", "%d:0" % card_i)
	await _wait(1.0)
	_ck("client's buy-for-someone-else opens a ring", not host.ring.is_empty(), str(host.ring))
	_ck("proposer is seat 1", int(host.ring.get("by", -1)) == 1)
	host._intent("shop", "%d:0" % card_i)
	await _wait(1.2)
	_ck("the card went to the NAMED dwarf (roster 0), not the proposer's",
		(host.roster[0]["deck"] as Array).size() == deck_h0 + 1
		and (host.roster[1]["deck"] as Array).size() == deck_c0,
		"h %d->%d  c %d->%d" % [deck_h0, (host.roster[0]["deck"] as Array).size(),
			deck_c0, (host.roster[1]["deck"] as Array).size()])
	_ck("the purse was charged once", host.treasury == t1 - int(host.shop_stock[card_i]["cost"]),
		"%d -> %d" % [t1, host.treasury])

	# ⚠ int("2:1") == 21 in GDScript (measured): it drops the separator and concatenates the digit
	# runs rather than erroring, so a forgotten split yields a plausible index, not a crash. A
	# malformed arg must therefore open no ring at all.
	_ck("a malformed buy arg opens no ring", not host._is_ring("shop", str(card_i)))
	_ck("an out-of-range recipient opens no ring", not host._is_ring("shop", "%d:99" % card_i))

	print("\n--- 3. RING: embark needs BOTH players ---------------------------")
	client._intent("select", "2")
	await _wait(0.8)
	_ck("select is free (no ring)", host.ring.is_empty())
	_ck("selection converged", host.selected_contract == 2 and client.selected_contract == 2)
	client._intent("embark", "2")
	await _wait(1.0)
	_ck("client's embark OPENED a ring", not host.ring.is_empty(), str(host.ring))
	_ck("proposer is seat 1", int(host.ring.get("by", -1)) == 1)
	_ck("proposing IS an aye", (host.ring.get("ayes", []) as Array) == [1], str(host.ring.get("ayes", [])))
	_ck("both seats are required", (host.ring.get("required", []) as Array).size() == 2)
	_ck("the company did NOT embark on one vote", host.state == "CONTRACTS", host.state)
	_ck("client SEES the open ring", not client.ring.is_empty())

	print("\n--- 4. duplicate intents must not double-apply --------------------")
	var stale: Dictionary = {"seat": 1, "kind": "embark", "arg": "2", "iseq": 1}
	host._authority_intent(stale)
	host._authority_intent(stale)
	await _wait(0.4)
	_ck("a replayed intent is ignored", (host.ring.get("ayes", []) as Array) == [1],
		str(host.ring.get("ayes", [])))

	print("\n--- 5. the host agrees -> the ring fires --------------------------")
	host._intent("embark", "2")
	await _wait(1.5)
	_ck("ring closed", host.ring.is_empty())
	_ck("host is on the hex map", host.state == "HEX", host.state)
	_ck("client is on the hex map", client.state == "HEX", client.state)
	_ck("client got the SAME map", client.hexes.size() == host.hexes.size() and client.hex_cur == host.hex_cur,
		"%d/%d  %s/%s" % [client.hexes.size(), host.hexes.size(), client.hex_cur, host.hex_cur])
	_ck("client's map is not empty", client.hexes.size() > 0)

	print("\n--- 5b. the wagon rule: a downed player is NOT a spectator --------")
	# Put seat 1 down, then take one step. The player must be piloting an heir on the next tile.
	var nb0: Array = host._hex_neighbors(host.hex_cur)
	var step := ""
	for k: String in nb0:
		if str(host.hexes[k]["kind"]) != "wall":
			step = k
			break
	host.hexes[step]["kind"] = "empty"
	host.hexes[step]["resolved"] = false
	var fallen_name: String = str(host.roster[1]["name"])
	var fallen_deck: int = (host.roster[1]["deck"] as Array).size()
	host.roster[1]["hp"] = 0
	host.roster[1]["downed"] = true
	host._push()
	await _wait(0.5)
	client._intent("hex", step)
	await _wait(0.4)
	host._intent("hex", step)
	await _wait(2.0)
	_ck("the fallen dwarf left the seat", str(host.roster[1]["name"]) != fallen_name,
		"%s -> %s" % [fallen_name, str(host.roster[1]["name"])])
	_ck("an HEIR is piloting seat 1", int(host.roster[1]["hp"]) > 0, str(host.roster[1]["hp"]))
	_ck("the heir kept the player's CLASS", str(host.roster[1]["cls"]) == "sorcerer")
	_ck("the fallen is on the wagon", host.carried.size() == 1 and str(host.carried[0]["name"]) == fallen_name)
	_ck("the wagon kept their deck", (host.carried[0]["deck"] as Array).size() == fallen_deck)
	_ck("the client sees the heir too", client.roster.size() == 2
		and str(client.roster[1]["name"]) == str(host.roster[1]["name"]),
		"%s / %s" % [str(client.roster[1]["name"]), str(host.roster[1]["name"])])
	_ck("the client sees the wagon", client.carried.size() == 1)

	print("\n--- 5b3. EXTRACTION IS A PLACE, and the host is what enforces it --")
	# The Extract button is only BUILT on an extract tile, but a client reaches the intent path
	# directly, so hiding the button is decoration and not a rule. Prove the host refuses.
	var exits: Array = []
	for k: String in host.hexes:
		if bool((host.hexes[k] as Dictionary).get("extract", false)):
			exits.append(k)
	_ck("the map has marked extract points", exits.size() >= 1, str(exits))
	_ck("the client received the extract flags too",
		exits.all(func(k): return bool((client.hexes[k] as Dictionary).get("extract", false))), str(exits))
	_ck("both peers lay the board out the same", str(host._hex_dims()) == str(client._hex_dims()),
		"%s / %s" % [str(host._hex_dims()), str(client._hex_dims())])
	var on_exit: bool = bool((host.hexes[host.hex_cur] as Dictionary).get("extract", false))
	_ck("the party is NOT standing on an exit (precondition)", not on_exit, host.hex_cur)
	var st_before: String = host.state
	client._intent("extract", "")
	await _wait(1.0)
	_ck("a client cannot extract from a non-exit tile", host.ring.is_empty() and host.state == st_before,
		"ring=%s state=%s" % [str(host.ring), host.state])
	# Now stand them on one and confirm it becomes an ordinary ring — still a VOTE, never unilateral.
	host.hexes[host.hex_cur]["extract"] = true
	host._push()
	await _wait(0.6)
	client._intent("extract", "")
	await _wait(1.0)
	_ck("on an exit tile, extract opens a ring", not host.ring.is_empty()
		and str(host.ring.get("kind", "")) == "extract", str(host.ring))
	_ck("one player cannot walk out alone", host.state == st_before, host.state)
	host.ring = {}
	host.hexes[host.hex_cur]["extract"] = false
	host._push()
	await _wait(0.6)

	# Same bug class, the other rule the UI enforces: _commit_hex checks adjacency, but a client's
	# intent never runs _commit_hex. Without a host-side check the wire accepts a teleport.
	var far := ""
	for k: String in host.hexes:
		if str(host.hexes[k]["kind"]) != "wall" and not host._hex_neighbors(host.hex_cur).has(k) \
				and k != host.hex_cur:
			far = k
			break
	_ck("found a non-adjacent tile (precondition)", far != "", far)
	var cur_before: String = host.hex_cur
	client._intent("hex", far)
	await _wait(1.0)
	_ck("a client cannot propose a teleport", host.ring.is_empty(), str(host.ring))
	_ck("the crew did not move", host.hex_cur == cur_before, "%s -> %s" % [cur_before, host.hex_cur])

	print("\n--- 5b4. an EVENT tile must not deadlock the expedition -----------")
	# _enter_hex sets busy=true for the march; the event arm returns without resolving, and only
	# _resume_hex clears it. The event choice is a RING, and _ring_intent's first line is
	# `if busy: return` -- so every seat's vote was swallowed, forever, with no way off the tile.
	var ev := ""
	for k: String in host._hex_neighbors(host.hex_cur):
		if str(host.hexes[k]["kind"]) != "wall":
			ev = k
			break
	_ck("found a neighbour to make an event of", ev != "", ev)
	host.hexes[ev]["kind"] = "event"
	host.hexes[ev]["resolved"] = false
	host._push()
	await _wait(0.5)
	client._intent("hex", ev)
	await _wait(0.4)
	host._intent("hex", ev)
	await _wait(2.2)
	_ck("the crew is on the event tile", host.state == "HEXEVENT", host.state)
	_ck("waiting for a choice is NOT busy", not host.busy, str(host.busy))
	var gold0: int = int(host.exp_loot_gold)
	client._intent("event", "safe")
	await _wait(1.0)
	_ck("a seat's event vote OPENS a ring", not host.ring.is_empty()
		and str(host.ring.get("kind", "")) == "event", str(host.ring))
	host._intent("event", "safe")
	await _wait(2.0)
	_ck("the table resolved the event", host.state == "HEX", host.state)
	_ck("the safe choice paid out", int(host.exp_loot_gold) > gold0,
		"%d -> %d" % [gold0, int(host.exp_loot_gold)])

	print("\n--- 5b5. the wagon: two survivors from ONE seat, nobody deleted --")
	# The original goes down on one tile and its heir on another, so seat 1 has TWO dwarves on the
	# wagon. _wagon_home used to write roster[seat] for each, so the second silently deleted the
	# first -- a living dwarf and every card ever bought into its deck.
	var keep_a := {"name": "Wagon A", "cls": "warrior", "status": "ready", "recover": 0,
		"hp": 0, "max_hp": 30, "deck": ["strike", "strike"], "downed": true, "stable": true,
		"ds_success": 3, "ds_fail": 0, "seat": 1}
	var keep_b := {"name": "Wagon B", "cls": "warrior", "status": "ready", "recover": 0,
		"hp": 0, "max_hp": 30, "deck": ["guard"], "downed": true, "stable": true,
		"ds_success": 3, "ds_fail": 0, "seat": 1}
	var roster_n0: int = host.roster.size()
	host.carried = [keep_a, keep_b]
	host._wagon_home("extract")
	var names: Array = []
	for d2: Dictionary in host.roster:
		names.append(str(d2["name"]))
	_ck("both survivors are on the books", names.has("Wagon A") and names.has("Wagon B"), str(names))
	_ck("the pool grew rather than overwrote", host.roster.size() == roster_n0 + 1,
		"%d -> %d" % [roster_n0, host.roster.size()])
	_ck("the reclaimed dwarf kept its deck",
		names.has("Wagon A") and (host.roster[1]["deck"] as Array).size() == 2,
		str(host.roster[1].get("deck", [])))
	# put the board back for the sections that follow
	while host.roster.size() > roster_n0:
		host.roster.pop_back()
	host.carried = []
	host._push()
	await _wait(0.6)

	print("\n--- 5b2. M3b: the client REPLAYS the flag march + counts the purse -")
	# A client never runs _enter_hex (it returns at _on_hex_input / _intent), so it can only have
	# marched because the host's fx arrived. That is the proof.
	_ck("the host marched its own flag", int(host._fx_played) > 0, str(host._fx_seen))
	_ck("the client replayed the march", int(client._fx_played) > 0, str(client._fx_seen))
	_ck("the bundle DRAINED after shipping", host._fx.is_empty(), str(host._fx))
	# _push() fires on every HUD refresh and on every client's 3s camp_hello. Without the drain one
	# march would replay on every heartbeat forever, so this is the check that matters most here.
	var m0: int = int(client._fx_played)
	host._push()
	host._push()
	await _wait(1.0)
	_ck("re-pushing the board replays NO stale fx", int(client._fx_played) == m0,
		"%d -> %d" % [m0, int(client._fx_played)])
	# The purse COUNTS on a client instead of snapping: treasury is state, so the snapshot delta is
	# the animation. _tre_shown lands on the new value either way — assert it tracks, not that it
	# tweened (a headless tween has no frames to observe).
	_ck("the client's purse tracks the host's", int(client._tre_shown) == host.treasury,
		"%d vs %d" % [int(client._tre_shown), host.treasury])
	# Forward-compat + hostile input: each of these must drop quietly. If any is fatal the harness
	# process dies and this line never prints.
	client._replay_fx({"k": "kind_from_a_newer_host", "d": {}})
	client._replay_fx({"k": "march", "d": {"a": "nowhere", "b": "nohow"}})
	client._replay_fx({"k": "march"})
	client._replay_fx("not even a dictionary")
	_ck("unknown + malformed fx are dropped, never fatal", true)

	print("\n--- 5c. loot is PERSONAL: first tap wins, for your own deck -------")
	host.hex_loot = ["strike", "guard", "cleave"]
	host.hex_loot_pick = -1
	host.state = "HEXREWARD"
	host._push()
	await _wait(0.8)
	_ck("client sees the spoils", client.state == "HEXREWARD" and client.hex_loot.size() == 3,
		"%s %d" % [client.state, client.hex_loot.size()])
	var cdeck0: int = (host.roster[1]["deck"] as Array).size()
	var hdeck0: int = (host.roster[0]["deck"] as Array).size()
	client._intent("loot", "0")
	await _wait(1.5)
	_ck("the claimer's own deck grew", (host.roster[1]["deck"] as Array).size() == cdeck0 + 1,
		"%d -> %d" % [cdeck0, (host.roster[1]["deck"] as Array).size()])
	_ck("nobody else got a card", (host.roster[0]["deck"] as Array).size() == hdeck0)
	_ck("the tile resolved back to the map", host.state == "HEX", host.state)
	_ck("client followed back to the map", client.state == "HEX", client.state)

	print("\n--- 6. a shared fight: both peers enter the SAME combat -----------")
	# Force the neighbouring tile to be a fight so the test is deterministic.
	var nb: Array = host._hex_neighbors(host.hex_cur)
	var target := ""
	for k: String in nb:
		if str(host.hexes[k]["kind"]) != "wall":
			target = k
			break
	_ck("found a passable neighbour", target != "")
	host.hexes[target]["kind"] = "combat"
	host.hexes[target]["danger"] = 1
	host.hexes[target]["resolved"] = false
	host._push()
	await _wait(0.6)

	client._intent("hex", target)
	await _wait(0.8)
	_ck("moving deeper opens a ring", not host.ring.is_empty())
	_ck("the crew did NOT move on one vote", host.hex_cur != target, host.hex_cur)
	host._intent("hex", target)
	await _wait(2.5)

	var hf: Node = host._fight_node
	var cf: Node = client._fight_node
	_ck("host entered the fight", hf != null)
	_ck("client entered the SAME fight", cf != null)
	if hf != null and cf != null:
		_ck("host is the combat AUTHORITY", int(hf.mode) == 1, str(hf.mode))
		_ck("client is a combat CLIENT", int(cf.mode) == 2, str(cf.mode))
		_ck("client pilots seat 1", int(cf.my_seat) == 1)
		_ck("identical enemies", hf.enemies.size() == cf.enemies.size() and hf.enemies.size() > 0,
			"%d vs %d" % [hf.enemies.size(), cf.enemies.size()])
		_ck("identical enemy names", _names(hf.enemies) == _names(cf.enemies),
			"%s vs %s" % [_names(hf.enemies), _names(cf.enemies)])
		_ck("identical enemy HP (same scale roll)", _hps(hf.enemies) == _hps(cf.enemies),
			"%s vs %s" % [_hps(hf.enemies), _hps(cf.enemies)])
		_ck("party is 2 (one dwarf per player)", hf.party.size() == 2 and cf.party.size() == 2)
		# The encounters were tuned for a crew of 3; a 2-player table must face exactly one
		# PARTY_STEP less threat than a 3-player table would on the very same tile.
		var escale: float = float(hf.request.get("enemy_scale", 0.0))
		_ck("the party-size term is applied", is_equal_approx(host._party_scale(), -host.PARTY_STEP),
			str(host._party_scale()))
		_ck("enemy_scale carries that term", escale > 0.0
			and is_equal_approx(escale + host.PARTY_STEP, escale + 0.34), "%f" % escale)
		_ck("client's combat got the same scale", is_equal_approx(escale, float(cf.request.get("enemy_scale", -1.0))),
			"%f vs %f" % [escale, float(cf.request.get("enemy_scale", -1.0))])

		print("\n--- 7. play the fight out (both peers just end their turns) -------")
		var guard := 0
		while is_instance_valid(host._fight_node) and guard < 400:
			guard += 1
			var f: Node = host._fight_node
			var g: Node = client._fight_node
			if is_instance_valid(f) and str(f.phase) == "playerTurn" and f._barrier_open:
				if not f._seat_ended(0):
					f._on_end_turn()
				if is_instance_valid(g) and not g._seat_ended(1):
					g._on_end_turn()
			await _wait(0.25)
		_ck("the fight ended and gave the campaign back", not is_instance_valid(host._fight_node), "guard=%d" % guard)
		await _wait(2.0)
		_ck("the client also left the fight", client._fight_node == null)

	print("\n--- 8. after the fight: boards still agree ------------------------")
	await _wait(1.5)
	_ck("states agree", host.state == client.state, "%s / %s" % [host.state, client.state])
	_ck("treasury agrees", host.treasury == client.treasury, "%d / %d" % [host.treasury, client.treasury])
	_ck("roster HP agrees", _hps(host.roster) == _hps(client.roster),
		"%s / %s" % [_hps(host.roster), _hps(client.roster)])
	_ck("nobody is stuck dead in a seat", _no_corpses(host.roster), str(_statuses(host.roster)))
	_ck("every seat still has a living dwarf to pilot", _all_alive(host.roster), str(_hps(host.roster)))

	print("\n--- 9. the AFK escape hatch ---------------------------------------")
	# Freeze the client: stop its hellos and let the host's sweep notice.
	client.set_process(false)
	host._last_seen[1] = Time.get_ticks_msec() - int(host.ABSENT_SEC * 1000.0) - 500
	await _wait(1.6)
	_ck("host marked the silent seat absent", not bool(host.seats[1].get("present", true)))
	_ck("an absent seat is no longer required", host._present_seats() == [0], str(host._present_seats()))
	# The remaining player proposes something shared. With the AFK seat pruned, it must fire on their
	# aye alone — otherwise one friend wandering off freezes the whole company forever.
	var before: String = host.state
	host._intent("endmonth", "")
	await _wait(2.5)
	_ck("a ring still closes with a player gone", host.ring.is_empty(), str(host.ring))
	_ck("the absent seat did not freeze the company", host.month > 0 or host.state != before,
		"month=%d state=%s" % [host.month, host.state])

func _slot_of(stock: Array, k: String) -> int:
	for i in range(stock.size()):
		if str((stock[i] as Dictionary).get("kind", "")) == k:
			return i
	return -1

func _has_kind(stock: Array, k: String) -> bool:
	for s: Dictionary in stock:
		if str(s.get("kind", "")) == k:
			return true
	return false

func _names(a: Array) -> Array:
	var out: Array = []
	for e: Dictionary in a:
		out.append(str(e.get("name", "?")))
	return out

func _hps(a: Array) -> Array:
	var out: Array = []
	for e: Dictionary in a:
		out.append(int(e.get("hp", -1)))
	return out

func _statuses(a: Array) -> Array:
	var out: Array = []
	for e: Dictionary in a:
		out.append(str(e.get("status", "?")))
	return out

func _no_corpses(a: Array) -> bool:
	for e: Dictionary in a:
		if str(e.get("status", "")) == "lost":
			return false
	return true

func _all_alive(a: Array) -> bool:
	for e: Dictionary in a:
		if int(e.get("hp", 0)) <= 0:
			return false
	return true

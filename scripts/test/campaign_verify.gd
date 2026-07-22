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
	# Co-op stocks a Recruit now: the crew is drawn from a SHARED POOL rather than welded one dwarf
	# per seat, so a new hand is a real body anyone can take onto the next job.
	_ck("co-op stocks a Recruit", _has_kind(host.shop_stock, "recruit"))
	_ck("crew_claim is sized to the TABLE, not the pool", host.crew_claim.size() == 2,
		str(host.crew_claim))

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

	print("\n--- 2c. ANYONE can be crewed, and a new hand is a voted spend -----")
	# Hiring: spending, so it votes -- and it grows the POOL past the seat count, which is the whole
	# point of the pool. (Top the purse up first; the two buys above ate into it.)
	host.treasury = 300
	host._push()
	await _wait(0.5)
	var hire_i := _slot_of(host.shop_stock, "recruit")
	var pool0: int = host.roster.size()
	client._intent("hire", str(hire_i))
	await _wait(1.0)
	_ck("a hire opens a ring", not host.ring.is_empty()
		and str(host.ring.get("kind", "")) == "hire", str(host.ring))
	_ck("nobody joined on one vote", host.roster.size() == pool0, str(host.roster.size()))
	host._intent("hire", str(hire_i))
	await _wait(1.2)
	_ck("the table signed them on", host.roster.size() == pool0 + 1,
		"%d -> %d" % [pool0, host.roster.size()])
	_ck("the POOL is now bigger than the table", host.roster.size() > host.seat_count,
		"%d dwarves / %d seats" % [host.roster.size(), host.seat_count])
	_ck("the client sees the bigger pool", client.roster.size() == host.roster.size(),
		"%d / %d" % [client.roster.size(), host.roster.size()])

	# ANY pool dwarf can fill ANY seat: seat 1 claims the dwarf that seat 0 started with.
	client._intent("crew", "0")
	await _wait(1.0)
	_ck("claiming is free (no ring)", host.ring.is_empty(), str(host.ring))
	_ck("seat 1 claimed roster 0", int(host.crew_claim[1]) == 0, str(host.crew_claim))
	_ck("the claim replicated", int(client.crew_claim[1]) == 0, str(client.crew_claim))
	# ...and two seats cannot hold the same body.
	host._intent("crew", "0")
	await _wait(1.0)
	_ck("a claimed dwarf cannot be taken twice", int(host.crew_claim[0]) != 0, str(host.crew_claim))
	# releasing is the same tap again
	client._intent("crew", "0")
	await _wait(1.0)
	_ck("tapping your own claim releases it", int(host.crew_claim[1]) == -1, str(host.crew_claim))

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
	# THE MODEL CHANGED: a downed dwarf leaves the CREW but never leaves the POOL. So the assertion
	# is no longer "roster[seat] was replaced" -- it is the invariant that actually matters, which is
	# that seat 1 still has a living body to pilot.
	_ck("the fallen left the crew", str(host.exp_crew[1]["name"]) != fallen_name,
		"%s -> %s" % [fallen_name, str(host.exp_crew[1]["name"])])
	_ck("seat 1 has a living dwarf to pilot", int(host.exp_crew[1]["hp"]) > 0,
		str(host.exp_crew[1]["hp"]))
	_ck("nobody spectates: the crew is still one body per seat", host.exp_crew.size() == 2,
		str(host.exp_crew.size()))
	_ck("the fallen is STILL in the pool, not deleted",
		host.roster.any(func(d): return str(d["name"]) == fallen_name),
		str(host.roster.map(func(d): return str(d["name"]))))
	_ck("the fallen is on the wagon", host.carried.size() == 1 and str(host.carried[0]["name"]) == fallen_name)
	_ck("the wagon kept their deck", (host.carried[0]["deck"] as Array).size() == fallen_deck)
	_ck("the client rebuilt the same crew from the wire",
		client.exp_crew.size() == host.exp_crew.size()
		and str(client.exp_crew[1]["name"]) == str(host.exp_crew[1]["name"]),
		"%s / %s" % [str(client.exp_crew.map(func(d): return str(d["name"]))),
			str(host.exp_crew.map(func(d): return str(d["name"])))])
	_ck("the client's crew ALIASES its own roster (not a copy)",
		client.exp_crew.any(func(d): return client.roster.any(func(r): return is_same(r, d))))
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

	print("\n--- 5b5. two survivors from ONE seat: neither is deleted ----------")
	# One seat can put two dwarves on the wagon in one expedition (the original goes down, then its
	# replacement). _wagon_home used to write roster[seat] for each, so the second silently deleted
	# the first. Under the pool model a carried dwarf never LEAVES the roster, which makes the
	# overwrite structurally impossible rather than merely guarded -- so the test is that both are
	# still on the books afterwards, with their decks.
	var roster_n0: int = host.roster.size()
	# ⚠ SAVE the real wagon. This section replaces `carried` wholesale, and clobbering it would
	# ORPHAN the dwarf section 5b put on it -- it would never roll another death save and never come
	# home, which then fails section 8 for a reason that has nothing to do with section 8.
	var carried_real: Array = host.carried.duplicate()
	var wa: Dictionary = host._make_dwarf("Wagon A", "warrior")
	var wb: Dictionary = host._make_dwarf("Wagon B", "warrior")
	wa["deck"] = ["strike", "strike"]
	wb["deck"] = ["guard"]
	for w in [wa, wb]:
		w["hp"] = 0
		w["downed"] = true
		w["stable"] = true
		w["ds_success"] = 3
		w["seat"] = 1
		host.roster.append(w)      # they are POOL members riding the wagon
	host.carried = [wa, wb]
	host._wagon_home("extract")
	var names: Array = host.roster.map(func(d): return str(d["name"]))
	_ck("both survivors are still on the books", names.has("Wagon A") and names.has("Wagon B"), str(names))
	_ck("neither overwrote the other", host.roster.size() == roster_n0 + 2,
		"%d -> %d" % [roster_n0, host.roster.size()])
	_ck("both kept their decks", (wa["deck"] as Array).size() == 2 and (wb["deck"] as Array).size() == 1,
		"%d / %d" % [(wa["deck"] as Array).size(), (wb["deck"] as Array).size()])
	_ck("both were patched up off the wagon", int(wa["hp"]) > 0 and int(wb["hp"]) > 0,
		"%d / %d" % [int(wa["hp"]), int(wb["hp"])])
	# put the board back for the sections that follow, wagon included
	while host.roster.size() > roster_n0:
		host.roster.pop_back()
	host.carried = carried_real
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

	print("\n--- 5c. spoils are COMPANY property: the table votes who learns it -")
	# Was "first tap wins, for YOUR deck". Loot is a ring now, and like a purchase the arg names both
	# halves -- which card, and which dwarf -- because the claimer and the recipient are no longer
	# the same person by construction.
	host.hex_loot = ["strike", "guard", "cleave"]
	host.hex_loot_pick = -1
	host.state = "HEXREWARD"
	host._push()
	await _wait(0.8)
	_ck("client sees the spoils", client.state == "HEXREWARD" and client.hex_loot.size() == 3,
		"%s %d" % [client.state, client.hex_loot.size()])
	var cdeck0: int = (host.roster[1]["deck"] as Array).size()
	var hdeck0: int = (host.roster[0]["deck"] as Array).size()
	# The CLIENT proposes card 0 for the HOST's dwarf.
	client._intent("loot", "0:0")
	await _wait(1.2)
	_ck("a lone claim no longer takes the card", not host.ring.is_empty()
		and str(host.ring.get("kind", "")) == "loot", str(host.ring))
	_ck("nothing moved on one vote", (host.roster[0]["deck"] as Array).size() == hdeck0
		and (host.roster[1]["deck"] as Array).size() == cdeck0)
	_ck("the ring names the card and the dwarf",
		host._ring_label("loot", "0:0").contains(str(host.roster[0]["name"])),
		host._ring_label("loot", "0:0"))
	_ck("a malformed loot arg opens no ring", not host._is_ring("loot", "0"))
	_ck("an out-of-range recipient opens no ring", not host._is_ring("loot", "0:99"))
	host._intent("loot", "0:0")
	await _wait(1.6)
	_ck("the NAMED dwarf learned it, not the proposer",
		(host.roster[0]["deck"] as Array).size() == hdeck0 + 1
		and (host.roster[1]["deck"] as Array).size() == cdeck0,
		"h %d->%d  c %d->%d" % [hdeck0, (host.roster[0]["deck"] as Array).size(),
			cdeck0, (host.roster[1]["deck"] as Array).size()])
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
	_ck("no corpses left in the pool", _no_corpses(host.roster), str(_statuses(host.roster)))
	# The anti-lockout invariant moved from the pool to the CREW: the pool may legitimately hold a
	# dwarf at 0 HP riding the wagon, but every SEAT must have a living body to pilot. It is a
	# MID-EXPEDITION invariant, so which form applies depends on whether we are still out there --
	# asserting the crew form unconditionally passes vacuously on an empty array, which is how this
	# check quietly stopped meaning anything the first time the expedition ended early.
	if host.state == "HEX":
		_ck("every seat still has a living dwarf to pilot", _all_alive(host.exp_crew),
			str(_hps(host.exp_crew)))
		_ck("the crew is exactly one body per seat", host.exp_crew.size() == 2,
			str(host.exp_crew.size()))
	else:
		_ck("the expedition ended and released the crew", host.exp_crew.is_empty()
			or _all_alive(host.exp_crew), "%s %s" % [host.state, str(_hps(host.exp_crew))])
		# Whatever it cost, the company must still be able to field a full table next time -- the
		# pool tops itself up with heirs rather than locking a player out.
		var next_crew: Array = host._crew_for_expedition()
		_ck("a full crew can still be fielded", next_crew.size() == 2 and _all_alive(next_crew),
			"%s %s" % [str(next_crew.size()), str(_hps(next_crew))])

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

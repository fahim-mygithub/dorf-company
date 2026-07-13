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

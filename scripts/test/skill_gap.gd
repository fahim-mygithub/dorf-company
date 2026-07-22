extends Node
## SKILL-GAP RIG — a headless balance harness that drives the REAL combat.gd, not a re-implementation.
##
## WHY THIS EXISTS. CLAUDE.md cites a Monte-Carlo sim called `dorf_sim.py` for every balance number
## in this repo. It lived in a session scratchpad, was never committed, and is gone
## (`git log --all -- "*dorf_sim*"` returns nothing). Rebuilding it in Python would mean
## re-implementing the whole rules engine, and a balance number is only worth what the rules it came
## from are worth. `powers_verify.gd` already proves combat.tscn instantiates headless and invisible
## with an arbitrary crew and encounter, so we drive THAT instead. Every number here comes out of the
## code the player actually plays.
##
## WHAT IT MEASURES — the SKILL-EXPRESSION GAP. Each encounter is run under two bot policies:
##   GREEDY  — spend every point of energy on the biggest number, always at the weakest enemy.
##             Never blocks on purpose, never reads an intent, never sets up.
##   PLANNER — reads the SAME telegraphed intents the player can see, blocks the dwarf that is
##             actually about to be hit, focus-fires for kills, heals whoever is worst off.
##
## The planner gets NO hidden information: `_incoming()` reads `_enemy_move` / `_enemy_target`,
## which is exactly what the on-screen intent label already tells the player.
##
## The gap between the two is the claim under test. An encounter where GREEDY and PLANNER score the
## same is not a puzzle — there is nothing in it to play well or badly, and no amount of enemy_scale
## will change that. A wide gap means the fight rewards thinking.
##
## Both policies choose only among cards the ENGINE'S OWN `_can_play` predicate allows, so neither
## can cheat past cost, limiter or targeting rules. Neither fires Class Powers — deliberate, and a
## known floor under BOTH numbers rather than a bias between them.
##
## Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://scenes/test/skill_gap.tscn

const COMBAT := preload("res://scenes/combat/combat.tscn")
const Db := preload("res://scripts/combat/card_db.gd")

const RUNS := 30           # fights per (encounter x policy) cell
const TURN_CAP := 40       # a fight unresolved by here is a stall and is scored as a loss
const CREW := ["warrior", "cleric", "sorcerer"]
const TIME_SCALE := 60.0   # SceneTreeTimers obey time_scale -> combat's 0.45s beats cost ~7ms

## Every comp the shipped game can actually roll today (Db.ENCOUNTER_POOLS), at the scales the hex
## crawl actually reaches. Nothing invented — this is a measurement of what we already ship.
const CELLS := [
	{"name": "canonical brute/assassin/caster", "comp": ["brute", "assassin", "caster"], "scale": 1.0},
	{"name": "med  wolf/wolf/witch",            "comp": ["wolf", "wolf", "witch"],       "scale": 1.0},
	{"name": "med  warden/caster/wolf",         "comp": ["warden", "caster", "wolf"],    "scale": 1.0},
	{"name": "med  assassin/witch/wolf",        "comp": ["assassin", "witch", "wolf"],   "scale": 1.0},
	{"name": "high brute/witch/caster",         "comp": ["brute", "witch", "caster"],    "scale": 1.2},
	{"name": "high ogre/warden/witch",          "comp": ["ogre", "warden", "witch"],     "scale": 1.2},
	{"name": "high brute/witch/assassin",       "comp": ["brute", "witch", "assassin"],  "scale": 1.2},
	{"name": "high ogre/wolf/wolf",             "comp": ["ogre", "wolf", "wolf"],        "scale": 1.2},
	{"name": "hex  brute/witch/caster  @1.6",   "comp": ["brute", "witch", "caster"],    "scale": 1.6},
	{"name": "hex  ogre/warden/witch   @1.6",   "comp": ["ogre", "warden", "witch"],     "scale": 1.6},
	{"name": "hex  ogre/wolf/wolf      @2.0",   "comp": ["ogre", "wolf", "wolf"],        "scale": 2.0},
]


func _ready() -> void:
	Engine.time_scale = TIME_SCALE
	await _run()
	await _routes()
	get_tree().quit(0)


func _run() -> void:
	var t0: int = Time.get_ticks_msec()
	print("\n================ SKILL-GAP RIG ================")
	print("crew=%s   runs/cell=%d   time_scale=%.0f" % [", ".join(CREW), RUNS, TIME_SCALE])
	print("both policies restricted to combat.gd's own _can_play(); no Class Powers fired\n")
	print("%-33s | %-21s | %-21s | %s" % ["encounter", "GREEDY", "PLANNER", "GAP"])
	print("%-33s | %-21s | %-21s | %s" % ["", "win%  turns  hp_left", "win%  turns  hp_left", "win pp    hp"])
	print("-".repeat(104))

	var rows: Array = []
	for cell: Dictionary in CELLS:
		var g: Dictionary = await _cell(cell, "greedy")
		var p: Dictionary = await _cell(cell, "planner")
		var wgap: float = float(p["win"]) - float(g["win"])
		var hgap: float = float(p["hp_left"]) - float(g["hp_left"])
		rows.append({"name": cell["name"], "wgap": wgap, "hgap": hgap})
		print("%-33s | %4.0f%% %6.1f %7.1f | %4.0f%% %6.1f %7.1f | %+5.0fpp %+6.1f" % [
			cell["name"],
			float(g["win"]) * 100.0, float(g["turns"]), float(g["hp_left"]),
			float(p["win"]) * 100.0, float(p["turns"]), float(p["hp_left"]),
			wgap * 100.0, hgap])

	print("-".repeat(104))
	var mw := 0.0
	var mh := 0.0
	for r: Dictionary in rows:
		mw += float(r["wgap"])
		mh += float(r["hgap"])
	mw /= float(rows.size())
	mh /= float(rows.size())
	print("MEAN SKILL-EXPRESSION GAP:  %+.1f pp win rate    %+.1f HP preserved" % [mw * 100.0, mh])
	print("(party pool is %d HP — a gap of a few HP is noise, not skill)" % _party_pool())
	print("\n%d fights in %.1fs" % [CELLS.size() * RUNS * 2, (Time.get_ticks_msec() - t0) / 1000.0])
	print("==============================================\n")


func _party_pool() -> int:
	var t := 0
	for cid: String in CREW:
		t += int(Db.CLASSES[cid]["max_hp"])
	return t


## One (encounter x policy) cell. Both policies see the SAME seed sequence, so a difference between
## them is the policy and not the shuffle.
func _cell(cell: Dictionary, policy: String) -> Dictionary:
	var wins := 0
	var turns_sum := 0
	var hp_sum := 0
	for i: int in range(RUNS):
		seed(90210 + i)
		var r: Dictionary = await _fight(cell["comp"], float(cell["scale"]), policy)
		if bool(r["won"]):
			wins += 1
		turns_sum += int(r["turns"])
		hp_sum += int(r["hp_left"])
	return {
		"win": float(wins) / float(RUNS),
		"turns": float(turns_sum) / float(RUNS),
		"hp_left": float(hp_sum) / float(RUNS),
	}


func _fight(comp: Array, scale: float, policy: String, carried: Array = []) -> Dictionary:
	# `carried` lets an expedition chain chain HP between hexes the way the hex crawl really does.
	var crew: Array = []
	if carried.is_empty():
		for cid: String in CREW:
			crew.append({"cls": cid, "name": cid.capitalize()})
	else:
		crew = carried.duplicate(true)
	var c: Node = COMBAT.instantiate()
	c.request = {"crew": crew, "enemies": comp, "enemy_scale": scale}
	add_child(c)
	c.visible = false

	var guard := 0
	while str(c.phase) == "playerTurn" and guard < TURN_CAP:
		guard += 1
		_take_turn(c, policy)
		if str(c.phase) != "playerTurn":
			break
		var before: int = int(c.turn)
		c._on_end_turn()
		# _on_end_turn is a coroutine paced by SceneTreeTimers. Poll for the next player phase
		# rather than awaiting the call, so a fight that ends mid-phase cannot strand us.
		var spins := 0
		while int(c.turn) == before and str(c.phase) == "enemyTurn" and spins < 3000:
			spins += 1
			await get_tree().process_frame

	var won: bool = str(c.phase) == "win"
	var hp_left := 0
	var out_crew: Array = []
	for a: Dictionary in c.party:
		hp_left += maxi(0, int(a["hp"]))
		out_crew.append({"cls": str(a["cls"]), "name": str(a["name"]),
			"hp": maxi(0, int(a["hp"])), "max_hp": int(a["max_hp"])})
	c.queue_free()
	await get_tree().process_frame
	return {"won": won, "turns": guard, "hp_left": hp_left, "crew": out_crew}


# ============================================================ the expedition chain
## A single fight is not the unit of difficulty in this game — an EXPEDITION is. HP carries between
## hexes and the only healing is HEX_POST_FIGHT_HEAL (+5) after a won combat hex, so the question
## that actually matters is not "can the party win this fight" but "how many of these in a row".
## This replays overworld.gd's real scale math:
##   enemy_scale = 1 + (comp_scale-1) + (mod-1) + (danger_scale-1),  danger_scale = 1+(danger-1)*0.21
const HEX_POST_FIGHT_HEAL := 5
const DANGER_STEP := 0.21

const ROUTES := [
	{"name": "med contract  ·  6 hexes",   "tier": "med",  "mod": 1.00, "dangers": [1, 1, 2, 2, 3, 3]},
	{"name": "high contract ·  6 hexes",   "tier": "high", "mod": 1.00, "dangers": [1, 2, 2, 3, 3, 3]},
	{"name": "high + ELITE  ·  6 hexes",   "tier": "high", "mod": 1.50, "dangers": [1, 2, 2, 3, 3, 3]},
]


func _routes() -> void:
	print("\n================ EXPEDITION CHAIN ================")
	print("HP carries between hexes, +%d heal per won hex — the real unit of difficulty" % HEX_POST_FIGHT_HEAL)
	print("scale math replays overworld.gd _hex_combat(); %d expeditions per cell\n" % RUNS)
	print("%-28s | %-20s | %-20s | %s" % ["route", "GREEDY", "PLANNER", "GAP"])
	print("%-28s | %-20s | %-20s | %s" % ["", "cleared  wipe%  hp", "cleared  wipe%  hp", "hexes"])
	print("-".repeat(96))
	for r: Dictionary in ROUTES:
		var g: Dictionary = await _route(r, "greedy")
		var p: Dictionary = await _route(r, "planner")
		print("%-28s | %6.2f %6.0f%% %5.1f | %6.2f %6.0f%% %5.1f | %+5.2f" % [
			r["name"], float(g["cleared"]), float(g["wipe"]) * 100.0, float(g["hp"]),
			float(p["cleared"]), float(p["wipe"]) * 100.0, float(p["hp"]),
			float(p["cleared"]) - float(g["cleared"])])
	print("-".repeat(96))
	print("'cleared' = combat hexes survived out of 6; 'wipe%' = expeditions that lost the whole crew")
	print("==================================================\n")

	# The ablation runs on the route where the gap actually lives. On the med route both policies
	# clear 6/6, so there is nothing there to attribute.
	var route: Dictionary = ROUTES[1]
	print("================ ABLATION — which decision carries it? ================")
	print("route: %s   (the only route with a gap to attribute)\n" % route["name"])
	print("%-34s | %8s | %6s | %s" % ["policy", "cleared", "wipe%", "share of the planner's gain"])
	print("-".repeat(96))
	var blind: Dictionary = await _route(route, "blind")
	var base: Dictionary = await _route(route, "greedy")
	var full: Dictionary = await _route(route, "planner")
	var span: float = float(full["cleared"]) - float(base["cleared"])
	print("%-34s | %8.2f | %5.0f%% | %s" % ["blind (random targeting)", float(blind["cleared"]), float(blind["wipe"]) * 100.0, "below baseline"])
	print("%-34s | %8.2f | %5.0f%% | %s" % ["greedy = blind + aim at weakest", float(base["cleared"]), float(base["wipe"]) * 100.0, "baseline"])
	for lever: String in ["block", "focus", "heal"]:
		var r: Dictionary = await _route(route, lever)
		var share: float = 0.0 if is_zero_approx(span) else (float(r["cleared"]) - float(base["cleared"])) / span
		print("%-34s | %8.2f | %5.0f%% | %+.0f%%" % ["  + " + lever + " only", float(r["cleared"]), float(r["wipe"]) * 100.0, share * 100.0])
	print("%-34s | %8.2f | %5.0f%% | %s" % ["planner (all three)", float(full["cleared"]), float(full["wipe"]) * 100.0, "100%"])
	print("-".repeat(96))
	print("shares need not sum to 100%: the levers interact.")
	print("======================================================================\n")


func _route(r: Dictionary, policy: String) -> Dictionary:
	var cleared_sum := 0
	var wipes := 0
	var hp_sum := 0
	var pools: Array = Db.ENCOUNTER_POOLS.get(str(r["tier"]), [])
	var comp_scale: float = float((Db.ENCOUNTERS_BY_TIER[str(r["tier"])] as Dictionary)["scale"])
	for i: int in range(RUNS):
		seed(31337 + i)
		var crew: Array = []
		for cid: String in CREW:
			crew.append({"cls": cid, "name": cid.capitalize(),
				"hp": int(Db.CLASSES[cid]["max_hp"]), "max_hp": int(Db.CLASSES[cid]["max_hp"])})
		var cleared := 0
		for danger: int in r["dangers"]:
			var comp: Array = pools[randi() % pools.size()] if not pools.is_empty() else Db.ENCOUNTER
			var dscale: float = 1.0 + float(maxi(0, danger - 1)) * DANGER_STEP
			var escale: float = 1.0 + (comp_scale - 1.0) + (float(r["mod"]) - 1.0) + (dscale - 1.0)
			var res: Dictionary = await _fight(comp, escale, policy, crew)
			if not bool(res["won"]):
				break
			cleared += 1
			crew = res["crew"]
			for m: Dictionary in crew:
				if int(m["hp"]) > 0:
					m["hp"] = mini(int(m["max_hp"]), int(m["hp"]) + HEX_POST_FIGHT_HEAL)
		cleared_sum += cleared
		if cleared < (r["dangers"] as Array).size():
			wipes += 1
		var left := 0
		for m: Dictionary in crew:
			left += int(m["hp"])
		hp_sum += left
	return {
		"cleared": float(cleared_sum) / float(RUNS),
		"wipe": float(wipes) / float(RUNS),
		"hp": float(hp_sum) / float(RUNS),
	}


## Play one full player phase for every living dwarf.
func _take_turn(c: Node, policy: String) -> void:
	for seat: int in range(c.party.size()):
		var a: Dictionary = c.party[seat]
		if not bool(a["alive"]):
			continue
		var fuse := 0
		while fuse < 15:
			fuse += 1
			if str(c.phase) != "playerTurn":
				return
			# Threat is recomputed per card: _enemy_target reads live block, so blocking on the tank
			# genuinely re-aims a "tankiest" attacker. A planner that cached it would read a stale board.
			var threat: Dictionary = {} if policy == "greedy" else _incoming(c)
			var pick: Dictionary = _pick(c, seat, policy, threat)
			if pick.is_empty():
				break
			c._try_play(seat, str(pick["uid"]), str(pick["kind"]), int(pick["idx"]))


## What each dwarf is about to eat this enemy phase, read off the same telegraphed intents shown
## on screen. Not hidden information.
func _incoming(c: Node) -> Dictionary:
	var dmg: Dictionary = {}
	for i: int in range(c.party.size()):
		dmg[i] = 0
	for e: Dictionary in c.enemies:
		if not bool(e["alive"]):
			continue
		var mv: Dictionary = c._enemy_move(e)
		match str(mv["kind"]):
			"attack", "multi":
				var t: Dictionary = c._enemy_target(e)
				if t.is_empty():
					continue
				var s: int = int(t["slot"])
				dmg[s] = int(dmg[s]) + c._move_dmg(e, mv) * int(mv.get("hits", 1))
			"attack_all":
				for i: int in range(c.party.size()):
					if bool(c.party[i]["alive"]):
						dmg[i] = int(dmg[i]) + c._move_dmg(e, mv)
	return dmg


## Choose this dwarf's next card, or {} to stop.
func _pick(c: Node, seat: int, policy: String, threat: Dictionary) -> Dictionary:
	var a: Dictionary = c.party[seat]
	var best: Dictionary = {}
	var best_score := -1.0
	var hand: Array = a["hand"]
	for i: int in range(hand.size()):
		var cid: String = hand[i]
		var def: Dictionary = Db.CARDS[cid]
		if not c._can_play(a, cid, def):
			continue
		var sc: Dictionary = _score(c, seat, def, policy, threat)
		if sc.is_empty():
			continue
		if float(sc["score"]) > best_score:
			best_score = float(sc["score"])
			best = {"uid": a["hand_uids"][i], "kind": sc["kind"], "idx": sc["idx"]}
	# Declining a worthless play is part of the BLOCK lever's own discipline ("don't over-block"),
	# so it travels with that lever and not with the others — otherwise the ablation below would be
	# measuring this rule instead of the thing it is supposed to isolate.
	if _f(policy, "block") and best_score <= 0.0:
		return {}
	return best


## ABLATION. The planner adds three levers to greedy at once — blocking to the telegraph,
## focus-firing for kills, and healing the worst-off dwarf. Running each ALONE is the only way to
## say which one actually carries the skill expression. `planner` = all three; `greedy` = none.
func _f(policy: String, lever: String) -> bool:
	return policy == "planner" or policy == lever


func _score(c: Node, seat: int, def: Dictionary, policy: String, threat: Dictionary) -> Dictionary:
	var a: Dictionary = c.party[seat]
	var want: String = str(def.get("target", "self"))
	var dmg: float = _dmg_of(def)
	var blk: float = _block_of(def)
	var live: Array = []
	for i: int in range(c.enemies.size()):
		if bool(c.enemies[i]["alive"]):
			live.append(i)
	if live.is_empty():
		return {}

	match want:
		"enemy", "ally_or_enemy":
			if want == "ally_or_enemy" and _f(policy, "heal"):
				var hurt: int = _most_hurt(c)
				if hurt >= 0 and _missing(c, hurt) >= int(dmg):
					return {"score": dmg + 2.0, "kind": "ally", "idx": hurt}
			# BLIND aims at random. Every other policy aims at the weakest enemy — which is already
			# most of what "focus fire" means, so without this baseline the `focus` lever below would
			# only be measuring "prefer a lethal card", and would understate targeting's real worth.
			var tgt: int = live[randi() % live.size()] if policy == "blind" else _weakest(c, live)
			var s: float = dmg
			if _f(policy, "focus"):
				# A killing blow is worth more than its raw damage: it deletes an attacker, which is
				# the only permanent damage reduction in the game.
				var eff: int = int(c.enemies[tgt]["hp"]) + int(c.enemies[tgt]["block"])
				if dmg >= float(eff):
					s += 14.0
			return {"score": s, "kind": "enemy", "idx": tgt}
		"all_enemies":
			return {"score": dmg * float(live.size()), "kind": "all", "idx": -1}
		"ally":
			if not _f(policy, "heal"):
				return {"score": 0.5, "kind": "ally", "idx": seat}
			var h: int = _most_hurt(c)
			if h < 0:
				return {}
			return {"score": 3.0 + float(int(threat.get(h, 0))) * 0.4, "kind": "ally", "idx": h}
		_:
			# self / party — blocks, stances, buffs.
			if not _f(policy, "block"):
				return {"score": 0.4, "kind": "self", "idx": -1}   # does not value defence
			if blk > 0.0:
				# Block is worth exactly what it actually stops, and not one point more.
				var mine: float = float(int(threat.get(seat, 0)))
				var have: float = float(int(a["block"]))
				var stopped: float = minf(blk, maxf(0.0, mine - have))
				return {"score": stopped * 1.3, "kind": "self", "idx": -1}
			return {"score": 1.0, "kind": "self", "idx": -1}


func _weakest(c: Node, live: Array) -> int:
	var best: int = live[0]
	for i: int in live:
		if int(c.enemies[i]["hp"]) < int(c.enemies[best]["hp"]):
			best = i
	return best


func _missing(c: Node, i: int) -> int:
	return int(c.party[i]["max_hp"]) - int(c.party[i]["hp"])


func _most_hurt(c: Node) -> int:
	var best := -1
	for i: int in range(c.party.size()):
		if not bool(c.party[i]["alive"]):
			continue
		if best < 0 or _missing(c, i) > _missing(c, best):
			best = i
	if best >= 0 and _missing(c, best) <= 0:
		return -1
	return best


## Naive face value of a card's damage / block, read off its ops. Deliberately shallow: a bot that
## understood every op perfectly would be a THIRD policy, not a baseline for the other two.
func _dmg_of(def: Dictionary) -> float:
	var t := 0.0
	for op: Array in def["effect"]:
		match op[0]:
			"damage", "dmg", "dmg_all":
				t += float(op[1])
			"damage_scaling":
				t += float(op[2])
			"heal_or_damage":
				t += float(op[1])
	return t


func _block_of(def: Dictionary) -> float:
	var t := 0.0
	for op: Array in def["effect"]:
		match op[0]:
			"block", "gain_guard", "party_block":
				t += float(op[1])
			"shield_ally":
				t += float(op[1]) * 2.0
	return t

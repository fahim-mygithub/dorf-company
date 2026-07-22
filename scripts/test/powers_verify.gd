extends Control
## Automated verification of the NINE CLASS POWERS — the three archetypes, shipped.
##
## SOLO on purpose. A request with no "net" key never touches the Net autoload (combat.gd:120-126),
## so this harness needs no Supabase, no second peer and no timers: it is deterministic and runs in
## about a second. combat_verify stays the co-op contract; this is the RULES contract.
##
## The house style is to assert on state the engine actually mutates, never on a log line.
##
## Run: godot --headless --path . res://scenes/test/powers_verify.tscn

const COMBAT := preload("res://scenes/combat/combat.tscn")
const Db := preload("res://scripts/combat/card_db.gd")
const Powers := preload("res://scripts/combat/class_powers.gd")
const Syn := preload("res://scripts/combat/synergies.gd")

var passed := 0
var failed := 0

func _ready() -> void:
	_run()
	print("\n================ POWERS VERIFY: %d passed, %d FAILED ================" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)

func _ck(name: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name, ("   [%s]" % detail) if detail != "" else "")

## A SOLO fight with an exact crew. No net block -> Mode.SOLO -> no wire, no RNG but our own.
func _fight(classes: Array, escale := 1.0) -> Node:
	var crew: Array = []
	for c: String in classes:
		crew.append({"cls": c, "name": c.capitalize()})
	var inst: Node = COMBAT.instantiate()
	inst.request = {"crew": crew, "enemies": Db.ENCOUNTER, "enemy_scale": escale}
	add_child(inst)
	inst.visible = false
	return inst

## A SOLO fight against a NAMED board. The synergy devices are all about which bodies stand together,
## so they cannot be tested against Db.ENCOUNTER; this is _fight with the comp spelled out.
func _fight_vs(classes: Array, enemy_ids: Array, escale := 1.0) -> Node:
	var crew: Array = []
	for c: String in classes:
		crew.append({"cls": c, "name": c.capitalize()})
	var inst: Node = COMBAT.instantiate()
	inst.request = {"crew": crew, "enemies": enemy_ids, "enemy_scale": escale}
	add_child(inst)
	inst.visible = false
	return inst

## Latch a body onto the first beat of a given KIND. Rotations start at a random offset per instance
## (duplicates desync on purpose), so any assertion about a specific beat has to pin it first or it is
## a test that passes two runs in three.
func _latch(e: Dictionary, kind: String) -> void:
	var mvs: Array = e.get("moves", [])
	for i: int in range(mvs.size()):
		if str((mvs[i] as Dictionary).get("kind", "")) == kind:
			e["move_i"] = i
			return

## Force a known hand. The engine draws at random; every rule below is about a SPECIFIC hand, so the
## tests deal their own.
func _hand(c: Node, seat: int, cids: Array) -> void:
	var a: Dictionary = c.party[seat]
	a["hand"] = []
	a["hand_uids"] = []
	for cid: String in cids:
		a["hand"].append(cid)
		a["hand_uids"].append(c._next_uid())

func _play(c: Node, seat: int, cid: String, kind := "self", idx := -1) -> void:
	var a: Dictionary = c.party[seat]
	var i: int = (a["hand"] as Array).find(cid)
	if i < 0:
		return
	c._try_play(seat, str(a["hand_uids"][i]), kind, idx)

func _live_enemy(c: Node) -> int:
	for i: int in range(c.enemies.size()):
		if c.enemies[i]["alive"]:
			return i
	return 0

func _run() -> void:
	_t_wiring()
	_t_tank()
	_t_support()
	_t_dps()
	_t_regressions()
	_t_synergies()
	_t_readout()

# ================================================================ wiring
func _t_wiring() -> void:
	print("\n--- 0. the roster wires up ---------------------------------------")
	var missing: Array = []
	var no_power: Array = []
	for cid: String in Db.ROLL_POOL:
		var cls: Dictionary = Db.CLASSES[cid]
		if not Db.POWERS.has(str(cls.get("power", ""))):
			no_power.append(cid)
		for card: String in cls["deck"]:
			if not Db.CARDS.has(card):
				missing.append("%s/%s" % [cid, card])
	_ck("every class deck references a real card", missing.is_empty(), str(missing))
	_ck("every class has a real Class Power", no_power.is_empty(), str(no_power))
	_ck("the roster is the full 10", Db.ROLL_POOL.size() == 10, str(Db.ROLL_POOL.size()))
	# One power per archetype in the DEFAULT trio, or a fresh player never sees the system at all.
	var roles: Array = []
	for cid: String in Db.PARTY_ORDER:
		roles.append(str(Db.CLASSES[cid]["role"]))
	_ck("the canonical trio covers all 3 archetypes",
		"tank" in roles and "support" in roles and "dps" in roles, str(roles))

	var no_school: Array = []
	for cid: String in Db.CARDS:
		var sc: String = str((Db.CARDS[cid] as Dictionary).get("school", ""))
		if not (sc in ["block", "physical", "spell"]):
			no_school.append(cid)
	_ck("every card carries a real school", no_school.is_empty(), str(no_school))

	# JSON hands back floats. A power int missing from _INT_KEYS arrives as 3.0 where the engine wants
	# 3 — and 3.0 == 3 is TRUE in GDScript, so the bug hides until a %d or a match. Assert the mirror.
	var c: Node = _fight(["warrior", "cleric", "sorcerer"])
	var drift: Array = []
	for k: String in Powers.int_keys():
		if not (k in c._INT_KEYS):
			drift.append(k)
	_ck("_INT_KEYS mirrors every Class Power int", drift.is_empty(), str(drift))

	# describe() is the ONLY thing that writes a card face. A new op with no arm renders a blank card.
	var blank: Array = []
	for cid: String in Db.CARDS:
		var d: Dictionary = Db.describe(Db.CARDS[cid], null, 0, 0)
		if str(d["text"]).strip_edges() == "":
			blank.append(cid)
	_ck("every card renders a non-empty body", blank.is_empty(), str(blank))
	c.queue_free()

# ================================================================ TANK
func _t_tank() -> void:
	print("\n--- 1. TANK: Guard IS block, and it pulls threat ------------------")
	var c: Node = _fight(["fighter", "cleric", "sorcerer"])
	var f: Dictionary = c.party[0]
	f["block"] = 0
	_hand(c, 0, ["shield_up"])
	_play(c, 0, "shield_up")
	_ck("gain_guard writes the shipped block field", int(f["block"]) == 8, str(int(f["block"])))
	# The design's whole Guard paragraph: it soaks, and it pulls the eye. _pick_tankiest sorts by
	# block first — so stacking Guard IS how a tank volunteers to eat the hit.
	c.party[1]["block"] = 0
	c.party[2]["block"] = 0
	_ck("Guard pulls threat (tankiest reads block first)", c._pick_tankiest()["slot"] == 0,
		str(c._pick_tankiest()["name"]))

	print("\n--- 1a. Fighter: Action Surge, and Guard spent as damage/mana ----")
	var e0: int = int(f["energy"])
	var h0: int = (f["hand"] as Array).size()
	c._try_power(0, "", -1)
	_ck("Action Surge grants +2 ⚡", int(f["energy"]) == e0 + Powers.SURGE_ENERGY,
		"%d -> %d" % [e0, int(f["energy"])])
	_ck("Action Surge draws 1", (f["hand"] as Array).size() == h0 + 1)
	_ck("Action Surge sets its cooldown", int(f["power_cd"]) == Powers.SURGE_CD, str(int(f["power_cd"])))
	_ck("a power on cooldown cannot fire again", not Powers.can_fire(c, f))

	# Shield Bash: cash the wall in. 8 Guard / 4 = +2 on top of 6.
	f["block"] = 8
	f["energy"] = 9
	var en: int = _live_enemy(c)
	var hp0: int = int(c.enemies[en]["hp"])
	c.enemies[en]["block"] = 0
	_hand(c, 0, ["shield_bash"])
	_play(c, 0, "shield_bash", "enemy", en)
	_ck("Shield Bash adds +1 per 4 Guard", hp0 - int(c.enemies[en]["hp"]) == 8,
		"dealt %d, wanted 8" % (hp0 - int(c.enemies[en]["hp"])))

	print("\n--- 1b. X-cost + Reforge: the two that would type-error -----------")
	# def["cost"] is the STRING "X". The shipped _can_play did `def["cost"] > a["energy"]`, and
	# comparing String to int in GDScript is a runtime error, not a review finding.
	f["energy"] = 3
	f["block"] = 0
	f["temp"]["pay_with_guard"] = false
	for e: Dictionary in c.enemies:
		e["block"] = 0
		e["hp"] = 40
		e["alive"] = true
	_hand(c, 0, ["whirlwind"])
	_play(c, 0, "whirlwind", "all", -1)
	_ck("an X-cost card spends the whole pool", int(f["energy"]) == 0, str(int(f["energy"])))
	var each: Array = []
	for e: Dictionary in c.enemies:
		each.append(40 - int(e["hp"]))
	# The N-squared trap: _apply_play ALREADY loops the enemies for an all_enemies card, so an op that
	# looped them again would deal X per enemy PER enemy. Every enemy must lose exactly X.
	_ck("Whirlwind deals X to each enemy exactly ONCE (not N-squared)",
		each == [3, 3, 3], str(each))

	f["energy"] = 2
	f["block"] = 6
	_hand(c, 0, ["reforge", "whirlwind"])
	_play(c, 0, "reforge")
	_ck("Reforge arms the Guard pool", bool(f["temp"]["pay_with_guard"]))
	for e: Dictionary in c.enemies:
		e["hp"] = 40
		e["block"] = 0
	_play(c, 0, "whirlwind", "all", -1)
	_ck("Reforged X spends GUARD, not energy", int(f["block"]) == 0 and int(f["energy"]) == 2,
		"guard=%d energy=%d" % [int(f["block"]), int(f["energy"])])
	_ck("Reforged Whirlwind deals the Guard it spent", 40 - int(c.enemies[0]["hp"]) == 6,
		str(40 - int(c.enemies[0]["hp"])))
	c.queue_free()

	print("\n--- 1c. Barbarian: rage replaces Guard --------------------------")
	var b: Node = _fight(["barbarian", "cleric", "sorcerer"])
	var bb: Dictionary = b.party[0]
	b._try_power(0, "", -1)
	_ck("Enrage raises the stance", bool(bb["raging"]))
	_ck("Enrage cannot be re-fired while raging", not Powers.can_fire(b, bb))
	bb["block"] = 0
	_hand(b, 0, ["thick_hide"])
	_play(b, 0, "thick_hide")
	_ck("a raging dwarf CANNOT gain Guard", int(bb["block"]) == 0, str(int(bb["block"])))
	# ...including from an ally's party-wide block, which is the correct read of "no longer gain Guard".
	_hand(b, 1, ["bless"])
	_play(b, 1, "bless", "party", -1)
	_ck("not even an ally's Bless lands Guard on a raging dwarf", int(bb["block"]) == 0,
		str(int(bb["block"])))
	_ck("but the ally still got theirs", int(b.party[1]["block"]) > 0)

	bb["hp"] = int(bb["max_hp"])
	bb["shield"] = 0
	var hp1: int = int(bb["hp"])
	b._enemy_attack(b.enemies[0], bb, 9)
	_ck("raging HALVES incoming damage (ceil)", hp1 - int(bb["hp"]) == 5,
		"took %d of 9, wanted ceil(4.5)=5" % (hp1 - int(bb["hp"])))

	# +4 only while raging AND bloodied.
	bb["hp"] = int(bb["max_hp"])
	_ck("no Bloodied bonus at full HP", Powers.attack_flat_bonus(bb) == 0)
	bb["hp"] = 4
	_ck("+4 while raging and Bloodied", Powers.attack_flat_bonus(bb) == Powers.ENRAGE_BLOODIED)

	# The upkeep. Firing Enrage must NOT fail its own upkeep on the turn it fired (the grace), but a
	# later turn with no attack drops it.
	b.turn += 1
	bb["momentum"] = 0
	Powers.on_seat_upkeep(b, bb)
	_ck("rage DROPS on a turn with no attack", not bool(bb["raging"]))
	_ck("...and locks out for 4", int(bb["power_cd"]) == Powers.ENRAGE_CD, str(int(bb["power_cd"])))
	bb["power_cd"] = 0
	b._try_power(0, "", -1)
	Powers.on_seat_upkeep(b, bb)
	_ck("the turn you FIRE it cannot fail its own upkeep", bool(bb["raging"]))
	b.turn += 1
	bb["momentum"] = 1   # you swung
	Powers.on_seat_upkeep(b, bb)
	_ck("attacking holds the rage", bool(bb["raging"]))
	b.queue_free()

	print("\n--- 1d. Paladin: Devotion BANKS between Smites -------------------")
	var p: Node = _fight(["paladin", "cleric", "sorcerer"])
	var pp: Dictionary = p.party[0]
	pp["devotion"] = 0
	_hand(p, 0, ["consecrate", "vow_of_wrath"])
	_play(p, 0, "consecrate", "party", -1)
	var d1: int = int(pp["devotion"])
	_ck("a skill banks Devotion", d1 == 1, str(d1))
	# The sheet says "bank Devotion hard between casts" — impossible if the phase zeroes it.
	p._start_player_phase()
	_ck("Devotion SURVIVES the turn (it is banked, not per-turn)", int(pp["devotion"]) == d1,
		"%d -> %d" % [d1, int(pp["devotion"])])
	pp["devotion"] = 3
	pp["power_cd"] = 0
	pp["temp"]["smite_bonus"] = 0
	var en2: int = _live_enemy(p)
	p.enemies[en2]["block"] = 0
	p.enemies[en2]["hp"] = 90
	p.enemies[en2]["marked"] = false
	p.enemies[en2]["vulnerable"] = 0
	p.party[1]["block"] = 0
	p._try_power(0, "", en2)
	_ck("Smite = 6 + 4 per Devotion", 90 - int(p.enemies[en2]["hp"]) == 18,
		"dealt %d, wanted 6+4*3=18" % (90 - int(p.enemies[en2]["hp"])))
	_ck("Smite spends the bank", int(pp["devotion"]) == 0)
	_ck("Smite blocks the party", int(p.party[1]["block"]) == Powers.SMITE_PARTY_BLOCK)
	_ck("Smite sets its 3-turn cooldown", int(pp["power_cd"]) == Powers.SMITE_CD)
	p.queue_free()

# ================================================================ SUPPORT
func _t_support() -> void:
	print("\n--- 2. Cleric: the aura reads your cast TYPES --------------------")
	var c: Node = _fight(["warrior", "cleric", "sorcerer"])
	var cl: Dictionary = c.party[1]
	_ck("Channel Divinity is passive — never a button", not Powers.can_fire(c, cl))
	# A PURE streak: 1+2+3+4+5 = 15. This is the whole "commit to a line" rule.
	for i: int in range(5):
		Powers.on_card_resolved(c, cl, Db.CARDS["mend"])
	_ck("5 pure 🙏 casts discharge on the 5th", int(cl["casts"]) == 5)
	_ck("...and the charge cleared after firing", int(cl["mercy_charge"]) == 0)

	var c2: Node = _fight(["warrior", "cleric", "sorcerer"])
	var cl2: Dictionary = c2.party[1]
	for x: Dictionary in c2.party:
		x["hp"] = 10
	# 5 ALTERNATING casts: 1+1+1+1+1 = 5 — a third of the pure line, off the same five cards.
	var alt: Array = ["mend", "censure", "mend", "censure", "mend"]
	for cid: String in alt:
		Powers.on_card_resolved(c2, cl2, Db.CARDS[cid])
	var healed_alt: int = int(c2.party[0]["hp"]) - 10
	var c3: Node = _fight(["warrior", "cleric", "sorcerer"])
	var cl3: Dictionary = c3.party[1]
	for x: Dictionary in c3.party:
		x["hp"] = 10
	for i: int in range(5):
		Powers.on_card_resolved(c3, cl3, Db.CARDS["mend"])
	var healed_pure: int = int(c3.party[0]["hp"]) - 10
	# THE WHOLE "commit to a line" RULE, in one comparison. Five cards either way:
	#   pure 🙏🙏🙏🙏🙏 -> the streak climbs, mercy banks 1+2+3+4+5 = 15
	#   alternating 🙏🔥🙏🔥🙏 -> the streak resets on every switch, and only THREE of the five were
	#   mercy at all, so mercy banks 1+1+1 = 3. The smite side took the other two, and split like that
	#   neither side is worth firing. Five times the payout for the same five cards.
	_ck("a PURE streak pays far more than alternating", healed_pure > healed_alt,
		"pure=%d alternating=%d" % [healed_pure, healed_alt])
	_ck("the streak maths is 1+2+3+4+5 = 15", healed_pure == 15, str(healed_pure))
	_ck("...and alternating banks only 1+1+1 = 3 on the mercy side", healed_alt == 3, str(healed_alt))
	_ck("committing to a line pays 5x", healed_pure == healed_alt * 5,
		"%d vs %d" % [healed_pure, healed_alt])
	c.queue_free()
	c2.queue_free()
	c3.queue_free()

	print("\n--- 2a. Bard: the song is held by REACH, and an AoE counts as 1 ---")
	var b: Node = _fight(["warrior", "bard", "sorcerer"])
	var bd: Dictionary = b.party[1]
	bd["communion"] = 3
	b._try_power(1, "", -1)
	_ck("the song ignites for a lump of 📿", bool(bd["performing"]))
	_ck("...and Communion PAID for it", int(bd["communion"]) == 0, str(int(bd["communion"])))

	# Three taps on the SAME dwarf = ONE distinct target. The song must break.
	bd["targets_turn"] = []
	for i: int in range(3):
		Powers.on_target_touched(b, bd, "ally", 0)
	_ck("poking one target 3 times is ONE target", (bd["targets_turn"] as Array).size() == 1,
		str(bd["targets_turn"]))
	b.turn += 1
	Powers.on_seat_upkeep(b, bd)
	_ck("coming up short BREAKS the song", not bool(bd["performing"]))
	_ck("...and it goes on a 3-turn cooldown", int(bd["power_cd"]) == Powers.PERFORM_CD)

	bd["communion"] = 3
	bd["power_cd"] = 0
	b._try_power(1, "", -1)
	bd["targets_turn"] = []
	# Mend a dwarf, Ballad the party, Strike an enemy — that's 3, and the music plays on.
	Powers.on_target_touched(b, bd, "ally", 0)
	Powers.on_target_touched(b, bd, "all", -1)     # an AoE carries ONE address
	Powers.on_target_touched(b, bd, "enemy", 1)
	_ck("3 DISTINCT addresses hold the song", (bd["targets_turn"] as Array).size() == 3,
		str(bd["targets_turn"]))
	b.turn += 1
	Powers.on_seat_upkeep(b, bd)
	_ck("the music plays on", bool(bd["performing"]))
	# The aura rides party_attack_buff — the shipped Aura of Valor channel, reused not reinvented.
	b._start_player_phase()
	_ck("a performing Bard buffs the party's attack", b.party_attack_buff >= Powers.PERFORM_ATK,
		str(b.party_attack_buff))
	b.queue_free()

	print("\n--- 2b. Druid: the tithe is CARDS, and it is not a mulligan ------")
	var d: Node = _fight(["warrior", "druid", "sorcerer"])
	var dr: Dictionary = d.party[1]
	dr["communion"] = 3
	d._try_power(1, "bear", -1)
	_ck("Wild Shape takes the form you picked", str(dr["form"]) == "bear", str(dr["form"]))
	_ck("...for 3 turns", int(dr["shift_turns"]) == Powers.SHAPE_TURNS)
	_ck("a form you cannot name is rejected", not Powers.fire(d, 1, "dragon", -1))

	d._start_player_phase()
	_ck("the tithe falls due at the start of your NEXT turn", int(dr["tithe_owed"]) == Powers.SHAPE_TITHE,
		str(int(dr["tithe_owed"])))
	var hand0: int = (dr["hand"] as Array).size()
	var deck0: int = (dr["deck"] as Array).size()
	var disc0: int = (dr["discard"] as Array).size()
	d._try_play(1, str(dr["hand_uids"][0]), "self", -1)
	_ck("paying the tithe does NOT play the card", (dr["hand"] as Array).size() == hand0 - 1)
	_ck("the tithed card goes to the DECK, not the discard",
		(dr["deck"] as Array).size() == deck0 + 1 and (dr["discard"] as Array).size() == disc0,
		"deck %d->%d discard %d->%d" % [deck0, (dr["deck"] as Array).size(), disc0, (dr["discard"] as Array).size()])
	_ck("...and it is NOT replaced — the −2 hand IS the price",
		(dr["hand"] as Array).size() == hand0 - 1)
	d._try_play(1, str(dr["hand_uids"][0]), "self", -1)
	_ck("two cards paid clears the debt", int(dr["tithe_owed"]) == 0)

	# The payout is on the DRAW, not the play: you are paid for HOLDING the right school.
	dr["form"] = "bear"
	dr["shift_turns"] = 3
	dr["block"] = 0
	_hand(d, 1, ["guard", "barkskin", "wall", "strike"])   # 3 block cards + 1 physical
	Powers._form_payout(d, dr)
	_ck("🐻 Bear pays +5 Guard per 🛡️ card HELD", int(dr["block"]) == 3 * Powers.BEAR_GUARD,
		"%d, wanted 3x%d" % [int(dr["block"]), Powers.BEAR_GUARD])
	dr["form"] = "wolf"
	dr["temp"]["next_attack_bonus"] = 0
	_hand(d, 1, ["strike", "maul", "guard"])   # 2 physical
	Powers._form_payout(d, dr)
	_ck("🐺 Wolf pays the first attack +5 per ⚔️ card held",
		int(dr["temp"]["next_attack_bonus"]) == 2 * Powers.WOLF_ATK, str(int(dr["temp"]["next_attack_bonus"])))
	dr["form"] = "hawk"
	for x: Dictionary in d.party:
		x["block"] = 0
	_hand(d, 1, ["bolt", "mend", "strike"])   # 2 spells
	Powers._form_payout(d, dr)
	_ck("🦅 Hawk pays the WHOLE PARTY per 🧿 card held",
		int(d.party[0]["block"]) == 2 * Powers.HAWK_PARTY_BLOCK, str(int(d.party[0]["block"])))
	d.queue_free()

# ================================================================ DPS
func _t_dps() -> void:
	print("\n--- 3. Sorcerer: your PARTY charges Metamagic --------------------")
	var c: Node = _fight(["warrior", "cleric", "sorcerer"])
	var so: Dictionary = c.party[2]
	so["meta_charge"] = 0
	# The whole point of the rework: an ALLY's spell charges you. The hook reads the resolving card's
	# school, not the caster's class.
	_hand(c, 1, ["mend"])
	_play(c, 1, "mend", "ally", 0)
	_ck("an ALLY's spell charges the Sorcerer", int(so["meta_charge"]) == 1, str(int(so["meta_charge"])))
	_hand(c, 0, ["strike"])
	_play(c, 0, "strike", "enemy", _live_enemy(c))
	_ck("a PHYSICAL card charges nothing", int(so["meta_charge"]) == 1, str(int(so["meta_charge"])))
	_ck("not ready below 3", not Powers.can_fire(c, so))
	so["meta_charge"] = 3
	_ck("ready at 3", Powers.can_fire(c, so))
	c._try_power(2, "quicken", -1)
	_ck("firing sets the pick", str(so["meta_pick"]) == "quicken")
	_ck("...and resets the charge", int(so["meta_charge"]) == 0)

	# ⚡ Quicken on a 1-cost spell.
	so["energy"] = 3
	_hand(c, 2, ["bolt"])
	_play(c, 2, "bolt", "enemy", _live_enemy(c))
	_ck("Quicken makes a 1-cost spell free", int(so["energy"]) == 3, str(int(so["energy"])))
	_ck("Quicken is consumed by the spell it shaped", str(so["meta_pick"]) == "")

	# THE 0-COST TRAP. `empower` is cost 0, school spell, and live in the Sorcerer's reward pool.
	# maxi(0, 0-2) == 0 == its printed cost, so a cost-DELTA check never fires and the pick survives
	# the very spell it was meant to shape. Consumption must key off the SCHOOL.
	so["meta_pick"] = "quicken"
	so["energy"] = 3
	_hand(c, 2, ["empower"])
	_play(c, 2, "empower")
	_ck("Quicken is consumed by a 0-cost spell too (the delta trap)", str(so["meta_pick"]) == "",
		"pick survived: %s" % str(so["meta_pick"]))

	print("\n--- 3a. Twinned + Heightened ------------------------------------")
	for e: Dictionary in c.enemies:
		e["hp"] = 40
		e["alive"] = true
		e["block"] = 0
		e["marked"] = false
		e["vulnerable"] = 0
	so["meta_pick"] = "twin"
	so["energy"] = 9
	so["temp"] = c._fresh_temp()
	c.party_attack_buff = 0
	_hand(c, 2, ["bolt"])
	_play(c, 2, "bolt", "enemy", 0)
	_ck("🌀 Twin hits a SECOND target in full",
		40 - int(c.enemies[0]["hp"]) == 6 and 40 - int(c.enemies[1]["hp"]) == 6,
		"%d / %d" % [40 - int(c.enemies[0]["hp"]), 40 - int(c.enemies[1]["hp"])])
	# arc_lightning carries a dmg_all INSIDE its effect, so re-running the whole array would hit the
	# entire board twice off one Twin. Twin is gated to spells that fan out nowhere.
	_ck("a spell that fans out on its own is NOT twinnable", not c._twinnable(Db.CARDS["arc_lightning"]))
	_ck("...but a single-target spell is", c._twinnable(Db.CARDS["bolt"]))

	# ⏳ Heighten: the only thing in the game that deliberately does nothing on the turn you pay.
	for e: Dictionary in c.enemies:
		e["hp"] = 40
		e["alive"] = true
		e["block"] = 0
	so["meta_pick"] = "heighten"
	so["energy"] = 9
	so["temp"] = c._fresh_temp()
	_hand(c, 2, ["bolt"])
	_play(c, 2, "bolt", "enemy", 0)
	_ck("⏳ Heighten does NOT fire the spell now", int(c.enemies[0]["hp"]) == 40,
		str(int(c.enemies[0]["hp"])))
	_ck("...it holds it", str(so["held_cid"]) == "bolt")
	Powers.on_phase_start_pre_draw(c, so)
	_ck("a Heightened spell fires TWICE at the start of your next turn",
		40 - int(c.enemies[0]["hp"]) == 12, "dealt %d, wanted 2x6" % (40 - int(c.enemies[0]["hp"])))
	_ck("...and the hold is spent", str(so["held_cid"]) == "")
	# The target may simply be gone — a held spell is a bet on next turn's board.
	so["held_cid"] = "bolt"
	so["held_idx"] = 0
	c.enemies[0]["alive"] = false
	Powers.on_phase_start_pre_draw(c, so)
	_ck("a held spell whose target died is dropped, never fatal", str(so["held_cid"]) == "")
	c.queue_free()

	print("\n--- 3b. Rogue: the party keeps the mark bleeding -----------------")
	var r: Node = _fight(["warrior", "cleric", "rogue"])
	var ro: Dictionary = r.party[2]
	var e0: Dictionary = r.enemies[0]
	e0["hp"] = 60
	e0["alive"] = true
	r._try_power(2, "", 0)
	_ck("the mark lands", int(e0["am_turns"]) == Powers.AM_TURNS and int(e0["am_tick"]) == Powers.AM_TICK)
	_ck("the mark remembers its OWNER seat", int(e0["am_owner"]) == 2, str(int(e0["am_owner"])))
	# 🗡️ the owner's hit makes it HURT.
	r._attack(ro, e0, 1, false)
	_ck("the OWNER's hit adds +2 tick", int(e0["am_tick"]) == Powers.AM_TICK + Powers.AM_OWNER_TICK,
		str(int(e0["am_tick"])))
	# 👥 an ally's hit keeps it ALIVE.
	r._attack(r.party[0], e0, 1, false)
	_ck("an ALLY's hit adds +1 turn", int(e0["am_turns"]) == Powers.AM_TURNS + Powers.AM_ALLY_TURNS,
		str(int(e0["am_turns"])))
	# The Warden's Bulwark is exactly what this answers: a bleed that ignores armour does not care.
	e0["block"] = 999
	var hp0: int = int(e0["hp"])
	Powers.tick_marks(r)
	_ck("the bleed IGNORES ARMOUR COMPLETELY", hp0 - int(e0["hp"]) == 6,
		"took %d through 999 block" % (hp0 - int(e0["hp"])))
	_ck("...and the block is untouched (it never routed through it)", int(e0["block"]) == 999)
	# One mark at a time.
	r.enemies[1]["hp"] = 60
	r.enemies[1]["alive"] = true
	r._try_power(2, "", 1)
	_ck("ONE mark at a time — the old one is cleared", int(e0["am_turns"]) == 0,
		str(int(e0["am_turns"])))
	_ck("...and the new one is live", int(r.enemies[1]["am_turns"]) == Powers.AM_TURNS)
	r.queue_free()

	print("\n--- 3c. Monk: ANYONE's status hands the fists back ---------------")
	var m: Node = _fight(["warrior", "cleric", "monk"])
	var mo: Dictionary = m.party[2]
	var me: Dictionary = m.enemies[0]
	me["hp"] = 90
	me["alive"] = true
	me["block"] = 0
	m._try_power(2, "", 0)
	_ck("Flurry strikes for 8 flat", 90 - int(me["hp"]) == Powers.FLURRY_DMG, str(90 - int(me["hp"])))
	_ck("...and lights the cooldown", int(mo["power_cd"]) == Powers.FLURRY_CD)
	_ck("a spent Flurry cannot re-fire", not Powers.can_fire(m, mo))
	# A TEAMMATE's Burn. Not the Monk's own card — that is the entire point of the power.
	_hand(m, 1, ["searing_word"])
	_play(m, 1, "searing_word", "enemy", 0)
	_ck("a TEAMMATE's status refunds the Flurry", int(mo["power_cd"]) == 0, str(int(mo["power_cd"])))
	_ck("...so it can fire again this turn", Powers.can_fire(m, mo))
	# A status on a turn you did not flurry is worth nothing.
	m.turn += 1
	mo["power_cd"] = 3
	_hand(m, 1, ["searing_word"])
	_play(m, 1, "searing_word", "enemy", 0)
	_ck("no refund on a turn you did not flurry", int(mo["power_cd"]) == 3, str(int(mo["power_cd"])))

	print("\n--- 3d. Stun: it loses its action, and keeps its telegraph -------")
	var s: Node = _fight(["warrior", "cleric", "monk"])
	var se: Dictionary = s.enemies[0]
	se["alive"] = true
	se["stun"] = 0
	_hand(s, 2, ["stunning_strike"])
	_play(s, 2, "stunning_strike", "enemy", 0)
	_ck("Stunning Strike stuns", int(se["stun"]) == 1, str(int(se["stun"])))
	s.queue_free()
	m.queue_free()

# ================================================================ regressions
func _t_regressions() -> void:
	print("\n--- 4. the role -> archetype pivot ------------------------------")
	# ⚠ combat_verify STRUCTURALLY CANNOT catch this: its 2-seat crew (warrior+sorcerer) has no
	# support dwarf, so _first_living_role("support") returns {} whether the pivot landed or not.
	# A 3-seat case is required, not optional.
	var c: Node = _fight(["warrior", "cleric", "sorcerer"])
	_ck("role is the ARCHETYPE now", str(c.party[0]["role"]) == "tank"
		and str(c.party[1]["role"]) == "support" and str(c.party[2]["role"]) == "dps",
		"%s/%s/%s" % [str(c.party[0]["role"]), str(c.party[1]["role"]), str(c.party[2]["role"])])
	# `role` used to double as the class id — and crew_results still hands one to the campaign.
	_ck("the class id survives beside it", str(c.party[0]["cls"]) == "warrior", str(c.party[0].get("cls", "")))

	# The Assassin dives the backline: healer first. That lookup keys off the role string.
	var assassin: Dictionary = {}
	for e: Dictionary in c.enemies:
		if str(e["archetype"]) == "assassin":
			assassin = e
	_ck("the Assassin still finds the healer after the pivot",
		not assassin.is_empty() and c._enemy_target(assassin)["slot"] == 1,
		str(c._enemy_target(assassin).get("name", "?")) if not assassin.is_empty() else "no assassin")
	# Taunt redirects to the TANK — the same lookup, the other role.
	for e: Dictionary in c.enemies:
		e["forced"] = true
	_ck("Taunt still redirects to the tank after the pivot",
		c._enemy_target(assassin)["slot"] == 0, str(c._enemy_target(assassin).get("name", "?")))
	c.queue_free()

	print("\n--- 4a. the shipped trio still works ----------------------------")
	var w: Node = _fight(["warrior", "cleric", "sorcerer"])
	var wa: Dictionary = w.party[0]
	# The legacy kit is untouched: Fortify still gates its +5 to a Guard, via the data tag.
	wa["block"] = 0
	_hand(w, 0, ["fortify", "guard"])
	_play(w, 0, "fortify")
	_play(w, 0, "guard")
	_ck("Fortify still grants its +5 to a Guard", int(wa["block"]) == 10, str(int(wa["block"])))
	# The limiter moved from a hardcoded `cid == "taunt"` to the data tag, so both cards inherit it.
	w.taunt_last_turn = -99
	_hand(w, 0, ["taunt"])
	wa["energy"] = 9
	_play(w, 0, "taunt")
	_ck("Taunt still fires", w.taunt_last_turn == w.turn)
	_hand(w, 0, ["taunt"])
	_ck("...and still can't be played twice in a row", not w._can_play(wa, "taunt", Db.CARDS["taunt"]))
	# TAUNT COMPETES WITH PREF INSTEAD OF OVERRIDING IT (2026-07-21). `forced` used to return the tank
	# before the pref match ever ran, so one energy deleted every targeting rule in the game. Now the
	# redirect catches MELEE bodies only; a ranged one keeps its own preference. The taunt above is
	# already standing, so the board is in the state the rule is about.
	# The trio's encounter is brute(melee/tankiest) · assassin(melee/healer_dps) · caster(RANGED/lowest_hp),
	# which is exactly one of each side of the rule.
	var t_brute: Dictionary = {}
	var t_caster: Dictionary = {}
	for e: Dictionary in w.enemies:
		if str(e["archetype"]) == "brute":
			t_brute = e
		if str(e["archetype"]) == "caster":
			t_caster = e
	_ck("reach is still in the data (melee 1 / ranged 2)",
		w._enemy_range(t_brute) == 1 and w._enemy_range(t_caster) == 2,
		"%d/%d" % [w._enemy_range(t_brute), w._enemy_range(t_caster)])
	_ck("every enemy is flagged by the Taunt, ranged included",
		bool(t_brute["forced"]) and bool(t_caster["forced"]))
	_ck("a MELEE body is caught and swings at the tank",
		w._taunt_catches(t_brute) and int(w._enemy_target(t_brute)["slot"]) == 0,
		str(w._enemy_target(t_brute).get("name", "?")))
	# The whole point: a body cannot block a spell. The Caster is on the softest dwarf, not the tank.
	_ck("a RANGED body is NOT caught and keeps its own preference",
		not w._taunt_catches(t_caster) and int(w._enemy_target(t_caster)["slot"]) == 2,
		str(w._enemy_target(t_caster).get("name", "?")))
	# An arrow that shows a pull the resolver then ignores is worse than never changing the rule, so
	# assert the TELEGRAPH agrees — the drawn pair must end on the same dwarf the resolver will hit.
	w.phase = "playerTurn"
	# LATCH THE CASTER ONTO A DIRECTED BEAT FIRST. Rotations start at a RANDOM offset per instance (so
	# duplicates desync), and only attack/multi/expose draw an arrow — on a Ward turn the Caster
	# threatens nobody, no pair is emitted, and this check failed one run in three for a reason that
	# has nothing to do with the rule it is testing. Found by re-running, not by reading.
	for mi: int in range((t_caster["moves"] as Array).size()):
		if str((t_caster["moves"][mi] as Dictionary)["kind"]) == "attack":
			t_caster["move_i"] = mi
			break
	w._refresh_threats()
	var caster_arrow_ok := false
	for p: Dictionary in (w.threat.threats as Array):
		if (p["from"] as Vector2).is_equal_approx(w.en_pos[int(t_caster["slot"])] + Vector2(0, 42)):
			caster_arrow_ok = (p["to"] as Vector2).is_equal_approx(w.pc_pos[2] + Vector2(0, -42))
	_ck("the threat arrow agrees with the resolver on the ranged body", caster_arrow_ok)
	var bar: Node = _fight(["barbarian", "cleric", "sorcerer"])
	bar.taunt_last_turn = bar.turn
	_ck("the Barbarian's Bellow inherits the same limiter from DATA, not an id",
		not bar._can_play(bar.party[0], "bellow", Db.CARDS["bellow"]))
	w.queue_free()
	bar.queue_free()

	print("\n--- 5. the review's findings, each pinned ------------------------")
	# Every class in the roll pool must have a colour AND a reward pool. CLASS_COL is indexed on every
	# overworld screen; a missing key there is a runtime error that takes the campaign down, and it was
	# keyed to the canonical trio while the roll pool grew to 10.
	var OW := load("res://scripts/overworld/overworld.gd")
	var no_col: Array = []
	var no_rew: Array = []
	for cid: String in Db.ROLL_POOL:
		if not (OW.CLASS_COL as Dictionary).has(cid):
			no_col.append(cid)
		if not (OW.CLASS_REWARDS as Dictionary).has(cid):
			no_rew.append(cid)
	_ck("every rollable class has an overworld colour (or the campaign CRASHES)", no_col.is_empty(), str(no_col))
	_ck("every rollable class has a reward pool", no_rew.is_empty(), str(no_rew))
	var bad_rew: Array = []
	for cid: String in (OW.CLASS_REWARDS as Dictionary):
		for card: String in OW.CLASS_REWARDS[cid]:
			if not Db.CARDS.has(card):
				bad_rew.append("%s/%s" % [cid, card])
	_ck("every reward card is a real card", bad_rew.is_empty(), str(bad_rew))

	# Vow of Wrath's whole second half was a silent no-op: ["temp","smite_bonus",4] had no arm in
	# _run_ops, so the card printed half its text and did half of nothing.
	var p: Node = _fight(["paladin", "cleric", "sorcerer"])
	var pp: Dictionary = p.party[0]
	pp["devotion"] = 0
	pp["energy"] = 9
	_hand(p, 0, ["vow_of_wrath"])
	_play(p, 0, "vow_of_wrath")
	_ck("Vow of Wrath actually banks its Smite bonus", int(pp["temp"]["smite_bonus"]) == 4,
		str(int(pp["temp"]["smite_bonus"])))
	_ck("...and the card SAYS so", "Smite" in str(Db.describe(Db.CARDS["vow_of_wrath"], null, 0, 0)["text"]),
		str(Db.describe(Db.CARDS["vow_of_wrath"], null, 0, 0)["text"]))
	p.enemies[0]["hp"] = 90
	p.enemies[0]["block"] = 0
	p.enemies[0]["alive"] = true
	p.enemies[0]["marked"] = false
	p.enemies[0]["vulnerable"] = 0
	pp["power_cd"] = 0
	# Vow of Wrath is itself a skill, so playing it BANKS a Devotion as well as swearing the bonus:
	# 6 base + 4 (the 1 Devotion the Vow itself banked) + 4 (the Vow) = 14. The card pays into the
	# bank it then spends, which is the Paladin's whole loop in one card.
	_ck("the Vow banked a Devotion of its own", int(pp["devotion"]) == 1, str(int(pp["devotion"])))
	p._try_power(0, "", 0)
	_ck("a sworn Smite = 6 + 4/devotion + 4 vow", 90 - int(p.enemies[0]["hp"]) == 14,
		"dealt %d, wanted 14" % (90 - int(p.enemies[0]["hp"])))
	_ck("...and the vow is spent, not permanent", int(pp["temp"]["smite_bonus"]) == 0)
	p.queue_free()

	# 🦅 Hawk pays the PARTY, so it cannot run inside the loop that zeroes each dwarf's block — a dwarf
	# later in the party order would reset away what the Druid just granted them.
	var d: Node = _fight(["warrior", "druid", "sorcerer"])
	var dr: Dictionary = d.party[1]
	dr["form"] = "hawk"
	dr["shift_turns"] = 3
	dr["tithe_pending"] = false
	dr["communion"] = 0
	d._start_player_phase()
	var sorc_block: int = int(d.party[2]["block"])
	_ck("🦅 Hawk's party block SURVIVES for a dwarf later in the order", sorc_block > 0,
		"sorcerer (slot 2, after the druid) has %d block" % sorc_block)
	d.queue_free()

	# A Heightened spell resolves INSIDE _start_player_phase. If it kills the last enemy, _check_end
	# fires _end(true) — and the phase must NOT be stamped back to playerTurn over the win.
	var h: Node = _fight(["warrior", "cleric", "sorcerer"])
	var so: Dictionary = h.party[2]
	for e: Dictionary in h.enemies:
		e["alive"] = false
	h.enemies[0]["alive"] = true
	h.enemies[0]["hp"] = 6
	h.enemies[0]["block"] = 0
	h.enemies[0]["marked"] = false
	h.enemies[0]["vulnerable"] = 0
	so["held_cid"] = "bolt"
	so["held_idx"] = 0
	var fired := [0]
	h.combat_finished.connect(func(_r): fired[0] += 1)
	h.phase = "enemyTurn"
	h._start_player_phase()
	_ck("a Heighten kill at phase start actually WINS", str(h.phase) == "win", str(h.phase))
	_ck("...and the fight is not revived into playerTurn", str(h.phase) != "playerTurn")
	_ck("...and the parent scene was told exactly once", fired[0] == 1, str(fired[0]))
	h.queue_free()

	# A held Mark must survive the phase reset it lands in — the enemy `marked` wipe used to run AFTER
	# the held spell resolved, erasing it the instant it landed.
	var m: Node = _fight(["warrior", "cleric", "sorcerer"])
	for e: Dictionary in m.enemies:
		e["alive"] = true
		e["marked"] = false
	m.party[2]["held_cid"] = "mark"
	m.party[2]["held_idx"] = 0
	m.phase = "enemyTurn"
	m._start_player_phase()
	_ck("a held Mark SURVIVES the reset it lands in", bool(m.enemies[0]["marked"]))
	m.queue_free()

	# Arming a power and arming a card must be mutually exclusive: the enemy tap checks power_armed
	# first, so a card armed on top of a power would fire the power instead.
	var u: Node = _fight(["warrior", "cleric", "sorcerer"])
	u.power_armed = true
	u.active_idx = 0
	u._on_party_clicked(1)
	_ck("switching dwarves disarms a held power", not u.power_armed)
	u.queue_free()

# ================================================================ SYNERGIES
## The devices that make one body worth more than its own health bar. The measured fact this section
## exists to move: a balance rig decomposed a planner bot's edge and found CHOOSING TARGETS worth 0%.
##
## Two properties are asserted over and over here, because they are the two that make a device fair:
##   1. THE ONE NUMBER — the telegraph and the resolver read the same function, so a label can never
##      promise a number the hit does not deliver.
##   2. IT IS VISIBLE BEFORE YOU COMMIT — a conditional the player cannot see is an unfair number, so
##      the readout (label / chip / slab / meter / panel line) is asserted, not just the arithmetic.
func _t_synergies() -> void:
	print("\n--- 6. the synergy engine ----------------------------------------")
	# The module's own contract first: 60-odd assertions over hand-built boards, no scene tree needed.
	var syn_fail: Array = Syn.self_test()
	_ck("synergies.self_test passes", syn_fail.is_empty(), str(syn_fail))

	# ---- CHORUS: the label prints the BUFFED TOTAL, and the hit delivers exactly it ---------------
	var c: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["caster", "wolf"])
	var caster: Dictionary = c.enemies[0]
	var wolf: Dictionary = c.enemies[1]
	_latch(wolf, "attack")
	var mv: Dictionary = c._enemy_move(wolf)
	_ck("chorus folds into the ONE number (5 +3 = 8)", c._move_dmg(wolf, mv) == 8, str(c._move_dmg(wolf, mv)))
	c._refresh()
	_ck("...and the intent LABEL prints that total, not the arithmetic",
		"8" in str(c.en_intent[1].text) and not ("+3" in str(c.en_intent[1].text)), str(c.en_intent[1].text))
	_ck("...tinted in the SOURCE's colour, so you know which body to kill",
		c.en_intent[1].get_theme_color("font_color").is_equal_approx(c._source_tint(caster)))
	# The resolver must land the number the label promised. This is the whole property.
	var victim: Dictionary = c._enemy_target(wolf)
	var hp0: int = int(victim["hp"])
	var told: int = c._intent_hit(wolf, mv)
	c._do_enemy_move(wolf, mv)
	_ck("the RESOLVER lands exactly what the telegraph promised",
		hp0 - int(victim["hp"]) == told, "%d vs %d" % [hp0 - int(victim["hp"]), told])
	# ...and it vanishes with its source. Rage is permanent; chorus is the opposite of rage.
	caster["alive"] = false
	_ck("chorus VANISHES the instant its source dies", c._move_dmg(wolf, mv) == 5, str(c._move_dmg(wolf, mv)))
	c.queue_free()

	# ---- AEGIS: soaks swings, does NOT soak status damage -----------------------------------------
	var a: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["shellback", "wolf", "warden"])
	var shell: Dictionary = a.enemies[0]
	var awolf: Dictionary = a.enemies[1]
	_ck("aegis reaches every OTHER body", Syn.incoming_reduction(a.enemies, awolf) == 3,
		str(Syn.incoming_reduction(a.enemies, awolf)))
	_ck("...and never stacks, even with two sources on the board",
		Syn.incoming_reduction(a.enemies, awolf) == 3 and Syn.aura_amount(a.enemies, Syn.AEGIS, awolf) == 3)
	_ck("a source does not shield itself", Syn.incoming_reduction(a.enemies, shell) == 3,
		"warden shields the shellback (3), not 6: %d" % Syn.incoming_reduction(a.enemies, shell))
	awolf["hp"] = 22
	awolf["block"] = 0
	a._attack(a.party[0], awolf, 10, false)
	_ck("a swing is soaked (10 -> 7)", int(awolf["hp"]) == 15, str(int(awolf["hp"])))
	# Burn / the Assassin's Mark write through _deal_enemy precisely because they ignore armour, and
	# aegis IS armour. Fire is the designed way through a shell line, not a loophole in it.
	a._deal_enemy(awolf, 5)
	_ck("status damage IGNORES the shell (it ignores block for the same reason)",
		int(awolf["hp"]) == 10, str(int(awolf["hp"])))
	a._refresh()
	# The slab is the AT-A-GLANCE half: it must be the SOURCE's colour (so the eye links the two
	# bodies) and it must be faint (it sits behind a portrait it may never obscure).
	var wash: Color = a.en_aura[1].color
	var src_tint: Color = a._source_tint(shell)
	_ck("a protected body wears its protector's colour, faintly",
		a.en_aura[1].visible and wash.a < 0.2
		and is_equal_approx(wash.r, src_tint.r) and is_equal_approx(wash.g, src_tint.g),
		str(wash))
	_ck("...and a chip that says what it actually soaks", "3" in str(a.en_device[1].text), str(a.en_device[1].text))
	shell["alive"] = false
	a.enemies[2]["alive"] = false
	a._refresh()
	_ck("kill the sources and the wash is GONE", not a.en_aura[1].visible)
	_ck("...and so is the soak", Syn.incoming_reduction(a.enemies, awolf) == 0)
	a.queue_free()

	# ---- ALONE GATE: previewed BEFORE it is true --------------------------------------------------
	var g: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["caster", "wolf"])
	var gc: Dictionary = g.enemies[0]
	_latch(gc, "block")   # its Ward beat: the substitution has to override the rotation, not follow it
	_ck("the alone gate does NOT fire while an ally lives",
		str(g._enemy_move(gc).get("kind", "")) == "block")
	g.intent_open = 0
	g._refresh_intent_panel()
	_ck("...but the PANEL warns you about it first", "LAST one standing" in str(g.ip_dev.text), str(g.ip_dev.text))
	g.enemies[1]["alive"] = false
	_ck("cornered, every beat becomes its heaviest spell",
		int(g._enemy_move(gc).get("dmg", 0)) == 10, str(g._enemy_move(gc)))
	g.queue_free()

	# ---- TWIN BOND: asymmetric, and one half rewrites the ROTATION --------------------------------
	# Which one you kill first is the decision, so the two outcomes must not be interchangeable.
	var t: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["wolf", "witch"])
	var twolf: Dictionary = t.enemies[0]
	var twitch: Dictionary = t.enemies[1]
	_latch(twolf, "attack")
	_ck("the bond is quiet while both live", str(t._enemy_move(twolf)["kind"]) == "attack")
	twitch["alive"] = false
	_ck("witch dead -> the wolf howls on EVERY beat",
		str(t._enemy_move(twolf)["kind"]) == "rage_all", str(t._enemy_move(twolf)))
	t.queue_free()
	var t2: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["wolf", "witch"])
	var t2witch: Dictionary = t2.enemies[1]
	_latch(t2witch, "attack_all")
	t2.enemies[0]["alive"] = false
	_ck("wolf dead -> the Shriek DOUBLES, inside the one number",
		t2._move_dmg(t2witch, t2._enemy_move(t2witch)) == 6, str(t2._move_dmg(t2witch, t2._enemy_move(t2witch))))
	_ck("...and the asymmetry holds: no howling from a witch",
		str(t2._enemy_move(t2witch)["kind"]) == "attack_all")
	t2.queue_free()

	# ---- REGALIA: the Gaze is worth what the lattice is worth --------------------------------------
	var o: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["overseer", "rune_crystal", "rune_crystal"])
	var boss: Dictionary = o.enemies[0]
	var gaze: Dictionary = {"kind": "attack", "gaze": true}
	_ck("Gaze = 3 + 2 per living crystal", o._move_base(boss, gaze) == 7, str(o._move_base(boss, gaze)))
	boss["hp"] = 90
	boss["block"] = 0
	o._attack(o.party[0], boss, 10, false)
	_ck("the boss shrugs off hits while the lattice stands", int(boss["hp"]) == 83, str(int(boss["hp"])))
	o.enemies[1]["alive"] = false
	o.enemies[2]["alive"] = false
	_ck("...break the lattice and the Gaze collapses", o._move_base(boss, gaze) == 3, str(o._move_base(boss, gaze)))
	o._attack(o.party[0], boss, 10, false)
	_ck("...and the boss takes full damage", int(boss["hp"]) == 73, str(int(boss["hp"])))
	o.queue_free()

	# ---- MOLT: a second rotation, a visible threshold, and NOTHING on the wire ---------------------
	var m: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["molt_king"])
	var king: Dictionary = m.enemies[0]
	king["move_i"] = 1
	_ck("armoured, it soaks", Syn.incoming_reduction(m.enemies, king) == 3)
	_ck("...and runs its armoured beat", str(m._enemy_move(king)["name"]) == "Claw", str(m._enemy_move(king)["name"]))
	king["hp"] = int(king["max_hp"]) / 2
	_ck("cracked, the SAME beat index resolves as the molted move",
		str(m._enemy_move(king)["name"]) == "Sting Rush" and int(king["move_i"]) == 1,
		"%s @ %d" % [str(m._enemy_move(king)["name"]), int(king["move_i"])])
	_ck("...the carapace is gone", Syn.incoming_reduction(m.enemies, king) == 0)
	_ck("...and the same beats hit harder", m._move_dmg(king, m._enemy_move(king)) == 5 + Syn.MOLT_FURY,
		str(m._move_dmg(king, m._enemy_move(king))))
	m._refresh()
	_ck("the crack meter is on screen and full", m.en_meter_fg[0].visible and m.en_meter_fg[0].size.x >= m.METER_W)
	# The second rotation is an ARRAY OF DICTS: if it crossed the wire its ints would come back as
	# floats that _INT_KEYS cannot reach (it only coerces top-level keys) and every cracked number
	# would print as "14.0". It must be erased with its sibling.
	m.mode = 1   # Mode.AUTHORITY — _build_snapshot is host-only
	var snap: Dictionary = m._build_snapshot()
	var leaked: Array = []
	for ed: Dictionary in (snap["enemies"] as Array):
		if ed.has("moves") or ed.has("moves_molt"):
			leaked.append(str(ed.get("archetype", "?")))
	_ck("NO rotation crosses the wire (neither of them)", leaked.is_empty(), str(leaked))
	m.queue_free()

	# ---- GORGE: pips, one per corpse, capped where the bonus caps ---------------------------------
	var mw: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["the_maw", "cave_bat", "cave_bat"])
	var maw: Dictionary = mw.enemies[0]
	mw._refresh()
	_ck("the Maw shows an empty gorge track before it feeds", "🩸" in str(mw.en_device[0].text), str(mw.en_device[0].text))
	mw.enemies[1]["alive"] = false
	mw.enemies[2]["alive"] = false
	_latch(maw, "attack")
	_ck("two corpses = +6 on the ONE number",
		mw._move_dmg(maw, mw._enemy_move(maw)) == 8 + 6, str(mw._move_dmg(maw, mw._enemy_move(maw))))
	mw._refresh()
	_ck("...and two lit pips under it", str(mw.en_device[0].text).count("🩸") == 2, str(mw.en_device[0].text))
	mw.queue_free()

	# ---- the whole telegraph still renders from DATA, for every kind ------------------------------
	# card_db dropped the per-move "emoji" key in favour of MOVE_KINDS. A kind with no row would render
	# a blank label — a body whose telegraph is empty is unreadable, and nothing else would catch it.
	var blank: Array = []
	for eid: String in Db.ENEMIES:
		for row: Dictionary in ((Db.ENEMIES[eid] as Dictionary).get("moves", []) as Array):
			if not Db.MOVE_KINDS.has(str(row.get("kind", ""))):
				blank.append("%s/%s" % [eid, str(row.get("name", "?"))])
		for row2: Dictionary in ((Db.ENEMIES[eid] as Dictionary).get("moves_molt", []) as Array):
			if not Db.MOVE_KINDS.has(str(row2.get("kind", ""))):
				blank.append("%s/%s" % [eid, str(row2.get("name", "?"))])
	_ck("every authored move has a MOVE_KINDS row to render from", blank.is_empty(), str(blank))

# ================================================================ the readout (2026-07-22)
## THE INTENT GRAMMAR, THE NAMEPLATE BADGES AND THE INCOMING FORECAST.
##
## The property under test throughout is the one the synergy section tests, pushed a layer out: a
## readout is worth nothing unless it AGREES WITH WHAT LANDS. So nothing here asserts on a string
## alone — every number in a label is checked against the resolver's own functions, and the forecast
## is checked by running the enemy phase and comparing the HP that was actually lost.
func _t_readout() -> void:
	print("\n--- 7. the intent grammar, the badges and the forecast ------------")

	# ---- the three-slot contract: [verb][magnitude][target chip], every kind, no exceptions ---------
	# Rendered through _fmt_move against a REAL board rather than by reading MOVE_KINDS back to itself:
	# what can break is the substitution, not the table.
	var g: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["ogre", "warden", "wolf"])
	var og: Dictionary = g.enemies[0]
	var forms: Dictionary = {
		"block":      [{"name": "Brace", "kind": "block", "amt": 5},                     "🛡️5>self"],
		"guard_all":  [{"name": "Bulwark", "kind": "guard_all", "amt": 8, "ally_amt": 4}, "🛡️8/+4>ALL"],
		"rage_all":   [{"name": "Howl", "kind": "rage_all", "amt": 2},                    "📈+2>ALL"],
		"attack_all": [{"name": "Shriek", "kind": "attack_all", "dmg": 3},                "🗡️3>ALL"],
		"multi":      [{"name": "Flurry", "kind": "multi", "dmg": 3, "hits": 3},          "🗡️3×3>War"],
		"attack":     [{"name": "Smash", "kind": "attack", "dmg": 9},                     "🗡️9>War"],
	}
	var wrong: Array = []
	for k: String in forms:
		var got: String = g._fmt_move(og, (forms[k] as Array)[0], "label_fmt")
		if got != str((forms[k] as Array)[1]):
			wrong.append("%s: %s != %s" % [k, got, str((forms[k] as Array)[1])])
	_ck("every kind renders [verb][magnitude][target chip]", wrong.is_empty(), str(wrong))
	# FOUR VERBS, and the budget IS the point — a fifth would mean the verb slot went back to encoding
	# magnitude or shape, which is what the digit and the × next to it already do.
	var verbs: Dictionary = {}
	for k2: String in Db.MOVE_KINDS:
		verbs[str((Db.MOVE_KINDS[k2] as Dictionary).get("verb", ""))] = true
	_ck("the verb vocabulary is FOUR glyphs, not one per kind", verbs.size() == 4, str(verbs.keys()))
	_ck("...🗡️ Harm covers all three attack shapes",
		str(Db.MOVE_KINDS["attack"]["verb"]) == str(Db.MOVE_KINDS["multi"]["verb"])
		and str(Db.MOVE_KINDS["multi"]["verb"]) == str(Db.MOVE_KINDS["attack_all"]["verb"]))
	# EVERY label ends in a chip. That is the whole reason × can now only mean "separate swings".
	var chipless: Array = []
	for k3: String in Db.MOVE_KINDS:
		for key: String in ["label_fmt", "label_fmt_zero"]:
			var fm: String = str((Db.MOVE_KINDS[k3] as Dictionary).get(key, ""))
			if fm != "" and not (fm.ends_with(">{tgt}") or fm.ends_with(">ALL") or fm.ends_with(">self")):
				chipless.append("%s/%s" % [k3, key])
	_ck("the target chip is MANDATORY on every label form", chipless.is_empty(), str(chipless))
	# The capped Howl keeps its chip: the truthfulness variant is a magnitude swap, not a second
	# grammar, and a *_fmt_zero that dropped the chip would be exactly that.
	og["rage"] = g.RAGE_CAP
	_ck("a capped Howl says 'max' and KEEPS the chip",
		g._fmt_move(og, {"name": "Howl", "kind": "rage_all", "amt": 2}, "label_fmt") == "📈max>ALL",
		g._fmt_move(og, {"name": "Howl", "kind": "rage_all", "amt": 2}, "label_fmt"))
	og["rage"] = 0
	# 📣 belonged to the party's Aura of Valor and to enemy rage at once. Only one of them may keep it.
	_ck("📣 is the PARTY aura alone — enemy rage moved to 📈",
		str(Db.MOVE_KINDS["rage_all"]["verb"]) == "📈")
	_ck("🌀 is Channel alone — Metamagic moved to 🧿",
		str(Db.POWERS["metamagic"]["emoji"]) == "🧿" and str(Db.CARDS["channel"]["emoji"]) == "🌀")

	# ---- the nameplate badge: identity, and never a promise the resolver breaks --------------------
	g._refresh()
	_ck("every body wears one of the THREE pref badges",
		g.en_name[0].text.begins_with("🧲") and g.en_name[2].text.begins_with("🥀"),
		"%s | %s" % [g.en_name[0].text, g.en_name[2].text])
	_ck("the badge set is closed at three rules + the override",
		Db.PREF_BADGES.size() == 4 and Db.PREF_BADGES.has("forced"))
	# A MELEE body: the Taunt takes, so 😡 replaces the rule and the rule is DEMOTED, not deleted.
	og["forced"] = true
	g._refresh()
	_ck("a taunt that TAKES shows 😡 on the nameplate", g.en_name[0].text.begins_with("😡"), g.en_name[0].text)
	_ck("...and the rule it overrode is still on screen, at half size",
		g.en_rule[0].visible and g.en_rule[0].text == "🧲", g.en_rule[0].text)
	_ck("...and the panel says the rule was overridden, off the same table",
		str(Db.PREF_BADGES["forced"]["tip"]) in g._pref_tip(og))
	og["forced"] = false
	# A RANGED body is flagged forced and NOT redirected (Taunt is melee-only). The badge has to keep
	# telling the truth here or it is a promise the resolver breaks — the reason this check exists.
	var r: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["caster", "wolf"])
	var cst: Dictionary = r.enemies[0]
	cst["forced"] = true
	r._refresh()
	_ck("a taunt that SLIDES OFF a ranged body leaves its own badge up",
		r.en_name[0].text.begins_with("🥀") and not r.en_rule[0].visible, r.en_name[0].text)
	_ck("...and the resolver agrees the pull did not take",
		str(r._enemy_target(cst).get("role", "")) != "tank")
	cst["forced"] = false

	# ---- 💫 Stun: three readouts, one fact --------------------------------------------------------
	# It was LOG-ONLY, so a player could not tell "I stunned it" from "the telegraph was wrong".
	var s: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["ogre", "wolf"])
	_latch(s.enemies[0], "attack")
	s._refresh()
	var pre: int = int(s._incoming_forecast()[0]["gross"])
	s.enemies[0]["stun"] = 1
	s._refresh()
	_ck("a stunned body's telegraph says so instead of promising a hit",
		"💫" in str(s.en_intent[0].text) and not (">" in str(s.en_intent[0].text)), s.en_intent[0].text)
	_ck("...it wears a status badge like every other status", "💫1" in str(s.en_block[0].text), s.en_block[0].text)
	_ck("...and the forecast stops counting it", int(s._incoming_forecast()[0]["gross"]) < pre)
	s.enemies[0]["stun"] = 0

	# ---- the swarm line: one object, one number ---------------------------------------------------
	var w: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["cave_bat", "cave_bat", "cave_bat", "caster"])
	w._refresh()
	var line: String = str(w.sw_line[0].text)
	_ck("3+ identical contiguous minions collapse to ONE line", w.sw_line[0].visible, line)
	_ck("...and their individual labels are GONE (never drawn twice)",
		not w.en_intent[0].visible and not w.en_intent[1].visible and not w.en_intent[2].visible)
	_ck("...while the body outside the run keeps its own", w.en_intent[3].visible)
	# A bat hits for 4 + the Caster's chorus 3 = 7; three of them = 21. The per-hit number AND the sum
	# are both in the line, and the sum is what the decision is actually made on.
	var bat_hit: int = w._move_dmg(w.enemies[0], w._enemy_move(w.enemies[0]))
	_ck("the line prints the per-hit number the resolver will use", ("%d>" % bat_hit) in line, line)
	_ck("...and the SUMMED total in parentheses", ("(%d)" % (bat_hit * 3)) in line, line)
	_ck("...tinted by the chorus source, exactly like the labels it replaced",
		w.sw_line[0].get_theme_color("font_color").is_equal_approx(w._source_tint(w.enemies[3])))
	_ck("every swarm body keeps its own HP bar", w.en_hp[0].visible and w.en_hp[1].visible and w.en_hp[2].visible)
	# Kill one and the run drops below SWARM_MIN: the collapse has to come apart cleanly.
	w.enemies[1]["alive"] = false
	w.enemies[1]["hp"] = 0
	w._refresh()
	_ck("kill one and the run falls apart — the labels come back",
		not w.sw_line[0].visible and w.en_intent[0].visible, str(w.sw_line[0].text))

	# ---- THE FORECAST: it must agree with what actually lands -------------------------------------
	# The strongest form of this available: forecast the phase, RUN it, compare the HP actually lost.
	# The board is all-`tankiest`/`healer_dps` on purpose — see the retargeting check below for why a
	# board with a `lowest_hp` body cannot be used for an exact-equality assertion.
	var f: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["ogre", "assassin", "warden"])
	for e: Dictionary in f.enemies:
		_latch(e, "attack")
	f.party[0]["block"] = 6      # partial cover: the drain has to be right, not just the sum
	f._refresh()
	var pred: Array = f._incoming_forecast()
	var hp_before: Array = []
	for a: Dictionary in f.party:
		hp_before.append(int(a["hp"]))
	for e2: Dictionary in f.enemies:
		if e2["alive"]:
			f._do_enemy_move(e2, f._enemy_move(e2))
	var bad: Array = []
	for i: int in range(f.party.size()):
		var lost: int = hp_before[i] - int(f.party[i]["hp"])
		if lost != int(pred[i]["net"]):
			bad.append("%s: predicted %d, lost %d" % [str(f.party[i]["name"]), int(pred[i]["net"]), lost])
	_ck("the forecast's `net` is EXACTLY the HP the enemy phase takes", bad.is_empty(), str(bad))

	# ---- THE ONE THING IT DOES NOT MODEL, asserted so it is RECORDED rather than discovered --------
	# Targets are read once off the CURRENT board — the same read the threat arrows make. On a board
	# with a `lowest_hp` body, an earlier beat can change who is lowest and the later beats reroute:
	# an Ogre putting 19 into a 36-HP Warrior drops it to 17, under the 22-HP Sorcerer, and the Wolf
	# and Caster follow it. The chip (and the arrow above it) both still point at the Sorcerer.
	# This is a deliberate trade, not an oversight: modelling the reroute would make the chip disagree
	# with the arrows drawn directly above it, and a player who catches those two contradicting each
	# other stops trusting both. If it is ever revisited, the arrows have to move in the same commit.
	var rt: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["ogre", "wolf", "caster"])
	for e3: Dictionary in rt.enemies:
		_latch(e3, "attack")
	rt._refresh()
	var rt_pred: Array = rt._incoming_forecast()
	var war_hp: int = int(rt.party[0]["hp"])
	# The forecast and the arrows tell the same story before the phase runs.
	var arrow_tgt: int = int(rt._enemy_target(rt.enemies[1])["slot"])
	_ck("the chip and the threat arrow always agree with each other", arrow_tgt == 2 and int(rt_pred[2]["net"]) > 0)
	for e4: Dictionary in rt.enemies:
		if e4["alive"]:
			rt._do_enemy_move(e4, rt._enemy_move(e4))
	_ck("KNOWN LIMIT: a lowest_hp body reroutes mid-phase and lands off-forecast",
		(war_hp - int(rt.party[0]["hp"])) > int(rt_pred[0]["net"]),
		"warrior lost %d, forecast said %d" % [war_hp - int(rt.party[0]["hp"]), int(rt_pred[0]["net"])])

	# VULNERABLE lives on the VICTIM, so no intent label can carry it — which is precisely why a
	# per-dwarf chip has to exist at all.
	var v: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["ogre"])
	_latch(v.enemies[0], "attack")
	var base_gross: int = int(v._incoming_forecast()[0]["gross"])
	v.party[0]["vulnerable"] = 1
	var vuln_gross: int = int(v._incoming_forecast()[0]["gross"])
	_ck("Vulnerable x1.5 is folded into the chip", vuln_gross == int(round(base_gross * v.VULN_MULT)),
		"%d -> %d" % [base_gross, vuln_gross])
	v.party[0]["vulnerable"] = 0
	# MULTI-HIT counts, and GUARD DRAINS across the swings instead of soaking each one in full.
	var m: Node = _fight_vs(["warrior", "cleric", "sorcerer"], ["assassin"])
	_latch(m.enemies[0], "multi")
	var mv: Dictionary = m._enemy_move(m.enemies[0])
	var per: int = m._move_dmg(m.enemies[0], mv)
	var tgt: int = int(m._enemy_target(m.enemies[0])["slot"])
	m.party[tgt]["block"] = per + 1     # covers the FIRST swing and one point of the second
	var mf: Dictionary = m._incoming_forecast()[tgt]
	_ck("multi counts every swing", int(mf["gross"]) == per * int(mv["hits"]), str(mf))
	_ck("...and Guard DRAINS across them instead of soaking each one",
		int(mf["net"]) == per * int(mv["hits"]) - (per + 1), str(mf))
	# THE THREE GLYPHS. The number never changes meaning between them; only the glyph does.
	m._refresh()
	_ck("partly covered -> 🗡️ with the gross swing",
		str(m.pc_forecast[tgt].text) == "🗡️%d" % int(mf["gross"]), str(m.pc_forecast[tgt].text))
	m.party[tgt]["block"] = 999
	m._refresh()
	_ck("fully covered -> 🛡️, and the number is STILL the gross swing",
		str(m.pc_forecast[tgt].text) == "🛡️%d" % int(mf["gross"]), str(m.pc_forecast[tgt].text))
	m.party[tgt]["block"] = 0
	m.party[tgt]["hp"] = 1
	m._refresh()
	_ck("lethal -> 💀, and the magnitude is dropped as irrelevant",
		str(m.pc_forecast[tgt].text) == "💀", str(m.pc_forecast[tgt].text))
	# A quiet dwarf shows NOTHING. A chip reading 0 every quiet turn is a chip the eye learns to skip
	# — and it would then be skipped on the turn it says 💀.
	var quiet: int = -1
	for i2: int in range(m.party.size()):
		if i2 != tgt:
			quiet = i2
	_ck("a dwarf nothing is aimed at shows no chip at all", not m.pc_forecast[quiet].visible)

	# ---- the six-body squeeze: the ENEMY_MAX cap must exist in the LAYOUT, not just in a const -----
	var six: Node = _fight_vs(["warrior", "cleric", "sorcerer"],
		["cave_bat", "cave_bat", "cave_bat", "cave_bat", "caster", "ogre"])
	six._refresh()
	var overflow: Array = []
	for i3: int in range(six.en_intent.size()):
		var l: Label = six.en_intent[i3]
		if l.position.x < 0.0 or l.position.x + l.size.x > 720.0:
			overflow.append("slot %d: %s..%s" % [i3, l.position.x, l.position.x + l.size.x])
		# Boxes may touch but must never OVERLAP, or two neighbouring telegraphs render into each other.
		if i3 > 0 and l.position.x < six.en_intent[i3 - 1].position.x + six.en_intent[i3 - 1].size.x:
			overflow.append("slot %d overlaps %d" % [i3, i3 - 1])
	_ck("at ENEMY_MAX bodies no intent label overlaps or leaves the 720px board", overflow.is_empty(), str(overflow))
	_ck("...and a 3-body board is left byte-identical (no silent restyle)",
		is_equal_approx(f._slot_font_scale(), 1.0) and is_equal_approx(f._slot_label_w(), f.SLOT_LABEL_W))

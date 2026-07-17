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

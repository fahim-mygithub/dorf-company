extends RefCounted
## (preloaded by combat.gd as Powers; no class_name to avoid global-class collision)
##
## THE NINE CLASS POWERS — the three published role sheets, shipped.
## design/cards/{class,support,dps}.html is the authority; docs/plans/2026-07-17-class-archetypes-plan.md
## records every place a sheet contradicted the engine and how it was resolved.
##
## A Class Power is a second lever beside the hand: tap your own dwarf's orb to fire it. Powers live
## here so combat.gd only has to ROUTE the tap; every rule below is one static func away from the
## engine it mutates. `c` is always the combat node (untyped on purpose — combat.gd has no class_name,
## so a typed param could not see .party/.enemies/._attack).
##
## THE THREE ARCHETYPES GATE ON THREE DIFFERENT THINGS, AND THAT IS THE DESIGN:
##   ⚔️ TANK    — a COOLDOWN. Guard IS the shipped `block` field: it already soaks (_enemy_attack)
##                and already pulls threat (_pick_tankiest sorts by block first). `gain_guard` is a
##                pure alias so the Tank card text can say "Guard" — there is no second pool.
##   📿 SUPPORT — COMMUNION, spent as a lump to IGNITE a stance and then out of the way. Neither
##                stance drains a meter to stay alive: the Bard pays in REACH (3 distinct targets a
##                turn), the Druid pays in CARDS (a −2 hand).
##   🗡️ DPS     — NOTHING. No cooldown, no meter: the gate reads what the PARTY just did. A cooldown
##                counts turns and these need to count teammates. It only works because combat is
##                SIMULTANEOUS — an ally's Burn lands while you still have your turn.
##
## HOST-AUTHORITATIVE: every func here runs on the host (or SOLO) only. A client never computes power
## state; it renders what rides the absolute snapshot. Nothing here sends a message.

const Db := preload("res://scripts/combat/card_db.gd")

# ---- tank ----
const SURGE_ENERGY := 2
const SURGE_CD := 4
const ENRAGE_CD := 4
const ENRAGE_BLOODIED := 4
const SMITE_BASE := 6
const SMITE_PER_DEVOTION := 4
const SMITE_PARTY_BLOCK := 3
const SMITE_CD := 3
# ---- support ----
const CHANNEL_EVERY := 5
const COMMUNION_MAX := 9
const PERFORM_TARGETS := 3
const PERFORM_ATK := 2
const PERFORM_BLOCK := 2
const PERFORM_CD := 3
const SHAPE_TURNS := 3
const SHAPE_TITHE := 2
const BEAR_GUARD := 5      # per 🛡️ block card held
const HAWK_PARTY_BLOCK := 3  # per 🧿 spell card held (reads lower only because it multiplies by party size)
const WOLF_ATK := 5        # per ⚔️ physical card held, onto the FIRST attack
# ---- dps ----
const META_READY := 3
const QUICKEN_OFF := 2
const AM_TICK := 4
const AM_TURNS := 3
const AM_ALLY_TURNS := 1   # an ALLY's hit keeps it alive
const AM_OWNER_TICK := 2   # the owner's hit makes it hurt
const FLURRY_DMG := 8
const FLURRY_CD := 3

## Per-dwarf power state. Merged into the party dict at _start_combat and reset per fight, never
## per turn — a stance and a cooldown both outlive the turn that set them.
static func fresh_state(power: String) -> Dictionary:
	return {
		"power": power, "power_cd": 0, "power_turn": -99,
		"communion": 0,
		"raging": false, "rage_turn": -99,                      # Barbarian
		"cast_side": "", "streak": 0, "casts": 0, "smite_charge": 0, "mercy_charge": 0,  # Cleric
		"performing": false,                                     # Bard
		"form": "", "shift_turns": 0, "tithe_owed": 0,           # Druid
		"meta_charge": 0, "meta_pick": "", "held_cid": "", "held_idx": -1,  # Sorcerer
		"regen": 0,
	}

## Ints that must survive the JSON round trip (every number comes back a float).
static func int_keys() -> Array:
	return ["power_cd", "power_turn", "communion", "rage_turn", "streak", "casts",
		"smite_charge", "mercy_charge", "shift_turns", "tithe_owed", "meta_charge",
		"held_idx", "regen"]

static func power_def(a: Dictionary) -> Dictionary:
	return Db.POWERS.get(str(a.get("power", "")), {})

## The cooldown a power lands on — the denominator the coin's recovery ring drains against. Kept here
## with the constants so the UI can never invent a number the rules don't use.
static func cd_max_of(power: String) -> int:
	match power:
		"action_surge": return SURGE_CD
		"smite": return SMITE_CD
		"flurry": return FLURRY_CD
		"enrage": return ENRAGE_CD
		"bardic_performance": return PERFORM_CD
		"wild_shape": return SHAPE_TURNS
	return 1

# ================================================================ Firing
## Can this seat fire right now? The ONE readable gate — the UI greys the orb with it and the host
## re-validates with it, so what you see and what the host allows can never drift apart.
static func can_fire(_c, a: Dictionary) -> bool:
	var p: Dictionary = power_def(a)
	if p.is_empty() or bool(p.get("passive", false)):
		return false
	if not a.get("alive", false):
		return false
	if int(a.get("power_cd", 0)) > 0:
		return false
	if int(p.get("communion", 0)) > 0 and int(a.get("communion", 0)) < int(p["communion"]):
		return false
	if int(p.get("charge", 0)) > 0 and int(a.get("meta_charge", 0)) < int(p["charge"]):
		return false
	# Enrage is the one power you cannot re-fire: the orb reads RAGING and only the upkeep drops it.
	if str(a.get("power", "")) == "enrage" and bool(a.get("raging", false)):
		return false
	# A stance you are already holding is not a button.
	if str(a.get("power", "")) == "bardic_performance" and bool(a.get("performing", false)):
		return false
	if str(a.get("power", "")) == "wild_shape" and int(a.get("shift_turns", 0)) > 0:
		return false
	return true

## Why the orb is dark. Player-facing, so it names the thing you can act on.
static func gate_reason(a: Dictionary) -> String:
	var p: Dictionary = power_def(a)
	if p.is_empty():
		return ""
	if bool(p.get("passive", false)):
		return "%s fires itself." % str(p["name"])
	if int(a.get("power_cd", 0)) > 0:
		return "%s recovers in %d." % [str(p["name"]), int(a["power_cd"])]
	if str(a.get("power", "")) == "enrage" and bool(a.get("raging", false)):
		return "Already raging."
	if str(a.get("power", "")) == "bardic_performance" and bool(a.get("performing", false)):
		return "The song is already playing."
	if str(a.get("power", "")) == "wild_shape" and int(a.get("shift_turns", 0)) > 0:
		return "Already shifted (%d turns left)." % int(a.get("shift_turns", 0))
	if int(p.get("communion", 0)) > 0 and int(a.get("communion", 0)) < int(p["communion"]):
		return "Needs %d 📿 (you have %d)." % [int(p["communion"]), int(a.get("communion", 0))]
	if int(p.get("charge", 0)) > 0 and int(a.get("meta_charge", 0)) < int(p["charge"]):
		return "Needs %d 🧿 casts (you have %d)." % [int(p["charge"]), int(a.get("meta_charge", 0))]
	return ""

## AUTHORITY/SOLO. Resolve a power tap. Returns true if it fired (the caller broadcasts).
## `choice` answers a 3-way pick (Metamagic's shapes, Wild Shape's forms); `t_idx` aims a targeted
## power at an enemy. Both are re-validated here — this is the same trust boundary as a card play.
static func fire(c, seat: int, choice: String, t_idx: int) -> bool:
	var a: Dictionary = c.party[seat]
	if not can_fire(c, a):
		return false
	var p: Dictionary = power_def(a)
	# Validate the pick against the power's OWN option list, never against what the client sent.
	var choices: Array = p.get("choices", [])
	if not choices.is_empty():
		var ok := false
		for o: Dictionary in choices:
			if str(o["key"]) == choice:
				ok = true
		if not ok:
			return false
	var target: Dictionary = {}
	if str(p.get("target", "")) == "enemy":
		if t_idx < 0 or t_idx >= c.enemies.size() or not c.enemies[t_idx]["alive"]:
			return false
		target = c.enemies[t_idx]
	# Pay the lump BEFORE the effect: Communion is the ignition, and a power that fired must have
	# cost something even if its effect no-ops.
	if int(p.get("communion", 0)) > 0:
		a["communion"] = int(a["communion"]) - int(p["communion"])
	match str(a["power"]):
		"action_surge": _fire_surge(c, a)
		"enrage": _fire_enrage(c, a)
		"smite": _fire_smite(c, a, target)
		"bardic_performance": _fire_perform(c, a)
		"wild_shape": _fire_wild_shape(c, a, choice)
		"metamagic": _fire_metamagic(c, a, choice)
		"assassins_mark": _fire_assassins_mark(c, a, target)
		"flurry": _fire_flurry(c, a, target)
		_: return false
	a["power_turn"] = int(c.turn)
	c._check_end()
	return true

# ---------------------------------------------------------------- tank
static func _fire_surge(c, a: Dictionary) -> void:
	a["energy"] = int(a["energy"]) + SURGE_ENERGY
	c._draw_cards(a, 1)
	a["power_cd"] = SURGE_CD
	c._flash(a)
	c._log("⏱️ %s surges — +%d ⚡ and a card." % [a["name"], SURGE_ENERGY])

static func _fire_enrage(c, a: Dictionary) -> void:
	a["raging"] = true
	# The grace: firing Enrage cannot fail its own upkeep on the turn it fired. Without it, raging as
	# your last action drops the rage instantly, which reads as the button being broken.
	a["rage_turn"] = int(c.turn)
	c._flash(a)
	c._log("😤 %s flies into a rage — half damage, no Guard." % a["name"])

static func _fire_smite(c, a: Dictionary, target: Dictionary) -> void:
	var dev: int = int(a.get("devotion", 0))
	var bonus: int = int((a["temp"] as Dictionary).get("smite_bonus", 0))
	var dmg: int = SMITE_BASE + SMITE_PER_DEVOTION * dev + bonus
	a["devotion"] = 0
	a["temp"]["smite_bonus"] = 0
	a["power_cd"] = SMITE_CD
	c._attack(a, target, dmg, false)   # a power, not an attack card: no Channel/Aura, no Momentum
	for x: Dictionary in c.party:
		if x["alive"]:
			c._gain_guard(x, SMITE_PARTY_BLOCK)
	c._log("🌟 %s smites %s for %d (spent %d 🙏)." % [a["name"], target.get("name", "?"), dmg, dev])

# ---------------------------------------------------------------- support
static func _fire_perform(c, a: Dictionary) -> void:
	a["performing"] = true
	a["targets_turn"] = []   # the turn you strike up, you still owe the reach
	c._flash(a)
	c._log("🎶 %s strikes up a song — touch %d distinct targets a turn to hold it." % [a["name"], PERFORM_TARGETS])

static func _fire_wild_shape(c, a: Dictionary, form: String) -> void:
	a["form"] = form
	a["shift_turns"] = SHAPE_TURNS
	# The tithe resolves at the START OF YOUR NEXT TURN, not now — you shift, then pay.
	a["tithe_owed"] = 0
	a["tithe_pending"] = true
	c._flash(a)
	c._log("🐾 %s shifts into %s form." % [a["name"], form.capitalize()])

# ---------------------------------------------------------------- dps
static func _fire_metamagic(c, a: Dictionary, pick: String) -> void:
	a["meta_pick"] = pick
	a["meta_charge"] = 0
	c._flash(a)
	# 🧿, not 🌀 — Metamagic's glyph moved in the 2026-07-22 collision pass (see Db.POWERS.metamagic).
	c._log("🧿 %s shapes the next spell: %s." % [a["name"], pick.capitalize()])

static func _fire_assassins_mark(c, a: Dictionary, target: Dictionary) -> void:
	# ONE mark at a time: clear this seat's old one wherever it sits.
	var owner: int = int(a.get("slot", -1))
	for e: Dictionary in c.enemies:
		if int(e.get("am_owner", -1)) == owner:
			_clear_mark(e)
	target["am_owner"] = owner
	target["am_tick"] = AM_TICK
	target["am_turns"] = AM_TURNS
	c._flash(target)
	c._log("🎯 %s marks %s — %d a turn, ignores armour." % [a["name"], target.get("name", "?"), AM_TICK])

static func _fire_flurry(c, a: Dictionary, target: Dictionary) -> void:
	a["power_cd"] = FLURRY_CD
	# FLAT damage, deliberately. Scaling it off a per-turn meter would make every refunded re-cast
	# weaker than the last, which kills the exact loop the power exists to create.
	c._attack(a, target, FLURRY_DMG, false)
	c._log("👊 %s flurries %s for %d — land a status and get it back." % [a["name"], target.get("name", "?"), FLURRY_DMG])

static func _clear_mark(e: Dictionary) -> void:
	e["am_owner"] = -1
	e["am_tick"] = 0
	e["am_turns"] = 0

# ================================================================ Hooks
## Every hook is fired from ONE place in the engine, next to the state it reads. Same reasoning as the
## M3b fx rider: put the recording inside the primitive and every present and future call site is
## covered by construction, with no second path to forget.

## Any card, any seat, just resolved. This is the Cleric's whole power and the Sorcerer's whole gate.
static func on_card_resolved(c, a: Dictionary, def: Dictionary) -> void:
	# --- Sorcerer: a SPELL charges every sorcerer in the party, whoever cast it. Reading the resolving
	# card's school (not the actor's class) is what makes an ally's Mend charge your Metamagic.
	if str(def.get("school", "")) == "spell":
		for x: Dictionary in c.party:
			if x["alive"] and str(x.get("power", "")) == "metamagic":
				x["meta_charge"] = mini(META_READY, int(x.get("meta_charge", 0)) + 1)
	# --- Cleric: the aura reads the CASTER's own card types. Attacks feed 🔥 smite, everything else
	# feeds 🙏 mercy. A streak of one side pays more with each repeat; switching resets it to 1. That
	# is the whole "commit to a line" rule: 5 pure = 1+2+3+4+5 = 15, 5 alternating = 1+1+1+1+1 = 5.
	if str(a.get("power", "")) == "channel_divinity":
		var side: String = "smite" if def.get("is_attack", false) else "mercy"
		if side == str(a.get("cast_side", "")):
			a["streak"] = int(a.get("streak", 0)) + 1
		else:
			a["streak"] = 1
			a["cast_side"] = side
		a[side + "_charge"] = int(a.get(side + "_charge", 0)) + int(a["streak"])
		a["casts"] = int(a.get("casts", 0)) + 1
		if int(a["casts"]) % CHANNEL_EVERY == 0:
			_discharge_channel(c, a)

static func _discharge_channel(c, a: Dictionary) -> void:
	var mercy: int = int(a.get("mercy_charge", 0))
	var smite: int = int(a.get("smite_charge", 0))
	if mercy > 0:
		for x: Dictionary in c.party:
			if x["alive"]:
				x["hp"] = mini(int(x["max_hp"]), int(x["hp"]) + mercy)
	if smite > 0:
		for e: Dictionary in c.enemies:
			if e["alive"]:
				c._attack(a, e, smite, false)
	a["mercy_charge"] = 0
	a["smite_charge"] = 0
	c._flash(a)
	c._log("✨ %s's aura discharges — heal %d, smite all %d." % [a["name"], mercy, smite])

## An attack of `a`'s just landed on `enemy`. The Assassin's Mark is fed from BOTH ends here.
## NOTE this may run on an enemy the hit just killed — harmless only because every reader of the mark
## gates on `alive`. That is the invariant this placement depends on, so it is stated, not assumed.
static func on_attack_landed(_c, a: Dictionary, enemy: Dictionary) -> void:
	if int(enemy.get("am_turns", 0)) <= 0:
		return
	if int(enemy.get("am_owner", -1)) == int(a.get("slot", -2)):
		enemy["am_tick"] = int(enemy["am_tick"]) + AM_OWNER_TICK    # you make it HURT
	else:
		enemy["am_turns"] = int(enemy["am_turns"]) + AM_ALLY_TURNS  # your party keeps it ALIVE

## A status just landed on an enemy — from anyone, by any route. The entire Monk.
static func on_status_applied(c, _enemy: Dictionary) -> void:
	for x: Dictionary in c.party:
		if not x["alive"] or str(x.get("power", "")) != "flurry":
			continue
		if int(x.get("power_turn", -99)) != int(c.turn):
			continue   # you only get refunds on a turn you actually flurried
		# Ending your turn is a FORFEIT — _authority_set_ready discards your hand for exactly this
		# reason. The Monk who ends first ends its own combo, and that tension is the design.
		if c._seat_ended(int(x.get("slot", -1))):
			continue
		if int(x.get("power_cd", 0)) > 0:
			x["power_cd"] = 0
			c._log("👊 A status lands — %s's fists come back." % x["name"])

## A card just resolved against a target address. The Bard's song is held with this and nothing else:
## (target_kind, target_idx) is ALREADY the distinct-target key the host validates every play with, so
## "an AoE counts as 1" is not a special case anyone writes — an AoE carries ONE address (kind="all",
## idx=-1), so it can only ever add one entry. Same static pair the fx rider ships as side+slot.
static func on_target_touched(_c, a: Dictionary, target_kind: String, target_idx: int) -> void:
	if not bool(a.get("performing", false)):
		return
	var key: String = "%s:%d" % [target_kind, target_idx]
	var t: Array = a.get("targets_turn", [])
	if not (key in t):
		t.append(key)
		a["targets_turn"] = t

# ================================================================ Turn flow
## Start of a player phase, per living dwarf, BEFORE the hand is drawn.
## Ordering matters exactly once, and this is it: a Heightened spell has to fire before the draw, or
## the hand it was meant to set up is already dealt.
static func on_phase_start_pre_draw(c, a: Dictionary) -> void:
	a["power_cd"] = maxi(0, int(a.get("power_cd", 0)) - 1)
	a["targets_turn"] = []
	# Regrowth's delayed half.
	var regen: int = int(a.get("regen", 0))
	if regen > 0:
		a["hp"] = mini(int(a["max_hp"]), int(a["hp"]) + regen)
		a["regen"] = 0
	_resolve_held_spell(c, a)

## Heighten: the held spell fires TWICE, now, before the draw. It is the only thing in the game that
## deliberately does nothing on the turn you pay for it.
static func _resolve_held_spell(c, a: Dictionary) -> void:
	var cid: String = str(a.get("held_cid", ""))
	if cid == "":
		return
	a["held_cid"] = ""
	var idx: int = int(a.get("held_idx", -1))
	a["held_idx"] = -1
	var def: Dictionary = Db.CARDS.get(cid, {})
	if def.is_empty():
		return
	var aoe: bool = str(def.get("target", "")) == "all_enemies"
	# The target may simply be gone by now — a held spell is a bet on next turn's board. Only a
	# SINGLE-target spell can be orphaned though: an AoE never had an idx to lose (combat.gd stores
	# -1 for it), so testing "all_enemies" here would silently eat every held Entangle.
	var target: Dictionary = {}
	if not aoe:
		if idx >= 0 and idx < c.enemies.size() and c.enemies[idx]["alive"]:
			target = c.enemies[idx]
		elif str(def.get("target", "")) == "enemy":
			c._log("⏳ %s's held %s finds nothing left to hit." % [a["name"], def["name"]])
			return
	c._log("⏳ %s's held %s lands — twice." % [a["name"], def["name"]])
	for i: int in range(2):
		if aoe:
			# Fan it the way _apply_play does, rather than handing _resolve one enemy and hoping.
			for e: Dictionary in c.enemies:
				if e["alive"]:
					c._resolve(def, a, e)
		else:
			c._resolve(def, a, target)
	# Nothing in _resolve's chain checks the end state, so a Heighten kill would otherwise leave a
	# board with no living enemies sitting in playerTurn until someone ended a turn.
	c._check_end()

## Start of a player phase, per living dwarf, AFTER the hand is drawn. The Druid's form reads the hand
## it was just dealt, so it has to be here.
static func on_phase_start_post_draw(c, a: Dictionary) -> void:
	if int(a.get("shift_turns", 0)) <= 0:
		return
	a["shift_turns"] = int(a["shift_turns"]) - 1
	if bool(a.get("tithe_pending", false)):
		a["tithe_pending"] = false
		a["tithe_owed"] = SHAPE_TITHE
		c._log("🐾 %s owes the form %d cards — tap them to hand them back." % [a["name"], SHAPE_TITHE])
	_form_payout(c, a)
	if int(a["shift_turns"]) <= 0:
		c._log("🐾 %s slips back into dwarf shape." % a["name"])
		a["form"] = ""
		a["tithe_owed"] = 0

## The payout is on the DRAW, not the play: you are paid for HOLDING the right schools, not spending
## them — which is exactly why the two you tithe are the two your form was never going to pay for.
static func _form_payout(c, a: Dictionary) -> void:
	var n := 0
	for cid: String in a["hand"]:
		if str((Db.CARDS[cid] as Dictionary).get("school", "")) == _form_school(str(a.get("form", ""))):
			n += 1
	if n <= 0:
		return
	match str(a.get("form", "")):
		"bear":
			c._gain_guard(a, n * BEAR_GUARD)
			c._log("🐻 Bear reads %d 🛡️ in hand — +%d Guard, free." % [n, n * BEAR_GUARD])
		"hawk":
			for x: Dictionary in c.party:
				if x["alive"]:
					c._gain_guard(x, n * HAWK_PARTY_BLOCK)
			c._log("🦅 Hawk reads %d 🧿 in hand — +%d block to the party." % [n, n * HAWK_PARTY_BLOCK])
		"wolf":
			a["temp"]["next_attack_bonus"] = int(a["temp"].get("next_attack_bonus", 0)) + n * WOLF_ATK
			c._log("🐺 Wolf reads %d ⚔️ in hand — first attack +%d." % [n, n * WOLF_ATK])

static func _form_school(form: String) -> String:
	match form:
		"bear": return "block"
		"hawk": return "spell"
		"wolf": return "physical"
		_: return ""

## Once per player phase, after every dwarf has drawn. The Bard's aura is the shipped Aura of Valor
## mechanism reused verbatim — party_attack_buff is already the "+N to every ally's attack this turn"
## channel, so the song rides it instead of inventing a parallel one.
static func on_phase_start_party(c) -> void:
	for a: Dictionary in c.party:
		if not a["alive"] or not bool(a.get("performing", false)):
			continue
		c.party_attack_buff += PERFORM_ATK
		for x: Dictionary in c.party:
			if x["alive"]:
				c._gain_guard(x, PERFORM_BLOCK)
		c._log("🎶 %s's song plays on — allies +%d attack, +%d block." % [a["name"], PERFORM_ATK, PERFORM_BLOCK])

## This seat just ended its turn. The upkeep for both stances that have one.
## Co-op ends per seat and in any order, so this is per SEAT — there is no party-wide end of turn to
## hang it on, and inventing one would mean a Barbarian's rage lapsed on someone else's clock.
static func on_seat_upkeep(c, a: Dictionary) -> void:
	# Barbarian: rage holds only while you attack. `momentum` already counts exactly that (it is bumped
	# per attack card in _finish_play and zeroed each phase), so no new field is invented for it.
	if bool(a.get("raging", false)) and int(a.get("rage_turn", -99)) != int(c.turn) and int(a.get("momentum", 0)) == 0:
		a["raging"] = false
		a["power_cd"] = ENRAGE_CD
		c._flash(a)
		c._log("😤 %s's rage guttered out — no blood this turn." % a["name"])
	# Bard: the song is held by REACH. Come up short and it breaks.
	if bool(a.get("performing", false)):
		var n: int = (a.get("targets_turn", []) as Array).size()
		if n < PERFORM_TARGETS:
			a["performing"] = false
			a["power_cd"] = PERFORM_CD
			c._flash(a)
			c._log("🎶 %s's song breaks — only %d of %d targets touched." % [a["name"], n, PERFORM_TARGETS])

## Enemy phase, before the enemies act — the Assassin's Mark bleeds. It IGNORES ARMOUR, so it writes
## hp directly and never routes through _deal_enemy (which subtracts block first). Burn already ticks
## exactly this way in _enemy_phase; this is the same precedent, not a new one.
static func tick_marks(c) -> bool:
	var any := false
	for e: Dictionary in c.enemies:
		if not e["alive"] or int(e.get("am_turns", 0)) <= 0:
			continue
		var tick: int = int(e.get("am_tick", 0))
		e["hp"] = maxi(0, int(e["hp"]) - tick)
		if int(e["hp"]) <= 0:
			e["alive"] = false
		e["am_turns"] = int(e["am_turns"]) - 1
		c._flash(e)
		c._impact(e, tick)
		c._log("🎯 %s bleeds %d (armour ignored)." % [e["name"], tick])
		if int(e["am_turns"]) <= 0:
			_clear_mark(e)
		any = true
	return any

# ================================================================ Read hooks (the engine asks)
## Barbarian: resistance REPLACES block, so a raging dwarf simply cannot gain Guard — including from
## an ally's Consecrate landing on him, which is the correct read of "no longer gain Guard".
static func blocks_guard(a: Dictionary) -> bool:
	return bool(a.get("raging", false))

## Half damage while raging. CEIL, not floor: flooring makes a 1-damage chip free, which reads as a bug.
static func incoming_scale(t: Dictionary, raw: int) -> int:
	if bool(t.get("raging", false)):
		return int(ceil(raw / 2.0))
	return raw

## The Barbarian's +4 while Bloodied, folded in with the other FLAT attack bonuses so it lands before
## the xMark multiply — base -> +flat -> xMark is the house resolution order.
static func attack_flat_bonus(a: Dictionary) -> int:
	if bool(a.get("raging", false)) and int(a["hp"]) * 2 <= int(a["max_hp"]):
		return ENRAGE_BLOODIED
	return 0

## Quicken. Consumed on SCHOOL MATCH, never on a cost delta: `empower` is a live 0-cost spell in the
## Sorcerer's own reward pool, and maxi(0, 0-2) == 0 == its printed cost, so a delta check would
## silently never fire and the pick would survive the spell it was meant to shape.
static func cost_of(a: Dictionary, def: Dictionary) -> int:
	var raw: Variant = def.get("cost", 0)
	if typeof(raw) == TYPE_STRING:
		return 0   # X — priced at whatever the pool holds; _spend stamps what was actually paid
	var cost: int = int(raw)
	if str(a.get("meta_pick", "")) == "quicken" and str(def.get("school", "")) == "spell":
		cost = maxi(0, cost - QUICKEN_OFF)
	return cost

static func is_x_cost(def: Dictionary) -> bool:
	return typeof(def.get("cost", 0)) == TYPE_STRING

extends RefCounted
## (preloaded by combat.gd as Syn; no class_name to avoid global-class collision)
##
## THE SYNERGY ENGINE — every device that makes one body worth more than its own health bar.
##
## WHY THIS FILE EXISTS: a balance rig (scripts/test/skill_gap.gd) decomposed a planner bot's edge
## over a greedy one and found aiming heals worth 95%, blocking to the telegraph 33%, and CHOOSING
## TARGETS 0%. Target choice was free because no body was ever worth more than its own HP. Every
## device below prices a target. Each one must also be VISIBLE BEFORE the player commits — a
## conditional the player cannot see is just an unfair number.
##
## THREE PROPERTIES THIS MODULE IS BUILT AROUND, in order of how expensive they are to lose:
##
##  1. PURE FUNCTIONS OVER THE BOARD. Nothing here stores state and nothing here mutates anything.
##     Every device is DERIVED from board state that already crosses the wire (alive · hp · archetype
##     · slot · rage). The game is host-authoritative over Supabase and ships ABSOLUTE snapshots, so
##     a stored synergy field would need a wire key, and any int leaf that crosses the wire has to
##     join combat.gd's _INT_KEYS or it arrives as a float. Deriving costs one loop over an array of
##     at most a handful of dicts and avoids all of it.
##
##  2. ONE NUMBER, TWO CALLERS. `effective_dmg()` is what the resolver hits with AND what the intent
##     label prints. That is the whole reason the telegraph is structurally incapable of lying:
##     there is no second code path to forget to update. It replaces combat.gd's `_move_dmg`, which
##     already had exactly this property (mv.dmg + rage, called by resolver and label alike) — do not
##     break it by folding a bonus in at a call site instead of in here.
##
##  3. AEGIS AND CHORUS POINT IN OPPOSITE DIRECTIONS AND MUST NEVER SHARE A FUNCTION.
##     AEGIS is a reduction on the enemy TAKING a hit -> `incoming_reduction()`.
##     CHORUS is a bonus on the enemy DEALING one -> folded into `effective_dmg()`.
##     They read the same `aura` data key and it is genuinely easy to fold them together by accident;
##     the result would be an enemy that shrugs off damage because its friend hits hard. Kept apart
##     on purpose, and this comment is the reason why.
##
## DATA vs IDS: the two AURAS (aegis/chorus) are DATA — an `aura` key on the enemy entry — precisely
## so a new body can join a synergy without touching code. The NAMED devices below (gorge, regalia,
## molt, twin_bond, alone_gate) are about specific bodies by definition — the Maw's whole identity is
## "prices your kills" — so they name archetype ids, and that is not the same mistake.
##
## DEFENSIVE BY CONTRACT: every func here tolerates an empty array, a dict missing any key, and a
## dead source. This module is called from the RENDER PATH every frame; a null-deref here does not
## throw an error somewhere quiet, it freezes the board.

const Db := preload("res://scripts/combat/card_db.gd")

# ---- aura kinds (the `aura` data key: {"kind": ..., "amt": ...}) ----
const AEGIS := "aegis"     # every OTHER enemy takes N less per hit. NEVER STACKS — take the max.
const CHORUS := "chorus"   # every OTHER enemy's attack damage rises. Vanishes the instant it dies.

# ---- the named devices ----
const GORGE_PER_CORPSE := 3
const GORGE_CAP := 12
const REGALIA_GAZE_BASE := 3
const REGALIA_GAZE_PER_CRYSTAL := 2
const REGALIA_BOSS_REDUCTION := 3
## The Molt-King is two fights in one body and the seam is the crack meter. Both halves are ONE
## number each so the seam is legible: before the molt it wears a carapace (takes less per hit),
## after it, it is faster and hits harder. Same beats, different fight — which is exactly the
## promise the bestiary makes. ⚠ UNSIMMED: dorf_sim.py has never seen either number.
const MOLT_CARAPACE := 3
const MOLT_FURY := 3
const SWARM_MIN := 3   # "3+ IDENTICAL contiguous minions" — two of a thing is not a swarm

# Archetype ids the named devices key off. Consts rather than inline literals so a rename is one
# edit and a typo is a parse-time-visible constant, not a silently-false condition.
const ID_MAW := "the_maw"
const ID_WOLF := "wolf"
const ID_WITCH := "witch"
const ID_CASTER := "caster"
const ID_CRYSTAL := "rune_crystal"
const ID_OVERSEER := "overseer"
const ID_MOLT_KING := "molt_king"

const DMG_KINDS := ["attack", "multi", "attack_all"]

# ================================================================ Board readers (private)
## Every accessor below reads the INSTANCE dict first and falls back to the static Db entry.
## Why both: `aura` and `tier` are authored in Db.ENEMIES and combat.gd's builder does not copy them
## onto the instance (it has no reason to — archetype already crosses the wire and Db is present on
## every peer). Reading the instance first costs nothing and means a test fixture, a future variant
## body, or a scaled instance can override without this module caring which.

static func _arch(e: Dictionary) -> String:
	return str(e.get("archetype", ""))

static func _def(e: Dictionary) -> Dictionary:
	var d: Variant = Db.ENEMIES.get(_arch(e), {})
	return d if d is Dictionary else {}

static func _alive(e: Dictionary) -> bool:
	return bool(e.get("alive", false))

## The `aura` tag, or {}. A missing/malformed tag is simply "no aura" — never an error.
static func _aura_of(e: Dictionary) -> Dictionary:
	var a: Variant = e.get("aura", null)
	if not (a is Dictionary):
		a = _def(e).get("aura", null)
	if not (a is Dictionary):
		return {}
	return a

static func _tier(e: Dictionary) -> String:
	if e.has("tier"):
		return str(e["tier"])
	return str(_def(e).get("tier", ""))

## Identity, for "every OTHER enemy" exclusions. Deliberately NOT `==` and NOT `is_same`:
## Dictionary equality in Godot 4 compares contents (two identical bats would read as the same body),
## and reference identity breaks the moment a caller hands us a copy rebuilt from a snapshot. The
## (archetype, slot) pair is the same static wire address the fx rider ships, so it survives both.
static func _same_body(a: Dictionary, b: Dictionary) -> bool:
	return _arch(a) == _arch(b) and int(a.get("slot", -1)) == int(b.get("slot", -2))

# ================================================================ Auras
## The live source of an aura kind, or {}. Returned as the ENEMY dict so a tooltip can name it and
## an intent label can tint in its colour. Dead sources are invisible here, which IS the device:
## kill the Shellback and the aegis is gone the same instant.
static func aura_source(enemies: Array, kind: String) -> Dictionary:
	return _aura_source_excluding(enemies, kind, {})

## The amount an aura of `kind` currently applies to `to` — the max across live sources, never a sum.
## Rule 1 of the synergy contract says exactly one source of each kind is ever rolled onto a board;
## this takes the max anyway, because "aegis does not stack" has to be true of the CODE, not of the
## encounter tables. A second source slipping through must be a no-op, not a doubling.
static func aura_amount(enemies: Array, kind: String, to: Dictionary) -> int:
	var src: Dictionary = _aura_source_excluding(enemies, kind, to)
	if src.is_empty():
		return 0
	return maxi(0, int(_aura_of(src).get("amt", 0)))

static func _aura_source_excluding(enemies: Array, kind: String, exclude: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	var best_amt: int = 0
	for e: Variant in enemies:
		if not (e is Dictionary):
			continue
		var en: Dictionary = e
		if not _alive(en):
			continue
		if not exclude.is_empty() and _same_body(en, exclude):
			continue   # "every OTHER enemy" — a source never buffs or shields itself
		var a: Dictionary = _aura_of(en)
		if str(a.get("kind", "")) != kind:
			continue
		var amt: int = int(a.get("amt", 0))
		if amt > best_amt:
			best_amt = amt
			best = en
	return best

## Chorus, from the perspective of the enemy DEALING damage. Public because the intent label needs to
## know whether to tint: the contract says a boosted label prints the BUFFED TOTAL ("12", never
## "9 (+3)") in the source's colour, so the UI asks this for >0 and `aura_source` for the colour.
static func chorus_bonus(enemies: Array, e: Dictionary) -> int:
	return aura_amount(enemies, CHORUS, e)

## Aegis (and the two boss-shaped reductions), from the perspective of the enemy BEING HIT: how much
## less it takes PER HIT. See property 3 at the top — this is the opposite direction from chorus.
##
## The three reductions are MAXed, never summed, for the same reason aegis does not stack with itself:
## a player who is told "3 less per hit" and observes 6 has been lied to, and every one of these is a
## flat per-hit soak that a multi-hit card already pays repeatedly.
static func incoming_reduction(enemies: Array, e: Dictionary) -> int:
	var red: int = aura_amount(enemies, AEGIS, e)
	# The Overseer cannot be meaningfully damaged while its regalia stands.
	if _arch(e) == ID_OVERSEER and int(regalia(enemies).get("boss_reduction", 0)) > 0:
		red = maxi(red, REGALIA_BOSS_REDUCTION)
	# The Molt-King's carapace — the first half of the fight, and it is PERMANENTLY gone after.
	if _arch(e) == ID_MOLT_KING and not molted(e):
		red = maxi(red, MOLT_CARAPACE)
	return maxi(0, red)

# ================================================================ THE one number
## The damage one hit of `mv` actually deals, folding EVERY outgoing modifier in one place: the
## Shriek doubling, Howl rage, chorus, gorge and the molt. `base` is the move's own printed damage
## (already pre-scaled by dscale at build time), i.e. what combat.gd's `_move_dmg` used to read.
##
## Both the resolver and the telegraph call this and nothing else. Adding a modifier anywhere but
## here makes the intent label lie, and a lying telegraph makes the whole grammar worthless.
static func effective_dmg(enemies: Array, e: Dictionary, mv: Dictionary, base: int) -> int:
	# A move that deals nothing keeps dealing nothing. Chorus AMPLIFIES an attack, it never creates
	# one: the 💎 Rune Crystal's whole identity is "deals ZERO damage and is still the most urgent
	# body", and a chorus that quietly gave it 3 would delete that reading.
	if base <= 0:
		return 0
	var dmg: int = base
	# The Shriek doubling is an outgoing modifier like any other, so it belongs in here rather than
	# in a caller — it is doubled FIRST because it is the move's own identity changing, and the flat
	# adders below are the board's contribution on top.
	if _shriek_doubles(enemies, e, mv):
		dmg *= 2
	dmg += int(e.get("rage", 0))            # Howl (rage_all), permanent, capped by combat.gd
	dmg += chorus_bonus(enemies, e)         # vanishes the instant the source dies
	dmg += gorge_bonus(enemies, e)          # the Maw prices your kills
	if _arch(e) == ID_MOLT_KING and molted(e):
		dmg += MOLT_FURY                    # the carapace is off; the same beats hit harder
	return maxi(0, dmg)

# ================================================================ The named devices
## ALONE GATE — the 🔮 Caster, cornered. Last one standing and every beat resolves as its heaviest
## attack instead of Ward/Zap, so "leave the caster for last" stops being free.
##
## The substituted move is DERIVED from the Caster's own rotation (its biggest damage beat) rather
## than written out here with a number. Two reasons: combat.gd pre-scales every move's damage by
## dscale at build time, so a literal would be wrong in every scaled fight; and the bestiary owns
## that number, so deriving means a restat can never leave this module printing a stale one.
## ⚠ The design text says "Bolt 12" while the shipped Caster's Bolt is 10 pre-scale. Deriving keeps
## whatever card_db authors — if 12 is wanted, it is a card_db edit, not an edit here.
##
## Returns the move BY REFERENCE (no duplicate): this is called per frame from the render path and
## moves are treated read-only everywhere in combat.gd (the builder already duplicated them once).
static func alone_gate(enemies: Array, e: Dictionary) -> Dictionary:
	if _arch(e) != ID_CASTER or not _alive(e):
		return {}
	for o: Variant in enemies:
		if not (o is Dictionary):
			continue
		var on: Dictionary = o
		if _alive(on) and not _same_body(on, e):
			return {}   # not alone
	var best: Dictionary = {}
	var best_dmg: int = -1
	for m: Variant in e.get("moves", []):
		if not (m is Dictionary):
			continue
		var mv: Dictionary = m
		if not (str(mv.get("kind", "")) in DMG_KINDS):
			continue
		var d: int = int(mv.get("dmg", 0))
		if d > best_dmg:
			best_dmg = d
			best = mv
	return best

## TWIN BOND — 🐺 and 🧿 rolled together, and the survivor changes when the other dies. ASYMMETRIC on
## purpose: which one you kill first is the decision, so the two outcomes must not be interchangeable.
##   Wolf dead  -> the Witch's Shriek DOUBLES.
##   Witch dead -> the Wolf HOWLS EVERY BEAT.
## Derived from the alive flags only. Storing "who died first" would be a wire field for information
## the board already carries — and it is not even needed, because the bond is about who is LEFT.
##
## Returned flags are relative to `e` ("what does THIS body do differently"), so a caller never has
## to work out which half applies to whom. With two wolves on the board the bond breaks only when the
## last one falls: the pack is still a pack while any of it is standing.
static func twin_bond(enemies: Array, e: Dictionary) -> Dictionary:
	var out: Dictionary = {"shriek_x2": false, "howl_every_beat": false}
	var has_wolf := false
	var has_witch := false
	var wolf_alive := false
	var witch_alive := false
	for o: Variant in enemies:
		if not (o is Dictionary):
			continue
		var on: Dictionary = o
		match _arch(on):
			ID_WOLF:
				has_wolf = true
				wolf_alive = wolf_alive or _alive(on)
			ID_WITCH:
				has_witch = true
				witch_alive = witch_alive or _alive(on)
	# Both must have been PRESENT for there to be a bond at all — a lone witch is just a witch.
	if not (has_wolf and has_witch):
		return out
	if not _alive(e):
		return out
	match _arch(e):
		ID_WITCH:
			out["shriek_x2"] = not wolf_alive
		ID_WOLF:
			out["howl_every_beat"] = not witch_alive
	return out

## The Shriek IS the Witch's attack_all beat. Matched on kind rather than on the move's name so a
## renamed or re-tipped beat still doubles (names are display text; kind is the contract).
static func _shriek_doubles(enemies: Array, e: Dictionary, mv: Dictionary) -> bool:
	if _arch(e) != ID_WITCH or str(mv.get("kind", "")) != "attack_all":
		return false
	return bool(twin_bond(enemies, e).get("shriek_x2", false))

## GORGE — 🐙 The Maw prices your kills: +3 per corpse on the board, capped at +12. The corpse count
## is derived from the enemies array (the board only ever shrinks, so a dead body never leaves it and
## the count can never be wrong). Capped so a swarm fight cannot turn it into a one-shot.
static func gorge_bonus(enemies: Array, e: Dictionary) -> int:
	if _arch(e) != ID_MAW:
		return 0
	var corpses: int = 0
	for o: Variant in enemies:
		if o is Dictionary and not _alive(o):
			corpses += 1
	return mini(GORGE_CAP, corpses * GORGE_PER_CORPSE)

## REGALIA — 💎 crystals standing in the 👀 Overseer fight. Gaze scales with the crystals and the boss
## shrugs off hits while any stand, which is what "cannot be meaningfully damaged until you kill its
## crystals" means in numbers. `gaze` is the BASE damage of the Gaze beat: run it through
## effective_dmg() like any other base so the one-number rule still holds.
static func regalia(enemies: Array) -> Dictionary:
	var crystals: int = 0
	for o: Variant in enemies:
		if o is Dictionary and _alive(o) and _arch(o) == ID_CRYSTAL:
			crystals += 1
	return {
		"crystals": crystals,
		"gaze": REGALIA_GAZE_BASE + REGALIA_GAZE_PER_CRYSTAL * crystals,
		# Unconditional on the Overseer being present: only the Overseer path reads it (see
		# incoming_reduction), and gating it here would make this func's answer depend on which
		# other bodies happen to be rolled, which is exactly the kind of hidden condition this
		# module exists to avoid.
		"boss_reduction": REGALIA_BOSS_REDUCTION if crystals > 0 else 0,
	}

## MOLT — at or below half HP the carapace is gone, permanently. Written as the pure half-HP
## predicate the contract specifies, so the crack meter can ask it about any body; the ARCHETYPE gate
## lives in the two places that fold it (effective_dmg / incoming_reduction), which keeps this
## honest for a UI that wants a generic "cracked" read.
## Integer form (hp*2 <= max_hp) rather than a divide: no float rounding to argue about at odd max HP.
static func molted(e: Dictionary) -> bool:
	var max_hp: int = int(e.get("max_hp", 0))
	if max_hp <= 0:
		return false
	return int(e.get("hp", 0)) * 2 <= max_hp

## SWARM — 3+ IDENTICAL contiguous living minions share a start offset and collapse their per-body
## intent labels into one bracketed line: 🦇x4 🗡️3>Sor (12).
##
## Contiguity is over SLOT ORDER (the array index is the wire address), and a run is broken by any
## body that is dead, a different archetype, or not a minion. Strict on purpose: the collapsed label
## is drawn as one span across adjacent portraits, so a "group" with a gap in it would render over a
## body that is not in it. A swarm that loses a member correctly falls back to per-body labels —
## which is also the honest read, since the survivors are no longer acting as one block on screen.
static func swarm_groups(enemies: Array) -> Array:
	var groups: Array = []
	var i: int = 0
	while i < enemies.size():
		var e: Variant = enemies[i]
		if not (e is Dictionary) or not _alive(e) or _tier(e) != "minion":
			i += 1
			continue
		var arch: String = _arch(e)
		var slots: Array = [int((e as Dictionary).get("slot", i))]
		var j: int = i + 1
		while j < enemies.size():
			var o: Variant = enemies[j]
			if not (o is Dictionary) or not _alive(o) or _arch(o) != arch or _tier(o) != "minion":
				break
			slots.append(int((o as Dictionary).get("slot", j)))
			j += 1
		if slots.size() >= SWARM_MIN:
			groups.append({"slots": slots, "archetype": arch, "count": slots.size()})
		# Jump to the end of the run either way: it was maximal, so nothing inside it can start a
		# longer one, and re-scanning from i+1 would emit overlapping groups for a run of 4+.
		i = j
	return groups

# ================================================================ Readout
## Everything currently LIVE on this board, in the order a player would want to read it. Feeds the
## design-notes popup and the enemy tooltips — one source of truth for "what is this board doing to
## me", so a device can never ship visible in the numbers and invisible in the text.
##
## SHAPE: Array[Dictionary] of {"key": String, "text": String}. `key` is the device id (aegis ·
## chorus · alone_gate · twin_bond · gorge · regalia · molt · swarm) so a tooltip can filter to the
## devices touching one body; `text` is the player-facing sentence. Dictionaries rather than plain
## strings because a tooltip needs the filter and a popup can just join the texts.
static func active_devices(enemies: Array) -> Array:
	var out: Array = []
	if enemies.is_empty():
		return out

	var aegis_src: Dictionary = aura_source(enemies, AEGIS)
	if not aegis_src.is_empty():
		out.append({"key": AEGIS, "text": "%s %s's aegis: every OTHER enemy takes %d less per hit." % [
			str(aegis_src.get("emoji", "")), str(aegis_src.get("name", "?")),
			int(_aura_of(aegis_src).get("amt", 0))]})

	var chorus_src: Dictionary = aura_source(enemies, CHORUS)
	if not chorus_src.is_empty():
		out.append({"key": CHORUS, "text": "%s %s's chorus: every OTHER enemy hits for +%d. Kill it and the bonus is gone." % [
			str(chorus_src.get("emoji", "")), str(chorus_src.get("name", "?")),
			int(_aura_of(chorus_src).get("amt", 0))]})

	for o: Variant in enemies:
		if not (o is Dictionary):
			continue
		var e: Dictionary = o
		if not alone_gate(enemies, e).is_empty():
			out.append({"key": "alone_gate", "text": "%s %s is cornered — every beat is its heaviest spell now." % [
				str(e.get("emoji", "")), str(e.get("name", "?"))]})
		var bond: Dictionary = twin_bond(enemies, e)
		if bool(bond.get("shriek_x2", false)):
			out.append({"key": "twin_bond", "text": "%s %s mourns the pack — its Shriek hits TWICE as hard." % [
				str(e.get("emoji", "")), str(e.get("name", "?"))]})
		if bool(bond.get("howl_every_beat", false)):
			out.append({"key": "twin_bond", "text": "%s %s lost its witch — it howls every single beat." % [
				str(e.get("emoji", "")), str(e.get("name", "?"))]})
		var gorge: int = gorge_bonus(enemies, e)
		if gorge > 0 and _alive(e):
			out.append({"key": "gorge", "text": "%s %s has gorged on the dead: +%d damage%s." % [
				str(e.get("emoji", "")), str(e.get("name", "?")), gorge,
				" (capped)" if gorge >= GORGE_CAP else ""]})
		if _arch(e) == ID_MOLT_KING and _alive(e):
			if molted(e):
				out.append({"key": "molt", "text": "%s %s has shed its carapace — it takes full damage and hits harder." % [
					str(e.get("emoji", "")), str(e.get("name", "?"))]})
			else:
				out.append({"key": "molt", "text": "%s %s's carapace holds: %d less per hit until it cracks at half HP." % [
					str(e.get("emoji", "")), str(e.get("name", "?")), MOLT_CARAPACE]})
		if _arch(e) == ID_OVERSEER and _alive(e):
			var reg: Dictionary = regalia(enemies)
			if int(reg["crystals"]) > 0:
				out.append({"key": "regalia", "text": "%s %s's regalia: %d 💎 standing — Gaze %d to everyone, and the boss takes %d less per hit." % [
					str(e.get("emoji", "")), str(e.get("name", "?")), int(reg["crystals"]),
					int(reg["gaze"]), int(reg["boss_reduction"])]})

	for g: Variant in swarm_groups(enemies):
		var grp: Dictionary = g
		var first: Dictionary = _first_of(enemies, str(grp.get("archetype", "")))
		out.append({"key": "swarm", "text": "%s x%d move as one swarm." % [
			str(first.get("emoji", "")), int(grp.get("count", 0))]})
	return out

static func _first_of(enemies: Array, arch: String) -> Dictionary:
	for o: Variant in enemies:
		if o is Dictionary and _arch(o) == arch:
			return o
	return {}

# ================================================================ Self test
## Runs with NO scene tree and NO Godot project state: every fixture below is a hand-built dict that
## carries its own `aura`/`tier`, so this passes whether or not card_db has been re-authored yet.
## Returns the list of FAILED assertions — an empty array is a pass.
static func self_test() -> Array:
	var f: Array = []

	# ---- fixtures ---------------------------------------------------------
	var shellback := func(slot: int, alive: bool = true) -> Dictionary:
		return {"archetype": "shellback", "name": "Shellback", "emoji": "🐢", "slot": slot,
			"alive": alive, "hp": 26, "max_hp": 26, "tier": "line", "aura": {"kind": AEGIS, "amt": 3}}
	var warden := func(slot: int, alive: bool = true) -> Dictionary:
		return {"archetype": "warden", "name": "Warden", "emoji": "🗿", "slot": slot,
			"alive": alive, "hp": 40, "max_hp": 40, "tier": "heavy", "aura": {"kind": AEGIS, "amt": 3}}
	var caster := func(slot: int, alive: bool = true) -> Dictionary:
		return {"archetype": ID_CASTER, "name": "Caster", "emoji": "🔮", "slot": slot,
			"alive": alive, "hp": 28, "max_hp": 28, "tier": "line", "aura": {"kind": CHORUS, "amt": 3},
			"moves": [{"name": "Zap", "kind": "attack", "dmg": 5},
				{"name": "Ward", "kind": "block", "amt": 6},
				{"name": "Bolt", "kind": "attack", "dmg": 10}]}
	var wolf := func(slot: int, alive: bool = true) -> Dictionary:
		return {"archetype": ID_WOLF, "name": "Wolf", "emoji": "🐺", "slot": slot,
			"alive": alive, "hp": 22, "max_hp": 22, "tier": "line"}
	var witch := func(slot: int, alive: bool = true) -> Dictionary:
		return {"archetype": ID_WITCH, "name": "Witch", "emoji": "🧿", "slot": slot,
			"alive": alive, "hp": 26, "max_hp": 26, "tier": "line"}
	var bat := func(slot: int, alive: bool = true) -> Dictionary:
		return {"archetype": "cave_bat", "name": "Cave Bat", "emoji": "🦇", "slot": slot,
			"alive": alive, "hp": 6, "max_hp": 6, "tier": "minion"}
	var adder := func(slot: int, alive: bool = true) -> Dictionary:
		return {"archetype": "pit_adder", "name": "Pit Adder", "emoji": "🐍", "slot": slot,
			"alive": alive, "hp": 7, "max_hp": 7, "tier": "minion"}
	var crystal := func(slot: int, alive: bool = true) -> Dictionary:
		return {"archetype": ID_CRYSTAL, "name": "Rune Crystal", "emoji": "💎", "slot": slot,
			"alive": alive, "hp": 14, "max_hp": 14, "tier": "minion", "aura": {"kind": AEGIS, "amt": 3}}
	var maw := func(slot: int, alive: bool = true) -> Dictionary:
		return {"archetype": ID_MAW, "name": "The Maw", "emoji": "🐙", "slot": slot,
			"alive": alive, "hp": 58, "max_hp": 58, "tier": "heavy"}
	var overseer := func(slot: int, alive: bool = true) -> Dictionary:
		return {"archetype": ID_OVERSEER, "name": "The Overseer", "emoji": "👀", "slot": slot,
			"alive": alive, "hp": 90, "max_hp": 90, "tier": "boss"}
	var molt := func(slot: int, hp: int) -> Dictionary:
		return {"archetype": ID_MOLT_KING, "name": "The Molt-King", "emoji": "🦂", "slot": slot,
			"alive": true, "hp": hp, "max_hp": 88, "tier": "boss"}
	var atk := func(d: int) -> Dictionary:
		return {"name": "Hit", "kind": "attack", "dmg": d}

	# ---- 1. aegis does not stack, and dies with its source -----------------
	var one_src: Array = [shellback.call(0), wolf.call(1)]
	if incoming_reduction(one_src, one_src[1]) != 3:
		f.append("aegis: one source should reduce another body by 3, got %d" % incoming_reduction(one_src, one_src[1]))
	if incoming_reduction(one_src, one_src[0]) != 0:
		f.append("aegis: the source must NOT shield itself")
	var two_src: Array = [shellback.call(0), warden.call(1), wolf.call(2)]
	if incoming_reduction(two_src, two_src[2]) != 3:
		f.append("aegis MUST NOT STACK: two sources gave %d, expected 3" % incoming_reduction(two_src, two_src[2]))
	var dead_src: Array = [shellback.call(0, false), wolf.call(1)]
	if incoming_reduction(dead_src, dead_src[1]) != 0:
		f.append("aegis: a dead source must apply nothing")

	# ---- 2. chorus vanishes when its source dies --------------------------
	var ch_live: Array = [caster.call(0), wolf.call(1)]
	if effective_dmg(ch_live, ch_live[1], atk.call(5), 5) != 8:
		f.append("chorus: live caster should raise 5 -> 8, got %d" % effective_dmg(ch_live, ch_live[1], atk.call(5), 5))
	if effective_dmg(ch_live, ch_live[0], atk.call(5), 5) != 5:
		f.append("chorus: the source must not buff itself")
	var ch_dead: Array = [caster.call(0, false), wolf.call(1)]
	if effective_dmg(ch_dead, ch_dead[1], atk.call(5), 5) != 5:
		f.append("chorus MUST VANISH when its source dies, got %d" % effective_dmg(ch_dead, ch_dead[1], atk.call(5), 5))
	# ...and it may never CREATE damage: the Rune Crystal deals zero and must stay at zero.
	var ch_crystal: Array = [caster.call(0), crystal.call(1)]
	if effective_dmg(ch_crystal, ch_crystal[1], atk.call(0), 0) != 0:
		f.append("chorus: a 0-damage move must stay 0")

	# ---- 3. gorge caps at +12 ---------------------------------------------
	var g0: Array = [maw.call(0), wolf.call(1), wolf.call(2)]
	if gorge_bonus(g0, g0[0]) != 0:
		f.append("gorge: no corpses should be +0")
	var g3: Array = [maw.call(0), wolf.call(1, false), wolf.call(2, false), bat.call(3, false)]
	if gorge_bonus(g3, g3[0]) != 9:
		f.append("gorge: 3 corpses should be +9, got %d" % gorge_bonus(g3, g3[0]))
	var g5: Array = [maw.call(0), wolf.call(1, false), wolf.call(2, false), bat.call(3, false),
		bat.call(4, false), bat.call(5, false)]
	if gorge_bonus(g5, g5[0]) != GORGE_CAP:
		f.append("gorge MUST CAP at +12, got %d" % gorge_bonus(g5, g5[0]))
	if gorge_bonus(g5, g5[1]) != 0:
		f.append("gorge: only the Maw gorges")

	# ---- 4. twin_bond is asymmetric ---------------------------------------
	var both: Array = [wolf.call(0), witch.call(1)]
	if bool(twin_bond(both, both[0])["howl_every_beat"]) or bool(twin_bond(both, both[1])["shriek_x2"]):
		f.append("twin_bond: nothing should fire while both live")
	var no_wolf: Array = [wolf.call(0, false), witch.call(1)]
	if not bool(twin_bond(no_wolf, no_wolf[1])["shriek_x2"]):
		f.append("twin_bond: wolf dead must double the Shriek")
	if bool(twin_bond(no_wolf, no_wolf[1])["howl_every_beat"]):
		f.append("twin_bond IS ASYMMETRIC: wolf dead must not grant howl-every-beat")
	var no_witch: Array = [wolf.call(0), witch.call(1, false)]
	if not bool(twin_bond(no_witch, no_witch[0])["howl_every_beat"]):
		f.append("twin_bond: witch dead must make the wolf howl every beat")
	if bool(twin_bond(no_witch, no_witch[0])["shriek_x2"]):
		f.append("twin_bond IS ASYMMETRIC: witch dead must not double anything")
	var lone_witch: Array = [witch.call(0), caster.call(1, false)]
	if bool(twin_bond(lone_witch, lone_witch[0])["shriek_x2"]):
		f.append("twin_bond: no bond without a wolf ever present")
	# the doubling has to land in the ONE number, not just in the flag
	var shriek: Dictionary = {"name": "Shriek", "kind": "attack_all", "dmg": 3}
	if effective_dmg(no_wolf, no_wolf[1], shriek, 3) != 6:
		f.append("twin_bond: Shriek doubling must fold into effective_dmg, got %d" % effective_dmg(no_wolf, no_wolf[1], shriek, 3))

	# ---- 5. swarm needs 3 AND needs contiguity ----------------------------
	var s3: Array = [bat.call(0), bat.call(1), bat.call(2)]
	var gr3: Array = swarm_groups(s3)
	if gr3.size() != 1 or int((gr3[0] as Dictionary)["count"]) != 3:
		f.append("swarm: 3 contiguous bats should be one group of 3")
	var s2: Array = [bat.call(0), bat.call(1), adder.call(2)]
	if not swarm_groups(s2).is_empty():
		f.append("swarm REQUIRES 3: two bats formed a group")
	var split: Array = [bat.call(0), bat.call(1), adder.call(2), bat.call(3)]
	if not swarm_groups(split).is_empty():
		f.append("swarm REQUIRES CONTIGUITY: a split 2+1 run formed a group")
	var broken: Array = [bat.call(0), bat.call(1, false), bat.call(2), bat.call(3)]
	if not swarm_groups(broken).is_empty():
		f.append("swarm: a dead body must break the run")
	var s4: Array = [bat.call(0), bat.call(1), bat.call(2), bat.call(3)]
	var gr4: Array = swarm_groups(s4)
	if gr4.size() != 1 or int((gr4[0] as Dictionary)["count"]) != 4:
		f.append("swarm: a run of 4 must be ONE group, not overlapping ones")
	var not_minions: Array = [wolf.call(0), wolf.call(1), wolf.call(2)]
	if not swarm_groups(not_minions).is_empty():
		f.append("swarm: only minions swarm")

	# ---- 6. alone gate ----------------------------------------------------
	var crowd: Array = [caster.call(0), wolf.call(1)]
	if not alone_gate(crowd, crowd[0]).is_empty():
		f.append("alone_gate: must not fire while an ally lives")
	var alone: Array = [caster.call(0), wolf.call(1, false)]
	var sub: Dictionary = alone_gate(alone, alone[0])
	if int(sub.get("dmg", 0)) != 10:
		f.append("alone_gate: cornered caster should substitute its heaviest beat (10), got %d" % int(sub.get("dmg", 0)))

	# ---- 7. regalia + molt ------------------------------------------------
	var reg2: Array = [overseer.call(0), crystal.call(1), crystal.call(2)]
	var r2: Dictionary = regalia(reg2)
	if int(r2["crystals"]) != 2 or int(r2["gaze"]) != 7 or int(r2["boss_reduction"]) != 3:
		f.append("regalia: 2 crystals should read crystals=2 gaze=7 reduction=3, got %s" % str(r2))
	if incoming_reduction(reg2, reg2[0]) != 3:
		f.append("regalia: the boss must take 3 less while crystals stand")
	var reg0: Array = [overseer.call(0), crystal.call(1, false)]
	var r0: Dictionary = regalia(reg0)
	if int(r0["crystals"]) != 0 or int(r0["gaze"]) != 3 or int(r0["boss_reduction"]) != 0:
		f.append("regalia: no crystals should strip the boss reduction, got %s" % str(r0))
	if incoming_reduction(reg0, reg0[0]) != 0:
		f.append("regalia: the boss must take full damage with every crystal down")
	var intact: Array = [molt.call(0, 88)]
	if molted(intact[0]):
		f.append("molt: a full-HP Molt-King is not molted")
	if incoming_reduction(intact, intact[0]) != MOLT_CARAPACE:
		f.append("molt: the carapace must soak %d before the crack" % MOLT_CARAPACE)
	if effective_dmg(intact, intact[0], atk.call(9), 9) != 9:
		f.append("molt: an intact Molt-King hits for its printed number")
	var cracked: Array = [molt.call(0, 44)]
	if not molted(cracked[0]):
		f.append("molt: exactly half HP must count as molted")
	if incoming_reduction(cracked, cracked[0]) != 0:
		f.append("molt: the carapace is gone after the crack")
	if effective_dmg(cracked, cracked[0], atk.call(9), 9) != 9 + MOLT_FURY:
		f.append("molt: a cracked Molt-King must hit harder")

	# ---- 8. rage still folds in, and the reductions never stack -----------
	var raging: Array = [caster.call(0), wolf.call(1)]
	(raging[1] as Dictionary)["rage"] = 2
	if effective_dmg(raging, raging[1], atk.call(5), 5) != 10:
		f.append("rage+chorus: 5 +2 rage +3 chorus should be 10, got %d" % effective_dmg(raging, raging[1], atk.call(5), 5))
	var stacked: Array = [shellback.call(0), molt.call(1, 88)]
	if incoming_reduction(stacked, stacked[1]) != 3:
		f.append("reductions MUST NOT STACK: aegis+carapace gave %d, expected 3" % incoming_reduction(stacked, stacked[1]))

	# ---- 9. defensive: empty arrays and dicts missing every key -----------
	var nothing: Array = []
	var bare: Dictionary = {}
	if effective_dmg(nothing, bare, bare, 5) != 5:
		f.append("defensive: effective_dmg on empty board/dicts must pass the base through")
	if incoming_reduction(nothing, bare) != 0:
		f.append("defensive: incoming_reduction on an empty board must be 0")
	if not aura_source(nothing, AEGIS).is_empty() or not alone_gate(nothing, bare).is_empty():
		f.append("defensive: lookups on an empty board must return {}")
	if gorge_bonus(nothing, bare) != 0 or molted(bare):
		f.append("defensive: gorge/molt on a bare dict must be 0/false")
	if not swarm_groups(nothing).is_empty() or not active_devices(nothing).is_empty():
		f.append("defensive: swarm_groups/active_devices on an empty board must be empty")
	var junk: Array = [null, 7, "not an enemy", {}]
	if effective_dmg(junk, bare, bare, 4) != 4 or not swarm_groups(junk).is_empty():
		f.append("defensive: a malformed enemies array must not throw or invent a device")
	if not active_devices(junk).is_empty():
		f.append("defensive: a malformed enemies array must list no devices")

	# ---- 10. the readout only ever describes what is live -----------------
	if active_devices(ch_live).is_empty():
		f.append("active_devices: a live chorus must be listed")
	if not active_devices([wolf.call(0), wolf.call(1)]).is_empty():
		f.append("active_devices: a plain board must list nothing")
	return f

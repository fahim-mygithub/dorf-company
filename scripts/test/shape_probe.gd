extends Node
## SHAPE PROBE — how many enemies can combat.gd actually field?
##
## The spec wants variable enemy counts (2 up to ~10, with 3 as the norm) plus a boss slot. The audit
## called this "blocked by architecture"; this probe settles it empirically instead of by reading.
##
## It boots a real fight at each body count and reports whether the board built, whether every enemy
## got a slot, and whether a turn can be played. No bot, no balance — purely structural.
##
## Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://scenes/test/shape_probe.tscn

const COMBAT := preload("res://scenes/combat/combat.tscn")
const Db := preload("res://scripts/combat/card_db.gd")

const POOL := ["brute", "assassin", "caster", "wolf", "warden", "witch", "ogre",
	"wolf", "witch", "assassin"]


func _ready() -> void:
	Engine.time_scale = 60.0
	print("\n============ SHAPE PROBE — enemy count ============")
	print("%-6s | %-9s | %-9s | %-9s | %s" % ["bodies", "built", "slots", "playable", "note"])
	print("-".repeat(74))
	for n: int in [1, 2, 3, 4, 5, 6, 8, 10]:
		await _try(n)
	print("-".repeat(74))
	print("'slots' = enemy dicts that got a live UI node; 'playable' = a card resolved without error")
	print("===================================================\n")
	get_tree().quit(0)


func _try(n: int) -> void:
	var comp: Array = []
	for i: int in range(n):
		comp.append(POOL[i % POOL.size()])
	var crew: Array = [
		{"cls": "warrior", "name": "W"}, {"cls": "cleric", "name": "C"}, {"cls": "sorcerer", "name": "S"}]

	var c: Node = COMBAT.instantiate()
	c.request = {"crew": crew, "enemies": comp, "enemy_scale": 1.0}
	var built := true
	var note := ""
	add_child(c)
	c.visible = false
	await get_tree().process_frame

	# Did every enemy get a UI node? en_emoji is built once in _build_ui.
	var slots: int = 0
	if c.get("en_emoji") != null:
		slots = (c.en_emoji as Array).size()
	var made: int = (c.enemies as Array).size()
	if made != n:
		built = false
		note = "built %d of %d enemy dicts" % [made, n]
	elif slots < n:
		note = "only %d UI slots for %d bodies" % [slots, n]

	# Can a turn actually be played? Play the first affordable card of seat 0 at enemy 0.
	var playable := false
	if str(c.phase) == "playerTurn":
		var a: Dictionary = c.party[0]
		for i: int in range((a["hand"] as Array).size()):
			var cid: String = a["hand"][i]
			var def: Dictionary = Db.CARDS[cid]
			if not c._can_play(a, cid, def):
				continue
			var want: String = str(def.get("target", "self"))
			var kind: String = "self"
			var idx: int = -1
			if want == "enemy":
				kind = "enemy"
				idx = 0
			elif want == "all_enemies":
				kind = "all"
			c._try_play(0, str(a["hand_uids"][i]), kind, idx)
			playable = true
			break
	else:
		note = note if note != "" else "phase was '%s', not playerTurn" % str(c.phase)

	print("%-6d | %-9s | %-9s | %-9s | %s" % [
		n, "yes" if built else "NO", "%d/%d" % [mini(slots, n), n],
		"yes" if playable else "NO", note])

	c.queue_free()
	await get_tree().process_frame

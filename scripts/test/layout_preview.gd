extends Node
## LAYOUT PREVIEW — a visual harness for _enemy_layout. Boots one real fight at BODIES enemies and
## leaves it on screen so the board can be screenshotted. Not a test; an eyeball.
##
## Change BODIES, then: play_scene res://scenes/test/layout_preview.tscn -> get_game_screenshot.

const COMBAT := preload("res://scenes/combat/combat.tscn")

const BODIES := 6
## A SIX-BODY BOARD AT THE ENEMY_MAX CAP, chosen to put every readout on screen at once rather than to
## be a fair fight: a contiguous run of four Cave Bats (the swarm line collapses them), a Caster whose
## chorus tints that line in its own colour, and an Ogre for the third pref badge. Between them the
## board carries all three nameplate badges (🥀 bats+caster, 🧲 ogre), a collapsed swarm line with a
## summed total, and a per-dwarf incoming forecast big enough to show 💀 on the Sorcerer.
## POOL is the comp verbatim now (it used to be cycled with a modulo, which made "which bodies am I
## looking at" a thing you had to compute rather than read).
const POOL := ["cave_bat", "cave_bat", "cave_bat", "cave_bat", "caster", "ogre"]


func _ready() -> void:
	var comp: Array = []
	for i: int in range(BODIES):
		comp.append(POOL[i % POOL.size()])
	var c: Node = COMBAT.instantiate()
	c.request = {
		"crew": [{"cls": "warrior", "name": "Warrior"}, {"cls": "cleric", "name": "Cleric"},
			{"cls": "sorcerer", "name": "Sorcerer"}],
		"enemies": comp, "enemy_scale": 1.0,
	}
	add_child(c)

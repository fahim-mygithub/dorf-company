extends Control
## Co-op verification harness: runs BOTH peers as two combat instances in ONE process.
##
## Why this exists: two browser tabs can't verify the netcode, because Chrome only ticks
## the FOREGROUND tab — the two peers are never alive at the same instant, so a handshake
## needing a round-trip can't complete (and a starved socket drops its buffered frames).
## One process = both peers always running.
##
## They share the single Net autoload, dialed with self_echo=true so a peer's own broadcast
## comes back to it. That is exactly what makes one socket serve two peers: every message is
## delivered to both instances, and each one's mode guard drops what isn't addressed to it
## (the authority ignores apply_snapshot/hand; a client ignores submit_action/combat_ready).

const COMBAT := preload("res://scenes/combat/combat.tscn")
const Db := preload("res://scripts/combat/card_db.gd")
const ROOM := "HARNESS"

var host: Node      # AUTHORITY, seat 0
var client: Node    # CLIENT, seat 1

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.02, 0.03)
	bg.size = Vector2(720, 1280)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	Net.ensure_peer_id()
	Net.realtime_joined.connect(_on_joined, CONNECT_ONE_SHOT)
	Net.connect_realtime(ROOM, true)

func _on_joined() -> void:
	var crew: Array = [{"cls": "warrior", "name": "Hosty"}, {"cls": "sorcerer", "name": "Clienty"}]
	var req: Dictionary = {"crew": crew, "enemies": Db.ENCOUNTER, "enemy_scale": 1.4}
	host = _spawn(req, "authority", 0, Vector2(0, 0))
	client = _spawn(req, "client", 1, Vector2(360, 0))

func _spawn(req: Dictionary, mode: String, seat: int, pos: Vector2) -> Node:
	var inst: Node = COMBAT.instantiate()
	var r: Dictionary = req.duplicate(true)
	r["net"] = {"mode": mode, "seat": seat, "seat_count": 2}
	inst.request = r          # must be set BEFORE add_child: combat._ready() parses it
	add_child(inst)
	inst.scale = Vector2(0.5, 0.5)   # two 720x1280 boards side by side in one 720x1280 window
	inst.position = pos
	return inst

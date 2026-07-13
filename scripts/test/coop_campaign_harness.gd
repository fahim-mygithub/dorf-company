extends Control
## Campaign co-op verification harness: BOTH peers as two overworld instances in ONE process.
##
## Why this exists (see also coop_harness.gd): two browser tabs cannot verify this netcode, because
## Chrome only ticks the FOREGROUND tab — the peers are never alive at the same instant, so no
## round-trip (a ring closing, a snapshot answering a hello, a fight barrier) can complete.
##
## Both instances share the single Net autoload, dialed with self_echo=true so a peer's own
## broadcast comes back to it. That is what lets one socket serve two peers: every message reaches
## both, and each one's mode guard drops what is not addressed to it (the host ignores
## camp_snapshot, a client ignores camp_intent).
##
## NOTE the peer_id caveat: one autoload = ONE Net.my_peer_id, so the two peers are
## indistinguishable by peer_id. That is exactly why the campaign protocol identifies a sender by
## its injected SEAT int and never by peer_id.

const OVERWORLD := preload("res://scenes/overworld/overworld.tscn")
const ROOM := "HARNESS"
const SEATS := [
	{"name": "Hosty", "cls": "warrior", "present": true},
	{"name": "Clienty", "cls": "sorcerer", "present": true},
]

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
	host = _spawn("authority", 0, Vector2(0, 0))
	client = _spawn("client", 1, Vector2(360, 0))

func _spawn(m: String, seat: int, pos: Vector2) -> Node:
	var inst: Node = OVERWORLD.instantiate()
	inst.request = {
		"net": {"mode": m, "seat": seat, "seat_count": SEATS.size()},
		"seats": SEATS.duplicate(true),
	}                                  # must be set BEFORE add_child: overworld._ready() parses it
	add_child(inst)
	inst.scale = Vector2(0.5, 0.5)     # two 720x1280 boards side by side in one 720x1280 window
	inst.position = pos
	return inst

extends Control
## Lobby: host shows a room code; each player picks one of 4 random dorfs and readies up;
## host starts the fight. Coordination rides Net (Supabase Broadcast). Host = authority (seat 0).
##
## Wire protocol (broadcast events):
##   "hello"  {peer_id, dorf:{cls,name}, ready}  client/host -> announces or updates itself
##   "roster" {seats:[{peer_id,dorf,ready}]}     host -> authoritative seat list (order = seat)
##   "start"  {order:[peer_id...], request}       host -> everyone change_scene into combat
##   "camp_start" {order:[peer_id...], seats}     host -> everyone change_scene into the CAMPAIGN
## Broadcast is fire-and-forget, so clients re-send "hello" until the host has seated them.

const Db := preload("res://scripts/combat/card_db.gd")
const COMBAT := "res://scenes/combat/combat.tscn"
const OVERWORLD := "res://scenes/overworld/overworld.tscn"
const MENU := "res://scenes/menu/main_menu.tscn"
const NAMES := ["Grimli", "Thora", "Bruni", "Vali", "Kili", "Odd", "Dwalin", "Nala", "Bofur", "Gerda", "Sten", "Yrsa"]
const MAX_SEATS := 4

var my_roster: Array = []          # 4 dorf dicts {cls, name}
var my_pick := 0
var my_ready := false
var seats: Array = []              # [{peer_id, dorf, ready}] — authoritative on host, mirror on client
var _hello_accum := 0.0
var _seen_self := false

var code_lbl: Label
var seat_box: Control
var roster_box: Control
var ready_btn: Button
var start_btn: Button
var camp_btn: Button
var status: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_gen_roster()
	_build()
	Net.message_received.connect(_on_msg)
	Net.realtime_joined.connect(_on_joined)
	if Net.is_authority:
		seats = [{"peer_id": Net.my_peer_id, "dorf": my_roster[my_pick], "ready": my_ready}]
		Net.my_seat = 0
	if Net.is_online():
		_on_joined()
	_refresh()

func _exit_tree() -> void:
	if Net.message_received.is_connected(_on_msg):
		Net.message_received.disconnect(_on_msg)
	if Net.realtime_joined.is_connected(_on_joined):
		Net.realtime_joined.disconnect(_on_joined)

func _gen_roster() -> void:
	my_roster = []
	for i in 4:
		var cls: String = Db.PARTY_ORDER[randi() % Db.PARTY_ORDER.size()]
		my_roster.append({"cls": cls, "name": NAMES[randi() % NAMES.size()]})

# ---------------------------------------------------------------- Net
func _on_joined() -> void:
	_broadcast_hello()

func _broadcast_hello() -> void:
	Net.send_message("hello", {"peer_id": Net.my_peer_id, "dorf": my_roster[my_pick], "ready": my_ready})

func _on_msg(event: String, p: Dictionary) -> void:
	match event:
		"hello":
			if Net.is_authority:
				_host_absorb(p)
		"roster":
			if not Net.is_authority:
				seats = p.get("seats", [])
				_learn_seat()
				_refresh()
		"start":
			_enter_combat(p)
		"camp_start":
			_enter_campaign(p)

func _host_absorb(p: Dictionary) -> void:
	var pid: String = str(p.get("peer_id", ""))
	if pid == "":
		return
	var dorf: Dictionary = p.get("dorf", {})
	var rdy: bool = bool(p.get("ready", false))
	for s in seats:
		if s["peer_id"] == pid:
			s["dorf"] = dorf
			s["ready"] = rdy
			_broadcast_roster()
			_refresh()
			return
	if seats.size() < MAX_SEATS:
		seats.append({"peer_id": pid, "dorf": dorf, "ready": rdy})
	_broadcast_roster()
	_refresh()

func _broadcast_roster() -> void:
	Net.send_message("roster", {"seats": seats})

func _learn_seat() -> void:
	for i in seats.size():
		if str(seats[i]["peer_id"]) == Net.my_peer_id:
			Net.my_seat = i
			_seen_self = true
			return

func _process(delta: float) -> void:
	if not Net.is_authority and Net.is_online() and not _seen_self:
		_hello_accum += delta
		if _hello_accum >= 1.5:
			_hello_accum = 0.0
			_broadcast_hello()

# ---------------------------------------------------------------- Actions
func _on_pick(idx: int) -> void:
	my_pick = idx
	if Net.is_authority:
		seats[0]["dorf"] = my_roster[my_pick]
		_broadcast_roster()
	else:
		_broadcast_hello()
	_refresh()

func _on_ready() -> void:
	my_ready = not my_ready
	if Net.is_authority:
		seats[0]["ready"] = my_ready
		_broadcast_roster()
	else:
		_broadcast_hello()
	_refresh()

func _on_start() -> void:
	if not Net.is_authority:
		return
	if seats.size() < 2:
		status.text = "need at least 2 players"
		return
	for s in seats:
		if not bool(s["ready"]):
			status.text = "waiting for everyone to ready up"
			return
	var order: Array = []
	var crew: Array = []
	for s in seats:
		order.append(s["peer_id"])
		crew.append(s["dorf"])
	# enemy_scale by party size is a PLACEHOLDER; real per-size+comp tuning is deferred (design 8.3 / M4).
	var req := {"crew": crew, "enemies": Db.ENCOUNTER, "enemy_scale": 0.8 + 0.3 * float(seats.size())}
	Net.send_message("start", {"order": order, "request": req})
	_enter_combat({"order": order, "request": req})

## The CAMPAIGN start. Unlike a skirmish, there is no pre-rolled encounter to agree on: the host
## builds the whole company (contracts, hex maps, every die) and streams it. All the lobby has to
## settle is WHO SITS WHERE — seat i pilots roster[i] for the rest of the campaign.
func _on_start_campaign() -> void:
	if not Net.is_authority:
		return
	if seats.size() < 2:
		status.text = "need at least 2 players"
		return
	for s in seats:
		if not bool(s["ready"]):
			status.text = "waiting for everyone to ready up"
			return
	var order: Array = []
	var crew: Array = []
	for s in seats:
		var d: Dictionary = s.get("dorf", {})
		order.append(s["peer_id"])
		crew.append({"name": str(d.get("name", "Dorf")), "cls": str(d.get("cls", "warrior")), "present": true})
	Net.send_message("camp_start", {"order": order, "seats": crew})
	_enter_campaign({"order": order, "seats": crew})

func _enter_campaign(p: Dictionary) -> void:
	var order: Array = p.get("order", [])
	var seat: int = order.find(Net.my_peer_id)
	if seat < 0:
		status.text = "the host started without you"
		return
	Net.my_seat = seat
	Net.campaign_request = {
		"net": {
			"mode": "authority" if Net.is_authority else "client",
			"seat": seat,
			"seat_count": order.size(),
		},
		"seats": (p.get("seats", []) as Array).duplicate(true),
	}
	get_tree().change_scene_to_file(OVERWORLD)   # Net stays connected across the scene change

func _enter_combat(p: Dictionary) -> void:
	var order: Array = p.get("order", [])
	var seat: int = order.find(Net.my_peer_id)
	if seat < 0:
		status.text = "the host started without you"
		return
	Net.my_seat = seat
	# Same request on every peer, plus a per-peer `net` block: who I am and who resolves.
	var req: Dictionary = (p.get("request", {}) as Dictionary).duplicate(true)
	req["net"] = {
		"mode": "authority" if Net.is_authority else "client",
		"seat": seat,
		"seat_count": order.size(),
	}
	Net.combat_request = req
	get_tree().change_scene_to_file(COMBAT)   # Net stays connected across the scene change

func _on_back() -> void:
	Net.disconnect_realtime()
	Net.room_code = ""
	Net.is_authority = false
	get_tree().change_scene_to_file(MENU)

# ---------------------------------------------------------------- UI
func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.09, 0.12)
	bg.size = Vector2(720, 1280)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_lbl("ROOM", Vector2(0, 60), Vector2(720, 26), 18, Color(0.7, 0.7, 0.78))
	code_lbl = _lbl(Net.room_code, Vector2(0, 90), Vector2(720, 70), 60)
	_lbl("PLAYERS", Vector2(40, 200), Vector2(300, 24), 16, Color(0.7, 0.7, 0.78), false)
	seat_box = _panel(Vector2(40, 230), Vector2(640, 250))
	_lbl("YOUR DORFS  (pick one)", Vector2(40, 500), Vector2(400, 24), 16, Color(0.7, 0.7, 0.78), false)
	roster_box = _panel(Vector2(40, 530), Vector2(640, 220))
	ready_btn = Button.new()
	ready_btn.add_theme_font_size_override("font_size", 22)
	ready_btn.position = Vector2(40, 800)
	ready_btn.size = Vector2(310, 60)
	ready_btn.pressed.connect(_on_ready)
	add_child(ready_btn)
	start_btn = Button.new()
	start_btn.text = "Start Fight"
	start_btn.add_theme_font_size_override("font_size", 22)
	start_btn.position = Vector2(370, 800)
	start_btn.size = Vector2(310, 60)
	start_btn.pressed.connect(_on_start)
	add_child(start_btn)
	camp_btn = Button.new()
	camp_btn.text = "🏰  Start Campaign"
	camp_btn.add_theme_font_size_override("font_size", 22)
	camp_btn.position = Vector2(40, 876)
	camp_btn.size = Vector2(640, 64)
	camp_btn.pressed.connect(_on_start_campaign)
	add_child(camp_btn)
	_lbl("one company · one purse · one rising rent", Vector2(0, 944), Vector2(720, 22), 14, Color(0.66, 0.66, 0.72))
	status = _lbl("", Vector2(0, 976), Vector2(720, 26), 16, Color(0.9, 0.8, 0.45))
	var back := Button.new()
	back.text = "Leave"
	back.add_theme_font_size_override("font_size", 16)
	back.position = Vector2(40, 1200)
	back.size = Vector2(140, 44)
	back.pressed.connect(_on_back)
	add_child(back)

func _refresh() -> void:
	code_lbl.text = Net.room_code
	for c in seat_box.get_children():
		c.queue_free()
	for i in seats.size():
		var s: Dictionary = seats[i]
		var d: Dictionary = s.get("dorf", {})
		var cls: String = str(d.get("cls", "warrior"))
		var emo: String = str(Db.CLASSES.get(cls, {}).get("emoji", "?"))
		var nm: String = str(d.get("name", "?"))
		var mine: bool = str(s["peer_id"]) == Net.my_peer_id
		var chk: String = "  ✅" if bool(s.get("ready", false)) else ""
		var host_tag: String = "  (host)" if i == 0 else ""
		var you_tag: String = "  (you)" if mine else ""
		var row := _child_lbl(seat_box, "%s  %s  %s%s%s%s" % [emo, nm, str(Db.CLASSES.get(cls, {}).get("name", cls)), host_tag, you_tag, chk], Vector2(16, 12 + i * 56), 22)
		row.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6) if bool(s.get("ready", false)) else Color.WHITE)
	for c in roster_box.get_children():
		c.queue_free()
	for i in my_roster.size():
		var d: Dictionary = my_roster[i]
		var cls: String = str(d["cls"])
		var b := Button.new()
		b.text = "%s %s\n%s" % [str(Db.CLASSES[cls]["emoji"]), str(d["name"]), str(Db.CLASSES[cls]["name"])]
		b.add_theme_font_size_override("font_size", 17)
		b.position = Vector2(16 + i * 154, 16)
		b.size = Vector2(146, 120)
		b.toggle_mode = true
		b.button_pressed = i == my_pick
		b.pressed.connect(_on_pick.bind(i))
		roster_box.add_child(b)
	ready_btn.text = "Unready" if my_ready else "Ready"
	start_btn.visible = Net.is_authority
	start_btn.disabled = not _all_ready()
	camp_btn.visible = Net.is_authority
	camp_btn.disabled = not _all_ready()

func _all_ready() -> bool:
	if seats.size() < 2:
		return false
	for s in seats:
		if not bool(s.get("ready", false)):
			return false
	return true

func _panel(pos: Vector2, sz: Vector2) -> Control:
	var pnl := Panel.new()
	pnl.position = pos
	pnl.size = sz
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.13, 0.17)
	sb.set_corner_radius_all(8)
	pnl.add_theme_stylebox_override("panel", sb)
	add_child(pnl)
	return pnl

func _lbl(text: String, pos: Vector2, sz: Vector2, font: int, col := Color.WHITE, center := true) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font)
	l.add_theme_color_override("font_color", col)
	if center:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.position = pos
	l.size = sz
	add_child(l)
	return l

func _child_lbl(parent: Control, text: String, pos: Vector2, font: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.position = pos
	l.size = Vector2(600, 40)
	parent.add_child(l)
	return l

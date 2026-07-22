extends Control
## Main menu: Campaign / Host / Join (+ Quick Fight). Host+Join dial Net (Supabase) and enter
## the lobby; both solo paths leave Net untouched.
##
## Solo Play used to mean COMBAT, from when a skirmish was the whole game. The campaign is the
## game now, so the primary solo button opens it and the bare skirmish is demoted to a secondary
## "Quick Fight" (still worth keeping — it is the fastest way to look at a card or an enemy move
## without playing a month first).

const LOBBY := "res://scenes/menu/lobby.tscn"
const COMBAT := "res://scenes/combat/combat.tscn"
const OVERWORLD := "res://scenes/overworld/overworld.tscn"
const BuildInfo := preload("res://scripts/menu/build_info.gd")
const CODE_CHARS := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"   # no ambiguous 0/O/1/I/L

var code_input: LineEdit
var status: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.09, 0.12)
	bg.size = Vector2(720, 1280)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_lbl("DORF COMPANY", Vector2(0, 210), Vector2(720, 64), 46)
	_lbl("- a quarterly raid -", Vector2(0, 286), Vector2(720, 30), 20, Color(0.7, 0.7, 0.78))
	_lbl("🛡️   ⛑️   🧙", Vector2(0, 344), Vector2(720, 64), 44)
	_btn("🏰  Campaign", 560, _on_campaign)
	_btn("Host Room", 650, _on_host)
	_btn("Join Room", 740, _on_join)
	_btn("Quick Fight", 1130, _on_quick_fight, 18, Vector2(200, 46))
	code_input = LineEdit.new()
	code_input.placeholder_text = "ROOM CODE"
	code_input.max_length = 4
	code_input.position = Vector2(210, 832)
	code_input.size = Vector2(300, 52)
	code_input.add_theme_font_size_override("font_size", 22)
	code_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_input.visible = false
	code_input.text_submitted.connect(_do_join)
	add_child(code_input)
	status = _lbl("", Vector2(0, 908), Vector2(720, 28), 16, Color(0.9, 0.8, 0.45))
	# So a player can tell us WHICH build they are on. A stale cached build and a real bug look
	# exactly the same from the outside; this makes them tell themselves apart.
	_lbl("build %s" % BuildInfo.BUILD, Vector2(0, 1224), Vector2(720, 22), 13, Color(0.42, 0.42, 0.48))

func _lbl(text: String, pos: Vector2, sz: Vector2, font: int, col := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.position = pos
	l.size = sz
	add_child(l)
	return l

func _btn(text: String, y: float, cb: Callable, font: int = 24, sz := Vector2(300, 64)) -> void:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font)
	b.position = Vector2(360.0 - sz.x * 0.5, y)
	b.size = sz
	b.pressed.connect(cb)
	add_child(b)

func _rand_code() -> String:
	var s := ""
	for i in 4:
		s += CODE_CHARS[randi() % CODE_CHARS.length()]
	return s

## Both solo entries hang up first. Clearing BOTH request dicts is the load-bearing part: each
## scene's _ready CONSUMES the matching one, and a leftover from an abandoned co-op lobby would
## boot the solo run as a CLIENT waiting on a host that is not coming.
func _go_solo(scene: String) -> void:
	Net.disconnect_realtime()
	Net.room_code = ""
	Net.is_authority = false
	Net.my_seat = -1
	Net.combat_request = {}
	Net.campaign_request = {}
	get_tree().change_scene_to_file(scene)

func _on_campaign() -> void:
	_go_solo(OVERWORLD)

func _on_quick_fight() -> void:
	_go_solo(COMBAT)

func _on_host() -> void:
	Net.ensure_peer_id()
	Net.room_code = _rand_code()
	Net.is_authority = true
	Net.my_seat = 0
	Net.connect_realtime(Net.room_code, false)
	get_tree().change_scene_to_file(LOBBY)

func _on_join() -> void:
	code_input.visible = true
	code_input.grab_focus()
	status.text = "enter a room code, then press Enter"

func _do_join(t: String) -> void:
	var code := t.strip_edges().to_upper()
	if code.length() != 4:
		status.text = "code must be 4 characters"
		return
	Net.ensure_peer_id()
	Net.room_code = code
	Net.is_authority = false
	Net.my_seat = -1
	Net.connect_realtime(code, false)
	get_tree().change_scene_to_file(LOBBY)

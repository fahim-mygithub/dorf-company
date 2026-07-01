extends Control
## "Demon Lord MBA" — OVERWORLD MVP (Step 1): the fee-clock economic layer.
##
## A text-and-emoji management loop that WRAPS combat with a dice-roll STUB (it does
## NOT call combat — that is Step 4). Loop: Dashboard -> Contract Board -> dice Resolve
## -> Outcome + fee clock -> repeat. Survive WIN_MONTH months solvent to win.
##
## Built all-in-code like combat.gd (bare Control root). Role emoji/name are read from
## card_db.gd (Db) so the roster matches the combat party. Economy is tunable `const`.
## Step-2 seams: CREW_SELECT (crew picking) + LOSS_ENABLED (permanent loss) are gated off.

const Db := preload("res://scripts/combat/card_db.gd")

# ============================================================ Economy (tunable)
const START_TREASURY := 100
const FEE_BASE := 40
const FEE_STEP := 10          # fee rises this much per payment
const FEE_PERIOD := 2         # rent due every N months (even months)
const WIN_MONTH := 12         # survive the month-WIN_MONTH advance -> victory
const WOUND_RECOVERY := 2     # months a wound keeps a dwarf unavailable
const DWARF_STRENGTH := 3     # flat in MVP (class only drives emoji/color)

const DANGER := {"low": 8, "med": 13, "high": 15}     # crew_strength + 2d6 must reach this
const PAYOUT := {"low": 30, "med": 80, "high": 100}
const DURATION := {"low": 1, "med": 2, "high": 1}
const CREW_SIZE := {"low": 1, "med": 3, "high": 3}    # low = crew_size-1 lifeline
const WOUND_CHANCE := {"low": 0.05, "med": 0.20, "high": 0.35}
const LOSS_CHANCE := {"low": 0.0, "med": 0.04, "high": 0.12}
const FAILURE_PAYOUT_MULT := 0.5
const FAILURE_ATTRITION_MULT := 2.0

const LOSS_ENABLED := false   # STEP 1: wounds only (A5). Step 2 flips true.
const CREW_SELECT := false    # STEP 2 seam: manual crew picking.

const STARTERS := [
	{"name": "Thrain", "cls": "warrior"},
	{"name": "Bruni", "cls": "cleric"},
	{"name": "Vela", "cls": "sorcerer"},
	{"name": "Gimli", "cls": "warrior"},
]
const LOCATIONS := [
	{"emoji": "🕳️", "name": "the Warrens"},
	{"emoji": "🏰", "name": "the Keep"},
	{"emoji": "🌲", "name": "the Marches"},
	{"emoji": "⛰️", "name": "the Deeproads"},
]
const TITLES := {
	"low": ["Rat Cull", "Cellar Sweep", "Debt Run", "Fungus Harvest"],
	"med": ["Bandit Camp", "Haunted Mine", "Goblin Warband", "Cursed Vault"],
	"high": ["Dragon's Tithe", "Lich's Ledger", "The Deep Delve", "Demon Audit"],
}
const TIER_LABEL := {"low": "LOW", "med": "MED", "high": "HIGH"}
const SKULLS := {"low": "💀", "med": "💀💀", "high": "💀💀💀"}
const COIN_STACK := {"low": 2, "med": 4, "high": 6}

# ============================================================ Colors (grammar)
const COL_BG := Color(0.09, 0.09, 0.12)
const COL_HUD := Color(0.12, 0.12, 0.16)
const C_GREEN := Color(0.30, 0.82, 0.42)
const C_AMBER := Color(0.95, 0.74, 0.20)
const C_RED := Color(0.92, 0.26, 0.26)
const C_COIN := Color(0.96, 0.82, 0.26)
const DANGER_BG := {"low": Color(0.16, 0.34, 0.20), "med": Color(0.40, 0.32, 0.10), "high": Color(0.40, 0.13, 0.13)}
const DANGER_BANNER := {"low": Color(0.30, 0.82, 0.42), "med": Color(0.95, 0.74, 0.20), "high": Color(0.92, 0.26, 0.26)}
const CLASS_COL := {"warrior": Color(0.62, 0.64, 0.68), "cleric": Color(0.95, 0.80, 0.30), "sorcerer": Color(0.62, 0.40, 0.85)}
const MOD_WOUNDED := Color(0.72, 0.66, 0.55)
const MOD_LOST := Color(0.35, 0.35, 0.38)

# ============================================================ State
var treasury := 0
var fee := 0
var month := 0
var months_survived := 0
var roster: Array = []
var contracts: Array = []
var current: Dictionary = {}
var selected_contract := -1
var state := ""
var run_epoch := 0
var busy := false
var _tre_shown := 0

# ============================================================ UI refs
var screen_root: Control
var hud: Control
var overlay: ColorRect
var overlay_label: Label
var overlay_btn: Button
var msg_label: Label
var coin_icon: Label
var hud_treasury: Label
var coin_band: ColorRect
var landlord: Label
var hud_fee: Label
var hud_next: Label
var hud_month: Label
var fee_pips: Array = []
var continue_btn: Button

# ============================================================ Lifecycle
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_chrome()
	_new_run()

# ============================================================ UI helpers
func _mklabel(text: String, pos: Vector2, sz: Vector2, font: int, parent: Node, center: bool = true, col: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font)
	l.add_theme_color_override("font_color", col)
	if center:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.position = pos
	l.size = sz
	parent.add_child(l)
	return l

func _mkemoji(center_pos: Vector2, box: Vector2, font: int, parent: Node) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.size = box
	l.position = center_pos - box * 0.5
	l.pivot_offset = box * 0.5
	parent.add_child(l)
	return l

func _rect(pos: Vector2, sz: Vector2, col: Color, parent: Node) -> ColorRect:
	var r := ColorRect.new()
	r.color = col
	r.position = pos
	r.size = sz
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)
	return r

func _msg(s: String) -> void:
	if is_instance_valid(msg_label):
		msg_label.text = s

func _flash(n: Control) -> void:
	n.pivot_offset = n.size * 0.5
	n.scale = Vector2.ONE
	var t := create_tween()
	t.tween_property(n, "scale", Vector2(1.32, 1.32), 0.09)
	t.tween_property(n, "scale", Vector2.ONE, 0.09)

# ============================================================ Chrome (built once)
func _build_chrome() -> void:
	_rect(Vector2.ZERO, Vector2(720, 1280), COL_BG, self)

	screen_root = Control.new()
	screen_root.size = Vector2(720, 1280)
	screen_root.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(screen_root)

	hud = Control.new()
	hud.size = Vector2(720, 158)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)
	_build_hud()

	msg_label = _mklabel("", Vector2(16, 1232), Vector2(688, 36), 15, self, false)

	overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.82)
	overlay.size = Vector2(720, 1280)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	overlay_label = Label.new()
	overlay_label.add_theme_font_size_override("font_size", 28)
	overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overlay_label.position = Vector2(60, 470)
	overlay_label.size = Vector2(600, 230)
	overlay.add_child(overlay_label)
	overlay_btn = Button.new()
	overlay_btn.text = "New Company"
	overlay_btn.add_theme_font_size_override("font_size", 22)
	overlay_btn.position = Vector2(250, 760)
	overlay_btn.size = Vector2(220, 64)
	overlay_btn.pressed.connect(_new_run)
	overlay.add_child(overlay_btn)
	overlay.visible = false

func _build_hud() -> void:
	_rect(Vector2.ZERO, Vector2(720, 158), COL_HUD, hud)
	_rect(Vector2(0, 156), Vector2(720, 2), Color(1, 1, 1, 0.08), hud)
	coin_icon = _mkemoji(Vector2(56, 62), Vector2(80, 76), 44, hud)
	coin_icon.text = "💰"
	hud_treasury = _mklabel("", Vector2(104, 30), Vector2(240, 60), 44, hud, false)
	coin_band = _rect(Vector2(106, 100), Vector2(180, 10), C_GREEN, hud)
	landlord = _mkemoji(Vector2(668, 48), Vector2(72, 64), 40, hud)
	landlord.text = "👹"
	hud_fee = _mklabel("", Vector2(360, 24), Vector2(268, 28), 20, hud, false)
	hud_fee.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hud_next = _mklabel("", Vector2(360, 56), Vector2(268, 20), 13, hud, false)
	hud_next.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fee_pips = []
	for j in range(FEE_PERIOD):
		fee_pips.append(_rect(Vector2(548 + j * 26, 88), Vector2(20, 18), C_AMBER, hud))
	hud_month = _mklabel("", Vector2(260, 120), Vector2(200, 24), 15, hud)

# ============================================================ HUD refresh
func _band_for(v: int) -> Color:
	if v < fee:
		return C_RED
	elif v < 2 * fee:
		return C_AMBER
	return C_GREEN

func _apply_treasury_label(v: float) -> void:
	var iv := int(round(v))
	if is_instance_valid(hud_treasury):
		hud_treasury.text = "%dg" % iv
		hud_treasury.add_theme_color_override("font_color", _band_for(iv))

func _months_to_fee() -> int:
	var m := month % FEE_PERIOD
	return FEE_PERIOD if m == 0 else FEE_PERIOD - m

func _refresh_hud() -> void:
	if not is_instance_valid(hud_treasury):
		return
	_apply_treasury_label(float(treasury))
	_tre_shown = treasury
	coin_band.color = _band_for(treasury)
	hud_fee.text = "RENT  %dg" % fee
	hud_fee.add_theme_color_override("font_color", C_RED if treasury < fee else Color(0.9, 0.9, 0.9))
	hud_next.text = "next  %dg" % (fee + FEE_STEP)
	hud_month.text = "Month %d / %d" % [month, WIN_MONTH]
	var r := _months_to_fee()
	for j in range(fee_pips.size()):
		var p: ColorRect = fee_pips[j]
		if j >= r:
			p.color = Color(0.25, 0.25, 0.3)
		elif r <= 1:
			p.color = C_RED
		else:
			p.color = C_AMBER

# ============================================================ Run setup
func _new_run() -> void:
	run_epoch += 1
	busy = false
	treasury = START_TREASURY
	_tre_shown = START_TREASURY
	fee = FEE_BASE
	month = 0
	months_survived = 0
	selected_contract = -1
	roster = []
	for s in STARTERS:
		roster.append({"name": s["name"], "cls": s["cls"], "status": "ready", "recover": 0})
	_regen_contracts()
	overlay.visible = false
	_msg("Rent's due every 2 months, and it only climbs. Take a job.")
	_enter_dashboard()

func _regen_contracts() -> void:
	contracts = [_make_contract("low"), _make_contract("med"), _make_contract("high")]

func _make_contract(tier: String) -> Dictionary:
	var titles: Array = TITLES[tier]
	var loc: Dictionary = LOCATIONS[randi() % LOCATIONS.size()]
	return {
		"tier": tier,
		"title": titles[randi() % titles.size()],
		"loc_emoji": loc["emoji"],
		"loc_name": loc["name"],
		"payout": int(PAYOUT[tier]),
		"duration": int(DURATION[tier]),
		"danger": int(DANGER[tier]),
		"crew_size": int(CREW_SIZE[tier]),
		"crew": [],
	}

func _ready_count() -> int:
	var n := 0
	for d in roster:
		if d["status"] == "ready":
			n += 1
	return n

func _recovering_count() -> int:
	var n := 0
	for d in roster:
		if d["status"] == "wounded":
			n += 1
	return n

# ============================================================ Screen switching
func _clear_screen() -> void:
	for c in screen_root.get_children():
		c.queue_free()

func _enter_dashboard() -> void:
	if _ready_count() == 0 and _recovering_count() == 0:
		_game_over("disbanded")
		return
	selected_contract = -1
	state = "DASHBOARD"
	_clear_screen()
	_build_dashboard()
	_refresh_hud()
	overlay.visible = false

func _on_view_contracts() -> void:
	if busy:
		return
	selected_contract = -1
	state = "CONTRACTS"
	_clear_screen()
	_build_contracts()
	_refresh_hud()

# ============================================================ Screen: Dashboard
func _build_dashboard() -> void:
	_mklabel("— DORF & CO. —", Vector2(0, 190), Vector2(720, 30), 24, screen_root)
	_mklabel("Your crew. Send them to make rent — or lose them.", Vector2(0, 226), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
	var cx := [96, 272, 448, 624]
	for i in range(roster.size()):
		_build_dwarf_token(roster[i], cx[i], 470)
	var vc := Button.new()
	vc.text = "📜  View Contracts"
	vc.add_theme_font_size_override("font_size", 22)
	vc.position = Vector2(210, 1150)
	vc.size = Vector2(320, 70)
	vc.pressed.connect(_on_view_contracts)
	screen_root.add_child(vc)
	var rest := Button.new()
	rest.text = "🛌 Rest"
	rest.add_theme_font_size_override("font_size", 18)
	rest.position = Vector2(40, 1150)
	rest.size = Vector2(150, 70)
	rest.pressed.connect(_on_rest)
	screen_root.add_child(rest)

func _build_dwarf_token(d: Dictionary, cx: int, cy: int) -> void:
	var status: String = d["status"]
	var col: Color = CLASS_COL[d["cls"]]
	_rect(Vector2(cx - 58, cy - 74), Vector2(116, 176), Color(col.r, col.g, col.b, 0.22), screen_root)
	var emo := _mkemoji(Vector2(cx, cy - 16), Vector2(110, 84), 54, screen_root)
	emo.text = Db.CLASSES[d["cls"]]["emoji"]
	if status == "wounded":
		emo.modulate = MOD_WOUNDED
	elif status == "lost":
		emo.modulate = MOD_LOST
	var dotcol := C_GREEN
	if status == "wounded":
		dotcol = C_AMBER
	elif status == "lost":
		dotcol = Color(0.4, 0.4, 0.44)
	_rect(Vector2(cx + 26, cy - 60), Vector2(20, 20), dotcol, screen_root)
	_mklabel(d["name"], Vector2(cx - 58, cy + 42), Vector2(116, 22), 15, screen_root)
	_mklabel(Db.CLASSES[d["cls"]]["name"], Vector2(cx - 58, cy + 64), Vector2(116, 18), 12, screen_root, true, Color(0.75, 0.75, 0.8))
	if status == "wounded":
		_mkemoji(Vector2(cx - 30, cy - 44), Vector2(36, 36), 22, screen_root).text = "🩹"
		_mklabel("wounded", Vector2(cx - 58, cy + 84), Vector2(116, 16), 11, screen_root, true, C_AMBER)
		for j in range(int(d["recover"])):
			_rect(Vector2(cx - 14 + j * 18, cy + 104), Vector2(14, 14), C_AMBER, screen_root)
	elif status == "lost":
		_mkemoji(Vector2(cx - 30, cy - 44), Vector2(36, 36), 22, screen_root).text = "⚰️"
		_mklabel("lost", Vector2(cx - 58, cy + 84), Vector2(116, 16), 11, screen_root, true, Color(0.6, 0.6, 0.6))

# ============================================================ Screen: Contracts
func _build_contracts() -> void:
	_mklabel("— CONTRACTS —", Vector2(0, 176), Vector2(720, 26), 20, screen_root)
	_mklabel("Pick one job. Weigh payout against danger and time.", Vector2(0, 206), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
	var xs := [12, 252, 492]
	for i in range(contracts.size()):
		_build_contract_card(i, xs[i])
	var back := Button.new()
	back.text = "◀ Back"
	back.add_theme_font_size_override("font_size", 18)
	back.position = Vector2(30, 1150)
	back.size = Vector2(150, 64)
	back.pressed.connect(_enter_dashboard)
	screen_root.add_child(back)

func _build_contract_card(i: int, x: int) -> void:
	var c: Dictionary = contracts[i]
	var tier: String = c["tier"]
	var card := Control.new()
	card.position = Vector2(x, 236 if i != selected_contract else 224)
	card.size = Vector2(216, 620)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(_on_contract_input.bind(i))
	screen_root.add_child(card)
	var takeable: bool = _ready_count() >= int(c["crew_size"])
	if not takeable:
		card.modulate = Color(0.5, 0.5, 0.5)
	if i == selected_contract:
		_rect(Vector2(-4, -4), Vector2(224, 628), DANGER_BANNER[tier], card)
	_rect(Vector2.ZERO, Vector2(216, 620), DANGER_BG[tier], card)
	_rect(Vector2.ZERO, Vector2(216, 46), DANGER_BANNER[tier], card)
	_mklabel("%s  %s" % [TIER_LABEL[tier], SKULLS[tier]], Vector2(0, 10), Vector2(216, 26), 18, card, true, Color(0.1, 0.1, 0.1))
	_mkemoji(Vector2(108, 96), Vector2(120, 60), 40, card).text = c["loc_emoji"]
	_mklabel(c["title"], Vector2(6, 132), Vector2(204, 26), 17, card)
	_mklabel(c["loc_name"], Vector2(6, 160), Vector2(204, 20), 13, card, true, Color(0.8, 0.8, 0.85))
	var coins: int = COIN_STACK[tier]
	for j in range(coins):
		_rect(Vector2(63, 330 - j * 15), Vector2(90, 12), C_COIN, card)
	_mklabel("%dg" % int(c["payout"]), Vector2(6, 340), Vector2(204, 30), 22, card, true, C_COIN)
	_mklabel("crew", Vector2(6, 392), Vector2(204, 18), 12, card, true, Color(0.8, 0.8, 0.85))
	var cs: int = int(c["crew_size"])
	for j in range(cs):
		_rect(Vector2(108 - cs * 15.0 + j * 30, 414), Vector2(24, 24), Color(0.1, 0.1, 0.13), card)
	_mklabel("time", Vector2(6, 452), Vector2(204, 18), 12, card, true, Color(0.8, 0.8, 0.85))
	var dur: int = int(c["duration"])
	for j in range(dur):
		_rect(Vector2(108 - dur * 17.0 + j * 34, 474), Vector2(28, 20), Color(0.55, 0.6, 0.75), card)
	if not takeable:
		_mklabel("need %d ready" % cs, Vector2(6, 540), Vector2(204, 22), 14, card, true, C_RED)
	elif i == selected_contract:
		_mklabel("tap again to embark", Vector2(6, 540), Vector2(204, 22), 14, card, true, C_GREEN)
	else:
		_mklabel("tap to select", Vector2(6, 540), Vector2(204, 22), 13, card, true, Color(0.85, 0.85, 0.9))

func _on_contract_input(event: InputEvent, i: int) -> void:
	if busy or state != "CONTRACTS":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var c: Dictionary = contracts[i]
		if _ready_count() < int(c["crew_size"]):
			_msg("Not enough ready dwarves — need %d." % int(c["crew_size"]))
			return
		if selected_contract != i:
			selected_contract = i
			_msg("%s — %dg, %s danger, %d month(s). Tap again to embark." % [c["title"], int(c["payout"]), String(TIER_LABEL[c["tier"]]).to_lower(), int(c["duration"])])
			_clear_screen()
			_build_contracts()
		else:
			_embark()

# ============================================================ Embark + Resolve
func _embark() -> void:
	if busy or selected_contract < 0:
		return
	var c: Dictionary = contracts[selected_contract]
	if _ready_count() < int(c["crew_size"]):
		_msg("Not enough ready dwarves.")
		return
	current = c
	current["crew"] = _auto_assign_crew(c)
	var result: Dictionary = _resolve_dice(current["crew"], current["tier"])
	selected_contract = -1
	var e := run_epoch
	state = "RESOLVE"
	_clear_screen()
	await _play_resolution(current, result)
	if e != run_epoch:
		return
	state = "OUTCOME"
	_clear_screen()
	_build_outcome(current, result)
	_refresh_hud()
	await _outcome_beats(current, result, e)

func _auto_assign_crew(c: Dictionary) -> Array:
	var crew: Array = []
	for d in roster:
		if d["status"] == "ready" and crew.size() < int(c["crew_size"]):
			crew.append(d)
	return crew

func _resolve_dice(crew: Array, tier: String) -> Dictionary:
	var strength: int = crew.size() * DWARF_STRENGTH
	var roll: int = randi_range(1, 6) + randi_range(1, 6)
	var success: bool = strength + roll >= int(DANGER[tier])
	var payout: int = int(round(float(PAYOUT[tier]) * (1.0 if success else FAILURE_PAYOUT_MULT)))
	var mult: float = 1.0 if success else FAILURE_ATTRITION_MULT
	var pending: Array = []
	for d in crew:
		if LOSS_ENABLED and randf() < float(LOSS_CHANCE[tier]) * mult:
			pending.append([d, "lost"])
		elif randf() < float(WOUND_CHANCE[tier]) * mult:
			pending.append([d, "wounded"])
	return {"success": success, "payout": payout, "pending": pending, "roll": roll, "strength": strength}

func _play_resolution(c: Dictionary, result: Dictionary) -> void:
	busy = true
	var e := run_epoch
	_msg("Marching on %s…" % c["title"])
	_rect(Vector2(560, 380), Vector2(70, 320), DANGER_BANNER[c["tier"]], screen_root)
	_mklabel(SKULLS[c["tier"]], Vector2(470, 300), Vector2(240, 40), 30, screen_root)
	_mklabel("%s DANGER" % TIER_LABEL[c["tier"]], Vector2(460, 716), Vector2(260, 26), 18, screen_root, true, DANGER_BANNER[c["tier"]])
	var toks: Array = []
	for i in range(c["crew"].size()):
		var d: Dictionary = c["crew"][i]
		var tok := _mkemoji(Vector2(130, 430 + i * 120), Vector2(96, 80), 54, screen_root)
		tok.text = Db.CLASSES[d["cls"]]["emoji"]
		toks.append(tok)
	var die := _mkemoji(Vector2(360, 600), Vector2(120, 120), 72, screen_root)
	die.text = "🎲"
	await get_tree().create_timer(0.4).timeout
	if e != run_epoch:
		return
	for tk in toks:
		var tw := create_tween()
		tw.tween_property(tk, "position:x", 300.0, 0.4)
	await get_tree().create_timer(0.5).timeout
	if e != run_epoch:
		return
	var dt := create_tween()
	dt.tween_property(die, "scale", Vector2(1.4, 1.4), 0.15)
	dt.tween_property(die, "rotation", deg_to_rad(30), 0.12)
	dt.tween_property(die, "rotation", deg_to_rad(-20), 0.12)
	dt.tween_property(die, "scale", Vector2.ONE, 0.12)
	dt.tween_property(die, "rotation", 0.0, 0.1)
	await get_tree().create_timer(0.7).timeout
	if e != run_epoch:
		return
	var res := _mkemoji(Vector2(360, 430), Vector2(150, 150), 96, screen_root)
	res.text = "✅" if result["success"] else "❌"
	_flash(res)
	_msg("%s   (rolled %d + %d strength vs %d)" % ["Success!" if result["success"] else "Setback…", int(result["roll"]), int(result["strength"]), int(c["danger"])])
	await get_tree().create_timer(0.6).timeout
	if e != run_epoch:
		return
	for entry in result["pending"]:
		var d: Dictionary = entry[0]
		var idx: int = c["crew"].find(d)
		if idx >= 0 and idx < toks.size():
			var tk: Label = toks[idx]
			_flash(tk)
			tk.modulate = MOD_WOUNDED if entry[1] == "wounded" else MOD_LOST
			_mkemoji(tk.position + Vector2(70, 6), Vector2(40, 40), 26, screen_root).text = "🩹" if entry[1] == "wounded" else "⚰️"
		await get_tree().create_timer(0.35).timeout
		if e != run_epoch:
			return
	await get_tree().create_timer(0.4).timeout

# ============================================================ Outcome + clock
func _build_outcome(c: Dictionary, result: Dictionary) -> void:
	_mklabel("— OUTCOME —", Vector2(0, 210), Vector2(720, 28), 22, screen_root)
	var big: String = "✅  SUCCESS" if result["success"] else "❌  SETBACK"
	_mklabel(big, Vector2(0, 300), Vector2(720, 44), 30, screen_root, true, C_GREEN if result["success"] else C_RED)
	_mklabel("%s — %s" % [c["title"], c["loc_name"]], Vector2(0, 360), Vector2(720, 24), 16, screen_root, true, Color(0.85, 0.85, 0.9))
	_mklabel("+%dg" % int(result["payout"]), Vector2(0, 430), Vector2(720, 52), 40, screen_root, true, C_COIN)
	continue_btn = Button.new()
	continue_btn.text = "Continue ▶"
	continue_btn.add_theme_font_size_override("font_size", 22)
	continue_btn.position = Vector2(240, 1150)
	continue_btn.size = Vector2(240, 70)
	continue_btn.disabled = true
	continue_btn.pressed.connect(_on_continue)
	screen_root.add_child(continue_btn)

func _outcome_beats(c: Dictionary, result: Dictionary, e: int) -> void:
	var pay: int = int(result["payout"])
	_spawn_coins(Vector2(360, 560), Vector2(56, 62), 6)
	treasury += pay
	_tween_treasury_to(treasury)
	_msg("Payout banked: +%dg" % pay)
	await get_tree().create_timer(0.7).timeout
	if e != run_epoch:
		return
	var verdict := await _advance_months(int(c["duration"]), e)
	if verdict == "abort":
		return
	if verdict == "bankrupt":
		_game_over("bankrupt")
		return
	# Apply wounds AFTER the advance so a job never heals the crew it just hurt.
	for entry in result["pending"]:
		var d: Dictionary = entry[0]
		if entry[1] == "lost":
			d["status"] = "lost"
			d["recover"] = 0
		else:
			d["status"] = "wounded"
			d["recover"] = WOUND_RECOVERY
	if verdict == "victory":
		_game_over("victory")
		return
	busy = false
	if is_instance_valid(continue_btn):
		continue_btn.disabled = false
	_msg("Back home. Continue when ready.")

# Returns "ok" | "bankrupt" | "victory" | "abort".
func _advance_months(count: int, e: int) -> String:
	for i in range(count):
		month += 1
		months_survived = month
		for d in roster:
			if d["status"] == "wounded":
				d["recover"] = int(d["recover"]) - 1
				if int(d["recover"]) <= 0:
					d["status"] = "ready"
					d["recover"] = 0
		_refresh_hud()
		await get_tree().create_timer(0.4).timeout
		if e != run_epoch:
			return "abort"
		if month % FEE_PERIOD == 0:
			if treasury < fee:
				return "bankrupt"
			await _drain_fee(e)
			if e != run_epoch:
				return "abort"
	if month >= WIN_MONTH:
		return "victory"
	return "ok"

func _drain_fee(e: int) -> void:
	_msg("Rent! The landlord collects %dg." % fee)
	_spawn_coins(Vector2(56, 62), Vector2(668, 48), 6)
	if is_instance_valid(landlord):
		_flash(landlord)
	treasury -= fee
	_tween_treasury_to(treasury)
	await get_tree().create_timer(0.55).timeout
	if e != run_epoch:
		return
	fee += FEE_STEP
	_refresh_hud()

func _on_continue() -> void:
	if busy:
		return
	_regen_contracts()
	_enter_dashboard()

func _on_rest() -> void:
	if busy:
		return
	busy = true
	var e := run_epoch
	_msg("Resting a month — the crew mends, but rent still looms.")
	var verdict := await _advance_months(1, e)
	if verdict == "abort":
		return
	if verdict == "bankrupt":
		_game_over("bankrupt")
		return
	if verdict == "victory":
		_game_over("victory")
		return
	busy = false
	_regen_contracts()
	_enter_dashboard()

# ============================================================ Coin VFX
func _tween_treasury_to(target: int) -> void:
	var tw := create_tween()
	tw.tween_method(Callable(self, "_apply_treasury_label"), float(_tre_shown), float(target), 0.5)
	_tre_shown = target

func _spawn_coins(from: Vector2, to: Vector2, n: int) -> void:
	for i in range(n):
		var coin := ColorRect.new()
		coin.color = C_COIN
		coin.size = Vector2(16, 16)
		coin.position = from + Vector2(randf_range(-24, 24), randf_range(-16, 16))
		coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(coin)
		var tw := create_tween().set_parallel(true)
		tw.tween_property(coin, "position", to, 0.5).set_delay(i * 0.04)
		tw.tween_property(coin, "modulate:a", 0.15, 0.5).set_delay(i * 0.04)
		get_tree().create_timer(0.75).timeout.connect(coin.queue_free)

# ============================================================ Game over
func _game_over(kind: String) -> void:
	busy = false
	state = "GAMEOVER"
	_clear_screen()
	var msg := ""
	match kind:
		"victory":
			msg = "The dwarves made it —\n%d months solvent.\nThe demon lord's targets are met." % months_survived
		"bankrupt":
			msg = "💥  BANKRUPT\nThe rent went unpaid after %d months.\nThe contract is void." % months_survived
		"disbanded":
			msg = "The company disbands —\nno dwarves left to send.\nSurvived %d months." % months_survived
	overlay_label.text = msg
	overlay_btn.text = "New Company"
	overlay.visible = true
	_refresh_hud()

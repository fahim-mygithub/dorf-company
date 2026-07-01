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
const COMBAT_SCENE := preload("res://scenes/combat/combat.tscn")

# ============================================================ Economy (tunable)
const START_TREASURY := 80    # Phase 0 retune: with PAYOUT.low 25, a Low-only "safe" grind can NO
                              # LONGER reach month 12 solvent — the fee now forces greedier jobs (A1/A2).
const FEE_BASE := 55          # rent is now MONTHLY (a month holds up to 3 campaigns), so a higher base
const FEE_STEP := 10          # fee rises this much each month
const FEE_PERIOD := 1         # rent due EVERY month
const WIN_MONTH := 8          # survive 8 months solvent -> victory (each month = up to 3 campaigns)
const CAMPAIGNS_PER_MONTH := 3   # jobs you can run before the month ends and rent comes due
const WOUND_RECOVERY := 2     # months a downed dwarf is benched; returns at full HP
const HP_REGEN_PER_MONTH := 6 # Phase 2: a ready-but-hurt dwarf mends this much HP per month
# Phase 4: post-win reward pool — universal chassis cards any dwarf can learn (signatures stay in
# starting decks, role-locked). Adding one to a dwarf's deck is how runs recombine (StS deckbuilding).
const REWARD_POOL := ["strike", "guard", "cleave", "wall"]
# Phase 5: contract modifiers — one data tag reshapes BOTH the job offer (payout) and the fight
# (enemy scale), so "which job" carries more variety from the same 3 enemies. Cheapest recomb axis.
const MODIFIERS := [
	{"key": "elite",     "name": "Elite",     "emoji": "👑", "scale": 1.40, "pay": 1.3, "tip": "A champion leads them — much tougher, pays more."},
	{"key": "lucrative", "name": "Lucrative", "emoji": "💰", "scale": 1.10, "pay": 1.7, "tip": "A rich contract — big payout, only a touch harder."},
	{"key": "grim",      "name": "Grim",      "emoji": "💀", "scale": 1.25, "pay": 1.15, "tip": "Something worse waits below — harder, a little more coin."},
]
const MOD_CHANCE := 0.45
const DWARF_STRENGTH := 3     # flat in MVP (class only drives emoji/color)

const DANGER := {"low": 8, "med": 13, "high": 15}     # crew_strength + 2d6 must reach this
const PAYOUT := {"low": 25, "med": 80, "high": 100}   # low 30->25 (Phase 0): safe grind now insufficient
const DURATION := {"low": 1, "med": 2, "high": 1}
const CREW_SIZE := {"low": 1, "med": 3, "high": 3}    # low = crew_size-1 lifeline
const WOUND_CHANCE := {"low": 0.05, "med": 0.20, "high": 0.35}
const LOSS_CHANCE := {"low": 0.0, "med": 0.04, "high": 0.12}
const FAILURE_PAYOUT_MULT := 0.5
const FAILURE_ATTRITION_MULT := 2.0

const LOSS_ENABLED := false   # STEP 1: wounds only (A5). Step 2 flips true.
const CREW_SELECT := true     # Phase 3: player picks WHICH dwarves crew each fight.
const USE_REAL_COMBAT := true # Phase 1 mesh: the top size-3 (High) contract launches a REAL fight.

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
var campaigns_left := 3       # campaigns remaining this month (resets at month end)
var crew_pick: Array = []     # Phase 3: dwarves the player has tapped for the current fight
var pending_spoils: Array = [] # Phase 4: reward card ids awaiting a pick after a won fight
var spoils_pick := -1
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
	for j in range(CAMPAIGNS_PER_MONTH):
		fee_pips.append(_rect(Vector2(500 + j * 26, 86), Vector2(20, 18), C_GREEN, hud))
	_mklabel("jobs left", Vector2(490, 108), Vector2(140, 16), 11, hud, false, Color(0.7, 0.7, 0.75))
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
	for j in range(fee_pips.size()):
		var p: ColorRect = fee_pips[j]
		p.color = C_GREEN if j < campaigns_left else Color(0.25, 0.25, 0.3)

# ============================================================ Run setup
func _new_run() -> void:
	run_epoch += 1
	busy = false
	treasury = START_TREASURY
	_tre_shown = START_TREASURY
	fee = FEE_BASE
	month = 0
	months_survived = 0
	campaigns_left = CAMPAIGNS_PER_MONTH
	selected_contract = -1
	roster = []
	for s in STARTERS:
		var mh: int = int(Db.CLASSES[s["cls"]]["max_hp"])
		roster.append({"name": s["name"], "cls": s["cls"], "status": "ready", "recover": 0, "hp": mh, "max_hp": mh,
			"deck": (Db.CLASSES[s["cls"]]["deck"] as Array).duplicate()})   # Phase 4: persistent, growable deck
	_regen_contracts()
	overlay.visible = false
	_msg("Rent's due at each month's end and only climbs. Run up to 3 campaigns a month.")
	_enter_dashboard()

func _regen_contracts() -> void:
	contracts = [_make_contract("low"), _make_contract("med"), _make_contract("high")]
	# Phase 1: the High job is a REAL fight, but only when a canonical W/C/S trio is fieldable
	# (keeps combat's role-indexed logic valid until Phase 3 de-indexes it).
	# Phase 3: combat is role-based (de-indexed), so ANY 3 ready dwarves can crew a fight.
	if USE_REAL_COMBAT and _ready_count() >= 3:
		contracts[1]["fight"] = true   # Med — the standard fight
		contracts[2]["fight"] = true   # High — heavier comp + scaled (see Db.ENCOUNTERS_BY_TIER)
		for i in [1, 2]:               # Phase 5: sometimes a modifier reshapes the fight contract
			if randf() < MOD_CHANCE:
				contracts[i]["mod"] = MODIFIERS[randi() % MODIFIERS.size()]

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
	_mklabel("%d campaign%s left this month · rent %dg due at month end" % [campaigns_left, "" if campaigns_left == 1 else "s", fee], Vector2(0, 256), Vector2(720, 20), 14, screen_root, true, C_AMBER if campaigns_left <= 1 else Color(0.72, 0.84, 0.95))
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
	rest.text = "⏭️ End Month"
	rest.add_theme_font_size_override("font_size", 17)
	rest.position = Vector2(24, 1150)
	rest.size = Vector2(180, 70)
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
	else:
		# READY: an HP bar (carried damage) — length + colour read the risk of sending them at a glance.
		var frac: float = clampf(float(d["hp"]) / float(d["max_hp"]), 0.0, 1.0)
		var barw: float = 84.0
		var hpcol: Color = C_GREEN if frac > 0.6 else (C_AMBER if frac > 0.3 else C_RED)
		_rect(Vector2(cx - barw / 2.0, cy + 88), Vector2(barw, 9), Color(0.25, 0.25, 0.3), screen_root)
		_rect(Vector2(cx - barw / 2.0, cy + 88), Vector2(barw * frac, 9), hpcol, screen_root)
		if int(d["hp"]) < int(d["max_hp"]):
			_mklabel("%d/%d" % [int(d["hp"]), int(d["max_hp"])], Vector2(cx - 58, cy + 100), Vector2(116, 16), 11, screen_root, true, hpcol)

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
	if c.has("mod"):
		_mklabel("%s %s" % [c["mod"]["emoji"], c["mod"]["name"]], Vector2(6, 194), Vector2(204, 22), 15, card, true, Color(1.0, 0.85, 0.4))
	var coins: int = COIN_STACK[tier]
	for j in range(coins):
		_rect(Vector2(63, 330 - j * 15), Vector2(90, 12), C_COIN, card)
	var eff_pay: int = int(round(float(int(c["payout"])) * (float(c["mod"]["pay"]) if c.has("mod") else 1.0)))
	_mklabel("%dg" % eff_pay, Vector2(6, 340), Vector2(204, 30), 22, card, true, C_COIN)
	_mklabel("crew", Vector2(6, 392), Vector2(204, 18), 12, card, true, Color(0.8, 0.8, 0.85))
	var cs: int = int(c["crew_size"])
	for j in range(cs):
		_rect(Vector2(108 - cs * 15.0 + j * 30, 414), Vector2(24, 24), Color(0.1, 0.1, 0.13), card)
	_mklabel("1 of 3 campaigns", Vector2(6, 460), Vector2(204, 18), 12, card, true, Color(0.68, 0.68, 0.73))
	if c.get("fight", false):
		_mklabel("⚔️ REAL FIGHT", Vector2(6, 508), Vector2(204, 22), 15, card, true, Color(1.0, 0.85, 0.4))
	if not takeable:
		_mklabel("need %d ready" % cs, Vector2(6, 540), Vector2(204, 22), 14, card, true, C_RED)
	elif i == selected_contract:
		_mklabel("tap again to %s" % ("FIGHT" if c.get("fight", false) else "embark"), Vector2(6, 540), Vector2(204, 22), 14, card, true, C_GREEN)
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
	if USE_REAL_COMBAT and c.get("fight", false):
		if CREW_SELECT:
			_open_crew_select(c)          # player picks the crew, then launches
		else:
			current["crew"] = _canonical_trio()
			await _embark_fight(c)
		return
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

# ============================================================ Real-combat mesh (Phase 1)
func _first_ready_of(cls: String) -> Variant:
	for d in roster:
		if d["status"] == "ready" and d["cls"] == cls:
			return d
	return null

func _has_canonical_trio() -> bool:
	return _first_ready_of("warrior") != null and _first_ready_of("cleric") != null and _first_ready_of("sorcerer") != null

func _canonical_trio() -> Array:
	return [_first_ready_of("warrior"), _first_ready_of("cleric"), _first_ready_of("sorcerer")]

# ============================================================ Crew select (Phase 3)
func _open_crew_select(c: Dictionary) -> void:
	crew_pick = []
	state = "CREW"
	_clear_screen()
	_build_crew_select(c)
	_refresh_hud()

func _build_crew_select(c: Dictionary) -> void:
	_mklabel("— CHOOSE YOUR CREW —", Vector2(0, 186), Vector2(720, 28), 22, screen_root)
	var eff: int = int(round(float(int(c["payout"])) * (float(c["mod"]["pay"]) if c.has("mod") else 1.0)))
	var modtxt: String = ("  ·  %s %s" % [c["mod"]["emoji"], c["mod"]["name"]]) if c.has("mod") else ""
	_mklabel("%s  ·  %s danger  ·  pays %dg%s" % [c["title"], TIER_LABEL[c["tier"]], eff, modtxt], Vector2(0, 220), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
	_mklabel("Tap %d ready dwarves to send. Who do you risk?" % int(c["crew_size"]), Vector2(0, 244), Vector2(720, 20), 13, screen_root, true, Color(0.7, 0.7, 0.75))
	var avail: Array = []
	for d in roster:
		if d["status"] == "ready":
			avail.append(d)
	var n: int = avail.size()
	var startx: int = 360 - (n - 1) * 90
	for i in range(n):
		_build_pick_token(avail[i], startx + i * 180, 400)
	_mklabel("crew", Vector2(0, 640), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
	var cs: int = int(c["crew_size"])
	var sx: int = 360 - cs * 44
	for j in range(cs):
		_rect(Vector2(sx + j * 88, 668), Vector2(76, 76), Color(0.14, 0.14, 0.18), screen_root)
		if j < crew_pick.size():
			_mkemoji(Vector2(sx + j * 88 + 38, 706), Vector2(70, 70), 40, screen_root).text = Db.CLASSES[crew_pick[j]["cls"]]["emoji"]
	_build_crew_gauge(c)
	var launch := Button.new()
	launch.text = "⚔️ Launch"
	launch.add_theme_font_size_override("font_size", 22)
	launch.position = Vector2(240, 1150)
	launch.size = Vector2(240, 70)
	launch.disabled = crew_pick.size() != cs
	launch.pressed.connect(_launch_fight)
	screen_root.add_child(launch)
	var back := Button.new()
	back.text = "◀ Back"
	back.add_theme_font_size_override("font_size", 18)
	back.position = Vector2(30, 1150)
	back.size = Vector2(140, 64)
	back.pressed.connect(_on_view_contracts)
	screen_root.add_child(back)

func _build_pick_token(d: Dictionary, cx: int, cy: int) -> void:
	var picked: bool = crew_pick.has(d)
	var col: Color = CLASS_COL[d["cls"]]
	var card := Control.new()
	card.position = Vector2(cx - 70, cy - 60)
	card.size = Vector2(140, 210)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(_on_crewpick_input.bind(d))
	screen_root.add_child(card)
	if picked:
		_rect(Vector2(-3, -3), Vector2(146, 216), C_GREEN, card)
	_rect(Vector2.ZERO, Vector2(140, 210), Color(col.r, col.g, col.b, 0.28 if picked else 0.14), card)
	_mkemoji(Vector2(70, 54), Vector2(110, 84), 52, card).text = Db.CLASSES[d["cls"]]["emoji"]
	_mklabel(d["name"], Vector2(0, 106), Vector2(140, 22), 15, card)
	_mklabel(Db.CLASSES[d["cls"]]["name"], Vector2(0, 128), Vector2(140, 16), 11, card, true, Color(0.75, 0.75, 0.8))
	var frac: float = clampf(float(d["hp"]) / float(d["max_hp"]), 0.0, 1.0)
	var hpcol: Color = C_GREEN if frac > 0.6 else (C_AMBER if frac > 0.3 else C_RED)
	_rect(Vector2(28, 150), Vector2(84, 9), Color(0.25, 0.25, 0.3), card)
	_rect(Vector2(28, 150), Vector2(84 * frac, 9), hpcol, card)
	_mklabel("%d/%d" % [int(d["hp"]), int(d["max_hp"])], Vector2(0, 162), Vector2(140, 16), 11, card, true, hpcol)
	_mklabel("🃏 %d cards" % (d["deck"].size() if d.has("deck") else 0), Vector2(0, 182), Vector2(140, 16), 11, card, true, Color(0.82, 0.78, 0.55))
	if picked:
		_mklabel(str(crew_pick.find(d) + 1), Vector2(110, 2), Vector2(26, 24), 16, card, true, C_GREEN)

func _build_crew_gauge(c: Dictionary) -> void:
	var y: int = 792
	var has_cleric: bool = false
	var has_sorc: bool = false
	var tothp: int = 0
	for d in crew_pick:
		if d["cls"] == "cleric": has_cleric = true
		if d["cls"] == "sorcerer": has_sorc = true
		tothp += int(d["hp"])
	if crew_pick.size() == int(c["crew_size"]):
		var warns: Array = []
		if not has_cleric: warns.append("⚠ no healer — no Mend / Shield / Aura")
		if not has_sorc: warns.append("⚠ no burst — no Mark / Channel / Finisher")
		if warns.is_empty():
			_mklabel("balanced crew — all three roles", Vector2(0, y), Vector2(720, 20), 14, screen_root, true, C_GREEN)
		else:
			for i in range(warns.size()):
				_mklabel(warns[i], Vector2(0, y + i * 22), Vector2(720, 20), 13, screen_root, true, C_AMBER)
	if not crew_pick.is_empty():
		_mklabel("crew HP pool: %d" % tothp, Vector2(0, y + 50), Vector2(720, 18), 12, screen_root, true, Color(0.8, 0.8, 0.85))

func _on_crewpick_input(event: InputEvent, d: Dictionary) -> void:
	if busy or state != "CREW":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if crew_pick.has(d):
			crew_pick.erase(d)
		elif crew_pick.size() < int(current["crew_size"]):
			crew_pick.append(d)
		else:
			_msg("Crew is full — tap a chosen dwarf to swap them out.")
			return
		_clear_screen()
		_build_crew_select(current)

func _launch_fight() -> void:
	if busy or crew_pick.size() != int(current["crew_size"]):
		return
	current["crew"] = crew_pick.duplicate()
	await _embark_fight(current)

# ============================================================ Card rewards (Phase 4)
func _roll_rewards() -> Array:
	var pool: Array = REWARD_POOL.duplicate()
	pool.shuffle()
	return pool.slice(0, mini(3, pool.size()))

func _open_spoils() -> void:
	spoils_pick = -1
	state = "SPOILS"
	_clear_screen()
	_build_spoils()
	_refresh_hud()

func _build_spoils() -> void:
	_mklabel("— SPOILS OF WAR —", Vector2(0, 186), Vector2(720, 28), 22, screen_root)
	_mklabel("A card for the company — pick it, then the dwarf who learns it.", Vector2(0, 222), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
	var xs := [40, 268, 496]
	for i in range(pending_spoils.size()):
		_build_spoil_card(i, xs[i])
	_mklabel("give to:", Vector2(0, 700), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
	var targets: Array = []
	for d in current["crew"]:
		if d["status"] != "lost":
			targets.append(d)
	var n: int = targets.size()
	var startx: int = 360 - (n - 1) * 100
	for j in range(n):
		_build_spoil_target(targets[j], startx + j * 200, 800)
	var skip := Button.new()
	skip.text = "Skip"
	skip.add_theme_font_size_override("font_size", 18)
	skip.position = Vector2(285, 1150)
	skip.size = Vector2(150, 62)
	skip.pressed.connect(_skip_spoils)
	screen_root.add_child(skip)

func _build_spoil_card(i: int, x: int) -> void:
	var cid: String = pending_spoils[i]
	var def: Dictionary = Db.CARDS[cid]
	var sel: bool = (i == spoils_pick)
	var card := Control.new()
	card.position = Vector2(x, 288 if sel else 300)
	card.size = Vector2(184, 300)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(_on_spoil_card_input.bind(i))
	screen_root.add_child(card)
	if sel:
		_rect(Vector2(-3, -3), Vector2(190, 306), C_GREEN, card)
	_rect(Vector2.ZERO, Vector2(184, 300), Db.type_tint(def.get("type", "skill")), card)
	_rect(Vector2(8, 8), Vector2(40, 40), C_COIN, card)
	_mklabel(str(int(def["cost"])), Vector2(8, 14), Vector2(40, 28), 22, card, true, Color(0.1, 0.1, 0.1))
	_mkemoji(Vector2(92, 84), Vector2(100, 76), 46, card).text = def.get("emoji", "🃏")
	_mklabel(def["name"], Vector2(4, 138), Vector2(176, 26), 18, card)
	var body: Dictionary = Db.describe(def, null, 0, 0)
	_mklabel(body["text"], Vector2(8, 178), Vector2(168, 110), 14, card, true, Color(0.9, 0.9, 0.92))

func _build_spoil_target(d: Dictionary, cx: int, cy: int) -> void:
	var col: Color = CLASS_COL[d["cls"]]
	var tok := Control.new()
	tok.position = Vector2(cx - 70, cy - 60)
	tok.size = Vector2(140, 170)
	tok.mouse_filter = Control.MOUSE_FILTER_STOP
	tok.gui_input.connect(_on_spoil_target_input.bind(d))
	screen_root.add_child(tok)
	_rect(Vector2.ZERO, Vector2(140, 170), Color(col.r, col.g, col.b, 0.18), tok)
	_mkemoji(Vector2(70, 50), Vector2(110, 80), 50, tok).text = Db.CLASSES[d["cls"]]["emoji"]
	_mklabel(d["name"], Vector2(0, 100), Vector2(140, 22), 15, tok)
	_mklabel("🃏 %d cards" % int(d["deck"].size()), Vector2(0, 126), Vector2(140, 16), 11, tok, true, Color(0.82, 0.78, 0.55))

func _on_spoil_card_input(event: InputEvent, i: int) -> void:
	if state != "SPOILS":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		spoils_pick = i
		_msg("%s — now tap the dwarf who learns it." % Db.CARDS[pending_spoils[i]]["name"])
		_clear_screen()
		_build_spoils()

func _on_spoil_target_input(event: InputEvent, d: Dictionary) -> void:
	if state != "SPOILS":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if spoils_pick < 0:
			_msg("Pick a card first.")
			return
		var cid: String = pending_spoils[spoils_pick]
		d["deck"].append(cid)
		_finish_spoils("%s learned %s — deck now %d cards." % [d["name"], Db.CARDS[cid]["name"], int(d["deck"].size())])

func _skip_spoils() -> void:
	_finish_spoils("Left the spoils behind.")

func _finish_spoils(msg: String) -> void:
	pending_spoils = []
	spoils_pick = -1
	_msg(msg)
	await _after_campaign()

func _build_crew_specs(crew: Array) -> Array:
	var specs: Array = []
	for d in crew:
		# Phase 2: carry CURRENT hp in. Phase 4: send the dwarf's PERSISTENT deck (combat duplicates it).
		specs.append({"cls": d["cls"], "name": d["name"], "hp": int(d["hp"]), "max_hp": int(d["max_hp"]),
			"deck": d.get("deck", (Db.CLASSES[d["cls"]]["deck"] as Array))})
	return specs

## Run combat.tscn as a CHILD, send the crew, await the result, map it into the SAME
## {success,payout,pending} shape the dice path produces, then feed the UNCHANGED outcome pipeline.
func _embark_fight(c: Dictionary) -> void:
	busy = true
	var e := run_epoch
	selected_contract = -1
	_msg("%s — into the fight!" % c["title"])
	var fight = COMBAT_SCENE.instantiate()
	var req: Dictionary = {"crew": _build_crew_specs(current["crew"])}
	var comp: Dictionary = Db.ENCOUNTERS_BY_TIER.get(c["tier"], {})   # Phase 2: danger tier -> enemy composition
	var mscale: float = float(c["mod"]["scale"]) if c.has("mod") else 1.0   # Phase 5: modifier scales the fight
	if not comp.is_empty():
		req["enemies"] = comp["enemies"]
		req["enemy_scale"] = float(comp["scale"]) * mscale
	fight.request = req   # set BEFORE add_child (_ready runs on entry)
	screen_root.visible = false
	hud.visible = false
	add_child(fight)
	var result: Dictionary = await fight.combat_finished
	if e != run_epoch:
		if is_instance_valid(fight):
			fight.queue_free()
		return
	fight.queue_free()
	screen_root.visible = true
	hud.visible = true
	var shaped: Dictionary = _resolve_from_combat(result, current["tier"])
	state = "OUTCOME"
	_clear_screen()
	_build_outcome(current, shaped)
	_refresh_hud()
	await _outcome_beats(current, shaped, e)
	if e != run_epoch:
		return
	if state != "GAMEOVER" and shaped["success"]:
		pending_spoils = _roll_rewards()   # Phase 4: a card reward waits on the OUTCOME's Continue

func _resolve_from_combat(result: Dictionary, tier: String) -> Dictionary:
	var success: bool = result["success"]
	var mpay: float = float(current["mod"]["pay"]) if current.has("mod") else 1.0   # Phase 5 modifier
	var payout: int = int(round(float(PAYOUT[tier]) * mpay * (1.0 if success else FAILURE_PAYOUT_MULT)))
	var pending: Array = []
	var crew_results: Array = result["crew_results"]
	for i in range(crew_results.size()):
		var cr: Dictionary = crew_results[i]
		var d: Dictionary = current["crew"][i]
		d["hp"] = maxi(0, int(cr["hp_end"]))   # Phase 2: carry battle damage back onto the roster
		if not cr["survived"]:
			# Downed -> benched (heals to full on return). Survivors stay READY but hurt (carried HP).
			pending.append([d, "lost" if LOSS_ENABLED else "wounded"])
	return {"success": success, "payout": payout, "pending": pending, "roll": 0, "strength": 0}

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

func _outcome_beats(_c: Dictionary, result: Dictionary, e: int) -> void:
	var pay: int = int(result["payout"])
	_spawn_coins(Vector2(360, 560), Vector2(56, 62), 6)
	treasury += pay
	_tween_treasury_to(treasury)
	_msg("Payout banked: +%dg" % pay)
	await get_tree().create_timer(0.7).timeout
	if e != run_epoch:
		return
	# A campaign does NOT advance the clock now — wounds land immediately; rent waits for month-end.
	for entry in result["pending"]:
		var d: Dictionary = entry[0]
		if entry[1] == "lost":
			d["status"] = "lost"
			d["recover"] = 0
		else:
			d["status"] = "wounded"
			d["recover"] = WOUND_RECOVERY
	campaigns_left -= 1
	busy = false
	if is_instance_valid(continue_btn):
		continue_btn.disabled = false
	_refresh_hud()
	_msg("Campaign done — %d left before rent." % campaigns_left)

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
					d["hp"] = int(d["max_hp"])   # back from the bench at full fighting shape
			elif d["status"] == "ready" and int(d["hp"]) > 0 and int(d["hp"]) < int(d["max_hp"]):
				d["hp"] = mini(int(d["max_hp"]), int(d["hp"]) + HP_REGEN_PER_MONTH)   # carried HP mends over time
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
	if not pending_spoils.is_empty():
		_open_spoils()
		return
	await _after_campaign()

# After a campaign resolves: another slot if any remain, else the month ends (rent due).
func _after_campaign() -> void:
	if campaigns_left <= 0:
		await _end_month()
	else:
		_regen_contracts()
		_enter_dashboard()

# Advance one month: crew mends + wounds tick, then rent comes due; resets the campaign slots.
func _end_month() -> void:
	if busy:
		return
	busy = true
	var e := run_epoch
	_msg("The month closes — rent comes due.")
	var verdict := await _advance_months(1, e)
	if verdict == "abort":
		return
	if verdict == "bankrupt":
		_game_over("bankrupt")
		return
	if verdict == "victory":
		_game_over("victory")
		return
	campaigns_left = CAMPAIGNS_PER_MONTH
	busy = false
	_regen_contracts()
	_enter_dashboard()

func _on_rest() -> void:
	# "End Month": advance to the next month now, forgoing any remaining campaigns (crew mends, rent due).
	await _end_month()

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

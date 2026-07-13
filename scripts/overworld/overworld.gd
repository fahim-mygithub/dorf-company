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
const HexTile := preload("res://scripts/ui/hex_tile.gd")

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
const REWARD_POOL := ["strike", "guard", "cleave", "wall",
	# 2026-07-01 expansion: the 9 GENERIC cards join the universal pool (class cards stay role-locked).
	"power_through", "precise_jab", "whetstone", "guard_break", "field_dressing",
	"bracing_stance", "opportunist", "rally", "trophy_hunter"]
# Class-gated reward cards, offered on hex reward tiles when a crew member of that class is present.
const CLASS_REWARDS := {
	"warrior":  ["reckless_swing", "second_wind", "momentum_strike"],
	"cleric":   ["lay_on_hands", "consecrate", "divine_smite"],
	"sorcerer": ["arc_lightning", "empower", "kindle"],
}
# Phase 5: contract modifiers — one data tag reshapes BOTH the job offer (payout) and the fight
# (enemy scale), so "which job" carries more variety from the same 3 enemies. Cheapest recomb axis.
const MODIFIERS := [
	{"key": "elite",     "name": "Elite",     "emoji": "👑", "scale": 1.50, "pay": 1.3, "tip": "A champion leads them — much tougher, pays more."},
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

const CREW_SELECT := true     # Phase 3: player picks WHICH dwarves crew each fight.
const USE_REAL_COMBAT := true # Phase 1 mesh: the top size-3 (High) contract launches a REAL fight.

# ============================================================ Hex-crawl expedition (2026-07-01, redesign 2)
# A VISIBLE-BOARD route-planner (no fog): the whole map is shown, the objective location is marked,
# and every passable tile telegraphs its KIND (fight/loot/mystery) + a rough danger read. The
# perimeter is impassable wall; you route through the interior to the captive. "Objective pays big"
# (the rescue is the bulk of the payout); loot tiles add optional side-gold. Enemy scale comes from a
# combat tile's telegraphed DANGER, not from distance.
const EXPEDITIONS := true          # Med/High fight contracts open an expedition (not one fight).
const HEX_COLS := 6                # offset-hex grid width  (border cols are wall)
const HEX_ROWS := 5                # offset-hex grid height (border rows are wall) -> 4x3 = 12 passable
const HEX_R := 50.0                # pointy-top hex radius (px): width = R*sqrt(3), row pitch = R*1.5
const DANGER_STEP := 0.21         # combat enemy_scale = 1 + (danger-1)*step  (danger 1/2/3 -> 1.0/1.21/1.42)
                                  # 0.30->0.225->0.21 (scaling audit v2/v3): at 0.30 the d3 band was a
                                  # 0%-win wall; 0.21 lifts every worst-corner comp past the >=2% gate
const HEX_POST_FIGHT_HEAL := 5    # living crew patch up after a WON combat hex — chains were pure attrition
const DS_SUCCESS_NEEDED := 3       # death saves: 3 successes -> stable (benched, lives)
const DS_FAIL_NEEDED := 3          # 3 failures -> dead (LOSS_ENABLED path)
const DS_SUCCESS_CHANCE := 0.55    # tuned toward survival; dorfs cheap-not-free
const EVENT_RISK_GOLD := 24        # risky event: gold on the good outcome
const EVENT_SAFE_GOLD := 8         # safe event: a little coin
const HEX_REWARD_GOLD := 18        # a gold reward tile
# Shop (H5) — money's second job: uplift for bad dorfs, competing with rent.
const SHOP_CARD_COST := 35
const SHOP_HEAL_COST := 25
const SHOP_RECRUIT_COST := 50
const RECRUIT_NAMES := ["Durn", "Kael", "Brom", "Hilda", "Nael", "Torvi", "Grund", "Sif"]

const LOSS_ENABLED := true    # Now SAFE: death only via failed death saves, and the shop's Recruit refills the roster.

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
# Expedition (hex-crawl) state
var exp_contract: Dictionary = {}   # the contract being run as an expedition
var exp_crew: Array = []            # the fixed 3 crew dwarves for this expedition
var hexes: Dictionary = {}          # "col,row" -> hex dict (offset coords; kind/danger/resolved/objective)
var hex_cur := ""                   # current hex key
var exp_loot_gold := 0              # side-gold collected this expedition (paid out on extract/rescue)
var hex_loot: Array = []            # card ids offered on a reward tile
var hex_loot_pick := -1
var hex_event: Dictionary = {}      # the active event tile
# Shop state (per month)
var shop_stock: Array = []          # [{kind,...}] 3 slots, re-rolled each month
var shop_sel := -1                  # selected shop slot awaiting a dwarf target

# ============================================================ Co-op (CampaignNet)
## The campaign replicates itself the way combat does, one layer up. The HOST is the only mutator
## and the only die-roller; it broadcasts an ABSOLUTE snapshot after every change. A client renders
## that snapshot and sends INTENTS — it never rolls, never runs a guarded coroutine, never writes.
##
## Two classes of intent:
##   RING — shared risk (embark / move / extract / event / end-month / a buy that dips under rent).
##          A proposal opens a ring and fires only when every PRESENT seat has said aye. Proposing
##          IS your aye. This is combat's "everyone ends their own turn" grammar, one layer up.
##   FREE — instant and yours alone (navigate, select, claim a loot card, an affordable buy).
##
## Wire events, chosen NOT to collide with combat's (submit_action / combat_ready / resync / ready /
## apply_snapshot / match_over) — the nested fight shares this one Net autoload with us:
##   camp_snapshot  host -> all   the whole company, absolute
##   camp_intent    client -> host   {seat, kind, arg, iseq}
##   camp_hello     client -> host   heartbeat; doubles as presence + "send me the board"
enum Mode { SOLO, AUTHORITY, CLIENT }
const PARTY_STEP := 0.34      # enemy_scale shifts this per crew member away from the 3 the sim tuned for
const HEIR_HP_FRAC := 0.5     # an heir walks in at half health: a real cost, not a free respawn
const STABLE_HP_FRAC := 0.25  # a dwarf who survives their death saves comes home on their last legs
const HELLO_SEC := 3.0        # client heartbeat
const ABSENT_SEC := 12.0      # silent this long and the seat stops blocking the ring (AFK escape hatch)
const INTENT_RETRY_SEC := 1.2 # broadcast is fire-and-forget: keep knocking until the host acks
const RING_KINDS := ["embark", "hex", "extract", "event", "endmonth"]

var mode: int = Mode.SOLO
var request: Dictionary = {}     # lobby/harness handoff; set BEFORE add_child (parsed in _ready)
var my_seat := 0
var seat_count := 1
var seats: Array = []            # [{name, cls, present}] — seat i pilots roster[i], for the whole campaign
var ring: Dictionary = {}        # the open proposal: {pid, kind, arg, by, required:[seat], ayes:[seat]}
var carried: Array = []          # co-op: the fallen, riding the wagon, still rolling death saves
var fight_req: Dictionary = {}   # non-empty = a fight is live; the host-rolled request EVERY peer runs
var outcome: Dictionary = {}     # view-model for the OUTCOME screen (clients can't replay the beats)
var over_kind := ""              # GAMEOVER reason, replicated
var msg_text := ""               # the ticker, replicated
var _pid := 0
var _seq := 0
var _last_seq := -1
var _iseq := 0                   # client: my own intent counter
var _seat_iseq: Array = []       # host: highest iseq applied per seat. Also the client's ACK channel.
var _pending_intent: Dictionary = {}
var _intent_accum := 0.0
var _hello_accum := 0.0
var _sweep_accum := 0.0
var _last_seen: Array = []       # host-only: msec of each seat's last hello
var _fight_node: Node = null
var _fid := 0
var _cur_fid := 0

# ============================================================ UI refs
var crew_bar: Control            # co-op: the seat pips + the open proposal (chrome; survives _clear_screen)
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
var hex_flag: Label                 # the current-tile 🚩 glyph; hidden while the move token animates

# ============================================================ Lifecycle
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Co-op handoff from the lobby (consume-and-clear: a later SOLO run must not inherit it).
	if request.is_empty() and not Net.campaign_request.is_empty():
		request = Net.campaign_request
		Net.campaign_request = {}
	# Parse the net block ONCE. No request (the standalone overworld build) = SOLO, which never
	# touches Net — the single-player campaign stays byte-identical.
	var net: Dictionary = request.get("net", {})
	var m: String = str(net.get("mode", ""))
	mode = Mode.AUTHORITY if m == "authority" else (Mode.CLIENT if m == "client" else Mode.SOLO)
	my_seat = int(net.get("seat", 0))
	seat_count = int(net.get("seat_count", 1))
	seats = (request.get("seats", []) as Array).duplicate(true)
	_build_chrome()
	if mode == Mode.SOLO:
		_new_run()
		return
	Net.ensure_peer_id()
	Net.message_received.connect(_on_net)
	Net.realtime_joined.connect(_on_net_rejoined)
	_seat_iseq = []
	for i in range(seat_count):
		_seat_iseq.append(0)
	if mode == Mode.AUTHORITY:
		_last_seen = []
		for i in range(seat_count):
			_last_seen.append(Time.get_ticks_msec())
		_new_run()
	else:
		state = "BOOT"
		_msg("Joining the company…")
		_render()
		_send_hello()   # the host answers with the whole board

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
	msg_text = s
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
	overlay_btn.pressed.connect(_on_overlay_btn)
	overlay.add_child(overlay_btn)
	overlay.visible = false

	# Co-op crew bar: who is at the table, who has said aye, and what is on the floor. It is CHROME
	# (a sibling of screen_root), so it survives every _clear_screen and shows on every screen.
	crew_bar = Control.new()
	crew_bar.position = Vector2(0, 1006)
	crew_bar.size = Vector2(720, 74)
	crew_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	crew_bar.visible = mode != Mode.SOLO
	add_child(crew_bar)

func _on_overlay_btn() -> void:
	if mode == Mode.CLIENT:
		_intent("restart", "")
		return
	_new_run()

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
	_refresh_ring()
	# Every screen rebuild ends here, which makes this the one honest "the board changed" hook.
	# _push() is a no-op unless we are the host.
	_push()

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
	ring = {}
	carried = []
	fight_req = {}
	outcome = {}
	over_kind = ""
	roster = []
	if mode == Mode.SOLO:
		for s in STARTERS:
			roster.append(_make_dwarf(s["name"], s["cls"]))
	else:
		# Co-op: the roster IS the table. One dwarf per seat, and it is yours for the whole campaign.
		for i in range(seats.size()):
			var sd: Dictionary = seats[i]
			var d := _make_dwarf(str(sd.get("name", "Dorf")), str(sd.get("cls", "warrior")))
			d["seat"] = i
			roster.append(d)
	_reroll_shop()
	_regen_contracts()
	overlay.visible = false
	_msg("Rent's due at each month's end and only climbs. Run up to 3 campaigns a month.")
	_enter_dashboard()

# One roster dwarf. downed/stable/ds_* are per-EXPEDITION death-save state (reset each expedition start).
func _make_dwarf(dname: String, cls: String) -> Dictionary:
	var mh: int = int(Db.CLASSES[cls]["max_hp"])
	return {"name": dname, "cls": cls, "status": "ready", "recover": 0, "hp": mh, "max_hp": mh,
		"deck": (Db.CLASSES[cls]["deck"] as Array).duplicate(),
		"downed": false, "stable": false, "ds_success": 0, "ds_fail": 0}

func _regen_contracts() -> void:
	contracts = [_make_contract("low"), _make_contract("med"), _make_contract("high")]
	# Phase 1: the High job is a REAL fight, but only when a canonical W/C/S trio is fieldable
	# (keeps combat's role-indexed logic valid until Phase 3 de-indexes it).
	# Phase 3: combat is role-based (de-indexed), so ANY 3 ready dwarves can crew a fight.
	# Co-op fields the whole table (2-4), so the "enough dwarves for a real fight" bar is the seat count.
	var need: int = 3 if mode == Mode.SOLO else roster.size()
	if USE_REAL_COMBAT and _ready_count() >= need:
		contracts[1]["fight"] = true   # Med — the standard fight
		contracts[2]["fight"] = true   # High — heavier comp + scaled (see Db.ENCOUNTERS_BY_TIER)
		for i in [1, 2]:               # Phase 5: sometimes a modifier reshapes the fight contract
			if randf() < MOD_CHANCE:
				contracts[i]["mod"] = MODIFIERS[randi() % MODIFIERS.size()]

func _make_contract(tier: String) -> Dictionary:
	var titles: Array = TITLES[tier]
	var loc: Dictionary = LOCATIONS[randi() % LOCATIONS.size()]
	# Co-op: a fight contract fields EVERY seat (nobody sits a job out). Low stays the 1-dwarf
	# dice lifeline it is in solo, so its risk/reward curve is unchanged.
	var cs: int = int(CREW_SIZE[tier])
	if mode != Mode.SOLO and tier != "low":
		cs = roster.size()
	return {
		"tier": tier,
		"title": titles[randi() % titles.size()],
		"loc_emoji": loc["emoji"],
		"loc_name": loc["name"],
		"payout": int(PAYOUT[tier]),
		"duration": int(DURATION[tier]),
		"danger": int(DANGER[tier]),
		"crew_size": cs,
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
	if mode != Mode.SOLO:
		_intent("nav", "contracts")
		return
	_do_view_contracts()

func _do_view_contracts() -> void:
	selected_contract = -1
	state = "CONTRACTS"
	_clear_screen()
	_build_contracts()
	_refresh_hud()

func _on_back_dashboard() -> void:
	if busy:
		return
	if mode != Mode.SOLO:
		_intent("nav", "dashboard")
		return
	_enter_dashboard()

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
	_build_shop_panel()
	var back := Button.new()
	back.text = "◀ Back"
	back.add_theme_font_size_override("font_size", 18)
	back.position = Vector2(30, 1150)
	back.size = Vector2(150, 64)
	back.pressed.connect(_on_back_dashboard)
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
		if mode != Mode.SOLO:
			# First tap highlights it for the table (free); the second PROPOSES it (a ring).
			if selected_contract != i:
				_intent("select", str(i))
			else:
				_intent("embark", str(i))
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
		if mode != Mode.SOLO:
			current["crew"] = roster.duplicate()   # co-op: the crew IS the table — no crew-select screen
			_open_expedition(c)
			return
		if CREW_SELECT:
			_open_crew_select(c)          # player picks the crew, then launches
		elif EXPEDITIONS:
			current["crew"] = _canonical_trio()
			_open_expedition(c)
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
	_set_outcome("dice", current, result)
	_clear_screen()
	_build_outcome(current, result)
	_refresh_hud()
	await _outcome_beats(current, result, e)

func _auto_assign_crew(c: Dictionary) -> Array:
	var pool: Array = []
	for d in roster:
		if d["status"] == "ready":
			pool.append(d)
	if mode != Mode.SOLO:
		pool.shuffle()   # co-op: the short straw on a Low job is DRAWN, not always the host's dwarf
	var crew: Array = []
	for d in pool:
		if crew.size() < int(c["crew_size"]):
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
	if EXPEDITIONS:
		_open_expedition(current)   # multi-hex expedition (uses the same seam per combat hex)
	else:
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
	var req: Dictionary = {"crew": _build_crew_specs(current["crew"])}
	var comp: Dictionary = Db.ENCOUNTERS_BY_TIER.get(c["tier"], {})   # Phase 2: danger tier -> enemy composition
	var mscale: float = float(c["mod"]["scale"]) if c.has("mod") else 1.0   # Phase 5: modifier scales the fight
	if not comp.is_empty():
		req["enemies"] = _roll_encounter(c["tier"], comp)
		req["enemy_scale"] = 1.0 + (float(comp["scale"]) - 1.0) + (mscale - 1.0) + _party_scale()   # additive (see _hex_combat)
	var result: Dictionary = await _run_fight(req, e)
	if result.is_empty():
		return
	var shaped: Dictionary = _resolve_from_combat(result, current["tier"])
	state = "OUTCOME"
	_set_outcome("fight", current, shaped)
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
		if mode != Mode.SOLO:
			# Co-op: a benched dwarf is a benched PLAYER. Nobody sits out months of a campaign —
			# they come back hurt instead. Death is already settled by the wagon rule (see
			# _reseat_fallen / _finish_expedition), so "lost" needs nothing here.
			if entry[1] != "lost":
				d["hp"] = maxi(1, int(round(float(d["max_hp"]) * STABLE_HP_FRAC)))
			continue
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
	if mode != Mode.SOLO:
		_intent("continue", "")
		return
	await _do_continue()

func _do_continue() -> void:
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
	_reroll_shop()   # shop stock refreshes each month
	_regen_contracts()
	_enter_dashboard()

func _on_rest() -> void:
	# "End Month": advance to the next month now, forgoing any remaining campaigns (crew mends, rent due).
	# Co-op: burning the rest of the month is the table's call, not one player's.
	if mode != Mode.SOLO:
		_intent("endmonth", "")
		return
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
	over_kind = kind
	_clear_screen()
	_game_over_ui(kind)
	_refresh_hud()

func _game_over_ui(kind: String) -> void:
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

# ============================================================ Hex-crawl expedition (2026-07-01 spec)
## An expedition = a small run-within-a-contract: a fogged hex map, per-hex combat via the SAME seam,
## push-or-extract after each tile, death saves for the downed. It resolves into the SAME
## {success,payout,pending} shape the dice/single-fight paths produce, so rent/spoils stay unchanged.
## Re-entrancy: capture e := run_epoch at each entry and re-check after EVERY await (report §9.3).

func _open_expedition(c: Dictionary) -> void:
	exp_contract = c
	exp_crew = c["crew"].duplicate()   # shallow: elements are the roster dicts (carried HP/status persists)
	carried = []
	exp_loot_gold = 0
	for d in exp_crew:                 # reset per-expedition death-save state; carried HP stays as-is
		d["downed"] = false
		d["stable"] = false
		d["ds_success"] = 0
		d["ds_fail"] = 0
	_gen_hex_map(c)
	state = "HEX"
	busy = false
	_msg("The whole warren's mapped. Route to the captive — or grab loot and get out.")
	_clear_screen()
	_build_hexcrawl()
	_refresh_hud()

func _hex_key(cc: int, rr: int) -> String:
	return "%d,%d" % [cc, rr]

## Odd-r offset neighbours (odd rows are shoved right half a tile — matches _hex_px).
func _hex_neighbors(key: String) -> Array:
	var h: Dictionary = hexes[key]
	var cc: int = int(h["q"])
	var rr: int = int(h["r"])
	var diffs: Array
	if rr % 2 == 0:
		diffs = [[1, 0], [0, -1], [-1, -1], [-1, 0], [-1, 1], [0, 1]]
	else:
		diffs = [[1, 0], [1, -1], [0, -1], [-1, 0], [0, 1], [1, 1]]
	var out: Array = []
	for d in diffs:
		var k := _hex_key(cc + d[0], rr + d[1])
		if hexes.has(k):
			out.append(k)
	return out

## BFS hop-distance from `start` over PASSABLE tiles (walls block); writes each hex["dist"].
func _bfs_dist(start: String) -> void:
	for k in hexes:
		hexes[k]["dist"] = -1
	hexes[start]["dist"] = 0
	var queue: Array = [start]
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		var cd: int = int(hexes[cur]["dist"])
		for nk in _hex_neighbors(cur):
			if hexes[nk]["kind"] == "wall":
				continue
			if int(hexes[nk]["dist"]) < 0:
				hexes[nk]["dist"] = cd + 1
				queue.append(nk)

## A fixed 6x5 offset grid: border ring = impassable WALL, 4x3 = 12 passable interior.
## Entry at a corner, objective on the farthest passable tile (visible), rest telegraphed.
func _gen_hex_map(_c: Dictionary) -> void:
	hexes = {}
	for rr in range(HEX_ROWS):
		for cc in range(HEX_COLS):
			var wall: bool = cc == 0 or cc == HEX_COLS - 1 or rr == 0 or rr == HEX_ROWS - 1
			hexes[_hex_key(cc, rr)] = {"q": cc, "r": rr, "kind": ("wall" if wall else "empty"),
				"danger": 0, "resolved": wall, "objective": false, "dist": 0}
	var entry: String = _hex_key(1, HEX_ROWS - 2)   # bottom-left interior corner
	hexes[entry]["kind"] = "entry"
	hexes[entry]["resolved"] = true
	hex_cur = entry
	_bfs_dist(entry)
	# objective = farthest passable tile (so the captive is always across the map)
	var objk: String = entry
	var maxd: int = -1
	for k in hexes:
		var h: Dictionary = hexes[k]
		if h["kind"] == "wall" or k == entry:
			continue
		if int(h["dist"]) > maxd:
			maxd = int(h["dist"])
			objk = k
	hexes[objk]["kind"] = "objective"
	hexes[objk]["objective"] = true
	hexes[objk]["resolved"] = false
	# assign telegraphed content to the remaining interior tiles
	var rest: Array = []
	for k in hexes:
		if hexes[k]["kind"] == "empty":
			rest.append(k)
	rest.shuffle()
	var bag: Array = _content_bag(rest.size())
	for i in range(rest.size()):
		var k: String = rest[i]
		var kind: String = bag[i]
		hexes[k]["kind"] = kind
		if kind == "combat":
			var dd: int = int(hexes[k]["dist"])
			hexes[k]["danger"] = clampi(1 + int(float(dd) * 0.4) + (randi() % 2), 1, 3)   # deeper tiles read deadlier
		elif kind == "empty":
			hexes[k]["resolved"] = true   # a quiet passage, nothing to trigger

## Content mix for the interior: ~45% combat, ~25% loot, ~15% event, rest quiet.
func _content_bag(n: int) -> Array:
	var bag: Array = []
	var nc: int = maxi(1, int(round(float(n) * 0.45)))
	var nr: int = maxi(1, int(round(float(n) * 0.25)))
	var ne: int = maxi(1, int(round(float(n) * 0.15)))
	for i in range(nc):
		bag.append("combat")
	for i in range(nr):
		bag.append("reward")
	for i in range(ne):
		bag.append("event")
	while bag.size() < n:
		bag.append("empty")
	bag = bag.slice(0, n)
	bag.shuffle()
	return bag

func _danger_scale(danger: int) -> float:
	return 1.0 + float(maxi(0, danger - 1)) * DANGER_STEP

## Encounter variety (2026-07-01): roll a comp from the tier's pool; scale still comes from
## ENCOUNTERS_BY_TIER. Missing/empty pool falls back to the fixed comp (old behavior).
func _roll_encounter(tier: String, comp: Dictionary) -> Array:
	var pool: Array = Db.ENCOUNTER_POOLS.get(tier, [])
	if pool.is_empty():
		return comp["enemies"]
	return pool[randi() % pool.size()]

func _living_up() -> Array:
	var up: Array = []
	for d in exp_crew:
		if d["status"] != "lost" and not bool(d["downed"]):
			up.append(d)
	return up

# ---------------------------------------------------------- Hex map render
func _hex_px(cc: int, rr: int) -> Vector2:
	var w := HEX_R * sqrt(3.0)                                   # pointy-top hex width
	var x0 := 360.0 - w * (float(HEX_COLS) + 0.5) * 0.5 + w * 0.5  # center the board (odd rows shove right)
	return Vector2(x0 + w * (float(cc) + 0.5 * float(rr & 1)), 300.0 + HEX_R * 1.5 * float(rr))

func _build_hexcrawl() -> void:
	_mklabel("— EXPEDITION —", Vector2(0, 168), Vector2(720, 26), 20, screen_root)
	var c := exp_contract
	var modtxt: String = ("  ·  %s %s" % [c["mod"]["emoji"], c["mod"]["name"]]) if c.has("mod") else ""
	_mklabel("%s  ·  %s%s" % [c["title"], c["loc_name"], modtxt], Vector2(0, 196), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
	_mklabel("Route to 🏁 the captive. Icons hint the tile; ☠ = how tough. Detour for loot if you dare.", Vector2(0, 220), Vector2(720, 18), 12, screen_root, true, Color(0.7, 0.7, 0.75))
	# war-table backdrop: the board sits on a dark framed panel instead of floating
	_rect(Vector2(48, 240), Vector2(624, 432), Color(0.05, 0.06, 0.08), screen_root)
	_rect(Vector2(48, 240), Vector2(624, 2), Color(0.72, 0.58, 0.30, 0.30), screen_root)
	_rect(Vector2(48, 670), Vector2(624, 2), Color(0.72, 0.58, 0.30, 0.30), screen_root)
	_rect(Vector2(48, 240), Vector2(2, 432), Color(0.72, 0.58, 0.30, 0.30), screen_root)
	_rect(Vector2(670, 240), Vector2(2, 432), Color(0.72, 0.58, 0.30, 0.30), screen_root)
	for k in hexes:
		_build_hex_tile(k)
	_build_exp_crew_strip()
	_mklabel("loot bag  +%dg  ·  🏁 the rescue pays the real money" % exp_loot_gold, Vector2(24, 1112), Vector2(430, 18), 12, screen_root, false, Color(0.85, 0.8, 0.55))
	var ex := Button.new()
	ex.text = "🏳️ Extract (+%dg)" % exp_loot_gold
	ex.add_theme_font_size_override("font_size", 18)
	ex.position = Vector2(430, 1146)
	ex.size = Vector2(266, 70)
	ex.disabled = busy
	ex.pressed.connect(_on_extract)
	screen_root.add_child(ex)

func _build_hex_tile(key: String) -> void:
	var h: Dictionary = hexes[key]
	var px := _hex_px(int(h["q"]), int(h["r"]))
	var sz := Vector2(HEX_R * sqrt(3.0), HEX_R * 2.0)
	var kind: String = h["kind"]
	var wall: bool = kind == "wall"
	var cur: bool = key == hex_cur
	var resolved: bool = bool(h["resolved"])
	var can_move: bool = not wall and not cur and _hex_neighbors(hex_cur).has(key)
	var tile: Control = HexTile.new()
	tile.radius = HEX_R
	tile.flat = wall                                        # walls sit IN the board; passable tiles pop
	tile.hoverable = can_move
	tile.position = px - sz * 0.5
	tile.size = sz
	tile.mouse_filter = Control.MOUSE_FILTER_STOP if can_move else Control.MOUSE_FILTER_IGNORE
	if can_move:
		tile.gui_input.connect(_on_hex_input.bind(key))
	# terrain-tinted fill per kind; resolved desaturates toward the board
	if wall:
		tile.fill = Color(0.11, 0.12, 0.14)
	elif cur:
		tile.fill = Color(0.30, 0.44, 0.58)
	elif kind == "objective":
		tile.fill = Color(0.46, 0.36, 0.13)
	elif resolved:
		tile.fill = Color(0.17, 0.21, 0.18)
	elif kind == "combat":
		tile.fill = Color(0.34, 0.21, 0.17)
	elif kind == "reward":
		tile.fill = Color(0.20, 0.31, 0.17)
	elif kind == "event":
		tile.fill = Color(0.27, 0.21, 0.33)
	else:
		tile.fill = Color(0.23, 0.26, 0.23)
	# pulsing highlight ring replaces the old rect frames: gold = the goal, amber = reachable
	if kind == "objective":
		tile.ring = Color(C_COIN.r, C_COIN.g, C_COIN.b, 0.95)
	elif can_move:
		tile.ring = Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.80)
	screen_root.add_child(tile)
	var glyph := ""
	if wall:
		glyph = "🏔️"
	elif cur:
		glyph = "🚩"
	elif kind == "objective":
		glyph = "🏁"
	elif resolved:
		glyph = "✔️"
	elif kind == "combat":
		glyph = "⚔️"
	elif kind == "reward":
		glyph = "🎁"
	elif kind == "event":
		glyph = "❔"
	else:
		glyph = "·"
	var gy: float = -8.0 if (kind == "combat" and not resolved) else 0.0
	var em := _mkemoji(sz * 0.5 + Vector2(0, gy), sz, 26, tile)
	em.text = glyph
	if wall:
		em.modulate = Color(1, 1, 1, 0.55)                  # the ridge recedes; passable content pops
	if cur:
		hex_flag = em
	if kind == "combat" and not resolved:
		var sk := ""
		for i in range(int(h["danger"])):
			sk += "☠"
		_mklabel(sk, Vector2(0, sz.y * 0.5 + 12), Vector2(sz.x, 16), 12, tile, true, Color(0.95, 0.5, 0.5))

func _build_exp_crew_strip() -> void:
	_mklabel("crew", Vector2(0, 716), Vector2(720, 18), 12, screen_root, true, Color(0.8, 0.8, 0.85))
	var n := exp_crew.size()
	var startx := 360 - (n - 1) * 120
	for i in range(n):
		_build_exp_crew_token(exp_crew[i], startx + i * 240, 800)

func _build_exp_crew_token(d: Dictionary, cx: int, cy: int) -> void:
	var col: Color = CLASS_COL[d["cls"]]
	_rect(Vector2(cx - 66, cy - 66), Vector2(132, 168), Color(col.r, col.g, col.b, 0.16), screen_root)
	var emo := _mkemoji(Vector2(cx, cy - 28), Vector2(96, 70), 44, screen_root)
	emo.text = Db.CLASSES[d["cls"]]["emoji"]
	var dead: bool = d["status"] == "lost"
	var down := bool(d["downed"])
	if dead:
		emo.modulate = MOD_LOST
	elif down:
		emo.modulate = MOD_WOUNDED
	_mklabel(d["name"], Vector2(cx - 66, cy + 16), Vector2(132, 20), 14, screen_root)
	if dead:
		_mklabel("💀 dead", Vector2(cx - 66, cy + 38), Vector2(132, 18), 12, screen_root, true, C_RED)
	elif bool(d["stable"]):
		_mklabel("🩹 stable", Vector2(cx - 66, cy + 38), Vector2(132, 18), 12, screen_root, true, C_AMBER)
	elif down:
		_mklabel("DOWNED — save:", Vector2(cx - 66, cy + 38), Vector2(132, 18), 11, screen_root, true, C_RED)
		var sx := cx - 40
		for j in range(DS_SUCCESS_NEEDED):
			_rect(Vector2(sx + j * 16, cy + 58), Vector2(12, 12), C_GREEN if j < int(d["ds_success"]) else Color(0.22, 0.3, 0.22), screen_root)
		for j in range(DS_FAIL_NEEDED):
			_rect(Vector2(sx + j * 16, cy + 74), Vector2(12, 12), C_RED if j < int(d["ds_fail"]) else Color(0.3, 0.22, 0.22), screen_root)
	else:
		var frac := clampf(float(d["hp"]) / float(d["max_hp"]), 0.0, 1.0)
		var hpcol: Color = C_GREEN if frac > 0.6 else (C_AMBER if frac > 0.3 else C_RED)
		_rect(Vector2(cx - 42, cy + 44), Vector2(84, 9), Color(0.25, 0.25, 0.3), screen_root)
		_rect(Vector2(cx - 42, cy + 44), Vector2(84 * frac, 9), hpcol, screen_root)
		_mklabel("%d/%d" % [int(d["hp"]), int(d["max_hp"])], Vector2(cx - 66, cy + 56), Vector2(132, 16), 11, screen_root, true, hpcol)

# ---------------------------------------------------------- Hex movement + resolution
func _on_hex_input(event: InputEvent, key: String) -> void:
	if busy or state != "HEX":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if hexes[key]["kind"] != "wall" and _hex_neighbors(hex_cur).has(key):
			if mode != Mode.SOLO:
				_intent("hex", key)   # pushing deeper risks everyone — the whole crew has to agree
				return
			await _enter_hex(key)

func _enter_hex(key: String) -> void:
	busy = true
	var e := run_epoch
	# the flag marches to the new hex before it resolves, so movement reads spatially
	var from := _hex_px(int(hexes[hex_cur]["q"]), int(hexes[hex_cur]["r"]))
	var to := _hex_px(int(hexes[key]["q"]), int(hexes[key]["r"]))
	if is_instance_valid(hex_flag):
		hex_flag.visible = false
	var tok := _mkemoji(from, Vector2(60, 60), 26, screen_root)
	tok.text = "🚩"
	var tw := create_tween()
	tw.tween_property(tok, "position", to - tok.size * 0.5, 0.28).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	if is_instance_valid(tok):
		tok.queue_free()
	if e != run_epoch:
		return
	hex_cur = key
	var h: Dictionary = hexes[key]
	_roll_death_saves()                    # each step = time passing for the downed
	if not bool(h["resolved"]) and not h["kind"] == "entry":
		match h["kind"]:
			"objective":
				await _finish_expedition("objective", e)
				return
			"combat":
				h["resolved"] = true
				_msg("They ambush you here!")
				await _hex_combat(int(h["danger"]), e)
				if e != run_epoch:
					return
			"reward":
				h["resolved"] = true
				_open_hex_reward(e)
				return
			"event":
				h["resolved"] = true
				_open_hex_event(e)
				return
			_:
				h["resolved"] = true
				_msg("A quiet passage.")
	await _resume_hex(e)

## Return to the map after a tile resolves; a wipe (nobody up) ends the expedition here.
func _resume_hex(e: int) -> void:
	if e != run_epoch:
		return
	if _living_up().is_empty():
		await _finish_expedition("wipe", e)
		return
	_reseat_fallen()   # co-op: nobody spectates the next tile
	busy = false
	state = "HEX"
	_clear_screen()
	_build_hexcrawl()
	_refresh_hud()

func _roll_death_saves() -> void:
	# Co-op: the downed are on the WAGON (their seat is already back in the fight with an heir),
	# so it is the wagon that rolls, not the walking crew.
	var pool: Array = carried if mode != Mode.SOLO else exp_crew
	for d in pool:
		if d["status"] == "lost" or bool(d["stable"]) or not bool(d["downed"]):
			continue
		if randf() < DS_SUCCESS_CHANCE:
			d["ds_success"] = int(d["ds_success"]) + 1
		else:
			d["ds_fail"] = int(d["ds_fail"]) + 1
		if int(d["ds_success"]) >= DS_SUCCESS_NEEDED:
			d["stable"] = true
			_msg("%s clings on — stable, but out of the fight." % d["name"])
		elif int(d["ds_fail"]) >= DS_FAIL_NEEDED:
			d["status"] = "lost"
			d["downed"] = false
			_msg("%s bleeds out. Gone." % d["name"])

## Enemy scale = tier base x contract modifier x the tile's telegraphed DANGER (not distance).
func _hex_combat(danger: int, e: int) -> void:
	var req: Dictionary = {"crew": _build_crew_specs(exp_crew)}   # downed dwarves ride in at 0 HP (benched slot)
	var comp: Dictionary = Db.ENCOUNTERS_BY_TIER.get(exp_contract["tier"], {})
	var mscale: float = float(exp_contract["mod"]["scale"]) if exp_contract.has("mod") else 1.0
	if not comp.is_empty():
		req["enemies"] = _roll_encounter(exp_contract["tier"], comp)
		# Scaling audit (2026-07-01): threat factors compose ADDITIVELY — multiplying tier x mod x
		# danger grew ~quadratically (worst 2.688 was 0% winnable in sim). Single-factor cells unchanged.
		# _party_scale() is the co-op term: the encounters were tuned for a crew of 3.
		req["enemy_scale"] = 1.0 + (float(comp["scale"]) - 1.0) + (mscale - 1.0) + (_danger_scale(danger) - 1.0) + _party_scale()
	var result: Dictionary = await _run_fight(req, e)
	if result.is_empty():
		return
	var crew_results: Array = result["crew_results"]
	for i in range(crew_results.size()):
		var cr: Dictionary = crew_results[i]
		var d: Dictionary = exp_crew[i]
		d["hp"] = maxi(0, int(cr["hp_end"]))
		if not cr["survived"] and not bool(d["downed"]) and d["status"] != "lost":
			d["downed"] = true          # newly downed -> starts rolling death saves next tile
	if result["success"]:
		# Patch up after a won fight — without this, expeditions were pure attrition and long
		# routes were mathematically uncompletable (scaling audit v2).
		for d in exp_crew:
			if d["status"] != "lost" and not bool(d["downed"]) and int(d["hp"]) > 0:
				d["hp"] = mini(int(d["max_hp"]), int(d["hp"]) + HEX_POST_FIGHT_HEAL)
	_msg("The ambush is broken — the crew patches up." if result["success"] else "The crew is overrun…")

# ---------------------------------------------------------- Reward tile (loot -> loot bag / a card)
func _open_hex_reward(e: int) -> void:
	if randf() < 0.35:                    # a coin cache instead of a card
		var g := HEX_REWARD_GOLD + (randi() % 12)
		exp_loot_gold += g
		_msg("A cache of coin: +%dg to the loot bag." % g)
		await _resume_hex(e)
		return
	hex_loot = _roll_hex_loot()
	hex_loot_pick = -1
	state = "HEXREWARD"
	_clear_screen()
	_build_hex_reward()
	_refresh_hud()

func _roll_hex_loot() -> Array:
	var pool: Array = REWARD_POOL.duplicate()
	var seen := {}
	for d in exp_crew:
		if d["status"] != "lost":
			seen[d["cls"]] = true
	for cls in seen:
		for cid in CLASS_REWARDS.get(cls, []):
			pool.append(cid)
	pool.shuffle()
	var out: Array = []
	for cid in pool:
		if not out.has(cid):
			out.append(cid)
		if out.size() >= 3:
			break
	return out

func _build_hex_reward() -> void:
	_mklabel("— SPOILS —", Vector2(0, 200), Vector2(720, 28), 22, screen_root)
	var xs := [40, 268, 496]
	if mode != Mode.SOLO:
		# Co-op: one card leaves this tile. Tap it and it is YOURS — first claim wins, so talk fast.
		_mklabel("One card leaves this room. Claim it and it joins YOUR deck — first tap wins.",
			Vector2(0, 238), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
		for i in range(hex_loot.size()):
			_build_hex_loot_card(i, xs[i])
		var skip2 := Button.new()
		skip2.text = "Leave it"
		skip2.add_theme_font_size_override("font_size", 18)
		skip2.position = Vector2(285, 1150)
		skip2.size = Vector2(150, 62)
		skip2.pressed.connect(_on_hexloot_skip)
		screen_root.add_child(skip2)
		return
	_mklabel("Take a card for the company — then the dwarf who learns it.", Vector2(0, 238), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
	for i in range(hex_loot.size()):
		_build_hex_loot_card(i, xs[i])
	_mklabel("give to:", Vector2(0, 720), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
	var targets: Array = []
	for d in exp_crew:
		if d["status"] != "lost":
			targets.append(d)
	var n := targets.size()
	var startx := 360 - (n - 1) * 100
	for j in range(n):
		_build_hex_loot_target(targets[j], startx + j * 200, 820)
	var skip := Button.new()
	skip.text = "Leave it"
	skip.add_theme_font_size_override("font_size", 18)
	skip.position = Vector2(285, 1150)
	skip.size = Vector2(150, 62)
	skip.pressed.connect(_on_hexloot_skip)
	screen_root.add_child(skip)

func _build_hex_loot_card(i: int, x: int) -> void:
	var cid: String = hex_loot[i]
	var def: Dictionary = Db.CARDS[cid]
	var sel: bool = i == hex_loot_pick
	var card := Control.new()
	card.position = Vector2(x, 300 if not sel else 288)
	card.size = Vector2(184, 300)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(_on_hexloot_card_input.bind(i))
	screen_root.add_child(card)
	if sel:
		_rect(Vector2(-3, -3), Vector2(190, 306), C_GREEN, card)
	_rect(Vector2.ZERO, Vector2(184, 300), Db.type_tint(def.get("type", "skill")), card)
	_rect(Vector2(8, 8), Vector2(40, 40), C_COIN, card)
	_mklabel(str(int(def["cost"])), Vector2(8, 14), Vector2(40, 28), 22, card, true, Color(0.1, 0.1, 0.1))
	_mkemoji(Vector2(92, 84), Vector2(100, 76), 46, card).text = def.get("emoji", "🃏")
	_mklabel(def["name"], Vector2(4, 138), Vector2(176, 26), 18, card)
	var body: Dictionary = Db.describe(def, null, 0, 0)
	_mklabel(body["text"], Vector2(8, 178), Vector2(168, 114), 13, card, true, Color(0.9, 0.9, 0.92))

func _build_hex_loot_target(d: Dictionary, cx: int, cy: int) -> void:
	var col: Color = CLASS_COL[d["cls"]]
	var tok := Control.new()
	tok.position = Vector2(cx - 70, cy - 60)
	tok.size = Vector2(140, 190)
	tok.mouse_filter = Control.MOUSE_FILTER_STOP
	tok.gui_input.connect(_on_hexloot_target_input.bind(d))
	screen_root.add_child(tok)
	_rect(Vector2.ZERO, Vector2(140, 190), Color(col.r, col.g, col.b, 0.18), tok)
	_mkemoji(Vector2(70, 50), Vector2(110, 80), 50, tok).text = Db.CLASSES[d["cls"]]["emoji"]
	_mklabel(d["name"], Vector2(0, 100), Vector2(140, 22), 15, tok)
	_mklabel("🃏 %d cards" % int(d["deck"].size()), Vector2(0, 126), Vector2(140, 16), 11, tok, true, Color(0.82, 0.78, 0.55))
	if bool(d["downed"]) or bool(d["stable"]):
		_mklabel("(down)", Vector2(0, 148), Vector2(140, 16), 11, tok, true, C_AMBER)

func _on_hexloot_card_input(event: InputEvent, i: int) -> void:
	if state != "HEXREWARD":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if mode != Mode.SOLO:
			_intent("loot", str(i))   # claims it for MY dwarf
			return
		hex_loot_pick = i
		_msg("%s — now tap the dwarf who learns it." % Db.CARDS[hex_loot[i]]["name"])
		_clear_screen()
		_build_hex_reward()

func _on_hexloot_target_input(event: InputEvent, d: Dictionary) -> void:
	if state != "HEXREWARD":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if hex_loot_pick < 0:
			_msg("Pick a card first.")
			return
		var cid: String = hex_loot[hex_loot_pick]
		d["deck"].append(cid)
		_msg("%s learned %s." % [d["name"], Db.CARDS[cid]["name"]])
		hex_loot = []
		hex_loot_pick = -1
		await _resume_hex(run_epoch)

func _on_hexloot_skip() -> void:
	if state != "HEXREWARD":   # guard parity with the other loot handlers (no double-fire after rebuild)
		return
	if mode != Mode.SOLO:
		_intent("loot_skip", "")
		return
	await _do_hexloot_skip()

func _do_hexloot_skip() -> void:
	hex_loot = []
	hex_loot_pick = -1
	_msg("Left the spoils behind.")
	await _resume_hex(run_epoch)

# ---------------------------------------------------------- Event tile
func _open_hex_event(_e: int) -> void:
	state = "HEXEVENT"   # choices re-capture run_epoch on click
	_clear_screen()
	_build_hex_event()
	_refresh_hud()

func _build_hex_event() -> void:
	_mklabel("— A CHOICE —", Vector2(0, 300), Vector2(720, 28), 22, screen_root)
	_mklabel("A sealed door, and a faint cry beyond it.", Vector2(0, 344), Vector2(720, 22), 15, screen_root, true, Color(0.85, 0.85, 0.9))
	var safe := Button.new()
	safe.text = "🚪 Play it safe\n(+%dg loot)" % EVENT_SAFE_GOLD
	safe.add_theme_font_size_override("font_size", 18)
	safe.position = Vector2(90, 560)
	safe.size = Vector2(240, 120)
	safe.pressed.connect(_on_event_choice.bind(false))
	screen_root.add_child(safe)
	var risk := Button.new()
	risk.text = "🗝️ Force it open\n(risk)"
	risk.add_theme_font_size_override("font_size", 18)
	risk.position = Vector2(390, 560)
	risk.size = Vector2(240, 120)
	risk.pressed.connect(_on_event_choice.bind(true))
	screen_root.add_child(risk)

func _on_event_choice(risky: bool) -> void:
	if state != "HEXEVENT":
		return
	if mode != Mode.SOLO:
		_intent("event", "risky" if risky else "safe")
		return
	await _do_event_choice(risky)

func _do_event_choice(risky: bool) -> void:
	var e := run_epoch
	state = "HEX"   # lock out double taps
	if not risky:
		exp_loot_gold += EVENT_SAFE_GOLD
		_msg("You take the cautious path. +%dg to the loot bag." % EVENT_SAFE_GOLD)
		await _resume_hex(e)
		return
	if randf() < 0.55:
		exp_loot_gold += EVENT_RISK_GOLD
		_msg("Fortune favours the bold: +%dg — and loot within." % EVENT_RISK_GOLD)
		_open_hex_reward(e)
		return
	var up := _living_up()
	if up.is_empty():
		await _resume_hex(e)
		return
	var d: Dictionary = up[randi() % up.size()]
	var dmg := int(d["max_hp"] * 0.4)
	d["hp"] = maxi(0, int(d["hp"]) - dmg)
	if int(d["hp"]) <= 0:
		d["downed"] = true
	_msg("A trap! %s takes %d." % [d["name"], dmg])
	await _resume_hex(e)

# ---------------------------------------------------------- Extract / resolve
func _on_extract() -> void:
	if busy or state != "HEX":
		return
	if mode != Mode.SOLO:
		_intent("extract", "")   # walking out with the loot is the table's call
		return
	await _finish_expedition("extract", run_epoch)

## mode: "objective" (rescue: loot + big pay) | "extract" (keep loot only) | "wipe" (lose everything).
func _finish_expedition(kind: String, e: int) -> void:
	busy = true
	if kind == "wipe":                      # the downed who never stabilised finish their saves on the way out
		for d in exp_crew:
			_finish_saves(d)
	var success := kind == "objective"
	var mpay: float = float(exp_contract["mod"]["pay"]) if exp_contract.has("mod") else 1.0
	var obj_pay: int = int(round(float(int(PAYOUT[exp_contract["tier"]])) * mpay)) if success else 0
	var loot: int = exp_loot_gold
	var payout: int = loot + obj_pay
	if kind == "wipe":
		payout = 0                          # a wipe loses the loot bag too
		loot = 0
	var pending: Array = []
	for d in exp_crew:
		if d["status"] == "lost":
			pending.append([d, "lost"])
		elif bool(d["downed"]) or bool(d["stable"]):
			pending.append([d, "wounded"])   # extract/rescue bring the fallen home wounded
		d["downed"] = false                  # clear per-expedition state
		d["stable"] = false
		d["ds_success"] = 0
		d["ds_fail"] = 0
	if mode != Mode.SOLO:
		_wagon_home(kind)
	var shaped: Dictionary = {"success": success, "payout": payout, "pending": pending,
		"loot": loot, "obj": obj_pay, "roll": 0, "strength": 0}
	current = exp_contract
	state = "OUTCOME"
	busy = false
	_set_outcome(kind, exp_contract, shaped)
	_clear_screen()
	_build_expedition_outcome(exp_contract, shaped, kind)
	_refresh_hud()
	await _outcome_beats(exp_contract, shaped, e)

func _build_expedition_outcome(c: Dictionary, result: Dictionary, kind: String) -> void:
	_mklabel("— OUTCOME —", Vector2(0, 210), Vector2(720, 28), 22, screen_root)
	var big := ""
	var col := C_GREEN
	match kind:
		"objective":
			big = "✅  CAPTIVE RESCUED"
			col = C_GREEN
		"extract":
			big = "🏳️  EXTRACTED"
			col = C_AMBER
		_:
			big = "☠️  WIPED OUT"
			col = C_RED
	_mklabel(big, Vector2(0, 300), Vector2(720, 44), 30, screen_root, true, col)
	var sub := ""
	if kind == "objective":
		sub = "🏁 rescue %dg  +  loot %dg" % [int(result["obj"]), int(result["loot"])]
	elif kind == "extract":
		sub = "loot bag %dg  ·  captive left behind" % int(result["loot"])
	else:
		sub = "everything lost in the dark"
	_mklabel("%s — %s" % [c["title"], sub], Vector2(0, 360), Vector2(720, 24), 15, screen_root, true, Color(0.85, 0.85, 0.9))
	_mklabel("+%dg" % int(result["payout"]), Vector2(0, 430), Vector2(720, 52), 40, screen_root, true, C_COIN)
	continue_btn = Button.new()
	continue_btn.text = "Continue ▶"
	continue_btn.add_theme_font_size_override("font_size", 22)
	continue_btn.position = Vector2(240, 1150)
	continue_btn.size = Vector2(240, 70)
	continue_btn.disabled = true
	continue_btn.pressed.connect(_on_continue)
	screen_root.add_child(continue_btn)

# ============================================================ Shop (contract board, H5)
func _reroll_shop() -> void:
	shop_stock = []
	shop_sel = -1
	var pool: Array = REWARD_POOL.duplicate()
	pool.shuffle()
	shop_stock.append({"kind": "card", "cid": pool[0], "cost": SHOP_CARD_COST})
	shop_stock.append({"kind": "heal", "cost": SHOP_HEAL_COST})
	if mode == Mode.SOLO:
		var rn: String = RECRUIT_NAMES[randi() % RECRUIT_NAMES.size()]
		var rc: String = Db.PARTY_ORDER[randi() % Db.PARTY_ORDER.size()]
		shop_stock.append({"kind": "recruit", "name": rn, "cls": rc, "cost": SHOP_RECRUIT_COST})
	else:
		# Co-op has no Recruit: seats are fixed and the wagon rule already refills a dead dwarf.
		shop_stock.append({"kind": "card", "cid": pool[1], "cost": SHOP_CARD_COST})

func _build_shop_panel() -> void:
	_mklabel("— SHOP —  buying trades against the rent clock", Vector2(0, 866), Vector2(720, 20), 14, screen_root, true, C_COIN)
	var xs := [24, 264, 504]
	for i in range(shop_stock.size()):
		_build_shop_slot(i, xs[i])
	if mode != Mode.SOLO:
		_mklabel("you buy for YOUR OWN dwarf · a buy that dips under the rent needs the whole crew",
			Vector2(0, 1010), Vector2(720, 16), 12, screen_root, true, Color(0.7, 0.7, 0.76))
		return
	if shop_sel >= 0 and shop_stock[shop_sel]["kind"] != "recruit":
		_build_shop_targets()

func _build_shop_slot(i: int, x: int) -> void:
	var s: Dictionary = shop_stock[i]
	var cost := int(s["cost"])
	var sold := bool(s.get("sold", false))
	var afford := treasury >= cost and not sold
	var slot := Control.new()
	slot.position = Vector2(x, 896)
	slot.size = Vector2(192, 108)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.gui_input.connect(_on_shop_input.bind(i))
	screen_root.add_child(slot)
	var bgc := Color(0.22, 0.28, 0.22) if i == shop_sel else Color(0.16, 0.16, 0.2)
	_rect(Vector2.ZERO, Vector2(192, 108), bgc, slot)
	if sold:
		slot.modulate = Color(0.4, 0.4, 0.42)
	var emoji := ""
	var title := ""
	var desc := ""
	match s["kind"]:
		"card":
			emoji = Db.CARDS[s["cid"]].get("emoji", "🃏")
			title = "Card"
			desc = Db.CARDS[s["cid"]]["name"]
		"heal":
			emoji = "🩹"
			title = "Field Medic"
			desc = "a dwarf to full HP"
		"recruit":
			emoji = Db.CLASSES[s["cls"]]["emoji"]
			title = "Recruit"
			desc = "%s · %s" % [s["name"], Db.CLASSES[s["cls"]]["name"]]
	_mkemoji(Vector2(96, 30), Vector2(80, 48), 28, slot).text = emoji
	_mklabel(title, Vector2(0, 54), Vector2(192, 18), 13, slot, true, Color(0.85, 0.85, 0.9))
	_mklabel(desc, Vector2(4, 72), Vector2(184, 16), 11, slot, true, Color(0.75, 0.75, 0.8))
	_mklabel(("SOLD" if sold else "%dg" % cost), Vector2(0, 88), Vector2(192, 18), 14, slot, true, (Color(0.6, 0.6, 0.6) if sold else (C_COIN if afford else C_RED)))

func _on_shop_input(event: InputEvent, i: int) -> void:
	if busy or state != "CONTRACTS":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var s: Dictionary = shop_stock[i]
		if bool(s.get("sold", false)):
			return
		if treasury < int(s["cost"]):
			_msg("Not enough gold — the rent comes first.")
			return
		if mode != Mode.SOLO:
			_intent("shop", str(i))   # buys for MY dwarf; below the rent line it becomes a ring
			return
		if s["kind"] == "recruit":
			_buy_recruit(i)
			return
		shop_sel = -1 if shop_sel == i else i
		_msg("Tap a dwarf below to receive it." if shop_sel >= 0 else "")
		_clear_screen()
		_build_contracts()

func _buy_recruit(i: int) -> void:
	var s: Dictionary = shop_stock[i]
	treasury -= int(s["cost"])
	_tween_treasury_to(treasury)
	roster.append(_make_dwarf(s["name"], s["cls"]))
	s["sold"] = true
	shop_sel = -1
	_msg("%s joins the company." % s["name"])
	_clear_screen()
	_build_contracts()
	_refresh_hud()

func _build_shop_targets() -> void:
	var s: Dictionary = shop_stock[shop_sel]
	_mklabel("give to:", Vector2(0, 1016), Vector2(720, 16), 12, screen_root, true, Color(0.85, 0.85, 0.9))
	var elig: Array = []
	for d in roster:
		if s["kind"] == "heal":
			if d["status"] == "wounded" or (d["status"] == "ready" and int(d["hp"]) < int(d["max_hp"])):
				elig.append(d)
		elif d["status"] != "lost":
			elig.append(d)
	if elig.is_empty():
		_mklabel("(no valid dwarf)", Vector2(0, 1040), Vector2(720, 16), 12, screen_root, true, C_AMBER)
		return
	var n := elig.size()
	var startx := 360 - (n - 1) * 48
	for i in range(n):
		_build_shop_target_token(elig[i], startx + i * 96, 1058)

func _build_shop_target_token(d: Dictionary, cx: int, cy: int) -> void:
	var col: Color = CLASS_COL[d["cls"]]
	var tok := Control.new()
	tok.position = Vector2(cx - 40, cy - 34)
	tok.size = Vector2(80, 74)
	tok.mouse_filter = Control.MOUSE_FILTER_STOP
	tok.gui_input.connect(_on_shop_target_input.bind(d))
	screen_root.add_child(tok)
	_rect(Vector2.ZERO, Vector2(80, 74), Color(col.r, col.g, col.b, 0.20), tok)
	_mkemoji(Vector2(40, 26), Vector2(70, 48), 28, tok).text = Db.CLASSES[d["cls"]]["emoji"]
	_mklabel(d["name"], Vector2(0, 54), Vector2(80, 16), 10, tok, true, Color(0.9, 0.9, 0.92))

func _on_shop_target_input(event: InputEvent, d: Dictionary) -> void:
	if busy or state != "CONTRACTS" or shop_sel < 0:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var s: Dictionary = shop_stock[shop_sel]
		if treasury < int(s["cost"]):
			return
		if s["kind"] == "card":
			d["deck"].append(s["cid"])
			treasury -= int(s["cost"])
			_tween_treasury_to(treasury)
			s["sold"] = true
			shop_sel = -1
			_msg("%s learned %s." % [d["name"], Db.CARDS[s["cid"]]["name"]])
		elif s["kind"] == "heal":
			if d["status"] == "wounded":
				d["status"] = "ready"
				d["recover"] = 0
			d["hp"] = int(d["max_hp"])
			treasury -= int(s["cost"])
			_tween_treasury_to(treasury)
			s["sold"] = true
			shop_sel = -1
			_msg("%s is patched up to full." % d["name"])
		_clear_screen()
		_build_contracts()
		_refresh_hud()


# ============================================================================================
# ============================  CO-OP CAMPAIGN (CampaignNet)  ================================
# ============================================================================================
# Everything below is INERT in SOLO: every entry point returns immediately when mode == Mode.SOLO,
# and nothing above calls into here without that guard. The single-player campaign never touches Net.

# ---------------------------------------------------------------- Snapshot (host -> everyone)
## Absolute state, every time. There is no delta and no ordering requirement: a client that misses
## three snapshots is repaired by the fourth. Campaign state is pure data (no live node refs live
## inside these dicts), so unlike combat's board this needs no "poison key" stripping — only the
## contract's "crew" is dropped, because it aliases roster dicts we already send.
func _push() -> void:
	if mode != Mode.AUTHORITY:
		return
	_seq += 1
	Net.send_message("camp_snapshot", _build_snap())

func _strip_crew(c: Dictionary) -> Dictionary:
	var d: Dictionary = c.duplicate()
	d.erase("crew")   # aliases roster dicts — they ride the snapshot once, under "roster"
	return d

func _build_snap() -> Dictionary:
	var cs: Array = []
	for c: Dictionary in contracts:
		cs.append(_strip_crew(c))
	return {
		"seq": _seq,
		"treasury": treasury, "fee": fee, "month": month, "months_survived": months_survived,
		"campaigns_left": campaigns_left, "busy": busy, "state": state, "over": over_kind,
		"roster": roster, "carried": carried, "contracts": cs, "selected_contract": selected_contract,
		"shop_stock": shop_stock,
		"hexes": hexes, "hex_cur": hex_cur, "exp_contract": _strip_crew(exp_contract),
		"exp_loot_gold": exp_loot_gold, "hex_loot": hex_loot,
		"ring": ring, "seats": seats, "seat_iseq": _seat_iseq,
		"fight": fight_req, "outcome": outcome, "msg": msg_text,
	}

## The OUTCOME screen is drawn from locals on the host (and the dice cinematic is pure animation),
## so a client has nothing to rebuild it from. Ship a small view-model instead of replaying beats.
func _set_outcome(kind: String, c: Dictionary, result: Dictionary) -> void:
	if mode == Mode.SOLO:
		return
	var r: Dictionary = result.duplicate()
	r.erase("pending")   # holds dwarf refs; the roster already carries the truth
	outcome = {"kind": kind, "contract": _strip_crew(c), "result": r}

## JSON has ONE number type: every int comes back a float. Read sites here use int()/float(), but a
## whole-number float assigned into a statically-typed int var is a hard error — so coerce on entry.
func _norm(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var f: float = v
			return int(f) if is_equal_approx(f, floor(f)) and absf(f) < 1.0e15 else f
		TYPE_ARRAY:
			var a: Array = []
			for x: Variant in (v as Array):
				a.append(_norm(x))
			return a
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			var sd: Dictionary = v
			for k: Variant in sd:
				d[k] = _norm(sd[k])
			return d
	return v

func _apply_snap(s: Dictionary) -> void:
	if mode != Mode.CLIENT:
		return
	var seq: int = int(s.get("seq", 0))
	if seq <= _last_seq:
		return   # a stale or duplicated broadcast; absolute state means we can just drop it
	_last_seq = seq
	treasury = int(s.get("treasury", 0))
	_tre_shown = treasury
	fee = int(s.get("fee", 0))
	month = int(s.get("month", 0))
	months_survived = int(s.get("months_survived", 0))
	campaigns_left = int(s.get("campaigns_left", 0))
	busy = bool(s.get("busy", false))
	state = str(s.get("state", ""))
	over_kind = str(s.get("over", ""))
	roster = _norm(s.get("roster", []))
	carried = _norm(s.get("carried", []))
	contracts = _norm(s.get("contracts", []))
	selected_contract = int(s.get("selected_contract", -1))
	shop_stock = _norm(s.get("shop_stock", []))
	hexes = _norm(s.get("hexes", {}))
	hex_cur = str(s.get("hex_cur", ""))
	exp_contract = _norm(s.get("exp_contract", {}))
	exp_loot_gold = int(s.get("exp_loot_gold", 0))
	hex_loot = _norm(s.get("hex_loot", []))
	ring = _norm(s.get("ring", {}))
	seats = _norm(s.get("seats", []))
	_seat_iseq = _norm(s.get("seat_iseq", []))
	outcome = _norm(s.get("outcome", {}))
	fight_req = _norm(s.get("fight", {}))
	current = exp_contract
	exp_crew = roster          # co-op: the crew IS the table, in seat order
	_msg(str(s.get("msg", "")))
	# The host echoes each seat's applied iseq: that IS the ack, and it is in every snapshot — so a
	# client can see it even if the one snapshot that first carried it was the one that dropped.
	if not _pending_intent.is_empty() and my_seat < _seat_iseq.size() \
			and int(_seat_iseq[my_seat]) >= int(_pending_intent.get("iseq", 0)):
		_pending_intent = {}
	# The fight rides the snapshot. Joining and leaving it are both driven by the host.
	if not fight_req.is_empty() and int(fight_req.get("fid", 0)) != _cur_fid and _fight_node == null:
		_client_join_fight()
		return
	if fight_req.is_empty() and _fight_node != null:
		_exit_fight()   # the host says the fight is over; our own match_over must have been lost
	if _fight_node != null:
		return          # a fight owns the screen — the board can wait
	_render()

# ---------------------------------------------------------------- Wire
func _on_net(event: String, p: Dictionary) -> void:
	match event:
		"camp_snapshot":
			if mode == Mode.CLIENT:
				_apply_snap(p)
		"camp_intent":
			if mode == Mode.AUTHORITY:
				_authority_intent(p)
		"camp_hello":
			if mode == Mode.AUTHORITY:
				_mark_seen(int(p.get("seat", -1)))
				_push()   # a hello is also "send me the board" — this is the whole resync path

## The socket dropped and Net re-dialed. One absolute snapshot repairs whatever we missed.
func _on_net_rejoined() -> void:
	if mode == Mode.AUTHORITY:
		_push()
	elif mode == Mode.CLIENT:
		_send_hello()

func _send_hello() -> void:
	if mode == Mode.CLIENT:
		Net.send_message("camp_hello", {"seat": my_seat})

func _process(delta: float) -> void:
	if mode == Mode.SOLO:
		return
	if mode == Mode.AUTHORITY:
		_sweep_accum += delta
		if _sweep_accum >= 1.0:
			_sweep_accum = 0.0
			_sweep_absent()
		return
	_hello_accum += delta
	if _hello_accum >= HELLO_SEC:
		_hello_accum = 0.0
		_send_hello()
	# Broadcast is fire-and-forget: keep re-sending the SAME iseq until the host acks it. The host's
	# per-seat high-water mark makes the retry idempotent, so this can never double-apply.
	if not _pending_intent.is_empty():
		_intent_accum += delta
		if _intent_accum >= INTENT_RETRY_SEC:
			_intent_accum = 0.0
			Net.send_message("camp_intent", _pending_intent)

# ---------------------------------------------------------------- Intents
func _intent(kind: String, arg: String) -> void:
	if mode == Mode.SOLO:
		return
	_iseq += 1
	var p: Dictionary = {"seat": my_seat, "kind": kind, "arg": arg, "iseq": _iseq}
	if mode == Mode.AUTHORITY:
		_authority_intent(p)   # the host taps through the same validator as everyone else
		return
	_pending_intent = p
	_intent_accum = 0.0
	Net.send_message("camp_intent", p)

func _authority_intent(p: Dictionary) -> void:
	if mode != Mode.AUTHORITY:
		return
	var seat: int = int(p.get("seat", -1))
	if seat < 0 or seat >= seat_count or seat >= _seat_iseq.size():
		return
	var iseq: int = int(p.get("iseq", 0))
	if iseq <= int(_seat_iseq[seat]):
		return   # a retry of something already applied — ack again by snapshot, but never re-apply
	_seat_iseq[seat] = iseq
	_mark_seen(seat)
	var kind: String = str(p.get("kind", ""))
	var arg: String = str(p.get("arg", ""))
	if _is_ring(kind, arg):
		_ring_intent(seat, kind, arg)
		return
	_apply_free(seat, kind, arg)
	_push()

## Is this decision the whole table's to make? Consequence decides, not the name: a shop buy is
## yours alone until it eats the rent money, and then it is everybody's problem.
func _is_ring(kind: String, arg: String) -> bool:
	if RING_KINDS.has(kind):
		return true
	if kind == "shop":
		var i: int = int(arg)
		if i < 0 or i >= shop_stock.size():
			return false
		return treasury - int(shop_stock[i]["cost"]) < fee
	return false

func _apply_free(seat: int, kind: String, arg: String) -> void:
	match kind:
		"nav":
			if busy:
				return
			if arg == "contracts":
				_do_view_contracts()
			else:
				_enter_dashboard()
		"select":
			if busy or state != "CONTRACTS":
				return
			var i: int = int(arg)
			if i < 0 or i >= contracts.size():
				return
			selected_contract = i
			var c: Dictionary = contracts[i]
			_msg("%s eyes %s — tap it again to put it to the crew." % [_seat_name(seat), c["title"]])
			_clear_screen()
			_build_contracts()
		"continue":
			if busy:
				return
			_do_continue()
		"loot":
			_claim_loot(seat, int(arg))
		"loot_skip":
			if state == "HEXREWARD":
				_do_hexloot_skip()
		"shop":
			_buy_shop(seat, int(arg))
		"restart":
			if state == "GAMEOVER":
				_new_run()

# ---------------------------------------------------------------- The ring
## A proposal lights a pip beside every seat and fires only when they are all lit. Proposing IS your
## aye — the same grammar as "everyone ends their own turn" in combat, applied to the map.
func _ring_intent(seat: int, kind: String, arg: String) -> void:
	if busy:
		return
	if not ring.is_empty() and str(ring["kind"]) == kind and str(ring["arg"]) == arg:
		var ayes: Array = ring["ayes"]
		if not ayes.has(seat):
			ayes.append(seat)
	else:
		# A different proposal REPLACES the open one and resets the ayes — you can always change
		# the plan, you just cannot bank the agreement someone gave to a different plan.
		_pid += 1
		ring = {"pid": _pid, "kind": kind, "arg": arg, "by": seat,
			"required": _present_seats(), "ayes": [seat]}
		_msg("%s proposes: %s" % [_seat_name(seat), _ring_label(kind, arg)])
	_try_close_ring()

func _ring_closed() -> bool:
	if ring.is_empty():
		return false
	var ayes: Array = ring["ayes"]
	for s: Variant in (ring["required"] as Array):
		if not ayes.has(int(s)):
			return false
	return true

func _try_close_ring() -> void:
	if not _ring_closed():
		_push()
		return
	var k: String = str(ring["kind"])
	var a: String = str(ring["arg"])
	var by: int = int(ring["by"])
	ring = {}
	_push()
	await _resolve_ring(k, a, by)

func _resolve_ring(kind: String, arg: String, by: int) -> void:
	match kind:
		"embark":
			if state != "CONTRACTS" or busy:
				return
			var i: int = int(arg)
			if i < 0 or i >= contracts.size():
				return
			selected_contract = i
			await _embark()
		"hex":
			if state != "HEX" or busy or not hexes.has(arg):
				return
			await _enter_hex(arg)
		"extract":
			if state != "HEX" or busy:
				return
			await _finish_expedition("extract", run_epoch)
		"event":
			if state != "HEXEVENT":
				return
			await _do_event_choice(arg == "risky")
		"endmonth":
			if busy:
				return
			await _end_month()
		"shop":
			_buy_shop(by, int(arg))
			_push()

func _ring_label(kind: String, arg: String) -> String:
	match kind:
		"embark":
			var i: int = int(arg)
			return "take %s" % str(contracts[i]["title"]) if i >= 0 and i < contracts.size() else "take the job"
		"hex":
			var h: Dictionary = hexes.get(arg, {})
			var k: String = str(h.get("kind", "?"))
			var icon: String = {"combat": "⚔", "reward": "💰", "event": "❓", "objective": "🏁"}.get(k, "·")
			return "push into %s  (☠ %d)" % [icon, int(h.get("danger", 1))]
		"extract":
			return "extract with %dg" % exp_loot_gold
		"event":
			return "force the door" if arg == "risky" else "play it safe"
		"endmonth":
			return "end the month (rent %dg)" % fee
		"shop":
			var i2: int = int(arg)
			if i2 >= 0 and i2 < shop_stock.size():
				return "spend %dg under the rent line" % int(shop_stock[i2]["cost"])
			return "spend under the rent line"
	return kind

func _on_agree() -> void:
	if ring.is_empty():
		return
	_intent(str(ring["kind"]), str(ring["arg"]))

# ---------------------------------------------------------------- Presence (the AFK escape hatch)
func _present_seats() -> Array:
	var out: Array = []
	for i in range(seats.size()):
		if bool(seats[i].get("present", true)):
			out.append(i)
	return out

func _seat_name(seat: int) -> String:
	if seat >= 0 and seat < roster.size():
		return str(roster[seat]["name"])
	if seat >= 0 and seat < seats.size():
		return str(seats[seat].get("name", "seat %d" % seat))
	return "seat %d" % seat

func _mark_seen(seat: int) -> void:
	if mode != Mode.AUTHORITY or seat < 0 or seat >= _last_seen.size():
		return
	_last_seen[seat] = Time.get_ticks_msec()
	if seat < seats.size() and not bool(seats[seat].get("present", true)):
		seats[seat]["present"] = true
		_msg("%s is back at the table." % _seat_name(seat))

## A friend who wanders off must not freeze the company. Go quiet and your seat stops blocking the
## ring; say anything and you are back in it. A seat is only ever REMOVED from an open ring, never
## added to one — so someone returning can never re-block a vote that was about to pass.
func _sweep_absent() -> void:
	if mode != Mode.AUTHORITY:
		return
	var now: int = Time.get_ticks_msec()
	var changed := false
	for i in range(seats.size()):
		if i == my_seat or i >= _last_seen.size():
			continue
		var gone: bool = (now - int(_last_seen[i])) > int(ABSENT_SEC * 1000.0)
		if gone == (not bool(seats[i].get("present", true))):
			continue
		seats[i]["present"] = not gone
		changed = true
		if gone:
			_msg("%s has gone quiet — the crew won't wait." % _seat_name(i))
			if not ring.is_empty():
				(ring["required"] as Array).erase(i)
	if not changed:
		return
	_try_close_ring() if not ring.is_empty() else _push()

# ---------------------------------------------------------------- The crew bar
func _refresh_ring() -> void:
	if mode == Mode.SOLO or not is_instance_valid(crew_bar):
		return
	crew_bar.visible = _fight_node == null
	for c in crew_bar.get_children():
		c.queue_free()
	_rect(Vector2.ZERO, Vector2(720, 74), Color(0.10, 0.10, 0.14, 0.94), crew_bar)
	_rect(Vector2.ZERO, Vector2(720, 2), Color(1, 1, 1, 0.07), crew_bar)
	var open: bool = not ring.is_empty()
	var head := "the crew — the company only commits when everyone agrees"
	if open:
		head = "%s proposes: %s   (%d/%d)" % [_seat_name(int(ring["by"])), _ring_label(str(ring["kind"]), str(ring["arg"])),
			(ring["ayes"] as Array).size(), (ring["required"] as Array).size()]
	_mklabel(head, Vector2(12, 5), Vector2(560, 18), 13, crew_bar, false, C_AMBER if open else Color(0.6, 0.6, 0.66))
	for i in range(seats.size()):
		var d: Dictionary = roster[i] if i < roster.size() else {}
		var cls: String = str(d.get("cls", seats[i].get("cls", "warrior")))
		var emo: String = str(Db.CLASSES.get(cls, {}).get("emoji", "?"))
		var present: bool = bool(seats[i].get("present", true))
		var ayed: bool = open and (ring["ayes"] as Array).has(i)
		var mark := "•"
		if not present:
			mark = "💤"
		elif open:
			mark = "✅" if ayed else "⏳"
		var col := Color(0.88, 0.88, 0.92)
		if not present:
			col = Color(0.45, 0.45, 0.5)
		elif ayed:
			col = C_GREEN
		var tag: String = "  (you)" if i == my_seat else ""
		_mklabel("%s %s %s%s" % [emo, str(d.get("name", _seat_name(i))), mark, tag],
			Vector2(12 + i * 138, 28), Vector2(136, 22), 13, crew_bar, false, col)
	if not open:
		return
	if (ring["ayes"] as Array).has(my_seat):
		_mklabel("waiting…", Vector2(578, 30), Vector2(130, 20), 14, crew_bar, true, Color(0.85, 0.8, 0.5))
		return
	var b := Button.new()
	b.text = "✅ Agree"
	b.add_theme_font_size_override("font_size", 16)
	b.position = Vector2(582, 8)
	b.size = Vector2(126, 58)
	b.pressed.connect(_on_agree)
	crew_bar.add_child(b)

# ---------------------------------------------------------------- Client rendering
## A client never runs the campaign — it draws whatever the last snapshot said, using the SAME
## _build_X() functions the host uses. That is the whole reason those functions read from state.
func _render() -> void:
	if mode != Mode.CLIENT:
		return
	_clear_screen()
	overlay.visible = false
	match state:
		"DASHBOARD":
			_build_dashboard()
		"CONTRACTS":
			_build_contracts()
		"HEX":
			_build_hexcrawl()
		"HEXREWARD":
			_build_hex_reward()
		"HEXEVENT":
			_build_hex_event()
		"RESOLVE":
			_mkemoji(Vector2(360, 580), Vector2(140, 140), 80, screen_root).text = "🎲"
			_mklabel("The dice are rolling…", Vector2(0, 680), Vector2(720, 30), 20, screen_root, true, Color(0.85, 0.85, 0.9))
		"OUTCOME":
			var k: String = str(outcome.get("kind", ""))
			var c: Dictionary = outcome.get("contract", {})
			var r: Dictionary = outcome.get("result", {})
			if c.is_empty() or r.is_empty():
				_mklabel("…", Vector2(0, 600), Vector2(720, 40), 24, screen_root)
			elif k == "objective" or k == "extract" or k == "wipe":
				_build_expedition_outcome(c, r, k)
			else:
				_build_outcome(c, r)
			if is_instance_valid(continue_btn):
				continue_btn.disabled = busy
		"GAMEOVER":
			_game_over_ui(over_kind)
		_:
			_mklabel("Joining the company…", Vector2(0, 600), Vector2(720, 40), 22, screen_root)
	_refresh_hud()

# ---------------------------------------------------------------- The nested fight
## ONE place a fight starts. The host rolls the encounter, publishes it in the snapshot, and every
## peer instantiates the SAME combat scene as a child with its own net block. Clients never roll:
## an identical board on every screen is the entire point of the exercise.
func _run_fight(req: Dictionary, e: int) -> Dictionary:
	if mode == Mode.AUTHORITY:
		_fid += 1
		req["fid"] = _fid
		fight_req = req
		_push()          # this is how the clients learn to join
	var result: Dictionary = await _enter_fight(req)
	if mode == Mode.AUTHORITY:
		fight_req = {}   # and this is how they learn to leave
	if e != run_epoch:
		return {}
	return result

func _enter_fight(req: Dictionary) -> Dictionary:
	_cur_fid = int(req.get("fid", 0))
	var f: Node = COMBAT_SCENE.instantiate()
	var r: Dictionary = req.duplicate(true)
	r["nested"] = true   # combat must hand control BACK to us, not change_scene to the lobby
	if mode != Mode.SOLO:
		r["net"] = {
			"mode": "authority" if mode == Mode.AUTHORITY else "client",
			"seat": my_seat,
			"seat_count": seat_count,
		}
	f.request = r        # BEFORE add_child: combat._ready() parses it on entry
	_fight_node = f
	screen_root.visible = false
	hud.visible = false
	if is_instance_valid(crew_bar):
		crew_bar.visible = false
	add_child(f)
	var result: Dictionary = await f.combat_finished
	_exit_fight()
	return result

func _exit_fight() -> void:
	if is_instance_valid(_fight_node):
		_fight_node.queue_free()
	_fight_node = null
	screen_root.visible = true
	hud.visible = true
	if is_instance_valid(crew_bar):
		crew_bar.visible = mode != Mode.SOLO

func _client_join_fight() -> void:
	await _enter_fight(fight_req.duplicate(true))
	# The host's snapshot carries the authoritative aftermath (HP, the fallen, the wagon). We only
	# had to render the fight; we do not get a vote on how it came out.
	_render()

## The encounters were tuned by Monte Carlo for a crew of THREE. Co-op fields 2-4, so the party term
## composes ADDITIVELY with the others (scaling audit 2026-07-01: multiplying them grew quadratically
## and produced 0%-win cells).
func _party_scale() -> float:
	if mode == Mode.SOLO:
		return 0.0
	return float(roster.size() - 3) * PARTY_STEP

# ---------------------------------------------------------------- Death without lockout
## A dwarf that goes down is hauled onto the WAGON — it keeps rolling its death saves there — and the
## player takes an HEIR at the same seat on the very next tile. Nobody watches the rest of an
## expedition. If the original stabilises it takes its seat back at the end, deck and all; the heir
## was only ever a stand-in. If it bleeds out, the heir keeps the seat and the DECK is what you lost.
func _reseat_fallen() -> void:
	if mode == Mode.SOLO:
		return
	var reseated := false
	for i in range(roster.size()):
		var d: Dictionary = roster[i]
		if not bool(d.get("downed", false)) and str(d["status"]) != "lost":
			continue
		d["seat"] = i
		carried.append(d)
		roster[i] = _make_heir(i)
		reseated = true
		_msg("%s is dragged onto the wagon — %s takes up their axe." % [d["name"], roster[i]["name"]])
	if reseated:
		exp_crew = roster

func _make_heir(i: int) -> Dictionary:
	var cls: String = str(seats[i].get("cls", "warrior")) if i < seats.size() else "warrior"
	var d: Dictionary = _make_dwarf(RECRUIT_NAMES[randi() % RECRUIT_NAMES.size()], cls)
	d["seat"] = i
	d["hp"] = maxi(1, int(round(float(d["max_hp"]) * HEIR_HP_FRAC)))   # a cost, not a free respawn
	return d

func _finish_saves(d: Dictionary) -> void:
	while str(d["status"]) != "lost" and bool(d["downed"]) and not bool(d["stable"]) \
			and int(d["ds_success"]) < DS_SUCCESS_NEEDED and int(d["ds_fail"]) < DS_FAIL_NEEDED:
		if randf() < DS_SUCCESS_CHANCE:
			d["ds_success"] = int(d["ds_success"]) + 1
			if int(d["ds_success"]) >= DS_SUCCESS_NEEDED:
				d["stable"] = true
		else:
			d["ds_fail"] = int(d["ds_fail"]) + 1
			if int(d["ds_fail"]) >= DS_FAIL_NEEDED:
				d["status"] = "lost"
				d["downed"] = false

func _clear_ds(d: Dictionary) -> void:
	d["downed"] = false
	d["stable"] = false
	d["ds_success"] = 0
	d["ds_fail"] = 0

## The expedition is over: the wagon comes home. Whoever survived their saves takes their seat back
## from the stand-in. Whoever did not is gone — but their SEAT is never left with a corpse in it,
## because a player staring at a corpse for the rest of the campaign is not playing the game.
func _wagon_home(kind: String) -> void:
	for d: Dictionary in carried:
		if kind == "wipe":
			_finish_saves(d)   # a wipe gives the dying no more time
		var si: int = int(d.get("seat", -1))
		if str(d["status"]) == "lost":
			_msg("%s never came home. Their deck dies with them." % d["name"])
			continue
		if si < 0 or si >= roster.size():
			continue
		_clear_ds(d)
		d["hp"] = maxi(1, int(round(float(d["max_hp"]) * STABLE_HP_FRAC)))
		roster[si] = d   # back on their feet, deck intact — the heir steps aside
		_msg("%s is patched up and back in the line." % d["name"])
	carried = []
	# A wipe never reseats (there was nobody left standing to do the dragging), so settle those seats
	# here too: dead seats get an heir, downed-but-alive seats get up.
	for i in range(roster.size()):
		var d2: Dictionary = roster[i]
		if str(d2["status"]) == "lost":
			roster[i] = _make_heir(i)
		elif bool(d2["downed"]) or bool(d2["stable"]):
			_clear_ds(d2)
			d2["hp"] = maxi(1, int(round(float(d2["max_hp"]) * STABLE_HP_FRAC)))
	exp_crew = roster

# ---------------------------------------------------------------- Personal claims (host-side)
## Loot is PERSONAL: one card leaves the tile and it joins the claimer's own deck. First tap wins —
## which is a conversation, not a mechanic, and that is the point.
func _claim_loot(seat: int, i: int) -> void:
	if state != "HEXREWARD" or i < 0 or i >= hex_loot.size():
		return
	if seat < 0 or seat >= roster.size():
		return
	var cid: String = hex_loot[i]
	var d: Dictionary = roster[seat]
	(d["deck"] as Array).append(cid)
	_msg("%s claimed %s." % [d["name"], str(Db.CARDS[cid]["name"])])
	hex_loot = []
	hex_loot_pick = -1
	await _resume_hex(run_epoch)

## You buy for your OWN dwarf, out of the SHARED purse. Above the rent line that is nobody's business
## but yours; below it, _is_ring() has already made the table agree before we ever get here.
func _buy_shop(seat: int, i: int) -> void:
	if i < 0 or i >= shop_stock.size() or seat < 0 or seat >= roster.size():
		return
	var s: Dictionary = shop_stock[i]
	if bool(s.get("sold", false)) or treasury < int(s["cost"]):
		return
	var d: Dictionary = roster[seat]
	match str(s["kind"]):
		"card":
			(d["deck"] as Array).append(s["cid"])
			_msg("%s bought %s." % [d["name"], str(Db.CARDS[s["cid"]]["name"])])
		"heal":
			d["hp"] = int(d["max_hp"])
			_msg("%s is patched up to full." % d["name"])
		_:
			return
	treasury -= int(s["cost"])
	_tween_treasury_to(treasury)
	s["sold"] = true
	if state == "CONTRACTS":
		_clear_screen()
		_build_contracts()
	_refresh_hud()

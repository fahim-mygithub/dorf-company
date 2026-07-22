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
const WritScene := preload("res://scripts/ui/writ_scene.gd")
const TutorialScript := preload("res://scripts/overworld/tutorial_summoning.gd")

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
## Every class in Db.ROLL_POOL needs an entry, or its dwarves silently get nothing from a reward tile.
## Each pool offers cards that are NOT already in that class's starting deck.
const CLASS_REWARDS := {
	# tank
	"warrior":   ["reckless_swing", "second_wind", "momentum_strike"],
	"barbarian": ["rampage", "second_wind", "guard_break"],
	"fighter":   ["hold_the_line", "bracing_stance", "shield_bash"],
	"paladin":   ["lay_on_hands", "divine_smite", "vow_of_wrath"],
	# support
	"cleric":    ["lay_on_hands", "consecrate", "searing_word"],
	"bard":      ["ballad", "inspiration", "mockery"],
	"druid":     ["barkskin", "regrowth", "entangle"],
	# dps
	"sorcerer":  ["arc_lightning", "empower", "kindle"],
	"rogue":     ["poison_blade", "fan_of_knives", "shadowstep"],
	"monk":      ["quivering_palm", "stunning_strike", "chill_touch"],
}
# Phase 5: contract modifiers — one data tag reshapes BOTH the job offer (payout) and the fight
# (enemy scale), so "which job" carries more variety from the same 3 enemies. Cheapest recomb axis.
## A hazard belongs to a ZONE for the day, not to one job — every contract posted in the Warrens
## carries the Warrens' hazard. That is what makes the zone the first decision on the board: not
## "which job" but "where is it safe to work today". It is stored on each contract under the SAME
## `mod` key the per-contract modifier used, so every downstream reader (payout, enemy scale, the
## Writ) is unchanged.
const ZONE_HAZARDS := [
	{"key": "clear",     "name": "Clear",     "emoji": "🌤️", "scale": 1.00, "pay": 1.00, "tip": "Quiet today. Nothing the crew has not handled before."},
	{"key": "elite",     "name": "Warband",   "emoji": "👑", "scale": 1.50, "pay": 1.30, "tip": "A champion is abroad — much tougher, pays more."},
	{"key": "lucrative", "name": "Rich Seam", "emoji": "💰", "scale": 1.10, "pay": 1.70, "tip": "Word of a rich seam — big payout, only a touch harder."},
	{"key": "grim",      "name": "Grim",      "emoji": "💀", "scale": 1.25, "pay": 1.15, "tip": "Something worse has moved in — harder, a little more coin."},
	{"key": "flooded",   "name": "Flooded",   "emoji": "🌊", "scale": 1.15, "pay": 1.10, "tip": "The low runs are underwater. Slow going, mean fights."},
	{"key": "fogbound",  "name": "Fogbound",  "emoji": "🌫️", "scale": 1.05, "pay": 1.25, "tip": "You cannot see a hand ahead — but neither can they."},
]
const CONTRACTS_POSTED := 6   # spread over 4 zones, so a zone can hold 0-3 and clustering is real
const DWARF_STRENGTH := 3     # flat in MVP (class only drives emoji/color)

const DANGER := {"low": 8, "med": 13, "high": 15}     # crew_strength + 2d6 must reach this
const PAYOUT := {"low": 25, "med": 80, "high": 100}   # low 30->25 (Phase 0): safe grind now insufficient
const DURATION := {"low": 1, "med": 2, "high": 1}
const CREW_SIZE := {"low": 2, "med": 3, "high": 3}    # low was 1 while it was a dice roll; it is a real expedition now
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
## Board size per tier. Low is a SHORT expedition rather than a dice roll: a real map with real
## attrition, but half the tiles, so it stays the cheap job that makes rent without costing the same
## real time as a Deep Delve.
const HEX_DIMS := {"low": Vector2i(6, 4), "med": Vector2i(6, 5), "high": Vector2i(6, 5)}
## You may only walk out at a marked 🏳️ point (or by finishing the job). Fewer of them deeper in the
## danger band is the whole cost of a High contract: the exits thin out as the job gets worse.
const EXTRACT_POINTS := {"low": 2, "med": 2, "high": 1}
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
## One colour per class in Db.ROLL_POOL. Read it through _class_col(), NEVER bare: this was keyed to
## the canonical trio while the roll pool grew to 10, and a bare index on a missing key is a runtime
## error that takes the whole campaign screen down with it.
const CLASS_COL := {
	"warrior": Color(0.62, 0.64, 0.68), "barbarian": Color(0.85, 0.35, 0.25),
	"fighter": Color(0.55, 0.70, 0.85), "paladin": Color(0.98, 0.88, 0.45),
	"cleric": Color(0.95, 0.80, 0.30), "bard": Color(0.90, 0.55, 0.80),
	"druid": Color(0.45, 0.75, 0.42), "sorcerer": Color(0.62, 0.40, 0.85),
	"rogue": Color(0.50, 0.50, 0.58), "monk": Color(0.95, 0.62, 0.30),
}
const CLASS_COL_FALLBACK := Color(0.60, 0.60, 0.65)
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
var hex_sel := ""                   # LOCAL preview target (the tile whose Writ is open) — never networked
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
var writ: Control                # THE SUMMONING and any future cutscene (chrome, topmost, modal)
var _tut_done := false           # per NODE, so a restart never replays it but a fresh campaign does
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
var hud_endmonth: Button            # lives in the HUD, under the pips it spends
var sheet: Control                  # chrome: the open venue sub-menu (see "Venue sub-menus")
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
	Net.resumed_from_sleep.connect(_on_woke_up)
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

	# The venue sub-menu. Chrome for the same reason crew_bar is: _clear_screen must not take it, and
	# a CLIENT's per-snapshot _render must not blink it away while someone is reading it.
	sheet = Control.new()
	sheet.size = Vector2(720, 1280)
	sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheet.visible = false
	add_child(sheet)

	# Added LAST so it is topmost. It is full-screen MOUSE_FILTER_STOP while visible, which is what
	# makes a focus beat safe: the highlighted control shows through the scrim hole but cannot be
	# pressed. Sibling of screen_root, so _clear_screen and a client's _render never touch it.
	writ = WritScene.new()
	writ.visible = false
	writ.finished.connect(_on_writ_finished)
	add_child(writ)

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
		fee_pips.append(_rect(Vector2(500 + j * 26, 82), Vector2(20, 16), C_GREEN, hud))
	_mklabel("jobs left", Vector2(490, 100), Vector2(140, 14), 11, hud, false, Color(0.7, 0.7, 0.75))
	# End Month sits directly under the jobs-left pips because it is the same fact from the other
	# side: the pips say how many jobs are left, this button spends every one of them at once. It is
	# HUD chrome, so it survives _clear_screen and _refresh_hud alone decides where it belongs.
	# Deliberately not a big target — ending early forfeits the rest of the month.
	hud_endmonth = Button.new()
	hud_endmonth.text = "⏭️ End Month"
	hud_endmonth.add_theme_font_size_override("font_size", 15)
	hud_endmonth.position = Vector2(468, 118)
	hud_endmonth.size = Vector2(228, 34)
	hud_endmonth.pressed.connect(_on_rest)
	hud.add_child(hud_endmonth)
	hud_month = _mklabel("", Vector2(240, 120), Vector2(200, 24), 15, hud)

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
	if is_instance_valid(hud_endmonth):
		# Only the town can end a month. Every other screen is inside something you already started.
		hud_endmonth.visible = state == "DASHBOARD"
		hud_endmonth.disabled = busy
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
	_maybe_play_tutorial()

# ============================================================ THE SUMMONING (opening cutscene)
## Plays once when a fresh campaign opens. NOT awaited and NOT networked: the scene is linear, so
## it has no shared state to agree on — every peer runs all 28 beats locally at its own reading
## pace. The dashboard is already built underneath; the writ layer is modal, so nothing can be
## touched until it finishes. Add a choice here and you inherit the ring, the pips and the deadlock
## timer along with it.
func _maybe_play_tutorial() -> void:
	if _tut_done or not is_instance_valid(writ):
		return
	_tut_done = true
	writ.play(TutorialScript.beats(), _writ_ctx())

func _on_writ_finished() -> void:
	_refresh_hud()

## `@us` — resolved PER CLIENT, never sent. Solo has no single avatar (you run all three dorfs),
## so it falls back to the human manager; in co-op it is THIS seat's own dorf, which is why every
## player sees themselves holding the resume.
func _writ_ctx() -> Dictionary:
	var us_name := "You"
	var us_art := "🧍"
	var us_metal := C_COIN
	if mode != Mode.SOLO:
		for d in roster:
			if int(d.get("seat", -1)) == my_seat:
				us_name = str(d.get("name", "You"))
				us_art = str(Db.CLASSES[d["cls"]]["emoji"])
				us_metal = _class_col(str(d["cls"]))
				break
	return {"us_name": us_name, "us_art": us_art, "us_metal": us_metal,
		"cast": TutorialScript.CAST, "focus_rects": _focus_rects()}

## Named rects rather than coordinates in the script, so a layout change moves the spotlight
## instead of breaking it. A name with no entry here degrades to a plain un-highlighted beat,
## which is how a beat pointing at another screen still reads.
func _focus_rects() -> Dictionary:
	var r := {
		"hud_treasury": Rect2(8, 16, 300, 100),      # coin + the big number + the solvency band
		"hud_rent": Rect2(348, 14, 292, 70),         # fee + "next due"
	}
	if state == "DASHBOARD":
		r["roster"] = Rect2(30, 388, 660, 192)       # the dwarf tokens, all four columns
		r["contract_board"] = Rect2(202, 1142, 336, 86)
		r["end_month"] = Rect2(16, 1142, 196, 86)
	return r

## Total by construction: a class added later renders grey instead of crashing the screen.
func _class_col(cls: String) -> Color:
	return CLASS_COL.get(cls, CLASS_COL_FALLBACK)

# One roster dwarf. downed/stable/ds_* are per-EXPEDITION death-save state (reset each expedition start).
func _make_dwarf(dname: String, cls: String) -> Dictionary:
	var mh: int = int(Db.CLASSES[cls]["max_hp"])
	return {"name": dname, "cls": cls, "status": "ready", "recover": 0, "hp": mh, "max_hp": mh,
		"deck": (Db.CLASSES[cls]["deck"] as Array).duplicate(),
		"downed": false, "stable": false, "ds_success": 0, "ds_fail": 0}

## The board is posted BY ZONE. Indices 0/1/2 are still low/med/high in that order — the co-op
## verifier addresses contracts[2] as the heavy job and the snapshot ships the array by index — and
## the rest fill in behind them so a zone can hold anywhere from nothing to three.
func _regen_contracts() -> void:
	# One hazard per zone, rerolled with the board. Shuffled without replacement, so four zones on
	# the same day never all read "Grim" and the map is worth looking at.
	var hz: Array = ZONE_HAZARDS.duplicate()
	hz.shuffle()
	var zone_mod: Array = []
	for i in range(LOCATIONS.size()):
		zone_mod.append(hz[i % hz.size()])

	var bag := ["low", "med", "high"]
	bag.shuffle()
	contracts = []
	for t in ["low", "med", "high"]:
		contracts.append(_make_contract(t, randi() % LOCATIONS.size()))
	for i in range(CONTRACTS_POSTED - 3):
		contracts.append(_make_contract(str(bag[i % bag.size()]), randi() % LOCATIONS.size()))
	for c in contracts:
		c["mod"] = zone_mod[int(c["zone"])]
		# EVERY contract is an expedition now — the low-tier dice roll is gone, so there is no job
		# that cannot cost you a dwarf. It still needs a crew that can actually be fielded; a company
		# worn down below that falls back to the dice path rather than being locked off the board.
		c["fight"] = USE_REAL_COMBAT and _ready_count() >= int(c["crew_size"])

func _make_contract(tier: String, zone: int) -> Dictionary:
	var titles: Array = TITLES[tier]
	var loc: Dictionary = LOCATIONS[zone]
	# Co-op fields EVERY seat on every job — nobody sits an expedition out, including a Low one now
	# that it is a real map.
	var cs: int = int(CREW_SIZE[tier])
	if mode != Mode.SOLO:
		cs = roster.size()
	return {
		"tier": tier,
		"zone": zone,
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
	sheet_key = ""
	shop_sel = -1
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
	sheet_key = ""
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
## DASHBOARD is now THE TOWN. The state id is deliberately unchanged: it is on the wire in every
## snapshot and asserted by campaign_verify, and renaming it would be a protocol change to buy
## nothing. `_build_dwarf_token` below is kept — it already renders the field-standard roster
## grammar and is the basis for the Ledger.
func _build_dashboard() -> void:
	_build_town()

func _build_dwarf_token(d: Dictionary, cx: int, cy: int) -> void:
	var status: String = d["status"]
	var col: Color = _class_col(str(d["cls"]))
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
## The Guild Hall keeps its contract cards — a contract is a document you read, not an object you
## bump into — but the room is drawn behind them so the hall is a place you walked into.
## THE BOARD IS A MAP. Work is posted by ZONE, so the first decision is not "which of these three
## jobs" but "where is it safe to work today" — a pin per zone, coloured by the worst tier posted
## there, counting what is on offer and naming the hazard that covers all of it. Tapping a pin opens
## that zone's ledger. The hall stays visible the whole time.
## Card centres. The top row clears the vellum's own title strip (y248..274) — the cards are 92 tall
## and hang from centre-46, so anything above y322 runs over the heading.
const ZONE_PIN := [Vector2(238, 332), Vector2(474, 324), Vector2(252, 452), Vector2(486, 460)]

func _zone_contracts(z: int) -> Array:
	var out: Array = []
	for i in range(contracts.size()):
		if int((contracts[i] as Dictionary).get("zone", 0)) == z:
			out.append(i)
	return out

## Every contract in a zone carries the same hazard, so the zone's hazard IS any of theirs. Deriving
## it keeps it off the wire — a zone with no work has no hazard to state.
func _zone_hazard(z: int) -> Dictionary:
	for i in _zone_contracts(z):
		return (contracts[i] as Dictionary).get("mod", {})
	return {}

## The worst tier posted in a zone. That is what the pin's colour means, because the thing you need
## to know at a glance is whether this zone can kill you, not what the average job pays.
func _zone_tier(z: int) -> String:
	var worst := ""
	for i in _zone_contracts(z):
		var t := str(contracts[i]["tier"])
		if t == "high" or (t == "med" and worst != "high") or worst == "":
			worst = t
	return worst

func _build_contracts() -> void:
	# The room prints its own title from the spec. Printing a second one here stacked two headers on
	# the same two lines — so this one is the FALLBACK's header, and only the fallback gets it.
	if not _build_room("guild"):
		_build_venue_header("— THE GUILD HALL —", "Pick one job. Weigh payout against danger and time.")
		var xs := [12, 252, 492]
		for i in range(mini(contracts.size(), 3)):
			_build_contract_card(i, xs[i])
		_build_back_to_town()
		return
	_build_zone_map()
	_build_back_to_town()

func _build_zone_map() -> void:
	# The cork behind the board runs x158..562 / y240..516; the vellum sits inside it.
	_rect(Vector2(166, 248), Vector2(388, 260), Color(0.80, 0.73, 0.58), screen_root)
	_rect(Vector2(166, 248), Vector2(388, 6), Color(0.66, 0.59, 0.45), screen_root)
	_mklabel("THE COMPANY'S REACH", Vector2(166, 256), Vector2(388, 18), 12, screen_root, true,
		Color(0.42, 0.35, 0.24))
	# routes between the zones, so the map reads as places connected rather than four floating dots
	for pair in [[0, 1], [0, 2], [1, 3], [2, 3], [0, 3]]:
		var a: Vector2 = ZONE_PIN[pair[0]]
		var b: Vector2 = ZONE_PIN[pair[1]]
		var mid: Vector2 = (a + b) * 0.5
		var d: Vector2 = (b - a)
		var seg := ColorRect.new()
		seg.color = Color(0.55, 0.47, 0.34, 0.55)
		seg.size = Vector2(d.length(), 2)
		seg.position = mid - Vector2(d.length(), 2) * 0.5
		seg.rotation = d.angle()
		seg.pivot_offset = Vector2(d.length(), 2) * 0.5
		seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		screen_root.add_child(seg)
	for z in range(LOCATIONS.size()):
		_build_zone_pin(z)

func _build_zone_pin(z: int) -> void:
	var idxs: Array = _zone_contracts(z)
	var tier: String = _zone_tier(z)
	var hz: Dictionary = _zone_hazard(z)
	var c: Vector2 = ZONE_PIN[z]
	var pin := Control.new()
	pin.position = c - Vector2(66, 46)
	pin.size = Vector2(132, 96)
	pin.mouse_filter = Control.MOUSE_FILTER_STOP
	pin.gui_input.connect(_on_zone_input.bind(z))
	screen_root.add_child(pin)
	var col: Color = DANGER_BANNER.get(tier, Color(0.52, 0.48, 0.42))
	# A pinned card on the vellum. It carries the same brass edge every tappable thing in a room
	# does — a zone pin is a control, so it obeys the same rule the props and the dwarves do.
	_rect(Vector2(3, 4), Vector2(132, 92), Color(0, 0, 0, 0.42), pin)
	_rect(Vector2.ZERO, Vector2(132, 92), Color(0.88, 0.83, 0.70), pin)
	_rect(Vector2.ZERO, Vector2(132, 5), col, pin)
	_mkemoji(Vector2(26, 30), Vector2(44, 40), 24, pin).text = str(LOCATIONS[z]["emoji"])
	# the count disc, struck in the zone's WORST tier — what you need at a glance is whether this
	# zone can kill you, not what the average job there pays
	_rect(Vector2(84, 12), Vector2(34, 34), Color(0, 0, 0, 0.35), pin)
	_rect(Vector2(82, 10), Vector2(34, 34), col, pin)
	_mklabel(str(idxs.size()) if not idxs.is_empty() else "—", Vector2(82, 16), Vector2(34, 24), 17,
		pin, true, Color(0.08, 0.07, 0.06))
	_mklabel(str(LOCATIONS[z]["name"]), Vector2(2, 52), Vector2(128, 20), 14, pin, true,
		Color(0.20, 0.15, 0.09) if not idxs.is_empty() else Color(0.50, 0.44, 0.35))
	if idxs.is_empty():
		_mklabel("no work posted", Vector2(2, 72), Vector2(128, 16), 11, pin, true, Color(0.52, 0.46, 0.36))
	else:
		_mklabel("%s %s" % [str(hz.get("emoji", "")), str(hz.get("name", ""))], Vector2(2, 72),
			Vector2(128, 16), 11, pin, true, Color(0.46, 0.29, 0.10))
	_brass_edge(pin, Vector2(132, 92))

func _on_zone_input(event: InputEvent, z: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not busy:
			_open_sheet("zone", z)

## The room chassis paints this edge round every tappable prop. A contract slip is a Control rather
## than a spec prop, so it paints its own — same grammar, same metal, so "brass edge means you can
## touch it" holds on both sides of the seam.
func _brass_edge(parent: Control, sz: Vector2) -> void:
	var b := Color(0.72, 0.55, 0.24)
	_rect(Vector2.ZERO, Vector2(sz.x, 2), b, parent)
	_rect(Vector2(0, sz.y - 2), Vector2(sz.x, 2), b, parent)
	_rect(Vector2.ZERO, Vector2(2, sz.y), b, parent)
	_rect(Vector2(sz.x - 2, 0), Vector2(2, sz.y), b, parent)
	var hi := Color(0.91, 0.78, 0.53)
	for c in [Vector2.ZERO, Vector2(sz.x - 16, 0), Vector2(0, sz.y - 3), Vector2(sz.x - 16, sz.y - 3)]:
		_rect(c, Vector2(16, 3), hi, parent)

## SOLO takes the job; co-op puts it to the table. The wire protocol is untouched — the first press
## is still the free `select` that lights the job for everyone, the second is still the `embark`
## ring that needs every present seat to agree.
func _on_contract_take(i: int) -> void:
	if busy or state != "CONTRACTS" or i < 0 or i >= contracts.size():
		return
	var c: Dictionary = contracts[i]
	if _ready_count() < int(c["crew_size"]):
		_msg("Not enough ready dwarves — need %d." % int(c["crew_size"]))
		return
	if mode != Mode.SOLO:
		if selected_contract != i:
			_intent("select", str(i))
			_msg("%s is on the table — press again to call the vote." % str(c["title"]))
			return
		_intent("embark", str(i))
		_close_sheet()
		return
	selected_contract = i
	_close_sheet()
	_embark()

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
	var col: Color = _class_col(str(d["cls"]))
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
		# Read the ARCHETYPE, not the class id — a Bard and a Druid heal too, and this gauge claims
		# "all three roles" while testing two ids.
		var role: String = str(Db.CLASSES[d["cls"]]["role"])
		if role == "support": has_cleric = true
		if role == "dps": has_sorc = true
		tothp += int(d["hp"])
	if crew_pick.size() == int(c["crew_size"]):
		var warns: Array = []
		if not has_cleric: warns.append("⚠ no support — nobody to heal or shield")
		if not has_sorc: warns.append("⚠ no damage dealer — the fight will grind")
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
	var col: Color = _class_col(str(d["cls"]))
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
	_tween_treasury_from(_tre_shown, target)

## Count the purse from one value to another. The host calls this as it mutates; a CLIENT calls it
## from _apply_snap with the previous snapshot's value, because treasury is STATE — the delta
## between two snapshots is the whole animation, so unlike a flag march it needs no event.
var _tre_tween: Tween = null
func _tween_treasury_from(from_v: int, target: int) -> void:
	_tre_shown = target
	# One counter at a time. The host's own call sites are spaced out by awaits, but a client calls
	# this from _apply_snap on every snapshot carrying a delta — and snapshots are not rate-limited,
	# so two buys inside 0.5s would leave two tweens fighting over the same label.
	if _tre_tween != null and _tre_tween.is_valid():
		_tre_tween.kill()
	_tre_tween = create_tween()
	_tre_tween.tween_method(Callable(self, "_apply_treasury_label"), float(from_v), float(target), 0.5)

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
	hex_sel = ""
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
	var dim: Vector2i = HEX_DIMS.get(str(_c.get("tier", "med")), Vector2i(HEX_COLS, HEX_ROWS))
	hexes = {}
	for rr in range(dim.y):
		for cc in range(dim.x):
			var wall: bool = cc == 0 or cc == dim.x - 1 or rr == 0 or rr == dim.y - 1
			hexes[_hex_key(cc, rr)] = {"q": cc, "r": rr, "kind": ("wall" if wall else "empty"),
				"danger": 0, "resolved": wall, "objective": false, "dist": 0, "extract": false}
	var entry: String = _hex_key(1, dim.y - 2)   # bottom-left interior corner
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

	# EXTRACT POINTS. You can no longer walk out from wherever you happen to be standing — leaving
	# is a PLACE, which is what turns the board from "push until it feels dicey" into a route you
	# commit to. They are marked from the start, like the objective, because the whole point of a
	# visible board is that you can plan the way out before you take the first step.
	var passable: Array = []
	for k in hexes:
		var hh: Dictionary = hexes[k]
		if hh["kind"] == "wall" or k == entry or bool(hh["objective"]):
			continue
		passable.append(k)
	passable.sort_custom(func(a, b): return int(hexes[a]["dist"]) < int(hexes[b]["dist"]))
	var want: int = int(EXTRACT_POINTS.get(str(_c.get("tier", "med")), 1))
	var picks: Array = []
	if passable.size() > 0:
		# One shallow bail-out, one deep. With a single point (High) you get only the deep one, so a
		# heavy contract means committing most of the way across before there is any way home.
		if want >= 2:
			picks.append(passable[clampi(int(float(passable.size()) * 0.3), 0, passable.size() - 1)])
		var deep: String = passable[clampi(int(float(passable.size()) * 0.72), 0, passable.size() - 1)]
		if not picks.has(deep):
			picks.append(deep)
	for k in picks:
		hexes[k]["kind"] = "extract"
		hexes[k]["extract"] = true
		hexes[k]["resolved"] = true

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
## Board size varies by tier now, so it is DERIVED from the hexes themselves rather than read off a
## constant. That keeps it off the wire: a client centres the board correctly from the snapshot it
## already receives, with no new field to forget to send.
func _hex_dims() -> Vector2i:
	var mc := 0
	var mr := 0
	for k in hexes:
		mc = maxi(mc, int(hexes[k]["q"]))
		mr = maxi(mr, int(hexes[k]["r"]))
	return Vector2i(mc + 1, mr + 1)

func _hex_px(cc: int, rr: int) -> Vector2:
	var dim := _hex_dims()
	var w := HEX_R * sqrt(3.0)                                   # pointy-top hex width
	var x0 := 360.0 - w * (float(dim.x) + 0.5) * 0.5 + w * 0.5   # center the board (odd rows shove right)
	# A short board is centred vertically in the same felt, so a Low map does not sit high and lonely.
	var y0 := 300.0 + (5.0 - float(dim.y)) * HEX_R * 0.75
	return Vector2(x0 + w * (float(cc) + 0.5 * float(rr & 1)), y0 + HEX_R * 1.5 * float(rr))

func _build_hexcrawl() -> void:
	# A preview that is no longer a reachable neighbour (we moved, or state changed) is stale — drop it.
	if hex_sel != "" and not (hexes.has(hex_sel) and _hex_neighbors(hex_cur).has(hex_sel)):
		hex_sel = ""
	_mklabel("— EXPEDITION —", Vector2(0, 168), Vector2(720, 26), 20, screen_root)
	var c := exp_contract
	var modtxt: String = ("  ·  %s %s" % [c["mod"]["emoji"], c["mod"]["name"]]) if c.has("mod") else ""
	_mklabel("%s  ·  %s%s" % [c["title"], c["loc_name"], modtxt], Vector2(0, 196), Vector2(720, 20), 14, screen_root, true, Color(0.8, 0.8, 0.85))
	_mklabel("Route to 🏁 the captive. Icons hint the tile; ☠ = how tough. Detour for loot if you dare.", Vector2(0, 220), Vector2(720, 18), 12, screen_root, true, Color(0.7, 0.7, 0.75))
	# Diorama backdrop: a felt playmat set into a walnut table — the board is a physical thing.
	_rect(Vector2(40, 240), Vector2(640, 440), Color(0.17, 0.11, 0.06), screen_root)   # walnut table frame
	_rect(Vector2(44, 244), Vector2(632, 432), Color(0.10, 0.07, 0.04), screen_root)   # inner shadow lip
	_rect(Vector2(52, 250), Vector2(616, 420), Color(0.09, 0.20, 0.15), screen_root)   # green felt playmat
	# brass edging on the wood frame
	_rect(Vector2(48, 246), Vector2(624, 2), Color(0.82, 0.66, 0.36, 0.60), screen_root)
	_rect(Vector2(48, 672), Vector2(624, 2), Color(0.82, 0.66, 0.36, 0.45), screen_root)
	_rect(Vector2(48, 246), Vector2(2, 428), Color(0.82, 0.66, 0.36, 0.45), screen_root)
	_rect(Vector2(670, 246), Vector2(2, 428), Color(0.82, 0.66, 0.36, 0.45), screen_root)
	for k in hexes:
		_build_hex_tile(k)
	_build_party_tokens()
	_build_exp_crew_strip()
	_build_writ()
	_mklabel("loot bag  +%dg  ·  🏁 the rescue pays the real money" % exp_loot_gold, Vector2(24, 1112), Vector2(430, 18), 12, screen_root, false, Color(0.85, 0.8, 0.55))
	# You leave from a PLACE, not from a button that is always there. Standing on a 🏳️ point offers
	# the way out; anywhere else the board tells you where the exits are and how many are left.
	if bool((hexes.get(hex_cur, {}) as Dictionary).get("extract", false)):
		var ex := Button.new()
		ex.text = "🏳️ Extract (+%dg)" % exp_loot_gold
		ex.add_theme_font_size_override("font_size", 18)
		ex.position = Vector2(430, 1146)
		ex.size = Vector2(266, 70)
		ex.disabled = busy
		ex.pressed.connect(_on_extract)
		screen_root.add_child(ex)
	else:
		var left := 0
		for k in hexes:
			if bool((hexes[k] as Dictionary).get("extract", false)):
				left += 1
		# _mklabel clips rather than reflows, so this one is explicitly told to wrap — it is the only
		# place the new rule is explained, and a half-sentence would be worse than no sentence.
		var hint := _mklabel("No way out here — make for a 🏳️ (%d on this map), or finish the job."
			% left, Vector2(396, 1140), Vector2(300, 76), 13, screen_root, true, Color(0.78, 0.74, 0.62))
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

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
	elif kind == "extract":
		tile.fill = Color(0.16, 0.34, 0.36)   # a cold way-out colour, distinct from the gold goal
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
	elif kind == "extract":
		tile.ring = Color(0.45, 0.86, 0.88, 0.85)
	elif can_move:
		tile.ring = Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.80)
	if key == hex_sel:
		tile.ring = Color(1, 1, 1, 0.95)                    # the tile you're reading the Writ for
	screen_root.add_child(tile)
	var glyph := ""
	if wall:
		glyph = "🏔️"
	elif cur:
		glyph = "🚩"
	elif kind == "objective":
		glyph = "🏁"
	elif kind == "extract":
		glyph = "🏳️"           # checked BEFORE `resolved`: an exit stays an exit after you pass it
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

## Diorama: the crew stand on their tile as coin-metal tokens (steel / gold / arcane), with a
## translucent ghost token on the tile whose Writ is open — the proposed next step made physical.
func _build_party_tokens() -> void:
	if not hexes.has(hex_cur):
		return
	var cur_px := _hex_px(int(hexes[hex_cur]["q"]), int(hexes[hex_cur]["r"]))
	# Lay the cluster out FROM the crew size — co-op seats up to 4, and a hardcoded 3-slot ring put
	# the fourth dwarf exactly on top of the first.
	var n: int = exp_crew.size()
	var r: float = 12.0 if n <= 3 else 9.0
	var spread: float = 17.0 if n <= 3 else 24.0
	for i in range(n):
		var t: float = 0.0 if n <= 1 else (float(i) / float(n - 1)) * 2.0 - 1.0   # -1 .. 1 across the tile
		_coin_token(cur_px + Vector2(t * spread, 14.0 - absf(t) * 4.0), _class_col(str(exp_crew[i]["cls"])), r, false)
	if hex_sel != "" and hexes.has(hex_sel):
		_coin_token(_hex_px(int(hexes[hex_sel]["q"]), int(hexes[hex_sel]["r"])), Color(0.92, 0.90, 0.96), 10.0, true)

func _coin_token(center: Vector2, col: Color, r: float, ghost: bool) -> void:
	var p := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col.r, col.g, col.b, 0.45) if ghost else col
	sb.set_corner_radius_all(int(r))
	sb.set_border_width_all(2)
	sb.border_color = Color(1, 1, 1, 0.55) if ghost else Color(0, 0, 0, 0.55)
	if not ghost:
		sb.shadow_color = Color(0, 0, 0, 0.5)
		sb.shadow_size = 3
		sb.shadow_offset = Vector2(0, 2)
	p.add_theme_stylebox_override("panel", sb)
	p.position = center - Vector2(r, r)
	p.size = Vector2(r * 2.0, r * 2.0)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen_root.add_child(p)

func _build_exp_crew_strip() -> void:
	# No "crew" caption: the coin cards sit directly under the board and are opaque, so a label in the
	# gap is drawn over anyway. Spacing scales with n — co-op seats up to 4, and a fixed 240 pitch
	# threw the outer cards off a 720-wide screen.
	var n := exp_crew.size()
	var gap: float = minf(240.0, 690.0 / float(maxi(n, 1)))
	var startx: float = 360.0 - (float(n) - 1.0) * gap * 0.5
	for i in range(n):
		_build_exp_crew_token(exp_crew[i], int(roundf(startx + float(i) * gap)), 758)

func _build_exp_crew_token(d: Dictionary, cx: int, cy: int) -> void:
	var col: Color = _class_col(str(d["cls"]))
	# Diorama: each dwarf is a coin-metal card struck in their class metal (same language as power_orb.gd).
	var card := Panel.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color = Color(0.13, 0.11, 0.09, 0.96)
	cs.set_corner_radius_all(10)
	cs.set_border_width_all(2)
	cs.border_color = Color(col.r, col.g, col.b, 0.90)
	cs.shadow_color = Color(0, 0, 0, 0.45)
	cs.shadow_size = 4
	cs.shadow_offset = Vector2(0, 3)
	card.add_theme_stylebox_override("panel", cs)
	card.position = Vector2(cx - 66, cy - 66)
	card.size = Vector2(132, 168)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen_root.add_child(card)
	_rect(Vector2(cx - 56, cy - 58), Vector2(112, 3), Color(col.r, col.g, col.b, 0.55), screen_root)   # rim accent
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

# ---------------------------------------------------------- The Writ (consequence readout)
## What a tile costs and pays, in plain words, BEFORE you commit — the gap every hex-crawl fills and
## Dorf did not. Reads from state (hex_sel, or the open hex ring), so a client draws the same panel.
func _hex_stakes(h: Dictionary) -> Dictionary:
	var kind: String = str(h.get("kind", ""))
	var dgr: int = int(h.get("danger", 0))
	var out: Dictionary = {"kind": kind, "danger": dgr, "title": "", "lines": []}
	# A cleared tile has nothing left to pay or cost — _enter_hex gates EVERY payload on `resolved`,
	# and the tile itself already shows ✔️ with no ☠. Backtracking must not re-advertise the fight.
	if bool(h.get("resolved", false)) and kind != "objective":
		out["title"] = "Ground you already hold"
		out["lines"] = [["", "cleared — the step costs only time"]]
		return out
	match kind:
		"combat":
			out["title"] = "Contested ground"
			out["lines"] = [["danger", ("☠".repeat(dgr)) if dgr > 0 else "—"],
				["win", "the crew patches +%d HP" % HEX_POST_FIGHT_HEAL],
				["lose", "a dwarf hauled to the wagon"]]
		"reward":
			out["title"] = "A cache"
			out["lines"] = [["take", "coin for the bag, or a card to learn"]]
		"event":
			out["title"] = "A sealed door"
			out["lines"] = [["choice", "force it for coin (risk), or play it safe"]]
		"objective":
			out["title"] = "The captive"
			out["lines"] = [["rescue", "the real payout — and the run ends here"]]
		_:
			out["title"] = "A quiet passage"
			out["lines"] = [["", "nothing waiting"]]
	return out

## 8-wind bearing from one tile to another, off pixel positions (avoids offset-coord headaches).
func _hex_bearing(from_key: String, to_key: String) -> String:
	if not hexes.has(from_key) or not hexes.has(to_key):
		return ""
	var a := _hex_px(int(hexes[from_key]["q"]), int(hexes[from_key]["r"]))
	var b := _hex_px(int(hexes[to_key]["q"]), int(hexes[to_key]["r"]))
	var d := b - a
	if d.length() < 0.5:
		return ""
	var idx: int = int(round(rad_to_deg(atan2(-d.y, d.x)) / 45.0)) % 8   # screen-y is down; flip for north
	if idx < 0:
		idx += 8
	return ["E", "NE", "N", "NW", "W", "SW", "S", "SE"][idx]

func _build_writ() -> void:
	# YOUR pick outranks the open plan. Proposing a different tile REPLACES that proposal and resets
	# its ayes (see _ring_intent) — that is the only way the crew can change its mind, and it also
	# stops the board (white ring + ghost token, both keyed off hex_sel) contradicting this button.
	var wkey := ""
	if hex_sel != "" and hexes.has(hex_sel) and _hex_neighbors(hex_cur).has(hex_sel):
		wkey = hex_sel
	elif not ring.is_empty() and str(ring.get("kind", "")) == "hex" and hexes.has(str(ring.get("arg", ""))):
		wkey = str(ring["arg"])
	if wkey == "":
		return
	var h: Dictionary = hexes[wkey]
	var st: Dictionary = _hex_stakes(h)
	var bearing: String = _hex_bearing(hex_cur, wkey)
	# Layout budget: the co-op crew_bar is fixed chrome at y1006..1080, so the Writ must land above it
	# — same geometry in SOLO (where the bar is hidden) so the screen never shifts between modes.
	var px := 40.0
	var py := 872.0
	var pw := 640.0
	var ph := 128.0
	# An aged-paper contract laid on the table, sealed in wax.
	_rect(Vector2(px + 5, py + 7), Vector2(pw, ph), Color(0, 0, 0, 0.38), screen_root)        # drop shadow
	_rect(Vector2(px, py), Vector2(pw, ph), Color(0.88, 0.83, 0.68), screen_root)             # parchment
	_rect(Vector2(px, py), Vector2(pw, 3), Color(0.74, 0.66, 0.48), screen_root)              # worn top edge
	_rect(Vector2(px, py + ph - 3), Vector2(pw, 3), Color(0.74, 0.66, 0.48), screen_root)     # worn bottom edge
	_rect(Vector2(px + 14, py - 10), Vector2(104, 22), Color(0.49, 0.16, 0.13), screen_root)  # wax tab
	_mklabel("THE WRIT", Vector2(px + 14, py - 9), Vector2(104, 20), 11, screen_root, true, Color(0.96, 0.90, 0.78))
	var head: String = str(st["title"])
	if bearing != "":
		head += "   ·   1 hex %s" % bearing
	_mklabel(head, Vector2(px + 18, py + 18), Vector2(pw - 36, 26), 20, screen_root, false, Color(0.20, 0.14, 0.07))
	var ly := py + 48
	for pair: Array in (st["lines"] as Array):
		var lab: String = str(pair[0])
		var val: String = str(pair[1])
		var ink := Color(0.34, 0.26, 0.14)
		if lab == "danger":
			# ☠ is a COLR/CPAL emoji and the fonts import with modulate_color_glyphs=false, so
			# font_color CANNOT tint it — it always paints its own pale palette, which is ~1:1 against
			# parchment. Back the row with a dark chip so the skulls actually read.
			_rect(Vector2(px + 14, ly - 3), Vector2(168, 22), Color(0.16, 0.13, 0.09, 0.92), screen_root)
			ink = Color(0.93, 0.90, 0.82)
		_mklabel(("%s:  %s" % [lab, val]) if lab != "" else val, Vector2(px + 18, ly), Vector2(356, 18), 13, screen_root, false, ink)
		ly += 22
	# Commit lives on the Writ, not the tile: a mis-tap on the board only ever changes what you read.
	var on_this: bool = not ring.is_empty() and str(ring.get("kind", "")) == "hex" and str(ring.get("arg", "")) == wkey
	var ayed: bool = on_this and (ring["ayes"] as Array).has(my_seat)
	var bx := px + pw - 262
	# Vote pips: one coin per required seat, struck in that seat's metal, lit when they have ayed.
	if mode != Mode.SOLO and on_this:
		var req: Array = ring["required"]
		var ayes: Array = ring["ayes"]
		var sx := bx + (246.0 - float(req.size()) * 20.0) * 0.5
		for i in range(req.size()):
			var seat: int = int(req[i])
			var scol: Color = _class_col(str(roster[seat].get("cls", "warrior"))) if seat < roster.size() else Color(0.60, 0.60, 0.65)
			var lit: bool = ayes.has(seat)
			_coin_token(Vector2(sx + float(i) * 20.0 + 10.0, py + 56), scol if lit else Color(scol.r * 0.40, scol.g * 0.40, scol.b * 0.45), 7.0, not lit)
	if mode != Mode.SOLO and ayed:
		_mklabel("proposed — waiting for the crew", Vector2(bx, py + ph - 46), Vector2(246, 20), 13, screen_root, true, Color(0.42, 0.30, 0.14))
		return
	var b := Button.new()
	var ring_hex: String = str(ring.get("arg", "")) if (not ring.is_empty() and str(ring.get("kind", "")) == "hex") else ""
	if mode == Mode.SOLO:
		b.text = "MARCH ->"
	else:
		b.text = "COUNTER-PROPOSE" if (ring_hex != "" and ring_hex != wkey) else "PROPOSE THE MARCH"
	b.add_theme_font_size_override("font_size", 18)
	b.position = Vector2(bx, py + ph - 58)
	b.size = Vector2(246, 48)
	b.disabled = busy
	b.add_theme_stylebox_override("normal", _wax_style(Color(0.49, 0.16, 0.13)))
	b.add_theme_stylebox_override("hover", _wax_style(Color(0.61, 0.23, 0.18)))
	b.add_theme_stylebox_override("pressed", _wax_style(Color(0.37, 0.11, 0.09)))
	b.add_theme_stylebox_override("disabled", _wax_style(Color(0.32, 0.26, 0.22)))
	b.add_theme_color_override("font_color", Color(0.96, 0.90, 0.78))
	b.add_theme_color_override("font_hover_color", Color(1.0, 0.97, 0.90))
	b.pressed.connect(_commit_hex.bind(wkey))
	screen_root.add_child(b)

## Wax-seal button face (fresh box per state — duplicating a StyleBox loses its static type).
func _wax_style(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(5)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.30, 0.09, 0.07)
	return sb

# ---------------------------------------------------------- Hex movement + resolution
## Tap a reachable tile to PREVIEW it (open its Writ). Committing is the Writ's button, so a mis-tap
## on the board only ever changes what you're reading — it never marches.
func _on_hex_input(event: InputEvent, key: String) -> void:
	if busy or state != "HEX":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if hexes[key]["kind"] != "wall" and _hex_neighbors(hex_cur).has(key):
			hex_sel = key
			_clear_screen()
			_build_hexcrawl()
			_refresh_hud()

## Fire the previewed move: SOLO steps in; co-op puts it to the crew as a ring proposal.
func _commit_hex(key: String) -> void:
	if busy or state != "HEX":
		return
	if not hexes.has(key) or str(hexes[key]["kind"]) == "wall" or not _hex_neighbors(hex_cur).has(key):
		return
	if mode != Mode.SOLO:
		_intent("hex", key)   # pushing deeper risks everyone — the whole crew has to agree
		if state == "HEX" and not busy:
			_clear_screen()
			_build_hexcrawl()
			_refresh_hud()
		return
	hex_sel = ""
	await _enter_hex(key)

## The 🚩 marching between two tiles. PURE cosmetic: it moves a throwaway token and never touches
## hex_cur, which is exactly what lets a client replay it against a board it has already rendered.
## Awaitable — the host waits for the march before resolving the tile; a client just lets it play.
const MARCH_SEC := 0.28
func _fx_march(from_key: String, to_key: String) -> void:
	_fx_mark("march")
	if not hexes.has(from_key) or not hexes.has(to_key) or not is_instance_valid(screen_root):
		return
	var from := _hex_px(int(hexes[from_key]["q"]), int(hexes[from_key]["r"]))
	var to := _hex_px(int(hexes[to_key]["q"]), int(hexes[to_key]["r"]))
	if is_instance_valid(hex_flag):
		hex_flag.visible = false
	var tok := _mkemoji(from, Vector2(60, 60), 26, screen_root)
	tok.text = "🚩"
	# bind_node: a client rebuilds its entire screen on the next snapshot, which frees this token
	# mid-march. Binding kills the tween along with it instead of leaving it writing to a dead node.
	var tw := create_tween().bind_node(tok)
	tw.tween_property(tok, "position", to - tok.size * 0.5, MARCH_SEC).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	# Wait on a TIMER, never on tw.finished: bind_node means a freed token kills the tween, and a
	# killed tween never emits finished — the host would hang here with busy stuck true and the
	# whole company frozen. The timer fires whatever happens to the token.
	await get_tree().create_timer(MARCH_SEC).timeout
	if is_instance_valid(tok):
		tok.queue_free()

func _enter_hex(key: String) -> void:
	busy = true
	var e := run_epoch
	# The flag marches to the new hex before it resolves, so movement reads spatially.
	# Ship the beat BEFORE we block on it: this tile may be a fight, and a fight takes the screen
	# away from the board — a march replayed after that lands on a client that has already left.
	# Emitting up front also means every peer marches at the same moment instead of trailing us.
	_fx_push("march", {"a": hex_cur, "b": key})
	_push()
	await _fx_march(hex_cur, key)
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
	var col: Color = _class_col(str(d["cls"]))
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
	# The button is only built on an extract tile, but the intent path is reachable from a client, so
	# the rule lives HERE where the host enforces it — not in the layout that happened to hide it.
	if not bool((hexes.get(hex_cur, {}) as Dictionary).get("extract", false)):
		_msg("You cannot walk out from here — make for a 🏳️ extract point.")
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
		var rc: String = Db.ROLL_POOL[randi() % Db.ROLL_POOL.size()]   # recruits draw from the full roster
		shop_stock.append({"kind": "recruit", "name": rn, "cls": rc, "cost": SHOP_RECRUIT_COST})
	else:
		# Co-op has no Recruit: seats are fixed and the wagon rule already refills a dead dwarf.
		shop_stock.append({"kind": "card", "cid": pool[1], "cost": SHOP_CARD_COST})

func _build_shop_panel() -> void:
	# Recruit has its own venue, so the shelf carries goods only — one door per purchase. Co-op never
	# stocks a recruit at all (seats are fixed), so the filter is a no-op there.
	var idx: Array = []
	for i in range(shop_stock.size()):
		if str(shop_stock[i].get("kind", "")) == "recruit":
			continue
		idx.append(i)
	if idx.is_empty():
		_mklabel("The shelf is bare until the month turns.", Vector2(0, 400), Vector2(720, 24), 16,
			screen_root, true, Color(0.66, 0.62, 0.55))
		return
	var n: int = idx.size()
	var startx: int = 360 - n * 100
	for j in range(n):
		_build_shop_slot(int(idx[j]), startx + j * 200, 300)
	if mode != Mode.SOLO:
		_mklabel("you buy for YOUR OWN dwarf · a buy that dips under the rent needs the whole crew",
			Vector2(0, 436), Vector2(720, 18), 13, screen_root, true, Color(0.7, 0.7, 0.76))
		return
	if shop_sel >= 0 and shop_stock[shop_sel]["kind"] != "recruit":
		_mklabel("Tap the dwarf who gets it.", Vector2(0, 436), Vector2(720, 24), 16, screen_root,
			true, C_AMBER)
		_build_shop_targets()

func _build_shop_slot(i: int, x: int, y: int = 896) -> void:
	var s: Dictionary = shop_stock[i]
	var cost := int(s["cost"])
	var sold := bool(s.get("sold", false))
	var afford := treasury >= cost and not sold
	var slot := Control.new()
	slot.position = Vector2(x, y)
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
	if busy or (state != "MARKET" and state != "TAVERN"):
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
		_rebuild_current()

func _buy_recruit(i: int) -> void:
	var s: Dictionary = shop_stock[i]
	treasury -= int(s["cost"])
	_tween_treasury_to(treasury)
	roster.append(_make_dwarf(s["name"], s["cls"]))
	s["sold"] = true
	shop_sel = -1
	_msg("%s joins the company." % s["name"])
	_rebuild_current()
	_refresh_hud()

func _build_shop_targets() -> void:
	var s: Dictionary = shop_stock[shop_sel]
	_mklabel("give to:", Vector2(0, 1016), Vector2(720, 16), 12, screen_root, true, Color(0.85, 0.85, 0.9))
	var elig: Array = []
	for d in roster:
		if _eligible_target(d, s):
			elig.append(d)
	if elig.is_empty():
		_mklabel("(no valid dwarf)", Vector2(0, 470), Vector2(720, 18), 13, screen_root, true, C_AMBER)
		return
	var n := elig.size()
	var startx := 360 - (n - 1) * 48
	for i in range(n):
		_build_shop_target_token(elig[i], startx + i * 96, 512)

func _build_shop_target_token(d: Dictionary, cx: int, cy: int) -> void:
	var col: Color = _class_col(str(d["cls"]))
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
	if busy or (state != "MARKET" and state != "TAVERN") or shop_sel < 0:
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
		_rebuild_current()
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

# ---------------------------------------------------------------- The FX rider (M3b)
## Same contract as combat's rider (see scripts/combat/combat.gd): cosmetics are ADVISORY, ride the
## snapshot as a TOP-LEVEL array, are DRAINED on every build so they ship exactly once, and never
## mutate state. A lost fx is a missed animation, never a desync.
##
## The drain matters more here than in combat: _push() fires on every incidental HUD refresh
## (_refresh_hud) and on every client's 3s camp_hello. Without the drain, one flag march would
## replay on every heartbeat, forever.
##
## Not everything visual belongs here. An fx is for a TRANSIENT the snapshot cannot carry — the
## flag march happens BETWEEN two boards, so no board describes it. The treasury count-up, by
## contrast, is pure state: the delta between two snapshots IS the animation (see
## _tween_treasury_from). If a client can derive it, derive it — don't spend an event on it.
const FX_MAX := 32
const FX_TAIL := 16
var _fx: Array = []        # AUTHORITY: the pending wire bundle, drained by _build_snap
var _fx_seen: Array = []   # EVERY peer: a TAIL of what played here (capped) — for eyeballing kinds
var _fx_played := 0        # EVERY peer: how many played, monotonic — the assertable count

## Record one event. No-op unless authoritative: SOLO needs no wire, and a CLIENT replaying through
## the players below must never re-record what it was just told.
func _fx_push(kind: String, d: Dictionary) -> void:
	if mode != Mode.AUTHORITY or _fx.size() >= FX_MAX:
		return
	_fx.append({"k": kind, "d": d})

## What played on THIS peer. Assert on _fx_played: _fx_seen is a capped ring, so once it is full
## its size stops growing and "did one more play?" cannot be read from it.
func _fx_mark(kind: String) -> void:
	_fx_played += 1
	_fx_seen.append(kind)
	if _fx_seen.size() > FX_TAIL:
		_fx_seen.remove_at(0)

## CLIENT: play one event the host recorded. Unknown kinds are ignored on purpose — an older client
## meeting a newer host should miss an animation, not break.
func _replay_fx(f: Variant) -> void:
	if typeof(f) != TYPE_DICTIONARY:
		return
	var ev: Dictionary = f
	var d: Dictionary = ev.get("d", {}) if typeof(ev.get("d")) == TYPE_DICTIONARY else {}
	match str(ev.get("k", "")):
		"march":
			_fx_march(str(d.get("a", "")), str(d.get("b", "")))

func _strip_crew(c: Dictionary) -> Dictionary:
	var d: Dictionary = c.duplicate()
	d.erase("crew")   # aliases roster dicts — they ride the snapshot once, under "roster"
	return d

func _build_snap() -> Dictionary:
	var cs: Array = []
	for c: Dictionary in contracts:
		cs.append(_strip_crew(c))
	# DRAIN, not read: fx are events, so they ship exactly once. Reassigning (rather than clearing)
	# means the dict we hand back can never alias the live buffer.
	# ⚠ This function MUST keep exactly ONE caller (_push). A second caller would silently eat a
	# bundle — the beat would simply never animate anywhere. campaign_verify asserts the drain.
	var fx: Array = _fx
	_fx = []
	return {
		"fx": fx,   # top level ONLY — an event welded to a roster dict would replay forever
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
	var had_board: bool = _last_seq > 0   # the first snapshot FILLS the board; it changes nothing
	_last_seq = seq
	var tre_prev: int = _tre_shown
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
	var prev_cur := hex_cur
	hex_cur = str(s.get("hex_cur", ""))
	if hex_cur != prev_cur:
		hex_sel = ""   # the board moved under us (or a new expedition started) — a stale preview isn't mine to keep
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
	# Everything below is COSMETIC and must come after _render(): it clears screen_root (so a token
	# spawned earlier would be freed on the spot) and ends in _refresh_hud(), which snaps the purse
	# label — this has to be the last writer to animate it.
	if had_board and tre_prev != treasury:
		_tween_treasury_from(tre_prev, treasury)
	for f: Variant in (s.get("fx", []) as Array):
		_replay_fx(f)
	# A CLIENT never runs _new_run, so this is its equivalent trigger: the first snapshot is the one
	# that fills the board, and month 0 tells a fresh campaign apart from a rejoin mid-run. It has to
	# be here rather than earlier because @us reads the roster this snapshot just delivered — before
	# this line the client does not yet know which dorf is its own.
	if not had_board and month == 0 and months_survived == 0 and state == "DASHBOARD":
		_maybe_play_tutorial()

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

## The browser froze this tab and just let it run again. While frozen we were not voting, not
## acting and — if we are the HOST — not resolving anything for anybody. Say so plainly: from the
## outside this is indistinguishable from the game being broken.
func _on_woke_up(asleep_ms: int) -> void:
	var secs: int = int(asleep_ms / 1000.0)
	if mode == Mode.AUTHORITY:
		_msg("⚠ You host — this tab was asleep %ds and the whole company stopped. Keep it in front." % secs)
	else:
		_msg("⚠ This tab was asleep %ds — browsers freeze background tabs. Keep it in front." % secs)
		_send_hello()   # tell the host we are back; it answers with the whole board
	_refresh_hud()

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
			_enter_venue(arg)
		"select":
			if busy or state != "CONTRACTS":
				return
			var i: int = int(arg)
			if i < 0 or i >= contracts.size():
				return
			selected_contract = i
			var c: Dictionary = contracts[i]
			_msg("%s eyes %s — press again to call the vote." % [_seat_name(seat), c["title"]])
			# _rebuild_current, not _build_contracts: the open zone ledger has to redraw too, or the
			# row that just went on the table still says "Put on the table".
			_rebuild_current()
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
		"TAVERN":
			_build_tavern()
		"MARKET":
			_build_market()
		"RECRUIT":
			_build_recruit()
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

# ============================================================ Rooms
## A venue is a full-bleed diegetic ROOM, not a list: the crew and the townsfolk mill about inside
## it and a price hangs on the object that sells it. Every room — and the town map itself — is the
## SAME chassis (`room_view.gd`) fed a different pure-data spec, so adding a venue is a JSON file
## rather than a screen. If a spec is missing or malformed the venue falls back to its list screen,
## which is why a bad room can never blank a door the player needs.
const RoomView := preload("res://scripts/ui/room_view.gd")
const ROOM_DIR := "res://resources/rooms/"
var _room_cache: Dictionary = {}
var room_view: Control = null

func _room_spec(key: String) -> Dictionary:
	if _room_cache.has(key):
		return _room_cache[key]
	var path := ROOM_DIR + key + ".json"
	if not FileAccess.file_exists(path):
		_room_cache[key] = {}
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_room_cache[key] = {}
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	var out: Dictionary = parsed if parsed is Dictionary else {}
	_room_cache[key] = out
	return out

## The player's own dwarves, in the shape room_view wants. Only these carry a base plate; the
## room's own NPCs come from the spec and carry nothing, because they hold no state.
func _room_dwarves() -> Array:
	var out: Array = []
	for d in roster:
		if str(d.get("status", "")) == "lost":
			continue
		out.append({
			"emoji": str(Db.CLASSES[d["cls"]]["emoji"]), "name": str(d["name"]),
			"hp": int(d["hp"]), "max_hp": int(d["max_hp"]),
			"status": str(d["status"]), "recover": int(d.get("recover", 0)),
		})
	return out

## Live numbers are injected into the spec's props at build time, never authored into the JSON —
## a price baked into a room file would go stale the moment the shelf sold out.
func _room_props_priced(sp: Dictionary) -> Array:
	var out: Array = []
	for p in sp.get("props", []):
		var q: Dictionary = (p as Dictionary).duplicate(true)
		var act := str(q.get("act", "none"))
		if act.begins_with("shop:"):
			var kind := act.substr(5)
			var i := _shop_slot_of(kind)
			if i < 0:
				q["price"] = "—"
				q["sub"] = "nothing in today"
			elif bool(shop_stock[i].get("sold", false)):
				q["price"] = "SOLD"
			else:
				q["price"] = "%dg" % int(shop_stock[i]["cost"])
		elif act == "hire":
			var r := _shop_slot_of("recruit")
			if r < 0 or mode != Mode.SOLO:
				q["price"] = "—"
				q["sub"] = "seats are fixed" if mode != Mode.SOLO else "nobody today"
			elif bool(shop_stock[r].get("sold", false)):
				q["price"] = "HIRED"
			else:
				q["price"] = "%dg" % int(shop_stock[r]["cost"])
				q["sub"] = "%s · %s" % [str(shop_stock[r]["name"]), str(Db.CLASSES[shop_stock[r]["cls"]]["name"])]
		elif act == "contracts":
			q["price"] = "%d posted" % contracts.size()
		elif act.begins_with("goto:"):
			# A door on the town map advertises what is WAITING behind it. Without this the four
			# buildings carry static flavour and the whole "where do I need to go" layer — which the
			# list town had — is lost the moment the room replaces it.
			var vk := act.substr(5)
			if vk == "guild":
				vk = "contracts"
			var st: Array = _venue_status(vk)
			if str(st[0]) != "":
				q["price"] = str(st[0])
				q["price_c"] = str(st[2])
		out.append(q)
	return out

## Can this good do anything for this dwarf? One predicate, so the room's tap-a-dwarf targeting and
## the list screen's target strip can never disagree about who is a valid recipient.
func _eligible_target(d: Dictionary, s: Dictionary) -> bool:
	if str(d.get("status", "")) == "lost":
		return false
	if str(s.get("kind", "")) == "heal":
		return str(d["status"]) == "wounded" or int(d["hp"]) < int(d["max_hp"])
	return true

func _shop_slot_of(kind: String) -> int:
	for i in range(shop_stock.size()):
		if str(shop_stock[i].get("kind", "")) == kind:
			return i
	return -1

## Returns false when there is no usable spec, so the caller can fall back to its list screen.
func _build_room(key: String) -> bool:
	var sp: Dictionary = _room_spec(key)
	if sp.is_empty() or not sp.has("furniture"):
		return false
	var live: Dictionary = sp.duplicate(true)
	live["props"] = _room_props_priced(sp)
	var rv: Control = RoomView.new()
	rv.position = Vector2.ZERO
	rv.size = Vector2(720, 1280)
	screen_root.add_child(rv)
	room_view = rv
	rv.configure(live, _room_dwarves())
	rv.prop_tapped.connect(_on_prop_tapped)
	rv.dwarf_tapped.connect(_on_room_dwarf_tapped)
	_mklabel(str(sp.get("title", "")), Vector2(0, 170), Vector2(720, 30), 22, screen_root)
	_mklabel(str(sp.get("sub", "")), Vector2(0, 204), Vector2(720, 20), 14, screen_root, true,
		Color(0.78, 0.74, 0.66))
	# A good you have paid attention to but not yet given away is the one piece of MODE the room has,
	# so it has to say so — otherwise the next tap on a dwarf spends gold without warning.
	if shop_sel >= 0 and shop_sel < shop_stock.size():
		_rect(Vector2(120, 1036), Vector2(480, 40), Color(0, 0, 0, 0.62), screen_root)
		_mklabel("Tap the dwarf who gets it.", Vector2(120, 1044), Vector2(480, 26), 17, screen_root,
			true, C_AMBER)
	return true

## Tapping a thing in a room either MOVES you (a door) or OPENS that thing's sub-menu. Nothing here
## commits gold: a sheet is where you read the price, and the sheet's own button is where you agree
## to it. A prop with no action still answers, with its own flavour — a tag that looks tappable and
## says nothing when tapped reads as broken, which is what an unhandled `none` used to do.
func _on_prop_tapped(id: String, act: String) -> void:
	if busy:
		return
	if act.begins_with("goto:"):
		_on_venue(act.substr(5))
		return
	match act:
		"contracts":
			_on_venue("contracts")
		"hire":
			_open_sheet("hire")
		"roster":
			_open_sheet("crew")
		"shop:heal":
			# In the Tavern the apothecary is the ONLY shelf, so it opens as itself; anywhere else the
			# same goods belong on one shelf rather than in two half-menus.
			_open_sheet("apothecary" if state == "TAVERN" else "shelf")
		"shop:card":
			_open_sheet("shelf")
		_:
			_msg(_prop_flavour(id))

func _prop_flavour(id: String) -> String:
	for p in _room_spec(_room_key_for_state()).get("props", []):
		if str((p as Dictionary).get("id", "")) == id:
			return "%s — %s" % [str(p.get("label", "")), str(p.get("sub", ""))]
	return ""

func _on_room_dwarf_tapped(idx: int) -> void:
	if busy or idx < 0 or idx >= roster.size():
		return
	# A dwarf tapped while a good is armed IS the purchase target — the two-tap grammar the shop
	# already used, moved into the room.
	if shop_sel >= 0 and shop_sel < shop_stock.size():
		# The list shop only ever OFFERED eligible targets, so it could not sell you a bandage for a
		# dwarf who has nothing to mend. A room offers every dwarf standing in it, so the filter has
		# to move here or the same 25g quietly buys nothing.
		if not _eligible_target(roster[idx], shop_stock[shop_sel]):
			_msg("%s has nothing to mend." % str(roster[idx]["name"]))
			return
		_buy_shop(idx, shop_sel)
		shop_sel = -1
		_rebuild_current()
		return
	# Walking up to a dwarf and looking at their kit — this is the deck view, and it is the reason
	# there is no "roster screen" button anywhere. A one-line status message used to be all you got.
	_open_sheet("dwarf", idx)

# ============================================================ Venue sub-menus (sheets)
## A SHEET is a building's sub-menu: a modal panel over the room, carrying the numbers the room
## deliberately does not. The room says WHERE you are and WHO is in it; the sheet says how much, how
## hurt, how long. That split is what lets a room drop its data panel without losing the data — the
## exact readouts the venue screens used to print underfoot now live one tap away, on the object
## that owns them.
##
## Sheet state is LOCAL and never networked (the `hex_sel` precedent): opening a menu is not a
## decision, so it rides no wire event and opens no ring. Anything inside it that IS a decision — a
## buy, a hire — goes out through the existing intents unchanged.
var sheet_key := ""
var sheet_arg := -1        # which dwarf / which contract the open sheet is about

const SHEET_X := 56.0
const SHEET_W := 608.0

func _open_sheet(kind: String, arg: int = -1) -> void:
	if busy:
		return
	sheet_key = kind
	sheet_arg = arg
	_refresh_sheet()

func _close_sheet() -> void:
	sheet_key = ""
	sheet_arg = -1
	_refresh_sheet()

func _refresh_sheet() -> void:
	if not is_instance_valid(sheet):
		return
	for c in sheet.get_children():
		c.queue_free()
	sheet.visible = sheet_key != ""
	match sheet_key:
		"crew":
			_sheet_crew()
		"shelf":
			_sheet_goods(["card", "heal"], "— THE SHELF —", "Every buy trades against the rent clock.")
		"apothecary":
			_sheet_goods(["heal"], "— THE APOTHECARY —", "Wounds clear over months. Coin clears one now.")
		"hire":
			_sheet_hire()
		"dwarf":
			_sheet_dwarf()
		"zone":
			_sheet_zone()

## The scrim is FULL-SCREEN and MOUSE_FILTER_STOP. That is the only thing that stops the room's props
## and wandering dwarves staying live underneath a panel that merely covers them.
func _sheet_frame(title: String, sub: String, h: float) -> Control:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.74)
	scrim.size = Vector2(720, 1280)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	sheet.add_child(scrim)
	var y: float = clampf(600.0 - h * 0.5, 186.0, 320.0)
	var panel := Control.new()
	panel.position = Vector2(SHEET_X, y)
	panel.size = Vector2(SHEET_W, h)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	sheet.add_child(panel)
	_rect(Vector2(5, 7), Vector2(SHEET_W, h), Color(0, 0, 0, 0.55), panel)
	_rect(Vector2.ZERO, Vector2(SHEET_W, h), Color(0.13, 0.11, 0.08), panel)
	_rect(Vector2.ZERO, Vector2(SHEET_W, 52), Color(0.29, 0.21, 0.11), panel)
	_rect(Vector2(0, 52), Vector2(SHEET_W, 2), Color(0.72, 0.55, 0.24), panel)
	_mklabel(title, Vector2(0, 13), Vector2(SHEET_W, 28), 20, panel, true, Color(0.96, 0.91, 0.78))
	_mklabel(sub, Vector2(16, 62), Vector2(SHEET_W - 32, 20), 14, panel, true, Color(0.72, 0.68, 0.58))
	var close := Button.new()
	close.text = "Close"
	close.add_theme_font_size_override("font_size", 17)
	close.position = Vector2(SHEET_X + SHEET_W * 0.5 - 90.0, minf(y + h + 18.0, 1196.0))
	close.size = Vector2(180, 56)
	close.pressed.connect(_close_sheet)
	sheet.add_child(close)
	return panel

func _sheet_crew() -> void:
	var n: int = maxi(1, roster.size())
	var rh: float = clampf(520.0 / float(n), 62.0, 104.0)
	var h: float = 92.0 + rh * float(roster.size()) + 12.0
	var panel := _sheet_frame("— THE COMPANY —",
		"%d on the books · tap one to read their deck" % roster.size(), h)
	var y := 90.0
	for i in range(roster.size()):
		_crew_row(roster[i], panel, 12.0, y, SHEET_W - 24.0, rh - 8.0)
		# The whole row is the target — the ledger lists them, so the ledger is also how you open one.
		var hit := Control.new()
		hit.position = Vector2(12, y)
		hit.size = Vector2(SHEET_W - 24.0, rh - 8.0)
		hit.mouse_filter = Control.MOUSE_FILTER_STOP
		hit.gui_input.connect(_on_crew_row_input.bind(i))
		panel.add_child(hit)
		y += rh

func _on_crew_row_input(event: InputEvent, i: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_open_sheet("dwarf", i)

## One dwarf, the field-standard way: the bar sits UNDER the name, never over the head, and the
## condition owns the right third. Parented and sized by the caller, so the tavern's fallback floor
## and the crew sheet are literally the same row rather than two drifting copies.
func _crew_row(d: Dictionary, parent: Node, x: float, y: float, w: float, h: float) -> void:
	var status := str(d["status"])
	var col: Color = _class_col(str(d["cls"]))
	_rect(Vector2(x, y), Vector2(w, h), Color(col.r, col.g, col.b, 0.16), parent)
	var half: float = h * 0.5
	var emo := _mkemoji(Vector2(x + 46.0, y + half), Vector2(76, minf(70.0, h - 8.0)),
		int(minf(38.0, half - 6.0)), parent)
	emo.text = Db.CLASSES[d["cls"]]["emoji"]
	if status == "wounded":
		emo.modulate = MOD_WOUNDED
	elif status == "lost":
		emo.modulate = MOD_LOST
	var tx: float = x + 92.0
	var tw: float = maxf(120.0, w - 92.0 - 190.0)
	_mklabel(str(d["name"]), Vector2(tx, y + h * 0.10), Vector2(tw, 26), 19, parent, false,
		Color(0.94, 0.90, 0.80))
	_mklabel("%s · %s" % [str(Db.CLASSES[d["cls"]]["name"]), str(Db.CLASSES[d["cls"]]["role"]).to_upper()],
		Vector2(tx, y + h * 0.40), Vector2(tw, 20), 13, parent, false, Color(0.70, 0.66, 0.58))
	var frac: float = clampf(float(d["hp"]) / maxf(1.0, float(d["max_hp"])), 0.0, 1.0)
	var hpcol: Color = C_GREEN if frac > 0.6 else (C_AMBER if frac > 0.3 else C_RED)
	var by: float = y + h * 0.70
	var barw: float = maxf(80.0, tw - 74.0)
	_rect(Vector2(tx, by), Vector2(barw, 11), Color(0.22, 0.20, 0.18), parent)
	_rect(Vector2(tx, by), Vector2(barw * frac, 11), hpcol, parent)
	_mklabel("%d / %d" % [int(d["hp"]), int(d["max_hp"])], Vector2(tx + barw + 8.0, by - 5.0),
		Vector2(68, 20), 13, parent, false, hpcol)
	var cond := "FIT"
	var ccol := C_GREEN
	if status == "wounded":
		cond = "WOUNDED · %dmo" % int(d["recover"])
		ccol = C_AMBER
	elif status == "lost":
		cond = "LOST"
		ccol = Color(0.55, 0.55, 0.6)
	_rect(Vector2(x + w - 180.0, y + h * 0.30), Vector2(168, 34), Color(0, 0, 0, 0.34), parent)
	_mklabel(cond, Vector2(x + w - 180.0, y + h * 0.30 + 7.0), Vector2(168, 22), 14, parent, true, ccol)

## THE DECK VIEW. Until now there was nowhere in the whole campaign to see what a dwarf actually
## fights with — you bought a card and it vanished into a number. It is reached by walking up to the
## dwarf and tapping them, in whichever room they are standing in, which is why the Tavern (where the
## crew are between jobs) is where you would think to look.
func _sheet_dwarf() -> void:
	if sheet_arg < 0 or sheet_arg >= roster.size():
		_close_sheet()
		return
	var d: Dictionary = roster[sheet_arg]
	# A deck is a MULTISET. Printing "Strike" four times is one fact printed four times, so identical
	# cards collapse to a count — and the order is FIRST SEEN, which puts a card you just bought at
	# the bottom, where you will look for it.
	var order: Array = []
	var count: Dictionary = {}
	for cid in d.get("deck", []):
		var k := str(cid)
		if not count.has(k):
			count[k] = 0
			order.append(k)
		count[k] = int(count[k]) + 1
	var rows: int = int(ceil(float(order.size()) * 0.5))
	var h: float = 100.0 + 96.0 + float(rows) * 56.0 + 14.0
	var panel := _sheet_frame(str(d["name"]), "%s · %s · %d cards in the deck"
		% [str(Db.CLASSES[d["cls"]]["name"]), str(Db.CLASSES[d["cls"]]["role"]).to_upper(),
		(d["deck"] as Array).size()], h)
	_crew_row(d, panel, 12.0, 92.0, SHEET_W - 24.0, 86.0)
	var cw: float = (SHEET_W - 30.0) * 0.5
	for i in range(order.size()):
		var cy: float = 194.0 + floorf(float(i) * 0.5) * 56.0
		_sheet_card_chip(str(order[i]), int(count[order[i]]), panel,
			12.0 + float(i % 2) * (cw + 6.0), cy, cw)

func _sheet_card_chip(cid: String, n: int, panel: Control, x: float, y: float, w: float) -> void:
	var def: Dictionary = Db.CARDS.get(cid, {})
	if def.is_empty():
		return
	var t := str(def.get("type", "skill"))
	var tint: Color = {"attack": Color(0.34, 0.17, 0.15), "skill": Color(0.15, 0.25, 0.32),
		"power": Color(0.26, 0.18, 0.34)}.get(t, Color(0.20, 0.20, 0.24))
	_rect(Vector2(x, y), Vector2(w, 50), tint, panel)
	_rect(Vector2(x, y), Vector2(4, 50), Color(0.72, 0.55, 0.24), panel)
	_mkemoji(Vector2(x + 32, y + 25), Vector2(44, 42), 22, panel).text = str(def.get("emoji", "🃏"))
	_mklabel(str(def.get("name", cid)), Vector2(x + 58, y + 5), Vector2(w - 108, 22), 15, panel, false,
		Color(0.94, 0.90, 0.80))
	_mklabel("%s · %s" % [t, str(def.get("school", "—"))], Vector2(x + 58, y + 28), Vector2(w - 108, 18),
		11, panel, false, Color(0.72, 0.68, 0.58))
	if n > 1:
		_mklabel("x%d" % n, Vector2(x + w - 82, y + 16), Vector2(30, 20), 14, panel, false,
			Color(0.86, 0.82, 0.72))
	# `cost` can legitimately be the STRING "X" (Whirlwind), so it is printed, never compared.
	_rect(Vector2(x + w - 44, y + 10), Vector2(30, 30), Color(0, 0, 0, 0.5), panel)
	_mklabel(str(def.get("cost", 0)), Vector2(x + w - 44, y + 14), Vector2(30, 22), 15, panel, true, C_COIN)

## THE ZONE LEDGER: everything posted in one place, under the one hazard that covers all of it.
func _sheet_zone() -> void:
	if sheet_arg < 0 or sheet_arg >= LOCATIONS.size():
		_close_sheet()
		return
	var z := sheet_arg
	var idxs: Array = _zone_contracts(z)
	var hz: Dictionary = _zone_hazard(z)
	var h: float = 96.0 + 62.0 + maxf(1.0, float(idxs.size())) * 132.0 + 12.0
	var panel := _sheet_frame("%s  %s" % [str(LOCATIONS[z]["emoji"]), str(LOCATIONS[z]["name"]).to_upper()],
		"%d contract%s posted today" % [idxs.size(), "" if idxs.size() == 1 else "s"], h)
	# The hazard is stated ONCE, at the top, because it applies to every job below it — printing it
	# per row would read as four different hazards.
	_rect(Vector2(12, 88), Vector2(SHEET_W - 24, 54), Color(0.24, 0.17, 0.07), panel)
	_rect(Vector2(12, 88), Vector2(4, 54), C_AMBER, panel)
	if hz.is_empty():
		_mklabel("Nobody is hiring here today.", Vector2(24, 104), Vector2(SHEET_W - 48, 24), 15,
			panel, true, Color(0.72, 0.68, 0.58))
		return
	_mklabel("TODAY'S HAZARD — %s %s" % [str(hz.get("emoji", "")), str(hz.get("name", ""))],
		Vector2(24, 94), Vector2(SHEET_W - 48, 22), 14, panel, false, C_AMBER)
	_mklabel(str(hz.get("tip", "")), Vector2(24, 116), Vector2(SHEET_W - 48, 20), 13, panel, false,
		Color(0.78, 0.74, 0.64))
	for j in range(idxs.size()):
		_sheet_contract_row(int(idxs[j]), panel, 152.0 + float(j) * 132.0)

func _sheet_contract_row(i: int, panel: Control, y: float) -> void:
	var c: Dictionary = contracts[i]
	var tier: String = c["tier"]
	var cs: int = int(c["crew_size"])
	var ready: int = _ready_count()
	var takeable: bool = ready >= cs
	var w: float = SHEET_W - 24.0
	_rect(Vector2(12, y), Vector2(w, 120), Color(0.17, 0.15, 0.12), panel)
	_rect(Vector2(12, y), Vector2(6, 120), DANGER_BANNER[tier], panel)
	if i == selected_contract:
		_rect(Vector2(12, y), Vector2(w, 3), C_GREEN, panel)
		_rect(Vector2(12, y + 117), Vector2(w, 3), C_GREEN, panel)
	_mkemoji(Vector2(56, y + 38), Vector2(56, 48), 26, panel).text = str(c["loc_emoji"])
	# "HIGH 💀💀💀" is the widest string this chip ever holds; at 11px it overran into the detail
	# column beside it, so the chip is sized to that worst case rather than to "MED 💀💀".
	_mklabel("%s %s" % [TIER_LABEL[tier], SKULLS[tier]], Vector2(8, y + 74), Vector2(96, 18), 10,
		panel, true, DANGER_BANNER[tier])
	_mklabel(str(c["title"]), Vector2(112, y + 12), Vector2(w - 292, 26), 18, panel, false,
		Color(0.94, 0.90, 0.80))
	var eff_pay: int = int(round(float(int(c["payout"])) * (float(c["mod"]["pay"]) if c.has("mod") else 1.0)))
	var exits: int = int(EXTRACT_POINTS.get(tier, 1))
	_mklabel("%dg  ·  %d crew  ·  %d of 3 campaigns" % [eff_pay, cs, int(c["duration"])],
		Vector2(112, y + 42), Vector2(w - 292, 22), 14, panel, false, C_COIN)
	# The exit count is the honest headline of the new rule, so it is printed on the job itself
	# rather than discovered once you are already inside the map.
	_mklabel("%d 🏳️ way%s out  ·  %s" % [exits, "" if exits == 1 else "s",
		"a real expedition" if c.get("fight", false) else "a dice roll (crew too thin)"],
		Vector2(112, y + 68), Vector2(w - 292, 22), 13, panel, false, Color(0.74, 0.70, 0.60))
	if not takeable:
		_mklabel("need %d ready — you have %d" % [cs, ready], Vector2(112, y + 92), Vector2(w - 292, 20),
			13, panel, false, C_RED)
		return
	var go := Button.new()
	if mode == Mode.SOLO:
		go.text = "Embark"
	else:
		go.text = "Call the vote" if i == selected_contract else "Put on the table"
	go.add_theme_font_size_override("font_size", 16)
	go.position = Vector2(w - 168, y + 36)
	go.size = Vector2(168, 48)
	go.pressed.connect(_on_contract_take.bind(i))
	panel.add_child(go)

func _sheet_goods(kinds: Array, title: String, sub: String) -> void:
	var idx: Array = []
	for i in range(shop_stock.size()):
		if kinds.has(str(shop_stock[i].get("kind", ""))):
			idx.append(i)
	if idx.is_empty():
		var bare := _sheet_frame(title, sub, 200.0)
		_mklabel("Nothing in until the month turns.", Vector2(0, 116), Vector2(SHEET_W, 26), 17,
			bare, true, Color(0.66, 0.62, 0.55))
		return
	var foot: float = 34.0 if mode != Mode.SOLO else 0.0
	var h: float = 92.0 + float(idx.size()) * 120.0 + 12.0 + foot
	var panel := _sheet_frame(title, sub, h)
	for j in range(idx.size()):
		_sheet_good_row(int(idx[j]), panel, 90.0 + float(j) * 120.0)
	if mode != Mode.SOLO:
		_mklabel("you buy for YOUR OWN dwarf · a buy that dips under rent needs the crew",
			Vector2(12, h - 28.0), Vector2(SHEET_W - 24, 18), 12, panel, true, Color(0.7, 0.7, 0.76))

func _sheet_good_row(i: int, panel: Control, y: float) -> void:
	var s: Dictionary = shop_stock[i]
	var cost := int(s["cost"])
	var sold := bool(s.get("sold", false))
	var afford := treasury >= cost and not sold
	var w: float = SHEET_W - 24.0
	_rect(Vector2(12, y), Vector2(w, 110), Color(0.18, 0.16, 0.13), panel)
	_rect(Vector2(12, y), Vector2(4, 110), Color(0.72, 0.55, 0.24) if afford else Color(0.4, 0.36, 0.3), panel)
	var emoji := ""
	var title := ""
	var desc := ""
	match str(s["kind"]):
		"card":
			emoji = str(Db.CARDS[s["cid"]].get("emoji", "🃏"))
			title = "Card — %s" % str(Db.CARDS[s["cid"]]["name"])
			desc = "goes into one dwarf's deck for good"
		"heal":
			emoji = "🩹"
			title = "Field Medic"
			desc = "one dwarf to full HP, and clears a wound"
	_mkemoji(Vector2(66, y + 52), Vector2(80, 64), 36, panel).text = emoji
	_mklabel(title, Vector2(116, y + 18), Vector2(w - 240, 26), 18, panel, false, Color(0.94, 0.90, 0.80))
	_mklabel(desc, Vector2(116, y + 48), Vector2(w - 240, 20), 13, panel, false, Color(0.70, 0.66, 0.58))
	_mklabel("SOLD" if sold else "%dg" % cost, Vector2(116, y + 76), Vector2(160, 24), 17, panel, false,
		Color(0.6, 0.6, 0.6) if sold else (C_COIN if afford else C_RED))
	if sold:
		return
	if not afford:
		_mklabel("%dg short" % (cost - treasury), Vector2(w - 190, y + 44), Vector2(180, 22), 14,
			panel, true, C_RED)
		return
	var buy := Button.new()
	buy.text = "Buy"
	buy.add_theme_font_size_override("font_size", 17)
	buy.position = Vector2(w - 150, y + 32)
	buy.size = Vector2(150, 48)
	buy.pressed.connect(_sheet_buy.bind(i))
	panel.add_child(buy)

## Buying closes the sheet and hands you back to the room, because the SECOND half of the purchase
## is picking who gets it — and the people you are picking between are standing right there. Same
## two-tap grammar the list shop always used, with the room as the target strip.
func _sheet_buy(i: int) -> void:
	if busy or i < 0 or i >= shop_stock.size():
		return
	var s: Dictionary = shop_stock[i]
	if bool(s.get("sold", false)):
		return
	if treasury < int(s["cost"]):
		_msg("%dg short — the rent comes first." % (int(s["cost"]) - treasury))
		return
	if mode != Mode.SOLO:
		_intent("shop", str(i))   # buys for MY dwarf; under the rent line _is_ring makes it a vote
		_close_sheet()
		return
	shop_sel = i
	_close_sheet()
	_rebuild_current()

func _sheet_hire() -> void:
	if mode != Mode.SOLO:
		var pc := _sheet_frame("— THE RECRUITMENT HALL —", "Seats are fixed for the whole campaign.", 260.0)
		_mklabel("Every seat is a player, so nobody is hired over one. A dwarf who goes down\nrides the wagon, and an heir takes the seat on the next tile.",
			Vector2(20, 110), Vector2(SHEET_W - 40, 80), 15, pc, true, Color(0.72, 0.68, 0.58))
		return
	var ri := _shop_slot_of("recruit")
	if ri < 0 or bool(shop_stock[ri].get("sold", false)):
		var pe := _sheet_frame("— THE RECRUITMENT HALL —", "The bench is empty.", 220.0)
		_mklabel("Nobody else is looking for work this month." if ri >= 0
			else "Nobody is looking for work this month.",
			Vector2(0, 116), Vector2(SHEET_W, 26), 17, pe, true, Color(0.78, 0.74, 0.66))
		return
	var s: Dictionary = shop_stock[ri]
	var cost := int(s["cost"])
	var afford := treasury >= cost
	var panel := _sheet_frame("— SIGN A NEW HAND —",
		"A roster you cannot field is the real loss.", 420.0)
	_mkemoji(Vector2(SHEET_W * 0.5, 150), Vector2(120, 96), 54, panel).text = Db.CLASSES[s["cls"]]["emoji"]
	_mklabel(str(s["name"]), Vector2(0, 208), Vector2(SHEET_W, 30), 22, panel, true, Color(0.94, 0.90, 0.80))
	_mklabel("%s · %s" % [str(Db.CLASSES[s["cls"]]["name"]), str(Db.CLASSES[s["cls"]]["role"]).to_upper()],
		Vector2(0, 242), Vector2(SHEET_W, 22), 15, panel, true, Color(0.70, 0.66, 0.58))
	_mklabel("%d HP · joins the roster ready to march" % int(Db.CLASSES[s["cls"]]["max_hp"]),
		Vector2(0, 268), Vector2(SHEET_W, 22), 14, panel, true, Color(0.66, 0.62, 0.55))
	_mklabel("%dg" % cost, Vector2(0, 300), Vector2(SHEET_W, 30), 22, panel, true,
		C_COIN if afford else C_RED)
	if afford:
		var hire := Button.new()
		hire.text = "Sign %s — %dg" % [str(s["name"]), cost]
		hire.add_theme_font_size_override("font_size", 18)
		hire.position = Vector2(SHEET_W * 0.5 - 150.0, 344)
		hire.size = Vector2(300, 56)
		hire.pressed.connect(_on_hire.bind(ri))
		panel.add_child(hire)
	else:
		_mklabel("%dg short — the rent comes first." % (cost - treasury), Vector2(0, 356),
			Vector2(SHEET_W, 24), 15, panel, true, C_RED)

# ============================================================ Screen: The Town
## The town IS the menu: a venue is a floor you walk onto, not a tab. Time here is FREE and the
## ROSTER is the constraint, so venue navigation is a plain `nav` intent — never a ring proposal.
## Consequence decides the tier, and walking into a room costs nothing.
const VENUES := [
	# Tips are held to ~40 characters: the copy box is 324px at 15px and does NOT autowrap, so a
	# longer string is silently CLIPPED, not reflowed.
	{"key": "contracts", "emoji": "📜", "name": "The Guild Hall",
		"tip": "Contracts. The job that makes rent."},
	{"key": "tavern", "emoji": "🍺", "name": "The Tavern",
		"tip": "Your crew, and what mends them."},
	{"key": "market", "emoji": "⚒️", "name": "The Market",
		"tip": "Cards and kit, paid against rent."},
	{"key": "recruit", "emoji": "📣", "name": "The Recruitment Hall",
		"tip": "Hire. Roster is what you can field."},
]

## The state a venue's floor advertises, so the town says what is WAITING in each room rather than
## just naming it. [text, colour] — colour carries urgency, text carries the count.
## [text, SCREEN colour, PARCHMENT ink token]. The third element exists because these same words are
## painted on a prop's parchment tag, and C_GREEN/C_AMBER are bright screen colours that go illegible
## on cream — a status worth showing is worth being able to read.
func _venue_status(key: String) -> Array:
	match key:
		"contracts":
			var n := contracts.size()
			return ["%d ON THE BOARD" % n, C_COIN if n > 0 else Color(0.6, 0.6, 0.64),
				"brass_lo" if n > 0 else "dim"]
		"tavern":
			var hurt := _recovering_count()
			if hurt > 0:
				return ["%d MENDING" % hurt, C_AMBER, "warn"]
			return ["ALL FIT", C_GREEN, "good"]
		"market":
			var left := 0
			for s in shop_stock:
				if not bool(s.get("sold", false)) and str(s.get("kind", "")) != "recruit":
					left += 1
			return ["%d ON THE SHELF" % left, C_COIN if left > 0 else Color(0.6, 0.6, 0.64),
				"brass_lo" if left > 0 else "dim"]
		"recruit":
			if mode != Mode.SOLO:
				# Co-op seats are fixed — a benched dwarf would be a benched PLAYER.
				return ["SEATS ARE FIXED", Color(0.6, 0.6, 0.64), "dim"]
			for s in shop_stock:
				if str(s.get("kind", "")) == "recruit" and not bool(s.get("sold", false)):
					return ["1 WAITING", C_COIN, "brass_lo"]
			return ["NOBODY TODAY", Color(0.6, 0.6, 0.64), "dim"]
	return ["", Color.WHITE, "dim"]

## Every venue tap goes through here, so SOLO and co-op take the same path and a client never
## mutates its own screen — it asks, and renders whatever the next snapshot says.
func _on_venue(key: String) -> void:
	if busy:
		return
	if mode != Mode.SOLO:
		_intent("nav", key)
		return
	_enter_venue(key)

func _enter_venue(key: String) -> void:
	# Walking out of a room closes whatever sub-menu was open in it, and disarms a good you armed
	# but never gave to anyone — an armed purchase must not follow you into the next building.
	sheet_key = ""
	shop_sel = -1
	match key:
		# "guild" is the ROOM's name and "contracts" is the VENUE's; the town map's prop says
		# `goto:guild`, so both must land here or the building that makes rent is a dead tap.
		"contracts", "guild":
			_do_view_contracts()
		"tavern":
			state = "TAVERN"
			_clear_screen()
			_build_tavern()
			_refresh_hud()
		"market":
			shop_sel = -1
			state = "MARKET"
			_clear_screen()
			_build_market()
			_refresh_hud()
		"recruit":
			state = "RECRUIT"
			_clear_screen()
			_build_recruit()
			_refresh_hud()
		_:
			_enter_dashboard()

## Rebuild whatever screen is currently up. Anything that mutates shared state (a buy, a heal) calls
## this instead of naming one screen — which is what stopped the shop refresh from being welded to
## the contracts board when the shop moved out of it.
func _rebuild_current() -> void:
	match state:
		"DASHBOARD":
			_clear_screen()
			_build_dashboard()
		"CONTRACTS":
			_clear_screen()
			_build_contracts()
		"TAVERN":
			_clear_screen()
			_build_tavern()
		"MARKET":
			_clear_screen()
			_build_market()
		"RECRUIT":
			_clear_screen()
			_build_recruit()
	_refresh_sheet()

## Which room spec the screen we are on is standing in. One table, so a prop lookup and a fallback
## never disagree about where the player is.
func _room_key_for_state() -> String:
	match state:
		"DASHBOARD":
			return "town"
		"CONTRACTS":
			return "guild"
		"TAVERN":
			return "tavern"
		"MARKET":
			return "market"
		"RECRUIT":
			return "recruit"
	return ""

func _build_town() -> void:
	# The town map is a room like any other — its four buildings are props whose act is `goto:`.
	# End Month is NOT built here any more: it lives in the HUD, under the pips it spends.
	if _build_room("town"):
		return
	_build_town_floors()

## The fallback shell: a plain list of floors, used when no town spec is present.
func _build_town_floors() -> void:
	_mklabel("— DORF & CO. —", Vector2(0, 174), Vector2(720, 30), 24, screen_root)
	_mklabel("%d campaign%s left this month · rent %dg due at month end"
		% [campaigns_left, "" if campaigns_left == 1 else "s", fee],
		Vector2(0, 208), Vector2(720, 20), 14, screen_root, true,
		C_AMBER if campaigns_left <= 1 else Color(0.72, 0.84, 0.95))
	_build_town_ticker()
	var ys := [352, 508, 664, 820]
	for i in range(VENUES.size()):
		_build_venue_floor(VENUES[i], ys[i])

## The roster along the top: who you have, and how hurt. It is the town's headline because the
## roster is what actually binds — the treasury is already in the HUD.
func _build_town_ticker() -> void:
	_rect(Vector2(24, 240), Vector2(672, 92), Color(0.13, 0.12, 0.10), screen_root)
	var n: int = maxi(1, roster.size())
	var w: float = 672.0 / float(n)
	for i in range(roster.size()):
		var d: Dictionary = roster[i]
		var cx: float = 24.0 + w * (float(i) + 0.5)
		var status := str(d["status"])
		var emo := _mkemoji(Vector2(cx, 272), Vector2(52, 44), 28, screen_root)
		emo.text = Db.CLASSES[d["cls"]]["emoji"]
		if status == "wounded":
			emo.modulate = MOD_WOUNDED
		elif status == "lost":
			emo.modulate = MOD_LOST
		_mklabel(str(d["name"]).split(" ")[0], Vector2(cx - w * 0.5, 296), Vector2(w, 18), 15,
			screen_root, true, Color(0.88, 0.86, 0.8))
		var line := "%d/%d" % [int(d["hp"]), int(d["max_hp"])]
		var col := C_GREEN
		if status == "wounded":
			line = "mending %d" % int(d["recover"])
			col = C_AMBER
		elif status == "lost":
			line = "lost"
			col = Color(0.55, 0.55, 0.6)
		_mklabel(line, Vector2(cx - w * 0.5, 314), Vector2(w, 16), 13, screen_root, true, col)

func _build_venue_floor(v: Dictionary, y: int) -> void:
	var floor_ctl := Control.new()
	floor_ctl.position = Vector2(24, y)
	floor_ctl.size = Vector2(672, 140)
	floor_ctl.mouse_filter = Control.MOUSE_FILTER_STOP
	floor_ctl.gui_input.connect(_on_venue_input.bind(str(v["key"])))
	screen_root.add_child(floor_ctl)
	_rect(Vector2.ZERO, Vector2(672, 140), Color(0.17, 0.13, 0.09), floor_ctl)
	_rect(Vector2.ZERO, Vector2(672, 4), Color(0.42, 0.31, 0.16), floor_ctl)
	_mkemoji(Vector2(74, 70), Vector2(84, 72), 40, floor_ctl).text = str(v["emoji"])
	# 132 + 324 = 456 against a status plate starting at 468 -> 12px of gutter. Widening either box
	# past 324 runs the copy under the plate, which is the defect the mockup audits kept finding.
	_mklabel(str(v["name"]), Vector2(132, 32), Vector2(324, 30), 22, floor_ctl, false,
		Color(0.94, 0.90, 0.80))
	_mklabel(str(v["tip"]), Vector2(132, 70), Vector2(324, 24), 15, floor_ctl, false,
		Color(0.70, 0.66, 0.58))
	var st: Array = _venue_status(str(v["key"]))
	_rect(Vector2(468, 50), Vector2(188, 40), Color(0, 0, 0, 0.34), floor_ctl)
	_mklabel(str(st[0]), Vector2(468, 58), Vector2(188, 24), 15, floor_ctl, true, st[1])

func _on_venue_input(event: InputEvent, key: String) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_venue(key)

## Shared venue chrome: a title and the one control every room needs — the way out. The back
## affordance is weighted over the entry, because free re-entry is the whole point of a free town.
func _build_venue_header(title: String, sub: String) -> void:
	_mklabel(title, Vector2(0, 172), Vector2(720, 30), 22, screen_root)
	_mklabel(sub, Vector2(0, 206), Vector2(720, 20), 14, screen_root, true, Color(0.78, 0.74, 0.66))

func _build_back_to_town() -> void:
	var back := Button.new()
	back.text = "◀ The Town"
	back.add_theme_font_size_override("font_size", 18)
	back.position = Vector2(24, 1150)
	back.size = Vector2(200, 70)
	back.pressed.connect(_on_back_dashboard)
	screen_root.add_child(back)

# ============================================================ Screen: The Tavern
## The crew's standing condition, directly above the goods that buy that condition back. The
## apothecary lives here rather than in the Market because what it sells is ROSTER TIME, and the
## roster is what binds.
func _build_tavern() -> void:
	if _build_room("tavern"):
		_build_back_to_town()
		return
	_build_venue_header("— THE TAVERN —", "Wounds clear over months, not on the job.")
	# The roster band is FIXED and the rows divide it, so a roster that grows past four still fits
	# above the apothecary. Letting a row list push into the band below is the scaling failure every
	# mockup of this screen made.
	var n: int = maxi(1, roster.size())
	var rh: int = clampi(int(474.0 / float(n)), 62, 118)
	var y := 244
	for d in roster:
		_build_tavern_row(d, y, rh - 10)
		y += rh
	var ay: int = 244 + rh * n + 14
	_mklabel("— THE APOTHECARY —", Vector2(0, ay), Vector2(720, 22), 16, screen_root, true, C_COIN)
	var heal_i := -1
	for i in range(shop_stock.size()):
		if str(shop_stock[i].get("kind", "")) == "heal":
			heal_i = i
			break
	if heal_i >= 0:
		_build_shop_slot(heal_i, 264, ay + 32)
		if mode == Mode.SOLO and shop_sel == heal_i:
			_mklabel("Tap the dwarf who gets it.", Vector2(0, ay + 150), Vector2(720, 24), 16,
				screen_root, true, C_AMBER)
			_build_shop_targets()
	else:
		_mklabel("The shelf is bare until the month turns.", Vector2(0, ay + 40), Vector2(720, 22), 15,
			screen_root, true, Color(0.66, 0.62, 0.55))
	_build_back_to_town()

func _build_tavern_row(d: Dictionary, y: int, h: int) -> void:
	_crew_row(d, screen_root, 24.0, float(y), 672.0, float(h))

# ============================================================ Screen: The Market
func _build_market() -> void:
	if _build_room("market"):
		_build_back_to_town()
		return
	_build_venue_header("— THE MARKET —", "Every buy trades against the rent clock.")
	_build_shop_panel()
	_build_back_to_town()

# ============================================================ Screen: The Recruitment Hall
## Recruitment exists because the ROSTER binds. In co-op it deliberately offers nobody: a seat is a
## player's identity for the whole campaign, so hiring a body for a seat would bench a person.
func _build_recruit() -> void:
	if _build_room("recruit"):
		_build_back_to_town()
		return
	_build_venue_header("— THE RECRUITMENT HALL —", "A roster you cannot field is the real loss.")
	if mode != Mode.SOLO:
		_mklabel("Seats are fixed for the whole campaign.", Vector2(0, 470), Vector2(720, 26), 19,
			screen_root, true, Color(0.86, 0.84, 0.78))
		_mklabel("Every seat is a player. Nobody gets hired over one — a dwarf who goes down\nrides the wagon and an heir takes the seat on the next tile.",
			Vector2(0, 508), Vector2(720, 60), 15, screen_root, true, Color(0.68, 0.65, 0.58))
		_build_back_to_town()
		return
	var ri := -1
	for i in range(shop_stock.size()):
		if str(shop_stock[i].get("kind", "")) == "recruit":
			ri = i
			break
	if ri < 0:
		_mklabel("Nobody is looking for work this month.", Vector2(0, 470), Vector2(720, 26), 19,
			screen_root, true, Color(0.78, 0.74, 0.66))
		_build_back_to_town()
		return
	var s: Dictionary = shop_stock[ri]
	var sold := bool(s.get("sold", false))
	var cost := int(s["cost"])
	_rect(Vector2(180, 300), Vector2(360, 320), Color(0.17, 0.13, 0.09), screen_root)
	_mkemoji(Vector2(360, 380), Vector2(120, 96), 56, screen_root).text = Db.CLASSES[s["cls"]]["emoji"]
	_mklabel(str(s["name"]), Vector2(180, 448), Vector2(360, 30), 22, screen_root, true,
		Color(0.94, 0.90, 0.80))
	_mklabel("%s · %s" % [str(Db.CLASSES[s["cls"]]["name"]), str(Db.CLASSES[s["cls"]]["role"]).to_upper()],
		Vector2(180, 482), Vector2(360, 22), 15, screen_root, true, Color(0.70, 0.66, 0.58))
	_mklabel("%d HP · joins the roster ready" % int(Db.CLASSES[s["cls"]]["max_hp"]),
		Vector2(180, 512), Vector2(360, 22), 14, screen_root, true, Color(0.66, 0.62, 0.55))
	var afford := treasury >= cost and not sold
	_mklabel(("HIRED" if sold else "%dg" % cost), Vector2(180, 556), Vector2(360, 30), 22,
		screen_root, true, (Color(0.6, 0.6, 0.6) if sold else (C_COIN if afford else C_RED)))
	if not sold:
		var hire := Button.new()
		hire.text = "Sign %s — %dg" % [str(s["name"]), cost]
		hire.add_theme_font_size_override("font_size", 20)
		hire.position = Vector2(396, 1150)
		hire.size = Vector2(300, 70)
		hire.disabled = not afford
		hire.pressed.connect(_on_hire.bind(ri))
		screen_root.add_child(hire)
		if not afford:
			_mklabel("%dg short." % (cost - treasury), Vector2(0, 640), Vector2(720, 22), 15,
				screen_root, true, C_RED)
	_build_back_to_town()

func _on_hire(i: int) -> void:
	if busy or mode != Mode.SOLO:
		return
	sheet_key = ""
	_buy_recruit(i)

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
			# Clearing the WOUND is the point — every shelf tag for this good says so ("mend one
			# wound"), and the older list path always did it. Topping HP alone made the room's
			# apothecary quietly weaker than the same purchase off a menu.
			if str(d["status"]) == "wounded":
				d["status"] = "ready"
				d["recover"] = 0
			d["hp"] = int(d["max_hp"])
			_msg("%s is patched up to full." % d["name"])
		_:
			return
	treasury -= int(s["cost"])
	_tween_treasury_to(treasury)
	s["sold"] = true
	_rebuild_current()
	_refresh_hud()

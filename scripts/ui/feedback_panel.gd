extends Control
## THE DESIGNER'S NOTES — a playtest instrument, not a hint system.
##
## A closable popup that prints what an encounter is TRYING to do: the one question it asks, the
## turn-by-turn rhythm it should have, what the design is betting on, what should be true if it
## landed, and — the load-bearing part — what we would see if it did NOT. Beside that it prints the
## board as it actually is right now, so a playtester can hold intent and reality side by side and
## tell us which one is lying.
##
## THE WHOLE DESIGN CONSTRAINT is the last clause of the request: "only reveal on pressing the
## feedback button as to not spoil." So this widget is INVISIBLE AND INERT until pressed. It reads
## nothing, polls nothing, and subscribes to nothing; combat.gd hands it a dict at the moment of the
## tap and it renders that dict. If it ever starts leaking intent into the fight (a badge, a nudge, a
## "you should be blocking here"), it has stopped being an instrument and become a tutorial.
##
## It is also deliberately OUT OF FICTION. The Writ owns parchment/ink/coin — that palette means
## "the world is speaking to you". These notes use a cold blueprint slate instead, with a monospaced
## eyebrow and section headings in flat capitals, so the moment it opens it reads as the developer
## talking over the game rather than the game talking to you. That is not decoration: a player who
## thinks the notes are diegetic will read the `assumes` list as instructions, and then they can no
## longer tell us whether the fight taught them anything.
##
## API (kept deliberately tiny — combat.gd should need to know nothing else):
##   setup()                      build it, start hidden
##   show_notes(enc, live)        render + reveal
##   close()                      hide, emits `closed`
##   signal closed
##
## `enc`  — the encounter dict from encounter_db.gd: {name, band, question, design: {question,
##          assumes[], rhythm[], asserts[], fails_if[], teaches}}. MAY BE EMPTY (a freeform skirmish
##          rolled from the encounter pool has no authored intent) — that case gets a written
##          fallback, because "no notes" is itself a finding worth showing a playtester.
## `live` — {"turn": int, "bodies": int, "devices": [String], "scale": float}: the board in front of
##          them right now.

signal closed

const W := 720.0
const H := 1280.0

## Above the threat arrows (a Node2D drawn across the WHOLE board, z 40), above the intent panel
## (60) and the Class Power tip (61), and above the 3-way pick dim (50). Below the Writ (80), which
## is a scene-level modal and should never be buried by a debug popup.
const Z := 70

# --- geometry (720x1280 portrait) ---
const SHEET_POS := Vector2(24, 88)
const SHEET_SIZE := Vector2(672, 1104)
const BAR_H := 132.0
const PAD := 22.0

## Type scale. Per the engine spec note in writ_scene.gd: Material 16sp and Apple 17pt both land at
## 27-31 game px on this 720-wide canvas, so 20 is the absolute floor for anything a human reads.
const F_EYEBROW := 20
const F_NAME := 30
const F_META := 20
const F_QUESTION := 34
const F_TEACH := 21
const F_HEAD := 21
const F_ITEM := 23
const F_FOOT := 21

# --- palette: cold drafting slate, deliberately NOT the game's parchment/coin ---
const COL_DIM       := Color(0.020, 0.024, 0.035, 0.90)
const COL_SHEET     := Color(0.078, 0.086, 0.110)
const COL_BAR       := Color(0.106, 0.122, 0.157)
const COL_EDGE      := Color(0.353, 0.443, 0.576)
const INK           := Color(0.882, 0.902, 0.941)
const INK_SOFT      := Color(0.580, 0.624, 0.706)
const INK_FAINT     := Color(0.435, 0.475, 0.549)
const ACC_EYEBROW   := Color(0.435, 0.714, 0.949)
const ACC_QUESTION  := Color(0.976, 0.898, 0.612)
const ACC_RHYTHM    := Color(0.494, 0.769, 0.949)
const ACC_ASSUME    := Color(0.639, 0.678, 0.769)
const ACC_ASSERT    := Color(0.443, 0.855, 0.545)
const ACC_FAIL      := Color(0.980, 0.427, 0.400)
const ACC_LIVE      := Color(0.725, 0.596, 0.976)

var _sheet: ColorRect
var _scroll: ScrollContainer
var _col: VBoxContainer
var _eyebrow: Label
var _name_lbl: Label
var _meta_lbl: Label
var _built := false

# ================================================================ lifecycle

## Build the panel and leave it hidden. Safe to call before or after the node is added to the tree,
## and safe to call twice (combat.gd rebuilds its UI on Play Again).
func setup() -> void:
	if _built:
		close()
		return
	_built = true

	# Explicit rect, NOT an anchor preset. PRESET_FULL_RECT would size this to the PARENT's rect, and
	# combat.gd's root is a bare Control whose rect is not guaranteed to be the viewport — the panel
	# would silently collapse to 0x0, which for a full-screen input blocker means it blocks nothing
	# and the card fan underneath stays live. combat.gd's own overlay/choice_box hardcode 720x1280
	# for exactly this reason; match them.
	position = Vector2.ZERO
	size = Vector2(W, H)
	# THE MODAL RULE (this repo's most expensive bug, documented in CLAUDE.md): MOUSE_FILTER_STOP only
	# catches taps inside the node's OWN RECT. A panel floated over the middle of the board would
	# leave the card fan at y~930 LIVE UNDERNEATH IT — you could read the notes and play a card with
	# the same tap. So the root is FULL-SCREEN and STOPs, exactly like combat.gd's choice_box.
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = Z
	visible = false

	# The dim is purely cosmetic and must NOT swallow input, because the root above is what turns a
	# tap-on-the-dim into a close (see _gui_input). One node owning the input is one node to reason
	# about; two would race.
	var dim := ColorRect.new()
	dim.color = COL_DIM
	dim.size = Vector2(W, H)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	# The sheet DOES stop: a tap on the notes must not close them (you will be dragging to scroll,
	# and a scroll that dismisses the thing you are reading is unusable on touch).
	_sheet = ColorRect.new()
	_sheet.color = COL_SHEET
	_sheet.position = SHEET_POS
	_sheet.size = SHEET_SIZE
	_sheet.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_sheet)
	_edge(_sheet)

	_build_bar()
	_build_scroll()

## A 1px light frame on all four sides — a drafting-sheet border, drawn with plain ColorRects
## because the rest of this repo builds every screen out of ColorRects and Labels in code.
func _edge(host: ColorRect) -> void:
	var s := host.size
	for r: Rect2 in [
		Rect2(Vector2(0, 0), Vector2(s.x, 2)),
		Rect2(Vector2(0, s.y - 2), Vector2(s.x, 2)),
		Rect2(Vector2(0, 0), Vector2(2, s.y)),
		Rect2(Vector2(s.x - 2, 0), Vector2(2, s.y)),
	]:
		var e := ColorRect.new()
		e.color = COL_EDGE
		e.position = r.position
		e.size = r.size
		e.mouse_filter = Control.MOUSE_FILTER_IGNORE
		host.add_child(e)

## The title bar is PINNED, not scrolled. Twelve encounters' notes are long; if the header scrolled
## away, so would the close button, and a modal you have to scroll back up to escape is a trap.
func _build_bar() -> void:
	var bar := ColorRect.new()
	bar.color = COL_BAR
	bar.position = Vector2(2, 2)
	bar.size = Vector2(SHEET_SIZE.x - 4, BAR_H)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheet.add_child(bar)

	var rule := ColorRect.new()
	rule.color = COL_EDGE
	rule.position = Vector2(2, BAR_H + 2)
	rule.size = Vector2(SHEET_SIZE.x - 4, 2)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheet.add_child(rule)

	_eyebrow = _bar_label("DESIGNER'S NOTES  //  OUT OF FICTION", Vector2(PAD, 12), F_EYEBROW, ACC_EYEBROW)
	_name_lbl = _bar_label("", Vector2(PAD, 40), F_NAME, INK)
	_meta_lbl = _bar_label("", Vector2(PAD, 84), F_META, INK_SOFT)

	# "×" is U+00D7, not U+2715 "✕". The web glyph gate rejects the latter: the browser build ships
	# only NotoSans + TwemojiMozilla with no OS fallback, and ✕ is in neither cmap, so it would be a
	# tofu box on the deployed build while looking perfect in the editor.
	var x := Button.new()
	x.text = "×"
	x.add_theme_font_size_override("font_size", 32)
	x.position = Vector2(SHEET_SIZE.x - 74, 14)
	x.size = Vector2(56, 56)
	x.pressed.connect(close)
	_sheet.add_child(x)

func _bar_label(text: String, pos: Vector2, font: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.size = Vector2(SHEET_SIZE.x - PAD * 2 - 60, float(font) + 12.0)
	l.add_theme_font_size_override("font_size", font)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheet.add_child(l)
	return l

## Everything below the bar scrolls. This is not optional: a clipped `fails_if` is the one thing that
## must never happen, and it is the LAST authored section — so on a long encounter it is exactly what
## would fall off the bottom of a fixed-height panel.
func _build_scroll() -> void:
	_scroll = ScrollContainer.new()
	_scroll.position = Vector2(2, BAR_H + 4)
	_scroll.size = Vector2(SHEET_SIZE.x - 4, SHEET_SIZE.y - BAR_H - 8)
	# Horizontal scrolling OFF is what makes the autowrap labels below wrap to the sheet width
	# instead of running off into an infinitely wide row.
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_sheet.add_child(_scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, int(PAD))
	_scroll.add_child(margin)

	_col = VBoxContainer.new()
	_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_col.add_theme_constant_override("separation", 16)
	margin.add_child(_col)

# ================================================================ public API

## Render `enc` against `live` and reveal. Both dicts are read once, here — the panel never holds a
## reference to combat state, so it cannot go stale behind the player's back or animate on its own.
func show_notes(enc: Dictionary, live: Dictionary) -> void:
	if not _built:
		setup()
	_clear()

	var design: Dictionary = enc.get("design", {}) if enc.get("design", null) is Dictionary else {}
	var enc_name := str(enc.get("name", "")).strip_edges()
	var band := str(enc.get("band", "")).strip_edges()

	_name_lbl.text = enc_name if enc_name != "" else "Unnamed skirmish"
	_meta_lbl.text = ("band: " + band) if band != "" else "no band - rolled from the encounter pool"

	if design.is_empty():
		_fallback(enc)
	else:
		_authored(enc, design)

	_live(live)
	_footer()

	_scroll.scroll_vertical = 0
	visible = true

## Hide and tell combat.gd (which un-dims the board and re-arms the card fan). Idempotent: the ✕ and
## a tap on the dim can both land in the same frame on touch.
func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()

## The root is full-screen and STOPs, so any tap that was not eaten by the sheet arrived here — i.e.
## the player tapped the dim. That closes, which is the standard modal gesture and costs no chrome.
func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		close()
		accept_event()

# ================================================================ content

func _clear() -> void:
	for c: Node in _col.get_children():
		c.queue_free()
		_col.remove_child(c)

## The authored case: the encounter carries a `design` sub-dict.
func _authored(enc: Dictionary, design: Dictionary) -> void:
	# The framing line lives in the scroll rather than the pinned bar so the bar stays a title, not a
	# paragraph. It is the first thing read on open, which is where the "this is not a hint" contract
	# has to be stated.
	_note("What follows is the intent behind this fight, written before you played it. The fight itself never says any of this out loud - that is on purpose. Read it, then tell us how much of it you actually felt.")

	# The one decision, largest type on the panel. `design.question` wins over the encounter's
	# top-level `question`: the design sub-dict is the authored playtest framing, the outer one may
	# just be a flavour headline.
	var q := str(design.get("question", enc.get("question", ""))).strip_edges()
	_question(q if q != "" else "This encounter has no stated question yet - that is itself worth reporting.")

	# `teaches` rides directly under the question because it is the same sentence from the other end:
	# the question is what we ask, teaches is what we hope you walk away knowing.
	var teaches := str(design.get("teaches", "")).strip_edges()
	if teaches != "":
		_teaches(teaches)

	# Rhythm is genuinely a SEQUENCE (turn 1 does this, turn 2 does that), so it is the one list that
	# is numbered. Everything else is an unordered set of claims and gets bullets.
	_block("THE RHYTHM IT SHOULD HAVE", ACC_RHYTHM, _arr(design, "rhythm"), "num", false)
	_block("WHAT IT'S BETTING ON", ACC_ASSUME, _arr(design, "assumes"), "dot", false)
	_block("IF IT LANDED, THIS IS TRUE", ACC_ASSERT, _arr(design, "asserts"), "check", false)
	# The most prominent block after the question, by request: a popup that only lists its successes
	# is a brag. This is the half that makes it an instrument — it hands the playtester the exact
	# symptoms of failure so they can say "yes, that one" instead of inventing their own vocabulary.
	_block("IF IT DIDN'T, THIS IS WHAT YOU'D SEE", ACC_FAIL, _arr(design, "fails_if"), "cross", true)

## The freeform case. Handled with WORDS, not a crash and not an empty panel: "no authored intent"
## is a real answer, and a playtester who opens the notes on a random skirmish deserves to know that
## nobody designed the fight they are in rather than assuming the panel broke.
func _fallback(enc: Dictionary) -> void:
	_note("This fight has no designer's notes. It was not authored as a set piece - it is a freeform skirmish rolled from the encounter pool, so there is no stated intention to hold it against.")
	var q := str(enc.get("question", "")).strip_edges()
	if q != "":
		_question(q)
	else:
		_question("No stated question. Did this fight still have a shape?")
	_block("WHAT WE'D STILL LIKE TO KNOW", ACC_FAIL, [
		"Did it feel like a fight with a point, or like three enemies and some arithmetic?",
		"Was there a turn where you had a real decision, or did every turn play itself?",
		"Would you have noticed if this fight had been swapped for a different one?",
	], "cross", true)

## The board in front of them right now. Intent is only useful next to reality — "the rhythm says
## turn 2 is the squeeze" means nothing until you can see that you are ON turn 2 with two bodies up.
func _live(live: Dictionary) -> void:
	var turn := int(live.get("turn", 0))
	var bodies := int(live.get("bodies", 0))
	var scale := float(live.get("scale", 1.0))
	var devices: Array = live.get("devices", []) if live.get("devices", null) is Array else []

	var lines: Array = [
		"turn %d   -   %d %s standing   -   enemy scale %.2f" % [turn, bodies, "body" if bodies == 1 else "bodies", scale],
	]
	if devices.is_empty():
		lines.append("no devices active on this board")
	else:
		var names: Array = []
		for d: Variant in devices:
			names.append(str(d))
		lines.append("devices live: " + ", ".join(names))
	_block("THE BOARD RIGHT NOW", ACC_LIVE, lines, "dot", false)

## Plain, unstyled, first person. After a page of design jargon the closing line should sound like a
## person asking a question, because that is the behaviour we actually want out of this widget.
func _footer() -> void:
	_rule()
	var l := _text("Did it land? Tell us the honest version - \"I never noticed\" is the single most useful thing you can say here.", F_FOOT, INK_SOFT)
	l.add_theme_constant_override("line_spacing", 6)

# ================================================================ pieces

func _text(body: String, font: int, col: Color) -> Label:
	var l := Label.new()
	l.text = body
	l.add_theme_font_size_override("font_size", font)
	l.add_theme_color_override("font_color", col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_child(l)
	return l

func _note(body: String) -> void:
	var l := _text(body, F_META, INK_FAINT)
	l.add_theme_constant_override("line_spacing", 5)

func _rule() -> void:
	var r := ColorRect.new()
	r.color = Color(COL_EDGE.r, COL_EDGE.g, COL_EDGE.b, 0.45)
	r.custom_minimum_size = Vector2(0, 2)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_child(r)

## The question: largest type on the panel, in the warm coin-gold that is otherwise reserved for
## things that matter, on its own slab. If a playtester reads one line before closing this, it is
## this one, so nothing else is allowed to compete with it for size.
func _question(q: String) -> void:
	var panel := _slab(ACC_QUESTION, Color(0.157, 0.145, 0.098, 0.55), 6)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(box)
	_into(box, "THE ONE DECISION", F_HEAD, ACC_QUESTION.darkened(0.15), 0)
	_into(box, q, F_QUESTION, ACC_QUESTION, 8)

func _teaches(t: String) -> void:
	var l := _text("teaches:  " + t, F_TEACH, INK_SOFT)
	l.add_theme_constant_override("line_spacing", 4)

## One section: a heading in flat capitals over a list. `emphatic` thickens the left spine and tints
## the slab — the single knob that makes `fails_if` louder than its neighbours without inventing a
## second visual language for it.
func _block(title: String, accent: Color, items: Array, style: String, emphatic: bool) -> void:
	if items.is_empty() and not emphatic:
		return   # an unauthored optional section prints nothing rather than an empty heading
	var tint := Color(accent.r, accent.g, accent.b, 0.14 if emphatic else 0.06)
	var panel := _slab(accent, tint, 8 if emphatic else 4)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(box)
	_into(box, title, F_HEAD + (3 if emphatic else 0), accent, 0)

	if items.is_empty():
		_into(box, "(not written yet - if this fight can fail, we have not said how)", F_ITEM - 2, INK_FAINT, 6)
		return

	for i: int in range(items.size()):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_child(row)

		var mark := Label.new()
		mark.text = _glyph(style, i)
		mark.add_theme_font_size_override("font_size", F_ITEM)
		mark.add_theme_color_override("font_color", accent)
		mark.custom_minimum_size = Vector2(38, 0)
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(mark)

		var body := Label.new()
		body.text = str(items[i])
		body.add_theme_font_size_override("font_size", F_ITEM)
		body.add_theme_color_override("font_color", INK if emphatic else Color(0.82, 0.84, 0.89))
		body.add_theme_constant_override("line_spacing", 4)
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(body)

## Bullet glyphs. Only the rhythm is numbered, because only the rhythm is a sequence — numbering an
## unordered list quietly asserts an order that the design never claimed.
##
## The check/cross are the EMOJI ✅/❌, not the text marks ✓/✗ (U+2713/U+2717): those two are in
## neither shipped web font and would be tofu on the deployed build. That is a happy accident here —
## the emoji carry their own green/red, and a Twemoji glyph ignores the font_color override, so the
## text marks would have needed the tint that the emoji provide for free.
func _glyph(style: String, i: int) -> String:
	match style:
		"num": return "%d." % (i + 1)
		"check": return "✅"
		"cross": return "❌"
	return "•"

## A tinted slab with a coloured left spine. PanelContainer + StyleBoxFlat rather than the repo's
## usual bare ColorRects: these blocks sit in a VBox and their heights come from wrapped text, so
## they have to size themselves — an absolutely-positioned ColorRect cannot.
func _slab(accent: Color, tint: Color, spine: int) -> PanelContainer:
	var sb := StyleBoxFlat.new()
	sb.bg_color = tint
	sb.border_color = accent
	sb.border_width_left = spine
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 16.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 16.0
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_child(p)
	return p

func _into(box: VBoxContainer, body: String, font: int, col: Color, top_pad: int) -> Label:
	if top_pad > 0:
		var sp := Control.new()
		sp.custom_minimum_size = Vector2(0, top_pad)
		sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(sp)
	var l := Label.new()
	l.text = body
	l.add_theme_font_size_override("font_size", font)
	l.add_theme_color_override("font_color", col)
	l.add_theme_constant_override("line_spacing", 4)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(l)
	return l

## Read an authored list defensively. encounter_db.gd is hand-written data and a missing or
## mistyped key must degrade to an empty section, never take the combat scene down with it — this
## panel is a debug tool and a debug tool that can crash the build is worse than no debug tool.
func _arr(design: Dictionary, key: String) -> Array:
	var v: Variant = design.get(key, [])
	return v if v is Array else []

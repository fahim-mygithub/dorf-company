extends Control
## THE WRIT — a LINEAR two-party dialogue player.
##
## World on the LEFT, Company on the RIGHT, fixed, never swapped. Exactly one side is lit; the
## listener drops to 45% and recedes. The name tab anchors to the SPEAKING side, which is what
## makes turn-taking readable without a label.
##
## Deliberately has NO choices, NO checks and NO networked state. That is not a simplification
## for its own sake: a scene with no decisions has nothing to agree on, so every peer can play it
## locally at its own reading pace and the campaign only needs one done-flag per seat at the end.
## If you add a choice here you also inherit the ring, the pips and the deadlock timer.
##
## Beat dict:
##   who      "" = narration (no tab) · "@us" = the local player's stand-in · else a literal name
##   side     "left" | "right"   (ignored for narration)
##   art      emoji placeholder; swap for a texture when portraits exist
##   body     the line
##   aside    optional second line, smaller + italic, in ink-soft
##   hold_ms  Continue stays disabled this long (comic timing)
##   auto_ms  advances itself after this long (used once, for the cut-off at beat 2)
##   focus    names a rect in ctx.focus_rects — dims everything EXCEPT that rect
##
## ctx: {us_name, us_art, us_metal: Color, focus_rects: {String: Rect2}}

signal finished

const W := 720.0
const H := 1280.0

const COL_BG      := Color(0.043, 0.043, 0.055)
const COL_SCRIM   := Color(0.024, 0.024, 0.035, 0.88)
const HELL        := Color(0.553, 0.122, 0.141)
const COIN        := Color(0.961, 0.820, 0.259)
const GOLD_TAB    := Color(0.478, 0.353, 0.071)
const PARCH       := Color(0.878, 0.827, 0.706)
const PARCH_EDGE  := Color(0.353, 0.275, 0.157)
const INK         := Color(0.133, 0.110, 0.071)
const INK_SOFT    := Color(0.353, 0.298, 0.204)
const FG          := Color(0.910, 0.902, 0.937)
const FG_DIM      := Color(0.341, 0.329, 0.373)
const SLAB_NEUTRAL:= Color(0.051, 0.059, 0.078)
const SLAB_HELL   := Color(0.102, 0.051, 0.063)
const SLAB_OURS   := Color(0.078, 0.071, 0.047)

## Type scale — derived for a 720-wide canvas at stretch/aspect "keep". See the engine spec:
## Material 16sp and Apple 17pt both land at 27-31 game px, so 20 is the absolute floor.
const F_PROSE := 27
const F_ASIDE := 23
const F_TAB   := 23
const F_NAME  := 22
const F_CONT  := 26
const F_STEP  := 20

var _beats: Array = []
var _ctx: Dictionary = {}
var _i := 0
var _layer: Control
var _cont_btn: Button
var _armed := false
var _auto_left := 0.0
var _hold_left := 0.0
var _epoch := 0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size = Vector2(W, H)
	# Full-screen STOP: the modal rule. During a focus beat the highlighted control is visible
	# through the scrim hole but MUST NOT be pressable — the hole is cosmetic, this eats the tap.
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 80
	_layer = Control.new()
	_layer.size = Vector2(W, H)
	_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_layer)
	set_process(true)

func play(beats: Array, ctx: Dictionary) -> void:
	_beats = beats
	_ctx = ctx
	_i = 0
	_epoch += 1
	visible = true
	_show(_i)

func _process(delta: float) -> void:
	if _hold_left > 0.0:
		_hold_left -= delta
		if _hold_left <= 0.0:
			_armed = true
			if is_instance_valid(_cont_btn):
				_cont_btn.disabled = false
				_cont_btn.modulate = Color(1, 1, 1, 1)
	if _auto_left > 0.0:
		_auto_left -= delta
		if _auto_left <= 0.0:
			_auto_left = 0.0
			_advance()

func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		_advance()
		accept_event()

func _on_continue() -> void:
	_advance()

func _advance() -> void:
	if not _armed:
		return
	_i += 1
	if _i >= _beats.size():
		_armed = false
		visible = false
		finished.emit()
		return
	_show(_i)

# ------------------------------------------------------------------ drawing
func _clear() -> void:
	for c in _layer.get_children():
		c.queue_free()
		_layer.remove_child(c)
	_cont_btn = null

func _rect(pos: Vector2, sz: Vector2, col: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = col
	r.position = pos
	r.size = sz
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(r)
	return r

func _label(txt: String, pos: Vector2, sz: Vector2, font: int, col: Color, center: bool = false, italic_dim: bool = false) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", font)
	l.add_theme_color_override("font_color", col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if center:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.position = pos
	l.size = sz
	if italic_dim:
		l.modulate = Color(1, 1, 1, 0.92)
	_layer.add_child(l)
	return l

func _emoji(center_pos: Vector2, box: Vector2, font: int, alpha: float = 1.0) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.size = box
	l.position = center_pos - box * 0.5
	l.modulate = Color(1, 1, 1, alpha)
	_layer.add_child(l)
	return l

## Resolve a speaker token to {name, art, metal, is_us}.
func _who(tok: String) -> Dictionary:
	if tok == "@us":
		return {"name": str(_ctx.get("us_name", "You")), "art": str(_ctx.get("us_art", "🧍")),
			"metal": _ctx.get("us_metal", COIN), "is_us": true}
	var names: Dictionary = _ctx.get("cast", {})
	var c: Dictionary = names.get(tok, {})
	return {"name": str(c.get("name", tok.capitalize())), "art": str(c.get("art", "😈")),
		"metal": c.get("metal", HELL), "is_us": false}

func _show(i: int) -> void:
	_clear()
	var b: Dictionary = _beats[i]
	var focus: String = str(b.get("focus", ""))
	var rects: Dictionary = _ctx.get("focus_rects", {})
	var has_focus: bool = focus != "" and rects.has(focus)

	var writ_y := 488.0
	if has_focus:
		_draw_focus(rects[focus] as Rect2)
		# Keep the parchment clear of the thing being pointed at.
		writ_y = 700.0 if (rects[focus] as Rect2).get_center().y < 640.0 else 300.0
	else:
		_rect(Vector2.ZERO, Vector2(W, H), COL_BG)
		_draw_portraits(b)

	var cont_y := 1080.0 if not has_focus else writ_y + 300.0 + 28.0
	_draw_writ(b, writ_y, has_focus)
	_draw_continue(b, cont_y, i)

## Scrim everything EXCEPT one rect, then ring it. Four bands, so a target anywhere on the
## screen works — not just one at the top.
func _draw_focus(r: Rect2) -> void:
	var top: float = maxf(0.0, r.position.y)
	var bot: float = minf(H, r.end.y)
	_rect(Vector2(0, 0), Vector2(W, top), COL_SCRIM)
	_rect(Vector2(0, bot), Vector2(W, H - bot), COL_SCRIM)
	_rect(Vector2(0, top), Vector2(maxf(0.0, r.position.x), bot - top), COL_SCRIM)
	_rect(Vector2(r.end.x, top), Vector2(maxf(0.0, W - r.end.x), bot - top), COL_SCRIM)
	var t := 3.0
	_rect(r.position - Vector2(t, t), Vector2(r.size.x + t * 2, t), COIN)
	_rect(Vector2(r.position.x - t, r.end.y), Vector2(r.size.x + t * 2, t), COIN)
	_rect(Vector2(r.position.x - t, r.position.y), Vector2(t, r.size.y), COIN)
	_rect(Vector2(r.end.x, r.position.y), Vector2(t, r.size.y), COIN)

func _draw_portraits(b: Dictionary) -> void:
	var who: String = str(b.get("who", ""))
	var side: String = str(b.get("side", "left"))
	var art: String = str(b.get("art", ""))

	if who == "":
		# Narration: no tab, art fills the whole band.
		_rect(Vector2(24, 104), Vector2(672, 360), SLAB_NEUTRAL)
		if art != "":
			_emoji(Vector2(360, 284), Vector2(300, 200), 150).text = art
		return

	var spk: Dictionary = _who(who)
	var spk_left: bool = side == "left"
	var other: Dictionary = _who(str(b.get("other", "belzenlok" if not spk_left else "@us")))

	var lx := 26.0
	var rx := 394.0
	var lit_x: float = lx if spk_left else rx
	var dim_x: float = rx if spk_left else lx
	# The beat's own emoji wins over the cast default, so a character can change expression.
	var lit_art: String = art if art != "" else str(spk["art"])

	# Listener first, so the lit slab's shadow would sit over it if one is added later.
	_rect(Vector2(dim_x, 128), Vector2(300, 308), SLAB_NEUTRAL)
	_emoji(Vector2(dim_x + 150, 246), Vector2(300, 130), 104, 0.42).text = str(other["art"])
	_label(str(other["name"]), Vector2(dim_x, 382), Vector2(300, 28), F_NAME - 1, FG_DIM, true)

	# Active slab: taller, 16px forward, and spined in its own metal on the OUTER edge.
	# No name label here on purpose — the tab below already names the speaker, and printing it
	# twice reads as a bug.
	_rect(Vector2(lit_x, 112), Vector2(300, 340), SLAB_HELL if spk_left else SLAB_OURS)
	_rect(Vector2(lit_x if spk_left else lit_x + 294, 112), Vector2(6, 340), spk["metal"])
	_emoji(Vector2(lit_x + 150, 274), Vector2(300, 190), 150).text = lit_art

func _draw_writ(b: Dictionary, y: float, has_focus: bool) -> void:
	var who: String = str(b.get("who", ""))
	var side: String = str(b.get("side", "left"))

	# During a focus beat he is a voice over a spreadsheet, not a body in the room — so he rides the
	# tab row rather than the portrait band. Centred, he would land on whatever is being pointed at.
	if has_focus:
		_emoji(Vector2(646, y - 48), Vector2(96, 96), 62, 0.6).text = str(b.get("art", "😈"))

	if who != "":
		var spk: Dictionary = _who(who)
		var nm: String = str(spk["name"]).to_upper()
		var tw: float = clampf(float(nm.length()) * 15.0 + 60.0, 160.0, 300.0)
		var tx: float = 44.0 if (side == "left" or has_focus) else (W - 44.0 - tw)
		var tabcol: Color = HELL if not bool(spk["is_us"]) else GOLD_TAB
		_rect(Vector2(tx, y - 36), Vector2(tw, 48), tabcol)
		_label(nm, Vector2(tx, y - 36), Vector2(tw, 48), F_TAB, Color(0.965, 0.894, 0.769), true)

	_rect(Vector2(24, y), Vector2(672, 300), PARCH_EDGE)
	_rect(Vector2(25, y + 1), Vector2(670, 298), PARCH)

	var prev: String = str(b.get("prev", ""))
	var ty := y + 26.0
	if prev != "":
		# Recency fade — the prior line stays at 55% above a hairline. Replaces a scrollback log,
		# and in co-op it is what protects a reader whose neighbour is faster.
		var pl := _label(prev, Vector2(54, ty), Vector2(612, 60), F_ASIDE, INK_SOFT)
		pl.modulate = Color(1, 1, 1, 0.55)
		ty += 58.0
		_rect(Vector2(54, ty - 10), Vector2(612, 1), Color(0.353, 0.298, 0.204, 0.35))
		ty += 8.0
	_label(str(b.get("body", "")), Vector2(54, ty), Vector2(612, 200), F_PROSE, INK)
	var aside: String = str(b.get("aside", ""))
	if aside != "":
		_label(aside, Vector2(54, y + 300.0 - 76.0), Vector2(612, 66), F_ASIDE, INK_SOFT)

func _draw_continue(b: Dictionary, y: float, i: int) -> void:
	_cont_btn = Button.new()
	_cont_btn.text = "Continue  ▾"
	_cont_btn.add_theme_font_size_override("font_size", F_CONT)
	_cont_btn.position = Vector2(36, y)
	_cont_btn.size = Vector2(648, 88)
	_cont_btn.pressed.connect(_on_continue)
	_layer.add_child(_cont_btn)

	_label("beat %d of %d" % [i + 1, _beats.size()], Vector2(36, y + 96), Vector2(648, 26), F_STEP, FG_DIM, true)

	var hold: float = float(b.get("hold_ms", 0)) / 1000.0
	var auto: float = float(b.get("auto_ms", 0)) / 1000.0
	_hold_left = hold
	_auto_left = auto
	_armed = hold <= 0.0
	_cont_btn.disabled = not _armed
	_cont_btn.modulate = Color(1, 1, 1, 1.0 if _armed else 0.45)
	if auto > 0.0:
		# An auto-advancing beat is not tappable — the cut-off has to land on time.
		_cont_btn.visible = false
		_armed = false

extends Control
## Reusable hand card asset: type-tinted frame, cost orb, emoji, generated body
## (live numbers), Slay-the-Spire hover-lift + fan rotation, and a hover tooltip
## (rules + plain-language explainer, per spec §13).

signal clicked(card)

const Db := preload("res://scripts/combat/card_db.gd")
const SIZE := Vector2(130, 188)

var index: int = -1
var uid: String = ""
var playable: bool = true
var _base_pos: Vector2 = Vector2.ZERO
var _base_rot: float = 0.0
var _hover: bool = false
var _selected: bool = false

var _sb: StyleBoxFlat
var _cost_sb: StyleBoxFlat
var _emoji: Label
var _cost: Label
var _name: Label
var _body: Label
var _tip_panel: Panel
var _tip_label: Label

func _ready() -> void:
	size = SIZE
	pivot_offset = Vector2(SIZE.x * 0.5, SIZE.y)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	mouse_entered.connect(_on_enter)
	mouse_exited.connect(_on_exit)
	gui_input.connect(_on_gui)

func _build() -> void:
	var frame := Panel.new()
	frame.size = SIZE
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frame)
	_sb = StyleBoxFlat.new()
	_sb.bg_color = Color(0.13, 0.26, 0.42)
	_sb.set_corner_radius_all(12)
	_sb.set_border_width_all(2)
	_sb.border_color = Color(1, 1, 1, 0.22)
	frame.add_theme_stylebox_override("panel", _sb)

	var orb := Panel.new()
	orb.size = Vector2(34, 34)
	orb.position = Vector2(6, 6)
	orb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(orb)
	_cost_sb = StyleBoxFlat.new()
	_cost_sb.bg_color = Color(0.96, 0.84, 0.25)
	_cost_sb.set_corner_radius_all(17)
	orb.add_theme_stylebox_override("panel", _cost_sb)
	_cost = _mk(34, HORIZONTAL_ALIGNMENT_CENTER)
	_cost.add_theme_color_override("font_color", Color(0.12, 0.10, 0.05))
	_cost.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cost.size = Vector2(34, 34)
	_cost.position = Vector2(6, 6)
	add_child(_cost)

	_emoji = _mk(44, HORIZONTAL_ALIGNMENT_CENTER)
	_emoji.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_emoji.size = Vector2(SIZE.x, 58)
	_emoji.position = Vector2(0, 24)
	add_child(_emoji)

	_name = _mk(15, HORIZONTAL_ALIGNMENT_CENTER)
	_name.size = Vector2(SIZE.x - 8, 22)
	_name.position = Vector2(4, 88)
	add_child(_name)

	_body = _mk(12, HORIZONTAL_ALIGNMENT_CENTER)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.size = Vector2(SIZE.x - 12, 74)
	_body.position = Vector2(6, 112)
	add_child(_body)

	_tip_panel = Panel.new()
	_tip_panel.size = Vector2(236, 110)
	_tip_panel.position = Vector2((SIZE.x - 236) * 0.5, -118)
	_tip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_panel.visible = false
	var tsb := StyleBoxFlat.new()
	tsb.bg_color = Color(0.05, 0.05, 0.08, 0.97)
	tsb.set_corner_radius_all(8)
	tsb.set_border_width_all(1)
	tsb.border_color = Color(1, 1, 1, 0.30)
	_tip_panel.add_theme_stylebox_override("panel", tsb)
	add_child(_tip_panel)
	_tip_label = Label.new()
	_tip_label.add_theme_font_size_override("font_size", 12)
	_tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_label.position = Vector2(8, 6)
	_tip_label.size = Vector2(220, 98)
	_tip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_panel.add_child(_tip_label)

func _mk(font: int, halign: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font)
	l.horizontal_alignment = halign
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

## face = Db.describe(def, ch, party_buff); tip = def["tip"] explainer.
func setup(def: Dictionary, face: Dictionary, is_playable: bool, is_selected: bool, tip: String, on_cooldown: bool) -> void:
	playable = is_playable
	_selected = is_selected
	var t: String = def.get("type", "skill")
	_cost.text = str(def["cost"])
	_emoji.text = def["emoji"]
	_name.text = ("⏳ " if on_cooldown else "") + def["name"]
	_body.text = face["text"]
	_body.add_theme_color_override(
		"font_color", Color(0.45, 1.0, 0.5) if face["buffed"] else Color(0.9, 0.92, 0.96))
	var tint: Color = Db.type_tint(t)
	_sb.bg_color = tint if is_playable else tint.darkened(0.5)
	_sb.border_color = Color(1.0, 0.95, 0.45) if is_selected else Color(1, 1, 1, 0.22)
	_sb.set_border_width_all(4 if is_selected else 2)
	modulate = Color.WHITE if is_playable else Color(0.7, 0.7, 0.78)
	_tip_label.text = (face["text"] + "\n— " + tip) if tip != "" else face["text"]
	_tip_panel.visible = is_selected or _hover

func set_slot(pos: Vector2, rot: float) -> void:
	_base_pos = pos
	_base_rot = rot
	if not _hover:
		position = pos
		rotation = rot

func _on_enter() -> void:
	_hover = true
	z_index = 100
	_tip_panel.visible = true
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "position", _base_pos + Vector2(0, -46), 0.12)
	tw.tween_property(self, "rotation", 0.0, 0.12)
	tw.tween_property(self, "scale", Vector2(1.18, 1.18), 0.12)

func _on_exit() -> void:
	_hover = false
	z_index = 0
	_tip_panel.visible = _selected
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "position", _base_pos, 0.12)
	tw.tween_property(self, "rotation", _base_rot, 0.12)
	tw.tween_property(self, "scale", Vector2.ONE, 0.12)

func _on_gui(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit(self)

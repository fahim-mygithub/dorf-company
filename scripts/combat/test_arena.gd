extends Node2D

## Test-arena driver for the VFX pipeline slices.
##
## Triggers (hold for a sustained effect; quick tap for a brief one):
##  - SPACE            -> hit-flash only
##  - LEFT MOUSE       -> full Warrior impact: hit-flash + mid Momentum burst
##  - 1 / 2 / 3        -> Momentum burst at low / mid / high (2 / 6 / 10)
##
## flash() is the REAL combat pulse (0->1->0, ~0.15s) for a damage signal.
## Momentum level changes are edge-detected so `amount` is set ONCE per change
## (reassigning GPUParticles2D.amount every frame thrashes the buffer -> nothing renders).
## Demo emission is CONTINUOUS while held so the lagged capture reliably catches it;
## the saved momentum_hit asset is a one_shot burst for real combat.

@onready var dwarf: Sprite2D = $Dwarf
@onready var momentum_hit: Node2D = $MomentumHit

var _demo_level: int = -1

func _process(_delta: float) -> void:
	var lmb: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

	# --- Hit flash: hold SPACE or LEFT MOUSE ---
	var mat: ShaderMaterial = dwarf.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("flash", 1.0 if (Input.is_key_pressed(KEY_SPACE) or lmb) else 0.0)

	# --- Momentum burst: 1/2/3, or LEFT MOUSE for mid (edge-detected) ---
	var level: int = 0
	if Input.is_key_pressed(KEY_1):
		level = 2
	elif Input.is_key_pressed(KEY_2):
		level = 6
	elif Input.is_key_pressed(KEY_3):
		level = 10
	elif lmb:
		level = 6
	if level != _demo_level:
		_demo_level = level
		var sparks: GPUParticles2D = momentum_hit.get_node_or_null("Sparks")
		if sparks != null:
			if level > 0:
				momentum_hit.set_momentum(level)  # sets amount once
				sparks.one_shot = false           # demo: sustained spray for capture
				sparks.emitting = true
				sparks.restart()
			else:
				sparks.emitting = false

## Real-combat hit flash: white pulse on damage. Drive `flash` 0->1->0 (~0.15s).
func flash() -> void:
	var mat: ShaderMaterial = dwarf.material as ShaderMaterial
	if mat == null:
		push_warning("Dwarf has no ShaderMaterial; cannot flash")
		return
	mat.set_shader_parameter("flash", 0.0)
	var t: Tween = create_tween()
	t.tween_property(mat, "shader_parameter/flash", 1.0, 0.05)
	t.tween_property(mat, "shader_parameter/flash", 0.0, 0.10)

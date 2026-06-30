extends Node2D

## Warrior Momentum impact burst (dorf-vfx Warrior identity: impact-driven,
## grounded, kinetic). Spark count scales with `momentum` (1-10) so a high-Momentum
## hit visibly hits harder. Reusable: instance on a target, set_momentum(n), burst(),
## then queue_free() once finished.

@export_range(1, 10) var momentum: int = 1

## Sparks per Momentum stack. amount = momentum * this (min 1 particle).
const AMOUNT_PER_STACK: int = 20

func _ready() -> void:
	_apply_momentum()

## Set Momentum level and rescale the spark count.
func set_momentum(value: int) -> void:
	momentum = clampi(value, 1, 10)
	_apply_momentum()

func _apply_momentum() -> void:
	var sparks: GPUParticles2D = get_node_or_null("Sparks")
	if sparks == null:
		return
	sparks.amount = maxi(1, momentum * AMOUNT_PER_STACK)

## Fire a one-shot impact burst at the current Momentum level.
func burst() -> void:
	var sparks: GPUParticles2D = get_node_or_null("Sparks")
	if sparks == null:
		return
	sparks.restart()
	sparks.emitting = true

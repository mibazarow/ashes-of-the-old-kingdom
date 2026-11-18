class_name SpikeTrap
extends Area2D
## Telegraphed trap: the plate flashes for `telegraph_time`, then the hitbox
## opens for `active_time`. Never damages without the warning phase.

@export var telegraph_time: float = 0.55
@export var active_time: float = 0.18
@export var cooldown: float = 1.6
@export var damage: int = 12

@onready var visual: ColorRect = $Visual
@onready var hitbox: CollisionShape2D = $CollisionShape2D

var _timer := 0.0
var _phase := 0  # 0 idle, 1 telegraph, 2 active, 3 cooldown
var _hit_id := ""
var _swing := 0


func _ready() -> void:
	hitbox.disabled = true
	visual.color = Color(0.45, 0.3, 0.2, 0.35)
	_timer = cooldown * 0.5


func _physics_process(delta: float) -> void:
	_timer -= delta
	match _phase:
		0:
			if _timer <= 0.0:
				_phase = 1
				_timer = telegraph_time
				_swing += 1
				_hit_id = DamageResolver.make_hit_id(get_instance_id(), _swing)
		1:
			var t := 1.0 - clampf(_timer / telegraph_time, 0.0, 1.0)
			visual.color = Color(1.0, 0.35, 0.2, 0.25 + 0.5 * t)
			if _timer <= 0.0:
				_phase = 2
				_timer = active_time
				hitbox.disabled = false
				visual.color = Color(1.0, 0.2, 0.15, 0.8)
				_apply_hits()
		2:
			if _timer <= 0.0:
				hitbox.disabled = true
				_phase = 3
				_timer = cooldown
				visual.color = Color(0.45, 0.3, 0.2, 0.35)
		3:
			if _timer <= 0.0:
				_phase = 0


func _apply_hits() -> void:
	for body in get_overlapping_bodies():
		if body.has_method("receive_damage"):
			DamageResolver.resolve_hit(self, body, {
				"damage": damage,
				"hit_id": _hit_id,
				"damage_type": "trap",
			})

class_name SpellProjectile
extends Area2D
## Player-cast straight-flying spell (spec §9).
##
## Kept separate from the enemy Projectile on purpose: that class has a fixed
## SPEED/LIFETIME, a physical damage type and a mask that hits the player, and
## the bots depend on it staying byte-identical. A spell instead carries a full
## per-cast payload (damage, status, status_duration, hit_id, shooter, speed,
## range), uses a mask that hits walls and enemies but never the caster, and
## despawns by travelled distance rather than by lifetime.

var direction: Vector2 = Vector2.RIGHT
var damage: int = 0
var status: String = ""
var status_duration: float = 0.0
var hit_id: String = ""
var damage_type: String = "spell"
var speed: float = 260.0
var max_range: float = 260.0
var shooter: Node = null

var _travelled := 0.0
var _spent := false


## payload keys: direction, damage, status, status_duration, hit_id,
## damage_type, speed, range, shooter.
func setup(payload: Dictionary) -> void:
	direction = (payload.get("direction", Vector2.RIGHT) as Vector2).normalized()
	damage = int(payload.get("damage", 0))
	status = String(payload.get("status", ""))
	status_duration = float(payload.get("status_duration", 0.0))
	hit_id = String(payload.get("hit_id", ""))
	damage_type = String(payload.get("damage_type", "spell"))
	speed = float(payload.get("speed", 260.0))
	max_range = float(payload.get("range", 260.0))
	shooter = payload.get("shooter")


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	rotation = direction.angle()


func _physics_process(delta: float) -> void:
	var step := direction * speed * delta
	global_position += step
	_travelled += step.length()
	if _travelled >= max_range:
		queue_free()


func _on_body_entered(body: Node) -> void:
	if _spent or body == null or body == shooter:
		return
	_spent = true
	if body.has_method("receive_damage"):
		var payload := {
			"damage": damage,
			"hit_id": hit_id,
			"damage_type": damage_type,
		}
		if status != "":
			payload["status"] = status
			payload["status_duration"] = status_duration
		DamageResolver.resolve_hit(shooter, body, payload)
	# Anything without receive_damage (walls, trees) absorbs the spell.
	queue_free()

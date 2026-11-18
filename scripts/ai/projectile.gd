class_name Projectile
extends Area2D
## Simple straight-flying enemy projectile with a lifetime and wall collision.

const SPEED := 150.0
const LIFETIME := 2.2

var direction: Vector2 = Vector2.RIGHT
var damage: int = 6
var shooter: Node = null
var _life := 0.0
var _spent := false


func setup(dir: Vector2, dmg: int, from: Node) -> void:
	direction = dir.normalized()
	damage = dmg
	shooter = from


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	rotation = direction.angle()


func _physics_process(delta: float) -> void:
	_life += delta
	if _life >= LIFETIME:
		queue_free()
		return
	global_position += direction * SPEED * delta


func _on_body_entered(body: Node) -> void:
	if _spent or body == null or body == shooter:
		return
	_spent = true
	if body.has_method("receive_damage"):
		DamageResolver.resolve_hit(shooter, body, {
			"damage": damage,
			"hit_id": DamageResolver.make_hit_id(get_instance_id(), 1),
			"damage_type": "physical",
		})
	# Anything without receive_damage (walls, trees, any solid body) absorbs
	# the projectile without taking damage.
	queue_free()

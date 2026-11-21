class_name InfectedNode
extends StaticBody2D
## A destructible weak point the Root Mother grows in its second phase (spec §11).
##
## The Root Mother does not simply become a bigger wolf below half health: it puts
## two living nodes into the ground and only weakens once both are cut down. This
## node is one of those nodes. It is deliberately not an `Enemy` — it never walks,
## never swings, never joins the `enemy` group and never pays XP or gold on death.
## It is a solid obstacle with a health pool that, once emptied, marks itself
## destroyed on `GameState`, announces itself on the toast line and tells the boss
## that grew it through the `destroyed` signal.
##
## The health pool is a real `HealthComponent` child built here in code rather than
## edited into a scene, so the node is one self-contained script with no .tscn to
## keep in step, and so `DamageResolver` reaches it through the same
## `receive_damage` / `get_defense` / `is_status_owner_dead` contract every other
## combatant satisfies.

## World movement layer (bit 1). The node is solid like a wall: the player and the
## enemies cannot walk through it.
const SOLID_LAYER := 1
## Enemy-hittable layer (bit 4). The player's melee hitbox listens on this layer,
## so a weak point the player could not actually strike would not be a weak point.
## The node is therefore solid on the world layer AND targetable on the combat
## layer; a test reads the solidity bit (`& 1`) rather than the exact number.
const HITTABLE_LAYER := 4

signal destroyed(node_id: String)

@export var node_id: String = ""
@export var max_health: int = 40

var health: HealthComponent


func _ready() -> void:
	add_to_group("infected_node")
	collision_layer = SOLID_LAYER | HITTABLE_LAYER
	collision_mask = 0

	var shape := RectangleShape2D.new()
	shape.size = Vector2(12, 12)
	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	collision.shape = shape
	add_child(collision)

	# The pool is handed its size before it enters the tree, because
	# HealthComponent._ready() seeds current_health from max_health the frame it is
	# added, and by then this node's own export must already be on it.
	health = HealthComponent.new()
	health.name = "HealthComponent"
	health.max_health = max_health
	add_child(health)
	health.died.connect(_on_died)


func receive_damage(amount: int, info: Dictionary = {}) -> void:
	if health != null:
		health.take_damage(amount, info)


func get_defense() -> int:
	return 0


func is_status_owner_dead() -> bool:
	return health != null and health.is_dead


func _on_died(_info: Dictionary) -> void:
	GameState.set_flag("infected_node_%s_destroyed" % node_id, true)
	EventBus.toast.emit("Узел уничтожен")
	destroyed.emit(node_id)
	queue_free()

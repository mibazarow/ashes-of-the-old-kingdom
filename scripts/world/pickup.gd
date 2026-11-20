class_name Pickup
extends Area2D
## Ground loot that is collected by touching it.

@export var item_id: String = "health_potion"
@export var amount: int = 1
@export var gold: int = 0

var _taken := false


func _ready() -> void:
	add_to_group("pickup")
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if _taken or not body.is_in_group("player"):
		return
	_taken = true
	if item_id != "":
		GameState.add_item(item_id, amount)
	if gold > 0:
		GameState.add_gold(gold)
	EventBus.toast.emit("+ %s" % ItemDB.display_name(item_id) if item_id != "" else "+%d золота" % gold)
	# No existing signal describes "loot left the ground" (`item_picked` also
	# fires for shop and craft results, where no sound is wanted), so the pickup
	# asks for its own cue and stays ignorant of whether anything listens.
	EventBus.sfx_requested.emit("pickup", "SFX")
	queue_free()

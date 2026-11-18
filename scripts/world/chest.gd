class_name Chest
extends Area2D
## One-shot loot container. Opened state is stored in GameState flags so a
## reload cannot hand out the same loot twice.

@export var chest_id: String = "chest_forest_01"
@export var item_id: String = "iron_sword"
@export var gold: int = 25

@onready var sprite: Sprite2D = $Sprite2D


func _ready() -> void:
	add_to_group("interactable")
	if bool(GameState.get_flag(_flag(), false)):
		sprite.modulate = Color(0.55, 0.55, 0.55)


func _flag() -> String:
	return "chest_opened_" + chest_id


func prompt_text() -> String:
	if bool(GameState.get_flag(_flag(), false)):
		return "Пустой сундук"
	return "Открыть сундук"


func interact(_player: Node) -> void:
	if bool(GameState.get_flag(_flag(), false)):
		EventBus.toast.emit("Сундук уже пуст")
		return
	GameState.set_flag(_flag(), true)
	sprite.modulate = Color(0.55, 0.55, 0.55)
	if item_id != "":
		GameState.add_item(item_id, 1)
	if gold > 0:
		GameState.add_gold(gold)
	EventBus.toast.emit("Сундук: %s" % ItemDB.display_name(item_id))
	Telemetry.event(&"chest_opened", {"chest_id": chest_id, "item": item_id, "gold": gold})

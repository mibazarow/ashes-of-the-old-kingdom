class_name Merchant
extends Area2D
## Shop NPC. Unlike the quest-giver `Npc` it holds no quest state: interacting
## opens the buy/sell screen on the HUD. The merchant owns the one `ShopManager`
## for its stock, so what the player buys is drawn from a single live pool that
## persists for the merchant's lifetime — buying lowers it, selling never refills
## it. Built entirely in code (no scene) so it reuses the shared npc sprite with a
## distinct tint and adds itself to the `interactable` group exactly like Edrik.

@export var display_name: String = "Йорек"
@export var sprite_texture: Texture2D

var _shop: ShopManager


func _ready() -> void:
	add_to_group("interactable")
	# Same interact layer as Edrik (layer 32, monitors nothing): the player finds
	# merchants through the group scan, not through physics contacts.
	collision_layer = 32
	collision_mask = 0

	var sprite := Sprite2D.new()
	if sprite_texture != null:
		sprite.texture = sprite_texture
	# A cool tint keeps the merchant visually distinct from the warm quest-giver
	# while reusing the one placeholder sprite.
	sprite.modulate = Color(0.62, 0.86, 1.0)
	add_child(sprite)

	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 8.0
	shape.shape = circle
	add_child(shape)

	var tag := Label.new()
	tag.text = "$"
	tag.add_theme_color_override("font_color", Color(0.98, 0.85, 0.3))
	tag.add_theme_font_size_override("font_size", 8)
	tag.position = Vector2(-2, -24)
	add_child(tag)

	# The injected state is the live GameState autoload; ShopManager reads prices
	# from ItemDB and never touches an autoload by name itself.
	_shop = ShopManager.new(GameState)


func prompt_text() -> String:
	return "Торговать"


func interact(_player: Node) -> void:
	# No shop signal exists on the (non-editable) EventBus, so the merchant hands
	# its manager straight to the HUD, which is the only thing that can open a
	# modal panel. Found by group so neither side hardcodes the other's path.
	var hud := get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("open_shop"):
		hud.call("open_shop", _shop)

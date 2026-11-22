class_name Smith
extends Area2D
## Crafting station NPC (spec §14.4). Same shape as `Merchant`: it holds no quest
## state, the first interaction runs `bran_intro` (which sets `met_bran`), and
## every interaction after that opens the craft screen on the HUD.
##
## The smith owns the one `CraftManager` for its station, built over the live
## `GameState`, so the recipes, the prices and the unlock flags it shows are the
## player's real ones — and a test can build the same manager over a throwaway
## state. Built entirely in code (no scene) so it reuses the shared npc sprite with
## a distinct tint and joins the `interactable` group exactly like Edrik and Yorek.

@export var display_name: String = "Кузнец Бран"
@export var sprite_texture: Texture2D
@export var station: String = "smith"

var _craft: CraftManager


func _ready() -> void:
	add_to_group("interactable")
	# Same interact layer as the other NPCs (layer 32, monitors nothing): the
	# player finds the smith through the group scan, not through physics contacts.
	collision_layer = 32
	collision_mask = 0

	var sprite := Sprite2D.new()
	if sprite_texture != null:
		sprite.texture = sprite_texture
	# A hot forge tint, deliberately the opposite of the merchant's cool blue, so
	# the two village NPCs read apart while sharing the one placeholder sprite.
	sprite.modulate = Color(1.0, 0.66, 0.42)
	add_child(sprite)

	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 8.0
	shape.shape = circle
	add_child(shape)

	# A blade rather than the merchant's coin: the glyph is the one the item table
	# already uses for a sword, so the HUD font is known to carry it.
	var tag := Label.new()
	tag.text = "†"
	tag.add_theme_color_override("font_color", Color(0.86, 0.9, 0.96))
	tag.add_theme_font_size_override("font_size", 8)
	tag.position = Vector2(-2, -24)
	add_child(tag)

	_craft = CraftManager.new(GameState, station)


func prompt_text() -> String:
	return "Ремесло"


## The station this NPC runs, so the HUD and a test can ask instead of assuming
## that every smith is the blacksmith.
func craft_station() -> String:
	return station


func interact(_player: Node) -> void:
	# The smith greets the player once before the bench opens, on the same
	# dialogue-runner-first pattern the quest-giver `Npc` uses. `bran_intro` is
	# gated on `not_flag: met_bran` in data/dialogue.json and its last line sets
	# that flag, so the runner refuses on every later meeting and the bench opens
	# straight away — the panel is never left unreachable behind a greeting.
	var hud := get_tree().get_first_node_in_group("hud")
	var runner := DialogueRunner.new(GameState, QuestManager)
	if runner.start("bran_intro"):
		if hud != null and hud.has_method("open_dialogue_runner"):
			hud.open_dialogue_runner(runner)
			return

	# Fallback: the greeting was already heard (the runner refused on its
	# condition), or there is no HUD to show it. Either way the craft screen must
	# still open. No craft signal exists on the (non-editable) EventBus, so the
	# smith hands its manager straight to the HUD, found by group, exactly like the
	# merchant hands over the shop. Opening must not craft anything: the panel only
	# acts on E.
	if hud != null and hud.has_method("open_craft"):
		hud.call("open_craft", _craft)

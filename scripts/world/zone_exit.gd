class_name ZoneExit
extends Area2D
## A door to another zone. It is an `interactable`, exactly like a chest or an
## NPC — nothing more: it owns no overlap handler, so walking across it does
## nothing. Travel happens only on the explicit interact key, which is what keeps
## a bot walking its route from leaving the map by accident.

## Zone id from `data/zones.json` this exit leads to. Empty means inert, and a
## travel the manager refuses (unknown id, already standing there) is simply a
## no-op rather than an error.
@export var target_zone: String = ""
## The line the HUD shows as `[E] <prompt>` while the player stands in reach.
@export var prompt: String = "Войти"

const COLOR_FILL := Color(0.20, 0.19, 0.24, 0.95)
const COLOR_EDGE := Color(0.62, 0.58, 0.72, 0.95)
const COLOR_INNER := Color(0.36, 0.33, 0.44, 0.95)


func _ready() -> void:
	add_to_group("interactable")
	# The interactable physics layer, and no mask at all: the exit reports no
	# overlap to anything, because nothing in the project masks this layer. The
	# shape is here so the area is a real area, not a trigger.
	collision_layer = 32
	collision_mask = 0
	var shape := CircleShape2D.new()
	shape.radius = 9.0
	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	collision.shape = shape
	add_child(collision)


func prompt_text() -> String:
	return prompt


func interact(_player: Node) -> void:
	if target_zone == "":
		return
	var manager := get_tree().get_first_node_in_group(ZoneManager.GROUP)
	if manager == null or not manager.has_method("travel"):
		EventBus.toast.emit("Отсюда пока никуда не уйти")
		return
	# Deferred on purpose. Travel frees the world this node and the calling player
	# are both standing in, and doing that from inside the player's own `_process`
	# would free the object running the call. At the end of the frame neither is
	# on the stack any more, and the world can go immediately instead of lingering
	# a frame as a queued free would.
	manager.call_deferred("travel", target_zone)


## A plain stone arch, drawn rather than textured: the slice has no gate sprite,
## and a generated placeholder is easier to replace with real art than a node
## wired into a scene file would be.
func _draw() -> void:
	var opening := Rect2(-6, -13, 12, 15)
	draw_rect(opening, COLOR_FILL)
	draw_rect(Rect2(-4, -11, 8, 13), COLOR_INNER)
	draw_rect(opening, COLOR_EDGE, false, 1.0)

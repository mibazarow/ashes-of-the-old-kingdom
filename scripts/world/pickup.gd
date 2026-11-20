class_name Pickup
extends Area2D
## Ground loot that is collected by touching it.

@export var item_id: String = "health_potion"
@export var amount: int = 1
@export var gold: int = 0
## A named find that must not come back once it is in the bag. A zone is freed and
## rebuilt on every travel, so a one-off item (the ruins key) would otherwise lie
## on the ground again each time the player walks back in. An empty flag — every
## ordinary ground loot — keeps the old behaviour: the find respawns with the zone.
@export var taken_flag: String = ""

var _taken := false


func _ready() -> void:
	# A rebuilt zone must not show a find that was already collected: the node
	# removes itself before it joins the group or listens for a body, so it is
	# neither a landmark nor a walk-over target for the frame it would otherwise
	# have existed.
	if taken_flag != "" and bool(_game_state().get_flag(taken_flag, false)):
		queue_free()
		return
	add_to_group("pickup")
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if _taken or not body.is_in_group("player"):
		return
	_taken = true
	if item_id != "":
		_game_state().add_item(item_id, amount)
	if gold > 0:
		_game_state().add_gold(gold)
	# Recorded before the free so a rebuild of this zone reads the flag and leaves
	# the find off the ground.
	if taken_flag != "":
		_game_state().set_flag(taken_flag, true)
	_event_bus().toast.emit("+ %s" % ItemDB.display_name(item_id) if item_id != "" else "+%d золота" % gold)
	# No existing signal describes "loot left the ground" (`item_picked` also
	# fires for shop and craft results, where no sound is wanted), so the pickup
	# asks for its own cue and stays ignorant of whether anything listens.
	_event_bus().sfx_requested.emit("pickup", "SFX")
	queue_free()


## The GameState and EventBus singletons, resolved through the scene tree rather
## than by their bare autoload names. This script is also loaded headless under
## `--script` (the acceptance suite builds a zone that spawns pickups), and that mode
## does not register autoload names as compile-time globals — referencing `GameState`
## or `EventBus` by name fails to compile, exactly the dependency the test core
## documents avoiding for the audio settings at tests/test_core.gd. `ItemDB` is a real
## `class_name`, so it stays a direct reference. Resolving `/root/...` yields the same
## singletons in both modes, so an ordinary ground find with an empty `taken_flag`
## adds its item, announces itself and frees itself precisely as before; only the
## path to the node differs.
func _game_state() -> Node:
	return get_node("/root/GameState")


func _event_bus() -> Node:
	return get_node("/root/EventBus")

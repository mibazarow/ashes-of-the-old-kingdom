class_name Mechanism
extends Area2D
## A wall mechanism that spends an item to raise a world flag — here, the key
## that opens the door of the ruins.
##
## It is the counterpart of `RuinDoor` and the two never name each other. The
## mechanism owns `sets_flag`, the door owns `open_flag`, and the shared string is
## the whole contract: `interact()` walks the `ruin_door` group and opens every
## door whose flag matches, so a door can be moved, renamed or duplicated without
## this script learning a node path, and a mechanism wired to a flag nothing
## listens to is simply a lever that does nothing to the world.
##
## The item is spent before the flag is raised, and the refusal paths write
## nothing at all: no key, no flag, no toast other than the reason. That ordering
## is what makes "the mechanism ate my key and nothing happened" impossible.
##
## Autoloads are resolved through the main loop rather than named, for the reason
## `Breakable` and `RuinDoor` spell out — this class is reached by `class_name`
## from the headless suite, where those identifiers are not registered.

signal triggered(mechanism_id: String)

@export var mechanism_id: String = "ruin_mechanism"
## Item id the mechanism takes out of the inventory. Empty means it asks for
## nothing and only raises the flag.
@export var requires_item: String = "ruin_key"
## The `GameState` flag this lever raises, and the name a `RuinDoor` answers to.
@export var sets_flag: String = "ruin_door_open"
## Whether the item is spent. A mechanism that stays usable — a lift, a bridge
## that can be called back — sets this to false and keeps the item in the bag.
@export var consumed: bool = true

const COLOR_FRAME := Color(0.18, 0.18, 0.20)
const COLOR_PLATE := Color(0.36, 0.34, 0.31)
const COLOR_SLOT := Color(0.10, 0.10, 0.12)
const COLOR_LEVER := Color(0.78, 0.66, 0.34)
const COLOR_LEVER_SET := Color(0.42, 0.72, 0.66)

## What the drawing last showed, so `_process` redraws on a change instead of
## every frame.
var _drawn_set := false


func _ready() -> void:
	add_to_group("interactable")
	add_to_group("mechanism")
	# The interactable layer with no mask, exactly like `ZoneExit`: the lever
	# reports no overlap to anything, because nothing in the project masks this
	# layer. The shape exists so the area is a real area, not a trigger.
	collision_layer = 32
	collision_mask = 0
	var shape := CircleShape2D.new()
	shape.radius = 9.0
	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	collision.shape = shape
	add_child(collision)
	_drawn_set = _is_set()


func _process(_delta: float) -> void:
	# The flag is world state, and a same-zone load replaces it without rebuilding
	# the zone (`travel` refuses the zone already stood in), so the lever watches it
	# rather than trusting that it was the one that last wrote it.
	var now_set := _is_set()
	if now_set == _drawn_set:
		return
	_drawn_set = now_set
	queue_redraw()


func _is_set() -> bool:
	var state := _autoload("GameState")
	return state != null and bool(state.call("get_flag", sets_flag, false))


func prompt_text() -> String:
	return "Рычаг опущен" if _is_set() else "Механизм"


func interact(_player: Node) -> void:
	var bus := _autoload("EventBus")
	if _is_set():
		if bus != null:
			bus.emit_signal("toast", "Уже открыто")
		return
	var state := _autoload("GameState")
	if state == null:
		return
	if requires_item != "" and int(state.call("count_item", requires_item)) <= 0:
		# The item name in the genitive case, which `ItemDB.display_name()` cannot
		# produce from the nominative it stores, so the line is written out here.
		if bus != null:
			bus.emit_signal("toast", "Нужен ржавый ключ")
		return
	if requires_item != "" and consumed:
		state.call("remove_item", requires_item, 1)
	state.call("set_flag", sets_flag, true)
	_drawn_set = true
	queue_redraw()
	if bus != null:
		bus.emit_signal("toast", "Рычаг опущен")
	_open_matching_doors()
	triggered.emit(mechanism_id)


## Opens every door in the scene that answers to this mechanism's flag. Group
## lookup, not a path: the door this lever belongs to is whichever door says so.
func _open_matching_doors() -> void:
	for node in get_tree().get_nodes_in_group("ruin_door"):
		if node.get("open_flag") == null or String(node.get("open_flag")) != sets_flag:
			continue
		if not node.has_method("open"):
			continue
		node.call("open")


## A stone bracket with a slot and a handle: the handle rides high and brass while
## the flag is down, low and cold once it is raised. Drawn rather than textured —
## the slice has no mechanism sprite.
func _draw() -> void:
	draw_rect(Rect2(-7, -8, 14, 16), COLOR_FRAME)
	draw_rect(Rect2(-5, -6, 10, 12), COLOR_PLATE)
	draw_rect(Rect2(-1, -5, 2, 10), COLOR_SLOT)
	var handle := Rect2(-3, -6, 6, 4) if not _drawn_set else Rect2(-3, 2, 6, 4)
	draw_rect(handle, COLOR_LEVER if not _drawn_set else COLOR_LEVER_SET)
	draw_rect(Rect2(-1, -1, 2, 2), COLOR_FRAME)


func _autoload(node_name: String) -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null(node_name)

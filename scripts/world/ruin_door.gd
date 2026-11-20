class_name RuinDoor
extends StaticBody2D
## A stone door that seals the doorway of the ruins until a mechanism raises its
## open flag.
##
## It is a `StaticBody2D` on the plain world layer (bit 1) rather than the
## `1 | 4` a `Breakable` carries: the door is not a combat target, and putting it
## on the enemy layer would hand the player's `AttackHitbox` (mask 4) a swingable
## wall. Layer 1 alone is what the player and every `Enemy` collide with, so one
## number here blocks both — which is the point: while the door stands, the
## skeletons stay in the hall behind it, and the ray `Enemy._player_visible()`
## casts against layer 1 is stopped by it too, so nothing on the far side can
## spot a player who has not opened it yet.
##
## The open state is a `GameState` flag, exactly like a chest's opened flag, so
## the door saves, loads and travels for free. `_ready()` applies that flag
## before the first frame, which is what makes a save with the door open spawn it
## open instead of shutting the player back in.
##
## Autoloads are resolved through the main loop rather than named, the way
## `Breakable` does it: a script reached as a `class_name` from the headless test
## suite is compiled in a pass where those identifiers are not registered, and
## this one has to compile there.

signal opened(door_id: String)

@export var door_id: String = "ruin_door"
## The `GameState` flag this door reads and raises. `Mechanism.sets_flag` names
## the same string, and that shared name — not a node path — is how the two find
## each other.
@export var open_flag: String = "ruin_door_open"
## How many tiles tall the doorway this slab stands in is. The slab fills all of
## them, because a door that only covers the tile it is placed on is a pillar, not
## a door: the player walks past it on either side and the hall behind it is open
## before anyone has solved anything. The zone owns its own geometry, so the zone
## says how tall its own opening is; one tile is the honest default for a doorway
## that is one tile wide.
@export var opening_tiles: int = 1

const COLOR_FRAME := Color(0.19, 0.19, 0.21)
const COLOR_SLAB := Color(0.40, 0.37, 0.33)
const COLOR_FACE := Color(0.50, 0.47, 0.42)
const COLOR_KEYHOLE := Color(0.11, 0.10, 0.11)
const COLOR_PASSAGE := Color(0.11, 0.12, 0.14, 0.55)
const TILE_PX := 16.0

## Half the height of the slab, in pixels: the door is one tile wide and
## `opening_tiles` tall, centred on the node, which the zone places on the middle
## row of its own doorway.
var _half_height := TILE_PX * 0.5

## Whether the collision and the drawing currently say "open". Kept apart from
## the flag so `open()` can tell a real change from a repeat call: the flag may
## already be raised by the mechanism that asked this door to open, and the door
## still has to drop its own collision the same frame.
var _open_applied := false


func _ready() -> void:
	add_to_group("interactable")
	add_to_group("ruin_door")
	collision_layer = 1
	collision_mask = 0
	_half_height = TILE_PX * 0.5 * float(maxi(1, opening_tiles))
	if get_node_or_null("CollisionShape2D") == null:
		var shape := RectangleShape2D.new()
		shape.size = Vector2(TILE_PX, _half_height * 2.0)
		var collision := CollisionShape2D.new()
		collision.name = "CollisionShape2D"
		collision.shape = shape
		add_child(collision)
	_apply_state()


## The flag is world state, and a same-zone load replaces it without rebuilding
## the zone (`travel` refuses the zone already stood in), so the body follows the
## flag instead of trusting that it was the one that last wrote it. Only the
## collision and the drawing are re-applied here — never the announcement, which
## belongs to `open()`.
func _physics_process(_delta: float) -> void:
	if is_open() != _open_applied:
		_apply_state()


## The single answer every other system asks: is this door open in the save.
func is_open() -> bool:
	var state := _autoload("GameState")
	return state != null and bool(state.call("get_flag", open_flag, false))


## Raises the flag and stops blocking, in this call, not on a free. Idempotent by
## effect and by announcement: a second call re-applies the same state, writes the
## same flag and stays silent, because the state has nothing left to change.
func open() -> void:
	var state := _autoload("GameState")
	if state != null:
		state.call("set_flag", open_flag, true)
	if not _apply_state():
		return
	var bus := _autoload("EventBus")
	if bus != null:
		bus.emit_signal("toast", "Дверь открыта")
	opened.emit(door_id)


## Pushes the flag into the body and the drawing. Returns whether that was a
## change, which is what makes `open()` announce once instead of on every call.
func _apply_state() -> bool:
	var open_now := is_open()
	_set_solid(not open_now)
	var changed := open_now != _open_applied
	_open_applied = open_now
	queue_redraw()
	return changed


## Collision off in the same frame as the flag, for the reason `Breakable` spells
## out: `queue_free` unregisters a body only at the end of the physics step, and a
## player already walking into the doorway must not bounce off a door that is no
## longer there. The shape is disabled as well as the layer cleared, so a body
## already overlapping the doorway is not pushed out by a shape that still exists.
func _set_solid(solid: bool) -> void:
	collision_layer = 1 if solid else 0
	collision_mask = 0
	var collision := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if collision != null:
		collision.disabled = not solid


func prompt_text() -> String:
	return "Открыто" if _open_applied else "Заперто"


## The door never opens itself: the mechanism across from it does. Standing here
## only tells the player what is missing.
func interact(_player: Node) -> void:
	if _open_applied:
		return
	var bus := _autoload("EventBus")
	if bus != null:
		bus.emit_signal("toast", "Нужен ключ")


## A slab in a stone frame while closed; the same frame with an empty passage once
## it is open, so the doorway still reads as a doorway rather than vanishing into
## the floor. Drawn, not textured: the slice has no door sprite, and a drawn
## placeholder is easier to replace with real art than a node wired into a scene.
## The slab is as tall as the opening it seals, with a seam at every tile boundary,
## so a five-tile door reads as masonry filling a gap rather than as one sprite
## stretched past its own proportions.
func _draw() -> void:
	var half := _half_height
	var frame := Rect2(-8.0, -half, TILE_PX, half * 2.0)
	if _open_applied:
		draw_rect(frame, COLOR_PASSAGE)
		draw_rect(Rect2(-8.0, -half, TILE_PX, 2.0), COLOR_FRAME)
		draw_rect(Rect2(-8.0, half - 2.0, TILE_PX, 2.0), COLOR_FRAME)
		return
	draw_rect(frame, COLOR_FRAME)
	draw_rect(Rect2(-7.0, -half + 1.0, 14.0, half * 2.0 - 2.0), COLOR_SLAB)
	draw_rect(Rect2(-5.0, -half + 3.0, 10.0, half * 2.0 - 6.0), COLOR_FACE)
	for i in range(1, maxi(1, opening_tiles)):
		draw_rect(Rect2(-5.0, -half + float(i) * TILE_PX - 0.5, 10.0, 1.0), COLOR_SLAB)
	# The lock stays the size of the single tile it belongs to and sits on the
	# middle row of the opening, which is the row the node itself stands on.
	draw_rect(Rect2(-1.0, -3.0, 2.0, 4.0), COLOR_KEYHOLE)
	draw_rect(Rect2(-2.0, 0.0, 4.0, 3.0), COLOR_KEYHOLE)


func _autoload(node_name: String) -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null(node_name)

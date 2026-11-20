class_name Breakable
extends StaticBody2D
## Destructible world obstacle: a rubble pile that seals a shortcut until the
## player smashes it.
##
## It is a `StaticBody2D` rather than an `Area2D` because it has to stop
## movement while it is alive, and it carries the enemy physics layer (bit 3,
## value 4) on top of the solid world layer (bit 1) so the player's ordinary
## melee reaches it. `scenes/player/player.tscn` gives `AttackHitbox`
## `collision_mask = 4`, which is exactly the layer the wolves live on, so a
## breakable on `1 | 4 = 5` is blocked by movement and hit by the sword with no
## special case anywhere: the swing still goes through `DamageResolver`, so the
## per-swing `hit_id` dedupe protects it like any other combatant.
##
## HP lives in a real `HealthComponent` child when one is present (the world
## scene has one). A bare `Breakable.new()` with no child falls back to the
## local counter below, so the class stays usable from code without a scene.

signal broken(shortcut_id: String)

const FLASH_TIME := 0.1
const FLASH_MODULATE := Color(1.8, 1.5, 1.5)

@export var max_health: int = 30
@export var display_name: String = "Завал"
## When non-empty, destroying this obstacle raises
## `shortcut_<id>_open` in GameState, which is what a later zone, quest or door
## reads. The flag is a plain GameState entry, so it saves and loads for free.
@export var blocks_shortcut_id: String = ""

var health: HealthComponent = null
var visual: ColorRect = null

var _own_health := 0
var _flash_left := 0.0
var _broke := false


func _ready() -> void:
	add_to_group("breakable")
	health = get_node_or_null("HealthComponent") as HealthComponent
	if health != null:
		# Same order the enemies use: the child's own _ready has already run, so
		# overwriting both numbers here is what actually lands.
		health.max_health = max_health
		health.current_health = max_health
	else:
		_own_health = max_health
	visual = get_node_or_null("Visual") as ColorRect


func is_broken() -> bool:
	return _broke


## HP readout for both storage paths, so a test or a future HUD never has to
## know which one this instance happens to use.
func current_health() -> int:
	return health.current_health if health != null else _own_health


func receive_damage(amount: int, info: Dictionary = {}) -> void:
	if _broke:
		return
	if health != null:
		health.take_damage(amount, info)
	else:
		_own_health = maxi(0, _own_health - maxi(0, amount))
	_flash_left = FLASH_TIME
	if visual != null:
		visual.modulate = FLASH_MODULATE
	var spent := health.is_dead if health != null else _own_health <= 0
	if spent:
		_break()


func _physics_process(delta: float) -> void:
	if _flash_left <= 0.0:
		return
	_flash_left -= delta
	if _flash_left <= 0.0 and visual != null:
		visual.modulate = Color.WHITE


func _break() -> void:
	if _broke:
		return
	_broke = true
	# Drop the collision in the same frame as the killing blow. queue_free only
	# unregisters the body at the end of the physics step, and a player already
	# walking into the pile must not bounce off a heap that is no longer there.
	collision_layer = 0
	collision_mask = 0
	if visual != null:
		visual.visible = false
	if blocks_shortcut_id != "":
		var state := _autoload("GameState")
		if state != null:
			state.call("set_flag", "shortcut_%s_open" % blocks_shortcut_id, true)
	var bus := _autoload("EventBus")
	if bus != null:
		bus.emit_signal("toast", "Проход расчищен")
	broken.emit(blocks_shortcut_id)
	queue_free()


## Autoloads are looked up through the main loop instead of named directly, the
## way DamageResolver does it. A script that names an autoload by identifier
## does not compile under `godot --script`, where those identifiers are not
## registered, and this one has to compile there: the test suite reaches for
## `Breakable` as a class, which drags it into the suite's own compile pass.
func _autoload(node_name: String) -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null(node_name)

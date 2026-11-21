class_name BossRootMother
extends Boss
## The Root Mother (spec §11): the forest's second boss, fought in the ash glade.
##
## Its phase-one mechanic is a summoning: while the player stands close it puts a
## spider into the ground every `summon_interval` seconds, never more than
## `max_minions` at once, so the fight is a crowd the player has to thin while the
## boss itself stays a slow, heavy chaser. Its phase-two mechanic is the opposite:
## below half health it stops calling help and instead roots two `InfectedNode`s
## beside itself. The base enrage still fires (it chases faster), but the boss is
## now genuinely vulnerable only once both nodes are cut down — destroying them is
## what applies the one-way `weakened` state that blunts its swing and its stride.
##
## Everything here is layered on top of `Boss` and `Enemy`; neither base script is
## touched. The summon is gated on player proximity so a world loaded with nobody
## near the glade stays clean, and so the debug bots, which never walk this far
## from the spawn, never trip it.

const SPIDER_SCENE := "res://scenes/enemies/spider.tscn"

## How often phase one puts another spider down, and how many may live at once.
@export var summon_interval: float = 4.0
@export var max_minions: int = 3
## How close the player has to stand before the Root Mother bothers to summon. The
## gate is what keeps an unengaged boss from filling the glade with spiders.
@export var summon_radius: float = 220.0
## How far from the boss a summoned spider may be placed (it is snapped to the
## nearest walkable spot inside this ring).
@export var summon_spread: float = 40.0

## How many weak points phase two grows, and how tough each one is.
@export var node_count: int = 2
@export var node_max_health: int = 40

## The weakened multipliers: the swing keeps 60 % of its number (a 40 % drop) and
## the stride keeps 75 % of its speed (a 25 % drop). Both are one-way.
@export var weakened_damage_multiplier: float = 0.6
@export var weakened_speed_multiplier: float = 0.75

var _summon_accum := 0.0
var _minions: Array[Node] = []
var _summoning_stopped := false
var _nodes: Array[Node] = []
var _destroyed_nodes := 0
var _weakened := false


func _physics_process(delta: float) -> void:
	super(delta)
	_tick_summon(delta)


func _tick_summon(delta: float) -> void:
	if _summoning_stopped or current_phase() >= 2 or state == State.DEAD:
		return
	var p := _player_ref()
	if p == null or is_status_owner_dead():
		return
	if global_position.distance_to(p.global_position) > summon_radius:
		return
	_summon_accum += delta
	if _summon_accum < summon_interval:
		return
	_summon_accum = 0.0
	_prune_minions()
	if _minions.size() >= max_minions:
		return
	_spawn_spider()


func _spawn_spider() -> void:
	var packed: PackedScene = load(SPIDER_SCENE)
	if packed == null:
		push_error("BossRootMother: cannot load %s" % SPIDER_SCENE)
		return
	var spider := packed.instantiate() as Node2D
	if spider == null:
		return
	get_parent().add_child(spider)
	spider.global_position = _find_summon_spot()
	_minions.append(spider)


## A walkable spot within `summon_spread` of the boss. With no tile grid above this
## enemy (a bare test arena) `_tile_is_solid` reads every candidate as free, so the
## first ring point is taken; in a real zone the scan steps to the first ring point
## that is not a wall or a tree.
func _find_summon_spot() -> Vector2:
	for i in range(8):
		var angle := TAU * float(i) / 8.0
		var candidate := global_position + Vector2.RIGHT.rotated(angle) * summon_spread
		if not _tile_is_solid(candidate):
			return candidate
	return global_position + Vector2(0.0, summon_spread)


func _prune_minions() -> void:
	var alive: Array[Node] = []
	for minion in _minions:
		if is_instance_valid(minion) and not _is_dead(minion):
			alive.append(minion)
	_minions = alive


func _is_dead(node: Node) -> bool:
	if node.has_method("is_status_owner_dead"):
		return bool(node.call("is_status_owner_dead"))
	var hc := node.get_node_or_null("HealthComponent") as HealthComponent
	return hc != null and hc.is_dead


func _enter_phase_two() -> void:
	super()
	_summoning_stopped = true
	_grow_nodes()


func _grow_nodes() -> void:
	for i in range(node_count):
		var node := InfectedNode.new()
		node.node_id = "%s_%d" % [String(enemy_type), i]
		node.max_health = node_max_health
		node.destroyed.connect(_on_node_destroyed)
		get_parent().add_child(node)
		node.global_position = _find_node_spot(i)
		_nodes.append(node)


## The weak points grow on either side of the boss, snapped to walkable ground the
## same way a summon is, so a node never rises inside a wall.
func _find_node_spot(index: int) -> Vector2:
	var side := -1.0 if index % 2 == 0 else 1.0
	var offset := Vector2(side * summon_spread, summon_spread * 0.5)
	var candidate := global_position + offset
	if _tile_is_solid(candidate):
		for i in range(8):
			var angle := TAU * float(i) / 8.0
			var ring := global_position + Vector2.RIGHT.rotated(angle) * summon_spread
			if not _tile_is_solid(ring):
				return ring
	return candidate


func _on_node_destroyed(_node_id: String) -> void:
	_destroyed_nodes += 1
	if _destroyed_nodes >= node_count:
		weaken()


## The one-way weakened state. Returns true the first time it is applied and false
## on every later call, so a second node reporting destroyed (or a late duplicate)
## cannot stack the blunting a second time.
func weaken() -> bool:
	if _weakened:
		return false
	_weakened = true
	attack_damage = int(round(float(attack_damage) * weakened_damage_multiplier))
	speed_multiplier *= weakened_speed_multiplier
	Telemetry.event(&"boss_weakened", {
		"enemy_type": String(enemy_type),
		"attack_damage": attack_damage,
		"speed_multiplier": speed_multiplier,
	})
	return true


func is_weakened() -> bool:
	return _weakened


func minion_count() -> int:
	_prune_minions()
	return _minions.size()


func infected_node_count() -> int:
	var alive := 0
	for node in _nodes:
		if is_instance_valid(node) and not _is_dead(node):
			alive += 1
	return alive


func _on_died(info: Dictionary) -> void:
	# A boss that dies with its weak points still standing leaves solid obstacles
	# in the glade for nothing; the fight is over, so they go with it.
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	super(info)

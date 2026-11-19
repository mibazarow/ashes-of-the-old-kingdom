class_name Enemy
extends CharacterBody2D
## Enemy with an explicit finite state machine.
##
## IDLE -> PATROL -> INVESTIGATE -> CHASE -> ATTACK -> STAGGER -> DEAD
## Every dangerous attack has a visible telegraph before the hitbox opens.

enum Kind { MELEE, RANGED }
enum State { IDLE, PATROL, INVESTIGATE, CHASE, ATTACK, STAGGER, DEAD }

const MELEE_SPEED := 62.0
const RANGED_SPEED := 44.0
const PATROL_SPEED := 30.0
const DETECT_RADIUS := 96.0
const LEASH_RADIUS := 230.0
const ATTACK_RANGE_MELEE := 18.0
const ATTACK_RANGE_RANGED := 130.0
const MIN_RANGED_RANGE := 55.0

const WINDUP := 0.42
const ACTIVE := 0.10
const RECOVERY := 0.45
const STAGGER_TIME := 0.22
const ATTACK_COOLDOWN := 0.85

@export var kind: Kind = Kind.MELEE
@export var enemy_type: StringName = &"ash_wolf"
@export var display_name: String = "Пепельный волк"
@export var max_health: int = 26
@export var attack_damage: int = 8
@export var xp_reward: int = 12
@export var gold_reward: int = 6
@export var loot_item: String = "wolf_fang"
@export var loot_chance: float = 0.75
@export var projectile_scene: PackedScene

@onready var sprite: Sprite2D = $Sprite2D
@onready var health: HealthComponent = $HealthComponent
@onready var attack_area: Area2D = $AttackHitbox
@onready var attack_shape: CollisionShape2D = $AttackHitbox/CollisionShape2D
@onready var telegraph: ColorRect = $Telegraph
@onready var muzzle: Marker2D = $Muzzle

var state: State = State.IDLE
var spawn_position: Vector2 = Vector2.ZERO
var patrol_target: Vector2 = Vector2.ZERO

var _state_time := 0.0
var _attack_cooldown_left := 0.0
var _swing_counter := 0
var _current_hit_id := ""
var _hit_this_swing: Dictionary = {}
var _player: Node2D = null
var _wander_timer := 0.0
var _flash_timer := 0.0
var _fired_this_swing := false
var _status_component: StatusComponent = null
## Combo bonus carried by the hit that caused the current stagger, and the
## stagger time left for this hit (spec §9.2 ice + physical).
var _stagger_bonus := 0.0
var _stagger_left := 0.0


func _ready() -> void:
	add_to_group("enemy")
	spawn_position = global_position
	patrol_target = global_position
	health.max_health = max_health
	health.current_health = max_health
	health.died.connect(_on_died)
	health.damaged.connect(_on_damaged)
	attack_shape.disabled = true
	telegraph.visible = false
	_attack_cooldown_left = randf_range(0.2, 0.9)
	_wander_timer = randf_range(1.0, 3.0)
	if get_node_or_null("StatusComponent") == null:
		var sc := StatusComponent.new()
		sc.name = "StatusComponent"
		add_child(sc)
		_status_component = sc


## Lazily resolved status component. Attached in code (never edited into the
## .tscn), so it is created in _ready() and cached here for the movement and
## attack gates.
func _status() -> StatusComponent:
	if _status_component != null and is_instance_valid(_status_component):
		return _status_component
	_status_component = get_node_or_null("StatusComponent") as StatusComponent
	return _status_component


func _blocks_actions() -> bool:
	var sc := _status()
	return sc != null and sc.blocks_actions()


func get_defense() -> int:
	return 0


## Resistance answer for StatusComponent. Enemies have no attributes, so the
## answer is an explicit zero rather than the component's "no hook" fallback:
## the contract the player satisfies is the same one an enemy satisfies.
func get_status_resistance(_status: String) -> float:
	return 0.0


## Dead answer for StatusComponent / DamageResolver, which probe the owner
## instead of assuming where HP lives.
func is_status_owner_dead() -> bool:
	return state == State.DEAD or (health != null and health.is_dead)


func receive_damage(amount: int, info: Dictionary = {}) -> void:
	if state == State.DEAD:
		return
	health.take_damage(amount, info)
	_spawn_damage_number(amount)
	if state != State.DEAD:
		# An ice + physical combination (spec §9.2) asks for a deeper stagger. The
		# bonus is written per hit and consumed by _enter(), so a later hit without
		# a combination cannot inherit it, and a DoT tick never re-applies it.
		_stagger_bonus = _combination_stagger_bonus(info)
		_enter(State.STAGGER)


## Extra stagger seconds carried by a hit's "combination" block (see
## Combinations.on_hit). Anything malformed reads as no bonus.
func _combination_stagger_bonus(info: Dictionary) -> float:
	var combination: Variant = info.get("combination", {})
	if not (combination is Dictionary):
		return 0.0
	return maxf(0.0, float((combination as Dictionary).get("extra_stagger", 0.0)))


func _on_damaged(_amount: int, _info: Dictionary) -> void:
	_flash_timer = 0.1
	modulate = Color(1.6, 1.2, 1.2)


func _on_died(_info: Dictionary) -> void:
	_enter(State.DEAD)
	# A corpse must not keep burning: the DoT would reach a dead target, and the
	# fading corpse would still hold live effects.
	var dead_sc := _status()
	if dead_sc != null:
		dead_sc.clear_all()
	attack_shape.disabled = true
	telegraph.visible = false
	collision_layer = 0
	collision_mask = 0
	GameState.add_xp(xp_reward)
	GameState.add_gold(gold_reward)
	GameState.register_kill(String(enemy_type))
	if loot_item != "" and randf() < loot_chance:
		GameState.add_item(loot_item, 1)
	EventBus.enemy_died.emit(StringName(str(get_instance_id())), enemy_type, global_position)
	Telemetry.event(&"enemy_died", {
		"enemy_type": String(enemy_type),
		"pos": [global_position.x, global_position.y],
	})
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "modulate:a", 0.0, 0.45)
	tween.tween_property(sprite, "scale", Vector2(1.2, 0.6), 0.45)
	tween.chain().tween_callback(queue_free)


func _physics_process(delta: float) -> void:
	_tick(delta)
	match state:
		State.DEAD:
			return
		State.STAGGER:
			velocity = velocity.move_toward(Vector2.ZERO, 400.0 * delta)
			# The stagger clock runs down, so a combination hit holds the target
			# down longer than a plain one. When it expires the enemy rejoins the
			# fight (spec §10.4): back onto the player while it is still in reach,
			# otherwise it gives up and investigates on its own. DEAD is matched
			# before this branch, so a killing blow taken mid-stagger keeps priority.
			_stagger_left = maxf(0.0, _stagger_left - delta)
			if _stagger_left <= 0.0:
				_leave_stagger()
		State.IDLE:
			_process_idle(delta)
		State.PATROL:
			_process_patrol(delta)
		State.INVESTIGATE:
			_process_investigate(delta)
		State.CHASE:
			_process_chase(delta)
		State.ATTACK:
			_process_attack(delta)
	var sc := _status()
	if sc != null:
		var mult := sc.move_multiplier()
		if mult != 1.0:
			velocity *= mult
	move_and_slide()


## Exit from STAGGER once the clock runs out (spec §10.4). Re-acquire the player
## only when it is still both visible and on a short leash from the post it was
## hit at; otherwise fall back to INVESTIGATE, which drops to IDLE/PATROL on its
## own. _player_visible() resolves the player through _player_ref(), so a null or
## freed player reads as "not visible" and routes to INVESTIGATE.
func _leave_stagger() -> void:
	if _player_visible() and global_position.distance_to(spawn_position) <= LEASH_RADIUS:
		_enter(State.CHASE)
	else:
		_enter(State.INVESTIGATE)


func _tick(delta: float) -> void:
	_state_time += delta
	_attack_cooldown_left = maxf(0.0, _attack_cooldown_left - delta)
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			modulate = Color.WHITE


func _enter(next: State) -> void:
	state = next
	_state_time = 0.0
	match next:
		State.IDLE:
			velocity = Vector2.ZERO
		State.STAGGER:
			telegraph.visible = false
			attack_shape.disabled = true
			# The stagger clock for this hit: the base time plus whatever the
			# combination on the incoming hit asked for, then the bonus is dropped so
			# the next hit starts from its own value.
			_stagger_left = STAGGER_TIME + _stagger_bonus
			_stagger_bonus = 0.0


func _player_ref() -> Node2D:
	if _player != null and is_instance_valid(_player):
		return _player
	_player = get_tree().get_first_node_in_group("player") as Node2D
	return _player


func _distance_to_player() -> float:
	var p := _player_ref()
	if p == null:
		return INF
	return global_position.distance_to(p.global_position)


func _player_visible() -> bool:
	var p := _player_ref()
	if p == null:
		return false
	if _distance_to_player() > DETECT_RADIUS:
		return false
	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(global_position, p.global_position, 1)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	return hit.is_empty()


func _process_idle(delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, 200.0 * delta)
	if _player_visible():
		_enter(State.CHASE)
		return
	if _state_time >= _wander_timer:
		patrol_target = spawn_position + Vector2(randf_range(-40, 40), randf_range(-40, 40))
		_enter(State.PATROL)


func _process_patrol(delta: float) -> void:
	if _player_visible():
		_enter(State.CHASE)
		return
	var dir := global_position.direction_to(patrol_target)
	if global_position.distance_to(patrol_target) < 6.0 or _state_time > 3.0:
		_wander_timer = randf_range(1.2, 3.4)
		_enter(State.IDLE)
		return
	velocity = dir * PATROL_SPEED
	_face(dir)


func _process_investigate(delta: float) -> void:
	if _player_visible():
		_enter(State.CHASE)
		return
	if _state_time > 1.2:
		_enter(State.IDLE)
	velocity = velocity.move_toward(Vector2.ZERO, 120.0 * delta)


func _process_chase(delta: float) -> void:
	var p := _player_ref()
	if p == null:
		_enter(State.IDLE)
		return
	if global_position.distance_to(spawn_position) > LEASH_RADIUS:
		_enter(State.INVESTIGATE)
		return
	var dist := _distance_to_player()
	if dist > DETECT_RADIUS * 1.4:
		_enter(State.INVESTIGATE)
		return

	var dir := global_position.direction_to(p.global_position)
	_face(dir)

	# Turning stays allowed while rooted/stunned; only the attack itself is gated.
	if not _blocks_actions() and _attack_cooldown_left <= 0.0:
		if kind == Kind.MELEE and dist <= ATTACK_RANGE_MELEE:
			_start_attack()
			return
		if kind == Kind.RANGED and dist <= ATTACK_RANGE_RANGED and dist >= MIN_RANGED_RANGE:
			_start_attack()
			return

	if kind == Kind.RANGED and dist < MIN_RANGED_RANGE:
		velocity = -dir * RANGED_SPEED
	else:
		var speed := MELEE_SPEED if kind == Kind.MELEE else RANGED_SPEED
		velocity = dir * speed


func _start_attack() -> void:
	_enter(State.ATTACK)
	_swing_counter += 1
	_current_hit_id = DamageResolver.make_hit_id(get_instance_id(), _swing_counter)
	_hit_this_swing.clear()
	_fired_this_swing = false
	velocity = Vector2.ZERO
	var p := _player_ref()
	if p != null:
		_face(global_position.direction_to(p.global_position))
	telegraph.visible = true
	telegraph.modulate = Color(1.0, 0.35, 0.25, 0.55)


func _process_attack(delta: float) -> void:
	# A shock/stun landing mid-swing cuts the telegraph short and drops the enemy
	# back to the chase ("Разряд: короткое прерывание").
	var swing_sc := _status()
	if swing_sc != null and swing_sc.attack_multiplier() == 0.0:
		attack_shape.disabled = true
		telegraph.visible = false
		_enter(State.CHASE)
		return

	_state_time += delta
	velocity = Vector2.ZERO
	if _state_time < WINDUP:
		var t := _state_time / WINDUP
		telegraph.modulate.a = 0.25 + 0.45 * t
		return

	telegraph.visible = false

	if _state_time < WINDUP + ACTIVE:
		if kind == Kind.MELEE:
			attack_shape.disabled = false
			_apply_melee_hits()
		elif not _fired_this_swing:
			_fired_this_swing = true
			_fire_projectile()
		return

	attack_shape.disabled = true
	if _state_time >= WINDUP + ACTIVE + RECOVERY:
		_attack_cooldown_left = ATTACK_COOLDOWN
		_enter(State.CHASE)


func _apply_melee_hits() -> void:
	for body in attack_area.get_overlapping_bodies():
		if not body.has_method("receive_damage"):
			continue
		var key := str(body.get_instance_id())
		if _hit_this_swing.has(key):
			continue
		_hit_this_swing[key] = true
		DamageResolver.resolve_hit(self, body, {
			"damage": attack_damage,
			"hit_id": _current_hit_id,
			"damage_type": "physical",
		})


func _fire_projectile() -> void:
	if projectile_scene == null:
		return
	var p := _player_ref()
	if p == null:
		return
	var proj := projectile_scene.instantiate()
	var dir := muzzle.global_position.direction_to(p.global_position)
	proj.global_position = muzzle.global_position
	proj.setup(dir, attack_damage, self)
	get_parent().add_child(proj)


func _face(dir: Vector2) -> void:
	if dir.length() < 0.01:
		return
	if absf(dir.x) > 0.2:
		sprite.flip_h = dir.x < 0.0


func _spawn_damage_number(amount: int) -> void:
	var label := Label.new()
	label.text = str(amount)
	label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.5))
	label.add_theme_font_size_override("font_size", 8)
	label.position = global_position + Vector2(-3, -18)
	label.z_index = 100
	get_parent().add_child(label)
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 14.0, 0.55)
	tween.tween_property(label, "modulate:a", 0.0, 0.55)
	tween.chain().tween_callback(label.queue_free)

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

## How much further a charging enemy spots the player (spec §10, "кабан идёт в
## атаку, как только почует"). Applied only when `charge_on_sight` is set.
const CHARGE_DETECT_MULTIPLIER := 1.5

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

## Behaviour tuning for a specific enemy type (spec §10). Every multiplier
## defaults to 1.0 and every flag to the value the wolf and the cultist already
## had, so a new enemy is a .tscn with different numbers rather than a new
## script, and the two original enemies keep their exact old feel.
@export var speed_multiplier: float = 1.0
@export var attack_cooldown_multiplier: float = 1.0
@export var windup_multiplier: float = 1.0
## A charger spots the player from `CHARGE_DETECT_MULTIPLIER` times the detection
## radius and pushes straight in: the ranged minimum distance (back off below
## `MIN_RANGED_RANGE`, refuse to shoot inside it) is inert while it is set.
@export var charge_on_sight: bool = false
## Colour of this enemy's own sprite, so a reused placeholder sprite still reads
## as a different creature. The damage flash returns to this colour rather than
## to plain white, otherwise the first hit would wash the identity away.
@export var sprite_tint: Color = Color.WHITE

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

## The world node that owns the village safe zone (the `Forest`), resolved through
## the `safe_zone_owner` group and cached. Null when no safe zone exists (a bare
## test arena), in which case every safe-zone rule below is inert and the enemy
## behaves exactly as it did before the village existed.
var _safe_owner: Node = null


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
	sprite.modulate = sprite_tint
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


# --- village safe zone ---------------------------------------------------------
# The village clearing is off limits to hostiles. Two rules, both keyed on the
# tile the enemy would occupy next frame rather than the one it is on, so a fast
# enemy cannot skip the boundary in a single step:
#   * a step that would land inside the zone is refused (velocity zeroed) — the
#     enemy stops dead at the edge and can never cross to chase or to strike;
#   * an enemy that is already inside (spawned or pushed there) walks straight out
#     toward its own post, ignoring the block rule so it can never deadlock.
# Everything here is inert while no `safe_zone_owner` is in the tree, so the open
# forest, the arena tests and every existing bot behave byte for byte as before.

func _safe_zone_owner() -> Node:
	if _safe_owner != null and is_instance_valid(_safe_owner):
		return _safe_owner
	_safe_owner = get_tree().get_first_node_in_group("safe_zone_owner")
	return _safe_owner


func _is_in_safe_zone(pos: Vector2) -> bool:
	var owner := _safe_zone_owner()
	if owner == null or not owner.has_method("is_in_safe_zone"):
		return false
	return bool(owner.call("is_in_safe_zone", Vector2i(floori(pos.x / 16.0), floori(pos.y / 16.0))))


func _inside_safe_zone() -> bool:
	return _is_in_safe_zone(global_position)


## The nearest point of the safe zone this enemy must reach to leave it: its own
## post when that lies outside (the honest "go back where you came from"), and
## otherwise the closest edge of the zone, so an enemy whose post is itself inside
## still has a deterministic way out instead of pressing against the border.
func _safe_zone_escape_point() -> Vector2:
	var owner := _safe_zone_owner()
	if owner != null and owner.has_method("safe_zone_rect"):
		var rect: Rect2i = owner.call("safe_zone_rect")
		if not rect.has_point(Vector2i(floori(spawn_position.x / 16.0), floori(spawn_position.y / 16.0))):
			return spawn_position
		var cx := clampf(global_position.x, rect.position.x * 16.0 + 8.0, (rect.position.x + rect.size.x) * 16.0 - 8.0)
		var cy := clampf(global_position.y, rect.position.y * 16.0 + 8.0, (rect.position.y + rect.size.y) * 16.0 - 8.0)
		var inside := Vector2(cx, cy)
		var out := inside
		var best := INF
		for cand: Vector2 in [
			Vector2((rect.position.x - 1) * 16.0 + 8.0, cy),
			Vector2((rect.position.x + rect.size.x) * 16.0 + 8.0, cy),
			Vector2(cx, (rect.position.y - 1) * 16.0 + 8.0),
			Vector2(cx, (rect.position.y + rect.size.y) * 16.0 + 8.0),
		]:
			var d := inside.distance_to(cand)
			if d < best:
				best = d
				out = cand
		return out
	return spawn_position


## Called after the state machine has set `velocity` but before the move. Returns
## true when the frame's movement was overridden (walk-out) and the caller must not
## apply the ordinary block check.
func _apply_safe_zone_movement() -> bool:
	if _inside_safe_zone():
		var base_speed := MELEE_SPEED if kind == Kind.MELEE else RANGED_SPEED
		var dir := global_position.direction_to(_safe_zone_escape_point())
		velocity = dir * base_speed * speed_multiplier
		_face(dir)
		return true
	if velocity.length() > 0.01 and _is_in_safe_zone(global_position + velocity * get_physics_process_delta_time()):
		velocity = Vector2.ZERO
	return false



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
	# The flash brightens this enemy's own tint instead of replacing it, so a
	# hit boar still flashes boar-coloured. With the default white tint the
	# product is the original flash colour, byte for byte.
	sprite.modulate = sprite_tint * Color(1.6, 1.2, 1.2)


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
	_apply_safe_zone_movement()
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
			sprite.modulate = sprite_tint


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


## Sight line of this enemy. A charger notices the player from further out, which
## is what makes it leave its post first; everything that does not charge keeps
## the plain `DETECT_RADIUS`, so the wolf and the cultist see exactly as far as
## they did before these exports existed.
func _detect_radius() -> float:
	return DETECT_RADIUS * (CHARGE_DETECT_MULTIPLIER if charge_on_sight else 1.0)


func _player_visible() -> bool:
	var p := _player_ref()
	if p == null:
		return false
	if _distance_to_player() > _detect_radius():
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
	if dist > _detect_radius() * 1.4:
		_enter(State.INVESTIGATE)
		return

	var dir := global_position.direction_to(p.global_position)
	_face(dir)

	# The ranged minimum distance is the kiting rule: back off below it, hold fire
	# inside it. A charger ignores the rule as a whole, so its floor drops to zero
	# and both halves fall out of the same number instead of needing a branch.
	# Anything that does not charge gets MIN_RANGED_RANGE, exactly as before.
	var min_range := MIN_RANGED_RANGE if (kind == Kind.RANGED and not charge_on_sight) else 0.0

	# Turning stays allowed while rooted/stunned; only the attack itself is gated.
	# The safe zone also forbids striking from inside it: an enemy that is already
	# walking out (or pressed at the border) must never land a hit on a villager or
	# a player standing in the clearing, so the whole attack-initiation block below
	# is skipped while this enemy is inside the zone.
	if not _inside_safe_zone() and not _blocks_actions() and _attack_cooldown_left <= 0.0:
		if kind == Kind.MELEE and dist <= ATTACK_RANGE_MELEE:
			_start_attack()
			return
		if kind == Kind.RANGED and dist <= ATTACK_RANGE_RANGED and dist >= min_range:
			_start_attack()
			return

	if kind == Kind.RANGED and min_range > 0.0 and dist < min_range:
		velocity = -dir * RANGED_SPEED * speed_multiplier
	else:
		var base_speed := MELEE_SPEED if kind == Kind.MELEE else RANGED_SPEED
		velocity = dir * base_speed * speed_multiplier


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
	# Both the telegraph length and the pause after a swing are per-enemy knobs, so
	# a heavy hitter can read its attack longer and recover slower while a quick one
	# does the opposite. At the default 1.0 every threshold below is the constant.
	var windup := WINDUP * windup_multiplier
	if _state_time < windup:
		var t := _state_time / windup
		telegraph.modulate.a = 0.25 + 0.45 * t
		return

	telegraph.visible = false

	if _state_time < windup + ACTIVE:
		if kind == Kind.MELEE:
			attack_shape.disabled = false
			_apply_melee_hits()
		elif not _fired_this_swing:
			_fired_this_swing = true
			_fire_projectile()
		return

	attack_shape.disabled = true
	if _state_time >= windup + ACTIVE + RECOVERY:
		_attack_cooldown_left = ATTACK_COOLDOWN * attack_cooldown_multiplier
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

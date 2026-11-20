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

## --- behaviour trait tuning (spec §10) ---------------------------------------
## A hit counts as frontal while the angle to the attacker stays inside this
## cone, so a shielded enemy only soaks what it actually faces. cos(70°).
const FRONTAL_BLOCK_ANGLE := 70.0
const FRONTAL_BLOCK_COS := 0.342
## Cultist aura: allies inside this radius are healed once per AURA_INTERVAL, and
## no more than AURA_MAX_TARGETS of them per tick (a packed room cannot lag a frame).
const AURA_RADIUS := 70.0
const AURA_INTERVAL := 1.0
const AURA_MAX_TARGETS := 8
## Death pool: a corpse zone of this radius that pays out death_pool_damage once
## per DEATH_POOL_TICK for DEATH_POOL_LIFETIME seconds. At most DEATH_POOL_MAX
## pools may be alive at once, however many plague bearers die together.
const DEATH_POOL_RADIUS := 34.0
const DEATH_POOL_LIFETIME := 4.0
const DEATH_POOL_TICK := 1.0
const DEATH_POOL_STATUS_DURATION := 1.5
const DEATH_POOL_MAX := 3
const DEATH_POOL_GROUP := &"death_pool"
## Blink hop length and the exposure window that follows it.
const TELEPORT_MIN := 40.0
const TELEPORT_MAX := 70.0
const TELEPORT_VULNERABLE_TIME := 0.15
const TELEPORT_VULNERABLE_BONUS := 1.5
## Swarm: allies within this radius each add pack_bonus to the speed multiplier,
## up to this total bonus.
const PACK_RADIUS := 90.0
const PACK_BONUS_CAP := 0.4
## How often the swarm re-counts its neighbours. A group scan is not free, so the
## count is refreshed a few times a second and read from a cache every frame.
const PACK_REFRESH_INTERVAL := 0.25

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

## --- behaviour traits (spec §10) ---------------------------------------------
## Seven mechanical levers that make a new enemy type genuinely different without
## a new script. Every one defaults to the value the wolf and the cultist already
## had (0.0 / false / ""), so an enemy that sets none of them behaves byte for
## byte as it did before these exports existed, and every new trait is inert until
## a scene opts in.
##
## Frontal shield: a fraction (0..1) of incoming damage absorbed when the hit
## lands on the side the enemy is facing (within FRONTAL_BLOCK_ANGLE). The knight.
@export var frontal_block: float = 0.0
## Cultist caster: heals allies within AURA_RADIUS through their HealthComponent
## every second. 0 disables the aura entirely.
@export var aura_heal_per_second: int = 0
## Plague bearer: on death leaves a short-lived damaging zone at the corpse. The
## string is the status it inflicts ("blight"); "" leaves no pool at all.
@export var death_pool: String = ""
@export var death_pool_damage: int = 4
## Root beast / turret: never walks, but still strikes anything that steps into
## attack_range. The chase turns to face the player; only the legs are off.
@export var stationary: bool = false
## Blinker: while chasing, teleports a short hop toward a random offset every N
## seconds and is briefly exposed right after. 0 disables blinking.
@export var teleport_interval: float = 0.0
## Spider: a landed melee hit chills the target for this many seconds. 0 keeps
## the swing clean.
@export var web_on_hit: float = 0.0
## Swarm: an additive speed bonus per living ally within PACK_RADIUS, capped at
## PACK_BONUS_CAP. 0 keeps the lone-wolf speed.
@export var pack_bonus: float = 0.0

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

## Facing as a unit vector, tracked alongside `sprite.flip_h` so the frontal-block
## cone and the blink direction have a real direction to work from. Only read by
## traits that opt in, so a default enemy never looks at it.
var _facing := Vector2.ZERO
## Cultist aura accumulator (heal once per AURA_INTERVAL, not per frame).
var _aura_accum := 0.0
## Blink clock and the exposure timer that follows a hop.
var _teleport_accum := 0.0
var _teleport_vulnerable_left := 0.0
## Swarm speed is recomputed on a slow clock (a group scan is not free) and read
## from this cache every frame, so `_physics_process` never allocates. For an enemy
## with no pack_bonus it is simply `speed_multiplier`, refreshed in place.
var _effective_speed_mult := 1.0
var _pack_accum := 0.0

## The world node that owns the village safe zone (the `Forest`), resolved through
## the `safe_zone_owner` group and cached. Null when no safe zone exists (a bare
## test arena), in which case every safe-zone rule below is inert and the enemy
## behaves exactly as it did before the village existed.
var _safe_owner: Node = null

## The zone that owns the tile grid (the node up the tree that answers `cell_at`),
## resolved lazily and cached so a blinker can reject a wall destination. Null in a
## bare test arena with no world above it, where the blink simply never validates.
var _world: Node = null


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
	# Seed the movement cache so the first chase frame already reads the scene's
	# own speed even before the swarm clock has had a chance to refresh.
	_effective_speed_mult = speed_multiplier


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
	var final_amount := amount
	# Frontal shield: only a hit that lands inside the facing cone is soaked, and
	# only when the attacker bothered to say where it came from. The absorbed
	# amount is written back onto the incoming info (the DamageResolver result
	# dict, which is what reaches Telemetry.combat right after this call), so the
	# block shows up in the combat log without a second event.
	if frontal_block > 0.0 and _is_frontal_hit(info):
		var reduced := maxi(1, int(round(float(amount) * (1.0 - frontal_block))))
		info["blocked"] = amount - reduced
		final_amount = reduced
	# A blink leaves the enemy briefly exposed: +50 % damage while the window is
	# open. Inert whenever teleport_interval is 0 (the timer never starts).
	if _teleport_vulnerable_left > 0.0:
		final_amount = int(round(float(final_amount) * TELEPORT_VULNERABLE_BONUS))
		info["teleport_vulnerable"] = true
	health.take_damage(final_amount, info)
	_spawn_damage_number(final_amount)
	if state != State.DEAD:
		# An ice + physical combination (spec §9.2) asks for a deeper stagger. The
		# bonus is written per hit and consumed by _enter(), so a later hit without
		# a combination cannot inherit it, and a DoT tick never re-applies it.
		_stagger_bonus = _combination_stagger_bonus(info)
		_enter(State.STAGGER)


## True when `info` names an attacker position that lies inside the facing cone.
## A missing/malformed attacker_position, or an enemy with no facing yet, reads as
## "not frontal" so the shield never fires on a hit it cannot place.
func _is_frontal_hit(info: Dictionary) -> bool:
	var attacker_position: Variant = info.get("attacker_position")
	if not (attacker_position is Vector2):
		return false
	if _facing.length() < 0.01:
		return false
	var to_attacker := (attacker_position as Vector2) - global_position
	if to_attacker.length() < 0.01:
		return false
	return _facing.dot(to_attacker.normalized()) >= FRONTAL_BLOCK_COS


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
	# The corpse pool is a separate node owned by the parent, so it outlives this
	# enemy's own fade-and-free tween below.
	_spawn_death_pool()
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
			# A blinker only shuffles position while it is actively chasing, and
			# only while the chase is still a chase (a swing that started this
			# frame must not also teleport).
			if state == State.CHASE:
				_tick_teleport(delta)
		State.ATTACK:
			_process_attack(delta)
	var sc := _status()
	if sc != null:
		var mult := sc.move_multiplier()
		if mult != 1.0:
			velocity *= mult
	_apply_safe_zone_movement()
	# A turret never walks: whatever the state machine decided, its legs stay put.
	# Turning and striking are untouched, so it still swings at anything that steps
	# into attack_range. Inert unless `stationary` is set.
	if stationary:
		velocity = Vector2.ZERO
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
	if _teleport_vulnerable_left > 0.0:
		_teleport_vulnerable_left = maxf(0.0, _teleport_vulnerable_left - delta)
	_refresh_pack_speed(delta)
	_tick_aura(delta)


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
		velocity = -dir * RANGED_SPEED * _effective_speed_mult
	else:
		var base_speed := MELEE_SPEED if kind == Kind.MELEE else RANGED_SPEED
		velocity = dir * base_speed * _effective_speed_mult


# --- behaviour traits (spec §10) -----------------------------------------------
# Each helper below is inert at its export default, so an enemy that opts into
# none of them runs the exact code path it ran before these traits existed.

## The speed multiplier this enemy would move at right now, counting the allies
## currently around it. Computed fresh (it is a query for tests and UI, not a
## per-frame call — movement reads the cache below instead), so a caller sees the
## swarm bonus the instant an ally walks in or out of range.
func effective_speed_multiplier() -> float:
	if pack_bonus <= 0.0:
		return speed_multiplier
	return speed_multiplier + _pack_bonus_value(_pack_allies_count())


## The swarm bonus a given number of nearby allies is worth, capped so a packed
## room cannot outrun the design. 0 when the enemy is not a pack fighter.
func _pack_bonus_value(allies: int) -> float:
	if pack_bonus <= 0.0:
		return 0.0
	return minf(PACK_BONUS_CAP, pack_bonus * float(allies))


## Living allies (group "enemy", not self, not dead) within PACK_RADIUS. Scans the
## group, so it is called on the slow refresh clock below, never every frame.
func _pack_allies_count() -> int:
	var count := 0
	for node in get_tree().get_nodes_in_group("enemy"):
		if node == self or not is_instance_valid(node):
			continue
		var e2d := node as Node2D
		if e2d == null:
			continue
		if e2d.global_position.distance_to(global_position) > PACK_RADIUS:
			continue
		if _is_dead_enemy(e2d):
			continue
		count += 1
	return count


## A corpse (or a fading one) is not a living ally. Reads the duck-typed shape the
## group actually holds: an Enemy answers through `state`, anything else through a
## HealthComponent, and a node with neither is treated as alive.
func _is_dead_enemy(node: Node) -> bool:
	var st: Variant = node.get("state")
	if st != null and int(st) == int(State.DEAD):
		return true
	var hc := node.get_node_or_null("HealthComponent") as HealthComponent
	return hc != null and hc.is_dead


## Refresh the cached speed multiplier. Without pack_bonus this is a plain
## assignment (so a boss that multiplies speed_multiplier mid-fight is picked up
## the same frame), and with it the group scan runs a few times a second, not 60.
func _refresh_pack_speed(delta: float) -> void:
	if pack_bonus <= 0.0:
		_effective_speed_mult = speed_multiplier
		return
	_pack_accum += delta
	if _pack_accum < PACK_REFRESH_INTERVAL:
		return
	_pack_accum = 0.0
	_effective_speed_mult = speed_multiplier + _pack_bonus_value(_pack_allies_count())


## Cultist aura: one heal pass per AURA_INTERVAL, never per frame. Inert at 0.
func _tick_aura(delta: float) -> void:
	if aura_heal_per_second <= 0 or state == State.DEAD:
		return
	_aura_accum += delta
	if _aura_accum < AURA_INTERVAL:
		return
	_aura_accum -= AURA_INTERVAL
	_heal_nearby_allies()


func _heal_nearby_allies() -> void:
	var healed := 0
	for node in get_tree().get_nodes_in_group("enemy"):
		if healed >= AURA_MAX_TARGETS:
			return
		if node == self or not is_instance_valid(node):
			continue
		var e2d := node as Node2D
		if e2d == null:
			continue
		if e2d.global_position.distance_to(global_position) > AURA_RADIUS:
			continue
		var hc := e2d.get_node_or_null("HealthComponent") as HealthComponent
		if hc == null or hc.is_dead:
			continue
		hc.heal(aura_heal_per_second)
		healed += 1


## Blinker: a hop every teleport_interval while chasing. Inert at 0.
func _tick_teleport(delta: float) -> void:
	if teleport_interval <= 0.0:
		return
	_teleport_accum += delta
	if _teleport_accum < teleport_interval:
		return
	_teleport_accum = 0.0
	_do_blink()


## A short hop toward a random offset around the current facing. The rotation only
## steers the landing point; the displacement is exactly the sampled distance, so a
## blink always moves 40–70 px. A wall destination is refused outright.
func _do_blink() -> void:
	var base := _facing
	if base.length() < 0.01:
		base = Vector2.RIGHT
	var dir := base.rotated(randf_range(-PI * 0.5, PI * 0.5))
	var destination := global_position + dir * randf_range(TELEPORT_MIN, TELEPORT_MAX)
	if _tile_is_solid(destination):
		return
	global_position = destination
	_teleport_vulnerable_left = TELEPORT_VULNERABLE_TIME
	Telemetry.event(&"enemy_blink", {
		"enemy_type": String(enemy_type),
		"pos": [global_position.x, global_position.y],
	})


## True when the tile under `pos` is solid in the owning zone. With no world above
## this enemy (a bare arena) there is nothing to validate against, so the blink is
## allowed; the walkable set is the same "." / "," the zones themselves use.
func _tile_is_solid(pos: Vector2) -> bool:
	var world := _world_node()
	if world == null or not world.has_method("cell_at"):
		return false
	var tile := Vector2i(floori(pos.x / 16.0), floori(pos.y / 16.0))
	var cell := String(world.call("cell_at", tile))
	return cell != "." and cell != ","


## The nearest ancestor that can read the tile grid, cached. Null when none exists.
func _world_node() -> Node:
	if _world != null and is_instance_valid(_world):
		return _world
	var parent := get_parent()
	while parent != null:
		if parent.has_method("cell_at"):
			_world = parent
			return _world
		parent = parent.get_parent()
	return null


## Plague bearer: leave a damaging pool on the corpse, unless the cap is already
## reached. Inert while death_pool is "".
func _spawn_death_pool() -> void:
	if death_pool == "" or get_parent() == null:
		return
	if get_tree().get_nodes_in_group(DEATH_POOL_GROUP).size() >= DEATH_POOL_MAX:
		return
	var pool := DeathPool.new()
	pool.configure(death_pool_damage, death_pool, DEATH_POOL_STATUS_DURATION,
		DEATH_POOL_RADIUS, DEATH_POOL_LIFETIME, DEATH_POOL_TICK)
	pool.global_position = global_position
	get_parent().add_child(pool)
	Telemetry.event(&"enemy_death_pool", {
		"enemy_type": String(enemy_type),
		"pos": [global_position.x, global_position.y],
	})


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
		var payload := {
			"damage": attack_damage,
			"hit_id": _current_hit_id,
			"damage_type": "physical",
			# Where this swing came from, so a target with a frontal shield can
			# place the hit. DamageResolver hands the payload's own keys to the
			# target, so this is the only way a melee hit can carry a position.
			"attacker_position": global_position,
		}
		# Spider web: a landed swing chills its target through the shared status
		# payload path. Inert at the default 0.0, so an ordinary swing stays clean.
		if web_on_hit > 0.0:
			payload["status"] = "chill"
			payload["status_duration"] = web_on_hit
		DamageResolver.resolve_hit(self, body, payload)


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
	# Track the facing as a vector for the traits that need a direction (frontal
	# block, blink). The flip_h rule below is untouched, so a default enemy still
	# turns exactly as it always did.
	_facing = dir.normalized()
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


## A short-lived damaging zone left by a plague bearer's corpse (spec §10). It is
## a plain Node2D so it survives the enemy that spawned it (which fades and frees
## itself a moment later), carries one Area2D that only listens on the player
## layer, pays out its damage once per tick to whoever stands inside, and frees
## itself on timeout. It never touches an enemy: the mask is the player layer and
## the body filter re-checks the group, so a double guard against friendly fire.
class DeathPool:
	extends Node2D

	## The player physics layer (bit 2). Masking to it alone is what keeps the pool
	## from ever reporting an enemy body.
	const PLAYER_LAYER := 2

	var damage := 4
	var inflicted_status := "blight"
	var status_duration := 1.5
	var radius := 34.0
	var lifetime := 4.0
	var tick_interval := 1.0

	var _life := 0.0
	var _tick_accum := 0.0
	var _tick_counter := 0
	var _area: Area2D = null

	func configure(dmg: int, status: String, dur: float, pool_radius: float, pool_lifetime: float, pool_tick: float) -> void:
		damage = dmg
		inflicted_status = status
		status_duration = dur
		radius = pool_radius
		lifetime = pool_lifetime
		tick_interval = pool_tick

	func _ready() -> void:
		add_to_group(&"death_pool")
		_area = Area2D.new()
		_area.collision_layer = 0
		_area.collision_mask = PLAYER_LAYER
		var shape := CircleShape2D.new()
		shape.radius = radius
		var collision := CollisionShape2D.new()
		collision.shape = shape
		_area.add_child(collision)
		add_child(_area)

	func _process(delta: float) -> void:
		_life += delta
		if _life >= lifetime:
			queue_free()
			return
		_tick_accum += delta
		if _tick_accum >= tick_interval:
			_tick_accum -= tick_interval
			_damage_inside()

	func _damage_inside() -> void:
		if _area == null:
			return
		for body in _area.get_overlapping_bodies():
			if body == null or not body.is_in_group("player"):
				continue
			if not body.has_method("receive_damage"):
				continue
			_tick_counter += 1
			var payload := {
				"damage": damage,
				"hit_id": "death-pool-%d-%d" % [get_instance_id(), _tick_counter],
				"damage_type": "blight",
			}
			if inflicted_status != "":
				payload["status"] = inflicted_status
				payload["status_duration"] = status_duration
			# The attacker is null on purpose: the pool is environmental, and a
			# source that could be freed before the blight it applied would leave
			# the DoT pointing at a dead reference.
			DamageResolver.resolve_hit(null, body, payload)

class_name Player
extends CharacterBody2D
## Top-down player: 8-way movement, dash with i-frames, melee attack with
## wind-up / active / recovery, and interaction through a single input funnel.

signal attack_started(hit_id: String)

const SPEED := 110.0
const DASH_SPEED := 330.0
const DASH_TIME := 0.16
const DASH_COOLDOWN := 0.55
const DASH_IFRAMES := 0.22
const HIT_IFRAMES := 0.45

const SPELL_PROJECTILE_SCENE := preload("res://scenes/items/spell_projectile.tscn")
## ice_barrier duration in seconds; the reduction percent comes from the data.
const BARRIER_DURATION := 4.0

const WINDUP := 0.08
const ACTIVE := 0.10
const RECOVERY := 0.16
const ATTACK_COOLDOWN := 0.06

## Base attack-area placement; the per-step reach/arc multipliers scale it.
const ATTACK_OFFSET := 14.0

const INTERACT_RADIUS := 26.0

enum State { IDLE, MOVE, ATTACK, DASH, DEAD }

const FRAME_DOWN := 0
const FRAME_UP := 1
const FRAME_SIDE := 2

@onready var sprite: Sprite2D = $Sprite2D
@onready var attack_area: Area2D = $AttackHitbox
@onready var attack_shape: CollisionShape2D = $AttackHitbox/CollisionShape2D
@onready var camera: Camera2D = $Camera2D

var state: State = State.IDLE
var facing: Vector2 = Vector2.DOWN
var spawn_point: Vector2 = Vector2.ZERO

var _state_time := 0.0
var _dash_cooldown_left := 0.0
var _attack_cooldown_left := 0.0
var _iframe_left := 0.0
var _swing_counter := 0
var _current_hit_id := ""
var _hit_this_swing: Dictionary = {}
var _interactable: Node = null
var _dead_timer := 0.0
var _flash_timer := 0.0
var _status_component: StatusComponent = null

## Weapon-driven attack chain (spec §6 "Комбо зависят от оружия"). The chain
## itself lives here; every parameter comes from the equipped weapon's item data
## through ItemDB.combo_steps(), so a new weapon needs no code. An unarmed
## player, or a weapon without combo data, keeps the single swing described by
## the WINDUP/ACTIVE/RECOVERY constants above.
var _combo_index := 0
var _combo_window_left := 0.0
var _current_step: Dictionary = {}

## Per-skill cooldowns (skill id -> seconds left) and the cast counter that
## feeds unique hit_ids. The ice_barrier buff lives here, not in GameState.
var _skill_cooldowns: Dictionary = {}
var _cast_counter := 0
var _barrier_left := 0.0
var _barrier_reduction := 0.0


func _ready() -> void:
	add_to_group("player")
	spawn_point = global_position
	attack_shape.disabled = true
	EventBus.player_died.connect(_on_player_died)
	EventBus.player_health_changed.connect(_on_health_changed)
	EventBus.save_loaded.connect(_on_save_loaded)
	if get_node_or_null("StatusComponent") == null:
		var sc := StatusComponent.new()
		sc.name = "StatusComponent"
		add_child(sc)
		_status_component = sc


## Lazily resolved status component, created in _ready() (never edited into the
## .tscn). Feeds the movement multiplier, the action gate and the healing gate.
func _status() -> StatusComponent:
	if _status_component != null and is_instance_valid(_status_component):
		return _status_component
	_status_component = get_node_or_null("StatusComponent") as StatusComponent
	return _status_component


## Movement multiplier the player actually moves at: the agility bonus from
## GameState (spec §7.1) stacked with whatever the statuses do to him. Both are
## plain factors, so a chilled agile player is still faster than a chilled
## untrained one, and a root (0.0) still stops everybody.
func _move_multiplier() -> float:
	var sc := _status()
	var from_status := sc.move_multiplier() if sc != null else 1.0
	return from_status * GameState.move_speed_multiplier()


func _blocks_actions() -> bool:
	var sc := _status()
	return sc != null and sc.blocks_actions()


## Healing entry point. The ash blight combination (spec §9.2) is resolved in
## Combinations.on_heal: while blight is active a heal lands at the blight
## healing multiplier and burns off one stack. HUD item use and the nature heal
## both route through here, so no caller has to know anything about statuses.
func heal_with_status(amount: int) -> int:
	return GameState.heal(Combinations.on_heal(self, amount))


func get_defense() -> int:
	return GameState.total_defense()


func is_invulnerable() -> bool:
	return _iframe_left > 0.0 or state == State.DASH or state == State.DEAD


## Resistance answer for StatusComponent, which asks its owner instead of
## knowing where the number lives. Only the control statuses (spec §8.2 root,
## stun, shock) are shortened by Выносливость; a burn or a chill lands at full
## duration no matter how tough the player is.
func get_status_resistance(status: String) -> float:
	match status:
		"root", "stun", "shock":
			return GameState.control_resistance()
		_:
			return 0.0


## Dead answer for StatusComponent / DamageResolver. The player has no
## HealthComponent child (HP lives in GameState), so without this hook the
## status dead guard would be a no-op for the player.
func is_status_owner_dead() -> bool:
	return state == State.DEAD or GameState.hp <= 0


func _physics_process(delta: float) -> void:
	_tick_timers(delta)

	match state:
		State.DEAD:
			velocity = Vector2.ZERO
			_dead_timer -= delta
			if _dead_timer <= 0.0:
				_respawn()
			move_and_slide()
			return
		State.DASH:
			_process_dash(delta)
			return
		State.ATTACK:
			_process_attack(delta)
			return
		_:
			_process_free(delta)

	move_and_slide()


func _tick_timers(delta: float) -> void:
	_dash_cooldown_left = maxf(0.0, _dash_cooldown_left - delta)
	_attack_cooldown_left = maxf(0.0, _attack_cooldown_left - delta)
	_iframe_left = maxf(0.0, _iframe_left - delta)
	# The chain window is a post-swing clock: it means "how long after a swing the
	# next attack still counts as the same chain", so it only counts down once the
	# swing that opened it is over. A spear step is longer than its own window
	# (0.66 s swing, 0.55 s window), and letting it run mid-swing would drop the
	# chain under the swing still in progress and make the next attack skip a step.
	if state != State.ATTACK:
		_combo_window_left = maxf(0.0, _combo_window_left - delta)
		if _combo_window_left <= 0.0 and _combo_index != 0:
			_combo_index = 0
	if _barrier_left > 0.0:
		_barrier_left = maxf(0.0, _barrier_left - delta)
	for key in _skill_cooldowns.keys():
		var left := float(_skill_cooldowns[key]) - delta
		_skill_cooldowns[key] = left if left > 0.0 else 0.0
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			modulate = Color.WHITE


func _process_free(delta: float) -> void:
	if GameState.ui_blocking:
		velocity = Vector2.ZERO
		state = State.IDLE
		_update_sprite()
		return

	var input_dir := InputSource.get_vector(&"move_left", &"move_right", &"move_up", &"move_down")
	if input_dir.length() > 0.01:
		velocity = input_dir.normalized() * SPEED * _move_multiplier()
		state = State.MOVE
		_update_facing(input_dir)
	else:
		velocity = Vector2.ZERO
		state = State.IDLE

	_update_sprite()

	# Stun/shock/root freeze combat actions. Movement is only slowed (chill) or
	# stopped (root/stun) through the multiplier above, so a chilled player can
	# still attack, dash and use the ability.
	var blocked := _blocks_actions()
	if not blocked and InputSource.is_action_just_pressed(&"ability"):
		try_ability()
	elif not blocked and InputSource.is_action_just_pressed(&"attack") and _attack_cooldown_left <= 0.0:
		_start_attack()
	elif not blocked and InputSource.is_action_just_pressed(&"dash") and _dash_cooldown_left <= 0.0:
		_start_dash(input_dir)
	else:
		_scan_interactable()
		if InputSource.is_action_just_pressed(&"interact") and _interactable != null:
			_interactable.call("interact", self)


func _start_attack() -> void:
	_pick_combo_step()
	state = State.ATTACK
	_state_time = 0.0
	# Attack direction is aim-driven (mouse for a human, target for the bot),
	# independent of the movement direction.
	var aim := InputSource.aim_direction(global_position)
	if aim.length() > 0.01:
		facing = aim.normalized()
	_swing_counter += 1
	_current_hit_id = DamageResolver.make_hit_id(get_instance_id(), _swing_counter)
	_hit_this_swing.clear()
	velocity = Vector2.ZERO
	_position_attack_area()
	attack_started.emit(_current_hit_id)


## Equipped weapon id, "" when the player fights unarmed.
func _weapon_id() -> String:
	return String(GameState.equipment.get("weapon", ""))


## Single-swing fallback so nothing regresses for an unarmed player or a weapon
## with no combo block: the timings are exactly the constants above.
func _default_step() -> Dictionary:
	return {
		"damage_mult": 1.0,
		"windup": WINDUP,
		"active": ACTIVE,
		"recovery": RECOVERY,
		"reach": 1.0,
		"arc": 1.0,
	}


## Chooses the step this swing uses. Inside the combo window the chain moves to
## the next step and wraps after the last one; outside it (or after the weapon
## changed under a chain) the chain restarts at step 0.
func _pick_combo_step() -> void:
	var steps := ItemDB.combo_steps(_weapon_id())
	if steps.is_empty():
		_combo_index = 0
		_current_step = _default_step()
		return
	if _combo_window_left > 0.0 and _combo_index < steps.size():
		_combo_index = (_combo_index + 1) % steps.size()
	else:
		_combo_index = 0
	var step: Variant = steps[_combo_index]
	_current_step = step if step is Dictionary else _default_step()


func combo_index() -> int:
	return _combo_index


func combo_step_count() -> int:
	var steps := ItemDB.combo_steps(_weapon_id())
	return steps.size() if not steps.is_empty() else 1


func combo_window_left() -> float:
	return _combo_window_left


func current_step_multiplier() -> float:
	return float(_current_step.get("damage_mult", 1.0))


func _process_attack(delta: float) -> void:
	# A shock/stun landing mid-swing cuts the attack short instead of letting the
	# hitbox open on the next frame ("Разряд: короткое прерывание").
	var sc := _status()
	if sc != null and sc.attack_multiplier() == 0.0:
		attack_shape.disabled = true
		state = State.IDLE
		_attack_cooldown_left = ATTACK_COOLDOWN
		return

	_state_time += delta
	velocity = Vector2.ZERO
	_update_sprite()

	# Phase lengths come from the current chain step; the constants are the
	# fallback for a swing whose step data is missing.
	var windup := float(_current_step.get("windup", WINDUP))
	var active := float(_current_step.get("active", ACTIVE))
	var recovery := float(_current_step.get("recovery", RECOVERY))

	if _state_time < windup:
		return
	if _state_time < windup + active:
		attack_shape.disabled = false
		_apply_attack_hits()
		return

	attack_shape.disabled = true
	if _state_time >= windup + active + recovery:
		state = State.IDLE
		_attack_cooldown_left = ATTACK_COOLDOWN
		# The chain stays open only for this window after the swing ends, so a
		# slow player or a paused player starts over instead of chaining forever.
		_combo_window_left = ItemDB.combo_window(_weapon_id())


func _apply_attack_hits() -> void:
	var damage := _step_damage()
	for body in attack_area.get_overlapping_bodies():
		if body == self or not body.has_method("receive_damage"):
			continue
		var key := str(body.get_instance_id())
		if _hit_this_swing.has(key):
			continue
		_hit_this_swing[key] = true
		DamageResolver.resolve_hit(self, body, {
			"damage": damage,
			"hit_id": _current_hit_id,
			"damage_type": "physical",
			"critical": randf() < GameState.crit_chance(),
		})
		_hit_stop(0.045)


## Total attack scaled by the chain step multiplier, rounded and never below 1,
## so a late chain step is strictly stronger than an early one.
func _step_damage() -> int:
	var mult := float(_current_step.get("damage_mult", 1.0))
	return maxi(1, int(round(float(GameState.total_attack()) * mult)))


## Magic damage of a skill (spec §7.1 Интеллект). The skill keeps its raw number
## in the data and the intelligence bonus is applied here, at cast time, so one
## skill definition serves every player and no skill data has to know about the
## attributes. A skill with no damage (heal, barrier) stays at 0.
func _magic_damage(skill: Dictionary) -> int:
	var raw := int(skill.get("damage", 0))
	if raw <= 0:
		return 0
	return maxi(1, int(round(float(raw) * GameState.magic_multiplier())))


## Hit-stop is delegated to the process-wide HitStop autoload so the slow-motion
## clock outlives the player: a player freed mid-stop (death + respawn, scene
## change, quit) can no longer strand Engine.time_scale below 1.0, and overlapping
## swings in one fan merge into a single window instead of racing. The autoload is
## resolved at runtime through the main loop, like the other systems do, so this
## also works under `godot --script` where autoload identifiers are not registered.
func _hit_stop_autoload() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null("HitStop")


func _hit_stop(duration: float) -> void:
	var hit_stop := _hit_stop_autoload()
	if hit_stop != null:
		hit_stop.call("request", duration)


## Wipe any running hit-stop. Called on death and respawn so a stop cannot carry
## into the death screen or onto the respawned player.
func _cancel_hit_stop() -> void:
	var hit_stop := _hit_stop_autoload()
	if hit_stop != null:
		hit_stop.call("cancel")


func _start_dash(dir: Vector2) -> void:
	state = State.DASH
	_state_time = 0.0
	_dash_cooldown_left = DASH_COOLDOWN
	_iframe_left = maxf(_iframe_left, DASH_IFRAMES)
	if dir.length() > 0.01:
		facing = dir.normalized()
	velocity = facing * DASH_SPEED
	_position_attack_area()
	_update_sprite()


## Casts the currently selected skill (spec §9). Replaces the old dash
## placeholder; Space still dashes. Single entry point, reachable from
## _process_free and from tests. Cooldown is tracked per skill id, so one skill
## on cooldown does not block the others.
func try_ability() -> bool:
	# A stun/root/shock freezes casting at the entry point too, not only in the
	# _process_free caller, so no caller can make a stunned player cast.
	if _blocks_actions():
		return false
	var id: String = GameState.selected_skill
	var skill := SkillDB.get_skill(id)
	if skill.is_empty():
		return false
	if float(_skill_cooldowns.get(id, 0.0)) > 0.0:
		return false
	var cost := int(skill.get("mana", 0))
	if not GameState.spend_mana(cost):
		EventBus.toast.emit("Не хватает маны")
		return false
	_skill_cooldowns[id] = float(skill.get("cooldown", 0.0))
	_cast_counter += 1
	var hit_id := DamageResolver.make_hit_id(get_instance_id(), _cast_counter)
	var aim := InputSource.aim_direction(global_position)
	var dir := aim if aim.length() > 0.01 else facing
	if dir.length() > 0.01:
		facing = dir.normalized()
		_update_sprite()
	match String(skill.get("shape", "")):
		"projectile":
			_cast_projectile(skill, dir, hit_id)
		"self":
			_cast_self(skill)
		"aoe":
			_cast_aoe(skill, dir, hit_id)
	var skill_name := String(skill.get("name", id))
	EventBus.toast.emit(skill_name)
	# A cast that actually paid mana and cooldown asks for its cue. Nothing else
	# in the slice emits "cast", so no new signal was needed for it.
	EventBus.sfx_requested.emit("cast", "SFX")
	Telemetry.event(&"skill_cast", {
		"skill": id,
		"school": String(skill.get("school", "")),
		"shape": String(skill.get("shape", "")),
		"cost": cost,
	})
	return true


func _cast_projectile(skill: Dictionary, dir: Vector2, hit_id: String) -> void:
	var proj := SPELL_PROJECTILE_SCENE.instantiate()
	proj.global_position = global_position
	proj.setup({
		"direction": dir,
		"damage": _magic_damage(skill),
		"status": String(skill.get("status", "")),
		"status_duration": float(skill.get("status_duration", 0.0)),
		"hit_id": hit_id,
		"damage_type": _school_damage_type(String(skill.get("school", ""))),
		"speed": float(skill.get("speed", 260.0)),
		"range": float(skill.get("range", 260.0)),
		"shooter": self,
	})
	get_parent().add_child(proj)


func _cast_self(skill: Dictionary) -> void:
	var heal_amount := int(skill.get("heal", 0))
	if heal_amount > 0:
		heal_with_status(heal_amount)
	var barrier := int(skill.get("barrier", 0))
	if barrier > 0:
		_barrier_left = BARRIER_DURATION
		_barrier_reduction = float(barrier)


## Area skill: every enemy within `radius` of the aim point (the cursor
## direction, pushed out to the skill's `range`) is resolved through
## DamageResolver with the cast's unique hit_id and gets its status.
func _cast_aoe(skill: Dictionary, dir: Vector2, hit_id: String) -> void:
	var aim_point := global_position + dir * float(skill.get("range", 0.0))
	var radius := float(skill.get("radius", 0.0))
	var damage := _magic_damage(skill)
	var status := String(skill.get("status", ""))
	var status_duration := float(skill.get("status_duration", 0.0))
	var damage_type := _school_damage_type(String(skill.get("school", "")))
	for node in get_tree().get_nodes_in_group("enemy"):
		var e2d := node as Node2D
		if e2d == null or not e2d.has_method("receive_damage"):
			continue
		if aim_point.distance_to(e2d.global_position) > radius:
			continue
		var payload := {
			"damage": damage,
			"hit_id": hit_id,
			"damage_type": damage_type,
		}
		if status != "":
			payload["status"] = status
			payload["status_duration"] = status_duration
		DamageResolver.resolve_hit(self, e2d, payload)


func _school_damage_type(school: String) -> String:
	match school:
		"fire":
			return "fire"
		"ice":
			return "ice"
		"lightning":
			return "lightning"
		"nature":
			return "nature"
		_:
			return "spell"


func _process_dash(delta: float) -> void:
	_state_time += delta
	velocity = velocity.move_toward(Vector2.ZERO, DASH_SPEED * 2.5 * delta)
	move_and_slide()
	if _state_time >= DASH_TIME:
		state = State.IDLE
		velocity = Vector2.ZERO


func _update_facing(dir: Vector2) -> void:
	if dir.length() < 0.01:
		return
	if absf(dir.x) > absf(dir.y):
		facing = Vector2(signf(dir.x), 0)
	else:
		facing = Vector2(0, signf(dir.y))


func _update_sprite() -> void:
	if absf(facing.x) > absf(facing.y):
		sprite.frame = FRAME_SIDE
		sprite.flip_h = facing.x < 0.0
	elif facing.y > 0.0:
		sprite.frame = FRAME_DOWN
		sprite.flip_h = false
	else:
		sprite.frame = FRAME_UP
		sprite.flip_h = false


## Places the hitbox for the current chain step: `reach` pushes it further out
## along the facing (a spear out-reaches a sword), `arc` scales it wider.
func _position_attack_area() -> void:
	var reach := float(_current_step.get("reach", 1.0))
	var arc := float(_current_step.get("arc", 1.0))
	attack_area.position = facing * ATTACK_OFFSET * reach
	attack_area.rotation = facing.angle()
	attack_area.scale = Vector2.ONE * arc


func _scan_interactable() -> void:
	var best: Node = null
	var best_dist := INTERACT_RADIUS
	for node in get_tree().get_nodes_in_group("interactable"):
		var n2d := node as Node2D
		if n2d == null:
			continue
		var d := global_position.distance_to(n2d.global_position)
		if d < best_dist:
			best_dist = d
			best = node
	if best != _interactable:
		_interactable = best
		if best == null:
			EventBus.interact_prompt.emit("")
		else:
			EventBus.interact_prompt.emit(String(best.call("prompt_text")))


func receive_damage(amount: int, info: Dictionary = {}) -> void:
	if is_invulnerable():
		if Telemetry != null:
			Telemetry.event(&"damage_ignored", {"reason": "iframes", "amount": amount})
		return
	# ice_barrier shaves a percentage off incoming damage while it lasts.
	var final_amount := amount
	if _barrier_left > 0.0 and _barrier_reduction > 0.0:
		final_amount = maxi(1, int(round(float(amount) * (1.0 - _barrier_reduction / 100.0))))
	GameState.take_damage(final_amount)
	_iframe_left = HIT_IFRAMES
	_flash_timer = 0.12
	modulate = Color(1.0, 0.45, 0.45)
	_spawn_damage_number(final_amount, Color(1.0, 0.35, 0.3))
	Telemetry.event(&"player_hit", {"amount": final_amount, "source": info.get("attacker_id", 0)})


func _on_save_loaded(pos: Vector2) -> void:
	global_position = pos
	velocity = Vector2.ZERO
	state = State.IDLE
	_iframe_left = 0.6
	spawn_point = pos


func _on_health_changed(current: int, _maximum: int) -> void:
	if current > 0 and state == State.DEAD:
		return


func _on_player_died() -> void:
	# A hit-stop in progress must not survive into the death screen: the player is
	# about to be freed and respawned, and a stop owned by the autoload would
	# otherwise keep the whole game in slow motion. Cancel before the DEAD guard so
	# it runs even on a re-entrant death signal.
	_cancel_hit_stop()
	# Death wipes every status: a burn must not keep ticking a corpse, and a stun
	# must not survive into the respawn.
	var dead_sc := _status()
	if dead_sc != null:
		dead_sc.clear_all()
	# A barrier cast a moment before death must not shield the respawned player.
	_barrier_left = 0.0
	_barrier_reduction = 0.0
	# Neither may a half-finished chain: the respawned player starts at step 0.
	_combo_index = 0
	_combo_window_left = 0.0
	if state == State.DEAD:
		return
	state = State.DEAD
	_dead_timer = 1.6
	velocity = Vector2.ZERO
	modulate = Color(0.6, 0.6, 0.6, 0.75)
	Telemetry.event(&"player_died", {"pos": [global_position.x, global_position.y]})


func _respawn() -> void:
	# Belt-and-braces: a stop started a moment before death (or a fresh one during
	# the death animation) must not carry onto the respawned player.
	_cancel_hit_stop()
	var spawn_sc := _status()
	if spawn_sc != null:
		spawn_sc.clear_all()
	_barrier_left = 0.0
	_barrier_reduction = 0.0
	global_position = spawn_point
	GameState.revive_full()
	state = State.IDLE
	_iframe_left = 1.0
	modulate = Color.WHITE
	EventBus.player_respawned.emit()
	Telemetry.event(&"player_respawn", {})


func _spawn_damage_number(amount: int, color: Color) -> void:
	var label := Label.new()
	label.text = str(amount)
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", 8)
	label.position = global_position + Vector2(-3, -18)
	label.z_index = 100
	get_parent().add_child(label)
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 14.0, 0.55)
	tween.tween_property(label, "modulate:a", 0.0, 0.55)
	tween.chain().tween_callback(label.queue_free)

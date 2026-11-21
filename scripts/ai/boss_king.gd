class_name BossKing
extends Boss
## The King Without a Crown (spec §11.4): the final boss, fought in the bare ring
## the fortress left empty at the far end of the broken sanctum.
##
## Where the three earlier bosses read a single threshold and enrage once, the King
## is a three-act fight, and the acts are told the same way the Bell Ringer tells
## its two: the base `Boss` FSM, telegraph, hitboxes and `DamageResolver` stay
## untouched, and this script only adds the third phase and the two things that
## phase changes. Phase one is the plain duel the base already is — melee swings with
## the heavy one every third. Phase two, below `PHASE2_FRACTION` of the pool, adds a
## radial ash wave every `WAVE_INTERVAL` seconds: a telegraphed ring that burns
## whoever is standing inside it when it closes, on top of the base enrage the scene
## already carries (`enraged_speed_multiplier` 1.2, `enraged_cooldown_multiplier`
## 0.8). Phase three, below `PHASE3_FRACTION`, replaces that single ring with three
## stationary ash pillars dropped around the King each wave — telegraphed, then
## dangerous for a few seconds, capped so a long fight cannot drown the ring — while
## the stride picks up to `PHASE3_SPEED_TOTAL` of the base number and the heavy swing
## lands on every second swing instead of every third.
##
## The phase machine is the one place this script does not simply borrow the base.
## `Boss` knows a single threshold; the King needs two, so `_on_pool_changed` is
## overridden to drive both crossings off `phase_thresholds()` and `_enter_phase_three`
## adds the third step. The base `_enter_phase_two` still owns the phase-two enrage
## (it multiplies the exported knobs exactly once), so phase three only has to bring
## the speed to its own total rather than re-apply the whole enrage. Both crossings
## are one-way doors, exactly like the base one: healing back over a threshold and
## dropping through it again cannot stack the multipliers or re-fire `phase_changed`.
##
## The wave and the pillars are separate short-lived nodes (as the Bell Ringer's shock
## wave and hazard circles are), so they outlive the frame that rang them and free
## themselves on timeout. Their damage is environmental: it goes through
## `DamageResolver` with a null attacker exactly like `Enemy.DeathPool`, so a King that
## dies mid-DoT can never leave a status pointing at a freed reference. The radial test
## is a plain distance check against the single player rather than an `Area2D` overlap
## scan, which makes the "inside the ring / outside the ring" promise directly testable
## without depending on when the physics server happens to populate overlaps.

const PHASE2_FRACTION := 0.66
const PHASE3_FRACTION := 0.33
## The stride multiplier phase three settles on, measured against the scene's own
## base `speed_multiplier`. Phase two already paid for `enraged_speed_multiplier`, so
## the third step only applies the remaining factor to reach this total.
const PHASE3_SPEED_TOTAL := 1.5

## The phase-two radial ash wave.
const WAVE_INTERVAL := 4.0
const WAVE_RADIUS := 100.0
const WAVE_TELEGRAPH := 1.0
const WAVE_DAMAGE := 12
const WAVE_STATUS := "burn"
const WAVE_STATUS_DURATION := 2.0
## A distinct damage type so the wave's hits are legible in the resolver log apart
## from the base melee (physical) and the phase-three pillars (ash_pillar).
const WAVE_DAMAGE_TYPE := "ash_wave"

## The phase-three ash pillars: how many a wave drops, how many may live at once,
## and each one's own numbers.
const PILLAR_PER_WAVE := 3
const PILLAR_MAX := 6
const PILLAR_RADIUS := 44.0
const PILLAR_TELEGRAPH := 1.2
const PILLAR_DAMAGE := 14
const PILLAR_STATUS := "blight"
const PILLAR_STATUS_DURATION := 2.0
const PILLAR_LIFETIME := 4.0
const PILLAR_TICK := 0.5
const PILLAR_DAMAGE_TYPE := "ash_pillar"
## How far from the King a pillar may be dropped (snapped to walkable ground).
const PILLAR_SPREAD := 120.0

## The ash only falls while the player is in the fight, so an unengaged King does not
## fill an empty sanctum with waves. The wave itself is harmless off-radius.
const WAVE_TRIGGER_RADIUS := 240.0

## Phase three lands the heavy swing on every second swing instead of the base three.
const HEAVY_EVERY_PHASE_THREE := 2

var _wave_accum := 0.0
var _death_announced := false


func _ready() -> void:
	super()


## The two pool fractions that open phases two and three, in order. Spelled out as a
## method rather than read off the base `phase_two_health_fraction` export because the
## base class only models one threshold; the King's whole identity is the second one.
func phase_thresholds() -> Array[float]:
	return [PHASE2_FRACTION, PHASE3_FRACTION]


## The two-way phase trigger. The base connects `health_changed` to a single-threshold
## version of this; the King replaces it so both crossings are driven from one place.
## Each branch is guarded by the current phase, so a threshold can only be crossed
## downward once and `phase_changed` fires exactly once per transition.
func _on_pool_changed(current: int, maximum: int) -> void:
	if maximum <= 0 or state == State.DEAD:
		return
	var fraction := float(current) / float(maximum)
	if _phase == 1 and fraction <= PHASE2_FRACTION:
		_enter_phase_two()
	if _phase == 2 and fraction <= PHASE3_FRACTION:
		_enter_phase_three()


## One-way transition into the last act. The base enrage has already multiplied speed
## once (in `_enter_phase_two`); this only lifts the stride to the phase-three total
## and announces the act, so the borrowed wind-up machinery in the base is untouched.
func _enter_phase_three() -> void:
	if _phase >= 3:
		return
	_phase = 3
	if enraged_speed_multiplier > 0.0:
		speed_multiplier *= PHASE3_SPEED_TOTAL / enraged_speed_multiplier
	Telemetry.event(&"boss_phase", {
		"enemy_type": String(enemy_type),
		"phase": _phase,
	})
	phase_changed.emit(_phase)


## The ash clock. Runs off the base physics step, gated on the same three things the
## Bell Ringer gates its bell on: alive, a live player, and that player close enough
## to be the target of the ring. Below phase two there is no ash at all.
func _physics_process(delta: float) -> void:
	super(delta)
	if state == State.DEAD:
		return
	if current_phase() < 2:
		return
	var p := _player_ref()
	if p == null or is_status_owner_dead():
		return
	if global_position.distance_to(p.global_position) > WAVE_TRIGGER_RADIUS:
		return
	_wave_accum += delta
	if _wave_accum >= WAVE_INTERVAL:
		_wave_accum = 0.0
		_fire_wave()


## Phase two rings the single radial wave; phase three trades that ring for a spread
## of pillars. Public seam so a test can fire a wave on demand instead of waiting out
## the four-second clock.
func _fire_wave() -> void:
	if current_phase() >= 3:
		spawn_pillars()
	else:
		ring_wave()


## Rings one radial ash wave centred on the King. Public so a test can ring a wave
## without waiting out the interval.
func ring_wave() -> Node:
	var wave := AshWave.new()
	wave.configure(WAVE_DAMAGE, WAVE_RADIUS, WAVE_TELEGRAPH, WAVE_STATUS, WAVE_STATUS_DURATION)
	get_parent().add_child(wave)
	wave.global_position = global_position
	return wave


## Drops up to `PILLAR_PER_WAVE` ash pillars on walkable ground near the King, never
## letting the live count pass `PILLAR_MAX`. Public for the same reason.
func spawn_pillars() -> void:
	var live := get_tree().get_nodes_in_group("king_pillar").size()
	for i in range(PILLAR_PER_WAVE):
		if live >= PILLAR_MAX:
			return
		var pillar := AshPillar.new()
		pillar.configure(PILLAR_DAMAGE, PILLAR_RADIUS, PILLAR_TELEGRAPH, PILLAR_LIFETIME,
			PILLAR_TICK, PILLAR_STATUS, PILLAR_STATUS_DURATION)
		get_parent().add_child(pillar)
		pillar.global_position = _find_pillar_spot()
		live += 1


## A random walkable spot within `PILLAR_SPREAD` of the King. In a bare arena every
## candidate reads as free (no tile grid above the enemy), so the first lands; in a
## real zone the loop steps until it finds ground that is not a wall.
func _find_pillar_spot() -> Vector2:
	for attempt in range(12):
		var angle := randf() * TAU
		var dist := randf_range(PILLAR_RADIUS, PILLAR_SPREAD)
		var candidate := global_position + Vector2.RIGHT.rotated(angle) * dist
		if not _tile_is_solid(candidate):
			return candidate
	return global_position + Vector2(0.0, PILLAR_RADIUS)


## Base decides the heavy swing on every third; the King, once in its last act,
## decides it on every second. The base `_start_attack` has already counted the swing
## and set the heavy flag for the three-count; in phase three this overrides that
## decision and re-applies the matching wind-up and telegraph, so the borrowed wind-up
## hand-back in `_process_attack` still works untouched. Mirrors the Captain exactly.
func _start_attack() -> void:
	super()
	if current_phase() < 3:
		return
	_heavy_swing = _swing_counter % HEAVY_EVERY_PHASE_THREE == 0
	windup_multiplier = current_swing_windup()
	if telegraph != null:
		telegraph.color = HEAVY_TELEGRAPH_COLOR if _heavy_swing else _base_telegraph_color


## The King's death is the story beat the whole route walked towards: it marks the
## run so the ending altar opens, and it says so out loud. The base `Enemy._on_died`
## has already paid the bounty and emitted `enemy_died` exactly once by the time this
## runs, so the flag and the toast ride the same single death and cannot double up.
func _on_died(info: Dictionary) -> void:
	super(info)
	if _death_announced:
		return
	_death_announced = true
	GameState.set_flag("king_defeated", true)
	EventBus.toast.emit("Король пал")


## A telegraphed radial ash burst that strikes the player once if they are inside the
## ring when the telegraph finishes.
class AshWave:
	extends Node2D

	var damage := 12
	var radius := 100.0
	var telegraph_time := 1.0
	var inflicted_status := "burn"
	var status_duration := 2.0

	var _elapsed := 0.0
	var _applied := false

	func configure(dmg: int, ring_radius: float, telegraph: float, status: String, dur: float) -> void:
		damage = dmg
		radius = ring_radius
		telegraph_time = telegraph
		inflicted_status = status
		status_duration = dur

	func _process(delta: float) -> void:
		_elapsed += delta
		queue_redraw()
		if _elapsed >= telegraph_time:
			apply_now()
		if _elapsed >= telegraph_time + 0.15:
			queue_free()

	## Strikes the player now if they are inside the ring. Idempotent: a wave rings
	## once, however many frames call it. Public so a test can resolve the burst
	## without waiting out the telegraph.
	func apply_now() -> void:
		if _applied:
			return
		_applied = true
		var p := get_tree().get_first_node_in_group("player") as Node2D
		if p == null or not p.has_method("receive_damage"):
			return
		if global_position.distance_to(p.global_position) > radius:
			return
		DamageResolver.resolve_hit(null, p, {
			"damage": damage,
			"hit_id": "king-wave-%d" % get_instance_id(),
			"damage_type": BossKing.WAVE_DAMAGE_TYPE,
			"status": inflicted_status,
			"status_duration": status_duration,
		})

	func _draw() -> void:
		var t := clampf(_elapsed / telegraph_time, 0.0, 1.0) if telegraph_time > 0.0 else 1.0
		draw_circle(Vector2.ZERO, radius, Color(0.95, 0.7, 0.4, 0.12 + 0.34 * t))


## A stationary ash pillar: telegraphed, then dangerous for `lifetime` seconds, paying
## out its damage and status to whoever stands in it on each tick.
class AshPillar:
	extends Node2D

	var damage := 14
	var radius := 44.0
	var telegraph_time := 1.2
	var lifetime := 4.0
	var tick_interval := 0.5
	var inflicted_status := "blight"
	var status_duration := 2.0

	var _elapsed := 0.0
	var _tick_accum := 0.0
	var _tick_counter := 0

	func configure(dmg: int, ring_radius: float, telegraph: float, life: float,
			tick: float, status: String, dur: float) -> void:
		damage = dmg
		radius = ring_radius
		telegraph_time = telegraph
		lifetime = life
		tick_interval = tick
		inflicted_status = status
		status_duration = dur

	func _ready() -> void:
		add_to_group("king_pillar")

	func _process(delta: float) -> void:
		_elapsed += delta
		queue_redraw()
		if _elapsed < telegraph_time:
			return
		if _elapsed >= telegraph_time + lifetime:
			queue_free()
			return
		_tick_accum += delta
		if _tick_accum >= tick_interval:
			_tick_accum -= tick_interval
			_damage_inside()

	func _damage_inside() -> void:
		var p := get_tree().get_first_node_in_group("player") as Node2D
		if p == null or not p.has_method("receive_damage"):
			return
		if global_position.distance_to(p.global_position) > radius:
			return
		_tick_counter += 1
		DamageResolver.resolve_hit(null, p, {
			"damage": damage,
			"hit_id": "king-pillar-%d-%d" % [get_instance_id(), _tick_counter],
			"damage_type": BossKing.PILLAR_DAMAGE_TYPE,
			"status": inflicted_status,
			"status_duration": status_duration,
		})

	## Forces one damage tick now, for a test that wants to prove the pillar strikes
	## whoever stands in it without waiting out the telegraph and the tick clock.
	func apply_now() -> void:
		_damage_inside()

	func _draw() -> void:
		if _elapsed < telegraph_time:
			var t := clampf(_elapsed / telegraph_time, 0.0, 1.0) if telegraph_time > 0.0 else 1.0
			draw_circle(Vector2.ZERO, radius, Color(0.85, 0.6, 0.35, 0.12 + 0.3 * t))
		else:
			draw_circle(Vector2.ZERO, radius, Color(0.7, 0.45, 0.25, 0.4))

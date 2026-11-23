class_name BossBellRinger
extends Boss
## The Bell Ringer of the Empty Crypt (spec §11): the undercroft's boss, met deep
## past the trap plates.
##
## Its signature is the bell. Independent of the base ranged attack it keeps in both
## phases, it rings a radial shock wave every `WAVE_INTERVAL` seconds: a visible
## telegraph for `WAVE_TELEGRAPH` seconds, then a burst that hits only the player if
## they are standing inside `WAVE_RADIUS`, for `WAVE_DAMAGE` and a short `shock`.
## Below half health the bell starts ringing two stationary hazard circles onto the
## ground with each wave — telegraphed, then dangerous for a few seconds, capped so a
## long fight cannot drown the room — while the plain shock wave keeps ringing too.
##
## The wave and the hazard are separate short-lived nodes (as the plague bearer's
## death pool is), so they outlive the frame that rang them and free themselves on
## timeout. Their damage is environmental: it goes through `DamageResolver` with a
## null attacker exactly like `Enemy.DeathPool`, so a boss that dies mid-DoT can
## never leave a status pointing at a freed reference. The radial test is a plain
## distance check against the single player rather than an `Area2D` overlap scan,
## which makes the "inside the ring / outside the ring" promise directly testable
## without depending on when the physics server happens to populate overlaps.

const WAVE_INTERVAL := 5.0
const WAVE_RADIUS := 90.0
const WAVE_TELEGRAPH := 0.9
const WAVE_DAMAGE := 10
const WAVE_STATUS := "shock"
const WAVE_STATUS_DURATION := 0.4

## The phase-two hazard circles: how many a wave drops, how many may live at once,
## and each one's own numbers.
const HAZARD_PER_WAVE := 2
const HAZARD_MAX := 4
const HAZARD_RADIUS := 40.0
const HAZARD_TELEGRAPH := 1.2
const HAZARD_DAMAGE := 8
const HAZARD_STATUS := "blight"
const HAZARD_STATUS_DURATION := 1.5
const HAZARD_LIFETIME := 3.0
const HAZARD_TICK := 0.5
## How far from the boss a hazard may be dropped (snapped to walkable ground).
const HAZARD_SPREAD := 120.0

## The bell only rings while the player is in the fight, so an unengaged boss does
## not fill an empty crypt with waves. The wave itself is harmless off-radius.
const WAVE_TRIGGER_RADIUS := 240.0

var _wave_accum := 0.0


func _physics_process(delta: float) -> void:
	super(delta)
	if state == State.DEAD:
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


func _fire_wave() -> void:
	ring_wave()
	if current_phase() >= 2:
		spawn_hazards()


## Rings one shock wave centred on the boss. Public so a test can ring a wave on
## demand instead of waiting out the five-second clock.
func ring_wave() -> Node:
	var wave := BellWave.new()
	wave.configure(WAVE_DAMAGE, WAVE_RADIUS, WAVE_TELEGRAPH, WAVE_STATUS, WAVE_STATUS_DURATION)
	get_parent().add_child(wave)
	wave.global_position = global_position
	return wave


## Drops up to `HAZARD_PER_WAVE` hazard circles on walkable ground near the boss,
## never letting the live count pass `HAZARD_MAX`. Public for the same reason.
func spawn_hazards() -> void:
	var live := get_tree().get_nodes_in_group("bell_hazard").size()
	for i in range(HAZARD_PER_WAVE):
		if live >= HAZARD_MAX:
			return
		var hazard := HazardCircle.new()
		hazard.configure(HAZARD_DAMAGE, HAZARD_RADIUS, HAZARD_TELEGRAPH, HAZARD_LIFETIME,
			HAZARD_TICK, HAZARD_STATUS, HAZARD_STATUS_DURATION)
		get_parent().add_child(hazard)
		hazard.global_position = _find_hazard_spot()
		live += 1


## A random walkable spot within `HAZARD_SPREAD` of the boss. In a bare arena every
## candidate reads as free (no tile grid above the enemy), so the first lands; in a
## real zone the loop steps until it finds ground that is not a wall.
func _find_hazard_spot() -> Vector2:
	for attempt in range(12):
		var angle := randf() * TAU
		var dist := randf_range(HAZARD_RADIUS, HAZARD_SPREAD)
		var candidate := global_position + Vector2.RIGHT.rotated(angle) * dist
		if not _tile_is_solid(candidate):
			return candidate
	return global_position + Vector2(0.0, HAZARD_RADIUS)


## A telegraphed radial shock burst that strikes the player once if they are inside
## the ring when the telegraph finishes.
class BellWave:
	extends Node2D

	var damage := 10
	var radius := 90.0
	var telegraph_time := 0.9
	var inflicted_status := "shock"
	var status_duration := 0.4

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
			"hit_id": "bell-wave-%d" % get_instance_id(),
			"damage_type": "shock",
			"status": inflicted_status,
			"status_duration": status_duration,
		})

	func _draw() -> void:
		var t := clampf(_elapsed / telegraph_time, 0.0, 1.0) if telegraph_time > 0.0 else 1.0
		draw_circle(Vector2.ZERO, radius, Color(0.72, 0.86, 1.0, 0.12 + 0.34 * t))
		# The CRITIC-P1-09 rule for drawn hazard shapes too: the translucent fill
		# carries the pulse, a hard dark ring carries the edge on any floor.
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 64, Color(0.02, 0.03, 0.05, 1.0), 1.0)


## A stationary hazard circle: telegraphed, then dangerous for `lifetime` seconds,
## paying out its damage and status to whoever stands in it on each tick.
class HazardCircle:
	extends Node2D

	var damage := 8
	var radius := 40.0
	var telegraph_time := 1.2
	var lifetime := 3.0
	var tick_interval := 0.5
	var inflicted_status := "blight"
	var status_duration := 1.5

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
		add_to_group("bell_hazard")

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
			"hit_id": "bell-hazard-%d-%d" % [get_instance_id(), _tick_counter],
			"damage_type": "blight",
			"status": inflicted_status,
			"status_duration": status_duration,
		})

	## Forces one damage tick now, for a test that wants to prove the circle strikes
	## whoever stands in it without waiting out the telegraph and the tick clock.
	func apply_now() -> void:
		_damage_inside()

	func _draw() -> void:
		if _elapsed < telegraph_time:
			var t := clampf(_elapsed / telegraph_time, 0.0, 1.0) if telegraph_time > 0.0 else 1.0
			draw_circle(Vector2.ZERO, radius, Color(0.55, 0.85, 0.5, 0.12 + 0.3 * t))
		else:
			draw_circle(Vector2.ZERO, radius, Color(0.4, 0.7, 0.35, 0.4))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 64, Color(0.02, 0.03, 0.05, 1.0), 1.0)

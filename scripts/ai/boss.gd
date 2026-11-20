class_name Boss
extends Enemy
## Mini-boss behaviour layered on top of the shared `Enemy` FSM (spec §10.4, §10.5).
##
## A boss is not "a bigger wolf". Three things make it a different fight, and all
## three live here rather than in `enemy.gd`, so the ordinary enemies keep the
## exact behaviour they had before bosses existed:
##
## 1. Two phases. Below `phase_two_health_fraction` of the pool the boss enrages
##    exactly once: it chases `enraged_speed_multiplier` times faster and swings
##    every `enraged_cooldown_multiplier` of its usual pause. The switch is a
##    one-way door, so healing back over the threshold and dropping through it
##    again cannot stack the multipliers into an unkillable sponge.
## 2. A telegraphed heavy swing. Every `HEAVY_SWING_EVERY`-th swing hits for
##    `HEAVY_DAMAGE_MULTIPLIER` of the normal number and reads `HEAVY_WINDUP_MULTIPLIER`
##    times longer, with a different telegraph colour, so the player has time to
##    step out of something that visibly weighs more.
## 3. No stagger lock. Ordinary hits do not interrupt a boss at all — a boss that
##    flinched from every hit would be locked forever by a fast build. Only the
##    ice + physical combination (spec §9.2, `combination.extra_stagger`) gets it
##    down, which makes the control rule a reward for setting the combo up.
##
## The phase multipliers are applied to the exported knobs themselves, which the
## base FSM reads every frame, so no base behaviour had to be duplicated here.
## The heavy swing borrows the same mechanism for the wind-up: the boosted value
## is put on the knob for the duration of that one swing and handed back when the
## swing ends. The damage of the swing is deliberately NOT put on the knob —
## `_apply_melee_hits()` below resolves the boosted number straight into the
## payload, so `attack_damage` always reads as the number the scene exported.

const BOSS_GROUP := &"boss"

## One swing in this many is the heavy one (`_swing_counter % 3 == 0`, so swings
## 3, 6, 9, ...). The counter starts at 0 and the base class increments it before
## the check, so the first heavy swing is the third swing, never the first.
const HEAVY_SWING_EVERY := 3
const HEAVY_DAMAGE_MULTIPLIER := 1.8
const HEAVY_WINDUP_MULTIPLIER := 1.6

## Heavy telegraph: same red as an ordinary swing, but brighter, thicker and
## amber-shifted, so the difference is readable at a glance instead of resting on
## a 15 % alpha change.
const HEAVY_TELEGRAPH_COLOR := Color(1.0, 0.62, 0.12, 0.85)

@export var phase_two_health_fraction: float = 0.5
@export var enraged_speed_multiplier: float = 1.3
@export var enraged_cooldown_multiplier: float = 0.6

signal phase_changed(phase: int)

var _phase := 1
var _heavy_swing := false
## The scene's own wind-up and telegraph colour, captured before this script ever
## boosts them, so a heavy swing can hand both back exactly as they were.
var _base_windup_multiplier := 1.0
var _base_telegraph_color := Color(1.0, 0.35, 0.25, 0.5)


func _ready() -> void:
	super()
	add_to_group(BOSS_GROUP)
	_base_windup_multiplier = windup_multiplier
	if telegraph != null:
		_base_telegraph_color = telegraph.color
	# The pool is the only phase trigger: `health_changed` fires on every applied
	# hit, which is exactly the moment the threshold may have been crossed.
	if health != null and not health.health_changed.is_connected(_on_pool_changed):
		health.health_changed.connect(_on_pool_changed)


func current_phase() -> int:
	return _phase


## The pool value that switches this boss to phase 2 (180 hp boss -> 90).
func phase_two_threshold() -> int:
	return int(round(float(max_health) * clampf(phase_two_health_fraction, 0.0, 1.0)))


## Damage of the swing that is being wound up right now: 1.8x, rounded, on every
## third swing and the plain number on the others (16 -> 29 on the heavy one).
func current_swing_damage() -> int:
	return int(round(float(attack_damage) * HEAVY_DAMAGE_MULTIPLIER)) if _heavy_swing else attack_damage


## Wind-up of the swing in progress: 1.6x longer while the heavy one winds up.
func current_swing_windup() -> float:
	return _base_windup_multiplier * HEAVY_WINDUP_MULTIPLIER if _heavy_swing else _base_windup_multiplier


func is_heavy_swing() -> bool:
	return _heavy_swing


func _on_pool_changed(current: int, maximum: int) -> void:
	if _phase != 1 or maximum <= 0:
		return
	if float(current) <= float(maximum) * clampf(phase_two_health_fraction, 0.0, 1.0):
		_enter_phase_two()


## One-way transition: the guard makes a second crossing of the same threshold a
## no-op, so the multipliers below are paid for once.
func _enter_phase_two() -> void:
	if _phase >= 2:
		return
	_phase = 2
	speed_multiplier *= enraged_speed_multiplier
	attack_cooldown_multiplier *= enraged_cooldown_multiplier
	Telemetry.event(&"boss_phase", {
		"enemy_type": String(enemy_type),
		"phase": _phase,
	})
	phase_changed.emit(_phase)


## Base: counts the swing, opens the telegraph. Boss: decides for this one swing
## whether it is the heavy one and puts the matching readout on the player.
func _start_attack() -> void:
	super()
	_heavy_swing = _swing_counter % HEAVY_SWING_EVERY == 0
	windup_multiplier = current_swing_windup()
	if telegraph != null:
		telegraph.color = HEAVY_TELEGRAPH_COLOR if _heavy_swing else _base_telegraph_color


## Base: runs WINDUP -> ACTIVE -> RECOVERY off `windup_multiplier`, which this
## script already set for the swing in progress. All the boss adds is handing the
## borrowed wind-up back once the swing is over, so the next ordinary swing is
## exactly as fast as it was before any heavy one existed.
func _process_attack(delta: float) -> void:
	super(delta)
	if state != State.ATTACK:
		_release_heavy_windup()


## Base: same hitbox, same dedupe, same `DamageResolver` path — only the number
## in the payload can differ, and only on the heavy swing.
func _apply_melee_hits() -> void:
	for body in attack_area.get_overlapping_bodies():
		if not body.has_method("receive_damage"):
			continue
		var key := str(body.get_instance_id())
		if _hit_this_swing.has(key):
			continue
		_hit_this_swing[key] = true
		DamageResolver.resolve_hit(self, body, {
			"damage": current_swing_damage(),
			"hit_id": _current_hit_id,
			"damage_type": "physical",
		})


## The stagger gate (spec §10.4). `receive_damage()` in the base class writes
## `_stagger_bonus` from the incoming hit's `combination` block and only then asks
## for STAGGER, so the bonus is exactly the "did this hit carry ice + physical"
## answer the rule needs. An ordinary hit (and a burn tick, which carries no
## combination either) is refused here and the boss simply stays in whatever state
## it was in: chasing keeps chasing, a swing in progress keeps its swing.
func _enter(next: State) -> void:
	if next == State.STAGGER and _stagger_bonus <= 0.0:
		_stagger_bonus = 0.0
		return
	super(next)


func _on_died(info: Dictionary) -> void:
	_release_heavy_windup()
	super(info)


func _release_heavy_windup() -> void:
	if not _heavy_swing:
		return
	_heavy_swing = false
	windup_multiplier = _base_windup_multiplier
	if telegraph != null:
		telegraph.color = _base_telegraph_color

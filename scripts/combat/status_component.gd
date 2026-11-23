class_name StatusComponent
extends Node
## Reusable status-effect container (spec §8.2): burn, chill, shock, root,
## blight, stun.
##
## One component per combatant, attached in code by Enemy/Player. Any future
## spell gets statuses for free by putting `status` + `status_duration` into
## the DamageResolver payload — the resolver hands them to apply_status().
## Periodic damage (DoT) deliberately goes back through DamageResolver so a
## status tick obeys the same dedupe/defense/telemetry rules as a normal hit.

enum Status { BURN, CHILL, SHOCK, ROOT, BLIGHT, STUN }

const NAMES := {
	Status.BURN: "burn",
	Status.CHILL: "chill",
	Status.SHOCK: "shock",
	Status.ROOT: "root",
	Status.BLIGHT: "blight",
	Status.STUN: "stun",
}
const ID_BY_NAME := {
	"burn": Status.BURN,
	"chill": Status.CHILL,
	"shock": Status.SHOCK,
	"root": Status.ROOT,
	"blight": Status.BLIGHT,
	"stun": Status.STUN,
}

signal applied(status_name: String, duration: float)
signal expired(status_name: String)
signal ticked(status_name: String, amount: int)

## status name -> {"time_left": float, "stacks": int, "source": Node}
var effects: Dictionary = {}

const MAX_STACKS := 5
const DOT_INTERVAL := 1.0
const DOT_BURN := 3
const DOT_BLIGHT := 2

## Hard ceiling on one DoT tick, so stacking cannot out-scale a direct hit.
const MAX_DOT_PER_TICK := 15

## Statuses that stack and refresh-to-the-longer-duration.
const STACKING := {Status.BURN: true, Status.BLIGHT: true, Status.CHILL: true, Status.ROOT: true}

var _dot_accum: Dictionary = {}
var _tick_counter := 0


func _physics_process(delta: float) -> void:
	tick(delta)


func apply_status(status: String, duration: float, source: Node = null, stacks: int = 1) -> bool:
	if not ID_BY_NAME.has(status):
		return false
	if duration <= 0.0:
		return false
	var res := _resistance(status)
	var effective := duration * (1.0 - res)
	if effective <= 0.05:
		return false

	var id: int = ID_BY_NAME[status]
	var stacking: bool = STACKING.get(id, false)
	if effects.has(status):
		var entry: Dictionary = effects[status]
		entry["time_left"] = maxf(float(entry["time_left"]), effective)
		if stacking:
			entry["stacks"] = mini(MAX_STACKS, int(entry["stacks"]) + maxi(1, stacks))
		if source != null:
			entry["source"] = source
	else:
		var start_stacks := 1
		if stacking:
			start_stacks = mini(MAX_STACKS, maxi(1, stacks))
		effects[status] = {"time_left": effective, "stacks": start_stacks, "source": source}

	applied.emit(status, effective)
	var bus := _autoload("EventBus")
	if bus != null:
		bus.status_applied.emit(status, effective)
	return true


func remove_status(status: String) -> void:
	if effects.has(status):
		_expire(status)


func has_status(status: String) -> bool:
	return effects.has(status)


func time_left(status: String) -> float:
	if not effects.has(status):
		return 0.0
	return float(effects[status]["time_left"])


func stacks(status: String) -> int:
	if not effects.has(status):
		return 0
	return int(effects[status]["stacks"])


func clear_all() -> void:
	effects.clear()
	_dot_accum.clear()


func _resistance(status: String) -> float:
	var o := get_parent()
	if o != null and o.has_method("get_status_resistance"):
		return clampf(float(o.call("get_status_resistance", status)), 0.0, 1.0)
	return 0.0


## Public and side-effect-free apart from advancing time and firing DoT through
## DamageResolver. Tests drive this directly; _process() forwards the real delta.
func tick(delta: float) -> void:
	if delta <= 0.0:
		return
	var owner := get_parent()
	var to_expire: Array[String] = []
	# _fire_dot reaches user code (receive_damage -> death -> clear_all), which
	# can mutate effects mid-loop, so walk a snapshot of the keys and re-check
	# membership before touching an entry.
	for key in effects.keys().duplicate():
		var status := String(key)
		if not effects.has(status):
			continue
		var entry: Dictionary = effects[status]
		entry["time_left"] = float(entry["time_left"]) - delta
		var id: int = ID_BY_NAME[status]
		# Accumulate before the expiry test: the last slice of a status that ends
		# inside this delta still has to pay out its tick, so a 3.0 s burn at a
		# 1.0 s interval fires three ticks and not two.
		if id == Status.BURN or id == Status.BLIGHT:
			var acc: float = float(_dot_accum.get(status, 0.0)) + delta
			while acc >= DOT_INTERVAL:
				acc -= DOT_INTERVAL
				if not effects.has(status):
					break
				_fire_dot(status, id, entry, owner)
			# clear_all() during a tick wiped the accumulator; do not resurrect it.
			if effects.has(status):
				_dot_accum[status] = acc
		if float(entry["time_left"]) <= 0.0:
			to_expire.append(status)
	for status in to_expire:
		if effects.has(status):
			_expire(status)


func _fire_dot(status: String, id: int, entry: Dictionary, owner: Node) -> void:
	if owner == null or not is_instance_valid(owner):
		return
	if _owner_is_dead():
		return
	var dmg := _dot_damage(status)
	if dmg <= 0:
		return
	_tick_counter += 1
	var hit_id := "status-%d-%s-%d" % [get_instance_id(), status, _tick_counter]
	var damage_type := "fire" if id == Status.BURN else "blight"
	var source: Node = entry.get("source")
	DamageResolver.resolve_hit(source, owner, {
		"damage": dmg,
		"hit_id": hit_id,
		"damage_type": damage_type,
		"status_tick": true,
	})
	ticked.emit(status, dmg)


func _dot_damage(status: String) -> int:
	var id: int = ID_BY_NAME.get(status, -1)
	var value := 0
	if id == Status.BURN:
		value = DOT_BURN
	elif id == Status.BLIGHT:
		value = DOT_BLIGHT
	else:
		return 0
	var total := stacks(status) * value
	return mini(total, MAX_DOT_PER_TICK)


## Dead guard for DoT. Combatants keep HP in different places (an enemy in its
## HealthComponent child, the player in GameState), so an owner may answer for
## itself through is_status_owner_dead(); otherwise the two known shapes are
## probed here so a status can never tick a corpse back to life.
func _owner_is_dead() -> bool:
	var o := get_parent()
	if o == null or not is_instance_valid(o):
		return true
	if o.has_method("is_status_owner_dead"):
		return bool(o.call("is_status_owner_dead"))
	var hc := o.get_node_or_null("HealthComponent")
	if hc != null and bool(hc.get("is_dead")):
		return true
	if o.is_in_group("player"):
		var gs := _autoload("GameState")
		if gs != null and int(gs.get("hp")) <= 0:
			return true
	return false


func _expire(status: String) -> void:
	effects.erase(status)
	_dot_accum.erase(status)
	expired.emit(status)
	var bus := _autoload("EventBus")
	if bus != null:
		bus.status_expired.emit(status)


func move_multiplier() -> float:
	if has_status("root") or has_status("stun"):
		return 0.0
	if has_status("chill"):
		return 0.6
	return 1.0


func attack_multiplier() -> float:
	if has_status("stun") or has_status("shock"):
		return 0.0
	return 1.0


func blocks_actions() -> bool:
	return has_status("stun") or has_status("root") or has_status("shock")


func healing_multiplier() -> float:
	if has_status("blight"):
		return 0.5
	return 1.0


## Autoloads are resolved at runtime so this class also runs under
## `godot --script`, where autoload identifiers are not registered.
func _autoload(node_name: String) -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null(node_name)

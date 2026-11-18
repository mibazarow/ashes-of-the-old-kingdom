class_name DamageResolver
extends RefCounted
## Single place where a hit becomes damage.
##
## Every attacker goes through resolve_hit(). A hit_id makes the same swing
## unable to damage the same target twice, which is the classic source of
## double-damage bugs when several hurtboxes overlap.

const MAX_TRACKED_HITS := 4096

static var _applied_hits: Dictionary = {}
static var _hit_order: Array[String] = []


static func resolve_hit(attacker: Node, target: Node, payload: Dictionary) -> Dictionary:
	var hit_id: String = String(payload.get("hit_id", ""))
	if target == null or not is_instance_valid(target):
		return {"applied": false, "reason": "no_target"}

	if hit_id != "":
		var key := "%d:%s" % [target.get_instance_id(), hit_id]
		if _applied_hits.has(key):
			return {"applied": false, "reason": "duplicate_hit"}
		_remember(key)

	var raw: int = maxi(1, int(payload.get("damage", 1)))
	var crit: bool = bool(payload.get("critical", false))
	if crit:
		raw = int(round(float(raw) * 1.5))

	var defense: int = 0
	if target.has_method("get_defense"):
		defense = int(target.call("get_defense"))
	var final_damage: int = maxi(1, raw - defense)

	var result := {
		"applied": true,
		"hit_id": hit_id,
		"attacker_id": attacker.get_instance_id() if attacker != null else 0,
		"target_id": target.get_instance_id(),
		"damage_type": String(payload.get("damage_type", "physical")),
		"raw_damage": raw,
		"final_damage": final_damage,
		"critical": crit,
		"defense": defense,
	}

	if target.has_method("receive_damage"):
		target.call("receive_damage", final_damage, result)
	else:
		result["applied"] = false
		result["reason"] = "target_has_no_receive_damage"

	var bus := _autoload("EventBus")
	if bus != null:
		bus.damage_dealt.emit(result)
	var telemetry := _autoload("Telemetry")
	if telemetry != null:
		telemetry.combat(result)
	return result


## Autoloads are resolved at runtime so this class also compiles under
## `godot --script`, where autoload identifiers are not registered.
static func _autoload(node_name: String) -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null(node_name)


static func _remember(key: String) -> void:
	_applied_hits[key] = true
	_hit_order.append(key)
	while _hit_order.size() > MAX_TRACKED_HITS:
		var oldest: String = _hit_order.pop_front()
		_applied_hits.erase(oldest)


static func reset() -> void:
	_applied_hits.clear()
	_hit_order.clear()


static func make_hit_id(owner_id: int, counter: int) -> String:
	return "%d-%d" % [owner_id, counter]

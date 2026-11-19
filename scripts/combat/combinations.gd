class_name Combinations
extends RefCounted
## Elemental combinations (spec §9.2): the single place where one status changes
## what another effect does.
##
## `DamageResolver.resolve_hit()` calls `on_hit()` before handing the result to
## the target (so a target can act on it) and `on_status_applied()` right after a
## status landed; `Player` routes every heal through `on_heal()`. No other file
## implements a rule, so all four are readable as one table and testable without a
## scene.
##
## This class deliberately names no project class (no `DamageResolver`, no
## `StatusComponent`): the resolver calls Combinations, so any static reference
## back to it — direct or through another combat script — is a parse-time circular
## dependency Godot refuses to compile. The resolver is reached through `load()`
## on its cached script resource, and the status component through the node path
## and `call()`, exactly like the resolver reaches it.
##
## Recursion guards — a combination must never chain into itself:
## - the lightning chain resolves with `no_chain: true` and carries no `status`,
##   so a chained hit can neither re-enter `on_status_applied()` nor arc again;
## - `_chain_depth` keeps that guard true even if a caller forgets the flag;
## - the chain walks a snapshot of the enemy group and takes at most
##   `MAX_CHAIN_TARGETS`, so the loop is bounded twice over;
## - live smoke markers are capped by `MAX_SMOKE_ZONES`, so markers cannot grow
##   without bound while a rooted target keeps burning;
## - `on_hit()` never deals damage, so no rule can recurse through
##   `receive_damage()`.

const MAX_CHAIN_TARGETS := 3
const SMOKE_DURATION := 3.0

## Fraction of a second added to the stagger of a chilled target hit by a
## physical blow. Stagger only — the rule never touches damage.
const ICE_PHYSICAL_STAGGER := 0.25
## Radius inside which a wet (chilled) target spreads a shock to other enemies.
const CHAIN_RADIUS := 70.0
## Ceiling on simultaneously live smoke markers.
const MAX_SMOKE_ZONES := 8
## Group every smoke marker joins, so counting them does not depend on node names
## (Godot renames a second sibling called "SmokeZone" to "SmokeZone2").
const SMOKE_GROUP := &"smoke_zone"

const RESOLVER_PATH := "res://scripts/combat/damage_resolver.gd"

static var _chain_depth := 0
static var _smoke_zones: Array[int] = []


## Called by `DamageResolver.resolve_hit()` before the result is handed to the
## target's `receive_damage()`, so the target can act on the block it is given.
## Returns a small description of what triggered (`{}` when nothing did), which
## the resolver merges into its result as `"combination"`; the resolver drops the
## block again if this very hit killed the target, so a corpse never carries one.
##
## Ice + physical: a chilled target takes a deeper stagger from a melee blow. The
## hit itself must stay exactly as painful as it was without chill, so this rule
## returns a stagger bonus and no damage of any kind.
static func on_hit(_attacker: Node, target: Node, payload: Dictionary, _result: Dictionary) -> Dictionary:
	if target == null or not is_instance_valid(target) or _is_dead(target):
		return {}
	if String(payload.get("damage_type", "")) != "physical":
		return {}
	if not _has_status(target, "chill"):
		return {}
	_log_combo("ice_physical", target)
	return {"triggered": "ice_physical", "extra_stagger": ICE_PHYSICAL_STAGGER}


## Healing + ash blight: a heal burns off one blight stack but lands at the blight
## healing multiplier while any stack is left. Returns the amount that should
## actually be applied; without blight the heal passes through untouched.
##
## The spec's "a rare resource cleanses blight completely" is deliberately not
## implemented: no such item exists in `data/items.json`, and inventing one would
## change balance rather than implement a rule.
static func on_heal(target: Node, amount: int) -> int:
	if target == null or not is_instance_valid(target) or amount <= 0:
		return amount
	var sc := _status_of(target)
	if sc == null or not _has_status(target, "blight"):
		return amount
	var applied := int(round(float(amount) * float(sc.call("healing_multiplier"))))
	_remove_one_stack(sc, "blight")
	_log_combo("healing_blight", target)
	return maxi(0, applied)


## Called by `DamageResolver` right after a status was applied successfully.
## `payload` is the hit payload that carried the status; it is what lets the
## lightning rule see the `no_chain` guard. Optional, so a scripted effect or a
## test can call a rule with the three documented arguments.
static func on_status_applied(target: Node, status: String, source: Node, payload: Dictionary = {}) -> void:
	if target == null or not is_instance_valid(target) or _is_dead(target):
		return
	if bool(payload.get("no_chain", false)) or _chain_depth > 0:
		return
	match status:
		"burn":
			_fire_roots(target)
		"shock":
			_lightning_wet(target, source, payload)


## Drops the bookkeeping the rules keep between hits. Tests call it around a
## group; nothing in the game needs to.
static func reset() -> void:
	_chain_depth = 0
	_smoke_zones.clear()


# --- rules -------------------------------------------------------------------


## Fire + roots: the roots burn away and leave a short smoke marker. The marker is
## a plain Node2D with a ColorRect child — no collision shape, no Area2D, no
## receive_damage — so burning the roots away cannot deal free mass damage. The
## burn itself stays on the target: it is the fire, not a new hit.
static func _fire_roots(target: Node) -> void:
	var sc := _status_of(target)
	if sc == null or not _has_status(target, "root"):
		return
	sc.call("remove_status", "root")
	_spawn_smoke_zone(target)
	_log_combo("fire_roots", target)


## Lightning + wet: ice leaves a target wet, so a shock on a chilled target arcs
## to the nearest other enemies. Chain damage is half of the hit that carried the
## shock, the count is capped, and every chain hit is flagged `no_chain` and
## carries no status, so the arc cannot cascade into a second level.
static func _lightning_wet(target: Node, source: Node, payload: Dictionary) -> void:
	var sc := _status_of(target)
	if sc == null or not _has_status(target, "chill"):
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var origin := (target as Node2D).global_position if target is Node2D else Vector2.ZERO
	var candidates: Array[Dictionary] = []
	for node in tree.get_nodes_in_group("enemy"):
		if node == target or not is_instance_valid(node):
			continue
		var other := node as Node2D
		if other == null or not other.has_method("receive_damage") or _is_dead(other):
			continue
		var dist := origin.distance_to(other.global_position)
		if dist > CHAIN_RADIUS:
			continue
		candidates.append({"node": other, "dist": dist})
	if candidates.is_empty():
		return
	# Nearest first, so the cap drops the farthest enemies and the rule stays
	# deterministic instead of depending on group registration order.
	candidates.sort_custom(_by_distance)
	var limit := mini(MAX_CHAIN_TARGETS, candidates.size())
	var chain_damage := maxi(1, int(payload.get("damage", 0)) / 2)
	var base_hit_id := String(payload.get("hit_id", ""))
	if base_hit_id == "":
		base_hit_id = str(target.get_instance_id())
	var resolver: Object = load(RESOLVER_PATH)
	_chain_depth += 1
	for i in range(limit):
		var other: Node2D = candidates[i]["node"]
		resolver.call("resolve_hit", source, other, {
			"damage": chain_damage,
			"hit_id": "%s-chain-%d" % [base_hit_id, i],
			"damage_type": "lightning",
			"no_chain": true,
		})
	_chain_depth -= 1
	_log_combo("lightning_wet", target)


static func _by_distance(a: Dictionary, b: Dictionary) -> bool:
	return float(a["dist"]) < float(b["dist"])


# --- smoke marker ------------------------------------------------------------


## The marker spawns next to the target, lives SMOKE_DURATION seconds through a
## scene-tree timer and deals nothing. Freeing it earlier (a test tearing down its
## arena) disconnects that timer on its own.
static func _spawn_smoke_zone(target: Node) -> void:
	_prune_smoke_zones()
	if _smoke_zones.size() >= MAX_SMOKE_ZONES:
		return
	var parent := target.get_parent()
	if parent == null or not is_instance_valid(parent):
		var tree := Engine.get_main_loop() as SceneTree
		parent = tree.root if tree != null else null
	if parent == null or not is_instance_valid(parent):
		return
	var zone := Node2D.new()
	zone.name = "SmokeZone"
	zone.add_to_group(SMOKE_GROUP)
	var marker := ColorRect.new()
	marker.name = "Smoke"
	marker.color = Color(0.55, 0.55, 0.6, 0.35)
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.offset_left = -14.0
	marker.offset_top = -14.0
	marker.offset_right = 14.0
	marker.offset_bottom = 14.0
	zone.add_child(marker)
	parent.add_child(zone)
	if target is Node2D:
		zone.global_position = (target as Node2D).global_position
	_smoke_zones.append(zone.get_instance_id())
	if zone.is_inside_tree():
		var timer := zone.get_tree().create_timer(SMOKE_DURATION)
		if timer != null:
			timer.timeout.connect(zone.queue_free)


static func _prune_smoke_zones() -> void:
	for i in range(_smoke_zones.size() - 1, -1, -1):
		if not is_instance_valid(instance_from_id(_smoke_zones[i])):
			_smoke_zones.remove_at(i)


# --- shared helpers ----------------------------------------------------------


## The target's status component, resolved by node name the way DamageResolver
## resolves it, and returned as an untyped Node so this script keeps no class
## dependency on StatusComponent.
static func _status_of(target: Node) -> Node:
	var comp := target.get_node_or_null("StatusComponent")
	if comp == null or not comp.has_method("has_status"):
		return null
	return comp


static func _has_status(target: Node, status: String) -> bool:
	var sc := _status_of(target)
	return sc != null and bool(sc.call("has_status", status))


## Mirrors DamageResolver._target_is_dead(): a corpse triggers no combination.
static func _is_dead(target: Node) -> bool:
	if target.has_method("is_status_owner_dead"):
		return bool(target.call("is_status_owner_dead"))
	var hc := target.get_node_or_null("HealthComponent")
	return hc != null and bool(hc.get("is_dead"))


## StatusComponent has no per-stack removal in its API, and one is not needed:
## `effects` is its public table, so a single stack is lowered in place and the
## last stack goes through the documented remove_status().
static func _remove_one_stack(sc: Node, status: String) -> void:
	var stacks := int(sc.call("stacks", status))
	if stacks <= 0:
		return
	if stacks <= 1:
		sc.call("remove_status", status)
		return
	var effects: Variant = sc.get("effects")
	if not (effects is Dictionary):
		return
	var entry: Variant = (effects as Dictionary).get(status)
	if entry is Dictionary:
		(entry as Dictionary)["stacks"] = stacks - 1


static func _log_combo(rule: String, target: Node) -> void:
	var telemetry := _autoload("Telemetry")
	if telemetry != null and telemetry.has_method("event"):
		telemetry.call("event", &"combo", {
			"rule": rule,
			"target": target.get_instance_id(),
		})


## Autoloads are resolved at runtime so this class also compiles under
## `godot --script`, where autoload identifiers are not registered.
static func _autoload(node_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(node_name)
